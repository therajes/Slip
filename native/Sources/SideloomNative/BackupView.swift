import AppKit
import SwiftUI

struct BackupView: View {
    @EnvironmentObject private var model: AppModel
    @State private var includeIPAs = false
    @State private var preview: SlipBackup?
    @State private var message = ""
    @State private var busy = false
    private let repository = BackupRepository()
    var body: some View {
        GroupBox("Portable library backup") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Export nonsecret library metadata. Passwords, sessions, signing keys, pairing records and iPhone app private data are excluded. Restore requires review, pairing and authentication.").font(.caption)
                Toggle("Include IPA copies I am authorized to copy (128 MiB each, 256 MiB total)", isOn: $includeIPAs)
                HStack {
                    Button("Export .slipbackup…") { export() }
                    Button("Preview Import…") { inspect() }
                }.disabled(busy || model.workspaceIsBusy)
                if let preview {
                    Text(preview.preview).font(.caption)
                    Text("Conflicts keep local entries. Imported targets require review; renewal is disabled.").font(.caption)
                    Button("Import reviewed workspaces") {
                        Task { @MainActor in
                            guard !model.workspaceIsBusy, await model.flushLibraryPersistence(),
                                  let lease = OperationCoordinator.beginOperation(type: .install, appName: "Restore library") else { return }
                            busy = true; defer { busy = false; lease.end() }
                            do { model.library = try await repository.restore(preview); self.preview = nil; message = "Workspaces restored. Locate or inspect IPAs before deployment." }
                            catch { message = "Backup import failed; existing library retained. \(error.localizedDescription)" }
                        }
                    }.disabled(busy || model.workspaceIsBusy)
                }
                if !message.isEmpty { Text(message).font(.caption).textSelection(.enabled) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Slip.slipbackup"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            guard await model.flushLibraryPersistence() else { return }
            busy = true; defer { busy = false }
            do { let data = try await repository.export(library: model.library, includeIPAs: includeIPAs); try data.write(to: url, options: .atomic); message = "Exported \(data.count.formatted(.byteCount(style: .file)))." }
            catch { message = error.localizedDescription }
        }
    }
    private func inspect() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            busy = true; defer { busy = false }
            do {
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 360 * 1024 * 1024 else { throw SideloomError.message("Backup exceeds format limits.") }
                preview = try await Task.detached { try BackupRepository.inspect(Data(contentsOf: url)) }.value
            } catch { message = error.localizedDescription; preview = nil }
        }
    }
}
