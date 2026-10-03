//! Locate a compatible system rpiboot payload and run it with admin rights.

use crate::usb::{BootDevice, BootMode};
use std::path::{Path, PathBuf};
use std::process::Command;

/// GUI apps on macOS do not inherit the shell PATH.
const PREFIXES: &[&str] = &["/opt/homebrew", "/usr/local", "/usr"];

pub fn locate_binary(is_file: impl Fn(&Path) -> bool) -> Option<PathBuf> {
    PREFIXES
        .iter()
        .map(|prefix| Path::new(prefix).join("bin/rpiboot"))
        .find(|path| is_file(path))
}

/// Check the required boot files, not just the existence of a directory. Older
/// install prefixes and a binary/payload in different prefixes are supported.
pub fn locate_payload(
    device: &BootDevice,
    is_file: impl Fn(&Path) -> bool,
    archive_has: impl Fn(&Path, &str) -> bool,
) -> Option<PathBuf> {
    let names: &[&str] = match device.mode {
        BootMode::Legacy => &["msd"],
        BootMode::Modern => &["mass-storage-gadget64", "mass-storage-gadget"],
    };
    for name in names {
        for prefix in PREFIXES {
            // Packaged installs use share/rpiboot; upstream make install also
            // uses share directly. Prefer the 64-bit gadget before its alias.
            for share in ["share/rpiboot", "share"] {
                let path = Path::new(prefix).join(share).join(name);
                if payload_compatible(&path, device, &is_file, &archive_has) {
                    return Some(path);
                }
            }
        }
    }
    None
}

fn payload_compatible(
    path: &Path,
    device: &BootDevice,
    is_file: &impl Fn(&Path) -> bool,
    archive_has: &impl Fn(&Path, &str) -> bool,
) -> bool {
    if device.mode == BootMode::Legacy {
        return ["bootcode.bin", "start.elf"]
            .iter()
            .all(|file| is_file(&path.join(file)));
    }
    let (prefix, bootloader) = match device.chip {
        "BCM2711" => ("2711", "bootcode4.bin"),
        "BCM2712" => ("2712", "bootcode5.bin"),
        _ => return false,
    };
    let unpacked = |file: &str| is_file(&path.join(prefix).join(file)) || is_file(&path.join(file));
    let archive = path.join("bootfiles.bin");
    let in_archive =
        |file: &str| is_file(&archive) && archive_has(&archive, &format!("{prefix}/{file}"));
    // boot.img contains the Linux mass-storage gadget. An msd/recovery directory
    // or a gadget for the other SoC must never be accepted as a substitute.
    unpacked("boot.img")
        && (unpacked("config.txt") || in_archive("config.txt"))
        && (unpacked(bootloader) || in_archive(bootloader))
}

/// bootfiles.bin is an uncompressed tar archive. List a single member without
/// extracting any paths; both supported host platforms provide /usr/bin/tar.
pub fn archive_has(path: &Path, member: &str) -> bool {
    Command::new("/usr/bin/tar")
        .arg("-tf")
        .arg(path)
        .arg(member)
        .output()
        .map(|output| {
            output.status.success()
                && String::from_utf8_lossy(&output.stdout)
                    .lines()
                    .any(|line| line == member)
        })
        .unwrap_or(false)
}

pub fn missing_payload_error(mode: BootMode) -> &'static str {
    match mode {
        BootMode::Legacy => "legacy-boot-files-missing",
        BootMode::Modern => "modern-boot-files-missing",
    }
}

/// Older UI callers may still send this flag. Changing outer config.txt does
/// not reliably change the Linux gadget's embedded configuration, so reject it.
pub fn validate_options(force_pcie: Option<bool>) -> Result<(), String> {
    if force_pcie.unwrap_or(false) {
        Err("pcie-unsupported".into())
    } else {
        Ok(())
    }
}

/// Runs rpiboot to completion; returns its combined output either way.
pub fn run(binary: &Path, payload: &Path) -> Result<String, String> {
    let output = elevated(binary, payload)
        .output()
        .map_err(|e| e.to_string())?;
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    if output.status.success() {
        Ok(text)
    } else {
        Err(text)
    }
}

/// rpiboot must claim the USB device, which needs root on both platforms.
#[cfg(target_os = "macos")]
fn elevated(binary: &Path, payload: &Path) -> Command {
    let shell = format!(
        "{} -d {} 2>&1",
        sh_quote(&binary.to_string_lossy()),
        sh_quote(&payload.to_string_lossy())
    );
    let mut cmd = Command::new("/usr/bin/osascript");
    cmd.arg("-e").arg(format!(
        "do shell script {} with administrator privileges",
        applescript_quote(&shell)
    ));
    cmd
}

#[cfg(not(target_os = "macos"))]
fn elevated(binary: &Path, payload: &Path) -> Command {
    let mut cmd = Command::new("pkexec");
    cmd.arg(binary).arg("-d").arg(payload);
    cmd
}

