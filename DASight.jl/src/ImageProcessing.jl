# ================================================================
#  DASight :: ImageProcessing.jl
#  Author: Mariano Arnaiz
#
#  Turns a DAS record (an `iDAS` object from DASVader) into a small
#  224x224 PNG that a ResNet can classify (signal vs. noise).
#
#  CONVENTION used everywhere in this file:
#      dDAS.data   is a matrix  (time samples) x (channels)
#      dDAS.time   has length = size(data, 1)   [seconds]
#      dDAS.offset has length = size(data, 2)   [metres]
#
#  Sections
#    0. Modules
#    1. Getting data in : empty_attb, check_das
#    2. Band selection  : welch_psd_trace ... get_dp
#    3. FK analysis     : fkpeak, fkgaussfilter
#    4. Pipeline        : process_das!, das2pics
#    5. Augmentation    : das_image_data_augmentation   (training only)
#    6. Figure making   : save_fig
#    7. Level intensity : auto_level_intensity ... batch_auto_level_intensity
#    8. File handling   : figs2dirs, noise2dirs
# ================================================================


# ---- 0. Modules ------------------------------------------------------
using FFTW, DSP, Statistics
using ImageFiltering: Kernel, imfilter
using FileIO, Images, Colors, ColorVectorSpace
using DASVader, CairoMakie, Dates, StatsBase


# ---- 1. Getting data in ----------------------------------------------
#   Everything below only needs a valid `iDAS`. Building it is the job of
#   the call script (DAS2Pics_*.jl); these two helpers make that easier.

"""
    empty_attb()

Return an empty DASVader `attb` (metadata) object. DASight does not use
the metadata, but `iDAS` requires one, so this hides the 18 empty fields.
"""
empty_attb() = attb(Int8[], Int32[], Int32[], Int32[], Float64[], Int32[], Int32[],
                    Float64[], "", Float64[], Int8[], "", 0.0, Int8[],
                    Int32[], Int32[], Float64[], Int32[])


"""
    check_das(dDAS; verbose=true) -> Bool

Sanity-check an `iDAS` object BEFORE processing. Prints a short summary
(sampling rate, duration, number of channels, spacing) and warns about the
usual reading mistakes: transposed data, wrong axis lengths, NaN/Inf,
dead channels, too few samples for the PSD step.

Returns `true` if no problem was found, `false` otherwise.
"""
function check_das(dDAS; verbose=true)
    nt, nx = size(dDAS.data)
    problems = String[]

    # axes must match the matrix
    length(dDAS.time)   == nt || push!(problems, "length(time)=$(length(dDAS.time)) but data has $nt rows (time)")
    length(dDAS.offset) == nx || push!(problems, "length(offset)=$(length(dDAS.offset)) but data has $nx columns (channels)")

    if length(dDAS.time) > 1 && length(dDAS.offset) > 1
        Δt = dDAS.time[2]   - dDAS.time[1]
        Δx = dDAS.offset[2] - dDAS.offset[1]
        Δt > 0 || push!(problems, "time step is not positive (Δt=$Δt)")
        Δx > 0 || push!(problems, "channel spacing is not positive (Δx=$Δx)")

        verbose && println("""
        ── DAS check ──────────────────────────
          matrix     : $nt samples (time) × $nx channels
          sampling   : $(round(1/Δt, digits=3)) Hz  (Δt = $Δt s)
          duration   : $(round(nt*Δt, digits=2)) s
          spacing    : $Δx m  →  cable length ≈ $(round(nx*Δx, digits=1)) m
        ───────────────────────────────────────""")
    end

    # usually there are more time samples than channels
    nx > nt && push!(problems, "more channels ($nx) than time samples ($nt): is the data transposed?")
    nt < 4096 && push!(problems, "only $nt time samples: the PSD step will shrink its window")

    nbad = count(!isfinite, dDAS.data)
    nbad > 0 && push!(problems, "$nbad NaN/Inf values in the data")

    ndead = count(j -> all(==(0), @view(dDAS.data[:, j])), 1:nx)
    ndead > 0 && push!(problems, "$ndead channels are all zeros")

    for p in problems
        @warn "check_das: $p"
    end
    verbose && isempty(problems) && printstyled("  ✓ data looks well read\n", color=:green)
    return isempty(problems)
