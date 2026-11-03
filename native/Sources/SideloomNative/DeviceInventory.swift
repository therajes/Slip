import Foundation

extension AppModel {
    func deviceSelectionDidChange(from previous: DeviceInfo?) {
        if let selectedDevice { desiredWorkspaceDeviceUDID = selectedDevice.udid }
        guard previous?.udid != selectedDevice?.udid else { return }
        inventoryGeneration = UUID()
        if !installedApps.isEmpty { installedApps = [] }
        if installedAppsDeviceUDID != nil { installedAppsDeviceUDID = nil }
        if isLoadingInstalledApps { isLoadingInstalledApps = false }
    }

    var inventoryMatchesSelectedDevice: Bool {
        guard let id = selectedDevice?.udid else { return false }
        return installedAppsDeviceUDID == id
    }

    func managedRecipeIDs(for bundleIDs: Set<String>, deviceUDID: String?) -> Set<String> {
        guard let deviceUDID else { return [] }
        return Set(managedInstallations.filter { $0.deviceUDID == deviceUDID && bundleIDs.contains($0.bundleId) }.map(\.id))
    }
}
