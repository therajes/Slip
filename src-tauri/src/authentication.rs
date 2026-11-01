//! Slip's authentication coordinator. Protocol/crypto operations remain in isideload;
//! lifecycle, recovery policy, provider boundaries and session persistence live here.
use crate::error::AppError;
use isideload::{
    auth::apple_account::AppleAccount,
    dev::developer_session::{DeveloperSession, TeamsApi},
};
use serde::Serialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::Duration,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum Stage {
    Preparing,
    CheckingSession,
    SigningIn,
    AwaitingCode,
    VerifyingCode,
    FinalizingAccount,
    RequestingDeveloperSession,
    CheckingDeveloperAccess,
    SignedIn,
}

impl Stage {
    fn description(self) -> &'static str {
        match self {
            Self::Preparing => "preparing Apple authentication",
            Self::CheckingSession => "checking the saved Apple session",
            Self::SigningIn => "signing in to Apple",
            Self::AwaitingCode | Self::VerifyingCode => "verifying the two-factor code",
            Self::FinalizingAccount => "finishing Apple sign-in after code acceptance",
            Self::RequestingDeveloperSession => {
                "obtaining the Apple Developer session after sign-in"
            }
            Self::CheckingDeveloperAccess => "checking Apple Developer account access",
            Self::SignedIn => "finishing sign-in",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum FailureKind {
    Cancelled,
    Throttled,
    Restricted,
    InvalidCredentials,
    InvalidCode,
    SessionExpired,
    ProviderUnavailable,
    Transport,
    DeveloperAccess,
    Other,
}
impl FailureKind {
    fn code(self) -> &'static str {
        match self {
            Self::Cancelled => "cancelled",
            Self::Throttled => "rateLimited",
            Self::Restricted => "accountRestricted",
            Self::InvalidCredentials => "invalidCredentials",
            Self::InvalidCode => "invalidVerificationCode",
            Self::SessionExpired => "sessionExpired",
            Self::ProviderUnavailable => "providerUnavailable",
            Self::Transport => "serviceUnavailable",
            Self::DeveloperAccess => "developerAccess",
            Self::Other => "authenticationFailed",
        }
    }
    pub(crate) fn retryable(self) -> bool {
        self == Self::Transport
    }
}

pub(crate) fn failure_kind(error: &AppError) -> FailureKind {
    let text = error.to_string().to_ascii_lowercase();
    if matches!(error, AppError::Canceled(_))
        || text.contains("no 2fa code provided, aborting")
        || text.contains("no 2fa method selected, aborting")
        || text.contains("two-factor verification was canceled")
        || text.contains("two-factor verification was cancelled")
        || text.contains("native app closed the request")
    {
        return FailureKind::Cancelled;
    }
    if text.contains("429")
        || text.contains("too many")
        || text.contains("-22979")
        || text.contains("-22981")
    {
        return FailureKind::Throttled;
    }
    if matches!(error, AppError::AccountLocked(_) | AppError::Underage(_))
        || text.contains("additional authentication")
    {
        return FailureKind::Restricted;
    }
    if text.contains("1100")
        || (text.contains("session") && (text.contains("expired") || text.contains("invalid")))
    {
        return FailureKind::SessionExpired;
    }
    if text.contains("-21669") {
        return FailureKind::InvalidCode;
    }
    if text.contains("this mac authentication") || text.contains("-80045") {
        return FailureKind::ProviderUnavailable;
    }
    // Explicit Apple authentication rejections must never turn into password/code replays.
    if matches!(error, AppError::Auth(_)) {
        return FailureKind::InvalidCredentials;
    }
    if matches!(error, AppError::Developer(_)) {
        return FailureKind::DeveloperAccess;
    }
    if text.contains("timed out")
        || text.contains("timeout")
        || text.contains("connection reset")
        || text.contains("connection refused")
        || text.contains("connect error")
        || text.contains("error sending request")
        || text.contains("dns error")
        || text.contains("websocket")
        || text.contains("502")
        || text.contains("503")
        || text.contains("504")
    {
        return FailureKind::Transport;
    }
    if matches!(error, AppError::Anisette(_)) {
        return FailureKind::ProviderUnavailable;
    }
    FailureKind::Other
}

/// At most three attempts. Only transport/service failures of safe operations qualify.
/// Verification submissions, SMS sends, password rejections and provisioning mutations
/// never use this policy automatically.
#[derive(Clone, Copy)]
pub(crate) struct RecoveryPolicy {
    pub max_attempts: u32,
}
impl Default for RecoveryPolicy {
    fn default() -> Self {
        Self { max_attempts: 3 }
    }
}
impl RecoveryPolicy {
    pub(crate) fn delay(self, completed_attempts: u32, error: &AppError) -> Option<Duration> {
        (completed_attempts < self.max_attempts && failure_kind(error).retryable())
            .then(|| Duration::from_millis(500 * u64::from(completed_attempts.max(1))))
    }
}

type Observer = Arc<dyn Fn(Value) + Send + Sync>;
#[derive(Clone)]
pub(crate) struct AuthenticationFlow {
    stage: Arc<Mutex<Stage>>,
    provider: String,
    observer: Observer,
}
impl AuthenticationFlow {
    pub(crate) fn new(provider: &str, observer: impl Fn(Value) + Send + Sync + 'static) -> Self {
        Self {
            stage: Arc::new(Mutex::new(Stage::Preparing)),
            provider: provider.into(),
            observer: Arc::new(observer),
        }
    }
    pub(crate) fn transition(&self, stage: Stage, message: &str) {
        *self.stage.lock().unwrap_or_else(|p| p.into_inner()) = stage;
        (self.observer)(
            json!({"type":"authenticationState", "stage":stage, "message":message, "provider":self.provider}),
        );
    }
    pub(crate) async fn recover(&self, attempt: u32, error: &AppError) -> bool {
        let Some(delay) = RecoveryPolicy::default().delay(attempt, error) else {
            return false;
        };
        let stage = *self.stage.lock().unwrap_or_else(|p| p.into_inner());
        (self.observer)(json!({"type":"authenticationState", "stage":stage,
            "message":format!("Connection interrupted while {}. Retrying…", stage.description()),
            "provider":self.provider, "attempt":attempt+1, "maxAttempts":3, "retryable":true}));
        tokio::time::sleep(delay).await;
        true
    }
    /// Emits only generated/sanitized text, never a raw Apple response or error chain.
    pub(crate) fn fail(&self, error: AppError) -> AppError {
        let stage = *self.stage.lock().unwrap_or_else(|p| p.into_inner());
        let kind = failure_kind(&error);
        let message = match kind {
            FailureKind::Cancelled => "Sign-in was cancelled.".into(),
            FailureKind::Throttled => "Apple is limiting sign-in or verification requests. Wait a few minutes before trying again; requesting more codes can extend the delay.".into(),
            FailureKind::Restricted => "Apple requires an account security or eligibility step. Check your account at account.apple.com and the Developer Agreement at developer.apple.com.".into(),
            FailureKind::InvalidCode => "Apple rejected the verification code. Enter the latest six-digit code.".into(),
            FailureKind::SessionExpired => "Your Apple Developer session expired. Enter your Apple Account password to sign in again.".into(),
            FailureKind::ProviderUnavailable if self.provider == "local" => {
                // Local capability messages are sanitized at the helper boundary.
                let detail = if let AppError::Anisette(detail) = &error { detail.as_str() } else { "This Mac authentication is unavailable." };
                format!("{detail} Slip has not contacted a remote authentication provider. Choose Remote compatibility explicitly if you want to use it.")
            },
            FailureKind::ProviderUnavailable => "The selected authentication provider could not prepare this sign-in. Check its address or choose another provider explicitly in Apple Accounts.".into(),
            FailureKind::Transport => format!("A connection or service failure occurred while {}. Slip kept the selected authentication provider. Try again in a moment.", stage.description()),
            FailureKind::InvalidCredentials if stage == Stage::SigningIn => "Apple rejected the sign-in. Check your Apple Account email and password.".into(),
            _ if stage == Stage::RequestingDeveloperSession => "Apple Account verification completed, but Apple did not provide a Developer session. Try again later and check the Developer Agreement at developer.apple.com.".into(),
            _ if stage == Stage::CheckingDeveloperAccess => "Apple sign-in completed, but Developer account access could not be confirmed. Sign in at developer.apple.com to check your free Personal Team and accept any agreement.".into(),
            _ => format!("Sign-in could not finish while {}. Try again or check your Apple Account settings.", stage.description()),
        };
        (self.observer)(
            json!({"type":"authenticationState", "stage":if kind == FailureKind::Cancelled {"cancelled"} else {"failed"},
            "failedStage":stage, "message":message, "provider":self.provider, "code":kind.code(), "retryable":kind.retryable()}),
        );
        if kind == FailureKind::Cancelled {
            AppError::Canceled("Apple sign-in".into())
        } else {
            AppError::Misc(message)
        }
    }
    pub(crate) fn cache_warning(&self) {
        (self.observer)(
            json!({"type":"authenticationWarning", "message":"Signed in, but the session could not be saved securely in Keychain. You may need to sign in again next time.","code":"sessionNotSaved"}),
        );
    }
}

/// Keep the same account and anisette identity after 2FA. Obtaining xcode.auth and
/// listing teams are safe to retry; restarting account.login here would ask for 2FA again.
pub(crate) async fn retry_safe_step<C, T>(
    context: &mut C,
    flow: &AuthenticationFlow,
    operation: for<'a> fn(&'a mut C) -> futures::future::BoxFuture<'a, Result<T, AppError>>,
) -> Result<T, AppError> {
    let mut attempt = 0;
    loop {
        attempt += 1;
        match operation(context).await {
            Ok(value) => return Ok(value),
            Err(error) => {
                if !flow.recover(attempt, &error).await {
                    return Err(error);
                }
            }
        }
    }
}

