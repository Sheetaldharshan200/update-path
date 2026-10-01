import unittest

from exakit.domain.errors import BadInput
from exakit.domain.platform import Platform, make_platform, normalize_arch, normalize_os


class PlatformTest(unittest.TestCase):
    def test_uname_names_are_normalised(self):
        self.assertEqual(normalize_os("Darwin"), "macos")
        self.assertEqual(normalize_os("Linux"), "linux")
        self.assertEqual(normalize_os("win32"), "windows")
        self.assertEqual(normalize_arch("arm64"), "aarch64")
        self.assertEqual(normalize_arch("AMD64"), "x86_64")

    def test_unsupported_names_are_bad_input(self):
        with self.assertRaises(BadInput):
            normalize_os("FreeBSD")
        with self.assertRaises(BadInput):
            normalize_arch("i386")

    def test_platform_key_is_the_versions_json_digest_key(self):
        self.assertEqual(make_platform("Darwin", "arm64").platform_key, "macos-aarch64")
        self.assertEqual(make_platform("Linux", "x86_64", wsl_version=2).platform_key, "linux-x86_64")

    def test_wsl_is_linux_with_a_version(self):
        wsl = make_platform("Linux", "x86_64", wsl_version=2)
        self.assertTrue(wsl.is_wsl)
        self.assertFalse(make_platform("Linux", "x86_64").is_wsl)

    def test_to_dict_uses_the_status_json_key_names(self):
        self.assertEqual(Platform("macos", "aarch64").to_dict(), {"platform": "macos", "arch": "aarch64", "wsl_version": None})


if __name__ == "__main__":
    unittest.main()
