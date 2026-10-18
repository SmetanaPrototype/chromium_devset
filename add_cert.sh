#!/bin/bash

if [ $# -ne 1 ]; then
    echo "Использование: $0 <путь_к_сертификату.crt>"
    exit 1
fi

CERT_FILE="$1"

if [ ! -f "$CERT_FILE" ]; then
    echo "Ошибка: Файл сертификата не найден: $CERT_FILE"
    exit 1
fi

echo "=== Информация о сертификате ==="
openssl x509 -in "$CERT_FILE" -noout -subject -issuer -dates 2>/dev/null
CERT_CN=$(openssl x509 -in "$CERT_FILE" -noout -subject 2>/dev/null | grep -oP 'CN\s*=\s*\K[^,]+')
echo "================================"
echo ""

# --- Копирование в системное хранилище ---
DEST_FILE="/usr/local/share/ca-certificates/$(basename "$CERT_FILE")"

echo "Копирование сертификата в $DEST_FILE ..."
sudo cp "$CERT_FILE" "$DEST_FILE"

if [ $? -ne 0 ]; then
    echo "❌ Не удалось скопировать файл. Возможно, нужны права sudo."
    exit 1
fi

echo "Обновление системного хранилища сертификатов..."
sudo update-ca-certificates

if [ $? -ne 0 ]; then
    echo "❌ Не удалось обновить хранилище сертификатов."
    exit 1
fi

# --- Перезапуск Wine ---
echo "Перезапуск Wine (wineserver -k)..."
wineserver -k

echo ""
echo "✅ Сертификат успешно добавлен в системное хранилище Linux."
echo "   Wine автоматически подхватит его при следующем запуске."
echo ""
echo "   Имя (CN) для проверки: '$CERT_CN'"
echo "   Проверить можно так: wine control → Свойства обозревателя →"
echo "   Содержание → Сертификаты → Доверенные корневые центры сертификации"