fn request_developer_session(
    account: &mut AppleAccount,
) -> futures::future::BoxFuture<'_, Result<DeveloperSession, AppError>> {
    Box::pin(async {
        DeveloperSession::from_account(account)
            .await
            .map_err(AppError::from)
    })
}
fn check_developer_access(
    session: &mut DeveloperSession,
) -> futures::future::BoxFuture<'_, Result<(), AppError>> {
    Box::pin(async {
        let teams = session.list_teams().await.map_err(AppError::from)?;
        if teams.is_empty() {
            return Err(AppError::Developer("No Personal Team or Developer team is available. Sign in at developer.apple.com and accept the Developer Agreement.".into()));
        }
        Ok(())
    })
}

pub(crate) async fn developer_session(
    account: &mut AppleAccount,
    flow: &AuthenticationFlow,
) -> Result<DeveloperSession, AppError> {
    flow.transition(
        Stage::RequestingDeveloperSession,
        "Apple verification completed. Preparing your Developer session…",
    );
    let mut session = retry_safe_step(account, flow, request_developer_session).await?;
    validate_session(&mut session, flow).await?;
    Ok(session)
}

pub(crate) async fn validate_session(
    session: &mut DeveloperSession,
    flow: &AuthenticationFlow,
) -> Result<(), AppError> {
    #[cfg(target_os = "macos")]
    if flow.provider == "local" {
        session.set_developer_client_info(
            isideload::util::host_identity::host_identity().developer_authentication_description(),
        );
    }
    flow.transition(
        Stage::CheckingDeveloperAccess,
        "Checking your Apple Developer account…",
    );
    retry_safe_step(session, flow, check_developer_access).await
}

