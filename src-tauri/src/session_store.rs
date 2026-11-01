//! Developer tokens are stored in macOS Keychain. The on-disk record contains
//! only an account/provider-bound reference; removing it immediately invalidates reuse.
use crate::error::AppError;
use isideload::auth::apple_account::AppToken;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    io::Write,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

pub(crate) const SESSION_SERVICE: &str = "com.slip.authentication.developer-session";
#[derive(Serialize, Deserialize)]
struct SessionSecret {
    token: AppToken,
    adsid: String,
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SessionMetadata {
    version: u8,
    email: String,
    provider: String,
    keychain_reference: String,
    generation: String,
}

trait CredentialVault {
    fn put(&self, reference: &str, secret: &[u8]) -> Result<(), AppError>;
    fn get(&self, reference: &str) -> Option<Vec<u8>>;
    fn remove(&self, reference: &str);
}
struct SystemVault;
#[cfg(target_os = "macos")]
impl CredentialVault for SystemVault {
    fn put(&self, reference: &str, secret: &[u8]) -> Result<(), AppError> {
        security_framework::passwords::set_generic_password(SESSION_SERVICE, reference, secret)
            .map_err(|_| {
                AppError::Keyring(
                    "Unable to save the Developer session securely in Keychain.".into(),
                )
            })
    }
    fn get(&self, reference: &str) -> Option<Vec<u8>> {
        security_framework::passwords::get_generic_password(SESSION_SERVICE, reference).ok()
    }
    fn remove(&self, reference: &str) {
        let _ = security_framework::passwords::delete_generic_password(SESSION_SERVICE, reference);
    }
}
#[cfg(not(target_os = "macos"))]
impl CredentialVault for SystemVault {
    fn put(&self, _: &str, _: &[u8]) -> Result<(), AppError> {
        Err(AppError::Keyring(
            "Secure session persistence requires macOS Keychain.".into(),
        ))
    }
    fn get(&self, _: &str) -> Option<Vec<u8>> {
        None
    }
    fn remove(&self, _: &str) {}
}

fn reference(storage: &Path, email: &str, provider: &str, generation: &str) -> String {
    let mut digest = Sha256::new();
    for value in [
        storage.to_string_lossy().as_ref(),
        &email.to_lowercase(),
        provider,
        generation,
    ] {
        digest.update(value.as_bytes());
        digest.update([0]);
    }
    digest
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}
fn metadata_path(storage: &Path) -> PathBuf {
    storage.join("dev_session.json")
}

fn write_atomic(path: &Path, value: &[u8]) -> std::io::Result<()> {
    let parent = path.parent().ok_or(std::io::ErrorKind::InvalidInput)?;
    std::fs::create_dir_all(parent)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700))?;
    }
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let temporary = parent.join(format!(".dev-session-{}-{stamp}.tmp", std::process::id()));
    let result = (|| {
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&temporary)?;
        file.write_all(value)?;
        file.sync_all()?;
        std::fs::rename(&temporary, path)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    result
}

fn save_with(
    vault: &impl CredentialVault,
    storage: &Path,
    email: &str,
    provider: &str,
    token: AppToken,
    adsid: String,
) -> Result<(), AppError> {
    save_using(vault, storage, email, provider, token, adsid, write_atomic)
}

