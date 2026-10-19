#!/bin/sh
# Resolve and verify the locked DeepSeek Harness upstream source checkout.
#
# Native fnOS/Debian implementation using plain git.
#
# The upstream source is either an explicit checkout (--source-tree, kind
# "override") or the submodule declared in .gitmodules (kind "submodule"). Both
# paths end in the same verification chain: the checkout must be a Git work
# tree, its origin URL, HEAD commit and HEAD tree hash must match the lock, a
# submodule checkout must stay detached at the locked commit, and the working
# tree must be clean because local deltas belong in
# apps/deepseek-harness/patches.
#
# Only git object hashes are read here, through `git rev-parse`. The blob-level
# SHA-256 checks of pnpm-lock.yaml and apps/cli/package.json belong to
# build-fpk.sh and are not duplicated by this script.
#
# usage: resolve-upstream-source.sh --repository-root DIR
#          --expected-repository URL --expected-commit SHA --expected-tree SHA
#          [--source-tree DIR] [--allow-download]
#          [--submodule-name NAME] [--submodule-path PATH]
set -u

usage() {
    cat <<'USAGE'
usage: resolve-upstream-source.sh --repository-root DIR --expected-repository URL
       --expected-commit SHA --expected-tree SHA [--source-tree DIR]
       [--allow-download] [--submodule-name NAME] [--submodule-path PATH]

  --repository-root DIR       superproject checkout carrying .gitmodules (required)
  --expected-repository URL   locked upstream repository URL (required)
  --expected-commit SHA       locked upstream commit (required)
  --expected-tree SHA         locked upstream tree hash (required)
  --source-tree DIR           verify this checkout instead of the submodule
  --allow-download            clone the locked submodule when it is uninitialized
  --submodule-name NAME       submodule name in .gitmodules (default deepseek-harness)
  --submodule-path PATH       submodule path in .gitmodules
                              (default vendor/upstream/deepseek-harness)
  -h, --help                  print this message
USAGE
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

usage_error() {
    printf 'ERROR: %s\n' "$*" >&2
    usage >&2
    exit 64
}

# --- git helpers -------------------------------------------------------------

normalize_git_remote() {
    # Normalize to forward slashes, remove trailing slash and .git, then
    # lowercase. Lowercasing first keeps .GIT equivalent to .git.
    _url=$1
    printf '%s' "$_url" |
        sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' |
        tr '\\' '/' |
        tr '[:upper:]' '[:lower:]' |
        sed -e 's|/*$||' -e 's|\.git$||'
}

resolve_existing_path() {
    # Print the physical absolute path of an existing path; return 1 when it is
    # missing. Never exits: the caller owns the diagnostic.
    _target=$1
    if [ ! -e "$_target" ]; then
        return 1
    fi
    if [ -d "$_target" ]; then
        _resolved=$(CDPATH= cd -- "$_target" 2>/dev/null && pwd -P) || return 1
    else
        _parent=$(dirname -- "$_target") || return 1
        _base=$(basename -- "$_target") || return 1
        _resolved=$(CDPATH= cd -- "$_parent" 2>/dev/null && pwd -P) || return 1
        _resolved=$_resolved/$_base
    fi
    printf '%s\n' "$_resolved"
}

GIT_OUTPUT=''

run_git() {
    # run_git <failure-message> <working-directory> <git-argument>...
    # Puts the trimmed combined output in GIT_OUTPUT and exits with a
    # diagnostic when git fails. The result travels through a variable because
    # a command substitution would turn the exit into a subshell exit.
    _message=$1
    _directory=$2
    shift 2
    _git_output=$(git -C "$_directory" "$@" 2>&1)
    _git_status=$?
    if [ "$_git_status" -ne 0 ]; then
        die "$_message (exit $_git_status): $_git_output"
    fi
    # Drop surrounding whitespace while preserving inner lines.
    GIT_OUTPUT=$(printf '%s' "$_git_output" |
        sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
}

initialize_locked_submodule() {
    # initialize_locked_submodule <repository-root> <submodule-root> <repository> <commit> <submodule-path>
    _root=$1
    _submodule_root=$2
    _repository=$3
    _commit=$4
    _submodule_path=$5

    if [ -e "$_submodule_root" ]; then
        if [ -n "$(ls -A -- "$_submodule_root" 2>/dev/null)" ]; then
            die "The upstream submodule path exists but is not a Git checkout: $_submodule_path"
        fi
    else
        mkdir -p -- "$(dirname -- "$_submodule_root")" ||
            die "Unable to create the upstream submodule parent directory: $(dirname -- "$_submodule_root")"
    fi

    _clone_output=$(git -C "$_root" clone --no-checkout -- "$_repository" "$_submodule_root" 2>&1)
    _clone_status=$?
    [ "$_clone_status" -eq 0 ] ||
        die "Unable to clone the upstream submodule (exit $_clone_status): $_clone_output"

    _checkout_output=$(git -C "$_submodule_root" checkout --detach "$_commit" 2>&1)
    _checkout_status=$?
    [ "$_checkout_status" -eq 0 ] ||
        die "Unable to checkout the locked upstream submodule commit (exit $_checkout_status): $_checkout_output"
}

# --- arguments ---------------------------------------------------------------

repository_root=''
source_tree=''
allow_download=0
expected_repository=''
expected_commit=''
expected_tree=''
submodule_name='deepseek-harness'
submodule_path='vendor/upstream/deepseek-harness'

while [ "$#" -gt 0 ]; do
    case "$1" in
        --repository-root)
            [ "$#" -ge 2 ] || usage_error '--repository-root requires a value'
            repository_root=$2
            shift 2
            ;;
        --source-tree)
            [ "$#" -ge 2 ] || usage_error '--source-tree requires a value'
            source_tree=$2
            shift 2
            ;;
        --expected-repository)
            [ "$#" -ge 2 ] || usage_error '--expected-repository requires a value'
            expected_repository=$2
            shift 2
            ;;
        --expected-commit)
            [ "$#" -ge 2 ] || usage_error '--expected-commit requires a value'
            expected_commit=$2
            shift 2
            ;;
        --expected-tree)
            [ "$#" -ge 2 ] || usage_error '--expected-tree requires a value'
            expected_tree=$2
            shift 2
            ;;
        --submodule-name)
            [ "$#" -ge 2 ] || usage_error '--submodule-name requires a value'
            submodule_name=$2
            shift 2
            ;;
        --submodule-path)
            [ "$#" -ge 2 ] || usage_error '--submodule-path requires a value'
            submodule_path=$2
            shift 2
            ;;
        --allow-download)
            allow_download=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage_error "unknown argument: $1"
            ;;
    esac
