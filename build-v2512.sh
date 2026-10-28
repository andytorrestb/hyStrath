#!/usr/bin/env bash
#------------------------------------------------------------------------------
# build-v2512.sh
#
# Non-interactive, fail-fast, in-place build entry point for hyStrath against
# OpenCFD OpenFOAM v2512.
#
# Replaces the copy-first interactive install.sh / build/install-*.sh path:
#   - builds directly from this checkout (no copy into WM_PROJECT_USER_DIR)
#   - validates the sourced OpenFOAM environment before doing anything
#   - refuses to run on a case-insensitive filesystem (see PREFLIGHT below)
#   - dependency-ordered manifests instead of timed progress bars
#   - exit status is the build result; no success-string parsing
#
# Usage:
#   ./build-v2512.sh --module dsmc --clean --jobs 8
#   ./build-v2512.sh --module all --dry-run
#
#------------------------------------------------------------------------------
set -euo pipefail

readonly REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REQUIRED_API=2512
readonly REQUIRED_VERSION="v2512"

MODULE=""
JOBS=1
DO_CLEAN=0
DRY_RUN=0
ALLOW_UNSUPPORTED=0
LOG_FILE=""

#------------------------------------------------------------------------------
# Build manifests.
#
# Each entry is "<relative-path>|<command>", executed in order from REPO_DIR.
# <command> is one of:
#   libso        -> wclean libso   / wmake -j N libso
#   all          -> wclean all     / wmake -j N all
#   exe          -> wclean         / wmake -j N
#   script:<name>[:<clean>]
#                -> build with ./<name> -j N
#                   <clean> is either the name of a clean script (./<clean>)
#                   or '@all' / '@libso' meaning 'wclean all' / 'wclean libso'
#                   for directories that ship no Allwclean.
#
# Order is derived from build/install-{CFD,DSMC,hybridPICDSMC}.sh and must stay
# dependency-ordered: leaves first.
#
# NOTE: src/functionObjects/Allwmake-{dsmc,cfd}Strath are deliberately NOT used.
# Those scripts assign makeType=${1:-libso} but then invoke `wmake $targetType`,
# an undefined variable, so any -j argument is silently dropped and the builds
# are always serial. The subdirectories they wrap are listed directly instead,
# which also makes a failure name the exact library.
#------------------------------------------------------------------------------

# DSMC: lagrangian/basic is the leaf every discrete-method target depends on.
readonly MANIFEST_DSMC=(
    "src/lagrangian|script:Allwmake:@all"
    "src/parallel/decompose/decompose|libso"
    "src/parallel/reconstruct|script:Allwmake:@all"
    "src/functionObjects/field-dsmcStrath|libso"
    "src/functionObjects/lagrangian|libso"
    "applications/solvers/discreteMethods/dsmc|script:wmakeAll:wcleanAll"
    "applications/solvers/discreteMethods/molecularDynamics/mdEquilibrationFoam|exe"
    "applications/solvers/discreteMethods/molecularDynamics/mdFoam|exe"
    "applications/utilities/preProcessing/mapFields|exe"
    "applications/utilities/preProcessing/mapFieldsPar|exe"
    "applications/utilities/preProcessing/dsmc|script:wmakeAll:wcleanAll"
    "applications/utilities/parallelProcessing|all"
    "applications/utilities/postProcessing/miscellaneous/foamListTimes|exe"
    "applications/utilities/mesh/generation/makeAxialMesh|exe"
    "applications/utilities/mesh/generation/blockMeshDG|script:Allwmake:@all"
)

readonly MANIFEST_CFD=(
    "src/thermophysicalModels/strath|script:Allwmake:Allwclean"
    "src/TurbulenceModels|script:Allwmake:@all"
    "src/thermophysicalModels/strath|script:AllwmakeBis"
    "src/hTCModels|libso"
    "src/mhdModels|libso"
    "src/finiteVolume|libso"
    "src/functionObjects/forces|libso"
    "src/functionObjects/field-cfdStrath|libso"
    "src/fvOptions|libso"
    "applications/solvers/compressible/hy2Foam|script:Allwmake:Allwclean"
    "applications/utilities/mesh/generation/makeAxialMesh|exe"
    "applications/utilities/mesh/generation/blockMeshDG|script:Allwmake:@all"
)

