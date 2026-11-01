// This file was made using https://github.com/Dadoum/Sideloader as a reference.
// I'm planning on redoing this later to better handle entitlements, extensions, etc, but it will do for now

use crate::SideloadError;
use crate::dev::app_ids::{AppId, AppIdsApi};
use crate::dev::developer_session::DeveloperSession;
use crate::dev::teams::DeveloperTeam;
use crate::sideload::bundle::Bundle;
use crate::sideload::cert_identity::CertificateIdentity;
use isideload_vfs::fs::File;
use rootcause::option_ext::OptionExt;
use rootcause::prelude::*;
use std::io::Write;
use std::path::PathBuf;
use tracing::{info, warn};
use zip::ZipArchive;

pub struct Application {
    pub bundle: Bundle,
    //pub temp_path: PathBuf,
}

impl Application {
    pub fn new(path: PathBuf) -> Result<Self, Report> {
        if !isideload_vfs::fs::metadata(&path).is_ok() {
            bail!(SideloadError::InvalidBundle(
                "Application path does not exist".to_string(),
            ));
        }

        let mut bundle_path = path.clone();
        //let mut temp_path = PathBuf::new();

        if isideload_vfs::fs::metadata(&bundle_path)?.is_file() {
            let temp_dir = isideload_vfs::fs::temp_dir();
            let temp_path = temp_dir.join(format!("slip-ipa-{}", uuid::Uuid::new_v4()));
            isideload_vfs::fs::create_dir_all(&temp_path)
                .context("Failed to create temporary directory")?;

            let file = File::open(&path).context("Failed to open application archive")?;
            let mut archive =
                ZipArchive::new(file).context("Failed to open application archive")?;

            // Validate the complete archive before extraction, including link destinations.
            // No archive member may be written through another member's symlink.
            let mut names = std::collections::HashSet::new();
            let mut symlinks = Vec::new();
            for index in 0..archive.len() {
                let mut entry = archive
                    .by_index(index)
                    .context("Failed to inspect application archive")?;
                let name = entry.name().trim_end_matches('/').to_string();
                if name.is_empty()
                    || name.contains('\\')
                    || name.contains('\0')
                    || name.split('/').any(|part| {
                        part.is_empty() || part == "." || part == ".." || part.contains(':')
                    })
                    || !names.insert(name.clone())
                {
                    bail!(SideloadError::InvalidBundle(format!(
                        "Unsafe or duplicate IPA archive path: {name:?}"
                    )));
                }
                if entry.unix_mode().unwrap_or(0) & 0o170000 == 0o120000 {
                    let mut target = String::new();
                    std::io::Read::read_to_string(&mut entry, &mut target)
                        .context("Failed to read IPA symbolic link")?;
                    let mut depth = name.split('/').count() - 1;
                    if target.is_empty()
                        || target.starts_with('/')
                        || target.contains('\\')
                        || target.contains('\0')
                    {
                        bail!(SideloadError::InvalidBundle(format!(
                            "Unsafe IPA symbolic link: {name}"
                        )));
                    }
                    for component in target.split('/') {
                        match component {
                            ".." => {
                                if depth == 0 {
                                    bail!(SideloadError::InvalidBundle(format!(
                                        "IPA symbolic link escapes the archive: {name}"
                                    )));
                                }
                                depth -= 1;
                            }
                            "." | "" => {}
                            value if value.contains(':') => {
                                bail!(SideloadError::InvalidBundle(format!(
                                    "Unsafe IPA symbolic link: {name}"
                                )));
                            }
                            _ => depth += 1,
                        }
                    }
                    symlinks.push((name, target));
                }
            }
            for (name, _) in &symlinks {
                let prefix = format!("{name}/");
                if names.iter().any(|member| member.starts_with(&prefix)) {
                    bail!(SideloadError::InvalidBundle(format!(
                        "IPA contains files inside symbolic link {name}"
                    )));
                }
            }
            archive
                .extract(&temp_path)
                .context("Failed to extract application archive")?;

            #[cfg(unix)]
            for (name, target) in &symlinks {
                let extracted_file = temp_path.join(name);
                if std::fs::symlink_metadata(&extracted_file).is_ok() {
                    std::fs::remove_file(&extracted_file)
                        .context("Failed to replace extracted IPA symbolic link")?;
                }
                std::os::unix::fs::symlink(target, extracted_file)
                    .context("Failed to restore IPA symbolic link")?;
            }
            #[cfg(unix)]
            for (name, _) in &symlinks {
                // Resolve chains as well: a lexically enclosed link can escape through
                // another link followed by a parent component.
                let link = temp_path.join(name);
                let resolved = std::fs::canonicalize(&link)
                    .context(format!("IPA symbolic link is broken or cyclic: {name}"))?;
                let extraction_root = std::fs::canonicalize(&temp_path)?;
                if !resolved.starts_with(&extraction_root) {
                    bail!(SideloadError::InvalidBundle(format!(
                        "IPA symbolic link resolves outside the archive: {name}"
                    )));
                }
            }

            let payload_folder = temp_path.join("Payload");
            if isideload_vfs::fs::metadata(&payload_folder).is_ok() && payload_folder.is_dir() {
                let app_dirs: Vec<_> = isideload_vfs::fs::read_dir(&payload_folder)
                    .context("Failed to read Payload directory")?
                    .filter_map(Result::ok)
                    .filter(|entry| entry.file_type().map(|ft| ft.is_dir()).unwrap_or(false))
                    .filter(|entry| entry.path().extension().is_some_and(|ext| ext == "app"))
                    .collect();
                if app_dirs.len() == 1 {
                    bundle_path = app_dirs[0].path();
                } else if app_dirs.is_empty() {
                    bail!(SideloadError::InvalidBundle(
                        "No .app directory found in Payload".to_string(),
                    ));
                } else {
                    bail!(SideloadError::InvalidBundle(
                        "Multiple .app directories found in Payload".to_string(),
                    ));
                }
            } else {
                // gather the directory contents as a string for debugging
                let mut contents = String::new();
                if isideload_vfs::fs::metadata(&temp_path).is_ok() && temp_path.is_dir() {
                    let entries = isideload_vfs::fs::read_dir(&temp_path)
                        .context("Failed to read temporary directory for error reporting")?;
                    for entry in entries {
                        if let Ok(entry) = entry {
                            contents
                                .push_str(&format!("{}\n", entry.file_name().to_string_lossy()));
                        }
                    }
                }
                bail!(SideloadError::InvalidBundle(format!(
                    "No Payload directory found in the application archive, instead: {}",
                    contents
                ),));
            }
        }

        let bundle = Bundle::new(bundle_path)?;

        Ok(Application {
            bundle, /*temp_path*/
        })
    }

