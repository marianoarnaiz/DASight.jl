#!/usr/bin/env bash
# ================================================================
#  DASight :: 3_WATCHER :: start_recording.sh   (FAKE DAS recorder)
#
#  Simulates a DAS instrument: every INTERVAL seconds it copies the next
#  file from SOURCE_DIR (1.jld2 ... 12.jld2, cycling) into OUTPUT_DIR,
#  named  DAS.YYYY.MM.DD-HH.MM.SS.jld2
#
#  Run it in its own terminal, next to ./run_watcher.sh
#
#  Usage:
#     ./start_recording.sh                         # Fake_DAS → DAS_RECORDING, every 60 s
#     ./start_recording.sh Fake_DAS DAS_RECORDING 10     # a file every 10 s
#
#  Stop with Ctrl+C.
# ================================================================
set -euo pipefail

SOURCE_DIR="${1:-Fake_DAS}"          # folder with 1.jld2 ... 12.jld2
OUTPUT_DIR="${2:-DAS_RECORDING}"     # where the "recorded" files appear
INTERVAL="${3:-60}"                  # seconds between files
FILE_PREFIX="DAS"
N_SOURCE=12                          # number of source files

if [ ! -d "$SOURCE_DIR" ]; then
    echo "ERROR: source folder '$SOURCE_DIR' does not exist." >&2
    exit 1
fi
mkdir -p "$OUTPUT_DIR"

echo "=========================================="
echo "  Fake DAS Recording System Started"
echo "=========================================="
echo "Source:   $SOURCE_DIR"
echo "Output:   $OUTPUT_DIR"
echo "Interval: ${INTERVAL}s"
echo "Press Ctrl+C to stop"
echo "=========================================="

file_index=1
while true; do
    source_file="$SOURCE_DIR/${file_index}.jld2"
    if [[ ! -f "$source_file" ]]; then
        echo "ERROR: Source file not found: $source_file" >&2
        exit 1
    fi

    # Timestamp: YYYY.MM.DD-HH.MM.SS
    timestamp=$(date '+%Y.%m.%d-%H.%M.%S')
    output_file="$OUTPUT_DIR/${FILE_PREFIX}.${timestamp}.jld2"

    # Copy under a hidden temporary name, then rename: the watcher never
    # sees a half-written file (it ignores names starting with ".").
    tmp_file="$OUTPUT_DIR/.${FILE_PREFIX}.${timestamp}.jld2.part"
    cp "$source_file" "$tmp_file"
    mv "$tmp_file" "$output_file"

    echo "[$(date '+%H:%M:%S')] Recorded: $output_file (from ${file_index}.jld2)"

    file_index=$((file_index % N_SOURCE + 1))
    sleep "$INTERVAL"
done