# PIC depends on a built DSMC module (lagrangian/basic + dsmc).
readonly MANIFEST_PIC=(
    "src/lagrangian/regionsAndInterfaces|libso"
    "src/lagrangian/pic|libso"
    "applications/solvers/hybridMethods/pdFoam|exe"
    "applications/utilities/preProcessing/hybrid/pdInitialise|all"
)

#------------------------------------------------------------------------------

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '[build-v2512] %s\n' "$*"; }

usage() {
    cat <<'EOF'
Usage: build-v2512.sh --module <cfd|dsmc|pic|all> [options]

Options:
  --module <name>   Module to build: cfd, dsmc, pic, or all (required)
  --jobs N          Parallel compile jobs (default: 1)
  --clean           wclean each target before building
  --dry-run         Print the ordered build plan and exit without building
  --log FILE        Write the full build log here
                    (default: build-v2512-<module>-<timestamp>.log)
  --allow-unsupported-openfoam
                    Bypass the strict v2512 environment check. Unsupported.
  -h, --help        Show this message

Module dependencies:
  pic requires dsmc to have been built first (shared lagrangian libraries).
  'all' builds cfd, then dsmc, then pic in that order.

Exit status is the build result. Nonzero means at least one target failed;
the failing target is named on stderr.
EOF
}

#------------------------------------------------------------------------------
# Argument parsing
#------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --module)  [[ $# -ge 2 ]] || die "--module requires an argument"
                   MODULE="$2"; shift 2 ;;
        --jobs)    [[ $# -ge 2 ]] || die "--jobs requires an argument"
                   JOBS="$2"; shift 2 ;;
        --log)     [[ $# -ge 2 ]] || die "--log requires an argument"
                   LOG_FILE="$2"; shift 2 ;;
        --clean)   DO_CLEAN=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --allow-unsupported-openfoam) ALLOW_UNSUPPORTED=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *)         die "unknown argument: $1 (try --help)" ;;
    esac
done

[[ -n "$MODULE" ]] || { usage >&2; die "--module is required"; }

case "$MODULE" in
    cfd|dsmc|pic|all) ;;
    *) die "invalid module '$MODULE' (expected: cfd, dsmc, pic, all)" ;;
esac

