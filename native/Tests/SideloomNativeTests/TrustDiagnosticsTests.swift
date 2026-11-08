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

    func testNotificationPolicyRespectsDenialAndExpiryThrottle() {
        let now = Date(timeIntervalSince1970: 200000)
        XCTAssertFalse(NotificationCoordinator.shouldDeliver(enabled: false, authorized: true, alertsEnabled: true, lastDelivered: nil, now: now, category: .queueCompleted))
        XCTAssertFalse(NotificationCoordinator.shouldDeliver(enabled: true, authorized: false, alertsEnabled: true, lastDelivered: nil, now: now, category: .refreshSuccess))
        XCTAssertFalse(NotificationCoordinator.shouldDeliver(enabled: true, authorized: true, alertsEnabled: false, lastDelivered: nil, now: now, category: .refreshFailed))
        XCTAssertFalse(NotificationCoordinator.shouldDeliver(enabled: true, authorized: true, alertsEnabled: true, lastDelivered: now.addingTimeInterval(-3600), now: now, category: .appExpiring))
        XCTAssertTrue(NotificationCoordinator.shouldDeliver(enabled: true, authorized: true, alertsEnabled: true, lastDelivered: now.addingTimeInterval(-86401), now: now, category: .appExpiring))
    }
    func testDeviceHealthNeverExposesFullIdentity() {
        XCTAssertEqual(DeviceHealthEvidence.maskedIdentity("00008120-ABCDEF123456"), "…3456")
        XCTAssertEqual(DeviceHealthEvidence.maskedIdentity(""), "Unknown")
    }
    @MainActor
    func testDiscoveryRemovalPreservesLastSeenWithUnknownCause() {
        let model = AppModel(startupTasks: false, loadSavedState: false)
        let device = DeviceInfo(name: "Test", id: 1, udid: "private-reference", connectionType: "USB", version: "26.0", productType: nil, deviceColor: nil)
        let seen = Date(timeIntervalSince1970: 100)
        model.updateDeviceHealth(discovered: [device], at: seen)
        model.devices = [device]
        model.updateDeviceHealth(discovered: [], at: seen.addingTimeInterval(30))
        XCTAssertEqual(model.deviceHealth[device.udid]?.lastSeen, seen)
        XCTAssertTrue(model.deviceHealth[device.udid]?.recentConnectionChange?.contains("unknown") == true)
    }

    func testRemovedExtensionEvidenceDoesNotBlockSelectedComponents() {
        let removed = "Payload/Main.app/PlugIns/Widget.appex"
        let check = SigningCheck(id: "binary.architecture", severity: .block, stage: "offline", evidence: "Mach-O", component: removed + "/Widget", observed: nil, expected: nil, resolution: nil, title: nil, explanation: nil)
        XCTAssertFalse(check.applies(removing: [removed]))
        XCTAssertTrue(check.applies(removing: [removed + "Other"]))
        XCTAssertTrue(check.applies(removing: []))
    }

}
