//! Endpoint-specific client identity for the known Android-backed V3 service.
//!
//! The original Dadoum server advertises a Mac while using Android ADI. Match
//! its actual platform during sign-in, then request Xcode developer access with
//! the Mac protocol identity required by that service. This is a compatibility
//! policy, not a claim that the remote machine is this physical Mac.
use crate::anisette::AnisetteClientInfo;
use reqwest::header::{HeaderMap, HeaderValue};

pub const ANDROID_SIGN_IN_DESCRIPTION: &str =
    "<Pixel 8><Android; 14; UQ1A.240205.004><com.apple.AuthKit/1 (com.apple.android.music/4.9.6)>";
pub const MAC_SERVICE_DESCRIPTION: &str =
    "<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>";
pub const SERVICE_USER_AGENT: &str = "akd/1.0 CFNetwork/808.1.4";
pub const XCODE_VERSION: &str = "16.2 (16C5032a)";

pub fn is_android_description(description: &str) -> bool {
    description.contains("<Android;")
}

pub fn remote_client_info(
    implementation: Option<&str>,
    reported: AnisetteClientInfo,
) -> AnisetteClientInfo {
    if implementation.is_some_and(|value| value.starts_with("anisette-v3-server v")) {
        AnisetteClientInfo {
            client_info: ANDROID_SIGN_IN_DESCRIPTION.into(),
            user_agent: SERVICE_USER_AGENT.into(),
        }
    } else {
        // In particular, native-c has different ADI and must retain its actual
        // Mac descriptor. Unknown implementations are never silently rewritten.
        reported
    }
}

pub fn android_service_headers(client_info: &AnisetteClientInfo) -> HeaderMap {
    let mut headers = HeaderMap::new();
    if is_android_description(&client_info.client_info) {
        headers.insert("X-Xcode-Version", HeaderValue::from_static(XCODE_VERSION));
        headers.insert(
            "X-Apple-App-Info",
            HeaderValue::from_static("com.apple.gs.xcode.auth"),
        );
        headers.insert("Connection", HeaderValue::from_static("close"));
    }
    headers
}

pub fn lookup_headers(description: &str) -> HeaderMap {
    let mut headers = HeaderMap::new();
    if is_android_description(description) {
        // The Android discovery bag lacks the developer endpoints we need.
        headers.insert(
            "X-Mme-Client-Info",
            HeaderValue::from_static(MAC_SERVICE_DESCRIPTION),
        );
    }
    headers
}

pub fn token_headers(client_info: &AnisetteClientInfo, app: &str) -> HeaderMap {
    let mut headers = HeaderMap::new();
    if app == "com.apple.gs.xcode.auth" && is_android_description(&client_info.client_info) {
        headers.insert(
            "X-Mme-Client-Info",
            HeaderValue::from_static(MAC_SERVICE_DESCRIPTION),
        );
        headers.insert("User-Agent", HeaderValue::from_static(SERVICE_USER_AGENT));
    }
    headers
}

#[cfg(test)]
mod tests {
    use super::*;

    fn reported(description: &str, user_agent: &str) -> AnisetteClientInfo {
        AnisetteClientInfo {
            client_info: description.into(),
            user_agent: user_agent.into(),
        }
    }

    #[test]
    fn only_the_known_android_backend_changes_its_reported_platform() {
        let supplied =
            "<fixture-provider> <macOS;fixture> <com.apple.AuthKit/1 (com.apple.akd/1.0)>";
        let known = remote_client_info(
            Some("anisette-v3-server v2.2.2"),
            reported(supplied, "fixture-UA"),
        );
        assert_eq!(known.client_info, ANDROID_SIGN_IN_DESCRIPTION);
        assert_eq!(known.user_agent, SERVICE_USER_AGENT);
        for implementation in [
            None,
            Some("anisette-v3-server (native-c 0.2.0)"),
            Some("other-compatible-server"),
        ] {
            let exact = remote_client_info(implementation, reported(supplied, "fixture-UA"));
            assert_eq!(exact.client_info, supplied);
            assert_eq!(exact.user_agent, "fixture-UA");
        }
    }

    #[test]
    fn android_lookup_and_xcode_token_overrides_leave_sign_in_identity_unchanged() {
        let android = remote_client_info(
            Some("anisette-v3-server v2.2.2"),
            reported("fixture", "fixture"),
        );
        assert_eq!(
            lookup_headers(&android.client_info)["X-Mme-Client-Info"],
            MAC_SERVICE_DESCRIPTION
        );
        let xcode = token_headers(&android, "com.apple.gs.xcode.auth");
        assert_eq!(xcode["X-Mme-Client-Info"], MAC_SERVICE_DESCRIPTION);
        assert!(token_headers(&android, "com.apple.gs.icloud.auth").is_empty());
        assert_eq!(android.client_info, ANDROID_SIGN_IN_DESCRIPTION);
        let native = reported("<fixture-native> <Mac OS X;10.12.6;fixture>", "native-UA");
        assert!(lookup_headers(&native.client_info).is_empty());
        assert!(token_headers(&native, "com.apple.gs.xcode.auth").is_empty());
        assert!(android_service_headers(&native).is_empty());
        assert_eq!(
            android_service_headers(&android)["X-Xcode-Version"],
            XCODE_VERSION
        );
    }
}
