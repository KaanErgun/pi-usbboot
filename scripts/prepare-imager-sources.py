#!/usr/bin/env python3
"""Prepare matching Imager source, notices, and reproducible upstream provenance."""

from __future__ import annotations

import argparse
import concurrent.futures
import gzip
import hashlib
import json
import shutil
import tarfile
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VERSIONS = {
    "2.0.11": {
        "orig": "9659a3993d99e1b53a06b9b6d9242e0d5b930f3709d451d4aa52df404c6b2c78",
        "debian": "3e73d1f2c07044064efb808d507e43c31d60af9e24182b53ef26e612b077597b",
        "platform": "Linux x86_64",
    },
    "2.0.11.1": {
        "orig": "43ed8217573c4aea09f42637f8f244a6fda6b5ab818eaa83dead3014a846010d",
        "debian": "992584491be64f6114ce8bbbc0680c725564de58d87a51311149f0c1032c291a",
        "platform": "macOS universal",
    },
}
# These gitlinks are identical in both release tags. The GitHub-generated
# original source archives do not contain these submodule contents.
VENDORS = {
    "curl": ("curl/curl", "a05f34973e6c4bb629d018f7cb51487be1c904d8", "8.20.0"),
    "libarchive": ("libarchive/libarchive", "ded82291ab41d5e355831b96b0e1ff49e24d8939", "3.8.7"),
    "libusb": ("libusb/libusb", "87a55632db62c9bdc58cd31d3ccfa673f1bb017f", "1.0.30"),
    "nghttp2": ("nghttp2/nghttp2", "68cb6900fde14c77f0cd7add0e094a862960eb99", "1.69.0"),
    "xz": ("tukaani-project/xz", "4b73f2ec19a99ef465282fbce633e8deb33691b3", "5.8.3"),
    "zlib": ("madler/zlib", "da607da739fa6047df13e66a2af6b8bec7c2a498", "1.3.2"),
    "zstd": ("facebook/zstd", "f8745da6ff1ad1e7bab384bd1f9d742439278e99", "1.5.7"),
}
VENDOR_SHA256 = {
    "curl": "02ef3b8c8ea32231b42fd707b1443472f0041fd97cc2c3a17d1bed7b61aaa1b1",
    "libarchive": "042f0efe7147063ff9ba10f1a38ed080e949bcbd04bdbf3592b8846dd11b1da2",
    "libusb": "26733c3eee2475c062e14f80a62ece4b33ee3b33fc0c88b2758964412a42b7e0",
    "nghttp2": "3f042e5284ad349f837b65dd5be953b34c007a05259119092dbe6ebeaa73d306",
    "xz": "de536250ae287bd6cdac94e72bab680a1e2219df7e07e27c376670f9cd15dc87",
    "zlib": "b9258cf6254e7f7c37f1cd61dba943a1c5ea3cff5718c789834dac359094f5f7",
    "zstd": "4b0bd1f0cfb25e61b9103c35f27395530ff5b4c0d2513a00fd745849e85ea52c",
}
QT_LICENSE_SHA256 = {
    "GPL-3.0-only": "8ceb4b9ee5adedde47b31e975c1d90c73ad27b6b165a1dcd80c7c545eb65b903",
    "LGPL-3.0-only": "da7eabb7bafdf7d3ae5e9f223aa5bdc1eece45ac569dc21b3b037520b4464768",
}
QT_SOURCE = "https://download.qt.io/official_releases/qt/6.11/6.11.1/single/qt-everywhere-src-6.11.1.tar.xz"
QT_MODULES = (
    "qtbase", "qtdeclarative", "qtsvg", "qtquicktimeline", "qtnetworkauth",
    "qtcanvaspainter", "qttasktree", "qtshadertools", "qtwayland", "qtimageformats",
)


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def fetch(url: str, destination: Path, expected: str | None = None) -> dict:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not destination.exists():
        temporary = destination.with_name(destination.name + ".part")
        request = urllib.request.Request(url, headers={"User-Agent": "Pi-USB-Boot-source-preparation"})
        with urllib.request.urlopen(request, timeout=180) as response, temporary.open("wb") as output:
            shutil.copyfileobj(response, output)
        temporary.replace(destination)
    actual = digest(destination)
    if expected and actual != expected:
        raise SystemExit(f"SHA256 mismatch: {destination.name}")
    return {"file": destination.name, "url": url, "sha256": actual}


