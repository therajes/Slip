import Foundation

struct RecoveryDiagnosis {
    let title: String
    let nextStep: String

    static func explain(_ message: String) -> Self {
        let value = message.lowercased()
        if value.contains("anisette") && ["unreachable", "connect", "timed out", "offline"].contains(where: value.contains) {
            return Self(title: "Authentication provider is unreachable", nextStep: "Check the private server address and network in Apple Accounts. Bring the selected server online, then retry. Your IPA and workspace are preserved.")
        }
        if value.contains("anisette") || value.contains("metadata") {
            return Self(title: "Authentication provider needs attention", nextStep: "Open Apple Accounts and check the selected anisette server. If metadata is incompatible, select a compatible provider and sign in again. Your IPA and workspace are preserved.")
        }
        if value.contains("pair") || value.contains("trust") {
            return Self(title: "iPhone pairing needs attention", nextStep: "Unlock your iPhone, reconnect its USB cable and accept Trust This Computer. Refresh devices before retrying. Your saved app choices are preserved.")
        }
        if value.contains("afc") || value.contains("transfer") || value.contains("installation proxy") {
            return Self(title: "Device transfer was interrupted", nextStep: "Reconnect the iPhone by USB and check whether the app was installed. Review the saved workspace before retrying; signing and installation restart safely.")
        }
        if value.contains("apple") || value.contains("session") || value.contains("password") || value.contains("verification") {
            return Self(title: "Apple authentication needs attention", nextStep: "Open Apple Accounts, sign in again and complete verification. Retry the saved workspace after the account is ready.")
        }
        if value.contains("download") || value.contains("http") || value.contains("offline") {
            return Self(title: "Download needs attention", nextStep: "Check your connection and direct IPA link. Resume is available only when the server supports validated transfers; otherwise start a fresh download. Your previous workspace is preserved.")
        }
        return Self(title: "Operation needs attention", nextStep: "Review the error below and check the saved workspace before retrying. Interrupted signing and installation restart from the beginning.")
    }
}

enum SupportReport {
    static func redact(_ text: String) -> String {
        var value = text
        let patterns = [
            #"https?://[^\s]+"#,
            #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            #"\b[0-9a-f]{8}-[0-9a-f-]{15,}\b"#,
            #"\b[0-9a-f]{24,}\b"#,
            #"/(?:Users|Volumes|private|var|tmp)/[^\n]+"#,
            #"(?i)(password|token|secret|authorization|verification code)\s*[:=]\s*[^\s,]+"#
        ]
        for pattern in patterns {
            value = value.replacingOccurrences(of: pattern, with: "[redacted]", options: [.regularExpression, .caseInsensitive])
        }
        return value
    }
}
