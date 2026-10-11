#!/usr/bin/env bash
set -euo pipefail

task_repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$task_repo_dir"
mkdir -p DerivedData/Logs dist

# Compile both the host app and Packet Tunnel without a developer certificate.
task_build_log="$task_repo_dir/DerivedData/Logs/iphoneos-build.log"
task_build_dir="$task_repo_dir/DerivedData/PublicReleaseBuild"
echo "Building the full WLOC app and Packet Tunnel (Release, iOS 16+)..."
if ! xcodebuild -project WLOC.xcodeproj -scheme WLOC -configuration Release \
    -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath "$task_build_dir" \
    CODE_SIGNING_ALLOWED=NO CLANG_ENABLE_CODE_COVERAGE=NO \
    ENABLE_CODE_COVERAGE=NO GCC_INSTRUMENT_PROGRAM_FLOW=NO \
    GCC_GENERATE_DEBUGGING_SYMBOLS=NO SWIFT_SERIALIZE_DEBUGGING_OPTIONS=NO build \
    > "$task_build_log" 2>&1; then
    tail -n 80 "$task_build_log"
    exit 1
fi

task_stage_dir="$(mktemp -d "$task_repo_dir/DerivedData/ipa-stage.XXXXXX")"
trap 'rm -rf "$task_stage_dir"' EXIT
mkdir -p "$task_stage_dir/Payload"
ditto "$task_build_dir/Build/Products/Release-iphoneos/WLOC.app" "$task_stage_dir/Payload/WLOC.app"
task_app="$task_stage_dir/Payload/WLOC.app"
task_extension="$task_app/PlugIns/PacketTunnelExtension.appex"

# Remove local debug metadata before signing; audit the final archive as well.
xcrun strip -S "$task_extension/PacketTunnelExtension"
xcrun strip -S "$task_app/WLOC"

# Ad-hoc signatures carry the repository's TrollStore entitlements. They are
# not developer provisioning profiles; TrollStore performs installation signing.
codesign --force --sign - --generate-entitlement-der \
    --entitlements TrollStoreEntitlements/PacketTunnelExtension.entitlements "$task_extension"
codesign --force --sign - --generate-entitlement-der \
    --entitlements TrollStoreEntitlements/WLOC.entitlements "$task_app"
python3 scripts/verify_trollstore_app.py "$task_app"

# Build at a temporary path, then replace the deliverable only after validation.
task_ipa="$task_stage_dir/WLOC-TrollStore.ipa"
ditto -c -k --norsrc --keepParent "$task_stage_dir/Payload" "$task_ipa"
unzip -tq "$task_ipa"
python3 scripts/verify_publication_privacy.py --ipa "$task_ipa"
mv -f "$task_ipa" "$task_repo_dir/dist/WLOC-TrollStore.ipa"
(cd dist && shasum -a 256 WLOC-TrollStore.ipa) > dist/WLOC-TrollStore.ipa.sha256
task_version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$task_app/Info.plist")"
task_build="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$task_app/Info.plist")"
task_versioned_ipa="dist/WLOC-$task_version-build$task_build-TrollStore.ipa"
cp dist/WLOC-TrollStore.ipa "$task_versioned_ipa"
(cd dist && shasum -a 256 "${task_versioned_ipa##*/}") > "$task_versioned_ipa.sha256"
echo "Versioned IPA: $task_repo_dir/$task_versioned_ipa"
echo "IPA: $task_repo_dir/dist/WLOC-TrollStore.ipa"
echo "Build log: $task_build_log"
