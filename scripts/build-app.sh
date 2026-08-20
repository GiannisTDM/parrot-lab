#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
DIST_DIR="$PROJECT_DIR/dist"
INSTALL_DIR="${PARROTLAB_INSTALL_DIR:-$HOME/Applications}"
APP_DIR="$INSTALL_DIR/Parrot Lab.app"
ZIP_PATH="$DIST_DIR/Parrot-Lab-macOS-arm64.zip"
STAGE_DIR=$(/usr/bin/mktemp -d /tmp/parrotlab-build.XXXXXX)
STAGE_APP="$STAGE_DIR/Parrot Lab.app"
STAGE_ZIP="$STAGE_DIR/Parrot-Lab-macOS-arm64.zip"

cleanup()
{
    /bin/rm -rf "$STAGE_DIR"
}
trap cleanup EXIT HUP INT TERM

cd "$PROJECT_DIR"
swift build -c release

mkdir -p "$STAGE_APP/Contents/MacOS" "$STAGE_APP/Contents/Resources"
mkdir -p "$DIST_DIR" "$INSTALL_DIR"
COPYFILE_DISABLE=1 cp .build/release/ParrotLab "$STAGE_APP/Contents/MacOS/ParrotLab"
COPYFILE_DISABLE=1 cp Resources/Info.plist "$STAGE_APP/Contents/Info.plist"

if [ -n "${PARROTLAB_FFMPEG:-}" ]; then
    if [ ! -x "$PARROTLAB_FFMPEG" ]; then
        echo "ERROR: PARROTLAB_FFMPEG is not executable: $PARROTLAB_FFMPEG" >&2
        exit 1
    fi
    COPYFILE_DISABLE=1 cp "$PARROTLAB_FFMPEG" "$STAGE_APP/Contents/Resources/ffmpeg-parrotlab"
    chmod 755 "$STAGE_APP/Contents/Resources/ffmpeg-parrotlab"
fi

chmod 755 "$STAGE_APP/Contents/MacOS/ParrotLab"
xattr -cr "$STAGE_APP"
codesign --force --deep --sign - "$STAGE_APP"
codesign --verify --deep --strict "$STAGE_APP"

(
    cd "$STAGE_DIR"
    /usr/bin/zip -qry -X "$STAGE_ZIP" "$(basename "$STAGE_APP")"
)

if [ -e "$APP_DIR" ]; then
    mv "$APP_DIR" "$STAGE_DIR/previous-Parrot-Lab.app"
fi

if ! ditto --noextattr --noqtn "$STAGE_APP" "$APP_DIR"; then
    if [ -e "$STAGE_DIR/previous-Parrot-Lab.app" ]; then
        mv "$STAGE_DIR/previous-Parrot-Lab.app" "$APP_DIR"
    fi
    exit 1
fi

codesign --verify --deep --strict "$APP_DIR"
mv -f "$STAGE_ZIP" "$ZIP_PATH"

printf 'Installed: %s\n' "$APP_DIR"
printf 'Archive:   %s\n' "$ZIP_PATH"
