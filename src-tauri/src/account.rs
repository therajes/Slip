use futures::FutureExt;
use isideload::{
    anisette::remote_v3::RemoteV3AnisetteProvider,
    auth::apple_account::{AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse},
    dev::{
        app_ids::{AppIdsApi, ListAppIdsResponse},
        certificates::{CertificatesApi, DevelopmentCertificate},
        developer_session::DeveloperSession,
    },
    sideload::{SideloaderBuilder, builder::MaxCertsBehavior, sideloader::Sideloader},
};
use keyring::Entry;
use rootcause::prelude::*;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::time::Duration;
use tauri::{AppHandle, Emitter, Listener, Manager, State, WebviewWindow};
use tauri_plugin_store::StoreExt;
use tracing::debug;

use crate::{
    error::AppError,
    secure_storage::{create_sideloading_storage, keyring_available},
    sideload::{SideloaderGuard, SideloaderMutex},
};

fn forget_saved_account(handle: &AppHandle, email: &str) -> Result<(), AppError> {
    let store = handle.store("data.json").map_err(|error| {
        AppError::Storage("Unable to open account store".into(), error.to_string())
    })?;
    let mut saved_ids = store
        .get("ids")
        .unwrap_or_else(|| Value::Array(Vec::new()))
        .as_array()
        .cloned()
        .unwrap_or_default();
    saved_ids.retain(|value| value.as_str() != Some(email));
    store.set("ids", Value::Array(saved_ids));
    store.save().map_err(|error| {
        AppError::Storage("Unable to save account list".into(), error.to_string())
    })?;

    let preferences = handle.store("preferences.json").map_err(|error| {
        AppError::Storage("Unable to open preferences".into(), error.to_string())
    })?;
    if preferences
        .get("defaultAccount")
        .and_then(|value| value.as_str().map(ToOwned::to_owned))
        .as_deref()
        == Some(email)
    {
        preferences.delete("defaultAccount");
        preferences.save().map_err(|error| {
            AppError::Storage("Unable to save preferences".into(), error.to_string())
        })?;
    }
    let _ = handle.emit("saved-accounts-changed", ());
    Ok(())
}

pub fn migrate_legacy_accounts(handle: &AppHandle) -> Result<usize, AppError> {
    let store = handle.store("data.json").map_err(|error| {
        AppError::Storage("Unable to open account store".into(), error.to_string())
    })?;
    let mut saved_ids = store
        .get("ids")
        .unwrap_or_else(|| Value::Array(Vec::new()))
        .as_array()
        .cloned()
        .unwrap_or_default();
    if !keyring_available() {
        if !saved_ids.is_empty() {
            store.set("ids", Value::Array(Vec::new()));
            store.save().map_err(|error| {
                AppError::Storage(
                    "Unable to clear stale saved accounts".into(),
                    error.to_string(),
                )
            })?;
            let preferences = handle.store("preferences.json").map_err(|error| {
                AppError::Storage("Unable to open preferences".into(), error.to_string())
            })?;
            preferences.delete("defaultAccount");
            preferences.save().map_err(|error| {
                AppError::Storage("Unable to save preferences".into(), error.to_string())
            })?;
            let _ = handle.emit("saved-accounts-changed", ());
        }
        return Ok(0);
    }
    if !saved_ids.is_empty() {
        return Ok(0);
    }
    let app_data_dir = handle.path().app_data_dir().map_err(|error| {
        AppError::Filesystem(
            "Unable to locate application data".into(),
            error.to_string(),
        )
    })?;
    let application_support = app_data_dir
        .parent()
        .ok_or_else(|| AppError::Misc("Unable to locate Application Support".into()))?;
    let mut migrated = 0;

    for (service, bundle_id) in [
        ("iloader", "me.nabdev.iloader"),
        ("ipa-pilot", "app.ipapilot.macos"),
    ] {
        let legacy_store_path = application_support.join(bundle_id).join("data.json");
        let Ok(bytes) = std::fs::read(&legacy_store_path) else {
            continue;
        };
        let Ok(legacy_store) = serde_json::from_slice::<Value>(&bytes) else {
            continue;
        };
        let Some(legacy_ids) = legacy_store.get("ids").and_then(Value::as_array) else {
            continue;
        };

        for value in legacy_ids {
            let Some(email) = value.as_str() else {
                continue;
            };
            let Ok(legacy_entry) = Entry::new(service, email) else {
                continue;
            };
            let Ok(password) = legacy_entry.get_password() else {
                continue;
            };
            let destination = Entry::new("sideloom", email).map_err(|error| {
                AppError::KeyringWithMessage(
                    "Unable to create Sideloom credential".into(),
                    error.to_string(),
                )
            })?;
            if destination.get_password().is_err() {
                destination.set_password(&password).map_err(|error| {
                    AppError::KeyringWithMessage(
                        "Unable to migrate saved credential".into(),
                        error.to_string(),
                    )
                })?;
                migrated += 1;
            }
            let email_value = Value::String(email.to_string());
            if !saved_ids.contains(&email_value) {
                saved_ids.push(email_value);
            }
        }

        if let (Ok(source), Ok(destination)) = (
            Entry::new(service, "anisette_state"),
            Entry::new("sideloom", "anisette_state"),
        ) && destination.get_password().is_err()
            && let Ok(state) = source.get_password()
        {
            let _ = destination.set_password(&state);
        }
    }

    store.set("ids", Value::Array(saved_ids.clone()));
    store.save().map_err(|error| {
        AppError::Storage("Unable to save migrated accounts".into(), error.to_string())
    })?;

    if let Some(default_account) = saved_ids.first().cloned() {
        let preferences = handle.store("preferences.json").map_err(|error| {
            AppError::Storage("Unable to open preferences".into(), error.to_string())
        })?;
        if preferences.get("defaultAccount").is_none() {
            preferences.set("defaultAccount", default_account);
            preferences.save().map_err(|error| {
                AppError::Storage("Unable to save default account".into(), error.to_string())
            })?;
        }
    }

    Ok(migrated)
}

