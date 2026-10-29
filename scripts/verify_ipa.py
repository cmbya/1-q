"""Validate the built IPA, not merely source configuration. No private data."""
import plistlib
import sys
import zipfile


def verify(path):
    with zipfile.ZipFile(path) as bundle:
        assert bundle.testzip() is None, "Corrupt IPA"
        main_path = "Payload/ParcelKeeper.app/"
        widget_path = main_path + "PlugIns/ParcelKeeperWidget.appex/"
        main = plistlib.loads(bundle.read(main_path + "Info.plist"))
        widget = plistlib.loads(bundle.read(widget_path + "Info.plist"))
        assert main.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon", {}).get("CFBundleIconName") == "AppIcon", "Missing primary icon metadata"
        assert main_path + "Assets.car" in bundle.namelist(), "Missing compiled asset catalog"
        for key in ("CFBundleShortVersionString", "CFBundleVersion", "MinimumOSVersion", "ParcelKeeperAppGroup"):
            assert main.get(key) and main[key] == widget.get(key), f"Main/widget mismatch: {key}"
        print("IPA verified: compiled icon, widget, matching version/system/App Group configuration")
        print("Signing entitlements and on-device shared-container access require separate validation.")


if __name__ == "__main__":
    verify(sys.argv[1])
