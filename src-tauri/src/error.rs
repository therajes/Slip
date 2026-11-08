use idevice::IdeviceError;
use isideload::SideloadError;
use rootcause::Report;
use serde::Serialize;
use serde::ser::{SerializeStruct, Serializer};

#[derive(Debug, thiserror::Error, Clone, strum::AsRefStr)]
#[strum(serialize_all = "snake_case")]
pub enum AppError {
    #[error("{0}")]
    InvalidArchive(String),
    #[error("{0}")]
    Encrypted(String),
    #[error("{0}")]
    EntitlementUnsupported(String),
    #[error("{0}")]
    SourceMissing(String),
    #[error("{0}")]
    MaxApps(String),
    #[error("{0}")]
    NotEnoughAppIds(String),
    #[error("{0}")]
    DeviceComs(String),
    #[error("{0}")]
    Underage(String),
    #[error("{0}")]
    AccountLocked(String),
    #[error("{0}")]
    Developer(String),
    #[error("{0}")]
    Auth(String),
    #[error("{0}")]
    Download(String),
    #[error("{0}: {1}")]
    HouseArrest(String, String),
    #[error("{0}")]
    RemotePairing(String),
    #[error("{0}: {1}")]
    LockdownPairing(String, String),
    #[error("{0} canceled")]
    Canceled(String),
    #[error("Failed to emit status to frontend: {0}")]
    OperationUpdate(String),
    #[error("{0}: {1}")]
    DeviceComsWithMessage(String, String),
    #[error("{0}: {1}")]
    Usbmuxd(String, String),
    #[error("Not logged in")]
    NotLoggedIn,
    #[error("No device selected")]
    NoDeviceSelected,
    #[error("{0}")]
    Anisette(String),
    #[error("{0}")]
    Keyring(String),
    #[error("Keyring error: {0} - {1}")]
    KeyringWithMessage(String, String),
    #[error("{0}: {1}")]
    Storage(String, String),
    #[error("{0}")]
    Misc(String),
    #[error("{0}: {1}")]
    Filesystem(String, String),
}

