import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AppLibraryView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var appearance: AppearanceController
    @State private var search = ""
    @State private var updatingWorkspace: SavedAppWorkspace?
    @State private var managingWorkspace: SavedAppWorkspace?
    @State private var sourceAvailability: [String: Bool] = [:]

    private var pending: [InstallQueueItem] { model.library.queue.filter { $0.status != .installed } }
    private var matchingApps: [SavedAppWorkspace] {
        model.library.apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.ipa.bundleId.localizedCaseInsensitiveContains(search) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        WorkspacePage {
            HStack {
                PageHeader(eyebrow: "YOUR WORKSPACE", title: "App Library",
                           subtitle: "Your IPAs and saved choices, ready when you are.")
                Button { addApps() } label: { Label("Add Apps…", systemImage: "plus") }
                    .disabled(model.workspaceIsBusy)
            }
            if let notice = model.libraryNotice {
                HStack(alignment: .top, spacing: 10) {
                    Label(notice, systemImage: "info.circle").font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { model.libraryNotice = nil } label: { Image(systemName: "xmark") }
                        .help("Dismiss library notice").accessibilityLabel("Dismiss library notice")
                }
                .padding(14).background(Chrome.overlay(0.04), in: RoundedRectangle(cornerRadius: 14))
            }
            if !model.library.queue.isEmpty { queueCard }
            if model.library.apps.isEmpty {
                WorkspaceEmptyState(symbol: "square.stack.3d.up", title: "A home for your apps",
                                    message: "Open an IPA to save its workspace. Add several to build a queue, then review each app before installing.")
            } else {
                GroupBox {
                    LazyVStack(spacing: 0) {
                        TextField("Search apps", text: $search)
                            .textFieldStyle(.roundedBorder).padding(.bottom, 16)
                            .accessibilityLabel("Search library")
                        let apps = matchingApps
                        ForEach(apps) { app in
                            libraryRow(app)
                            if app.id != apps.last?.id { Divider().padding(.vertical, 14) }
                        }
                        if apps.isEmpty { Text("No matching apps").foregroundStyle(Chrome.secondaryText).padding() }
                    }
                    .padding(4)
                } label: { Label("Saved apps · \(model.library.apps.count)", systemImage: "square.stack") }
                Text("Use Updates to follow a release source, or Manage App for presets, history and optional managed storage. Removing a library entry keeps its IPA and Auto Refresh schedule.")
                    .font(.caption).foregroundStyle(Chrome.secondaryText)
            }
        }
        .sheet(item: $updatingWorkspace) { app in
            AppUpdatesView(workspace: app).environmentObject(model)
        }
        .sheet(item: $managingWorkspace) { app in
            LibraryManagementView(workspace: app).environmentObject(model)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.workspaceIsBusy, urls.contains(where: { $0.isFileURL && $0.pathExtension.lowercased() == "ipa" }) else { return false }
            Task { await model.importIPAs(urls) }
            return true
        }
        .task(id: model.library.apps.map(\.ipa.path)) { await refreshSourceAvailability() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshSourceAvailability() }
        }
    }

    private func refreshSourceAvailability() async {
        let paths = model.library.apps.map(\.ipa.path)
        let available = await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: Set(paths).map { ($0, FileManager.default.fileExists(atPath: $0)) })
        }.value
        guard !Task.isCancelled, paths == model.library.apps.map(\.ipa.path) else { return }
        if sourceAvailability != available { sourceAvailability = available }
    }

    private func addApps() {
        guard !model.workspaceIsBusy else { return }
        Task {
            let urls = await WorkspaceFilePicker.ipas()
            if !urls.isEmpty { await model.importIPAs(urls) }
        }
    }

    private func locateIPA(_ id: UUID) {
        guard !model.workspaceIsBusy else { return }
        Task {
            if let url = await WorkspaceFilePicker.ipas(multiple: false).first { await model.locateLibraryWorkspace(id, at: url) }
        }
    }

    private var queueCard: some View {
        GroupBox {
            LazyVStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.isRunningInstallQueue ? "Installing one app at a time" : "Review, then install together")
                            .font(.system(size: 14, weight: .semibold))
                        Text("\(pending.count) pending · Stops if an app needs attention.")
                            .font(.caption).foregroundStyle(Chrome.secondaryText)
                    }
                    Spacer()
                    if model.isRunningInstallQueue {
                        Button(model.pauseQueueAfterCurrent ? "Continue Queue" : "Pause After This App") {
                            model.pauseQueueAfterCurrent.toggle()
                        }
                        Button("Cancel This App") { model.cancelCurrentQueueApp() }
                        Button("Stop Queue") { model.stopInstallQueue() }
                    } else {
                        Button { appearance.selectionFeedback(); model.startInstallQueue() } label: {
                            Label("Install Queue", systemImage: "play.fill")
                        }
                        .disabled(model.workspaceIsBusy || pending.isEmpty || !pending.allSatisfy { $0.status == .ready })
                    }
                }
                ForEach(Array(model.library.queue.enumerated()), id: \.element.id) { index, item in
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: item.status == .installed ? "checkmark.circle" : item.status == .installing ? "arrow.down.app" : "app.badge")
                            .font(.title3).foregroundStyle(item.status == .installed ? Color.green : Chrome.primaryText)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.workspace.name).font(.callout.weight(.medium)).lineLimit(1)
                            Text(item.message ?? "\(item.status.rawValue) · \(item.workspace.ipa.version)")
                                .font(.caption).foregroundStyle(Chrome.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(queueDestination(item.workspace)).font(.caption).foregroundStyle(Chrome.secondaryText).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if item.id == model.activeQueueID {
                            ProgressView().controlSize(.small)
                            Button("Show") { NotificationCenter.default.post(name: .showInstall, object: nil) }
                        } else {
                            Button(item.status == .failed || item.status == .cancelled ? "Review & Retry" : "Review") {
                                Task { await model.reviewQueueItem(item.id) }
                            }.disabled(model.workspaceIsBusy)
                            Button { model.moveQueueItem(item.id, by: -1) } label: { Image(systemName: "chevron.up") }
                                .disabled(index == 0 || model.isRunningInstallQueue).help("Move earlier")
                                .accessibilityLabel("Move \(item.workspace.name) earlier")
                            Button { model.moveQueueItem(item.id, by: 1) } label: { Image(systemName: "chevron.down") }
                                .disabled(index == model.library.queue.count - 1 || model.isRunningInstallQueue).help("Move later")
                                .accessibilityLabel("Move \(item.workspace.name) later")
                            Button { model.removeQueueItem(item.id) } label: { Image(systemName: "xmark") }
                                .help("Remove from queue").accessibilityLabel("Remove \(item.workspace.name) from queue")
                        }
                    }
                    .padding(12).background(Chrome.overlay(0.03), in: RoundedRectangle(cornerRadius: 12))
                }
                if model.library.queue.contains(where: { $0.status == .installed }), !model.isRunningInstallQueue {
                    Button("Clear Completed") {
                        model.library.queue.removeAll { $0.status == .installed }; model.persistWorkspace()
                    }
                }
            }
        } label: { Label("Installation Queue", systemImage: "list.number") }
    }

    private func libraryRow(_ app: SavedAppWorkspace) -> some View {
        let sourceExists = sourceAvailability[app.ipa.path] ?? true
        return HStack(spacing: 14) {
            LibraryArtwork(workspace: app)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name).font(.system(size: 14, weight: .semibold))
                Text("\(app.ipa.version) · \(app.ipa.bundleId)").font(.caption).foregroundStyle(Chrome.secondaryText)
                    .lineLimit(1).truncationMode(.middle)
                Text(sourceExists ? app.ipa.fileName : "Source IPA missing")
                    .font(.caption).foregroundStyle(sourceExists ? Chrome.secondaryText : Color.orange)
                    .lineLimit(1).help(app.ipa.path)
            }
            Spacer(minLength: 8)
            if sourceExists {
                Button("Open") {
                    appearance.selectionFeedback()
                    Task { if await model.openLibraryWorkspace(app.id) { NotificationCenter.default.post(name: .showInstall, object: nil) } }
                }.disabled(model.workspaceIsBusy)
            } else {
                Button("Locate IPA…") { locateIPA(app.id) }.disabled(model.workspaceIsBusy)
            }
            Button("Updates…") { updatingWorkspace = app }.disabled(model.workspaceIsBusy)
            Menu {
                Button("Manage App…") { managingWorkspace = app }
                Divider()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.ipa.path)]) }
                    .disabled(!sourceExists)
                Button("Locate IPA…") { locateIPA(app.id) }
                Divider()
                Button("Remove from Library", role: .destructive) { model.removeLibraryWorkspace(app.id) }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().disabled(model.workspaceIsBusy)
                .accessibilityLabel("Options for \(app.name)")
        }
    }

    private func queueDestination(_ workspace: SavedAppWorkspace) -> String {
        let account = model.hideSensitiveInfo ? "Saved account" : model.accountProfiles[workspace.account]?.displayName ?? (workspace.account.isEmpty ? "Choose an account" : workspace.account)
        let phone = model.devices.first(where: { $0.udid == workspace.deviceUDID })?.displayName
            ?? (workspace.deviceUDID == nil ? "Choose an iPhone" : "Saved iPhone · disconnected")
        return "\(phone) · \(account)"
    }
}
