use std::{
    io::{BufRead, BufReader, Write},
    path::PathBuf,
    sync::{Arc, Mutex},
    time::{SystemTime, UNIX_EPOCH},
};

use base64::{Engine as _, engine::general_purpose::STANDARD};
use futures::FutureExt;
use idevice::{
    IdeviceService, installation_proxy::InstallationProxyClient,
    springboardservices::SpringBoardServicesClient,
};
use isideload::{
    anisette::remote_v3::RemoteV3AnisetteProvider,
    auth::apple_account::{AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse},
    dev::{
        certificates::DevelopmentCertificate,
        developer_session::{
            AppIdsApi, CertificatesApi, DeveloperDeviceType, DeveloperSession, DevicesApi, TeamsApi,
        },
    },
    sideload::{SideloaderBuilder, builder::MaxCertsBehavior},
    util::{device::IdeviceInfo, fs_storage::FsStorage, storage::SideloadingStorage},
};
use rootcause::prelude::*;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::{
    authentication::{self, AuthenticationFlow, Stage},
    certificate_management,
    device::{DeviceInfo, enable_wifi_debugging, get_provider, list_devices},
    error::AppError,
    fast_install::install_signed_app_fast_with_progress,
    ipa::{IpaInstallOptions, export_prepared_ipa, extract_ipa_icon, inspect_ipa, prepare_ipa_in},
    session_store,
};

