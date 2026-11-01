import AppKit
import SwiftUI

struct RemoteAnisetteSettings: View {
    @Binding var address: String
    let isAuthenticating: Bool
    @EnvironmentObject private var appearance: AppearanceController
    @StateObject private var directory = AnisetteServerDirectory()
    @State private var showingServers = false
    @State private var editingCustom = false
    @State private var isChecking = false
    @State private var check: AnisetteConnectionCheck?
    @State private var checkError: String?
    @State private var checkTask: Task<Void, Never>?
    @FocusState private var customFieldFocused: Bool

    private var selected: AnisetteDirectoryEntry? { directory.entry(for: address) }
    private var hasAddress: Bool { !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var showsCustomField: Bool { editingCustom || (hasAddress && selected == nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { showingServers.toggle() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "network").font(.system(size: 17, weight: .medium)).frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(selected?.name ?? (hasAddress ? "Custom or saved server" : "Choose a server"))
                            .font(.system(size: 13, weight: .medium))
                        Text(hasAddress ? address : "macOS ADI servers from GitHub")
                            .font(.caption).foregroundStyle(Chrome.secondaryText).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 12)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Chrome.secondaryText)
                }
                .foregroundStyle(Chrome.primaryText)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .slipGlassSurface(interactive: true, cornerRadius: 12)
            .disabled(isAuthenticating)
            .accessibilityLabel("Choose anisette server")
            .accessibilityValue(selected?.name ?? address)
            .popover(isPresented: $showingServers, arrowEdge: .bottom) {
                AnisetteServerPopover(directory: directory, address: address, isAuthenticating: isAuthenticating) { entry in
                    guard !isAuthenticating else { return }
                    address = entry.address
                    editingCustom = false
                    showingServers = false
                    appearance.selectionFeedback()
                } useCustom: {
                    guard !isAuthenticating else { return }
                    editingCustom = true
                    showingServers = false
                    customFieldFocused = true
                    appearance.selectionFeedback()
                }
            }

