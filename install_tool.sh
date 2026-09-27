#!/bin/bash

# ============================================================================
# install_tool.sh
# ============================================================================
#
# CORA-COMP installation script for ancora.
#
# Requires CMake 3.28+ for native NVIDIA HIP language support.
#
# This installation is specifically for NVIDIA GPUs.
#
# It builds:
#
#   CPU:
#       libancora_fast.a
#       ancora_benchmark_cpu
#
#   NVIDIA GPU:
#       libancora_fast_gpu.a
#       ancora_benchmark_gpu
#
# GPU backend:
#
#       NVIDIA GPU
#           |
#         CUDA
#           |
#       HIP-over-CUDA
#           |
#         ancora
#
# The script detects the actual NVIDIA GPU before building.
#
# For example:
#
#   NVIDIA A100
#       compute capability 8.0
#       HIP architecture 80
#
# If the GPU cannot be identified, installation stops immediately.
#
# ============================================================================

set -euo pipefail


# ============================================================================
# Configuration
# ============================================================================

VERSION="${1:-v1}"

ANCORA_GPU_PLATFORM="nvidia"

ROCM_VERSION="${ROCM_VERSION:-6.3.1}"

ANCORA_ROCM_ROOT="${ANCORA_ROCM_ROOT:-/opt/rocm}"

ANCORA_REPO_URL="${ANCORA_REPO_URL:-https://github.com/AdrianKulmburg/ancora}"


# These are determined automatically from nvidia-smi.
ANCORA_GPU_NAME=""
ANCORA_GPU_COMPUTE_CAPABILITY=""
ANCORA_HIP_ARCHITECTURES=""


# ============================================================================
# Paths
# ============================================================================

TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TOOLKIT_DIR}/.." && pwd)"


# ============================================================================
# Helpers
# ============================================================================

die()
{
    echo
    echo "============================================================" >&2
    echo "ERROR" >&2
    echo "============================================================" >&2
    echo "$*" >&2
    echo "============================================================" >&2
    exit 1
}


have_command()
{
    command -v "$1" >/dev/null 2>&1
}


section()
{
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}


# ============================================================================
# Banner
# ============================================================================

section "Installing ancora tool"

echo "Interface version : ${VERSION}"
echo "Toolkit directory : ${TOOLKIT_DIR}"
echo "Repository root   : ${REPO_ROOT}"
echo "GPU platform      : NVIDIA"
echo "HIP backend       : HIP-over-CUDA"
echo "ROCm version      : ${ROCM_VERSION}"
echo "ROCm root         : ${ANCORA_ROCM_ROOT}"


# ============================================================================
# 1. Base build tools
# ============================================================================

section "Installing base build tools"

apt-get update

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    cmake \
    gcc \
    g++ \
    git \
    python3 \
    python3-pip \
    wget \
    curl \
    build-essential \
    libgomp1 \
    ca-certificates \
    gpg \
    pkg-config


# ============================================================================
# 2. CMake
# ============================================================================
#
# CMake 3.28 introduced native NVIDIA HIP language support. Ubuntu 22.04
# commonly provides CMake 3.22, which is too old for HIP-over-CUDA builds.
#
# Install CMake from the Python wheel so the build does not depend on the
# Ubuntu repository's CMake version.
# ============================================================================

section "Checking CMake"

CMAKE_MIN_VERSION="3.28.0"

python3 -m pip install --upgrade --disable-pip-version-check "cmake>=3.28,<4"

# Prefer the pip-installed CMake if it lives outside the normal PATH.
if [ -x /usr/local/bin/cmake ]; then
    export PATH="/usr/local/bin:${PATH}"
fi

if ! have_command cmake; then
    die "CMake was not found after installation."
fi

echo
echo "CMake:"
echo "    $(command -v cmake)"
cmake --version

CMAKE_VERSION="$(
    cmake --version |
    head -1 |
    sed -E 's/.* ([0-9]+\.[0-9]+\.[0-9]+).*/\1/'
)"

