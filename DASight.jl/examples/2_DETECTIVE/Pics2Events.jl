#!/usr/bin/env julia
# ================================================================
#  DASight :: 2_DETECTIVE :: Pics2Events.jl
#
#  Classifies every image of a folder with the three trained ResNets
#  (ZEUS, POSEIDON, HADES), combines their answers with a 3-stage
#  voting scheme, and writes text files listing signals and noise.
#
#  Typical chain:   DAS data → 1_PAINTER → images → 2_DETECTIVE → events
#
#  HOW TO USE
#    1. Edit the SETTINGS block below if you want other thresholds/weights.
#    2. Run:  julia Pics2Events.jl [image_dir] [output_dir] [models_dir]
#       or use the launcher:  ./run_detective.sh data_test_pics
#
#  Output files (in output_dir), where <tag> is the image folder's name:
#       Results_<tag>.txt          class + probability of each model
#       pipeline_output_<tag>.txt  score, votes, decision per image
#       found_signals_<tag>.txt    images decided SIGNAL
#       found_noise_<tag>.txt      images decided NOISE
#       others_<tag>.txt           images where the models disagreed
# ================================================================

using DASight


# ================================================================
#  SETTINGS  ← edit here
# ================================================================

# Folders can be given on the command line (1st, 2nd and 3rd argument);
# the values here are the defaults.
const _ARGS      = filter(a -> !startswith(a, "--"), ARGS)
const IMAGE_DIR  = length(_ARGS) >= 1 ? _ARGS[1] : "DASight_pics"        # output of 1_PAINTER
const OUTPUT_DIR = length(_ARGS) >= 2 ? _ARGS[2] : "DASight_results"
# MODEL_DIR = "" means: use the models that DASight downloads for you (see ?models_dir)
const MODEL_DIR  = length(_ARGS) >= 3 ? _ARGS[3] : ""

# Only classify images whose filename contains this text ("" = all images).
# Use "_AUTO" if the folder holds both plain and contrast-stretched PNGs.
const NAME_CONTAINS = ""

# The three trained models (BSON files inside MODEL_DIR)
const MODEL_FILES = (zeus     = "ZEUS.bson",
                     poseidon = "POSEIDON.bson",
                     hades    = "HADES.bson")

# Decision scheme (see ?PipelineParams in Julia for details)
const PARAMS = PipelineParams(
    hades_noise_threshold = 0.95,   # Stage 1: discard if HADES says noise with p > this
    score_threshold       = 0.5,    # Stage 2: weighted score must exceed this
    min_signal_votes      = 2,      # Stage 3: at least this many models must say signal
    w_zeus                = 1.1,    # model weights in the score (signal +, noise −)
    w_poseidon            = 0.4,
    w_hades               = 1.5,
)

const BATCHSIZE   = 16      # images per batch (lower it if you run out of memory)
const SHOW_TABLE  = false   # print one line per image in the terminal
const ALT_SCORES  = false   # also print the older sum/Bayes table (combine_scores)


# ================================================================
#  RUN
# ================================================================
function main()
    println("DASight DETECTIVE")
    println("  images : $(abspath(IMAGE_DIR))")
    model_dir = isempty(MODEL_DIR) ? models_dir() : MODEL_DIR
    println("  models : $(abspath(model_dir))")
    println("  output : $(abspath(OUTPUT_DIR))")

    # --- images ---
    paths = list_images(IMAGE_DIR; contains=NAME_CONTAINS)
    println("\nFound $(length(paths)) images")

    # --- models + inference + decision ---
    models = load_detective_models(model_dir, MODEL_FILES)
    results, pipeline_output = detect_files(paths, models; params=PARAMS,
                                            batchsize=BATCHSIZE, show_progress=true,
                                            verbose=true, show_table=SHOW_TABLE)
    ALT_SCORES && print_scores(combine_scores(results))

    # --- save ---
    written = write_results(results, pipeline_output;
                            outdir=OUTPUT_DIR, tag=dir_tag(IMAGE_DIR))
    println("\nWrote:")
    foreach(p -> println("  $p"), written)
end

main()
