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

import Foundation

/// The memory state of a running container's virtual machine: the active
/// policy, the current balloon target, and the guest kernel's whole-VM
/// memory numbers (inflated balloon pages count as used in the guest).
public struct MemoryStatus: Sendable, Codable {
    /// The active memory policy mode.
    public var policyMode: ContainerConfiguration.MemoryPolicy.Mode
    /// The current balloon target; nil when no target was ever set.
    public var targetBytes: UInt64?
    /// The guest kernel's MemTotal.
    public var guestTotalBytes: UInt64
    /// The guest kernel's MemFree.
    public var guestFreeBytes: UInt64
    /// The guest kernel's MemAvailable.
    public var guestAvailableBytes: UInt64

    public init(
        policyMode: ContainerConfiguration.MemoryPolicy.Mode,
        targetBytes: UInt64?,
        guestTotalBytes: UInt64,
        guestFreeBytes: UInt64,
        guestAvailableBytes: UInt64
    ) {
        self.policyMode = policyMode
        self.targetBytes = targetBytes
        self.guestTotalBytes = guestTotalBytes
        self.guestFreeBytes = guestFreeBytes
        self.guestAvailableBytes = guestAvailableBytes
    }
}
