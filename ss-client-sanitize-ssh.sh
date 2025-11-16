#!/usr/bin/env bash
#
# Remove all 192.168.8.1 entries from ~/.ssh/known_hosts

set -euo pipefail

HOST="192.168.8.1"
KNOWN_HOSTS="${HOME}/.ssh/known_hosts"
BACKUP="${KNOWN_HOSTS}.$(date +%Y%m%d%H%M%S).bak"

if [ ! -f "$KNOWN_HOSTS" ]; then
  echo "No known_hosts file found at: $KNOWN_HOSTS"
  exit 0
fi

echo "Backing up $KNOWN_HOSTS -> $BACKUP"
cp "$KNOWN_HOSTS" "$BACKUP"

# Create a temp file
TMP_FILE="$(mktemp)"

# Filter out any lines whose first field is:
#   - exactly 192.168.8.1
#   - or [192.168.8.1]:<port>
awk '
  $1 == "192.168.8.1" { next }
  $1 ~ /^\[192\.168\.8\.1\]:[0-9]+$/ { next }
  { print }
' "$KNOWN_HOSTS" > "$TMP_FILE"

mv "$TMP_FILE" "$KNOWN_HOSTS"

echo "All entries for $HOST have been removed from $KNOWN_HOSTS."
echo "Backup saved at: $BACKUP"
