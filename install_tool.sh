#!/bin/bash

# install_tool.sh — run once on the worker to install the tool.
#
# CORA-COMP tools run inside a Docker base image named on the submission form.
# The platform clones this repository into that image and then runs this script.
#
# This toolkit drives the ancora library.
#
# ancora is built in FAST mode in two configurations:
#
#   1. CPU:
#        libancora_fast.a
#        -> ancora_benchmark_cpu
#
#   2. GPU:
#        libancora_fast_gpu.a
#        -> ancora_benchmark_gpu
#
# The GPU configuration targets NVIDIA GPUs using:
#
#        NVIDIA CUDA
#             |
#             v
#        HIP-over-CUDA
#             |
#             v
#        ancora HIP kernels
#
# The GPU build is optional. If the HIP/CUDA toolchain cannot be configured,
# the CPU build is still installed and GPU instances will report unsupported.
#
# Source selection, in order:
#
#   1. ANCORA_SOURCE_DIR, if set
#   2. ../ancora relative to this repository
#   3. git clone of ANCORA_REPO_URL
#
# Argument:
#   $1: interface version string, e.g. "v1"


set -e


# ============================================================================
# Configuration
# ============================================================================

VERSION="${1:-v1}"

# NVIDIA is the only supported GPU platform for this installation.
ANCORA_GPU_PLATFORM="${ANCORA_GPU_PLATFORM:-nvidia}"

# ROCm version used for HIP-over-CUDA.
ROCM_VERSION="${ROCM_VERSION:-6.3.1}"

# ROCm installation prefix.
ANCORA_ROCM_ROOT="${ANCORA_ROCM_ROOT:-/opt/rocm}"

# Optional explicit GPU architecture.
#
# If empty, CMake will use its configured/default architecture.
# For a known NVIDIA GPU, setting this explicitly is preferable.
#
# Examples:
#
#   RTX 30 / A100: 80
#   A10:           86
#   RTX 40 / L40:  89
#
ANCORA_HIP_ARCHITECTURES="${ANCORA_HIP_ARCHITECTURES:-}"


echo "============================================================"
echo "Installing tool"
echo "Interface version : ${VERSION}"
echo "GPU platform      : ${ANCORA_GPU_PLATFORM}"
echo "ROCm version      : ${ROCM_VERSION}"
echo "ROCm root         : ${ANCORA_ROCM_ROOT}"
echo "============================================================"


# ============================================================================
# Validate configuration
# ============================================================================

if [ "${ANCORA_GPU_PLATFORM}" != "nvidia" ]; then
    echo "error: this install script supports NVIDIA GPUs only." >&2
    echo "       ANCORA_GPU_PLATFORM must be 'nvidia'." >&2
    exit 1
fi


# ============================================================================
# Locate this repository
# ============================================================================

TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TOOLKIT_DIR}/.." && pwd)"

echo "Toolkit directory: ${TOOLKIT_DIR}"
echo "Repository root:   ${REPO_ROOT}"


# ============================================================================
# 1. Base build tools
# ============================================================================

echo
echo "==> Installing base build tools"

apt-get update

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    cmake \
    gcc \
    g++ \
    git \
    python3 \
    wget \
    build-essential \
    libgomp1 \
    ca-certificates \
    gpg


# ============================================================================
# 2. HiGHS
# ============================================================================
#
# HiGHS is used by ancora's FAST zonotope containment implementation.
#
# The ancora FindHIGHS.cmake module expects:
#
#     /usr/local/include/highs/interfaces/highs_c_api.h
#     /usr/local/lib/libhighs.so
#
# ============================================================================

if [ ! -f /usr/local/include/highs/interfaces/highs_c_api.h ] || \
   [ ! -f /usr/local/lib/libhighs.so ]; then

    echo
    echo "==> Building HiGHS from source"

    HIGHS_SRC="${TOOLKIT_DIR}/HiGHS"

    if [ ! -d "${HIGHS_SRC}/.git" ]; then
        git clone \
            --depth 1 \
            https://github.com/ERGO-Code/HiGHS.git \
            "${HIGHS_SRC}"
    fi

    cmake \
        -S "${HIGHS_SRC}" \
        -B "${HIGHS_SRC}/build" \
        -DCMAKE_BUILD_TYPE=Release

    cmake \
        --build "${HIGHS_SRC}/build" \
        -j"$(nproc)"

    cmake \
        --install "${HIGHS_SRC}/build"

    ldconfig

else

    echo
    echo "==> HiGHS already installed"

fi


# ============================================================================
# 3. CUDA toolkit
# ============================================================================
#
# CUDA provides:
#
#     nvcc
#     libcudart
#
# HIP-over-CUDA uses the CUDA toolkit underneath.
# ============================================================================

if command -v nvcc >/dev/null 2>&1; then

    echo
    echo "==> CUDA toolkit already installed"

    nvcc --version

else

    echo
    echo "==> Installing CUDA toolkit"

    CUDA_KEYRING="cuda-keyring_1.1-1_all.deb"

    wget -q \
        "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/${CUDA_KEYRING}" \
        -O "/tmp/${CUDA_KEYRING}"

    dpkg -i "/tmp/${CUDA_KEYRING}"

    apt-get update

    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        cuda-toolkit

