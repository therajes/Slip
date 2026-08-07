import SwiftUI

struct DeviceAppsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""

    private var filteredApps: [InstalledAppInfo] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.installedApps }
        return model.installedApps.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.bundleId.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(
                eyebrow: "DEVICE INVENTORY",
                title: "iPhone Apps",
                subtitle: "Inspect user-installed apps and match them with Slip refresh recipes."
            )

            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    Picker("iPhone", selection: $model.selectedDevice) {
                        ForEach(model.devices) { device in
                            Text("\(device.name) · \(device.connectionType)")
                                .tag(Optional(device))
                        }
                    }
                    .frame(maxWidth: 360)
                    TextField("Search apps or bundle IDs", text: $search)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        Task { await model.loadInstalledApps() }
                    } label: {
                        if model.isLoadingInstalledApps {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Load Apps", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(model.selectedDevice == nil || model.isLoadingInstalledApps)
                }

                if model.installedApps.isEmpty && !model.isLoadingInstalledApps {
                    ContentUnavailableView {
                        Label("No app inventory loaded", systemImage: "iphone.gen3")
                    } description: {
                        Text("Connect and unlock your iPhone, then choose Load Apps.")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filteredApps) { app in
                        HStack(spacing: 14) {
                            Image(systemName: managedRecipe(for: app) == nil ? "app" : "arrow.clockwise.circle.fill")
                                .font(.title2)
                                .foregroundStyle(managedRecipe(for: app) == nil ? Color.secondary : Color.green)
                                .frame(width: 34)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(app.name.isEmpty ? app.bundleId : app.name)
                                    .fontWeight(.semibold)
                                Text(app.bundleId)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
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
                        .padding(.vertical, 5)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .padding(28)
        }
        .background(SlipBackdrop())
    }

    private func managedRecipe(for app: InstalledAppInfo) -> ManagedInstallation? {
        model.managedInstallations.first { $0.bundleId == app.bundleId }
    }
}

private extension View {
    @ViewBuilder
    func glassEffectIfAvailable(tint: Color) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.tint(tint), in: Capsule())
        } else {
            background(.thinMaterial, in: Capsule())
        }
    }
}
