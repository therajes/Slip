import Foundation
import UserNotifications

final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationCoordinator()
    enum Category: String, CaseIterable { case refreshSuccess = "refresh.success", refreshFailed = "refresh.failed", appExpiring = "app.expiring", queueCompleted = "queue.completed" }
    func configureInteractiveApplication() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let open = UNNotificationAction(identifier: "open", title: "Open Slip", options: .foreground)
        let issue = UNNotificationAction(identifier: "issue", title: "View Issue", options: .foreground)
        let refresh = UNNotificationAction(identifier: "refresh", title: "Review & Refresh", options: .foreground)
        center.setNotificationCategories(Set(Category.allCases.map {
            UNNotificationCategory(identifier: $0.rawValue, actions: [open, issue, refresh], intentIdentifiers: [])
        }))
    }
    /// Called only from an explicit control in the foreground application.
    func requestInteractiveAuthorization() async -> Bool {
        guard !CommandLine.arguments.contains("--refresh-due") else { return false }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge])) ?? false
    }
    static func shouldDeliver(enabled: Bool, authorized: Bool, alertsEnabled: Bool, lastDelivered: Date?, now: Date, category: Category) -> Bool {
        guard enabled && authorized && alertsEnabled else { return false }
        if category == .appExpiring, let lastDelivered, now.timeIntervalSince(lastDelivered) < 24 * 3600 { return false }
        return true
    }
    func deliver(_ category: Category) async {
        guard UserDefaults.standard.bool(forKey: "renewalNotificationsEnabled") else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let deliveryKey = "notificationLastDelivered." + category.rawValue
        let now = Date()
        guard Self.shouldDeliver(enabled: true, authorized: true, alertsEnabled: settings.alertSetting == .enabled,
            lastDelivered: UserDefaults.standard.object(forKey: deliveryKey) as? Date, now: now, category: category) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Slip"
        content.body = switch category {
        case .refreshSuccess: "App renewal completed and was verified."
        case .refreshFailed: "A renewal needs attention. Open Slip to review the next step."
        case .appExpiring: "An app may expire soon. Open Slip to review renewal."
        case .queueCompleted: "The reviewed installation queue has finished. Open Slip for outcomes."
        }
        content.categoryIdentifier = category.rawValue
        // No private account/device information or audible sound in a quiet notification.
        do {
            try await center.add(UNNotificationRequest(identifier: category.rawValue, content: content, trigger: nil))
            UserDefaults.standard.set(now, forKey: deliveryKey)
        } catch {
            // Delivery failure leaves the preference unchanged and permits a later retry.
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let actionIdentifier = response.actionIdentifier
        await MainActor.run {
            NotificationCenter.default.post(name: .slipNotificationAction, object: nil, userInfo: ["action": actionIdentifier])
        }
    }
}
extension Notification.Name {
    static let showRefreshHealth = Notification.Name("SlipShowRefreshHealth")
    static let slipNotificationAction = Notification.Name("SlipNotificationAction") }
