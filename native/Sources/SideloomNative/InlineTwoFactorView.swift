import SwiftUI

/// The verification step lives with the credentials so its context never disappears mid-request.
struct InlineTwoFactorView: View {
    @Binding var code: String
    let flow: AuthenticationFlow
    let onSubmit: (String) -> Void
    let onResend: () -> Void
    let onCancel: () -> Void
    let onChooseMethod: (UInt32?) -> Void
    @FocusState private var isCodeFocused: Bool

    private var isBusy: Bool { flow.phase.isActive && !flow.canRespondToChallenge }
    private var details: TwoFactorDetails? { flow.challenge }
    private var destination: String {
        if details?.sms == true {
            if let selectedID = details?.selectedNumberId,
               let number = details?.numbers?.first(where: { $0.id == selectedID }) {
                return "Enter the code sent to \(number.displayNumber)."
            }
            return "Enter the code sent to your trusted phone."
        }
        return "Enter the six-digit code from your iPhone, iPad, or Mac."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if details?.unknown == true {
                Text("Choose where Apple should send your code.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    if details?.sms != true {
                        Button("Send to Trusted Apple Devices") { onChooseMethod(nil) }
                    }
                    ForEach(details?.numbers ?? []) { number in
                        Button("Send SMS to \(number.displayNumber)") { onChooseMethod(number.id) }
                    }
                }
                .disabled(!flow.canRespondToChallenge)
            } else {
                HStack(spacing: 10) {
                    TextField("6-digit code", text: $code)
                        .textContentType(.oneTimeCode)
                        .font(.body.monospacedDigit())
                        .textFieldStyle(.roundedBorder)
                        .focused($isCodeFocused)
                        .disabled(!flow.canSubmitCode)
                        .accessibilityLabel("Apple verification code")
                        .accessibilityHint("Paste or enter the six-digit code, then press Return to verify.")
                        .onSubmit(submitCode)
                        .onChange(of: code) { _, value in
                            let normalized = VerificationCode.normalized(value)
                            if normalized != value { code = normalized }
                        }
                    Button("Verify", action: submitCode)
                        .buttonStyle(.bordered)
                        .foregroundStyle(.primary)
                        .disabled(!flow.canSubmitCode || code.count != 6)
                }
                Text(destination)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let message = flow.errorMessage, !message.isEmpty {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let step = flow.failedStep, flow.phase == .failed {
                    Text("\(step). \(flow.retryable ? "You can try signing in again." : "Review the message above before trying again.")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                if isBusy {
                    ProgressView().controlSize(.small)
                    Text(flow.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(flow.message)
                } else if details?.unknown != true && flow.phase != .failed {
                    Button("Resend Code", action: onResend)
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .disabled(!flow.canRespondToChallenge)
                }
                Spacer(minLength: 8)
                Button(flow.phase == .failed ? "Dismiss" : "Cancel Sign-In", action: onCancel)
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: focusCode)
        .onChange(of: flow.challengeSequence) { _, _ in focusCode() }
        .onChange(of: flow.canSubmitCode) { _, canSubmit in
            if canSubmit { focusCode() } else { isCodeFocused = false }
        }
    }

    private func submitCode() {
        let normalized = VerificationCode.normalized(code)
        guard flow.canSubmitCode, normalized.count == 6 else { return }
        onSubmit(normalized)
    }

    private func focusCode() {
        guard flow.canSubmitCode else { return }
        // Focus after SwiftUI attaches the newly inserted native text field.
        Task { @MainActor in
            await Task.yield()
            isCodeFocused = true
        }
    }
}
