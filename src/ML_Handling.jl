# ================================================================
#  DASight :: ML_Handling.jl   (consolidated from Script2_2.jl)
#  Author: Mariano Arnaiz
#
#  Runs the trained ResNet classifiers (ZEUS, POSEIDON, HADES) on PNG
#  images made by 1_PAINTER and decides which ones contain events.
#
#  Sections
#    0. Modules & constants
#    1. Models        : load_model
#    2. Images        : preprocess_image, list_images
#    3. Inference     : classify_files, classify_dir, combine_predictions,
#                       load_detective_models, detect_files
#    4. Decision      : PipelineParams, run_pipeline   (3-stage voting)
#    5. Alt. scoring  : combine_scores, print_scores   (older, optional)
#    6. Output        : dir_tag, write_results
#
#  The "results" matrix used throughout has 9 columns (N rows = N images):
#     1: filename   2: ZEUS class     3: ZEUS prob
#     4: filename   5: POSEIDON class 6: POSEIDON prob
#     7: filename   8: HADES class    9: HADES prob
# ================================================================


# ---- 0. Modules & constants ------------------------------------------
using Flux, Metalhead
using Images, ImageIO, FileIO
using MLUtils            # needed so BSON can rebuild `flatten` layers of saved models
using BSON: @load
using DelimitedFiles
using Printf

# Constants used during training (ImageNet statistics). DO NOT change
# unless the models were retrained with different values.
const μ_IMAGENET = Float32[0.485, 0.456, 0.406]
const σ_IMAGENET = Float32[0.229, 0.224, 0.225]
const IMG_SIZE   = (224, 224)

# Class names stored inside the .bson files
const SIGNAL_CLASS = "signals"
const NOISE_CLASS  = "noise"

const IMAGE_EXTENSIONS = (".png", ".jpg", ".jpeg")


# ---- 1. Models -------------------------------------------------------

"""
    load_model(path) -> (model, classes)

Load a trained classifier saved with BSON (it must contain the variables
`model` and `classes`). The model is put in test mode (BatchNorm uses its
learned statistics, Dropout is off). The model is expected to output raw
scores (logits), not probabilities: softmax is applied during inference.
"""
function load_model(path::AbstractString)
    isfile(path) || error("Model file not found: $path")
    local model, classes
    @load path model classes
    Flux.testmode!(model)
    for c in (SIGNAL_CLASS, NOISE_CLASS)
        c in classes || error("$path: class \"$c\" not found in classes = $classes")
    end
    return model, classes
end


# ---- 2. Images -------------------------------------------------------

"""
    preprocess_image(path) -> Array{Float32,3}

Load one image and prepare it for the ResNet, exactly as in training:

1. load and resize to `IMG_SIZE` (224×224)
2. Float32, channel-first
3. make sure there are 3 channels (grayscale is repeated, alpha is dropped)
4. normalise with the ImageNet mean and std
5. reorder to Flux layout (height, width, channels)

Returns an array of size `(224, 224, 3)`.
"""
function preprocess_image(path::AbstractString)
    img = load(path)
    img = imresize(img, IMG_SIZE)
    x   = Float32.(channelview(img))

    ndims(x) == 2 && (x = reshape(x, 1, size(x)...))      # plain grayscale: no channel axis
    size(x, 1) == 1 && (x = repeat(x, 3, 1, 1))           # 1 channel  → 3
    size(x, 1) == 4 && (x = x[1:3, :, :])                 # RGBA       → RGB

    x = (x .- μ_IMAGENET) ./ σ_IMAGENET
    return permutedims(x, (2, 3, 1))
end


"""
    list_images(dir; contains="") -> Vector{String}

Sorted full paths of the images (`.png`, `.jpg`, `.jpeg`) in `dir`.
Hidden files (`.DS_Store`, `._xxx.png`) are ignored. If `contains` is not
empty, only filenames containing that text are used (e.g. `"_AUTO"`).
"""
function list_images(dir::AbstractString; contains::AbstractString="")
    isdir(dir) || error("Image folder not found: $(abspath(dir))")
    files = filter(readdir(dir)) do f
        !startswith(f, ".") &&
        lowercase(splitext(f)[2]) in IMAGE_EXTENSIONS &&
        occursin(contains, f)
    end
    isempty(files) && error("No images (png/jpg) found in $(abspath(dir))" *
                            (isempty(contains) ? "" : " with \"$contains\" in the name"))
    return joinpath.(dir, files)
end


# ---- 3. Inference ----------------------------------------------------

