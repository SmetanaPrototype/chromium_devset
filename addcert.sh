#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") <path_to_certificate.crt>

Adds a certificate to the system-wide Linux trust store and restarts Wine
so it picks up the change on the next launch.

Environment:
  (none — installs to /usr/local/share/ca-certificates, requires sudo)
EOF
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac

if [ $# -ne 1 ]; then
    echo "ERROR: exactly one argument required." >&2
    usage >&2
    exit 1
fi

CERT_FILE="$1"

if [ ! -f "$CERT_FILE" ]; then
    echo "ERROR: certificate file not found: $CERT_FILE" >&2
    exit 1
fi

echo "=== Certificate information ==="
openssl x509 -in "$CERT_FILE" -noout -subject -issuer -dates 2>/dev/null || true
CERT_CN=$(openssl x509 -in "$CERT_FILE" -noout -subject 2>/dev/null \
          | grep -oP 'CN\s*=\s*\K[^,]+' || true)
echo "==============================="
echo

# --- Copy into the system trust store ---
DEST_FILE="/usr/local/share/ca-certificates/$(basename "$CERT_FILE")"

echo "Copying certificate to $DEST_FILE ..."
if ! sudo cp "$CERT_FILE" "$DEST_FILE"; then
    echo "❌ Failed to copy the file. sudo privileges may be required." >&2
    exit 1
fi

echo "Updating system certificate store ..."
if ! sudo update-ca-certificates; then
    echo "❌ Failed to update the certificate store." >&2
    exit 1
fi

# --- Restart Wine ---
echo "Restarting Wine (wineserver -k) ..."
wineserver -k || true

echo
echo "✅ Certificate successfully added to the Linux system trust store."
echo "   Wine will pick it up automatically on the next launch."
echo
echo "   Common Name (CN) for verification: '${CERT_CN:-<not found>}'"
echo "   Verify manually: wine control → Internet Properties →"
echo "   Content → Certificates → Trusted Root Certification Authorities"