end


# ---- 2. Band selection -----------------------------------------------
#   Automatically find the dominant low-frequency band of the record so
#   we can band-pass filter around it.

"""
    running_median(v; halfwidth=5)

Running median of `v` over a window of ±`halfwidth` samples (edges use a
shorter window). Shared by `smooth_db` and `bump_band`.
"""
function running_median(v; halfwidth=5)
    n = length(v)
    out = similar(v, float(eltype(v)))
    for i in 1:n
        lo = max(1, i - halfwidth)
        hi = min(n, i + halfwidth)
        out[i] = median(@view v[lo:hi])
    end
    return out
end


"""
    welch_psd_trace(x, dt; seglen=4096, overlap=0.5, window=hanning)

Welch-style Power Spectral Density of ONE trace: overlapping segments,
windowed, `rfft`, power averaged over segments (like `scipy.signal.welch`).

Returns `(freqs, P)` with the one-sided frequency axis (0 … fs/2).
`x` must have at least `seglen` samples.
"""
function welch_psd_trace(x::AbstractVector, dt; seglen=4096, overlap=0.5, window=hanning)
    n    = length(x)
    step = round(Int, seglen * (1 - overlap))
    step < 1 && error("increase seglen or reduce overlap")

    starts = 1:step:(n - seglen + 1)
    isempty(starts) && error("trace has $n samples, shorter than seglen=$seglen")
    fs     = 1 / dt
    freqs  = collect(0:fs/seglen:fs/2)

    w    = window(seglen)
    U    = sum(abs2, w)                      # window power
    Pacc = zeros(length(freqs))
    for s in starts
        X = rfft(x[s:(s + seglen - 1)] .* w)
        Pacc .+= abs.(X[1:length(freqs)]) .^ 2 ./ (U * fs)
    end
    return freqs, Pacc ./ length(starts)
end


"""
    median_psd_welch(dDAS; seglen=4096, overlap=0.5)

Welch PSD of every channel, then across channels:
the median PSD and a noise-floor estimate (15th percentile).

Returns `(freqs, median_psd, noise_psd, Pmat)`; `Pmat` is channels × freqs.
"""
function median_psd_welch(dDAS; seglen=4096, overlap=0.5)
    dt      = dDAS.time[2] - dDAS.time[1]
    ntraces = size(dDAS.data, 2)

    freqs = nothing
    PSDs  = Vector{Vector{Float64}}()
    for j in 1:ntraces
        f, P = welch_psd_trace(dDAS.data[:, j], dt; seglen=seglen, overlap=overlap)
        freqs === nothing && (freqs = f)
        push!(PSDs, P)
    end

    Pmat       = reduce(hcat, PSDs)'                                   # channels × freqs
    median_psd = vec(median(Pmat, dims=1))
    noise_psd  = [quantile(@view(Pmat[:, k]), 0.15) for k in axes(Pmat, 2)]
    return freqs, median_psd, noise_psd, Pmat
end


"""
    smooth_db(vec; halfwidth_bins=5)

Convert a linear PSD to dB and smooth it with a running median.
"""
smooth_db(vec; halfwidth_bins=5) =
    running_median(10 .* log10.(vec .+ eps(Float64)); halfwidth=halfwidth_bins)