    pub fn get_special_app(&self) -> Option<SpecialApp> {
        let bundle_id = self.bundle.bundle_identifier().unwrap_or("");
        let special_app = match bundle_id {
            "com.rileytestut.AltStore" => Some(SpecialApp::AltStore),
            "com.SideStore.SideStore" => Some(SpecialApp::SideStore),
            "app.stik.store" => Some(SpecialApp::StikStore),
            _ => None,
        };
        if special_app.is_some() {
            return special_app;
        }

        if self
            .bundle
            .frameworks()
            .iter()
            .any(|f| f.bundle_identifier().unwrap_or("") == "com.SideStore.SideStore")
        {
            return Some(SpecialApp::SideStoreLc);
        }

        if bundle_id == "com.kdt.livecontainer" {
            return Some(SpecialApp::LiveContainer);
        }

        None
    }

    pub fn main_bundle_id(&self) -> Result<String, Report> {
        let str = self
            .bundle
            .bundle_identifier()
            .ok_or_report()
            .context("Failed to get main bundle identifier")?
            .to_string();

        Ok(str)
    }

    pub fn main_app_name(&self) -> Result<String, Report> {
        let str = self
            .bundle
            .bundle_name()
            .ok_or_report()
            .context("Failed to get main app name")?
            .to_string();

        Ok(str)
    }

    pub fn update_bundle_id(
        &mut self,
        main_app_bundle_id: &str,
        main_app_id_str: &str,
    ) -> Result<(), Report> {
        let extensions = self.bundle.app_extensions_mut();
        for ext in extensions.iter_mut() {
            if let Some(id) = ext.bundle_identifier() {
                if !id.starts_with(&format!("{main_app_bundle_id}.")) {
                    bail!(SideloadError::InvalidBundle(format!(
                        "Extension {} is not part of the main app bundle identifier: {}",
                        ext.bundle_name().unwrap_or("Unknown"),
                        id
                    )));
                } else {
                    ext.set_bundle_identifier(&format!(
                        "{}{}",
                        main_app_id_str,
                        &id[main_app_bundle_id.len()..]
                    ));
                }
            }
        }
        self.bundle.set_bundle_identifier(main_app_id_str);

        Ok(())
    }

