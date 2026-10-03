# Bundled runtime and source distribution

Pi USB Boot 0.3.1 includes its USB boot tool, firmware and a separate, unmodified
Raspberry Pi Imager. No runtime installer downloads these components. The main
application remains MIT licensed; each separate component keeps its own license.

| Component | Pinned version | Build / acquisition |
|---|---|---|
| rpiboot | `12fa1cdbbeab880f7c8e7e797c4ef2831c9f784e` | Built with static libusb; macOS universal, Linux x86_64 |
| libusb for rpiboot | 1.0.29 | Complete source and relinking script accompany release |
| Legacy MSD boot files | Same commit as rpiboot | Unmodified `msd/bootcode.bin` and `msd/start.elf` |
| Linux gadget boot files | `fe4a6288878b104ceb232ab4b8a777be6ac98ff3` | Three unmodified, checksum-pinned files; independent of the host binary |
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
  'release/Pi-USB-Boot_0.3.1_amd64.run'
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

The Linux gadget is pinned independently because the newer gadget in 0.3.0
completed the USB transfer but lacked the kernel modules needed to expose disks.
The replacement was checked on the same board and exposes its NVMe disk. The
host rpiboot executable and legacy MSD files retain their existing source pin.

`scripts/prepare-rpiboot.sh` downloads the following files directly from the
[pinned upstream gadget directory](https://github.com/raspberrypi/usbboot/tree/fe4a6288878b104ceb232ab4b8a777be6ac98ff3/mass-storage-gadget64)
and verifies each SHA-256 before copying it into the runtime:

| File | SHA-256 |
|---|---|
| `boot.img` | `ba98c962eb41270379681f78c97907890a791f281ff84bd0b98ea0fcf7fc441e` |
| `bootfiles.bin` | `344c6a2c6a9109e0d041f58bd1a65f839c4f30d8bbe6a73eabd8e894772805ad` |
| `config.txt` | `f74a9db07cd32f418e25754134840b138486e39cda2a4e536042b86c5c67b687` |

The image's root filesystem identifies Buildroot
`93c97919253c7a2caa12373b06a7d035b95e1b1d`; its Linux 6.12.49-v8 compiler banner
identifies the earlier toolchain build `ca9f386ae8`. These identify different
parts of the image. The source collection uses the root filesystem's exact
Buildroot commit and its `raspberrypi64-mass-storage-gadget_defconfig`.
The original configuration tracks `rpi-6.12.y`. The collected kernel source is
`2f4a28199c418599ba0224186e42926b482b523c`, the latest upstream branch commit
before the embedded build time, 2025-10-02 12:01:23 BST. That kernel revision is
inferred, rather than recorded in the image; this is not a claim of bit-for-bit
reproducibility. The Linux 6.18 source collection from 0.3.0 does not describe
this replacement image.

To regenerate the gadget source collection on Linux:

1. Extract the checksum-verified Buildroot archive copied into the release's
   `sources/` directory by `scripts/prepare-rpiboot.sh`.
2. Run `make raspberrypi64-mass-storage-gadget_defconfig`. In `.config`, disable
   `BR2_LINUX_KERNEL_CUSTOM_GIT`, enable `BR2_LINUX_KERNEL_CUSTOM_TARBALL`, and set
   `BR2_LINUX_KERNEL_CUSTOM_TARBALL_LOCATION` to
   `https://github.com/raspberrypi/linux/archive/2f4a28199c418599ba0224186e42926b482b523c.tar.gz`.
3. Run `make olddefconfig`, then `make source legal-info`. An existing download
   cache can be reused with `BR2_DL_DIR=/absolute/path/to/cache`. These targets
   collect sources and notices; they do not rebuild the gadget image.
4. Include the complete `output/legal-info` tree and exact Buildroot archive in
   the source asset. Add the kernel source's `COPYING` and complete `LICENSES/`
   directory to both `licenses/linux-custom` and `licenses/linux-headers-custom`,
   because Buildroot's custom-kernel metadata does not list those license files.
   Preserve the generated warnings, configuration and manifests.

The 0.3.1 collection reuses already collected package source archives and
notices only after checking that all target and host package versions and
source filenames match the older configuration. Linux and Linux headers are
the two source changes; their source archive and notices are replaced.
`gadget-SOURCE-PROVENANCE.txt` and `gadget/PI-USB-BOOT-NOTES.txt` record these limits.

Recipients may modify/relink the LGPL components and run their own rebuilt
versions; the application adds no restrictions on debugging such modifications.
On macOS a modified app can use local ad-hoc signing. Raspberry Pi branding
identifies the bundled tools' origin and does not imply endorsement.