#[tauri::command]
pub async fn login_new(
    handle: AppHandle,
    window: WebviewWindow,
    sideloader_state: State<'_, SideloaderMutex>,
    email: String,
    password: String,
    anisette_server: String,
    save_credentials: bool,
) -> Result<(), AppError> {
    let account = login(&handle, &window, &email, &password, anisette_server).await?;
    let mut sideloader_guard = sideloader_state.lock().unwrap();
    *sideloader_guard = Some(account);

    if save_credentials && keyring_available() {
        let pass_entry = Entry::new("sideloom", &email).map_err(|e| {
            AppError::KeyringWithMessage(
                "Failed to create entry for credentials".into(),
                e.to_string(),
            )
        })?;
        pass_entry.set_password(&password).map_err(|e| {
            AppError::KeyringWithMessage("Failed to save credentials".into(), e.to_string())
        })?;
        let store = handle
            .store("data.json")
            .map_err(|e| AppError::Misc(format!("Failed to get store: {:?}", e)))?;
        let mut existing_ids = store
            .get("ids")
            .unwrap_or_else(|| Value::Array(vec![]))
            .as_array()
            .cloned()
            .unwrap_or_else(std::vec::Vec::new);
        let value = Value::String(email.clone());
        if !existing_ids.contains(&value) {
            existing_ids.push(value);
        }
        store.set("ids", Value::Array(existing_ids));
        store.save().map_err(|error| {
            AppError::Storage("Unable to save account".into(), error.to_string())
        })?;
        let _ = handle.emit("saved-accounts-changed", ());
    }
    Ok(())
}

#[tauri::command]
pub async fn login_stored(
    handle: AppHandle,
    window: WebviewWindow,
    email: String,
    anisette_server: String,
    sideloader_state: State<'_, SideloaderMutex>,
) -> Result<(), AppError> {
    if !keyring_available() {
        forget_saved_account(&handle, &email)?;
        return Err(AppError::Keyring(
            "Saved Apple Account passwords are disabled in Keychain-free mode. Please sign in again."
                .into(),
        ));
    }
    let pass_entry = Entry::new("sideloom", &email).map_err(|e| {
        AppError::KeyringWithMessage(
            "Failed to create keyring entry for credentials".to_string(),
            e.to_string(),
        )
    })?;
    let password = match pass_entry.get_password() {
        Ok(password) => password,
        Err(keyring::Error::NoEntry) => {
            forget_saved_account(&handle, &email)?;
            return Err(AppError::Keyring(
                "The saved password was missing, so Sideloom removed the stale login. Please add the Apple Account again."
                    .into(),
            ));
        }
        Err(error) => {
            return Err(AppError::KeyringWithMessage(
                "Failed to get credentials".into(),
                error.to_string(),
            ));
        }
    };
    let account = login(&handle, &window, &email, &password, anisette_server).await?;
    let mut sideloader_guard = sideloader_state.lock().unwrap();
    *sideloader_guard = Some(account);

    Ok(())
}

