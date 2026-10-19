#!/usr/bin/env bash
#
# wine-update.sh — incremental rebuild of changed Wine DLLs.
#
# Strategy:
#   * Only consider dlls that already have at least one built artifact
#     (windows .dll / windows .drv / unix .so). If none, skip — this tree
#     never built it, so don't start now.
#   * Ask `make -q` whether the dll subdir is up to date.
#       0 = up to date    -> skip
#       1 = needs rebuild -> include
#       >1 = error        -> skip (e.g. missing optional toolchain)
#   * Never rm built artifacts. Let make decide what's stale.
#   * Keep going if one target fails; report at the end.

set -uo pipefail   # NOTE: no -e here — one dll failing must not abort everything

WINE_PREFIX="${WINEPREFIX:-$HOME/.wine}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local}"
INSTALL_LIB="$INSTALL_PREFIX/lib/wine"

# Targets that need optional toolchains (Android SDK/gradle, etc.)
# and should be skipped unless explicitly requested.
# Override via env: SKIP_DLLS="wineandroid.drv winefoo.drv"
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
            echo "$dir"
            return 0
        fi
        dir=$(dirname "$dir")
    done
    return 1
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac

if [ $# -gt 1 ]; then
    echo "ERROR: too many arguments: $*" >&2
    usage >&2
    exit 1
fi

if [ $# -eq 1 ]; then
    WINE_SRC="$1"
elif detected=$(detect_wine_src); then
    WINE_SRC="$detected"
    echo ">>> Wine src: $WINE_SRC" >&2
else
    WINE_SRC="${WINE_SRC:-$HOME/wine}"
fi

if [ ! -d "$WINE_SRC/dlls" ]; then
    echo "ERROR: $WINE_SRC/dlls not found." >&2
    echo "Run from the wine source tree or pass it as an argument." >&2
    exit 1
fi

cd "$WINE_SRC"

# --- Fix ownership of build artifacts if needed (unchanged) ---
if [ "$(id -u)" -ne 0 ]; then
    owner_mismatch=$(find . -maxdepth 4 \
        \( -name '*.dll' -o -name '*.so' -o -name '*.o' -o -name '*.a' \) \
        ! -user "$(id -u)" -print -quit 2>/dev/null)
    if [ -n "$owner_mismatch" ]; then
        echo ">>> Found file not owned by $USER: $owner_mismatch" >&2
        echo ">>> Fixing ownership of the source tree ..." >&2
        sudo chown -Rh "$USER:$(id -gn)" .
    fi
fi

is_skipped() {
    local name="$1" s
    for s in "${SKIP_DLLS[@]}"; do
        [ "$s" = "$name" ] && return 0
    done
    return 1
}

# Return 0 if this dll has at least one built artifact in this tree.
# Covers windows .dll, windows .drv, and unix .so (top-level).
has_built_artifact() {
    local dir="$1" name="$2"
    [ -f "$dir/x86_64-windows/$name.dll" ] && return 0
    [ -f "$dir/i386-windows/$name.dll"   ] && return 0
    [ -f "$dir/x86_64-windows/$name.drv" ] && return 0
    [ -f "$dir/i386-windows/$name.drv"   ] && return 0
    [ -f "$dir/$name.so"                 ] && return 0
    return 1
}

detect_changed() {
    local dll_dir dll_name rc
    for dll_dir in dlls/*/; do
        dll_name=$(basename "$dll_dir")

        is_skipped "$dll_name" && continue
        has_built_artifact "$dll_dir" "$dll_name" || continue

        make -q -C "dlls/$dll_name" >/dev/null 2>&1
        rc=$?
        case "$rc" in
            1) echo "$dll_name" ;;
            0) : ;;                       # up to date
            *) : ;;                       # error/unknown -> skip silently
        esac
    done
}

mapfile -t changed < <(detect_changed)

if [ ${#changed[@]} -eq 0 ]; then
    echo "Nothing to update."
    exit 0
fi

echo "Rebuild targets: ${changed[*]}"
echo

# Rebuild changed dlls one by one. Do NOT stop on first failure —
# collect failures and keep going, otherwise the tree ends up half-built.
failures=()
for dll in "${changed[@]}"; do
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
    # Skip dlls that failed to build
    skip=0
    for f in "${failures[@]}"; do
        [ "$f" = "$dll" ] && skip=1 && break
    done
    [ "$skip" = 1 ] && continue

    src="$INSTALL_LIB/x86_64-windows/$dll.dll"
    dst="$WINE_PREFIX/drive_c/windows/system32/$dll.dll"
    if [ -f "$src" ] && [ -e "$dst" ]; then
        cp -v "$src" "$dst"
    fi

    src="$INSTALL_LIB/i386-windows/$dll.dll"
    dst="$WINE_PREFIX/drive_c/windows/syswow64/$dll.dll"
    if [ -f "$src" ] && [ -e "$dst" ]; then
        cp -v "$src" "$dst"
    fi
done
echo

echo "Ready."
