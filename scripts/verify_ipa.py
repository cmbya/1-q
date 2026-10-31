"""Basic IPA metadata/Mach-O checks, NOT signature or runtime validation.

Run dependency-free regression tests with: python3 scripts/verify_ipa.py --self-test
"""
import io
import plistlib
import re
import struct
import sys
import unittest
import zipfile


def require(condition, message):
    if not condition:
        raise ValueError(message)


def check_macho(data, minimum):
    """Check all slices are bounded arm64 iOS executables with matching min OS."""
    if data[:4] in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
        require(len(data) >= 8, "Truncated fat header")
        count = struct.unpack_from(">I", data, 4)[0]
        wide = data[:4] == b"\xca\xfe\xba\xbf"
        size = 32 if wide else 20
        end = 8 + count * size
        require(0 < count <= 32 and end <= len(data), "Invalid fat architecture table")
        ranges = []
        for index in range(count):
            fields = struct.unpack_from(">IIQQII" if wide else ">IIIII", data, 8 + index * size)
            cpu, _, offset, length = fields[:4]
            require(cpu == 0x0100000C, "Non-arm64 IPA slice")
            require(offset >= end and length > 0 and offset + length <= len(data), "Invalid fat slice bounds")
            require(all(offset + length <= a or offset >= b for a, b in ranges), "Overlapping fat slices")
            ranges.append((offset, offset + length))
            check_thin(data[offset:offset + length], minimum)
    else:
        check_thin(data, minimum)