"""
    bump_band(freqs, SNR_med; mindrop_db=2.0, smooth_bins=10)

Find the dominant "bump" of the median SNR curve: smooth, locate the peak,
walk left/right until the curve has dropped by `mindrop_db`.

NOTE: only the first half of the input vectors is searched. `get_dp` already
passes half of a one-sided spectrum, so in practice the search covers
0 … fs/8. This is inherited from earlier versions (it favours low
frequencies) and is kept on purpose so images stay comparable.

Returns `(fmin, fpeak, fmax)`, rounded to whole Hz.
"""
function bump_band(freqs, SNR_med; mindrop_db=2.0, smooth_bins=10)
    half = div(length(SNR_med), 2)
    f    = freqs[1:half]
    S    = running_median(SNR_med[1:half]; halfwidth=smooth_bins)

    peak_idx = argmax(S)
    peak_val = S[peak_idx]

    left_idx = 1
    for i in peak_idx:-1:2
        if peak_val - S[i] >= mindrop_db
            left_idx = i
            break
        end
    end

    right_idx = half
    for i in peak_idx:half-1
        if peak_val - S[i] >= mindrop_db
            right_idx = i
            break
        end
    end

    return (floor(f[left_idx]), round(f[peak_idx]), ceil(f[right_idx]))
end


"""
    get_dp(dDAS; seglen=4096)

Automatic band-pass limits for a DAS record
(median PSD − noise PSD → SNR curve → `bump_band`).

If the record is shorter than `seglen`, the window is shrunk to the largest
power of two that fits.

Returns `(dbmin, dbmax, freqs, SNR_med)`.
"""
function get_dp(dDAS; seglen=4096)
    seglen = min(seglen, prevpow(2, size(dDAS.data, 1)))

    freqs, median_psd, noise_psd, _ = median_psd_welch(dDAS; seglen=seglen, overlap=0.5)

    sm_med    = smooth_db(median_psd; halfwidth_bins=floor(Int, length(median_psd) * 0.5 / 100))
    noise_med = smooth_db(noise_psd;  halfwidth_bins=floor(Int, length(noise_psd)  * 10  / 100))
    SNR_med   = sm_med .- noise_med

    half = div(length(SNR_med), 2)
    dbmin, _, dbmax = bump_band(
        freqs[1:half], SNR_med[1:half];
        mindrop_db  = round(mean(SNR_med[1:half])),
        smooth_bins = floor(Int, half * 0.5 / 100),
    )
    return dbmin, dbmax, freqs, SNR_med
end


# ---- 3. FK analysis --------------------------------------------------
#   Go to the frequency-wavenumber (FK) domain, find the strongest
#   (f, k) peak inside the band, and use it to size a 2-D Gaussian blur.

# Median filter with a (2r+1)x(2r+1) window. Non-mutating on purpose:
# an in-place `median!` on views can reorder the input while we slide over it.
function _median_filter(A; r=2)
    B  = similar(A)
    R  = CartesianIndices(A)
    Ifirst, Ilast = first(R), last(R)
    for I in R
        imin = max(Ifirst, I - CartesianIndex(r, r))
        imax = min(Ilast,  I + CartesianIndex(r, r))
        B[I] = median(view(A, imin:imax))
    end
    return B
end


