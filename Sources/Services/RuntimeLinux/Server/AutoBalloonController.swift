//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ContainerResource
import Containerization
import ContainerizationOS
import Foundation
import Logging

/// Sizes a virtual machine's virtio memory balloon continuously so the host
/// footprint follows the guest's workload instead of only ever growing.
///
/// Every tick the controller reads the guest's /proc/meminfo and moves the
/// balloon target to the workload plus headroom: lowering the target
/// inflates the balloon and the host frees the ballooned pages; raising it
/// deflates and re-commits memory. When the guest runs low on available
/// memory the target is boosted immediately and the controller polls at a
/// much shorter interval until the pressure clears — the guest's own
/// deflate-on-OOM escape hatch works but only trickles pages back, so
/// prompt host-side deflation is what keeps workloads fast.
///
/// A virtual machine restored from saved state needs one full deflate +
/// re-inflate cycle before the host frees anything: restore re-commits the
/// whole guest memory, and the hypervisor only frees freshly ballooned
/// pages. Start the controller with `recycle: true` after a restore.
actor AutoBalloonController {
    struct Policy: Sendable {
        /// The configured memory size; the balloon fully deflated.
        var maxBytes: UInt64
        /// Floor for the balloon target.
        var minBytes: UInt64
        /// Memory kept available for the guest above its workload.
        var headroomBytes: UInt64

        init(configuredMemory: UInt64, settings: ContainerConfiguration.MemoryPolicy?) {
            self.maxBytes = configuredMemory
            self.minBytes = min(settings?.minBytes ?? 1024.mib(), configuredMemory)
            self.headroomBytes = min(settings?.headroomBytes ?? 1024.mib(), configuredMemory)
        }
    }

    private let container: LinuxContainer
    private let policy: Policy
    private let logger: Logging.Logger

    /// The balloon target currently applied. The balloon device keeps its
    /// state across suspend/restore, so a restarted controller starts from
    /// the persisted value handed to `run`.
    private var targetBytes: UInt64
    private var task: Task<Void, Never>?

    /// Normal poll interval.
    private static let interval: Duration = .seconds(10)
    /// Poll interval while the guest is short on available memory.
    private static let pressureInterval: Duration = .seconds(1)
    /// Back-off after a failed guest reading (e.g. during shutdown).
    private static let errorInterval: Duration = .seconds(30)
    /// Ignore target changes smaller than this to avoid balloon churn.
    private static let hysteresisBytes: UInt64 = 256.mib()

    init(
        container: LinuxContainer,
        policy: Policy,
        initialTarget: UInt64?,
        logger: Logging.Logger
    ) {
        self.container = container
        self.policy = policy
        self.targetBytes = min(initialTarget ?? policy.maxBytes, policy.maxBytes)
        self.logger = logger
    }

    /// The balloon target the controller last applied (the configured
    /// memory until the first adjustment).
    var currentTarget: UInt64 {
        self.targetBytes
    }

    /// Start the control loop. With `recycle` the balloon is first fully
    /// deflated and re-inflated so the host re-frees the memory a restore
    /// re-committed.
    func start(recycle: Bool) {
        guard self.task == nil else { return }
        self.logger.info(
            "auto balloon: starting",
            metadata: [
                "max": "\(self.policy.maxBytes)",
                "min": "\(self.policy.minBytes)",
                "headroom": "\(self.policy.headroomBytes)",
                "recycle": "\(recycle)",
            ])
        self.task = Task { [weak self] in
            await self?.run(recycle: recycle)
        }
    }

    /// Stop the control loop. The balloon keeps its current target.
    func stop() async {
        guard let task = self.task else { return }
        task.cancel()
        await task.value
        self.task = nil
        self.logger.info("auto balloon: stopped")
    }

    private func run(recycle: Bool) async {
        if recycle {
            // Fully deflate and let the guest hand every ballooned page
            // back before the loop below re-inflates: the hypervisor frees
            // only freshly ballooned pages, and a restored balloon may be
            // inflated to a target this controller never saw.
            await self.setTarget(self.policy.maxBytes)
            try? await Task.sleep(for: .seconds(3))
        }
        while !Task.isCancelled {
            let interval = await self.tick()
            do {
                try await Task.sleep(for: interval)
            } catch {
                break  // cancelled
            }
        }
    }

    /// One control step; returns the delay until the next.
    private func tick() async -> Duration {
        let info: GuestMemoryInfo
        do {
            info = try await self.container.guestMemoryInfo()
        } catch {
            if !Task.isCancelled {
                self.logger.debug("auto balloon: guest reading failed", metadata: ["error": "\(error)"])
            }
            return Self.errorInterval
        }

        // Inflated balloon pages count as used in the guest, so subtract
        // them to get the real workload. The guest may lag behind the
        // target; clamp instead of going negative.
        let balloonBytes = self.policy.maxBytes > self.targetBytes ? self.policy.maxBytes - self.targetBytes : 0
        let usedBytes = info.totalBytes > info.availableBytes ? info.totalBytes - info.availableBytes : 0
        let workloadBytes = usedBytes > balloonBytes ? usedBytes - balloonBytes : 0
        let desired = min(max(workloadBytes + self.policy.headroomBytes, self.policy.minBytes), self.policy.maxBytes)

        // The guest is close to running dry: deflate NOW and poll fast.
        // The guest's own deflate-on-OOM path frees pages far too slowly
        // to keep a bursty workload (image pull, pod start) healthy.
        let pressureFloor = max(self.policy.headroomBytes / 2, 256.mib())
        if info.availableBytes < pressureFloor && self.targetBytes < self.policy.maxBytes {
            let boost = max(self.policy.headroomBytes, self.policy.maxBytes / 8)
            let boosted = min(max(desired, self.targetBytes + boost), self.policy.maxBytes)
            self.logger.info(
                "auto balloon: guest memory pressure, deflating",
                metadata: ["available": "\(info.availableBytes)", "target": "\(boosted)"])
            await self.setTarget(boosted)
            return Self.pressureInterval
        }

        if desired > self.targetBytes {
            // Growing workload: keep the headroom ahead of it promptly.
            await self.setTarget(desired)
            return Self.pressureInterval
        }
        if self.targetBytes - desired >= Self.hysteresisBytes {
            self.logger.info(
                "auto balloon: reclaiming",
                metadata: ["workload": "\(workloadBytes)", "target": "\(desired)"])
            await self.setTarget(desired)
        }
        return Self.interval
    }

    private func setTarget(_ bytes: UInt64) async {
        do {
            try await self.container.setTargetMemory(bytes: bytes)
            self.targetBytes = bytes
        } catch {
            if !Task.isCancelled {
                self.logger.warning("auto balloon: setting target failed", metadata: ["error": "\(error)"])
            }
        }
    }
}
