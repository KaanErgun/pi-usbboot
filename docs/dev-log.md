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

**Doğrulanmayan:**
- Gerçek kartla uçtan uca akış (algılama → rpiboot → disk) henüz uygulamayla denenmedi;
  ikinci CM5 (netsay-ros-001, CM5 Lite) ile denenecek.
- "PCIe'yi zorla" seçeneğinin NVMe'yi gösterip göstermediği.
- Linux AppImage.
