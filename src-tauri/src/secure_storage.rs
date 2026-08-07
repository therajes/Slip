use isideload::util::{fs_storage::FsStorage, storage::SideloadingStorage};
use tauri::{AppHandle, Manager};
use tracing::warn;

use crate::error::AppError;

#[tauri::command]
pub fn force_disable_keyring(_force: bool) {
    warn!("Sideloom is running in Keychain-free mode.");
}

#[tauri::command]
pub fn keyring_available() -> bool {
    false
}

pub fn create_sideloading_storage(
    app: &AppHandle,
) -> Result<Box<dyn SideloadingStorage>, AppError> {
    warn!("Using local application storage; macOS Keychain access is disabled.");
    let app_data_dir = app
        .path()
        .app_data_dir()
        .map_err(|e| AppError::Misc(format!("Failed to get app data directory: {:?}", e)))?;
    std::fs::create_dir_all(&app_data_dir).map_err(|error| {
        AppError::Filesystem(
            "Failed to create app data directory".into(),
            error.to_string(),
        )
    })?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&app_data_dir, std::fs::Permissions::from_mode(0o700)).map_err(
            |error| {
                AppError::Filesystem(
                    "Failed to protect app data directory".into(),
                    error.to_string(),
                )
            },
        )?;
    }
    Ok(Box::new(FsStorage::new(app_data_dir)))
}
