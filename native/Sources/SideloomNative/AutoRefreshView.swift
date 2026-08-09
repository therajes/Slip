import SwiftUI

struct AutoRefreshView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(
                eyebrow: "DAY 6 RENEWAL",
                title: "Auto Refresh",
                subtitle: "Renew free Apple development installs 24 hours before their seven-day deadline."
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    scheduleSummary
                    if model.managedInstallations.isEmpty {
                        ContentUnavailableView {
                            Label("No managed apps", systemImage: "arrow.clockwise.circle")
                        } description: {
                            Text("Turn on “Keep refreshed automatically” when installing an IPA. It will appear here after a successful install.")
                        }
                        .frame(maxWidth: .infinity, minHeight: 300)
                    } else {
                        ForEach(model.managedInstallations) { item in
                            managedCard(item)
                        }
                    }
                }
                .padding(28)
            }
            .scrollIndicators(.hidden)
        }
        .background(SlipBackdrop())
        .onAppear { model.reloadManagedInstallations() }
    }

    private var scheduleSummary: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: AutoRefreshScheduler.isInstalled ? "checkmark.circle.fill" : "clock.badge.exclamationmark")
                    .font(.system(size: 30))
                    .slipDimensionalSymbol(strength: 1.15)
                    .foregroundStyle(AutoRefreshScheduler.isInstalled ? .green : .orange)
                VStack(alignment: .leading, spacing: 6) {
                    Text(AutoRefreshScheduler.isInstalled ? "Background checks are active" : "Open the installed copy of Slip to activate background checks")
                        .font(.headline)
                    Text("Slip checks every six hours, begins refreshing on day 6, prefers your iPhone’s Network connection, and falls back to USB. The Mac must be awake, the IPA must remain at its saved location, and both devices must join a shared router or a different device’s hotspot.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 10) {
                    Text("Every 6 hours")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.quaternary, in: Capsule())
                    Button {
                        model.refreshAllManagedInstallations()
                    } label: {
                        Label("Refresh All", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(model.managedInstallations.filter(\.enabled).isEmpty || !model.refreshingManagedIDs.isEmpty)
                }
            }
            .padding(10)
        }
    }

    private func managedCard(_ item: ManagedInstallation) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Image(systemName: statusSymbol(item))
                        .font(.system(size: 26))
                        .slipDimensionalSymbol(strength: 1.08)
                        .foregroundStyle(statusColor(item))
                        .frame(width: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.appName).font(.title3.bold())
                        Text(item.bundleId)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { item.enabled },
                        set: { model.setAutoRefreshEnabled($0, for: item.id) }
                    ))
                    .labelsHidden()
                }

                Divider()

                Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 8) {
                    GridRow {
                        Text("Status").foregroundStyle(.secondary)
                        Text(item.status).fontWeight(.medium)
                    }
                    GridRow {
                        Text("Next refresh").foregroundStyle(.secondary)
                        Text(item.enabled ? item.nextRefreshAt.formatted(date: .abbreviated, time: .shortened) : "Paused")
                    }
                    GridRow {
                        Text("Current deadline").foregroundStyle(.secondary)
                        Text(item.expiresAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    GridRow {
                        Text("iPhone").foregroundStyle(.secondary)
                        Text(item.deviceName)
                    }
                    GridRow {
                        Text("IPA").foregroundStyle(.secondary)
                        Text(item.ipaPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(item.ipaPath)
                    }
                }
                .font(.callout)

                if let error = item.lastError, !error.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(item.status == "Needs attention" ? .orange : .secondary)
                }

                HStack {
                    Button("Forget", role: .destructive) {
                        model.forgetManagedInstallation(item.id)
                    }
                    Spacer()
                    Button {
                        model.refreshManagedInstallationNow(item.id)
                    } label: {
                        if model.refreshingManagedIDs.contains(item.id) {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Refresh Now", systemImage: "arrow.clockwise")
                        }
                    }
                    .slipProminentButton()
                    .disabled(model.refreshingManagedIDs.contains(item.id))
                }
            }
            .padding(10)
        }
    }

    private func statusSymbol(_ item: ManagedInstallation) -> String {
        switch item.status {
        case "Needs attention": "exclamationmark.triangle.fill"
        case "Waiting to retry": "wifi.exclamationmark"
        case "Refreshing": "arrow.clockwise.circle.fill"
        case "Paused": "pause.circle.fill"
        default: "checkmark.circle.fill"
        }
    }

    private func statusColor(_ item: ManagedInstallation) -> Color {
        switch item.status {
        case "Needs attention": .orange
        case "Waiting to retry": .secondary
        case "Paused": .secondary
        default: .green
        }
    }
}