"""
    fkpeak(zs, Δx, Δt; dbmin=0.0, dbmax=Inf, taper=0.05)

2-D FK spectrum (folded, positive f and k), values outside `dbmin…dbmax` Hz
set to 0 dB, a 5×5 median filter against hot pixels, and the (f, k) of the
global maximum.

    zs :: Matrix  (nt, nx)  time × space
    Δx :: channel spacing [m]      Δt :: sample interval [s]

Returns `(f_pk [Hz], k_pk [rad/m], f_axis, k_axis, Pdb_smooth)`.
"""
function fkpeak(zs, Δx, Δt; dbmin=0.0, dbmax=Inf, taper=0.05)
    nt, nx = size(zs)

    # --- pre-processing (work on a copy) ---
    zs = copy(zs)
    zs .-= mean(zs, dims=2)
    zs .-= mean(zs, dims=1)
    tap_t = DSP.Windows.tukey(nt, taper)
    tap_x = DSP.Windows.tukey(nx, taper)
    zs  .= zs .* tap_t .* tap_x'

    # --- 2-D FFT ---
    Δk  = 2π / (nx * Δx)
    Δf  = 1 / (nt * Δt)
    FFT = fftshift(fft(zs))

    # --- positive f and k only, negative k folded onto positive k ---
    k_pos_idx = nx÷2+1 : nx
    f_pos_idx = nt÷2+1 : nt
    k_pos = (0 : length(k_pos_idx)-1) .* Δk
    f_pos = (0 : length(f_pos_idx)-1) .* Δf
    FFT_pos = FFT[f_pos_idx, k_pos_idx]

    k_neg_idx = nx÷2 : -1 : 1
    # NOTE (known, kept on purpose): zip pairs k=0 with k=-Δk, +Δk with -2Δk, ...
    # A symmetric fold would pair +jΔk with -jΔk (k=0 alone), i.e. use `nx÷2+2-j`
    # for the negative bin. The off-by-one makes waves travelling one way report a
    # k that is one bin low. The 5 % kernel cap in `fkgaussfilter` limits its effect
    # on the images, and the trained models have only seen images made this way,
    # so it is left unchanged until the models are retrained or compared.
    FFT_fold  = similar(FFT_pos)
    for (j, (_, kn)) in enumerate(zip(k_pos_idx, k_neg_idx))
        @views FFT_fold[:, j] = FFT_pos[:, j] .+ FFT[f_pos_idx, kn]
    end

    # --- power (dB), mask outside the band ---
    Pdb = @. 10 * log10(abs2(FFT_fold) + eps(real(FFT_fold)))
    mask = @. (f_pos < dbmin) | (f_pos > dbmax)
    Pdb_masked = copy(Pdb)
    Pdb_masked[mask, :] .= 0.0

    # --- clean + pick the peak ---
    Pdb_smooth = _median_filter(Pdb_masked; r=2)
    imax = argmax(Pdb_smooth)
    return f_pos[imax[1]], k_pos[imax[2]], f_pos, k_pos, Pdb_smooth
end


# helpers for fkgaussfilter
_odd_floor(n::Integer) = isodd(n) ? n : n - 1

# kernel length (odd) for a Gaussian of width σ, kept between 3 and wmax
_kernel_len(σ, wmax) = isfinite(σ) ?
    clamp(ceil(Int, min(4σ, 1e6)) ÷ 2 * 2 + 1, 3, wmax) : wmax


"""
    fkgaussfilter(zs, Δx, Δt, f_pk, k_pk; relwidth=0.1, max_frac=0.05)

Blur `zs` with a 2-D Gaussian whose σ is `relwidth` × the peak wavelength
(in time: 1/f_pk, in space: 2π/k_pk), converted to samples.

The kernel is never larger than `max_frac` (default 5 %) of the matrix size
in each dimension (and never smaller than 3). If σ would need a larger
kernel, σ is reduced to match (kernel ≈ ±2σ). A peak at f=0 or k=0 gives
an infinite wavelength; that case simply uses the largest allowed kernel.
"""
function fkgaussfilter(zs, Δx, Δt, f_pk, k_pk; relwidth=0.1, max_frac=0.05)
    nt, nx = size(zs)

    # largest allowed (odd) kernel per dimension
    wmax_t = max(3, _odd_floor(floor(Int, max_frac * nt)))
    wmax_x = max(3, _odd_floor(floor(Int, max_frac * nx)))

    # wavelength → σ in samples (Inf if the peak is at 0)
    σt = (isfinite(f_pk) && f_pk > 0) ? relwidth * (1 / f_pk)  / Δt : Inf
    σx = (isfinite(k_pk) && k_pk > 0) ? relwidth * (2π / k_pk) / Δx : Inf

    wt = _kernel_len(σt, wmax_t)
    wx = _kernel_len(σx, wmax_x)
    σt = min(σt, wt / 4)
    σx = min(σx, wx / 4)

    kernel = Kernel.gaussian((σt, σx), (wt, wx))
    return imfilter(zs, kernel, "replicate")
