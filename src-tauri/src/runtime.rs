//! Paths for tools shipped inside this application, independent of the host PATH.

use std::path::{Path, PathBuf};
use std::process::Command;
use tauri::Manager;

pub fn root(app: &tauri::AppHandle) -> Result<PathBuf, String> {
    #[cfg(debug_assertions)]
    {
        let development = Path::new(env!("CARGO_MANIFEST_DIR")).join("resources/runtime");
        if development.is_dir() {
            return Ok(development);
        }
    }
    app.path()
        .resource_dir()
        .map(|path| path.join("runtime"))
        .map_err(|_| "package-missing".into())
}

pub fn imager(root: &Path) -> PathBuf {
    #[cfg(target_os = "macos")]
    return root.join("imager/Raspberry Pi Imager.app");
    #[cfg(not(target_os = "macos"))]
    return root.join("imager/AppRun");
}

pub fn imager_ready(root: &Path) -> bool {
    #[cfg(target_os = "macos")]
    return imager(root).join("Contents/MacOS/rpi-imager").is_file();
    #[cfg(not(target_os = "macos"))]
    return imager(root).is_file();
}

pub fn open_imager(root: &Path) -> Result<(), String> {
    if !imager_ready(root) {
        return Err("imager-missing".into());
    }
    #[cfg(target_os = "macos")]
    {
        // An explicit path prevents LaunchServices choosing a separate installation.
        let result = Command::new("/usr/bin/open")
            .args(["-n", "-a"])
            .arg(imager(root))
            .status()
            .map_err(|_| "imager-missing")?;
        if result.success() {
            Ok(())
        } else {
            Err("imager-missing".into())
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        let mut command = Command::new(imager(root));
        command.current_dir(root.join("imager"));
        // The nested Qt application has its own libraries. Do not inherit the
        // enclosing GTK AppImage's loader paths or mount metadata.
        for name in [
            "APPDIR",
            "APPIMAGE",
            "ARGV0",
            "LD_LIBRARY_PATH",
            "LD_PRELOAD",
            "QT_PLUGIN_PATH",
            "QT_QPA_PLATFORM_PLUGIN_PATH",
            "QML2_IMPORT_PATH",
            "QML_IMPORT_PATH",
            "GIO_MODULE_DIR",
        ] {
            command.env_remove(name);
        }
        command
            .spawn()
            .map(drop)
            .map_err(|_| "imager-missing".into())
    }
}

/// A read-only release check that works without a display or connected board.
pub fn check(root: &Path) -> bool {
    use crate::{rpiboot, usb};
    let binary = rpiboot::locate_binary(root, Path::is_file);
    let version = binary.as_ref().and_then(|path| {
        Command::new(path)
            .arg("-V")
            .output()
            .ok()
            .filter(|output| output.status.success())
    });
    let mut payloads = serde_json::Map::new();
    let mut complete = version.is_some() && imager_ready(root);
    for (chip, mode) in [
        ("BCM283x", usb::BootMode::Legacy),
        ("BCM2711", usb::BootMode::Modern),
        ("BCM2712", usb::BootMode::Modern),
    ] {
        let board = usb::BootDevice {
            chip,
            mode,
            product: None,
        };
        let found =
            rpiboot::locate_payload(root, &board, Path::is_file, rpiboot::archive_has).is_some();
        complete &= found;
        payloads.insert(chip.into(), found.into());
    }
    println!(
        "{}",
        serde_json::json!({
            "complete": complete,
            "runtime": root,
            "rpiboot_runs": version.is_some(),
            "imager_ready": imager_ready(root),
            "boot_files": payloads,
        })
    );
    complete
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn imager_path_stays_in_the_bundle_even_with_spaces() {
        let root = Path::new("/a package/runtime");
        assert!(imager(root).starts_with(root));
        assert!(!imager_ready(Path::new("/nonexistent-pi-usbboot-runtime")));
        assert_eq!(
            open_imager(Path::new("/nonexistent-pi-usbboot-runtime")),
            Err("imager-missing".into())
        );
    }
}
