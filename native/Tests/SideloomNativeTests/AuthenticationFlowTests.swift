import XCTest
@testable import SideloomNative

final class AuthenticationFlowTests: XCTestCase {
    private var trustedDeviceChallenge: TwoFactorDetails {
        TwoFactorDetails(unknown: false, sms: false, numbers: nil, selectedNumberId: nil, lastError: nil)
    }

    func testVerificationStaysVisibleUntilDeveloperAccessAndLocalSavingComplete() {
        var flow = AuthenticationFlow()
        flow.begin(accountEmail: "example@example.invalid")
        flow.receiveChallenge(trustedDeviceChallenge)
        XCTAssertTrue(flow.showsChallenge)
        XCTAssertTrue(flow.beginChallengeAction(.verifying))
        XCTAssertFalse(flow.canSubmitCode)
        XCTAssertFalse(flow.beginChallengeAction(.verifying), "A second Return or click must not queue another code.")
        for stage in ["verifyingCode", "finalizingAccount", "requestingDeveloperSession", "checkingDeveloperAccess", "signedIn"] {
            flow.receiveState(stage: stage, message: "Working…", provider: "local", code: nil, retryable: nil, failedStage: nil)
            XCTAssertTrue(flow.showsChallenge, "The inline field must survive \(stage).")
            XCTAssertFalse(flow.canRespondToChallenge)
        }
        XCTAssertEqual(flow.phase, .savingAccount)
        flow.complete()
        XCTAssertEqual(flow.phase, .signedIn)
        XCTAssertFalse(flow.showsChallenge)
    }

    func testTrustedSessionDoesNotForceAnUnnecessaryCodePrompt() {
        var flow = AuthenticationFlow()
        flow.begin(accountEmail: "example@example.invalid")
        for stage in ["checkingSession", "requestingDeveloperSession", "checkingDeveloperAccess", "signedIn"] {
            flow.receiveState(stage: stage, message: nil, provider: "local", code: nil, retryable: nil, failedStage: nil)
            XCTAssertFalse(flow.showsChallenge)
        }
        XCTAssertEqual(flow.phase, .savingAccount, "Backend readiness alone must not claim Keychain saving succeeded.")
        flow.complete()
        XCTAssertEqual(flow.phase, .signedIn)
    }

    func testRejectedCodeReopensTheSameChallengeWithAnInlineError() {
        var flow = AuthenticationFlow()
        flow.begin(accountEmail: "example@example.invalid")
        flow.receiveChallenge(trustedDeviceChallenge)
        let initialSequence = flow.challengeSequence
        XCTAssertTrue(flow.beginChallengeAction(.verifying))
        flow.receiveChallenge(TwoFactorDetails(unknown: false, sms: false, numbers: nil, selectedNumberId: nil,
                                              lastError: "That code expired. Enter the new code."))
        XCTAssertTrue(flow.showsChallenge)
        XCTAssertTrue(flow.canSubmitCode)
        XCTAssertEqual(flow.challengeSequence, initialSequence + 1)
        XCTAssertEqual(flow.errorMessage, "That code expired. Enter the new code.")
        XCTAssertTrue(flow.beginChallengeAction(.verifying))
        XCTAssertNil(flow.errorMessage)
    }

    func testResendAndMethodSelectionCannotOverlap() {
        var flow = AuthenticationFlow()
        flow.begin(accountEmail: "example@example.invalid")
        flow.receiveChallenge(TwoFactorDetails(unknown: true, sms: nil, numbers: nil, selectedNumberId: nil, lastError: nil))
        XCTAssertFalse(flow.canSubmitCode)
        XCTAssertFalse(flow.beginChallengeAction(.verifying))
        XCTAssertTrue(flow.beginChallengeAction(.choosingMethod))
        XCTAssertFalse(flow.beginChallengeAction(.choosingMethod))
        XCTAssertFalse(flow.beginChallengeAction(.resending))
        flow.receiveChallenge(trustedDeviceChallenge)
        XCTAssertTrue(flow.beginChallengeAction(.resending))
        XCTAssertFalse(flow.beginChallengeAction(.verifying))
        flow.receiveChallenge(trustedDeviceChallenge)
        XCTAssertTrue(flow.canSubmitCode)
    }

