use image::{DynamicImage, ImageFormat, ImageReader, Limits, imageops::FilterType};
use plist::{Dictionary, Value};
use serde::{Deserialize, Serialize};
use std::{
    collections::{HashMap, HashSet},
    fs::{self, File, OpenOptions},
    io::{Cursor, Read, Write},
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};
use zip::{CompressionMethod, ZipArchive, ZipWriter, write::SimpleFileOptions};

use crate::error::AppError;

const MAX_ARCHIVE_ENTRIES: usize = 100_000;
const MAX_PLIST_BYTES: u64 = 8 * 1_024 * 1_024;
const MAX_ICON_BYTES: u64 = 24 * 1_024 * 1_024;
const MAX_EXECUTABLE_SCAN_BYTES: u64 = 4 * 1_024 * 1_024;
const MAX_IMAGE_DIMENSION: u32 = 8_192;
const MAX_IMAGE_ALLOCATION: u64 = 128 * 1_024 * 1_024;
const MAX_UNCOMPRESSED_IPA_BYTES: u64 = 32 * 1_024 * 1_024 * 1_024;

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

struct RemoveOnDrop {
    path: PathBuf,
    keep: bool,
}

impl Drop for RemoveOnDrop {
    fn drop(&mut self) {
        if !self.keep {
            let _ = fs::remove_file(&self.path);
        }
    }
}

fn plist_string(dict: &Dictionary, key: &str) -> Option<String> {
    dict.get(key)
        .and_then(Value::as_string)
        .map(ToOwned::to_owned)
}

fn validated_archive_name(raw_name: &str) -> Result<String, AppError> {
    if raw_name.contains('\0') {
        return Err(AppError::Misc(
            "The IPA contains a NUL byte in an entry name".into(),
        ));
    }
    let name = raw_name.replace('\\', "/");
    if name.starts_with('/')
        || name
            .split('/')
            .next()
            .is_some_and(|component| component.ends_with(':'))
        || name
            .split('/')
            .any(|component| component == ".." || component == ".")
    {
        return Err(AppError::Misc(format!(
            "The IPA contains an unsafe archive path: {raw_name}"
        )));
    }
    Ok(name)
}

fn read_entry_limited(
    entry: &mut zip::read::ZipFile<'_, File>,
    limit: u64,
    description: &str,
) -> Result<Vec<u8>, AppError> {
    if entry.size() > limit {
        return Err(AppError::Misc(format!(
            "{description} is unexpectedly large ({} bytes)",
            entry.size()
        )));
    }
    let mut bytes = Vec::with_capacity(entry.size().min(limit) as usize);
    entry
        .take(limit + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| {
            AppError::Filesystem(format!("Unable to read {description}"), error.to_string())
        })?;
    if bytes.len() as u64 > limit {
        return Err(AppError::Misc(format!(
            "{description} exceeds the supported size limit"
        )));
    }
    Ok(bytes)
}

fn read_entry_prefix(
    entry: &mut zip::read::ZipFile<'_, File>,
    limit: u64,
    description: &str,
) -> Result<Vec<u8>, AppError> {
    let mut bytes = Vec::with_capacity(entry.size().min(limit) as usize);
    entry.take(limit).read_to_end(&mut bytes).map_err(|error| {
        AppError::Filesystem(format!("Unable to read {description}"), error.to_string())
    })?;
    Ok(bytes)
}

fn decode_image_bounded(bytes: &[u8], description: &str) -> Result<DynamicImage, AppError> {
    let mut reader = ImageReader::new(Cursor::new(bytes))
        .with_guessed_format()
        .map_err(|error| AppError::Misc(format!("Unable to identify {description}: {error}")))?;
    let mut limits = Limits::default();
    limits.max_image_width = Some(MAX_IMAGE_DIMENSION);
    limits.max_image_height = Some(MAX_IMAGE_DIMENSION);
    limits.max_alloc = Some(MAX_IMAGE_ALLOCATION);
    reader.limits(limits);
    reader
        .decode()
        .map_err(|error| AppError::Misc(format!("Unable to decode {description}: {error}")))
}

