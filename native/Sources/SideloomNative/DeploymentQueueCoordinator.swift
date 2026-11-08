import Foundation

extension AppModel {
    /// Hashing stays off the main actor. Each target retains the same reviewed IPA/options.
    func saveReviewedDeployment(targetUDIDs: Set<String>) async {
        guard !workspaceIsBusy, let snapshot = currentWorkspace(), blockingInstallIssue == nil else { return }
        let known = Set(devices.map(\.udid))
        let targets = targetUDIDs.isEmpty ? Set([snapshot.deviceUDID].compactMap { $0 }) : targetUDIDs
        guard !targets.isEmpty, targets.isSubset(of: known) else {
            errorMessage = "Select connected, paired devices and review their readiness before adding targets."
            return
        }
        do {
            let digest = try await Task.detached { try DeploymentJob.sourceHash(snapshot.ipa.path) }.value
            guard !workspaceIsBusy, let current = currentWorkspace(), current.ipa == snapshot.ipa, current.options == snapshot.options, current.account == snapshot.account, current.deviceUDID == snapshot.deviceUDID else {
                libraryNotice = "Choices changed while hashing. Review before adding the deployment."
                return
            }
            persistWorkspace()
            let now = Date()
            for udid in targets.sorted() {
                var target = snapshot; target.deviceUDID = udid
                let job = DeploymentJob(operationID: UUID(), sourceSHA256: digest,
                    optionsSHA256: try DeploymentJob.optionsHash(target.options), deviceUDID: udid,
                    account: target.account, teamID: resourcesAccount == target.account ? resourcesTeamID : nil,
                    effectiveBundleID: target.options.bundleId ?? target.ipa.bundleId, createdAt: now,
                    reviewedAt: now, updatedAt: now)
                let prior = library.queue.firstIndex { $0.workspace.id == target.id && $0.workspace.deviceUDID == udid && $0.status != .installed && $0.status != .unknown }
                if let prior {
                    var reviewed = job
                    reviewed.retryCount = (library.queue[prior].deployment?.retryCount ?? -1) + 1
                    library.queue[prior] = InstallQueueItem(id: library.queue[prior].id, workspace: target, status: .ready, deployment: reviewed)
                } else { library.queue.append(InstallQueueItem(workspace: target, status: .ready, deployment: job)) }
            }
            reviewingQueueID = nil
            persistWorkspace()
            _ = await flushLibraryPersistence()
            NotificationCenter.default.post(name: .showLibrary, object: nil)
        } catch { errorMessage = "The IPA could not be hashed or the deployment could not be saved. Review the source before retrying." }
    }

    /// Install stream owner awaits this before accepting a durable stage change.
    @discardableResult
    func checkpointDeploymentPhase(_ phase: DeploymentPhase, operationID: String? = nil) async -> Bool {
        guard let id = activeQueueID, let index = library.queue.firstIndex(where: { $0.id == id }), library.queue[index].deployment != nil else { return true }
        if let operationID { library.queue[index].deployment?.coreOperationID = operationID }
        if library.queue[index].deployment?.phase != phase {
            do { try library.queue[index].deployment?.transition(to: phase) }
            catch { return false }
        }
        persistWorkspace()
        return await flushLibraryPersistence()
    }

    func reconcileDeploymentOutcome(operationID: String, verified: Bool, noTransfer: Bool = false) async -> Bool {
        guard let index = library.queue.firstIndex(where: { $0.deployment?.coreOperationID == operationID }) else { return true }
        if verified {
            library.queue[index].status = .installed
            library.queue[index].deployment?.phase = .succeeded
            library.queue[index].message = "Installation verified on the intended iPhone."
        } else if noTransfer {
            library.queue[index].status = .review
            library.queue[index].deployment?.phase = .needsReview
            library.queue[index].message = "No transfer occurred. Review this target before another attempt."
        } else { return true }
        library.queue[index].deployment?.updatedAt = Date()
        persistWorkspace()
        return await flushLibraryPersistence()
    }

    func retryFailedDeploymentTargets() {
        guard !workspaceIsBusy else { return }
        for index in library.queue.indices where library.queue[index].status == .failed || library.queue[index].status == .cancelled {
            library.queue[index].status = .review
            library.queue[index].deployment?.phase = .needsReview
            library.queue[index].message = "Review this target before retrying; its previous result remains recorded."
        }
        persistWorkspace()
    }
}
