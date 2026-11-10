# ================================================================
#  DASight :: DataIO.jl
#  Author: Mariano Arnaiz
#
#  Getting DAS data into Julia. Everything in DASight works on an `iDAS`
#  object (from DASVader):
#
#      dDAS = iDAS(data, timee, htime, offset, atrib, filename)
#
#        data    Matrix        (time samples) × (channels)   ← orientation matters!
#        timee   range/vector  seconds, length = size(data, 1)
#        htime   Vector{DateTime}, length = size(data, 1)   (human time; metadata)
#        offset  range/vector  metres,  length = size(data, 2)
#        atrib   empty_attb()  (metadata, not used by DASight)
#        filename String
#
#  Readers provided here
#    read_das_nc    NetCDF (.nc)
#    read_das_jld2  DASVader's own format (.jld2)
#
#  For any other format, write a function that returns an `iDAS` built as
#  above and check it with `check_das(dDAS)`. If it prints
#  "data looks well read", the rest of DASight will work on it.
# ================================================================

using NCDatasets, NanoDates, Dates, Statistics
import JLD2            # lets FileIO read .jld2 files (DASVader format)

const UNIT_TO_NS = Dict("nanoseconds"  => 1.0, "microseconds" => 1e3,
                        "milliseconds" => 1e6, "seconds"      => 1e9)


"""
    read_das_nc(filename; data_var="StrainRate", offset_var="offset",
                time_var="time", time_unit=nothing) -> iDAS

Read a NetCDF DAS file. `data_var`, `offset_var` and `time_var` are the names
of the variables inside your files.

The data matrix is returned as (time × channels): if the file stores it the
other way round it is transposed automatically (decided by comparing its size
with the length of the time and offset axes).

`time_unit` is the unit of the time variable: `nothing` reads it from the
file's "units" attribute ("microseconds since 1970-01-01 ..."); otherwise one
of "nanoseconds", "microseconds", "milliseconds", "seconds".
"""
function read_das_nc(filename::AbstractString; data_var::AbstractString="StrainRate",
                     offset_var::AbstractString="offset", time_var::AbstractString="time",
                     time_unit=nothing)

    NCDataset(filename, "r") do ds
        # --- axes (".var" gives the raw numbers, with no automatic decoding) ---
        off_raw  = ds[offset_var].var[:]
        time_raw = ds[time_var].var[:]
        nx, nt   = length(off_raw), length(time_raw)

        # --- data: make it (time × channels) ---
        raw = ds[data_var].var[:, :]
        if size(raw) == (nt, nx) && nt != nx
            data = Matrix(raw)                     # already time × channels
        elseif size(raw) == (nx, nt)
            data = Matrix(permutedims(raw))        # channels × time → transpose
        else
            error("$filename: '$data_var' has size $(size(raw)) but the file has " *
                  "$nt time samples and $nx channels. Check data_var / time_var / offset_var.")
        end

        # --- distance axis ---
        offset = range(start=off_raw[1], step=mean(diff(off_raw)), length=nx)

        # --- time axis ---
        att   = ds[time_var].attrib
        units = haskey(att, "units") ? att["units"] : ""
        m     = match(r"^\s*(nanoseconds|microseconds|milliseconds|seconds)\s+since\s+(.*)$", units)
        unit  = isnothing(time_unit) ? (isnothing(m) ? nothing : m.captures[1]) : time_unit
        isnothing(unit) && error("$filename: cannot tell the unit of '$time_var' " *
                                 "(units attribute: \"$units\"). Pass time_unit=\"microseconds\" (or similar).")
        ns_per_unit = UNIT_TO_NS[unit]

        Δt    = mean(diff(time_raw)) * ns_per_unit / 1e9          # seconds
        timee = range(start=0.0, step=Δt, length=nt)              # seconds from first sample

        # human-readable time = reference date + raw time (falls back to now())
        htime = try
            ref = NanoDate(strip(replace(m.captures[2], r"\s*(UTC|Z)$" => "")))
            DateTime.(ref .+ Nanosecond.(round.(Int64, time_raw .* ns_per_unit)))
        catch
            @warn "$filename: could not parse the reference date; using now() for htime"
            now() .+ Millisecond.(round.(Int, (0:nt-1) .* Δt .* 1000))
        end

        return iDAS(data, timee, htime, offset, empty_attb(), filename)
    end
end


"""
    read_das_jld2(path; varname="dDAS") -> iDAS

Read a DASVader `.jld2` file. This is the only line needed to get this
kind of data into DASight.
"""
read_das_jld2(path::AbstractString; varname::AbstractString="dDAS") = FileIO.load(path)[varname]
