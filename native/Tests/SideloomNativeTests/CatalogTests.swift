import XCTest
@testable import SideloomNative

final class CatalogTests: XCTestCase {
    private func source() -> CatalogSource { CatalogSource(address: "https://example.com/source.json", github: false, name: "New", publisher: "Unknown") }
    func testPublisherNamespacesDoNotMergeBundleIdentities() throws {
        let data = Data(#"{"name":"Developer","apps":[{"name":"App","bundleIdentifier":"dev.app","developerName":"Publisher","versions":[{"version":"1","downloadURL":"https://downloads.example/app.ipa"}]}]}"#.utf8)
        let a = try CatalogParser.parse(data, source: source())
        let b = try CatalogParser.parse(data, source: source())
        XCTAssertNotEqual(a.apps[0].id, b.apps[0].id)
        XCTAssertEqual(a.apps[0].domains, ["downloads.example"])
        XCTAssertEqual(a.apps[0].publisher, "Publisher")
        XCTAssertTrue(a.isStale)
    }
    func testDuplicateIdentifiersAndMissingSourceNamesFailClosed() {
        for json in [#"{"apps":[]}"#, #"{"name":"Developer","apps":[{"name":"A","bundleIdentifier":"dev.app"},{"name":"B","bundleIdentifier":"dev.app"}]}"#, #"{"name":"Developer","apps":[{"name":"A","bundleIdentifier":"../../escape"}]}"#] {
            XCTAssertThrowsError(try CatalogParser.parse(Data(json.utf8), source: source()))
        }
    }
    func testGitHubAssetsStayExplicitChoices() throws {
        var source = source()
        source = CatalogSource(address: "https://api.github.com/repos/a/b/releases?per_page=20", github: true, name: "a/b", publisher: "a")
        let data = Data(#"[{"tag_name":"v1","assets":[{"name":"a.ipa","browser_download_url":"https://github.com/a.ipa"},{"name":"b.ipa","browser_download_url":"https://github.com/b.ipa"}]}]"#.utf8)
        let result = try CatalogParser.parse(data, source: source)
        XCTAssertNil(result.apps[0].bundleID)
        XCTAssertEqual(result.apps[0].releases.count, 2)
    }
    func testNoSubscriptionWithoutApprovalOrExistingStateMutation() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogRepository(fileURL: dir.appendingPathComponent("catalog.json"))
        do { _ = try await store.add(address: "https://example.com/source.json", github: false, approved: false); XCTFail("Consent required") }
        catch { }
        let sources = try await store.load()
        XCTAssertTrue(sources.isEmpty)
    }
    func testFailedFetchStateIsStaleEvenWithRecentTimestamp() {
        var source = source(); source.fetchedAt = Date(); XCTAssertFalse(source.isStale)
        source.lastError = "Offline"; XCTAssertTrue(source.isStale)
    }
}
