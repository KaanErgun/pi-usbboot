//! Detect a Raspberry Pi SoC waiting in its USB boot ROM (nRPIBOOT asserted).

use nusb::MaybeFuture;
use serde::Serialize;

/// Every Raspberry Pi boot ROM enumerates with Broadcom's vendor id.
const BROADCOM: u16 = 0x0a5c;

#[derive(Clone, Copy, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum BootMode {
    /// Original VideoCore mass-storage firmware (CM1/CM3 and supported Zero boards).
    Legacy,
    /// Linux mass-storage gadget (BCM2711 and BCM2712).
    Modern,
}

#[derive(Debug, Serialize, PartialEq)]
pub struct BootDevice {
    pub chip: &'static str,
    /// e.g. "BCM2712D0 Boot"; not every host OS exposes it.
    pub product: Option<String>,
    pub mode: BootMode,
}

/// Boot-ROM product ids, as matched by raspberrypi/usbboot.
pub fn chip_for(vendor: u16, product: u16) -> Option<&'static str> {
    if vendor != BROADCOM {
        return None;
    }
    match product {
        0x2763 | 0x2764 => Some("BCM283x"),
        0x2711 => Some("BCM2711"),
        0x2712 => Some("BCM2712"),
        _ => None,
    }
}

fn device_for(vendor: u16, product: u16, name: Option<String>) -> Option<BootDevice> {
    chip_for(vendor, product).map(|chip| BootDevice {
        chip,
        product: name,
        // 2763/2764 identify the boot-ROM family, not an exact board model.
        mode: if matches!(product, 0x2763 | 0x2764) {
            BootMode::Legacy
        } else {
            BootMode::Modern
        },
    })
}

/// rpiboot chooses the connected device itself. Refuse an ambiguous selection so
/// a payload chosen for one family cannot be sent to another connected board.
fn select_one(devices: impl IntoIterator<Item = BootDevice>) -> Result<Option<BootDevice>, String> {
    let mut devices = devices.into_iter();
    let first = devices.next();
    if devices.next().is_some() {
        return Err("multiple-devices".into());
    }
    Ok(first)
}

pub fn find() -> Result<Option<BootDevice>, String> {
    let devices = nusb::list_devices().wait().map_err(|e| e.to_string())?;
    select_one(devices.into_iter().filter_map(|d| {
        device_for(
            d.vendor_id(),
            d.product_id(),
            d.product_string().map(str::to_owned),
        )
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_boot_roms() {
        assert_eq!(chip_for(0x0a5c, 0x2712), Some("BCM2712"));
        assert_eq!(chip_for(0x0a5c, 0x2711), Some("BCM2711"));
        assert_eq!(chip_for(0x0a5c, 0x2763), Some("BCM283x"));
        assert_eq!(chip_for(0x0a5c, 0x2764), Some("BCM283x"));
    }

    #[test]
    fn other_devices_ignored() {
        assert_eq!(chip_for(0x0a5c, 0x0001), None);
        assert_eq!(chip_for(0x1d6b, 0x2712), None);
    }

    #[test]
    fn all_supported_ids_select_their_payload_family() {
        for id in [0x2763, 0x2764] {
            assert_eq!(
                device_for(BROADCOM, id, None).unwrap().mode,
                BootMode::Legacy
            );
        }
        for id in [0x2711, 0x2712] {
            assert_eq!(
                device_for(BROADCOM, id, None).unwrap().mode,
                BootMode::Modern
            );
        }
    }

    #[test]
    fn multiple_boards_are_rejected_including_same_family() {
        for second in [0x2763, 0x2712] {
            let devices = [
                device_for(BROADCOM, 0x2763, None).unwrap(),
                device_for(BROADCOM, second, None).unwrap(),
            ];
            assert_eq!(select_one(devices), Err("multiple-devices".into()));
        }
        assert_eq!(select_one([]), Ok(None));
        let board = device_for(BROADCOM, 0x2711, Some("BCM2711 Boot".into())).unwrap();
        assert_eq!(
            select_one([board]).unwrap().unwrap().product.as_deref(),
            Some("BCM2711 Boot")
        );
    }
}
