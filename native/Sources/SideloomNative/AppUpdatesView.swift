import SwiftUI

struct AppUpdatesView: View {
    let workspace: SavedAppWorkspace
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var subscription = AppUpdateSubscription()
    @State private var source = ""
    @State private var github = false
    @State private var busy = false
    @State private var error: String?
    @State private var selectedReleaseID: String?
    private var selected: AppUpdateRelease? { subscription.releases.first { $0.id == selectedReleaseID } }
    private var installed: InstalledAppInfo? {
        guard model.installedAppsDeviceUDID == workspace.deviceUDID else { return nil }
        return model.installedApps.first { $0.bundleId == (workspace.options.bundleId ?? workspace.ipa.bundleId) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Updates for \(workspace.name)").font(.title2.weight(.semibold))
            HStack {
                Text("Saved IPA: \(workspace.ipa.version)")
                if let installed { Text("Installed: \(installed.version)") }
                else { Text("Installed version not verified").foregroundStyle(.secondary) }
            }.font(.caption)
            Picker("Source", selection: $github) {
                Text("AltStore source feed").tag(false)
                Text("GitHub releases").tag(true)
            }.pickerStyle(.segmented)
            TextField(github ? "owner/repository" : "https://developer.example/source.json", text: $source).textFieldStyle(.roundedBorder)
            HStack {
                Button("Check Updates") { Task { await check() } }.disabled(busy || source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if busy { ProgressView().controlSize(.small) }
                if let date = subscription.checkedAt { Text("Last checked \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            if subscription.releases.isEmpty {
                Text(subscription.checkedAt == nil ? "Add the developer’s source to follow updates. Source contents and downloads are supplied by that developer." : "No eligible IPA releases were found.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
            } else {
                Picker("Release and IPA asset", selection: $selectedReleaseID) {
                    Text("Choose a release and IPA").tag(String?.none)
                    ForEach(subscription.releases) { release in
                        Text("\(release.version) · \(release.assetName)").tag(Optional(release.id))
                    }
                }
                if let release = selected {
                    Text(AppUpdateRelease.compare(release.version, installed?.version ?? workspace.ipa.version) == .orderedDescending ? "Newer version available: \(release.version)" : "Selected version: \(release.version) · Review before replacing the saved IPA.")
                        .font(.headline)
                    Text(release.compatibility(with: model.selectedDevice?.version)).font(.caption).foregroundStyle(.secondary)
                    if let date = release.date { Text(date).font(.caption).foregroundStyle(.secondary) }
                    ScrollView {
                        Text(release.notes.isEmpty ? "No release notes were provided." : release.notes)
                            .font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(minHeight: 90, maxHeight: 180)
                    Text("\(release.downloadURL.host ?? "") · The downloaded bundle identifier must match this app. Saved choices are restored for review; installation requires a separate action.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            HStack {
                Button("Close") { dismiss() }.disabled(busy)
                if busy && model.isDownloading {
                    Button("Cancel Download") { model.cancelDownload() }
                }
                Spacer()
                if let release = selected {
                    Button("Prepare Update…") {
                        Task {
                            busy = true; defer { busy = false }
                            if await model.prepareLibraryUpdate(release, workspace: workspace) { dismiss() }
                            else { error = model.errorMessage ?? (model.currentStage.localizedCaseInsensitiveContains("cancelled") ? "Update download cancelled. Your previous workspace is preserved." : "Finish the current operation before preparing an update.") }
                        }
                    }.disabled(busy || model.workspaceIsBusy || subscription.source != source || subscription.github != github)
                }
            }
        }
        .padding(24).frame(width: 680, height: 600)
        .disabled(model.isRunningInstallQueue)
        .task {
            do {
                subscription = try await AppUpdateRepository.shared.load(workspace.id)
                source = subscription.source; github = subscription.github
                selectUnambiguousLatest()
            } catch { self.error = error.localizedDescription }
        }
        .interactiveDismissDisabled(busy)
    }

    private func selectUnambiguousLatest() {
        guard let first = subscription.releases.first else { selectedReleaseID = nil; return }
        selectedReleaseID = subscription.releases.filter { $0.version == first.version }.count == 1 ? first.id : nil
    }

    private func check() async {
        busy = true; defer { busy = false }
        error = nil
        do {
            let releases = try await SourceFeedClient().releases(source: source, github: github, bundleID: workspace.ipa.bundleId)
            let updated = AppUpdateSubscription(source: source, github: github, checkedAt: Date(), releases: releases)
            try await AppUpdateRepository.shared.save(updated, for: workspace.id)
            subscription = updated
            selectUnambiguousLatest()
        } catch { self.error = error.localizedDescription + " Previous checked results are preserved." }
    }
}
