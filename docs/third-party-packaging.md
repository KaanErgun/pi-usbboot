# Bundled runtime and source distribution

Pi USB Boot 0.3.0 includes its USB boot tool, firmware and a separate, unmodified
Raspberry Pi Imager. No runtime installer downloads these components. The main
application remains MIT licensed; each separate component keeps its own license.

| Component | Pinned version | Build / acquisition |
|---|---|---|
| rpiboot | `12fa1cdbbeab880f7c8e7e797c4ef2831c9f784e` | Built with static libusb; macOS universal, Linux x86_64 |
| libusb for rpiboot | 1.0.29 | Complete source and relinking script accompany release |
| Legacy and Linux gadget boot files | Same usbboot commit | Unmodified upstream files; see gadget provenance |
| Raspberry Pi Imager, macOS | 2.0.11.1 | Official universal application, minimum macOS 13 |
| Raspberry Pi Imager, Linux | 2.0.11 | Official desktop x86_64 AppImage, extracted during packaging |
| Qt used by Imager | 6.11.1 | Exact upstream source and upstream build scripts identified in notices |

`npm run prepare:runtime` downloads verified archives and creates the ignored
`src-tauri/resources/runtime` tree. The build uses only that tree, never host
rpiboot or Imager installations. Fresh runtime preparation verifies the pinned notice archives published with the
release. To regenerate source assets, run `python3 scripts/prepare-imager-sources.py`,
`python3 scripts/prepare-imager-linux-sources.py`, and the gadget source collection
described in its provenance manifest before distributing replacement binaries.
Generated archives belong in ignored `release/`, not Git. Include notices before
signing: editing resources afterwards invalidates the macOS bundle signature.

`npm run bundle:mac` signs the standalone rpiboot helper when
`APPLE_SIGNING_IDENTITY` is set, then builds the universal app and DMG. The nested
Imager retains Raspberry Pi Ltd's original signature. Notarize and staple the
final DMG using the existing Keychain profile; credentials never enter resources.

`npm run bundle:linux` creates the `.deb`, intermediate AppImage, and final
FUSE-free `.run` installer on the Linux host. It clears only generated AppImage
staging directories first, preventing removed Qt libraries from leaking into
later builds. The final installer step can also be run separately:

```sh
./scripts/build-linux-installer.sh \
  'src-tauri/target/release/bundle/appimage/Pi USB Boot.AppDir' \
  'release/Pi-USB-Boot_0.3.0_amd64.run'
```

The installer verifies its embedded archive, installs a private per-user copy
under the XDG data directory, adds an application-menu entry, and starts AppRun.
The installed directory remains available when Imager outlives the main window.
No FUSE mount or root installation is involved. Root approval is requested only
when accessing USB hardware or writing an image.

Use the final packaged executable's `--check-runtime` option to check actual
resource resolution, execute bundled rpiboot's version command, and verify boot
files for all three supported boot families without touching USB hardware.
This does not replace physical-board end-to-end testing.

## Source and notices

Release source assets and `runtime/licenses` contain component-specific notices,
source locations, checksums, upstream build recipes and any provenance limits.
The Imager source archive includes both exact platform source versions and all
seven vendor submodules omitted by upstream source tarballs. Qt's exact complete
source archive is available on the official server identified in the accompanying
notice; the included Imager scripts describe its configuration and patches.

The Linux gadget source bundle identifies the upstream Buildroot configuration
and matching package sources. The kernel revision recovery method is recorded
explicitly in `gadget-SOURCE-PROVENANCE.txt`; it must not be described as a
bit-for-bit reproduction of Raspberry Pi's firmware build.

Recipients may modify/relink the LGPL components and run their own rebuilt
versions; the application adds no restrictions on debugging such modifications.
On macOS a modified app can use local ad-hoc signing. Raspberry Pi branding
identifies the bundled tools' origin and does not imply endorsement.