if [ -z "${CMAKE_VERSION}" ]; then
    die "Could not determine the installed CMake version."
fi

if [ "$(printf '%s\n' "${CMAKE_VERSION}" "${CMAKE_MIN_VERSION}" | sort -V | head -1)" != "${CMAKE_MIN_VERSION}" ]; then
    die "CMake ${CMAKE_MIN_VERSION} or newer is required; found ${CMAKE_VERSION}."
fi


# ============================================================================
# 3. Detect NVIDIA GPU
# ============================================================================
#
# IMPORTANT:
#
# Do this BEFORE configuring CMake/HIP.
#
# The previous failure:
#
#     Failed to find a default HIP architecture
#
# happened because CMake 3.22 attempted to initialize HIP before an explicit
# architecture was supplied.
#
# We therefore query the actual GPU and derive the architecture first.
# ============================================================================

section "Checking NVIDIA GPU"

if ! have_command nvidia-smi; then
    die "nvidia-smi was not found. This worker does not appear to have an NVIDIA GPU/driver."
fi


echo "nvidia-smi:"
nvidia-smi


# ---------------------------------------------------------------------------
# Query GPU name and compute capability.
#
# nvidia-smi normally returns one line per GPU.
# ---------------------------------------------------------------------------

GPU_QUERY="$(
    nvidia-smi \
        --query-gpu=name,compute_cap \
        --format=csv,noheader,nounits \
        2>/dev/null
)" || die "nvidia-smi could not query the GPU."


if [ -z "${GPU_QUERY}" ]; then
    die "nvidia-smi returned no GPU information."
fi


echo
echo "GPU query:"
echo "${GPU_QUERY}"


# ---------------------------------------------------------------------------
# We expect a single GPU on the worker.
#
# If multiple GPUs are present, use the first one only if all GPUs have the
# same compute capability. Otherwise stop rather than producing a binary
# targeted at the wrong device.
# ---------------------------------------------------------------------------

GPU_COUNT="$(printf '%s\n' "${GPU_QUERY}" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"

if [ "${GPU_COUNT}" -lt 1 ]; then
    die "No NVIDIA GPU was detected."
fi


ANCORA_GPU_NAME="$(
    printf '%s\n' "${GPU_QUERY}" \
        | head -1 \
        | cut -d',' -f1 \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
)"


ANCORA_GPU_COMPUTE_CAPABILITY="$(
    printf '%s\n' "${GPU_QUERY}" \
        | head -1 \
        | cut -d',' -f2 \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
)"


if [ -z "${ANCORA_GPU_NAME}" ]; then
    die "Could not determine NVIDIA GPU name."
fi


if [ -z "${ANCORA_GPU_COMPUTE_CAPABILITY}" ]; then
    die "Could not determine NVIDIA GPU compute capability."
fi


echo
echo "GPU name:"
echo "    ${ANCORA_GPU_NAME}"

echo
echo "GPU compute capability:"
echo "    ${ANCORA_GPU_COMPUTE_CAPABILITY}"


# ---------------------------------------------------------------------------
# Verify all GPUs have the same compute capability.
# ---------------------------------------------------------------------------

if [ "${GPU_COUNT}" -gt 1 ]; then

    FIRST_CC="${ANCORA_GPU_COMPUTE_CAPABILITY}"

    while IFS= read -r GPU_LINE; do

        [ -z "${GPU_LINE}" ] && continue

        CC="$(
            printf '%s\n' "${GPU_LINE}" \
                | cut -d',' -f2 \
                | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
        )"

        if [ "${CC}" != "${FIRST_CC}" ]; then
            die \
                "Multiple NVIDIA GPUs with different compute capabilities were detected. " \
                "Refusing to guess a HIP architecture."
        fi

    done <<< "${GPU_QUERY}"

fi


# ---------------------------------------------------------------------------
# Convert compute capability to HIP/CUDA architecture.
#
# Examples:
#
#   8.0 -> 80
#   8.6 -> 86
#   8.9 -> 89
#   9.0 -> 90
#
# NVIDIA HIP uses the CUDA-style architecture number for the NVIDIA backend.
# ---------------------------------------------------------------------------