fi


# ============================================================================
# 4. HIP / ROCm — NVIDIA backend
# ============================================================================
#
# IMPORTANT:
#
# This is NOT an AMD/ROCm GPU build.
#
# We install HIP's NVIDIA backend:
#
#     hip-runtime-nvidia
#     hip-dev
#
# HIP then uses CUDA underneath.
#
# ============================================================================

if [ ! -f "${ANCORA_ROCM_ROOT}/include/hip/hip_runtime.h" ]; then

    echo
    echo "==> Installing HIP ${ROCM_VERSION} for NVIDIA/CUDA"

    wget -q -O - \
        https://repo.radeon.com/rocm/rocm.gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/rocm.gpg

    echo \
        "deb [arch=amd64 signed-by=/usr/share/keyrings/rocm.gpg] " \
        "https://repo.radeon.com/rocm/apt/${ROCM_VERSION} jammy main" \
        > /etc/apt/sources.list.d/rocm.list

    apt-get update

    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        hip-runtime-nvidia \
        hip-dev

else

    echo
    echo "==> HIP already installed at ${ANCORA_ROCM_ROOT}"

fi


# ============================================================================
# HIP environment
# ============================================================================

export PATH="${ANCORA_ROCM_ROOT}/bin:${PATH}"

# Explicitly select the NVIDIA HIP backend.
export HIP_PLATFORM="nvidia"

echo
echo "==> HIP configuration"

if command -v hipcc >/dev/null 2>&1; then
    echo "hipcc: $(command -v hipcc)"
    hipcc --version
else
    echo "warning: hipcc was not found after HIP installation" >&2
fi


# ============================================================================
# 5. hipBLAS
# ============================================================================
#
# ancora's GPU matrix implementation uses hipBLAS.
# ============================================================================

echo
echo "==> Installing hipBLAS"

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    hipblas \
    hipblas-dev


# ============================================================================
# 6. Locate ancora source
# ============================================================================

ANCORA_REPO_URL="${ANCORA_REPO_URL:-https://github.com/AdrianKulmburg/ancora}"

ANCORA_SOURCE_DIR="${ANCORA_SOURCE_DIR:-}"


if [ -z "${ANCORA_SOURCE_DIR}" ] && \
   [ -f "${REPO_ROOT}/ancora/CMakeLists.txt" ]; then

    ANCORA_SOURCE_DIR="${REPO_ROOT}/ancora"

fi


if [ -z "${ANCORA_SOURCE_DIR}" ]; then

    echo
    echo "==> ancora source not found locally"
    echo "    Cloning ${ANCORA_REPO_URL}"

    ANCORA_SOURCE_DIR="${TOOLKIT_DIR}/ancora"

    if [ ! -d "${ANCORA_SOURCE_DIR}/.git" ]; then

        git clone \
            --depth 1 \
            "${ANCORA_REPO_URL}" \
            "${ANCORA_SOURCE_DIR}"

    fi

fi


if [ ! -f "${ANCORA_SOURCE_DIR}/CMakeLists.txt" ]; then

    echo "error: ancora source not found at:" >&2
    echo "       ${ANCORA_SOURCE_DIR}" >&2
    echo >&2
    echo "Set ANCORA_SOURCE_DIR to the ancora source tree," >&2
    echo "or make sure the repository clone succeeded." >&2

    exit 1

fi


echo
echo "==> Using ancora source:"
echo "    ${ANCORA_SOURCE_DIR}"


# ============================================================================
# 7. Build ancora — FAST CPU
# ============================================================================
#
# Result:
#
#     build/ancora_cpu/libancora_fast.a
#
# ============================================================================

echo
echo "============================================================"
echo "Building ancora FAST CPU"
echo "============================================================"

CPU_BUILD_DIR="${TOOLKIT_DIR}/build/ancora_cpu"


cmake \
    -S "${ANCORA_SOURCE_DIR}" \
    -B "${CPU_BUILD_DIR}" \
    -DANCORA_MODE_SAFE=OFF \
    -DANCORA_USE_GPU=OFF \
    -DANCORA_BUILD_TESTS=OFF \
    -DCMAKE_BUILD_TYPE=Release


cmake \
    --build "${CPU_BUILD_DIR}" \
    --target ancora \
    -j"$(nproc)"


# ============================================================================
# 8. Build CPU benchmark driver
# ============================================================================

echo
echo "==> Building CPU benchmark driver"


cc \
    -O2 \
    -std=c11 \
    -I"${ANCORA_SOURCE_DIR}/include" \
    -DANCORA_MODE=ANCORA_MODE_FAST \
    "${TOOLKIT_DIR}/src/ancora_benchmark.c" \
    -o "${TOOLKIT_DIR}/ancora_benchmark_cpu" \
    "${CPU_BUILD_DIR}/libancora_fast.a" \
    -lhighs \
    -lm


