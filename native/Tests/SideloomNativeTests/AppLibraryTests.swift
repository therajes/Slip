import Foundation
import XCTest
@testable import SideloomNative

@MainActor
final class AppLibraryTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "SlipLibraryTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private var device: DeviceInfo {
        DeviceInfo(name: "Fixture iPhone", id: 1, udid: "fixture-device", connectionType: "USB", version: "27.2", productType: nil, deviceColor: nil)
    }

    private func model(_ root: URL) throws -> AppModel {
        let executable = root.appending(path: "core-fixture")
        let program = #"""
        #!/usr/bin/env python3
        import sys,json,os
        command=sys.argv[1]
        if command=='icon': print('{"type":"completed"}');sys.exit(0)
        if command=='devices':
            print(json.dumps({'type':'completed','devices':[{'name':'Fixture iPhone','id':1,'udid':'fixture-device','connectionType':'USB','version':'27.2'}]}));sys.exit(0)
        path=sys.argv[2]
        if not os.path.exists(path) or 'bad' in path:
            print('{"type":"error","message":"Invalid fixture"}');sys.exit(1)
        name=os.path.basename(path).split('.')[0]
        print(json.dumps({'type':'completed','ipa':{'path':path,'fileName':os.path.basename(path),'appName':name,'bundleId':'test.'+name,'version':'1.0','buildVersion':'1','minimumOsVersion':'26.0','executable':'Fixture','encryptionStatus':'Decrypted','sizeBytes':os.path.getsize(path),'extensions':[],'appIdCost':1,'warnings':[]}}))
        """#
        try Data(program.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let model = AppModel(startupTasks: false, core: CoreClient(executableURL: executable), loadSavedState: false,
                             libraryRepository: AppLibraryRepository(fileURL: root.appending(path: "Library/state.json")))
        model.devices = [device]; model.selectedDevice = device
        model.accounts = ["fixture@invalid.local"]; model.selectedAccount = "fixture@invalid.local"
        return model
    }

    private func file(_ root: URL, _ name: String) throws -> URL {
        let url = root.appending(path: name + ".ipa")
        try Data("synthetic archive fixture".utf8).write(to: url)
        return url
    }

    private func readyQueue(_ model: AppModel, _ files: [URL]) async {
        for file in files {
            _ = await model.loadIPA(file)
            model.customName = file.deletingPathExtension().lastPathComponent + " Reviewed"
            model.saveWorkspaceToQueue()
        }
    }

    func testWorkspaceRestoresAllEditsAndUnfinishedPlistRowsAcrossModelLifetimes() async throws {
        let root = try directory(), first = try model(root)
        let source = try file(root, "one")
        _ = await first.loadIPA(source)
        first.customName = "My App"; first.customBundleID = "custom.app"
        first.minimumOSVersion = "27.0"; first.enableFileSharing = true
        first.increasedMemoryLimit = true; first.removeSupportedDevices = true
        first.keepAutomaticallyRefreshed = false
        first.plistOverrides = [PlistOverride(key: "", value: "unfinished")]
        first.persistWorkspace()
        let saved = try XCTUnwrap(first.library.apps.first)
        let restored = try model(root)
        let opened = await restored.openLibraryWorkspace(saved.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(restored.customName, "My App")
        XCTAssertEqual(restored.customBundleID, "custom.app")
        XCTAssertEqual(restored.minimumOSVersion, "27.0")
        XCTAssertTrue(restored.enableFileSharing && restored.increasedMemoryLimit && restored.removeSupportedDevices)
        XCTAssertFalse(restored.keepAutomaticallyRefreshed)
        XCTAssertEqual(restored.plistOverrides, first.plistOverrides)
        XCTAssertEqual(restored.selectedDevice?.udid, device.udid)
        XCTAssertEqual(restored.selectedAccount, "fixture@invalid.local")
    }

    func testBatchImportKeepsInputOrderDeduplicatesAndRequiresReview() async throws {
        let root = try directory(), model = try model(root)
        let second = try file(root, "second"), first = try file(root, "first")
        await model.importIPAs([second, first, second])
        XCTAssertEqual(model.library.queue.map { $0.workspace.ipa.appName }, ["second", "first"])
        XCTAssertTrue(model.library.queue.allSatisfy { $0.status == .review })
        XCTAssertEqual(model.library.apps.count, 2)
        model.startInstallQueue()
        XCTAssertFalse(model.isRunningInstallQueue)
    }

    func testChangedSourceInvalidatesReviewAndDoesNotApplyOldChoices() async throws {
        let root = try directory(), model = try model(root), url = try file(root, "one")
        await readyQueue(model, [url])
        let id = try XCTUnwrap(model.library.apps.first?.id)
        try Data("different contents and size".utf8).write(to: url)
        _ = await model.openLibraryWorkspace(id)
        XCTAssertEqual(model.customName, "")
        XCTAssertEqual(model.library.queue.first?.status, .review)
    }

    func testQueueRunsSequentiallyWithReviewedSnapshotsAndStopsAfterFailure() async throws {
        let root = try directory(), model = try model(root)
        await readyQueue(model, [try file(root, "one"), try file(root, "two"), try file(root, "three")])
        let ids = model.library.queue.map(\.id)
        model.library.apps[0].options = IpaInstallOptions(appPath: model.library.apps[0].ipa.path, displayName: "Later unrelated edits", bundleId: nil,
            removedExtensions: [], customIconPath: nil, increasedMemoryLimit: false)
        model.isRunningInstallQueue = true
        var names: [String] = []
        await model.runInstallQueue(ids) {
            names.append(model.customName)
            return names.count == 1
        }
        XCTAssertEqual(names, ["one Reviewed", "two Reviewed"])
        XCTAssertEqual(model.library.queue.map(\.status), [.installed, .failed, .ready])
        XCTAssertFalse(model.isRunningInstallQueue)
    }

    func testStoppingQueueKeepsRemainingAppsPending() async throws {
        let root = try directory(), model = try model(root)
        await readyQueue(model, [try file(root, "one"), try file(root, "two")])
        model.isRunningInstallQueue = true
        var calls = 0
        await model.runInstallQueue(model.library.queue.map(\.id)) {
            calls += 1; model.stopInstallQueue(); return true
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(model.library.queue.map(\.status), [.installed, .ready])
    }

    func testMissingSourceStopsBeforeInstallerAndLeavesLaterAppsPending() async throws {
        let root = try directory(), model = try model(root), one = try file(root, "one")
        await readyQueue(model, [one, try file(root, "two")])
        try FileManager.default.removeItem(at: one)
        model.isRunningInstallQueue = true
        var called = false
        await model.runInstallQueue(model.library.queue.map(\.id)) { called = true; return true }
        XCTAssertFalse(called)
        XCTAssertEqual(model.library.queue.map(\.status), [.review, .ready])
    }

    func testReorderRemovalAndRelaunchRecoveryNeverResumeSigning() async throws {
        let root = try directory(), model = try model(root)
        await readyQueue(model, [try file(root, "one"), try file(root, "two")])
        let last = try XCTUnwrap(model.library.queue.last?.id)
        model.moveQueueItem(last, by: -1)
        XCTAssertEqual(model.library.queue.first?.workspace.ipa.appName, "two")
        model.library.queue[0].status = .installing; model.persistWorkspace()
        let reopened = try self.model(root)
        XCTAssertEqual(reopened.library.queue[0].status, .review)
        XCTAssertFalse(reopened.isRunningInstallQueue)
        reopened.removeQueueItem(last)
        XCTAssertEqual(reopened.library.queue.count, 1)
        XCTAssertEqual(reopened.library.apps.count, 2)
    }

    func testRemovingLibraryEntryKeepsOriginalIPA() async throws {
        let root = try directory(), model = try model(root), url = try file(root, "one")
        await readyQueue(model, [url])
        model.removeLibraryWorkspace(try XCTUnwrap(model.library.apps.first?.id))
        XCTAssertTrue(model.library.apps.isEmpty && model.library.queue.isEmpty)
        XCTAssertNil(model.ipa)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testCorruptOrFutureLibraryIsPreservedAndFilePermissionsArePrivate() throws {
        let root = try directory(), repo = AppLibraryRepository(fileURL: root.appending(path: "state.json"))
        try repo.save(AppLibraryState())
        let mode = try FileManager.default.attributesOfItem(atPath: repo.fileURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        for payload in ["broken", "{\"version\":2,\"apps\":[],\"queue\":[]}"] {
            let bytes = Data(payload.utf8); try bytes.write(to: repo.fileURL)
            XCTAssertThrowsError(try repo.save(AppLibraryState()))
            XCTAssertEqual(try Data(contentsOf: repo.fileURL), bytes)
        }
    }
}
