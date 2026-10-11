import copy
import plistlib
import re
import subprocess
import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts"))
from verify_trollstore_app import validate_metadata


class TrollStoreConfigurationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        project = plistlib.loads(subprocess.check_output([
            "plutil", "-convert", "xml1", "-o", "-",
            str(REPO / "WLOC.xcodeproj/project.pbxproj"),
        ]))
        objects = project["objects"]
        root = objects[project["rootObject"]]
        configs = objects[root["buildConfigurationList"]]["buildConfigurations"]
        defaults = {objects[key]["name"]: objects[key]["buildSettings"] for key in configs}
        cls.configurations = []
        for config in objects.values():
            settings = config.get("buildSettings", {})
            if settings.get("INFOPLIST_FILE") != "WLOC-App-Info.plist":
                continue
            extension_settings = next(obj["buildSettings"] for obj in objects.values()
                                      if obj.get("name") == config["name"]
                                      and obj.get("buildSettings", {}).get("INFOPLIST_FILE")
                                      == "PacketTunnelExtension/Info.plist")

            def info_for(build_settings):
                info = plistlib.loads((REPO / build_settings["INFOPLIST_FILE"]).read_bytes())
                for key, value in list(info.items()):
                    if isinstance(value, str) and value.startswith("$("):
                        info[key] = build_settings.get(value[2:-1], value)
                info["CFBundleIdentifier"] = build_settings["PRODUCT_BUNDLE_IDENTIFIER"]
                info["CFBundleSupportedPlatforms"] = ["iPhoneOS"]
                info["MinimumOSVersion"] = build_settings.get(
                    "IPHONEOS_DEPLOYMENT_TARGET", defaults[config["name"]]["IPHONEOS_DEPLOYMENT_TARGET"])
                return info

            entitlements = [plistlib.loads((REPO / path).read_bytes()) for path in (
                "TrollStoreEntitlements/WLOC.entitlements",
                "TrollStoreEntitlements/PacketTunnelExtension.entitlements")]
            cls.configurations.append((info_for(settings), info_for(extension_settings), *entitlements))
        if len(cls.configurations) != 2:
            raise AssertionError("Expected both Debug and Release configurations")

    def setUp(self):
        self.metadata = copy.deepcopy(self.configurations[0])

    def test_debug_and_release_match_runtime_defaults_and_both_signing_methods(self):
        constants = (REPO / "Shared/SharedConstants.swift").read_text()
        for app_info, extension_info, app_entitlements, extension_entitlements in self.configurations:
            validate_metadata(app_info, extension_info, app_entitlements, extension_entitlements)
            for field, constant in (("AppGroupIdentifier", "appGroupIdentifier"),
                                    ("TunnelProviderBundleIdentifier", "tunnelProviderBundleIdentifier")):
                self.assertEqual(app_info[field], re.search(
                    rf'static let {constant} = "([^"]+)"', constants)[1])
            for path in ("WLOC/WLOC.entitlements", "PacketTunnelExtension/PacketTunnelExtension.entitlements"):
                ordinary_entitlements = plistlib.loads((REPO / path).read_bytes())
                for key in ordinary_entitlements:
                    self.assertEqual(ordinary_entitlements[key], app_entitlements[key])

    def test_wrong_provider_cannot_pass_even_with_valid_signatures(self):
        self.metadata[0]["TunnelProviderBundleIdentifier"] = "com.xiaobovlog.WLOC.PacketTunnel"
        with self.assertRaisesRegex(ValueError, "provider identifier"):
            validate_metadata(*self.metadata)

    def test_missing_extension_permission_is_rejected(self):
        del self.metadata[3]["com.apple.developer.networking.networkextension"]
        with self.assertRaisesRegex(ValueError, "entitlement"):
            validate_metadata(*self.metadata)

    def test_different_shared_container_is_rejected(self):
        self.metadata[3]["com.apple.security.application-groups"] = ["group.other"]
        with self.assertRaisesRegex(ValueError, "App Group"):
            validate_metadata(*self.metadata)

    def test_simulator_artifact_is_rejected(self):
        self.metadata[0]["CFBundleSupportedPlatforms"] = ["iPhoneSimulator"]
        with self.assertRaisesRegex(ValueError, "Simulator"):
            validate_metadata(*self.metadata)

    def test_newer_deployment_target_is_rejected(self):
        self.metadata[1]["MinimumOSVersion"] = "16.4"
        with self.assertRaisesRegex(ValueError, "16.3.1"):
            validate_metadata(*self.metadata)

    def test_wrong_signed_application_identifier_is_rejected(self):
        self.metadata[2]["application-identifier"] = "6X9BLAS47C.com.other.app"
        with self.assertRaisesRegex(ValueError, "application identifier"):
            validate_metadata(*self.metadata)

    def test_unresolved_app_group_build_setting_is_rejected(self):
        self.metadata[0]["AppGroupIdentifier"] = "$(INFOPLIST_KEY_AppGroupIdentifier)"
        with self.assertRaisesRegex(ValueError, "unresolved"):
            validate_metadata(*self.metadata)


if __name__ == "__main__":
    unittest.main()
