use std::sync::Arc;

use plist::Dictionary;
use plist_macro::{plist, plist_to_xml_string};
use reqwest::header::{HeaderMap, HeaderValue};
use rootcause::prelude::*;
use serde::de::DeserializeOwned;
use tracing::{error, warn};
use uuid::Uuid;

use crate::{
    SideloadError,
    anisette::AnisetteDataGenerator,
    auth::{
        apple_account::{AppToken, AppleAccount},
        client_identity,
        grandslam::GrandSlam,
    },
    util::plist::PlistDataExtract,
};

pub use super::app_groups::*;
pub use super::app_ids::*;
pub use super::certificates::*;
pub use super::device_type::DeveloperDeviceType;
pub use super::devices::*;
pub use super::teams::*;

/// Keep native Mac provider metadata intact. Android-backed sign-in requires
/// the Mac protocol descriptor for developer access; this does not change its
/// earlier GrandSlam/2FA identity or claim to be this physical Mac.
pub fn developer_authentication_description(client_info: &str) -> String {
    let client_info = if client_identity::is_android_description(client_info) {
        client_identity::MAC_SERVICE_DESCRIPTION
    } else {
        client_info
    };
    if let Some(application) = client_info.rfind('(')
        && client_info[application..]
            .to_ascii_lowercase()
            .starts_with("(com.apple.")
        && client_info.ends_with(")>")
    {
        return format!(
            "{}(com.apple.dt.Xcode/3594.4.19)>",
            &client_info[..application]
        );
    }
    client_info.to_owned()
}

#[derive(Clone)]
pub struct DeveloperSession {
    pub token: AppToken,
    pub adsid: String,
    pub client: Arc<GrandSlam>,
    pub anisette_generator: AnisetteDataGenerator,
    developer_client_info: Option<String>,
}

impl DeveloperSession {
    pub fn new(
        token: AppToken,
        adsid: String,
        client: Arc<GrandSlam>,
        anisette_generator: AnisetteDataGenerator,
    ) -> Self {
        DeveloperSession {
            token,
            adsid,
            client,
            anisette_generator,
            developer_client_info: None,
        }
    }

    pub async fn from_account(account: &mut AppleAccount) -> Result<Self, Report> {
        let token = account
            .get_app_token("xcode.auth")
            .await
            .context("Failed to get xcode token from Apple account")?;

        let spd = account
            .spd
            .as_ref()
            .ok_or_else(|| report!("SPD not available, cannot get adsid"))?;

        Ok(DeveloperSession::new(
            token,
            spd.get_string("adsid")?,
            account.grandslam_client.clone(),
            account.anisette_generator.clone(),
        ))
    }

    /// Only local authentication opts into the physical Mac's Xcode descriptor.
    /// Remote authentication keeps the identity supplied by its selected service.
    pub fn set_developer_client_info(&mut self, description: String) {
        self.developer_client_info = Some(description);
    }

    pub async fn get_headers(&mut self) -> Result<HeaderMap, Report> {
        let mut headers = self
            .anisette_generator
            .get_anisette_data(self.client.clone())
            .await?
            .get_header_map()?;

        headers.insert("User-Agent", HeaderValue::from_static("Xcode"));
        headers.insert("Accept", HeaderValue::from_static("text/x-xml-plist"));
        headers.insert("Content-Type", HeaderValue::from_static("text/x-xml-plist"));
        headers.insert("Accept-Language", HeaderValue::from_static("en-us"));
        headers.insert(
            "X-Apple-App-Info",
            HeaderValue::from_static("com.apple.gs.xcode.auth"),
        );
        headers.insert(
            "X-Xcode-Version",
            HeaderValue::from_static("16.2 (16C5032a)"),
        );
        let client_info = self.developer_client_info.clone().unwrap_or_else(|| {
            developer_authentication_description(&self.client.client_info.client_info)
        });
        headers.insert("X-Mme-Client-Info", HeaderValue::from_str(&client_info)?);
        headers.insert(
            "X-Apple-GS-Token",
            HeaderValue::from_str(&self.token.token)?,
        );
        headers.insert("X-Apple-I-Identity-Id", HeaderValue::from_str(&self.adsid)?);

        Ok(headers)
    }

    pub fn get_grandslam_client(&self) -> Arc<GrandSlam> {
        self.client.clone()
    }

    pub fn token(&self) -> &AppToken {
        &self.token
    }

    pub fn adsid(&self) -> &str {
        &self.adsid
    }

    async fn send_dev_request_internal(
        &mut self,
        url: &str,
        body: impl Into<Option<Dictionary>>,
    ) -> Result<(Dictionary, Option<SideloadError>), Report> {
        let body = body.into().unwrap_or_else(Dictionary::new);

        let base = plist!(dict {
            "clientId": "XABBG36SBA",
            "protocolVersion": "QH65B2",
            "requestId": Uuid::new_v4().to_string().to_uppercase(),
            "userLocale": ["en_US"],
        });

        let body = base.into_iter().chain(body.into_iter()).collect();

        let text = self
            .client
            .client
            .post(url)
            .body(plist_to_xml_string(&body))
            .headers(
                self.get_headers()
                    .await
                    .context("Failed to get anisette headers")?,
            )
            .send()
            .await?
            .error_for_status()
            .context("Developer request failed")?
            .text()
            .await
            .context("Failed to read developer request response text")?;

        let dict: Dictionary = plist::from_bytes(text.as_bytes())
            .context("Failed to parse developer request plist")?;

        // All this error handling is here to ensure that:
        // 1. We always warn/log errors from the server even if it returns the expected data
        // 2. We return server errors if the expected data is missing
        // 3. We return parsing errors if there is no server error but the expected data is missing
        let response_code = dict.get("resultCode").and_then(|v| v.as_signed_integer());
        let mut server_error: Option<SideloadError> = None;
        if let Some(code) = response_code {
            if code != 0 {
                let result_string = dict
                    .get("resultString")
                    .and_then(|v| v.as_string())
                    .unwrap_or("No error message given.");
                let user_string = dict
                    .get("userString")
                    .and_then(|v| v.as_string())
                    .unwrap_or(result_string);
                server_error = Some(SideloadError::DeveloperError(code, user_string.to_string()));

                error!(
                    "Developer request returned error code {}: {} ({})",
                    code, user_string, result_string
                );
            }
        } else {
            warn!("No resultCode in developer request response");
        }

        Ok((dict, server_error))
    }

    pub async fn send_dev_request<T: DeserializeOwned>(
        &mut self,
        url: &str,
        body: impl Into<Option<Dictionary>>,
        response_key: &str,
    ) -> Result<T, Report> {
        let (dict, server_error) = self.send_dev_request_internal(url, body).await?;

        let result: Result<T, _> = dict.get_struct(response_key);

        if result.is_err()
            && let Some(err) = server_error
        {
            bail!(err);
        }

        Ok(result.context("Failed to extract developer request result")?)
    }

    pub async fn send_dev_request_no_response(
        &mut self,
        url: &str,
        body: impl Into<Option<Dictionary>>,
    ) -> Result<Dictionary, Report> {
        let (dict, server_error) = self.send_dev_request_internal(url, body).await?;

        if let Some(err) = server_error {
            bail!(err);
        }

        Ok(dict)
    }
}
