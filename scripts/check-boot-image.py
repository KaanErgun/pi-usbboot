#!/usr/bin/env python3
"""Read-only audit of the Linux gadget inside boot.img; no mounts or extraction.

Python 3 and the host libarchive library are build-time requirements. macOS
ships libarchive; Linux build hosts can install libarchive13/libarchive-tools.
"""
import ctypes as C
import ctypes.util
import gzip
import re
import struct
import sys
from pathlib import Path


class InvalidImage(ValueError):
    pass


class FatImage:
    """Read the FAT16/FAT32 files used by the upstream gadget image."""

    def __init__(self, data):
        self.data = data
        if len(data) < 512:
            raise InvalidImage("truncated FAT image")
        self.base = 0 if data[54:57] == b"FAT" or data[82:85] == b"FAT" else self.u32(454) * 512
        b = self.base
        self.sector = self.u16(b + 11)
        self.cluster = data[b + 13] * self.sector
        reserved, fats, roots = self.u16(b + 14), data[b + 16], self.u16(b + 17)
        fat16 = self.u16(b + 22)
        self.bits = 16 if fat16 else 32
        fat_sectors = fat16 or self.u32(b + 36)
        if self.sector not in (512, 1024, 2048, 4096) or not self.cluster or not fats or not reserved:
            raise InvalidImage("unsupported FAT boot image")
        self.fat = b + reserved * self.sector
        self.root = b + (reserved + fats * fat_sectors) * self.sector
        self.root_size = ((roots * 32 + self.sector - 1) // self.sector) * self.sector
        self.start = self.root + self.root_size
        self.root_cluster = self.u32(b + 44) if self.bits == 32 else 0

    def u16(self, offset):
        return struct.unpack_from("<H", self.data, offset)[0]

    def u32(self, offset):
        return struct.unpack_from("<I", self.data, offset)[0]

    def chain(self, cluster):
        seen, chunks = set(), []
        end = 0xFFF8 if self.bits == 16 else 0xFFFFFF8
        while cluster < end:
            if cluster < 2 or cluster in seen:
                raise InvalidImage("invalid or cyclic FAT cluster chain")
            seen.add(cluster)
            offset = self.start + (cluster - 2) * self.cluster
            if offset + self.cluster > len(self.data):
                raise InvalidImage("FAT cluster outside boot image")
            chunks.append(self.data[offset:offset + self.cluster])
            cluster = (self.u16(self.fat + cluster * 2) if self.bits == 16
                       else self.u32(self.fat + cluster * 4) & 0xFFFFFFF)
        return b"".join(chunks)

    def read(self, name):
        parts = name.replace("\\", "/").strip("/").split("/")
        if any(p in ("", ".", "..") for p in parts):
            raise InvalidImage("invalid boot file path")
        directory = (self.chain(self.root_cluster) if self.bits == 32
                     else self.data[self.root:self.root + self.root_size])
        for depth, part in enumerate(parts):
            long_name, found = {}, None
            for offset in range(0, len(directory), 32):
                entry = directory[offset:offset + 32]
                if not entry or entry[0] == 0:
                    break
                if entry[0] == 0xE5:
                    long_name = {}
                    continue
                if entry[11] == 0x0F:
                    chars = entry[1:11] + entry[14:26] + entry[28:32]
                    long_name[entry[0] & 31] = chars.decode("utf-16le").rstrip("\x00\uffff")
                    continue
                short = entry[:8].decode("ascii", "replace").rstrip()
                extension = entry[8:11].decode("ascii", "replace").rstrip()
                filename = "".join(long_name[k] for k in sorted(long_name)) if long_name else short + ("." + extension if extension else "")
                long_name = {}
                if filename.casefold() == part.casefold():
                    found = entry
                    break
            if found is None:
                raise InvalidImage("boot image is missing " + name)
            cluster = struct.unpack_from("<H", found, 26)[0]
            if self.bits == 32:
                cluster |= struct.unpack_from("<H", found, 20)[0] << 16
            content = self.chain(cluster) if cluster else b""
            if depth == len(parts) - 1:
                size = struct.unpack_from("<I", found, 28)[0]
                if found[11] & 0x10 or size > len(content):
                    raise InvalidImage("incomplete boot file " + name)
                return content[:size]
            if not found[11] & 0x10:
                raise InvalidImage("boot path is not a directory")
            directory = content
        raise InvalidImage("empty boot path")


def archive_members(data, wanted):
    """Return selected uncompressed archive members via the host libarchive."""
    name = ctypes.util.find_library("archive")
    if not name:
        raise InvalidImage("libarchive is required to validate boot.img on this build host")
    lib = C.CDLL(name)
    signatures = {
        "archive_read_new": (C.c_void_p, []),
        "archive_read_support_filter_all": (C.c_int, [C.c_void_p]),
        "archive_read_support_format_all": (C.c_int, [C.c_void_p]),
        "archive_read_support_format_raw": (C.c_int, [C.c_void_p]),
        "archive_read_open_memory": (C.c_int, [C.c_void_p, C.c_void_p, C.c_size_t]),
        "archive_read_next_header": (C.c_int, [C.c_void_p, C.POINTER(C.c_void_p)]),
        "archive_entry_pathname": (C.c_char_p, [C.c_void_p]),
        "archive_read_data": (C.c_ssize_t, [C.c_void_p, C.c_void_p, C.c_size_t]),
        "archive_read_data_skip": (C.c_int, [C.c_void_p]),
        "archive_error_string": (C.c_char_p, [C.c_void_p]),
        "archive_read_free": (C.c_int, [C.c_void_p]),
    }
    for func, (restype, argtypes) in signatures.items():
        getattr(lib, func).restype, getattr(lib, func).argtypes = restype, argtypes
    reader = lib.archive_read_new()
    source = C.create_string_buffer(data)
    block = C.create_string_buffer(65536)
    result = {}
    def checked(value):
        if value < 0:
            detail = lib.archive_error_string(reader)
            raise InvalidImage((detail or b"invalid compressed archive").decode(errors="replace"))
        return value
    try:
        checked(lib.archive_read_support_filter_all(reader))
        checked(lib.archive_read_support_format_all(reader))
        checked(lib.archive_read_support_format_raw(reader))
        checked(lib.archive_read_open_memory(reader, source, len(data)))
        entry = C.c_void_p()
        while True:
            code = checked(lib.archive_read_next_header(reader, C.byref(entry)))
            if code == 1:
                break
            path = lib.archive_entry_pathname(entry).decode(errors="replace").removeprefix("./")
            if wanted(path):
                chunks, size = [], 0
                while True:
                    count = checked(lib.archive_read_data(reader, block, len(block)))
                    if count == 0:
                        break
                    size += count
                    if size > 128 * 1024 * 1024:
                        raise InvalidImage("unexpectedly large firmware archive member")
                    chunks.append(block.raw[:count])
                result[path] = b"".join(chunks)
            else:
                checked(lib.archive_read_data_skip(reader))
        return result
    finally:
        lib.archive_read_free(reader)


DRIVERS = {
    "dwc2": "CONFIG_USB_DWC2",
    "libcomposite": "CONFIG_USB_LIBCOMPOSITE",
    "usb_f_mass_storage": "CONFIG_USB_F_MASS_STORAGE",
}
MODULE = re.compile(r"(?:^|/)lib/modules/([^/]+)/.*(?:/|^)(dwc2|libcomposite|usb_f_mass_storage)\.ko(?:\.(?:xz|gz|zst))?$")


def kernel_config(kernel):
    start, end = kernel.find(b"IKCFG_ST"), kernel.find(b"IKCFG_ED")
    if start < 0 or end <= start:
        return ""
    try:
        return gzip.decompress(kernel[start + 8:end]).decode()
    except (OSError, EOFError, UnicodeError) as error:
        raise InvalidImage("invalid embedded kernel configuration") from error


def check_drivers(kernel, members):
    banner = re.search(rb"Linux version ([^\s\x00]+)", kernel)
    if not banner:
        raise InvalidImage("cannot identify gadget kernel release")
    release = banner.group(1).decode()
    config = kernel_config(kernel)
    builtins = set()
    for path, data in members.items():
        if path in (f"lib/modules/{release}/modules.builtin", f"usr/lib/modules/{release}/modules.builtin"):
            builtins.update(Path(line).name.removesuffix(".ko") for line in data.decode().splitlines())
    evidence = {}
    for driver, option in DRIVERS.items():
        if re.search(r"^" + option + r"=y$", config, re.M) or driver in builtins:
            evidence[driver] = "built-in"
            continue
        for path, data in members.items():
            match = MODULE.search(path)
            if not match or match.groups() != (release, driver):
                continue
            if not path.endswith(".ko"):
                decoded = archive_members(data, lambda _: True)
                data = next(iter(decoded.values()), b"")
            vermagic = re.search(rb"(?:^|\x00)vermagic=([^\s\x00]+)", data)
            if data.startswith(b"\x7fELF") and vermagic and vermagic.group(1).decode() == release:
                evidence[driver] = "matching module"
                break
    missing = sorted(set(DRIVERS) - evidence.keys())
    if missing:
        raise InvalidImage(f"kernel {release}: no matching module or built-in evidence for {', '.join(missing)}; do not ship this boot.img")
    return release, evidence


def check_image(path):
    image = FatImage(Path(path).read_bytes())
    config = image.read("config.txt").decode()
    kernels = re.findall(r"^\s*kernel\s*=\s*([^\s#]+)", config, re.M) or ["kernel8.img"]
    initramfs = re.findall(r"^\s*initramfs\s+([^\s#]+)", config, re.M)
    if len(set(initramfs)) != 1:
        raise InvalidImage("expected one explicit initramfs in boot.img/config.txt")
    members = archive_members(image.read(initramfs[0]), lambda p: bool(MODULE.search(p)) or p.endswith("/modules.builtin"))
    results = []
    for name in dict.fromkeys(kernels):
        kernel = image.read(name)
        if kernel.startswith(b"\x1f\x8b"):
            kernel = gzip.decompress(kernel)
        results.append(check_drivers(kernel, members))
    return results


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: check-boot-image.py BOOT.IMG")
    try:
        for release, evidence in check_image(sys.argv[1]):
            print(f"Gadget kernel {release}: " + ", ".join(f"{k} ({v})" for k, v in evidence.items()))
    except (InvalidImage, OSError, ValueError, IndexError, struct.error) as error:
        print(f"Firmware validation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
