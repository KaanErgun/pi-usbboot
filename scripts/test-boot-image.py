#!/usr/bin/env python3
"""Firmware integrity cases; no device, elevation, or installed payload needed."""
import gzip
import importlib.util
import sys
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("boot_image", Path(__file__).with_name("check-boot-image.py"))
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)
RELEASE = "6.12.49-v8"
KERNEL = b"Linux version 6.12.49-v8 (test compiler)\x00"


def module_files(release=RELEASE, vermagic=RELEASE):
    return {f"usr/lib/modules/{release}/kernel/drivers/usb/{driver}.ko":
            b"\x7fELF\x00vermagic=" + vermagic.encode() + b" SMP preempt aarch64\x00"
            for driver in audit.DRIVERS}


def cpio_entry(name, data):
    # A standard newc archive, independent of libarchive's reader implementation.
    name = name.encode() + b"\x00"
    fields = [1, 0o100644, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(name), 0]
    header = b"070701" + b"".join(f"{x:08x}".encode() for x in fields) + name
    header += b"\x00" * (-len(header) % 4)
    return header + data + b"\x00" * (-len(data) % 4)


class FirmwareChecks(unittest.TestCase):
    def test_matching_modules_allow_image(self):
        release, evidence = audit.check_drivers(KERNEL, module_files())
        self.assertEqual(release, RELEASE)
        self.assertEqual(set(evidence), set(audit.DRIVERS))

    def test_missing_modules_reproduce_broken_image(self):
        with self.assertRaisesRegex(audit.InvalidImage, "no matching module or built-in evidence"):
            audit.check_drivers(KERNEL + b"configfs nvme", {})

    def test_one_missing_required_driver_blocks_release(self):
        files = module_files()
        del files[next(path for path in files if path.endswith("libcomposite.ko"))]
        with self.assertRaisesRegex(audit.InvalidImage, "libcomposite"):
            audit.check_drivers(KERNEL, files)

    def test_module_directory_must_match_running_kernel(self):
        with self.assertRaises(audit.InvalidImage):
            audit.check_drivers(KERNEL, module_files(release="6.18.54-v8"))

    def test_vermagic_must_match_even_when_directory_name_matches(self):
        with self.assertRaises(audit.InvalidImage):
            audit.check_drivers(KERNEL, module_files(vermagic="6.18.54-v8"))

    def test_embedded_config_can_prove_builtin_drivers(self):
        config = "\n".join(option + "=y" for option in audit.DRIVERS.values()) + "\n"
        kernel = KERNEL + b"IKCFG_ST" + gzip.compress(config.encode()) + b"IKCFG_ED"
        _, evidence = audit.check_drivers(kernel, {})
        self.assertTrue(all(value == "built-in" for value in evidence.values()))

    def test_matching_builtin_manifest_is_accepted(self):
        names = "\n".join(f"kernel/drivers/usb/{driver}.ko" for driver in audit.DRIVERS).encode()
        _, evidence = audit.check_drivers(KERNEL, {f"usr/lib/modules/{RELEASE}/modules.builtin": names})
        self.assertEqual(set(evidence), set(audit.DRIVERS))
        with self.assertRaises(audit.InvalidImage):
            audit.check_drivers(KERNEL, {"usr/lib/modules/6.18.54-v8/modules.builtin": names})

    def test_compressed_cpio_reads_selected_driver_files(self):
        files = module_files()
        archive = b"".join(cpio_entry(path, data) for path, data in files.items())
        archive += cpio_entry("unrelated/file", b"ignored") + cpio_entry("TRAILER!!!", b"")
        selected = audit.archive_members(gzip.compress(archive), lambda path: bool(audit.MODULE.search(path)))
        self.assertEqual(selected, files)
        audit.check_drivers(KERNEL, selected)

    def test_truncated_image_and_archive_are_rejected(self):
        with self.assertRaises(audit.InvalidImage):
            audit.FatImage(b"short")
        with self.assertRaises(audit.InvalidImage):
            audit.archive_members(b"\x28\xb5\x2f\xfdinvalid", lambda _: True)


if __name__ == "__main__":
    unittest.main()