ANCORA_HIP_ARCHITECTURES="$(
    printf '%s' "${ANCORA_GPU_COMPUTE_CAPABILITY}" \
        | tr -d '.'
)"


if ! [[ "${ANCORA_HIP_ARCHITECTURES}" =~ ^[0-9]+$ ]]; then
    die \
        "Could not convert compute capability '${ANCORA_GPU_COMPUTE_CAPABILITY}' " \
        "to a HIP architecture."
fi


echo
echo "HIP architecture:"
echo "    ${ANCORA_HIP_ARCHITECTURES}"


# ---------------------------------------------------------------------------
# Explicitly handle the A100 we expect on the competition worker.
# ---------------------------------------------------------------------------

if [ "${ANCORA_GPU_COMPUTE_CAPABILITY}" = "8.0" ]; then
    echo
    echo "Detected NVIDIA A100-class compute capability."
    echo "Using HIP architecture 80."
fi


# ============================================================================
# 4. BLAS / OpenBLAS
# ============================================================================

section "Installing BLAS / OpenBLAS"

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    libblas-dev \
    libopenblas-dev


echo
echo "Checking BLAS installation"


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

    echo
    echo "Installed BLAS files:" >&2

    dpkg -L libblas-dev 2>/dev/null >&2 || true
    dpkg -L libopenblas-dev 2>/dev/null >&2 || true

    die "Could not locate a BLAS library."

fi


# ---------------------------------------------------------------------------
# Find cblas.h explicitly.
#
# This avoids the earlier failure where OpenBLAS was installed but CMake
# couldn't locate the CBLAS header.
# ---------------------------------------------------------------------------

CBLAS_HEADER=""

for candidate in \
    /usr/include/cblas.h \
    /usr/include/x86_64-linux-gnu/cblas.h \
    /usr/include/openblas/cblas.h \
    /usr/local/include/cblas.h
do

    if [ -f "${candidate}" ]; then
        CBLAS_HEADER="${candidate}"
        break
    fi

done


if [ -z "${CBLAS_HEADER}" ]; then

    echo
    echo "Searching for cblas.h:" >&2

    find \
        /usr/include \
        /usr/local/include \
        -name cblas.h \
        -type f \
        2>/dev/null \
        | head -20 >&2 || true

    die "Could not locate cblas.h."

fi


CBLAS_INCLUDE_DIR="$(dirname "${CBLAS_HEADER}")"


echo "BLAS library:"
echo "    ${BLAS_LIBRARY}"

echo
echo "CBLAS header:"
echo "    ${CBLAS_HEADER}"

echo
echo "CBLAS include directory:"
echo "    ${CBLAS_INCLUDE_DIR}"


ldconfig


# ============================================================================
# 5. HiGHS
# ============================================================================

section "Installing HiGHS"

if [ ! -f /usr/local/include/highs/interfaces/highs_c_api.h ] || \
   [ ! -f /usr/local/lib/libhighs.so ]; then

    echo "Building HiGHS from source."

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
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_TESTING=OFF


    cmake \
        --build "${HIGHS_SRC}/build" \
        -j"$(nproc)"


    cmake \
        --install "${HIGHS_SRC}/build"


    ldconfig

else

    echo "HiGHS is already installed."

fi


# ============================================================================
# 6. CUDA
# ============================================================================
#
# NVIDIA driver and CUDA toolkit are separate things.
#
# The driver is already present because nvidia-smi worked above.
# We still need nvcc for HIP-over-CUDA compilation.
# ============================================================================

section "Checking CUDA"

CUDA_ROOT=""


# ---------------------------------------------------------------------------
# Existing conventional installation.
# ---------------------------------------------------------------------------

if [ -x /usr/local/cuda/bin/nvcc ]; then
    CUDA_ROOT="/usr/local/cuda"
fi


# ---------------------------------------------------------------------------
# Existing versioned installation.
# ---------------------------------------------------------------------------

