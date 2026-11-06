use super::{client_identity, middleware::WasmProxyMiddleware};
use plist::Dictionary;
use plist_macro::plist_to_xml_string;
#[cfg(not(feature = "wasm"))]
use reqwest::Certificate;
use reqwest::{
    ClientBuilder,
    header::{HeaderMap, HeaderValue},
};
use reqwest_middleware::ClientBuilder as MwClientBuilder;
use rootcause::prelude::*;
use tracing::debug;

#[cfg(not(feature = "wasm"))]
use crate::sideload::cert_identity::APPLE_ROOT;
use crate::{
    SideloadError,
    anisette::AnisetteClientInfo,
    util::plist::{PlistDataExtract, SensitivePlistAttachment},
};

const URL_BAG: &str = "https://gsa.apple.com/grandslam/GsService2/lookup";
const MAX_AUTH_ERROR_BODY: usize = 64 * 1024;

/// Apple can return an authentication rejection inside an HTTP 500/503 response.
/// Only the numeric status crosses this boundary; server text and other fields
/// may contain private account material and must never be attached to the error.
fn authentication_error_code(bytes: &[u8]) -> Option<i64> {
    let dictionary: Dictionary = plist::from_bytes(bytes).ok()?;
    let nested_status = dictionary
        .get("Response")
        .and_then(plist::Value::as_dictionary)
        .and_then(|response| response.get("Status"))
        .and_then(plist::Value::as_dictionary);
    let status = nested_status.or_else(|| {
        dictionary
            .get("Status")
            .and_then(plist::Value::as_dictionary)
    })?;
    status
        .get("ec")
        .and_then(plist::Value::as_signed_integer)
        .filter(|code| *code != 0)
}

async fn authentication_http_error(
    response: &mut reqwest::Response,
    http_error: reqwest::Error,
) -> Report {
    let status = response.status().as_u16();
    let mut bytes = Vec::new();
    loop {
        match response.chunk().await {
            Ok(Some(chunk)) if chunk.len() <= MAX_AUTH_ERROR_BODY - bytes.len() => {
                bytes.extend_from_slice(&chunk);
            }
            Ok(None) => break,
            // Never parse a truncated body, and retain the original HTTP status
            // when the body is oversized, incomplete, or cannot be read.
            Ok(Some(_)) | Err(_) => {
                return report!(http_error)
                    .context("Received error response from grandslam")
                    .into();
            }
        }
    }
    if let Some(code) = authentication_error_code(&bytes) {
        return report!(SideloadError::AuthWithMessage(
            code,
            format!("Apple rejected the authentication request (HTTP {status})."),
        ))
        .into();
    }
    report!(http_error)
        .context("Received error response from grandslam")
        .into()
}

pub struct GrandSlam {
    pub client: reqwest_middleware::ClientWithMiddleware,
    pub client_info: AnisetteClientInfo,
    url_bag: Dictionary,
}

impl GrandSlam {
    /// Create a new GrandSlam instance
    ///
    /// # Arguments
    /// - `client`: The reqwest client to use for requests
    pub async fn new(
        client_info: AnisetteClientInfo,
        debug: bool,
        proxy_url: Option<String>,
    ) -> Result<Self, Report> {
        let client =
            Self::build_reqwest_client(debug, proxy_url).context("Failed to build HTTP client")?;
        let base_headers = Self::base_headers(&client_info, false)?;
        let url_bag = Self::fetch_url_bag(&client, base_headers).await?;
        Ok(Self {
            client,
            client_info,
            url_bag,
        })
    }

    /// Fetch the URL bag from GrandSlam and cache it
    pub async fn fetch_url_bag(
        client: &reqwest_middleware::ClientWithMiddleware,
        mut base_headers: HeaderMap,
    ) -> Result<Dictionary, Report> {
        debug!("Fetching URL bag from GrandSlam");
        let discovery_headers = client_identity::lookup_headers(
            base_headers
                .get("X-Mme-Client-Info")
                .and_then(|value| value.to_str().ok())
                .unwrap_or(""),
        );
        base_headers.extend(discovery_headers);
        let resp = client
            .get(URL_BAG)
            .headers(base_headers)
            .send()
            .await
            .context("Failed to fetch URL Bag")?
            .error_for_status()
            .context("Apple authentication discovery service is unavailable")?
            .text()
            .await
            .context("Failed to read URL Bag response text")?;

        let dict: Dictionary =
            plist::from_bytes(resp.as_bytes()).context("Failed to parse URL Bag plist")?;
        let urls = dict
            .get("urls")
            .and_then(|v| v.as_dictionary())
            .cloned()
            .ok_or_else(|| report!("URL Bag plist missing 'urls' dictionary"))?;

        Ok(urls)
    }

