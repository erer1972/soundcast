import Darwin
import Foundation
import dnssd

/// The addresses a native AirPlay 2 session needs for one receiver.
///
/// RTSP and the RTP audio/control streams must use the receiver's IPv6
/// link-local address (it binds stream ports on IPv6 only — see design
/// doc §12.5). The PTP clock currently runs over IPv4, so that address
/// is needed too.
public struct AirPlayResolvedReceiver: Sendable, CustomStringConvertible {
    public let serviceName: String
    public let hostName: String
    public let port: UInt16
    public let interfaceName: String
    /// Unscoped literal, e.g. `fe80::422:6a1f:4bc5:3df7`.
    public let ipv6LinkLocal: String
    public let ipv4: String

    /// `fe80::…%en0`, for sockets and `NWEndpoint.Host`.
    public var scopedIPv6: String { "\(ipv6LinkLocal)%\(interfaceName)" }

    public var description: String {
        "\(serviceName) (\(hostName)) [\(scopedIPv6)]:\(port) ipv4=\(ipv4)"
    }
}

/// Resolves a Bonjour `_airplay._tcp` instance name (as listed by
/// `AirPlayDiscovery`) to the addresses above via the DNS-SD API.
public enum AirPlayReceiverResolver {
    public enum ResolveError: Error, CustomStringConvertible {
        case dnsServiceError(Int32)
        case timedOut(String)
        case missingAddress(String)

        public var description: String {
            switch self {
            case .dnsServiceError(let code): return "DNS-SD error \(code)"
            case .timedOut(let what): return "timed out \(what)"
            case .missingAddress(let what): return "receiver has no \(what) address"
            }
        }
    }

    public static func resolve(serviceName: String, timeout: TimeInterval = 5) async throws -> AirPlayResolvedReceiver {
        let service = try await resolveService(serviceName, timeout: timeout)
        let addresses = try await lookupAddresses(host: service.host, interfaceIndex: service.interfaceIndex, timeout: timeout)
        guard let ipv6 = addresses.ipv6LinkLocal else { throw ResolveError.missingAddress("IPv6 link-local") }
        guard let ipv4 = addresses.ipv4 else { throw ResolveError.missingAddress("IPv4") }
        // Scope the link-local address to the interface the IPv4 route
        // uses, so RTSP/RTP and PTP (IPv4, route-selected) leave on the
        // same interface. Hosts with two NICs on one LAN otherwise get
        // whichever interface DNS-SD answered on first.
        var interfaceName: String?
        var peer = sockaddr_in()
        peer.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        peer.sin_family = sa_family_t(AF_INET)
        if ipv4.withCString({ inet_pton(AF_INET, $0, &peer.sin_addr) }) == 1,
           let local = AirPlayPTPClock.routeSelectedIPv4(to: peer) {
            interfaceName = AirPlayPTPClock.interfaceName(forLocalIPv4: local)
        }
        if interfaceName == nil {
            var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
            if if_indextoname(service.interfaceIndex, &nameBuffer) != nil {
                interfaceName = String(cString: nameBuffer)
            }
        }
        guard let interfaceName else { throw ResolveError.missingAddress("interface") }
        return AirPlayResolvedReceiver(
            serviceName: serviceName,
            hostName: service.host,
            port: service.port,
            interfaceName: interfaceName,
            ipv6LinkLocal: ipv6,
            ipv4: ipv4
        )
    }

    // MARK: - DNS-SD plumbing

    private struct ServiceInfo: Sendable { let host: String; let port: UInt16; let interfaceIndex: UInt32 }
    private struct AddressInfo: Sendable { var ipv6LinkLocal: String?; var ipv4: String? }

    /// Owns one DNSServiceRef plus the continuation it completes. All
    /// access happens on `queue` (the queue DNS-SD calls back on).
    private final class Operation<Value: Sendable>: @unchecked Sendable {
        let queue = DispatchQueue(label: "SoundCast.AirPlayReceiverResolver")
        var ref: DNSServiceRef?
        var continuation: CheckedContinuation<Value, Error>?
        var partial = AddressInfo()

