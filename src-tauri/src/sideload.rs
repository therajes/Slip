use std::{
    path::PathBuf,
    sync::Mutex,
    time::{SystemTime, UNIX_EPOCH},
};

use crate::{
    device::{DeviceInfoMutex, get_provider, get_provider_from_connection, get_usbmuxd},
    error::AppError,
    fast_install::install_signed_app_fast,
    ipa::{IpaInstallOptions, prepare_ipa},
    operation::Operation,
    pairing::{get_sidestore_info, place_file},
};
use isideload::sideload::{application::SpecialApp, sideloader::Sideloader};
use isideload::{dev::devices::DevicesApi, util::device::IdeviceInfo};
use tauri::{AppHandle, Manager, State, WebviewWindow};
use tracing::info;

pub type SideloaderMutex = Mutex<Option<Sideloader>>;

pub struct SideloaderGuard<'a> {
    state: &'a SideloaderMutex,
    sideloader: Option<Sideloader>,
}

impl<'a> SideloaderGuard<'a> {
    pub fn take(state: &'a SideloaderMutex) -> Result<Self, AppError> {
        let mut guard = state.lock().unwrap();
        let sideloader = guard.take().ok_or(AppError::NotLoggedIn)?;
        Ok(Self {
            state,
            sideloader: Some(sideloader),
        })
    }

    pub fn get_mut(&mut self) -> &mut Sideloader {
        self.sideloader
            .as_mut()
            .expect("Sideloader should be present")
    }
}

impl Drop for SideloaderGuard<'_> {
    fn drop(&mut self) {
        let mut guard = self.state.lock().unwrap();
        *guard = self.sideloader.take();
    }
}

pub async fn sideload(
    device_state: State<'_, DeviceInfoMutex>,
    sideloader_state: State<'_, SideloaderMutex>,
    app_path: String,
) -> Result<Option<SpecialApp>, AppError> {
    let device = {
        let device_lock = device_state.lock().unwrap();
        match &*device_lock {
            Some(d) => d.clone(),
            None => return Err(AppError::NoDeviceSelected),
        }
    };

    let provider = get_provider(&device.info).await?;

    let mut sideloader = SideloaderGuard::take(&sideloader_state)?;

    let special = sideloader
        .get_mut()
        .install_app(
            &provider,
            app_path.into(),
            false,
            None::<fn(f32) -> std::future::Ready<()>>,
        )
        .await?;

    Ok(special)
}

#[tauri::command]
pub async fn sideload_operation(
    window: WebviewWindow,
    device_state: State<'_, DeviceInfoMutex>,
    sideloader_state: State<'_, SideloaderMutex>,
    app_path: String,
) -> Result<(), AppError> {
    let op = Operation::new("sideload".to_string(), &window);
    op.start("install")?;
    op.fail_if_err(
        "install",
        sideload(device_state, sideloader_state, app_path).await,
    )?;
    op.complete("install")?;
    Ok(())
}

#[tauri::command]
pub async fn custom_sideload_operation(
    handle: AppHandle,
    window: WebviewWindow,
    device_state: State<'_, DeviceInfoMutex>,
    sideloader_state: State<'_, SideloaderMutex>,
    options: IpaInstallOptions,
) -> Result<(), AppError> {
    info!(ipa = %options.app_path, "Custom sideload requested");
    let op = Operation::new("custom_sideload".to_string(), &window);
    op.start("prepare")?;
    let prepared_path = op.fail_if_err("prepare", prepare_ipa(&handle, &options))?;
    info!(prepared = %prepared_path.display(), "IPA preparation completed");
    op.complete("prepare")?;
    op.start("sign")?;

    let result: Result<(), (&str, AppError)> = async {
        let device = {
            let device_lock = device_state.lock().unwrap();
            device_lock
                .clone()
                .ok_or(("sign", AppError::NoDeviceSelected))?
        };
        info!(device = %device.info.name, connection = %device.info.connection_type, "Signing for selected device");
        let provider = get_provider(&device.info)
            .await
            .map_err(|error| ("sign", error))?;
        let mut sideloader =
            SideloaderGuard::take(&sideloader_state).map_err(|error| ("sign", error))?;

        let team = sideloader
            .get_mut()
            .get_team()
            .await
            .map_err(|error| ("sign", AppError::from(error)))?;
        let device_info = IdeviceInfo::from_device(&provider)
            .await
            .map_err(|error| ("sign", AppError::from(error)))?;
        sideloader
            .get_mut()
            .get_dev_session()
            .ensure_device_registered(&team, &device_info.name, &device_info.udid, None)
            .await
            .map_err(|error| ("sign", AppError::from(error)))?;

        let sign_window = window.clone();
        let (signed_app_path, _) = sideloader
            .get_mut()
            .sign_app(
                prepared_path.clone(),
                Some(team),
                options.increased_memory_limit,
                Some(move |progress| {
                    let sign_window = sign_window.clone();
                    async move {
                        let _ = Operation::new("custom_sideload".to_string(), &sign_window)
                            .progress("sign", progress);
                    }
                }),
            )
            .await
            .map_err(|error| ("sign", AppError::from(error)))?;
        info!(signed = %signed_app_path.display(), "IPA signing completed");
        op.complete("sign").map_err(|error| ("sign", error))?;

        op.start("install").map_err(|error| ("install", error))?;
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let optimized_ipa = handle
            .path()
            .temp_dir()
            .map_err(|error| ("install", AppError::Filesystem("Unable to locate temporary folder".into(), error.to_string())))?
            .join(format!("sideloom-fast-{}-{unique}.ipa", std::process::id()));
        let install_result = install_signed_app_fast(
            &provider,
            &signed_app_path,
            &optimized_ipa,
            &window,
        )
        .await;
        let _ = std::fs::remove_dir_all(&signed_app_path);
        let _ = std::fs::remove_file(&optimized_ipa);
        install_result.map_err(|error| ("install", AppError::from(error)))?;
        info!(device = %device.info.name, "IPA installation completed");
        op.complete("install").map_err(|error| ("install", error))?;
        Ok(())
    }
    .await;

    let _ = std::fs::remove_file(&prepared_path);
    match result {
        Ok(()) => Ok(()),
        Err((step, error)) => op.fail(step, error),
    }
}