done

[ -n "$repository_root" ] || usage_error '--repository-root is required'
[ -n "$expected_repository" ] || usage_error '--expected-repository is required'
[ -n "$expected_commit" ] || usage_error '--expected-commit is required'
[ -n "$expected_tree" ] || usage_error '--expected-tree is required'

command -v git >/dev/null 2>&1 || die 'git is required to resolve the upstream source.'

# --- source resolution -------------------------------------------------------

resolved_repository_root=$(resolve_existing_path "$repository_root") ||
    die "The repository root does not exist: $repository_root"
normalized_submodule_path=$(printf '%s' "$submodule_path" | tr '\\' '/')
source_kind='override'

if [ -n "$source_tree" ]; then
    resolved_source=$(resolve_existing_path "$source_tree") ||
        die "The source tree does not exist: $source_tree"
else
    source_kind='submodule'
    gitmodules_path=$resolved_repository_root/.gitmodules
    [ -f "$gitmodules_path" ] ||
        die "The upstream submodule declaration is missing: $gitmodules_path"

    configured_path=$(git config -f "$gitmodules_path" --get "submodule.$submodule_name.path" 2>/dev/null)
    configured_path_status=$?
    if [ "$configured_path_status" -ne 0 ] ||
        [ "$(printf '%s' "$configured_path" | tr '\\' '/')" != "$normalized_submodule_path" ]; then
        die "The $submodule_name submodule path must be $normalized_submodule_path."
    fi

    configured_url=$(git config -f "$gitmodules_path" --get "submodule.$submodule_name.url" 2>/dev/null)
    configured_url_status=$?
    if [ "$configured_url_status" -ne 0 ] ||
        [ "$(normalize_git_remote "$configured_url")" != "$(normalize_git_remote "$expected_repository")" ]; then
        die "The $submodule_name submodule URL must be $expected_repository."
    fi

    git config -f "$gitmodules_path" --get "submodule.$submodule_name.branch" >/dev/null 2>&1
    configured_branch_status=$?
    if [ "$configured_branch_status" -eq 0 ]; then
        die "The $submodule_name submodule must pin a commit without a tracking branch."
    fi
    if [ "$configured_branch_status" -ne 1 ]; then
        die "Unable to inspect the $submodule_name submodule branch declaration."
    fi

    run_git 'Unable to read the upstream submodule gitlink' "$resolved_repository_root" \
        ls-files --stage -- "$normalized_submodule_path"
    gitlink_commit=$(printf '%s\n' "$GIT_OUTPUT" | head -n 1 |
        sed -n 's/^160000[[:space:]]\{1,\}\([0-9a-f]\{40\}\)[[:space:]]\{1,\}[0-9]\{1,\}[[:space:]].*$/\1/p')
    [ -n "$gitlink_commit" ] ||
        die "The upstream source path is not a tracked Git submodule: $normalized_submodule_path"
    [ "$gitlink_commit" = "$expected_commit" ] ||
        die "Submodule gitlink mismatch. Expected $expected_commit, got $gitlink_commit"

    # The checkout is joined on the normalized path: a backslash is a literal
    # character on Linux, so the raw --submodule-path value must not be used.
    submodule_root=$resolved_repository_root/$normalized_submodule_path
    if [ ! -e "$submodule_root/.git" ]; then
        if [ "$allow_download" -eq 0 ]; then
            die "The upstream submodule is not initialized. Run 'git submodule update --init -- $normalized_submodule_path' or pass --allow-download."
        fi
        initialize_locked_submodule "$resolved_repository_root" "$submodule_root" \
            "$expected_repository" "$expected_commit" "$normalized_submodule_path"
    fi
    resolved_source=$(resolve_existing_path "$submodule_root") ||
        die "Unable to resolve the upstream submodule path: $submodule_root"
