//! Password-free provider diagnostic. Sends only an SRP init for a reserved
//! synthetic account; never accepts a password or submits an SRP proof/2FA code.
//! Output contains HTTP status and Apple's numeric status only, never raw bodies.
use isideload::{
    anisette::remote_v3::RemoteV3AnisetteProvider, auth::apple_account::AppleAccount,
    util::storage::InMemoryStorage,
};
use plist_macro::{plist, plist_to_xml_string};
use rootcause::prelude::*;
use sha2::Sha256;
use srp::groups::G2048;

fn main() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("Diagnostic runtime");
    let mut stage = "initializing";
    if let Err(error) = runtime.block_on(probe(&mut stage)) {
        let status = error.iter_reports().find_map(|cause| {
            cause
                .downcast_current_context::<reqwest::Error>()
                .and_then(|error| error.status())
                .map(|status| status.as_u16())
        });
        println!(
            "{}",
            serde_json::json!({"probeError":true,"stage":stage,"httpStatus":status,"passwordSubmitted":false})
        );
        std::process::exit(1);
    }
}

async fn probe(stage: &mut &'static str) -> Result<(), Report> {
    let endpoint = std::env::args()
        .nth(1)
        .ok_or_else(|| report!("Pass the provider URL"))?;
    let url = reqwest::Url::parse(&endpoint)?;
    let loopback = matches!(url.host_str(), Some("localhost" | "127.0.0.1" | "[::1]" | "::1"));
    if (url.scheme() != "https" && !(url.scheme() == "http" && loopback))
        || !url.username().is_empty() || url.password().is_some()
        || url.query().is_some() || url.fragment().is_some() {
        bail!("Use HTTPS or a loopback HTTP provider without embedded credentials");
    }
    *stage = "providerMetadataAndAppleDiscovery";
    let provider = RemoteV3AnisetteProvider::default()?
        .set_url(&endpoint)
        .set_storage(Box::new(InMemoryStorage::new()));
    let mut account = AppleAccount::builder("slip-provider-probe@example.com")
        .anisette_provider(provider)
        .build()
        .await?;
    *stage = "providerProvisioning";
    let data = account
        .anisette_generator
        .get_anisette_data(account.grandslam_client.clone())
        .await?;
    let srp = srp::Client::<G2048, Sha256>::new_with_options(false);
    let ephemeral: Vec<u8> = (0..32).map(|_| rand::random::<u8>()).collect();
    let body = plist!(dict {
        "Header": { "Version": "1.0.1" },
        "Request": {
            "A2k": srp.compute_public_ephemeral(&ephemeral),
            "cpd": data.get_client_provided_data(),
            "o": "init",
            "ps": ["s2k", "s2k_fo"],
            "u": "slip-provider-probe@example.com",
        }
    });
    let service = account.grandslam_client.get_url("gsService")?;
    *stage = "appleSRPInit";
    let mut response = account
        .grandslam_client
        .post(&service)?
        .body(plist_to_xml_string(&body))
        .send()
        .await?;
    let http = response.status().as_u16();
    let content_type = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .unwrap_or("unknown")
        .to_owned();
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await? {
        if bytes.len() + chunk.len() > 131_072 {
            bail!("Oversized diagnostic response");
        }
        bytes.extend_from_slice(&chunk);
    }
    let plist: Option<plist::Value> = plist::from_bytes(&bytes).ok();
    let root = plist.as_ref().and_then(plist::Value::as_dictionary);
    let payload = root
        .and_then(|d| d.get("Response"))
        .and_then(plist::Value::as_dictionary)
        .or(root);
    let code = payload
        .and_then(|d| d.get("Status"))
        .and_then(plist::Value::as_dictionary)
        .and_then(|d| d.get("ec"))
        .and_then(plist::Value::as_signed_integer);
    let challenge = payload.is_some_and(|d| d.contains_key("B") && d.contains_key("s"));
    println!(
        "{}",
        serde_json::json!({
            "provider": endpoint, "httpStatus": http, "appleCode": code,
            "srpChallengeReturned": challenge, "passwordSubmitted": false,
            "clientInfo": account.grandslam_client.client_info.client_info,
            "contentType": content_type, "bodyBytes": bytes.len(), "plistResponse": plist.is_some(),
        })
    );
    Ok(())
}
