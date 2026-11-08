// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 Jordy Spruit (Droppy)
// Droppy Code by Jordy Spruit (Droppy), https://getdroppycode.app
// Modified by Slip: native sideloading interface, controls and compatibility.

import AppKit
import DroppyWindowBridge
import SwiftUI

@main
struct SlipApp: App {
    @NSApplicationDelegateAdaptor(SlipApplicationDelegate.self) private var applicationDelegate

    var body: some Scene {
        Settings {
            AppearanceSettingsView()
                .environmentObject(applicationDelegate.appearance)
                .frame(width: 760, height: 680)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { applicationDelegate.showSettings() }
                    .keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {
                Button("Show Slip") { applicationDelegate.showMainWindow() }
                    .keyboardShortcut("n")
                Button("Open IPA…") { applicationDelegate.openIPA() }
                    .keyboardShortcut("o")
                Button("Refresh Devices") {
                    Task { await applicationDelegate.model.refreshDevices() }
                }
                .keyboardShortcut("r")
            }
        }
    }
}

/// Droppy's display-cycle guarded AppKit window, with Slip's keyboard routing.
final class SlipWindow: DCDisplayCycleGuardedWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class SlipApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model: AppModel
    let appearance = AppearanceController()
    private let workerMode: Bool
    private var mainWindow: SlipWindow?
    private var waitingToTerminate = false
    private var notificationObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var recoveryRunning = false

    override init() {
        let isWorker = CommandLine.arguments.contains("--refresh-due")
        workerMode = isWorker
        model = AppModel(startupTasks: !isWorker)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if workerMode {
            NSApp.setActivationPolicy(.prohibited)
            Task {
                _ = await AutoRefreshWorker.runDue()
                NSApp.terminate(nil)
            }
        } else {
            NSApp.setActivationPolicy(.regular)
            NotificationCoordinator.shared.configureInteractiveApplication()
            notificationObserver = NotificationCenter.default.addObserver(forName: .slipNotificationAction, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.showMainWindow()
                    NotificationCenter.default.post(name: .showRefreshHealth, object: nil)
                }
            }
            showMainWindow()
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, !self.recoveryRunning else { return }
                    self.recoveryRunning = true
                    defer { self.recoveryRunning = false }
                    _ = await AutoRefreshWorker.runDue()
                    self.model.reloadManagedInstallations()
                    await self.model.refreshDevices()
                }
            }
        }
    }

    func showMainWindow() {
        guard !workerMode else { return }
        let window: SlipWindow
        if let existing = mainWindow {
            window = existing
        } else {
            let content = ContentView()
                .environmentObject(model)
                .environmentObject(appearance)
                .frame(minWidth: 1040, minHeight: 680)
            window = SlipWindowHost.make(size: NSSize(width: 1200, height: 800)) { content }
            window.delegate = self
            window.contentMinSize = NSSize(width: 1040, height: 680)
            window.setFrameAutosaveName("SlipMainWindow")
            if !window.setFrameUsingName("SlipMainWindow") { window.center() }
            mainWindow = window
        }
        appearance.apply()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        NSApp.activate(ignoringOtherApps: true)
    }

    func showSettings() {
        showMainWindow()
        NotificationCenter.default.post(name: .showSlipSettings, object: nil)
    }

    func openIPA() {
        showMainWindow()
        NotificationCenter.default.post(name: .openIPA, object: nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !workerMode else { return .terminateNow }
        if waitingToTerminate { return .terminateLater }
        model.persistWorkspace()
        if !model.workspaceIsBusy {
            guard model.pendingLibraryWrites > 0 else {
                if model.librarySaveFailed { model.errorMessage = "Slip couldn’t save your latest library changes. Keep Slip open and check available storage before quitting." }
                return model.librarySaveFailed ? .terminateCancel : .terminateNow
            }
            finishTermination(sender)
            return .terminateLater
        }
        let cancellable = model.isAuthenticating || model.isDownloading || model.isRunningInstallQueue
        let alert = NSAlert()
        alert.messageText = "Slip is still working"
        alert.informativeText = cancellable
            ? "An installation, renewal or download is in progress. Keep Slip open, or stop the operation before quitting."
            : "An IPA is being checked or exported. Slip can quit as soon as it finishes."
        alert.addButton(withTitle: "Keep Slip Open")
        alert.addButton(withTitle: cancellable ? "Stop and Quit" : "Quit When Finished")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        if model.isDownloading { model.cancelDownload() }
        if model.isRunningInstallQueue { model.stopInstallQueue() }
        if model.isAuthenticating { model.cancelInstall() }
        finishTermination(sender)
        return .terminateLater
    }

    private func finishTermination(_ sender: NSApplication) {
        waitingToTerminate = true
        Task {
            while model.workspaceIsBusy {
                try? await Task.sleep(for: .milliseconds(50))
            }
            let saved = await model.flushLibraryPersistence()
            waitingToTerminate = false
            sender.reply(toApplicationShouldTerminate: saved)
            if !saved { model.errorMessage = "Slip couldn’t save your latest library changes. Keep Slip open and check available storage before quitting." }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        model.deviceMonitor?.stop()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        showMainWindow()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .slipOpenURL, object: urls)
        }
    }
}

extension Notification.Name {
    static let openIPA = Notification.Name("SideloomOpenIPA")
    static let slipOpenURL = Notification.Name("SlipOpenIncomingURL")
}
