#!/usr/bin/env julia
# ================================================================
#  DASight :: 1_PAINTER :: DAS2Pics_nc.jl
#
#  Reads every .nc file in INPUT_DIR and paints one 224x224 PNG per file,
#  ready for the DASight classifier.
#
#  HOW TO USE
#    1. Edit the SETTINGS block (variable names in your .nc files).
#    2. Run:   julia DAS2Pics_nc.jl [input_dir] [output_dir] [--keep-originals]
#       or use the launcher:   ./run_painter.sh data_test
#
#    Only the contrast-stretched *_AUTO.png images are kept, unless
#    --keep-originals is given.
#
#  HOW TO ADAPT TO OTHER FORMATS (h5, segy, ...)
#    Only STEP 1 changes. Write a function that returns an `iDAS` built from:
#
#        dDAS = iDAS(data, timee, htime, offset, atrib, filename)
#
#          data    Matrix        (time samples) × (channels)   ← orientation matters!
#          timee   range/vector  seconds, length = size(data, 1)
#          htime   Vector{DateTime}, length = size(data, 1)   (human time; metadata)
#          offset  range/vector  metres,  length = size(data, 2)
#          atrib   empty_attb()  (metadata, not used by DASight)
#          filename String
#
#    Then call check_das(dDAS). If it prints "data looks well read",
#    the rest of DASight will work on it. `read_das_nc` (see
#    DASight/src/DataIO.jl) is a complete worked example.
# ================================================================

using DASight


# ================================================================
#  SETTINGS  ← edit here
# ================================================================
# Folders can be given on the command line (1st and 2nd argument);
# the values here are the defaults.
const _ARGS      = filter(a -> !startswith(a, "--"), ARGS)
const INPUT_DIR  = length(_ARGS) >= 1 ? _ARGS[1] : "."                # folder with the .nc files
const OUTPUT_DIR = length(_ARGS) >= 2 ? _ARGS[2] : "DASight_pics"    # PNGs are written here
const KEEP_ORIGINALS = "--keep-originals" in ARGS   # keep the plain (non-AUTO) PNGs?
const AUGMENT    = 0                   # >0 only to build TRAINING sets

# Names of the variables inside your .nc files
const VAR_DATA   = "StrainRate"
const VAR_OFFSET = "offset"
const VAR_TIME   = "time"

# Time unit of VAR_TIME. `nothing` = read it from the file's "units"
# attribute ("microseconds since 1970-01-01 ..."). Otherwise one of:
# "nanoseconds", "microseconds", "milliseconds", "seconds".
const TIME_UNIT  = nothing


# ================================================================
#  STEP 1 : READ A .nc FILE INTO AN iDAS
# ================================================================
read_file(f) = read_das_nc(f; data_var=VAR_DATA, offset_var=VAR_OFFSET,
                              time_var=VAR_TIME, time_unit=TIME_UNIT)


# ================================================================
#  STEP 2 : PAINT
# ================================================================
function main()
    files = sort(filter(f -> endswith(lowercase(f), ".nc"), readdir(INPUT_DIR; join=true)))
    isempty(files) && error("No .nc files found in '$(abspath(INPUT_DIR))'. Edit INPUT_DIR.")
    println("Found $(length(files)) .nc file(s)")

    for f in files
        try
            dDAS = read_file(f)
            check_das(dDAS) || @warn "Problems reported above; continuing anyway"
            das2pics(dDAS; label=f, outdir=OUTPUT_DIR, augment=AUGMENT)
        catch err
            @error "Skipping $f" exception=(err, catch_backtrace())
        end
        GC.gc()                                   # release memory between large files
    end

    # contrast-stretched copies (<name>_AUTO.png)
    batch_auto_level_intensity(dir=OUTPUT_DIR, remove_original=!KEEP_ORIGINALS)
    println("\nDone. Images are in $(abspath(OUTPUT_DIR))")
end

main()
