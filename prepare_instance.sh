#!/bin/bash

# prepare_instance.sh — untimed setup before each instance.
# Arguments (the interface version, then the instance's instances.csv columns in file order):
# - $1: interface version string, e.g. "v1"
# - $2: benchmark,  the set representation, e.g. "zonotope" or "zonotope-batched"
# - $3: instance,   "<operation>-<n>d[-b<batch>]-<device>", e.g. "matMul-500d-b10-gpu"
# - $4: params,     JSON object with everything the tool needs, e.g. '{"set": "zonotope",
#                   "operation": "matMul", "dim": 500, "generators": 1000, "device": "gpu",
#                   "repetition": 100, "batch_size": 10}'
# A column added to the catalog later arrives as a further argument, in file order.
#
# This step is NOT timed, and the instance itself — inputs included — belongs in
# run_instance.sh. Use it only for setup the measurement should not carry, such as starting
# a long-lived process for your library or initializing the GPU. Doing nothing is fine.
#
# A nonzero exit code skips this instance.

set -e

VERSION_STRING="v1"
if [ "$1" != "$VERSION_STRING" ]; then
    echo "Expected first argument (version string) '$VERSION_STRING', got '$1'"
    exit 1
fi

# No untimed setup is needed: the benchmark driver is a standalone binary that does all
# input generation and measurement inside run_instance.sh.

exit 0
