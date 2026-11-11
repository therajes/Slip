import AppKit
import IOKit

/// USB changes are event driven. Network discovery runs only while Slip is
/// active, at most every 30 seconds, and resumes promptly after wake/activation.
@MainActor
final class DeviceConnectionMonitor {
    private let refresh: @MainActor () async -> Void
    private var usb: USBConnectionObserver?
    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var stopped = false

    init(observeSystemEvents: Bool = true, refresh: @escaping @MainActor () async -> Void) {
        self.refresh = refresh
        guard observeSystemEvents else { return }
        usb = USBConnectionObserver { [weak self] in
            Task { @MainActor [weak self] in self?.requestRefresh() }
        }
        observe(NSApplication.didBecomeActiveNotification, on: .default)
        observe(NSWorkspace.didWakeNotification, on: NSWorkspace.shared.notificationCenter)
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                if NSApp.isActive { self?.requestRefresh() }
            }
        }
    }

    private func observe(_ name: Notification.Name, on center: NotificationCenter) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.requestRefresh() }
        }
        observers.append((center, token))
    }

    func requestRefresh() {
        guard !stopped else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            await self?.refresh()
            NotificationCenter.default.post(name: .slipRenewalHint, object: nil)
        }
    }

    func stop() {
        stopped = true
        pollTask?.cancel(); pollTask = nil
        refreshTask?.cancel(); refreshTask = nil
        usb = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }

    deinit { pollTask?.cancel(); refreshTask?.cancel() }
}

private final class USBConnectionObserver: @unchecked Sendable {
    private var port: IONotificationPortRef?
    private var added: io_iterator_t = 0
    private var removed: io_iterator_t = 0
    private var ready = false
    private let changed: @Sendable () -> Void

    init(changed: @escaping @Sendable () -> Void) {
        self.changed = changed
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { context, iterator in
            USBConnectionObserver.drain(iterator)
            guard let context else { return }
            let observer = Unmanaged<USBConnectionObserver>.fromOpaque(context).takeUnretainedValue()
            if observer.ready { observer.changed() }
        }
        _ = IOServiceAddMatchingNotification(port, kIOMatchedNotification, IOServiceMatching("IOUSBHostDevice"), callback, context, &added)
        Self.drain(added)
        _ = IOServiceAddMatchingNotification(port, kIOTerminatedNotification, IOServiceMatching("IOUSBHostDevice"), callback, context, &removed)
        Self.drain(removed)
        ready = true
    }

    private static func drain(_ iterator: io_iterator_t) {
        guard iterator != 0 else { return }
        while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
    }

    deinit {
        if let port { IONotificationPortDestroy(port) }
        if added != 0 { IOObjectRelease(added) }
        if removed != 0 { IOObjectRelease(removed) }
    }
}

extension Notification.Name { static let slipRenewalHint = Notification.Name("SlipRenewalHint") }
