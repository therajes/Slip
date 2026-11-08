import Foundation

struct AppUpdateRelease: Codable, Hashable, Identifiable, Sendable {
    var id: String { version + downloadURL.absoluteString }
    let version: String
    let downloadURL: URL
    let notes: String
    let date: String?
    let minOSVersion: String?
    let maxOSVersion: String?
    var assetName: String { downloadURL.lastPathComponent }

    func compatibility(with ios: String?) -> String {
        guard let ios else { return "Connect an iPhone to check iOS compatibility." }
        if let minimum = minOSVersion, Self.compare(ios, minimum) == .orderedAscending { return "Requires iOS \(minimum) or newer." }
        if let maximum = maxOSVersion, Self.compare(ios, maximum) == .orderedDescending { return "Supports up to iOS \(maximum)." }
        return minOSVersion == nil && maxOSVersion == nil ? "Developer did not provide iOS compatibility." : "Compatible with iOS \(ios) according to the source."
    }
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        func normalized(_ input: String) -> String {
            let value = input.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            var parts = value.split(separator: ".").map(String.init)
            if parts.allSatisfy({ Int($0) != nil }) {
                while parts.count > 1 && Int(parts.last ?? "") == 0 { parts.removeLast() }
                return parts.joined(separator: ".")
            }
            return value
        }
        return normalized(lhs).compare(normalized(rhs), options: [.numeric, .caseInsensitive])
    }
}

enum SourceFeedParser {
    static func secureURL(_ value: String) -> URL? {
        guard let parts = URLComponents(string: value), parts.scheme?.lowercased() == "https", parts.host?.isEmpty == false,
              parts.user == nil, parts.password == nil else { return nil }
        guard NetworkEndpointPolicy.publicHost(parts.host ?? "") else { return nil }
        return parts.url
    }
    static func sourceURL(_ input: String, github: Bool) throws -> URL {
        if github {
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            let components: [String]
            if let url = secureURL(trimmed), url.host?.lowercased() == "github.com" { components = url.path.split(separator: "/").map(String.init) }
            else { components = trimmed.split(separator: "/").map(String.init) }
            guard components.count == 2, components.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) } }), !components.contains("..") else {
                throw SideloomError.message("Enter a GitHub repository as owner/repository or its HTTPS repository URL.")
            }
            return URL(string: "https://api.github.com/repos/\(components[0])/\(components[1])/releases?per_page=20")!
        }
        guard let url = secureURL(input.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw SideloomError.message("Enter an HTTPS source-feed URL without embedded credentials.") }
        return url
    }
    static func parse(_ data: Data, bundleID: String, github: Bool) throws -> [AppUpdateRelease] {
        let object = try JSONSerialization.jsonObject(with: data)
        var releases: [AppUpdateRelease] = []
        if github {
            guard let items = object as? [[String: Any]] else { throw SideloomError.message("GitHub returned an invalid releases document.") }
            for item in items where item["draft"] as? Bool != true && item["prerelease"] as? Bool != true {
                guard let version = item["tag_name"] as? String, !version.isEmpty else { continue }
                for asset in item["assets"] as? [[String: Any]] ?? [] {
                    guard let name = asset["name"] as? String, name.lowercased().hasSuffix(".ipa"),
                          let address = asset["browser_download_url"] as? String, let url = secureURL(address) else { continue }
                    releases.append(.init(version: version, downloadURL: url, notes: item["body"] as? String ?? "", date: item["published_at"] as? String, minOSVersion: nil, maxOSVersion: nil))
                }
            }
        } else {
            guard let root = object as? [String: Any], let apps = root["apps"] as? [[String: Any]] else { throw SideloomError.message("This document is not an AltStore source feed.") }
            guard let app = apps.first(where: { $0["bundleIdentifier"] as? String == bundleID }) else { throw SideloomError.message("The source does not contain this app’s bundle identifier.") }
            let versions = app["versions"] as? [[String: Any]] ?? [app]
            for version in versions {
                guard let label = (version["version"] ?? version["latestVersion"]) as? String, !label.isEmpty,
                      let address = version["downloadURL"] as? String, let url = secureURL(address) else { continue }
                releases.append(.init(version: label, downloadURL: url, notes: version["localizedDescription"] as? String ?? version["versionDescription"] as? String ?? "", date: version["date"] as? String ?? version["versionDate"] as? String, minOSVersion: version["minOSVersion"] as? String, maxOSVersion: version["maxOSVersion"] as? String))
            }
        }
        var seen = Set<String>()
        return releases.filter { seen.insert($0.id).inserted }
    }
}

private final class FeedRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard task.countOfBytesReceived <= 4 * 1024 * 1024,
              let url = request.url, SourceFeedParser.secureURL(url.absoluteString) != nil,
              let host = url.host else { completionHandler(nil); return }
        Task { completionHandler(await NetworkEndpointPolicy.resolvesPublicly(host) ? request : nil) }
    }
}

struct FeedRateLimit: LocalizedError, Sendable {
    let delay: TimeInterval
    var errorDescription: String? { "Source rate limited. Cached results remain available; try later." }
}
struct FeedFetchResponse: Sendable {
    let data: Data
    let notModified: Bool
    let etag: String?
    let lastModified: String?
}
struct SourceFeedClient: Sendable {
    func releases(source: String, github: Bool, bundleID: String) async throws -> [AppUpdateRelease] {
        let response = try await fetch(url: SourceFeedParser.sourceURL(source, github: github))
        return try SourceFeedParser.parse(response.data, bundleID: bundleID, github: github)
    }
    func fetch(url: URL, etag: String? = nil, lastModified: String? = nil) async throws -> FeedFetchResponse {
        guard SourceFeedParser.secureURL(url.absoluteString) != nil, let host = url.host,
              await NetworkEndpointPolicy.resolvesPublicly(host) else { throw SideloomError.message("The source must resolve to a public HTTPS address.") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration, delegate: FeedRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Slip", forHTTPHeaderField: "User-Agent")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw SideloomError.message("Invalid source response.") }
        if http.statusCode == 429 || (http.statusCode == 403 && http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0") {
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(Double.init).map { $0 - Date().timeIntervalSince1970 }
            throw FeedRateLimit(delay: min(3600, max(45, retry ?? reset ?? 60)))
        }
        guard [200, 304].contains(http.statusCode) else { throw SideloomError.message("Source unavailable. Try later.") }
        guard http.url?.host?.lowercased() == host.lowercased() else { throw SideloomError.message("Source changed hosts. Review its new address before subscribing.") }
        guard response.expectedContentLength <= 4 * 1024 * 1024 else { throw SideloomError.message("The source exceeds the 4 MB limit.") }
        var data = Data()
        if http.statusCode != 304 {
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 4 * 1024 * 1024 else { throw SideloomError.message("The source exceeds the 4 MB limit.") }
                data.append(byte)
            }
        }
        return FeedFetchResponse(data: data, notModified: http.statusCode == 304, etag: http.value(forHTTPHeaderField: "ETag"), lastModified: http.value(forHTTPHeaderField: "Last-Modified"))
    }
}
