use std::path::{Component, Path, PathBuf};

use rootcause::prelude::*;

use crate::util::storage::SideloadingStorage;

pub struct FsStorage {
    path: PathBuf,
}

impl FsStorage {
    pub fn new(path: PathBuf) -> Self {
        FsStorage { path }
    }

    fn key_path(&self, key: &str) -> Result<PathBuf, Report> {
        let key = Path::new(key);
        if key.as_os_str().is_empty()
            || !key
                .components()
                .all(|part| matches!(part, Component::Normal(_)))
        {
            bail!("Invalid storage key path");
        }
        Ok(self.path.join(key))
    }

    #[cfg(unix)]
    fn private_path(&self, key: &str, create: bool) -> std::io::Result<PathBuf> {
        use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
        if create {
            std::fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(&self.path)?;
        }
        // The configured root can contain normal system aliases (e.g. /var on
        // macOS), but key components may never redirect outside that root.
        let root = std::fs::canonicalize(&self.path)?;
        if !std::fs::metadata(&root)?.is_dir() {
            return Err(std::io::ErrorKind::NotADirectory.into());
        }
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700))?;
        let mut current = root;
        let mut components = Path::new(key).components().peekable();
        while let Some(part) = components.next() {
            current.push(part.as_os_str());
            if components.peek().is_none() {
                break;
            }
            if create {
                match std::fs::DirBuilder::new().mode(0o700).create(&current) {
                    Ok(()) => {}
                    Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
                    Err(error) => return Err(error),
                }
            }
            let metadata = std::fs::symlink_metadata(&current)?;
            if !metadata.is_dir() || metadata.file_type().is_symlink() {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidInput,
                    "Storage key parent must be a directory without symbolic links",
                ));
            }
            std::fs::set_permissions(&current, std::fs::Permissions::from_mode(0o700))?;
        }
        Ok(current)
    }
}

#[cfg(unix)]
fn private_atomic_write(path: &Path, data: &[u8]) -> std::io::Result<()> {
    use std::{
        io::Write,
        os::unix::fs::OpenOptionsExt,
        sync::atomic::{AtomicU64, Ordering},
    };
    static NEXT_FILE: AtomicU64 = AtomicU64::new(0);
    match std::fs::symlink_metadata(path) {
        Ok(metadata) if !metadata.is_file() || metadata.file_type().is_symlink() => {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "Storage key must be a file without symbolic links",
            ));
        }
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    let parent = path.parent().ok_or(std::io::ErrorKind::InvalidInput)?;
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let temporary = parent.join(format!(
        ".slip-storage-{}-{stamp}-{}.tmp",
        std::process::id(),
        NEXT_FILE.fetch_add(1, Ordering::Relaxed)
    ));
    let result = (|| {
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temporary)?;
        file.write_all(data)?;
        file.sync_all()?;
        // Replacement gives existing files the same private mode, without a
        // truncate/write interval exposing partial keys to another operation.
        std::fs::rename(&temporary, path)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    result
}

impl Default for FsStorage {
    fn default() -> Self {
        Self::new(PathBuf::from("."))
    }
}

impl SideloadingStorage for FsStorage {
    fn store_data(&self, key: &str, data: &[u8]) -> Result<(), Report> {
        self.key_path(key)?;
        #[cfg(unix)]
        {
            let path = self
                .private_path(key, true)
                .context("Failed to protect storage directory")?;
            private_atomic_write(&path, data).context("Failed to write private storage file")?;
        }
        #[cfg(not(unix))]
        {
            let path = self.path.join(key);
            let parent = path.parent().unwrap_or(Path::new("."));
            isideload_vfs::fs::create_dir_all(parent)
                .context("Failed to create storage directory")?;
            isideload_vfs::fs::write(&path, data).context("Failed to write data to file")?;
        }
        Ok(())
    }

