#!/bin/bash

# install_tool.sh — run once on the worker to install your tool.
#
# Builds:
#
#   CPU:
#       libancora_fast.a
#       ancora_benchmark_cpu
#
#   NVIDIA GPU:
#       libancora_fast_gpu.a
#       ancora_benchmark_gpu
#
# The GPU build uses HIP over CUDA.
#
# This script intentionally targets NVIDIA only.
#
# Source selection:
#
#   1. ANCORA_SOURCE_DIR, if set
#   2. ../ancora relative to this repository
#   3. git clone from ANCORA_REPO_URL
#
# Argument:
#
#   $1: interface version string, e.g. "v1"

set -e

# ============================================================================
# Configuration
# ============================================================================

VERSION="${1:-v1}"

ANCORA_GPU_PLATFORM="nvidia"

echo
echo "============================================================"
echo "Checking NVIDIA GPU"
echo "============================================================"

if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "ERROR: nvidia-smi is not available." >&2
    exit 1
fi

if ! nvidia-smi; then
    echo "ERROR: nvidia-smi failed." >&2
    exit 1
fi

GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader)"

if [ -z "${GPU_NAME}" ]; then
    echo "ERROR: No NVIDIA GPU detected." >&2
    exit 1
fi

echo
echo "GPU name:"
echo "    ${GPU_NAME}"

echo
echo "GPU compute capability:"
nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null || true

echo
echo "Stopping installation intentionally so the GPU can be identified."
exit 1


ROCM_VERSION="${ROCM_VERSION:-6.3.1}"
ANCORA_ROCM_ROOT="${ANCORA_ROCM_ROOT:-/opt/rocm}"

# Optional NVIDIA GPU architecture.
#
# Examples:
#   A100       -> 80
#   A10        -> 86
#   RTX 3090   -> 86
#   RTX 4090   -> 89
#   L40/L40S   -> 89
#
# Leave empty to let the CMake/HIP configuration choose.
ANCORA_HIP_ARCHITECTURES="${ANCORA_HIP_ARCHITECTURES:-}"

ANCORA_REPO_URL="${ANCORA_REPO_URL:-https://github.com/AdrianKulmburg/ancora}"

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
    echo "ERROR: $*" >&2
    exit 1
}

have_command()
{
    command -v "$1" >/dev/null 2>&1
}

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
# 2. BLAS / OpenBLAS
# ============================================================================

echo
echo "==> Installing BLAS / OpenBLAS"

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    libblas-dev \
    libopenblas-dev

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
# Find an existing installation first. CUDA may be installed at:
#
#   /usr/local/cuda
#   /usr/local/cuda-12.x
#
# ============================================================================

echo
echo "==> Checking CUDA"

CUDA_ROOT=""

if [ -x /usr/local/cuda/bin/nvcc ]; then
    CUDA_ROOT="/usr/local/cuda"
fi

if [ -z "${CUDA_ROOT}" ]; then
    for candidate in /usr/local/cuda-*; do
        if [ -x "${candidate}/bin/nvcc" ]; then
            CUDA_ROOT="${candidate}"
            break
        fi
    done
fi

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

    if [ -x /usr/local/cuda/bin/nvcc ]; then
        CUDA_ROOT="/usr/local/cuda"
    fi

    if [ -z "${CUDA_ROOT}" ]; then
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
    echo "CUDA installation completed, but nvcc could not be located." >&2

    echo
    echo "Searching for nvcc:" >&2

    find /usr/local /usr -name nvcc -type f 2>/dev/null |
        head -20 >&2 || true

    echo
    echo "Installed CUDA packages:" >&2

    dpkg -l | grep -i cuda >&2 || true

    die "Could not locate CUDA nvcc"
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

# ============================================================================
# 5. HIP / ROCm — NVIDIA backend
# ============================================================================

echo
echo "==> Checking HIP"

if [ -f "${ANCORA_ROCM_ROOT}/include/hip/hip_runtime.h" ]; then

    echo "HIP headers already exist:"
    echo "    ${ANCORA_ROCM_ROOT}/include/hip/hip_runtime.h"

else

    echo "HIP not found; installing ROCm/HIP ${ROCM_VERSION}"

    wget -q -O - \
        https://repo.radeon.com/rocm/rocm.gpg.key |
        gpg --dearmor -o /usr/share/keyrings/rocm.gpg

    echo \
        "deb [arch=amd64 signed-by=/usr/share/keyrings/rocm.gpg] " \
        "https://repo.radeon.com/rocm/apt/${ROCM_VERSION} jammy main" \
        > /etc/apt/sources.list.d/rocm.list

    apt-get update

    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        hip-runtime-nvidia \
        hip-dev
