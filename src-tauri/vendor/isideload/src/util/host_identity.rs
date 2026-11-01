use serde::Serialize;
use std::sync::OnceLock;

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HostIdentity {
    pub computer_name: String,
    pub model_identifier: String,
    pub os_version: String,
    pub os_build: String,
    pub authentication_description: String,
}

static HOST_IDENTITY: OnceLock<HostIdentity> = OnceLock::new();

pub fn host_identity() -> &'static HostIdentity {
    HOST_IDENTITY.get_or_init(detect_host_identity)
}

// Only descriptor components enter HTTP headers; the display name retains Unicode.
fn descriptor_component(value: &str, fallback: &str) -> String {
    let value: String = value
        .chars()
        .filter(|character| {
            character.is_ascii_alphanumeric() || matches!(character, '.' | ',' | '_' | '-')
        })
        .take(128)
        .collect();
    if value.is_empty() {
        fallback.to_string()
    } else {
        value
    }
}

impl HostIdentity {
    /// Construct an identity from local system values without network access.
    pub fn from_system_values(
        platform: &str,
        computer_name: Option<&str>,
        model: Option<&str>,
        version: Option<&str>,
        build: Option<&str>,
    ) -> Self {
        let platform = descriptor_component(platform, "UnknownPlatform");
        let fallback_model = format!("{platform}-host");
        let model_identifier = descriptor_component(model.unwrap_or(""), &fallback_model);
        let os_version = descriptor_component(version.unwrap_or(""), "Unknown");
        let os_build = descriptor_component(build.unwrap_or(""), "Unknown");
        let computer_name = computer_name
            .map(str::trim)
            .filter(|name| !name.is_empty())
            .unwrap_or(&fallback_model)
            .to_string();
        let os_label = if platform == "macos" {
            if os_version
                .split('.')
                .next()
                .and_then(|major| major.parse::<u32>().ok())
                .is_some_and(|major| major < 11)
            {
                "Mac OS X"
            } else {
                "macOS"
            }
        } else {
            &platform
        };
        let authentication_description = format!(
            "<{model_identifier}> <{os_label};{os_version};{os_build}> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
        );
        Self {
            computer_name,
            model_identifier,
            os_version,
            os_build,
            authentication_description,
        }
    }

    pub fn developer_authentication_description(&self) -> String {
        // Xcode's application identifier is required by the developer protocol.
        self.authentication_description
            .replace("com.apple.akd/1.0", "com.apple.dt.Xcode/3594.4.19")
    }
}

#[cfg(target_os = "macos")]
fn system_value(program: &str, arguments: &[&str]) -> Option<String> {
    let output = std::process::Command::new(program)
        .args(arguments)
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let value = String::from_utf8(output.stdout).ok()?;
    let value = value.trim();
    (!value.is_empty()).then(|| value.to_string())
}

fn detect_host_identity() -> HostIdentity {
    #[cfg(target_os = "macos")]
    {
        let model = system_value("/usr/sbin/sysctl", &["-n", "hw.model"]);
        let version = system_value("/usr/bin/sw_vers", &["-productVersion"]);
        let build = system_value("/usr/bin/sw_vers", &["-buildVersion"]);
        let computer_name = system_value("/usr/sbin/scutil", &["--get", "ComputerName"]);
        HostIdentity::from_system_values(
            "macos",
            computer_name.as_deref(),
            model.as_deref(),
            version.as_deref(),
            build.as_deref(),
        )
    }
    #[cfg(not(target_os = "macos"))]
    {
        HostIdentity::from_system_values(std::env::consts::OS, None, None, None, None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn real_system_values_preserve_model_and_display_name() {
        let host = HostIdentity::from_system_values(
            "macos",
            Some("  Renée’s MacBook Air  "),
            Some("Mac16,12"),
            Some("26.0"),
            Some("25A354"),
        );
        assert_eq!(host.computer_name, "Renée’s MacBook Air");
        assert_eq!(
            host.authentication_description,
            "<Mac16,12> <macOS;26.0;25A354> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
        );
        assert!(
            host.developer_authentication_description()
                .contains("com.apple.dt.Xcode/3594.4.19")
        );
    }

    #[test]
    fn descriptor_cannot_inject_headers_or_sections() {
        let host = HostIdentity::from_system_values(
            "macos",
            Some("Display 👋"),
            Some("Mac16,12>\r\n<Injected"),
            Some("26;fake"),
            Some("[25A]"),
        );
        assert_eq!(host.model_identifier, "Mac16,12Injected");
        assert_eq!(host.os_version, "26fake");
        assert_eq!(host.os_build, "25A");
        assert!(host.authentication_description.is_ascii());
        assert!(!host.authentication_description.contains(['\r', '\n']));
        assert_eq!(host.computer_name, "Display 👋");
    }

    #[test]
    fn unavailable_values_do_not_invent_apple_hardware() {
        let host = HostIdentity::from_system_values("linux", None, Some("<>"), None, Some(""));
        assert_eq!(host.model_identifier, "linux-host");
        assert_eq!(host.computer_name, "linux-host");
        assert_eq!(host.os_version, "Unknown");
        assert!(
            host.authentication_description
                .starts_with("<linux-host> <linux;Unknown;Unknown>")
        );
    }
}