    pub fn get_url(&self, key: &str) -> Result<String, Report> {
        let url = self
            .url_bag
            .get_string(key)
            .context("Unable to find key in URL bag")?;
        Ok(url)
    }

    pub fn get(&self, url: &str) -> Result<reqwest_middleware::RequestBuilder, Report> {
        let builder = self
            .client
            .get(url)
            .headers(Self::base_headers(&self.client_info, false)?);

        Ok(builder)
    }

    pub fn get_sms(&self, url: &str) -> Result<reqwest_middleware::RequestBuilder, Report> {
        let builder = self
            .client
            .get(url)
            .headers(Self::base_headers(&self.client_info, true)?);

        Ok(builder)
    }

    pub fn put_sms(&self, url: &str) -> Result<reqwest_middleware::RequestBuilder, Report> {
        let builder = self
            .client
            .put(url)
            .headers(Self::base_headers(&self.client_info, true)?);

        Ok(builder)
    }

    pub fn post(&self, url: &str) -> Result<reqwest_middleware::RequestBuilder, Report> {
        let builder = self
            .client
            .post(url)
            .headers(Self::base_headers(&self.client_info, false)?);

        Ok(builder)
    }

    pub fn post_sms(&self, url: &str) -> Result<reqwest_middleware::RequestBuilder, Report> {
        let builder = self
            .client
            .post(url)
            .headers(Self::base_headers(&self.client_info, true)?);

        Ok(builder)
    }

    pub fn patch(&self, url: &str) -> Result<reqwest_middleware::RequestBuilder, Report> {
        let builder = self
            .client
            .patch(url)
            .headers(Self::base_headers(&self.client_info, false)?);

        Ok(builder)
    }

    pub async fn plist_request(
        &self,
        url: &str,
        body: &Dictionary,
        additional_headers: Option<HeaderMap>,
    ) -> Result<Dictionary, Report> {
        // Do not automatically replay authentication or verification POSTs. In
        // particular, HTTP 429 is a stop condition, not a request for another code.
        let mut req = self.post(url)?;
        if let Some(headers) = additional_headers {
            req = req.headers(headers);
        }
        let mut response = req
            .body(plist_to_xml_string(body))
            .send()
            .await
            .context("Failed to send grandslam request")?;
        if let Err(http_error) = response.error_for_status_ref() {
            return Err(authentication_http_error(&mut response, http_error).await);
        }
        let text = response
            .text()
            .await
            .context("Failed to read grandslam response as text")?;
        let dict: Dictionary = plist::from_bytes(text.as_bytes())
            .context("Failed to parse grandslam response plist")
            .attach_with(|| SensitivePlistAttachment::from_text(&text))?;
        dict.get("Response")
            .and_then(|value| value.as_dictionary())
            .cloned()
            .ok_or_else(|| {
                report!("grandslam response missing 'Response'")
                    .attach(SensitivePlistAttachment::new(dict))
            })
    }

    pub(crate) fn app_token_headers(&self, app: &str) -> HeaderMap {
        client_identity::token_headers(&self.client_info, app)
    }

    fn base_headers(
        client_info: &AnisetteClientInfo,
        sms: bool,
    ) -> Result<reqwest::header::HeaderMap, Report> {
        let mut headers = reqwest::header::HeaderMap::new();
        if !sms {
            headers.insert("Content-Type", HeaderValue::from_static("text/x-xml-plist"));
            headers.insert("Accept", HeaderValue::from_static("text/x-xml-plist"));
        } else {
            headers.insert("Content-Type", HeaderValue::from_static("application/json"));
            headers.insert("Accept", HeaderValue::from_static("application/json"));
        }
        headers.insert(
            "X-Mme-Client-Info",
            HeaderValue::from_str(&client_info.client_info)?,
        );
        headers.insert(
            "User-Agent",
            HeaderValue::from_str(&client_info.user_agent)?,
        );
        headers.extend(client_identity::android_service_headers(client_info));

        Ok(headers)
    }