echo "Built CPU driver:"
echo "    ${TOOLKIT_DIR}/ancora_benchmark_cpu"


# ============================================================================
# 9. Build ancora — FAST NVIDIA GPU
# ============================================================================
#
# Result:
#
#     build/ancora_gpu/libancora_fast_gpu.a
#
# The CMake configuration explicitly selects:
#
#     ANCORA_GPU_PLATFORM=nvidia
#
# which corresponds to HIP-over-CUDA.
#
# ============================================================================

echo
echo "============================================================"
echo "Building ancora FAST NVIDIA GPU"
echo "============================================================"


GPU_BUILD_DIR="${TOOLKIT_DIR}/build/ancora_gpu"


if ! command -v hipcc >/dev/null 2>&1; then

    echo
    echo "warning: hipcc not found."
    echo "         GPU build will be skipped."
    echo "         GPU instances will report unsupported."

else

    echo "hipcc: $(command -v hipcc)"

    # ------------------------------------------------------------
    # Configure
    # ------------------------------------------------------------

    cmake \
        -S "${ANCORA_SOURCE_DIR}" \
        -B "${GPU_BUILD_DIR}" \
        -DANCORA_MODE_SAFE=OFF \
        -DANCORA_USE_GPU=ON \
        -DANCORA_BUILD_TESTS=OFF \
        -DANCORA_GPU_PLATFORM=nvidia \
        -DANCORA_HIP_ARCHITECTURES="${ANCORA_HIP_ARCHITECTURES}" \
        -DANCORA_ROCM_ROOT="${ANCORA_ROCM_ROOT}" \
        -DCMAKE_BUILD_TYPE=Release


    # ------------------------------------------------------------
    # Build
    # ------------------------------------------------------------

    if cmake \
        --build "${GPU_BUILD_DIR}" \
        --target ancora \
        -j"$(nproc)"; then

        echo
        echo "==> ancora NVIDIA GPU library built successfully"

    else

        echo
        echo "warning: GPU build of ancora failed."
        echo "         GPU instances will report unsupported."

    fi


    # ------------------------------------------------------------
    # Build GPU benchmark driver
    # ------------------------------------------------------------

    if [ -f "${GPU_BUILD_DIR}/libancora_fast_gpu.a" ]; then

        echo
        echo "==> Building GPU benchmark driver"


        # CMake's HIP package/cache normally records the HIP runtime
        # library. Extract its directory if available.
        HIP_LIBDIR="$(
            grep -E '^HIP_LIBRARY:FILEPATH=' \
                "${GPU_BUILD_DIR}/CMakeCache.txt" \
                | head -1 \
                | cut -d= -f2 \
                | xargs dirname 2>/dev/null || true
        )


        # Fall back to the standard ROCm library directory.
        if [ -z "${HIP_LIBDIR}" ] || \
           [ ! -f "${HIP_LIBDIR}/libamdhip64.so" ]; then

            HIP_LIBDIR="${ANCORA_ROCM_ROOT}/lib"

        fi


        if [ ! -f "${HIP_LIBDIR}/libamdhip64.so" ]; then

            echo "warning: libamdhip64.so was not found." >&2
            echo "         GPU benchmark driver will not be built." >&2

        else

            echo "Using HIP runtime:"
            echo "    ${HIP_LIBDIR}/libamdhip64.so"


            # HIP objects may not be compatible with a PIE executable,
            # so disable PIE for this benchmark driver.
            cc \
                -O2 \
                -std=c11 \
                -no-pie \
                -I"${ANCORA_SOURCE_DIR}/include" \
                -DANCORA_MODE=ANCORA_MODE_FAST \
                -DANCORA_USE_GPU=1 \
                "${TOOLKIT_DIR}/src/ancora_benchmark.c" \
                -o "${TOOLKIT_DIR}/ancora_benchmark_gpu" \
                "${GPU_BUILD_DIR}/libancora_fast_gpu.a" \
                -L"${HIP_LIBDIR}" \
                -lamdhip64 \
                -lhighs \
                -lm


            echo
            echo "Built GPU driver:"
            echo "    ${TOOLKIT_DIR}/ancora_benchmark_gpu"

        fi

    fi

fi


# ============================================================================
# 10. Final summary
# ============================================================================

echo
echo "============================================================"
echo "Install complete"
echo "============================================================"

if [ -x "${TOOLKIT_DIR}/ancora_benchmark_cpu" ]; then
    echo "CPU benchmark:  ${TOOLKIT_DIR}/ancora_benchmark_cpu"
else
    echo "CPU benchmark:  NOT BUILT"
fi


if [ -x "${TOOLKIT_DIR}/ancora_benchmark_gpu" ]; then
    echo "GPU benchmark:  ${TOOLKIT_DIR}/ancora_benchmark_gpu"
else
    echo "GPU benchmark:  unavailable"
fi

echo
echo "GPU platform:    NVIDIA"
echo "HIP backend:     HIP-over-CUDA"
echo "ROCm root:       ${ANCORA_ROCM_ROOT}"
echo "ROCm version:    ${ROCM_VERSION}"
echo "============================================================"
