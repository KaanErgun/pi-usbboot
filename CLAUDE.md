# cm5-usbboot

Tauri v2 masaüstü uygulaması: CM4/CM5'i USB boot modunda algılar, sistemdeki `rpiboot`'u
`mass-storage-gadget64` ile yönetici yetkisiyle çalıştırır, çıkan diskleri listeler.

- Kapı: `./scripts/check.sh` (tsc → rustfmt → clippy `-D warnings` → `cargo test`).
  Paketleme ayrı ve yavaş: `npm run bundle:mac` (bu Mac) / `npm run bundle:linux` (ros üzerinde).
- Hosted CI yok (global kural). Release dosyaları elle yüklenir.
- Kod, yorum, commit ve README İngilizce; arayüz metinleri `ui/i18n/tr.json` (kaynak) +
  `en.json`, kodda metin yok. Rust hata dönüşleri ya kararlı kod (`rpiboot-missing`) ya da
  ham rpiboot çıktısıdır; çeviriyi arayüz yapar.
- `ui/main.js` üretilir (`src-ui/main.ts` → `tsc`); elle düzenlenmez, commit edilmez.
- Simgeler `src-tauri/icons/icon-source.svg`'den `npx tauri icon` ile üretilir; Android/iOS
  ve Windows çıktıları silinir.

## Tuzaklar

- macOS GUI uygulamaları kabuk PATH'ini almaz: rpiboot `/opt/homebrew`, `/usr/local`, `/usr`
  önekleri tek tek aranır (`rpiboot.rs`).
- rpiboot USB aygıtını sahiplenmek için root ister: macOS'te `osascript … with administrator
  privileges`, Linux'ta `pkexec`. Cihaz yokken rpiboot sonsuza kadar bekler; düğme bu yüzden
  yalnız cihaz algılanınca açılır.
- CSP `connect-src` içinde `'self'` olmalı; yoksa `fetch("i18n/…")` engellenir ve arayüz
  boş açılır (2026-10-03'te yaşandı).
- `[hidden]` için `display: none !important` şart; `code { display: inline-block }` gibi
  kurallar `hidden` özniteliğini ezer.
- Stok gadget CM5'te (eMMC'li kart) yalnız `mmcblk0`'ı açtı, NVMe görünmedi (2026-10-03).
  Nedeni bilinmiyor; "PCIe'yi zorla" seçeneği doğrulanmamış bir deneme.
- AppImage yalnız Linux'ta derlenir; macOS'ten çapraz derleme yok.
