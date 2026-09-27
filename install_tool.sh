#!/bin/bash

# install_tool.sh — run once on the worker to install the tool.
#
# CORA-COMP tools run inside a Docker base image named on the submission form.
# The platform clones this repository into that image and then runs this script.
#
# This toolkit drives the ancora library.
#
# Two FAST-mode ancora builds are produced:
#
#   CPU:
#       libancora_fast.a
#       -> ancora_benchmark_cpu
#
#   NVIDIA GPU:
#       libancora_fast_gpu.a
#       -> ancora_benchmark_gpu
#
# The GPU build uses HIP over CUDA:
#
#       NVIDIA GPU
#           |
#         CUDA
#           |
#     HIP-over-CUDA
#           |
#        ancora
#
# The GPU build is optional. If the NVIDIA/HIP toolchain cannot be configured,
# the CPU build remains available and GPU instances can report unsupported.
#
# Source selection:
#
#   1. ANCORA_SOURCE_DIR, if explicitly set
#   2. ../ancora relative to this repository
#   3. git clone of ANCORA_REPO_URL
#
# Argument:
#
#   $1: interface version string, e.g. "v1"


set -e


# ============================================================================
# Configuration
# ============================================================================

VERSION="${1:-v1}"

# This installation is specifically for NVIDIA GPUs.
ANCORA_GPU_PLATFORM="nvidia"

# ROCm/HIP version used for HIP-over-CUDA.
#
# Override with:
#
#   ROCM_VERSION=6.3.1 ./install_tool.sh
#
ROCM_VERSION="${ROCM_VERSION:-6.3.1}"

# ROCm installation root.
ANCORA_ROCM_ROOT="${ANCORA_ROCM_ROOT:-/opt/rocm}"

# Optional NVIDIA GPU architecture.
#
# If left empty, CMake/HIP will use its configured default.
#
# Common examples:
#
#   A100       -> 80
#   A10        -> 86
#   RTX 3090   -> 86
#   RTX 4090   -> 89
#   L40/L40S   -> 89
#
# Set this explicitly when the competition's GPU model is known.
#
ANCORA_HIP_ARCHITECTURES="${ANCORA_HIP_ARCHITECTURES:-}"

# ancora repository.
ANCORA_REPO_URL="${ANCORA_REPO_URL:-https://github.com/AdrianKulmburg/ancora}"


# ============================================================================
# Basic paths
# ============================================================================

TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TOOLKIT_DIR}/.." && pwd)"


# ============================================================================
# Banner
# ============================================================================

echo
echo "============================================================"
echo "Installing ancora tool"
echo "============================================================"
echo "Interface version : ${VERSION}"
echo "Toolkit directory : ${TOOLKIT_DIR}"
echo "Repository root   : ${REPO_ROOT}"
echo "GPU platform      : NVIDIA"
echo "HIP backend       : HIP-over-CUDA"
echo "ROCm version      : ${ROCM_VERSION}"
echo "ROCm root         : ${ANCORA_ROCM_ROOT}"
echo "HIP architecture  : ${ANCORA_HIP_ARCHITECTURES:-CMake default}"
echo "============================================================"
echo


# ============================================================================
# Helper functions
# ============================================================================

die()
{
    echo
    echo "ERROR: $*" >&2
    exit 1
}


have_command()
{
    command -v "$1" >/dev/null 2>&1
}


# ============================================================================
# 1. Base build tools
# ============================================================================

echo "==> Installing base build tools"

apt-get update

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    cmake \
    gcc \
    g++ \
    git \
    python3 \
    wget \
    curl \
    build-essential \
    libgomp1 \
    ca-certificates \
    gpg \
    pkg-config


# ============================================================================
# 2. BLAS
# ============================================================================
#
# ancora FAST CPU requires BLAS.
#
# Install both the generic BLAS development package and OpenBLAS. The generic
# package provides the standard BLAS development interface while OpenBLAS
# provides the actual implementation.
# ============================================================================

echo
echo "==> Installing BLAS / OpenBLAS"

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    libblas-dev \
    libopenblas-dev


echo "==> Checking BLAS installation"

# Locate the BLAS library without assuming a particular architecture-specific
# directory.
BLAS_LIBRARY=""

for candidate in \
    /usr/lib/x86_64-linux-gnu/libopenblas.so \
    /usr/lib/x86_64-linux-gnu/openblas-pthread/libopenblas.so \
    /usr/lib/x86_64-linux-gnu/openblas-serial/libopenblas.so \
    /usr/lib/x86_64-linux-gnu/libblas.so \
    /usr/lib/libopenblas.so \
    /usr/lib/libblas.so
do
    if [ -f "${candidate}" ]; then
        BLAS_LIBRARY="${candidate}"
        break
    fi
done

