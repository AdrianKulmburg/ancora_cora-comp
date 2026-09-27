#!/bin/bash

# prepare_instance.sh — untimed setup before each instance.
set -e

VERSION_STRING="v1"
if [ "$1" != "$VERSION_STRING" ]; then
    echo "Expected first argument (version string) '$VERSION_STRING', got '$1'"
    exit 1
fi

PARAMS="$4"

# Extract the device type from the JSON payload
read -r DEVICE <<EOF
$(printf '%s' "$PARAMS" | python3 -c 'import json,sys; p=json.load(sys.stdin); print(p.get("device", "cpu"))')
EOF

TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# If the instance uses a GPU, warm it up / initialize the context
if [ "$DEVICE" = "gpu" ]; then
    if [ -x "${TOOLKIT_DIR}/ancora_benchmark_gpu" ]; then
        echo "Initializing and warming up GPU context..."

        # Run a tiny, minimal invocation to force HIP/ROCm runtime initialization
        # and kernel loading without affecting your actual timed measurements.
        # (Adjust arguments to match a minimal valid run for your binary,
        # or redirect output to /dev/null to keep logs clean)
        "${TOOLKIT_DIR}/ancora_benchmark_gpu" "zonotope" "matMul" "1" "1" "1" "1" "0" "" > /dev/null 2>&1 || true
    else
        echo "No GPU driver found; skipping warm-up."
    fi
fi

exit 0