#[tauri::command]
pub fn delete_account(handle: AppHandle, email: String) -> Result<(), AppError> {
    if !keyring_available() {
        return forget_saved_account(&handle, &email);
    }
    let pass_entry = Entry::new("sideloom", &email).map_err(|e| {
        AppError::KeyringWithMessage(
            "Failed to create keyring entry for credentials".into(),
            e.to_string(),
        )
    })?;
    match pass_entry.delete_credential() {
        Ok(()) | Err(keyring::Error::NoEntry) => forget_saved_account(&handle, &email),
        Err(error) => Err(AppError::KeyringWithMessage(
            "Failed to delete credentials".into(),
            error.to_string(),
        )),
    }
}

#[tauri::command]
pub fn logged_in_as(sideloader_state: State<'_, SideloaderMutex>) -> Option<String> {
    let sideloader_guard = sideloader_state.lock().unwrap();
    if let Some(account) = &*sideloader_guard {
        return Some(account.get_email().to_string());
    }
    None
}

#[tauri::command]
pub fn invalidate_account(sideloader_state: State<'_, SideloaderMutex>) {
    let mut sideloader_guard = sideloader_state.lock().unwrap();
    *sideloader_guard = None;
}

#[tauri::command]
pub fn reset_anisette_state(handle: AppHandle) -> Result<bool, AppError> {
    if !keyring_available() {
        let storage = create_sideloading_storage(&handle)?;
        let existed = storage
            .retrieve_data("anisette_state")
            .map_err(AppError::from)?
            .is_some();
        if existed {
            storage.delete("anisette_state").map_err(AppError::from)?;
        }
        return Ok(existed);
    }
    let state_entry = Entry::new("sideloom", "anisette_state").map_err(|e| {
        AppError::KeyringWithMessage(
            "Failed to create keyring entry for anisette".into(),
            e.to_string(),
        )
    })?;

    match state_entry.delete_credential() {
        Ok(_) => {
            debug!("Anisette state deleted from keyring.");
            Ok(true)
        }
        Err(keyring::Error::NoEntry) => {
            debug!("No existing anisette state found in keyring, nothing to delete.");
            Ok(false)
        }
        Err(e) => Err(AppError::KeyringWithMessage(
            "Failed to delete anisette state".into(),
            e.to_string(),
        )),
    }
}

