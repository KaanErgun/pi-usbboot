//! Run the packaged rpiboot and matching boot files with administrator access.

use crate::usb::{BootDevice, BootMode};
use std::path::{Path, PathBuf};
use std::process::Command;

/// Resolve only the packaged binary; a separate system installation is never used.
pub fn locate_binary(runtime: &Path, is_file: impl Fn(&Path) -> bool) -> Option<PathBuf> {
    let path = runtime.join("bin/rpiboot");
    is_file(&path).then_some(path)
}

/// Every release contains both boot families in one private resource directory.
pub fn locate_payload(
    runtime: &Path,
    device: &BootDevice,
    is_file: impl Fn(&Path) -> bool,
    archive_has: impl Fn(&Path, &str) -> bool,
) -> Option<PathBuf> {
    let name = match device.mode {
        BootMode::Legacy => "msd",
        BootMode::Modern => "mass-storage-gadget64",
    };
    let path = runtime.join("share/rpiboot").join(name);
    payload_compatible(&path, device, &is_file, &archive_has).then_some(path)
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
    fn binary_requires_bundled_path_and_never_uses_system_installation() {
        let root = Path::new("/package with spaces/runtime");
        assert_eq!(
            locate_binary(
                root,
                present(&["/usr/local/bin/rpiboot", "/usr/bin/rpiboot"])
            ),
            None
        );
        assert_eq!(
            locate_binary(root, present(&["/package with spaces/runtime/bin/rpiboot"])),
            Some(root.join("bin/rpiboot"))
        );
    }

    #[test]
    fn legacy_requires_both_packaged_firmware_files() {
        let root = Path::new("/bundle/runtime");
        let files = [
            "/bundle/runtime/share/rpiboot/msd/bootcode.bin",
            "/bundle/runtime/share/rpiboot/msd/start.elf",
        ];
        assert_eq!(
            locate_payload(root, &board("BCM283x"), present(&files), |_, _| false),
            Some(root.join("share/rpiboot/msd"))
        );
        assert!(
            locate_payload(root, &board("BCM283x"), present(&files[..1]), |_, _| false).is_none()
        );
        assert!(locate_payload(root, &board("BCM2711"), present(&files), |_, _| true).is_none());
    }

    #[test]
    fn modern_requires_bundled_image_and_matching_soc() {
        let root = Path::new("/bundle/runtime");
        let files = [
            "/bundle/runtime/share/rpiboot/mass-storage-gadget64/boot.img",
            "/bundle/runtime/share/rpiboot/mass-storage-gadget64/config.txt",
            "/bundle/runtime/share/rpiboot/mass-storage-gadget64/bootfiles.bin",
        ];
        let cm4_only = |_: &Path, member: &str| member == "2711/bootcode4.bin";
        assert!(locate_payload(root, &board("BCM2711"), present(&files), cm4_only).is_some());
        assert!(locate_payload(root, &board("BCM2712"), present(&files), cm4_only).is_none());
        assert!(locate_payload(root, &board("BCM2711"), present(&files[1..]), cm4_only).is_none());
        assert!(locate_payload(root, &board("BCM283x"), present(&files), cm4_only).is_none());
    }

    #[test]
    fn system_payload_does_not_mask_a_broken_package() {
        let files = [
            "/usr/share/rpiboot/msd/bootcode.bin",
            "/usr/share/rpiboot/msd/start.elf",
        ];
        assert!(locate_payload(
            Path::new("/bundle/runtime"),
            &board("BCM283x"),
            present(&files),
            |_, _| false
        )
        .is_none());
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
