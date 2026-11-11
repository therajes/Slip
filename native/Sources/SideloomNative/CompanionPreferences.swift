import AppKit
import ServiceManagement
import SwiftUI

struct CompanionPreferences: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("showMenuBarCompanion") private var showMenu = false
    @AppStorage("backgroundRefreshEnabled") private var background = false
    @AppStorage("backgroundRefreshPaused") private var paused = false
    @AppStorage("renewalNotificationsEnabled") private var notifications = false
    @AppStorage("renewalQuietHoursEnabled") private var quiet = false
    @AppStorage("renewalQuietStart") private var quietStart = 22
    @AppStorage("renewalQuietEnd") private var quietEnd = 8
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var message: String?
    var body: some View {
        GroupBox("Companion and background behavior") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Show menu bar companion", isOn: $showMenu)
                Toggle("Launch Slip GUI at login", isOn: $loginEnabled).onChange(of: loginEnabled) { _, enabled in
                    do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                    catch { loginEnabled = SMAppService.mainApp.status == .enabled; message = "Login registration needs attention in macOS Login Items." }
                }
                Toggle("Enable background refresh", isOn: $background).onChange(of: background) { _, enabled in
                    if enabled {
                        do { try AutoRefreshScheduler.installIfAppropriate(); message = AutoRefreshScheduler.isInstalled ? "The 15-minute fallback is registered." : "Open the installed Slip app from Applications to register background refresh." }
                        catch { message = error.localizedDescription }
                    }
                    NotificationCenter.default.post(name: .slipRenewalHint, object: nil)
                }
                Toggle("Pause background refresh", isOn: $paused)
                Text("Closing a window keeps Slip running. Quit stops the GUI companion; an opted-in independent LaunchAgent can still renew approved apps every 15 minutes. Disabling background refresh prevents that worker from renewing.").font(.caption).foregroundStyle(.secondary)
                Toggle("Renewal notifications", isOn: $notifications).onChange(of: notifications) { _, enabled in
                    guard enabled else { return }
                    Task { if !(await NotificationCoordinator.shared.requestInteractiveAuthorization()) { notifications = false; message = "Notifications are unavailable. Review Slip in macOS notification settings." } }
                }
                Toggle("Quiet hours for renewal notifications", isOn: $quiet)
                if quiet {
                    HStack {
                        Picker("From", selection: $quietStart) { ForEach(0..<24) { hour in Text(String(format: "%02d:00", hour)).tag(hour) } }
                        Picker("Until", selection: $quietEnd) { ForEach(0..<24) { hour in Text(String(format: "%02d:00", hour)).tag(hour) } }
                    }
                    Text("Quiet hours suppress banners, not eligible renewals. Equal start and end means quiet all day.").font(.caption).foregroundStyle(.secondary)
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.onAppear {
            if UserDefaults.standard.object(forKey: "backgroundRefreshEnabled") == nil { background = AutoRefreshStore.load().contains(where: \.enabled) }
        }
    }
}
