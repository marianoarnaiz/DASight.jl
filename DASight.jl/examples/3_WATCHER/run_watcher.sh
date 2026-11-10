#!/usr/bin/env bash
# ================================================================
#  DASight :: 3_WATCHER :: run_watcher.sh
#
#  Watches a folder that receives DAS files, classifies each new file,
#  keeps the ones with signals and decides what to do with the noise.
#
#  Usage:
#     ./run_watcher.sh                                  # watches ./DAS_RECORDING, keeps all noise
#     ./run_watcher.sh /path/to/DAS_RECORDING
#     ./run_watcher.sh DAS_RECORDING --keep-noise 10    # keep 1 of every 10 noise files
#     ./run_watcher.sh DAS_RECORDING --keep-noise 100   # keep 1 of every 100
#     ./run_watcher.sh DAS_RECORDING --keep-noise 0     # delete ALL noise files
#     ./run_watcher.sh DAS_RECORDING --keep-pics        # keep the pictures in DAS_RECORDING/PICS
#     ./run_watcher.sh DAS_RECORDING --models /path/to/MODELS
#     ./run_watcher.sh DAS_RECORDING --once             # process what is waiting, then exit
#
#  Result folders (inside the watched folder):
#     SIGNALS/   files with signals (always kept)
#     NOISE/     noise files kept by the --keep-noise policy
#     FAILED/    files that could not be read/processed
#     watcher.log   one line per file: time, file, decision, score, votes, action
#
#  To test without an instrument, in ANOTHER terminal run:  ./start_recording.sh
#  First time only:   chmod +x run_watcher.sh start_recording.sh
# ================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../DASight_env.sh"          # sets DASight_JULIA

WATCH_DIR="DAS_RECORDING"
KEEP_NOISE=1
MODEL_ARGS=()
ONCE=""
KEEP_PICS=""

# --- read arguments ---
while [ $# -gt 0 ]; do
    case "$1" in
        --keep-noise)
            [ $# -ge 2 ] || { echo "ERROR: --keep-noise needs a number (0, 1, 10, 100, ...)" >&2; exit 1; }
            KEEP_NOISE="$2"; shift 2 ;;
        --models)
            [ $# -ge 2 ] || { echo "ERROR: --models needs a folder" >&2; exit 1; }
            MODEL_ARGS=(--models "$2"); shift 2 ;;
        --once)
            ONCE="--once"; shift ;;
        --keep-pics)
            KEEP_PICS="--keep-pics"; shift ;;
        -*)
            echo "ERROR: unknown option '$1'" >&2; exit 1 ;;
        *)
            WATCH_DIR="$1"; shift ;;
    esac
done

# --- checks ---
if ! [[ "$KEEP_NOISE" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --keep-noise must be a whole number (0, 1, 10, 100, ...), got '$KEEP_NOISE'" >&2
    exit 1
fi
if [ "${#MODEL_ARGS[@]}" -gt 0 ] && [ ! -d "${MODEL_ARGS[1]}" ]; then
    echo "ERROR: models folder '${MODEL_ARGS[1]}' does not exist." >&2
    exit 1
fi
if [ "$KEEP_NOISE" -eq 0 ]; then
    echo "WARNING: --keep-noise 0 means ALL noise files will be DELETED."
fi
mkdir -p "$WATCH_DIR"

# --- run (exec: Ctrl+C goes straight to Julia) ---
# ($ONCE and $KEEP_PICS are intentionally unquoted: when empty they must disappear.)
if [ "${#MODEL_ARGS[@]}" -gt 0 ]; then
    exec "${DASight_JULIA[@]}" "$HERE/Watch_DAS.jl" "$WATCH_DIR" "${MODEL_ARGS[@]}" --keep-noise "$KEEP_NOISE" $ONCE $KEEP_PICS
else
    exec "${DASight_JULIA[@]}" "$HERE/Watch_DAS.jl" "$WATCH_DIR" --keep-noise "$KEEP_NOISE" $ONCE $KEEP_PICS
fi
