import Foundation
import XCTest
@testable import SideloomNative

final class SourceFeedTests: XCTestCase {
    func testSourceMatchesExactBundleAndPreservesDeveloperOrder() throws {
        let data = Data(#"{"apps":[{"bundleIdentifier":"test.app","versions":[{"version":"1.0","downloadURL":"https://example.com/first.ipa","minOSVersion":"17.0","localizedDescription":"Fixes"},{"version":"2.0","downloadURL":"https://example.com/second.ipa"}]}]}"#.utf8)
        let releases = try SourceFeedParser.parse(data, bundleID: "test.app", github: false)
        XCTAssertEqual(releases.map(\.version), ["1.0", "2.0"])
        XCTAssertEqual(releases.first?.notes, "Fixes")
        XCTAssertEqual(releases.first?.compatibility(with: "16.0"), "Requires iOS 17.0 or newer.")
        XCTAssertThrowsError(try SourceFeedParser.parse(data, bundleID: "TEST.app", github: false))
    }
    func testGitHubRetainsMultipleIPAChoicesAndExcludesDrafts() throws {
        let data = Data(#"[{"tag_name":"v2","body":"Notes","assets":[{"name":"a.ipa","browser_download_url":"https://example.com/a.ipa"},{"name":"b.ipa","browser_download_url":"https://example.com/b.ipa"},{"name":"source.zip","browser_download_url":"https://example.com/s.zip"}]},{"draft":true,"tag_name":"v3","assets":[{"name":"c.ipa","browser_download_url":"https://example.com/c.ipa"}]}]"#.utf8)
        let values = try SourceFeedParser.parse(data, bundleID: "test.app", github: true)
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(Set(values.map(\.assetName)), ["a.ipa", "b.ipa"])
    }
    func testLegacyFeedAndUnsafeURLs() throws {
        let data = Data(#"{"apps":[{"bundleIdentifier":"test.app","version":"1.2","downloadURL":"https://example.com/a.ipa","versionDescription":"Legacy"}]}"#.utf8)
        XCTAssertEqual(try SourceFeedParser.parse(data, bundleID: "test.app", github: false).first?.notes, "Legacy")
        XCTAssertNil(SourceFeedParser.secureURL("http://example.com/a.ipa"))
        XCTAssertNil(SourceFeedParser.secureURL("https://user:password@example.com/a.ipa"))
        XCTAssertThrowsError(try SourceFeedParser.parse(Data("{}".utf8), bundleID: "test.app", github: false))
        XCTAssertEqual(try SourceFeedParser.sourceURL("owner/repo", github: true).host, "api.github.com")
        XCTAssertThrowsError(try SourceFeedParser.sourceURL("../repo", github: true))
    }
    func testVersionsAndMissingCompatibilityAreExplicit() {
        XCTAssertEqual(AppUpdateRelease.compare("v1.10", "1.9"), .orderedDescending)
        let release = AppUpdateRelease(version: "1", downloadURL: URL(string: "https://example.com/a.ipa")!, notes: "", date: nil, minOSVersion: nil, maxOSVersion: nil)
        XCTAssertEqual(release.compatibility(with: "27"), "Developer did not provide iOS compatibility.")
    }
    func testDuplicateReleasesAreCollapsedAndOSVersionsNormalizeTrailingZeros() throws {
        let data = Data(#"{"apps":[{"bundleIdentifier":"test.app","versions":[{"version":"1","downloadURL":"https://example.com/a.ipa"},{"version":"1","downloadURL":"https://example.com/a.ipa"}]}]}"#.utf8)
        XCTAssertEqual(try SourceFeedParser.parse(data, bundleID: "test.app", github: false).count, 1)
        XCTAssertEqual(AppUpdateRelease.compare("17", "17.0.0"), .orderedSame)
    }

}
