# ================================================================
#  DASight :: Watcher.jl
#  Author: Mariano Arnaiz
#
#  Functions for the live watcher (3_WATCHER). It uses ImageProcessing.jl
#  (data → picture) and ML_Handling.jl (picture → decision).
#
#  How it works: the watch folder is a QUEUE. Every new data file is turned
#  into a picture, classified, and then MOVED out of the queue:
#       SIGNAL → <watch_dir>/SIGNALS/            (always kept)
#       NOISE  → <watch_dir>/NOISE/ or deleted   (see the noise policy)
#       error  → <watch_dir>/FAILED/             (so it is never retried forever)
#  Every decision is appended to <watch_dir>/watcher.log (tab-separated).
#
#  Noise policy (`keep_every`):
#       1   keep ALL noise files
#       10  keep 1 of every 10 noise files (the 1st, 11th, 21st, ...)
#       100 keep 1 of every 100 noise files
#       0   keep NO noise files (delete them all)
#
#  Sections
#    1. Command line   : parse_args
#    2. Queue          : pending_files
#    3. Noise policy   : keep_noise_file
#    4. Log            : log_decision, count_logged
#    5. One file       : classify_das_file, handle_file!
#    6. Main loop      : watch
# ================================================================

using Dates, Printf


# ---- 1. Command line -------------------------------------------------

"""
    parse_args(args; valueflags=("--keep-noise", "--models")) -> (positional, options)

Minimal command-line parser. `--flag value` pairs for the names in
`valueflags`, bare `--flag` for anything else starting with `--`; the rest
are positional arguments. `options` is a `Dict{String,String}`.
"""
function parse_args(args; valueflags=("--keep-noise", "--models"))
    pos  = String[]
    opts = Dict{String,String}()
    i = 1
    while i <= length(args)
        a = args[i]
        if a in valueflags
            i == length(args) && error("$a needs a value")
            opts[a] = args[i+1]
            i += 2
        elseif startswith(a, "--")
            opts[a] = "true"
            i += 1
        else
            push!(pos, a)
            i += 1
        end
    end
    return pos, opts
end


# ---- 2. Queue --------------------------------------------------------

"""
    pending_files(dir; ext=".jld2", min_age=2.0) -> Vector{String}

Data files waiting in `dir`, oldest first. Hidden files are ignored, and so
are files modified less than `min_age` seconds ago (they may still be
being written by the recorder).
"""
function pending_files(dir::AbstractString; ext::AbstractString=".jld2", min_age::Real=2.0)
    files = String[]
    for f in readdir(dir)
        startswith(f, ".") && continue
        endswith(lowercase(f), lowercase(ext)) || continue
        p = joinpath(dir, f)
        isfile(p) || continue
        time() - mtime(p) >= min_age || continue
        push!(files, p)
    end
    sort!(files; by = p -> (mtime(p), p))
    return files
end


# ---- 3. Noise policy -------------------------------------------------

"""
    keep_noise_file(n_noise, keep_every) -> Bool

Should the `n_noise`-th noise file (counting from 1) be kept?
`keep_every = 1` keeps all, `N` keeps the 1st, (N+1)th, (2N+1)th, ...
and `0` keeps none.
"""
keep_noise_file(n_noise::Integer, keep_every::Integer) =
    keep_every > 0 && (n_noise - 1) % keep_every == 0


# ---- 4. Log ----------------------------------------------------------

const LOG_HEADER = "time\tfile\tdecision\tscore\tvotes\taction"

"Append one line to the log file (the header is written the first time)."
function log_decision(logfile, fname, decision, score, votes, action)
    is_new = !isfile(logfile)
    open(logfile, "a") do io
        is_new && println(io, LOG_HEADER)
        println(io, join((Dates.format(now(), "yyyy-mm-dd HH:MM:SS"),
                          fname, decision, score, votes, action), '\t'))
    end
end

"How many lines of the log have this decision (\"SIGNAL\", \"NOISE\" or \"FAILED\")."
function count_logged(logfile, decision)
    isfile(logfile) || return 0
    return count(eachline(logfile)) do line
        p = split(line, '\t')
        length(p) >= 3 && p[3] == decision
    end
end


# ---- 5. One file -----------------------------------------------------

"""
    classify_das_file(path, models; params, picdir, keep_pics=false,
                      batchsize=16, varname="dDAS") -> (decision, score, votes)

The full chain for ONE data file:
read → process → picture (`_RdBu_0.png`) → contrast-stretched picture
(`_AUTO.png`) → ZEUS + POSEIDON + HADES → 3-stage decision.
The AUTO picture is the one classified (same as the PAINTER default).
The plain picture is deleted at once; the `_AUTO` picture is deleted after
classification unless `keep_pics=true`.
"""
function classify_das_file(path, models; params::PipelineParams, picdir,
                           keep_pics::Bool=false, batchsize::Int=16, varname="dDAS")
    dDAS = read_das_jld2(path; varname=varname)
    check_das(dDAS; verbose=false)

    png  = das2pics(dDAS; label=path, outdir=picdir, verbose=false)
    auto = auto_level_file(png)
    rm(png; force=true)                       # the plain picture is never needed again
    try
        _, out = detect_files([auto], models; params=params, batchsize=batchsize)
        return string(out[1, 5]), out[1, 2], out[1, 3]
    finally
        keep_pics || rm(auto; force=true)     # only the _AUTO picture can be kept
    end
