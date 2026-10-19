#!/usr/bin/env bash
#
# wine-update.sh — incremental rebuild of changed Wine DLLs.
#
# Optimization:
#   Instead of calling `make -q` 600+ times sequentially (which is slow
#   because make re-parses the Makefile tree on each call), we run
#   `make -n` once. It prints what *would* be built, and we extract
#   the affected dll directories from its output.

set -uo pipefail

WINE_PREFIX="${WINEPREFIX:-$HOME/.wine}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local}"
INSTALL_LIB="$INSTALL_PREFIX/lib/wine"

read -ra SKIP_DLLS <<<"${SKIP_DLLS:-wineandroid.drv}"

usage() {
    cat <<'EOF'
Usage: wine-update.sh [wine_src]
  wine_src   Path to the Wine source tree. If omitted, auto-detected.
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

case "${1:-}" in -h|--help) usage; exit 0 ;; esac
[ $# -gt 1 ] && { echo "ERROR: too many arguments: $*" >&2; usage >&2; exit 1; }

if [ $# -eq 1 ]; then
    WINE_SRC="$1"
elif detected=$(detect_wine_src); then
    WINE_SRC="$detected"
    echo ">>> Wine src: $WINE_SRC" >&2
else
    WINE_SRC="${WINE_SRC:-$HOME/wine}"
fi

[ -d "$WINE_SRC/dlls" ] || { echo "ERROR: $WINE_SRC/dlls not found." >&2; exit 1; }
cd "$WINE_SRC"

if [ "$(id -u)" -ne 0 ]; then
    echo ">>> Requesting sudo (needed later for 'make install')..." >&2
    sudo -v || { echo "ERROR: sudo required" >&2; exit 1; }
fi

# --- Ownership check (only dlls/ dir for speed) ---
if [ "$(id -u)" -ne 0 ]; then
    echo ">>> Checking ownership of build artifacts..." >&2
    bad=$(find dlls -maxdepth 3 \
            \( -name '*.dll' -o -name '*.so' -o -name '*.o' -o -name '*.a' \) \
            ! -user "$(id -u)" -print -quit 2>/dev/null)
    if [ -n "$bad" ]; then
        echo ">>> Found file not owned by $USER: $bad" >&2
        echo ">>> Fixing ownership of dlls/ (this may take a moment)..." >&2
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

detect_changed() {
    echo ">>> Scanning for changes (dry-run)..." >&2
    
    # Run make in dry-run mode. It parses all dependencies ONCE and
    # prints the commands it would execute. We extract 'dlls/foo/'.
    local changed_dlls
    changed_dlls=$(timeout 120 make -n 2>/dev/null | \
        grep -oE '\bdlls/[a-zA-Z0-9._-]+/' | \
        cut -d/ -f2 | sort -u)

    local dll_name
    for dll_name in $changed_dlls; do
        # 1. Is it a real directory?
        [ -d "dlls/$dll_name" ] || continue
        
        # 2. Should we skip it?
        is_skipped "$dll_name" && continue
        
        # 3. Does it have a pre-existing built artifact?
        has_built_artifact "dlls/$dll_name/" "$dll_name" || continue
        
        echo "$dll_name"
    done
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
