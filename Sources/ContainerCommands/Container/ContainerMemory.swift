//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

import ArgumentParser
import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import ContainerizationError
import Foundation
import Logging

extension Application {
    public struct ContainerMemory: AsyncParsableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "memory",
            abstract: "Manage the memory of a running container",
            subcommands: [
                MemoryTarget.self,
                MemoryPolicy.self,
                MemoryStatus.self,
            ]
        )

        public struct MemoryTarget: AsyncLoggableCommand {
            public init() {}

            public static let configuration = CommandConfiguration(
                commandName: "target",
                abstract: "Set the memory balloon target of a container's virtual machine; "
                    + "a target below the configured memory lets the host reclaim the difference"
            )

            @OptionGroup
            public var logOptions: Flags.Logging

            @Argument(help: "Container ID")
            public var containerId: String

            @Argument(help: "Target memory size (e.g. 8g, 4096m)")
            public var size: String

            public mutating func run() async throws {
                let measurement = try Measurement.parse(parsing: size)
                let bytes = UInt64(measurement.converted(to: .bytes).value)
                guard bytes > 0 else {
                    throw ContainerizationError(.invalidArgument, message: "invalid memory size \(size)")
                }
                let client = ContainerClient()
                try await client.setTargetMemory(id: containerId, bytes: bytes)
                print(containerId)
            }
        }

        public struct MemoryPolicy: AsyncLoggableCommand {
            public init() {}

            public static let configuration = CommandConfiguration(
                commandName: "policy",
                abstract: "Set the memory policy of a container's virtual machine; auto sizes the memory "
                    + "balloon continuously to the guest's workload, returning unused memory to the host"
            )

            @OptionGroup
            public var logOptions: Flags.Logging

            @Argument(help: "Container ID")
            public var containerId: String

            @Argument(help: "Memory policy (auto or manual)")
            public var mode: String

            @Option(name: .customLong("min"), help: "Floor for the balloon target in auto mode (e.g. 1g)")
            public var minSize: String?

            @Option(name: .customLong("headroom"), help: "Memory kept available above the workload in auto mode (e.g. 1g)")
            public var headroomSize: String?

            public mutating func run() async throws {
                guard let mode = ContainerConfiguration.MemoryPolicy.Mode(rawValue: mode) else {
                    throw ContainerizationError(.invalidArgument, message: "invalid memory policy \(mode); use auto or manual")
                }
                var policy = ContainerConfiguration.MemoryPolicy(mode: mode)
                if let minSize {
                    policy.minBytes = UInt64(try Measurement.parse(parsing: minSize).converted(to: .bytes).value)
                }
                if let headroomSize {
                    policy.headroomBytes = UInt64(try Measurement.parse(parsing: headroomSize).converted(to: .bytes).value)
                }
                let client = ContainerClient()
                try await client.setMemoryPolicy(id: containerId, policy: policy)
                print(containerId)
            }
        }

        public struct MemoryStatus: AsyncLoggableCommand {
            public init() {}

            public static let configuration = CommandConfiguration(
                commandName: "status",
                abstract: "Show the memory state of a container's virtual machine: "
                    + "policy, balloon target, and guest memory"
            )

            @OptionGroup
            public var logOptions: Flags.Logging

            @Argument(help: "Container ID")
            public var containerId: String

            public mutating func run() async throws {
                let client = ContainerClient()
                let status = try await client.memoryStatus(id: containerId)
                let mib = { (bytes: UInt64) in "\(bytes / (1024 * 1024))M" }
                print("policy: \(status.policyMode.rawValue)")
                if let target = status.targetBytes {
                    print("target: \(mib(target))")
                }
                print("guest total: \(mib(status.guestTotalBytes))")
                print("guest free: \(mib(status.guestFreeBytes))")
                print("guest available: \(mib(status.guestAvailableBytes))")
            }
        }
    }
}