end


"""
    handle_file!(path, models; params, dirs, keep_every, noise_count, logfile,
                 picdir, keep_pics, batchsize, varname) -> String

Classify one file and act on the result (move / delete, log, print one line).
`noise_count` is a `Ref{Int}` with the number of noise files seen so far;
it is increased here. Returns "SIGNAL", "NOISE" or "FAILED".
"""
function handle_file!(path, models; params, dirs, keep_every, noise_count::Ref{Int}, logfile,
                      picdir, keep_pics, batchsize, varname)
    fname = basename(path)
    clock = Dates.format(now(), "HH:MM:SS")
    try
        decision, score, votes = classify_das_file(path, models; params=params, picdir=picdir,
                                                   keep_pics=keep_pics, batchsize=batchsize,
                                                   varname=varname)
        if decision == "SIGNAL"
            mv(path, joinpath(dirs.signals, fname); force=true)
            action = "→ SIGNALS/"
        else
            noise_count[] += 1
            if keep_noise_file(noise_count[], keep_every)
                mv(path, joinpath(dirs.noise, fname); force=true)
                action = "→ NOISE/ (kept)"
            else
                rm(path)
                action = "deleted"
            end
        end

        score_str = (score isa Real && isfinite(score)) ? @sprintf("%+.2f", score) : "—"
        votes_str = (votes isa Real && isfinite(votes)) ? string(votes) : "—"
        icon = decision == "SIGNAL" ? "✅" : "❌"
        println("[$clock] $icon $(rpad(decision, 6)) $fname  score=$score_str votes=$votes_str  $action")
        log_decision(logfile, fname, decision, score_str, votes_str, action)
        return decision

    catch err
        err isa InterruptException && rethrow()
        @error "Could not process $fname" exception=(err, catch_backtrace())
        try
            mv(path, joinpath(dirs.failed, fname); force=true)
        catch
        end
        log_decision(logfile, fname, "FAILED", "—", "—", "→ FAILED/")
        return "FAILED"
    end
end


# ---- 6. Main loop ----------------------------------------------------

"""
    watch(; watch_dir, models, params, keep_every=1, ext=".jld2", poll=5.0,
            min_age=2.0, picdir=joinpath(watch_dir, "PICS"), keep_pics=false,
            batchsize=16, varname="dDAS", once=false)

Watch `watch_dir` and process every new file (see the top of this file).
Stops with Ctrl+C. With `once=true` it processes what is waiting and returns.
"""
function watch(; watch_dir::AbstractString, models, params::PipelineParams,
                 keep_every::Integer=1, ext::AbstractString=".jld2", poll::Real=5.0,
                 min_age::Real=2.0, picdir::AbstractString=joinpath(watch_dir, "PICS"),
                 keep_pics::Bool=false, batchsize::Int=16, varname::AbstractString="dDAS",
                 once::Bool=false)

    dirs = (signals = joinpath(watch_dir, "SIGNALS"),
            noise   = joinpath(watch_dir, "NOISE"),
            failed  = joinpath(watch_dir, "FAILED"))
    foreach(mkpath, values(dirs))
    mkpath(picdir)
    logfile = joinpath(watch_dir, "watcher.log")

    # continue the noise count of earlier sessions so the 1-in-N rhythm survives restarts
    noise_count = Ref(count_logged(logfile, "NOISE"))
    session = Dict("SIGNAL" => 0, "NOISE" => 0, "FAILED" => 0)

    policy = keep_every == 1 ? "keep ALL noise files" :
             keep_every == 0 ? "DELETE all noise files" :
                               "keep 1 of every $keep_every noise files"
    println("="^60)
    println("  DASight WATCHER")
    println("  watching : $(abspath(watch_dir))   (*$ext)")
    println("  noise    : $policy")
    println("  log      : $logfile")
    println("  Ctrl+C to stop")
    println("="^60)

    idle_announced = false
    try
        while true
            pending = pending_files(watch_dir; ext=ext, min_age=min_age)
            if isempty(pending)
                once && break
                if !idle_announced
                    println("[$(Dates.format(now(), "HH:MM:SS"))] waiting for new files...")
                    idle_announced = true
                end
                sleep(poll)
            else
                idle_announced = false
                for p in pending
                    decision = handle_file!(p, models; params=params, dirs=dirs,
                                            keep_every=keep_every, noise_count=noise_count,
                                            logfile=logfile, picdir=picdir, keep_pics=keep_pics,
                                            batchsize=batchsize, varname=varname)
                    session[decision] += 1
                    GC.gc()
                end
            end
        end
    catch err
        err isa InterruptException || rethrow()
        println()
    end

    println("Watcher stopped. This session: $(session["SIGNAL"]) signals, " *
            "$(session["NOISE"]) noise, $(session["FAILED"]) failed.")
    return session
end
