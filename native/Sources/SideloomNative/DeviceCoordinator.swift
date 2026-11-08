import AppKit
import Combine
import Foundation
import SwiftUI

// State remains owned by the MainActor facade; operations retain the shared lease.
extension AppModel {
    func refreshDevices(quiet: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let event = try await core.run(["devices"])
            let discovered = event.devices ?? []
            updateDeviceHealth(discovered: discovered)
            if devices != discovered { devices = discovered }
            let selection: DeviceInfo?
            if let current = selectedDevice,
               let replacement = devices.first(where: { $0.identity == current.identity }) {
                selection = replacement
            } else {
                if let desiredWorkspaceDeviceUDID {
                    selection = devices.first(where: { $0.udid == desiredWorkspaceDeviceUDID && $0.connectionType == "USB" })
                        ?? devices.first(where: { $0.udid == desiredWorkspaceDeviceUDID })
                } else {
                    selection = devices.first(where: { $0.connectionType.caseInsensitiveCompare("USB") == .orderedSame }) ?? devices.first
                }
            }
            if selectedDevice != selection { selectedDevice = selection }
            if !quiet, let errors = event.errors, !errors.isEmpty {
                appendActivity(errors.joined(separator: " • "))
            }
        } catch {
            // A transient discovery failure is not evidence of disconnection.
            if !quiet { errorMessage = error.localizedDescription }
        }
    }

    func enableWiFiConnection() async {
        guard !isEnablingWiFi else { return }
        guard let device = selectedDevice else {
            errorMessage = "Connect and select an iPhone first."
            return
        }
        guard device.connectionType.caseInsensitiveCompare("USB") == .orderedSame else {
            errorMessage = "Connect this iPhone by USB before enabling its Wi-Fi connection."
            return
        }
        isEnablingWiFi = true
        defer { isEnablingWiFi = false }
        do {
            let event = try await core.run(["enable-wifi", device.udid])
            appendActivity(event.message ?? "Enabled Wi-Fi connection for \(device.name)")
            await refreshDevices()
        } catch {
            errorMessage = error.localizedDescription
            appendActivity("Wi-Fi setup failed: \(error.localizedDescription)")
        }
    }

    func loadInstalledApps() async {
        guard !isLoadingInstalledApps, !isUninstallingApps else { return }
        guard let device = selectedDevice else {
            installedApps = []
            return
        }
        isLoadingInstalledApps = true
        let generation = UUID()
        inventoryGeneration = generation
        defer { if inventoryGeneration == generation { isLoadingInstalledApps = false } }
        do {
            let event = try await core.run(["apps"], input: device)
            guard inventoryGeneration == generation, selectedDevice?.udid == device.udid else { return }
            installedAppsDeviceUDID = device.udid
            installedApps = event.apps ?? []
            appendActivity("Loaded \(installedApps.count) user apps from \(device.name)")
        } catch {
            guard inventoryGeneration == generation, selectedDevice?.udid == device.udid else { return }
            installedApps = []
            installedAppsDeviceUDID = nil
            errorMessage = error.localizedDescription
        }
    }

    func copyBundleIDs(_ bundleIDs: Set<String>) {
        guard !bundleIDs.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(bundleIDs.sorted().joined(separator: "\n"), forType: .string)
        appendActivity("Copied \(bundleIDs.count) bundle ID\(bundleIDs.count == 1 ? "" : "s")")
    }

    func uninstallApps(bundleIDs: Set<String>, expectedDeviceUDID: String? = nil) async -> Set<String> {
        guard !workspaceIsBusy, !isUninstallingApps, let device = selectedDevice, !bundleIDs.isEmpty,
              inventoryMatchesSelectedDevice, expectedDeviceUDID == nil || expectedDeviceUDID == device.udid else { return [] }
        isUninstallingApps = true
        defer { isUninstallingApps = false }
        do {
            let request = UninstallAppsRequest(device: device, bundleIds: bundleIDs.sorted())
            let event = try await core.run(["uninstall"], input: request)
            let removed = Set(event.bundleIds ?? [])
            if selectedDevice?.udid == device.udid, installedAppsDeviceUDID == device.udid {
                installedApps.removeAll { removed.contains($0.bundleId) }
            }
            if !removed.isEmpty {
                removeRefreshRecipes(for: removed, deviceUDID: device.udid)
            }
            appendActivity(event.message ?? "Removed \(removed.count) app\(removed.count == 1 ? "" : "s") from \(device.marketingName)")
            if let errors = event.errors, !errors.isEmpty {
                errorMessage = errors.joined(separator: "\n")
                appendActivity("Some selected apps could not be removed")
            }
            return removed
        } catch {
            errorMessage = friendlyMessage(for: error)
            appendActivity("Uninstall failed: \(friendlyMessage(for: error))")
            return []
        }
    }

    func copySelectedUDID() {
        guard let udid = selectedDevice?.udid else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(udid, forType: .string)
        appendActivity("Copied iPhone UDID")
    }

    func removeRefreshRecipes(for bundleIDs: Set<String>, deviceUDID: String) {
        do {
            let removed = try AutoRefreshStore.remove(bundleIDs: bundleIDs, deviceUDID: deviceUDID)
            guard removed > 0 else { return }
            reloadManagedInstallations()
            appendActivity("Removed matching Auto Refresh schedules")
        } catch {
            errorMessage = "The apps were removed, but Slip could not remove their Auto Refresh schedules: \(error.localizedDescription)"
        }
    }

}
