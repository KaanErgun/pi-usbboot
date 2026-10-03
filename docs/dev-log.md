# Geliştirme günlüğü

## 2026-10-03 — v0.1.0 ilk sürüm

**Neden:** netsay-ros-001/002 (CM5) Ubuntu 26.04'e geçerken NVMe'yi Mac'e açmak için
`sudo rpiboot -d …/mass-storage-gadget64` elle çalıştırıldı; adım adım komut yerine tek
pencerelik bir araç istendi (Kaan).

**Yapılan:**
- USB boot ROM algılama (`nusb`, vendor `0a5c`, ürün `2711` / `2712` / `2763` / `2764`).
- rpiboot konumu bulma, macOS `osascript` / Linux `pkexec` ile çalıştırma.
- Harici disk listesi (`diskutil` / `lsblk -J`), NVMe ve eMMC/SD etiketi.
- Deneysel "PCIe'yi zorla": gadget'ın geçici kopyasına `dtparam=pciex1`.
- Raspberry Pi Imager'ı açma.

**Doğrulama (bu Mac, macOS 27.0.1, arm64):**
- `./scripts/check.sh` exit 0 — 9 Rust birim testi geçti.
- `npm run bundle:mac` → `CM5 USB Boot.app` (8.4 MiB) + `CM5 USB Boot_0.1.0_aarch64.dmg` (2.8 MiB),
  `/Applications`'a kuruldu.
- Görsel: `docs/screenshots/2026-10-03-macos-before-hidden-fix.jpg` (rpiboot kurulu olduğu
  hâlde kurulum ipucu görünüyordu) → `docs/screenshots/2026-10-03-macos-waiting.jpg` (düzeltildi).
- İlk derlemede arayüz boş açıldı: CSP `connect-src` `'self'` içermiyordu, çeviri dosyaları
  yüklenemedi. Düzeltildi.

**Yayın hazırlığı (aynı gün):**
- Güvenlik incelemesi: "PCIe'yi zorla" sabit `$TMPDIR/cm5-usbboot-gadget` yoluna yazıyordu →
  her seferinde yeni `0700` dizin, iş bitince siliniyor; test eklendi (10 test).
  Homebrew rpiboot'un kullanıcı yazabilir yolda olması bilinçli kabul edildi, README "Security".
- Arayüze sürüm (`v0.1.0`) eklendi.
- macOS: universal (`x86_64 arm64`), Developer ID imzalı, hardened runtime;
  `CM5-USB-Boot_0.1.0_universal.dmg` (5.8 MiB). Notarization kabul edildi; DMG bileti
  doğrulandı ve Gatekeeper kontrolü geçti (`Notarized Developer ID`).
- Linux: ros (Ubuntu 26.04 x86_64) üzerinde gate exit 0 (10 test), `CM5-USB-Boot_0.1.0_amd64.AppImage`
  (82.5 MiB). Xvfb + openbox'ta açıldı: `docs/screenshots/2026-10-03-linux-appimage.png`.

**Doğrulanmayan:**
- Gerçek kartla uçtan uca akış (algılama → rpiboot → disk) henüz uygulamayla denenmedi;
  ikinci CM5 (netsay-ros-001, CM5 Lite) ile denenecek.
- "PCIe'yi zorla" seçeneğinin NVMe'yi gösterip göstermediği.
- Linux'ta `pkexec` ile rpiboot çalıştırma (ros'ta rpiboot ve kart yok).

### Notarization completed

- App-specific-password authentication initially returned HTTP 403:
  "A required agreement is missing or has expired." Switching to the supplied
  App Store Connect team API key validated successfully and saved the
  `cm5-usbboot` Keychain profile. The earlier error's underlying cause was not
  established; API-key authentication succeeded without further account changes
  by this agent.
- Submission `3aa57ddd-781c-46e0-8ccd-59f0e98d638c`, created on 2026-10-03 at
  20:00 Istanbul time, was already present in Apple's history. Its final status
  is `Accepted`, with `Ready for distribution` and no reported issues. No duplicate
  submission was created. The downloaded report is in the ignored local file
  `release/notarization-0.1.0.json`.
- The DMG already had its ticket attached when checked. `stapler validate` passed;
  both the DMG and universal application passed Gatekeeper with
  `source=Notarized Developer ID`. DMG signature verification also passed.
