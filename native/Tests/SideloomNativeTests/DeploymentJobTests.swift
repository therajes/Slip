import Foundation
import XCTest
@testable import SideloomNative

final class DeploymentJobTests: XCTestCase {
    func testStateGraphRequiresReviewAndCannotReplayUnknownTransfer() {
        XCTAssertTrue(DeploymentPhase.needsReview.permits(.ready))
        XCTAssertTrue(DeploymentPhase.ready.permits(.waitingForDevice))
        XCTAssertTrue(DeploymentPhase.waitingForDevice.permits(.signing))
        XCTAssertTrue(DeploymentPhase.transferring.permits(.unknown))
        XCTAssertFalse(DeploymentPhase.unknown.permits(.signing))
        XCTAssertFalse(DeploymentPhase.succeeded.permits(.signing))
        XCTAssertFalse(DeploymentPhase.failed.permits(.ready))
    }
    func testHashChangesWithBytesEvenWhenSizeIsUnchanged() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("first".utf8).write(to: file)
        let first = try DeploymentJob.sourceHash(file.path)
        try Data("other".utf8).write(to: file)
        XCTAssertNotEqual(first, try DeploymentJob.sourceHash(file.path))
    }
    func testIndependentTargetIdentityAndExpiredApproval() throws {
        let now = Date()
        let first = DeploymentJob(operationID: UUID(), sourceSHA256: "hash", optionsSHA256: "options", deviceUDID: "first", account: "reference", teamID: nil, effectiveBundleID: "example.app", createdAt: now, reviewedAt: now, updatedAt: now)
        var second = DeploymentJob(operationID: UUID(), sourceSHA256: "hash", optionsSHA256: "options", deviceUDID: "second", account: "reference", teamID: nil, effectiveBundleID: "example.app", createdAt: now, reviewedAt: now.addingTimeInterval(-86401), updatedAt: now)
        XCTAssertNotEqual(first.operationID, second.operationID)
        XCTAssertNotEqual(first.deviceUDID, second.deviceUDID)
        XCTAssertTrue(second.approvalExpired)
        try second.transition(to: .needsReview)
        XCTAssertEqual(second.phase, .needsReview)
        let decoded = try JSONDecoder().decode(DeploymentJob.self, from: JSONEncoder().encode(second))
        XCTAssertEqual(decoded, second)
    }
    func testLegacyLibraryDecodesWithoutDeploymentFields() throws {
        let state = try JSONDecoder().decode(AppLibraryState.self, from: Data(#"{"version":1,"apps":[],"queue":[]}"#.utf8))
        XCTAssertEqual(state.version, 1)
        XCTAssertTrue(state.queue.isEmpty)
    }
}
