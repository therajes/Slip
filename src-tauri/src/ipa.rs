use image::{DynamicImage, ImageFormat, imageops::FilterType};
use plist::{Dictionary, Value};
use serde::{Deserialize, Serialize};
use std::{
    collections::{HashMap, HashSet},
    fs::{self, File, OpenOptions},
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
    pub preflight: PreflightReport,
}

/// Versioned, bounded evidence from the source archive, never an Apple capability promise.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PreflightReport { pub schema_version: u8, pub checks: Vec<PreflightCheck> }
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PreflightCheck {
    pub id: String, pub severity: String, pub stage: String, pub component: String,
    pub evidence: String, pub observed: Option<String>, pub expected: Option<String>,
    pub resolution: String,
}
// Large games remain supported: 200k entries, 32 GiB expanded total, 8 GiB per
// file. Highly compressible tiny metadata is exempt from the 1000:1 ratio cap.
const MAX_ENTRIES: usize = 200_000;
const MAX_EXPANDED: u64 = 32 * 1024 * 1024 * 1024;
const MAX_ENTRY: u64 = 8 * 1024 * 1024 * 1024;
const MAX_METADATA: u64 = 8 * 1024 * 1024;
const MAX_BINARY_INSPECTION: u64 = 256 * 1024 * 1024;

fn validate_archive(archive: &mut ZipArchive<File>) -> Result<(), AppError> {
    if archive.len() > MAX_ENTRIES { return Err(AppError::Misc("IPA exceeds the 200,000-entry safety limit.".into())); }
    let mut total = 0u64;
    let mut path_bytes = 0usize;
    let mut names = HashSet::new();
    for index in 0..archive.len() {
        let entry = archive.by_index(index).map_err(|e| AppError::Misc(format!("Invalid IPA entry: {e}")))?;
        validate_archive_name(entry.name())?;
        path_bytes = path_bytes.saturating_add(entry.name().len());
        if path_bytes > 32 * 1024 * 1024 { return Err(AppError::Misc("IPA archive paths exceed the 32 MiB metadata budget.".into())); }
        if entry.name().len() > 4096 || entry.name().split('/').count() > 128 {
            return Err(AppError::Misc("IPA archive path exceeds inspection limits.".into()));
        }
        if !names.insert(entry.name().trim_end_matches('/').to_lowercase()) {
            return Err(AppError::Misc("IPA contains duplicate or case-colliding paths.".into()));
        }
        let kind = entry.unix_mode().unwrap_or(0) & 0o170000;
        if !matches!(kind, 0 | 0o100000 | 0o040000) {
            return Err(AppError::Misc("IPA contains a symbolic link or special file; obtain a regular-file IPA.".into()));
        }
        total = total.checked_add(entry.size()).ok_or_else(|| AppError::Misc("IPA expanded size overflow.".into()))?;
        if entry.size() > MAX_ENTRY || total > MAX_EXPANDED ||
            (entry.size() > 16 * 1024 * 1024 && entry.size() / entry.compressed_size().max(1) > 1000) {
            return Err(AppError::Misc("IPA exceeds archive safety limits (8 GiB/file, 32 GiB total, or 1000:1 compression).".into()));
        }
    }
    Ok(())
}

fn bounded_entry(archive: &mut ZipArchive<File>, name: &str, limit: u64) -> Result<Vec<u8>, AppError> {
    let entry = archive.by_name(name).map_err(|e| AppError::Misc(format!("Unable to inspect {name}: {e}")))?;
    if entry.size() > limit { return Err(AppError::Misc(format!("Inspection input {name} exceeds its {limit}-byte safety budget."))); }
    let mut data = Vec::new();
    entry.take(limit + 1).read_to_end(&mut data).map_err(|e| AppError::Misc(format!("Unable to read {name}: {e}")))?;
    if data.len() as u64 > limit { return Err(AppError::Misc("IPA entry expands beyond its inspection budget.".into())); }
    Ok(data)
}

/// Preserve structured capability values so equal-length arrays cannot hide a
/// changed App Group or associated domain. Oversized values remain explicit.
pub(crate) fn entitlement_summary(value: &Value) -> String {
    let encoded = serde_json::to_string(value).unwrap_or_else(|_| "Unverifiable structured value".into());
    if encoded.len() > 4096 { "Unverifiable: structured entitlement exceeds display budget".into() } else { encoded }
}

