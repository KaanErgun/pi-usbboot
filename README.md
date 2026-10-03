# Pi USB Boot

A desktop app for macOS and Linux that exposes storage on **RPIBOOT-compatible
Raspberry Pi boards** as USB disks, ready to flash with Raspberry Pi Imager.
Previously named CM5 USB Boot.

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
recent Linux gadgets. The installed rpiboot firmware must support your board.

This is **USB device boot (RPIBOOT)**, which differs from booting a Pi from a USB
flash drive. Classic B-model boards with an onboard USB hub (including Pi 2B,
3B and 3B+) and Pico microcontrollers are outside this workflow. Use Raspberry Pi
Imager with a card reader for an unsupported board's removable storage.

Compatibility is based on [Raspberry Pi's upstream documentation](https://github.com/raspberrypi/usbboot#compatible-devices)
and the app's boot-file selection tests. Physical-board end-to-end operation across
these models has not been verified; Linux privilege elevation with a board also
remains untested. The disk list includes other external USB disks: select the
intended drive carefully in Imager.

## Download

Get the latest build from [Releases](https://github.com/KaanErgun/pi-usbboot/releases):

| Platform | File |
|---|---|
| macOS 11+ (Apple Silicon and Intel) | `Pi-USB-Boot_<version>_universal.dmg` — Developer ID signed and notarized |
| Linux x86_64 | `Pi-USB-Boot_<version>_amd64.AppImage` — built and tested on Ubuntu 26.04 |

Verify downloads against `SHA256SUMS`. On Linux, `chmod +x` the AppImage; if your distro
has no FUSE 2 (`libfuse2` / `libfuse2t64`), use `--appimage-extract-and-run`.
Compatibility with older Linux distributions has not been verified.

## Requirements

- A current `rpiboot` installation and the appropriate boot files:
  - Modern boards: `mass-storage-gadget64` (or its `mass-storage-gadget` alias).
  - Earlier boards: the `msd` directory containing `bootcode.bin` and `start.elf`.
  - macOS: `brew install rpiboot`; Debian / Ubuntu: `sudo apt install rpiboot`.
  - If a package lacks the required files, follow the [upstream build/install instructions](https://github.com/raspberrypi/usbboot#building).
- [Raspberry Pi Imager](https://www.raspberrypi.com/software/) to write the OS image.
- A USB data connection to the board's device/OTG port and sufficient power.
- On Linux, `pkexec` and a desktop authentication agent.

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
2. Check the detected board and storage mode. If boot files are missing, update
   the rpiboot installation before continuing.
3. Click **Expose disk over USB** and authenticate.
4. When the disk appears, open Raspberry Pi Imager and select the correct drive.
5. If macOS reports that the disk is unreadable, choose **Ignore**, not **Initialize**.

The old experimental Force PCIe option was removed in v0.2.0. Its outer config-file
change was not verified to affect the Linux gadget's inner boot configuration.
The app now uses the installed, unmodified boot files; current upstream Pi 5 gadget
configuration already enables PCIe. See the [upstream gadget configuration](https://github.com/raspberrypi/buildroot/blob/mass-storage-gadget64/board/raspberrypi64-mass-storage-gadget/config.txt).

## Build

Needs Rust (stable) and Node.js. On Linux also the Tauri system packages
(`libwebkit2gtk-4.1-dev librsvg2-dev patchelf libssl-dev build-essential file`).

```sh
npm install
./scripts/check.sh        # typecheck, rustfmt, clippy, unit tests
npm run bundle:mac        # .app + .dmg      (on macOS)
npm run bundle:linux      # .AppImage        (on Linux)
```

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

`rpiboot` needs root to claim the USB device, so the app asks for your password each time
you click **Expose disk over USB** and runs exactly the binary shown under **rpiboot**.
With a Homebrew install that binary lives in a user-writable prefix, so the trust is the
same as typing `sudo rpiboot` yourself: anything already running as your user could have
replaced it. Boot files are read from the installed rpiboot package; the app does not
modify them or change a board's EEPROM/OTP configuration.

## License

MIT. `rpiboot` and its boot images belong to Raspberry Pi Ltd and are not bundled.
