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
                MemoryTarget.self
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
    }
}