type Input = Arc<Mutex<BufReader<std::io::Stdin>>>;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct InstallRequest {
    #[serde(default = "default_authentication_mode")]
    authentication_mode: String,
    email: String,
    password: String,
    anisette_server: String,
    storage_path: String,
    device: DeviceInfo,
    options: IpaInstallOptions,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ExportRequest {
    destination: String,
    options: IpaInstallOptions,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct LoginAccountRequest {
    #[serde(default = "default_authentication_mode")]
    authentication_mode: String,
    #[serde(alias = "appleId")]
    email: String,
    password: String,
    anisette_server: String,
    storage_path: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AccountResourceRequest {
    #[serde(flatten)]
    account: LoginAccountRequest,
    serial_number: Option<String>,
    serial_numbers: Option<Vec<String>>,
    expected_serial_numbers: Option<Vec<String>>,
    app_id_id: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct UninstallAppsRequest {
    device: DeviceInfo,
    bundle_ids: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PromptResponse {
    code: Option<String>,
    serials: Option<Vec<String>>,
    cancel: Option<bool>,
    resend: Option<bool>,
    number_id: Option<u32>,
    send_to_devices: Option<bool>,
}

fn default_authentication_mode() -> String {
    "remote".to_string()
}

fn validate_authentication_mode(mode: &str) -> Result<(), AppError> {
    if mode != "local" && mode != "remote" {
        return Err(AppError::Auth(
            "Choose This Mac or Remote compatibility in Apple Accounts.".into(),
        ));
    }
    Ok(())
}

fn effective_authentication_mode(requested: &str, local_available: bool) -> Result<&str, AppError> {
    validate_authentication_mode(requested)?;
    if requested == "local" && !local_available {
        return Err(AppError::Anisette("This Mac authentication is unavailable. Choose Remote compatibility explicitly if you want to use a remote provider.".into()));
    }
    Ok(requested)
}

fn configured_provider_url(configured: &str) -> Result<String, AppError> {
    let configured = configured.trim();
    if configured.is_empty() {
        return Err(AppError::Anisette(
            "Choose a remote authentication provider address in Apple Accounts.".into(),
        ));
    }
    let with_scheme = if configured.contains("://") {
        configured.to_owned()
    } else {
        format!("https://{configured}")
    };
    let mut parsed = reqwest::Url::parse(&with_scheme).map_err(|_| {
        AppError::Anisette("The selected authentication provider address is invalid.".into())
    })?;
    if !matches!(parsed.scheme(), "https" | "http")
        || parsed.host_str().is_none()
        || !parsed.username().is_empty()
        || parsed.password().is_some()
        || parsed.query().is_some()
        || parsed.fragment().is_some()
    {
        return Err(AppError::Anisette("Use a plain HTTPS authentication provider address without credentials or query parameters.".into()));
    }
    if parsed.scheme() == "http"
        && !matches!(
            parsed.host_str(),
            Some("localhost" | "127.0.0.1" | "[::1]" | "::1")
        )
    {
        return Err(AppError::Anisette("Remote authentication requires HTTPS. HTTP is available only for a provider on this Mac.".into()));
    }
    let path = parsed.path().trim_end_matches('/').to_owned();
    parsed.set_path(&path);
    Ok(parsed.as_str().trim_end_matches('/').to_owned())
}

fn emit(value: Value) {
    let stdout = std::io::stdout();
    let mut output = stdout.lock();
    let _ = serde_json::to_writer(&mut output, &value);
    let _ = writeln!(output);
    let _ = output.flush();
}

pub fn emit_fatal(message: &str) {
    emit(json!({ "type": "error", "message": message }));
}

fn emit_progress(stage: &str, value: f32, message: &str) {
    emit(json!({
        "type": "progress",
        "stage": stage,
        "value": value.clamp(0.0, 1.0),
        "message": message,
    }));
}

fn read_json<T: for<'de> Deserialize<'de>>(input: &Input) -> Result<T, AppError> {
    let mut line = String::new();
    input
        .lock()
        .map_err(|_| AppError::Misc("Core input lock failed".into()))?
        .read_line(&mut line)
        .map_err(|error| AppError::Misc(format!("Unable to read native app response: {error}")))?;
    if line.trim().is_empty() {
        return Err(AppError::Canceled("Native app closed the request".into()));
    }
    serde_json::from_str(&line)
        .map_err(|error| AppError::Misc(format!("Invalid native app response: {error}")))
}

fn storage(path: &str) -> Result<Box<dyn SideloadingStorage>, AppError> {
    let path = PathBuf::from(path);
    std::fs::create_dir_all(&path).map_err(|error| {
        AppError::Filesystem("Unable to create core storage".into(), error.to_string())
    })?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).map_err(
            |error| {
                AppError::Filesystem("Unable to protect core storage".into(), error.to_string())
            },
        )?;
    }
    Ok(Box::new(FsStorage::new(path)))
}

fn get_machine_name() -> String {
    isideload::util::host_identity::host_identity()
        .computer_name
        .clone()
}

async fn install(request: InstallRequest, input: Input) -> Result<(), AppError> {
    let ipa = inspect_ipa(request.options.app_path.clone())?;
    if ipa.encryption_status == "Encrypted" {
        return Err(AppError::Misc("This IPA contains an encrypted App Store executable. Choose a decrypted IPA that you are authorized to install; encrypted apps cannot be re-signed.".into()));
    }
    emit_progress("account", 0.0, "Authenticating with Apple");

    let make_max_certs = |cert_input: Input| {
        move |certificates: &Vec<DevelopmentCertificate>| {
            let details: Vec<_> = certificates
                .iter()
                .map(|certificate| {
                    json!({
                        "name": certificate.name,
                        "serialNumber": certificate.serial_number,
                        "machineName": certificate.machine_name,
                    })
                })
                .collect();
            let available: Vec<String> = certificates
                .iter()
                .filter_map(|certificate| certificate.serial_number.clone())
                .collect();
            let mut message: Option<String> = None;
            loop {
                emit(
                    json!({ "type": "certificateSelectionRequired", "certificates": details, "message":message }),
                );
                let response: PromptResponse = read_json(&cert_input).ok()?;
                if response.cancel.unwrap_or(false) {
                    return None;
                }
                match certificate_management::validate_selection(
                    &response.serials.unwrap_or_default(),
                    &available,
                    Some(&available),
                ) {
                    Ok(selected) => return Some(selected),
                    Err(error) => message = Some(error.human_message()),
                }
            }
        }
    };

    let account_request = LoginAccountRequest {
        authentication_mode: request.authentication_mode.clone(),
        email: request.email.clone(),
        password: request.password.clone(),
        anisette_server: request.anisette_server.clone(),
        storage_path: request.storage_path.clone(),
    };
    let developer_session = authenticated_session(&account_request, input.clone(), true).await?;
    let mut sideloader =
        SideloaderBuilder::new(developer_session, request.email.trim().to_lowercase())
            .machine_name(get_machine_name())
            .storage(storage(&request.storage_path)?)
            .max_certs_behavior(MaxCertsBehavior::Prompt(Box::new(make_max_certs(
                input.clone(),
            ))))
            .build();

    emit_progress("prepare", 0.0, "Preparing IPA");
    let prepared = prepare_ipa_in(&std::env::temp_dir(), &request.options)?;
    emit_progress("prepare", 1.0, "IPA prepared");
    let result: Result<(), AppError> = async {
        emit_progress("sign", 0.01, "Registering device");
        let provider = get_provider(&request.device).await?;
        let team = sideloader.get_team().await.map_err(|e| {
            let err_str = e.to_string();
            let lower = err_str.to_lowercase();
            if lower.contains("1100") || (lower.contains("session") && lower.contains("expired")) {
                session_store::invalidate_stored(&request.storage_path);
            }
            AppError::from(e)
        })?;
        let device = IdeviceInfo::from_device(&provider)
            .await
            .unwrap_or_else(|_| {
                IdeviceInfo::new(request.device.name.clone(), request.device.udid.clone())
            });
        sideloader
            .get_dev_session()
            .ensure_device_registered(&team, &device.name, &device.udid, None)
            .await
            .map_err(AppError::from)?;

        let (signed_app, _) = sideloader
            .sign_app(
                prepared.clone(),
                Some(team),
                request.options.increased_memory_limit,
                Some(|progress| async move {
                    emit_progress("sign", progress, "Signing app");
                }),
            )
            .await
            .map_err(AppError::from)?;
        emit_progress("sign", 1.0, "App signed");

        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let optimized = std::env::temp_dir().join(format!(
            "sideloom-native-{}-{unique}.ipa",
            std::process::id()
        ));
        let mut install_result = Err(AppError::Misc("Installation did not start".into()));
        for attempt in 1..=4 {
            let provider = match get_provider(&request.device).await {
                Ok(provider) => provider,
                Err(error) => {
                    install_result = Err(error);
                    if attempt < 4 {
                        emit_progress(
                            "install",
                            0.01,
                            &format!("Waiting for iPhone — retry {attempt} of 4"),
                        );
                        tokio::time::sleep(std::time::Duration::from_secs(attempt * 2)).await;
                        continue;
                    }
                    break;
                }
            };
            install_result = install_signed_app_fast_with_progress(
                &provider,
                &signed_app,
                &optimized,
                move |progress| {
                    emit_progress(
                        "install",
                        progress,
                        &format!("Installing on iPhone — attempt {attempt} of 4"),
                    )
                },
            )
            .await;
            if install_result.is_ok() {
                break;
            }
            if attempt < 4 {
                emit_progress(
                    "install",
                    0.01,
                    &format!("Connection interrupted — retrying ({attempt}/4)"),
                );
                tokio::time::sleep(std::time::Duration::from_secs(attempt * 2)).await;
            }
        }
        let _ = std::fs::remove_dir_all(&signed_app);
        let _ = std::fs::remove_file(&optimized);
        install_result
    }
    .await;
    let _ = std::fs::remove_file(prepared);
    result?;
    emit(json!({ "type": "completed" }));
    Ok(())
}

fn session_expired(error: &AppError) -> bool {
    let lower = error.to_string().to_lowercase();
    lower.contains("1100") || (lower.contains("session") && lower.contains("expired"))
}

#[cfg(test)]
fn retryable_auth_transport(error: &AppError) -> bool {
    authentication::failure_kind(error) == authentication::FailureKind::Transport
}

#[cfg(test)]
mod host_identity_tests {
    use isideload::util::host_identity::HostIdentity;

    #[test]
    fn real_mac_identity_is_used_in_both_authentication_descriptors() {
        let host = HostIdentity::from_system_values(
            "macos",
            Some("  Renée’s MacBook Air  "),
            Some("Mac16,12"),
            Some("26.0"),
            Some("25A354"),
        );
        assert_eq!(host.computer_name, "Renée’s MacBook Air");
        let prefix = "<Mac16,12> <macOS;26.0;25A354>";
        assert!(host.authentication_description.starts_with(prefix));
        assert!(
            host.developer_authentication_description()
                .starts_with(prefix)
        );
        assert!(
            host.developer_authentication_description()
                .contains("com.apple.dt.Xcode/3594.4.19")
        );
        let payload = serde_json::to_value(&host).unwrap();
        assert_eq!(payload["computerName"], host.computer_name);
        assert_eq!(
            payload["authenticationDescription"],
            host.authentication_description
        );
    }

    #[test]
    fn unexpected_system_values_cannot_inject_authentication_headers() {
        let host = HostIdentity::from_system_values(
            "macos",
            Some("Mac 👋"),
            Some("Mac16,12>\r\n<Injected"),
            Some("26;fake"),
            Some("[25A]"),
        );
        assert_eq!(host.model_identifier, "Mac16,12Injected");
        assert_eq!(host.os_version, "26fake");
        assert_eq!(host.os_build, "25A");
        assert_eq!(host.computer_name, "Mac 👋");
        assert_eq!(host.authentication_description.matches('<').count(), 3);
        reqwest::header::HeaderValue::from_str(&host.authentication_description).unwrap();
        reqwest::header::HeaderValue::from_str(&host.developer_authentication_description())
            .unwrap();
    }

    #[test]
    fn missing_system_values_are_honest_about_unknown_hardware() {
        let host = HostIdentity::from_system_values("linux", Some("  "), Some("<>"), None, None);
        assert_eq!(host.model_identifier, "linux-host");
        assert_eq!(host.computer_name, "linux-host");
        assert!(
            host.authentication_description
                .starts_with("<linux-host> <linux;Unknown;Unknown>")
        );
    }
}

#[cfg(test)]
mod authentication_mode_tests {
    use super::*;
    #[test]
    fn local_mode_never_silently_switches_provider() {
        assert_eq!(
            effective_authentication_mode("local", true).unwrap(),
            "local"
        );
        assert!(effective_authentication_mode("local", false).is_err());
        assert_eq!(
            effective_authentication_mode("remote", false).unwrap(),
            "remote"
        );
        assert!(effective_authentication_mode("automatic", true).is_err());
    }
    #[test]
    fn remote_mode_requires_explicit_valid_provider() {
        assert!(configured_provider_url("").is_err());
        assert!(configured_provider_url("http://untrusted.example").is_err());
        assert!(configured_provider_url("https://user:password@a.example").is_err());
        assert_eq!(
            configured_provider_url("https://EXAMPLE.com/").unwrap(),
            "https://example.com"
        );
        assert_eq!(
            configured_provider_url("http://localhost:6969/").unwrap(),
            "http://localhost:6969"
        );
    }
    #[test]
    fn legacy_request_mode_is_preserved_but_has_no_hidden_server_default() {
        let request: LoginAccountRequest = serde_json::from_value(json!({"email":"fixture@invalid.local","password":"fixture","anisetteServer":"","storagePath":"fixture"})).unwrap();
        assert_eq!(request.authentication_mode, "remote");
        assert!(configured_provider_url(&request.anisette_server).is_err());
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn native_helper_errors_are_sanitized() {
        use isideload::anisette::local_macos::parse_helper_data;
        let error = parse_helper_data(br#"{"error":"sensitive-helper-message"}"#).unwrap_err();
        assert!(!error.to_string().contains("sensitive-helper-message"));
    }
}

#[cfg(test)]
mod auth_recovery_tests {
    use super::*;

    #[test]
    fn credential_and_throttling_failures_do_not_trigger_fallback_login() {
        for error in [
            AppError::Auth("Incorrect password; anisette service responded".into()),
            AppError::AccountLocked("Account locked".into()),
            AppError::Underage("Account restricted".into()),
            AppError::Misc("Anisette HTTP 429 Too Many Requests".into()),
        ] {
            assert!(!retryable_auth_transport(&error), "{error}");
        }
        assert!(retryable_auth_transport(&AppError::Misc(
            "WebSocket connection reset".into()
        )));
    }

    #[test]
    fn transport_errors_do_not_invalidate_a_saved_session() {
        assert!(!session_expired(&AppError::Misc(
            "Connection timed out".into()
        )));
        assert!(session_expired(&AppError::Developer(
            "1100: session invalid".into()
        )));
    }

    #[test]
    fn resource_errors_preserve_recovery_instructions() {
        for message in [
            "Select a certificate to revoke.",
            "The selected certificate no longer belongs to this account. Refresh the list and select it again.",
            "The selected App ID no longer belongs to this account. Refresh the list and select it again.",
            "Apple cannot delete this App ID because it is in use.",
        ] {
            assert_eq!(AppError::Developer(message.into()).human_message(), message);
        }
    }
}

async fn authenticated_session(
    request: &LoginAccountRequest,
    input: Input,
    reuse_cached_session: bool,
) -> Result<DeveloperSession, AppError> {
    let flow = AuthenticationFlow::new(&request.authentication_mode, emit);
    flow.transition(Stage::Preparing, "Preparing Apple authentication…");
    match authenticated_session_inner(request, input, reuse_cached_session, &flow).await {
        Ok(session) => {
            flow.transition(
                Stage::SignedIn,
                "Apple Account and Developer session are ready.",
            );
            Ok(session)
        }
        Err(error) => Err(flow.fail(error)),
    }
}

async fn authenticated_session_inner(
    request: &LoginAccountRequest,
    input: Input,
    reuse_cached_session: bool,
    flow: &AuthenticationFlow,
) -> Result<DeveloperSession, AppError> {
    validate_authentication_mode(&request.authentication_mode)?;
    let email = request.email.trim().to_lowercase();
    if email.is_empty() || request.storage_path.trim().is_empty() {
        return Err(AppError::Auth(
            "Enter your Apple Account email and a valid storage location.".into(),
        ));
    }
    let (local_available, local_reason) = if request.authentication_mode == "local" {
        #[cfg(target_os = "macos")]
        {
            isideload::anisette::local_macos::local_authentication_status().await
        }
        #[cfg(not(target_os = "macos"))]
        {
            (
                false,
                Some("This Mac authentication requires macOS.".into()),
            )
        }
    } else {
        (false, None)
    };
    if request.authentication_mode == "local" && !local_available {
        return Err(AppError::Anisette(local_reason.unwrap_or_else(|| {
            "This Mac authentication is unavailable.".into()
        })));
    }
    let mode = effective_authentication_mode(&request.authentication_mode, local_available)?;
    let url = if mode == "remote" {
        configured_provider_url(&request.anisette_server)?
    } else {
        String::new()
    };
    let identity = authentication::provider_identity(mode, &url);
    let provider_storage = authentication::provider_storage(&request.storage_path, &identity);
    let provider_storage = provider_storage.to_string_lossy();
    let mut attempt = 0;
    let mut account = loop {
        attempt += 1;
        match account_for_mode(&email, &url, &provider_storage, mode).await {
            Ok(account) => break account,
            Err(error) => {
                if !flow.recover(attempt, &error).await {
                    return Err(error);
                }
            }
        }
    };
    if reuse_cached_session
        && let Some((token, adsid)) = session_store::load(&request.storage_path, &email, &identity)
    {
        flow.transition(Stage::CheckingSession, "Checking your saved Apple session…");
        let mut session = DeveloperSession::new(
            token,
            adsid,
            account.grandslam_client.clone(),
            account.anisette_generator.clone(),
        );
        match authentication::validate_session(&mut session, flow).await {
            Ok(()) => return Ok(session),
            Err(error) if session_expired(&error) => {
                session_store::invalidate(&request.storage_path, &email, &identity)
            }
            // Preserve a valid saved session during outages; never restart password/2FA
            // authentication just because team lookup encountered a transport error.
            Err(error) => return Err(error),
        }
    }
    if request.password.is_empty() {
        return Err(AppError::Developer("Your Apple Developer session expired. Enter your Apple Account password to sign in again.".into()));
    }
    emit_progress("account", 0.05, "Authenticating with Apple");
    flow.transition(Stage::SigningIn, "Signing in with Apple…");
    let callback_input = input.clone();
    let callback_flow = flow.clone();
    let callback = move |mut params: TwoFactorCallbackParams| {
        let input = callback_input.clone();
        let flow = callback_flow.clone();
        async move {
            loop {
                flow.transition(
                    Stage::AwaitingCode,
                    "Enter the verification code sent by Apple.",
                );
                emit(json!({"type":"twoFactorRequired", "details":params}));
                let response: PromptResponse = read_json(&input).map_err(|error| report!(error))?;
                if response.cancel.unwrap_or(false) {
                    return Ok(TwoFactorCallbackResponse::Abort);
                }
                if let Some(id) = response.number_id {
                    flow.transition(Stage::VerifyingCode, "Requesting a code by text message…");
                    return Ok(TwoFactorCallbackResponse::SendSms(id));
                }
                if response.send_to_devices.unwrap_or(false) {
                    flow.transition(
                        Stage::VerifyingCode,
                        "Requesting a code on your trusted devices…",
                    );
                    return Ok(TwoFactorCallbackResponse::SendToDevices);
                }
                if response.resend.unwrap_or(false) {
                    flow.transition(
                        Stage::VerifyingCode,
                        "Requesting another verification code…",
                    );
                    return Ok(TwoFactorCallbackResponse::ResendCode);
                }
                let code = response.code.unwrap_or_default().trim().to_owned();
                if code.len() != 6 || !code.bytes().all(|byte| byte.is_ascii_digit()) {
                    params.last_error =
                        Some("Enter the six-digit verification code from Apple.".into());
                    continue;
                }
                flow.transition(Stage::VerifyingCode, "Verifying your code with Apple…");
                return Ok(TwoFactorCallbackResponse::SubmitCode(code));
            }
        }
        .boxed()
    };
    let progress_flow = flow.clone();
    let account_progress = move |state| {
        if matches!(
            state,
            isideload::auth::apple_account::LoginState::NeedsLogin
        ) {
            progress_flow.transition(
                Stage::FinalizingAccount,
                "Code accepted. Finishing Apple sign-in…",
            );
        }
    };
    account
        .login_with_progress(&request.password, Box::new(callback), &account_progress)
        .await
        .map_err(AppError::from)?;
    let session = authentication::developer_session(&mut account, flow).await?;
    if session_store::save(
        &request.storage_path,
        &email,
        &identity,
        session.token.clone(),
        session.adsid.clone(),
    )
    .is_err()
    {
        // An unsuccessful replacement keeps the previous metadata and secret.
        flow.cache_warning();
    }
    if let Ok((first, last)) = account.get_name() {
        emit(
            json!({"type":"accountProfile", "email":email, "accountName":format!("{first} {last}").trim()}),
        );
    }
    Ok(session)
}

async fn login_account(request: LoginAccountRequest, input: Input) -> Result<(), AppError> {
    // Validate the entered password before replacing the saved Keychain credential.
    authenticated_session(&request, input, false).await?;
    emit(json!({ "type": "completed", "email": request.email.trim().to_lowercase() }));
    Ok(())
}

async fn account_resources(
    request: AccountResourceRequest,
    input: Input,
    command: &str,
) -> Result<(), AppError> {
    let selected = match command {
        "revoke-certificate" => vec![request.serial_number.clone().unwrap_or_default()],
        "revoke-certificates" => request.serial_numbers.clone().unwrap_or_default(),
        _ => Vec::new(),
    };
    let revoking = matches!(command, "revoke-certificate" | "revoke-certificates");
    if revoking && (selected.is_empty() || selected.iter().any(|serial| serial.trim().is_empty())) {
        return Err(AppError::Developer(
            "Select at least one certificate to revoke.".into(),
        ));
    }
    if command == "delete-app-id" && request.app_id_id.as_deref().unwrap_or("").trim().is_empty() {
        return Err(AppError::Developer("Select an App ID to delete.".into()));
    }
    let mut session = authenticated_session(&request.account, input, true).await?;
    let team = session.list_teams().await.map_err(AppError::from)?.into_iter().next()
        .ok_or_else(|| AppError::Developer("No developer teams available. Accept the Apple Developer Agreement at developer.apple.com and try again.".into()))?;
    let certificates = if command != "delete-app-id" {
        session
            .list_ios_certs(&team)
            .await
            .map_err(AppError::from)?
    } else {
        Vec::new()
    };
    let app_ids = if !revoking {
        Some(
            session
                .list_app_ids(&team, DeveloperDeviceType::Ios)
                .await
                .map_err(AppError::from)?,
        )
    } else {
        None
    };
    if revoking {
        let available: Vec<String> = certificates
            .iter()
            .filter_map(|certificate| certificate.serial_number.clone())
            .collect();
        let selected = certificate_management::validate_selection(
            &selected,
            &available,
            request.expected_serial_numbers.as_deref(),
        )?;
        let mut context = (session, team);
        let outcome = certificate_management::revoke_selected(
            &mut context,
            &selected,
            revoke_certificate_once,
        )
        .await;
        let message = outcome.message();
        emit(
            json!({"type":"certificateRevocationResult","revokedCount":outcome.revoked.len(),"revokedSerialNumbers":outcome.revoked,"failedSerialNumbers":outcome.unconfirmed,"unattemptedSerialNumbers":outcome.not_attempted,"message":message}),
        );
        if !outcome.completed() {
            return Err(AppError::Developer(message));
        }
        emit(json!({"type":"completed","revokedCount":outcome.revoked.len(),"message":message}));
        return Ok(());
    }
    match command {
        "delete-app-id" => {
            let id = request.app_id_id.as_deref().unwrap_or("");
            if !app_ids
                .as_ref()
                .is_some_and(|response| response.app_ids.iter().any(|app| app.app_id_id == id))
            {
                return Err(AppError::Developer("The selected App ID no longer belongs to this account. Refresh the list and select it again.".into()));
            }
            session
                .delete_app_id(&team, id, DeveloperDeviceType::Ios)
                .await
                .map_err(AppError::from)?;
        }
        _ => {
            let certificates: Vec<_> = certificates.iter().map(|cert| json!({ "name": cert.name, "serialNumber": cert.serial_number, "machineName": cert.machine_name })).collect();
            let app_ids = app_ids.expect("non-revocation operation lists App IDs");
            let limit = app_ids.max_quantity;
            let remaining = app_ids.available_quantity;
            let used = limit.zip(remaining).and_then(|(limit, remaining)| {
                u64::try_from(remaining)
                    .ok()
                    .map(|remaining| limit.saturating_sub(remaining))
            });
            emit(json!({"type":"appIdQuota","limit":limit,"remaining":remaining,"used":used}));
            let app_ids: Vec<_> = app_ids.app_ids.iter().map(|app| json!({ "id": app.app_id_id, "name": app.name, "bundleId": app.identifier })).collect();
            emit(
                json!({ "type": "accountResources", "certificates": certificates, "appIds": app_ids }),
            );
        }
    }
    emit(json!({ "type": "completed" }));
    Ok(())
}

fn revoke_certificate_once<'a>(
    context: &'a mut (DeveloperSession, isideload::dev::teams::DeveloperTeam),
    serial: &'a str,
) -> futures::future::BoxFuture<'a, Result<(), AppError>> {
    Box::pin(async move {
        context
            .0
            .revoke_development_cert(&context.1, serial, DeveloperDeviceType::Ios)
            .await
            .map_err(AppError::from)
    })
}

async fn list_installed_apps(device: &DeviceInfo) -> Result<Vec<Value>, AppError> {
    let provider = get_provider(device).await?;
    let mut client = InstallationProxyClient::connect(&provider)
        .await
        .map_err(|error| {
            AppError::DeviceComsWithMessage(
                "Unable to read installed iPhone apps".into(),
                error.to_string(),
            )
        })?;
    let apps = client.get_apps(Some("User"), None).await.map_err(|error| {
        AppError::DeviceComsWithMessage(
            "Unable to list installed iPhone apps".into(),
            error.to_string(),
        )
    })?;
    drop(client);

    // SpringBoard exposes the exact icon iOS is displaying. Keep this optional:
    // an inventory is still useful even if an individual app or iOS version refuses
    // icon access.
    let mut springboard = SpringBoardServicesClient::connect(&provider).await.ok();
    let mut result = Vec::with_capacity(apps.len());
    for (bundle_id, value) in apps {
        let info = value.as_dictionary();
        let string = |key: &str| {
            info.and_then(|dictionary| dictionary.get(key))
                .and_then(|value| value.as_string())
                .unwrap_or("")
        };
        let display_name = string("CFBundleDisplayName");
        let name = if display_name.is_empty() {
            string("CFBundleName")
        } else {
            display_name
        };
        let icon_data = if let Some(client) = springboard.as_mut() {
            client
                .get_icon_pngdata(bundle_id.clone())
                .await
                .ok()
                .map(|data| STANDARD.encode(data))
        } else {
            None
        };
        result.push(json!({
            "bundleId": bundle_id,
            "name": name,
            "version": string("CFBundleShortVersionString"),
            "buildVersion": string("CFBundleVersion"),
            "applicationType": string("ApplicationType"),
            "iconData": icon_data,
        }));
    }
    result.sort_by_key(|app| {
        app.get("name")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_ascii_lowercase()
    });
    Ok(result)
}

async fn uninstall_apps(
    request: UninstallAppsRequest,
) -> Result<(Vec<String>, Vec<String>), AppError> {
    if request.bundle_ids.is_empty() {
        return Err(AppError::Misc(
            "Select at least one app to uninstall".into(),
        ));
    }
    let provider = get_provider(&request.device).await?;
    let mut client = InstallationProxyClient::connect(&provider)
        .await
        .map_err(|error| {
            AppError::DeviceComsWithMessage(
                "Unable to open iPhone app management".into(),
                error.to_string(),
            )
        })?;
    let mut removed = Vec::new();
    let mut errors = Vec::new();
    for bundle_id in request.bundle_ids {
        match client.uninstall(bundle_id.clone(), None).await {
            Ok(()) => removed.push(bundle_id),
            Err(error) => errors.push(format!("{bundle_id}: {error}")),
        }
    }
    if removed.is_empty() && !errors.is_empty() {
        return Err(AppError::DeviceComsWithMessage(
            "Unable to uninstall the selected apps".into(),
            errors.join(" • "),
        ));
    }
    Ok((removed, errors))
}

async fn account_for_mode(
    email: &str,
    anisette_url: &str,
    storage_path: &str,
    authentication_mode: &str,
) -> Result<AppleAccount, AppError> {
    validate_authentication_mode(authentication_mode)?;
    if authentication_mode == "remote" {
        return provisioned_account(email, anisette_url, storage_path).await;
    }
    #[cfg(target_os = "macos")]
    {
        let (available, reason) =
            isideload::anisette::local_macos::local_authentication_status().await;
        if !available {
            return Err(AppError::Anisette(reason.unwrap_or_else(|| {
                isideload::anisette::local_macos::LOCAL_AUTH_UNAVAILABLE.into()
            })));
        }
        let mut account = AppleAccount::builder(email)
            .anisette_provider(isideload::anisette::local_macos::LocalMacOsAnisetteProvider)
            .build()
            .await
            .map_err(AppError::from)?;
        account
            .anisette_generator
            .get_anisette_data(account.grandslam_client.clone())
            .await
            .map_err(AppError::from)?;
        Ok(account)
    }
    #[cfg(not(target_os = "macos"))]
    {
        Err(AppError::Auth("This Mac authentication requires macOS. Choose Remote compatibility in Apple Accounts.".into()))
    }
}

async fn provisioned_account(
    email: &str,
    anisette_url: &str,
    storage_path: &str,
) -> Result<AppleAccount, AppError> {
    let provider = RemoteV3AnisetteProvider::default()
        .map_err(AppError::from)?
        .set_storage(storage(storage_path)?)
        .set_url(anisette_url);
    let mut account = AppleAccount::builder(email)
        .anisette_provider(provider)
        .build()
        .await
        .map_err(AppError::from)?;
    account
        .anisette_generator
        .get_anisette_data(account.grandslam_client.clone())
        .await
        .map_err(AppError::from)?;
    Ok(account)
}

pub fn user_facing_error(message: &str) -> String {
    let lower = message.to_lowercase();

    if lower.contains("certificate selection canceled") {
        return "Certificate revocation was canceled. No additional certificates were revoked."
            .into();
    }
    if lower.contains("7460") || lower.contains("maximum number of certificates") {
        return "Your Apple Account has reached its signing certificate limit. Select an existing certificate to revoke when prompted, or manage certificates under Apple Accounts. Revoking a certificate can stop apps signed with it from opening.".into();
    }

    if lower.contains("1100") || (lower.contains("session") && lower.contains("expired")) {
        return "Your Apple Developer session has expired. Sign in again; if Apple still rejects it, accept the Developer Agreement at developer.apple.com.".into();
    }

    if lower.contains("no developer teams available") {
        return "No Apple Developer team found for this account. Sign in to https://developer.apple.com with this Apple Account once to accept the free Developer Agreement, then try sideloading again.".into();
    }

    if lower.contains("no 2fa code provided")
        || lower.contains("no 2fa method selected")
        || lower.contains("two-factor verification was canceled")
        || lower.contains("two factor verification was canceled")
        || lower.contains("native app closed the request")
        || lower.contains("a two-factor code is required")
        || ((lower.contains("abort")
            || lower.contains("cancel")
            || lower.contains("canceled")
            || lower.contains("cancelled"))
            && (lower.contains("2fa")
                || lower.contains("two-factor")
                || lower.contains("two factor")
                || lower.contains("twofactor")
                || lower.contains("verification")
                || lower.contains("prompt")))
    {
        return "Two-factor verification was canceled. Enter the code sent to your Apple devices to complete sign-in.".into();
    }

    if lower.contains("-80045") {
        return "Apple rejected the authentication device session. Please try signing in again; if it persists, choose another authentication service under Apple Accounts.".into();
    }

    if lower.contains("websocket") || lower.contains("connection reset without closing handshake") {
        return "The Apple authentication service (Anisette) temporarily disconnected. Please try signing in again.".into();
    }

    // Check specific known Apple error codes & conditions first
    if lower.contains("-20209")
        || (lower.contains("locked") && (lower.contains("apple id") || lower.contains("account")))
    {
        return "Your Apple Account has been locked for security reasons. Please visit https://iforgot.apple.com to unlock it, then try again.".into();
    }
    if lower.contains("-20101")
        || lower.contains("-20102")
        || lower.contains("your apple id or password was incorrect")
        || (lower.contains("incorrect") && lower.contains("password"))
    {
        return "Apple rejected the sign-in. Your Apple Account email or password was incorrect. Please check your credentials and try again.".into();
    }
    if lower.contains("-21669") || lower.contains("incorrect verification code") {
        return "The verification code entered was incorrect. Please try signing in again with a new code.".into();
    }
    if lower.contains("-22979")
        || lower.contains("-22981")
        || (lower.contains("too many") && lower.contains("code"))
    {
        return "Too many verification codes have been requested. Please wait a few minutes before trying again.".into();
    }
    if lower.contains("-28248") {
        return "SMS verification is unavailable for this Apple Account. Please verify using a trusted Apple device.".into();
    }
    if lower.contains("503") || lower.contains("service temporarily unavailable") {
        return "Apple's sign-in service (GrandSlam) is temporarily unavailable (HTTP 503). Apple may be experiencing high load or throttling requests. Please wait a few moments and try again.".into();
    }
    if lower.contains("429") || lower.contains("too many requests") {
        return "Apple's authentication servers are temporarily rate-limiting requests (HTTP 429 Too Many Requests). Please wait 2 to 3 minutes before trying again.".into();
    }
    if lower.contains("mach-o") {
        return "The selected IPA contains an incompatible or corrupted binary. Slip has attempted to repair it, but the app bundle may be incomplete.".into();
    }
    if lower.contains("anisette provisioning timed out")
        || lower.contains("authentication preparation failed")
    {
        return "Apple authentication preparation timed out on all available services. Check your network and try again.".into();
    }
    if lower.contains("applicationverificationfailed")
        || lower.contains("failed to verify code signature")
    {
        return "iOS rejected the app signature. Ensure Developer Mode is enabled on your iPhone in Settings \u{2192} Privacy & Security.".into();
    }
    if lower.contains("not enough available app ids") {
        return "You have used all 10 free App IDs for this week on your Apple Account. Try disabling app extensions in the Extensions tab.".into();
    }
    if lower.contains("maximum number of installed apps") {
        return "Free Apple Accounts can only have 3 active sideloaded apps at a time. Delete another sideloaded app from your iPhone and try again.".into();
    }

    // Check for specific Auth error or Developer error in Rootcause report lines
    for line in message.lines() {
        let trimmed = line.trim();
        let cleaned = trimmed
            .trim_start_matches('●')
            .trim_start_matches("╰─▶")
            .trim_start_matches("├─▶")
            .trim_start_matches("│")
            .trim();
        let cl = cleaned.to_lowercase();
        if cl.starts_with("auth error") {
            if let Some((_, desc)) = cleaned.split_once(':') {
                let desc = desc.trim();
                let desc_lower = desc.to_lowercase();
                if desc_lower.contains("locked") {
                    return "Your Apple Account has been locked for security reasons. Please visit https://iforgot.apple.com to unlock it, then try again.".into();
                }
                if desc_lower.contains("password was incorrect") || desc_lower.contains("incorrect")
                {
                    return "Apple rejected the sign-in. Your Apple Account email or password was incorrect. Please check your credentials and try again.".into();
                }
                return format!("Apple authentication error: {}", desc);
            } else {
                return cleaned.to_string();
            }
        }
        if cl.starts_with("developer error") {
            if let Some((_, desc)) = cleaned.split_once(':') {
                return format!("Apple Developer error: {}", desc.trim());
            } else {
                return cleaned.to_string();
            }
        }
    }

    // Extract actual error bullets from Rootcause reports
    let bullets: Vec<&str> = message
        .lines()
        .map(|l| l.trim())
        .filter(|l| l.starts_with("● ") || l.starts_with("╰─▶ ") || l.starts_with("├─▶ "))
        .map(|l| {
            l.trim_start_matches("● ")
                .trim_start_matches("╰─▶ ")
                .trim_start_matches("├─▶ ")
                .trim()
        })
        .collect();

    if let Some(specific) = bullets.iter().rev().find(|b| {
        let bl = b.to_lowercase();
        !bl.starts_with("failed to log in")
            && !bl.starts_with("failed to send initial")
            && !bl.starts_with("grandslam error")
            && !bl.starts_with("received error response")
            && !bl.starts_with("caused by")
            && !bl.contains(".cargo")
            && !bl.contains(".rs:")
            && !bl.is_empty()
    }) {
        return (*specific).to_string();
    }

    if lower.contains("failed to log in to apple id") {
        return "Apple rejected the sign-in. Check your Apple Account email and password in the Accounts tab, then try again.".into();
    }

    // Filter out cargo source file lines and tree formatting characters
    let clean = message
        .lines()
        .map(|line| line.trim())
        .filter(|line| {
            !line.is_empty()
                && !line.starts_with("Caused by")
                && !line.starts_with("Stack")
                && !line.starts_with("note:")
                && !line.starts_with("╰")
                && !line.starts_with("├")
                && !line.starts_with("│")
                && !line.contains(".cargo")
                && !line.contains(".rs:")
                && line.to_lowercase() != "misc"
        })
        .next()
        .unwrap_or(message)
        .trim_start_matches("● ")
        .trim_start_matches("╰─▶ ")
        .trim_start_matches("├─▶ ")
        .trim();

    if clean.is_empty() || clean.to_lowercase() == "misc" {
        "An unexpected error occurred during Apple authentication or installation. Please check your iPhone connection and credentials, then try again.".into()
    } else {
        clean.to_string()
    }
}

pub async fn run() -> Result<(), AppError> {
    let mut arguments = std::env::args().skip(1);
    match arguments.next().as_deref() {
        Some("host-identity") => {
            let mut identity = serde_json::to_value(isideload::util::host_identity::host_identity())
                .map_err(|_| AppError::Misc("Unable to read this computer's identity.".into()))?;
            #[cfg(target_os = "macos")]
            let (available, message) = isideload::anisette::local_macos::local_authentication_status().await;
            #[cfg(not(target_os = "macos"))]
            let (available, message) = (false, Some("This Mac authentication requires macOS.".to_string()));
            identity["localAuthenticationAvailable"] = json!(available);
            identity["localAuthenticationMessage"] = json!(message);
            emit(json!({
                "type": "hostIdentity",
                "hostIdentity": identity,
            }));
            Ok(())
        }
        Some("devices") => {
            let results = list_devices().await?;
            let mut devices = Vec::new();
            let mut errors = Vec::new();
            for result in results {
                match result {
                    Ok(device) => devices.push(device),
                    Err(error) => errors.push(error.to_string()),
                }
            }
            devices.sort_by_key(|device| match device.connection_type.as_str() {
                "USB" => 0,
                "Network" => 1,
                _ => 2,
            });
            emit(json!({ "type": "devices", "devices": devices, "errors": errors }));
            Ok(())
        }
        Some("inspect") => {
            let path = arguments
                .next()
                .ok_or_else(|| AppError::Misc("Missing IPA path".into()))?;
            let info = inspect_ipa(path)?;
            emit(json!({ "type": "ipa", "ipa": info }));
            Ok(())
        }
        Some("icon") => {
            let path = arguments
                .next()
                .ok_or_else(|| AppError::Misc("Missing IPA path".into()))?;
            let destination = arguments
                .next()
                .ok_or_else(|| AppError::Misc("Missing icon destination".into()))?;
            let icon_path = extract_ipa_icon(path, destination)?;
            emit(json!({ "type": "icon", "message": icon_path }));
            Ok(())
        }
        Some("enable-wifi") => {
            let udid = arguments
                .next()
                .ok_or_else(|| AppError::Misc("Missing iPhone UDID".into()))?;
            enable_wifi_debugging(&udid).await?;
            emit(json!({
                "type": "wifiEnabled",
                "message": "Wi-Fi connection enabled. Keep the Mac and iPhone on the same network."
            }));
            Ok(())
        }
        Some("export") => {
            let input = Arc::new(Mutex::new(BufReader::new(std::io::stdin())));
            let request: ExportRequest = read_json(&input)?;
            let bytes = export_prepared_ipa(&request.options, PathBuf::from(&request.destination).as_path())?;
            emit(json!({
                "type": "completed",
                "message": format!("Exported {} bytes to {}", bytes, request.destination)
            }));
            Ok(())
        }
        Some("apps") => {
            let input = Arc::new(Mutex::new(BufReader::new(std::io::stdin())));
            let device: DeviceInfo = read_json(&input)?;
            let apps = list_installed_apps(&device).await?;
            emit(json!({ "type": "apps", "apps": apps }));
            Ok(())
        }
        Some("uninstall") => {
            let input = Arc::new(Mutex::new(BufReader::new(std::io::stdin())));
            let request: UninstallAppsRequest = read_json(&input)?;
            let (bundle_ids, errors) = uninstall_apps(request).await?;
            let count = bundle_ids.len();
            emit(json!({
                "type": "uninstalled",
                "bundleIds": bundle_ids,
                "errors": errors,
                "message": format!("Removed {count} app{} from the iPhone", if count == 1 { "" } else { "s" })
            }));
            Ok(())
        }
        Some("network-check") => {
            let url = configured_provider_url(&arguments.next().ok_or_else(|| AppError::Anisette("Pass the provider address explicitly for a network check.".into()))?)?;
            let response = reqwest::Client::builder().connect_timeout(std::time::Duration::from_secs(12)).timeout(std::time::Duration::from_secs(30)).redirect(reqwest::redirect::Policy::none()).build().map_err(|_| AppError::Misc("Unable to prepare a network check.".into()))?
                .get(&url)
                .send()
                .await
                .map_err(|error| {
                    AppError::Misc(format!("Unable to establish a secure connection: {error}"))
                })?;
            emit(json!({
                "type": "network",
                "url": url,
                "status": response.status().as_u16(),
            }));
            Ok(())
        }
        Some("anisette-check") => {
            let url = configured_provider_url(&arguments.next().ok_or_else(|| AppError::Anisette("Pass the provider address explicitly for an authentication-provider check.".into()))?)?;
            let requested_storage = arguments.next().map(PathBuf::from);

            if let Ok(entries) = std::fs::read_dir(std::env::temp_dir()) {
                for entry in entries.flatten() {
                    if let Ok(name) = entry.file_name().into_string() {
                        if name.starts_with("sideloom-anisette-check-") {
                            let _ = std::fs::remove_dir_all(entry.path());
                        }
                    }
                }
            }

            let storage_path = requested_storage.clone().unwrap_or_else(|| {
                let unique = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_nanos();
                std::env::temp_dir().join(format!(
                    "sideloom-anisette-check-{}-{unique}",
                    std::process::id()
                ))
            });
            let result = provisioned_account(
                "sideloom-network-check@invalid.local",
                &url,
                storage_path.to_string_lossy().as_ref(),
            )
            .await;
            if requested_storage.is_none() {
                let _ = std::fs::remove_dir_all(&storage_path);
            }
            result?;
            emit(json!({ "type": "anisette", "url": url, "status": "ready" }));
            Ok(())
        }
        Some("install") => {
            let input = Arc::new(Mutex::new(BufReader::new(std::io::stdin())));
            let request: InstallRequest = read_json(&input)?;
            install(request, input).await
        }
        Some(command @ ("account-resources" | "revoke-certificate" | "revoke-certificates" | "delete-app-id")) => {
            let input = Arc::new(Mutex::new(BufReader::new(std::io::stdin())));
            let request: AccountResourceRequest = read_json(&input)?;
            account_resources(request, input, command).await
        }
        Some("login") => {
            let input = Arc::new(Mutex::new(BufReader::new(std::io::stdin())));
            let request: LoginAccountRequest = read_json(&input)?;
            login_account(request, input).await
        }
        _ => Err(AppError::Misc(
            "Usage: sideloom-core host-identity | devices | inspect <ipa> | icon <ipa> <destination> | enable-wifi <udid> | apps | uninstall | export | network-check <url> | anisette-check <url> [storage] | install | login | account-resources | revoke-certificate | revoke-certificates | delete-app-id".into(),
        )),

    }
}
