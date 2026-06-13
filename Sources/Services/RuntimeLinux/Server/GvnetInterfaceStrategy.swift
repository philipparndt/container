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
import ContainerRuntimeClient
import ContainerXPC
import Containerization
import ContainerizationError
import Darwin
import Foundation
import Logging

/// XPC key under which the gvnet network passes the path of the userspace
/// network stack's vfkit unixgram socket for this attachment.
public let gvnetSocketPathKey = "gvnetSocketPath"

/// Interface strategy for the gvnet transparent-egress network. It connects a
/// datagram socket to the per-VM userspace network stack (gvisor-tap-vsock
/// served over a vfkit unixgram socket) and backs the guest NIC with it via
/// FileHandleInterface, so the guest's connections are re-originated from the
/// host (transparent egress) without a host bridge.
public struct GvnetInterfaceStrategy: InterfaceStrategy {
    private let log: Logger

    public init(log: Logger) {
        self.log = log
    }

    public func toInterface(attachment: Attachment, interfaceIndex: Int, additionalData: XPCMessage?) throws -> Interface {
        guard let socketPath = additionalData?.string(key: gvnetSocketPathKey) else {
            throw ContainerizationError(
                .invalidState, message: "gvnet attachment is missing the netstack socket path")
        }
        let fd = try Self.connectDatagramSocket(to: socketPath)
        log.info("gvnet: connected NIC datagram socket to \(socketPath) (fd \(fd))")
        let ipv4Gateway = interfaceIndex == 0 ? attachment.ipv4Gateway : nil
        return FileHandleInterface(
            fileDescriptor: fd,
            ipv4Address: attachment.ipv4Address,
            ipv4Gateway: ipv4Gateway,
            macAddress: attachment.macAddress,
            // The gvnet network leaves mtu unset (0); the userspace netstack
            // runs at 1500. VZ rejects any attachment MTU below 1500, and
            // `?? 1500` only catches nil — not 0 — so clamp to the netstack MTU.
            mtu: Swift.max(attachment.mtu ?? 1500, 1500)
        )
    }

    /// Creates a SOCK_DGRAM unix socket bound to a unique local path (so the
    /// netstack can send frames back) and connected to the netstack's vfkit
    /// socket. VZFileHandleNetworkDeviceAttachment requires a connected
    /// datagram socket. Ownership of the returned fd transfers to the caller.
    static func connectDatagramSocket(to remotePath: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            throw ContainerizationError(.internalError, message: "gvnet: socket() failed: \(errno)")
        }
        var ok = false
        defer { if !ok { close(fd) } }

        // bind a unique short local path (sun_path is only 104 bytes on macOS)
        let localPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("k3c-gv-\(getpid())-\(UInt16.random(in: 0..<UInt16.max)).sock")
        unlink(localPath)
        try Self.withSockaddrUn(path: localPath) { addr, len in
            guard bind(fd, addr, len) == 0 else {
                throw ContainerizationError(.internalError, message: "gvnet: bind(\(localPath)) failed: \(errno)")
            }
        }
        try Self.withSockaddrUn(path: remotePath) { addr, len in
            guard connect(fd, addr, len) == 0 else {
                throw ContainerizationError(.internalError, message: "gvnet: connect(\(remotePath)) failed: \(errno)")
            }
        }
        ok = true
        return fd
    }

    /// Builds a sockaddr_un for the given path and invokes body with a pointer
    /// to it (sockaddr) and its length.
    private static func withSockaddrUn(path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Void) throws {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < cap else {
            throw ContainerizationError(.invalidArgument, message: "gvnet: socket path too long (\(path))")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
            sunPath.withMemoryRebound(to: CChar.self, capacity: cap) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[bytes.count] = 0
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        try withUnsafePointer(to: &addr) { p in
            try p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                try body(sa, len)
            }
        }
    }
}