#[tauri::command]
pub async fn install_sidestore_operation(
    handle: AppHandle,
    window: WebviewWindow,
    device_state: State<'_, DeviceInfoMutex>,
    sideloader_state: State<'_, SideloaderMutex>,
    nightly: bool,
    live_container: bool,
) -> Result<(), AppError> {
    let op = Operation::new("install_sidestore".to_string(), &window);
    op.start("download")?;
    // TODO: Cache & check version to avoid re-downloading
    let (filename, url) = if live_container {
        if nightly {
            (
                "LiveContainerSideStore-Nightly.ipa",
                "https://github.com/LiveContainer/LiveContainer/releases/download/nightly/LiveContainer+SideStore.ipa",
            )
        } else {
            (
                "LiveContainerSideStore.ipa",
                "https://github.com/LiveContainer/LiveContainer/releases/latest/download/LiveContainer+SideStore.ipa",
            )
        }
    } else if nightly {
        (
            "SideStore-Nightly.ipa",
            "https://github.com/SideStore/SideStore/releases/download/nightly/SideStore.ipa",
        )
    } else {
        (
            "SideStore.ipa",
            "https://github.com/SideStore/SideStore/releases/latest/download/SideStore.ipa",
        )
    };

    let dest = handle
        .path()
        .temp_dir()
        .map_err(|e| AppError::Filesystem("Failed to get temp dir".into(), e.to_string()))?
        .join(filename);
    op.fail_if_err("download", download(url, &dest).await)?;
    op.move_on("download", "install")?;
    let device = {
        let device_guard = device_state.lock().unwrap();
        match &*device_guard {
            Some(d) => d.clone(),
            None => return op.fail("install", AppError::NoDeviceSelected),
        }
    };
    op.fail_if_err(
        "install",
        sideload(
            device_state,
            sideloader_state,
            dest.to_string_lossy().to_string(),
        )
        .await,
    )?;
    op.move_on("install", "pairing")?;
    let sidestore_info = op.fail_if_err(
        "pairing",
        get_sidestore_info(&device.info, live_container).await,
    )?;
    if let Some(info) = sidestore_info {
        let mut usbmuxd = op.fail_if_err("pairing", get_usbmuxd().await)?;

        let provider = op.fail_if_err(
            "pairing",
            get_provider_from_connection(&device.info, &mut usbmuxd).await,
        )?;

        op.fail_if_err(
            "pairing",
            place_file(device.pairing, &provider, info.bundle_id, info.path).await,
        )?;
    } else {
        return op.fail(
            "pairing",
            AppError::HouseArrest(
                "SideStore's not found".into(),
                "The device did not report SideStore's bundle ID as installed".into(),
            ),
        );
    }

    op.complete("pairing")?;
    Ok(())
}

pub async fn download(url: impl AsRef<str>, dest: &PathBuf) -> Result<(), AppError> {
    let response = reqwest::get(url.as_ref())
        .await
        .map_err(|e| AppError::Download(e.to_string()))?;
    if !response.status().is_success() {
        return Err(AppError::Download(format!(
            "Failed to download file: HTTP {}",
            response.status()
        )));
    }

    let bytes = response
        .bytes()
        .await
        .map_err(|e| AppError::Download(e.to_string()))?;
    tokio::fs::write(dest, &bytes).await.map_err(|e| {
        AppError::Filesystem("Failed to write downloaded file".into(), e.to_string())
    })?;

    Ok(())
}