fn read_plist(archive: &mut ZipArchive<File>, path: &str) -> Result<Dictionary, AppError> {
    let mut entry = archive.by_name(path).map_err(|e| {
        AppError::Filesystem(format!("Unable to read {path} from IPA"), e.to_string())
    })?;
    let bytes = read_entry_limited(&mut entry, MAX_PLIST_BYTES, path)?;
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
    if command_count > 16_384 {
        return None;
    }
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
        Some(value) if (1..=64).contains(&value) => value as usize,
        None => return "Unknown".to_string(),
        _ => return "Unknown".to_string(),
    };
    let arch_size = if fat64 { 32 } else { 20 };
    let mut found_slice = false;
    let mut encrypted_slice = false;
    let mut inspected_slices = 0_usize;
    for index in 0..count {
        let Some(arch) = index
            .checked_mul(arch_size)
            .and_then(|offset| 8usize.checked_add(offset))
        else {
            return "Unknown".to_string();
        };
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
        let Some(slice_end) = slice_offset
            .checked_add(slice_size)
            .map(|end| end.min(bytes.len()))
        else {
            continue;
        };
        let Some(slice) = bytes.get(slice_offset..slice_end) else {
            continue;
        };
        if let Some(encrypted) = thin_macho_encryption(slice) {
            found_slice = true;
            inspected_slices += 1;
            encrypted_slice |= encrypted;
        }
    }
    if encrypted_slice {
        "Encrypted".to_string()
    } else if found_slice && inspected_slices == count {
        "Decrypted".to_string()
    } else {
        "Unknown".to_string()
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
            .ok()
            .filter(|value| value.is_finite())
            .map(Value::Real)
            .ok_or_else(|| AppError::Misc(format!("{} must be a finite number", item.key))),
        other => Err(AppError::Misc(format!(
            "Unsupported plist value type {other} for {}",
            item.key
        ))),
    }
}

