//! Locate the system rpiboot install and run its mass-storage gadget with admin rights.

use std::path::{Path, PathBuf};
use std::process::Command;

/// GUI apps on macOS do not inherit the shell PATH, so look in the usual prefixes explicitly.
const PREFIXES: &[&str] = &["/opt/homebrew", "/usr/local", "/usr"];
const GADGET: &str = "share/rpiboot/mass-storage-gadget64";

#[derive(Debug, PartialEq)]
pub struct Install {
    pub binary: PathBuf,
    pub gadget: PathBuf,
}

pub fn locate(exists: impl Fn(&Path) -> bool) -> Option<Install> {
    let first = |rel: &str| {
        PREFIXES
            .iter()
            .map(|p| Path::new(p).join(rel))
            .find(|p| exists(p))
    };
    Some(Install {
        binary: first("bin/rpiboot")?,
        gadget: first(GADGET)?,
    })
}

/// Copy the gadget into a temp dir with `dtparam=pciex1` appended to config.txt.
/// Experimental: meant for boards whose NVMe does not show up with the stock gadget.
/// The caller removes the directory after rpiboot has run.
pub fn gadget_with_pcie(stock: &Path) -> Result<PathBuf, String> {
    let dir = private_temp_dir().map_err(|e| e.to_string())?;
    for entry in std::fs::read_dir(stock).map_err(|e| e.to_string())? {
        let entry = entry.map_err(|e| e.to_string())?;
        std::fs::copy(entry.path(), dir.join(entry.file_name())).map_err(|e| e.to_string())?;
    }
    let config = dir.join("config.txt");
    let stock_config = std::fs::read_to_string(&config).map_err(|e| e.to_string())?;
    std::fs::write(&config, with_pcie(&stock_config)).map_err(|e| e.to_string())?;
    Ok(dir)
}

/// rpiboot reads this directory as root, so it must be fresh and private: a fixed name
/// under a shared /tmp could be pre-created by another user with their own boot files.
fn private_temp_dir() -> std::io::Result<PathBuf> {
    use std::os::unix::fs::DirBuilderExt;
    use std::time::{SystemTime, UNIX_EPOCH};
    let mut last_err = None;
    for attempt in 0..8u32 {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or_default();
        let dir = std::env::temp_dir().join(format!(
            "cm5-usbboot-{}-{nanos:x}-{attempt}",
            std::process::id()
        ));
        // `create` (not `create_dir_all`) fails if the path already exists, symlinks included.
        match std::fs::DirBuilder::new().mode(0o700).create(&dir) {
            Ok(()) => return Ok(dir),
            Err(e) => last_err = Some(e),
        }
    }
    Err(last_err.expect("loop ran at least once"))
}

fn with_pcie(config: &str) -> String {
    format!("{}\n[all]\ndtparam=pciex1\n", config.trim_end())
}

/// Runs rpiboot to completion; returns its combined output either way.
pub fn run(binary: &Path, gadget: &Path) -> Result<String, String> {
    let output = elevated(binary, gadget)
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
fn elevated(binary: &Path, gadget: &Path) -> Command {
    let shell = format!(
        "{} -d {} 2>&1",
        sh_quote(&binary.to_string_lossy()),
        sh_quote(&gadget.to_string_lossy())
    );
    let mut cmd = Command::new("/usr/bin/osascript");
    cmd.arg("-e").arg(format!(
        "do shell script {} with administrator privileges",
        applescript_quote(&shell)
    ));
    cmd
}

#[cfg(not(target_os = "macos"))]
fn elevated(binary: &Path, gadget: &Path) -> Command {
    let mut cmd = Command::new("pkexec");
    cmd.arg(binary).arg("-d").arg(gadget);
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

    #[test]
    fn locate_prefers_homebrew_and_mixes_prefixes() {
        let present = [
            "/opt/homebrew/bin/rpiboot",
            "/usr/share/rpiboot/mass-storage-gadget64",
        ];
        let found = locate(|p| present.iter().any(|x| Path::new(x) == p)).unwrap();
        assert_eq!(found.binary, Path::new("/opt/homebrew/bin/rpiboot"));
        assert_eq!(
            found.gadget,
            Path::new("/usr/share/rpiboot/mass-storage-gadget64")
        );
    }

    #[test]
    fn locate_needs_both_parts() {
        assert_eq!(locate(|p| p.ends_with("bin/rpiboot")), None);
    }

    #[test]
    fn pcie_line_is_appended_once_at_the_end() {
        let out = with_pcie("boot_ramdisk=1\nuart_2ndstage=1\n\n");
        assert_eq!(
            out,
            "boot_ramdisk=1\nuart_2ndstage=1\n[all]\ndtparam=pciex1\n"
        );
    }

    #[test]
    fn temp_dirs_are_fresh_and_private() {
        use std::os::unix::fs::PermissionsExt;
        let a = private_temp_dir().unwrap();
        let b = private_temp_dir().unwrap();
        assert_ne!(a, b);
        let mode = std::fs::metadata(&a).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o700);
        std::fs::remove_dir(a).unwrap();
        std::fs::remove_dir(b).unwrap();
    }

    #[test]
    fn quoting_survives_hostile_paths() {
        assert_eq!(sh_quote("/a b/it's"), r"'/a b/it'\''s'");
        assert_eq!(applescript_quote(r#"say "hi" \"#), r#""say \"hi\" \\""#);
    }
}