"""
    classify_files(paths, model, classes; batchsize=16, label="") -> Matrix{Any}

Classify the images in `paths`. Returns an `N × 3` matrix:
filename (no folder), predicted class, probability (softmax of the winner).
Images are processed in batches of `batchsize`.
"""
function classify_files(paths::AbstractVector, model, classes; batchsize::Int=16, label::AbstractString="")
    n     = length(paths)
    preds = Array{Any}(undef, n, 3)

    for batch in Iterators.partition(1:n, batchsize)
        x = cat((preprocess_image(paths[i]) for i in batch)...; dims=4)   # (224,224,3,B)

        y = model(x)                    # (nclasses, B) raw scores
        p = softmax(y; dims=1)
        for (j, i) in enumerate(batch)
            idx = argmax(view(y, :, j))
            preds[i, 1] = basename(paths[i])
            preds[i, 2] = classes[idx]
            preds[i, 3] = p[idx, j]
        end
        isempty(label) || @printf("\r  %-10s %d / %d images", label, last(batch), n)
    end
    isempty(label) || println()
    return preds
end

"""
    classify_dir(dir, model, classes; contains="", kwargs...) -> Matrix{Any}

`classify_files` on every image of a folder (see `list_images`).
"""
classify_dir(dir, model, classes; contains="", kwargs...) =
    classify_files(list_images(dir; contains=contains), model, classes; kwargs...)


"""
    combine_predictions(preds_zeus, preds_poseidon, preds_hades) -> Matrix{Any}

Join the three `N × 3` prediction matrices into the `N × 9` results matrix.
Checks that the three refer to the same images in the same order.
"""
function combine_predictions(preds_zeus, preds_poseidon, preds_hades)
    preds_zeus[:, 1] == preds_poseidon[:, 1] == preds_hades[:, 1] ||
        error("The three models did not classify the same files in the same order")
    return [preds_zeus preds_poseidon preds_hades]
end


"""
    load_detective_models(model_dir, files) -> NamedTuple

Load the three classifiers. `files` is a NamedTuple with the `.bson` filename
of each one, e.g. `(zeus="ZEUS.bson", poseidon="POSEIDON.bson", hades="HADES.bson")`.
Returns a NamedTuple of `(model, classes)` with the same keys.
"""
load_detective_models(model_dir::AbstractString, files::NamedTuple) =
    map(f -> load_model(joinpath(model_dir, f)), files)


"""
    detect_files(paths, models; params=PipelineParams(), batchsize=16,
                 show_progress=false, verbose=false, show_table=false)
        -> (results, pipeline_output)

The whole detection in one call: run ZEUS, POSEIDON and HADES (from
`load_detective_models`) on the images in `paths`, then the 3-stage decision.
Used by both 2_DETECTIVE (many images) and 3_WATCHER (one image at a time).
"""
function detect_files(paths, models; params=PipelineParams(), batchsize::Int=16,
                      show_progress::Bool=false, verbose::Bool=false, show_table::Bool=false)
    classify(name) = classify_files(paths, models[name][1], models[name][2];
                                    batchsize=batchsize,
                                    label=show_progress ? uppercase(string(name)) : "")
    results = combine_predictions(classify(:zeus), classify(:poseidon), classify(:hades))
    output  = run_pipeline(results; params=params, show_table=show_table, verbose=verbose)
    return results, output
end


# ---- 4. Decision: 3-stage voting pipeline ----------------------------

"""
    PipelineParams(; kwargs...)

Parameters of the 3-stage decision (`run_pipeline`):

| field                  | default | meaning                                             |
|:-----------------------|:--------|:----------------------------------------------------|
| `hades_noise_threshold`| 0.95    | Stage 1: discard if HADES says noise with p > this  |
| `score_threshold`      | 0.5     | Stage 2/3: weighted score must exceed this          |
| `min_signal_votes`     | 2       | Stage 3: at least this many models must say signal  |
| `w_zeus`               | 1.1     | weight of ZEUS in the score                         |
| `w_poseidon`           | 0.4     | weight of POSEIDON                                  |
| `w_hades`              | 1.5     | weight of HADES                                     |
"""
Base.@kwdef struct PipelineParams
    hades_noise_threshold::Float64 = 0.95
    score_threshold::Float64       = 0.5
    min_signal_votes::Int          = 2
    w_zeus::Float64                = 1.1
    w_poseidon::Float64            = 0.4
    w_hades::Float64               = 1.5
end


# +p if the model says "signals", -p if it says "noise"
signed_prob(class::AbstractString, prob::Real) = class == SIGNAL_CLASS ? Float64(prob) : -Float64(prob)

count_signal_votes(classes...) = count(==(SIGNAL_CLASS), classes)


