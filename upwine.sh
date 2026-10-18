#!/usr/bin/env bash
#
#   ./wine-update.sh                  # auto-detect from current directory
#   ./wine-update.sh ~/wine           # explicit source path

set -euo pipefail

WINE_PREFIX="${WINEPREFIX:-$HOME/.wine}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local}"

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

INSTALL_LIB="$INSTALL_PREFIX/lib/wine"

if [ ! -d "$WINE_SRC/dlls" ]; then
    echo "ERROR: $WINE_SRC/dlls not found." >&2
    echo "Run from the wine source tree or pass it as an argument." >&2
    exit 1
fi

cd "$WINE_SRC"

# --- Ensure build artifacts in the source tree are owned by the current user ---
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

detect_changed() {
    local dll_dir dll_name built missing
    for dll_dir in dlls/*/; do
        dll_name=$(basename "$dll_dir")

        built=""
        missing=0
        for cand in "$dll_dir/x86_64-windows/$dll_name.dll" \
                    "$dll_dir/i386-windows/$dll_name.dll" \
                    "$dll_dir/x86_64-unix/$dll_name.so" \
                    "$dll_dir/i386-unix/$dll_name.so"; do
            if [ -f "$cand" ]; then
                [ -z "$built" ] && built="$cand"
            else
                missing=1
            fi
        done

        [ -z "$built" ] && missing=1

        if [ "$missing" = "1" ]; then
            echo "$dll_name"
            continue
        fi

        if [ -n "$(find "$dll_dir" -maxdepth 1 -newer "$built" \
                    \( -name '*.c' -o -name '*.h' -o -name '*.idl' -o -name '*.spec' -o -name '*.rc' \) \
                    -print -quit 2>/dev/null)" ]; then
            echo "$dll_name"
        fi
    done
}

mapfile -t changed < <(detect_changed)

if [ ${#changed[@]} -eq 0 ]; then
    echo "Nothing to update."
    exit 0
fi

echo "Rebuild targets: ${changed[*]}"
echo

echo ">>> Removing built DLLs to force rebuild"
for dll in "${changed[@]}"; do
    for f in "dlls/$dll/x86_64-windows/$dll.dll" \
             "dlls/$dll/i386-windows/$dll.dll" \
             "dlls/$dll/x86_64-unix/$dll.so" \
             "dlls/$dll/i386-unix/$dll.so"; do
        [ -f "$f" ] && rm -v "$f"
    done
done
echo

for dll in "${changed[@]}"; do
    make -C "dlls/$dll"
done

echo ">>> sudo make install"
sudo make install
echo

echo ">>> Copy to prefix $WINE_PREFIX"
for dll in "${changed[@]}"; do
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
