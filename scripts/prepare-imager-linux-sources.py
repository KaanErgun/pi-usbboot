#!/usr/bin/env python3
"""Preserve exact Debian library sources and notices for the official Imager AppImage."""

from __future__ import annotations

import argparse
import concurrent.futures
import gzip
import hashlib
import json
import re
import shutil
import tarfile
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
# Exact source versions corresponding to the libraries copied into Imager 2.0.11.
# Descriptors pin the hashes of every original and Debian packaging archive.
PACKAGES = (
    ("brotli", "1.0.9-2", "b/brotli", "8c4c86748ec9770e08b60233d658593650444b04a452dc5b607ed5b5537b683e"),
    ("libffi", "3.4.4-1", "libf/libffi", "21c9ef156b6766535cb014e0765142c8104ffbcd73f003ecfa80cfb314baa4f0"),
    ("gmp", "6.2.1+dfsg1-1.1", "g/gmp", "2831ed4f83bc3304c2403474b335652ab2dc507cd517de44414d9142171748f0"),
    ("gnutls28", "3.7.9-2+deb12u7", "g/gnutls28", "027b2f60e38add78ee611d099dbf34e977a6600d446cc39673534b736a182cb6"),
    ("nettle", "3.8.1-2", "n/nettle", "a437e204da67612efb656cab354835f358b44c077c5c0a46d6e8c30b5c0bddff"),
    ("libidn2", "2.3.3-1", "libi/libidn2", "13865e96a0fed8dcb82767db65c946b56ed44fc1806d80d407c512ded2a83984"),
    ("p11-kit", "0.24.1-2", "p/p11-kit", "b88a483cb9afd5556ea4ac64d5df4543123a53bf0e50d1c01454887220259a89"),
    ("pcre2", "10.42-1", "p/pcre2", "726dafe7a8d07332d4df61edf23f384ddb158b2b263846273d1103b6b9a7c176"),
    ("libtasn1-6", "4.19.0-2+deb12u1", "libt/libtasn1-6", "54eabe8526f590a52771d99ce8c592d3edd549e98d84ea6649db473d528cc6ec"),
    ("libunistring", "1.0-2", "libu/libunistring", "9b9a9d9d4cd1c2118df8cf5ca0dfb787d89afcd99400d7cd01b4c4e9b0bc1ae5"),
    ("liburing", "2.3-3", "libu/liburing", "1eefd4e81c0c3c767ccc95adcb6a37d184418ea127dd9e8b68624ae911f2f66d"),
    ("libzstd", "1.5.4+dfsg2-5", "libz/libzstd", "8f602f92b575aa8b5e979196fb6ee82d78f233521dc9636526d3ecba1f63c1b1"),
    ("zlib", "1.2.13.dfsg-1", "z/zlib", "3fa1e6b2fc525062aa88207dda52fed8e045373c809d362fe8a2bfbf7cf515a8"),
    ("glib2.0", "2.74.6-2+deb12u9", "g/glib2.0", "bd8e8cd8d251c2365a02258bf4d6c44721289ac44c3a2477c140ce253bdb4b41"),
    ("double-conversion", "3.2.1-1", "d/double-conversion", "b1f8bf054b5c99b57a6b5320d49ffdc749ecc3c61cbbc1efc8daa0341bb6a884"),
    ("libjpeg-turbo", "2.1.5-2", "libj/libjpeg-turbo", "d718ead0dfbcbc8523665c02a7f7152e31039ded641d022868722623bb3b486d"),
    ("libpng1.6", "1.6.39-2+deb12u5", "libp/libpng1.6", "7b86211030a34deb6b0a2cd7e1d9db0fe92443fd30cab537fb89b1e7f7c9f188"),
)
BUILD_IDS = {
    "libbrotlicommon.so.1": ("brotli", "1a5835e993c63c2c099a561000188b190df888b1"),
    "libbrotlidec.so.1": ("brotli", "aea63b8bb900dbac1ff7501df51440d224bf5be3"),
    "libdouble-conversion.so.3": ("double-conversion", "c1e78e20543b5faabe79378026d893c59703e7ef"),
    "libffi.so.8": ("libffi", "4b5ef0d8f602b880c279f15ed3b07bf6686ea09b"),
    "libglib-2.0.so.0": ("glib2.0", "edd2644598e8e0c7656687c30a7daede5f4b6e6d"),
    "libgmp.so.10": ("gmp", "0c00b6d88e6ba3d5177fdae0bd46d8b9d007dc59"),
    "libgnutls.so.30": ("gnutls28", "2a74c5f0802dbaa1d0b0139c5fe0502c9bc6001a"),
    "libhogweed.so.6": ("nettle", "568595f2db0c8a2a59fc8aeb153db78ca51d0168"),
    "libidn2.so.0": ("libidn2", "ddba28970641f1f110f7585d57dc5867e2ee4ffd"),
    "libjpeg.so.62": ("libjpeg-turbo", "75b71ddb85234be3659c097f2561a765b45993bd"),
    "libnettle.so.8": ("nettle", "df9d509c9055db57df09603aab0fc4c66ad2837c"),
    "libp11-kit.so.0": ("p11-kit", "95e3b240efb89892bdff70a5ce483d088c5020b9"),
    "libpcre2-16.so.0": ("pcre2", "98e0460418b01e23da5e4837b601b8cf8b142b04"),
    "libpcre2-8.so.0": ("pcre2", "fbc37bf891c814600cbe68abb040c56b949f321e"),
    "libpng16.so.16": ("libpng1.6", "8385e45a3034521da48c6ba61f60b86ace6bcb7e"),
    "libtasn1.so.6": ("libtasn1-6", "a560c4e27669c957c7ae0efdb8a03e04bb1c2c22"),
    "libunistring.so.2": ("libunistring", "926062d8c8d5bfcbfaf7bad9b41cf4f073ee521e"),
    "liburing.so.2": ("liburing", "e58b26e09cc13f1f3bec3f79bb64163337049492"),
    "libz.so.1": ("zlib", "1f95d5498d283b79505861523e20b3db2afdf518"),
    "libzstd.so.1": ("libzstd", "d662b4158d7eac9a97404296d0a32a0e812a9f67"),
}


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def fetch(url: str, destination: Path, expected: str) -> dict:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not destination.exists():
        temporary = destination.with_name(destination.name + ".part")
        with urllib.request.urlopen(url, timeout=180) as response, temporary.open("wb") as output:
            shutil.copyfileobj(response, output)
        temporary.replace(destination)
    if digest(destination) != expected:
        raise SystemExit(f"SHA256 mismatch: {destination.name}")
    return {"file": destination.name, "url": url, "sha256": expected}


