import Combine
import Foundation

struct AnisetteDirectoryEntry: Codable, Equatable, Identifiable, Sendable {
    let name: String
    let address: String
    let kind: Int?
    var id: String { address }
}

enum AnisetteEndpoint {
    static func url(_ address: String, allowLoopback: Bool = true) -> URL? {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 2048,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              var parts = URLComponents(string: value),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { return nil }
        let scheme = parts.scheme?.lowercased()
        let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        guard scheme == "https" || (allowLoopback && loopback && scheme == "http") else { return nil }
        parts.scheme = scheme
        parts.host = host
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        return parts.url
    }

    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        guard let a = url(lhs), let b = url(rhs) else { return false }
        return a == b
    }
}

enum AnisetteDirectoryError: LocalizedError {
    case invalidData, oversized, invalidAddress, unconfirmedList, noLongerListed, notMacOS, status(Int)

    var errorDescription: String? {
        switch self {
        case .invalidData: "The service returned an unreadable response."
        case .oversized: "The service response was larger than expected."
        case .invalidAddress: "Use an HTTPS server address, or HTTP for a server on this Mac."
        case .unconfirmedList: "Couldn’t confirm the current GitHub list. Refresh and try again."
        case .noLongerListed: "This server is no longer in the current macOS list. Choose another server."
        case .notMacOS: "This server responded without a macOS identity. Choose another server."
        case .status(429): "The service is limiting requests. Try again shortly."
        case .status(let code): "The service returned HTTP \(code). Try again later."
        }
    }
}

struct AnisetteHTTPResponse: Sendable {
    let data: Data
    let response: HTTPURLResponse
}

protocol AnisetteDirectoryTransport: Sendable {
    func fetch(_ request: URLRequest, limit: Int) async throws -> AnisetteHTTPResponse
}

private final class AnisetteNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct AnisetteDirectoryHTTPClient: AnisetteDirectoryTransport {
    private let session: URLSession
    private let redirects = AnisetteNoRedirects()

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        session = URLSession(configuration: configuration)
    }

    func fetch(_ request: URLRequest, limit: Int) async throws -> AnisetteHTTPResponse {
        let (stream, response) = try await session.bytes(for: request, delegate: redirects)
        guard let response = response as? HTTPURLResponse else { throw AnisetteDirectoryError.invalidData }
        guard response.expectedContentLength <= limit else { throw AnisetteDirectoryError.oversized }
        var data = Data()
        for try await byte in stream {
            try Task.checkCancellation()
            guard data.count < limit else { throw AnisetteDirectoryError.oversized }
            data.append(byte)
        }
        return AnisetteHTTPResponse(data: data, response: response)
    }
}

struct AnisetteConnectionCheck: Equatable, Sendable {
    let milliseconds: Int
    let reportsMacOS: Bool

    var message: String {
        reportsMacOS ? "Responding · macOS identity · \(milliseconds) ms" : "Responding · macOS identity not confirmed"
    }
}

@MainActor
final class AnisetteServerDirectory: ObservableObject {
    static let source = URL(string: "https://raw.githubusercontent.com/SideStore/anisette-servers/main/servers.json")!
    static let github = URL(string: "https://github.com/SideStore/anisette-servers/blob/main/servers.json")!
    static let maximumBytes = 256 * 1024

    @Published private(set) var servers: [AnisetteDirectoryEntry] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastChecked: Date?
    @Published private(set) var usingCachedList = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var cacheWarning: String?
    private var etag: String?
    private let transport: any AnisetteDirectoryTransport
    private let cacheURL: URL?

    private struct Document: Codable { let servers: [AnisetteDirectoryEntry] }
    private struct Cache: Codable {
        let version: Int
        let source: URL
        let document: Document
        let checked: Date
        let etag: String?
    }

