mod disks;
mod rpiboot;
mod usb;

use serde::Serialize;
use std::path::Path;
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};

static GADGET_RUNNING: AtomicBool = AtomicBool::new(false);

struct RunGuard;

impl RunGuard {
    fn acquire() -> Result<Self, String> {
        GADGET_RUNNING
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .map(|_| Self)
            .map_err(|_| "busy".into())
    }
}

impl Drop for RunGuard {
    fn drop(&mut self) {
        GADGET_RUNNING.store(false, Ordering::Release);
    }
}

#[derive(Serialize)]
struct Status {
    device: Option<usb::BootDevice>,
    /// The binary is located independently of any board-specific boot files.
    rpiboot: Option<String>,
    boot_files: Option<String>,
    boot_error: Option<String>,
    ready: bool,
    disks: Vec<disks::Disk>,
    usb_error: Option<String>,
}

#[tauri::command]
fn status() -> Status {
    let (device, usb_error) = match usb::find() {
        Ok(d) => (d, None),
        Err(e) => (None, Some(e)),
    };
    let binary = rpiboot::locate_binary(Path::is_file);
    let payload = device
        .as_ref()
        .and_then(|d| rpiboot::locate_payload(d, Path::is_file, rpiboot::archive_has));
    let boot_error = if GADGET_RUNNING.load(Ordering::Acquire) {
        Some("busy")
    } else if binary.is_none() {
        Some("rpiboot-missing")
    } else if usb_error.is_some() {
        // USB enumeration failures are reported separately, with their cause.
        None
    } else if let Some(d) = &device {
        payload
            .is_none()
            .then(|| rpiboot::missing_payload_error(d.mode))
    } else {
        Some("device-missing")
    };
    let ready = boot_error.is_none() && usb_error.is_none() && payload.is_some();
    Status {
        device,
        rpiboot: binary.map(|p| p.display().to_string()),
        boot_files: payload.map(|p| p.display().to_string()),
        boot_error: boot_error.map(str::to_owned),
        ready,
        disks: disks::list(),
        usb_error,
    }
}

/// Errors are either a stable code the UI translates ("rpiboot-missing") or raw rpiboot output.
#[tauri::command]
async fn start_gadget(force_pcie: Option<bool>) -> Result<String, String> {
    rpiboot::validate_options(force_pcie)?;
    let guard = RunGuard::acquire()?;
    tauri::async_runtime::spawn_blocking(move || {
        let _guard = guard;
        // Re-detect immediately before preparing the privileged command; the
        // board shown by the last UI poll may already have been disconnected.
        let device = usb::find()?.ok_or("device-missing")?;
        let binary = rpiboot::locate_binary(Path::is_file).ok_or("rpiboot-missing")?;
        let payload = rpiboot::locate_payload(&device, Path::is_file, rpiboot::archive_has)
            .ok_or_else(|| rpiboot::missing_payload_error(device.mode))?;
        rpiboot::run(&binary, &payload)
    })
    .await
    .map_err(|e| e.to_string())?
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn concurrent_starts_are_rejected_and_guard_releases_on_drop() {
        let guard = RunGuard::acquire().unwrap();
        assert!(matches!(RunGuard::acquire(), Err(error) if error == "busy"));
        drop(guard);
        assert!(RunGuard::acquire().is_ok());
    }
}

#[tauri::command]
fn open_imager() -> Result<(), String> {
    #[cfg(target_os = "macos")]
    let mut cmd = {
        let mut c = Command::new("/usr/bin/open");
        c.args(["-a", "Raspberry Pi Imager"]);
        c
    };
    #[cfg(not(target_os = "macos"))]
    let mut cmd = Command::new("rpi-imager");
    cmd.spawn().map(drop).map_err(|_| "imager-missing".into())
}

pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![status, start_gadget, open_imager])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