fn save_using(
    vault: &impl CredentialVault,
    storage: &Path,
    email: &str,
    provider: &str,
    token: AppToken,
    adsid: String,
    writer: fn(&Path, &[u8]) -> std::io::Result<()>,
) -> Result<(), AppError> {
    let previous = std::fs::read(metadata_path(storage))
        .ok()
        .and_then(|bytes| serde_json::from_slice::<SessionMetadata>(&bytes).ok());
    let generation = format!(
        "{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
    );
    let reference = reference(storage, email, provider, &generation);
    let secret = serde_json::to_vec(&SessionSecret { token, adsid })
        .map_err(|_| AppError::Storage("Unable to encode Developer session".into(), "".into()))?;
    vault.put(&reference, &secret)?;
    let metadata = SessionMetadata {
        version: 1,
        email: email.to_lowercase(),
        provider: provider.into(),
        keychain_reference: reference.clone(),
        generation,
    };
    let encoded = serde_json::to_vec(&metadata)
        .map_err(|_| AppError::Storage("Unable to encode session reference".into(), "".into()))?;
    if writer(&metadata_path(storage), &encoded).is_err() {
        vault.remove(&reference);
        return Err(AppError::Storage(
            "Unable to save session reference".into(),
            "".into(),
        ));
    }
    if let Some(previous) = previous
        && previous.version == 1
        && previous.keychain_reference
            == self::reference(
                storage,
                &previous.email,
                &previous.provider,
                &previous.generation,
            )
        && previous.keychain_reference != reference
    {
        vault.remove(&previous.keychain_reference);
    }
    Ok(())
}
fn load_with(
    vault: &impl CredentialVault,
    storage: &Path,
    email: &str,
    provider: &str,
) -> Option<(AppToken, String)> {
    let data = std::fs::read(metadata_path(storage)).ok()?;
    // Legacy plaintext tokens have no reliable provider identity. They cannot be
    // migrated across providers safely: invalidate them and require one fresh sign-in.
    let metadata: SessionMetadata = match serde_json::from_slice(&data) {
        Ok(value) => value,
        Err(_) => {
            let _ = std::fs::remove_file(metadata_path(storage));
            return None;
        }
    };
    let expected = reference(storage, email, provider, &metadata.generation);
    if metadata.version != 1
        || !metadata.email.eq_ignore_ascii_case(email)
        || metadata.provider != provider
        || metadata.keychain_reference != expected
    {
        return None;
    }
    let bytes = vault.get(&expected)?;
    let secret: SessionSecret = serde_json::from_slice(&bytes).ok()?;
    Some((secret.token, secret.adsid))
}

pub(crate) fn save(
    storage: &str,
    email: &str,
    provider: &str,
    token: AppToken,
    adsid: String,
) -> Result<(), AppError> {
    save_with(
        &SystemVault,
        Path::new(storage),
        email,
        provider,
        token,
        adsid,
    )
}
pub(crate) fn load(storage: &str, email: &str, provider: &str) -> Option<(AppToken, String)> {
    load_with(&SystemVault, Path::new(storage), email, provider)
}
pub(crate) fn invalidate(storage: &str, email: &str, provider: &str) {
    let storage = Path::new(storage);
    let metadata = std::fs::read(metadata_path(storage))
        .ok()
        .and_then(|bytes| serde_json::from_slice::<SessionMetadata>(&bytes).ok());
    if let Some(metadata) = metadata
        && metadata.version == 1
        && metadata.email.eq_ignore_ascii_case(email)
        && metadata.provider == provider
        && metadata.keychain_reference == reference(storage, email, provider, &metadata.generation)
    {
        // Make reuse impossible even if Keychain is locked and deletion fails.
        let _ = std::fs::remove_file(metadata_path(storage));
        SystemVault.remove(&metadata.keychain_reference);
    }
}