    static var defaultCacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "app.sideloom.native/anisette-directory-v1.json")
    }

    init(transport: any AnisetteDirectoryTransport = AnisetteDirectoryHTTPClient(),
         cacheURL: URL? = AnisetteServerDirectory.defaultCacheURL) {
        self.transport = transport
        self.cacheURL = cacheURL
        if let cacheURL,
           let size = try? cacheURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size <= Self.maximumBytes,
           let data = try? Data(contentsOf: cacheURL),
           let cache = try? JSONDecoder().decode(Cache.self, from: data),
           cache.version == 1, cache.source == Self.source,
           cache.checked <= Date().addingTimeInterval(300),
           let entries = try? Self.validEntries(cache.document) {
            servers = entries
            lastChecked = cache.checked
            etag = Self.validETag(cache.etag)
            usingCachedList = true
        }
    }

    static func decode(_ data: Data) throws -> [AnisetteDirectoryEntry] {
        guard data.count <= maximumBytes else { throw AnisetteDirectoryError.oversized }
        return try validEntries(JSONDecoder().decode(Document.self, from: data))
    }

    private static func validEntries(_ document: Document) throws -> [AnisetteDirectoryEntry] {
        guard document.servers.count <= 500 else { throw AnisetteDirectoryError.oversized }
        var seen = Set<String>()
        // Filtering an array retains GitHub's order. Status and latency never sort it.
        return document.servers.compactMap { entry in
            guard entry.kind == 2, !entry.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  entry.name.count <= 120,
                  !entry.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  let address = AnisetteEndpoint.url(entry.address, allowLoopback: false)?.absoluteString,
                  seen.insert(address).inserted else { return nil }
            return AnisetteDirectoryEntry(name: entry.name, address: address, kind: 2)
        }
    }

    private static func validETag(_ value: String?) -> String? {
        guard let value, value.utf8.count <= 300,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return value
    }

    func entry(for address: String) -> AnisetteDirectoryEntry? {
        servers.first { AnisetteEndpoint.matches($0.address, address) }
    }

    func refresh() async {
        guard !isRefreshing, !Task.isCancelled else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        var request = URLRequest(url: Self.source, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        do {
            let result = try await transport.fetch(request, limit: Self.maximumBytes)
            try Task.checkCancellation()
            switch result.response.statusCode {
            case 200:
                let entries = try Self.decode(result.data)
                servers = entries
                etag = Self.validETag(result.response.value(forHTTPHeaderField: "ETag"))
            case 304 where lastChecked != nil: break
            default: throw AnisetteDirectoryError.status(result.response.statusCode)
            }
            lastChecked = Date()
            usingCachedList = false
            errorMessage = nil
            saveCache()
        } catch {
            guard !Task.isCancelled, !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
            usingCachedList = lastChecked != nil
            errorMessage = (error as? AnisetteDirectoryError)?.localizedDescription
                ?? "Couldn’t reach GitHub. Check your connection and try again."
        }
    }

    private func saveCache() {
        guard let cacheURL, let lastChecked else { return }
        do {
            let cache = Cache(version: 1, source: Self.source, document: Document(servers: servers), checked: lastChecked, etag: etag)
            let data = try JSONEncoder().encode(cache)
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: cacheURL, options: .atomic)
            cacheWarning = nil
        } catch { cacheWarning = "List updated. An offline copy could not be saved." }
    }

    func checkConnection(to address: String) async throws -> AnisetteConnectionCheck {
        guard let base = AnisetteEndpoint.url(address) else { throw AnisetteDirectoryError.invalidAddress }
        let url = base.appending(path: "v3/client_info")
        let start = ContinuousClock.now
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        let result = try await transport.fetch(request, limit: 16 * 1024)
        try Task.checkCancellation()
        guard result.data.count <= 16 * 1024 else { throw AnisetteDirectoryError.oversized }
        guard result.response.statusCode == 200 else { throw AnisetteDirectoryError.status(result.response.statusCode) }
        struct Metadata: Decodable { let client_info: String; let user_agent: String }
        let metadata: Metadata
        do { metadata = try JSONDecoder().decode(Metadata.self, from: result.data) }
        catch { throw AnisetteDirectoryError.invalidData }
        for value in [metadata.client_info, metadata.user_agent] {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.utf8.count <= 8192,
                  value.utf8.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) else { throw AnisetteDirectoryError.invalidData }
        }
        let elapsed = start.duration(to: .now).components
        let milliseconds = Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
        let mac = metadata.client_info.localizedCaseInsensitiveContains("Mac OS X")
            || metadata.client_info.localizedCaseInsensitiveContains("macOS")
        // Never retain or display the raw identity metadata, and never sign in here.
        return AnisetteConnectionCheck(milliseconds: milliseconds, reportsMacOS: mac)
    }

    func verifiedEntry(for address: String) async throws -> AnisetteDirectoryEntry {
        guard !isRefreshing else { throw AnisetteDirectoryError.unconfirmedList }
        await refresh()
        try Task.checkCancellation()
        guard errorMessage == nil, !usingCachedList, lastChecked != nil else { throw AnisetteDirectoryError.unconfirmedList }
        guard let current = entry(for: address) else { throw AnisetteDirectoryError.noLongerListed }
        let result = try await checkConnection(to: current.address)
        guard result.reportsMacOS else { throw AnisetteDirectoryError.notMacOS }
        return current
    }
}
