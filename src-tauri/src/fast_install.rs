use std::{
    fs::{self, File, OpenOptions},
    io::{BufReader, BufWriter},
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

use idevice::{
    IdeviceService,
    afc::{AfcClient, opcode::AfcFopenMode},
    installation_proxy::InstallationProxyClient,
    provider::IdeviceProvider,
};
use plist_macro::plist;
use tracing::info;
use zip::{CompressionMethod, ZipWriter, write::SimpleFileOptions};

use crate::error::AppError;

const REMOTE_IPA: &str = "PublicStaging/Slip.ipa";
const TRANSFER_CHUNK: usize = 1024 * 1024;
const DEVICE_IO_TIMEOUT: Duration = Duration::from_secs(30);
const INSTALL_TIMEOUT: Duration = Duration::from_secs(15 * 60);

fn zip_path(path: &Path) -> String {
    path.to_string_lossy().replace('\\', "/")
}

fn is_already_compressed(path: &Path) -> bool {
    matches!(
        path.extension()
            .and_then(|extension| extension.to_str())
            .map(|extension| extension.to_ascii_lowercase())
            .as_deref(),
        Some(
            "png"
                | "jpg"
                | "jpeg"
                | "webp"
                | "gif"
                | "heic"
                | "heif"
                | "mp3"
                | "m4a"
                | "aac"
                | "mp4"
                | "mov"
                | "car"
                | "zip"
                | "gz"
                | "pdf"
        )
    )
}

fn add_tree(
    writer: &mut ZipWriter<BufWriter<File>>,
    source: &Path,
    archive_path: &Path,
) -> Result<(), AppError> {
    let metadata = fs::symlink_metadata(source).map_err(|error| {
        AppError::Filesystem("Unable to inspect signed app".into(), error.to_string())
    })?;
    let permissions = metadata.permissions().mode();
    let archive_name = zip_path(archive_path);

    if metadata.file_type().is_symlink() {
        let target = fs::read_link(source).map_err(|error| {
            AppError::Filesystem("Unable to read app symlink".into(), error.to_string())
        })?;
        writer
            .add_symlink(
                archive_name,
                zip_path(&target),
                SimpleFileOptions::default().unix_permissions(permissions),
            )
            .map_err(|error| AppError::Misc(format!("Unable to package app symlink: {error}")))?;
        return Ok(());
    }

    if metadata.is_dir() {
        writer
            .add_directory(
                format!("{}/", archive_name.trim_end_matches('/')),
                SimpleFileOptions::default().unix_permissions(permissions),
            )
            .map_err(|error| AppError::Misc(format!("Unable to package app directory: {error}")))?;
        let mut entries = fs::read_dir(source)
            .map_err(|error| {
                AppError::Filesystem("Unable to read signed app".into(), error.to_string())
            })?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|error| {
                AppError::Filesystem("Unable to read signed app entry".into(), error.to_string())
            })?;
        entries.sort_by_key(|entry| entry.file_name());
        for entry in entries {
            add_tree(writer, &entry.path(), &archive_path.join(entry.file_name()))?;
        }
        return Ok(());
    }

    let compression = if is_already_compressed(source) {
        CompressionMethod::Stored
    } else {
        CompressionMethod::Deflated
    };
    let compression_level = (compression == CompressionMethod::Deflated).then_some(1);
    writer
        .start_file(
            archive_name,
            SimpleFileOptions::default()
                .compression_method(compression)
                .compression_level(compression_level)
                .large_file(metadata.len() > u32::MAX as u64)
                .unix_permissions(permissions),
        )
        .map_err(|error| AppError::Misc(format!("Unable to add signed app file: {error}")))?;
    let mut input = BufReader::with_capacity(
        TRANSFER_CHUNK,
        File::open(source).map_err(|error| {
            AppError::Filesystem("Unable to open signed app file".into(), error.to_string())
        })?,
    );
    std::io::copy(&mut input, writer).map_err(|error| {
        AppError::Filesystem("Unable to package signed app".into(), error.to_string())
    })?;
    Ok(())
}

