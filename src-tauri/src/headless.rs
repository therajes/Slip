use std::{
    io::{BufRead, BufReader, Write},
    path::PathBuf,
    sync::{Arc, Mutex},
    time::{SystemTime, UNIX_EPOCH},
};

use futures::FutureExt;
use idevice::{IdeviceService, installation_proxy::InstallationProxyClient};
use isideload::{
    anisette::remote_v3::{DEFAULT_ANISETTE_V3_URL, RemoteV3AnisetteProvider},
    auth::apple_account::{AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse},
    dev::{
        certificates::DevelopmentCertificate,
        developer_session::{DeveloperSession, DevicesApi},
    },
    sideload::{SideloaderBuilder, builder::MaxCertsBehavior},
    util::{device::IdeviceInfo, fs_storage::FsStorage, storage::SideloadingStorage},
};
use rootcause::prelude::*;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::{
    device::{DeviceInfo, enable_wifi_debugging, get_provider, list_devices},
    error::AppError,
    fast_install::install_signed_app_fast_with_progress,
    ipa::{IpaInstallOptions, export_prepared_ipa, extract_ipa_icon, inspect_ipa, prepare_ipa_in},
};

type Input = Arc<Mutex<BufReader<std::io::Stdin>>>;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct InstallRequest {
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

async fn install(request: InstallRequest, input: Input) -> Result<(), AppError> {
    emit_progress("account", 0.0, "Authenticating with Apple");
    let tfa_input = input.clone();
    let tfa_callback = move |params: TwoFactorCallbackParams| {
        let tfa_input = tfa_input.clone();
        async move {
            emit(json!({ "type": "twoFactorRequired", "details": params }));
            let response: PromptResponse = read_json(&tfa_input).map_err(|error| report!(error))?;
            if response.cancel.unwrap_or(false) {
                return Ok(TwoFactorCallbackResponse::Abort);
            }
            let code = response
                .code
                .filter(|code| !code.trim().is_empty())
                .ok_or_else(|| report!("A two-factor code is required"))?;
            Ok(TwoFactorCallbackResponse::SubmitCode(code))
        }
        .boxed()
    };

    let anisette_url = if request.anisette_server.starts_with("http") {
        request.anisette_server.clone()
    } else {
        format!("https://{}", request.anisette_server)
    };
    let mut anisette_urls = vec![anisette_url];
    if !anisette_urls
        .iter()
        .any(|url| url == DEFAULT_ANISETTE_V3_URL)
    {
        anisette_urls.push(DEFAULT_ANISETTE_V3_URL.into());
    }

    let email = request.email.to_lowercase();
    let mut account = None;
    let mut provisioning_errors = Vec::new();
    for (server_index, url) in anisette_urls.iter().enumerate() {
        for attempt in 1..=3 {
            emit_progress(
                "account",
                0.01 + ((server_index * 3 + attempt) as f32 * 0.01),
                match (server_index, attempt) {
                    (0, 1) => "Preparing Apple authentication",
                    (0, _) => "Retrying Apple authentication preparation",
                    (_, 1) => "Trying backup authentication service",
                    _ => "Retrying backup authentication service",
                },
            );
            match provisioned_account(&email, url, &request.storage_path).await {
                Ok(candidate) => {
                    account = Some(candidate);
                    break;
                }
                Err(error) => {
                    provisioning_errors.push(format!("{url} attempt {attempt}: {error}"));
                    if attempt < 3 {
                        tokio::time::sleep(std::time::Duration::from_secs((attempt * 2) as u64))
                            .await;
                    }
                }
            }
        }
        if account.is_some() {
            break;
        }
    }
    let mut account = account.ok_or_else(|| {
        AppError::Misc(format!(
            "Authentication preparation failed on every available anisette service: {}",
            provisioning_errors.join(" | ")
        ))
    })?;
    account
        .login(&request.password, Box::new(tfa_callback))
        .await
        .map_err(AppError::from)?;
    if let Ok((first_name, last_name)) = account.get_name() {
        let account_name = format!("{first_name} {last_name}").trim().to_string();
        if !account_name.is_empty() {
            emit(json!({
                "type": "accountProfile",
                "email": email,
                "accountName": account_name,
            }));
        }
    }
    let developer_session = DeveloperSession::from_account(&mut account)
        .await
        .map_err(AppError::from)?;

    let certificate_input = input.clone();
    let max_certs_callback = move |certificates: &Vec<DevelopmentCertificate>| {
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
        emit(json!({ "type": "certificateSelectionRequired", "certificates": details }));
        let response: PromptResponse = read_json(&certificate_input).ok()?;
        if response.cancel.unwrap_or(false) {
            None
        } else {
            response.serials
        }
    };

    let mut sideloader = SideloaderBuilder::new(developer_session, request.email.to_lowercase())
        .machine_name("Slip".into())
        .storage(storage(&request.storage_path)?)
        .max_certs_behavior(MaxCertsBehavior::Prompt(Box::new(max_certs_callback)))
        .build();

    emit_progress("prepare", 0.0, "Preparing IPA");
    let prepared = prepare_ipa_in(&std::env::temp_dir(), &request.options)?;
    emit_progress("prepare", 1.0, "IPA prepared");
    let result: Result<(), AppError> = async {
        emit_progress("sign", 0.01, "Registering device");
        let provider = get_provider(&request.device).await?;
        let team = sideloader.get_team().await.map_err(AppError::from)?;
        let device = IdeviceInfo::from_device(&provider)
            .await
            .map_err(AppError::from)?;
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
    let mut result: Vec<_> = apps
        .into_iter()
        .map(|(bundle_id, value)| {
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
            json!({
                "bundleId": bundle_id,
                "name": name,
                "version": string("CFBundleShortVersionString"),
                "buildVersion": string("CFBundleVersion"),
                "applicationType": string("ApplicationType"),
            })
        })
        .collect();
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
    if lower.contains("anisette provisioning timed out")
        || lower.contains("authentication preparation failed")
    {
        return "Apple authentication preparation timed out on all available services. Check your network and try again.".into();
    }
    if lower.contains("failed to log in to apple id") {
        return "Apple rejected the sign-in. Check the Apple Account password and complete any verification Apple requests, then try again.".into();
    }
    message
        .lines()
        .find(|line| !line.trim().is_empty())
        .unwrap_or(message)
        .trim()
        .to_string()
}

pub async fn run() -> Result<(), AppError> {
    let mut arguments = std::env::args().skip(1);
    match arguments.next().as_deref() {
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
            let url = arguments
                .next()
                .unwrap_or_else(|| "https://ani.sidestore.io".into());
            let response = reqwest::Client::new()
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
            let url = arguments
                .next()
                .unwrap_or_else(|| DEFAULT_ANISETTE_V3_URL.into());
            let requested_storage = arguments.next().map(PathBuf::from);
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
            let mut result = Err(AppError::Misc(
                "Apple authentication preparation did not run".into(),
            ));
            for _ in 0..3 {
                result = provisioned_account(
                    "sideloom-network-check@invalid.local",
                    &url,
                    storage_path.to_string_lossy().as_ref(),
                )
                .await;
                if result.is_ok() {
                    break;
                }
                tokio::time::sleep(std::time::Duration::from_secs(2)).await;
            }
            if requested_storage.is_none() {
                let _ = std::fs::remove_dir_all(storage_path);
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
        _ => Err(AppError::Misc(
            "Usage: sideloom-core devices | inspect <ipa> | icon <ipa> <destination> | enable-wifi <udid> | apps | uninstall | export | network-check [url] | anisette-check [url] [storage] | install".into(),
        )),
    }
}