"""
    run_pipeline(results; params=PipelineParams(), show_table=false, verbose=true) -> Matrix{Any}

3-stage decision on the `N × 9` results matrix:

- **Stage 1** HADES hard filter: HADES noise probability > `hades_noise_threshold` → NOISE.
- **Stage 2** weighted score = Σ weight × signed probability (signal +, noise −).
- **Stage 3** voting: SIGNAL only if score > `score_threshold` AND at least
  `min_signal_votes` models say signal; otherwise NOISE.

Returns an `N × 6` matrix:
`filename, score, signal votes (0-3), stage that decided (1 or 3 for SIGNAL, 1 or 2 for NOISE),
decision ("SIGNAL"/"NOISE"), reason`.
(Files rejected in stage 1 have `NaN` as score and votes.)
"""
function run_pipeline(results::Matrix{Any}; params::PipelineParams=PipelineParams(),
                      show_table::Bool=false, verbose::Bool=true)
    n      = size(results, 1)
    output = Array{Any}(undef, n, 6)

    events   = String[]
    noise_s1 = String[]
    noise_s2 = String[]

    for i in 1:n
        fname = string(results[i, 1])
        zeus_class  = string(results[i, 2]);  zeus_p  = Float64(results[i, 3])
        posi_class  = string(results[i, 5]);  posi_p  = Float64(results[i, 6])
        hades_class = string(results[i, 8]);  hades_p = Float64(results[i, 9])

        # ---- Stage 1: HADES hard filter ----
        hades_noise_p = hades_class == NOISE_CLASS ? hades_p : 1.0 - hades_p
        if hades_noise_p > params.hades_noise_threshold
            output[i, :] = [fname, NaN, NaN, 1, "NOISE", "HADES hard filter"]
            push!(noise_s1, fname)
            continue
        end

        # ---- Stage 2: weighted score ----
        score = params.w_zeus     * signed_prob(zeus_class,  zeus_p)  +
                params.w_poseidon * signed_prob(posi_class,  posi_p)  +
                params.w_hades    * signed_prob(hades_class, hades_p)
        votes = count_signal_votes(zeus_class, posi_class, hades_class)

        # ---- Stage 3: combined decision ----
        reason = "score=$(round(score, digits=3)) votes=$votes"
        if score > params.score_threshold && votes >= params.min_signal_votes
            output[i, :] = [fname, round(score, digits=3), votes, 3, "SIGNAL", reason]
            push!(events, fname)
        else
            output[i, :] = [fname, round(score, digits=3), votes, 2, "NOISE", reason]
            push!(noise_s2, fname)
        end
    end

    if verbose
        println("\n" * "="^70)
        println("  DASight 3-STAGE PIPELINE")
        println("  HADES threshold: $(params.hades_noise_threshold)  |  Score threshold: $(params.score_threshold)  |  Min votes: $(params.min_signal_votes)")
        println("="^70)

        if show_table
            println("  $(lpad("FILE", 45))  SCORE   VOTES  DECISION")
            println("-"^70)
            for i in 1:n
                fname    = string(output[i, 1])
                fname_sh = length(fname) > 45 ? "..." * fname[end-41:end] : fname
                score    = output[i, 2]
                votes    = output[i, 3]
                stage    = output[i, 4]
                score_str = isnan(score) ? "  —   " : @sprintf("%+6.3f", score)
                votes_str = (votes isa Real && isnan(votes)) ? " — " : "  $votes  "
                marker    = output[i, 5] == "SIGNAL" ? "✅" : stage == 1 ? "❌ S1" : "❌ S2"
                println("  $(lpad(fname_sh, 45))  $score_str  $votes_str  $marker $(output[i, 5])")
            end
            println("="^70)
        end

        println("  ✅ Events   : $(length(events))")
        println("  ❌ Noise S1 : $(length(noise_s1))  (HADES hard filter)")
        println("  ❌ Noise S2 : $(length(noise_s2))  (score/votes)")
        println("  Total       : $n")

        if !isempty(events)
            println("\n  EVENTS FOUND:")
            for f in first(events, 50)
                println("    → $f")
            end
            length(events) > 50 && println("    ... and $(length(events) - 50) more (see found_signals_*.txt)")
        end
    end
    return output
end


# ---- 5. Alternative scoring (older method, optional) -----------------
#   Not used by the pipeline above; kept for comparison.

