import CryptoKit
import Foundation

actor IPAPreviewCache {
    static let shared = IPAPreviewCache()
    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "app.sideloom.native/IPAIcons-v2", directoryHint: .isDirectory)
    }

    func location(for info: IpaInfo) throws -> (url: URL, exists: Bool) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stamp = IPAFileStamp.read(info.path)
        let identity = "\(info.path)|\(info.sizeBytes)|\(stamp?.modifiedAt.timeIntervalSince1970 ?? 0)|\(info.version)|\(info.buildVersion)"
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let url = directory.appending(path: key + ".png")
        let exists = FileManager.default.fileExists(atPath: url.path)
        if exists { try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path) }
        return (url, exists)
    }

    func store(_ temporary: URL, at destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) { try? FileManager.default.removeItem(at: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: destination) }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
            .filter { $0.pathExtension == "png" && !$0.lastPathComponent.hasPrefix("temporary-") && $0 != destination }
            .map { ($0, try $0.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])) }
            .sorted { ($0.1.contentModificationDate ?? .distantPast) > ($1.1.contentModificationDate ?? .distantPast) }
        var bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        for (index, file) in files.enumerated() {
            bytes += file.1.fileSize ?? 0
            if index >= 63 || bytes > 32 * 1024 * 1024 { try? FileManager.default.removeItem(at: file.0) }
        }
    }

    func discard(_ url: URL) { try? FileManager.default.removeItem(at: url) }
}