        func finish(_ result: Result<Value, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            if let ref { DNSServiceRefDeallocate(ref) }
            ref = nil
            continuation.resume(with: result)
        }
    }

    private static func resolveService(_ name: String, timeout: TimeInterval) async throws -> ServiceInfo {
        let operation = Operation<ServiceInfo>()
        return try await withCheckedThrowingContinuation { continuation in
            operation.queue.async {
                operation.continuation = continuation
                let context = Unmanaged.passUnretained(operation).toOpaque()
                let callback: DNSServiceResolveReply = { _, _, interfaceIndex, error, _, host, port, _, _, context in
                    let operation = Unmanaged<Operation<ServiceInfo>>.fromOpaque(context!).takeUnretainedValue()
                    guard error == kDNSServiceErr_NoError, let host else {
                        operation.finish(.failure(ResolveError.dnsServiceError(error)))
                        return
                    }
                    operation.finish(.success(ServiceInfo(
                        host: String(cString: host),
                        port: UInt16(bigEndian: port),
                        interfaceIndex: interfaceIndex
                    )))
                }
                var ref: DNSServiceRef?
                let error = DNSServiceResolve(&ref, 0, 0, name, "_airplay._tcp", "local.", callback, context)
                guard error == kDNSServiceErr_NoError, let ref else {
                    operation.finish(.failure(ResolveError.dnsServiceError(error)))
                    return
                }
                operation.ref = ref
                DNSServiceSetDispatchQueue(ref, operation.queue)
                operation.queue.asyncAfter(deadline: .now() + timeout) {
                    operation.finish(.failure(ResolveError.timedOut("resolving \(name)")))
                }
            }
        }
    }

    private static func lookupAddresses(host: String, interfaceIndex: UInt32, timeout: TimeInterval) async throws -> AddressInfo {
        let operation = Operation<AddressInfo>()
        return try await withCheckedThrowingContinuation { continuation in
            operation.queue.async {
                operation.continuation = continuation
                let context = Unmanaged.passUnretained(operation).toOpaque()
                let callback: DNSServiceGetAddrInfoReply = { _, _, _, error, _, address, _, context in
                    let operation = Unmanaged<Operation<AddressInfo>>.fromOpaque(context!).takeUnretainedValue()
                    guard error == kDNSServiceErr_NoError, let address else { return }
                    switch Int32(address.pointee.sa_family) {
                    case AF_INET:
                        var ipv4 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                        operation.partial.ipv4 = operation.partial.ipv4 ?? numericString(AF_INET, &ipv4)
                    case AF_INET6:
                        var ipv6 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                        let isLinkLocal = ipv6.__u6_addr.__u6_addr8.0 == 0xFE && (ipv6.__u6_addr.__u6_addr8.1 & 0xC0) == 0x80
                        if isLinkLocal, operation.partial.ipv6LinkLocal == nil {
                            operation.partial.ipv6LinkLocal = numericString(AF_INET6, &ipv6)
                        }
                    default:
                        break
                    }
                    if operation.partial.ipv4 != nil, operation.partial.ipv6LinkLocal != nil {
                        operation.finish(.success(operation.partial))
                    }
                }
                var ref: DNSServiceRef?
                let error = DNSServiceGetAddrInfo(
                    &ref, 0, interfaceIndex,
                    DNSServiceProtocol(kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6),
                    host, callback, context
                )
                guard error == kDNSServiceErr_NoError, let ref else {
                    operation.finish(.failure(ResolveError.dnsServiceError(error)))
                    return
                }
                operation.ref = ref
                DNSServiceSetDispatchQueue(ref, operation.queue)
                operation.queue.asyncAfter(deadline: .now() + timeout) {
                    // Return whatever arrived; the caller reports what's missing.
                    operation.finish(.success(operation.partial))
                }
            }
        }
    }
}

/// File-scope (not a static method) so the DNS-SD C callbacks, which
/// can't capture context, can call it.
private func numericString<T>(_ family: Int32, _ address: inout T) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    guard inet_ntop(family, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
    return String(cString: buffer)
}
