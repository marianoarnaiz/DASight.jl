using Test, Random, Dates
using DASight

# ---------------------------------------------------------------
#  Fast tests of the decision logic (no models, no data needed)
# ---------------------------------------------------------------
@testset "noise policy" begin
    @test all(n -> keep_noise_file(n, 1), 1:50)                  # keep all
    @test count(n -> keep_noise_file(n, 10), 1:100) == 10        # 1 of every 10
    @test [n for n in 1:25 if keep_noise_file(n, 10)] == [1, 11, 21]
    @test count(n -> keep_noise_file(n, 100), 1:100) == 1        # 1 of every 100
    @test !any(n -> keep_noise_file(n, 0), 1:100)                # keep none
end

@testset "command line parser" begin
    pos, opts = parse_args(["mydir", "--keep-noise", "10", "--once", "--models", "/m"])
    @test pos == ["mydir"]
    @test opts["--keep-noise"] == "10"
    @test opts["--models"] == "/m"
    @test haskey(opts, "--once")
    @test_throws ErrorException parse_args(["--keep-noise"])
end

# results matrix: filename, class, prob (×3 models: ZEUS, POSEIDON, HADES)
row(f, zc, zp, pc, pp, hc, hp) = Any[f, zc, zp, f, pc, pp, f, hc, hp]

@testset "3-stage pipeline" begin
    results = permutedims(hcat(
        row("A_all_signal.png",  "signals", 0.99, "signals", 0.99, "signals", 0.99),
        row("B_hades_noise.png", "signals", 0.99, "signals", 0.99, "noise",   0.99),
        row("C_mostly_noise.png","signals", 0.90, "noise",   0.90, "noise",   0.60),
        row("D_low_score.png",   "signals", 0.80, "signals", 0.70, "noise",   0.70),
        row("E_two_votes.png",   "signals", 0.90, "noise",   0.50, "signals", 0.80),
    ))
    out = run_pipeline(results; verbose=false)
    @test size(out) == (5, 6)
    @test string.(out[:, 5]) == ["SIGNAL", "NOISE", "NOISE", "NOISE", "SIGNAL"]
    @test out[1, 3] == 3 && out[1, 4] == 3                       # all agree, decided in stage 3
    @test out[2, 4] == 1 && isnan(out[2, 2])                     # HADES hard filter (stage 1)
    @test out[3, 4] == 2 && out[3, 3] == 1                       # stage 2, one vote
    @test out[4, 3] == 2 && out[4, 2] < 0.5                      # two votes but score too low
    @test out[5, 2] ≈ 1.99 atol=1e-6

    # stricter parameters change the decision
    strict = run_pipeline(results; params=PipelineParams(min_signal_votes=3), verbose=false)
    @test string.(strict[:, 5]) == ["SIGNAL", "NOISE", "NOISE", "NOISE", "NOISE"]

    # alternative scoring runs and agrees with obvious cases
    sc = combine_scores(results)
    @test sc[1, 4] == "signals" && sc[1, 3] > 0.99
    @test sc[3, 4] == "MIXED"
end

@testset "result files" begin
    results = permutedims(hcat(
        row("a.png", "signals", 0.99, "signals", 0.99, "signals", 0.99),
        row("b.png", "noise",   0.99, "noise",   0.99, "noise",   0.99),
    ))
    out = run_pipeline(results; verbose=false)
    mktempdir() do dir
        paths = write_results(results, out; outdir=dir, tag="T")
        @test length(paths) == 5 && all(isfile, paths)
        @test strip(read(joinpath(dir, "found_signals_T.txt"), String)) == "a.png"
        @test strip(read(joinpath(dir, "found_noise_T.txt"), String))   == "b.png"
    end
    @test dir_tag("/some/where/Long_Test/") == "Long_Test"
end

# ---------------------------------------------------------------
#  A synthetic DAS record through the whole picture pipeline
# ---------------------------------------------------------------
function synthetic_das(; nt=6000, nx=64, fs=200.0, dx=10.0, name="synthetic.h5")
    Random.seed!(1)
    t = range(0.0, step=1/fs, length=nt)
    x = range(0.0, step=dx, length=nx)
    data = 0.1f0 .* randn(Float32, nt, nx)
    for j in 1:nx                                    # a 5 Hz Ricker pulse, 2000 m/s apparent velocity
        τ = 10.0 + x[j] / 2000
        data[:, j] .+= Float32.((1 .- 2 .* (π * 5 .* (t .- τ)).^2) .* exp.(-(π * 5 .* (t .- τ)).^2))
    end
    htime = DateTime(2026, 1, 1) .+ Millisecond.(round.(Int, 1000 .* t))
    return iDAS(data, t, htime, x, empty_attb(), name)
end

@testset "check_das" begin
    @test check_das(synthetic_das(); verbose=false)
    # transposed data must be flagged
    d = synthetic_das()
    bad = iDAS(Matrix(permutedims(d.data)), d.time[1:64], d.htime[1:64], d.offset[1:6000], d.atrib, "bad")
    @test_logs (:warn,) match_mode=:any check_das(bad; verbose=false)
end

@testset "filter kernel caps" begin
    zs = randn(Float32, 1000, 200)
    @test size(fkgaussfilter(zs, 10.0, 0.005, 0.01, 1e-4)) == size(zs)   # huge σ: kernel capped
    @test size(fkgaussfilter(zs, 10.0, 0.005, 0.0, 0.0))   == size(zs)   # peak at 0: infinite wavelength
    @test size(fkgaussfilter(zs, 10.0, 0.005, 5.0, 0.05))  == size(zs)
end

@testset "data → picture" begin
    mktempdir() do dir
        dDAS = synthetic_das()
        png = das2pics(dDAS; label="synthetic.h5", outdir=dir, verbose=false)
        @test basename(png) == "synthetic_RdBu_0.png"
        @test isfile(png)
        img = DASight.load(png)
        @test size(img) == (224, 224)

        auto = auto_level_file(png)
        @test isfile(auto) && endswith(auto, "_AUTO.png")

        batch_auto_level_intensity(dir=dir, remove_original=true)
        @test sort(readdir(dir)) == ["synthetic_RdBu_0_AUTO.png"]
        batch_auto_level_intensity(dir=dir, remove_original=true)        # safe to repeat
        @test sort(readdir(dir)) == ["synthetic_RdBu_0_AUTO.png"]
    end
end

@testset "jld2 reader" begin
    mktempdir() do dir
        dDAS = synthetic_das(nt=500, nx=8)
        f = joinpath(dir, "x.jld2")
        DASight.JLD2.jldsave(f; dDAS)
        back = read_das_jld2(f)
        @test back.data == dDAS.data
        @test back.name == dDAS.name
    end
end

# ---------------------------------------------------------------
#  Models, data and examples (no download needed)
# ---------------------------------------------------------------
@testset "distribution" begin
    withenv("DASight_MODELS_DIR" => "/my/models", "DASight_DATA_DIR" => "/my/data") do
        @test models_dir() == "/my/models"
        @test example_data_dir() == "/my/data"
    end
    mktempdir() do tmp
        dest = install_examples(joinpath(tmp, "ex"); data=false)
        for f in ("1_PAINTER/DAS2Pics_nc.jl", "2_DETECTIVE/Pics2Events.jl", "3_WATCHER/Watch_DAS.jl",
                  "1_PAINTER/run_painter.sh", "DASight_env.sh")
            @test isfile(joinpath(dest, f))
        end
        @test iswritable(joinpath(dest, "1_PAINTER", "DAS2Pics_nc.jl"))
        @test_throws ErrorException install_examples(dest; data=false)   # never overwrite silently
    end
end