fn parse_ipa(path: &Path) -> Result<ParsedIpa, AppError> {
    if !path
        .extension()
        .and_then(|value| value.to_str())
        .is_some_and(|extension| extension.eq_ignore_ascii_case("ipa"))
    {
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
    if archive.len() > MAX_ARCHIVE_ENTRIES {
        return Err(AppError::Misc(format!(
            "The IPA contains too many archive entries ({})",
            archive.len()
        )));
    }

    let mut main_info_paths = HashSet::new();
    let mut extension_info_paths = HashMap::new();
    let mut archive_names = HashSet::new();
    let mut total_uncompressed_bytes = 0_u64;
    for index in 0..archive.len() {
        let entry = archive.by_index(index).map_err(|e| {
            AppError::Filesystem("Unable to inspect IPA entry".to_string(), e.to_string())
        })?;
        let name = validated_archive_name(entry.name())?;
        if !archive_names.insert(name.clone()) {
            return Err(AppError::Misc(format!(
                "The IPA contains a duplicate archive entry: {name}"
            )));
        }
        total_uncompressed_bytes = total_uncompressed_bytes
            .checked_add(entry.size())
            .filter(|total| *total <= MAX_UNCOMPRESSED_IPA_BYTES)
            .ok_or_else(|| {
                AppError::Misc("The IPA expands beyond Slip's 32 GB safety limit".into())
            })?;
        if entry
            .unix_mode()
            .is_some_and(|mode| mode & 0o170000 == 0o120000)
        {
            return Err(AppError::Misc(format!(
                "The IPA contains an unsupported symbolic link: {name}"
            )));
        }
        let components: Vec<_> = name.split('/').filter(|part| !part.is_empty()).collect();
        if components.len() == 3
            && components[0] == "Payload"
            && components[1].ends_with(".app")
            && components[2] == "Info.plist"
        {
            main_info_paths.insert(name.clone());
        }
        if name.contains("/PlugIns/") && name.ends_with(".appex/Info.plist") {
            extension_info_paths.insert(
                name.trim_end_matches("/Info.plist").to_string(),
                name.clone(),
            );
        }
    }

    if main_info_paths.len() > 1 {
        return Err(AppError::Misc(
            "The IPA contains more than one top-level app in Payload".into(),
        ));
    }
    let main_info_path = main_info_paths
        .into_iter()
        .next()
        .ok_or_else(|| AppError::Misc("No iOS app was found in Payload".to_string()))?;
    let main_root = main_info_path.trim_end_matches("Info.plist").to_string();
    extension_info_paths.retain(|root, _| root.starts_with(&main_root));
    let main_info = read_plist(&mut archive, &main_info_path)?;
    let bundle_id = plist_string(&main_info, "CFBundleIdentifier")
        .ok_or_else(|| AppError::Misc("The app has no bundle identifier".to_string()))?;
    validate_bundle_id(&bundle_id)?;
    let app_name = plist_string(&main_info, "CFBundleDisplayName")
        .or_else(|| plist_string(&main_info, "CFBundleName"))
        .unwrap_or_else(|| "Unnamed App".to_string());
    if app_name.chars().count() > 128 || app_name.chars().any(char::is_control) {
        return Err(AppError::Misc(
            "The IPA app name is too long or contains control characters".into(),
        ));
    }
    let bounded_metadata = |key: &str, fallback: &str, maximum: usize| {
        let value = plist_string(&main_info, key).unwrap_or_else(|| fallback.to_string());
        if value.chars().count() > maximum || value.chars().any(char::is_control) {
            Err(AppError::Misc(format!(
                "The IPA contains invalid or oversized {key} metadata"
            )))
        } else {
            Ok(value)
        }
    };
    let version = bounded_metadata("CFBundleShortVersionString", "Unknown", 128)?;
    let build_version = bounded_metadata("CFBundleVersion", "Unknown", 128)?;
    let minimum_os_version = plist_string(&main_info, "MinimumOSVersion")
        .map(|value| {
            if value.chars().count() > 32 || value.chars().any(char::is_control) {
                Err(AppError::Misc(
                    "The IPA contains invalid MinimumOSVersion metadata".into(),
                ))
            } else {
                Ok(value)
            }
        })
        .transpose()?;

    let mut extensions = Vec::new();
    for (extension_path, info_path) in &extension_info_paths {
        if !extension_path.starts_with(&main_root) {
            continue;
        }
        let info = read_plist(&mut archive, info_path)?;
        let extension_bundle_id = plist_string(&info, "CFBundleIdentifier").ok_or_else(|| {
            AppError::Misc(format!(
                "The extension at {extension_path} has no bundle identifier"
            ))
        })?;
        validate_bundle_id(&extension_bundle_id)?;
        let name = extension_name(&info, extension_path);
        if name.chars().count() > 128 || name.chars().any(char::is_control) {
            return Err(AppError::Misc(format!(
                "The extension at {extension_path} has an invalid display name"
            )));
        }
        extensions.push(IpaExtensionInfo {
            path: extension_path.clone(),
            bundle_id: extension_bundle_id,
            name,
            extension_point: extension_point(&info),
        });
    }
    extensions.sort_by(|left, right| left.name.cmp(&right.name));

    let executable = plist_string(&main_info, "CFBundleExecutable");
    if executable.as_ref().is_some_and(|name| {
        name.is_empty()
            || name.len() > 255
            || name == "."
            || name == ".."
            || name.contains('/')
            || name.contains('\\')
            || name.chars().any(char::is_control)
    }) {
        return Err(AppError::Misc(
            "The IPA contains an unsafe main executable name".into(),
        ));
    }
    let encryption_status = if let Some(executable) = &executable {
        let executable_path = format!("{main_root}{executable}");
        archive
            .by_name(&executable_path)
            .ok()
            .and_then(|mut entry| {
                read_entry_prefix(&mut entry, MAX_EXECUTABLE_SCAN_BYTES, "the main executable").ok()
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
            version,
            build_version,
            minimum_os_version,
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

pub fn inspect_ipa(app_path: String) -> Result<IpaInfo, AppError> {
    Ok(parse_ipa(Path::new(&app_path))?.info)
}

fn declared_icon_names(info: &Dictionary) -> HashSet<String> {
    fn normalized(value: &str) -> String {
        let file_name = Path::new(value)
            .file_name()
            .map(|name| name.to_string_lossy().to_string())
            .unwrap_or_else(|| value.to_string());
        file_name
            .strip_suffix(".png")
            .or_else(|| file_name.strip_suffix(".PNG"))
            .unwrap_or(&file_name)
            .to_ascii_lowercase()
    }

    fn collect(container: &Dictionary, result: &mut HashSet<String>) {
        if let Some(name) = container.get("CFBundleIconName").and_then(Value::as_string) {
            result.insert(normalized(name));
        }
        if let Some(files) = container.get("CFBundleIconFiles").and_then(Value::as_array) {
            for file in files.iter().filter_map(Value::as_string) {
                result.insert(normalized(file));
            }
        }
    }

    let mut result = HashSet::new();
    collect(info, &mut result);
    for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
        if let Some(primary) = info
            .get(key)
            .and_then(Value::as_dictionary)
            .and_then(|icons| icons.get("CFBundlePrimaryIcon"))
            .and_then(Value::as_dictionary)
        {
            collect(primary, &mut result);
        }
    }
    result
}

pub fn extract_ipa_icon(app_path: String, destination: String) -> Result<String, AppError> {
    let parsed = parse_ipa(Path::new(&app_path))?;
    let declared_icons = declared_icon_names(&parsed.main_info);
    let file = File::open(&app_path).map_err(|error| {
        AppError::Filesystem(
            "Unable to open IPA for icon preview".into(),
            error.to_string(),
        )
    })?;
    let mut archive = ZipArchive::new(file)
        .map_err(|error| AppError::Misc(format!("Unable to read IPA icon: {error}")))?;
    let mut candidates = Vec::new();

    for index in 0..archive.len() {
        let entry = archive.by_index(index).map_err(|error| {
            AppError::Filesystem("Unable to inspect IPA icon entry".into(), error.to_string())
        })?;
        let name = validated_archive_name(entry.name())?;
        let Some(relative) = name.strip_prefix(&parsed.main_root) else {
            continue;
        };
        let lower = relative.to_ascii_lowercase();
        if relative.contains('/') || !lower.ends_with(".png") {
            continue;
        }

        let stem = lower.strip_suffix(".png").unwrap_or(&lower);
        let declared = declared_icons.iter().any(|name| stem.starts_with(name));
        let score = if declared {
            40_000
        } else if lower.contains("appicon") {
            25_000
        } else if lower.contains("icon") {
            20_000
        } else if lower.contains("logo") {
            15_000
        } else {
            1_000
        } + if lower.contains("@3x") {
            300
        } else if lower.contains("@2x") {
            200
        } else {
            0
        } + if lower.contains("~ipad") { 0 } else { 50 };
        if entry.size() <= MAX_ICON_BYTES {
            candidates.push((score, declared, entry.size(), name));
        }
    }

    let mut best: Option<(u64, Vec<u8>)> = None;
    for (name_score, declared, archived_size, name) in candidates {
        let mut entry = archive.by_name(&name).map_err(|error| {
            AppError::Filesystem("Unable to read IPA icon".into(), error.to_string())
        })?;
        let bytes = read_entry_limited(&mut entry, MAX_ICON_BYTES, "IPA icon")?;
        // Some real-world IPAs still contain Apple's CgBI-optimized PNGs.
        // ImageIO on macOS displays those directly even though the portable
        // Rust decoder cannot, so retain the original bytes as a fallback.
        let (detail_score, preview) = match decode_image_bounded(&bytes, "IPA icon") {
            Ok(image) => {
                let shortest = image.width().min(image.height());
                let longest = image.width().max(image.height());
                let square_enough = shortest >= 40 && shortest.saturating_mul(100) / longest >= 82;
                if !square_enough && name_score == 1_000 {
                    continue;
                }
                (
                    image.width() as u64 * image.height() as u64,
                    make_icon(&image, 256)?,
                )
            }
            Err(_) if declared || name_score >= 15_000 => (archived_size, bytes),
            Err(_) => continue,
        };
        let score = name_score as u64 * 1_000_000 + detail_score;
        if best
            .as_ref()
            .is_none_or(|(best_score, _)| score > *best_score)
        {
            best = Some((score, preview));
        }
    }

    let (_, preview) = best.ok_or_else(|| {
        AppError::Misc("This IPA does not contain an extractable app icon".into())
    })?;
    let destination = PathBuf::from(destination);
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent).map_err(|error| {
            AppError::Filesystem(
                "Unable to create icon preview folder".into(),
                error.to_string(),
            )
        })?;
    }
    fs::write(&destination, preview).map_err(|error| {
        AppError::Filesystem("Unable to save IPA icon preview".into(), error.to_string())
    })?;
    Ok(destination.to_string_lossy().into_owned())
}

fn validate_bundle_id(bundle_id: &str) -> Result<(), AppError> {
    let valid = !bundle_id.is_empty()
        && bundle_id.len() <= 255
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

fn validate_ios_version(version: &str) -> bool {
    let components: Vec<_> = version.split('.').collect();
    (1..=3).contains(&components.len())
        && components.iter().all(|component| {
            !component.is_empty()
                && component
                    .chars()
                    .all(|character| character.is_ascii_digit())
                && component.parse::<u16>().is_ok_and(|number| number <= 999)
        })
}

fn set_custom_icon_plist(info: &mut Dictionary) {
    let files = Value::Array(vec![Value::String("SlipIcon".to_string())]);
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
    if let Some(display_name) = options.display_name.as_deref() {
        let display_name = display_name.trim();
        if display_name.chars().count() > 128 || display_name.chars().any(char::is_control) {
            return Err(AppError::Misc(
                "App names must be 128 characters or fewer and cannot contain control characters"
                    .into(),
            ));
        }
    }

    let removed: HashSet<_> = options.removed_extensions.iter().cloned().collect();
    if let Some(unknown) = removed
        .iter()
        .find(|path| !parsed.extension_info_paths.contains_key(path.as_str()))
    {
        return Err(AppError::Misc(format!(
            "The requested extension path is not part of this IPA: {unknown}"
        )));
    }
    let custom_icon = options
        .custom_icon_path
        .as_ref()
        .filter(|path| !path.trim().is_empty())
        .map(|path| {
            let metadata = fs::metadata(path).map_err(|error| {
                AppError::Filesystem("Unable to inspect custom icon".into(), error.to_string())
            })?;
            if metadata.len() > MAX_ICON_BYTES {
                return Err(AppError::Misc(
                    "The custom icon is unexpectedly large".into(),
                ));
            }
            let bytes = fs::read(path).map_err(|error| {
                AppError::Filesystem("Unable to open custom icon".into(), error.to_string())
            })?;
            decode_image_bounded(&bytes, "custom icon")
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
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&prepared_dir, fs::Permissions::from_mode(0o700)).map_err(|e| {
            AppError::Filesystem("Unable to protect temporary folder".into(), e.to_string())
        })?;
    }
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let output_path = prepared_dir.join(format!("prepared-{}-{timestamp}.ipa", std::process::id()));
    let output_file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&output_path)
        .map_err(|e| {
            AppError::Filesystem("Unable to create prepared IPA".to_string(), e.to_string())
        })?;
    let mut cleanup = RemoveOnDrop {
        path: output_path.clone(),
        keep: false,
    };
    let mut output = ZipWriter::new(output_file);

    if source.len() > MAX_ARCHIVE_ENTRIES {
        return Err(AppError::Misc(format!(
            "The IPA contains too many archive entries ({})",
            source.len()
        )));
    }
    let mut archive_names = HashSet::new();
    for index in 0..source.len() {
        let mut entry = source.by_index(index).map_err(|e| {
            AppError::Filesystem("Unable to read IPA entry".to_string(), e.to_string())
        })?;
        let name = validated_archive_name(entry.name())?;
        if !archive_names.insert(name.clone()) {
            return Err(AppError::Misc(format!(
                "The IPA contains a duplicate archive entry: {name}"
            )));
        }
        if entry
            .unix_mode()
            .is_some_and(|mode| mode & 0o170000 == 0o120000)
        {
            return Err(AppError::Misc(format!(
                "The IPA contains an unsupported symbolic link: {name}"
            )));
        }
        if removed
            .iter()
            .any(|extension| name == *extension || name.starts_with(&format!("{extension}/")))
        {
            continue;
        }
        if custom_icon.is_some()
            && (name.starts_with(&format!("{}SlipIcon", parsed.main_root))
                || name.starts_with(&format!("{}SideloomIcon", parsed.main_root)))
        {
            continue;
        }

        let compression = entry.compression();
        let file_options = SimpleFileOptions::default()
            .compression_method(compression)
            .unix_permissions(entry.unix_mode().unwrap_or(0o644));
        if entry.is_dir() {
            output.add_directory(&name, file_options).map_err(|e| {
                AppError::Filesystem("Unable to write IPA directory".to_string(), e.to_string())
            })?;
            continue;
        }

        if name == parsed.main_info_path {
            output.start_file(&name, file_options).map_err(|e| {
                AppError::Filesystem("Unable to write IPA metadata".to_string(), e.to_string())
            })?;
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
                if !validate_ios_version(version) {
                    return Err(AppError::Misc(
                        "Minimum iOS must be a numeric version such as 17.0 or 27.0.1".into(),
                    ));
                }
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
                if key.chars().count() > 256 || key.chars().any(char::is_control) {
                    return Err(AppError::Misc(
                        "Info.plist override keys must be one line and 256 characters or fewer"
                            .into(),
                    ));
                }
                if item.value.len() > 1_048_576 {
                    return Err(AppError::Misc(
                        "Info.plist override values are limited to 1 MB".into(),
                    ));
                }
                if matches!(
                    key,
                    "CFBundleIdentifier"
                        | "CFBundleExecutable"
                        | "CFBundlePackageType"
                        | "CFBundleSupportedPlatforms"
                        | "DTPlatformName"
                        | "DTPlatformVersion"
                        | "LSRequiresIPhoneOS"
                ) {
                    return Err(AppError::Misc(format!(
                        "{key} is identity-critical and cannot be changed through a plist override"
                    )));
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
            let bytes = read_entry_limited(&mut entry, MAX_PLIST_BYTES, "extension metadata")?;
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
            output.start_file(&name, file_options).map_err(|e| {
                AppError::Filesystem(
                    "Unable to write extension metadata".to_string(),
                    e.to_string(),
                )
            })?;
            output.write_all(&plist_bytes(&info)?).map_err(|e| {
                AppError::Filesystem(
                    "Unable to write extension metadata".to_string(),
                    e.to_string(),
                )
            })?;
        } else {
            // Preserve the original compressed bytes for unchanged files. Large IPAs are
            // mostly assets and frameworks; inflating and deflating those entries again
            // wastes seconds without changing their content.
            output.raw_copy_file(entry).map_err(|e| {
                AppError::Filesystem("Unable to copy IPA entry".to_string(), e.to_string())
            })?;
        }
    }

    if let Some(icon) = custom_icon {
        for (name, size) in [
            ("SlipIcon.png", 60),
            ("SlipIcon@2x.png", 120),
            ("SlipIcon@3x.png", 180),
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
    cleanup.keep = true;
    Ok(output_path)
}

pub fn export_prepared_ipa(
    options: &IpaInstallOptions,
    destination: &Path,
) -> Result<u64, AppError> {
    if !destination
        .extension()
        .and_then(|value| value.to_str())
        .is_some_and(|extension| extension.eq_ignore_ascii_case("ipa"))
    {
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

#[cfg(test)]
mod tests {
    use super::{
        IpaInstallOptions, PlistOverride, extract_ipa_icon, macho_encryption_status, make_icon,
        parse_ipa, plist_bytes, plist_override_value, prepare_ipa_in, validate_bundle_id,
        validate_ios_version, validated_archive_name,
    };
    use image::DynamicImage;
    use plist::{Dictionary, Value};
    use std::{
        fs::File,
        io::{Read, Write},
        time::SystemTime,
    };
    use zip::{CompressionMethod, ZipWriter, write::SimpleFileOptions};

    #[test]
    fn validates_bundle_ids() {
        assert!(validate_bundle_id("com.example.App-2").is_ok());
        assert!(validate_bundle_id("missing-dot").is_err());
        assert!(validate_bundle_id("com.example.bad_value").is_err());
        assert!(validate_bundle_id("com..example").is_err());
        assert!(validate_bundle_id(&format!("com.example.{}", "a".repeat(245))).is_err());
    }

    #[test]
    fn validates_ios_versions() {
        assert!(validate_ios_version("17"));
        assert!(validate_ios_version("27.0.1"));
        assert!(!validate_ios_version("27..1"));
        assert!(!validate_ios_version("27.beta"));
        assert!(!validate_ios_version("1000.0"));
    }

    #[test]
    fn rejects_non_finite_plist_numbers() {
        for value in ["NaN", "inf", "-inf"] {
            let override_value = PlistOverride {
                key: "AuditNumber".into(),
                value_type: "Real".into(),
                value: value.into(),
            };
            assert!(plist_override_value(&override_value).is_err());
        }
    }

    #[test]
    fn reads_encryption_from_a_macho_prefix() {
        let mut executable = vec![0_u8; 64];
        executable[..4].copy_from_slice(&[0xcf, 0xfa, 0xed, 0xfe]);
        executable[16..20].copy_from_slice(&1_u32.to_le_bytes());
        executable[32..36].copy_from_slice(&0x2c_u32.to_le_bytes());
        executable[36..40].copy_from_slice(&24_u32.to_le_bytes());
        executable[48..52].copy_from_slice(&1_u32.to_le_bytes());
        assert_eq!(macho_encryption_status(&executable), "Encrypted");
        executable[48..52].copy_from_slice(&0_u32.to_le_bytes());
        assert_eq!(macho_encryption_status(&executable), "Decrypted");
    }

    #[test]
    fn rejects_unsafe_archive_paths() {
        assert!(validated_archive_name("Payload/App.app/Info.plist").is_ok());
        assert!(validated_archive_name("../outside").is_err());
        assert!(validated_archive_name("Payload/../outside").is_err());
        assert!(validated_archive_name("/absolute/path").is_err());
        assert!(validated_archive_name("C:\\absolute\\path").is_err());
        assert!(validated_archive_name("Payload/App.app/.\\secret").is_err());
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
        let mut primary_icon = Dictionary::new();
        primary_icon.insert(
            "CFBundleIconFiles".to_string(),
            Value::Array(vec![Value::String("BrandMark60x60".to_string())]),
        );
        let mut icons = Dictionary::new();
        icons.insert(
            "CFBundlePrimaryIcon".to_string(),
            Value::Dictionary(primary_icon),
        );
        app.insert("CFBundleIcons".to_string(), Value::Dictionary(icons));
        zip.start_file("Payload/Test.app/Info.plist", options)
            .unwrap();
        zip.write_all(&plist_bytes(&app).unwrap()).unwrap();
        zip.start_file("Payload/Test.app/BrandMark60x60@2x.png", options)
            .unwrap();
        zip.write_all(&make_icon(&DynamicImage::new_rgba8(120, 120), 120).unwrap())
            .unwrap();

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

        let preview = std::env::temp_dir().join(format!("sideloom-test-{unique}-icon.png"));
        extract_ipa_icon(
            path.to_string_lossy().into_owned(),
            preview.to_string_lossy().into_owned(),
        )
        .unwrap();
        let preview_image = image::open(&preview).unwrap();
        assert_eq!((preview_image.width(), preview_image.height()), (256, 256));

        std::fs::remove_file(path).unwrap();
        std::fs::remove_file(preview).unwrap();
    }

    #[test]
    fn prepares_identity_compatibility_and_typed_metadata() {
        let unique = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("slip-prepare-test-{unique}"));
        std::fs::create_dir_all(&root).unwrap();
        let source_path = root.join("Source.ipa");
        let file = File::create(&source_path).unwrap();
        let mut zip = ZipWriter::new(file);
        let file_options =
            SimpleFileOptions::default().compression_method(CompressionMethod::Deflated);
        let mut app = Dictionary::new();
        app.insert(
            "CFBundleIdentifier".into(),
            Value::String("com.example.Source".into()),
        );
        app.insert("CFBundleDisplayName".into(), Value::String("Source".into()));
        app.insert(
            "CFBundleShortVersionString".into(),
            Value::String("1.0".into()),
        );
        app.insert("CFBundleVersion".into(), Value::String("1".into()));
        app.insert("MinimumOSVersion".into(), Value::String("16.0".into()));
        app.insert(
            "UISupportedDevices".into(),
            Value::Array(vec![Value::String("iPhone15,2".into())]),
        );
        zip.start_file("Payload/Source.app/Info.plist", file_options)
            .unwrap();
        zip.write_all(&plist_bytes(&app).unwrap()).unwrap();
        zip.start_file("Payload/Source.app/Asset.bin", file_options)
            .unwrap();
        zip.write_all(&vec![7_u8; 32_768]).unwrap();
        zip.finish().unwrap();

        let options = IpaInstallOptions {
            app_path: source_path.to_string_lossy().into_owned(),
            display_name: Some("Prepared".into()),
            bundle_id: Some("com.example.Prepared".into()),
            removed_extensions: vec![],
            custom_icon_path: None,
            increased_memory_limit: false,
            minimum_os_version: Some("17.0".into()),
            remove_supported_devices: true,
            enable_file_sharing: true,
            plist_overrides: vec![PlistOverride {
                key: "SlipValidated".into(),
                value_type: "Boolean".into(),
                value: "true".into(),
            }],
        };
        let prepared_path = prepare_ipa_in(&root, &options).unwrap();
        let prepared_file = File::open(&prepared_path).unwrap();
        let mut prepared = zip::ZipArchive::new(prepared_file).unwrap();
        let mut info_bytes = Vec::new();
        prepared
            .by_name("Payload/Source.app/Info.plist")
            .unwrap()
            .read_to_end(&mut info_bytes)
            .unwrap();
        let info: Dictionary = plist::from_bytes(&info_bytes).unwrap();
        assert_eq!(
            info["CFBundleIdentifier"].as_string(),
            Some("com.example.Prepared")
        );
        assert_eq!(info["CFBundleDisplayName"].as_string(), Some("Prepared"));
        assert_eq!(info["MinimumOSVersion"].as_string(), Some("17.0"));
        assert_eq!(info["UIFileSharingEnabled"].as_boolean(), Some(true));
        assert_eq!(info["SlipValidated"].as_boolean(), Some(true));
        assert!(!info.contains_key("UISupportedDevices"));
        assert_eq!(
            prepared
                .by_name("Payload/Source.app/Asset.bin")
                .unwrap()
                .compression(),
            CompressionMethod::Deflated
        );

        std::fs::remove_dir_all(root).unwrap();
    }
}
