import AppKit
import Combine
import Foundation
import XCTest
@testable import SideloomNative

@MainActor
final class ResponsivenessTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "Slip25-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func phone(_ udid: String) -> DeviceInfo {
        DeviceInfo(name: udid, id: udid == "A" ? 1 : 2, udid: udid, connectionType: "USB", version: "27.2", productType: nil, deviceColor: nil)
    }

    private func fixtureCore(_ root: URL) throws -> CoreClient {
        let path = root.appending(path: "fixture-core")
        let program = #"""
        #!/usr/bin/env python3
        import sys,json,time,pathlib,fcntl
        root=pathlib.Path(__file__).parent
        if sys.argv[1]=='devices':
            source=root/'devices.json'
            if not source.exists(): print('{"type":"error","message":"Fixture offline"}');sys.exit(1)
            print(json.dumps({'type':'completed','devices':json.loads(source.read_text())}));sys.exit(0)
        if sys.argv[1]=='uninstall':
            (root/'uninstall-was-called').touch();sys.exit(99)
        device=json.loads(sys.stdin.readline())
        identifier=device['udid']
        with open(root/('counter-'+identifier),'a+') as count:
            fcntl.flock(count,fcntl.LOCK_EX);count.seek(0)
            number=int(count.read() or 0)+1;count.seek(0);count.truncate();count.write(str(number));count.flush()
        (root/('started-'+identifier+'-'+str(number))).touch()
        if identifier=='A' and number==1: time.sleep(.3)
        if identifier=='error': time.sleep(.2);print('{"type":"error","message":"Old device failed"}');sys.exit(1)
        print(json.dumps({'type':'completed','apps':[{'bundleId':'test.app','name':identifier+'-'+str(number),'version':'1','buildVersion':'1','applicationType':'User'}]}))
        """#
        try Data(program.utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        return CoreClient(executableURL: path)
    }

    private func waitFor(_ path: URL) async throws {
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: path.path) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Fixture request did not start")
    }

    private func entry(_ device: String) -> ManagedInstallation {
        ManagedInstallation(id: device + "|test.app", appName: "Fixture", bundleId: "test.app", account: "fixture@invalid.local",
            deviceUDID: device, deviceName: device,
            options: IpaInstallOptions(appPath: "/fixture.ipa", displayName: nil, bundleId: nil, removedExtensions: [], customIconPath: nil, increasedMemoryLimit: false),
            installedAt: Date(timeIntervalSince1970: 1_700_000_000), expiresAt: Date(timeIntervalSince1970: 1_700_604_800),
            nextRefreshAt: Date(timeIntervalSince1970: 1_700_518_400), enabled: true, status: "Scheduled")
    }

    private func workspace(_ id: UUID = UUID()) -> SavedAppWorkspace {
        let info = IpaInfo(path: "/fixture.ipa", fileName: "Fixture.ipa", appName: "Fixture", bundleId: "test.app", version: "1",
            buildVersion: "1", minimumOsVersion: "26.0", executable: "Fixture", encryptionStatus: "Decrypted", sizeBytes: 10,
            extensions: [], appIdCost: 1, warnings: [])
        return SavedAppWorkspace(id: id, ipa: info, options: entry("A").options, account: "fixture@invalid.local", deviceUDID: "A", keepRefreshed: true)
    }

    func testLateInventoryCannotReplaceNewDevicesApps() async throws {
        let root = try directory(), model = AppModel(startupTasks: false, core: try fixtureCore(root), loadSavedState: false)
        model.selectedDevice = phone("A")
        let slow = Task { await model.loadInstalledApps() }
        try await waitFor(root.appending(path: "started-A-1"))
        model.selectedDevice = phone("B")
        await model.loadInstalledApps()
        await slow.value
        XCTAssertEqual(model.installedApps.first?.name, "B-1")
        XCTAssertEqual(model.installedAppsDeviceUDID, "B")
        XCTAssertFalse(model.isLoadingInstalledApps)
    }

    func testSwitchingAwayAndBackStillRejectsOldResult() async throws {
        let root = try directory(), model = AppModel(startupTasks: false, core: try fixtureCore(root), loadSavedState: false)
        model.selectedDevice = phone("A")
        let slow = Task { await model.loadInstalledApps() }
        try await waitFor(root.appending(path: "started-A-1"))
        model.selectedDevice = phone("B"); model.selectedDevice = phone("A")
        await model.loadInstalledApps(); await slow.value
        XCTAssertEqual(model.installedApps.first?.name, "A-2")
    }

    func testLateFailureCannotClearNewInventoryOrShowAnOldError() async throws {
        let root = try directory(), model = AppModel(startupTasks: false, core: try fixtureCore(root), loadSavedState: false)
        model.selectedDevice = phone("error")
        let slow = Task { await model.loadInstalledApps() }
        try await waitFor(root.appending(path: "started-error-1"))
        model.selectedDevice = phone("B")
        await model.loadInstalledApps(); await slow.value
        XCTAssertEqual(model.installedApps.first?.name, "B-1")
        XCTAssertNil(model.errorMessage)
    }

    func testUninstallConfirmationForAnotherDeviceNeverReachesCore() async throws {
        let root = try directory(), model = AppModel(startupTasks: false, core: try fixtureCore(root), loadSavedState: false)
        model.selectedDevice = phone("B"); await model.loadInstalledApps()
        let removed = await model.uninstallApps(bundleIDs: ["test.app"], expectedDeviceUDID: "A")
        XCTAssertTrue(removed.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "uninstall-was-called").path))
    }

    func testRenewalSelectionAndRemovalOnlyAffectExactDevice() throws {
        let root = try directory(), model = AppModel(startupTasks: false, loadSavedState: false)
        let a = entry("A"), b = entry("B")
        model.managedInstallations = [a, b]
        XCTAssertEqual(model.managedRecipeIDs(for: ["test.app"], deviceUDID: "A"), [a.id])
        XCTAssertTrue(model.managedRecipeIDs(for: ["test.app"], deviceUDID: nil).isEmpty)
        let repository = ManagedInstallationsRepository(fileURL: root.appending(path: "schedule.json"))
        try repository.update { $0 = [a, b] }
        XCTAssertEqual(try repository.remove(bundleIDs: ["test.app"], deviceUDID: "A"), 1)
        XCTAssertEqual(try repository.load(), [b]) // Includes the original account and exact renewal timestamps.
    }

    func testQuietDiscoveryPreservesStateOnFailureAndRestoresRememberedPhone() async throws {
        let root = try directory(), model = AppModel(startupTasks: false, core: try fixtureCore(root), loadSavedState: false)
        let a = phone("A")
        model.devices = [a]; model.selectedDevice = a
        await model.refreshDevices(quiet: true)
        XCTAssertEqual(model.selectedDevice, a); XCTAssertEqual(model.devices, [a]); XCTAssertNil(model.errorMessage)
        try JSONEncoder().encode([DeviceInfo]()).write(to: root.appending(path: "devices.json"))
        await model.refreshDevices(quiet: true)
        XCTAssertNil(model.selectedDevice); XCTAssertEqual(model.desiredWorkspaceDeviceUDID, "A")
        try JSONEncoder().encode([phone("B"), a]).write(to: root.appending(path: "devices.json"))
        await model.refreshDevices(quiet: true)
        XCTAssertEqual(model.selectedDevice, a)
    }

    func testUnchangedDiscoveryDoesNotRepublishDeviceOrInventory() async throws {
        let root = try directory(), model = AppModel(startupTasks: false, core: try fixtureCore(root), loadSavedState: false)
        let a = phone("A"); model.devices = [a]; model.selectedDevice = a
        await model.loadInstalledApps()
        try JSONEncoder().encode([a]).write(to: root.appending(path: "devices.json"))
        var selectionChanges = 0, inventoryChanges = 0
        let selection = model.$selectedDevice.dropFirst().sink { _ in selectionChanges += 1 }
        let inventory = model.$installedApps.dropFirst().sink { _ in inventoryChanges += 1 }
        await model.refreshDevices(quiet: true)
        XCTAssertEqual(selectionChanges, 0); XCTAssertEqual(inventoryChanges, 0)
        withExtendedLifetime([selection, inventory]) {}
    }

    func testProgressUpdatesDoNotInvalidateWholeWorkspaceOrSaveLibrary() async throws {
        let root = try directory(), repository = AppLibraryRepository(fileURL: root.appending(path: "library.json"))
        let saved = workspace()
        let baseline = AppLibraryState(apps: [saved], activeID: saved.id)
        try repository.save(baseline)
        let before = try Data(contentsOf: repository.fileURL)
        let model = AppModel(startupTasks: false, loadSavedState: false, libraryRepository: repository)
        var wholeModelChanges = 0
        let token = model.objectWillChange.sink { wholeModelChanges += 1 }
        for index in 1...1_000 {
            model.currentStage = "Phase \(index)"; model.overallProgress = Double(index) / 1000
            model.downloadProgress = IPADownloadProgress(received: Int64(index), expected: 1000)
        }
        try await Task.sleep(for: .milliseconds(450))
        await model.flushLibraryPersistence()
        XCTAssertEqual(wholeModelChanges, 0)
        XCTAssertEqual(try Data(contentsOf: repository.fileURL), before)
        withExtendedLifetime(token) {}
    }

    func testRapidEditsCoalesceAndImmediateFlushKeepsLatestChoices() async throws {
        let root = try directory(), repository = AppLibraryRepository(fileURL: root.appending(path: "library.json"))
        let model = AppModel(startupTasks: false, loadSavedState: false, libraryRepository: repository)
        let saved = workspace(); model.ipa = saved.ipa; model.activeLibraryID = saved.id
        for index in 0..<100 { model.customName = "Edited \(index)" }
        await model.flushLibraryPersistence()
        XCTAssertEqual(try repository.load().apps.first?.options.displayName, "Edited 99")
        let writer = try XCTUnwrap(model.libraryDiskWriter)
        let writes = await writer.writeCount
        XCTAssertEqual(writes, 1)
        model.customName = "Last keystroke"
        await model.flushLibraryPersistence()
        XCTAssertEqual(try repository.load().apps.first?.options.displayName, "Last keystroke")
    }

    func testOlderDiskRevisionCannotOverwriteNewerState() async throws {
        let root = try directory(), repository = AppLibraryRepository(fileURL: root.appending(path: "library.json"))
        let initial = AppLibraryState()
        let writer = LibraryDiskWriter(repository: repository, initialState: initial)
        let newest = AppLibraryState(apps: [workspace()])
        try await writer.save(newest, revision: 2)
        let written = try await writer.save(initial, revision: 1)
        XCTAssertFalse(written); XCTAssertEqual(try repository.load(), newest)
    }

    func testNoOpSavePreservesExisting24BytesAndCorruptFileIsNotOverwritten() async throws {
        let root = try directory(), repository = AppLibraryRepository(fileURL: root.appending(path: "library.json"))
        let initial = AppLibraryState(apps: [workspace()])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted]
        let original = try encoder.encode(initial); try original.write(to: repository.fileURL)
        let writer = LibraryDiskWriter(repository: repository, initialState: try repository.load())
        let written = try await writer.save(initial, revision: 1)
        XCTAssertFalse(written); XCTAssertEqual(try Data(contentsOf: repository.fileURL), original)
        let corrupt = Data("damaged externally".utf8); try corrupt.write(to: repository.fileURL)
        do { try await writer.save(AppLibraryState(), revision: 2); XCTFail("Damaged state must remain untouched") }
        catch { XCTAssertEqual(try Data(contentsOf: repository.fileURL), corrupt) }
    }

    func testThumbnailDecodesOnceAndIsDownsampled() async throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 800, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let cache = ThumbnailCache(), encoded = data.base64EncodedString()
        let first = await cache.image(encoded: encoded), second = await cache.image(encoded: encoded)
        XCTAssertNotNil(first); XCTAssertTrue(first === second)
        XCTAssertLessThanOrEqual(first?.size.width ?? 1000, 128)
    }

    func testDeviceEventsCoalesceAndStopCancelsPendingDiscovery() async throws {
        var requests = 0
        let monitor = DeviceConnectionMonitor(observeSystemEvents: false) { requests += 1 }
        for _ in 0..<20 { monitor.requestRefresh() }
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertEqual(requests, 1)
        monitor.requestRefresh(); monitor.stop(); monitor.requestRefresh()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(requests, 1)
    }

    func testPreviewCacheReusesUnchangedIPAAndInvalidatesModifiedSource() async throws {
        let root = try directory(), cache = IPAPreviewCache(directory: root.appending(path: "icons"))
        let source = root.appending(path: "fixture.ipa")
        try Data([1, 2, 3]).write(to: source)
        let original = workspace().ipa
        let info = IpaInfo(path: source.path, fileName: original.fileName, appName: original.appName, bundleId: original.bundleId,
            version: original.version, buildVersion: original.buildVersion, minimumOsVersion: original.minimumOsVersion,
            executable: original.executable, encryptionStatus: original.encryptionStatus, sizeBytes: 3, extensions: [], appIdCost: 1, warnings: [])
        let location = try await cache.location(for: info)
        XCTAssertFalse(location.exists)
        let temporary = root.appending(path: "icon.png"); try Data([4, 5, 6]).write(to: temporary)
        try await cache.store(temporary, at: location.url)
        let reused = try await cache.location(for: info)
        XCTAssertTrue(reused.exists); XCTAssertEqual(reused.url, location.url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: source.path)
        let changed = try await cache.location(for: info)
        XCTAssertFalse(changed.exists); XCTAssertNotEqual(changed.url, location.url)
    }
}
