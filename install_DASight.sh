#!/usr/bin/env bash
# ================================================================
#  DASight installer (macOS and Linux)
#
#  What it does:
#    1. installs juliaup (which installs and manages Julia), if missing
#    2. installs the current stable Julia
#    3. installs the three helper packages that are not in the public
#       Julia registry (Geodesics, Seis, DASvader)
#    4. installs DASight itself
#    5. checks that DASight loads
#
#  Usage:   bash install_DASight.sh
# ================================================================
set -euo pipefail

say() { printf '\n==> %s\n' "$*"; }

# ---- 0. system check -------------------------------------------
OS="$(uname -s)"
case "$OS" in
    Darwin|Linux) ;;
    *) echo "Unsupported system: $OS (only macOS and Linux)"; exit 1 ;;
esac

command -v curl >/dev/null 2>&1 || { echo "curl is required but not found. Please install it first."; exit 1; }
command -v git  >/dev/null 2>&1 || { echo "git is required but not found. Please install it first."; exit 1; }

# ---- 1. juliaup + Julia ----------------------------------------
if ! command -v juliaup >/dev/null 2>&1 && [ ! -x "$HOME/.juliaup/bin/juliaup" ]; then
    say "Installing juliaup (this also installs the current Julia)"
    curl -fsSL https://install.julialang.org | sh -s -- --yes
else
    say "juliaup already installed"
fi

# make juliaup/julia visible in this script
export PATH="$HOME/.juliaup/bin:$PATH"

say "Making sure the current stable Julia is installed"
juliaup add release >/dev/null 2>&1 || true
juliaup default release

command -v julia >/dev/null 2>&1 || { echo "Julia was not found after installation. Open a new terminal and run this script again."; exit 1; }
julia --version

# ---- 2. packages -----------------------------------------------
say "Installing Geodesics, Seis, DASvader and DASight (this can take several minutes)"
julia -e '
using Pkg
Pkg.add([
    PackageSpec(url="https://github.com/anowacki/Geodesics.jl"),
    PackageSpec(url="https://github.com/anowacki/Seis.jl"),
    PackageSpec(url="https://github.com/marianoarnaiz/DASvader.jl"),
    PackageSpec(url="https://github.com/marianoarnaiz/DASight.jl"),
])
'

# ---- 3. check --------------------------------------------------
say "Checking that DASight loads"
julia -e 'using DASight; println("DASight loaded correctly")'

say "Done. Start Julia with:  julia"
echo "Then try:  using DASight; DASight.install_examples()"
