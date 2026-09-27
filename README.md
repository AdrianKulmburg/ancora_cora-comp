# ancora CORA-COMP toolkit

A CORA-COMP tool submission that solves the benchmark catalog with the
[ancora](https://github.com/AdrianKulmburg/ancora) library. It provides the
three required scripts (`install_tool.sh`, `prepare_instance.sh`,
`run_instance.sh`) plus a C benchmark driver (`src/ancora_benchmark.c`) that
dispatches on the instance's `params` and performs each operation with ancora.

## What it solves

The catalog defines two set representations — `interval` and `zonotope`, each
plain and `-batched` — and six operations, plus a `test`/`startup` overhead
instance. The driver maps each operation to an ancora call:

| Operation | interval | zonotope |
| --- | --- | --- |
| `generateRandom` | `ancora_interval_initRandom_uniform` | `ancora_zonotope_initRandom_uniform` |
| `randPoint` | `ancora_interval_randomPoints_uniform` | `ancora_zonotope_randomPoints_standard` |
| `supportFunc` | `ancora_interval_supportFunction` | `ancora_zonotope_supportFunction` |
| `matMul` | `ancora_interval_affine` (c = 0) | `ancora_zonotope_affine` (c = 0) |
| `minkSum` | `ancora_interval_minkowskiSum` | `ancora_zonotope_minkowskiSum` |
| `contains` | `ancora_interval_containsPoints` | `ancora_zonotope_containsPoints` |

On a `-batched` benchmark (`batch_size` > 1) the driver uses the corresponding
`ancora_*_batched_*` variant, e.g. `ancora_interval_batched_minkowskiSum`,
`ancora_zonotope_batched_affine`, `ancora_interval_batched_containsPoints`,
etc. `generateRandom` has no batched ancora primitive, so the batched case
loops over the batch calling the single-instance generator per set (the
catalog explicitly allows "one set after another" where a library has no
vectorized call).

`matMul` maps to the affine map with a zero translation vector `c`, matching
`M * S` for a set `S`.

## Build

`install_tool.sh` obtains the ancora source from, in order:

1. `ANCORA_SOURCE_DIR`, if set (a local path to the ancora source tree);
2. a sibling directory named `ancora` next to this repo root;
3. a `git clone` of `https://github.com/AdrianKulmburg/ancora` (the default).

It then builds ancora in **FAST mode** (plain double) **twice** — once without
GPU and once with GPU — and compiles the driver against each:

- `ancora_benchmark_cpu` — linked against `libancora_fast` (no GPU)
- `ancora_benchmark_gpu` — linked against `libancora_fast_gpu` (GPU kernels)

`run_instance.sh` picks the right binary from the instance's `device` field.
The GPU build requires a HIP/ROCm toolchain; if it is not available,
`install_tool.sh` skips it and `run_instance.sh` reports `unsupported` for
`gpu` instances (never silently falling back to the CPU).

It needs:

- `git` (to clone ancora if not provided locally);
- CMake and a C compiler;
- HiGHS (ancora's FAST-mode zonotope containment uses it);
- for the GPU build: a HIP/ROCm toolchain (`hipcc`), and optionally
  `ANCORA_GPU_PLATFORM` (`amd` or `nvidia`) and `ANCORA_HIP_ARCHITECTURES`.

```bash
./install_tool.sh v1
```

This produces `./ancora_benchmark_cpu` and (if HIP is present)
`./ancora_benchmark_gpu` in the toolkit directory.

## Running an instance

`run_instance.sh` parses the instance's `params` JSON and invokes the driver
for the instance's device:

```bash
./run_instance.sh v1 zonotope matMul-500d-cpu \
  '{"set":"zonotope","operation":"matMul","dim":500,"generators":1000,"device":"cpu","repetition":100}' \
  /path/to/results.csv
```

The driver generates the random inputs the catalog defines, performs the
operation `repetition` times, and exits 0 on success. `run_instance.sh` writes
the `finished`/`error` verdict to the results file.

### GPU instances

For a `gpu` instance, `run_instance.sh` runs `ancora_benchmark_gpu`. The GPU
driver is the same source compiled with `-DANCORA_USE_GPU=1`; ancora's
arithmetic then dispatches to its HIP kernels internally (each operation copies
the operands to the device, runs the kernel, and copies the result back).

Running a GPU instance requires a GPU device on the worker (the platform's
Docker backends pass `--gpus all` into the node container when
`COMP_DOCKER_GPU=1` is set). If the GPU driver was not built (no HIP toolchain),
the instance reports `unsupported`. If it was built but no GPU device is present
at runtime, the GPU kernel launches fail and the instance reports `error` — the
benchmark only runs `gpu` instances on GPU-capable workers.

## Notes on random sets

The catalog says random sets follow CORA's `generateRandom`. The driver uses
ancora's `*_initRandom_uniform` generators (as directed), which draw interval
bounds from `U[-1,1]` and zonotope centers/generators from `U[-1,1]` — a
different distribution from CORA's exact spec (interval `[c−r, c+r]` with
`c~U[-2,2]`, `r_i = R_i·u_i/2`; zonotope `c = 10·randn(n)` with unit-direction
generators). This does not affect the timing methodology or the validity of the
`contains` checks (points are drawn from the set, so containment holds), but if
distribution fidelity to CORA matters, the driver's `make_random_interval` /
`make_random_zonotope` helpers can be replaced with an exact CORA-spec
generator.
