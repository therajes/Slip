import SwiftUI

struct LibraryManagementView: View {
    let workspace: SavedAppWorkspace
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var state = LibraryManagementState()
    @State private var presetName = ""
    @State private var files: [ManagedStorageFile] = []
    @State private var cleanup: [ManagedStorageFile] = []
    @State private var busy = false
    @State private var error: String?
    @State private var confirmCleanup = false
    @State private var cleanupPreviewed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(workspace.name).font(.title2)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Done") { dismiss() }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    GroupBox("Customization presets") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Presets contain preparation choices only. Account, device and sign-in information are excluded.").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                TextField("Preset name", text: $presetName)
                                Button("Save Choices") { perform {
                                    let options = model.activeLibraryID == workspace.id ? model.currentWorkspace()?.options ?? workspace.options : workspace.options
                                    try await LibraryManagementStore.shared.savePreset(name: presetName, options: options)
                                    presetName = ""
                                } }.disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            ForEach(state.presets) { preset in
                                HStack {
                                    Text(preset.name)
                                    Spacer()
                                    Button("Apply & Review") { perform { try await model.applyCustomizationPreset(preset, to: workspace) } }
                                    Button("Delete", role: .destructive) { perform { try await LibraryManagementStore.shared.removePreset(preset.id) } }
                                }
                            }
                            if state.presets.isEmpty { Text("No saved presets").foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                    GroupBox("Version history") {
                        VStack(alignment: .leading, spacing: 10) {
                            let records = state.history[workspace.id.uuidString] ?? []
                            ForEach(records.reversed()) { record in
                                HStack {
                                    Text("\(record.version) (\(record.build))")
                                    Spacer()
                                    Text(record.installed ? "Installed" : "Saved IPA").foregroundStyle(.secondary)
                                    Text(record.date, style: .date).foregroundStyle(.secondary)
                                }.font(.caption)
                            }
                            if records.isEmpty { Text("History starts when this app is saved or installed with Slip 2.7.").foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                    GroupBox("Managed IPA storage") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("\(files.reduce(Int64(0)) { $0 + $1.bytes }.formatted(.byteCount(style: .file))) in \(files.count) managed IPAs")
                            Text("Optionally copy this IPA into Slip’s storage so moving the original cannot break renewal. Originals are always preserved.").font(.caption).foregroundStyle(.secondary)
                            Button("Copy to Managed Storage") { perform { try await model.copyWorkspaceToManagedStorage(workspace.id) } }
                            Divider()
                            Text("Cleanup protects saved workspaces, queued apps and renewal schedules.").font(.caption).foregroundStyle(.secondary)
                            Button("Preview Unreferenced Files") { perform {
                                let schedules = try AutoRefreshStore.loadChecked()
                                cleanup = try await LibraryManagementStore.shared.cleanupCandidates(references: model.managedIPAReferences.union(schedules.map(\.ipaPath)))
                                cleanupPreviewed = true
                            } }
                            if cleanupPreviewed && cleanup.isEmpty { Text("No unreferenced managed IPAs found.").font(.caption).foregroundStyle(.secondary) }
                            ForEach(cleanup) { file in Text("\(file.url.lastPathComponent) · \(file.bytes.formatted(.byteCount(style: .file)))").font(.caption).textSelection(.enabled) }
                            if !cleanup.isEmpty {
                                Button("Move \(cleanup.count) Files to Trash…", role: .destructive) { confirmCleanup = true }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                }
            }
        }
        .padding(24).frame(width: 700, height: 650)
        .disabled(busy || model.workspaceIsBusy)
        .task { await refresh() }
        .confirmationDialog("Move the listed unreferenced managed IPAs to Trash?", isPresented: $confirmCleanup) {
            Button("Move to Trash", role: .destructive) {
                perform {
                    guard !model.workspaceIsBusy else { throw SideloomError.message("Finish the current operation before cleanup.") }
                    guard let operation = OperationCoordinator.beginOperation(type: .install, appName: "Cleaning managed storage") else { throw SideloomError.message("Another installation or renewal is active. Try again when it finishes.") }
                    model.isImportingLibrary = true
                    defer { model.isImportingLibrary = false; operation.end() }
                    try await LibraryManagementStore.shared.cleanup(Set(cleanup.map(\.url.path)), references: model.managedIPAReferences, scheduleURL: AutoRefreshStore.fileURL)
                    cleanup = []
                }
            }
        } message: { Text("These files move to the Bin and can be restored from Finder. Source files outside managed storage are never deleted.") }
    }

    private func refresh() async {
        do {
            state = try await LibraryManagementStore.shared.load()
            files = try await LibraryManagementStore.shared.files()
        } catch { self.error = error.localizedDescription }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy, !model.workspaceIsBusy else { return }
        busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await action(); await refresh() } catch { self.error = error.localizedDescription }
        }
    }
}