    pub async fn register_app_ids(
        &self,
        //mode: &ExtensionsBehavior,
        dev_session: &mut DeveloperSession,
        team: &DeveloperTeam,
    ) -> Result<Vec<AppId>, Report> {
        let extension_refs: Vec<_> = self.bundle.app_extensions().iter().collect();
        let mut bundles_with_app_id = vec![&self.bundle];
        bundles_with_app_id.extend(extension_refs);

        let list_app_ids_response = dev_session
            .list_app_ids(team, None)
            .await
            .context("Failed to list app IDs for the developer team")?;
        let app_ids_to_register = bundles_with_app_id
            .iter()
            .filter(|bundle| {
                let bundle_id = bundle.bundle_identifier().unwrap_or("");
                !list_app_ids_response
                    .app_ids
                    .iter()
                    .any(|app_id| app_id.identifier == bundle_id)
            })
            .collect::<Vec<_>>();

        if let Some(available) = list_app_ids_response.available_quantity {
            if available < 0 {
                warn!(
                    "Apple reports a negative number of available app IDs ({}), which shouldn't be possible.",
                    available
                );
                // Since the App IDs should never be negative in the first place, it might still be worth trying to register them anyways. Who knows.
            } else {
                // We only do the conversion if available is positive, else we get an integral conversion error
                if app_ids_to_register.len() > available.try_into()? {
                    bail!(
                        "Not enough available app IDs. {} {} required, but only {} {} available.",
                        app_ids_to_register.len(),
                        if app_ids_to_register.len() == 1 {
                            "is"
                        } else {
                            "are"
                        },
                        available,
                        if available == 1 { "is" } else { "are" }
                    );
                }
            }
        }

        for bundle in app_ids_to_register {
            let id = bundle.bundle_identifier().unwrap_or("");
            let name = bundle.bundle_name().unwrap_or("");
            dev_session.add_app_id(team, name, id, None).await?;
        }
        let list_app_id_response = dev_session.list_app_ids(team, None).await?;
        let app_ids: Vec<_> = list_app_id_response
            .app_ids
            .into_iter()
            .filter(|app_id| {
                bundles_with_app_id
                    .iter()
                    .any(|bundle| app_id.identifier == bundle.bundle_identifier().unwrap_or(""))
            })
            .collect();

        info!("Registered app IDs");
        Ok(app_ids)
    }

    pub async fn apply_special_app_behavior(
        &mut self,
        special: &Option<SpecialApp>,
        group_identifier: &str,
        cert: &CertificateIdentity,
    ) -> Result<(), Report> {
        let Some(special) = special.as_ref() else {
            return Ok(());
        };

        if matches!(
            special,
            SpecialApp::SideStoreLc
                | SpecialApp::SideStore
                | SpecialApp::AltStore
                | SpecialApp::StikStore
        ) {
            if !matches!(special, SpecialApp::StikStore) {
                self.bundle.app_info.insert(
                    "ALTAppGroups".to_string(),
                    plist::Value::Array(vec![plist::Value::String(group_identifier.to_string())]),
                );
            }
            info!("Injecting certificate for {}", special);

            let target_bundle =
                match special {
                    SpecialApp::SideStoreLc => self.bundle.frameworks_mut().iter_mut().find(|fw| {
                        fw.bundle_identifier().unwrap_or("") == "com.SideStore.SideStore"
                    }),
                    _ => Some(&mut self.bundle),
                };

            if let Some(target_bundle) = target_bundle {
                let id_key = match special {
                    SpecialApp::StikStore => "MachineID",
                    _ => "ALTCertificateID",
                };
                let cert_file_name = match special {
                    SpecialApp::StikStore => "Certificate.p12",
                    _ => "ALTCertificate.p12",
                };
                target_bundle.app_info.insert(
                    id_key.to_string(),
                    plist::Value::String(cert.get_serial_number()),
                );

                let p12_bytes = cert
                    .as_p12(&cert.machine_id)
                    .await
                    .context("Failed to encode cert as p12")?;
                let alt_cert_path = target_bundle.bundle_dir.join(cert_file_name);

                let mut file = isideload_vfs::fs::File::create(&alt_cert_path)
                    .context(format!("Failed to create {}", cert_file_name))?;
                file.write_all(&p12_bytes)
                    .context(format!("Failed to write {}", cert_file_name))?;
            }
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SpecialApp {
    SideStore,
    SideStoreLc,
    LiveContainer,
    AltStore,
    StikStore,
}

// impl display
impl std::fmt::Display for SpecialApp {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SpecialApp::SideStore => write!(f, "SideStore"),
            SpecialApp::SideStoreLc => write!(f, "SideStore+LiveContainer"),
            SpecialApp::LiveContainer => write!(f, "LiveContainer"),
            SpecialApp::AltStore => write!(f, "AltStore"),
            SpecialApp::StikStore => write!(f, "StikStore"),
        }
    }
}