[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive integer, got '$JOBS'"

#------------------------------------------------------------------------------
# PREFLIGHT
#------------------------------------------------------------------------------
preflight() {
    # --- OpenFOAM environment sourced? -------------------------------------
    [[ -n "${WM_PROJECT:-}" ]] \
        || die "OpenFOAM environment not sourced (WM_PROJECT unset).
       Run: source /usr/lib/openfoam/openfoam${REQUIRED_API}/etc/bashrc"

    [[ "$WM_PROJECT" == "OpenFOAM" ]] \
        || die "WM_PROJECT is '$WM_PROJECT', expected 'OpenFOAM'"

    # --- Correct flavour and version? --------------------------------------
    # OpenCFD releases set FOAM_API (2512). The OpenFOAM Foundation line does
    # not, which is how we tell the two apart.
    if [[ $ALLOW_UNSUPPORTED -eq 0 ]]; then
        [[ -n "${FOAM_API:-}" ]] \
            || die "FOAM_API is unset. This looks like an OpenFOAM Foundation
       build, not an OpenCFD release. hyStrath v2512 support targets
       OpenCFD OpenFOAM $REQUIRED_VERSION.
       Override with --allow-unsupported-openfoam (unsupported)."

        [[ "$FOAM_API" == "$REQUIRED_API" ]] \
            || die "FOAM_API is '$FOAM_API', expected '$REQUIRED_API'.
       Override with --allow-unsupported-openfoam (unsupported)."

        [[ "${WM_PROJECT_VERSION:-}" == "$REQUIRED_VERSION" ]] \
            || die "WM_PROJECT_VERSION is '${WM_PROJECT_VERSION:-unset}', expected '$REQUIRED_VERSION'.
       Override with --allow-unsupported-openfoam (unsupported)."
    else
        info "WARNING: strict OpenFOAM version check bypassed (--allow-unsupported-openfoam)."
        info "WARNING: FOAM_API=${FOAM_API:-unset} WM_PROJECT_VERSION=${WM_PROJECT_VERSION:-unset}"
    fi

    # --- Required paths and tools ------------------------------------------
    [[ -n "${WM_PROJECT_DIR:-}" && -d "$WM_PROJECT_DIR" ]] \
        || die "WM_PROJECT_DIR is unset or not a directory: '${WM_PROJECT_DIR:-}'"

    command -v wmake  >/dev/null 2>&1 || die "'wmake' not found on PATH"
    command -v wclean >/dev/null 2>&1 || die "'wclean' not found on PATH"

    for var in FOAM_USER_APPBIN FOAM_USER_LIBBIN; do
        [[ -n "${!var:-}" ]] || die "$var is unset"
        mkdir -p -- "${!var}" \
            || die "cannot create $var directory: ${!var}"
        [[ -w "${!var}" ]] || die "$var is not writable: ${!var}"
    done

    # --- The OpenFOAM installation must not be a build target --------------
    # Guards against targets that write into FOAM_LIBBIN / FOAM_APPBIN.
    case "$REPO_DIR/" in
        "$WM_PROJECT_DIR"/*)
            die "this checkout lives inside WM_PROJECT_DIR ($WM_PROJECT_DIR).
       Move it outside the OpenFOAM installation before building." ;;
    esac

    # --- Case-sensitive filesystem -----------------------------------------
    # OpenFOAM's headers rely on case to distinguish, e.g., cloud.H from
    # Cloud.H. wmake's flat lnInclude directories put both names in one
    # directory, so on a case-insensitive filesystem (NTFS via /mnt/c, or
    # macOS default APFS) #include "cloud.H" silently resolves to Cloud.H.
    # That produces a flood of misleading "class has no member" errors that
    # look like API drift but are pure filesystem artifacts.
    local probe insensitive=0
    probe="$(mktemp -d "$REPO_DIR/.casecheck.XXXXXX")" \
        || die "cannot create a temporary directory under $REPO_DIR"
    : > "$probe/CaseSensitivityProbe"
    [[ -e "$probe/casesensitivityprobe" ]] && insensitive=1
    rm -rf -- "$probe"

    if [[ $insensitive -eq 1 ]]; then
        die "this checkout is on a CASE-INSENSITIVE filesystem: $REPO_DIR

       OpenFOAM cannot be built here. wmake's flat lnInclude directories
       contain both 'cloud.H' and 'Cloud.H'; without case sensitivity the
       wrong header is included and the build fails with errors that look
       like API incompatibilities but are not.

       Fix: build from a case-sensitive filesystem. Under WSL, clone into
       the Linux filesystem rather than building under /mnt/c:

           git clone <this-repo> ~/hyStrath && cd ~/hyStrath"
    fi
}

#------------------------------------------------------------------------------
# Environment report (recorded at the top of every log)
#------------------------------------------------------------------------------
environment_report() {
    cat <<EOF
================================================================================
 hyStrath build for OpenFOAM v2512
================================================================================
 date              : $(date -Is)
 repo              : $REPO_DIR
 git commit        : $(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo 'not a git repo')
 git status        : $(git -C "$REPO_DIR" status --porcelain 2>/dev/null | wc -l) modified file(s)
 module            : $MODULE
 jobs              : $JOBS
 clean             : $DO_CLEAN
--------------------------------------------------------------------------------
 WM_PROJECT        : ${WM_PROJECT:-}
 WM_PROJECT_VERSION: ${WM_PROJECT_VERSION:-}
 FOAM_API          : ${FOAM_API:-}
 WM_OPTIONS        : ${WM_OPTIONS:-}
 WM_PROJECT_DIR    : ${WM_PROJECT_DIR:-}
 FOAM_USER_LIBBIN  : ${FOAM_USER_LIBBIN:-}
 FOAM_USER_APPBIN  : ${FOAM_USER_APPBIN:-}
 compiler          : $(${CXX:-g++} --version 2>/dev/null | head -1)
 mpi               : $(mpirun --version 2>/dev/null | head -1)
 uname             : $(uname -sr)
================================================================================
EOF
}

#------------------------------------------------------------------------------
# Target execution
#------------------------------------------------------------------------------
manifest_for() {
    case "$1" in
        dsmc) printf '%s\n' "${MANIFEST_DSMC[@]}" ;;
        cfd)  printf '%s\n' "${MANIFEST_CFD[@]}" ;;
        pic)  printf '%s\n' "${MANIFEST_PIC[@]}" ;;
    esac
}

# build_target <relative-dir> <command>
build_target() {
    local rel="$1" cmd="$2"
    local dir="$REPO_DIR/$rel"

    [[ -d "$dir" ]] || die "target directory missing: $rel"

    case "$cmd" in
        libso|all)
            if [[ $DO_CLEAN -eq 1 ]]; then
                ( cd -- "$dir" && wclean "$cmd" ) || true
            fi
            ( cd -- "$dir" && wmake -j "$JOBS" "$cmd" )
            ;;
        exe)
            if [[ $DO_CLEAN -eq 1 ]]; then
                ( cd -- "$dir" && wclean ) || true
            fi
            ( cd -- "$dir" && wmake -j "$JOBS" )
            ;;
        script:*)
            local rest="${cmd#script:}"
            local make_script="${rest%%:*}"
            local clean_script=""
            [[ "$rest" == *:* ]] && clean_script="${rest#*:}"

            [[ -x "$dir/$make_script" ]] \
                || die "build script not executable: $rel/$make_script"

            if [[ $DO_CLEAN -eq 1 && -n "$clean_script" ]]; then
                # wclean on a never-built target is harmless but nonzero,
                # so a failed clean must not abort the build.
                if [[ "$clean_script" == @* ]]; then
                    ( cd -- "$dir" && wclean "${clean_script#@}" ) || true
                elif [[ -x "$dir/$clean_script" ]]; then
                    ( cd -- "$dir" && "./$clean_script" ) || true
                else
                    die "clean script not executable: $rel/$clean_script"
                fi
            fi
            ( cd -- "$dir" && "./$make_script" -j "$JOBS" )
            ;;
        *)
            die "internal: unknown manifest command '$cmd' for $rel"
            ;;
    esac
}

build_module() {
    local module="$1"
    local -a entries
    mapfile -t entries < <(manifest_for "$module")

    local total="${#entries[@]}"
    local n=0 entry rel cmd

    info "=== module '$module': $total target(s) ==="

    for entry in "${entries[@]}"; do
        n=$((n + 1))
        rel="${entry%%|*}"
        cmd="${entry#*|}"

        info "[$module $n/$total] $rel ($cmd)"

        if ! build_target "$rel" "$cmd"; then
            printf '\n' >&2
            printf 'FAILED TARGET : %s\n' "$rel" >&2
            printf 'FAILED COMMAND: %s\n' "$cmd" >&2
            printf 'MODULE        : %s (target %d of %d)\n' "$module" "$n" "$total" >&2
            [[ -n "$LOG_FILE" ]] && printf 'FULL LOG      : %s\n' "$LOG_FILE" >&2
            return 1
        fi
    done

    info "=== module '$module': all $total target(s) built ==="
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------
main() {
    local -a modules
    if [[ "$MODULE" == "all" ]]; then
        modules=(cfd dsmc pic)
    else
        modules=("$MODULE")
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        environment_report
        local m entry n
        for m in "${modules[@]}"; do
            printf '\n--- module: %s ---\n' "$m"
            n=0
            while IFS= read -r entry; do
                n=$((n + 1))
                printf '  %2d. %-62s %s\n' "$n" "${entry%%|*}" "${entry#*|}"
            done < <(manifest_for "$m")
        done
        printf '\nDry run: nothing was built.\n'
        return 0
    fi

    local m
    for m in "${modules[@]}"; do
        build_module "$m"
    done

    info "build complete: ${modules[*]}"
    [[ -n "$LOG_FILE" ]] && info "log: $LOG_FILE"
    return 0
}

# Validate the environment BEFORE touching the filesystem or running the
# (potentially slow) environment report. In particular the case-sensitivity
# guard must fire before anything walks the repository.
preflight

# Tee everything to a log unless already running under one.
if [[ -z "${_BUILD_V2512_LOGGING:-}" && $DRY_RUN -eq 0 ]]; then
    if [[ -z "$LOG_FILE" ]]; then
        LOG_FILE="$REPO_DIR/build-v2512-${MODULE}-$(date +%Y%m%d-%H%M%S).log"
    fi
    export _BUILD_V2512_LOGGING=1
    environment_report | tee "$LOG_FILE"
    # Preserve the pipeline's exit status through tee.
    set -o pipefail
    main 2>&1 | tee -a "$LOG_FILE"
    exit "${PIPESTATUS[0]}"
else
    main
fi