if [ -z "${BLAS_LIBRARY}" ]; then
    echo "Installed BLAS files:" >&2
    dpkg -L libblas-dev 2>/dev/null >&2 || true
    dpkg -L libopenblas-dev 2>/dev/null >&2 || true
    die "Could not locate a BLAS library"
fi

echo "BLAS library: ${BLAS_LIBRARY}"

ldconfig


# ============================================================================
# 3. HiGHS
# ============================================================================
#
# ancora FAST zonotope containment uses HiGHS.
#
# The ancora FindHIGHS.cmake module expects the development files under
# /usr/local after installation.
#
# ============================================================================

if [ ! -f /usr/local/include/highs/interfaces/highs_c_api.h ] || \
   [ ! -f /usr/local/lib/libhighs.so ]; then

    echo
    echo "==> Building HiGHS from source"

    HIGHS_SRC="${TOOLKIT_DIR}/HiGHS"

    if [ ! -d "${HIGHS_SRC}/.git" ]; then

        echo "Cloning HiGHS..."

        git clone \
            --depth 1 \
            https://github.com/ERGO-Code/HiGHS.git \
            "${HIGHS_SRC}"

    else

        echo "HiGHS source already present"

    fi


    cmake \
        -S "${HIGHS_SRC}" \
        -B "${HIGHS_SRC}/build" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_TESTING=OFF


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
# 4. CUDA
# ============================================================================
#
# CUDA is the NVIDIA backend underneath HIP.
#
# We need:
#
#     nvcc
#     CUDA runtime libraries
#
# Ubuntu may install CUDA under /usr/local/cuda-<version>/ rather than making
# nvcc immediately available on PATH, so explicitly locate it.
# ============================================================================

echo
echo "==> Checking CUDA"


CUDA_ROOT=""


# First try the conventional symlink.
if [ -x /usr/local/cuda/bin/nvcc ]; then

    CUDA_ROOT="/usr/local/cuda"

fi


# Otherwise search versioned CUDA installations.
if [ -z "${CUDA_ROOT}" ]; then

    for candidate in /usr/local/cuda-*; do

        if [ -x "${candidate}/bin/nvcc" ]; then
            CUDA_ROOT="${candidate}"
            break
        fi

    done

fi


# If CUDA wasn't found, install it.
if [ -z "${CUDA_ROOT}" ]; then

    echo "CUDA not found; installing CUDA toolkit"

    CUDA_KEYRING="cuda-keyring_1.1-1_all.deb"
    CUDA_KEYRING_PATH="/tmp/${CUDA_KEYRING}"


    wget -q \
        "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/${CUDA_KEYRING}" \
        -O "${CUDA_KEYRING_PATH}"


    dpkg -i "${CUDA_KEYRING_PATH}"


    apt-get update


    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        cuda-toolkit


    # Look again after installation.
    if [ -x /usr/local/cuda/bin/nvcc ]; then

        CUDA_ROOT="/usr/local/cuda"

    else

        for candidate in /usr/local/cuda-*; do

            if [ -x "${candidate}/bin/nvcc" ]; then
                CUDA_ROOT="${candidate}"
                break
            fi

        done

    fi

fi


# CUDA must have been found by this point.
if [ -z "${CUDA_ROOT}" ]; then

    echo
    echo "CUDA installation completed, but nvcc could not be located." >&2

    echo >&2
    echo "Searching for nvcc:" >&2

    find /usr/local /usr -name nvcc -type f 2>/dev/null | head -20 >&2 || true

    echo >&2
    echo "Installed CUDA packages:" >&2

    dpkg -l | grep -i cuda >&2 || true

    die "Could not locate CUDA nvcc"

fi


# Put CUDA on PATH and library search paths.
export CUDA_HOME="${CUDA_ROOT}"
export PATH="${CUDA_ROOT}/bin:${PATH}"

export LD_LIBRARY_PATH="${CUDA_ROOT}/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"


echo
echo "CUDA root:"
echo "    ${CUDA_ROOT}"

echo
echo "nvcc:"
echo "    $(command -v nvcc)"

nvcc --version



# ============================================================================
# 5. HIP / ROCm — NVIDIA backend
# ============================================================================
#
# IMPORTANT:
#
# This is HIP configured for NVIDIA/CUDA.
#
# We do NOT want an AMD GPU configuration here.
#
# Packages:
#
#     hip-runtime-nvidia
#     hip-dev
#
# ============================================================================

echo
echo "==> Checking HIP"

if [ -f "${ANCORA_ROCM_ROOT}/include/hip/hip_runtime.h" ]; then

    echo "HIP headers already exist at:"
    echo "    ${ANCORA_ROCM_ROOT}/include/hip/hip_runtime.h"

else

    echo "HIP not found; installing ROCm/HIP ${ROCM_VERSION}"

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

