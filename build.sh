#!/usr/bin/env bash
# Builds Companion.ipa (arm64, unsigned; re-sign with AltStore/SideStore).
# Set COMPANION_FINAL_IPA to override the publication path.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$ROOT"
FINAL_IPA=${COMPANION_FINAL_IPA:-Companion.ipa}
if [[ "$FINAL_IPA" != /* ]]; then
    FINAL_IPA="$ROOT/$FINAL_IPA"
fi
FINAL_DIR=$(dirname -- "$FINAL_IPA")
if [[ ! -d "$FINAL_DIR" ]]; then
    echo "final IPA directory does not exist: $FINAL_DIR" >&2
    exit 1
fi

DERIVED="$ROOT/.derived"
rm -rf "$DERIVED"

xcodebuild -project Companion.xcodeproj -scheme Companion -sdk iphoneos \
    -configuration Release -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
    build

APP="$DERIVED/Build/Products/Release-iphoneos/Companion.app"
if [[ ! -d "$APP" ]]; then
    echo "build produced no .app at $APP" >&2
    exit 1
fi

OUT=$(mktemp -d)
IPA_TMP=$(mktemp "$FINAL_DIR/.Companion.ipa.XXXXXX")
rm -f -- "$IPA_TMP"
cleanup() {
    rm -rf -- "$OUT"
    if [[ -e "$IPA_TMP" ]]; then rm -f -- "$IPA_TMP"; fi
}
trap cleanup EXIT

mkdir -p "$OUT/Payload"
cp -R "$APP" "$OUT/Payload/Companion.app"
(cd "$OUT" && zip -qry "$IPA_TMP" Payload)
unzip -tqq "$IPA_TMP"
mv -f -- "$IPA_TMP" "$FINAL_IPA"
IPA_TMP=""
echo "wrote $FINAL_IPA"
ls -l "$FINAL_IPA"
