import Darwin
import Foundation

/// A dual-stack UDP socket with an OS-assigned port.
///
/// It must be able to reach the receiver over IPv6: an Apple TV whose RTSP
/// session was set up over its IPv6 link-local address binds the stream's
/// data/control ports on IPv6 only, and answers IPv4 datagrams to those
/// ports with ICMP port-unreachable (confirmed by packet capture against
/// kaan, 2026-11-07). Destinations may be IPv4, IPv6, or scoped IPv6
/// literals like `fe80::1%en0`.
public final class AirPlayUDPPort {
    public enum PortError: Error {
        case invalidAddress(String)
        case socketFailure(Int32)
        case sendFailed(Int32)
    }

    public let port: UInt16
    private let descriptor: Int32

    /// `localAddress` is kept for API compatibility; the socket binds to
    /// the IPv6 wildcard with `IPV6_V6ONLY` off so it serves both families.
    public init(localAddress: String) throws {
        let descriptor = Darwin.socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw PortError.socketFailure(errno) }
        var off: Int32 = 0
        _ = setsockopt(descriptor, IPPROTO_IPV6, IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
        var local = sockaddr_in6()
        local.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        local.sin6_family = sa_family_t(AF_INET6)
        local.sin6_port = 0
        local.sin6_addr = in6addr_any
        let bindResult = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bindResult == 0 else {
            let error = errno
            Darwin.close(descriptor)
            throw PortError.socketFailure(error)
        }

        var bound = sockaddr_in6()
        var addressLength = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &addressLength)
            }
        }
        guard nameResult == 0 else {
            let error = errno
            Darwin.close(descriptor)
            throw PortError.socketFailure(error)
        }

        self.descriptor = descriptor
        port = UInt16(bigEndian: bound.sin6_port)
    }

    deinit {
        Darwin.close(descriptor)
    }

    public func send(_ bytes: [UInt8], to address: String, port destinationPort: UInt16) throws {
        var destination = try Self.resolve(address, port: destinationPort)
        let sent = bytes.withUnsafeBytes { bytesPointer in
            withUnsafePointer(to: &destination) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(descriptor, bytesPointer.baseAddress, bytesPointer.count, 0, $0,
                           socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
        guard sent == bytes.count else { throw PortError.sendFailed(errno) }
    }

    /// Numeric IPv4/IPv6 literal (with optional `%scope`) to a
    /// `sockaddr_in6`, mapping IPv4 to `::ffff:a.b.c.d`.
    private static func resolve(_ address: String, port: UInt16) throws -> sockaddr_in6 {
        var hints = addrinfo()
        hints.ai_family = AF_INET6
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_flags = AI_NUMERICHOST | AI_V4MAPPED
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(address, String(port), &hints, &result) == 0, let first = result else {
            throw PortError.invalidAddress(address)
        }
        defer { freeaddrinfo(first) }
        guard let socketAddress = first.pointee.ai_addr, first.pointee.ai_family == AF_INET6 else {
            throw PortError.invalidAddress(address)
        }
        return UnsafeRawPointer(socketAddress).assumingMemoryBound(to: sockaddr_in6.self).pointee
    }
}
