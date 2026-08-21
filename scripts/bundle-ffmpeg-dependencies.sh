#!/bin/sh
# Make Contents/Resources/ffmpeg-parrotlab portable by copying every
# non-system Mach-O dependency into Contents/Frameworks and rewriting paths.

set -eu

fail()
{
    printf '%s\n' "bundle-ffmpeg-dependencies: $*" >&2
    exit 1
}

[ "$#" -eq 1 ] || {
    printf '%s\n' "Usage: $0 \"/path/to/Parrot Lab.app\"" >&2
    exit 2
}

case "$1" in
    /*) APP_DIR=$1 ;;
    *) APP_DIR="$(pwd)/$1" ;;
esac

FFMPEG="$APP_DIR/Contents/Resources/ffmpeg-parrotlab"
FRAMEWORKS="$APP_DIR/Contents/Frameworks"
[ -x "$FFMPEG" ] || fail "Contents/Resources/ffmpeg-parrotlab is missing or not executable"

FFMPEG_ARCHS=$(/usr/bin/lipo -archs "$FFMPEG" 2>/dev/null) || fail "FFmpeg is not a Mach-O executable"
printf '%s\n' "$FFMPEG_ARCHS" | /usr/bin/grep -Eq '(^|[[:space:]])arm64($|[[:space:]])' || \
    fail "FFmpeg does not contain an arm64 slice"

mkdir -p "$FRAMEWORKS"
WORK_DIR=$(/usr/bin/mktemp -d /tmp/parrotlab-ffmpeg-bundle.XXXXXX)
QUEUE="$WORK_DIR/queue"
PROCESSED="$WORK_DIR/processed"
SOURCE_MAP="$WORK_DIR/source-map"
DEPENDENCIES="$WORK_DIR/dependencies"
RPATHS="$WORK_DIR/rpaths"
trap '/bin/rm -rf "$WORK_DIR"' EXIT HUP INT TERM

: > "$PROCESSED"
: > "$SOURCE_MAP"
printf '%s\n' "$FFMPEG" > "$QUEUE"

is_system_path()
{
    case "$1" in
        /System/*|/usr/lib/*) return 0 ;;
        *) return 1 ;;
    esac
}

source_for_binary()
{
    BINARY=$1
    if [ "$BINARY" = "$FFMPEG" ]; then
        printf '%s\n' "$FFMPEG"
        return 0
    fi
    NAME=$(basename "$BINARY")
    /usr/bin/awk -F '\t' -v name="$NAME" '$1 == name { print $2; exit }' "$SOURCE_MAP"
}

resolve_dependency()
{
    DEPENDENCY=$1
    LOADER=$2
    ORIGIN=$(source_for_binary "$LOADER")
    [ -n "$ORIGIN" ] || ORIGIN=$LOADER
    ORIGIN_DIR=$(dirname "$ORIGIN")

    case "$DEPENDENCY" in
        /*)
            [ -f "$DEPENDENCY" ] && printf '%s\n' "$DEPENDENCY" && return 0
            ;;
        @loader_path/*)
            RELATIVE=${DEPENDENCY#@loader_path/}
            [ -f "$ORIGIN_DIR/$RELATIVE" ] && printf '%s\n' "$ORIGIN_DIR/$RELATIVE" && return 0
            [ -f "$(dirname "$LOADER")/$RELATIVE" ] && \
                printf '%s\n' "$(dirname "$LOADER")/$RELATIVE" && return 0
            ;;
        @executable_path/*)
            RELATIVE=${DEPENDENCY#@executable_path/}
            [ -f "$(dirname "$FFMPEG")/$RELATIVE" ] && \
                printf '%s\n' "$(dirname "$FFMPEG")/$RELATIVE" && return 0
            ;;
        @rpath/*)
            RELATIVE=${DEPENDENCY#@rpath/}
            [ -f "$FRAMEWORKS/$(basename "$RELATIVE")" ] && \
                printf '%s\n' "$FRAMEWORKS/$(basename "$RELATIVE")" && return 0
            /usr/bin/otool -l "$ORIGIN" 2>/dev/null | \
                /usr/bin/awk '/cmd LC_RPATH/{getline; getline; print $2}' > "$RPATHS"
            while IFS= read -r RPATH; do
                case "$RPATH" in
                    @loader_path/*) ROOT="$ORIGIN_DIR/${RPATH#@loader_path/}" ;;
                    @executable_path/*) ROOT="$(dirname "$FFMPEG")/${RPATH#@executable_path/}" ;;
                    /*) ROOT=$RPATH ;;
                    *) continue ;;
                esac
                if [ -f "$ROOT/$RELATIVE" ]; then
                    printf '%s\n' "$ROOT/$RELATIVE"
                    return 0
                fi
            done < "$RPATHS"
            ;;
    esac
    return 1
}

INDEX=1
while :; do
    BINARY=$(/usr/bin/sed -n "${INDEX}p" "$QUEUE")
    [ -n "$BINARY" ] || break
    INDEX=$((INDEX + 1))
    /usr/bin/grep -Fqx "$BINARY" "$PROCESSED" && continue
    printf '%s\n' "$BINARY" >> "$PROCESSED"

    /usr/bin/otool -L "$BINARY" 2>/dev/null | /usr/bin/tail -n +2 | \
        /usr/bin/sed -E 's/^[[:space:]]+([^[:space:]]+).*/\1/' > "$DEPENDENCIES" || \
        fail "could not inspect $BINARY"
    MACHO_ID=$(/usr/bin/otool -D "$BINARY" 2>/dev/null | /usr/bin/sed -n '2p')

    while IFS= read -r DEPENDENCY; do
        [ -n "$DEPENDENCY" ] || continue
        [ -n "$MACHO_ID" ] && [ "$DEPENDENCY" = "$MACHO_ID" ] && continue
        is_system_path "$DEPENDENCY" && continue

        RESOLVED=$(resolve_dependency "$DEPENDENCY" "$BINARY") || \
            fail "cannot resolve non-system dependency $DEPENDENCY required by $(basename "$BINARY")"

        # A relative dependency may resolve to a system path. Make that path
        # explicit rather than copying an operating-system library.
        if is_system_path "$RESOLVED"; then
            /usr/bin/install_name_tool -change "$DEPENDENCY" "$RESOLVED" "$BINARY"
            continue
        fi
        case "$RESOLVED" in
            *.framework/*) fail "non-system framework dependencies are not supported: $RESOLVED" ;;
        esac

        LIBRARY_NAME=$(basename "$RESOLVED")
        TARGET="$FRAMEWORKS/$LIBRARY_NAME"
        ARCHS=$(/usr/bin/lipo -archs "$RESOLVED" 2>/dev/null) || \
            fail "$RESOLVED is not a Mach-O library"
        printf '%s\n' "$ARCHS" | /usr/bin/grep -Eq '(^|[[:space:]])arm64($|[[:space:]])' || \
            fail "$RESOLVED does not contain an arm64 slice"

        EXISTING_SOURCE=$(/usr/bin/awk -F '\t' -v name="$LIBRARY_NAME" \
            '$1 == name { print $2; exit }' "$SOURCE_MAP")
        if [ -n "$EXISTING_SOURCE" ] && [ "$EXISTING_SOURCE" != "$RESOLVED" ]; then
            fail "two different libraries share the name $LIBRARY_NAME"
        fi
        if [ ! -f "$TARGET" ]; then
            COPYFILE_DISABLE=1 /bin/cp -L "$RESOLVED" "$TARGET"
            chmod 755 "$TARGET"
        fi
        if [ -z "$EXISTING_SOURCE" ]; then
            printf '%s\t%s\n' "$LIBRARY_NAME" "$RESOLVED" >> "$SOURCE_MAP"
        fi

        if [ "$BINARY" = "$FFMPEG" ]; then
            NEW_REFERENCE="@executable_path/../Frameworks/$LIBRARY_NAME"
        else
            NEW_REFERENCE="@loader_path/$LIBRARY_NAME"
        fi
        [ "$DEPENDENCY" = "$NEW_REFERENCE" ] || \
            /usr/bin/install_name_tool -change "$DEPENDENCY" "$NEW_REFERENCE" "$BINARY"
        printf '%s\n' "$TARGET" >> "$QUEUE"
    done < "$DEPENDENCIES"

    if [ "$BINARY" != "$FFMPEG" ]; then
        /usr/bin/install_name_tool -id "@rpath/$(basename "$BINARY")" "$BINARY"
    fi
done

# Reject any unresolved package-manager/local dependency after rewriting.
while IFS= read -r BINARY; do
    /usr/bin/otool -L "$BINARY" 2>/dev/null | /usr/bin/tail -n +2 | \
        /usr/bin/sed -E 's/^[[:space:]]+([^[:space:]]+).*/\1/' > "$DEPENDENCIES"
    MACHO_ID=$(/usr/bin/otool -D "$BINARY" 2>/dev/null | /usr/bin/sed -n '2p')
    while IFS= read -r DEPENDENCY; do
        [ -n "$DEPENDENCY" ] || continue
        [ -n "$MACHO_ID" ] && [ "$DEPENDENCY" = "$MACHO_ID" ] && continue
        is_system_path "$DEPENDENCY" && continue
        if [ "$BINARY" = "$FFMPEG" ]; then
            case "$DEPENDENCY" in
                @executable_path/../Frameworks/*)
                    REQUIRED="$FRAMEWORKS/${DEPENDENCY#@executable_path/../Frameworks/}"
                    ;;
                *) fail "FFmpeg retains an external dependency: $DEPENDENCY" ;;
            esac
        else
            case "$DEPENDENCY" in
                @loader_path/*) REQUIRED="$FRAMEWORKS/${DEPENDENCY#@loader_path/}" ;;
                *) fail "$(basename "$BINARY") retains an external dependency: $DEPENDENCY" ;;
            esac
        fi
        [ -f "$REQUIRED" ] || fail "rewritten dependency is missing: $REQUIRED"
    done < "$DEPENDENCIES"
done < "$PROCESSED"

# This must succeed without Homebrew paths or DYLD_* overrides.
env -u DYLD_LIBRARY_PATH -u DYLD_FALLBACK_LIBRARY_PATH \
    "$FFMPEG" -version >/dev/null 2>&1 || fail "bundled FFmpeg cannot start"

LIBRARY_COUNT=$(/usr/bin/find "$FRAMEWORKS" -type f | /usr/bin/wc -l | /usr/bin/tr -d ' ')
printf '%s\n' "Bundled FFmpeg with $LIBRARY_COUNT non-system dylib(s) in Contents/Frameworks"
