import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AutoRefreshView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var appearance: AppearanceController
    @AppStorage("renewalNotificationsEnabled") private var renewalNotificationsEnabled = false
    @State private var notificationStatus: String?
    @State private var replacementID: String?
    @State private var showingSourcePicker = false

    var body: some View {
        WorkspacePage {
            PageHeader(eyebrow: "AUTOMATIC RENEWAL", title: "Auto Refresh",
                       subtitle: "Keep your apps ready to open, with renewal before they expire.")
            AssuranceView()
            scheduleSummary
            if let error = model.managedInstallationsError {
                GroupBox {
                    HStack(spacing: 14) {
                        Label(error, systemImage: "exclamationmark.triangle").font(.callout)
                        Spacer()
                        Button("Show saved schedule") { NSWorkspace.shared.activateFileViewerSelecting([AutoRefreshStore.fileURL]) }
                    }
                }
            }
            if model.managedInstallations.isEmpty {
                WorkspaceEmptyState(symbol: "arrow.clockwise", title: "Ready for the next seven days",
                                    message: "Turn on Keep refreshed when you install an app. Slip will take care of its next renewal here.")
            } else {
                GroupBox {
                    VStack(spacing: 12) {
                        ForEach(model.managedInstallations) { item in managedCard(item) }
                    }
                } label: {
                    Label("Your apps · \(model.managedInstallations.count)", systemImage: "square.stack")
                }
            }
        }
        .onAppear { model.reloadManagedInstallations() }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                if NSApp.isActive { model.reloadManagedInstallations() }
            }
        }
        .fileImporter(isPresented: $showingSourcePicker, allowedContentTypes: [UTType(filenameExtension: "ipa") ?? .archive]) { result in
            let id = replacementID
            replacementID = nil
            if case .success(let url) = result, let id {
                Task { await model.prepareManagedReinstall(id, from: url) }
            }
        }
    }

    private var scheduleSummary: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: AutoRefreshScheduler.isInstalled ? "checkmark.circle" : "clock.badge.exclamationmark")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(AutoRefreshScheduler.isInstalled ? Color.green : .orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(AutoRefreshScheduler.isInstalled ? "Background renewal is ready" : "Open Slip from Applications to enable renewal")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Checks every 15 minutes and after wake. Renews one day before expiry.")
                            .font(.caption).foregroundStyle(Chrome.secondaryText)
                    }
                    Spacer(minLength: 12)
                    Button {
                        appearance.selectionFeedback()
                        model.refreshAllManagedInstallations()
                    } label: { Label("Refresh all", systemImage: "arrow.clockwise") }
                    .disabled(!model.managedInstallations.contains(where: \.enabled) || !model.refreshingManagedIDs.isEmpty)
                }
                Toggle("Quiet renewal notifications", isOn: $renewalNotificationsEnabled)
                    .font(.callout)
                    .onChange(of: renewalNotificationsEnabled) { _, enabled in
                        guard enabled else { return }
                        Task {
                            let allowed = await NotificationCoordinator.shared.requestInteractiveAuthorization()
                            notificationStatus = allowed ? "Quiet alerts enabled. System notification settings control presentation." : "Notifications are unavailable or denied. Enable Slip alerts in macOS System Settings."
                            if !allowed { renewalNotificationsEnabled = false }
                        }
                    }
                if let notificationStatus { Text(notificationStatus).font(.caption).foregroundStyle(Chrome.secondaryText) }
                DisclosureGroup {
                    Text("Keep your Mac awake and your saved IPA in place. Slip prefers Wi-Fi and can use USB. Both devices need the same router or another device’s hotspot.")
                        .font(.callout).foregroundStyle(Chrome.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                } label: {
                    Label("How background renewal works", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(Chrome.secondaryText)
                }
            }
        } label: { Label("Schedule", systemImage: "calendar") }
    }

    private func managedCard(_ item: ManagedInstallation) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: statusSymbol(item))
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(statusColor(item))
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.appName).font(.system(size: 14, weight: .semibold))
                    HStack(spacing: 8) {
                        Text(RenewalEngine.status(for: item).rawValue).foregroundStyle(statusColor(item))
                        Text("·").foregroundStyle(Chrome.secondaryText)
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text((item.expiryIsEstimated ? "Estimated · " : "") + RenewalHealth.label(expiration: item.expiresAt, now: context.date))
                                .foregroundStyle(expiryColor(item, now: context.date))
                        }
                    }.font(.caption)
                }
                Spacer()
                Toggle("Automatically refresh \(item.appName)", isOn: Binding(
                    get: { item.enabled },
                    set: {
                        appearance.selectionFeedback()
                        model.setAutoRefreshEnabled($0, for: item.id)
                    }
                ))
                .labelsHidden().toggleStyle(.switch)
                Menu {
                    Button("Stop managing", role: .destructive) { model.forgetManagedInstallation(item.id) }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("Options for \(item.appName)")
            }
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.enabled ? "Next renewal" : "Automatic renewal paused")
                        .font(.caption).foregroundStyle(Chrome.secondaryText)
                    if item.enabled {
                        Text(item.nextRefreshAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.callout.weight(.medium))
                    }
                }
                Spacer()
                Button {
                    appearance.selectionFeedback()
                    model.refreshManagedInstallationNow(item.id)
                } label: {
                    HStack(spacing: 6) {
                        if model.refreshingManagedIDs.contains(item.id) { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.clockwise") }
                        Text(model.refreshingManagedIDs.contains(item.id)
                             ? (model.activeRefreshID == item.id ? "Refreshing…" : "Queued") : "Refresh now")
                    }
                }
                .disabled(model.isAuthenticating || !model.refreshingManagedIDs.isEmpty || !FileManager.default.fileExists(atPath: item.ipaPath))
                if model.activeRefreshID == item.id {
                    Button("Cancel") { model.cancelInstall() }
                }
            }
            if !FileManager.default.fileExists(atPath: item.ipaPath) {
                HStack(spacing: 12) {
                    Label("Saved IPA is missing", systemImage: "doc.badge.ellipsis")
                        .font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("Choose replacement IPA…") {
                        replacementID = item.id
                        showingSourcePicker = true
                    }
                    .disabled(model.isAuthenticating || model.isInspecting || model.isDownloading)
                }
            }
            if let error = item.lastError, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("Details") {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                    GridRow { Text("App ID").foregroundStyle(Chrome.secondaryText); Text(item.bundleId).textSelection(.enabled) }
                    GridRow { Text(item.expiryIsEstimated ? "Estimated expiry" : "Profile expiry").foregroundStyle(Chrome.secondaryText); Text(item.expiresAt.formatted(date: .abbreviated, time: .shortened)) }
                    GridRow { Text("iPhone").foregroundStyle(Chrome.secondaryText); Text(item.deviceName) }
                    GridRow {
                        Text("IPA").foregroundStyle(Chrome.secondaryText)
                        Text(item.ipaPath).lineLimit(1).truncationMode(.middle).help(item.ipaPath)
                    }
                }
                .font(.caption).padding(.top, 10)
            }
            .font(.caption).foregroundStyle(Chrome.secondaryText)
        }
        .padding(16)
        .background(Chrome.overlay(0.03), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func statusSymbol(_ item: ManagedInstallation) -> String {
        switch item.status {
        case "Needs attention": "exclamationmark.triangle"
        case "Waiting to retry": "wifi.exclamationmark"
        case "Refreshing": "arrow.clockwise"
        case "Paused": "pause.circle"
        default: "checkmark.circle"
        }
    }

    private func statusColor(_ item: ManagedInstallation) -> Color {
        switch item.status {
        case "Needs attention": .orange
        case "Waiting to retry", "Paused": Chrome.secondaryText
        default: .green
        }
    }

    private func expiryColor(_ item: ManagedInstallation, now: Date) -> Color {
        switch RenewalHealth.assess(expiration: item.expiresAt, now: now) {
        case .expired: .red
        case .urgent, .soon: .orange
        case .healthy: Chrome.secondaryText
        }
    }
}
