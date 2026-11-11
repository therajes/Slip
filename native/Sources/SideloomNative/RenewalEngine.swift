import Foundation

enum RenewalStatus: String, Codable, Sendable, CaseIterable {
    case upToDate = "Up to Date", scheduled = "Scheduled", due = "Due", renewing = "Renewing"
    case waitingForDevice = "Waiting for iPhone", waitingForNetwork = "Waiting for Network"
    case requiresAuthentication = "Requires Authentication", paused = "Paused"
    case backingOff = "Temporarily Backing Off", expired = "Expired", verificationPending = "Verification Pending"
    case reviewRequired = "Review Required"
}
struct RenewalContext: Sendable {
    var now: Date
    var paused = false
    var networkAvailable = true
    var matchingDeviceReachable = false
    var accountUsable = false
    var sourceMatches = false
    var operationConflict = false
    var onBattery = false
    var force = false
}
struct RenewalDecision: Sendable {
    var status: RenewalStatus
    var reason: String
    var eligible = false
    var nextAction: String
}
enum RenewalEngine {
    static func status(for item: ManagedInstallation, at now: Date = Date()) -> RenewalStatus {
        if !item.enabled { return .paused }
        if item.pendingOperationID != nil { return .verificationPending }
        if item.actionRequired == true || item.status == "Needs attention" {
            return item.reasonCode == "authentication.interaction_required" ? .requiresAuthentication : .reviewRequired
        }
        if item.approvedSourceSHA256 == nil || item.reviewedOptionsSHA256 == nil { return .reviewRequired }
        if item.expiresAt <= now { return .expired }
        if let next = item.nextEligibleAt, next > now { return .backingOff }
        if item.reasonCode == "device.disconnected" { return .waitingForDevice }
        if item.reasonCode == "network.unavailable" { return .waitingForNetwork }
        if item.status == "Refreshing" || item.status == "Renewing" { return .renewing }
        if item.nextRefreshAt > now { return item.lastVerifiedAt == nil ? .scheduled : .upToDate }
        return .due
    }
    static func evaluate(_ item: ManagedInstallation, context: RenewalContext) -> RenewalDecision {
        func blocked(_ status: RenewalStatus, _ reason: String, _ action: String) -> RenewalDecision {
            .init(status: status, reason: reason, nextAction: action)
        }
        guard item.enabled && !context.paused else { return blocked(.paused, "policy.paused", "Resume background refresh when ready.") }
        guard item.pendingOperationID == nil else { return blocked(.verificationPending, "install.verification_pending", "Verify the intended iPhone before retrying.") }
        guard item.approvedSourceSHA256 != nil, item.reviewedOptionsSHA256 != nil, context.sourceMatches else { return blocked(.reviewRequired, "refresh.source_review_required", "Review and approve this IPA and its signing options in Slip.") }
        guard item.actionRequired != true, item.status != "Needs attention" else { return blocked(item.reasonCode == "authentication.interaction_required" ? .requiresAuthentication : .reviewRequired, item.reasonCode ?? "operation.interaction_required", "Open Slip and resolve the recorded issue before retrying.") }
        guard context.force || (item.nextEligibleAt ?? item.nextRefreshAt) <= context.now else { return blocked(status(for: item, at: context.now), "schedule.not_due", "Slip will check again at the next eligible time.") }
        guard !context.operationConflict else { return blocked(.scheduled, "operation.busy", "Wait for the current operation.") }
        guard context.networkAvailable else { return blocked(.waitingForNetwork, "network.unavailable", "Reconnect this Mac to the network.") }
        guard context.matchingDeviceReachable else { return blocked(.waitingForDevice, "device.disconnected", "Connect the intended iPhone by USB or its paired network pathway.") }
        guard context.accountUsable else { return blocked(.requiresAuthentication, "authentication.interaction_required", "Open Accounts and authenticate. Background renewal cannot enter verification codes.") }
        if context.onBattery && item.expiresAt.timeIntervalSince(context.now) > 48 * 3600 && !context.force {
            return blocked(.scheduled, "power.prefers_ac", "AC power is preferred while sufficient expiry headroom remains.")
        }
        return .init(status: .due, reason: "schedule.eligible", eligible: true, nextAction: "Perform a normal re-sign and verified install.")
    }
    static func retryDate(now: Date, attempt: Int, jitter: Double, retryAfter: TimeInterval? = nil) -> Date {
        let exponential = min(6 * 3600, 15 * 60 * pow(2, Double(min(max(attempt - 1, 0), 5))))
        let delay = exponential * (1 + min(max(jitter, 0), 1) * 0.2)
        // A server Retry-After is a lower bound, never shortened by our cap.
        return now.addingTimeInterval(max(delay, max(0, retryAfter ?? 0)))
    }
}