end


# ---- 4. Pipeline -----------------------------------------------------
#   The whole recipe in one call: dDAS in → normalised matrix → PNG.

"""
    normalize_columns(zs)

Divide each column (channel) by its maximum absolute value, so every
channel peaks at ±1. All-zero channels are left untouched.
"""
function normalize_columns(zs)
    col_max = maximum(abs, zs; dims=1)
    col_max[col_max .== 0] .= 1
    return zs ./ col_max
end


# Run `f()` with stdout/stderr silenced. DASVader prints one line per channel
# ("Working on channel 399 of 448."), which floods the terminal.
# Exceptions still propagate normally.
function _quiet(f, on::Bool)
    on || return f()
    redirect_stdout(devnull) do
        redirect_stderr(devnull) do
            f()
        end
    end
end


"""
    process_das!(dDAS; seglen=4096, relwidth=0.1, max_kernel_frac=0.05,
                 fallback_band=(1.0, 5.0), quiet=true, verbose=true)

Full DAS processing chain (modifies `dDAS.data`):

1. remove mean/trend, normalise per channel, NaN → 0
2. pick the band-pass limits automatically (`get_dp`)
3. band-pass filter (4 poles), clean again
4. find the FK peak
5. Gaussian blur sized by that peak (`fkgaussfilter`)
6. per-channel normalisation

If the automatic band is unusable (`dbmin ≥ dbmax`), `fallback_band` is used.
`quiet=true` silences DASVader's per-channel progress messages.

Returns `(zs, info)`: the image matrix and a NamedTuple with
`dbmin, dbmax, f_pk, k_pk`.
"""
function process_das!(dDAS; seglen=4096, relwidth=0.1, max_kernel_frac=0.05,
                      fallback_band=(1.0, 5.0), quiet=true, verbose=true)

    _quiet(quiet) do
        ppdas!(dDAS; rmean=true, rtrend=true, taper=false, w=0.01, f=:hanning)
        normdas!(dDAS; style="channel")
        nan2zero!(dDAS)
    end

    dbmin, dbmax, _, _ = get_dp(dDAS; seglen=seglen)
    dbmin = max(1, dbmin)
    if dbmin >= dbmax
        verbose && @warn "Automatic band $(dbmin)–$(dbmax) Hz is unusable; using $(fallback_band)"
        dbmin, dbmax = fallback_band
    end

    _quiet(quiet) do
        bpdas!(dDAS; f1=dbmin, f2=dbmax, poles=4)
        ppdas!(dDAS; rmean=true, rtrend=true, taper=false, w=0.01, f=:hanning)
        normdas!(dDAS; style="channel")
        nan2zero!(dDAS)
    end

    Δx = dDAS.offset[2] - dDAS.offset[1]
    Δt = dDAS.time[2]   - dDAS.time[1]
    f_pk, k_pk, _, _, _ = fkpeak(dDAS.data, Δx, Δt; dbmin=dbmin, dbmax=dbmax)

    zs_blur = fkgaussfilter(dDAS.data, Δx, Δt, f_pk, k_pk;
                            relwidth=relwidth, max_frac=max_kernel_frac)
    zs = normalize_columns(zs_blur)

    verbose && println("  band $(dbmin)–$(dbmax) Hz, FK peak f=$(round(f_pk, digits=2)) Hz, k=$(round(k_pk, digits=4)) rad/m")
    return zs, (dbmin=dbmin, dbmax=dbmax, f_pk=f_pk, k_pk=k_pk)
end


