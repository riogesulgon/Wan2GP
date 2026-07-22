#!/usr/bin/env bash
# Restart WanGP without restarting the pod (keeps the /workspace volume + queue).
# Installed at /usr/local/bin/restart-wan2gp.sh in the image.
set -euo pipefail
pkill -f "wgp.py" || true
sleep 1
exec /opt/start.sh