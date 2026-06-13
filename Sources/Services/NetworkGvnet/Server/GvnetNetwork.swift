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

import ContainerNetworkServer
import ContainerResource
import ContainerXPC
import ContainerizationError
import ContainerizationExtras
import Logging

/// XPC key under which the gvnet network passes its userspace-netstack vfkit
/// socket path to the runtime's interface strategy. Must match the runtime
/// side (GvnetInterfaceStrategy).
public let gvnetSocketPathKey = "gvnetSocketPath"

/// A transparent-egress network. It allocates addresses like a NAT network
/// (handled generically by the network service), but instead of a host bridge
/// the guest NIC is backed by a userspace network stack (gvisor-tap-vsock)
/// reachable over the vfkit unixgram socket passed in the network's options.
/// The socket path is forwarded to the runtime via additional data so the
/// interface strategy can connect the guest NIC to the right per-VM netstack.
public actor GvnetNetwork: Network {
    private static let defaultIPv4Subnet = try! CIDRv4("192.168.127.1/24")

    private let configuration: NetworkConfiguration
    private let socketPath: String
    private let log: Logger
    private var _status: NetworkStatus?

    public init(configuration: NetworkConfiguration, log: Logger) throws {
        guard configuration.mode == .nat else {
            throw ContainerizationError(.unsupported, message: "invalid network mode \(configuration.mode)")
        }
        guard configuration.ipv6Subnet == nil else {
            throw ContainerizationError(.unsupported, message: "IPv6 subnet assignment is not yet implemented")
        }
        guard let socketPath = configuration.options[gvnetSocketPathKey], !socketPath.isEmpty else {
            throw ContainerizationError(
                .invalidArgument, message: "gvnet network requires the \(gvnetSocketPathKey) option")
        }
        self.configuration = configuration
        self.socketPath = socketPath
        self.log = log
        self._status = nil
    }

    public nonisolated var id: String { configuration.id }

    /// gvnet has a single, default variant: the runtime always selects the
    /// gvnet interface strategy from the plugin name alone.
    public nonisolated var variant: String? { nil }

    public var status: NetworkStatus? { _status }

    public nonisolated func withAdditionalData(_ handler: (XPCMessage?) throws -> Void) throws {
        let message = XPCMessage(route: "gvnet")
        message.set(key: gvnetSocketPathKey, value: socketPath)
        try handler(message)
    }

    public func start() async throws {
        guard _status == nil else {
            throw ContainerizationError(.invalidState, message: "cannot start network \(configuration.id): already started")
        }
        let ipv4Subnet = configuration.ipv4Subnet ?? Self.defaultIPv4Subnet
        let gateway = IPv4Address(ipv4Subnet.lower.value + 1)
        self._status = NetworkStatus(
            ipv4Subnet: ipv4Subnet,
            ipv4Gateway: gateway,
            ipv6Subnet: nil
        )
        log.info(
            "started gvnet network",
            metadata: [
                "id": "\(configuration.id)",
                "cidr": "\(ipv4Subnet)",
                "socket": "\(socketPath)",
            ]
        )
    }
}