/// Invalidate the current provider-bound reference after a downstream Developer
/// request explicitly reports expiry, without needing to recreate provider state.
pub(crate) fn invalidate_stored(storage: &str) {
    let path = Path::new(storage);
    let metadata = std::fs::read(metadata_path(path))
        .ok()
        .and_then(|bytes| serde_json::from_slice::<SessionMetadata>(&bytes).ok());
    if let Some(metadata) = metadata {
        invalidate(storage, &metadata.email, &metadata.provider);
    } else {
        let _ = std::fs::remove_file(metadata_path(path));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{collections::HashMap, sync::Mutex};
    #[derive(Default)]
    struct FakeVault(Mutex<HashMap<String, Vec<u8>>>);
    impl CredentialVault for FakeVault {
        fn put(&self, key: &str, value: &[u8]) -> Result<(), AppError> {
            self.0.lock().unwrap().insert(key.into(), value.into());
            Ok(())
        }
        fn get(&self, key: &str) -> Option<Vec<u8>> {
            self.0.lock().unwrap().get(key).cloned()
        }
        fn remove(&self, key: &str) {
            self.0.lock().unwrap().remove(key);
        }
    }
    fn fixture_dir() -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "slip-session-test-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }
    #[test]
    fn secret_is_vault_only_and_metadata_invalidates_reuse() {
        let vault = FakeVault::default();
        let dir = fixture_dir();
        save_with(
            &vault,
            &dir,
            "fixture@invalid.local",
            "remote:https://a.example",
            AppToken {
                token: "secret-fixture".into(),
                duration: 1,
                expiry: 1,
            },
            "secret-adsid".into(),
        )
        .unwrap();
        let bytes = std::fs::read(metadata_path(&dir)).unwrap();
        let text = String::from_utf8(bytes).unwrap();
        assert!(!text.contains("secret-fixture"));
        assert!(!text.contains("secret-adsid"));
        assert!(text.contains("keychainReference"));
        assert!(
            load_with(
                &vault,
                &dir,
                "FIXTURE@invalid.local",
                "remote:https://a.example"
            )
            .is_some()
        );
        assert!(
            load_with(
                &vault,
                &dir,
                "fixture@invalid.local",
                "remote:https://b.example"
            )
            .is_none()
        );
        assert!(
            load_with(
                &vault,
                &dir,
                "other@invalid.local",
                "remote:https://a.example"
            )
            .is_none()
        );
        std::fs::remove_file(metadata_path(&dir)).unwrap();
        assert!(
            load_with(
                &vault,
                &dir,
                "fixture@invalid.local",
                "remote:https://a.example"
            )
            .is_none()
        );
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn failed_metadata_commit_preserves_the_previous_secret_and_reference() {
        let vault = FakeVault::default();
        let dir = fixture_dir();
        let token = |value: &str| AppToken {
            token: value.into(),
            duration: 1,
            expiry: 1,
        };
        save_with(
            &vault,
            &dir,
            "fixture@invalid.local",
            "local-macos",
            token("old-secret"),
            "fixture".into(),
        )
        .unwrap();
        let old_metadata = std::fs::read(metadata_path(&dir)).unwrap();
        fn fail_write(_: &Path, _: &[u8]) -> std::io::Result<()> {
            Err(std::io::ErrorKind::PermissionDenied.into())
        }
        assert!(
            save_using(
                &vault,
                &dir,
                "fixture@invalid.local",
                "local-macos",
                token("new-secret"),
                "fixture".into(),
                fail_write
            )
            .is_err()
        );
        assert_eq!(std::fs::read(metadata_path(&dir)).unwrap(), old_metadata);
        assert_eq!(
            load_with(&vault, &dir, "fixture@invalid.local", "local-macos")
                .unwrap()
                .0
                .token,
            "old-secret"
        );
        assert_eq!(vault.0.lock().unwrap().len(), 1);
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn successful_provider_change_removes_the_old_vault_secret() {
        let vault = FakeVault::default();
        let dir = fixture_dir();
        for provider in ["remote:https://a.example", "remote:https://b.example"] {
            save_with(
                &vault,
                &dir,
                "fixture@invalid.local",
                provider,
                AppToken {
                    token: "fixture".into(),
                    duration: 1,
                    expiry: 1,
                },
                "fixture".into(),
            )
            .unwrap();
        }
        assert_eq!(vault.0.lock().unwrap().len(), 1);
        assert!(
            load_with(
                &vault,
                &dir,
                "fixture@invalid.local",
                "remote:https://b.example"
            )
            .is_some()
        );
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[cfg(unix)]
    #[test]
    fn metadata_has_private_permissions_and_atomic_replacement() {
        use std::os::unix::fs::PermissionsExt;
        let dir = fixture_dir();
        let path = metadata_path(&dir);
        write_atomic(&path, b"first").unwrap();
        write_atomic(&path, b"second").unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"second");
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(
            std::fs::metadata(&dir).unwrap().permissions().mode() & 0o777,
            0o700
        );
        assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 1);
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn legacy_plaintext_cache_is_not_used_with_an_unknown_provider() {
        let dir = fixture_dir();
        std::fs::write(metadata_path(&dir),br#"{"email":"fixture@invalid.local","token":{"token":"fixture","duration":1,"expiry":1},"adsid":"fixture"}"#).unwrap();
        assert!(
            load_with(
                &FakeVault::default(),
                &dir,
                "fixture@invalid.local",
                "local-macos"
            )
            .is_none()
        );
        assert!(!metadata_path(&dir).exists());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
