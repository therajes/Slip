import Foundation

struct CatalogApp: Codable, Hashable, Identifiable, Sendable {
    let sourceID: UUID
    let bundleID: String?
    let name: String
    let publisher: String
    let summary: String
    let iconURL: URL?
    let screenshots: [URL]
    let releases: [AppUpdateRelease]
    var id: String { sourceID.uuidString + ":" + (bundleID ?? name) }
    var domains: [String] { Set(releases.compactMap { $0.downloadURL.host }).sorted() }
}
struct CatalogSource: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    let address: String
    let github: Bool
    var name: String
    var publisher: String
    var apps: [CatalogApp] = []
    var fetchedAt: Date?
    var etag: String?
    var lastModified: String?
    var lastError: String?
    var nextAllowedFetch: Date?
    var githubPage: Int?
    var githubHasMore: Bool?
    var isStale: Bool { lastError != nil || fetchedAt.map { Date().timeIntervalSince($0) > 86400 } ?? true }
}
enum CatalogParser {
    static func parse(_ data: Data, source: CatalogSource) throws -> CatalogSource {
        guard data.count <= 4 * 1024 * 1024 else { throw SideloomError.message("Source exceeds the 4 MB feed limit.") }
        var result = source
        if source.github {
            let releases = try SourceFeedParser.parse(data, bundleID: "", github: true)
            result.githubPage = 1
            result.githubHasMore = (try JSONSerialization.jsonObject(with: data) as? [Any])?.count == 20
            result.apps = [.init(sourceID: source.id, bundleID: nil, name: source.name, publisher: source.publisher,
                                 summary: "GitHub repository releases. Bundle identity is unknown until IPA inspection.", iconURL: nil, screenshots: [], releases: releases)]
        } else {
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = root["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let apps = root["apps"] as? [[String: Any]], apps.count <= 5000 else {
                throw SideloomError.message("A source must declare its name and at most 5,000 applications.")
            }
            result.name = String(name.prefix(256))
            result.publisher = String((root["subtitle"] as? String ?? root["name"] as? String ?? "Undeclared publisher").prefix(256))
            var identifiers = Set<String>()
            result.apps = try apps.map { app in
                guard let bundle = app["bundleIdentifier"] as? String, !bundle.isEmpty, bundle.count <= 255,
                      bundle.split(separator: ".").count >= 2, bundle.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-".contains($0)) }),
                      identifiers.insert(bundle).inserted, let title = app["name"] as? String, !title.isEmpty else {
                    throw SideloomError.message("Source has missing, invalid or duplicate application identifiers.")
                }
                let appDocument = try JSONSerialization.data(withJSONObject: ["apps": [app]])
                let releases = try SourceFeedParser.parse(appDocument, bundleID: bundle, github: false)
                let screenshots = (app["screenshotURLs"] as? [String] ?? []).prefix(12).compactMap(SourceFeedParser.secureURL)
                return CatalogApp(sourceID: source.id, bundleID: bundle, name: String(title.prefix(256)),
                    publisher: String((app["developerName"] as? String ?? result.publisher).prefix(256)),
                    summary: String((app["localizedDescription"] as? String ?? "").prefix(16384)),
                    iconURL: (app["iconURL"] as? String).flatMap(SourceFeedParser.secureURL), screenshots: screenshots, releases: releases)
            }
        }
        result.lastError = nil
        return result
    }
}

