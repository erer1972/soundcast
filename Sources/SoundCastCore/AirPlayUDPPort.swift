import Darwin
import Foundation

/// A UDP socket bound to a local IPv4 address with an OS-assigned port.
public final class AirPlayUDPPort {
    public enum PortError: Error {
        case invalidAddress(String)
        case socketFailure(Int32)
        case sendFailed(Int32)
    }

    public let port: UInt16
    private let descriptor: Int32

    public init(localAddress: String) throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw PortError.socketFailure(errno) }
        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = 0
        guard localAddress.withCString({ inet_pton(AF_INET, $0, &local.sin_addr) }) == 1 else {
            Darwin.close(descriptor)
            throw PortError.invalidAddress(localAddress)
        }
        let bindResult = withUnsafePointer(to: &local) { localPointer in
            localPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let error = errno
            Darwin.close(descriptor)
            throw PortError.socketFailure(error)
        }

        var bound = sockaddr_in()
        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { boundPointer in
            boundPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &addressLength)
            }
        }
        guard nameResult == 0 else {
            let error = errno
            Darwin.close(descriptor)
            throw PortError.socketFailure(error)
        }

        self.descriptor = descriptor
        port = UInt16(bigEndian: bound.sin_port)
    }

    deinit {
        Darwin.close(descriptor)
    }

    public func send(_ bytes: [UInt8], to address: String, port destinationPort: UInt16) throws {
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = destinationPort.bigEndian
        guard address.withCString({ inet_pton(AF_INET, $0, &destination.sin_addr) }) == 1 else {
            throw PortError.invalidAddress(address)
        }
        let sent = bytes.withUnsafeBytes { bytesPointer in
            withUnsafePointer(to: &destination) { destinationPointer in
                destinationPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(descriptor, bytesPointer.baseAddress, bytesPointer.count, 0, $0,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == bytes.count else { throw PortError.sendFailed(errno) }
    }
}