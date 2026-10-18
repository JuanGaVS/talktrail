#!/bin/zsh
# Builds the `talktrail` CLI and Talktrail.app (with the speaker-identification models inside) into ./build.
#
#   scripts/build.sh                                               # ad-hoc signed, for local use
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build.sh   # for distribution (then notarize)
set -euo pipefail

ROOT=${0:A:h:h}
OUT=$ROOT/build
APP=$OUT/Talktrail.app
cd "$ROOT"

if [[ ! -d Models/speaker-diarization ]]; then
    echo "The models are missing from ./Models. Download them once (see the README, \"Models\")." >&2
    exit 1
fi

echo "› swift build"
BIN=$(swift build -c release --show-bin-path)
# Support/Info.plist is linked into the CLI, but SwiftPM does not track it as an input: force a relink.
rm -f "$BIN/talktrail"
swift build -c release --product talktrail
swift build -c release --product TalktrailApp

echo "› Talktrail.app"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/TalktrailApp" "$APP/Contents/MacOS/Talktrail"
cp Support/Talktrail-Info.plist "$APP/Contents/Info.plist"
# Translated permission prompts (InfoPlist.strings).
cp -R Support/*.lproj "$APP/Contents/Resources/"
cp -R Models "$APP/Contents/Resources/Models"
cp -R "$BIN"/*.bundle "$APP/Contents/Resources/"

# Apache-2.0 and CC BY 4.0 require shipping the licenses and attributions with the binaries.
LICENSES=$APP/Contents/Resources/Licenses
mkdir -p "$LICENSES/FluidAudio"
cp LICENSE NOTICE "$LICENSES/"
cp -R .build/checkouts/FluidAudio/LICENSE .build/checkouts/FluidAudio/ThirdPartyLicenses "$LICENSES/FluidAudio/"

cp "$BIN/talktrail" "$OUT/talktrail"
cp -R Models "$OUT/Models"
cp -R "$BIN"/*.bundle "$OUT/"
cp -R "$LICENSES" "$OUT/Licenses"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --entitlements Support/Talktrail.entitlements \
        --sign "$SIGN_IDENTITY" "$APP"
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$OUT/talktrail"
else
    codesign --force --sign - "$APP"
    codesign --force --sign - "$OUT/talktrail"
fi

echo "✓ $APP"
echo "✓ $OUT/talktrail"
