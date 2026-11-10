#!/usr/bin/env julia
# ================================================================
#  DASight :: scripts/make_artifact.jl      (for maintainers, not users)
#
#  Packs a folder into a .tar.gz and registers it in Artifacts.toml, so that
#  DASight can download it on demand (models, example data).
#
#  Usage:
#     julia scripts/make_artifact.jl <name> <source_folder> <download_url> [output_folder]
#
#  Examples:
#     julia scripts/make_artifact.jl DASight_models /path/to/MODELS \
#         "https://zenodo.org/records/1234567/files/DASight_models.tar.gz?download=1"
#     julia scripts/make_artifact.jl DASight_example_data /path/to/example_data \
#         "https://zenodo.org/records/1234568/files/DASight_example_data.tar.gz?download=1"
#
#  What it does
#     1. copies the CONTENTS of <source_folder> into an artifact
#        (the files end up at the top level of the artifact)
#     2. writes <output_folder>/<name>.tar.gz   ← this is the file you upload to Zenodo
#     3. adds/updates the entry <name> in Artifacts.toml (checksums + <download_url>)
#
#  <download_url> must be the FINAL address of the uploaded file. On Zenodo
#  you can reserve it before publishing: create a draft, note the record
#  number, and the file URL is .../records/<number>/files/<name>.tar.gz?download=1
#  See scripts/PUBLISHING.md for the full procedure.
# ================================================================
using Pkg.Artifacts

length(ARGS) >= 3 || error("usage: julia scripts/make_artifact.jl <name> <source_folder> <download_url> [output_folder]")
name, src, url = ARGS[1], abspath(ARGS[2]), ARGS[3]
outdir = abspath(length(ARGS) >= 4 ? ARGS[4] : ".")

isdir(src) || error("source folder not found: $src")
mkpath(outdir)
toml    = joinpath(dirname(@__DIR__), "Artifacts.toml")
tarball = joinpath(outdir, "$(name).tar.gz")

println("Packing $src ...")
hash = create_artifact() do dir
    for f in readdir(src)
        cp(joinpath(src, f), joinpath(dir, f))
    end
end

println("Writing $tarball ...")
sha256 = archive_artifact(hash, tarball)

bind_artifact!(toml, name, hash; download_info=[(url, sha256)], lazy=true, force=true)

println("""

Done.
  tarball  : $tarball   ($(round(filesize(tarball) / 1e6, digits=1)) MB)
  sha256   : $sha256
  tree hash: $hash
  entry    : "$name" in $toml
Next: upload the tarball to $url
      and commit the updated Artifacts.toml.""")
