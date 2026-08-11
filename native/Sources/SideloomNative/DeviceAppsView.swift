import AppKit
import SwiftUI

struct DeviceAppsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    @State private var selectedBundleIDs: Set<String> = []
    @State private var pendingUninstall: Set<String> = []
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
        Set(model.managedInstallations.compactMap { installation in
            selectedBundleIDs.contains(installation.bundleId) ? installation.id : nil
        })
    }

    private var uninstallNames: String {
        let names = model.installedApps
            .filter { pendingUninstall.contains($0.bundleId) }
            .map { $0.name.isEmpty ? $0.bundleId : $0.name }
        if names.count <= 3 { return names.joined(separator: ", ") }
        return names.prefix(3).joined(separator: ", ") + ", and \(names.count - 3) more"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(
                eyebrow: "DEVICE MANAGEMENT",
                title: "iPhone Apps",
                subtitle: "Select apps to copy identifiers, refresh managed installs, or uninstall them safely."
            )

            VStack(spacing: 14) {
                controls
                if !model.installedApps.isEmpty { selectionBar }
                content
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
        .background(SlipBackdrop())
        .onChange(of: model.selectedDevice) { _, _ in
            selectedBundleIDs.removeAll()
            model.installedApps = []
        }
        .onChange(of: model.installedApps) { _, apps in
            selectedBundleIDs.formIntersection(Set(apps.map(\.bundleId)))
        }
        .alert("Uninstall \(pendingUninstall.count) App\(pendingUninstall.count == 1 ? "" : "s")?", isPresented: $showUninstallConfirmation) {
            Button("Cancel", role: .cancel) { pendingUninstall.removeAll() }
            Button("Uninstall", role: .destructive) {
                let requested = pendingUninstall
                pendingUninstall.removeAll()
                Task {
                    let removed = await model.uninstallApps(bundleIDs: requested)
                    selectedBundleIDs.subtract(removed)
                }
            }
        } message: {
            Text("This removes \(uninstallNames) and their matching Slip Auto Refresh schedules. iOS also deletes their local app data. This cannot be undone.")
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("iPhone", selection: $model.selectedDevice) {
                ForEach(model.devices) { device in
                    Text("\(device.marketingName) · \(device.connectionType)")
                        .tag(Optional(device))
                }
            }
            .frame(maxWidth: 340)
            TextField("Search apps or bundle IDs", text: $search)
                .textFieldStyle(.roundedBorder)
            Button {
                Task { await model.loadInstalledApps() }
            } label: {
                if model.isLoadingInstalledApps { ProgressView().controlSize(.small) }
                else { Label(model.installedApps.isEmpty ? "Load Apps" : "Reload", systemImage: "arrow.clockwise") }
            }
            .disabled(model.selectedDevice == nil || model.isLoadingInstalledApps || model.isUninstallingApps)
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            SlipStatusPill(
                title: selectedBundleIDs.isEmpty ? "Select apps below" : "\(selectedBundleIDs.count) selected",
                symbol: selectedBundleIDs.isEmpty ? "checklist.unchecked" : "checkmark.circle.fill",
                tint: selectedBundleIDs.isEmpty ? .secondary : .accentColor
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
                showUninstallConfirmation = true
            } label: {
                if model.isUninstallingApps { ProgressView().controlSize(.small) }
                else { Label("Uninstall…", systemImage: "trash") }
            }
            .disabled(selectedBundleIDs.isEmpty || model.isUninstallingApps)
        }
        .padding(12)
        .slipGlassSurface(tint: selectedBundleIDs.isEmpty ? nil : Color.accentColor.opacity(0.08), cornerRadius: 16)
    }

    @ViewBuilder
    private var content: some View {
        if model.installedApps.isEmpty && !model.isLoadingInstalledApps {
            ContentUnavailableView {
                Label("No app inventory loaded", systemImage: "iphone.gen3")
            } description: {
                Text("Connect and unlock your iPhone, then choose Load Apps.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(filteredApps) { app in
                appRow(app)
                    .contentShape(Rectangle())
                    .onTapGesture { toggle(app.bundleId) }
                    .listRowBackground(Color.clear)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            .overlay {
                if filteredApps.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
    }

    private func appRow(_ app: InstalledAppInfo) -> some View {
        let selected = selectedBundleIDs.contains(app.bundleId)
        return HStack(spacing: 14) {
            Button { toggle(app.bundleId) } label: {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .slipDimensionalSymbol(strength: 0.72)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(selected ? "Deselect \(app.name)" : "Select \(app.name)")
            InstalledAppIcon(app: app, isManaged: managedRecipe(for: app) != nil)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name.isEmpty ? app.bundleId : app.name).fontWeight(.semibold)
                Text(app.bundleId).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            if !app.version.isEmpty {
                Text("\(app.version) (\(app.buildVersion))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let recipe = managedRecipe(for: app) {
                Text(recipe.status)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .glassEffectIfAvailable(tint: .green.opacity(0.15))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(selected ? Color.accentColor.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func toggle(_ bundleID: String) {
        if selectedBundleIDs.contains(bundleID) { selectedBundleIDs.remove(bundleID) }
        else { selectedBundleIDs.insert(bundleID) }
    }

    private func managedRecipe(for app: InstalledAppInfo) -> ManagedInstallation? {
        model.managedInstallations.first { $0.bundleId == app.bundleId }
    }
}

private struct InstalledAppIcon: View {
    let app: InstalledAppInfo
    let isManaged: Bool

    private var icon: NSImage? {
        guard let encoded = app.iconData,
              let data = Data(base64Encoded: encoded) else { return nil }
        return NSImage(data: data)
    }

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
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.72), .cyan.opacity(0.34), .white.opacity(0.16)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Text(initials)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.28), radius: 1, y: 1)
            }
        }
        .frame(width: 40, height: 40)
        .fixedSize(horizontal: true, vertical: true)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(0.35), lineWidth: 0.8)
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
        .shadow(color: .white.opacity(0.16), radius: 1, x: -0.5, y: -0.5)
        .shadow(color: .black.opacity(0.30), radius: 4, y: 2)
        .accessibilityLabel("\(app.name.isEmpty ? app.bundleId : app.name) icon")
    }
}

private extension View {
    @ViewBuilder
    func glassEffectIfAvailable(tint: Color) -> some View {
        if #available(macOS 26.0, *) { glassEffect(.regular.tint(tint), in: Capsule()) }
        else { background(.thinMaterial, in: Capsule()) }
    }
}