fn create_signed_ipa(signed_app: &Path, destination: &Path) -> Result<u64, AppError> {
    let app_name = signed_app
        .file_name()
        .ok_or_else(|| AppError::Misc("Signed app has no bundle name".into()))?;
    let output = BufWriter::with_capacity(
        TRANSFER_CHUNK,
        OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(destination)
            .map_err(|error| {
                AppError::Filesystem("Unable to create optimized IPA".into(), error.to_string())
            })?,
    );
    let mut writer = ZipWriter::new(output).set_auto_large_file();
    add_tree(
        &mut writer,
        signed_app,
        &PathBuf::from("Payload").join(app_name),
    )?;
    writer
        .finish()
        .map_err(|error| AppError::Misc(format!("Unable to finish optimized IPA: {error}")))?;
    fs::metadata(destination)
        .map(|metadata| metadata.len())
        .map_err(|error| {
            AppError::Filesystem("Unable to inspect optimized IPA".into(), error.to_string())
        })
}

fn device_error(context: &str, error: impl std::fmt::Display) -> AppError {
    AppError::DeviceComsWithMessage(context.to_string(), error.to_string())
}

pub async fn install_signed_app_fast_with_progress<F>(
    provider: &impl IdeviceProvider,
    signed_app: &Path,
    optimized_ipa: &Path,
    progress: F,
) -> Result<(), AppError>
where
    F: Fn(f32) + Clone + Send + Sync + 'static,
{
    progress(0.01);
    let package_size = if optimized_ipa.is_file() {
        fs::metadata(optimized_ipa)
            .map_err(|error| {
                AppError::Filesystem("Unable to inspect optimized IPA".into(), error.to_string())
            })?
            .len()
    } else {
        let signed_app = signed_app.to_path_buf();
        let optimized_ipa_for_packaging = optimized_ipa.to_path_buf();
        let package_started = Instant::now();
        let package_size = tokio::task::spawn_blocking(move || {
            create_signed_ipa(&signed_app, &optimized_ipa_for_packaging)
        })
        .await
        .map_err(|error| AppError::Misc(format!("Optimized packaging task failed: {error}")))??;
        let package_seconds = package_started.elapsed().as_secs_f64();
        info!(
            bytes = package_size,
            seconds = package_seconds,
            "Created single-file optimized IPA"
        );
        package_size
    };
    progress(0.08);

    let mut afc = tokio::time::timeout(DEVICE_IO_TIMEOUT, AfcClient::connect(provider))
        .await
        .map_err(|_| AppError::DeviceComs("Timed out opening native AFC transfer".into()))?
        .map_err(|error| device_error("Unable to open native AFC transfer", error))?;
    let staging_exists =
        tokio::time::timeout(DEVICE_IO_TIMEOUT, afc.get_file_info("PublicStaging"))
            .await
            .is_ok_and(|result| result.is_ok());
    if !staging_exists {
        tokio::time::timeout(DEVICE_IO_TIMEOUT, afc.mk_dir("PublicStaging"))
            .await
            .map_err(|_| AppError::DeviceComs("Timed out creating the device staging area".into()))?
            .map_err(|error| device_error("Unable to create device staging area", error))?;
    }
    let _ = tokio::time::timeout(DEVICE_IO_TIMEOUT, afc.remove(REMOTE_IPA)).await;
    let transfer_started = Instant::now();
    let transfer_result: Result<u64, AppError> = async {
        let mut remote = tokio::time::timeout(
            DEVICE_IO_TIMEOUT,
            afc.open(REMOTE_IPA, AfcFopenMode::WrOnly),
        )
        .await
        .map_err(|_| AppError::DeviceComs("Timed out opening the device package".into()))?
        .map_err(|error| device_error("Unable to open optimized device package", error))?;
        let mut local = tokio::fs::File::open(optimized_ipa)
            .await
            .map_err(|error| {
                AppError::Filesystem("Unable to open optimized IPA".into(), error.to_string())
            })?;
        let mut buffer = vec![0_u8; TRANSFER_CHUNK];
        let mut transferred = 0_u64;
        loop {
            use tokio::io::AsyncReadExt;
            let count = local.read(&mut buffer).await.map_err(|error| {
                AppError::Filesystem("Unable to read optimized IPA".into(), error.to_string())
            })?;
            if count == 0 {
                break;
            }
            tokio::time::timeout(DEVICE_IO_TIMEOUT, remote.write_entire(&buffer[..count]))
                .await
                .map_err(|_| AppError::DeviceComs("Native IPA transfer timed out".into()))?
                .map_err(|error| device_error("Native IPA transfer failed", error))?;
            transferred += count as u64;
            progress(0.08 + 0.70 * transferred as f32 / package_size.max(1) as f32);
        }
        tokio::time::timeout(DEVICE_IO_TIMEOUT, remote.close())
            .await
            .map_err(|_| {
                AppError::DeviceComs("Timed out finishing the native IPA transfer".into())
            })?
            .map_err(|error| device_error("Unable to finish native IPA transfer", error))?;
        Ok(transferred)
    }
    .await;
    let transferred = match transfer_result {
        Ok(transferred) => transferred,
        Err(error) => {
            let _ = tokio::time::timeout(DEVICE_IO_TIMEOUT, afc.remove(REMOTE_IPA)).await;
            return Err(error);
        }
    };
    let transfer_seconds = transfer_started.elapsed().as_secs_f64();
    info!(
        bytes = transferred,
        seconds = transfer_seconds,
        mib_per_second = transferred as f64 / 1_048_576.0 / transfer_seconds.max(0.001),
        "Single-file native transfer completed"
    );

    let mut installer = tokio::time::timeout(
        DEVICE_IO_TIMEOUT,
        InstallationProxyClient::connect(provider),
    )
    .await
    .map_err(|_| AppError::DeviceComs("Timed out starting Apple Installation Proxy".into()))?
    .map_err(|error| device_error("Unable to start Apple Installation Proxy", error))?;
    let install_progress = progress.clone();
    let install_result = tokio::time::timeout(
        INSTALL_TIMEOUT,
        installer.install_with_callback(
            REMOTE_IPA,
            Some(plist!({ "PackageType": "Developer" })),
            move |(percentage, _)| {
                let install_progress = install_progress.clone();
                async move {
                    install_progress(0.78 + percentage as f32 / 100.0 * 0.22);
                }
            },
            (),
        ),
    )
    .await
    .map_err(|_| AppError::DeviceComs("iPhone installation timed out".into()))?
    .map_err(|error| device_error("Apple Installation Proxy rejected the app", error));
    let _ = tokio::time::timeout(DEVICE_IO_TIMEOUT, afc.remove(REMOTE_IPA)).await;
    install_result?;
    progress(1.0);
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::{
        fs,
        io::Read,
        os::unix::fs::{PermissionsExt, symlink},
        time::{SystemTime, UNIX_EPOCH},
    };

    use zip::ZipArchive;

    use super::create_signed_ipa;

    #[test]
    fn packages_a_signed_app_with_permissions_and_symlinks() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("sideloom-package-test-{unique}"));
        let app = root.join("Example.app");
        let frameworks = app.join("Frameworks");
        let ipa = root.join("Example.ipa");
        fs::create_dir_all(&frameworks).unwrap();
        fs::write(app.join("Info.plist"), b"plist").unwrap();
        fs::write(app.join("Example"), b"executable").unwrap();
        fs::set_permissions(app.join("Example"), fs::Permissions::from_mode(0o755)).unwrap();
        symlink("../Example", frameworks.join("ExampleLink")).unwrap();

        let size = create_signed_ipa(&app, &ipa).unwrap();
        assert!(size > 0);
        let mut archive = ZipArchive::new(fs::File::open(&ipa).unwrap()).unwrap();
        let executable = archive.by_name("Payload/Example.app/Example").unwrap();
        assert_eq!(executable.unix_mode().unwrap() & 0o777, 0o755);
        drop(executable);
        let mut link = archive
            .by_name("Payload/Example.app/Frameworks/ExampleLink")
            .unwrap();
        let mut target = String::new();
        link.read_to_string(&mut target).unwrap();
        assert_eq!(target, "../Example");

        fs::remove_dir_all(root).unwrap();
    }
}
