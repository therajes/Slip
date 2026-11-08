import XCTest
@testable import SideloomNative

final class TrustDiagnosticsTests: XCTestCase {
    func testReportNeverIncludesFreeFormSecrets() {
        let secrets = "password=hunter2 token=secret SMS123456 user@example.com 00008120-ABCDEF /Users/private pairing-record"
        let diagnostic = SlipDiagnostic(code: .verificationPending, phase: secrets, severity: .warning, retryable: false, recovery: .verifyInstallation)
        let report = SupportReport.generate(diagnostics: [diagnostic], appVersion: secrets, osVersion: secrets)
        for secret in ["hunter2", "secret", "123456", "example.com", "00008120", "/Users", "pairing-record"] { XCTAssertFalse(report.contains(secret)) }
        XCTAssertTrue(report.contains("install.verification_pending"))
    }
    func testReportOrderingIsDeterministic() {
        let a = SlipDiagnostic(code: .timeout, phase: nil, severity: .warning, retryable: true, recovery: .retrySafely)
        let b = SlipDiagnostic(code: .encrypted, phase: nil, severity: .error, retryable: false, recovery: .reviewEntitlements)
        XCTAssertEqual(SupportReport.generate(diagnostics: [a,b], appVersion: "2.8.0", osVersion: "26.0"), SupportReport.generate(diagnostics: [b,a], appVersion: "2.8.0", osVersion: "26.0"))
    }
    func testSourceRejectsObviousLocalAndMetadataEndpoints() {
        for host in ["localhost", "127.0.0.1", "169.254.169.254", "10.0.0.1", "172.16.0.1", "192.168.1.1", "[::1]"] { XCTAssertNil(SourceFeedParser.secureURL("https://\(host)/source.json")) }
        XCTAssertNotNil(SourceFeedParser.secureURL("https://developer.example/source.json"))
    }
    func testCompletionRequiresExplicitDeviceVerification() throws {
        func event(_ json: String) throws -> CoreEvent { try JSONDecoder().decode(CoreEvent.self, from: Data(json.utf8)) }
        XCTAssertFalse(try event(#"{"type":"completed"}"#).confirmsInstallation)
        XCTAssertFalse(try event(#"{"type":"completed","verificationStatus":"pending"}"#).confirmsInstallation)
        XCTAssertTrue(try event(#"{"type":"completed","verificationStatus":"verified"}"#).confirmsInstallation)
        XCTAssertFalse(try event(#"{"type":"progress","verificationStatus":"verified"}"#).confirmsInstallation)
    }

    func testFutureDiagnosticCodesRemainReadable() throws {
        let data = Data(#"{"code":"future.failure","phase":"verify","severity":"warning","retryable":true,"recovery":"futureAction"}"#.utf8)
        let diagnostic = try JSONDecoder().decode(SlipDiagnostic.self, from: data)
        XCTAssertEqual(diagnostic.code, .unknown)
        XCTAssertEqual(diagnostic.recovery, .detailedDiagnostics)
    }

}