            if showsCustomField {
                TextField("https://your-server.example or http://127.0.0.1:6969", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .focused($customFieldFocused)
                    .disabled(isAuthenticating)
                    .accessibilityLabel("Custom anisette service URL")
                if hasAddress && AnisetteEndpoint.url(address) == nil {
                    Label("Use HTTPS, or HTTP for a server running on this Mac.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(Chrome.secondaryText)
                }
            }

            HStack(spacing: 10) {
                if hasAddress {
                    Button(action: checkConnection) {
                        HStack(spacing: 6) {
                            if isChecking { ProgressView().controlSize(.mini).accessibilityHidden(true) }
                            Text(isChecking ? "Checking…" : "Check connection")
                        }
                    }
                    .buttonStyle(WorkspaceActionButtonStyle())
                    .disabled(isChecking || isAuthenticating || AnisetteEndpoint.url(address) == nil)
                }
                if let check {
                    Label(check.message, systemImage: check.reportsMacOS ? "checkmark.circle" : "info.circle")
                        .font(.caption).foregroundStyle(Chrome.secondaryText)
                }
            }
            if let checkError {
                Label(checkError, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(Chrome.secondaryText)
            }
            if check != nil {
                Text("This checks the service connection. Apple may still require verification or decline a sign-in.")
                    .font(.caption).foregroundStyle(Chrome.secondaryText)
            }
            Text("Uses only the server you choose. Apple may show a different device in its sign-in alert.")
                .font(.caption).foregroundStyle(Chrome.secondaryText)
        }
        .onChange(of: address) { _, _ in
            checkTask?.cancel()
            isChecking = false
            check = nil
            checkError = nil
        }
        .onChange(of: isAuthenticating) { _, busy in
            if busy { showingServers = false; checkTask?.cancel(); isChecking = false }
        }
        .onDisappear { checkTask?.cancel() }
    }

    private func checkConnection() {
        guard !isAuthenticating, !isChecking else { return }
        let endpoint = address
        check = nil
        checkError = nil
        isChecking = true
        checkTask = Task {
            defer { if !Task.isCancelled { isChecking = false } }
            do {
                let result = try await directory.checkConnection(to: endpoint)
                guard !Task.isCancelled, AnisetteEndpoint.matches(address, endpoint) else { return }
                check = result
            } catch {
                guard !Task.isCancelled else { return }
                if (error as? URLError)?.code == .timedOut {
                    checkError = "The server timed out. Try again or choose another server."
                } else {
                    checkError = (error as? AnisetteDirectoryError)?.localizedDescription
                        ?? "Couldn’t reach this server. Check your connection or choose another server."
                }
            }
        }
    }
}

private struct AnisetteServerPopover: View {
    @ObservedObject var directory: AnisetteServerDirectory
    let address: String
    let isAuthenticating: Bool
    let choose: (AnisetteDirectoryEntry) -> Void
    let useCustom: () -> Void
    @State private var refreshTask: Task<Void, Never>?
    @State private var selectionTask: Task<Void, Never>?
    @State private var checkingAddress: String?
    @State private var selectionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("macOS servers").font(.system(size: 14, weight: .semibold))
                    Text("GitHub order · checked before use").font(.caption).foregroundStyle(Chrome.secondaryText)
                }
                Spacer()
                if directory.isRefreshing { ProgressView().controlSize(.small).accessibilityLabel("Updating server list") }
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(WorkspaceActionButtonStyle())
                    .disabled(directory.isRefreshing || checkingAddress != nil)
                    .help("Refresh server list").accessibilityLabel("Refresh server list")
            }
            if directory.servers.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "network").font(.system(size: 26, weight: .light))
                    Text(directory.isRefreshing ? "Getting servers from GitHub…" : "No macOS servers available")
                        .font(.callout)
                }
                .foregroundStyle(Chrome.secondaryText)
                .frame(maxWidth: .infinity).padding(.vertical, 22)
            } else {
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(directory.servers) { entry in
                            AnisetteServerRow(entry: entry, selected: AnisetteEndpoint.matches(entry.address, address),
                                              isChecking: checkingAddress == entry.address) {
                                chooseAfterChecking(entry)
                            }
                            .disabled(isAuthenticating || directory.isRefreshing || directory.usingCachedList
                                      || directory.lastChecked == nil || directory.errorMessage != nil || checkingAddress != nil)
                        }
                    }
                }
                .frame(height: min(CGFloat(directory.servers.count) * 58, 290))
                .scrollIndicators(.automatic)
            }
            if let error = directory.errorMessage {
                Label(error, systemImage: "wifi.exclamationmark")
                    .font(.caption).foregroundStyle(Chrome.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
            if let error = selectionError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(Chrome.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
            if let warning = directory.cacheWarning {
                Text(warning).font(.caption).foregroundStyle(Chrome.secondaryText)
            }
            HStack {
                if let checked = directory.lastChecked {
                    Text("\(directory.usingCachedList ? "Cached" : "Checked") \(checked.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2).foregroundStyle(Chrome.secondaryText)
                }
                Spacer()
                Link("View on GitHub", destination: AnisetteServerDirectory.github)
                    .font(.caption).foregroundStyle(Chrome.primaryText)
            }
            Divider()
            Button(action: useCustom) {
                Label("Custom/private server…", systemImage: "server.rack")
                    .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(WorkspaceActionButtonStyle()).disabled(isAuthenticating)
        }
        .padding(16).frame(width: 400)
        .foregroundStyle(Chrome.primaryText)
        .task {
            await directory.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                if NSApp.isActive && checkingAddress == nil { await directory.refresh() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .onDisappear { refreshTask?.cancel(); selectionTask?.cancel() }
    }

    private func refresh() {
        guard !directory.isRefreshing, checkingAddress == nil else { return }
        refreshTask?.cancel()
        refreshTask = Task { await directory.refresh() }
    }

    private func chooseAfterChecking(_ entry: AnisetteDirectoryEntry) {
        guard !isAuthenticating, !directory.isRefreshing, checkingAddress == nil else { return }
        checkingAddress = entry.address
        selectionError = nil
        selectionTask = Task {
            defer { if !Task.isCancelled { checkingAddress = nil } }
            do {
                let current = try await directory.verifiedEntry(for: entry.address)
                guard !Task.isCancelled, !isAuthenticating else { return }
                choose(current)
            } catch {
                guard !Task.isCancelled else { return }
                selectionError = (error as? AnisetteDirectoryError)?.localizedDescription
                    ?? "This server isn’t responding with compatible data. Your selected server is unchanged."
            }
        }
    }
}

private struct AnisetteServerRow: View {
    let entry: AnisetteDirectoryEntry
    let selected: Bool
    let isChecking: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "network").font(.system(size: 15)).frame(width: 22)
                    .foregroundStyle(Chrome.secondaryText)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name).font(.system(size: 13, weight: selected ? .semibold : .medium))
                    Text(entry.address).font(.caption).foregroundStyle(Chrome.secondaryText)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 6)
                if isChecking {
                    ProgressView().controlSize(.mini).accessibilityLabel("Checking server connection")
                } else {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).opacity(selected ? 1 : 0)
                }
            }
            .foregroundStyle(Chrome.primaryText)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Chrome.overlay(selected ? 0.09 : hovering ? 0.05 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(entry.name), \(entry.address)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