    func testFailureAfterCodePreservesContextAndRejectsLateState() {
        var flow = AuthenticationFlow()
        flow.begin(accountEmail: "example@example.invalid")
        flow.receiveChallenge(trustedDeviceChallenge)
        XCTAssertTrue(flow.beginChallengeAction(.verifying))
        flow.receiveState(stage: "failed", message: "The connection was interrupted.", provider: "local",
                          code: "network", retryable: true, failedStage: "requestingDeveloperSession")
        XCTAssertTrue(flow.showsChallenge)
        XCTAssertFalse(flow.canRespondToChallenge)
        XCTAssertEqual(flow.failedStep, "Preparing the developer session")
        XCTAssertEqual(flow.errorCode, "network")
        XCTAssertTrue(flow.retryable)
        flow.receiveState(stage: "signedIn", message: nil, provider: "remote", code: nil, retryable: nil, failedStage: nil)
        flow.receiveChallenge(trustedDeviceChallenge)
        XCTAssertEqual(flow.phase, .failed)
        XCTAssertEqual(flow.provider, "local")
    }

    func testCancellationClearsChallengeAndIgnoresLateEvents() {
        var flow = AuthenticationFlow()
        flow.begin(accountEmail: "example@example.invalid")
        flow.receiveChallenge(trustedDeviceChallenge)
        flow.cancel()
        flow.receiveChallenge(trustedDeviceChallenge)
        flow.receiveState(stage: "verifyingCode", message: nil, provider: nil, code: nil, retryable: nil, failedStage: nil)
        flow.complete()
        flow.fail(message: "A late error must not undo cancellation.")
        XCTAssertEqual(flow.phase, .cancelled)
        XCTAssertFalse(flow.showsChallenge)
        XCTAssertNil(flow.pendingAction)
    }

    func testNewAttemptClearsOldFailureAndProvider() {
        var flow = AuthenticationFlow()
        flow.begin(accountEmail: "first@example.invalid")
        flow.receiveChallenge(trustedDeviceChallenge)
        flow.receiveState(stage: "failed", message: "Unavailable", provider: "remote", code: "network", retryable: true, failedStage: "signingIn")
        flow.begin(accountEmail: "second@example.invalid")
        XCTAssertEqual(flow.phase, .preparing)
        XCTAssertEqual(flow.accountEmail, "second@example.invalid")
        XCTAssertNil(flow.errorMessage)
        XCTAssertNil(flow.provider)
        XCTAssertFalse(flow.showsChallenge)
    }

    func testPastedCodeAcceptsSeparatorsButNeverUnicodeDigitsOrMoreThanSixDigits() {
        XCTAssertEqual(VerificationCode.normalized("123 456"), "123456")
        XCTAssertEqual(VerificationCode.normalized("12-34\n56"), "123456")
        XCTAssertEqual(VerificationCode.normalized("۱۲۳abc1234567"), "")
        XCTAssertEqual(VerificationCode.normalized("1234567"), "")
        XCTAssertEqual(VerificationCode.normalized("Call 42; code 123456"), "")
        XCTAssertEqual(VerificationCode.normalized("123"), "123")
        XCTAssertEqual(VerificationCode.normalized("hello"), "")
    }
    func testSMSChallengeUsesPhoneWordingAndRetainsCodeEntryOnRejection() {
        var flow = AuthenticationFlow()
        flow.begin(accountEmail: "fixture@example.invalid")
        flow.receiveChallenge(TwoFactorDetails(unknown: false, sms: true, numbers: nil, selectedNumberId: 7, lastError: nil))
        XCTAssertTrue(flow.message.contains("SMS"))
        XCTAssertTrue(flow.canSubmitCode)
        XCTAssertTrue(flow.beginChallengeAction(.verifying))
        flow.receiveChallenge(TwoFactorDetails(unknown: false, sms: true, numbers: nil, selectedNumberId: 7, lastError: "Incorrect code"))
        XCTAssertTrue(flow.canSubmitCode)
        XCTAssertEqual(flow.challenge?.selectedNumberId, 7)
        XCTAssertEqual(flow.errorMessage, "Incorrect code")
    }

}
