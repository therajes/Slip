import Foundation
import Darwin

private actor HostResolutionCache {
    static let shared = HostResolutionCache()
    private var verified: Set<String> = []
    func contains(_ host: String) -> Bool { verified.contains(host) }
    func insert(_ host: String) { verified.insert(host) }
}

enum NetworkEndpointPolicy {
    static func publicHost(_ input: String) -> Bool {
        let host = input.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !host.isEmpty, !host.hasSuffix("."), host != "localhost", !host.hasSuffix(".localhost"),
              !host.hasSuffix(".local"), !host.hasSuffix(".internal"), !host.contains("%") else { return false }
        let labels = host.split(separator: ".")
        if labels.allSatisfy({ UInt64($0) != nil }), labels.contains(where: { $0.count > 1 && $0.first == "0" }) { return false }
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            let n = UInt32(bigEndian: v4.s_addr)
            let a = n >> 24, b = (n >> 16) & 255
            return a != 0 && a != 10 && a != 127 && a < 224 && !(a == 100 && (64...127).contains(b))
                && !(a == 169 && b == 254) && !(a == 172 && (16...31).contains(b))
                && !(a == 192 && (b == 168 || b == 0)) && !(a == 198 && (b == 18 || b == 19))
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            // Only global unicast; excludes mapped IPv4, loopback, link-local and multicast.
            return bytes[0] & 0xe0 == 0x20
        }
        // Reject alternate numeric IPv4 forms interpreted differently by URL loaders.
        guard !host.contains(":"), !host.split(separator: ".").allSatisfy({ UInt64($0) != nil || $0.hasPrefix("0x") }) else { return false }
        return true
    }

    static func resolvesPublicly(_ host: String) async -> Bool {
        let key = host.lowercased()
        if await HostResolutionCache.shared.contains(key) { return true }
        let result = await Task.detached(priority: .utility) {
            guard publicHost(key) else { return false }
            var hints = addrinfo()
            hints.ai_socktype = SOCK_STREAM
            var addresses: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(key, nil, &hints, &addresses) == 0, let first = addresses else { return false }
            defer { freeaddrinfo(first) }
            var current: UnsafeMutablePointer<addrinfo>? = first
            while let item = current {
                var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(item.pointee.ai_addr, item.pointee.ai_addrlen, &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0,
                      publicHost(String(decoding: name.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)) else { return false }
                current = item.pointee.ai_next
            }
            return true
        }.value
        if result { await HostResolutionCache.shared.insert(key) }
        return result
    }
}
