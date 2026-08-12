use crate::error::AppError;
use std::time::Duration;

use idevice::{
    IdeviceService,
    lockdown::LockdownClient,
    provider::UsbmuxdProvider,
    usbmuxd::{Connection, UsbmuxdAddr, UsbmuxdConnection},
};
use serde::{Deserialize, Serialize};

#[derive(Deserialize, Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct DeviceInfo {
    pub name: String,
    pub id: u32,
    pub udid: String,
    pub connection_type: String,
    pub version: String,
    #[serde(default)]
    pub product_type: Option<String>,
    #[serde(default)]
    pub device_color: Option<String>,
}

fn bounded_single_line(value: &str, maximum_characters: usize) -> String {
    value
        .chars()
        .map(|character| {
            if character.is_control() {
                ' '
            } else {
                character
            }
        })
        .take(maximum_characters)
        .collect()
}

pub async fn list_devices() -> Result<Vec<Result<DeviceInfo, AppError>>, AppError> {
    let mut usbmuxd = get_usbmuxd().await?;

    let devs = tokio::time::timeout(Duration::from_secs(8), usbmuxd.get_devices())
        .await
        .map_err(|_| {
            AppError::Usbmuxd(
                "Timed out listing connected iPhones".into(),
                "usbmuxd did not respond".into(),
            )
        })?
        .map_err(|e| {
            AppError::Usbmuxd("Failed to list devices from usbmuxd".into(), e.to_string())
        })?;
    if devs.is_empty() {
        return Ok(vec![]);
    }

    let usbmuxd_addr = UsbmuxdAddr::from_env_var().map_err(|e| {
        AppError::Usbmuxd(
            "Invalid usbmuxd address from environment".into(),
            e.to_string(),
        )
    })?;

    let device_info_futures: Vec<_> = devs
        .iter()
        .map(|d| {
            let usbmuxd_addr = usbmuxd_addr.clone();
            async move {
                let provider = d.to_provider(usbmuxd_addr, "Slip");
                let device_uid = d.device_id;
                let connection_type = match d.connection_type {
                    Connection::Usb => "USB",
                    Connection::Network(_) => "Network",
                    Connection::Unknown(_) => "Unknown",
                }
                .to_string();

                let mut lockdown_client =
                    LockdownClient::connect(&provider).await.map_err(|e| {
                        eprintln!("Unable to connect to lockdown for {}: {e:?}", d.udid);
                        AppError::DeviceComsWithMessage(
                            "Unable to connect to lockdown".into(),
                            e.to_string(),
                        )
                    })?;

                let device_name_value = lockdown_client
                    .get_value(Some("DeviceName"), None)
                    .await
                    .map_err(|e| {
                    eprintln!("Failed to fetch DeviceName for {}: {e:?}", d.udid);
                    AppError::DeviceComsWithMessage(
                        "Failed to fetch DeviceName".into(),
                        e.to_string(),
                    )
                })?;

                let device_name = device_name_value.as_string().ok_or_else(|| {
                    eprintln!("DeviceName for {} was not a string", d.udid);
                    AppError::DeviceComs("DeviceName was not a string".into())
                })?;

                let version_value = lockdown_client
                    .get_value(Some("ProductVersion"), None)
                    .await
                    .map_err(|e| {
                        eprintln!("Failed to fetch ProductVersion for {}: {e:?}", d.udid);
                        AppError::DeviceComsWithMessage(
                            "Failed to fetch ProductVersion".into(),
                            e.to_string(),
                        )
                    })?;

                let version = version_value.as_string().ok_or_else(|| {
                    eprintln!("ProductVersion for {} was not a string", d.udid);
                    AppError::DeviceComs("Product version was not a string".into())
                })?;

                let product_type = lockdown_client
                    .get_value(Some("ProductType"), None)
                    .await
                    .ok()
                    .and_then(|value| value.as_string().map(ToOwned::to_owned));
                let device_color = lockdown_client
                    .get_value(Some("DeviceColor"), None)
                    .await
                    .ok()
                    .and_then(|value| value.as_string().map(ToOwned::to_owned));

                Ok::<DeviceInfo, AppError>(DeviceInfo {
                    name: bounded_single_line(device_name, 128),
                    id: device_uid,
                    udid: d.udid.clone(),
                    connection_type,
                    version: bounded_single_line(version, 32),
                    product_type: product_type.map(|value| bounded_single_line(&value, 64)),
                    device_color: device_color.map(|value| bounded_single_line(&value, 64)),
                })
            }
        })
        .collect();

    let device_infos =
        futures::future::join_all(device_info_futures.into_iter().map(|future| async move {
            tokio::time::timeout(Duration::from_secs(10), future)
                .await
                .unwrap_or_else(|_| {
                    Err(AppError::DeviceComs(
                        "Timed out reading an iPhone's device information".into(),
                    ))
                })
        }))
        .await;
    Ok(device_infos)
}

