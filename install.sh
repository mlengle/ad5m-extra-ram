#!/bin/sh
# extra-ram installer: run from the unpacked repository, as root, over SSH.
#   install.sh [--experimental] [--yes]
# Copies the files into place (overwriting an older version; the state in /etc/extra-ram is not touched)
# and runs "extra-ram install", which does the checks and arms the mode. XR_* variables override the paths.

XR_SRCDIR=$(cd "$(dirname "$0")" && pwd)/src
if [ ! -f "$XR_SRCDIR/lib.sh" ] || [ ! -f "$XR_SRCDIR/extra-ram" ] || [ ! -f "$XR_SRCDIR/S45xram" ]; then
    echo "install.sh: src/lib.sh, src/extra-ram or src/S45xram not found next to the script" >&2
    exit 1
fi
. "$XR_SRCDIR/lib.sh"

if [ "${XR_UID:-$(id -u)}" != 0 ]; then
    xr_msg "install.sh: нужны права root (запускайте от root)" "install.sh: must be run as root" >&2
    exit 1
fi

# xr_put_file SRC DEST MODE: copy through a temporary name and rename, so a running copy never sees a half-written file
xr_put_file() {
    cp -f "$1" "$2.new" && chmod "$3" "$2.new" && mv -f "$2.new" "$2"
}

xr_install_fail() {
    xr_msg "install.sh: не удалось скопировать файлы ($1)" "install.sh: cannot copy the files ($1)" >&2
    exit 1
}

mkdir -p "$XR_CODE" "$(dirname "$XR_INIT")" || xr_install_fail "mkdir"
xr_put_file "$XR_SRCDIR/lib.sh" "$XR_CODE/lib.sh" 644 || xr_install_fail "lib.sh"
xr_put_file "$XR_SRCDIR/extra-ram" "$XR_CODE/extra-ram" 755 || xr_install_fail "extra-ram"
if [ -d "$XR_SRCDIR/test" ]; then
    mkdir -p "$XR_CODE/test" || xr_install_fail "test"
    for xr_f in "$XR_SRCDIR"/test/*; do
        [ -f "$xr_f" ] || continue
        xr_put_file "$xr_f" "$XR_CODE/test/$(basename "$xr_f")" 755 || xr_install_fail "$xr_f"
    done
fi
xr_put_file "$XR_SRCDIR/S45xram" "$XR_INIT" 755 || xr_install_fail "$XR_INIT"

exec "$XR_CODE/extra-ram" install "$@"
