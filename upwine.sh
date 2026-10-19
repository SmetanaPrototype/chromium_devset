#!/usr/bin/env bash
#
# wine-update.sh — incremental rebuild of changed Wine DLLs.
#
# Design notes:
#   * Only touch dlls that already have a built artifact in this tree.
#   * Use `make -q` with a timeout per dll — Wine's makefiles can make -q
#     slow (and it returns 1 for "Makefile stale", not just "target stale").
#   * Never rm built artifacts. Let make decide what is stale.
#   * Keep going if one target fails; report at the end.
#   * Ask for sudo once, up front — never surprise-prompt mid-run.

set -uo pipefail

WINE_PREFIX="${WINEPREFIX:-$HOME/.wine}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local}"
INSTALL_LIB="$INSTALL_PREFIX/lib/wine"

read -ra SKIP_DLLS <<<"${SKIP_DLLS:-wineandroid.drv}"

usage() {
    cat <<'EOF'
Usage: wine-update.sh [wine_src]

  wine_src   Path to the Wine source tree. If omitted, auto-detected by
             walking up from the current directory, then $WINE_SRC,
             then ~/wine.

Environment:
  WINEPREFIX        Wine prefix (default: ~/.wine)
  INSTALL_PREFIX    make install prefix (default: /usr/local)
  WINE_SRC          Fallback path to the Wine sources
  SKIP_DLLS         Space-separated dlls to skip (default: wineandroid.drv)
EOF
}

detect_wine_src() {
    local dir="$PWD"
    while [ "$dir" != "/" ]; do
        if [ -f "$dir/configure" ] && [ -f "$dir/dlls/ntdll/ntdll.spec" ]; then
            echo "$dir"; return 0
        fi
        dir=$(dirname "$dir")
    done
    return 1
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac
[ $# -gt 1 ] && { echo "ERROR: too many arguments: $*" >&2; usage >&2; exit 1; }

if [ $# -eq 1 ]; then
    WINE_SRC="$1"
elif detected=$(detect_wine_src); then
    WINE_SRC="$detected"
    echo ">>> Wine src: $WINE_SRC" >&2
else
    WINE_SRC="${WINE_SRC:-$HOME/wine}"
fi

[ -d "$WINE_SRC/dlls" ] || {
    echo "ERROR: $WINE_SRC/dlls not found." >&2
    echo "Run from the wine source tree or pass it as an argument." >&2
    exit 1
}

cd "$WINE_SRC"

# --- Ask for sudo once, up front. If the user cannot sudo, fail early. ---
if [ "$(id -u)" -ne 0 ]; then
    echo ">>> Requesting sudo (needed later for 'make install')..." >&2
    sudo -v || { echo "ERROR: sudo required" >&2; exit 1; }
fi

# --- Fast ownership check: only built artifacts, not the whole tree. ---
if [ "$(id -u)" -ne 0 ]; then
    echo ">>> Checking ownership of build artifacts..." >&2
    # Target the only directories that contain build outputs.
    bad=$(find dlls -maxdepth 3 \
            \( -name '*.dll' -o -name '*.so' -o -name '*.o' -o -name '*.a' \) \
            ! -user "$(id -u)" -print -quit 2>/dev/null)
    if [ -n "$bad" ]; then
        echo ">>> Found file not owned by $USER: $bad" >&2
        echo ">>> Fixing ownership (this may take a moment)..." >&2
        # Limit chown to dlls/ to avoid touching .git and other huge subtrees.
        sudo chown -Rh "$USER:$(id -gn)" dlls
    fi
fi

is_skipped() {
    local name="$1" s
    for s in "${SKIP_DLLS[@]}"; do [ "$s" = "$name" ] && return 0; done
    return 1
}

has_built_artifact() {
    local dir="$1" name="$2"
    [ -f "$dir/x86_64-windows/$name.dll" ] && return 0
    [ -f "$dir/i386-windows/$name.dll"   ] && return 0
    [ -f "$dir/x86_64-windows/$name.drv" ] && return 0
    [ -f "$dir/i386-windows/$name.drv"   ] && return 0
    [ -f "$dir/$name.so"                 ] && return 0
    return 1
}

# How long we allow a single `make -q` to take before giving up on it.
MAKE_Q_TIMEOUT="${MAKE_Q_TIMEOUT:-10}"

detect_changed() {
    local dll_dir dll_name rc total=0 done_=0
    local -a dirs=()
    for dll_dir in dlls/*/; do
        dll_name=$(basename "$dll_dir")
        is_skipped "$dll_name" && continue
        has_built_artifact "$dll_dir" "$dll_name" || continue
        dirs+=("$dll_name")
    done
    total=${#dirs[@]}
    echo ">>> Scanning $total built dlls for staleness..." >&2

    for dll_name in "${dirs[@]}"; do
        done_=$((done_ + 1))
        printf '\r>>> [%d/%d] checking dlls/%s\033[K' "$done_" "$total" "$dll_name" >&2
        timeout "$MAKE_Q_TIMEOUT" make -q -C "dlls/$dll_name" >/dev/null 2>&1
        rc=$?
        case "$rc" in
            0) : ;;                       # up to date
            1) echo "$dll_name" ;;        # needs rebuild
            124) : ;;                     # timeout — skip, don't hang
            *) : ;;                       # error — skip
        esac
    done
    echo >&2
}

mapfile -t changed < <(detect_changed)

if [ ${#changed[@]} -eq 0 ]; then
    echo "Nothing to update."
    exit 0
fi

echo "Rebuild targets: ${changed[*]}"
echo

failures=()
for dll in "${changed[@]}"; do
    echo ">>> make -C dlls/$dll"
    if ! make -C "dlls/$dll"; then
        failures+=("$dll")
    fi
done

if [ ${#failures[@]} -gt 0 ]; then
    echo
    echo ">>> WARNING: these targets failed to build: ${failures[*]}" >&2
    echo ">>> Continuing with install for the targets that succeeded." >&2
fi
echo

echo ">>> sudo make install"
sudo make install
echo

echo ">>> Copy to prefix $WINE_PREFIX"
for dll in "${changed[@]}"; do
    skip=0
    for f in "${failures[@]:-}"; do
        [ "$f" = "$dll" ] && skip=1 && break
    done
    [ "$skip" = 1 ] && continue

    src="$INSTALL_LIB/x86_64-windows/$dll.dll"
    dst="$WINE_PREFIX/drive_c/windows/system32/$dll.dll"
    [ -f "$src" ] && [ -e "$dst" ] && cp -v "$src" "$dst"

    src="$INSTALL_LIB/i386-windows/$dll.dll"
    dst="$WINE_PREFIX/drive_c/windows/syswow64/$dll.dll"
    [ -f "$src" ] && [ -e "$dst" ] && cp -v "$src" "$dst"
done
echo

echo "Ready."