fn source_checks(archive: &mut ZipArchive<File>, root: &str, info: &Dictionary) -> Vec<PreflightCheck> {
    let mut checks = Vec::new();
    let mut add = |id: &str, severity: &str, observed: Option<String>, expected: Option<String>, evidence: &str, resolution: &str| {
        checks.push(PreflightCheck { id: format!("{root}:{id}"), severity: severity.into(), stage: "offlineAnalysis".into(), component: root.into(), observed, expected, evidence: evidence.into(), resolution: resolution.into() });
    };
    let binary = plist_string(info, "CFBundleExecutable").and_then(|name| bounded_entry(archive, &format!("{root}{name}"), MAX_BINARY_INSPECTION).ok());
    if let Some(bytes) = binary.as_ref() {
        let status = macho_encryption_status(bytes);
        add("encryption", if status == "Encrypted" { "block" } else if status == "Decrypted" { "pass" } else { "unknown" }, Some(status), Some("Unencrypted Mach-O".into()), "Mach-O load commands", "Use a complete, legitimately decrypted IPA.");
        let cpu = read_u32(bytes, 4, true);
        let architecture = match cpu { Some(0x0100000c) => Some("arm64"), Some(12) => Some("arm"), Some(0x01000007) => Some("x86_64"), _ => None };
        add("architecture", if architecture == Some("x86_64") { "block" } else if architecture.is_some() { "pass" } else { "unknown" }, architecture.map(str::to_owned), Some("Physical iPhone architecture".into()), "Mach-O CPU header (fat slices require further verification)", "Use a device build rather than an iOS Simulator archive.");
        // Read actual embedded XML entitlements from the code-signature SuperBlob.
        let entitlement = embedded_xml_entitlements(bytes);
        if let Some(entitlements) = entitlement {
            for (key, value) in entitlements.iter().take(64) {
                if key.len() > 256 { continue; }
                let observed = entitlement_summary(value);
                add(&format!("entitlement:{key}"), "unknown", Some(observed), None, "Embedded code-signature entitlement blob; source signature is not a newly issued profile", "Compare this capability with the actual profile issued for the selected team before transfer.");
            }
        } else {
            add("entitlements", "unknown", None, None, "No readable XML code-signature entitlements; DER-only or unsigned binary may be present", "Entitlements require verification against the newly issued profile.");
        }
    } else { add("binary", "unknown", None, None, "Executable absent or beyond finite inspection budget", "Use a complete IPA and review signing diagnostics."); }
    let profile_name = format!("{root}embedded.mobileprovision");
    let profile = bounded_entry(archive, &profile_name, MAX_METADATA).ok().and_then(|bytes| xml_dictionary(&bytes));
    add("source-profile", "unknown", profile.as_ref().and_then(|p| plist_string(p, "Name")).map(|v| v.chars().take(128).collect()), None, if profile.is_some() { "Source CMS profile metadata (not signature-validated and not Slip's newly issued profile)" } else { "Source provisioning profile missing or unreadable" }, "The source profile does not prove selected-account signing availability.");
    add("minimum-ios", if info.get("MinimumOSVersion").is_some() { "pass" } else { "unknown" }, plist_string(info, "MinimumOSVersion"), None, "Source Info.plist declaration; binary/framework requirements may be higher", "Compare with the selected iPhone OS and inspect nested components.");
    checks
}

fn xml_dictionary(bytes: &[u8]) -> Option<Dictionary> {
    let start = bytes.windows(5).position(|v| v == b"<?xml")?;
    let tail = &bytes[start..];
    let end = tail.windows(8).position(|v| v == b"</plist>")? + 8;
    plist::from_bytes(&tail[..end]).ok()
}

