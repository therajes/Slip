import Foundation
import XCTest
@testable import SideloomNative

final class LibraryManagementTests: XCTestCase, @unchecked Sendable {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "LibraryManagement-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testPresetExcludesSourceAccountAndDevice() async throws {
        let store = LibraryManagementStore(root: try temporary())
        let options = IpaInstallOptions(appPath: "/private/source.ipa", displayName: "My App", bundleId: "test.app", removedExtensions: [], customIconPath: nil, increasedMemoryLimit: false)
        try await store.savePreset(name: "Personal", options: options)
        let state = try await store.load()
        XCTAssertEqual(state.presets.first?.options.appPath, "")
        let json = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        XCTAssertFalse(json.contains("source.ipa"))
        XCTAssertFalse(json.contains("account"))
        XCTAssertFalse(json.contains("deviceUDID"))
        XCTAssertEqual(state.presets.first?.options.displayName, "My App")
    }
    func testEmptyOlderMetadataDecodesWithNoInventedHistory() throws {
        let state = try JSONDecoder().decode(LibraryManagementState.self, from: Data("{}".utf8))
        XCTAssertTrue(state.history.isEmpty)
        XCTAssertTrue(state.presets.isEmpty)
    }
    func testVerifiedManagedCopyProtectsReferencesAndIgnoresSymlinks() async throws {
        let root = try temporary(), store = LibraryManagementStore(root: root)
        let source = root.appending(path: "original.ipa")
        let bytes = Data(repeating: 42, count: 1024 * 1024)
        try bytes.write(to: source)
        let copy = try await store.copyIPA(source)
        XCTAssertEqual(try Data(contentsOf: copy), bytes)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        let candidates = try await store.cleanupCandidates(references: [copy.path])
        XCTAssertTrue(candidates.isEmpty)
        let link = copy.deletingLastPathComponent().appending(path: "external.ipa")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let unreferenced = try await store.cleanupCandidates(references: [])
        XCTAssertEqual(unreferenced.map { $0.url.resolvingSymlinksInPath() }, [copy.resolvingSymlinksInPath()])
    }
    func testSavedAndInstalledHistoryRemainDistinctAcrossReopening() async throws {
        let root = try temporary(), store = LibraryManagementStore(root: root), id = UUID()
        let ipa = IpaInfo(path: "/fixture.ipa", fileName: "fixture.ipa", appName: "Fixture", bundleId: "test.fixture", version: "2", buildVersion: "20", minimumOsVersion: nil, executable: "Fixture", encryptionStatus: "Decrypted", sizeBytes: 1, extensions: [], appIdCost: 1, warnings: [])
        try await store.record(workspaceID: id, ipa: ipa, installed: false)
        try await store.record(workspaceID: id, ipa: ipa, installed: false)
        try await store.record(workspaceID: id, ipa: ipa, installed: true)
        let reloaded = try await LibraryManagementStore(root: root).load()
        XCTAssertEqual(reloaded.history[id.uuidString]?.map(\.installed), [false, true])
    }

}