if [ -z "${CUDA_ROOT}" ]; then

    for candidate in /usr/local/cuda-*; do

        if [ -x "${candidate}/bin/nvcc" ]; then
            CUDA_ROOT="${candidate}"
            break
        fi

    done

fi


# ---------------------------------------------------------------------------
# Install CUDA if necessary.
# ---------------------------------------------------------------------------

if [ -z "${CUDA_ROOT}" ]; then

    echo "CUDA toolkit not found."
    echo "Installing NVIDIA CUDA toolkit."

    CUDA_KEYRING="cuda-keyring_1.1-1_all.deb"
    CUDA_KEYRING_PATH="/tmp/${CUDA_KEYRING}"


    wget -q \
        "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/${CUDA_KEYRING}" \
        -O "${CUDA_KEYRING_PATH}"


    dpkg -i "${CUDA_KEYRING_PATH}"


    apt-get update


    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        cuda-toolkit


    # Search again after installation.

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


if [ -z "${CUDA_ROOT}" ]; then

    echo
    echo "Searching for nvcc:" >&2

    find \
        /usr/local \
        /usr \
        -name nvcc \
        -type f \
        2>/dev/null \
        | head -20 >&2 || true


    echo
    echo "Installed CUDA packages:" >&2

    dpkg -l | grep -i cuda >&2 || true


    die "CUDA installation completed, but nvcc was not found."

fi


export CUDA_HOME="${CUDA_ROOT}"
export CUDA_PATH="${CUDA_ROOT}"

export PATH="${CUDA_ROOT}/bin:${PATH}"

if [ -d "${CUDA_ROOT}/lib64" ]; then

    export LD_LIBRARY_PATH="${CUDA_ROOT}/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

fi


echo
echo "CUDA root:"
echo "    ${CUDA_ROOT}"

echo
echo "nvcc:"
echo "    $(command -v nvcc)"

nvcc --version

section "Debugging CUDA / ROCm Version Skew"

echo "=== System Info ==="
nvcc --version
cat /usr/local/cuda/version.txt 2>/dev/null || true
dpkg -l | grep -E "cuda|rocm|hip" || true

# Force an early exit to inspect the output
die "Stopping here to inspect CUDA and ROCm versions."


# ============================================================================
# 7. HIP / ROCm NVIDIA backend
# ============================================================================

section "Installing HIP-over-CUDA"

export HIP_PLATFORM="nvidia"


if [ ! -f "${ANCORA_ROCM_ROOT}/include/hip/hip_runtime.h" ]; then

    echo "HIP not found."
    echo "Installing ROCm HIP ${ROCM_VERSION}."

    wget -q -O - \
        https://repo.radeon.com/rocm/rocm.gpg.key \
        | gpg --dearmor --yes -o /usr/share/keyrings/rocm.gpg


    echo \
        "deb [arch=amd64 signed-by=/usr/share/keyrings/rocm.gpg] " \
        "https://repo.radeon.com/rocm/apt/${ROCM_VERSION} jammy main" \
        > /etc/apt/sources.list.d/rocm.list


    apt-get update


    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        hip-runtime-nvidia \
        hip-dev

else

    echo "HIP headers already exist."

fi


export PATH="${ANCORA_ROCM_ROOT}/bin:${PATH}"


if [ ! -x "${ANCORA_ROCM_ROOT}/bin/hipcc" ]; then

    if ! have_command hipcc; then
        die "HIP installation completed, but hipcc was not found."
    fi

fi


echo
echo "HIP compiler:"
echo "    $(command -v hipcc)"

hipcc --version


# ============================================================================
# 8. hipBLAS
# ============================================================================

section "Installing hipBLAS"

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    hipblas \
    hipblas-dev


# ============================================================================
# 9. Verify HIP NVIDIA backend
# ============================================================================

section "Verifying HIP NVIDIA backend"

export HIP_PLATFORM="nvidia"

if have_command hipconfig; then

    hipconfig --full || true

fi