fi


# ============================================================================
# 6. HIP environment
# ============================================================================

export PATH="${ANCORA_ROCM_ROOT}/bin:${PATH}"

# Force the NVIDIA backend for tools that honor HIP_PLATFORM.
export HIP_PLATFORM="nvidia"
export CUDA_PATH="${CUDA_ROOT}"



echo
echo "==> Checking HIP compiler"

if have_command hipcc; then

    echo "hipcc: $(command -v hipcc)"
    hipcc --version

else

    echo "warning: hipcc was not found." >&2
    echo "         The CPU build will still be attempted." >&2

fi


# ============================================================================
# 7. hipBLAS
# ============================================================================

echo
echo "==> Installing hipBLAS"

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    hipblas \
    hipblas-dev


# ============================================================================
# 8. Locate ancora source
# ============================================================================

echo
echo "==> Locating ancora source"

ANCORA_SOURCE_DIR="${ANCORA_SOURCE_DIR:-}"


# First choice: explicitly supplied source directory.
if [ -n "${ANCORA_SOURCE_DIR}" ]; then

    echo "Using ANCORA_SOURCE_DIR:"
    echo "    ${ANCORA_SOURCE_DIR}"

# Second choice: sibling repository.
elif [ -f "${REPO_ROOT}/ancora/CMakeLists.txt" ]; then

    ANCORA_SOURCE_DIR="${REPO_ROOT}/ancora"

    echo "Using sibling ancora repository:"
    echo "    ${ANCORA_SOURCE_DIR}"

# Third choice: clone.
else

    ANCORA_SOURCE_DIR="${TOOLKIT_DIR}/ancora"

    echo "ancora source not found locally."
    echo "Cloning:"
    echo "    ${ANCORA_REPO_URL}"

    if [ ! -d "${ANCORA_SOURCE_DIR}/.git" ]; then

        git clone \
            --depth 1 \
            "${ANCORA_REPO_URL}" \
            "${ANCORA_SOURCE_DIR}"

    fi

fi


[ -f "${ANCORA_SOURCE_DIR}/CMakeLists.txt" ] || \
    die "ancora source not found at ${ANCORA_SOURCE_DIR}"


echo
echo "Using ancora source:"
echo "    ${ANCORA_SOURCE_DIR}"


# ============================================================================
# 9. Build ancora — FAST CPU
# ============================================================================
#
# Configuration:
#
#     ANCORA_MODE_SAFE=OFF
#     ANCORA_USE_GPU=OFF
#
# Output:
#
#     libancora_fast.a
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
    -DCMAKE_BUILD_TYPE=Release \
    -DANCORA_MODE_SAFE=OFF \
    -DANCORA_USE_GPU=OFF \
    -DANCORA_BUILD_TESTS=OFF \
    -DBLA_VENDOR=OpenBLAS \
    -DBLAS_LIBRARIES="${BLAS_LIBRARY}"



echo
echo "==> Building ancora CPU library"


cmake \
    --build "${CPU_BUILD_DIR}" \
    --target ancora \
    -j"$(nproc)"


[ -f "${CPU_BUILD_DIR}/libancora_fast.a" ] || \
    die "CPU ancora library was not produced"


# ============================================================================
# 10. Build CPU benchmark
# ============================================================================

echo
echo "==> Building CPU benchmark"


cc \
    -O2 \
    -std=c11 \
    -I"${ANCORA_SOURCE_DIR}/include" \
    -DANCORA_MODE=ANCORA_MODE_FAST \
    "${TOOLKIT_DIR}/src/ancora_benchmark.c" \
    -o "${TOOLKIT_DIR}/ancora_benchmark_cpu" \
    "${CPU_BUILD_DIR}/libancora_fast.a" \
    -lhighs \
    "${BLAS_LIBRARY}" \
    -lm



[ -x "${TOOLKIT_DIR}/ancora_benchmark_cpu" ] || \
    die "CPU benchmark was not produced"


echo
echo "CPU benchmark built:"
echo "    ${TOOLKIT_DIR}/ancora_benchmark_cpu"


# ============================================================================
# 11. Build ancora — FAST NVIDIA GPU
# ============================================================================
#
# Configuration:
#
#     ANCORA_MODE_SAFE=OFF
#     ANCORA_USE_GPU=ON
#     ANCORA_GPU_PLATFORM=nvidia
#
# Output:
#
#     libancora_fast_gpu.a
#
# ============================================================================

echo
echo "============================================================"
echo "Building ancora FAST NVIDIA GPU"
echo "============================================================"


GPU_BUILD_DIR="${TOOLKIT_DIR}/build/ancora_gpu"


if ! have_command hipcc; then

    echo
    echo "warning: hipcc is unavailable."
    echo "         Skipping GPU build."
    echo "         GPU instances will report unsupported."

