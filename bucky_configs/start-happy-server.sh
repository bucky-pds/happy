#!/bin/bash
# Start the happy-server compose stack after Podman machine is ready.
# Called by launchd on login (com.bucky.happy-server.plist).
# Logs go to ~/Library/Logs/happy-server-autostart.log via launchd plist.

set -e

PODMAN="/opt/podman/bin/podman"
REPO_DIR="$HOME/happy"

echo "=== $(date) ==="
echo "Waiting for Podman machine to be ready..."

# Wait up to 120 seconds for the Podman machine to respond
for i in $(seq 1 60); do
    if $PODMAN info >/dev/null 2>&1; then
        echo "Podman machine ready after ~$((i * 2))s"
        break
    fi
    sleep 2
done

if ! $PODMAN info >/dev/null 2>&1; then
    echo "ERROR: Podman machine did not become ready within 120s. Aborting."
    exit 1
fi

cd "$REPO_DIR"

echo "Starting happy-server compose stack..."
$PODMAN compose up -d 2>&1

sleep 10

STATUS=$($PODMAN inspect --format='{{.State.Status}}' happy-happy-server-1 2>/dev/null || echo "unknown")
if [ "$STATUS" = "running" ]; then
    echo "happy-server is running."
else
    echo "WARNING: happy-server status is '$STATUS' — check logs with: podman compose logs happy-server"
fi

echo "=== done ==="