pub async fn get_usbmuxd() -> Result<UsbmuxdConnection, AppError> {
    tokio::time::timeout(Duration::from_secs(8), UsbmuxdConnection::default())
        .await
        .map_err(|_| {
            AppError::Usbmuxd(
                "Timed out connecting to usbmuxd".into(),
                "The Apple device service did not respond".into(),
            )
        })?
        .map_err(|e| AppError::Usbmuxd("Failed to connect to usbmuxd".into(), e.to_string()))
}

pub async fn enable_wifi_debugging(udid: &str) -> Result<(), AppError> {
    let mut usbmuxd = get_usbmuxd().await?;
    let devices = usbmuxd.get_devices().await.map_err(|error| {
        AppError::Usbmuxd(
            "Failed to list devices from usbmuxd".into(),
            error.to_string(),
        )
    })?;
    let device = devices
        .iter()
        .find(|device| device.udid == udid && matches!(device.connection_type, Connection::Usb))
        .cloned()
        .ok_or_else(|| {
            AppError::DeviceComs(
                "Connect this iPhone by USB before enabling its Wi-Fi connection".into(),
            )
        })?;
    let pairing_file = usbmuxd.get_pair_record(udid).await.map_err(|error| {
        AppError::LockdownPairing(
            "Failed to read the trusted pairing record".into(),
            error.to_string(),
        )
    })?;
    let provider = device.to_provider(
        UsbmuxdAddr::from_env_var().map_err(|error| {
            AppError::Usbmuxd(
                "Invalid usbmuxd address from environment".into(),
                error.to_string(),
            )
        })?,
        "Slip",
    );
    let mut lockdown = LockdownClient::connect(&provider).await.map_err(|error| {
        AppError::DeviceComsWithMessage("Failed to connect to the iPhone".into(), error.to_string())
    })?;
    lockdown
        .start_session(&pairing_file)
        .await
        .map_err(|error| {
            AppError::LockdownPairing(
                "Failed to start the trusted iPhone session".into(),
                error.to_string(),
            )
        })?;
    lockdown
        .set_value(
            "EnableWifiDebugging",
            true.into(),
            Some("com.apple.mobile.wireless_lockdown"),
        )
        .await
        .map_err(|error| {
            AppError::LockdownPairing(
                "Failed to enable the iPhone Wi-Fi connection".into(),
                error.to_string(),
            )
        })?;
    Ok(())
}

pub async fn get_provider(device_info: &DeviceInfo) -> Result<UsbmuxdProvider, AppError> {
    get_provider_from_connection(device_info, &mut (get_usbmuxd().await?)).await
}

pub async fn get_provider_from_connection(
    device_info: &DeviceInfo,
    connection: &mut UsbmuxdConnection,
) -> Result<UsbmuxdProvider, AppError> {
    let devices = tokio::time::timeout(Duration::from_secs(8), connection.get_devices())
        .await
        .map_err(|_| AppError::DeviceComs("Timed out finding the selected iPhone".into()))?
        .map_err(|e| {
            AppError::DeviceComsWithMessage("Failed to get device".into(), e.to_string())
        })?;
    let device = devices
        .iter()
        .find(|device| device.device_id == device_info.id)
        .or_else(|| {
            devices.iter().find(|device| {
                device.udid == device_info.udid && matches!(device.connection_type, Connection::Usb)
            })
        })
        .or_else(|| {
            devices
                .iter()
                .find(|device| device.udid == device_info.udid)
        })
        .cloned()
        .ok_or_else(|| AppError::DeviceComs("Selected device is no longer connected".into()))?;

    let address = UsbmuxdAddr::from_env_var().map_err(|error| {
        AppError::Usbmuxd(
            "Invalid usbmuxd address from environment".into(),
            error.to_string(),
        )
    })?;
    let provider = device.to_provider(address, "Slip");
    Ok(provider)
}