pub(crate) fn provider_identity(mode: &str, url: &str) -> String {
    if mode == "local" {
        "local-macos".into()
    } else {
        format!("remote:{url}")
    }
}
pub(crate) fn provider_storage(storage: &str, identity: &str) -> PathBuf {
    Path::new(storage).join("authentication").join(
        Sha256::digest(identity.as_bytes())
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn never_retry_account_rejections_or_throttling() {
        for error in [
            AppError::Auth("-21669 wrong code".into()),
            AppError::Auth("invalid credentials".into()),
            AppError::Auth("-80045 anisette".into()),
            AppError::Misc("HTTP 429".into()),
            AppError::AccountLocked("locked".into()),
            AppError::Underage("restricted".into()),
        ] {
            assert!(
                RecoveryPolicy::default().delay(1, &error).is_none(),
                "{error}"
            );
        }
    }
    #[test]
    fn retry_exhaustion_is_failure_while_explicit_abort_is_cancellation() {
        assert_ne!(
            failure_kind(&AppError::Misc(
                "Couldn't login after 15 attempts, aborting".into()
            )),
            FailureKind::Cancelled
        );
        assert_eq!(
            failure_kind(&AppError::Misc("No 2FA code provided, aborting".into())),
            FailureKind::Cancelled
        );
        assert_eq!(
            failure_kind(&AppError::Misc("No 2FA method selected, aborting".into())),
            FailureKind::Cancelled
        );
    }
    #[test]
    fn transport_recovery_is_bounded() {
        let error = AppError::Misc("HTTP 503".into());
        assert!(RecoveryPolicy::default().delay(1, &error).is_some());
        assert!(RecoveryPolicy::default().delay(2, &error).is_some());
        assert!(RecoveryPolicy::default().delay(3, &error).is_none());
    }
    #[test]
    fn failures_preserve_post_verification_stage_without_raw_error() {
        let events = Arc::new(Mutex::new(Vec::new()));
        let output = events.clone();
        let flow =
            AuthenticationFlow::new("local", move |event| output.lock().unwrap().push(event));
        flow.transition(Stage::RequestingDeveloperSession, "Preparing session");
        let error = flow.fail(AppError::Misc(
            "HTTP 503 <token>secret-fixture</token>".into(),
        ));
        let events = events.lock().unwrap();
        assert_eq!(events[1]["failedStage"], "requestingDeveloperSession");
        assert_eq!(events[1]["code"], "serviceUnavailable");
        assert!(
            !serde_json::to_string(&*events)
                .unwrap()
                .contains("secret-fixture")
        );
        assert!(!error.to_string().contains("secret-fixture"));
    }
    struct MockStep {
        responses: std::collections::VecDeque<Result<u32, AppError>>,
        calls: usize,
        addresses: Vec<usize>,
    }
    fn mock_step(context: &mut MockStep) -> futures::future::BoxFuture<'_, Result<u32, AppError>> {
        Box::pin(async move {
            context.calls += 1;
            context.addresses.push(context as *const MockStep as usize);
            context.responses.pop_front().expect("unexpected retry")
        })
    }
    #[tokio::test]
    async fn developer_step_recovers_in_the_same_context_without_restarting_sign_in() {
        let events = Arc::new(Mutex::new(Vec::new()));
        let output = events.clone();
        let flow =
            AuthenticationFlow::new("remote", move |event| output.lock().unwrap().push(event));
        flow.transition(
            Stage::RequestingDeveloperSession,
            "Preparing Developer session",
        );
        let mut context = MockStep {
            responses: [Err(AppError::Misc("HTTP 503".into())), Ok(42)].into(),
            calls: 0,
            addresses: vec![],
        };
        assert_eq!(
            retry_safe_step(&mut context, &flow, mock_step)
                .await
                .unwrap(),
            42
        );
        assert_eq!(context.calls, 2);
        assert_eq!(context.addresses[0], context.addresses[1]);
        let events = events.lock().unwrap();
        assert!(
            events
                .iter()
                .all(|event| event["stage"] == "requestingDeveloperSession")
        );
        assert_eq!(events[1]["attempt"], 2);
    }
    #[tokio::test]
    async fn developer_step_stops_on_rate_limit_without_retrying_or_resetting_context() {
        let flow = AuthenticationFlow::new("remote", |_| {});
        let mut context = MockStep {
            responses: [Err(AppError::Misc("HTTP 429".into())), Ok(42)].into(),
            calls: 0,
            addresses: vec![],
        };
        assert!(
            retry_safe_step(&mut context, &flow, mock_step)
                .await
                .is_err()
        );
        assert_eq!(context.calls, 1);
    }
    #[tokio::test]
    async fn developer_step_stops_after_three_transport_failures() {
        let flow = AuthenticationFlow::new("remote", |_| {});
        let mut context = MockStep {
            responses: (0..3)
                .map(|_| Err(AppError::Misc("connection reset".into())))
                .collect(),
            calls: 0,
            addresses: vec![],
        };
        assert!(
            retry_safe_step(&mut context, &flow, mock_step)
                .await
                .is_err()
        );
        assert_eq!(context.calls, 3);
    }
    #[test]
    fn developer_descriptor_preserves_remote_hardware_and_os() {
        use isideload::dev::developer_session::developer_authentication_description;
        let provider =
            "<PC> <Windows;6.2(0,0);9200> <com.apple.AuthKit/1 (com.apple.iTunes/12.12.4.1)>";
        assert_eq!(
            developer_authentication_description(provider),
            "<PC> <Windows;6.2(0,0);9200> <com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>"
        );
        assert_eq!(
            developer_authentication_description("<fixture-device> <fixture-os>"),
            "<fixture-device> <fixture-os>"
        );
    }
    #[test]
    fn providers_have_separate_state_directories() {
        assert_ne!(
            provider_storage("fixture", &provider_identity("remote", "https://a.example")),
            provider_storage("fixture", &provider_identity("remote", "https://b.example"))
        );
        assert_ne!(
            provider_storage("fixture", &provider_identity("local", "")),
            provider_storage("fixture", &provider_identity("remote", "https://a.example"))
        );
    }
}
