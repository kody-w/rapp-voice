#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="${1:-$(uname -m)}"
case "$ARCH" in
  arm64|x86_64) ;;
  *) echo "Expected native architecture arm64 or x86_64, got: $ARCH" >&2; exit 2 ;;
esac
if [ "$(uname -m)" != "$ARCH" ]; then
  echo "This check must run on a native $ARCH host; refusing a mislabeled architecture run." >&2
  exit 2
fi
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "XcodeGen is required for the unsigned application-bundle check." >&2
  exit 1
fi

cd "$ROOT"
swift --version
xcodebuild -version
xcodegen --version
python3 --version
echo "Native CI: fixtures only; no capture, permission grants, signing, or publication."

./tools/dryrun.sh --safe
(
  cd native
  swift build -j 2
)

RESULTS="$ROOT/native/.build/ci/$ARCH-$(date -u +%Y%m%dT%H%M%SZ)-$$"
DERIVED="$RESULTS/DerivedData"
mkdir -p "$RESULTS"
cd "$ROOT/native"
xcodegen generate --spec project.yml --quiet
xcodebuild -quiet \
  -resolvePackageDependencies \
  -project RAPPVoice.xcodeproj -scheme RAPPVoice \
  -derivedDataPath "$DERIVED" -resultBundlePath "$RESULTS/resolve.xcresult" \
  -jobs 2
xcodebuild -quiet \
  -project RAPPVoice.xcodeproj -scheme RAPPVoice \
  -configuration Release -destination "platform=macOS,arch=$ARCH" \
  -derivedDataPath "$DERIVED" -resultBundlePath "$RESULTS/build.xcresult" \
  -jobs 2 -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  ARCHS="$ARCH" ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
xcodebuild -quiet \
  -project RAPPVoice.xcodeproj -scheme RAPPVoice \
  -destination "platform=macOS,arch=$ARCH" \
  -derivedDataPath "$DERIVED" -resultBundlePath "$RESULTS/tests.xcresult" \
  -jobs 2 -parallel-testing-enabled NO \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  ARCHS="$ARCH" ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO test

APP="$DERIVED/Build/Products/Release/RAPPVoice.app"
BINARY="$APP/Contents/MacOS/RAPPVoice"
test "$(/usr/bin/lipo -archs "$BINARY")" = "$ARCH"
/usr/bin/plutil -lint "$APP/Contents/Info.plist" "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
"$BINARY" --version
cd "$ROOT"
RAPPVOICE_TEST_CLI="$BINARY" python3 -B tools/test_native_adapter.py
printf 'PASS: safe native checks on %s. Xcode results: %s\n' "$ARCH" "$RESULTS"