#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn sh_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn applescript_quote(s: &str) -> String {
    format!("\"{}\"", s.replace('\\', r"\\").replace('"', "\\\""))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn board(chip: &'static str) -> BootDevice {
        BootDevice {
            chip,
            product: None,
            mode: if chip == "BCM283x" {
                BootMode::Legacy
            } else {
                BootMode::Modern
            },
        }
    }

    fn present<'a>(files: &'a [&str]) -> impl Fn(&Path) -> bool + 'a {
        |path| files.iter().any(|file| Path::new(file) == path)
    }

    #[test]
    fn binary_is_found_without_any_payload() {
        assert_eq!(
            locate_binary(present(&["/usr/local/bin/rpiboot"])),
            Some("/usr/local/bin/rpiboot".into())
        );
        assert_eq!(locate_binary(|_| false), None);
    }

    #[test]
    fn locate_prefers_homebrew_and_mixes_prefixes() {
        let files = [
            "/opt/homebrew/bin/rpiboot",
            "/usr/bin/rpiboot",
            "/usr/share/rpiboot/mass-storage-gadget64/boot.img",
            "/usr/share/rpiboot/mass-storage-gadget64/config.txt",
            "/usr/share/rpiboot/mass-storage-gadget64/bootfiles.bin",
        ];
        assert_eq!(
            locate_binary(present(&files)),
            Some("/opt/homebrew/bin/rpiboot".into())
        );
        assert_eq!(
            locate_payload(&board("BCM2712"), present(&files), |_, member| member
                == "2712/bootcode5.bin"),
            Some("/usr/share/rpiboot/mass-storage-gadget64".into())
        );
    }

    #[test]
    fn legacy_requires_msd_and_both_firmware_files() {
        let device = board("BCM283x");
        let files = [
            "/usr/local/share/msd/bootcode.bin",
            "/usr/local/share/msd/start.elf",
        ];
        assert_eq!(
            locate_payload(&device, present(&files), |_, _| false),
            Some("/usr/local/share/msd".into())
        );
        assert_eq!(
            locate_payload(&device, present(&files[..1]), |_, _| false),
            None
        );
        assert_eq!(
            locate_payload(&board("BCM2711"), present(&files), |_, _| true),
            None
        );
        let modern_only = [
            "/usr/local/share/mass-storage-gadget64/boot.img",
            "/usr/local/share/mass-storage-gadget64/config.txt",
            "/usr/local/share/mass-storage-gadget64/bootfiles.bin",
        ];
        assert_eq!(
            locate_payload(&device, present(&modern_only), |_, _| true),
            None
        );
    }

    #[test]
    fn modern_archive_must_include_the_connected_soc() {
        let files = [
            "/usr/share/mass-storage-gadget64/boot.img",
            "/usr/share/mass-storage-gadget64/config.txt",
            "/usr/share/mass-storage-gadget64/bootfiles.bin",
        ];
        let cm4_only = |_: &Path, member: &str| member == "2711/bootcode4.bin";
        assert!(locate_payload(&board("BCM2711"), present(&files), cm4_only).is_some());
        assert_eq!(
            locate_payload(&board("BCM2712"), present(&files), cm4_only),
            None
        );
        assert_eq!(
            locate_payload(&board("BCM2711"), present(&files[1..]), cm4_only),
            None
        );
    }

    #[test]
    fn modern_accepts_unpacked_alias_for_its_soc_only() {
        let files = [
            "/opt/homebrew/share/rpiboot/mass-storage-gadget/boot.img",
            "/opt/homebrew/share/rpiboot/mass-storage-gadget/config.txt",
            "/opt/homebrew/share/rpiboot/mass-storage-gadget/2712/bootcode5.bin",
        ];
        assert_eq!(
            locate_payload(&board("BCM2712"), present(&files), |_, _| false),
            Some("/opt/homebrew/share/rpiboot/mass-storage-gadget".into())
        );
        assert_eq!(
            locate_payload(&board("BCM2711"), present(&files), |_, _| false),
            None
        );
    }

    #[test]
    fn modern_prefers_gadget64_to_alias_across_prefixes() {
        let files = [
            "/opt/homebrew/share/mass-storage-gadget/boot.img",
            "/opt/homebrew/share/mass-storage-gadget/config.txt",
            "/opt/homebrew/share/mass-storage-gadget/bootcode4.bin",
            "/usr/share/mass-storage-gadget64/boot.img",
            "/usr/share/mass-storage-gadget64/config.txt",
            "/usr/share/mass-storage-gadget64/bootcode4.bin",
        ];
        assert_eq!(
            locate_payload(&board("BCM2711"), present(&files), |_, _| false),
            Some("/usr/share/mass-storage-gadget64".into())
        );
    }

    #[test]
    fn old_pcie_override_is_rejected_before_elevation() {
        assert_eq!(validate_options(Some(true)), Err("pcie-unsupported".into()));
        assert_eq!(validate_options(Some(false)), Ok(()));
        assert_eq!(validate_options(None), Ok(()));
    }

    #[test]
    fn quoting_survives_hostile_paths() {
        assert_eq!(sh_quote("/a b/it's"), r"'/a b/it'\''s'");
        assert_eq!(applescript_quote(r#"say "hi" \"#), r#""say \"hi\" \\""#);
    }
}
