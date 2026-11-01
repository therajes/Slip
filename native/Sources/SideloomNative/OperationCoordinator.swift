import Foundation

struct SlipOperation: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case install, refresh }
    var type: Kind
    var appName: String
    var bundleId: String?
    var pid: Int32
    var startedAt: Date
}

final class OperationLeaseStore: @unchecked Sendable {
    let fileURL: URL
    private var lockURL: URL { fileURL.appendingPathExtension("lock") }
    private let metadataLock = NSLock()
    init(fileURL: URL) { self.fileURL = fileURL }

    func current() -> SlipOperation? {
        metadataLock.lock()
        defer { metadataLock.unlock() }
        do {
            if let idle = try FileLease.acquire(lockURL) {
                defer { idle.release() }
                try? FileManager.default.removeItem(at: fileURL)
                return nil
            }
            return try? JSONDecoder().decode(SlipOperation.self, from: Data(contentsOf: fileURL))
        } catch { return nil }
    }

    func begin(type: SlipOperation.Kind, appName: String, bundleId: String?) -> OperationHandle? {
        metadataLock.lock()
        defer { metadataLock.unlock() }
        do {
            guard let lease = try FileLease.acquire(lockURL) else { return nil }
            let operation = SlipOperation(type: type, appName: appName, bundleId: bundleId,
                                          pid: ProcessInfo.processInfo.processIdentifier, startedAt: Date())
            do { try JSONEncoder().encode(operation).write(to: fileURL, options: .atomic) }
            catch { lease.release(); throw error }
            return OperationHandle(operation: operation, lease: lease, store: self)
        } catch { return nil }
    }

    fileprivate func finish(_ operation: SlipOperation) {
        metadataLock.lock()
        defer { metadataLock.unlock() }
        if let current = try? JSONDecoder().decode(SlipOperation.self, from: Data(contentsOf: fileURL)), current == operation {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    final class OperationHandle: @unchecked Sendable {
        let operation: SlipOperation
        private let lease: FileLease
        private let store: OperationLeaseStore
        private let lock = NSLock()
        private var ended = false
        fileprivate init(operation: SlipOperation, lease: FileLease, store: OperationLeaseStore) {
            self.operation = operation; self.lease = lease; self.store = store
        }
        func end() {
            lock.lock()
            defer { lock.unlock() }
            guard !ended else { return }
            ended = true
            store.finish(operation)
            lease.release()
        }
        deinit { end() }
    }
}

enum OperationCoordinator {
    typealias OperationHandle = OperationLeaseStore.OperationHandle
    private static let store = OperationLeaseStore(fileURL:
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "app.sideloom.native/current-operation.json"))
    static func currentOperation() -> SlipOperation? { store.current() }
    static func currentlyRefreshingAppName() -> String? {
        guard let operation = currentOperation(), operation.type == .refresh else { return nil }
        return operation.appName
    }
    static func isOperationInProgress() -> Bool { currentOperation() != nil }
    static func beginOperation(type: SlipOperation.Kind, appName: String, bundleId: String? = nil) -> OperationHandle? {
        store.begin(type: type, appName: appName, bundleId: bundleId)
    }
}
