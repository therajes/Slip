use std::{path::Path, time::Duration};

use tauri::{AppHandle, Manager, WebviewWindow};
use tracing::{error, info};

use crate::{
    account::logged_in_as,
    device::{DeviceInfo, DeviceInfoMutex, PairingCancelToken, list_devices, set_selected_device},
    error::AppError,
    ipa::{IpaInstallOptions, inspect_ipa},
    sideload::{SideloaderMutex, custom_sideload_operation},
};

fn connection_rank(device: &DeviceInfo) -> u8 {
    match device.connection_type.as_str() {
        "USB" => 0,
        "Network" => 1,
        _ => 2,
    }
}

async fn wait_for_account(handle: &AppHandle) -> Result<String, AppError> {
    for _ in 0..120 {
        if let Some(email) = logged_in_as(handle.state::<SideloaderMutex>()) {
            return Ok(email);
        }
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
    Err(AppError::NotLoggedIn)
}

async fn ensure_device(handle: &AppHandle) -> Result<DeviceInfo, AppError> {
    if let Some(device) = handle
        .state::<DeviceInfoMutex>()
        .lock()
        .map_err(|_| AppError::Misc("Device selection lock failed".into()))?
        .as_ref()
        .map(|selected| selected.info.clone())
    {
        return Ok(device);
    }

    let mut devices: Vec<_> = list_devices()
        .await?
        .into_iter()
        .filter_map(Result::ok)
        .collect();
    devices.sort_by_key(connection_rank);
    let device = devices
        .into_iter()
        .next()
        .ok_or(AppError::NoDeviceSelected)?;
    set_selected_device(
        handle.clone(),
        handle.state::<DeviceInfoMutex>(),
        handle.state::<PairingCancelToken>(),
        Some(device.clone()),
    )
    .await?;
    Ok(device)
}

pub async fn install_ipa(handle: AppHandle, window: WebviewWindow, ipa_path: String) -> i32 {
    let result: Result<(), AppError> = async {
        if !Path::new(&ipa_path).is_file() {
            return Err(AppError::Filesystem(
                "Automation IPA does not exist".into(),
                ipa_path.clone(),
            ));
        }

        info!(ipa = %ipa_path, "Automation waiting for Apple account session");
        let account = wait_for_account(&handle).await?;
        let device = ensure_device(&handle).await?;
        let info = inspect_ipa(ipa_path.clone())?;
        let removed_extensions = info
            .extensions
            .into_iter()
            .map(|extension| extension.path)
            .collect();

        info!(account = %account, device = %device.name, connection = %device.connection_type, "Automation starting real IPA installation");
        custom_sideload_operation(
            handle.clone(),
            window,
            handle.state::<DeviceInfoMutex>(),
            handle.state::<SideloaderMutex>(),
            IpaInstallOptions {
                app_path: ipa_path,
                display_name: None,
                bundle_id: None,
                removed_extensions,
                custom_icon_path: None,
                increased_memory_limit: false,
            },
        )
        .await
    }
    .await;

    match result {
        Ok(()) => {
            info!("AUTOMATION_RESULT=success");
            println!("AUTOMATION_RESULT=success");
            0
        }
        Err(error) => {
            error!(%error, "AUTOMATION_RESULT=failure");
            eprintln!("AUTOMATION_RESULT=failure: {error}");
            1
        }
    }
}
