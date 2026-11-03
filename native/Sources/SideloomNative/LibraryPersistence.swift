import Foundation

/// Serial disk work never runs on the main actor. Revisions also prevent an
/// older task from overwriting a newer snapshot if task scheduling changes.
actor LibraryDiskWriter {
    private let repository: AppLibraryRepository
    private var newestRevision: UInt64 = 0
    private var savedState: AppLibraryState?
    private(set) var writeCount = 0

    init(repository: AppLibraryRepository, initialState: AppLibraryState) {
        self.repository = repository
        savedState = initialState
    }

    @discardableResult
    func save(_ state: AppLibraryState, revision: UInt64) throws -> Bool {
        guard revision > newestRevision else { return false }
        newestRevision = revision
        guard state != savedState else { return false }
        try repository.save(state)
        savedState = state
        writeCount += 1
        return true
    }
}