- The report's code-signing digest matches the release DMG. The archive SHA-256
  in Apple's report describes the uploaded file; the distributed DMG has a
  different SHA-256 after stapling.
- `release/SHA256SUMS` covers the final stapled DMG and Linux AppImage. Both
  checksums pass. The README now reflects the verified notarization status.
- `./scripts/check.sh` passed earlier in this session: TypeScript, rustfmt, clippy,
  and all 10 Rust tests. No application source changed during notarization.

For subsequent submissions, use `--keychain-profile cm5-usbboot`. Keep the API
private key outside the repository. Record each submission ID and query it if
interrupted; staple only after `Accepted`, verify with `stapler validate` and
Gatekeeper, and regenerate checksums after stapling.

## 2026-10-03 — Pi USB Boot 0.2.0

- Renamed the app and GitHub repository to Pi USB Boot / `pi-usbboot`. The macOS
  bundle identifier and existing Keychain notarization profile stay unchanged.
- Fixed boot-file selection: USB IDs 2763/2764 use legacy `msd`; BCM2711/2712 use
  the Linux mass-storage gadget with the matching SoC bootloader. Binary and
  payload discovery support independent installation prefixes.
- Added readiness checks, multiple-board rejection, a concurrent-run guard,
  fresh detection before elevation, and translated board preparation guidance.
- Removed the unverified Force PCIe override; installed boot files remain unchanged.
- Documented supported RPIBOOT models and board-specific preparation. This does
  not add USB device boot to unsupported boards.
- Validation: TypeScript, rustfmt, clippy and 16 Rust tests passed on macOS and
  Ubuntu 26.04 x86_64. All 11 secret-guard regression scenarios passed. English
  and Turkish UI states passed 28 headless Chrome assertions.
- macOS universal build is Developer ID signed. Apple accepted notarization
  submission `926213d5-8a24-47d6-898f-b551b332aec7`; distribution checks follow
  the existing stapling and checksum procedure above.
- Physical-board end-to-end operation and Linux privilege elevation with a board
  remain unverified. Payload checks validate starting files, not every firmware
  component or board-specific behavior.

## 2026-10-03 — Pi USB Boot 0.3.0 self-contained packages

- Bundled pinned rpiboot, static libusb, legacy MSD, Linux gadget firmware and
  official Raspberry Pi Imager. Runtime discovery uses only application resources.
- macOS includes universal executables and requires macOS 13 due to Imager's Qt
  deployment target. The nested Imager retains its original Raspberry Pi signature.
- Linux packages isolate the official Imager in a verified local archive to avoid
  GTK/Qt library collisions during packaging. Its wrapper extracts into a stable
  per-user cache without FUSE or downloads; Imager can outlive the main window.
- Added a per-user `.run` installer, desktop-menu entry, `.deb` dependencies, build
  preflight checks, and a display-free `--check-runtime` diagnostic.
- TypeScript, clippy, formatting and 15 Rust tests passed on macOS and Linux.
  English/Turkish browser checks passed 28 assertions at 560x680. Installer/wrapper
  fixtures verified first extraction, repeat launch, spaces, argument preservation,
  environment isolation and corruption rejection.
- macOS notarization submission `08a7c21d-7ecf-4b41-ad11-8a0d93cf97c6` was Accepted.
  Stapling and Gatekeeper verification passed. The final app and the user's
  `/Applications/Pi USB Boot.app` both passed bundle diagnostics and signature checks.
- A user-reported macOS “Could not install” dialog was investigated. Installed main
  and Imager processes were running; no corresponding crash report was found. The
  precise trigger was not reproduced. Do not describe that report as a proven fix.
- Matching third-party source assets/notices accompany the release. The gadget
  kernel source revision is inferred from the embedded build date, explicitly
  documented in the provenance manifest; bit-identical reconstruction is not claimed.
- Physical USB boot/image-writing end-to-end tests remain unperformed.

- Native macOS inspection confirmed a visible, fully rendered 0.3.0 window with
  bundled tools ready; thread sampling showed normal WebKit/backend polling. The
  earlier installation alert remains unattributed rather than claimed fixed.
- Linux AppImage packaging initially reused a stale `appimage_deb` staging tree
  containing old Qt libraries. Cleaning both generated staging trees fixed it;
  `bundle-linux.sh` now performs that cleanup before every build. Final AppDir and
  installed `.run` diagnostics pass for all three boot families; first launch and
  repeat launch in isolated, space-containing XDG directories both passed.
