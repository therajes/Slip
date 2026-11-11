import XCTest
@testable import SideloomNative

final class CompanionPolicyTests: XCTestCase {
    func testQuietHoursWrapMidnightAndCanDisable() {
        XCTAssertTrue(NotificationCoordinator.isQuiet(hour: 23, enabled: true, start: 22, end: 8))
        XCTAssertTrue(NotificationCoordinator.isQuiet(hour: 7, enabled: true, start: 22, end: 8))
        XCTAssertFalse(NotificationCoordinator.isQuiet(hour: 8, enabled: true, start: 22, end: 8))
        XCTAssertFalse(NotificationCoordinator.isQuiet(hour: 23, enabled: false, start: 22, end: 8))
        XCTAssertTrue(NotificationCoordinator.isQuiet(hour: 12, enabled: true, start: 0, end: 0))
    }
    func testNotificationScopeSeparatesTargetAndIssueWithoutLeakingIdentifiers() {
        let first = NotificationCoordinator.deliveryScope(installationID: "private-device|app", reason: "auth")
        XCTAssertEqual(first.count, 64)
        XCTAssertFalse(first.contains("private"))
        XCTAssertNotEqual(first, NotificationCoordinator.deliveryScope(installationID: "another", reason: "auth"))
        XCTAssertNotEqual(first, NotificationCoordinator.deliveryScope(installationID: "private-device|app", reason: "device"))
    }
    @MainActor func testExplicitBackgroundPreferenceWinsOverLegacySchedules() {
        let name = "SlipCompanionTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(CompanionCoordinator.backgroundEnabled(defaults, legacyEnabled: true))
        XCTAssertFalse(CompanionCoordinator.backgroundEnabled(defaults, legacyEnabled: false))
        defaults.set(false, forKey: "backgroundRefreshEnabled")
        XCTAssertFalse(CompanionCoordinator.backgroundEnabled(defaults, legacyEnabled: true))
    }
}