    /// Build a reqwest client with the Apple root certificate
    ///
    /// # Arguments
    /// - `debug`: DANGER, If true, accept invalid certificates and enable verbose connection logging
    /// # Errors
    /// Returns an error if the reqwest client cannot be built
    pub fn build_reqwest_client(
        debug: bool,
        proxy_url: Option<String>,
    ) -> Result<reqwest_middleware::ClientWithMiddleware, Report> {
        #[cfg(not(feature = "wasm"))]
        let cert = Certificate::from_der(APPLE_ROOT)?;
        #[cfg(not(feature = "wasm"))]
        let client = ClientBuilder::new()
            .add_root_certificate(cert)
            .http1_title_case_headers()
            .danger_accept_invalid_certs(debug)
            .connection_verbose(debug)
            .pool_max_idle_per_host(0)
            .connect_timeout(std::time::Duration::from_secs(12))
            .read_timeout(std::time::Duration::from_secs(30))
            .timeout(std::time::Duration::from_secs(45))
            .redirect(reqwest::redirect::Policy::none())
            .build()?;
        #[cfg(feature = "wasm")]
        let client = ClientBuilder::new().build()?;

        let builder = MwClientBuilder::new(client);
        let builder = if let Some(proxy_url) = proxy_url {
            builder.with(WasmProxyMiddleware::new(proxy_url))
        } else {
            builder
        };
        Ok(builder.build())
    }
}

pub trait GrandSlamErrorChecker {
    fn check_grandslam_error(self) -> Result<Dictionary, Report<SideloadError>>;
}

impl GrandSlamErrorChecker for Dictionary {
    fn check_grandslam_error(self) -> Result<Self, Report<SideloadError>> {
        let result = match self.get("Status") {
            Some(plist::Value::Dictionary(d)) => d,
            _ => &self,
        };

        if result.get_signed_integer("ec").unwrap_or(0) != 0 {
            bail!(SideloadError::AuthWithMessage(
                result.get_signed_integer("ec").unwrap_or(-1),
                result.get_str("em").unwrap_or("Unknown error").to_string(),
            ))
        }

        Ok(self)
    }
}

#[cfg(all(test, not(target_arch = "wasm32")))]
mod http_error_tests {
    use super::*;
    use std::{
        io::{BufRead, BufReader, Read, Write},
        net::TcpListener,
        thread,
        time::{Duration, Instant},
    };