fn embedded_xml_entitlements(bytes: &[u8]) -> Option<Dictionary> {
    let magic = bytes.get(..4)?;
    if matches!(magic, [0xca, 0xfe, 0xba, 0xbe] | [0xbe, 0xba, 0xfe, 0xca]) {
        let little = magic == [0xbe, 0xba, 0xfe, 0xca];
        let count = read_u32(bytes, 4, little)? as usize;
        if count > 32 { return None; }
        for index in 0..count {
            let base = 8 + index * 20;
            let offset = read_u32(bytes, base + 8, little)? as usize;
            let length = read_u32(bytes, base + 12, little)? as usize;
            let slice = bytes.get(offset..offset.checked_add(length)?)?;
            // Nested fat containers are not valid Mach-O slices.
            if thin_macho_encryption(slice).is_some() {
                if let Some(dict) = embedded_xml_entitlements(slice) { return Some(dict); }
            }
        }
        return None;
    }
    let (little, header) = match magic {
        [0xcf, 0xfa, 0xed, 0xfe] => (true, 32usize),
        [0xce, 0xfa, 0xed, 0xfe] => (true, 28usize),
        [0xfe, 0xed, 0xfa, 0xcf] => (false, 32usize),
        [0xfe, 0xed, 0xfa, 0xce] => (false, 28usize),
        _ => return None,
    };
    thin_macho_encryption(bytes)?;
    let count = read_u32(bytes, 16, little)?;
    let mut offset = header;
    for _ in 0..count {
        let command = read_u32(bytes, offset, little)?;
        let size = read_u32(bytes, offset + 4, little)? as usize;
        if command == 0x1d && size >= 16 {
            let start = read_u32(bytes, offset + 8, little)? as usize;
            let length = read_u32(bytes, offset + 12, little)? as usize;
            let blob = bytes.get(start..start.checked_add(length)?)?;
            if read_u32(blob, 0, false)? != 0xfade0cc0 { return None; }
            let records = read_u32(blob, 8, false)? as usize;
            if records > 64 { return None; }
            for index in 0..records {
                let kind = read_u32(blob, 12 + index * 8, false)?;
                let record = read_u32(blob, 16 + index * 8, false)? as usize;
                if kind != 5 || read_u32(blob, record, false)? != 0xfade7171 { continue; }
                let length = read_u32(blob, record + 4, false)? as usize;
                if length < 8 || length > MAX_METADATA as usize { return None; }
                return plist::from_bytes(blob.get(record + 8..record.checked_add(length)?)?).ok();
            }
        }
        offset = offset.checked_add(size)?;
    }
    None
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
        .filter(|value| value.len() <= 4096)
        .map(ToOwned::to_owned)
}

struct IncompleteIpa(Option<PathBuf>);

impl Drop for IncompleteIpa {
    fn drop(&mut self) {
        if let Some(path) = &self.0 {
            let _ = fs::remove_file(path);
        }
    }
}

fn read_plist(archive: &mut ZipArchive<File>, path: &str) -> Result<Dictionary, AppError> {
    let mut entry = archive.by_name(path).map_err(|e| {
        AppError::Filesystem(format!("Unable to read {path} from IPA"), e.to_string())
    })?;
    if entry.size() > MAX_METADATA { return Err(AppError::Misc(format!("Plist {path} exceeds 8 MiB."))); }
    let mut bytes = Vec::new();
    entry.by_ref().take(MAX_METADATA + 1).read_to_end(&mut bytes).map_err(|e| AppError::Misc(format!("Unable to read plist: {e}")))?;
    if bytes.len() as u64 > MAX_METADATA { return Err(AppError::Misc("Plist exceeds inspection limit.".into())); }
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
        [0xcf, 0xfa, 0xed, 0xfe] => (true, 32usize),
        [0xce, 0xfa, 0xed, 0xfe] => (true, 28),
        [0xfe, 0xed, 0xfa, 0xcf] => (false, 32),
        [0xfe, 0xed, 0xfa, 0xce] => (false, 28),
        _ => return None,
    };
    let command_count = read_u32(bytes, 16, little_endian)? as usize;
    let commands_size = read_u32(bytes, 20, little_endian)? as usize;
    let commands_end = header_size.checked_add(commands_size)?;
    if commands_end > bytes.len() || command_count > commands_size / 8 {
        return None;
    }
    let mut encrypted = false;
    let mut offset = header_size;
    for _ in 0..command_count {
        let command = read_u32(bytes, offset, little_endian)?;
        let command_size = read_u32(bytes, offset + 4, little_endian)? as usize;
        let end = offset.checked_add(command_size)?;
        if command_size < 8 || end > commands_end {
            return None;
        }
        if command == 0x21 || command == 0x2c {
            let required_size = if command == 0x2c { 24 } else { 20 };
            if command_size < required_size {
                return None;
            }
            encrypted |= read_u32(bytes, offset + 16, little_endian)? != 0;
        }
        offset = end;
    }
    (offset == commands_end).then_some(encrypted)
}