async fn login(
    app: &AppHandle,
    window: &WebviewWindow,
    email: &str,
    password: &str,
    anisette_server: String,
) -> Result<Sideloader, AppError> {
    let tfa_closure = {
        let window_clone = window.clone();
        move |params: TwoFactorCallbackParams| {
            let window_clone = window_clone.clone();

            async move {
                window_clone
                    .emit("2fa-required", params)
                    .context("Failed to emit 2fa-required event")?;

                let (tx, rx) = std::sync::mpsc::channel::<String>();
                let handler_id = window_clone.listen("2fa-recieved", move |event| {
                    let code = event.payload();
                    let _ = tx.send(code.to_string());
                });

                let result = rx.recv_timeout(Duration::from_secs(120))?;
                window_clone.unlisten(handler_id);

                let code = result.trim_matches('"').to_string();
                Ok(TwoFactorCallbackResponse::SubmitCode(code))
            }
            .boxed()
        }
    };

    let anisette_url = if !anisette_server.starts_with("http") {
        format!("https://{}", anisette_server)
    } else {
        anisette_server
    };

    let mut account = AppleAccount::builder(&email.to_lowercase())
        .anisette_provider(
            RemoteV3AnisetteProvider::default()?
                .set_serial_number("0".to_string())
                .set_storage(create_sideloading_storage(app)?)
                .set_url(&anisette_url),
        )
        .login(password, Box::new(tfa_closure))
        .await?;

    debug!("Logged in");

    let dev_session = DeveloperSession::from_account(&mut account).await?;

    debug!("Created developer session");

    let max_certs_callback = {
        let window_clone = window.clone();
        move |certs: &Vec<DevelopmentCertificate>| -> Option<Vec<String>> {
            let cert_infos: Vec<CertificateInfo> = certs
                .iter()
                .map(|cert| CertificateInfo {
                    name: cert.name.clone(),
                    certificate_id: cert.certificate_id.clone(),
                    serial_number: cert.serial_number.clone(),
                    machine_name: cert.machine_name.clone(),
                    machine_id: cert.machine_id.clone(),
                })
                .collect();
            window_clone
                .emit("max-certs-reached", cert_infos)
                .expect("Failed to emit max-certs-reached event");

            let (tx, rx) = std::sync::mpsc::channel::<Option<Vec<String>>>();
            let handler_id = window_clone.listen("max-certs-response", move |event| {
                let certs = event.payload();
                let certs = serde_json::from_str::<Option<Vec<String>>>(certs).unwrap_or(None);
                let _ = tx.send(certs);
            });

            let result = rx.recv_timeout(Duration::from_secs(300));
            window_clone.unlisten(handler_id);
            result.unwrap_or(None)
        }
    };

    // TODO: Team Selection

    let sideloader = SideloaderBuilder::new(dev_session, email.to_lowercase())
        .machine_name("Sideloom".into())
        .storage(create_sideloading_storage(app)?)
        .max_certs_behavior(MaxCertsBehavior::Prompt(Box::new(max_certs_callback)))
        .build();

    debug!("Built sideloader");

    Ok(sideloader)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CertificateInfo {
    pub name: Option<String>,
    pub certificate_id: Option<String>,
    pub serial_number: Option<String>,
    pub machine_name: Option<String>,
    pub machine_id: Option<String>,
}

#[tauri::command]
pub async fn get_certificates(
    sideloader_state: State<'_, SideloaderMutex>,
) -> Result<Vec<CertificateInfo>, AppError> {
    let mut sideloader = SideloaderGuard::take(&sideloader_state)?;

    let team = sideloader.get_mut().get_team().await?;
    let dev_session = sideloader.get_mut().get_dev_session();

    let certificates = dev_session.list_all_development_certs(&team, None).await?;

    Ok(certificates
        .into_iter()
        .map(|cert| CertificateInfo {
            name: cert.name,
            certificate_id: cert.certificate_id,
            serial_number: cert.serial_number,
            machine_name: cert.machine_name,
            machine_id: cert.machine_id,
        })
        .collect())
}

#[tauri::command]
pub async fn revoke_certificate(
    serial_number: String,
    sideloader_state: State<'_, SideloaderMutex>,
) -> Result<(), AppError> {
    let mut sideloader = SideloaderGuard::take(&sideloader_state)?;

    let team = sideloader.get_mut().get_team().await?;
    let dev_session = sideloader.get_mut().get_dev_session();

    dev_session
        .revoke_development_cert(&team, &serial_number, None)
        .await?;

    Ok(())
}

#[tauri::command]
pub async fn list_app_ids(
    sideloader_state: State<'_, SideloaderMutex>,
) -> Result<ListAppIdsResponse, AppError> {
    let mut sideloader = SideloaderGuard::take(&sideloader_state)?;

    let team = sideloader.get_mut().get_team().await?;
    let dev_session = sideloader.get_mut().get_dev_session();

    let response = dev_session.list_app_ids(&team, None).await?;

    Ok(response.clone())
}

#[tauri::command]
pub async fn delete_app_id(
    app_id_id: String,
    sideloader_state: State<'_, SideloaderMutex>,
) -> Result<(), AppError> {
    let mut sideloader = SideloaderGuard::take(&sideloader_state)?;

    let team = sideloader.get_mut().get_team().await?;
    let dev_session = sideloader.get_mut().get_dev_session();

    dev_session.delete_app_id(&team, &app_id_id, None).await?;

    Ok(())
}