    /// A local response fixture. Requests contain an empty synthetic dictionary;
    /// no account, password, verification code, or Apple service is involved.
    fn request(status: &str, body: &[u8]) -> Result<Dictionary, Report> {
        static CRYPTO: std::sync::Once = std::sync::Once::new();
        CRYPTO.call_once(|| {
            let _ = rustls::crypto::ring::default_provider().install_default();
        });
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        listener.set_nonblocking(true).unwrap();
        let body = body.to_vec();
        let status = status.to_owned();
        let server = thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(3);
            let mut stream = loop {
                match listener.accept() {
                    Ok((stream, _)) => break stream,
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        assert!(Instant::now() < deadline, "Fixture was not contacted");
                        thread::sleep(Duration::from_millis(5));
                    }
                    Err(error) => panic!("Fixture listener failed: {error}"),
                }
            };
            // Darwin may inherit the listener's nonblocking mode on accepted sockets.
            stream.set_nonblocking(false).unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(2)))
                .unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut first_line = String::new();
            reader.read_line(&mut first_line).unwrap();
            assert!(first_line.starts_with("POST /fixture "));
            let mut content_length = 0;
            loop {
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                if line == "\r\n" || line.is_empty() {
                    break;
                }
                if let Some((name, value)) = line.split_once(':')
                    && name.eq_ignore_ascii_case("content-length")
                {
                    content_length = value.trim().parse::<usize>().unwrap();
                }
            }
            assert!(content_length <= 16_384);
            reader.read_exact(&mut vec![0; content_length]).unwrap();
            write!(
                stream,
                "HTTP/1.1 {status}\r\nContent-Type: application/x-plist\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            )
            .unwrap();
            // Oversized responses may be dropped before all bytes are consumed.
            let _ = stream.write_all(&body);
        });
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(3))
            .build()
            .unwrap();
        let service = GrandSlam {
            client: MwClientBuilder::new(client).build(),
            client_info: AnisetteClientInfo {
                client_info: "<synthetic-fixture>".into(),
                user_agent: "fixture/1".into(),
            },
            url_bag: Dictionary::new(),
        };
        let result = runtime.block_on(service.plist_request(
            &format!("http://{address}/fixture"),
            &Dictionary::new(),
            None,
        ));
        server.join().unwrap();
        result
    }

    fn error_plist(nested: bool) -> Vec<u8> {
        let status = "<key>Status</key><dict><key>ec</key><integer>-80045</integer><key>em</key><string>private-fixture-message</string></dict><key>token</key><string>private-fixture-token</string>";
        format!(
            "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict>{}</dict></plist>",
            if nested {
                format!("<key>Response</key><dict>{status}</dict>")
            } else {
                status.to_owned()
            }
        )
        .into_bytes()
    }

    fn assert_private_data_is_absent(error: &Report) {
        let formatted = format!("{error:?}\n{error}");
        assert!(!formatted.contains("private-fixture"));
    }

    fn assert_http_outage(error: &Report) {
        assert!(error.iter_reports().any(|cause| {
            cause
                .downcast_current_context::<reqwest::Error>()
                .and_then(reqwest::Error::status)
                .is_some_and(|status| status.as_u16() == 503)
        }));
        assert!(
            error
                .iter_reports()
                .all(|cause| { cause.downcast_current_context::<SideloadError>().is_none() })
        );
        assert_private_data_is_absent(error);
    }

    #[test]
    fn logical_provider_rejections_survive_http_500_and_503_without_private_data() {
        for status in ["500 Internal Server Error", "503 Service Unavailable"] {
            for nested in [false, true] {
                let error = request(status, &error_plist(nested)).unwrap_err();
                assert!(error.iter_reports().any(|cause| {
                    matches!(
                        cause.downcast_current_context::<SideloadError>(),
                        Some(SideloadError::AuthWithMessage(-80045, message))
                            if message == &format!("Apple rejected the authentication request (HTTP {}).", &status[..3])
                    )
                }));
                assert_private_data_is_absent(&error);
            }
        }
    }

    #[test]
    fn empty_malformed_and_untyped_bodies_preserve_http_outage() {
        for body in [
            Vec::new(),
            b"<html>private-fixture-token: Service Unavailable</html>".to_vec(),
            b"<plist><dict>private-fixture-malformed".to_vec(),
            b"<plist version=\"1.0\"><dict><key>Status</key><dict><key>ec</key><string>-80045</string><key>em</key><string>private-fixture-message</string></dict></dict></plist>".to_vec(),
            b"<plist version=\"1.0\"><dict><key>Status</key><dict><key>ec</key><integer>0</integer><key>em</key><string>private-fixture-message -80045</string></dict></dict></plist>".to_vec(),
        ] {
            let error = request("503 Service Unavailable", &body).unwrap_err();
            assert_http_outage(&error);
        }
    }

    #[test]
    fn oversized_body_is_not_parsed_as_a_logical_rejection() {
        let mut body = error_plist(false);
        body.extend(vec![b' '; MAX_AUTH_ERROR_BODY]);
        let error = request("503 Service Unavailable", &body).unwrap_err();
        assert_http_outage(&error);
    }

    #[test]
    fn successful_plist_protocol_is_unchanged() {
        let body = b"<plist version=\"1.0\"><dict><key>Response</key><dict><key>fixture</key><string>ready</string></dict></dict></plist>";
        let response = request("200 OK", body).unwrap();
        assert_eq!(
            response.get("fixture").and_then(plist::Value::as_string),
            Some("ready")
        );
    }
}
