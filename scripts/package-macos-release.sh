#!/bin/sh
# Create Parrot Lab's temporary, ad-hoc-signed macOS release archive.
# No Developer ID identity, Apple account, provisioning profile, or secret is
# used. This is intentionally not a notarization workflow.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
DEFAULT_ZIP="$PROJECT_DIR/dist/Parrot-Lab-macOS-arm64.zip"

usage()
{
    printf '%s\n' "Usage: $0 \"/path/to/Parrot Lab.app\" [output.zip]" >&2
    exit 2
}

fail()
{
    printf '%s\n' "package-macos-release: $*" >&2
    exit 1
}

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage

case "$1" in
    /*) INPUT_APP=$1 ;;
    *) INPUT_APP="$(pwd)/$1" ;;
esac
case "${2:-$DEFAULT_ZIP}" in
    /*) OUTPUT_ZIP=${2:-$DEFAULT_ZIP} ;;
    *) OUTPUT_ZIP="$(pwd)/${2:-$DEFAULT_ZIP}" ;;
esac

[ -d "$INPUT_APP" ] || fail "app bundle not found: $INPUT_APP"
[ "$(basename "$INPUT_APP")" = "Parrot Lab.app" ] || \
    fail "expected a bundle named Parrot Lab.app"
[ -f "$INPUT_APP/Contents/Info.plist" ] || fail "Contents/Info.plist is missing"

BUNDLE_EXECUTABLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \
    "$INPUT_APP/Contents/Info.plist" 2>/dev/null) || \
    fail "CFBundleExecutable is missing from Info.plist"
[ -x "$INPUT_APP/Contents/MacOS/$BUNDLE_EXECUTABLE" ] || \
    fail "bundle executable is missing or not executable: $BUNDLE_EXECUTABLE"

OUTPUT_DIR=$(dirname "$OUTPUT_ZIP")
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(CDPATH= cd -- "$OUTPUT_DIR" && pwd)
OUTPUT_ZIP="$OUTPUT_DIR/$(basename "$OUTPUT_ZIP")"

STAGE_DIR=$(/usr/bin/mktemp -d /tmp/parrotlab-package.XXXXXX)
STAGE_APP="$STAGE_DIR/Parrot Lab.app"
STAGE_ZIP="$STAGE_DIR/Parrot-Lab-macOS-arm64.zip"
VERIFY_DIR="$STAGE_DIR/verify"
trap '/bin/rm -rf "$STAGE_DIR"' EXIT HUP INT TERM

# Work on a clean temporary copy. This avoids signing instability caused by
# cloud/File Provider metadata and leaves the caller's source bundle alone.
/usr/bin/ditto --noextattr --noqtn "$INPUT_APP" "$STAGE_APP"
/usr/bin/xattr -cr "$STAGE_APP"

# Temporary distribution identity: ad-hoc only. Do not replace '-' with a
# paid identity unless the project deliberately adopts Developer ID signing.
/usr/bin/codesign --force --deep --sign - "$STAGE_APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGE_APP"

SIGNATURE_DETAILS=$(/usr/bin/codesign -dv --verbose=4 "$STAGE_APP" 2>&1)
printf '%s\n' "$SIGNATURE_DETAILS" | /usr/bin/grep -q '^Signature=adhoc$' || \
    fail "the staged bundle is not ad-hoc signed"
printf '%s\n' "$SIGNATURE_DETAILS" | /usr/bin/grep -q '^TeamIdentifier=not set$' || \
    fail "the staged bundle unexpectedly contains a team identifier"

# Exercise the packaged executable before archiving it. This is an offline
# application self-test and does not connect to a drone or controller.
"$STAGE_APP/Contents/MacOS/$BUNDLE_EXECUTABLE" --self-test

# Store the normal app hierarchy, executable modes, and any future symlinks,
# while omitting Finder/File Provider metadata and AppleDouble `._*` entries.
(
    cd "$STAGE_DIR"
    COPYFILE_DISABLE=1 /usr/bin/zip -qry -X -y "$STAGE_ZIP" "Parrot Lab.app"
)
/usr/bin/unzip -tq "$STAGE_ZIP"
if /usr/bin/unzip -Z1 "$STAGE_ZIP" | /usr/bin/grep -Eq '(^|/)\._|^__MACOSX/'; then
    fail "release ZIP contains AppleDouble metadata"
fi

# Verify the exact app recovered from the release ZIP, not only the pre-ZIP
# staging copy.
mkdir -p "$VERIFY_DIR"
/usr/bin/ditto -x -k "$STAGE_ZIP" "$VERIFY_DIR"
[ -d "$VERIFY_DIR/Parrot Lab.app" ] || fail "release ZIP does not contain Parrot Lab.app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$VERIFY_DIR/Parrot Lab.app"

mv -f "$STAGE_ZIP" "$OUTPUT_ZIP"

printf '%s\n' "Created ad-hoc-signed, non-notarized release:"
printf '%s\n' "$OUTPUT_ZIP"
/usr/bin/shasum -a 256 "$OUTPUT_ZIP"