def extract(archive: Path, destination: Path) -> Path:
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as source:
        members = source.getmembers()
        roots = {Path(member.name).parts[0] for member in members if Path(member.name).parts}
        if len(roots) != 1:
            raise SystemExit(f"Expected a single source directory in {archive}")
        source.extractall(destination, filter="data")
    return destination / roots.pop()


def add_normalized(archive: tarfile.TarFile, source: Path, name: str) -> None:
    def normalize(info: tarfile.TarInfo) -> tarfile.TarInfo:
        info.uid = info.gid = 0
        info.uname = info.gname = ""
        info.mtime = 0
        return info

    archive.add(source, arcname=name, filter=normalize)


def collect_qt_notices(cache: Path, destination: Path) -> dict:
    """Preserve Qt module license texts, REUSE copyright and third-party notices."""
    metadata = cache / "qt-6.11.1-modules.json"
    fetch("https://api.github.com/repos/qt/qt5/git/trees/v6.11.1", metadata)
    gitlinks = {entry["path"]: entry["sha"] for entry in json.loads(metadata.read_text())["tree"] if entry["type"] == "commit"}
    modules = {}
    module_tree_paths = {}
    jobs = []
    for module in QT_MODULES:
        commit = gitlinks[module]
        tree_file = cache / f"{module}-{commit}-tree.json"
        fetch(f"https://api.github.com/repos/qt/{module}/git/trees/{commit}?recursive=1", tree_file)
        tree = json.loads(tree_file.read_text())
        if tree.get("truncated"):
            raise SystemExit(f"Incomplete Qt file inventory: {module}")
        module_tree_paths[module] = {entry["path"] for entry in tree["tree"] if entry["type"] == "blob"}
        module_files = []
        for item in tree["tree"]:
            path = Path(item["path"])
            lower = path.name.lower()
            if item["type"] != "blob":
                continue
            notice = (path.parts[0] == "LICENSES" or str(path) == ".reuse/dep5"
                      or lower.startswith(("license", "licence", "copying", "copyright", "notice"))
                      or lower.endswith("attribution.json")
                      or ("3rdparty" in path.parts and lower.startswith(("readme", "authors"))))
            if notice:
                url = f"https://raw.githubusercontent.com/qt/{module}/{commit}/{path.as_posix()}"
                jobs.append((url, destination / module / path, None))
                module_files.append(path.as_posix())
        modules[module] = {"commit": commit, "notice_files": module_files}
    downloads = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
        for item in pool.map(lambda job: fetch(*job), jobs):
            downloads.append(item)
    # Attribution files can name nonstandard license filenames, such as
    # BDF-LICENSE.txt or ../../MIT_LICENSE.txt. Preserve those exact targets too.
    additional = {}
    initial_targets = {str(job[1].resolve()) for job in jobs}
    for module, metadata in modules.items():
        module_root = (destination / module).resolve()
        for attribution in sorted(module_root.rglob("*attribution.json")):
            # Upstream attribution records sometimes contain literal newlines
            # inside copyright strings; preserve them when parsing metadata.
            records = json.loads(attribution.read_text(), strict=False)
            for record in records if isinstance(records, list) else [records]:
                filenames = record.get("LicenseFile", [])
                if isinstance(filenames, str):
                    filenames = [filenames]
                for filename in filenames:
                    target = (attribution.parent / filename).resolve()
                    relative = target.relative_to(module_root).as_posix()
                    if relative not in module_tree_paths[module]:
                        raise SystemExit(f"Missing referenced Qt license: {module}/{relative}")
                    if str(target) in initial_targets:
                        continue
                    url = f"https://raw.githubusercontent.com/qt/{module}/{metadata['commit']}/{relative}"
                    additional[str(target)] = (url, target, None)
                    if relative not in metadata["notice_files"]:
                        metadata["notice_files"].append(relative)
    with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
        downloads.extend(pool.map(lambda job: fetch(*job), additional.values()))
    print(f"Preserved {len(downloads)} Qt license and attribution files", flush=True)
    return {"modules": modules, "files": downloads}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release-dir", type=Path, default=ROOT / "release/v0.3.0")
    parser.add_argument("--notices-dir", type=Path, default=ROOT / "src-tauri/resources/runtime/licenses")
    parser.add_argument("--download-qt", action="store_true", help="Also mirror the 971 MiB Qt source archive beside the source package")
    args = parser.parse_args()
    release = args.release_dir.resolve()
    cache = release / "imager-downloads"
    prepared = release / "imager-source-work"
    prepared.mkdir(parents=True, exist_ok=True)
    licenses = args.notices_dir.resolve() / "imager"
    licenses.mkdir(parents=True, exist_ok=True)
    downloads = []
    jobs = []
    for version, metadata in VERSIONS.items():
        base = f"https://github.com/raspberrypi/rpi-imager/releases/download/v{version}/"
        for kind, suffix in (("orig", ".orig.tar.xz"), ("debian", "-1.debian.tar.xz")):
            filename = f"rpi-imager_{version}{suffix}"
            jobs.append((base + filename, cache / filename, metadata[kind]))
    for name, (repository, commit, _) in VENDORS.items():
        jobs.append((f"https://codeload.github.com/{repository}/tar.gz/{commit}", cache / f"{name}-{commit}.tar.gz", VENDOR_SHA256[name]))
    for license_name in ("GPL-3.0-only", "LGPL-3.0-only"):
        jobs.append((f"https://raw.githubusercontent.com/qt/qtbase/v6.11.1/LICENSES/{license_name}.txt", licenses / f"{license_name}.txt", QT_LICENSE_SHA256[license_name]))
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        futures = [pool.submit(fetch, *job) for job in jobs]
        for future in futures:
            item = future.result()
            downloads.append(item)
            print(f"Verified {item['file']}: {item['sha256']}", flush=True)

    source_roots = []
    for version in VERSIONS:
        source = extract(cache / f"rpi-imager_{version}.orig.tar.xz", prepared)
        with tarfile.open(cache / f"rpi-imager_{version}-1.debian.tar.xz") as packaging:
            packaging.extractall(source, filter="data")
        shutil.copy2(source / "license.txt", licenses / f"rpi-imager-{version}-license.txt")
        source_roots.append(source)

    for name, (_, commit, _) in VENDORS.items():
        vendor = extract(cache / f"{name}-{commit}.tar.gz", prepared / "vendor")
        for source in source_roots:
            shutil.copytree(vendor, source / "src/dependencies/vendor" / name, dirs_exist_ok=True)
        notice_dir = licenses / name
        notice_dir.mkdir(exist_ok=True)
        for path in vendor.iterdir():
            if path.is_file() and path.name.lower().startswith(("copying", "copyright", "license", "authors", "notice")):
                shutil.copy2(path, notice_dir / path.name)

    qt_notices = collect_qt_notices(cache, licenses / "qt-6.11.1")

    qt = {
        "version": "6.11.1",
        "source_url": QT_SOURCE,
        "license": "LGPL-3.0 for core modules; GPL-3.0 for modules including Quick Timeline, Network Authorization and Canvas Painter. See module LICENSES and attribution files.",
        "notices": qt_notices,
        "build_scripts": "rpi-imager-*/qt/ (includes platform configuration, module exclusions and patches)",
        "distribution": "Equivalent source access from the upstream server; mirror with --download-qt if needed.",
    }
    if args.download_qt:
        qt["mirror"] = fetch(QT_SOURCE, release / "qt-everywhere-src-6.11.1.tar.xz")
    manifest = {
        "imager_versions": VERSIONS,
        "downloads": downloads,
        "vendors": {name: {"repository": repo, "commit": sha, "version": version} for name, (repo, sha, version) in VENDORS.items()},
        "qt": qt,
    }
    manifest_path = prepared / "IMAGER-SOURCES.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    instructions = prepared / "IMAGER-SOURCES.txt"
    instructions.write_text(f"""Raspberry Pi Imager: source and third-party notices

Pi USB Boot bundles the unmodified official Raspberry Pi Imager application as
a separate executable: 2.0.11.1 on macOS and 2.0.11 on Linux. Imager's own code is
Apache-2.0. Qt core libraries use LGPL-3.0; Qt modules including Quick Timeline,
Network Authorization and Canvas Painter use GPL-3.0. The statically linked
libusb uses LGPL-2.1-or-later. Module-specific Qt licenses and third-party
copyright/attribution files are included in qt-6.11.1/. These licenses permit
modification, rebuilding and relinking.
This project imposes no restriction on reverse engineering for debugging such
modifications. Copyright and license texts accompany this file.

Matching source package: Pi-USB-Boot_0.3.0_imager-sources.tar.gz
The two source trees include all seven pinned vendor submodules, the official
Debian packaging, Qt build scripts, module configuration and patches. They can
be built with a modified libusb or modified compatible Qt. Follow each tree's
CONTRIBUTING.md, doc/linux-build.md, and qt/README-qt-build*.md. Source downloads
and SHA256 digests are recorded in IMAGER-SOURCES.json. Build dependencies named
by those documents must be installed on the build host.

Qt 6.11.1 complete corresponding source is available without charge at:
{QT_SOURCE}
This is the upstream source archive used by the matching Imager build scripts.
It includes the Qt submodules and their third-party notices. This separate
source server is identified under GPLv3 section 6(d), incorporated by LGPLv3.
The binary distributor remains responsible for keeping equivalent access
available. To mirror it alongside the release, run this preparation script with
--download-qt, then publish qt-everywhere-src-6.11.1.tar.xz with the other assets.

After building a replacement Imager, run it directly or replace the bundled
application in a writable copy of Pi USB Boot. On macOS modified applications
can be signed locally with an ad-hoc signature; the original publisher's
Developer ID is not needed to rebuild or run your own modified version. On
Linux the AppImage can be extracted with --appimage-extract, changed and run
through its AppRun. The official Imager code/signing scripts are included.

libarchive, libcurl, zlib, xz/liblzma, zstd, nghttp2 and yescrypt retain their own
licenses, copied from the pinned source trees and Imager's combined license.
Raspberry Pi names identify the origin of the bundled program; this project
does not claim Raspberry Pi endorsement.
""")
    shutil.copy2(instructions, licenses / instructions.name)
    shutil.copy2(manifest_path, licenses / manifest_path.name)
    asset = release / "Pi-USB-Boot_0.3.0_imager-sources.tar.gz"
    with asset.open("wb") as output, gzip.GzipFile(filename="", mode="wb", fileobj=output, mtime=0) as compressed, tarfile.open(fileobj=compressed, mode="w") as archive:
        for source in source_roots:
            add_normalized(archive, source, source.name)
        add_normalized(archive, licenses, "licenses")
        add_normalized(archive, instructions, instructions.name)
        add_normalized(archive, manifest_path, manifest_path.name)
    checksum = digest(asset)
    asset.with_name(asset.name + ".sha256").write_text(f"{checksum}  {asset.name}\n")
    print(f"Prepared {asset} ({asset.stat().st_size} bytes), SHA256 {checksum}")


if __name__ == "__main__":
    main()
