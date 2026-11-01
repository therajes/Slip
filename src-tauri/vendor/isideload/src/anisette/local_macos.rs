use std::{
    io::Read,
    process::{Child, Command, Stdio},
    sync::{Arc, mpsc},
    time::{Duration, Instant},
};

use rootcause::prelude::*;
use serde::Deserialize;
use web_time::SystemTime;

use super::{AnisetteClientInfo, AnisetteData, AnisetteProvider};
use crate::{auth::grandslam::GrandSlam, util::host_identity::host_identity};

pub const LOCAL_AUTH_UNAVAILABLE: &str = "macOS did not release local Apple authentication data to Slip. Remote compatibility requires an external authentication-data provider.";
const MAX_HELPER_OUTPUT: u64 = 65_536;

// Only known capability codes affect user-visible diagnostics. In particular,
// arbitrary helper messages and errors are never passed through to the UI.
fn capability_message(code: Option<&str>) -> &'static str {
    match code {
        Some("framework_unavailable" | "api_unavailable") => {
            "This macOS installation does not expose the local Apple authentication API used by Slip. Remote compatibility requires an external provider."
        }
        Some("headers_unavailable") => {
            "macOS did not release local Apple authentication data to Slip. This macOS version may require private Apple entitlements. Remote compatibility requires an external provider."
        }
        Some("headers_incomplete" | "headers_conflict" | "identity_unavailable") => {
            "macOS returned incomplete or inconsistent local Apple authentication data. Slip rejected this response. Try again, or explicitly select a remote provider."
        }
        _ => LOCAL_AUTH_UNAVAILABLE,
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum HelperFailure {
    Unavailable,
    Timeout,
    InvalidOutput,
}

impl HelperFailure {
    fn message(self) -> &'static str {
        match self {
            Self::Unavailable => {
                "Slip could not start its local Apple authentication helper. Reinstall or rebuild Slip to restore the bundled helper."
            }
            Self::Timeout => {
                "The local Apple authentication service did not respond within 15 seconds. Try again, or explicitly select a remote provider."
            }
            Self::InvalidOutput => {
                "Slip rejected an invalid response from its local Apple authentication helper."
            }
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct HelperData {
    machine_id: String,
    one_time_password: String,
    device_id: String,
    local_user_id: String,
    routing_info: String,
}

/// Validate helper output without exposing its sensitive contents in an error.
pub fn parse_helper_data(bytes: &[u8]) -> Result<AnisetteData, Report> {
    let data: HelperData =
        serde_json::from_slice(bytes).map_err(|_| report!(LOCAL_AUTH_UNAVAILABLE))?;
    if [
        &data.machine_id,
        &data.one_time_password,
        &data.device_id,
        &data.local_user_id,
        &data.routing_info,
    ]
    .iter()
    .any(|value| {
        value.trim().is_empty() || !value.is_ascii() || value.chars().any(char::is_control)
    }) {
        bail!(LOCAL_AUTH_UNAVAILABLE);
    }
    Ok(AnisetteData {
        machine_id: data.machine_id,
        one_time_password: data.one_time_password,
        device_unique_identifier: data.device_id,
        local_user_id: data.local_user_id,
        routing_info: data.routing_info,
        _device_description: host_identity().authentication_description.clone(),
        generated_at: SystemTime::now(),
    })
}

struct HelperProcess(Child);

impl Drop for HelperProcess {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

struct HelperOutput {
    success: bool,
    bytes: Vec<u8>,
}

async fn helper_output(check: bool) -> Result<HelperOutput, HelperFailure> {
    let executable = std::env::current_exe().map_err(|_| HelperFailure::Unavailable)?;
    let helper = executable
        .parent()
        .ok_or(HelperFailure::Unavailable)?
        .join("slip-anisette");
    let mut command = Command::new(helper);
    if check {
        command.arg("--check");
    }
    run_helper(command, Duration::from_secs(15)).await
}

async fn run_helper(
    mut command: Command,
    timeout: Duration,
) -> Result<HelperOutput, HelperFailure> {
    // Drain stdout while the child runs. Waiting before reading can deadlock if
    // a broken helper fills its pipe, even though ordinary output is very small.
    let mut child = HelperProcess(
        command
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .stdin(Stdio::null())
            .spawn()
            .map_err(|_| HelperFailure::Unavailable)?,
    );
    let stdout = child.0.stdout.take().ok_or(HelperFailure::InvalidOutput)?;
    let (sender, receiver) = mpsc::sync_channel(1);
    std::thread::Builder::new()
        .name("slip-local-auth-output".into())
        .spawn(move || {
            let mut bytes = Vec::new();
            let result = stdout
                .take(MAX_HELPER_OUTPUT + 1)
                .read_to_end(&mut bytes)
                .map_err(|_| HelperFailure::InvalidOutput)
                .and_then(|_| {
                    if bytes.len() as u64 > MAX_HELPER_OUTPUT {
                        Err(HelperFailure::InvalidOutput)
                    } else {
                        Ok(bytes)
                    }
                });
            let _ = sender.send(result);
        })
        .map_err(|_| HelperFailure::Unavailable)?;
    let started = Instant::now();
    let mut output = None;
    loop {
        if output.is_none() {
            match receiver.try_recv() {
                Ok(result) => output = Some(result?),
                Err(mpsc::TryRecvError::Empty) => {}
                Err(mpsc::TryRecvError::Disconnected) => return Err(HelperFailure::InvalidOutput),
            }
        }
        if let Some(status) = child.0.try_wait().map_err(|_| HelperFailure::Unavailable)?
            && let Some(bytes) = output.take()
        {
            return Ok(HelperOutput {
                success: status.success(),
                bytes,
            });
        }
        if started.elapsed() >= timeout {
            return Err(HelperFailure::Timeout);
        }
        // Cancellation drops HelperProcess, which terminates and reaps the child.
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}

fn parse_availability(output: HelperOutput) -> (bool, Option<String>) {
    #[derive(Deserialize)]
    struct Availability {
        available: bool,
        code: Option<String>,
    }
    match serde_json::from_slice::<Availability>(&output.bytes) {
        Ok(value) if value.available && output.success => (true, None),
        Ok(value) if !value.available => (
            false,
            Some(capability_message(value.code.as_deref()).into()),
        ),
        _ => (false, Some(HelperFailure::InvalidOutput.message().into())),
    }
}

pub async fn local_authentication_status() -> (bool, Option<String>) {
    match helper_output(true).await {
        Ok(output) => parse_availability(output),
        Err(error) => (false, Some(error.message().into())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn output(success: bool, bytes: &[u8]) -> HelperOutput {
        HelperOutput {
            success,
            bytes: bytes.to_vec(),
        }
    }

    #[test]
    fn unavailable_helper_diagnostics_do_not_expose_response_text() {
        let (available, message) = parse_availability(output(false, br#"{"available":false,"code":"headers_unavailable","message":"sensitive-helper-message"}"#));
        assert!(!available);
        let message = message.unwrap();
        assert!(message.contains("private Apple entitlements"));
        assert!(!message.contains("sensitive-helper-message"));
        assert_eq!(
            parse_availability(output(
                false,
                br#"{"available":false,"code":"secret-value"}"#
            ))
            .1
            .as_deref(),
            Some(LOCAL_AUTH_UNAVAILABLE)
        );
    }

    #[test]
    fn successful_status_requires_successful_process_and_valid_json() {
        assert_eq!(
            parse_availability(output(true, br#"{"available":true,"code":"ready"}"#)),
            (true, None)
        );
        assert!(!parse_availability(output(false, br#"{"available":true}"#)).0);
        assert!(!parse_availability(output(true, b"not JSON")).0);
    }

    #[test]
    fn credential_data_rejects_missing_or_unsafe_values_without_disclosing_them() {
        let fixture = serde_json::json!({
            "machineId": "fixture-machine", "oneTimePassword": "fixture-otp",
            "deviceId": "fixture-device", "localUserId": "fixture-user", "routingInfo": "84215040"
        });
        assert!(parse_helper_data(&serde_json::to_vec(&fixture).unwrap()).is_ok());
        for field in [
            "machineId",
            "oneTimePassword",
            "deviceId",
            "localUserId",
            "routingInfo",
        ] {
            let mut missing = fixture.clone();
            missing.as_object_mut().unwrap().remove(field);
            assert!(parse_helper_data(&serde_json::to_vec(&missing).unwrap()).is_err());
            for unsafe_value in [
                "",
                "  ",
                "secret-value\r\ninjected",
                "secret-\u{1f}",
                "secret-\u{7f}",
                "secret-\u{e9}",
            ] {
                let mut invalid = fixture.clone();
                invalid[field] = serde_json::json!(unsafe_value);
                let error = parse_helper_data(&serde_json::to_vec(&invalid).unwrap()).unwrap_err();
                assert!(!error.to_string().contains("secret-"));
            }
        }
    }

    #[test]
    fn helper_output_is_drained_and_bounded_without_waiting_for_pipe_capacity() {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_time()
            .build()
            .unwrap();
        let mut command = Command::new("/usr/bin/head");
        command.args(["-c", "65537", "/dev/zero"]);
        let result = runtime.block_on(run_helper(command, Duration::from_secs(2)));
        assert_eq!(result.err(), Some(HelperFailure::InvalidOutput));
    }

    #[test]
    fn helper_has_deadline_and_can_preserve_nonzero_capability_output() {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_time()
            .build()
            .unwrap();
        let mut command = Command::new("/bin/sleep");
        command.arg("2");
        let started = Instant::now();
        let result = runtime.block_on(run_helper(command, Duration::from_millis(50)));
        assert_eq!(result.err(), Some(HelperFailure::Timeout));
        assert!(started.elapsed() < Duration::from_secs(1));
        let mut command = Command::new("/bin/sh");
        command.args([
            "-c",
            "printf '%s' '{\"available\":false,\"code\":\"headers_unavailable\"}'; exit 1",
        ]);
        let result = runtime
            .block_on(run_helper(command, Duration::from_secs(2)))
            .unwrap();
        assert!(!result.success);
        assert!(
            parse_availability(result)
                .1
                .unwrap()
                .contains("private Apple entitlements")
        );
    }
}

pub struct LocalMacOsAnisetteProvider;

#[cfg_attr(feature = "wasm", async_trait::async_trait(?Send))]
#[cfg_attr(not(feature = "wasm"), async_trait::async_trait)]
impl AnisetteProvider for LocalMacOsAnisetteProvider {
    async fn get_anisette_data(&self) -> Result<AnisetteData, Report> {
        let output = helper_output(false)
            .await
            .map_err(|error| report!(error.message()))?;
        if !output.success {
            #[derive(Deserialize)]
            struct Failure {
                code: Option<String>,
            }
            let code = serde_json::from_slice::<Failure>(&output.bytes)
                .ok()
                .and_then(|failure| failure.code);
            bail!(capability_message(code.as_deref()));
        }
        parse_helper_data(&output.bytes)
    }

    async fn get_client_info(&self) -> Result<AnisetteClientInfo, Report> {
        Ok(AnisetteClientInfo {
            client_info: host_identity().authentication_description.clone(),
            user_agent: "akd/1.0 CFNetwork/808.1.4".to_string(),
        })
    }

    async fn provision(&mut self, _gs: Arc<GrandSlam>) -> Result<(), Report> {
        Ok(())
    }
    fn needs_provisioning(&self) -> Result<bool, Report> {
        Ok(false)
    }
}
