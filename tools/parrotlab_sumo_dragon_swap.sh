#!/bin/sh
# Preserve both executables. Link before renaming so a power loss never leaves
# the stock startup path missing. No process is stopped and no reboot is issued.
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
ROOT=
if [ -n "${PARROTLAB_SUMO_SWAP_TEST_ROOT:-}" ]; then
    case "$PARROTLAB_SUMO_SWAP_TEST_ROOT" in /tmp/parrotlab-sumo-swap-test.*) ;; *) exit 2 ;; esac
    ROOT=$PARROTLAB_SUMO_SWAP_TEST_ROOT
    [ -f "$ROOT/.parrotlab-test-root" ] && [ ! -L "$ROOT" ] || exit 2
    PATH=$ROOT/test-bin:$PATH
    export PATH
fi
ACTIVE=$ROOT/usr/bin/dragon-prog
ORIGINAL=$ROOT/usr/bin/dragon-prog.parrotlab-original
B29=$ROOT/usr/bin/B29
STATE=$ROOT/usr/bin/dragon-prog.parrotlab-state
UPLOAD=$ROOT/data/ftp/internal_000/parrotlab-sumo-B29.upload
LOCK=$ROOT/tmp/parrotlab-sumo-dragon-swap.lock
STAGE=$ROOT/usr/bin/.parrotlab-B29.$$
STATE_STAGE=$ROOT/usr/bin/.parrotlab-dragon-state.$$
RESTORE_RO=0
LOCKED=0

error() { printf '__PARROTLAB_SUMO_SWAP__=ERROR:%s\n' "$1" >&2; exit 1; }
valid_digest() { [ "${#1}" = 32 ] && case "$1" in *[!0-9a-f]*) return 1 ;; *) return 0 ;; esac; }
digest() { D=$(md5sum "$1") || return 1; printf '%s\n' "${D%% *}"; }
matches() { [ -f "$1" ] && [ ! -L "$1" ] && [ "$(digest "$1")" = "$2" ]; }
root_is_rw() { mount | awk '$3 == "/" {rw=($0 ~ /\(rw[,)]/)} END {exit(rw ? 0 : 1)}'; }
restore_root() {
    [ "$RESTORE_RO" = 1 ] || return 0
    mount -o remount,ro / && ! root_is_rw || return 1
    RESTORE_RO=0
}
cleanup() {
    rm -f "$STAGE" "$STATE_STAGE"
    restore_root || printf '%s\n' '__PARROTLAB_SUMO_SWAP__=ERROR:ROOT_LEFT_WRITABLE' >&2
    [ "$LOCKED" = 0 ] || rmdir "$LOCK" 2>/dev/null
}
trap cleanup 0
trap 'exit 130' HUP INT TERM

ACTION=${1:-}
case "$ACTION" in
    install) EXPECTED=${2:-}; valid_digest "$EXPECTED" || error INVALID_DIGEST ;;
    restore) EXPECTED= ;;
    *) error 'USAGE_install_MD5_or_restore' ;;
esac
[ "$(id -u)" = 0 ] || error ROOT_REQUIRED
[ -x "$ROOT/bin/DragonStarter.sh" ] || error NOT_SUMO_STARTER
for file in "$ACTIVE" "$ORIGINAL" "$B29" "$STATE" "$UPLOAD"; do
    [ ! -L "$file" ] || error SYMLINK_REFUSED
    [ ! -e "$file" ] || [ -f "$file" ] || error NON_REGULAR_FILE
done
mkdir "$LOCK" 2>/dev/null || error OPERATION_LOCKED
LOCKED=1
[ -x "$ACTIVE" ] || error ACTIVE_DRAGON_MISSING

if [ -e "$STATE" ]; then
    read -r STOCK_MD5 B29_MD5 EXTRA < "$STATE" || error INVALID_STATE
    valid_digest "$STOCK_MD5" && valid_digest "$B29_MD5" && [ -z "$EXTRA" ] &&
        [ "$STOCK_MD5" != "$B29_MD5" ] || error INVALID_STATE