else

    echo
    echo "==> Configuring NVIDIA HIP build"


    GPU_CMAKE_ARGS=(
        -S "${ANCORA_SOURCE_DIR}"
        -B "${GPU_BUILD_DIR}"
        -DCMAKE_BUILD_TYPE=Release
        -DANCORA_MODE_SAFE=OFF
        -DANCORA_USE_GPU=ON
        -DANCORA_BUILD_TESTS=OFF
        -DANCORA_GPU_PLATFORM=nvidia
        -DANCORA_ROCM_ROOT="${ANCORA_ROCM_ROOT}"
    )


    if [ -n "${ANCORA_HIP_ARCHITECTURES}" ]; then
        GPU_CMAKE_ARGS+=(
            "-DANCORA_HIP_ARCHITECTURES=${ANCORA_HIP_ARCHITECTURES}"
        )
    fi


    if cmake "${GPU_CMAKE_ARGS[@]}"; then

        echo
        echo "==> NVIDIA GPU configuration succeeded"

    else

        echo
        echo "warning: NVIDIA GPU configuration failed."
        echo "         GPU instances will report unsupported."

        GPU_CONFIG_FAILED=1

    fi


    if [ "${GPU_CONFIG_FAILED:-0}" -eq 0 ]; then

        echo
        echo "==> Building ancora NVIDIA GPU library"


        if cmake \
            --build "${GPU_BUILD_DIR}" \
            --target ancora \
            -j"$(nproc)"; then

            echo
            echo "NVIDIA GPU library built successfully"

        else

            echo
            echo "warning: NVIDIA GPU library build failed."
            echo "         GPU instances will report unsupported."

            GPU_BUILD_FAILED=1

        fi

    fi


    # ------------------------------------------------------------------------
    # Build GPU benchmark driver
    # ------------------------------------------------------------------------

    if [ "${GPU_CONFIG_FAILED:-0}" -eq 0 ] && \
       [ "${GPU_BUILD_FAILED:-0}" -eq 0 ] && \
       [ -f "${GPU_BUILD_DIR}/libancora_fast_gpu.a" ]; then


        echo
        echo "==> Locating HIP runtime"


        HIP_LIBDIR="$(
            grep -E '^HIP_LIBRARY:FILEPATH=' \
                "${GPU_BUILD_DIR}/CMakeCache.txt" \
                | head -1 \
                | cut -d= -f2 \
                | xargs dirname 2>/dev/null || true
        )


        if [ -z "${HIP_LIBDIR}" ]; then
            HIP_LIBDIR="${ANCORA_ROCM_ROOT}/lib"
        fi


        if [ ! -f "${HIP_LIBDIR}/libamdhip64.so" ]; then

            if [ -f "${ANCORA_ROCM_ROOT}/lib/libamdhip64.so" ]; then
                HIP_LIBDIR="${ANCORA_ROCM_ROOT}/lib"
            fi

        fi


        if [ ! -f "${HIP_LIBDIR}/libamdhip64.so" ]; then

            echo
            echo "warning: libamdhip64.so was not found."
            echo "         GPU benchmark will not be built."

        else

            echo "HIP runtime:"
            echo "    ${HIP_LIBDIR}/libamdhip64.so"


            echo
            echo "==> Building NVIDIA GPU benchmark"


            # The HIP objects may not be compatible with a PIE executable,
            # so explicitly disable PIE.
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
                -lopenblas \
                -lm


            if [ -x "${TOOLKIT_DIR}/ancora_benchmark_gpu" ]; then

                echo
                echo "NVIDIA GPU benchmark built:"
                echo "    ${TOOLKIT_DIR}/ancora_benchmark_gpu"

            else

                echo
                echo "warning: GPU benchmark was not produced."

            fi

        fi

    fi

fi


# ============================================================================
# 12. Final summary
# ============================================================================

echo
echo "============================================================"
echo "Installation complete"
echo "============================================================"

if [ -x "${TOOLKIT_DIR}/ancora_benchmark_cpu" ]; then
    echo "CPU benchmark:"
    echo "    ${TOOLKIT_DIR}/ancora_benchmark_cpu"
else
    echo "CPU benchmark: NOT AVAILABLE"
fi


if [ -x "${TOOLKIT_DIR}/ancora_benchmark_gpu" ]; then
    echo "GPU benchmark:"
    echo "    ${TOOLKIT_DIR}/ancora_benchmark_gpu"
else
    echo "GPU benchmark: NOT AVAILABLE"
fi


echo
echo "GPU platform: NVIDIA"
echo "HIP backend:  HIP-over-CUDA"
echo "ROCm root:    ${ANCORA_ROCM_ROOT}"
echo "ROCm version: ${ROCM_VERSION}"
echo "============================================================"