fn macho_encryption_status(bytes: &[u8]) -> String {
    if let Some(encrypted) = thin_macho_encryption(bytes) {
        return if encrypted { "Encrypted" } else { "Decrypted" }.to_string();
    }
    let magic = bytes.get(..4);
    let little_endian = match magic {
        Some([0xca, 0xfe, 0xba, 0xbe]) | Some([0xca, 0xfe, 0xba, 0xbf]) => false,
        Some([0xbe, 0xba, 0xfe, 0xca]) | Some([0xbf, 0xba, 0xfe, 0xca]) => true,
        _ => return "Unknown".to_string(),
    };
    let fat64 = matches!(
        magic,
        Some([0xca, 0xfe, 0xba, 0xbf]) | Some([0xbf, 0xba, 0xfe, 0xca])
    );
    let arch_size = if fat64 { 32 } else { 20 };
    let read_u64 = |offset| -> Option<usize> {
        let chunk: [u8; 8] = bytes.get(offset..offset + 8)?.try_into().ok()?;
        usize::try_from(if little_endian {
            u64::from_le_bytes(chunk)
        } else {
            u64::from_be_bytes(chunk)
        })
        .ok()
    };
    let Some(count) = read_u32(bytes, 4, little_endian).map(|value| value as usize) else {
        return "Unknown".into();
    };
    if count == 0 || count > bytes.len().saturating_sub(8) / arch_size {
        return "Unknown".into();
    }
    let mut unknown = false;
    for index in 0..count {
        let arch = 8 + index * arch_size;
        let offset = if fat64 {
            read_u64(arch + 8)
        } else {
            read_u32(bytes, arch + 8, little_endian).map(|value| value as usize)
        };
        let size = if fat64 {
            read_u64(arch + 16)
        } else {
            read_u32(bytes, arch + 12, little_endian).map(|value| value as usize)
        };
        let slice = offset.zip(size).and_then(|(offset, size)| {
            offset
                .checked_add(size)
                .and_then(|end| bytes.get(offset..end))
        });
        match slice.and_then(thin_macho_encryption) {
            Some(true) => return "Encrypted".into(),
            Some(false) => {}
            None => unknown = true,
        }
    }
    if unknown { "Unknown" } else { "Decrypted" }.into()
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

fn has_ipa_extension(path: &Path) -> bool {
    path.extension()
        .and_then(|value| value.to_str())
        .is_some_and(|value| value.eq_ignore_ascii_case("ipa"))
}

fn validate_archive_name(name: &str) -> Result<(), AppError> {
    let path = name.trim_end_matches('/');
    if path.is_empty()
        || name.contains('\\')
        || name.contains('\0')
        || path
            .split('/')
            .any(|part| part.is_empty() || part == "." || part == ".." || part.contains(':'))
    {
        return Err(AppError::Misc(format!(
            "The IPA contains an unsafe archive path: {name:?}. Obtain a clean IPA and try again."
        )));
    }
    Ok(())
}

fn executable_encryption(
    archive: &mut ZipArchive<File>,
    root: &str,
    info: &Dictionary,
) -> Result<String, AppError> {
    let Some(executable) = plist_string(info, "CFBundleExecutable") else {
        return Ok("Unknown".into());
    };
    if executable.is_empty()
        || executable.contains('/')
        || executable.contains('\\')
        || executable == "."
        || executable == ".."
    {
        return Err(AppError::Misc(format!(
            "Invalid CFBundleExecutable in {root}Info.plist"
        )));
    }
    let path = format!("{root}{executable}");
    let bytes = bounded_entry(archive, &path, MAX_BINARY_INSPECTION)?;
    Ok(macho_encryption_status(&bytes))
}

fn parse_ipa(path: &Path) -> Result<ParsedIpa, AppError> {
    if !has_ipa_extension(path) {
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

    validate_archive(&mut archive)?;
    let mut main_info_path = None;
    let mut entry_names = HashSet::new();
    let mut app_roots = HashSet::new();
    let mut extension_info_paths = HashMap::new();
    for index in 0..archive.len() {
        let entry = archive.by_index(index).map_err(|e| {
            AppError::Filesystem("Unable to inspect IPA entry".to_string(), e.to_string())
        })?;
        let name = entry.name().to_string();
        validate_archive_name(&name)?;
        if !entry_names.insert(name.trim_end_matches('/').to_string()) {
            return Err(AppError::Misc(format!(
                "The IPA contains duplicate archive entries at {name}. Obtain a clean IPA."
            )));
        }
        let components: Vec<_> = name.trim_end_matches('/').split('/').collect();
        if components.len() >= 2 && components[0] == "Payload" && components[1].ends_with(".app") {
            app_roots.insert(components[1].to_string());
        }
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

    if app_roots.len() > 1 {
        return Err(AppError::Misc("The IPA contains multiple apps in Payload. Select an IPA containing exactly one main app.".into()));
    }
    let main_info_path = main_info_path
        .ok_or_else(|| AppError::Misc("No iOS app was found in Payload".to_string()))?;
    let main_root = main_info_path.trim_end_matches("Info.plist").to_string();
    let main_info = read_plist(&mut archive, &main_info_path)?;
    let bundle_id = plist_string(&main_info, "CFBundleIdentifier")
        .ok_or_else(|| AppError::Misc("The app has no bundle identifier".to_string()))?;
    validate_bundle_id(&bundle_id)?;
    let app_name = plist_string(&main_info, "CFBundleDisplayName")
        .or_else(|| plist_string(&main_info, "CFBundleName"))
        .unwrap_or_else(|| "Unnamed App".to_string());

    extension_info_paths.retain(|root, _| root.starts_with(&main_root));
    if extension_info_paths.len() > 128 { return Err(AppError::Misc("IPA exceeds the 128-extension inspection budget.".into())); }
    let mut encrypted_extensions = Vec::new();
    let mut extensions = Vec::new();
    for (extension_path, info_path) in &extension_info_paths {
        if !extension_path.starts_with(&main_root) {
            continue;
        }
        let info = read_plist(&mut archive, info_path)?;
        if executable_encryption(&mut archive, &format!("{extension_path}/"), &info)? == "Encrypted"
        {
            encrypted_extensions.push(extension_name(&info, extension_path));
        }
        let extension_id = plist_string(&info, "CFBundleIdentifier")
            .filter(|value| !value.trim().is_empty())
            .ok_or_else(|| {
                AppError::Misc(format!(
                    "The extension {extension_path} has no bundle identifier"
                ))
            })?;
        validate_bundle_id(&extension_id)?;
        extensions.push(IpaExtensionInfo {
            path: extension_path.clone(),
            bundle_id: extension_id,
            name: extension_name(&info, extension_path),
            extension_point: extension_point(&info),
        });
    }
    extensions.sort_by(|left, right| left.name.cmp(&right.name));

    let executable = plist_string(&main_info, "CFBundleExecutable");
    let main_encryption = executable_encryption(&mut archive, &main_root, &main_info)?;
    let encryption_status = if encrypted_extensions.is_empty() {
        main_encryption
    } else {
        "Encrypted".into()
    };

    let mut preflight_checks = source_checks(&mut archive, &main_root, &main_info);
    for (root, path) in &extension_info_paths {
        let info = read_plist(&mut archive, path)?;
        preflight_checks.extend(source_checks(&mut archive, &format!("{root}/"), &info));
    }
    let nested: Vec<_> = (0..archive.len()).filter_map(|index| {
        let entry = archive.by_index(index).ok()?;
        let name = entry.name();
        (name.starts_with(&main_root) && name.ends_with(".framework/Info.plist")).then(|| name.to_owned())
    }).take(129).collect();
    if nested.len() > 128 { return Err(AppError::Misc("IPA exceeds 128 nested framework inspection limit.".into())); }
    for path in nested {
        let info = read_plist(&mut archive, &path)?;
        preflight_checks.extend(source_checks(&mut archive, path.trim_end_matches("Info.plist"), &info));
    }
    if preflight_checks.len() > 1024 { return Err(AppError::Misc("IPA has too many components/capabilities for bounded inspection.".into())); }
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
    if encryption_status == "Unknown" {
        warnings.push("The executable's encryption status could not be verified. Use a complete iOS IPA from a trusted source; malformed or unsupported executables may fail signing or installation.".into());
    }
    if encryption_status == "Encrypted" {
        warnings.push(
            "This IPA contains an App Store encrypted executable. Provide a legitimately decrypted IPA before signing or installing it."
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
            preflight: PreflightReport { schema_version: 1, checks: preflight_checks },
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
    validate_archive(&mut archive)?;
    let mut candidates = Vec::new();

    for index in 0..archive.len() {
        let entry = archive.by_index(index).map_err(|error| {
            AppError::Filesystem("Unable to inspect IPA icon entry".into(), error.to_string())
        })?;
        let name = entry.name().replace('\\', "/");
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
        candidates.push((score, declared, entry.size(), name));
    }

    let mut best: Option<(u64, Vec<u8>)> = None;
    for (name_score, declared, archived_size, name) in candidates {
        let mut entry = archive.by_name(&name).map_err(|error| {
            AppError::Filesystem("Unable to read IPA icon".into(), error.to_string())
        })?;
        if entry.size() > MAX_METADATA { continue; }
        let mut bytes = Vec::new();
        entry.by_ref().take(MAX_METADATA + 1).read_to_end(&mut bytes).map_err(|error| {
            AppError::Filesystem("Unable to read IPA icon".into(), error.to_string())
        })?;
        // Some real-world IPAs still contain Apple's CgBI-optimized PNGs.
        // ImageIO on macOS displays those directly even though the portable
        // Rust decoder cannot, so retain the original bytes as a fallback.
        let (detail_score, preview) = match image::load_from_memory(&bytes) {
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
    let mut icons = Dictionary::new();
    icons.insert(
        "CFBundlePrimaryIcon".to_string(),
        Value::Dictionary(primary),
    );
    info.insert(
        "CFBundleIcons".to_string(),
        Value::Dictionary(icons.clone()),
    );
    info.insert("CFBundleIcons~ipad".to_string(), Value::Dictionary(icons));
    info.remove("CFBundleIconName");
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
    for extension in &removed {
        if !parsed.extension_info_paths.contains_key(extension) {
            return Err(AppError::Misc(format!(
                "The selected extension {extension} is not present in this IPA. Inspect the IPA again before preparing it."
            )));
        }
    }
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

    validate_archive(&mut source)?;
    let prepared_dir = temp_root.join(format!("sideloom-owned-{}-{}", std::process::id(), SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_nanos()));
    fs::create_dir(&prepared_dir).map_err(|e| {
        AppError::Filesystem(
            "Unable to create temporary folder".to_string(),
            e.to_string(),
        )
    })?;
    #[cfg(unix)] {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&prepared_dir, fs::Permissions::from_mode(0o700)).map_err(|e| AppError::Misc(format!("Unable to protect temporary IPA directory: {e}")))?;
    }
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let output_path = prepared_dir.join(format!("prepared-{timestamp}.ipa"));
    let output_file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&output_path)
        .map_err(|e| {
            AppError::Filesystem("Unable to create prepared IPA".to_string(), e.to_string())
        })?;
    let mut incomplete = IncompleteIpa(Some(output_path.clone()));
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
                && let Some(suffix) =
                    original_id.strip_prefix(&format!("{}.", parsed.info.bundle_id))
            {
                info.insert(
                    "CFBundleIdentifier".to_string(),
                    Value::String(format!("{target_bundle_id}.{suffix}")),
                );
            }
            for key in [
                "WKCompanionAppBundleIdentifier",
                "NSExtensionContainingAppBundleIdentifier",
            ] {
                if info.get(key).and_then(Value::as_string) == Some(parsed.info.bundle_id.as_str())
                {
                    info.insert(key.into(), Value::String(target_bundle_id.clone()));
                }
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
    incomplete.0 = None;
    Ok(output_path)
}

pub fn export_prepared_ipa(
    options: &IpaInstallOptions,
    destination: &Path,
) -> Result<u64, AppError> {
    if !has_ipa_extension(destination) {
        return Err(AppError::Misc(
            "The exported file must use the .ipa extension".to_string(),
        ));
    }
    let source = Path::new(&options.app_path);
    let same_path = source
        .canonicalize()
        .ok()
        .zip(destination.canonicalize().ok())
        .is_some_and(|(source, destination)| source == destination);
    #[cfg(unix)]
    let same_path = same_path || {
        use std::os::unix::fs::MetadataExt;
        source
            .metadata()
            .ok()
            .zip(destination.metadata().ok())
            .is_some_and(|(source, destination)| {
                source.dev() == destination.dev() && source.ino() == destination.ino()
            })
    };
    if same_path {
        return Err(AppError::Misc(
            "Choose a different export path to preserve the original IPA.".into(),
        ));
    }
    if let Some(parent) = destination
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
    {
        fs::create_dir_all(parent).map_err(|error| {
            AppError::Filesystem(
                "Unable to create the export folder".to_string(),
                error.to_string(),
            )
        })?;
    }
    let prepared = prepare_ipa_in(&std::env::temp_dir(), options)?;
    let _prepared_cleanup = IncompleteIpa(Some(prepared.clone()));
    let export_name = destination
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("Export.ipa");
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let staging = destination.with_file_name(format!(".{export_name}.{stamp}.tmp"));
    let result = (|| {
        let mut staged_file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&staging)
            .map_err(|error| {
                AppError::Filesystem("Unable to create IPA export".into(), error.to_string())
            })?;
        let _staging_cleanup = IncompleteIpa(Some(staging.clone()));
        let mut input = File::open(&prepared).map_err(|error| {
            AppError::Filesystem("Unable to read prepared IPA".into(), error.to_string())
        })?;
        let size = std::io::copy(&mut input, &mut staged_file).map_err(|error| {
            AppError::Filesystem("Unable to write IPA export".into(), error.to_string())
        })?;
        staged_file.sync_all().map_err(|error| {
            AppError::Filesystem("Unable to finish IPA export".into(), error.to_string())
        })?;
        drop(staged_file);
        fs::rename(&staging, destination).map_err(|error| {
            AppError::Filesystem("Unable to save IPA export".into(), error.to_string())
        })?;
        Ok(size)
    })();
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
    use super::{
        IpaInstallOptions, PlistOverride, extract_ipa_icon, make_icon, parse_ipa, plist_bytes,
        prepare_ipa_in, validate_bundle_id,
    };
    use image::DynamicImage;
    use plist::{Dictionary, Value};
    use std::{
        fs::File,
        io::{Read, Write},
        time::SystemTime,
    };
    use zip::{CompressionMethod, ZipWriter, write::SimpleFileOptions};

    fn fixture(entries: &[(&str, &[u8])], suffix: &str) -> std::path::PathBuf {
        static NEXT_FIXTURE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let unique = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let sequence = NEXT_FIXTURE.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "slip-archive-{}-{unique}-{sequence}.{suffix}",
            std::process::id()
        ));
        let mut zip = ZipWriter::new(File::create(&path).unwrap());
        for (name, data) in entries {
            zip.start_file(*name, SimpleFileOptions::default()).unwrap();
            zip.write_all(data).unwrap();
        }
        zip.finish().unwrap();
        path
    }

    #[test]
    fn rejects_unsafe_archive_paths_and_multiple_main_apps() {
        let mut info = Dictionary::new();
        info.insert(
            "CFBundleIdentifier".into(),
            Value::String("com.example.Test".into()),
        );
        let bytes = plist_bytes(&info).unwrap();
        for unsafe_path in [
            "../outside",
            "/absolute",
            "Payload/../outside",
            "Payload\\Test.app\\Other",
        ] {
            let path = fixture(
                &[
                    ("Payload/Test.app/Info.plist", &bytes),
                    (unsafe_path, b"bad"),
                ],
                "ipa",
            );
            assert!(parse_ipa(&path).is_err(), "accepted {unsafe_path}");
            std::fs::remove_file(path).unwrap();
        }
        let path = fixture(
            &[
                ("Payload/One.app/Info.plist", &bytes),
                ("Payload/Two.app/file", b"other"),
            ],
            "ipa",
        );
        assert!(parse_ipa(&path).is_err());
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn supports_uppercase_ipa_and_preserves_source_on_export() {
        let mut info = Dictionary::new();
        info.insert(
            "CFBundleIdentifier".into(),
            Value::String("com.example.Test".into()),
        );
        let bytes = plist_bytes(&info).unwrap();
        let path = fixture(&[("Payload/Test.app/Info.plist", &bytes)], "IPA");
        assert!(parse_ipa(&path).is_ok());
        let original = std::fs::read(&path).unwrap();
        let options = IpaInstallOptions {
            app_path: path.to_string_lossy().into_owned(),
            display_name: None,
            bundle_id: None,
            removed_extensions: vec![],
            custom_icon_path: None,
            increased_memory_limit: false,
            minimum_os_version: None,
            remove_supported_devices: false,
            enable_file_sharing: false,
            plist_overrides: vec![],
        };
        assert!(super::export_prepared_ipa(&options, &path).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), original);
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn signing_extraction_preserves_small_assets_and_isolates_archives() {
        use isideload::sideload::application::Application;

        let mut info = Dictionary::new();
        info.insert(
            "CFBundleIdentifier".into(),
            Value::String("com.example.Test".into()),
        );
        let bytes = plist_bytes(&info).unwrap();
        let asset = b"This is a real text asset, not a symbolic link.";
        let library = b"small library bytes";
        let path = fixture(
            &[
                ("Payload/Test.app/Info.plist", &bytes),
                ("Payload/Test.app/notice.txt", asset),
                ("Payload/Test.app/tiny.dylib", library),
            ],
            "ipa",
        );
        let first = Application::new(path.clone()).unwrap();
        let second = Application::new(path.clone()).unwrap();
        assert_ne!(first.bundle.bundle_dir, second.bundle.bundle_dir);
        for application in [first, second] {
            let directory = application.bundle.bundle_dir;
            assert_eq!(std::fs::read(directory.join("notice.txt")).unwrap(), asset);
            assert_eq!(
                std::fs::read(directory.join("tiny.dylib")).unwrap(),
                library
            );
            std::fs::remove_dir_all(directory.parent().unwrap().parent().unwrap()).unwrap();
        }
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn validates_macho_load_commands_and_little_endian_fat64() {
        let mut thin = vec![0u8; 56];
        thin[..4].copy_from_slice(&[0xcf, 0xfa, 0xed, 0xfe]);
        thin[16..20].copy_from_slice(&1u32.to_le_bytes());
        thin[20..24].copy_from_slice(&24u32.to_le_bytes());
        thin[32..36].copy_from_slice(&0x2cu32.to_le_bytes());
        thin[36..40].copy_from_slice(&24u32.to_le_bytes());
        thin[48..52].copy_from_slice(&1u32.to_le_bytes());
        assert_eq!(super::macho_encryption_status(&thin), "Encrypted");
        let mut fat = vec![0u8; 40];
        fat[..4].copy_from_slice(&[0xbf, 0xba, 0xfe, 0xca]);
        fat[4..8].copy_from_slice(&1u32.to_le_bytes());
        fat[16..24].copy_from_slice(&40u64.to_le_bytes());
        fat[24..32].copy_from_slice(&(thin.len() as u64).to_le_bytes());
        fat.extend_from_slice(&thin);
        assert_eq!(super::macho_encryption_status(&fat), "Encrypted");
        thin[36..40].copy_from_slice(&8u32.to_le_bytes());
        assert_eq!(super::macho_encryption_status(&thin), "Unknown");
    }

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
    #[test]
    fn rejects_case_collisions_before_inspection() {
        let path = fixture(&[("Payload/Test.app/Info.plist", b"invalid"), ("payload/test.app/info.plist", b"invalid")], "ipa");
        let error = parse_ipa(&path).err().unwrap().to_string();
        assert!(error.contains("case-colliding"));
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn structured_entitlements_compare_contents_not_array_lengths() {
        let first = Value::Array(vec![Value::String("group.first".into())]);
        let second = Value::Array(vec![Value::String("group.other".into())]);
        assert_ne!(super::entitlement_summary(&first), super::entitlement_summary(&second));
        assert!(super::entitlement_summary(&Value::String("x".repeat(5000))).starts_with("Unverifiable:"));
    }

    #[test]
    fn malformed_binary_has_unknown_entitlements_without_scanning_arbitrary_xml() {
        assert!(super::embedded_xml_entitlements(b"arbitrary data \xfa\xde\x71\x71 malformed").is_none());
        assert_eq!(super::macho_encryption_status(&[0xcf, 0xfa, 0xed, 0xfe]), "Unknown");
    }

    #[test]
    fn plist_budget_is_enforced_before_allocation() {
        let huge = vec![0u8; (super::MAX_METADATA + 1) as usize];
        let path = fixture(&[("Payload/Test.app/Info.plist", &huge)], "ipa");
        assert!(parse_ipa(&path).err().unwrap().to_string().contains("8 MiB"));
        std::fs::remove_file(path).unwrap();
    }

}