    fn retrieve_data(&self, key: &str) -> Result<Option<Vec<u8>>, Report> {
        self.key_path(key)?;
        #[cfg(unix)]
        let result = (|| {
            use std::{io::Read, os::unix::fs::PermissionsExt};
            let path = self.private_path(key, false)?;
            let metadata = std::fs::symlink_metadata(&path)?;
            if !metadata.is_file() || metadata.file_type().is_symlink() {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidInput,
                    "Storage key must be a file without symbolic links",
                ));
            }
            let mut file = std::fs::File::open(path)?;
            file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
            let mut data = Vec::new();
            file.read_to_end(&mut data)?;
            Ok(data)
        })();
        #[cfg(not(unix))]
        let result = isideload_vfs::fs::read(self.path.join(key));
        match result {
            Ok(data) => Ok(Some(data)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(report!(e).context("Failed to read data from file").into()),
        }
    }

    fn store(&self, key: &str, value: &str) -> Result<(), Report> {
        self.store_data(key, value.as_bytes())
    }

    fn retrieve(&self, key: &str) -> Result<Option<String>, Report> {
        match self.retrieve_data(key) {
            Ok(Some(data)) => Ok(Some(String::from_utf8_lossy(&data).into_owned())),
            Ok(None) => Ok(None),
            Err(e) => Err(e),
        }
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::{
        io::Read,
        os::unix::fs::{PermissionsExt, symlink},
    };

    fn fixture_directory() -> PathBuf {
        let directory = std::env::temp_dir().join(format!(
            "slip-fs-private-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir(&directory).unwrap();
        directory
    }

    #[test]
    fn private_storage_hardens_legacy_files_and_atomically_replaces_them() {
        let directory = fixture_directory();
        let nested = directory.join("nested");
        std::fs::create_dir(&nested).unwrap();
        std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o755)).unwrap();
        std::fs::set_permissions(&nested, std::fs::Permissions::from_mode(0o755)).unwrap();
        let key = nested.join("fixture-key");
        std::fs::write(&key, b"old-synthetic-value").unwrap();
        std::fs::set_permissions(&key, std::fs::Permissions::from_mode(0o644)).unwrap();
        let storage = FsStorage::new(directory.clone());
        assert_eq!(
            storage
                .retrieve_data("nested/fixture-key")
                .unwrap()
                .unwrap(),
            b"old-synthetic-value"
        );
        for (path, mode) in [(&directory, 0o700), (&nested, 0o700), (&key, 0o600)] {
            assert_eq!(
                std::fs::metadata(path).unwrap().permissions().mode() & 0o777,
                mode
            );
        }
        let mut old_reader = std::fs::File::open(&key).unwrap();
        storage
            .store_data("nested/fixture-key", b"new-synthetic-value")
            .unwrap();
        let mut old_value = Vec::new();
        old_reader.read_to_end(&mut old_value).unwrap();
        assert_eq!(
            old_value, b"old-synthetic-value",
            "Atomic replacement preserves a reader's complete prior version"
        );
        assert_eq!(std::fs::read(&key).unwrap(), b"new-synthetic-value");
        assert_eq!(
            std::fs::metadata(&key).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(
            std::fs::read_dir(&nested).unwrap().count(),
            1,
            "Temporary write files must not remain"
        );
        storage
            .store_data("created/parents/fixture-key", b"synthetic")
            .unwrap();
        for path in [directory.join("created"), directory.join("created/parents")] {
            assert_eq!(
                std::fs::metadata(path).unwrap().permissions().mode() & 0o777,
                0o700
            );
        }
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn storage_keys_cannot_traverse_or_follow_links_outside_the_root() {
        let directory = fixture_directory();
        let outside = fixture_directory();
        let outside_key = outside.join("fixture-key");
        std::fs::write(&outside_key, b"unchanged-synthetic-value").unwrap();
        let storage = FsStorage::new(directory.clone());
        for key in [
            "",
            ".",
            "..",
            "../fixture-key",
            "nested/../../fixture-key",
            "/tmp/fixture-key",
        ] {
            assert!(storage.store_data(key, b"rejected").is_err());
            assert!(storage.retrieve_data(key).is_err());
        }
        symlink(&outside, directory.join("linked-parent")).unwrap();
        assert!(
            storage
                .store_data("linked-parent/fixture-key", b"rejected")
                .is_err()
        );
        assert!(storage.retrieve_data("linked-parent/fixture-key").is_err());
        symlink(&outside_key, directory.join("linked-key")).unwrap();
        assert!(storage.store_data("linked-key", b"rejected").is_err());
        assert!(storage.retrieve_data("linked-key").is_err());
        assert_eq!(
            std::fs::read(outside_key).unwrap(),
            b"unchanged-synthetic-value"
        );
        std::fs::remove_dir_all(directory).unwrap();
        std::fs::remove_dir_all(outside).unwrap();
    }
}