echo
echo "HIP_PLATFORM:"
echo "    ${HIP_PLATFORM}"


# ============================================================================
# 10. Locate ancora source
# ============================================================================

section "Locating ancora source"

ANCORA_SOURCE_DIR="${ANCORA_SOURCE_DIR:-}"


if [ -n "${ANCORA_SOURCE_DIR}" ]; then

    echo "Using ANCORA_SOURCE_DIR:"
    echo "    ${ANCORA_SOURCE_DIR}"

elif [ -f "${REPO_ROOT}/ancora/CMakeLists.txt" ]; then

    ANCORA_SOURCE_DIR="${REPO_ROOT}/ancora"

    echo "Using sibling ancora repository:"
    echo "    ${ANCORA_SOURCE_DIR}"

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


if [ ! -f "${ANCORA_SOURCE_DIR}/CMakeLists.txt" ]; then
    die "ancora source not found at ${ANCORA_SOURCE_DIR}"
fi


echo
echo "Using ancora source:"
echo "    ${ANCORA_SOURCE_DIR}"


# ============================================================================
# 11. Build ancora FAST CPU
# ============================================================================

section "Building ancora FAST CPU"

CPU_BUILD_DIR="${TOOLKIT_DIR}/build/ancora_cpu"


cmake \
    -S "${ANCORA_SOURCE_DIR}" \
    -B "${CPU_BUILD_DIR}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DANCORA_MODE_SAFE=OFF \
    -DANCORA_USE_GPU=OFF \
    -DANCORA_BUILD_TESTS=OFF \
    -DBLA_VENDOR=OpenBLAS \
    -DBLAS_LIBRARIES="${BLAS_LIBRARY}" \
    -DBLAS_INCLUDE_DIR="${CBLAS_INCLUDE_DIR}"


cmake \
    --build "${CPU_BUILD_DIR}" \
    --target ancora \
    -j"$(nproc)"


if [ ! -f "${CPU_BUILD_DIR}/libancora_fast.a" ]; then
    die "CPU ancora library was not produced."
fi


echo
echo "CPU library:"
echo "    ${CPU_BUILD_DIR}/libancora_fast.a"


# ============================================================================
# 12. Build CPU benchmark
# ============================================================================

section "Building CPU benchmark"

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


if [ ! -x "${TOOLKIT_DIR}/ancora_benchmark_cpu" ]; then
    die "CPU benchmark was not produced."
fi


echo
echo "CPU benchmark:"
echo "    ${TOOLKIT_DIR}/ancora_benchmark_cpu"


# ============================================================================
# 13. Build ancora FAST NVIDIA GPU
# ============================================================================
#
# The architecture was detected from the actual NVIDIA GPU above.
#
# For the detected A100:
#
#     compute capability = 8.0
#     HIP architecture   = 80
#
# ============================================================================

section "Building ancora FAST NVIDIA GPU"

GPU_BUILD_DIR="${TOOLKIT_DIR}/build/ancora_gpu"


echo
echo "NVIDIA GPU:"
echo "    ${ANCORA_GPU_NAME}"

echo
echo "Compute capability:"
echo "    ${ANCORA_GPU_COMPUTE_CAPABILITY}"

echo
echo "HIP architecture:"
echo "    ${ANCORA_HIP_ARCHITECTURES}"


if ! have_command hipcc; then
    die "hipcc is not available; cannot build the NVIDIA GPU version."
fi

if [ ! -x "${CUDA_ROOT}/bin/nvcc" ]; then
    die "NVCC was not found at ${CUDA_ROOT}/bin/nvcc; cannot build NVIDIA HIP."
fi


# ---------------------------------------------------------------------------
# Configure.
#
# IMPORTANT:
#
# ANCORA_HIP_ARCHITECTURES is passed explicitly so CMake does not have
# to run amdgpu-arch or otherwise guess an architecture.
#
# CMAKE_HIP_PLATFORM=nvidia and CMAKE_HIP_COMPILER=nvcc are passed explicitly
# because this is a native CMake HIP-language build targeting NVIDIA.
# ---------------------------------------------------------------------------

