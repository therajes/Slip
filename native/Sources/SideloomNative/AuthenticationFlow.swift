import Foundation

/// Sign-in remains active until Apple developer access is ready and Keychain saving succeeds.
/// This value owns no password, verification code, token, or other authentication secret.
struct AuthenticationFlow {
    enum Phase: String {
        case idle, preparing, checkingSession, signingIn, awaitingCode, verifyingCode
        case finalizingAccount, requestingDeveloperSession, checkingDeveloperAccess, savingAccount, signedIn, failed, cancelled

        var isActive: Bool {
            switch self {
            case .idle, .signedIn, .failed, .cancelled: false
            default: true
            }
        }
    }

    enum ChallengeAction { case verifying, resending, choosingMethod }

    private(set) var phase: Phase = .idle
    private(set) var message = ""
    private(set) var accountEmail = ""
    private(set) var provider: String?
    private(set) var challenge: TwoFactorDetails?
    private(set) var challengeSequence = 0
    private(set) var pendingAction: ChallengeAction?
    private(set) var errorMessage: String?
    private(set) var errorCode: String?
    private(set) var failedStage: String?
    private(set) var retryable = false

    var showsChallenge: Bool {
        challenge != nil && phase != .idle && phase != .signedIn && phase != .cancelled
    }

    var canRespondToChallenge: Bool {
        phase == .awaitingCode && challenge != nil && pendingAction == nil
    }

    var canSubmitCode: Bool { canRespondToChallenge && challenge?.unknown != true }

    var failedStep: String? {
        switch failedStage {
        case "preparing": "Preparing authentication"
        case "checkingSession": "Checking the saved session"
        case "signingIn": "Signing in to Apple"
        case "awaitingCode", "verifyingCode": "Verifying your code"
        case "finalizingAccount": "Completing Apple Account authentication"
        case "requestingDeveloperSession": "Preparing the developer session"
        case "checkingDeveloperAccess": "Checking developer access"
        case "savingAccount": "Saving to Keychain"
        default: nil
        }
    }

    mutating func begin(accountEmail: String) {
        self = AuthenticationFlow()
        self.accountEmail = accountEmail
        phase = .preparing
        message = "Preparing secure Apple sign-in…"
    }

    mutating func receiveState(stage: String?, message: String?, provider: String?, code: String?, retryable: Bool?, failedStage: String?) {
        guard phase.isActive else { return }
        if let provider { self.provider = provider }
        guard let stage else {
            if let message { self.message = message }
            return
        }
        if stage == "failed" {
            fail(message: message ?? "Apple sign-in could not finish.", code: code, retryable: retryable, failedStage: failedStage)
        } else if stage == "cancelled" {
            cancel()
        } else if stage == "signedIn" {
            // The backend is ready, but the verified account still needs to be saved locally.
            phase = .savingAccount
            self.message = "Saving your verified account securely…"
            pendingAction = nil
        } else if let next = Phase(rawValue: stage), next.isActive {
            phase = next
            if let message { self.message = message }
            if next == .verifyingCode { pendingAction = .verifying }
        }
    }

    mutating func updateMessage(_ message: String) {
        guard phase.isActive else { return }
        self.message = message
    }

    mutating func receiveChallenge(_ details: TwoFactorDetails?) {
        guard phase.isActive else { return }
        challenge = details ?? TwoFactorDetails(unknown: false, sms: false, numbers: nil, selectedNumberId: nil, lastError: nil)
        phase = .awaitingCode
        if details?.unknown == true {
            message = details?.sms == true ? "Choose the trusted phone number for your SMS code." : "Choose where to receive your verification code."
        } else {
            message = details?.sms == true ? "Enter the code sent by SMS to your trusted phone." : "Enter the code from your trusted Apple device."
        }
        errorMessage = details?.lastError.flatMap { $0.isEmpty ? nil : $0 }
        errorCode = nil
        failedStage = nil
        retryable = false
        pendingAction = nil
        challengeSequence += 1
    }

    @discardableResult
    mutating func beginChallengeAction(_ action: ChallengeAction) -> Bool {
        guard canRespondToChallenge, action != .verifying || canSubmitCode else { return false }
        pendingAction = action
        errorMessage = nil
        switch action {
        case .verifying:
            phase = .verifyingCode
            message = "Verifying your code with Apple…"
        case .resending: message = "Requesting a new code…"
        case .choosingMethod: message = "Sending your verification code…"
        }
        return true
    }

    mutating func showChallengeError(_ message: String) {
        guard phase.isActive else { return }
        errorMessage = message
    }

    mutating func fail(message: String, code: String? = nil, retryable: Bool? = nil, failedStage: String? = nil) {
        guard phase.isActive || phase == .failed else { return }
        let previousStage = phase.rawValue
        phase = .failed
        self.message = "Sign-in could not finish"
        errorMessage = message
        errorCode = code ?? errorCode
        self.failedStage = failedStage ?? self.failedStage ?? previousStage
        self.retryable = retryable ?? self.retryable
        pendingAction = nil
    }

    mutating func complete() {
        guard phase.isActive else { return }
        phase = .signedIn
        message = "Signed in and saved securely."
        challenge = nil
        errorMessage = nil
        pendingAction = nil
    }

    mutating func cancel() {
        phase = .cancelled
        message = "Sign-in cancelled."
        challenge = nil
        errorMessage = nil
        pendingAction = nil
    }
}

enum VerificationCode {
    static func normalized(_ value: String) -> String {
        let digits = value.filter { $0.isASCII && $0.isNumber }
        guard digits.count <= 6, value.allSatisfy({ ($0.isASCII && $0.isNumber) || $0.isWhitespace || $0 == "-" }) else { return "" }
        return String(digits)
    }
}
