import Foundation
import XCTest
@testable import SideloomNative

final class RenewalEngineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func item() -> ManagedInstallation {
        var value = ManagedInstallation(id: "fixture", appName: "Fixture", bundleId: "example.fixture", account: "fixture",
            deviceUDID: "target", deviceName: "Fixture iPhone", options: .init(appPath: "/fixture.ipa", displayName: nil,
                bundleId: nil, removedExtensions: [], customIconPath: nil, increasedMemoryLimit: false),
            installedAt: now.addingTimeInterval(-6 * 86400), expiresAt: now.addingTimeInterval(12 * 3600),
            nextRefreshAt: now.addingTimeInterval(-3600), enabled: true, status: "Scheduled")
        value.approvedSourceSHA256 = "approved"; value.reviewedOptionsSHA256 = "options"
        return value
    }
    private func context() -> RenewalContext { .init(now: now, matchingDeviceReachable: true, accountUsable: true, sourceMatches: true) }

    func testEligibleIdentityAndExplicitBlockingReasons() {
        let value = item()
        XCTAssertTrue(RenewalEngine.evaluate(value, context: context()).eligible)
        var conditions = context(); conditions.matchingDeviceReachable = false
        XCTAssertEqual(RenewalEngine.evaluate(value, context: conditions).status, .waitingForDevice)
        conditions = context(); conditions.networkAvailable = false
        XCTAssertEqual(RenewalEngine.evaluate(value, context: conditions).status, .waitingForNetwork)
        conditions = context(); conditions.accountUsable = false
        XCTAssertEqual(RenewalEngine.evaluate(value, context: conditions).status, .requiresAuthentication)
        conditions = context(); conditions.operationConflict = true
        XCTAssertFalse(RenewalEngine.evaluate(value, context: conditions).eligible)
    }
    func testPendingTransferCannotBeForcedOrReapprovedIntoRetry() {
        var value = item(); value.pendingOperationID = "opaque-operation"
        var conditions = context(); conditions.force = true
        XCTAssertEqual(RenewalEngine.evaluate(value, context: conditions).status, .verificationPending)
        XCTAssertFalse(value.isDueForBackgroundRefresh(at: now.addingTimeInterval(30 * 86400)))
    }
    func testAuthenticationAndMissingApprovalNeverLoop() throws {
        var value = item(); value.actionRequired = true; value.reasonCode = "authentication.interaction_required"
        XCTAssertEqual(RenewalEngine.evaluate(value, context: context()).status, .requiresAuthentication)
        XCTAssertFalse(value.isDueForBackgroundRefresh(at: now.addingTimeInterval(86400)))
        value = item(); value.approvedSourceSHA256 = nil
        XCTAssertEqual(RenewalEngine.evaluate(value, context: context()).status, .reviewRequired)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
        for key in ["approvedSourceSHA256", "reviewedOptionsSHA256", "pendingOperationID", "lastVerifiedAt", "retryCount", "actionRequired"] { legacy.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(ManagedInstallation.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.approvedSourceSHA256)
        XCTAssertEqual(RenewalEngine.status(for: decoded, at: now), .reviewRequired)
    }
    func testBatteryPreferenceDoesNotDelayUrgentRenewal() {
        var conditions = context(); conditions.onBattery = true
        XCTAssertTrue(RenewalEngine.evaluate(item(), context: conditions).eligible)
        var later = item(); later.expiresAt = now.addingTimeInterval(3 * 86400)
        XCTAssertEqual(RenewalEngine.evaluate(later, context: conditions).reason, "power.prefers_ac")
    }
    func testBackoffJitterAndServerLowerBoundAreDeterministic() {
        let early = RenewalEngine.retryDate(now: now, attempt: 1, jitter: 0)
        let late = RenewalEngine.retryDate(now: now, attempt: 1, jitter: 1)
        XCTAssertEqual(early.timeIntervalSince(now), 900)
        XCTAssertEqual(late.timeIntervalSince(now), 1080)
        XCTAssertEqual(RenewalEngine.retryDate(now: now, attempt: 100, jitter: 0, retryAfter: 48 * 3600).timeIntervalSince(now), 48 * 3600)
        var value = item(); value.nextEligibleAt = now.addingTimeInterval(900)
        XCTAssertFalse(value.isDueForBackgroundRefresh(at: now))
        XCTAssertTrue(value.isDueForBackgroundRefresh(at: now.addingTimeInterval(901)))
    }
    func testExpiredEvidenceAndPausedPolicyStayDistinct() {
        var value = item(); value.expiresAt = now.addingTimeInterval(-1); value.profileExpiryConfirmed = true
        XCTAssertEqual(RenewalEngine.status(for: value, at: now), .expired)
        XCTAssertFalse(value.expiryIsEstimated)
        value.enabled = false
        XCTAssertEqual(RenewalEngine.status(for: value, at: now), .paused)
        XCTAssertFalse(RenewalEngine.evaluate(value, context: context()).eligible)
    }
}