cmake \
    -S "${ANCORA_SOURCE_DIR}" \
    -B "${GPU_BUILD_DIR}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DANCORA_MODE_SAFE=OFF \
    -DANCORA_USE_GPU=ON \
    -DANCORA_GPU_PLATFORM=nvidia \
    -DANCORA_HIP_ARCHITECTURES="${ANCORA_HIP_ARCHITECTURES}" \
    -DANCORA_ROCM_ROOT="${ANCORA_ROCM_ROOT}" \
    -DCMAKE_HIP_PLATFORM=nvidia \
    -DCMAKE_HIP_COMPILER="${CUDA_ROOT}/bin/nvcc" \
    -DCMAKE_CUDA_COMPILER="${CUDA_ROOT}/bin/nvcc" \
    -DANCORA_BUILD_TESTS=OFF


# ---------------------------------------------------------------------------
# Build.
# ---------------------------------------------------------------------------

cmake \
    --build "${GPU_BUILD_DIR}" \
    --target ancora \
    -j"$(nproc)"


if [ ! -f "${GPU_BUILD_DIR}/libancora_fast_gpu.a" ]; then
    die "NVIDIA GPU ancora library was not produced."
fi


echo
echo "NVIDIA GPU library:"
echo "    ${GPU_BUILD_DIR}/libancora_fast_gpu.a"


# ============================================================================
# 14. Build NVIDIA GPU benchmark
# ============================================================================
#
# Use hipcc rather than cc.
#
# ROCm documents hipcc as the compiler driver for the NVIDIA HIP backend and
# recommends it for linking because it supplies the required HIP/CUDA runtime
# libraries.
# ============================================================================

section "Building NVIDIA GPU benchmark"

export HIP_PLATFORM="nvidia"


hipcc \
    -x cu \
    -O2 \
    -std=c++17 \
    "--offload-arch=${ANCORA_HIP_ARCHITECTURES}" \
    -I"${ANCORA_SOURCE_DIR}/include" \
    -DANCORA_MODE=ANCORA_MODE_FAST \
    -DANCORA_USE_GPU=1 \
    "${TOOLKIT_DIR}/src/ancora_benchmark.c" \
    "${GPU_BUILD_DIR}/libancora_fast_gpu.a" \
    -L/usr/local/lib \
    -lhighs \
    -lm \
    -o "${TOOLKIT_DIR}/ancora_benchmark_gpu"


if [ ! -x "${TOOLKIT_DIR}/ancora_benchmark_gpu" ]; then
    die "NVIDIA GPU benchmark was not produced."
fi


# ============================================================================
# 15. Final verification
# ============================================================================

section "Final verification"

echo "CPU benchmark:"
echo "    ${TOOLKIT_DIR}/ancora_benchmark_cpu"

echo
echo "GPU benchmark:"
echo "    ${TOOLKIT_DIR}/ancora_benchmark_gpu"

echo
echo "Detected GPU:"
echo "    ${ANCORA_GPU_NAME}"

echo
echo "Compute capability:"
echo "    ${ANCORA_GPU_COMPUTE_CAPABILITY}"

echo
echo "HIP architecture:"
echo "    ${ANCORA_HIP_ARCHITECTURES}"

echo
echo "HIP platform:"
echo "    ${HIP_PLATFORM}"

echo
echo "CUDA root:"
echo "    ${CUDA_ROOT}"

echo
echo "ROCm root:"
echo "    ${ANCORA_ROCM_ROOT}"


# ============================================================================
# 16. Done
# ============================================================================

section "Installation complete"

echo "Both CPU and NVIDIA GPU drivers were built successfully."
echo
echo "CPU:"
echo "    ancora_benchmark_cpu"
echo
echo "GPU:"
echo "    ancora_benchmark_gpu"
echo
echo "NVIDIA GPU:"
echo "    ${ANCORA_GPU_NAME}"
echo
echo "HIP architecture:"
echo "    ${ANCORA_HIP_ARCHITECTURES}"
