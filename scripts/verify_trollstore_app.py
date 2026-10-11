#!/usr/bin/env python3
"""Verify the actual host/extension metadata, signatures and iOS device binaries."""
import plistlib
import re
import subprocess
import sys
from pathlib import Path

APP_GROUP_KEY = "com.apple.security.application-groups"
NETWORK_EXTENSION_KEY = "com.apple.developer.networking.networkextension"


def validate_metadata(app_info, extension_info, app_entitlements, extension_entitlements):
    provider_id = extension_info["CFBundleIdentifier"]
    if app_info.get("TunnelProviderBundleIdentifier") != provider_id:
        raise ValueError("Host provider identifier does not match the embedded Packet Tunnel")
    if not provider_id.startswith(app_info["CFBundleIdentifier"] + "."):
        raise ValueError("Packet Tunnel bundle identifier must be nested under the host")
    if extension_info.get("NSExtension", {}).get("NSExtensionPointIdentifier") != \
            "com.apple.networkextension.packet-tunnel":
        raise ValueError("Embedded extension is not a Packet Tunnel provider")
    group_id = app_info.get("AppGroupIdentifier")
    if not group_id or "$" in group_id:
        raise ValueError("Missing or unresolved App Group identifier")
    for info, entitlements in ((app_info, app_entitlements),
                               (extension_info, extension_entitlements)):
        if entitlements.get(APP_GROUP_KEY) != [group_id]:
            raise ValueError("Host and Packet Tunnel must share the configured App Group")
        if entitlements.get(NETWORK_EXTENSION_KEY) != ["packet-tunnel-provider"]:
            raise ValueError("Missing Packet Tunnel entitlement")
        team = entitlements.get("com.apple.developer.team-identifier")
        if not team or entitlements.get("application-identifier") != \
                f"{team}.{info['CFBundleIdentifier']}":
            raise ValueError("Signed application identifier does not match the bundle")
        if tuple(map(int, info["MinimumOSVersion"].split("."))) > (16, 3, 1):
            raise ValueError("Deployment target exceeds the test device's iOS 16.3.1")
        if info.get("CFBundleSupportedPlatforms") != ["iPhoneOS"]:
            raise ValueError("Expected an iPhone device build, not a Simulator build")
    if app_entitlements["com.apple.developer.team-identifier"] != \
            extension_entitlements["com.apple.developer.team-identifier"]:
        raise ValueError("Host and Packet Tunnel signing identifiers use different teams")


def signed_entitlements(bundle):
    return plistlib.loads(subprocess.check_output(
        ["codesign", "--display", "--entitlements", "-", "--xml", str(bundle)],
        stderr=subprocess.DEVNULL,
    ))


def verify_app(app):
    extension = app / "PlugIns/PacketTunnelExtension.appex"
    infos = [plistlib.loads((bundle / "Info.plist").read_bytes())
             for bundle in (app, extension)]
    validate_metadata(*infos, signed_entitlements(app), signed_entitlements(extension))
    for bundle, info in zip((app, extension), infos):
        subprocess.run(["codesign", "--verify", "--strict", str(bundle)], check=True)
        binary = bundle / info["CFBundleExecutable"]
        arches = subprocess.check_output(["xcrun", "lipo", "-archs", str(binary)], text=True)
        if "arm64" not in arches.split():
            raise ValueError(f"Missing arm64 device architecture: {binary}")
        build = subprocess.check_output(["xcrun", "vtool", "-show-build", str(binary)], text=True)
        if not re.search(r"platform\s+IOS\s", build):
            raise ValueError(f"Expected iOS device binary: {binary}")
        minos = re.search(r"minos\s+([\d.]+)", build)
        if not minos or tuple(map(int, minos[1].split("."))) > (16, 3, 1):
            raise ValueError(f"Binary deployment target exceeds iOS 16.3.1: {binary}")
    if not (app / "Assets.car").is_file():
        raise ValueError("Compiled application assets are missing")
    print("Verified: full arm64 iOS app + Packet Tunnel, matching entitlements, iOS 16.3.1 target")


if __name__ == "__main__":
    verify_app(Path(sys.argv[1]))
