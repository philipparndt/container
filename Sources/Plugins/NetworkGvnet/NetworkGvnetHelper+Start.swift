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

import ArgumentParser
import ContainerLog
import ContainerNetworkClient
import ContainerNetworkServer
import ContainerNetworkGvnetServer
import ContainerResource
import ContainerXPC
import ContainerizationError
import ContainerizationExtras
import Foundation
import Logging

extension NetworkGvnetHelper {
    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "start",
            abstract: "Starts the gvnet network plugin"
        )

        @Flag(name: .long, help: "Enable debug logging")
        var debug = false

        @Option(name: .long, help: "XPC service identifier")
        var serviceIdentifier: String

        @Option(name: .shortAndLong, help: "Network identifier")
        var id: String

        @Option(name: .long, help: "Network mode")
        var mode: String = NetworkMode.nat.rawValue

        @Option(name: .customLong("subnet"), help: "CIDR address for the IPv4 subnet")
        var ipv4Subnet: String?

        // Accepted for parity with the generic network-plugin launch args the
        // apiserver passes (vmnet declares these). gvnet is IPv4-only and has a
        // single variant, so subnet-v6/variant are accepted and ignored.
        @Option(name: .customLong("subnet-v6"), help: "CIDR address for the IPv6 prefix (ignored; gvnet is IPv4-only)")
        var ipv6Subnet: String?

        @Option(name: .long, help: "Variant of the network helper to use (accepted for compatibility; ignored)")
        var variant: String?

        @Option(name: .customLong("gvnet-socket"), help: "vfkit unixgram socket path of this network's userspace netstack")
        var gvnetSocket: String

        func run() async throws {
            let commandName = NetworkGvnetHelper._commandName
            let log = ServiceLogger.bootstrap(category: "NetworkGvnetHelper", metadata: ["id": "\(id)"], debug: debug, logPath: nil)
            do {
                log.info("configuring XPC server")
                let ipv4Subnet = try self.ipv4Subnet.map { try CIDRv4($0) }
                let configuration = try NetworkConfiguration(
                    name: id,
                    mode: NetworkMode(rawValue: mode) ?? .nat,
                    ipv4Subnet: ipv4Subnet,
                    ipv6Subnet: nil,
                    plugin: commandName,
                    options: [gvnetSocketPathKey: gvnetSocket]
                )
                let network = try GvnetNetwork(configuration: configuration, log: log)
                try await network.start()
                let service = try await DefaultNetworkService(network: network, log: log)
                let harness = NetworkHarness(service: service)
                let xpc = XPCServer(
                    identifier: serviceIdentifier,
                    routes: [
                        NetworkRoutes.status.rawValue: XPCServer.route(harness.status),
                        NetworkRoutes.allocate.rawValue: harness.allocate,
                        NetworkRoutes.lookup.rawValue: XPCServer.route(harness.lookup),
                    ],
                    log: log
                )
                log.info("starting XPC server")
                try await xpc.listen()
            } catch {
                log.error("helper failed", metadata: ["name": "\(commandName)", "error": "\(error)"])
                throw error
            }
        }
    }
}