"""
    combine_scores(results) -> Matrix{Any}

Two older scores per image:
- `sum_zh`: signed sum of ZEUS + HADES probabilities (range −2 … +2)
- `bayes` : naive-Bayes combination of all three models (range −1 … +1)

Returns `N × 4`: filename, sum_zh, bayes, agreement (the common class, or "MIXED").
"""
function combine_scores(results::Matrix{Any})
    n      = size(results, 1)
    output = Array{Any}(undef, n, 4)

    for i in 1:n
        zeus_class  = string(results[i, 2]);  zeus_p  = Float64(results[i, 3])
        posi_class  = string(results[i, 5]);  posi_p  = Float64(results[i, 6])
        hades_class = string(results[i, 8]);  hades_p = Float64(results[i, 9])

        sum_zh = signed_prob(zeus_class, zeus_p) + signed_prob(hades_class, hades_p)

        # probability of "signal" according to each model
        p_zeus  = zeus_class  == SIGNAL_CLASS ? zeus_p  : 1.0 - zeus_p
        p_posi  = posi_class  == SIGNAL_CLASS ? posi_p  : 1.0 - posi_p
        p_hades = hades_class == SIGNAL_CLASS ? hades_p : 1.0 - hades_p

        p_signal = p_zeus * p_posi * p_hades
        p_noise  = (1.0 - p_zeus) * (1.0 - p_posi) * (1.0 - p_hades)
        total    = p_signal + p_noise
        bayes    = total > 0 ? (p_signal - p_noise) / total : 0.0

        output[i, 1] = results[i, 1]
        output[i, 2] = round(sum_zh, digits=4)
        output[i, 3] = round(bayes,  digits=4)
        output[i, 4] = zeus_class == posi_class == hades_class ? zeus_class : "MIXED"
    end
    return output
end

"""
    print_scores(output; x_sum=0.75, x_bayes=0.25)

Print the table from `combine_scores` with a SIGNAL / NOISE / REVIEW decision
for each score, and a summary. Try different thresholds without recomputing.
"""
function print_scores(output::Matrix{Any}; x_sum=0.75, x_bayes=0.25)
    decide(v, x) = v > x ? "SIGNAL" : v < -x ? "NOISE" : "REVIEW"

    println("\n" * "="^75)
    println("  FILE                          | SUM(Z+H) | BAYES  | AGREEMENT")
    println("="^75)
    for i in 1:size(output, 1)
        fname = first(string(output[i, 1]), 30)
        s, b  = output[i, 2], output[i, 3]
        @printf("  %-30s | %+6.3f %-6s | %+5.3f %-6s | %s\n",
                fname, s, decide(s, x_sum), b, decide(b, x_bayes), output[i, 4])
    end
    println("="^75)

    ds = [decide(output[i, 2], x_sum)   for i in 1:size(output, 1)]
    db = [decide(output[i, 3], x_bayes) for i in 1:size(output, 1)]
    println("\nSUM   (X=$x_sum):   Events=$(count(==("SIGNAL"), ds))  Noise=$(count(==("NOISE"), ds))  Review=$(count(==("REVIEW"), ds))")
    println("BAYES (X=$x_bayes): Events=$(count(==("SIGNAL"), db))  Noise=$(count(==("NOISE"), db))  Review=$(count(==("REVIEW"), db))")
end


# ---- 6. Output -------------------------------------------------------

"Last folder name of a path, e.g. \"/data/Long_Test/\" → \"Long_Test\"."
dir_tag(dir::AbstractString) = basename(rstrip(abspath(dir), ['/', '\\']))


"""
    write_results(results, pipeline_output; outdir=".", tag="") -> Vector{String}

Write the result files in `outdir` (created if needed). `tag` is added to
every filename (normally the name of the image folder, see `dir_tag`).

| file                    | content                                                  |
|:------------------------|:---------------------------------------------------------|
| `Results_<tag>.txt`     | the full N×9 matrix: class and probability of each model |
| `pipeline_output_<tag>.txt` | the N×6 matrix of `run_pipeline`                     |
| `found_signals_<tag>.txt`   | filenames decided SIGNAL by the pipeline             |
| `found_noise_<tag>.txt`     | filenames decided NOISE by the pipeline              |
| `others_<tag>.txt`          | filenames where the three models did NOT agree (may also be in the two lists above; useful for manual review) |

Returns the list of written paths.
"""
function write_results(results::Matrix{Any}, pipeline_output::Matrix{Any}; outdir=".", tag="")
    mkpath(outdir)
    fnames   = string.(results[:, 1])
    decision = string.(pipeline_output[:, 5])

    found_signals = fnames[decision .== "SIGNAL"]
    found_noise   = fnames[decision .== "NOISE"]
    disagree      = [length(unique(string.(results[i, [2, 5, 8]]))) > 1 for i in eachindex(fnames)]
    others        = fnames[disagree]

    suffix = isempty(tag) ? ".txt" : "_$(tag).txt"
    files = [
        "Results"         => results,
        "pipeline_output" => pipeline_output,
        "found_signals"   => found_signals,
        "found_noise"     => found_noise,
        "others"          => others,
    ]
    paths = String[]
    for (name, data) in files
        p = joinpath(outdir, name * suffix)
        writedlm(p, data)
        push!(paths, p)
    end
    return paths
end
