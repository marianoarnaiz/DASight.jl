#!/usr/bin/env bash
# ================================================================
#  DASight :: 2_DETECTIVE :: run_detective.sh
#
#  Classifies the images of a folder (made by 1_PAINTER) and writes
#  lists of signals and noise.
#
#  Usage:
#     ./run_detective.sh                              # images from ./DASight_pics
#     ./run_detective.sh Long_Test                    # any image folder
#     ./run_detective.sh Long_Test my_results         # choose the output folder
#     ./run_detective.sh Long_Test my_results /path/to/MODELS
#
#  Defaults: output folder DASight_results; models = the ones DASight
#  downloads for you (3rd argument only if you want your own).
#  Thresholds and weights: edit the SETTINGS block of Pics2Events.jl
#
#  First time only:   chmod +x run_detective.sh
# ================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../DASight_env.sh"          # sets DASight_JULIA

IMAGE_DIR="${1:-DASight_pics}"
OUTPUT_DIR="${2:-DASight_results}"
MODEL_DIR="${3:-}"

if [ ! -d "$IMAGE_DIR" ]; then
    echo "ERROR: image folder '$IMAGE_DIR' does not exist." >&2
    exit 1
fi
if [ -n "$MODEL_DIR" ] && [ ! -d "$MODEL_DIR" ]; then
    echo "ERROR: models folder '$MODEL_DIR' does not exist." >&2
    exit 1
fi

if [ -n "$MODEL_DIR" ]; then
    "${DASight_JULIA[@]}" "$HERE/Pics2Events.jl" "$IMAGE_DIR" "$OUTPUT_DIR" "$MODEL_DIR"
else
    "${DASight_JULIA[@]}" "$HERE/Pics2Events.jl" "$IMAGE_DIR" "$OUTPUT_DIR"
fi
