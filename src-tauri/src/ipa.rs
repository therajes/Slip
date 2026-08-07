use image::{DynamicImage, ImageFormat, imageops::FilterType};
use plist::{Dictionary, Value};
use serde::{Deserialize, Serialize};
use std::{
    collections::{HashMap, HashSet},
    fs::{self, File},
    io::{Cursor, Read, Write},
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};
#[cfg(feature = "tauri-ui")]
use tauri::{AppHandle, Manager};
use zip::{CompressionMethod, ZipArchive, ZipWriter, write::SimpleFileOptions};

use crate::error::AppError;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IpaExtensionInfo {
    pub path: String,
    pub bundle_id: String,
    pub name: String,
    pub extension_point: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IpaInfo {
    pub path: String,
    pub file_name: String,
    pub app_name: String,
    pub bundle_id: String,
    pub version: String,
    pub build_version: String,
    pub minimum_os_version: Option<String>,
    pub executable: Option<String>,
    pub encryption_status: String,
    pub size_bytes: u64,
    pub extensions: Vec<IpaExtensionInfo>,
    pub app_id_cost: usize,
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IpaInstallOptions {
    pub app_path: String,
    pub display_name: Option<String>,
    pub bundle_id: Option<String>,
    #[serde(default)]
    pub removed_extensions: Vec<String>,
    pub custom_icon_path: Option<String>,
    #[serde(default)]
    pub increased_memory_limit: bool,
    pub minimum_os_version: Option<String>,
    #[serde(default)]
    pub remove_supported_devices: bool,
    #[serde(default)]
    pub enable_file_sharing: bool,
    #[serde(default)]
    pub plist_overrides: Vec<PlistOverride>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlistOverride {
    pub key: String,
    pub value_type: String,
    pub value: String,
}

struct ParsedIpa {
    info: IpaInfo,
    main_root: String,
    main_info_path: String,
    main_info: Dictionary,
    extension_info_paths: HashMap<String, String>,
}

fn plist_string(dict: &Dictionary, key: &str) -> Option<String> {
    dict.get(key)
        .and_then(Value::as_string)
        .map(ToOwned::to_owned)
}

fn read_plist(archive: &mut ZipArchive<File>, path: &str) -> Result<Dictionary, AppError> {
    let mut entry = archive.by_name(path).map_err(|e| {
        AppError::Filesystem(format!("Unable to read {path} from IPA"), e.to_string())
    })?;
    let mut bytes = Vec::new();
    entry.read_to_end(&mut bytes).map_err(|e| {
        AppError::Filesystem(format!("Unable to read {path} from IPA"), e.to_string())
    })?;
    plist::from_bytes::<Dictionary>(&bytes)
        .map_err(|e| AppError::Misc(format!("Invalid plist at {path}: {e}")))
}

fn extension_point(dict: &Dictionary) -> Option<String> {
    dict.get("NSExtension")
        .and_then(Value::as_dictionary)
        .and_then(|extension| extension.get("NSExtensionPointIdentifier"))
        .and_then(Value::as_string)
        .map(ToOwned::to_owned)
}

fn extension_name(dict: &Dictionary, path: &str) -> String {
    plist_string(dict, "CFBundleDisplayName")
        .or_else(|| plist_string(dict, "CFBundleName"))
        .or_else(|| {
            Path::new(path)
                .file_stem()
                .map(|value| value.to_string_lossy().to_string())
        })
        .unwrap_or_else(|| "App Extension".to_string())
}

fn read_u32(bytes: &[u8], offset: usize, little_endian: bool) -> Option<u32> {
    let chunk: [u8; 4] = bytes.get(offset..offset + 4)?.try_into().ok()?;
    Some(if little_endian {
        u32::from_le_bytes(chunk)
    } else {
        u32::from_be_bytes(chunk)
    })
}

fn thin_macho_encryption(bytes: &[u8]) -> Option<bool> {
    let magic = bytes.get(..4)?;
    let (little_endian, header_size) = match magic {
        [0xcf, 0xfa, 0xed, 0xfe] => (true, 32),
        [0xce, 0xfa, 0xed, 0xfe] => (true, 28),
        [0xfe, 0xed, 0xfa, 0xcf] => (false, 32),
        [0xfe, 0xed, 0xfa, 0xce] => (false, 28),
        _ => return None,
    };
    let command_count = read_u32(bytes, 16, little_endian)? as usize;
    let mut offset = header_size;
    for _ in 0..command_count {
        let command = read_u32(bytes, offset, little_endian)?;
        let command_size = read_u32(bytes, offset + 4, little_endian)? as usize;
        if command_size < 8 || offset.checked_add(command_size)? > bytes.len() {
            return None;
        }
        // LC_ENCRYPTION_INFO and LC_ENCRYPTION_INFO_64 have cryptid at +16.
        if command == 0x21 || command == 0x2c {
            return Some(read_u32(bytes, offset + 16, little_endian)? != 0);
        }
        offset += command_size;
    }
    Some(false)
}

fn macho_encryption_status(bytes: &[u8]) -> String {
    if let Some(encrypted) = thin_macho_encryption(bytes) {
        return if encrypted { "Encrypted" } else { "Decrypted" }.to_string();
    }

    let magic = bytes.get(..4);
    let fat_little_endian = match magic {
        Some([0xca, 0xfe, 0xba, 0xbe]) | Some([0xca, 0xfe, 0xba, 0xbf]) => false,
        Some([0xbe, 0xba, 0xfe, 0xca]) | Some([0xbf, 0xba, 0xfe, 0xca]) => true,
        _ => return "Unknown".to_string(),
    };
    let fat64 = matches!(
        magic,
        Some([0xca, 0xfe, 0xba, 0xbf]) | Some([0xbf, 0xba, 0xfe, 0xca])
    );
    let count = match read_u32(bytes, 4, fat_little_endian) {
        Some(value) => value as usize,
        None => return "Unknown".to_string(),
    };
    let arch_size = if fat64 { 32 } else { 20 };
    let mut found_slice = false;
    let mut encrypted_slice = false;
    for index in 0..count {
        let arch = 8 + index * arch_size;
        let slice_offset = if fat64 {
            let high = read_u32(bytes, arch + 8, fat_little_endian).unwrap_or(0) as u64;
            let low = read_u32(bytes, arch + 12, fat_little_endian).unwrap_or(0) as u64;
            (high << 32 | low) as usize
        } else {
            read_u32(bytes, arch + 8, fat_little_endian).unwrap_or(0) as usize
        };
        let slice_size = if fat64 {
            let high = read_u32(bytes, arch + 16, fat_little_endian).unwrap_or(0) as u64;
            let low = read_u32(bytes, arch + 20, fat_little_endian).unwrap_or(0) as u64;
            (high << 32 | low) as usize
        } else {
            read_u32(bytes, arch + 12, fat_little_endian).unwrap_or(0) as usize
        };
        let Some(slice) = bytes.get(slice_offset..slice_offset.saturating_add(slice_size)) else {
            continue;
        };
        if let Some(encrypted) = thin_macho_encryption(slice) {
            found_slice = true;
            encrypted_slice |= encrypted;
        }
    }
    match (found_slice, encrypted_slice) {
        (true, true) => "Encrypted".to_string(),
        (true, false) => "Decrypted".to_string(),
        _ => "Unknown".to_string(),
    }
}

fn plist_override_value(item: &PlistOverride) -> Result<Value, AppError> {
    let value = item.value.trim();
    match item.value_type.as_str() {
        "String" => Ok(Value::String(item.value.clone())),
        "Boolean" => value
            .parse::<bool>()
            .map(Value::Boolean)
            .map_err(|_| AppError::Misc(format!("{} must be true or false", item.key))),
        "Integer" => value
            .parse::<i64>()
            .map(|value| Value::Integer(value.into()))
            .map_err(|_| AppError::Misc(format!("{} must be an integer", item.key))),
        "Real" => value
            .parse::<f64>()
            .map(Value::Real)
            .map_err(|_| AppError::Misc(format!("{} must be a number", item.key))),
        other => Err(AppError::Misc(format!(
            "Unsupported plist value type {other} for {}",
            item.key
        ))),
    }
}

fn parse_ipa(path: &Path) -> Result<ParsedIpa, AppError> {
    if path.extension().and_then(|value| value.to_str()) != Some("ipa") {
        return Err(AppError::Misc(
            "The selected file is not an IPA".to_string(),
        ));
    }

    let file = File::open(path)
        .map_err(|e| AppError::Filesystem("Unable to open IPA".to_string(), e.to_string()))?;
    let size_bytes = file
        .metadata()
        .map_err(|e| AppError::Filesystem("Unable to inspect IPA".to_string(), e.to_string()))?
        .len();
    let mut archive = ZipArchive::new(file)
        .map_err(|e| AppError::Misc(format!("The selected IPA is not a valid ZIP archive: {e}")))?;

    let mut main_info_path = None;
    let mut extension_info_paths = HashMap::new();
    for index in 0..archive.len() {
        let entry = archive.by_index(index).map_err(|e| {
            AppError::Filesystem("Unable to inspect IPA entry".to_string(), e.to_string())
        })?;
        let name = entry.name().replace('\\', "/");
        let components: Vec<_> = name.split('/').filter(|part| !part.is_empty()).collect();
        if components.len() == 3
            && components[0] == "Payload"
            && components[1].ends_with(".app")
            && components[2] == "Info.plist"
        {
            main_info_path = Some(name.clone());
        }
        if name.contains("/PlugIns/") && name.ends_with(".appex/Info.plist") {
            extension_info_paths.insert(
                name.trim_end_matches("/Info.plist").to_string(),
                name.clone(),
            );
        }
    }

    let main_info_path = main_info_path
        .ok_or_else(|| AppError::Misc("No iOS app was found in Payload".to_string()))?;
    let main_root = main_info_path.trim_end_matches("Info.plist").to_string();
    let main_info = read_plist(&mut archive, &main_info_path)?;
    let bundle_id = plist_string(&main_info, "CFBundleIdentifier")
        .ok_or_else(|| AppError::Misc("The app has no bundle identifier".to_string()))?;
    let app_name = plist_string(&main_info, "CFBundleDisplayName")
        .or_else(|| plist_string(&main_info, "CFBundleName"))
        .unwrap_or_else(|| "Unnamed App".to_string());

    let mut extensions = Vec::new();
    for (extension_path, info_path) in &extension_info_paths {
        if !extension_path.starts_with(&main_root) {
            continue;
        }
        let info = read_plist(&mut archive, info_path)?;
        extensions.push(IpaExtensionInfo {
            path: extension_path.clone(),
            bundle_id: plist_string(&info, "CFBundleIdentifier")
                .unwrap_or_else(|| "Unknown bundle ID".to_string()),
            name: extension_name(&info, extension_path),
            extension_point: extension_point(&info),
        });
    }
    extensions.sort_by(|left, right| left.name.cmp(&right.name));

    let executable = plist_string(&main_info, "CFBundleExecutable");
    let encryption_status = if let Some(executable) = &executable {
        let executable_path = format!("{main_root}{executable}");
        archive
            .by_name(&executable_path)
            .ok()
            .and_then(|mut entry| {
                let mut bytes = Vec::new();
                entry.read_to_end(&mut bytes).ok().map(|_| bytes)
            })
            .map(|bytes| macho_encryption_status(&bytes))
            .unwrap_or_else(|| "Unknown".to_string())
    } else {
        "Unknown".to_string()
    };

    let mut warnings = Vec::new();
    if extensions.len() >= 3 {
        warnings.push(format!(
            "This IPA contains {} extensions and may use {} App IDs with a free Apple Account.",
            extensions.len(),
            extensions.len() + 1
        ));
    }
    if size_bytes > 1_000_000_000 {
        warnings.push(
            "This IPA is larger than 1 GB; signing and Wi-Fi transfer may take several minutes."
                .to_string(),
        );
    }
    if encryption_status == "Encrypted" {
        warnings.push(
            "The main executable is App Store encrypted. Signing can succeed, but the app will not launch until you provide a legitimately decrypted IPA."
                .to_string(),
        );
    }

    let file_name = path
        .file_name()
        .map(|value| value.to_string_lossy().to_string())
        .unwrap_or_else(|| "App.ipa".to_string());

    Ok(ParsedIpa {
        info: IpaInfo {
            path: path.to_string_lossy().to_string(),
            file_name,
            app_name,
            bundle_id,
            version: plist_string(&main_info, "CFBundleShortVersionString")
                .unwrap_or_else(|| "Unknown".to_string()),
            build_version: plist_string(&main_info, "CFBundleVersion")
                .unwrap_or_else(|| "Unknown".to_string()),
            minimum_os_version: plist_string(&main_info, "MinimumOSVersion"),
            executable,
            encryption_status,
            size_bytes,
            app_id_cost: extensions.len() + 1,
            extensions,
            warnings,
        },
        main_root,
        main_info_path,
        main_info,
        extension_info_paths,
    })
}

#[cfg_attr(feature = "tauri-ui", tauri::command)]
pub fn inspect_ipa(app_path: String) -> Result<IpaInfo, AppError> {
    Ok(parse_ipa(Path::new(&app_path))?.info)
}

fn validate_bundle_id(bundle_id: &str) -> Result<(), AppError> {
    let valid = !bundle_id.is_empty()
        && bundle_id.contains('.')
        && bundle_id.split('.').all(|component| {
            !component.is_empty()
                && component
                    .chars()
                    .all(|character| character.is_ascii_alphanumeric() || character == '-')
        });
    if valid {
        Ok(())
    } else {
        Err(AppError::Misc(
            "Bundle IDs must contain dot-separated letters, numbers, or hyphens".to_string(),
        ))
    }
}

fn set_custom_icon_plist(info: &mut Dictionary) {
    let files = Value::Array(vec![Value::String("SideloomIcon".to_string())]);
    let mut primary = Dictionary::new();
    primary.insert("CFBundleIconFiles".to_string(), files.clone());
    primary.remove("CFBundleIconName");
    let mut icons = Dictionary::new();
    icons.insert(
        "CFBundlePrimaryIcon".to_string(),
        Value::Dictionary(primary),
    );
    info.insert("CFBundleIcons".to_string(), Value::Dictionary(icons));
    info.insert("CFBundleIconFiles".to_string(), files);
}

fn plist_bytes(info: &Dictionary) -> Result<Vec<u8>, AppError> {
    let mut output = Vec::new();
    plist::to_writer_binary(&mut output, info)
        .map_err(|e| AppError::Misc(format!("Unable to write modified Info.plist: {e}")))?;
    Ok(output)
}

fn make_icon(source: &DynamicImage, size: u32) -> Result<Vec<u8>, AppError> {
    let side = source.width().min(source.height());
    let x = (source.width() - side) / 2;
    let y = (source.height() - side) / 2;
    let cropped = source.crop_imm(x, y, side, side);
    let resized = cropped.resize_exact(size, size, FilterType::Lanczos3);
    let mut bytes = Cursor::new(Vec::new());
    resized
        .write_to(&mut bytes, ImageFormat::Png)
        .map_err(|e| AppError::Misc(format!("Unable to create app icon: {e}")))?;
    Ok(bytes.into_inner())
}

pub fn prepare_ipa_in(temp_root: &Path, options: &IpaInstallOptions) -> Result<PathBuf, AppError> {
    let source_path = Path::new(&options.app_path);
    let parsed = parse_ipa(source_path)?;
    let target_bundle_id = options
        .bundle_id
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or(&parsed.info.bundle_id)
        .to_string();
    validate_bundle_id(&target_bundle_id)?;

    let removed: HashSet<_> = options.removed_extensions.iter().cloned().collect();
    let custom_icon = options
        .custom_icon_path
        .as_ref()
        .filter(|path| !path.trim().is_empty())
        .map(|path| {
            image::open(path)
                .map_err(|e| AppError::Misc(format!("Unable to open custom icon: {e}")))
        })
        .transpose()?;

    let source_file = File::open(source_path)
        .map_err(|e| AppError::Filesystem("Unable to open IPA".to_string(), e.to_string()))?;
    let mut source = ZipArchive::new(source_file)
        .map_err(|e| AppError::Misc(format!("Unable to open IPA archive: {e}")))?;

    let prepared_dir = temp_root.join("sideloom");
    fs::create_dir_all(&prepared_dir).map_err(|e| {
        AppError::Filesystem(
            "Unable to create temporary folder".to_string(),
            e.to_string(),
        )
    })?;
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let output_path = prepared_dir.join(format!("prepared-{timestamp}.ipa"));
    let output_file = File::create(&output_path).map_err(|e| {
        AppError::Filesystem("Unable to create prepared IPA".to_string(), e.to_string())
    })?;
    let mut output = ZipWriter::new(output_file);

    for index in 0..source.len() {
        let mut entry = source.by_index(index).map_err(|e| {
            AppError::Filesystem("Unable to read IPA entry".to_string(), e.to_string())
        })?;
        let name = entry.name().replace('\\', "/");
        if removed
            .iter()
            .any(|extension| name == *extension || name.starts_with(&format!("{extension}/")))
        {
            continue;
        }
        if custom_icon.is_some() && name.starts_with(&format!("{}SideloomIcon", parsed.main_root)) {
            continue;
        }

        let compression = match entry.compression() {
            CompressionMethod::Stored => CompressionMethod::Stored,
            _ => CompressionMethod::Deflated,
        };
        let file_options = SimpleFileOptions::default()
            .compression_method(compression)
            .unix_permissions(entry.unix_mode().unwrap_or(0o644));
        if entry.is_dir() {
            output.add_directory(&name, file_options).map_err(|e| {
                AppError::Filesystem("Unable to write IPA directory".to_string(), e.to_string())
            })?;
            continue;
        }

        output.start_file(&name, file_options).map_err(|e| {
            AppError::Filesystem("Unable to write IPA entry".to_string(), e.to_string())
        })?;

        if name == parsed.main_info_path {
            let mut info = parsed.main_info.clone();
            info.insert(
                "CFBundleIdentifier".to_string(),
                Value::String(target_bundle_id.clone()),
            );
            if let Some(display_name) = options
                .display_name
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty())
            {
                info.insert(
                    "CFBundleDisplayName".to_string(),
                    Value::String(display_name.to_string()),
                );
                info.insert(
                    "CFBundleName".to_string(),
                    Value::String(display_name.to_string()),
                );
            }
            if custom_icon.is_some() {
                set_custom_icon_plist(&mut info);
            }
            if let Some(version) = options
                .minimum_os_version
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty())
            {
                info.insert(
                    "MinimumOSVersion".to_string(),
                    Value::String(version.to_string()),
                );
            }
            if options.remove_supported_devices {
                info.remove("UISupportedDevices");
            }
            if options.enable_file_sharing {
                info.insert("UIFileSharingEnabled".to_string(), Value::Boolean(true));
                info.insert(
                    "LSSupportsOpeningDocumentsInPlace".to_string(),
                    Value::Boolean(true),
                );
            }
            for item in &options.plist_overrides {
                let key = item.key.trim();
                if key.is_empty() {
                    return Err(AppError::Misc(
                        "Info.plist override keys cannot be empty".to_string(),
                    ));
                }
                info.insert(key.to_string(), plist_override_value(item)?);
            }
            output.write_all(&plist_bytes(&info)?).map_err(|e| {
                AppError::Filesystem("Unable to write app metadata".to_string(), e.to_string())
            })?;
        } else if let Some(extension_root) = parsed
            .extension_info_paths
            .iter()
            .find_map(|(root, info_path)| (info_path == &name).then_some(root))
        {
            let mut bytes = Vec::new();
            entry.read_to_end(&mut bytes).map_err(|e| {
                AppError::Filesystem(
                    "Unable to read extension metadata".to_string(),
                    e.to_string(),
                )
            })?;
            let mut info = plist::from_bytes::<Dictionary>(&bytes).map_err(|e| {
                AppError::Misc(format!("Invalid extension plist at {extension_root}: {e}"))
            })?;
            if let Some(original_id) = plist_string(&info, "CFBundleIdentifier")
                && let Some(suffix) = original_id.strip_prefix(&parsed.info.bundle_id)
            {
                info.insert(
                    "CFBundleIdentifier".to_string(),
                    Value::String(format!("{target_bundle_id}{suffix}")),
                );
            }
            output.write_all(&plist_bytes(&info)?).map_err(|e| {
                AppError::Filesystem(
                    "Unable to write extension metadata".to_string(),
                    e.to_string(),
                )
            })?;
        } else {
            std::io::copy(&mut entry, &mut output).map_err(|e| {
                AppError::Filesystem("Unable to copy IPA entry".to_string(), e.to_string())
            })?;
        }
    }

    if let Some(icon) = custom_icon {
        for (name, size) in [
            ("SideloomIcon.png", 60),
            ("SideloomIcon@2x.png", 120),
            ("SideloomIcon@3x.png", 180),
        ] {
            output
                .start_file(
                    format!("{}{name}", parsed.main_root),
                    SimpleFileOptions::default().compression_method(CompressionMethod::Deflated),
                )
                .map_err(|e| {
                    AppError::Filesystem("Unable to add app icon".to_string(), e.to_string())
                })?;
            output.write_all(&make_icon(&icon, size)?).map_err(|e| {
                AppError::Filesystem("Unable to write app icon".to_string(), e.to_string())
            })?;
        }
    }

    output.finish().map_err(|e| {
        AppError::Filesystem("Unable to finish prepared IPA".to_string(), e.to_string())
    })?;
    Ok(output_path)
}

pub fn export_prepared_ipa(
    options: &IpaInstallOptions,
    destination: &Path,
) -> Result<u64, AppError> {
    if destination.extension().and_then(|value| value.to_str()) != Some("ipa") {
        return Err(AppError::Misc(
            "The exported file must use the .ipa extension".to_string(),
        ));
    }
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent).map_err(|error| {
            AppError::Filesystem(
                "Unable to create the export folder".to_string(),
                error.to_string(),
            )
        })?;
    }
    let prepared = prepare_ipa_in(&std::env::temp_dir(), options)?;
    let result = fs::copy(&prepared, destination).map_err(|error| {
        AppError::Filesystem(
            "Unable to export the modified IPA".to_string(),
            error.to_string(),
        )
    });
    let _ = fs::remove_file(prepared);
    result
}

