# ================================================================
#  DASight :: DASight_env.sh   (sourced by the run_*.sh launchers)
#
#  Finds the Julia environment where DASight is installed and sets the
#  array DASight_JULIA to the right julia command. Order of preference:
#     1. the environment named in $DASight_ENV (a folder, or @name)
#     2. the shared environment @DASight   (recommended, see the README)
#     3. Julia's default environment
# ================================================================
if ! command -v julia >/dev/null 2>&1; then
    echo "ERROR: 'julia' not found. Install Julia (https://julialang.org/downloads/) and make sure it is in your PATH." >&2
    exit 1
fi

_has_DASight() {   # usage: _has_DASight <julia flags...>
    julia "$@" -e 'exit(Base.find_package("DASight") === nothing ? 1 : 0)' >/dev/null 2>&1
}

if [ -n "${DASight_ENV:-}" ]; then
    DASight_JULIA=(julia "--project=$DASight_ENV")
elif _has_DASight --project=@DASight; then
    DASight_JULIA=(julia --project=@DASight)
elif _has_DASight; then
    DASight_JULIA=(julia)
else
    echo "ERROR: the Julia package DASight was not found." >&2
    echo "       Install it first (see the README), e.g. in the shared environment @DASight:" >&2
    echo "         julia> ] activate @DASight" >&2
    echo "         (@DASight) pkg> add <the four URLs from the README>" >&2
    echo "       or tell the launcher where it is:  DASight_ENV=/path/to/env ./run_painter.sh ..." >&2
    exit 1
fi
