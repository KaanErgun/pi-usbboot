//! Detect a Raspberry Pi SoC waiting in its USB boot ROM (nRPIBOOT asserted).

use nusb::MaybeFuture;
use serde::Serialize;

/// Every Raspberry Pi boot ROM enumerates with Broadcom's vendor id.
const BROADCOM: u16 = 0x0a5c;

#[derive(Debug, Serialize, PartialEq)]
pub struct BootDevice {
    pub chip: &'static str,
    /// e.g. "BCM2712D0 Boot"; not every host OS exposes it.
    pub product: Option<String>,
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

pub fn find() -> Result<Option<BootDevice>, String> {
    let devices = nusb::list_devices().wait().map_err(|e| e.to_string())?;
    Ok(devices.into_iter().find_map(|d| {
        chip_for(d.vendor_id(), d.product_id()).map(|chip| BootDevice {
            chip,
            product: d.product_string().map(str::to_owned),
        })
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
    }

    #[test]
    fn other_devices_ignored() {
        assert_eq!(chip_for(0x0a5c, 0x0001), None);
        assert_eq!(chip_for(0x1d6b, 0x2712), None);
    }
}