#[cfg(feature = "tauri-ui")]
pub fn prepare_ipa(app: &AppHandle, options: &IpaInstallOptions) -> Result<PathBuf, AppError> {
    let temp_root = app.path().temp_dir().map_err(|e| {
        AppError::Filesystem(
            "Unable to access temporary folder".to_string(),
            e.to_string(),
        )
    })?;
    prepare_ipa_in(&temp_root, options)
}

#[cfg(test)]
mod tests {
    use super::{parse_ipa, plist_bytes, validate_bundle_id};
    use plist::{Dictionary, Value};
    use std::{fs::File, io::Write, time::SystemTime};
    use zip::{CompressionMethod, ZipWriter, write::SimpleFileOptions};

    #[test]
    fn validates_bundle_ids() {
        assert!(validate_bundle_id("com.example.App-2").is_ok());
        assert!(validate_bundle_id("missing-dot").is_err());
        assert!(validate_bundle_id("com.example.bad_value").is_err());
        assert!(validate_bundle_id("com..example").is_err());
    }

    #[test]
    fn inspects_main_app_and_extensions() {
        let unique = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!("sideloom-test-{unique}.ipa"));
        let file = File::create(&path).unwrap();
        let mut zip = ZipWriter::new(file);
        let options = SimpleFileOptions::default().compression_method(CompressionMethod::Deflated);

