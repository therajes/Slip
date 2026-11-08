import XCTest
@testable import SideloomNative

final class BackupTests: XCTestCase {
    func testMetadataRoundTripAndCorruption() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = BackupRepository(root: root)
        let data = try await repository.export(library: .init(), includeIPAs: false)
        let preview = try BackupRepository.inspect(data)
        XCTAssertEqual(preview.schemaVersion, 1)
        _ = try await repository.restore(preview)
        var damaged = preview; damaged.checksums["../escape"] = "bad"
        XCTAssertThrowsError(try BackupRepository.inspect(JSONEncoder().encode(damaged)))
        XCTAssertFalse(String(data: data, encoding: .utf8)!.contains("password"))
    }
    func testInterruptedRestoreRollsBack() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let directory = root.appending(path: "Library")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = directory.appending(path: "workspaces-v1.json")
        try Data("partial".utf8).write(to: file)
        let old = try JSONEncoder().encode(AppLibraryState())
        try JSONEncoder().encode(["workspaces-v1.json":old]).write(to: directory.appending(path: "restore-rollback-v1.json"))
        try BackupRepository.recover(root: root)
        XCTAssertEqual(try Data(contentsOf: file), old)
    }
}
