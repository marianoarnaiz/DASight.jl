#!/usr/bin/env julia
# ================================================================
#  DASight :: 3_WATCHER :: Watch_DAS.jl
#
#  Watches a folder that receives DAS files from a (live or fake) recorder.
#  Every new file is turned into a picture (like 1_PAINTER), classified by
#  ZEUS + POSEIDON + HADES (like 2_DETECTIVE), and then:
#       SIGNAL → moved to  <watch_dir>/SIGNALS/
#       NOISE  → kept in   <watch_dir>/NOISE/   or deleted, as you choose
#
#  HOW TO USE
#    1. Edit the SETTINGS block below if needed.
#    2. Run (normally through the launcher):
#         ./run_watcher.sh DAS_RECORDING --keep-noise 10
#       or directly:
#         julia Watch_DAS.jl DAS_RECORDING --keep-noise 10
#
#  Options
#    --keep-noise N   1 = keep all noise files (default)
#                     10 = keep 1 of every 10      100 = keep 1 of every 100
#                     0 = keep none (noise files are deleted!)
#    --models DIR     folder with the .bson models (default: the ones DASight downloads)
#    --keep-pics      keep the pictures in <watch_dir>/PICS (default: deleted after use)
#    --once           process what is waiting and exit (useful for testing)
#
#  Reading a different data format: only `read_das_jld2` has to be replaced
#  by a function that returns an `iDAS` (see 1_PAINTER/DAS2Pics_nc.jl for
#  how to build one).
# ================================================================

using DASight


# ================================================================
#  SETTINGS  ← edit here
# ================================================================

# Values from the command line (the launcher passes them through)
const _CLI = parse_args(ARGS)

const WATCH_DIR  = length(_CLI[1]) >= 1 ? _CLI[1][1] : "DAS_RECORDING"
# MODEL_DIR = "" means: use the models that DASight downloads for you (see ?models_dir)
const MODEL_DIR  = get(_CLI[2], "--models", "")
const KEEP_NOISE_EVERY = parse(Int, get(_CLI[2], "--keep-noise", "1"))
const ONCE       = haskey(_CLI[2], "--once")

# Incoming data files
const FILE_EXT      = ".jld2"
const DAS_VARNAME   = "dDAS"     # name of the variable inside the .jld2 file
const POLL_SECONDS  = 5          # how often to look for new files
const MIN_FILE_AGE  = 2          # ignore files modified in the last N seconds (still being written)

# Pictures made on the way (deleted after classification unless KEEP_PICS)
const PICS_DIR   = joinpath(WATCH_DIR, "PICS")
const KEEP_PICS  = haskey(_CLI[2], "--keep-pics")   # or set to true here

# The three trained models (BSON files inside MODEL_DIR)
const MODEL_FILES = (zeus     = "ZEUS.bson",
                     poseidon = "POSEIDON.bson",
                     hades    = "HADES.bson")

# Decision scheme: keep identical to 2_DETECTIVE so both give the same answers
const PARAMS = PipelineParams(
    hades_noise_threshold = 0.95,
    score_threshold       = 0.5,
    min_signal_votes      = 2,
    w_zeus                = 1.1,
    w_poseidon            = 0.4,
    w_hades               = 1.5,
)

const BATCHSIZE = 16


# ================================================================
#  RUN
# ================================================================
function main()
    KEEP_NOISE_EVERY >= 0 || error("--keep-noise must be 0 or a positive number")

    model_dir = isempty(MODEL_DIR) ? models_dir() : MODEL_DIR
    println("Loading models (once) from $(abspath(model_dir)) ...")
    models = load_detective_models(model_dir, MODEL_FILES)

    watch(; watch_dir=WATCH_DIR, models=models, params=PARAMS,
            keep_every=KEEP_NOISE_EVERY, ext=FILE_EXT, poll=POLL_SECONDS,
            min_age=MIN_FILE_AGE, picdir=PICS_DIR, keep_pics=KEEP_PICS,
            batchsize=BATCHSIZE, varname=DAS_VARNAME, once=ONCE)
end

main()