fi

# --- checkout verification ---------------------------------------------------

[ -e "$resolved_source/.git" ] ||
    die "The DeepSeek Harness source must be a Git checkout: $resolved_source"
run_git 'Unable to inspect the source checkout' "$resolved_source" rev-parse --is-inside-work-tree
[ "$GIT_OUTPUT" = 'true' ] ||
    die "The DeepSeek Harness source is not a Git working tree: $resolved_source"

run_git 'Unable to read the source commit' "$resolved_source" rev-parse HEAD
source_commit=$GIT_OUTPUT
run_git 'Unable to read the source tree' "$resolved_source" rev-parse 'HEAD^{tree}'
source_tree_hash=$GIT_OUTPUT
run_git 'Unable to read the source origin' "$resolved_source" remote get-url origin
source_remote=$GIT_OUTPUT

[ "$source_commit" = "$expected_commit" ] ||
    die "Source commit mismatch. Expected $expected_commit, got $source_commit"
[ "$source_tree_hash" = "$expected_tree" ] ||
    die "Source tree mismatch. Expected $expected_tree, got $source_tree_hash"
[ "$(normalize_git_remote "$source_remote")" = "$(normalize_git_remote "$expected_repository")" ] ||
    die "Source origin mismatch. Expected $expected_repository, got $source_remote"

if [ "$source_kind" = 'submodule' ]; then
    source_branch=$(git -C "$resolved_source" symbolic-ref --quiet --short HEAD 2>&1)
    detached_status=$?
    if [ "$detached_status" -eq 0 ]; then
        die "The upstream submodule must remain detached at $expected_commit, but it is on branch $source_branch."
    fi
    if [ "$detached_status" -ne 1 ]; then
        die 'Unable to inspect whether the upstream submodule is detached.'
    fi
fi

run_git 'Unable to inspect source working-tree status' "$resolved_source" \
    status --porcelain=v1 --untracked-files=normal
if [ -n "$GIT_OUTPUT" ]; then
    status_preview=$(printf '%s\n' "$GIT_OUTPUT" | head -n 10 |
        awk 'NR == 1 { printf "%s", $0; next } { printf "; %s", $0 }')
    die "The upstream source checkout must be clean because local changes are not build inputs. Store deltas in apps/deepseek-harness/patches instead. Status: $status_preview"
fi

printf 'Path=%s\n' "$resolved_source"
printf 'Kind=%s\n' "$source_kind"
printf 'Repository=%s\n' "$source_remote"
printf 'Commit=%s\n' "$source_commit"
printf 'Tree=%s\n' "$source_tree_hash"