impl AppError {
    /// Returns a concise, plain-English summary of the error — no Rust
    /// internal details, no stack traces. The frontend shows this first;
    /// the raw chain is kept in `message` for the "More Details" panel.
    pub fn human_message(&self) -> String {
        match self {
            AppError::InvalidArchive(message) | AppError::Encrypted(message) | AppError::EntitlementUnsupported(message) | AppError::SourceMissing(message) => message.clone(),
            AppError::NotLoggedIn => {
                "You need to sign in with your Apple Account before installing.".into()
            }
            AppError::NoDeviceSelected => {
                "No iPhone is selected. Pick your device from the list and try again.".into()
            }
            AppError::Auth(msg) => {
                let lower = msg.to_lowercase();
                if lower.contains("429") || lower.contains("too many") || lower.contains("-22979") || lower.contains("-22981") {
                    "Apple is limiting sign-in or verification requests. Wait a few minutes before trying again; requesting more codes can extend the delay.".into()
                } else if lower.contains("additional authentication") {
                    "Apple needs an additional account security step. Sign in at account.apple.com to complete it, then try again in Slip.".into()
                } else if lower.contains("503") || lower.contains("service temporarily unavailable") {
                    "Apple's sign-in service (GrandSlam) is temporarily unavailable (HTTP 503). Please wait a few moments and try again.".into()
                } else if lower.contains("two-factor") || lower.contains("2fa") || lower.contains("verification") {
                    "Apple rejected the two-factor code. Make sure you entered it correctly and try signing in again.".into()
                } else if lower.contains("password") || lower.contains("credentials") || lower.contains("incorrect") {
                    "Apple rejected the password. Double-check your Apple Account email and password, then try again.".into()
                } else {
                    let cleaned = crate::headless::user_facing_error(msg);
                    if cleaned.is_empty() || cleaned == "misc" {
                        "Apple rejected the sign-in. Check your credentials and try again.".into()
                    } else {
                        cleaned
                    }
                }
            }
            AppError::AccountLocked(_) => {
                "Your Apple Account is temporarily locked due to too many failed attempts. Visit appleid.apple.com to unlock it, then try again.".into()
            }
            AppError::Underage(_) => {
                "This Apple Account cannot use developer services because it is registered to someone under the minimum age.".into()
            }
            AppError::Anisette(msg) => {
                if msg.starts_with("This Mac authentication") {
                    msg.clone()
                } else if msg.contains("timed out") || msg.contains("timeout") {
                    "The Apple authentication service timed out. Check your internet connection and try again.".into()
                } else if msg.contains("connect") || msg.contains("network") {
                    "Could not reach the Apple authentication service. Make sure you are online and the anisette server is reachable.".into()
                } else {
                    "Apple authentication preparation failed. Try a different authentication service under Apple Accounts, or check your internet connection.".into()
                }
            }
            AppError::DeviceComs(msg) | AppError::DeviceComsWithMessage(msg, _) => {
                if msg.contains("lock") || msg.contains("trust") || msg.contains("pair") {
                    "Your iPhone is locked or hasn't trusted this Mac yet. Unlock it, go to the home screen, and accept any 'Trust This Computer' prompt.".into()
                } else if msg.contains("connect") || msg.contains("socket") || msg.contains("refused") {
                    "Lost connection to the iPhone mid-transfer. Unplug and reconnect the cable, then try again.".into()
                } else if msg.contains("Installation Proxy") || msg.contains("rejected") {
                    "The iPhone rejected the app installation. Make sure there is enough storage and that the app is compatible with your iOS version.".into()
                } else {
                    "Communication with the iPhone failed. Reconnect the cable, unlock your device, and try again.".into()
                }
            }
            AppError::Usbmuxd(_, _) => {
                "Cannot talk to the iPhone driver. Make sure Apple Mobile Device Support (or libimobiledevice on Linux) is running.".into()
            }
            AppError::Developer(msg) => {
                let lower = msg.to_lowercase();
                if lower.contains("7460") || lower.contains("maximum number of certificates") {
                    "Your signing certificate limit has been reached. Select a certificate to revoke when prompted, or open Apple Accounts to review certificates. Revocation can stop other apps signed with that certificate from opening.".into()
                } else if lower.contains("1100") || (lower.contains("session") && lower.contains("expired")) {
                    "Your Apple Developer session has expired. Sign in again; if Apple still rejects it, accept the Developer Agreement at developer.apple.com.".into()
                } else if lower.contains("invalid bundle") || lower.contains("invalid identifier") {
                    "Apple rejected the bundle ID. Make sure it uses only letters, numbers, and dots (e.g. com.example.App).".into()
                } else if lower.contains("entitlement") {
                    "An app entitlement is not allowed on a free Apple Account. Remove unsupported capabilities and try again.".into()
                } else {
                    let cleaned = crate::headless::user_facing_error(msg);
                    if !cleaned.is_empty()
                        && cleaned != "misc"
                        && cleaned != "An unexpected error occurred during Apple authentication or installation. Please check your iPhone connection and credentials, then try again."
                    {
                        cleaned
                    } else {
                        "Apple's developer service returned an error. Try signing out and back in, or wait a few minutes and try again.".into()
                    }
                }
            }
            AppError::NotEnoughAppIds(_) => {
                "You've used the available free App IDs. Review them under Apple Accounts → App IDs, or wait for them to expire. Apple may keep the weekly limit in place even after an App ID is deleted.".into()
            }
            AppError::MaxApps(_) => {
                "A free Apple Account can only have 3 sideloaded apps installed at once. Delete one of your existing sideloaded apps from the iPhone and try again.".into()
            }
            AppError::Download(msg) => {
                if msg.contains("404") || msg.contains("Not Found") {
                    "The download link returned 'Not Found'. The release may have moved — check the project's GitHub for a new link.".into()
                } else if msg.contains("timeout") || msg.contains("timed out") {
                    "The download timed out. Check your internet connection and try again.".into()
                } else {
                    "The download failed. Check your internet connection and try again.".into()
                }
            }
            AppError::HouseArrest(_, _) => {
                "Could not access the app's document folder on your iPhone. Reconnect the device and make sure it is unlocked and trusted.".into()
            }
            AppError::RemotePairing(_) | AppError::LockdownPairing(_, _) => {
                "Pairing with the iPhone failed. Make sure the device is unlocked, has a passcode set, and has accepted the trust prompt on screen.".into()
            }
            AppError::Canceled(_) => {
                "The operation was canceled.".into()
            }
            AppError::Keyring(_) | AppError::KeyringWithMessage(_, _) => {
                "Could not access the Mac Keychain to save or read credentials. Try enabling the \"Don\u{2019}t use keyring\" option in Settings.".into()

            }
            AppError::Storage(_, _) => {
                "Could not read or write the app's local storage. Make sure the app has disk permission and there is free space available.".into()
            }
            AppError::Filesystem(context, detail) => {
                if detail.contains("permission") || detail.contains("denied") {
                    format!("{}: Permission denied. Make sure the app can access that folder.", context)
                } else if detail.contains("space") || detail.contains("quota") || detail.contains("ENOSPC") {
                    format!("{}: Not enough disk space. Free up some space and try again.", context)
                } else {
                    format!("{}: A file system error occurred. Check that the file exists and is readable.", context)
                }
            }
            AppError::OperationUpdate(_) => {
                "The app failed to update its own progress display. The operation may have completed successfully — check your iPhone.".into()
            }
            AppError::Misc(msg) => {
                crate::headless::user_facing_error(msg)
            }


        }
    }
}