        let mut app = Dictionary::new();
        app.insert(
            "CFBundleIdentifier".to_string(),
            Value::String("com.example.Test".to_string()),
        );
        app.insert(
            "CFBundleDisplayName".to_string(),
            Value::String("Test App".to_string()),
        );
        app.insert(
            "CFBundleShortVersionString".to_string(),
            Value::String("1.2.3".to_string()),
        );
        app.insert(
            "CFBundleVersion".to_string(),
            Value::String("42".to_string()),
        );
        zip.start_file("Payload/Test.app/Info.plist", options)
            .unwrap();
        zip.write_all(&plist_bytes(&app).unwrap()).unwrap();

        let mut extension = Dictionary::new();
        extension.insert(
            "CFBundleIdentifier".to_string(),
            Value::String("com.example.Test.Share".to_string()),
        );
        extension.insert(
            "CFBundleDisplayName".to_string(),
            Value::String("Share".to_string()),
        );
        let mut extension_config = Dictionary::new();
        extension_config.insert(
            "NSExtensionPointIdentifier".to_string(),
            Value::String("com.apple.share-services".to_string()),
        );
        extension.insert(
            "NSExtension".to_string(),
            Value::Dictionary(extension_config),
        );
        zip.start_file("Payload/Test.app/PlugIns/Share.appex/Info.plist", options)
            .unwrap();
        zip.write_all(&plist_bytes(&extension).unwrap()).unwrap();
        zip.finish().unwrap();

        let parsed = parse_ipa(&path).unwrap();
        assert_eq!(parsed.info.app_name, "Test App");
        assert_eq!(parsed.info.bundle_id, "com.example.Test");
        assert_eq!(parsed.info.version, "1.2.3");
        assert_eq!(parsed.info.extensions.len(), 1);
        assert_eq!(parsed.info.app_id_cost, 2);
        assert_eq!(
            parsed.info.extensions[0].extension_point.as_deref(),
            Some("com.apple.share-services")
        );

        std::fs::remove_file(path).unwrap();
    }
}
