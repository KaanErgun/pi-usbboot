# Pi USB Boot

A desktop app for macOS and Linux that exposes storage on **RPIBOOT-compatible
Raspberry Pi boards** as USB disks, ready to flash with Raspberry Pi Imager.
Previously named CM5 USB Boot.

The app includes rpiboot, its boot files, libusb, and Raspberry Pi Imager.
Users do not install these tools separately. Selecting an OS from Imager's catalog
requires an internet connection; a local image can be written offline.

It wraps the official [`rpiboot`](https://github.com/raspberrypi/usbboot) tool:

1. Detects a board waiting in USB device boot mode.
2. Chooses the storage boot files for the detected USB boot family.
3. Runs rpiboot with administrator access and lists external USB disks.
4. Opens Raspberry Pi Imager to write an OS image.

## Compatible boards

| Family | Boards with RPIBOOT support | Storage mode selected by this app |
|---|---|---|
| BCM2711 / BCM2712 | CM4, CM4S, CM5; Pi 4B, Pi 400, Pi 5, Pi 500, Pi 500+ | Linux mass-storage gadget: SD / eMMC, NVMe and other supported block devices |
| Earlier boot families | CM1, CM3, CM3+, CM3E; Pi 1A+, Pi 3A+, Zero / Zero W, Zero 2 W | Legacy MSD firmware: SD / eMMC |

The earlier USB identifiers do not uniquely identify a retail model. This app
conservatively uses legacy MSD for them, including 64-bit boards that can also run
recent Linux gadgets. The bundled firmware must support your board.

This is **USB device boot (RPIBOOT)**, which differs from booting a Pi from a USB
flash drive. Classic B-model boards with an onboard USB hub (including Pi 2B,
3B and 3B+) and Pico microcontrollers are outside this workflow. Use Raspberry Pi
Imager with a card reader for an unsupported board's removable storage.

Compatibility is based on [Raspberry Pi's upstream documentation](https://github.com/raspberrypi/usbboot#compatible-devices)
and the app's boot-file selection tests. On October 3, 2026, the bundled rpiboot
with the corrected gadget payload exposed a BCM2712 board's 256.1 GB NVMe as a
USB disk on macOS. Other models, Linux privilege elevation with a board, and OS
image writing remain untested. The disk list includes other external USB disks:
select the intended drive carefully in Imager.

## Download

Get the latest build from [Releases](https://github.com/KaanErgun/pi-usbboot/releases):

| Platform | File |
|---|---|
| macOS 13+ (Apple Silicon and Intel) | `Pi-USB-Boot_<version>_universal.dmg` — signed and notarized, all tools included |
| Ubuntu 26.04 desktop x86_64 | `Pi-USB-Boot_<version>_amd64.run` — self-contained installer, no FUSE |
| Ubuntu / Debian package | `Pi-USB-Boot_<version>_amd64.deb` — desktop installer with OS dependencies declared |

On macOS, open the DMG and drag **Pi USB Boot** into Applications. On Linux, allow
execution of the `.run` file and launch it (or run `sh Pi-USB-Boot_<version>_amd64.run`).
It installs into your user data directory and adds Pi USB Boot to the applications
menu. Installation and both included tools require no additional downloads.
The `.deb` alternative uses your distribution's package installer to resolve any
missing base OS libraries automatically. Compatibility with older distributions
has not been verified.

Verify downloads against `SHA256SUMS`. Source archives are provided for license
compliance and rebuilding; users do not need them to run the application.

## Requirements

- A supported desktop OS, a USB data cable and sufficient board power.
- Administrator permission for USB access and writing disks. Linux uses the
  desktop's existing polkit authentication service (`pkexec`); Ubuntu 26.04
  desktop includes it, and the `.deb` declares it as an installation dependency.
- An internet connection to download an OS image, or an existing local image.
- Board-specific preparation below. No Homebrew, compiler, separate rpiboot,
  libusb, Raspberry Pi Imager, or FUSE installation is needed for the supported
  desktop environment.

## Prepare the board

Connect **one board in RPIBOOT mode at a time**. The app prevents starting when
multiple boot-mode boards are detected.

- **Compute Modules:** enable the carrier's nRPIBOOT / EMMC-DISABLE jumper before
  power-on and use its USB device port. The connector depends on the carrier.
- **Pi 5 / 500 / 500+:** disconnect power, hold the power button, and reconnect
  the USB-C data cable. Pi 500 requires keyboard firmware with RPIBOOT support.
- **Pi 4B / 400:** RPIBOOT must be configured beforehand. The upstream GPIO method
  permanently programs OTP; follow the [official preparation instructions](https://github.com/raspberrypi/usbboot#enabling-rpiboot-support--extra-steps-for-pi-4b-pi-400--pi-500)
  for your exact board. This app does not perform that configuration.
- **Earlier supported Pi boards:** use the USB device/OTG port and the model's
  [USB device boot procedure](https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#usb-device-boot-mode).
  Pi 3A+ device boot is unavailable once USB host boot OTP has been enabled.

## Usage

1. Prepare the board for RPIBOOT, connect its data port, and power it.
2. Check the detected board and storage mode. If bundled files are missing, download
   and reinstall the complete application package.
3. Click **Expose disk over USB** and authenticate.
4. When the disk appears, open Raspberry Pi Imager and select the correct drive.
5. If macOS reports that the disk is unreadable, choose **Ignore**, not **Initialize**.

If v0.3.0 finishes transferring `boot.img` but no USB device appears, update to
v0.3.1. The v0.3.0 gadget image omitted the kernel modules required for USB storage.
The corrected release pins the complete earlier official gadget payload and
checks its required drivers during packaging. A successful rpiboot transfer only
means the boot files reached the board; the app then waits for a new external disk.

The old experimental Force PCIe option was removed in v0.2.0. Its outer config-file
change was not verified to affect the Linux gadget's inner boot configuration.
The app now uses its bundled, unmodified boot files; current upstream Pi 5 gadget
configuration already enables PCIe. See the [upstream gadget configuration](https://github.com/raspberrypi/buildroot/blob/mass-storage-gadget64/board/raspberrypi64-mass-storage-gadget/config.txt).

## Build

Building requires Rust (stable), Node.js, Python 3.12+, a C toolchain, curl, make
and xxd. These are developer requirements, not end-user dependencies. On Linux also the Tauri system packages
(`libwebkit2gtk-4.1-dev librsvg2-dev patchelf libssl-dev build-essential file libarchive-tools`).
The boot-image audit uses the host's libarchive library; macOS includes it.

```sh
npm install
npm run prepare:runtime # downloads pinned tools; compiles rpiboot for this host
./scripts/check.sh        # typecheck, rustfmt, clippy, unit tests
npm run bundle:mac        # .app + .dmg      (on macOS)
npm run bundle:linux      # .deb + AppImage  (on Linux)
```

See [third-party packaging](docs/third-party-packaging.md) for pinned versions,
source archives, licenses, and the Linux installer build. `--check-runtime` runs a
read-only bundled-tool check without a display or connected board.

## Security

Before contributing, install [Gitleaks](https://github.com/gitleaks/gitleaks) 8.30.1 or newer
(`brew install gitleaks` on macOS) and run `npm run setup:hooks` once per clone.
The local pre-commit hook scans staged changes and blocks files covered by this
project's `.gitignore`, including files added with `git add -f`. The pre-push hook
also scans Git history, including sensitive files removed in later commits. Both
hooks stop if Gitleaks is missing, and scanner output redacts secret values.
Run `npm run check:secrets` for a history scan and `npm run test:secrets` to verify
the guards using synthetic data in temporary repositories.

Keep `.p8` signing keys, Keychain exports, `.env` files, and assistant transcripts
outside Git. Only placeholder values belong in `.env.example`, `.env.sample`, or
`.env.template`. A `.gitignore` rule does not remove files already committed; if a
credential reaches GitHub, revoke or rotate it before cleaning up history. Local
hooks must be installed on each clone and can be bypassed; keep GitHub secret
scanning and push protection enabled as another layer of protection.

`rpiboot` needs root to claim the USB device. The application runs only its
bundled binary and boot files; a separate system rpiboot or Imager installation
cannot silently replace them. macOS requests administrator approval through the
system prompt; Linux uses polkit. Boot files remain unchanged, and the app does
not change a board's EEPROM/OTP configuration. Tools in a per-user installation
have the same trust boundary as other software writable by that user.

## License

Pi USB Boot source: MIT. Bundled third-party tools and firmware retain their own
licenses. Notices are included in `runtime/licenses` inside the application;
matching source information and archives accompany the release. Raspberry Pi
Imager keeps its original Raspberry Pi Ltd branding and macOS signature.
