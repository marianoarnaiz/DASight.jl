# Publishing DASight (maintainers)

The git repository only holds code. The trained models and the example data are
hosted on **Zenodo** and downloaded on demand through Julia **Artifacts**
(`Artifacts.toml`). This is the order of work for a release.

## 1. Prepare the folders

```
MODELS/            ZEUS.bson  POSEIDON.bson  HADES.bson        (nothing else)
example_data/      data_test/   (a few .nc files)
                   Fake_DAS/    (1.jld2 ... 12.jld2)
```

Keep them small enough to be friendly: the models are the big part (hundreds of MB).

## 2. Create the Zenodo records (drafts)

Make two *drafts* at <https://zenodo.org/uploads/new>: one for the models, one for the
example data. Do **not** publish yet. For each draft, note the record number that Zenodo
shows (it is reserved as soon as you click *Reserve DOI*). The final file address will be:

```
https://zenodo.org/records/<RECORD>/files/<NAME>.tar.gz?download=1
```

## 3. Pack the files and write `Artifacts.toml`

From the repository root:

```bash
julia scripts/make_artifact.jl DASight_models /path/to/MODELS \
    "https://zenodo.org/records/<MODELS_RECORD>/files/DASight_models.tar.gz?download=1" ./dist

julia scripts/make_artifact.jl DASight_example_data /path/to/example_data \
    "https://zenodo.org/records/<DATA_RECORD>/files/DASight_example_data.tar.gz?download=1" ./dist
```

This creates `dist/DASight_models.tar.gz` and `dist/DASight_example_data.tar.gz` and fills
`Artifacts.toml` with their checksums. The artifact names must stay exactly
`DASight_models` and `DASight_example_data` (the code asks for them by name).

## 4. Upload and publish

Upload each `.tar.gz` to its draft, then publish both records.
**The file names must match the URLs used in step 3.** If you change anything in a tarball
afterwards, repeat step 3: the checksum changes.

## 5. Test it as a stranger would

On a clean Julia environment (or after `rm -rf ~/.julia/artifacts`):

```julia
using Pkg
Pkg.activate("clean_test"; shared=true)
Pkg.add([PackageSpec(url="https://github.com/anowacki/Geodesics.jl"),
         PackageSpec(url="https://github.com/anowacki/Seis.jl"),
         PackageSpec(url="https://github.com/marianoarnaiz/DASvader.jl"),
         PackageSpec(url="https://github.com/marianoarnaiz/DASight.jl")])
using DASight
DASight.models_dir()          # downloads and verifies
DASight.install_examples("~/DASight_test")
```

Then run the three examples from `~/DASight_test`.

## 6. Release

1. Commit `Artifacts.toml` and push.
2. Bump `version` in `Project.toml` and `CITATION.cff`.
3. Create a GitHub release with tag `v0.1.0`.
4. If the repository is linked to Zenodo (<https://zenodo.org/account/settings/github/>),
   the release also gets its own DOI: add it to `CITATION.cff` and the README badge.

Users can then install a fixed version with `...DASight.jl#v0.1.0`.

## Things to keep in mind

- **BSON models depend on package versions.** `Project.toml` pins Flux 0.14.25, Metalhead 0.9.5
  and MLUtils 0.4.5, the versions the models were saved and tested with. If you ever
  upgrade them, test loading the models first.
- **Julia versions.** `Project.toml` claims Julia ≥ 1.10; the code was checked on 1.12. The CI
  matrix tests 1.10 and the latest release: trust it over this note.