actor CatalogRepository {
    static let shared = CatalogRepository(fileURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "app.sideloom.native/Library/catalog-v1.json"))
    let fileURL: URL
    init(fileURL: URL) { self.fileURL = fileURL }
    func load() throws -> [CatalogSource] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        guard data.count <= 32 * 1024 * 1024 else { throw SideloomError.message("Catalog cache exceeds 32 MB.") }
        return try JSONDecoder().decode([CatalogSource].self, from: data)
    }
    private func save(_ sources: [CatalogSource]) throws {
        let data = try JSONEncoder().encode(sources)
        guard sources.count <= 32, data.count <= 32 * 1024 * 1024 else { throw SideloomError.message("Catalog storage limit reached (32 sources / 32 MB). Remove a source first.") }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
    func add(address: String, github: Bool, approved: Bool) async throws -> CatalogSource {
        guard approved else { throw SideloomError.message("Approve the source subscription first.") }
        let url = try SourceFeedParser.sourceURL(address, github: github)
        var sources = try load()
        guard !sources.contains(where: { $0.address == url.absoluteString }) else { throw SideloomError.message("This source is already subscribed.") }
        let source = CatalogSource(address: url.absoluteString, github: github, name: github ? address : "New source", publisher: github ? address : "Unverified publisher")
        let response = try await SourceFeedClient().fetch(url: url)
        var parsed = try CatalogParser.parse(response.data, source: source)
        parsed.fetchedAt = Date(); parsed.etag = response.etag; parsed.lastModified = response.lastModified
        try Task.checkCancellation()
        sources = try load()
        guard !sources.contains(where: { $0.address == url.absoluteString }) else { throw SideloomError.message("This source is already subscribed.") }
        sources.append(parsed); try save(sources)
        return parsed
    }
    static func nextGitHubPageURL(_ source: CatalogSource) -> URL? {
        let next = (source.githubPage ?? 1) + 1
        guard source.github, source.githubHasMore != false, next <= 10,
              var parts = URLComponents(string: source.address), parts.host == "api.github.com",
              parts.path.hasPrefix("/repos/"), parts.path.hasSuffix("/releases") else { return nil }
        parts.queryItems = [URLQueryItem(name: "per_page", value: "20"), URLQueryItem(name: "page", value: String(next))]
        return parts.url
    }
    func loadMore(_ id: UUID) async throws {
        guard var source = try load().first(where: { $0.id == id }), let url = Self.nextGitHubPageURL(source) else { return }
        guard source.nextAllowedFetch.map({ $0 <= Date() }) ?? true else { throw SideloomError.message("Source rate-limit cooldown is active.") }
        let response: FeedFetchResponse
        do { response = try await SourceFeedClient().fetch(url: url) }
        catch let rate as FeedRateLimit {
            var all = try load()
            if let index = all.firstIndex(where: { $0.id == id }) {
                all[index].lastError = rate.localizedDescription
                all[index].nextAllowedFetch = Date().addingTimeInterval(rate.delay + Double.random(in: 0...10))
                try save(all)
            }
            throw rate
        }
        try Task.checkCancellation()
        let page = try CatalogParser.parse(response.data, source: source)
        let previous = source.apps.first?.releases ?? []
        var ids = Set(previous.map(\.id))
        let merged = previous + (page.apps.first?.releases ?? []).filter { ids.insert($0.id).inserted }
        source.apps = [.init(sourceID: source.id, bundleID: nil, name: source.name, publisher: source.publisher,
            summary: page.apps.first?.summary ?? "GitHub releases", iconURL: nil, screenshots: [], releases: merged)]
        source.githubPage = (source.githubPage ?? 1) + 1
        source.githubHasMore = page.githubHasMore
        source.lastError = nil
        var all = try load()
        guard let index = all.firstIndex(where: { $0.id == id }), all[index].githubPage == (source.githubPage ?? 2) - 1 || all[index].githubPage == nil else { return }
        all[index] = source
        try save(all)
    }
    func remove(_ id: UUID) throws { try save(load().filter { $0.id != id }) }
    func refresh(_ id: UUID) async throws {
        guard var source = try load().first(where: { $0.id == id }), let url = URL(string: source.address) else { return }
        guard source.nextAllowedFetch.map({ $0 <= Date() }) ?? true else { throw SideloomError.message("This source is cooling down after an unsuccessful request. Try later.") }
        do {
            let response = try await SourceFeedClient().fetch(url: url, etag: source.etag, lastModified: source.lastModified)
            try Task.checkCancellation()
            if !response.notModified { source = try CatalogParser.parse(response.data, source: source) }
            source.fetchedAt = Date(); source.lastError = nil; source.nextAllowedFetch = nil
            source.etag = response.etag ?? source.etag; source.lastModified = response.lastModified ?? source.lastModified
        } catch is CancellationError { throw CancellationError() }
        catch let rate as FeedRateLimit {
            source.lastError = rate.localizedDescription
            source.nextAllowedFetch = Date().addingTimeInterval(rate.delay + Double.random(in: 0...10))
        }
        catch {
            source.lastError = "Source unavailable. Cached results may be stale."
            source.nextAllowedFetch = Date().addingTimeInterval(Double.random(in: 45...90))
        }
        var all = try load()
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index] = source; try save(all)
    }
}
