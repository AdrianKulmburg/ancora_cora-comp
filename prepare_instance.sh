#!/bin/bash

# prepare_instance.sh — untimed setup before each instance.
set -e

VERSION_STRING="v1"
if [ "$1" != "$VERSION_STRING" ]; then
    echo "Expected first argument (version string) '$VERSION_STRING', got '$1'"
    exit 1
fi

PARAMS="$4"

read -r DEVICE DIM GENERATORS <<EOF
$(printf '%s' "$PARAMS" | python3 -c 'import json,sys; p=json.load(sys.stdin); print(p.get("device", "cpu"), p.get("dim", 1), p.get("generators", 1))')
EOF

TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$DEVICE" = "gpu" ]; then
    if [ -x "${TOOLKIT_DIR}/ancora_benchmark_gpu" ]; then
        echo "Initializing and warming up GPU context..."

        # Wake the GPU / keep it initialized between processes, if permitted.
        nvidia-smi -pm 1 >/dev/null 2>&1 || echo "note: could not enable GPU persistence mode (likely insufficient privileges)"

        # Persistent, writable JIT cache directory: THIS is what actually
        # survives the process boundary between this script and
        # run_instance.sh's later invocation -- context/handle state does
        # not, but a cached compiled kernel does, avoiding a recompile on
        # first use in the timed run.
        export CUDA_CACHE_PATH="${TOOLKIT_DIR}/.nv_cache"
        mkdir -p "${CUDA_CACHE_PATH}"

        # Warm up with dimensions close to the real instance, since cuBLAS/
        # hipBLAS may select a different kernel variant (and thus a
        # different cache entry) depending on problem size.
        WARM_DIM="${DIM:-64}"
        WARM_GEN="${GENERATORS:-64}"

        echo "Warm-up run: dim=${WARM_DIM}, generators=${WARM_GEN}"
        if ! "${TOOLKIT_DIR}/ancora_benchmark_gpu" \
                "zonotope" "matMul" "${WARM_DIM}" "${WARM_GEN}" "1" "1" "0" ""; then
            echo "warning: GPU warm-up run failed (see output above); continuing anyway"
        fi
    else
        echo "No GPU driver found; skipping warm-up."
    fi
fi

exit 0
