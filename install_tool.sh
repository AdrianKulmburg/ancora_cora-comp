#!/bin/bash

# install_tool.sh — run once on the worker to install your tool.
#
# CORA-COMP tools run inside a Docker base image you name on the submission form; the
# platform clones this repository into that image and then runs this script. It is the
# place for dependencies, builds, and license activation.
#
# This toolkit drives the ancora library. It obtains the ancora source from, in order:
#   1. ANCORA_SOURCE_DIR, if set (a local path to the ancora source tree);
#   2. a sibling directory named "ancora" next to this repo root;
#   3. a git clone of https://github.com/AdrianKulmburg/ancora (the default).
#
# It builds ancora in FAST mode TWICE:
#   - libancora_fast        (no GPU)  -> ancora_benchmark_cpu
#   - libancora_fast_gpu    (GPU)     -> ancora_benchmark_gpu
# run_instance.sh then picks the right binary from the instance's "device" field. The
# GPU build requires a HIP/ROCm toolchain; if it is not available, the GPU build is
# skipped and gpu instances report `unsupported`.
#
# Argument:
# - $1: interface version string, e.g. "v1"

set -e

VERSION="${1:-v1}"
echo "Installing tool (interface $VERSION)"

# --- Locate the ancora source tree ---------------------------------------------
TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TOOLKIT_DIR}/.." && pwd)"

ANCORA_REPO_URL="${ANCORA_REPO_URL:-https://github.com/AdrianKulmburg/ancora}"
ANCORA_SOURCE_DIR="${ANCORA_SOURCE_DIR:-}"

if [ -z "${ANCORA_SOURCE_DIR}" ] && [ -f "${REPO_ROOT}/ancora/CMakeLists.txt" ]; then
    ANCORA_SOURCE_DIR="${REPO_ROOT}/ancora"
fi

if [ -z "${ANCORA_SOURCE_DIR}" ]; then
    echo "ancora source not found locally; cloning ${ANCORA_REPO_URL}"
    ANCORA_SOURCE_DIR="${TOOLKIT_DIR}/ancora"
    if [ ! -d "${ANCORA_SOURCE_DIR}/.git" ]; then
        git clone --depth 1 "${ANCORA_REPO_URL}" "${ANCORA_SOURCE_DIR}"
    fi
fi

if [ ! -f "${ANCORA_SOURCE_DIR}/CMakeLists.txt" ]; then
    echo "error: ancora source not found at ${ANCORA_SOURCE_DIR}" >&2
    echo "Set ANCORA_SOURCE_DIR to the ancora source tree, or make sure the clone succeeded." >&2
    exit 1
fi
echo "Using ancora source at ${ANCORA_SOURCE_DIR}"

# --- Build ancora in FAST mode, no GPU ----------------------------------------
# The CPU flavor. FAST mode needs HiGHS (used by zonotope containment).
CPU_BUILD_DIR="${TOOLKIT_DIR}/build/ancora_cpu"
cmake -S "${ANCORA_SOURCE_DIR}" -B "${CPU_BUILD_DIR}" \
    -DANCORA_MODE_SAFE=OFF \
    -DANCORA_USE_GPU=OFF \
    -DANCORA_BUILD_TESTS=OFF
cmake --build "${CPU_BUILD_DIR}" --target ancora

# --- Compile the CPU benchmark driver -----------------------------------------
cc -O2 -std=c11 \
    -I"${ANCORA_SOURCE_DIR}/include" \
    -DANCORA_MODE=ANCORA_MODE_FAST \
    "${TOOLKIT_DIR}/src/ancora_benchmark.c" \
    -o "${TOOLKIT_DIR}/ancora_benchmark_cpu" \
    "${CPU_BUILD_DIR}/libancora_fast.a" \
    -lhighs -lm
echo "Built CPU driver: ${TOOLKIT_DIR}/ancora_benchmark_cpu"

# --- Build ancora in FAST mode, with GPU (optional) ---------------------------
# The GPU flavor needs a HIP/ROCm toolchain. If it is unavailable, skip it and let
# run_instance.sh report `unsupported` for gpu instances.
if command -v hipcc >/dev/null 2>&1; then
    GPU_BUILD_DIR="${TOOLKIT_DIR}/build/ancora_gpu"
    if cmake -S "${ANCORA_SOURCE_DIR}" -B "${GPU_BUILD_DIR}" \
            -DANCORA_MODE_SAFE=OFF \
            -DANCORA_USE_GPU=ON \
            -DANCORA_BUILD_TESTS=OFF \
            -DANCORA_GPU_PLATFORM="${ANCORA_GPU_PLATFORM:-amd}" \
            -DANCORA_HIP_ARCHITECTURES="${ANCORA_HIP_ARCHITECTURES:-}" \
            >/dev/null 2>&1; then
        if cmake --build "${GPU_BUILD_DIR}" --target ancora >/dev/null 2>&1; then
            # Locate the HIP runtime library. The CMake cache of the GPU build records
            # exactly which libamdhip64 it found (HIP_LIBRARY), so read it from there;
            # fall back to /opt/rocm/lib if it is not present.
            HIP_LIBDIR="$(grep -E '^HIP_LIBRARY:FILEPATH=' "${GPU_BUILD_DIR}/CMakeCache.txt" \
                          | head -1 | cut -d= -f2 | xargs dirname 2>/dev/null)"
            if [ -z "${HIP_LIBDIR}" ] || [ ! -f "${HIP_LIBDIR}/libamdhip64.so" ]; then
                HIP_LIBDIR="/opt/rocm/lib"
            fi
            # The HIP objects are not PIC-compatible with a PIE executable, so link
            # -no-pie, and pull in the HIP runtime (libamdhip64).
            cc -O2 -std=c11 -no-pie \
                -I"${ANCORA_SOURCE_DIR}/include" \
                -DANCORA_MODE=ANCORA_MODE_FAST \
                -DANCORA_USE_GPU=1 \
                "${TOOLKIT_DIR}/src/ancora_benchmark.c" \
                -o "${TOOLKIT_DIR}/ancora_benchmark_gpu" \
                "${GPU_BUILD_DIR}/libancora_fast_gpu.a" \
                -L"${HIP_LIBDIR}" -lamdhip64 \
                -lhighs -lm
            echo "Built GPU driver: ${TOOLKIT_DIR}/ancora_benchmark_gpu"
        else
            echo "warning: GPU build of ancora failed; gpu instances will report unsupported" >&2
        fi
    else
        echo "warning: GPU configure failed; gpu instances will report unsupported" >&2
    fi
else
    echo "warning: hipcc not found; gpu instances will report unsupported" >&2
fi

echo "Install complete."
