#[cfg(feature = "tauri-ui")]
#[macro_use]
mod account;
#[cfg(feature = "tauri-ui")]
mod automation;
#[macro_use]
mod device;
#[cfg(feature = "tauri-ui")]
#[macro_use]
mod sideload;
#[cfg(feature = "tauri-ui")]
#[macro_use]
mod pairing;
#[cfg(feature = "tauri-ui")]
#[macro_use]
mod secure_storage;
mod error;
mod fast_install;
pub mod headless;
mod ipa;
#[cfg(feature = "tauri-ui")]
mod logging;
#[cfg(feature = "tauri-ui")]
mod operation;

#[cfg(feature = "tauri-ui")]
use crate::{
    account::{
        delete_account, delete_app_id, get_certificates, invalidate_account, list_app_ids,
        logged_in_as, login_new, login_stored, migrate_legacy_accounts, reset_anisette_state,
        revoke_certificate,
    },
    device::{
        DeviceInfoMutex, PairingCancelToken, cancel_pairing, list_devices, set_selected_device,
    },
    ipa::inspect_ipa,
    pairing::{
        delete_stored_rppairing, export_pairing_cmd, has_stored_rppairing, installed_pairing_apps,
        place_pairing_cmd,
    },
    secure_storage::{create_sideloading_storage, force_disable_keyring, keyring_available},
    sideload::{
        SideloaderMutex, custom_sideload_operation, install_sidestore_operation, sideload_operation,
    },
};
#[cfg(feature = "tauri-ui")]
use tauri::Manager;
#[cfg(feature = "tauri-ui")]
use tracing_subscriber::{
    Layer, Registry,
    filter::{LevelFilter, Targets},
    fmt,
    layer::SubscriberExt,
    util::SubscriberInitExt,
};

#[cfg(feature = "tauri-ui")]
#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            Some(vec!["--refresh-guard"]),
        ))
        .plugin(tauri_plugin_process::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_store::Builder::new().build())
        .setup(|app| {
            let arguments: Vec<String> = std::env::args().collect();
            let automation_ipa = arguments
                .windows(2)
                .find(|pair| pair[0] == "--automation-install-ipa")
                .map(|pair| pair[1].clone());
            if arguments
                .iter()
                .any(|argument| argument == "--refresh-guard")
                && let Some(window) = app.get_webview_window("main")
            {
                let _ = window.hide();
            }
            let log_dir = app
                .path()
                .app_data_dir()
                .expect("failed to get app data dir")
                .join("logs");

            std::fs::create_dir_all(&log_dir).ok();

            let file_appender = tracing_appender::rolling::RollingFileAppender::builder()
                .rotation(tracing_appender::rolling::Rotation::DAILY)
                .filename_prefix("sideloom")
                .filename_suffix("log")
                .max_log_files(2)
                .build(&log_dir)
                .expect("failed to create log file appender");

            let file_layer = fmt::layer()
                .with_writer(file_appender)
                .with_target(true)
                .with_ansi(false)
                .with_filter(
                    Targets::new()
                        .with_default(LevelFilter::INFO)
                        .with_target("sideloom_lib", LevelFilter::DEBUG),
                );

            let frontend_layer = logging::FrontendLoggingLayer::new(app.handle().clone())
                .with_filter(
                    Targets::new()
                        .with_default(LevelFilter::INFO)
                        .with_target("sideloom_lib", LevelFilter::DEBUG),
                );

            Registry::default()
                .with(file_layer)
                .with(frontend_layer)
                .init();

            std::panic::set_hook(Box::new(|panic_info| {
                let thread = std::thread::current();
                let thread_name = thread.name().unwrap_or("<unnamed>");

                let message = if let Some(s) = panic_info.payload().downcast_ref::<&str>() {
                    s.to_string()
                } else if let Some(s) = panic_info.payload().downcast_ref::<String>() {
                    s.clone()
                } else {
                    "<non-string panic payload>".to_string()
                };

                let location = panic_info
                    .location()
                    .map(|loc| format!("{}:{}", loc.file(), loc.line()))
                    .unwrap_or_else(|| "<unknown>".to_string());

                let backtrace = std::backtrace::Backtrace::capture();

                tracing::error!(
                    target: "panic",
                    thread = thread_name,
                    location = location,
                    message = message,
                    backtrace = %backtrace,
                    "panic captured"
                );
            }));

            app.manage(DeviceInfoMutex::new(None));
            app.manage(SideloaderMutex::new(None));
            app.manage(PairingCancelToken::new(None));

            if let Err(error) = create_sideloading_storage(app.handle()) {
                tracing::warn!(%error, "Unable to protect local Sideloom storage");
            }

            match migrate_legacy_accounts(app.handle()) {
                Ok(count) if count > 0 => {
                    tracing::info!(accounts = count, "Migrated saved Apple account to Sideloom")
                }
                Ok(_) => {}
                Err(error) => tracing::warn!(%error, "Unable to migrate legacy Apple account"),
            }

            if let Some(ipa_path) = automation_ipa {
                let handle = app.handle().clone();
                let window = app
                    .get_webview_window("main")
                    .expect("main window is required for installation automation");
                tauri::async_runtime::spawn(async move {
                    let status = automation::install_ipa(handle.clone(), window, ipa_path).await;
                    handle.exit(status);
                });
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            login_new,
            invalidate_account,
            logged_in_as,
            login_stored,
            delete_account,
            list_devices,
            sideload_operation,
            set_selected_device,
            install_sidestore_operation,
            get_certificates,
            revoke_certificate,
            list_app_ids,
            delete_app_id,
            installed_pairing_apps,
            place_pairing_cmd,
            reset_anisette_state,
            export_pairing_cmd,
            delete_stored_rppairing,
            keyring_available,
            force_disable_keyring,
            cancel_pairing,
            has_stored_rppairing,
            inspect_ipa,
            custom_sideload_operation,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