else
    [ "$ACTION" = install ] || error ORIGINAL_RECORD_MISSING
    [ ! -e "$ORIGINAL" ] || error UNMANAGED_BACKUP
    STOCK_MD5=$(digest "$ACTIVE") || error ACTIVE_DIGEST
    B29_MD5=$EXPECTED
    [ "$STOCK_MD5" != "$B29_MD5" ] || error ORIGINAL_ALREADY_REPLACED
fi
[ ! -e "$ORIGINAL" ] || matches "$ORIGINAL" "$STOCK_MD5" || error ORIGINAL_BACKUP_CHANGED
CURRENT=$(digest "$ACTIVE") || error ACTIVE_DIGEST
case "$CURRENT" in "$STOCK_MD5"|"$B29_MD5") ;; *) error ACTIVE_DRAGON_CHANGED ;; esac
[ ! -e "$B29" ] || matches "$B29" "$B29_MD5" || error UNMANAGED_B29

if [ "$ACTION" = install ]; then
    [ "$EXPECTED" = "$B29_MD5" ] || error DIFFERENT_B29_BUILD
    matches "$UPLOAD" "$EXPECTED" || error UPLOAD_DIGEST
    if [ "$CURRENT" = "$B29_MD5" ]; then
        matches "$ORIGINAL" "$STOCK_MD5" || error ORIGINAL_BACKUP_MISSING
        printf '%s\n' '__PARROTLAB_SUMO_SWAP__=ALREADY_INSTALLED'
        exit 0
    fi
elif [ "$CURRENT" = "$B29_MD5" ]; then
    matches "$ORIGINAL" "$STOCK_MD5" || error ORIGINAL_BACKUP_MISSING
elif [ ! -e "$ORIGINAL" ]; then
    printf '%s\n' '__PARROTLAB_SUMO_SWAP__=ALREADY_ORIGINAL'
    exit 0
fi

if ! root_is_rw; then
    RESTORE_RO=1
    mount -o remount,rw / && root_is_rw || error ROOT_NOT_WRITABLE
fi

if [ "$ACTION" = install ]; then
    cp "$UPLOAD" "$STAGE" && chmod 755 "$STAGE" && matches "$STAGE" "$B29_MD5" || error STAGING_FAILED
    if [ ! -e "$STATE" ]; then
        printf '%s %s\n' "$STOCK_MD5" "$B29_MD5" > "$STATE_STAGE" &&
            mv "$STATE_STAGE" "$STATE" || error STATE_WRITE_FAILED
    fi
    # Never overwrite the original backup, including after an interrupted run.
    if [ ! -e "$ORIGINAL" ]; then ln "$ACTIVE" "$ORIGINAL" || error BACKUP_FAILED; fi
    matches "$ORIGINAL" "$STOCK_MD5" || error BACKUP_VERIFY_FAILED
    mv "$STAGE" "$B29" && sync || error STAGING_FAILED
    mv -f "$B29" "$ACTIVE" || error INSTALL_RENAME_FAILED
    matches "$ACTIVE" "$B29_MD5" && matches "$ORIGINAL" "$STOCK_MD5" || error INSTALL_VERIFY_FAILED
    RESULT=INSTALLED
else
    if [ "$CURRENT" = "$B29_MD5" ]; then
        if [ ! -e "$B29" ]; then ln "$ACTIVE" "$B29" || error B29_PRESERVE_FAILED; fi
        matches "$B29" "$B29_MD5" && sync || error B29_PRESERVE_FAILED
        mv -f "$ORIGINAL" "$ACTIVE" || error RESTORE_RENAME_FAILED
        RESULT=RESTORED
    else
        # A previous install may have stopped after preserving the original.
        if [ -e "$ORIGINAL" ]; then rm "$ORIGINAL" || error BACKUP_UNLINK_FAILED; fi
        RESULT=ALREADY_ORIGINAL
    fi
    matches "$ACTIVE" "$STOCK_MD5" || error RESTORE_VERIFY_FAILED
fi
sync || error SYNC_FAILED
restore_root || error READ_ONLY_RESTORE_FAILED
printf '__PARROTLAB_SUMO_SWAP__=%s\n' "$RESULT"
