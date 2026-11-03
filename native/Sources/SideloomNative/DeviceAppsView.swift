// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 Jordy Spruit (Droppy)
// Droppy Code by Jordy Spruit (Droppy), https://getdroppycode.app
// Modified by Slip: native sideloading interface, controls and compatibility.

import AppKit
import SwiftUI

struct DeviceAppsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var appearance: AppearanceController
    @State private var search = ""
    @State private var selectedBundleIDs: Set<String> = []
    @State private var pendingUninstall: Set<String> = []
    @State private var pendingUninstallDeviceUDID: String?
    @State private var showUninstallConfirmation = false

    private var filteredApps: [InstalledAppInfo] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.installedApps }
        return model.installedApps.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.bundleId.localizedCaseInsensitiveContains(query)
        }
    }

    private var filteredBundleIDs: Set<String> { Set(filteredApps.map(\.bundleId)) }

    private var selectedRecipeIDs: Set<String> {
        model.managedRecipeIDs(for: selectedBundleIDs, deviceUDID: model.selectedDevice?.udid)
    }

    private var uninstallNames: String {
        let names = model.installedApps
            .filter { pendingUninstall.contains($0.bundleId) }
            .map { $0.name.isEmpty ? $0.bundleId : $0.name }
        if names.count <= 3 { return names.joined(separator: ", ") }
        return names.prefix(3).joined(separator: ", ") + ", and \(names.count - 3) more"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(
                eyebrow: "DEVICE MANAGEMENT",
                title: "iPhone Apps",
                subtitle: "A home for the apps on your iPhone. Select an app to manage it."
            )

            VStack(spacing: 16) {
                controls
                if !model.installedApps.isEmpty { selectionBar }
                content
            }
        }
        .padding(28)
        .frame(maxWidth: 860)
        .frame(maxWidth: .infinity)
        .buttonStyle(WorkspaceActionButtonStyle())
        .animation(appearance.motionAllowed ? .smooth(duration: 0.2) : nil, value: selectedBundleIDs)
        .onChange(of: model.selectedDevice?.udid) { _, _ in
            selectedBundleIDs.removeAll()
            pendingUninstall.removeAll()
            pendingUninstallDeviceUDID = nil
            showUninstallConfirmation = false
        }
        .onChange(of: model.installedApps) { _, apps in
            selectedBundleIDs.formIntersection(Set(apps.map(\.bundleId)))
        }
        .alert("Uninstall \(pendingUninstall.count) App\(pendingUninstall.count == 1 ? "" : "s")?", isPresented: $showUninstallConfirmation) {
            Button("Cancel", role: .cancel) { pendingUninstall.removeAll() }
            Button("Uninstall", role: .destructive) {
                let requested = pendingUninstall
                let deviceUDID = pendingUninstallDeviceUDID
                pendingUninstall.removeAll()
                Task {
                    guard let deviceUDID else { return }
                    let removed = await model.uninstallApps(bundleIDs: requested, expectedDeviceUDID: deviceUDID)
                    selectedBundleIDs.subtract(removed)
                }
            }
        } message: {
            Text("This removes \(uninstallNames) and their matching Slip Auto Refresh schedules. iOS also deletes their local app data. This cannot be undone.")
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            DeviceConnectionGlyph(device: model.selectedDevice, height: 24)
            Picker("iPhone", selection: $model.selectedDevice) {
                ForEach(model.devices) { device in
                    Text("\(device.marketingName) · \(device.connectionType)")
                        .tag(Optional(device))
                }
            }
            .frame(maxWidth: 245)
            .disabled(model.workspaceIsBusy)
            SidebarSearchField(text: $search, prompt: "Search apps or bundle IDs")
            Button {
                Task { await model.loadInstalledApps() }
            } label: {
                if model.isLoadingInstalledApps { ProgressView().controlSize(.small) }
                else { Label(model.installedApps.isEmpty ? "Load Apps" : "Reload", systemImage: "arrow.clockwise") }
            }
            .disabled(model.selectedDevice == nil || model.isLoadingInstalledApps || model.isUninstallingApps)
        }
        .padding(12)
        .background(Chrome.overlay(0.03), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            SlipStatusPill(
                title: selectedBundleIDs.isEmpty ? "Select apps below" : "\(selectedBundleIDs.count) selected",
                symbol: selectedBundleIDs.isEmpty ? "checklist.unchecked" : "checkmark.circle.fill",
                tint: selectedBundleIDs.isEmpty ? .secondary : Chrome.primaryText
            )
            Button(filteredBundleIDs.isSubset(of: selectedBundleIDs) ? "Clear Visible" : "Select Visible") {
                if filteredBundleIDs.isSubset(of: selectedBundleIDs) {
                    selectedBundleIDs.subtract(filteredBundleIDs)
                } else {
                    selectedBundleIDs.formUnion(filteredBundleIDs)
                }
            }
            .disabled(filteredApps.isEmpty)
            if !selectedBundleIDs.isEmpty {
                Button("Clear") { selectedBundleIDs.removeAll() }
            }
            Spacer()
            Button {
                model.copyBundleIDs(selectedBundleIDs)
            } label: {
                Label("Copy IDs", systemImage: "doc.on.doc")
            }
            .disabled(selectedBundleIDs.isEmpty)
            Button {
                model.refreshManagedInstallations(selectedRecipeIDs)
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help(selectedRecipeIDs.isEmpty ? "Only apps managed by Slip can be refreshed" : "Refresh selected Slip-managed apps")
            .disabled(selectedRecipeIDs.isEmpty || !model.refreshingManagedIDs.isDisjoint(with: selectedRecipeIDs))
            Button(role: .destructive) {
                pendingUninstall = selectedBundleIDs
                pendingUninstallDeviceUDID = model.selectedDevice?.udid
                showUninstallConfirmation = true
            } label: {
                if model.isUninstallingApps { ProgressView().controlSize(.small) }
                else { Label("Uninstall…", systemImage: "trash") }
            }
            .disabled(selectedBundleIDs.isEmpty || model.workspaceIsBusy || !model.inventoryMatchesSelectedDevice)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .slipGlassSurface(cornerRadius: 16)
    }

    @ViewBuilder
    private var content: some View {
        if model.installedApps.isEmpty {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                WorkspaceEmptyState(symbol: "square.grid.2x2", title: model.isLoadingInstalledApps ? "Getting your apps…" : "Your iPhone’s app library",
                                    message: model.selectedDevice == nil ? "Connect and unlock your iPhone to see its apps here." : "See what’s installed, refresh your managed apps, or make room for something new.")
                if model.isLoadingInstalledApps {
                    ProgressView().controlSize(.small)
                } else if model.selectedDevice != nil {
                    Button {
                        appearance.selectionFeedback()
                        Task { await model.loadInstalledApps() }
                    } label: { Label("Load apps", systemImage: "square.grid.2x2") }
                }
                Spacer(minLength: 30)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    if filteredApps.isEmpty {
                        WorkspaceEmptyState(symbol: "magnifyingglass", title: "No matching apps",
                                            message: "Try a different name or app identifier.")
                    }
                    ForEach(filteredApps) { app in
                        Button { toggle(app.bundleId) } label: { appRow(app) }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selectedBundleIDs.contains(app.bundleId) ? .isSelected : [])
                            .contextMenu {
                                Button("Copy app identifier") { model.copyBundleIDs([app.bundleId]) }
                            }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func appRow(_ app: InstalledAppInfo) -> some View {
        let selected = selectedBundleIDs.contains(app.bundleId)
        return HStack(spacing: 14) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(selected ? Chrome.primaryText : Chrome.secondaryText)
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)
            InstalledAppIcon(app: app, isManaged: managedRecipe(for: app) != nil)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name.isEmpty ? app.bundleId : app.name).fontWeight(.semibold)
                Text(app.bundleId).font(.caption.monospaced()).foregroundStyle(Color.primary.opacity(0.7))
            }
            Spacer()
            if !app.version.isEmpty {
                Text(app.buildVersion.isEmpty ? app.version : "\(app.version) (\(app.buildVersion))")
                    .font(.caption)
                    .foregroundStyle(Color.primary.opacity(0.7))
            }
            if let recipe = managedRecipe(for: app) {
                Text(recipe.status)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .foregroundStyle(.green)
                    .slipGlassSurface(cornerRadius: 999)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Chrome.overlay(selected ? 0.08 : 0.03), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func toggle(_ bundleID: String) {
        appearance.selectionFeedback()
        if selectedBundleIDs.contains(bundleID) { selectedBundleIDs.remove(bundleID) }
        else { selectedBundleIDs.insert(bundleID) }
    }

    private func managedRecipe(for app: InstalledAppInfo) -> ManagedInstallation? {
        model.managedInstallations.first { $0.deviceUDID == model.selectedDevice?.udid && $0.bundleId == app.bundleId }
    }
}

private struct InstalledAppIcon: View {
    let app: InstalledAppInfo
    let isManaged: Bool

    @State private var icon: NSImage?

    private var initials: String {
        let value = (app.name.isEmpty ? app.bundleId : app.name)
            .split(whereSeparator: { $0.isWhitespace || $0 == "." || $0 == "-" || $0 == "_" })
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .uppercased()
        return value.isEmpty ? "A" : value
    }

    var body: some View {
        ZStack {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: 40, height: 40)
                    .clipped()
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.065))
                Text(initials)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
            }
        }
        .frame(width: 40, height: 40)
        .fixedSize(horizontal: true, vertical: true)
        .task(id: app.iconData) {
            icon = nil
            guard let encoded = app.iconData else { return }
            let decoded = await ThumbnailCache.shared.image(encoded: encoded)
            if !Task.isCancelled { icon = decoded }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.8)
        }
        .overlay(alignment: .bottomTrailing) {
            if isManaged {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white, .green)
                    .background(Circle().fill(.green).padding(1))
                    .offset(x: 4, y: 4)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel("\(app.name.isEmpty ? app.bundleId : app.name) icon")
    }
}
