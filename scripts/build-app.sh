#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
DIST_DIR="$PROJECT_DIR/dist"
LEGACY_APP_DIR="$DIST_DIR/Parrot Lab.app"
INSTALL_DIR="${PARROTLAB_INSTALL_DIR:-$HOME/Applications}"
APP_DIR="$INSTALL_DIR/Parrot Lab.app"
ZIP_PATH="$DIST_DIR/Parrot-Lab-macOS-arm64.zip"
STAGE_DIR=$(/usr/bin/mktemp -d /tmp/parrotlab-build.XXXXXX)
STAGE_APP="$STAGE_DIR/Parrot Lab.app"
STAGE_ZIP="$STAGE_DIR/Parrot-Lab-macOS-arm64.zip"
trap '/bin/rm -rf "$STAGE_DIR"' EXIT HUP INT TERM

cd "$PROJECT_DIR"
swift build -c release

mkdir -p "$STAGE_APP/Contents/MacOS" "$STAGE_APP/Contents/Resources/DeviceTools" "$DIST_DIR" "$INSTALL_DIR"
COPYFILE_DISABLE=1 cp "$PROJECT_DIR/.build/release/ParrotLab" "$STAGE_APP/Contents/MacOS/ParrotLab"
COPYFILE_DISABLE=1 cp "$PROJECT_DIR/Resources/Info.plist" "$STAGE_APP/Contents/Info.plist"
COPYFILE_DISABLE=1 cp "$PROJECT_DIR/Resources/ParrotLabIcon.png" "$STAGE_APP/Contents/Resources/ParrotLabIcon.png"
COPYFILE_DISABLE=1 cp "$PROJECT_DIR/Resources/ParrotLab.icns" "$STAGE_APP/Contents/Resources/ParrotLab.icns"
COPYFILE_DISABLE=1 cp "$PROJECT_DIR/patched/dragon-prog-1080p-mode1-30fps" "$STAGE_APP/Contents/Resources/DeviceTools/dragon-prog-1080p-mode1-30fps"
COPYFILE_DISABLE=1 cp "$PROJECT_DIR/tools/parrotlab_dragon_video.sh" "$STAGE_APP/Contents/Resources/DeviceTools/parrotlab_dragon_video.sh"
COPYFILE_DISABLE=1 cp "$PROJECT_DIR/tools/parrot_rf_lab.sh" "$STAGE_APP/Contents/Resources/DeviceTools/parrot_rf_lab.sh"
COPYFILE_DISABLE=1 cp "$PROJECT_DIR/sc2/install.sh" "$STAGE_APP/Contents/Resources/DeviceTools/install_sc2_apple_ncm.sh"
COPYFILE_DISABLE=1 cp "$PROJECT_DIR/sc2/apple_mac_ncm.ko" "$STAGE_APP/Contents/Resources/DeviceTools/apple_mac_ncm.ko"
chmod 755 "$STAGE_APP/Contents/Resources/DeviceTools/dragon-prog-1080p-mode1-30fps" \
    "$STAGE_APP/Contents/Resources/DeviceTools/parrotlab_dragon_video.sh" \
    "$STAGE_APP/Contents/Resources/DeviceTools/parrot_rf_lab.sh" \
    "$STAGE_APP/Contents/Resources/DeviceTools/install_sc2_apple_ncm.sh"
chmod 644 "$STAGE_APP/Contents/Resources/DeviceTools/apple_mac_ncm.ko"
FFMPEG_SOURCE=${PARROTLAB_FFMPEG:-}
if [ -z "$FFMPEG_SOURCE" ] && [ -x "$APP_DIR/Contents/Resources/ffmpeg-parrotlab" ]; then
    FFMPEG_SOURCE="$APP_DIR/Contents/Resources/ffmpeg-parrotlab"
fi
if [ -z "$FFMPEG_SOURCE" ] && [ -x "$LEGACY_APP_DIR/Contents/Resources/ffmpeg-parrotlab" ]; then
    FFMPEG_SOURCE="$LEGACY_APP_DIR/Contents/Resources/ffmpeg-parrotlab"
fi
if [ -n "$FFMPEG_SOURCE" ]; then
    COPYFILE_DISABLE=1 cp "$FFMPEG_SOURCE" "$STAGE_APP/Contents/Resources/ffmpeg-parrotlab"
    chmod 755 "$STAGE_APP/Contents/Resources/ffmpeg-parrotlab"
fi
chmod 755 "$STAGE_APP/Contents/MacOS/ParrotLab"

# Sign outside Documents: File Provider reapplies FinderInfo to .app bundles
# there quickly enough to make codesign reject an otherwise clean bundle.
xattr -cr "$STAGE_APP"
codesign --force --deep --sign - "$STAGE_APP"
codesign --verify --deep --strict "$STAGE_APP"

(
    cd "$STAGE_DIR"
    /usr/bin/zip -qry -X "$STAGE_ZIP" "$(basename "$STAGE_APP")"
)

PREVIOUS_APP="$STAGE_DIR/previous-Parrot-Lab.app"
if [ -e "$APP_DIR" ]; then
    mv "$APP_DIR" "$PREVIOUS_APP"
fi
if ! ditto --noextattr --noqtn "$STAGE_APP" "$APP_DIR" || ! codesign --verify --deep --strict "$APP_DIR"; then
    if [ -e "$APP_DIR" ]; then
        mv "$APP_DIR" "$STAGE_DIR/failed-Parrot-Lab.app"
    fi
    if [ -e "$PREVIOUS_APP" ]; then
        mv "$PREVIOUS_APP" "$APP_DIR"
    fi
    exit 1
fi

mv -f "$STAGE_ZIP" "$ZIP_PATH"

# Older builds left a second launchable copy inside dist. The installed app is
# now the single canonical copy; dist contains only the distributable archive.
if [ "$LEGACY_APP_DIR" != "$APP_DIR" ] && [ -e "$LEGACY_APP_DIR" ]; then
    mv "$LEGACY_APP_DIR" "$STAGE_DIR/legacy-dist-Parrot-Lab.app"
fi

printf '%s\n' "$APP_DIR"
printf '%s\n' "$ZIP_PATH"
