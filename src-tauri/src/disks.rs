//! List external USB disks so the user can see which Compute Module storage came up.

use serde::{Deserialize, Serialize};
use std::process::Command;

#[derive(Debug, Serialize, PartialEq)]
pub struct Disk {
    pub device: String,
    pub size: String,
    pub name: String,
    /// "nvme", "mmc" (eMMC or SD) or "other", from the name the gadget gives each LUN.
    pub kind: &'static str,
}

fn kind_of(name: &str) -> &'static str {
    let name = name.to_ascii_lowercase();
    if name.contains("nvme") {
        "nvme"
    } else if name.contains("mmcblk") {
        "mmc"
    } else {
        "other"
    }
}

fn run(cmd: &str, args: &[&str]) -> Option<String> {
    let out = Command::new(cmd).args(args).output().ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

#[cfg(target_os = "macos")]
pub fn list() -> Vec<Disk> {
    let Some(listing) = run("/usr/sbin/diskutil", &["list", "external", "physical"]) else {
        return Vec::new();
    };
    external_devices(&listing)
        .into_iter()
        .filter_map(|device| {
            let info = run("/usr/sbin/diskutil", &["info", &device])?;
            let (name, size) = media_info(&info);
            Some(Disk {
                kind: kind_of(&name),
                device,
                size,
                name,
            })
        })
        .collect()
}

#[cfg(not(target_os = "macos"))]
pub fn list() -> Vec<Disk> {
    run("lsblk", &["-J", "-d", "-o", "NAME,SIZE,MODEL,TRAN"])
        .map(|json| usb_disks(&json))
        .unwrap_or_default()
}

/// `/dev/diskN` entries from `diskutil list external physical`.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn external_devices(listing: &str) -> Vec<String> {
    listing
        .lines()
        .filter(|l| l.starts_with("/dev/disk") && l.contains("(external, physical)"))
        .filter_map(|l| l.split_whitespace().next().map(str::to_owned))
        .collect()
}

/// (media name, human size) from `diskutil info`.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn media_info(info: &str) -> (String, String) {
    let field = |key: &str| {
        info.lines()
            .find_map(|l| l.trim().strip_prefix(key).map(|v| v.trim().to_owned()))
            .unwrap_or_default()
    };
    let size = field("Disk Size:")
        .split(" (")
        .next()
        .unwrap_or_default()
        .to_owned();
    (field("Device / Media Name:"), size)
}

#[derive(Deserialize)]
struct Lsblk {
    blockdevices: Vec<LsblkDevice>,
}

#[derive(Deserialize)]
struct LsblkDevice {
    name: String,
    size: String,
    model: Option<String>,
    tran: Option<String>,
}

#[cfg_attr(target_os = "macos", allow(dead_code))]
fn usb_disks(json: &str) -> Vec<Disk> {
    let Ok(parsed) = serde_json::from_str::<Lsblk>(json) else {
        return Vec::new();
    };
    parsed
        .blockdevices
        .into_iter()
        .filter(|d| d.tran.as_deref() == Some("usb"))
        .map(|d| {
            let name = d.model.unwrap_or_default().trim().to_owned();
            Disk {
                kind: kind_of(&name),
                device: format!("/dev/{}", d.name),
                size: d.size,
                name,
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    // Captured from macOS with a CM5 behind mass-storage-gadget64 (2026-10-03).
    const LIST: &str = "/dev/disk4 (external, physical):
   #:                       TYPE NAME                    SIZE       IDENTIFIER
   0:     FDisk_partition_scheme                        *31.3 GB    disk4
   1:             Windows_FAT_32 BOOT                    31.3 GB    disk4s1
";
    const INFO: &str = "   Device Identifier:         disk4
   Device / Media Name:       mmcblk0 Media
   Protocol:                  USB
   Disk Size:                 31.3 GB (31268536320 Bytes) (exactly 61071360 512-Byte-Units)
";

    #[test]
    fn diskutil_listing_and_info() {
        assert_eq!(external_devices(LIST), vec!["/dev/disk4"]);
        assert_eq!(
            media_info(INFO),
            ("mmcblk0 Media".to_owned(), "31.3 GB".to_owned())
        );
    }

    #[test]
    fn lsblk_keeps_only_usb() {
        let json = r#"{"blockdevices":[
            {"name":"nvme0n1","size":"931.5G","model":"KINGSTON SNV2S1000G","tran":"nvme"},
            {"name":"sdb","size":"238.5G","model":"nvme0n1 Media  ","tran":"usb"},
            {"name":"loop0","size":"66.8M","model":null,"tran":null}]}"#;
        assert_eq!(
            usb_disks(json),
            vec![Disk {
                device: "/dev/sdb".into(),
                size: "238.5G".into(),
                name: "nvme0n1 Media".into(),
                kind: "nvme",
            }]
        );
    }

    #[test]
    fn kinds() {
        assert_eq!(kind_of("nvme0n1 Media"), "nvme");
        assert_eq!(kind_of("mmcblk0 Media"), "mmc");
        assert_eq!(kind_of("SanDisk Ultra"), "other");
    }
}