impl Serialize for AppError {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        let mut state = serializer.serialize_struct("AppError", 3)?;
        state.serialize_field("type", self.as_ref())?;
        state.serialize_field("message", &self.to_string())?;
        state.serialize_field("humanMessage", &self.human_message())?;
        state.end()
    }
}

// from rootcause report
impl From<Report> for AppError {
    fn from(report: Report) -> Self {
        let report_str = report.to_string();
        if report_str
            .to_lowercase()
            .contains("certificate selection canceled")
        {
            return AppError::Canceled("Certificate selection".into());
        }

        for cause in report.iter_reports() {
            #[cfg(feature = "tauri-ui")]
            if cause.downcast_current_context::<keyring::Error>().is_some() {
                return AppError::Keyring(report_str);
            }
            if let Some(err) = cause.downcast_current_context::<SideloadError>() {
                match err {
                    &SideloadError::AuthWithMessage(code, _) => match code {
                        -20209 => return AppError::AccountLocked(report_str),
                        _ => {
                            return AppError::Auth(report_str);
                        }
                    },
                    &SideloadError::DeveloperError(code, _) => match code {
                        1102 => return AppError::Underage(report_str),
                        _ => {
                            return AppError::Developer(report_str);
                        }
                    },
                    SideloadError::IdeviceError(idev_err) => match idev_err {
                        IdeviceError::Socket(_) => {
                            return AppError::DeviceComs(report_str);
                        }
                        IdeviceError::ApplicationVerificationFailed(e) => {
                            if e.contains("maximum number of installed apps") {
                                return AppError::MaxApps(report_str);
                            }
                        }
                        _ => {}
                    },
                    _ => {}
                }
            }
            let cause_str = cause.to_string();
            if cause_str.contains("Not enough available app IDs") {
                return AppError::NotEnoughAppIds(report_str);
            }
            if cause_str.contains("Failed to get anisette data for login")
                || cause_str.contains("Failed to get anisette client info")
                || cause_str.contains("Failed to get anisette headers")
            {
                return AppError::Anisette(report_str);
            }
        }

        AppError::Misc(report_str)
    }
}

impl AppError {
    pub fn diagnostic_payload(&self) -> serde_json::Value {
        let (code, phase, retryable, recovery) = match self {
            Self::InvalidArchive(_) => ("ipa.invalid_archive", "inspect", false, "locateIPA"),
            Self::Encrypted(_) => ("ipa.encrypted", "inspect", false, "locateIPA"),
            Self::EntitlementUnsupported(_) => ("signing.entitlement_unsupported", "sign", false, "reviewEntitlements"),
            Self::SourceMissing(_) => ("refresh.source_missing", "inspect", false, "locateIPA"),
            Self::Canceled(_) => ("operation.cancelled", "operation", false, "detailedDiagnostics"),
            Self::NotEnoughAppIds(_) | Self::MaxApps(_) => ("account.app_id_capacity", "account", false, "refreshResources"),
            Self::Auth(_) | Self::NotLoggedIn | Self::AccountLocked(_) | Self::Underage(_) | Self::Anisette(_) => ("authentication.interaction_required", "authenticate", false, "openAccounts"),
            Self::RemotePairing(_) | Self::LockdownPairing(_, _) => ("device.untrusted", "device", false, "connectUSB"),
            Self::DeviceComs(_) | Self::DeviceComsWithMessage(_, _) | Self::Usbmuxd(_, _) | Self::NoDeviceSelected => ("device.disconnected", "device", true, "retryDiscovery"),
            Self::Download(_) => ("network.timeout", "download", true, "retrySafely"),
            _ => ("operation.unknown", "operation", false, "detailedDiagnostics"),
        };
        serde_json::json!({"schemaVersion":1,"code":code,"phase":phase,"severity":"error","retryable":retryable,"recovery":recovery})
    }
}

#[cfg(test)]
mod diagnostic_boundary_tests {
    use super::*;
    #[test]
    fn originating_categories_do_not_depend_on_message_text() {
        for (error, expected) in [
            (AppError::InvalidArchive("arbitrary private context".into()), "ipa.invalid_archive"),
            (AppError::Encrypted("arbitrary".into()), "ipa.encrypted"),
            (AppError::EntitlementUnsupported("arbitrary".into()), "signing.entitlement_unsupported"),
            (AppError::SourceMissing("arbitrary".into()), "refresh.source_missing"),
        ] {
            let payload = error.diagnostic_payload();
            assert_eq!(payload["code"], expected);
            assert!(!payload.to_string().contains("arbitrary"));
        }
    }
}