fi

export PATH="${ANCORA_ROCM_ROOT}/bin:${CUDA_ROOT}/bin:${PATH}"

export HIP_PLATFORM="nvidia"
export CUDA_PATH="${CUDA_ROOT}"

if [ -d "${ANCORA_ROCM_ROOT}/lib" ]; then
    export LD_LIBRARY_PATH="${ANCORA_ROCM_ROOT}/lib:${LD_LIBRARY_PATH}"
fi

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
# 6. hipBLAS
# ============================================================================

echo
echo "==> Installing hipBLAS"

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    hipblas \
    hipblas-dev

# ============================================================================
# 7. Locate ancora source
# ============================================================================

echo
echo "==> Locating ancora source"

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

[ -f "${ANCORA_SOURCE_DIR}/CMakeLists.txt" ] || \
    die "ancora source not found at ${ANCORA_SOURCE_DIR}"

echo
echo "Using ancora source:"
echo "    ${ANCORA_SOURCE_DIR}"

# ============================================================================
# 8. Build ancora — FAST CPU
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
# 9. Build CPU benchmark
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
# 10. Build ancora — FAST NVIDIA GPU
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
        -DCMAKE_HIP_PLATFORM=nvidia
        -DCUDAToolkit_ROOT="${CUDA_ROOT}"
    )

    if [ -n "${ANCORA_HIP_ARCHITECTURES}" ]; then
        GPU_CMAKE_ARGS+=(
            "-DANCORA_HIP_ARCHITECTURES=${ANCORA_HIP_ARCHITECTURES}"
        )
    fi

    GPU_CONFIG_FAILED=0
    GPU_BUILD_FAILED=0

    if cmake "${GPU_CMAKE_ARGS[@]}"; then

        echo
        echo "==> NVIDIA GPU configuration succeeded"

    else

        echo
        echo "warning: NVIDIA GPU configuration failed."
        echo "         GPU instances will report unsupported."

        GPU_CONFIG_FAILED=1
    fi

    if [ "${GPU_CONFIG_FAILED}" -eq 0 ]; then

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

    # ========================================================================
    # 11. Build GPU benchmark
    # ========================================================================

    if [ "${GPU_CONFIG_FAILED}" -eq 0 ] && \
       [ "${GPU_BUILD_FAILED}" -eq 0 ] && \
       [ -f "${GPU_BUILD_DIR}/libancora_fast_gpu.a" ]; then

        echo
        echo "==> Locating NVIDIA HIP runtime"

        # HIP-over-CUDA still uses the HIP runtime library, but on NVIDIA
        # installations the exact library location can differ. Search rather
        # than assuming libamdhip64.so.
        HIP_RUNTIME_LIB=""

        for candidate in \
            "${ANCORA_ROCM_ROOT}/lib/libamdhip64.so" \
            "${ANCORA_ROCM_ROOT}/lib64/libamdhip64.so" \
            /usr/lib/x86_64-linux-gnu/libamdhip64.so
        do
            if [ -f "${candidate}" ]; then
                HIP_RUNTIME_LIB="${candidate}"
                break
            fi
        done

        # If CMake recorded the HIP library, prefer that.
        if [ -f "${GPU_BUILD_DIR}/CMakeCache.txt" ]; then

            CMAKE_HIP_LIB="$(
                grep -E '^HIP_LIBRARY:FILEPATH=' \
                    "${GPU_BUILD_DIR}/CMakeCache.txt" |
                head -1 |
                cut -d= -f2
            )"

            if [ -n "${CMAKE_HIP_LIB}" ] && \
               [ -f "${CMAKE_HIP_LIB}" ]; then
                HIP_RUNTIME_LIB="${CMAKE_HIP_LIB}"
            fi
        fi

        if [ -z "${HIP_RUNTIME_LIB}" ]; then

            echo
            echo "warning: HIP runtime library was not found."
            echo "         GPU benchmark will not be built."

        else

            HIP_LIBDIR="$(dirname "${HIP_RUNTIME_LIB}")"

            echo "HIP runtime:"
            echo "    ${HIP_RUNTIME_LIB}"

            echo
            echo "==> Building NVIDIA GPU benchmark"

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
                "${BLAS_LIBRARY}" \
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
echo "CUDA root:    ${CUDA_ROOT}"
echo "ROCm root:    ${ANCORA_ROCM_ROOT}"
echo "ROCm version: ${ROCM_VERSION}"
echo "============================================================"
