import Foundation
import XCTest
@testable import SideloomNative

@MainActor
final class ReliabilityTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "SlipReliability-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func entry(_ path: String = "/fixture.ipa", id: String = "fixture") -> ManagedInstallation {
        ManagedInstallation(id: id, appName: "Fixture", bundleId: "test.fixture", account: "fixture@invalid.local",
                            deviceUDID: "fixture-device", deviceName: "Fixture iPhone",
                            options: IpaInstallOptions(appPath: path, displayName: nil, bundleId: nil,
                                                      removedExtensions: [], customIconPath: nil, increasedMemoryLimit: false),
                            installedAt: Date(), expiresAt: Date().addingTimeInterval(86400), nextRefreshAt: Date(),
                            enabled: true, status: "Scheduled")
    }

    private func ipa(_ path: String = "/fixture.ipa") -> IpaInfo {
        IpaInfo(path: path, fileName: "Fixture.ipa", appName: "Fixture", bundleId: "test.fixture", version: "1",
                buildVersion: "1", minimumOsVersion: "26.0", executable: "Fixture", encryptionStatus: "Decrypted",
                sizeBytes: 1024, extensions: [], appIdCost: 1, warnings: [])
    }

    func testOperationLeaseRejectsSameProcessReentryAndAnotherStore() throws {
        let path = try directory().appending(path: "operation.json")
        let a = OperationLeaseStore(fileURL: path), b = OperationLeaseStore(fileURL: path)
        let first = try XCTUnwrap(a.begin(type: .install, appName: "First", bundleId: nil))
        XCTAssertNil(a.begin(type: .refresh, appName: "Second", bundleId: nil))
        XCTAssertNil(b.begin(type: .refresh, appName: "Second", bundleId: nil))
        XCTAssertEqual(b.current()?.appName, "First")
        first.end()
        let second = try XCTUnwrap(b.begin(type: .refresh, appName: "Second", bundleId: nil))
        first.end() // Ending an old lease twice cannot clear the new operation.
        XCTAssertEqual(a.current()?.appName, "Second")
        second.end()
        XCTAssertNil(a.current())
    }

    func testActiveLeaseDoesNotExpireAfterTwentyMinutes() throws {
        let path = try directory().appending(path: "operation.json")
        let store = OperationLeaseStore(fileURL: path)
        let handle = try XCTUnwrap(store.begin(type: .install, appName: "Large IPA", bundleId: nil))
        var metadata = handle.operation
        metadata.startedAt = Date().addingTimeInterval(-7200)
        try JSONEncoder().encode(metadata).write(to: path, options: .atomic)
        XCTAssertEqual(store.current()?.appName, "Large IPA")
        XCTAssertNil(store.begin(type: .refresh, appName: "Cannot overlap", bundleId: nil))
        handle.end()
        XCTAssertNil(store.current())
    }

    func testCrossProcessLeaseIsReleasedWhenOwnerExits() async throws {
        let root = try directory(), metadata = root.appending(path: "operation.json")
        let ready = root.appending(path: "ready")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        child.arguments = ["python3", "-c", "import fcntl,sys,time,pathlib; f=open(sys.argv[1],'a'); fcntl.flock(f,fcntl.LOCK_EX); pathlib.Path(sys.argv[2]).touch(); time.sleep(30)", metadata.appendingPathExtension("lock").path, ready.path]
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: ready.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        let store = OperationLeaseStore(fileURL: metadata)
        XCTAssertNil(store.begin(type: .install, appName: "Blocked", bundleId: nil))
        child.terminate(); child.waitUntilExit()
        let lease = try XCTUnwrap(store.begin(type: .install, appName: "Recovered", bundleId: nil))
        lease.end()
    }

    func testWorkerMergePreservesPauseAndDoesNotResurrectDeletedSchedule() throws {
        let repo = ManagedInstallationsRepository(fileURL: try directory().appending(path: "entries.json"))
        let original = entry()
        try repo.update { $0 = [original] }
        var refreshed = original
        refreshed.expiresAt = original.expiresAt.addingTimeInterval(86400)
        refreshed.status = "Scheduled"
        try repo.update { $0[0].enabled = false; $0[0].status = "Paused" }
        try repo.mergeOutcome(refreshed, original: original)
        XCTAssertEqual(try repo.load().first?.enabled, false)
        XCTAssertEqual(try repo.load().first?.status, "Paused")
        XCTAssertEqual(try repo.load().first?.expiresAt, refreshed.expiresAt)
        try repo.update { $0.removeAll() }
        try repo.mergeOutcome(refreshed, original: original)
        XCTAssertTrue(try repo.load().isEmpty)
    }

    func testWorkerOutcomeCannotOverwriteAReplacementRecipe() throws {
        let repo = ManagedInstallationsRepository(fileURL: try directory().appending(path: "entries.json"))
        let original = entry(), replacement = entry("/new-version.ipa")
        try repo.update { $0 = [replacement] }
        var failed = original; failed.status = "Needs attention"
        try repo.mergeOutcome(failed, original: original)
        XCTAssertEqual(try repo.load().first?.ipaPath, "/new-version.ipa")
        XCTAssertEqual(try repo.load().first?.status, "Scheduled")
    }

    func testMalformedScheduleIsPreservedInsteadOfOverwritten() throws {
        let path = try directory().appending(path: "entries.json")
        let data = Data("corrupted fixture".utf8)
        try data.write(to: path)
        let repo = ManagedInstallationsRepository(fileURL: path)
        XCTAssertThrowsError(try repo.update { $0 = [entry()] })
        XCTAssertEqual(try Data(contentsOf: path), data)
    }

    func testAttentionStopsUnattendedAuthenticationLoopsButTransientFailureCanRetry() {
        let now = Date()
        var item = entry()
        item.nextRefreshAt = now.addingTimeInterval(-3600)
        XCTAssertTrue(item.isDueForBackgroundRefresh(at: now))
        item.status = "Needs attention"
        XCTAssertFalse(item.isDueForBackgroundRefresh(at: now.addingTimeInterval(86400)))
        item.status = "Waiting to retry"
        item.nextRefreshAt = now.addingTimeInterval(1800)
        XCTAssertFalse(item.isDueForBackgroundRefresh(at: now))
        XCTAssertTrue(item.isDueForBackgroundRefresh(at: now.addingTimeInterval(1801)))
        item.enabled = false
        XCTAssertFalse(item.isDueForBackgroundRefresh(at: now.addingTimeInterval(86400)))
    }

    func testRefreshStatusNamesTheActiveAppInsteadOfAnArbitraryQueuedApp() {
        let model = AppModel(startupTasks: false, loadSavedState: false)
        var first = entry(id: "first"), second = entry(id: "second")
        first.appName = "Queued app"; second.appName = "Active app"
        model.managedInstallations = [first, second]
        model.refreshingManagedIDs = [first.id, second.id]
        model.activeRefreshID = second.id
        XCTAssertEqual(model.currentlyRefreshingAppName, "Active app")
        model.activeRefreshID = nil
        XCTAssertEqual(model.currentlyRefreshingAppName, "Queued app")
    }

    func testExpiryBoundariesAndFiniteCustomizationValues() {
        let now = Date()
        XCTAssertEqual(RenewalHealth.assess(expiration: now, now: now), .expired)
        XCTAssertEqual(RenewalHealth.assess(expiration: now.addingTimeInterval(3600), now: now), .urgent)
        XCTAssertEqual(RenewalHealth.assess(expiration: now.addingTimeInterval(36 * 3600), now: now), .soon)
        XCTAssertEqual(RenewalHealth.assess(expiration: now.addingTimeInterval(72 * 3600), now: now), .healthy)
        let model = AppModel(startupTasks: false, loadSavedState: false)
        model.ipa = ipa()
        for version in ["²", "٢٧.٠", "999999999999999999999999999", "1..2"] {
            model.minimumOSVersion = version
            XCTAssertTrue(model.customizationIssues.contains { $0.id == "minimum-ios" && $0.level == .blocking })
        }
        model.minimumOSVersion = "27.2"
        for value in ["nan", "inf", "-infinity"] {
            model.plistOverrides = [PlistOverride(key: "FixtureReal", valueType: "Real", value: value)]
            XCTAssertTrue(model.customizationIssues.contains { $0.title.contains("Invalid real") })
        }
    }

    private func fakeCore(in root: URL) throws -> CoreClient {
        let script = root.appending(path: "core-fixture")
        let program = #"""
        #!/usr/bin/env python3
        import sys,json,time,os
        if sys.argv[1]=='icon':
            print(json.dumps({'type':'completed'})); sys.exit(0)
        if sys.argv[1]=='install':
            json.loads(sys.stdin.readline())
            print(json.dumps({'type':'twoFactorRequired','details':{'unknown':False}}),flush=True)
            answer=sys.stdin.readline()
            print(json.dumps({'type':'error','message':'Fixture finished after verification response'}),flush=True)
            sys.exit(1)
        path=sys.argv[2]
        if 'bad' in os.path.basename(path):
            print(json.dumps({'type':'error','message':'Invalid archive fixture'}));sys.exit(1)
        if 'slow' in path: time.sleep(.25)
        print(json.dumps({'type':'completed','ipa':{'path':path,'fileName':os.path.basename(path),'appName':os.path.basename(path),'bundleId':'test.fixture','version':'1','buildVersion':'1','minimumOsVersion':'26.0','executable':'Fixture','encryptionStatus':'Decrypted','sizeBytes':1024,'extensions':[],'appIdCost':1,'warnings':[]}}))
        """#
        try Data(program.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return CoreClient(executableURL: script)
    }

    func testFailedImportPreservesCurrentIPAIconAndCustomizations() async throws {
        let root = try directory()
        let model = AppModel(startupTasks: false, core: try fakeCore(in: root), loadSavedState: false)
        let previous = ipa()
        let icon = root.appending(path: "original.png")
        try Data([1, 2, 3]).write(to: icon)
        model.ipa = previous; model.ipaIconURL = icon
        model.customName = "My edited app"; model.customBundleID = "custom.fixture"
        model.enableFileSharing = true
        let loaded = await model.loadIPA(root.appending(path: "bad.ipa"))
        XCTAssertFalse(loaded)
        XCTAssertEqual(model.ipa, previous)
        XCTAssertEqual(model.customName, "My edited app")
        XCTAssertEqual(model.customBundleID, "custom.fixture")
        XCTAssertTrue(model.enableFileSharing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: icon.path))
        XCTAssertFalse(model.isInspecting)
    }

    func testLatestInspectionWinsAndIncorrectRecoveryIdentityDoesNotCommit() async throws {
        let root = try directory()
        let model = AppModel(startupTasks: false, core: try fakeCore(in: root), loadSavedState: false)
        let slow = Task { await model.loadIPA(root.appending(path: "slow.ipa")) }
        try await Task.sleep(for: .milliseconds(30))
        _ = await model.loadIPA(root.appending(path: "latest.ipa"))
        _ = await slow.value
        XCTAssertEqual(model.ipa?.appName, "latest.ipa")
        let before = model.ipa
        let recovered = await model.loadIPA(root.appending(path: "wrong.ipa"), expectedBundleID: "another.app")
        XCTAssertFalse(recovered)
        XCTAssertEqual(model.ipa, before)
    }

    func testBackgroundVerificationRemainsAttentionInsteadOfBecomingRetry() async throws {
        let root = try directory()
        let device = DeviceInfo(name: "Fixture", id: 1, udid: "fixture", connectionType: "USB", version: "27.2", productType: nil, deviceColor: nil)
        let request = InstallRequest(email: "fixture@invalid.local", password: "synthetic", anisetteServer: "https://invalid.local",
                                     storagePath: root.path, device: device, options: entry().options)
        let outcome = try await AutoRefreshWorker.performInstall(request, core: try fakeCore(in: root))
        guard case .attention(let message) = outcome else { return XCTFail("A verification prompt must remain actionable.") }
        XCTAssertTrue(message.contains("verification code"))
    }

    func testForegroundRenewalFlowKeepsVerificationInteractive() async throws {
        let root = try directory()
        let model = AppModel(startupTasks: false, core: try fakeCore(in: root), loadSavedState: false)
        let device = DeviceInfo(name: "Fixture", id: 1, udid: "fixture", connectionType: "USB", version: "27.2", productType: nil, deviceColor: nil)
        let request = InstallRequest(email: "fixture@invalid.local", password: "synthetic", anisetteServer: "https://invalid.local",
                                     storagePath: root.path, device: device, options: entry().options)
        model.isInstalling = true
        let flow = Task { await model.consumeInstall(request, ipa: ipa()) }
        for _ in 0..<200 {
            if model.showTwoFactor { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard model.showTwoFactor else {
            model.cancelInstall()
            await flow.value
            return XCTFail("Foreground renewal must present Apple's verification challenge.")
        }
        XCTAssertTrue(model.canRespondToTwoFactor)
        model.submitTwoFactor("123456")
        await flow.value
        XCTAssertFalse(model.isInstalling)
        XCTAssertFalse(model.showTwoFactor)
        XCTAssertNotNil(model.errorMessage)
    }
}