def check_thin(data, minimum):
    require(len(data) >= 32 and data[:4] == b"\xcf\xfa\xed\xfe", "Missing arm64 Mach-O executable")
    _, cpu, _, filetype, count, command_bytes, _, _ = struct.unpack_from("<8I", data)
    require(cpu == 0x0100000C and filetype == 2, "Expected arm64 MH_EXECUTE")
    end = 32 + command_bytes
    require(end <= len(data) and count <= command_bytes // 8, "Invalid load-command bounds")
    offset = 32
    versions = []
    for _ in range(count):
        require(offset + 8 <= end, "Truncated load command")
        command, size = struct.unpack_from("<II", data, offset)
        require(size >= 8 and size % 8 == 0 and offset + size <= end, "Invalid load command size")
        if command == 0x32:  # LC_BUILD_VERSION
            require(size >= 24, "Truncated build version")
            platform, minos, sdk, tools = struct.unpack_from("<4I", data, offset + 8)
            require(24 + tools * 8 <= size, "Truncated build tools")
            require(platform == 2, "Expected device iOS platform (not simulator)")
            require(minos == minimum and sdk >= minos, "Mach-O deployment target/SDK mismatch")
            versions.append(minos)
        offset += size
    require(offset == end and len(versions) == 1, "Missing or ambiguous iOS build version")


def os_version(value):
    require(isinstance(value, str), "Missing minimum iOS version")
    parts = value.split(".")
    require(1 <= len(parts) <= 3 and all(p.isascii() and p.isdigit() for p in parts), "Invalid minimum iOS version")
    numbers = [int(p) for p in parts] + [0] * (3 - len(parts))
    require(17 <= numbers[0] <= 65535 and all(n <= 255 for n in numbers[1:]), "Expected iOS 17 or later")
    return numbers[0] << 16 | numbers[1] << 8 | numbers[2]


def verify(path):
    with zipfile.ZipFile(path) as bundle:
        require(bundle.testzip() is None, "Corrupt IPA")
        names = bundle.namelist()
        require(len(names) == len(set(names)), "Duplicate IPA entries")
        main_path = "Payload/ParcelKeeper.app/"
        widget_path = main_path + "PlugIns/ParcelKeeperWidget.appex/"
        main = plistlib.loads(bundle.read(main_path + "Info.plist"))
        widget = plistlib.loads(bundle.read(widget_path + "Info.plist"))
        require(main.get("CFBundlePackageType") == "APPL", "Expected main APPL package")
        require(widget.get("CFBundlePackageType") == "XPC!", "Expected widget XPC! package")
        extension = widget.get("NSExtension")
        require(isinstance(extension, dict) and extension.get("NSExtensionPointIdentifier") == "com.apple.widgetkit-extension",
                "Expected WidgetKit extension point")
        identifier_pattern = r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+"
        for info in (main, widget):
            identifier = info.get("CFBundleIdentifier")
            require(isinstance(identifier, str) and re.fullmatch(identifier_pattern, identifier), "Invalid bundle identifier")
            for key in ("CFBundleShortVersionString", "CFBundleVersion"):
                value = info.get(key)
                require(isinstance(value, str) and re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", value), f"Invalid {key}")
        require(widget["CFBundleIdentifier"].startswith(main["CFBundleIdentifier"] + "."),
                "Widget identifier must be nested under main identifier")
        require(main.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon", {}).get("CFBundleIconName") == "AppIcon", "Missing primary icon metadata")
        require(main_path + "Assets.car" in names, "Missing compiled asset catalog")
        for key in ("CFBundleShortVersionString", "CFBundleVersion", "MinimumOSVersion", "ParcelKeeperAppGroup"):
            require(main.get(key) and main[key] == widget.get(key), f"Main/widget mismatch: {key}")
        group = main.get("ParcelKeeperAppGroup")
        require(isinstance(group, str) and re.fullmatch(r"group\.[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*", group),
                "Invalid App Group identifier")
        minimum = os_version(main["MinimumOSVersion"])
        for prefix, info in ((main_path, main), (widget_path, widget)):
            executable = info.get("CFBundleExecutable")
            require(isinstance(executable, str) and executable not in ("", ".", "..") and "/" not in executable and "\\" not in executable, "Invalid executable metadata")
            require(prefix + executable in names, "Missing bundled executable")
            check_macho(bundle.read(prefix + executable), minimum)
        print("IPA basic checks passed: package types, nested bundle identifiers, WidgetKit extension point, icon metadata/catalog, matching versions/configuration, arm64 iOS executable headers/deployment targets.")
        print("Not signature, entitlement, complete binary integrity, or on-device shared-container validation.")


class VerifierTests(unittest.TestCase):
    @staticmethod
    def binary(platform=2, minos=17 << 16):
        command = struct.pack("<6I", 0x32, 24, platform, minos, 18 << 16, 0)
        return struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 2, 1, len(command), 0, 0) + command

    def ipa(self, binary=None, missing=False, version="17.0", widget_binary=None, main_changes=None, widget_changes=None):
        output = io.BytesIO()
        with zipfile.ZipFile(output, "w") as archive:
            for prefix, name in (("Payload/ParcelKeeper.app/", "ParcelKeeper"), ("Payload/ParcelKeeper.app/PlugIns/ParcelKeeperWidget.appex/", "ParcelKeeperWidget")):
                info: dict[str, object] = dict(CFBundleExecutable=name, CFBundleShortVersionString="1.0", CFBundleVersion="1", MinimumOSVersion=version, ParcelKeeperAppGroup="group.test", CFBundleIcons={"CFBundlePrimaryIcon": {"CFBundleIconName": "AppIcon"}})
                info.update(CFBundleIdentifier="com.example." + name,
                            CFBundlePackageType="XPC!" if name == "ParcelKeeperWidget" else "APPL")
                if name == "ParcelKeeperWidget":
                    info["CFBundleIdentifier"] = "com.example.ParcelKeeper.widget"
                    info["NSExtension"] = {"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"}
                info.update((widget_changes if name == "ParcelKeeperWidget" else main_changes) or {})
                archive.writestr(prefix + "Info.plist", plistlib.dumps(info))
                if not missing:
                    payload = widget_binary if name == "ParcelKeeperWidget" and widget_binary is not None else binary
                    archive.writestr(prefix + name, self.binary() if payload is None else payload)
            archive.writestr("Payload/ParcelKeeper.app/Assets.car", b"fixture")
        output.seek(0)
        return output

    def test_valid_thin_and_fat(self):
        verify(self.ipa())
        thin = self.binary()
        fat = struct.pack(">7I", 0xCAFEBABE, 1, 0x0100000C, 0, 28, len(thin), 0) + thin
        verify(self.ipa(binary=fat))

    def test_rejected_artifacts(self):
        cases = [dict(missing=True), dict(binary=b"text"), dict(binary=self.binary(platform=7)),
                 dict(version="16.0"), dict(version="17.invalid"), dict(binary=self.binary(minos=18 << 16)),
                 dict(binary=self.binary()[:-1]), dict(widget_binary=b"not Mach-O")]
        for case in cases:
            with self.subTest(case=case), self.assertRaises(ValueError):
                verify(self.ipa(**case))

    def test_rejected_bundle_metadata(self):
        cases = [
            dict(widget_changes={"NSExtension": {}}),
            dict(widget_changes={"NSExtension": {"NSExtensionPointIdentifier": "com.apple.wrong"}}),
            dict(widget_changes={"CFBundlePackageType": "APPL"}),
            dict(main_changes={"CFBundlePackageType": "XPC!"}),
            dict(widget_changes={"CFBundleIdentifier": "com.unrelated.widget"}),
            dict(widget_changes={"CFBundleIdentifier": "com.example.ParcelKeeper"}),
            dict(widget_changes={"CFBundleIdentifier": "com.example.ParcelKeeper."}),
            dict(main_changes={"CFBundleIdentifier": "invalid/id"}),
            dict(main_changes={"CFBundleShortVersionString": "next"}, widget_changes={"CFBundleShortVersionString": "next"}),
            dict(main_changes={"CFBundleVersion": "next"}, widget_changes={"CFBundleVersion": "next"}),
            dict(widget_changes={"CFBundleVersion": "2"}),
        ]
        for case in cases:
            with self.subTest(case=case), self.assertRaises(ValueError):
                verify(self.ipa(**case))

    def test_app_group_requires_valid_string_identifier(self):
        for invalid in (123, True, "123", "group.", " group.test", "group.test ", "group.test/invalid", "group..test"):
            with self.subTest(value=invalid), self.assertRaises(ValueError):
                verify(self.ipa(main_changes={"ParcelKeeperAppGroup": invalid},
                                widget_changes={"ParcelKeeperAppGroup": invalid}))

    def test_invalid_commands_and_fat_bounds(self):
        data = bytearray(self.binary())
        struct.pack_into("<I", data, 36, 0)
        for bad in (bytes(data), struct.pack(">7I", 0xCAFEBABE, 1, 0x0100000C, 0, 200, 56, 0), self.binary()[:32]):
            with self.subTest(binary=bad), self.assertRaises(ValueError):
                check_macho(bad, 17 << 16)


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        unittest.main(argv=[sys.argv[0]])
    else:
        verify(sys.argv[1])