"""
    das2pics(dDAS; label, outdir=".", augment=0, verbose=true, kwargs...) -> path

Process one record and save its image `<label>_RdBu_0.png` in `outdir`.
With `augment=N > 0`, N extra augmented images are saved too (training only).
`verbose=false` silences the progress messages (used by the live watcher).
`kwargs` go to `process_das!`. Returns the path of the main image.
"""
function das2pics(dDAS; label, outdir=".", augment=0, verbose=true, kwargs...)
    zs, _ = process_das!(dDAS; verbose=verbose, kwargs...)
    path  = save_fig(zs, label; suffix="RdBu_0", outdir=outdir, verbose=verbose)
    augment > 0 && das_image_data_augmentation(zs, label; it=augment, outdir=outdir)
    return path
end


# ---- 5. Augmentation (training data only) ----------------------------
#   Not needed to classify data; it only enlarges a training set.

"""
    das_image_data_augmentation(zs_norm, label; it=10, outdir=".")

Save `it` randomly augmented copies of `zs_norm`. Each of the 5 operations
is applied with 50 % probability:

1. polarity reversal              2. channel (fibre) flip
3. circular time shift            4. crop 1–10 % of rows at top/bottom
5. crop 0–15 % of columns at left/right

The 5-digit code `r1r2r3r4r5` of what was applied is part of the filename.
"""
function das_image_data_augmentation(zs_norm, label; it=10, outdir=".")
    for i in 1:it
        stamp = Dates.format(now(), "yyyymmdd_HHMMSS_sss")   # no ':' → valid on Windows
        zs = copy(zs_norm)

        r1 = rand(0:1)
        r1 == 1 && (zs = -zs)

        r2 = rand(0:1)
        r2 == 1 && (zs = zs[:, end:-1:1])

        r3 = rand(0:1)
        if r3 == 1
            s  = max(1, floor(Int, size(zs, 1) * rand(0.05:0.01:0.95)))
            zs = [zs[s:end, :]; zs[1:s-1, :]]      # (v4 used zs_norm here: a bug)
        end

        r4 = rand(0:1)
        if r4 == 1
            nrows = size(zs, 1)
            cut1  = floor(Int, nrows * rand(1:10) / 100)
            cut2  = floor(Int, nrows * rand(1:10) / 100)
            zs    = zs[cut1+1 : nrows-cut2, :]
        end

        r5 = rand(0:1)
        if r5 == 1
            ncols = size(zs, 2)
            cut1  = floor(Int, ncols * rand(0:15) / 100)
            cut2  = floor(Int, ncols * rand(0:15) / 100)
            zs    = zs[:, cut1+1 : ncols-cut2]
        end

        save_fig(zs, label; suffix="RdBu_$(r1)$(r2)$(r3)$(r4)$(r5)_$(stamp)_$(i)", outdir=outdir)
    end
end


# ---- 6. Figure making ------------------------------------------------

# "dir/file.nc" → "file"  (only strips known data-file extensions)
das_stem(label) = replace(basename(label), r"\.(nc|h5|hdf5|jld2|segy|sgy|tdms|dat|png)$"i => "")


"""
    save_fig(zs, label; suffix="RdBu_0", cm=:RdBu_9, outdir=".", verbose=true) -> path

Save the matrix `zs` as a 224×224 px heatmap with no axes or decorations
(ResNet-ready). Colour limits are ±3σ of `zs`. The file is
`outdir/<stem of label>_<suffix>.png`. Returns the path.
"""
function save_fig(zs, label; suffix="RdBu_0", cm=:RdBu_9, outdir=".", verbose=true)
    mkpath(outdir)
    climit = max(3 * std(zs), eps(Float32))     # symmetric colour range around 0

    fig = Figure(figure_padding=0, size=(224, 224), aspect=DataAspect())
    ihm = heatmap(fig[1, 1], zs;
                  colormap=cm, colorrange=(-climit, climit), interpolate=false)
    hidespines!(ihm.axis)
    hidedecorations!(ihm.axis)
    rowgap!(fig.layout, 0)
    colgap!(fig.layout, 0)

    path = joinpath(outdir, "$(das_stem(label))_$(suffix).png")
    save(path, fig; px_per_unit=1)
    verbose && printstyled("  saved $path\n", color=:blue)
    return path
