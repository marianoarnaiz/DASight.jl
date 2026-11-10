#!/usr/bin/env bash
# ================================================================
#  DASight :: 1_PAINTER :: run_painter.sh
#
#  Paints one PNG per .nc file found in a folder.
#
#  Usage:
#     ./run_painter.sh                         # reads ./data_test
#     ./run_painter.sh /path/to/my_nc_files    # reads any folder
#     ./run_painter.sh data_test my_pics       # choose the output folder
#     ./run_painter.sh data_test --keep-originals
#
#  Output: <output folder>/<name>_RdBu_0_AUTO.png
#  (default output folder: DASight_pics, next to where you run this)
#
#  First time only:   chmod +x run_painter.sh
# ================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../DASight_env.sh"          # sets DASight_JULIA

# --- read arguments: two optional folders + one optional flag ---
KEEP=""
POS=()
for arg in "$@"; do
    case "$arg" in
        --keep-originals) KEEP="--keep-originals" ;;
        *)                POS+=("$arg") ;;
    esac
done
INPUT_DIR="${POS[0]:-data_test}"
OUTPUT_DIR="${POS[1]:-DASight_pics}"

if [ ! -d "$INPUT_DIR" ]; then
    echo "ERROR: input folder '$INPUT_DIR' does not exist." >&2
    exit 1
fi

echo "DASight PAINTER"
echo "  input : $INPUT_DIR"
echo "  output: $OUTPUT_DIR"

# ($KEEP is intentionally unquoted: when empty it must disappear.)
"${DASight_JULIA[@]}" "$HERE/DAS2Pics_nc.jl" "$INPUT_DIR" "$OUTPUT_DIR" $KEEP
