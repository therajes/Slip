import Foundation
import XCTest
@testable import SideloomNative

private actor DirectoryFixtureTransport: AnisetteDirectoryTransport {
    struct Reply: Sendable {
        var status = 200
        var body = Data()
        var headers: [String: String] = [:]
        var failure: URLError?
    }
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func fetch(_ request: URLRequest, limit: Int) async throws -> AnisetteHTTPResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        let reply = replies.removeFirst()
        if let failure = reply.failure { throw failure }
        return AnisetteHTTPResponse(data: reply.body, response: HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!)
    }
}

@MainActor
final class AnisetteServerDirectoryTests: XCTestCase {
    private let document = Data(#"{"servers":[{"name":"Zebra Mac","address":"https://z.example","kind":2},{"name":"Android","address":"https://android.example","kind":0},{"name":"Windows","address":"https://win.example","kind":1},{"name":"Alpha Mac","address":"https://a.example/","kind":2},{"name":"Future","address":"https://future.example","kind":3}]}"#.utf8)
    private let macMetadata = Data(#"{"client_info":"<MacBookPro18,1> <Mac OS X;15.0> <com.apple.AuthKit>","user_agent":"akd/1"}"#.utf8)

    private func cachePath() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "SlipDirectoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appending(path: "directory.json")
    }

    func testMacFilteringPreservesGitHubOrderAndFirstDuplicate() throws {
        let data = Data(#"{"servers":[{"name":"Z","address":"https://Z.example/","kind":2},{"name":"Mac in name only","address":"https://other.example","kind":0},{"name":"A","address":"https://a.example","kind":2},{"name":"Duplicate","address":"https://z.example","kind":2},{"name":"HTTP","address":"http://plain.example","kind":2},{"name":"Credentials","address":"https://user:secret@private.example","kind":2}]}"#.utf8)
        let entries = try AnisetteServerDirectory.decode(data)
        XCTAssertEqual(entries.map(\.name), ["Z", "A"])
        XCTAssertEqual(entries.map(\.address), ["https://z.example", "https://a.example"])
    }

    func testConditionalRefreshRetainsOrderAndCachedListOnNetworkFailure() async throws {
        let cache = try cachePath()
        let transport = DirectoryFixtureTransport([
            .init(body: document, headers: ["ETag": "\"fixture-v1\""]),
            .init(status: 304),
            .init(failure: URLError(.notConnectedToInternet))
        ])
        let directory = AnisetteServerDirectory(transport: transport, cacheURL: cache)
        await directory.refresh()
        XCTAssertEqual(directory.servers.map(\.name), ["Zebra Mac", "Alpha Mac"])
        let entries = directory.servers
        await directory.refresh()
        XCTAssertEqual(directory.servers, entries)
        XCTAssertFalse(directory.usingCachedList)
        let checked = directory.lastChecked
        await directory.refresh()
        XCTAssertEqual(directory.servers, entries)
        XCTAssertEqual(directory.lastChecked, checked)
        XCTAssertTrue(directory.usingCachedList)
        XCTAssertNotNil(directory.errorMessage)
        let requests = await transport.requests
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "If-None-Match"), "\"fixture-v1\"")
        XCTAssertEqual(requests[0].url, AnisetteServerDirectory.source)
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(requests[0].httpBody)
        let restored = AnisetteServerDirectory(transport: transport, cacheURL: cache)
        XCTAssertEqual(restored.servers, entries)
        XCTAssertTrue(restored.usingCachedList)
    }

    func testMalformedUpdateDoesNotReplaceLastGoodDirectory() async throws {
        let transport = DirectoryFixtureTransport([.init(body: document), .init(body: Data("<html>error</html>".utf8))])
        let directory = AnisetteServerDirectory(transport: transport, cacheURL: nil)
        await directory.refresh()
        let previous = directory.servers
        await directory.refresh()
        XCTAssertEqual(directory.servers, previous)
        XCTAssertTrue(directory.usingCachedList)
        XCTAssertNotNil(directory.errorMessage)
    }

    func testSelectionRevalidatesCurrentMembershipThenChecksMetadata() async throws {
        let transport = DirectoryFixtureTransport([.init(body: document), .init(body: macMetadata)])
        let directory = AnisetteServerDirectory(transport: transport, cacheURL: nil)
        let entry = try await directory.verifiedEntry(for: "https://a.example/")
        XCTAssertEqual(entry.name, "Alpha Mac")
        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.url!.absoluteString }, [AnisetteServerDirectory.source.absoluteString, "https://a.example/v3/client_info"])
        XCTAssertEqual(directory.servers.map(\.name), ["Zebra Mac", "Alpha Mac"])
    }

    func testRemovedServerCannotBeChosenFromAnOlderList() async throws {
        let transport = DirectoryFixtureTransport([.init(body: document), .init(body: Data(#"{"servers":[]}"#.utf8))])
        let directory = AnisetteServerDirectory(transport: transport, cacheURL: nil)
        await directory.refresh()
        do {
            _ = try await directory.verifiedEntry(for: "https://a.example")
            XCTFail("A removed directory entry must not be applied.")
        } catch AnisetteDirectoryError.noLongerListed { }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2, "No server probe should follow failed membership validation.")
    }

    func testOfflineDirectoryCannotBePresentedAsFreshDuringSelection() async throws {
        let transport = DirectoryFixtureTransport([.init(body: document), .init(failure: URLError(.timedOut))])
        let directory = AnisetteServerDirectory(transport: transport, cacheURL: nil)
        await directory.refresh()
        do {
            _ = try await directory.verifiedEntry(for: "https://a.example")
            XCTFail("Cached membership cannot be called current.")
        } catch AnisetteDirectoryError.unconfirmedList { }
        XCTAssertTrue(directory.usingCachedList)
    }

    func testNonMacMetadataAndUnreachableServerCannotPassSelection() async throws {
        for reply in [DirectoryFixtureTransport.Reply(body: Data(#"{"client_info":"<Windows;10>","user_agent":"AppleWin/1"}"#.utf8)),
                      .init(failure: URLError(.cannotConnectToHost))] {
            let directory = AnisetteServerDirectory(transport: DirectoryFixtureTransport([.init(body: document), reply]), cacheURL: nil)
            do {
                _ = try await directory.verifiedEntry(for: "https://a.example")
                XCTFail("A failed check cannot choose a catalog provider.")
            } catch { }
        }
    }

    func testMetadataIsNotAuthenticationAndRequiresBothFields() async throws {
        let transport = DirectoryFixtureTransport([.init(body: Data(#"{"client_info":"<Mac OS X;15>"}"#.utf8))])
        let directory = AnisetteServerDirectory(transport: transport, cacheURL: nil)
        do {
            _ = try await directory.checkConnection(to: "http://127.0.0.1:6969/")
            XCTFail("An incomplete protocol response must not pass.")
        } catch AnisetteDirectoryError.invalidData { }
        let request = await transport.requests.first!
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:6969/v3/client_info")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
    }

    func testEndpointPolicyAndResponseLimits() throws {
        for value in ["http://public.example", "https://user:secret@host.example", "https://host.example?secret=value", "file:///tmp/server", "https://host.example#fragment"] {
            XCTAssertNil(AnisetteEndpoint.url(value), value)
        }
        for value in ["http://localhost:6969", "http://127.0.0.1:6969", "http://[::1]:6969", "https://server.example"] {
            XCTAssertNotNil(AnisetteEndpoint.url(value), value)
        }
        XCTAssertThrowsError(try AnisetteServerDirectory.decode(Data(repeating: 32, count: AnisetteServerDirectory.maximumBytes+1)))
    }
}
