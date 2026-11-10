# ================================================================
#  DASight :: Distribution.jl
#  Author: Mariano Arnaiz
#
#  The big files (trained models, example data) do not live in the git
#  repository: they are hosted on Zenodo and described in Artifacts.toml.
#  Julia downloads them the first time they are needed, checks them, and
#  caches them in ~/.julia/artifacts.
#
#    models_dir()                  folder with ZEUS.bson, POSEIDON.bson, HADES.bson
#    example_data_dir()            folder with the example data (data_test, Fake_DAS)
#    install_examples(dest)        copy the example scripts (and data) to a folder you own
#
#  Environment variables (to use your own copies instead of downloading):
#    DASight_MODELS_DIR, DASight_DATA_DIR
# ================================================================

import Pkg

const ARTIFACTS_TOML = joinpath(dirname(@__DIR__), "Artifacts.toml")
const EXAMPLES_DIR   = joinpath(dirname(@__DIR__), "examples")

# path of an artifact (downloaded on first use)
function _artifact_path(name::AbstractString)
    meta = Pkg.Artifacts.artifact_meta(name, ARTIFACTS_TOML)
    meta === nothing && error("""
        Artifact "$name" is not listed in $(ARTIFACTS_TOML).
        The data files of this release have not been published yet (or Artifacts.toml is outdated).
        You can point DASight to your own copy instead (see ?models_dir).""")
    return Pkg.Artifacts.ensure_artifact_installed(name, ARTIFACTS_TOML)
end


"""
    models_dir() -> String

Folder with the trained models (`ZEUS.bson`, `POSEIDON.bson`, `HADES.bson`).
The first call downloads them from Zenodo (a few hundred MB, once).
Set the environment variable `DASight_MODELS_DIR` to use a local folder instead.
"""
function models_dir()
    haskey(ENV, "DASight_MODELS_DIR") && return ENV["DASight_MODELS_DIR"]
    @info "Getting the DASight models (the first time this downloads a few hundred MB)..."
    return _artifact_path("DASight_models")
end


"""
    example_data_dir() -> String

Folder with the example data used by the examples
(`data_test/` with .nc files and `Fake_DAS/` with .jld2 files).
The first call downloads it from Zenodo.
Set `DASight_DATA_DIR` to use a local folder instead.
"""
function example_data_dir()
    haskey(ENV, "DASight_DATA_DIR") && return ENV["DASight_DATA_DIR"]
    @info "Getting the DASight example data..."
    return _artifact_path("DASight_example_data")
end


# Make a copied tree usable: files inside ~/.julia/packages are read-only, and
# the launcher scripts must be executable (git/zip/web uploads can drop that bit).
function _make_writable(path)
    for (root, dirs, files) in walkdir(path)
        chmod(root, filemode(root) | 0o200)
        for f in files
            p = joinpath(root, f)
            chmod(p, filemode(p) | 0o200 | (endswith(f, ".sh") ? 0o111 : 0o000))
        end
    end
end


"""
    install_examples(dest="DASight_examples"; data=true, force=false) -> String

Copy the three examples (`1_PAINTER`, `2_DETECTIVE`, `3_WATCHER`, with their
launcher scripts) to the folder `dest`, where you can edit and run them.
With `data=true` the example data is copied too (`1_PAINTER/data_test`,
`3_WATCHER/Fake_DAS`); if it cannot be downloaded you get a warning and the
scripts are still copied. An existing `dest` is only replaced with `force=true`.
"""
function install_examples(dest::AbstractString="DASight_examples"; data::Bool=true, force::Bool=false)
    dest = abspath(expanduser(dest))
    ispath(dest) && !force && error("$dest already exists. Use force=true to replace it.")
    cp(EXAMPLES_DIR, dest; force=force)
    _make_writable(dest)

    if data
        try
            src = example_data_dir()
            for (sub, target) in (("data_test", "1_PAINTER"), ("Fake_DAS", "3_WATCHER"))
                from = joinpath(src, sub)
                isdir(from) && cp(from, joinpath(dest, target, sub); force=true)
            end
            _make_writable(dest)
        catch err
            @warn "Example scripts copied, but the example data could not be added" exception=err
        end
    end

    println("""
    Examples installed in $dest
      1_PAINTER   : data → pictures        (try: ./run_painter.sh data_test)
      2_DETECTIVE : pictures → events      (try: ./run_detective.sh DASight_pics)
      3_WATCHER   : live classification    (try: ./start_recording.sh  and  ./run_watcher.sh)
    """)
    return dest
end