end


# ---- 7. Automatic level intensity ------------------------------------
#   Contrast stretch (like "auto levels" in Preview) so large values
#   look clearer.

"""
    auto_level_intensity(img; tail=0.005)

Linear contrast stretch of an image: the `tail` and `1-tail` luminance
quantiles are mapped to 0 and 1, applied to R, G and B alike. Alpha is kept.
"""
function auto_level_intensity(img; tail=0.005)
    col = float.(RGB.(img))
    α   = alpha.(img)
    lum = Gray.(col)

    lo = quantile(vec(channelview(lum)), tail)
    hi = quantile(vec(channelview(lum)), 1 - tail)
    Δ  = hi - lo

    f(x) = Δ > 0 ? clamp((x - lo) / Δ, 0.0, 1.0) : x
    out  = map(c -> RGB(f(c.r), f(c.g), f(c.b)), col)
    return eltype(img) <: ColorAlpha ? RGBA.(out, α) : out
end


"""
    auto_level_file(path; tail=0.005) -> outpath

Load a PNG, apply `auto_level_intensity`, save it as `<name>_AUTO.png`.
"""
function auto_level_file(path; tail=0.005)
    outpath = replace(path, r"\.png$"i => "_AUTO.png")
    save(outpath, auto_level_intensity(load(path); tail=tail))
    return outpath
end


"""
    batch_auto_level_intensity(; dir=".", tail=0.005, overwrite=false,
                                 remove_original=false)

Apply `auto_level_file` to every PNG in `dir`. Files that already end in
`_AUTO.png` are skipped, and (unless `overwrite=true`) so are images whose
`_AUTO` version already exists, so it is safe to run twice.

With `remove_original=true` the plain PNG is deleted once its `_AUTO`
version has been written successfully (if the write fails, the original stays).
"""
function batch_auto_level_intensity(; dir=".", tail=0.005, overwrite=false,
                                      remove_original=false)
    for f in readdir(dir; join=true)
        (isfile(f) && endswith(lowercase(f), ".png")) || continue
        endswith(lowercase(f), "_auto.png") && continue
        out = replace(f, r"\.png$"i => "_AUTO.png")
        if !(isfile(out) && !overwrite)
            auto_level_file(f; tail=tail)
            println("  → $out")
        end
        remove_original && isfile(out) && rm(f)
    end
end


# ---- 8. File handling ------------------------------------------------

"""
    figs2dirs(; srcdir=".", prefix="FIGS", subdir="RdBu") -> masterdir

Move every RdBu PNG found in `srcdir` into
`<prefix>_YYYYMMDD_HHMMSS/<subdir>/`. Returns the new directory.
(Other PNGs in `srcdir` are left alone.)
"""
function figs2dirs(; srcdir=".", prefix="FIGS", subdir="RdBu")
    stamp     = Dates.format(now(), "yyyymmdd_HHMMSS")
    masterdir = joinpath(srcdir, "$(prefix)_$(stamp)")
    target    = joinpath(masterdir, subdir)
    mkpath(target)

    for f in readdir(srcdir)
        p = joinpath(srcdir, f)
        if isfile(p) && endswith(lowercase(f), ".png") && occursin("rdbu", lowercase(f))
            mv(p, joinpath(target, f))
        end
    end
    println("✅ Figures organized into $masterdir")
    return masterdir
end

"""
    noise2dirs(; srcdir=".")

Same as `figs2dirs` but the folder is called `NOISE_<timestamp>`.
"""
noise2dirs(; srcdir=".") = figs2dirs(; srcdir=srcdir, prefix="NOISE")
