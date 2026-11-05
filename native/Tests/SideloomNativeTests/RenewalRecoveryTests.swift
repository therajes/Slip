import Foundation
import XCTest
@testable import SideloomNative

@MainActor
final class RenewalRecoveryTests: XCTestCase {
    private func entry() -> ManagedInstallation {
        ManagedInstallation(id: "fixture", appName: "Fixture", bundleId: "test.fixture", account: "fixture@invalid.local",
            deviceUDID: "fixture-device", deviceName: "Fixture iPhone",
            options: IpaInstallOptions(appPath: "/fixture.ipa", displayName: nil, bundleId: nil,
                removedExtensions: [], customIconPath: nil, increasedMemoryLimit: false),
            installedAt: Date(), expiresAt: Date().addingTimeInterval(86400), nextRefreshAt: Date(),
            enabled: true, status: "Scheduled")
    }

    func testOldSchedulesDecodeAsEstimatedAndConfirmedDatesRoundTrip() throws {
        var item = entry()
        let old = try JSONEncoder().encode(item)
        XCTAssertTrue(try JSONDecoder().decode(ManagedInstallation.self, from: old).expiryIsEstimated)
        item.profileExpiryConfirmed = true
        let decoded = try JSONDecoder().decode(ManagedInstallation.self, from: JSONEncoder().encode(item))
        XCTAssertFalse(decoded.expiryIsEstimated)
        XCTAssertEqual(decoded.expiresAt, item.expiresAt)
    }

    func testWakeEligibilityDoesNotRepeatInteractiveFailuresOrPausedSchedules() {
        var item = entry()
        XCTAssertTrue(item.isDueForBackgroundRefresh(at: Date().addingTimeInterval(10)))
        item.status = "Needs attention"
        XCTAssertFalse(item.isDueForBackgroundRefresh(at: Date().addingTimeInterval(100000)))
        item.status = "Scheduled"; item.enabled = false
        XCTAssertFalse(item.isDueForBackgroundRefresh(at: Date().addingTimeInterval(100000)))
    }

    func testSupportReportAlwaysRedactsSensitiveValues() {
        let text = "fixture@example.com https://example.com/file?token=secret /Users/fixture/private.ipa\n00008110-00123456789ABCDE token=secret password=hunter2"
        let report = SupportReport.redact(text)
        for secret in ["fixture@example.com", "example.com", "/Users/", "00008110", "secret", "hunter2"] {
            XCTAssertFalse(report.contains(secret), secret)
        }
    }

    func testDiagnosticsDistinguishProviderReachabilityMetadataPairingAndTransfer() {
        XCTAssertEqual(RecoveryDiagnosis.explain("anisette server unreachable").title, "Authentication provider is unreachable")
        XCTAssertEqual(RecoveryDiagnosis.explain("incompatible anisette metadata").title, "Authentication provider needs attention")
        XCTAssertEqual(RecoveryDiagnosis.explain("pairing failure").title, "iPhone pairing needs attention")
        XCTAssertEqual(RecoveryDiagnosis.explain("AFC transfer failure").title, "Device transfer was interrupted")
    }
    func testPlannerScopesReuseToAccountTeamAndKeptExtensions() {
        let model = AppModel(startupTasks: false, loadSavedState: false)
        model.selectedAccount = "fixture@invalid.local"
        model.ipa = IpaInfo(path: "/fixture.ipa", fileName: "fixture.ipa", appName: "Fixture",
            bundleId: "test.fixture", version: "1", buildVersion: "1", minimumOsVersion: "26",
            executable: "Fixture", encryptionStatus: "Decrypted", sizeBytes: 100,
            extensions: [.init(path: "PlugIns/Widget.appex", bundleId: "test.fixture.widget", name: "Widget", extensionPoint: nil)],
            appIdCost: 2, warnings: [])
        model.resourcesLoaded = true
        model.resourcesAccount = model.selectedAccount
        model.resourcesTeamID = "TEAM"
        model.resourcesUpdatedAt = Date()
        model.accountAppIDs = [.init(id: "fixture", name: "Fixture", bundleId: "test.fixture.TEAM")]
        XCTAssertEqual(model.appIDPlan.reusedCount, 1)
        XCTAssertEqual(model.appIDPlan.newCount, 1)
        model.removedExtensions = ["PlugIns/Widget.appex"]
        XCTAssertEqual(model.appIDPlan.newCount, 0)
        model.selectedAccount = "other@invalid.local"
        XCTAssertEqual(model.appIDPlan.reusedCount, 0)
        XCTAssertNil(model.appIDPlan.checkedAt)
    }

}
