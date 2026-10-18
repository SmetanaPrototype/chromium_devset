#!/usr/bin/env bash
#
#   ./rebuild_wine.sh                  # автоопределение изменений
#   ./rebuild_wine.sh winhttp          # конкретные DLL
#   ./rebuild_wine.sh winhttp secur32  # несколько


set -euo pipefail

WINE_SRC="${WINE_SRC:-$HOME/wine}"
WINE_PREFIX="${WINEPREFIX:-$HOME/.wine}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local}"
INSTALL_LIB="$INSTALL_PREFIX/lib/wine"

if [ ! -d "$WINE_SRC/dlls" ]; then
    echo "ОШИБКА: $WINE_SRC/dlls не найден. Задайте WINE_SRC." >&2
    exit 1
fi

cd "$WINE_SRC"

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

        # если ничего не собрано вообще — тоже пересборка
        [ -z "$built" ] && missing=1

        # если что-то удалено — сразу в список
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

if [ $# -gt 0 ]; then
    changed=("$@")
else
    mapfile -t changed < <(detect_changed)
fi

if [ ${#changed[@]} -eq 0 ]; then
    echo "Изменений не обнаружено."
    exit 0
fi

echo "Будут пересобраны: ${changed[*]}"
echo

echo ">>> Удаляю собранные DLL, чтобы форсировать сборку"
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
    echo ">>> make -C dlls/$dll"
    make -C "dlls/$dll"
    echo
done

echo ">>> sudo make install"
sudo make install
echo

echo ">>> Копирую в префикс $WINE_PREFIX"
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

echo "Готово."
