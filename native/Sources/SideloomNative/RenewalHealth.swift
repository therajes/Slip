import Foundation

enum RenewalHealth: Equatable {
    case healthy, soon, urgent, expired
    static func assess(expiration: Date, now: Date = Date()) -> Self {
        let remaining = expiration.timeIntervalSince(now)
        if remaining <= 0 { return .expired }
        if remaining <= 24 * 3600 { return .urgent }
        if remaining <= 48 * 3600 { return .soon }
        return .healthy
    }
    static func label(expiration: Date, now: Date = Date()) -> String {
        let remaining = expiration.timeIntervalSince(now)
        if remaining <= 0 { return "Expired · refresh to reopen" }
        if remaining < 3600 { return "Less than an hour left" }
        if remaining < 48 * 3600 { return "\(Int(ceil(remaining / 3600))) hours left" }
        return "\(Int(ceil(remaining / (24 * 3600)))) days left"
    }
}
