import AppKit
import IOKit.ps
import Network

@MainActor
final class CompanionCoordinator: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let open: () -> Void
    private let install: () -> Void
    private var item: NSStatusItem?
    private var observer: NSObjectProtocol?
    private var pulse: Task<Void, Never>?
    private var pending: Task<Void, Never>?
    private let network = NWPathMonitor()
    private var networkAvailable = true
    private var running = false
    init(model: AppModel, open: @escaping () -> Void, install: @escaping () -> Void) {
        self.model = model; self.open = open; self.install = install
        super.init()
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.configure() } }
        network.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in self?.networkAvailable = available; self?.requestRenewalCheck() }
        }
        network.start(queue: DispatchQueue(label: "app.sideloom.native.network-hints"))
        configure()
        pulse = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self else { return }
                let now = Date()
                if AutoRefreshStore.load().contains(where: { $0.enabled && $0.nextRefreshAt <= now }) { self.requestRenewalCheck() }
            }
        }
        requestRenewalCheck()
    }
    func configure() {
        if UserDefaults.standard.bool(forKey: "showMenuBarCompanion") {
            if item == nil {
                let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                status.button?.image = NSImage(systemSymbolName: "iphone.arrow.forward", accessibilityDescription: String(localized: "Slip renewal companion"))
                let menu = NSMenu(); menu.delegate = self; status.menu = menu; item = status
            }
        } else if let item { NSStatusBar.system.removeStatusItem(item); self.item = nil }
    }
    static func backgroundEnabled(_ defaults: UserDefaults = .standard, legacyEnabled: Bool) -> Bool {
        defaults.object(forKey: "backgroundRefreshEnabled") as? Bool ?? legacyEnabled
    }
    func requestRenewalCheck() {
        guard !running else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, !self.running else { return }
            let entries = AutoRefreshStore.load()
            guard Self.backgroundEnabled(legacyEnabled: entries.contains(where: \.enabled)), !UserDefaults.standard.bool(forKey: "backgroundRefreshPaused"), !self.model.workspaceIsBusy else { return }
            self.running = true
            defer { self.running = false }
            _ = await AutoRefreshWorker.runDue(networkAvailable: self.networkAvailable, onBattery: Self.onBattery)
            self.model.reloadManagedInstallations()
        }
    }
    static var onBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (source as String) == kIOPSBatteryPowerValue
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        model.reloadManagedInstallations()
        menu.removeAllItems()
        func row(_ title: String, _ action: Selector? = nil, key: String = "") {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key); entry.target = self; menu.addItem(entry)
        }
        row(String(localized: "Slip Renewal Assurance"))
        let entries = model.managedInstallations
        let attention = entries.filter { [.expired,.verificationPending,.requiresAuthentication,.reviewRequired].contains(RenewalEngine.status(for: $0)) }.count
        row("\(model.devices.count) discovered iPhones · \(attention) need attention")
        row(String(localized: "Discovery is a hint; the core verifies the intended iPhone."))
        for device in model.devices.prefix(3) { row("\(device.displayName) · \(device.connectionType) · discovery") }
        if let verified = entries.compactMap(\.lastReachableAt).max() { row("Last verified device reachability: \(verified.formatted(date: .abbreviated, time: .shortened))") }
        if let next = entries.filter(\.enabled).min(by: { $0.expiresAt < $1.expiresAt }) {
            row((next.expiryIsEstimated ? String(localized: "Estimated expiry: ") : String(localized: "Confirmed expiry: ")) + next.expiresAt.formatted(date: .abbreviated, time: .shortened))
        } else { row(String(localized: "No enabled renewal recipes")) }
        if let operation = OperationCoordinator.currentOperation() { row("\(operation.appName) · \(model.operationProgress.stage)") }
        menu.addItem(.separator())
        row(String(localized: "Open Slip"), #selector(openSlip), key: "o")
        row(String(localized: "Install IPA…"), #selector(installIPA), key: "i")
        row(String(localized: "Refresh Due"), #selector(refreshDue))
        row(UserDefaults.standard.bool(forKey: "backgroundRefreshPaused") ? String(localized: "Resume Background Refresh") : String(localized: "Pause Background Refresh"), #selector(togglePause))
        menu.addItem(.separator())
        row(String(localized: "Quit Slip"), #selector(quit), key: "q")
    }
    @objc private func openSlip() { open() }
    @objc private func installIPA() { install() }
    @objc private func refreshDue() {
        if !Self.backgroundEnabled(legacyEnabled: AutoRefreshStore.load().contains(where: \.enabled)) || UserDefaults.standard.bool(forKey: "backgroundRefreshPaused") {
            open(); NotificationCenter.default.post(name: .showRefreshHealth, object: nil)
        } else { requestRenewalCheck() }
    }
    @objc private func togglePause() { UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "backgroundRefreshPaused"), forKey: "backgroundRefreshPaused"); requestRenewalCheck() }
    @objc private func quit() { NSApp.terminate(nil) }
    func stop() { pending?.cancel(); pulse?.cancel(); network.cancel(); if let observer { NotificationCenter.default.removeObserver(observer) }; if let item { NSStatusBar.system.removeStatusItem(item) }; item = nil }
}
