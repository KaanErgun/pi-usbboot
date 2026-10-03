mod disks;
mod rpiboot;
mod usb;

use serde::Serialize;
use std::path::Path;
use std::process::Command;

#[derive(Serialize)]
struct Status {
    device: Option<usb::BootDevice>,
    /// Path of the rpiboot binary, or None when it (or its gadget) is not installed.
    rpiboot: Option<String>,
    disks: Vec<disks::Disk>,
    usb_error: Option<String>,
}

#[tauri::command]
fn status() -> Status {
    let (device, usb_error) = match usb::find() {
        Ok(d) => (d, None),
        Err(e) => (None, Some(e)),
    };
    Status {
        device,
        rpiboot: rpiboot::locate(Path::exists).map(|i| i.binary.display().to_string()),
        disks: disks::list(),
        usb_error,
    }
}

/// Errors are either a stable code the UI translates ("rpiboot-missing") or raw rpiboot output.
#[tauri::command]
async fn start_gadget(force_pcie: bool) -> Result<String, String> {
    let install = rpiboot::locate(Path::exists).ok_or("rpiboot-missing")?;
    tauri::async_runtime::spawn_blocking(move || {
        let gadget = if force_pcie {
            rpiboot::gadget_with_pcie(&install.gadget)?
        } else {
            install.gadget
        };
        rpiboot::run(&install.binary, &gadget)
    })
    .await
    .map_err(|e| e.to_string())?
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