def prepare(package: tuple, cache: Path, notices: Path) -> dict:
    name, version, pool, expected = package
    base = f"https://deb.debian.org/debian/pool/main/{pool}/"
    descriptor = f"{name}_{version}.dsc"
    files = [fetch(base + descriptor, cache / descriptor, expected)]
    text = (cache / descriptor).read_text()
    section = text.split("Checksums-Sha256:\n", 1)[1].split("\nFiles:", 1)[0]
    for line in section.splitlines():
        checksum, size, filename = line.split()
        if not re.fullmatch(r"[0-9a-f]{64}", checksum) or Path(filename).name != filename:
            raise SystemExit(f"Invalid source descriptor: {descriptor}")
        files.append(fetch(base + filename, cache / filename, checksum))
        if (cache / filename).stat().st_size != int(size):
            raise SystemExit(f"Size mismatch: {filename}")
    output = notices / name / "copyright"
    output.parent.mkdir(parents=True, exist_ok=True)
    packaging = next((row for row in files if ".debian.tar." in row["file"]), None)
    if packaging:
        with tarfile.open(cache / packaging["file"]) as archive:
            member = next(item for item in archive.getmembers() if item.name.lstrip("./") == "debian/copyright")
            if not member.isfile():
                raise SystemExit(f"Missing copyright file: {name}")
            output.write_bytes(archive.extractfile(member).read())
    else:
        # PCRE2 uses Debian source format 1.0, adding copyright as a new file.
        patch = next(row for row in files if row["file"].endswith(".diff.gz"))
        with gzip.open(cache / patch["file"], "rt") as stream:
            text = stream.read()
        section = re.search(r"^\+\+\+ [^\n]+/debian/copyright\n@@ -0,0 \+1,(\d+) @@\n(.*?)(?=^--- |\Z)", text, re.MULTILINE | re.DOTALL)
        if not section or any(not line.startswith("+") for line in section[2].splitlines()):
            raise SystemExit(f"Unsupported copyright patch: {name}")
        lines = section[2].splitlines()
        if len(lines) != int(section[1]):
            raise SystemExit(f"Incomplete copyright patch: {name}")
        output.write_text("\n".join(line[1:] for line in lines) + "\n")
    print(f"Verified source and copyright: {name} {version}", flush=True)
    return {"source": name, "version": version, "files": files}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release-dir", type=Path, default=ROOT / "release/v0.3.0")
    parser.add_argument("--notices-dir", type=Path, default=ROOT / "src-tauri/resources/runtime/licenses/imager-linux-system")
    parser.add_argument("--common-licenses-dir", type=Path, help="Debian /usr/share/common-licenses (copied with symlinks dereferenced on non-Linux hosts)")
    args = parser.parse_args()
    cache = args.release_dir / "imager-debian-source"
    notices = args.notices_dir
    common = args.common_licenses_dir or (cache / "common-licenses")
    if not common.exists():
        common = Path("/usr/share/common-licenses")
    required = ("GPL-2", "GPL-3", "LGPL-2.1", "LGPL-3", "Apache-2.0", "BSD", "Artistic")
    if not all((common / filename).is_file() for filename in required):
        raise SystemExit("Provide Debian common license texts with --common-licenses-dir")
    notices.mkdir(parents=True, exist_ok=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        packages = list(pool.map(lambda package: prepare(package, cache, notices), PACKAGES))
    buildinfo_name = "rpi-imager_2.0.11-1_amd64.buildinfo"
    buildinfo = fetch(
        "https://github.com/raspberrypi/rpi-imager/releases/download/v2.0.11/" + buildinfo_name,
        cache / buildinfo_name,
        "072f1bc231733cbd13d4d3123a4ce81c7014a75377b6eb9e2efcd55b5b4c5416",
    )
    shutil.copytree(common, notices / "common-licenses", dirs_exist_ok=True)
    manifest = {
        "imager_version": "2.0.11", "platform": "Linux x86_64",
        "binary_url": "https://github.com/raspberrypi/rpi-imager/releases/download/v2.0.11/Raspberry_Pi_Imager-v2.0.11-desktop-x86_64.AppImage",
        "binary_sha256": "d7338d88440c04f8114d2a5cb526e5ba604250b78b267c3bb2f58b1df04cbda7",
        "library_build_ids": {name: {"source": row[0], "elf_build_id": row[1]} for name, row in BUILD_IDS.items()},
        "packages": packages,
        "official_buildinfo": buildinfo,
        "common_license_sha256": {path.name: digest(path) for path in sorted(common.iterdir()) if path.is_file()},
    }
    (notices / "SOURCE-MANIFEST.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (notices / "README.txt").write_text("""Linux libraries bundled with Raspberry Pi Imager 2.0.11

The unmodified official Imager AppImage includes the 20 non-Qt libraries listed
in SOURCE-MANIFEST.json. Their 17 exact Debian source packages and complete
Debian packaging are supplied beside Pi USB Boot installers in:

  Pi-USB-Boot_0.3.0_imager-linux-library-sources.tar.gz
  https://github.com/KaanErgun/pi-usbboot/releases/tag/v0.3.0

Each package directory here contains its Debian copyright/license inventory.
Full Debian common license texts referenced by those inventories are included
in common-licenses/. The source archives also preserve original license texts.
These components retain their own copyright and license conditions; no
additional restriction on modification, reverse engineering for debugging
such modifications, or replacement of LGPL libraries is imposed by Pi USB Boot.

Source versions were identified from the official release buildinfo (Debian
bookworm build), with ELF build-ID matches against official Debian binaries
for glib2.0, double-conversion, libjpeg-turbo, and libpng1.6. Debian binary-only
rebuild suffixes and epochs do not change source filenames.

To inspect or rebuild a library, install Debian source-build tools, then run:
  dpkg-source -x sources/PACKAGE_VERSION.dsc
  cd PACKAGE-VERSION
  dpkg-buildpackage -b -uc -us
Use Debian bookworm and the build dependencies specified in debian/control.
Every original source part, Debian patch, and build rule referenced by each
.dsc is included. SHA256 values and original source URLs are in the manifest.

Imager itself, its static vendor libraries, and Qt notices/source access are
covered by the separate imager/ notice directory and Imager source asset.
The extracted Imager AppDir loads its shared libraries from usr/lib; a modified
copy can replace those libraries and launch via that AppDir's AppRun.
""")
    asset = args.release_dir / "Pi-USB-Boot_0.3.0_imager-linux-library-sources.tar.gz"
    members = [(notices, "imager-linux-library-sources/notices")]
    members.append((cache / buildinfo_name, "imager-linux-library-sources/" + buildinfo_name))
    members.extend((cache / row["file"], "imager-linux-library-sources/sources/" + row["file"])
                   for package in packages for row in package["files"])
    def normalize(info: tarfile.TarInfo) -> tarfile.TarInfo:
        info.uid = info.gid = info.mtime = 0
        info.uname = info.gname = ""
        return info
    with asset.open("wb") as output, gzip.GzipFile(filename="", fileobj=output, mode="wb", mtime=0) as zipped:
        with tarfile.open(fileobj=zipped, mode="w") as archive:
            for path, name in members:
                archive.add(path, arcname=name, filter=normalize)
    print(f"{asset.name}: {asset.stat().st_size} bytes; SHA256 {digest(asset)}")


if __name__ == "__main__":
    main()
