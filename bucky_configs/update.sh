#!/bin/bash
set -e

# Update happy from upstream monorepo and redeploy
# Usage: ./bucky_configs/update.sh (run from ~/happy)

REPO_DIR="$HOME/happy"
cd "$REPO_DIR"

echo "==> Fetching upstream (slopus/happy)..."
git fetch upstream

echo "==> Rebasing self-hosted branch onto upstream/main..."
git rebase upstream/main

echo "==> Rebuilding container image..."
podman build -t happy-server:latest -f Dockerfile.server .

echo "==> Restarting stack..."
podman compose down
podman compose up -d

echo "==> Waiting for server to start..."
sleep 15

# Check if happy-server is running (not crash-looping)
STATUS=$(podman inspect --format='{{.State.Status}}' happy-happy-server-1 2>/dev/null || echo "unknown")

if [ "$STATUS" = "running" ]; then
    echo "==> Server is running"
    echo "==> Testing endpoint..."
    curl -sk https://bms4.lan:3030/ && echo ""
    echo "==> Update complete!"
else
    echo "!!! Server may not be running (status: $STATUS) — check logs:"
    echo "    podman compose logs happy-server | tail -30"
    exit 1
fi
