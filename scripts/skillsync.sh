#!/usr/bin/env bash
#
# skillsync.sh - pull agent skills from the dotfiles repository onto this machine.
#
# Installs every skill under the repository's .agents/skills into
# ~/.agents/skills and links each one from ~/.claude/skills. Skills with the
# same name are replaced wholesale; everything else on the machine is left
# alone. Needs only bash, git, and coreutils. Works on Linux, macOS, and
# Git Bash on Windows.

set -euo pipefail

# --self-update may overwrite this file while it runs, and bash reads scripts
# incrementally. Run from a private copy so the original can be replaced.
if [[ ${SKILLSYNC_RUNTIME_COPY:-0} != 1 ]]; then
  runtime_copy=$(mktemp "${TMPDIR:-/tmp}/skillsync-runtime.XXXXXX")
  trap 'rm -f "$runtime_copy"' EXIT
  cp "$0" "$runtime_copy"
  chmod 700 "$runtime_copy"
  SKILLSYNC_RUNTIME_COPY=1 SKILLSYNC_SELF_PATH=$0 bash "$runtime_copy" "$@"
  exit $?
fi

repo_url=${SKILLSYNC_REPO:-https://github.com/Harrison-Blair/dotfiles.git}
branch=${SKILLSYNC_BRANCH:-main}
home_dir=${HOME:?HOME is not set}
skills_dir=${SKILLSYNC_SKILLS_DIR:-$home_dir/.agents/skills}
claude_dir=${SKILLSYNC_CLAUDE_DIR:-$home_dir/.claude/skills}
state_file=${SKILLSYNC_STATE_FILE:-$home_dir/.agents/.skillsync-state}
source_dir=''
mode=sync
force=0
self_update=0
self_path=${SKILLSYNC_SELF_PATH:-$0}

usage() {
  cat <<'USAGE' >&2
Usage: skillsync.sh [options]

Pull skills from the dotfiles repository and install them locally.

Options:
  --check            Report whether an update is available; change nothing.
                     Exits 0 when up to date, 3 when an update is available.
  --dry-run          Print the install manifest without writing anything.
  --force            Reinstall even when the recorded commit matches upstream.
  --self-update      After a successful sync, replace this script with the
                     repository's copy if it changed.
  --source DIR       Install from a local checkout instead of cloning.
  --repo URL         Repository to clone (default: Harrison-Blair/dotfiles).
  --branch NAME      Branch to track (default: main).
  --skills-dir DIR   Canonical skills directory (default: ~/.agents/skills).
  --claude-dir DIR   Claude adapter directory (default: ~/.claude/skills).
  --state-file FILE  Where the last synced commit is recorded.
  -h, --help         Show this help.

Environment overrides: SKILLSYNC_REPO, SKILLSYNC_BRANCH, SKILLSYNC_SKILLS_DIR,
SKILLSYNC_CLAUDE_DIR, SKILLSYNC_STATE_FILE.
USAGE
  exit 2
}

die() {
  printf 'skillsync: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'skillsync: warning: %s\n' "$*" >&2
}

need_value() {
  [[ $# -ge 2 && -n $2 ]] || die "$1 requires a value"
}

while (( $# > 0 )); do
  case $1 in
    --check) mode=check ;;
    --dry-run) mode=dry-run ;;
    --force) force=1 ;;
    --self-update) self_update=1 ;;
    --source) need_value "$@"; source_dir=$2; shift ;;
    --repo) need_value "$@"; repo_url=$2; shift ;;
    --branch) need_value "$@"; branch=$2; shift ;;
    --skills-dir) need_value "$@"; skills_dir=$2; shift ;;
    --claude-dir) need_value "$@"; claude_dir=$2; shift ;;
    --state-file) need_value "$@"; state_file=$2; shift ;;
    -h|--help) usage ;;
    *) printf 'skillsync: unknown option: %s\n' "$1" >&2; usage ;;
  esac
  shift
done

for command_name in awk cp diff git mkdir mktemp mv readlink rm; do
  command -v "$command_name" >/dev/null 2>&1 ||
    die "required command not found: $command_name"
done

on_windows=0
case ${OSTYPE:-} in
  msys*|cygwin*) on_windows=1 ;;
esac

# Resolve a directory to an absolute physical path (no readlink -f on macOS).
absolute_dir() {
  (cd -- "$1" 2>/dev/null && pwd -P) || die "not a directory: $1"
}

pretty_path() {
  local path=$1
  if [[ $path == "$home_dir" ]]; then
    printf '~'
  elif [[ $path == "$home_dir"/* ]]; then
    printf '~/%s' "${path#"$home_dir"/}"
  else
    printf '%s' "$path"
  fi
}

read_state_sha() {
  [[ -f $state_file ]] || return 0
  awk -F= '$1 == "sha" { print $2; exit }' "$state_file"
}

write_state() {
  local sha=$1
  mkdir -p -- "$(dirname -- "$state_file")"
  {
    printf 'sha=%s\n' "$sha"
    printf 'source=%s\n' "$2"
    printf 'branch=%s\n' "$branch"
    printf 'synced_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$state_file"
}

# ---------------------------------------------------------------------------
# Locate the source: a local checkout or a fresh shallow clone.
# ---------------------------------------------------------------------------

work_dir=''
cleanup() {
  [[ -n $work_dir && -d $work_dir ]] && rm -rf -- "$work_dir"
  return 0
}
trap cleanup EXIT

remote_sha=''
source_label=''
if [[ -n $source_dir ]]; then
  source_dir=$(absolute_dir "$source_dir")
  source_label=$source_dir
  remote_sha=$(git -C "$source_dir" rev-parse HEAD 2>/dev/null || true)
else
  source_label="$repo_url ($branch)"
  remote_sha=$(git ls-remote --quiet "$repo_url" "refs/heads/$branch" 2>/dev/null | awk '{ print $1; exit }') ||
    true
  [[ -n $remote_sha ]] || die "cannot read branch $branch from $repo_url"
fi

local_sha=$(read_state_sha)
if [[ -n $remote_sha && $remote_sha == "$local_sha" && $force == 0 ]]; then
  printf 'Up to date at %s (%s).\n' "${remote_sha:0:12}" "$source_label"
  exit 0
fi

if [[ $mode == check ]]; then
  if [[ -n $local_sha ]]; then
    printf 'Update available: %s -> %s (%s).\n' \
      "${local_sha:0:12}" "${remote_sha:0:12}" "$source_label"
  else
    printf 'Never synced; %s is at %s.\n' "$source_label" "${remote_sha:0:12}"
  fi
  exit 3
fi

if [[ -z $source_dir ]]; then
  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/skillsync.XXXXXX")
  printf 'Fetching %s ...\n' "$source_label"
  git clone --quiet --depth 1 --branch "$branch" --config core.symlinks=false \
    -- "$repo_url" "$work_dir/repo" || die "clone failed for $repo_url"
  source_dir=$work_dir/repo
  remote_sha=$(git -C "$source_dir" rev-parse HEAD)
fi

repo_skills_dir=$source_dir/.agents/skills
[[ -d $repo_skills_dir ]] || die "no .agents/skills directory in $source_label"

# ---------------------------------------------------------------------------
# Plan.
# ---------------------------------------------------------------------------

skill_names=()
skill_actions=()
link_actions=()
invalid_count=0

frontmatter_name() {
  awk '
    NR == 1 && $0 == "---" { frontmatter = 1; next }
    frontmatter && $0 == "---" { exit }
    frontmatter && /^name:[[:space:]]*/ {
      sub(/^name:[[:space:]]*/, "")
      gsub(/^[\047"]|[\047"]$/, "")
      print
      exit
    }
  ' "$1"
}

validate_skill() {
  local skill_dir=$1
  local name=${skill_dir##*/}
  local declared
  if [[ ! $name =~ ^[a-z0-9-]+$ ]]; then
    warn "skipping $name: directory name must be lowercase letters, digits, hyphens"
    return 1
  fi
  if [[ ! -f $skill_dir/SKILL.md ]]; then
    warn "skipping $name: missing SKILL.md"
    return 1
  fi
  declared=$(frontmatter_name "$skill_dir/SKILL.md")
  if [[ $declared != "$name" ]]; then
    warn "skipping $name: frontmatter name '$declared' does not match directory"
    return 1
  fi
  return 0
}

# Does the Claude adapter already point at the canonical skill?
link_is_current() {
  local link=$1 target=$2 current
  [[ -L $link ]] || return 1
  current=$(readlink "$link") || return 1
  [[ $current == "$target" ]] && return 0
  # Git Bash reports junctions with Windows-style targets; compare loosely.
  if (( on_windows )) && command -v cygpath >/dev/null 2>&1; then
    [[ $(cygpath -u "$current" 2>/dev/null) == "$target" ]] && return 0
  fi
  return 1
}

for skill_dir in "$repo_skills_dir"/*/; do
  [[ -d $skill_dir ]] || continue
  skill_dir=${skill_dir%/}
  name=${skill_dir##*/}
  if ! validate_skill "$skill_dir"; then
    invalid_count=$((invalid_count + 1))
    continue
  fi
  destination=$skills_dir/$name
  if [[ -L $destination || ( -e $destination && ! -d $destination ) ]]; then
    action=REPLACE
  elif [[ ! -e $destination ]]; then
    action=ADD
  elif diff -r -q -- "$skill_dir" "$destination" >/dev/null 2>&1; then
    action=SAME
  else
    action=UPDATE
  fi
  if link_is_current "$claude_dir/$name" "$destination"; then
    link_action=SAME
  elif [[ -e $claude_dir/$name || -L $claude_dir/$name ]]; then
    link_action=RELINK
  else
    link_action=LINK
  fi
  skill_names+=("$name")
  skill_actions+=("$action")
  link_actions+=("$link_action")
done

(( ${#skill_names[@]} > 0 )) || die "no valid skills found in $source_label"

printf 'Source: %s @ %s\n' "$source_label" "${remote_sha:0:12}"
printf 'Skills: %s\nClaude: %s\n\n' "$(pretty_path "$skills_dir")" "$(pretty_path "$claude_dir")"
change_count=0
for i in "${!skill_names[@]}"; do
  name=${skill_names[$i]}
  printf '%-8s %s\n' "${skill_actions[$i]}" "$(pretty_path "$skills_dir/$name")"
  [[ ${skill_actions[$i]} != SAME ]] && change_count=$((change_count + 1))
  if [[ ${link_actions[$i]} != SAME ]]; then
    printf '%-8s %s -> %s\n' "${link_actions[$i]}" \
      "$(pretty_path "$claude_dir/$name")" "$(pretty_path "$skills_dir/$name")"
    change_count=$((change_count + 1))
  fi
done

if [[ $mode == dry-run ]]; then
  printf '\nDry run: %d change(s) would be made; nothing written.\n' "$change_count"
  exit 0
fi

# ---------------------------------------------------------------------------
# Apply.
# ---------------------------------------------------------------------------

mkdir -p -- "$skills_dir" "$claude_dir"

# Replace the whole skill directory. Stage a copy next to the destination so
# the final swap is a rename on the same filesystem.
install_skill() {
  local source=$1 destination=$2
  local parent=${destination%/*} name=${destination##*/}
  local staged=$parent/.skillsync-new-$name old=$parent/.skillsync-old-$name
  rm -rf -- "$staged" "$old"
  cp -R -p -- "$source" "$staged"
  if [[ -e $destination || -L $destination ]]; then
    mv -- "$destination" "$old"
  fi
  mv -- "$staged" "$destination"
  rm -rf -- "$old"
}

# Point $link at $target: symlink first, then a Windows junction, then a copy.
make_link() {
  local link=$1 target=$2
  rm -rf -- "$link"
  if (( on_windows )); then
    if MSYS=winsymlinks:nativestrict ln -s -- "$target" "$link" 2>/dev/null && [[ -L $link ]]; then
      return 0
    fi
    rm -rf -- "$link"
    if command -v cmd >/dev/null 2>&1 && command -v cygpath >/dev/null 2>&1; then
      if cmd //c "mklink /J \"$(cygpath -w "$link")\" \"$(cygpath -w "$target")\"" >/dev/null 2>&1; then
        return 0
      fi
    fi
    rm -rf -- "$link"
    warn "cannot link $(pretty_path "$link"); copying instead"
    cp -R -p -- "$target" "$link"
    return 0
  fi
  ln -s -- "$target" "$link"
}

for i in "${!skill_names[@]}"; do
  name=${skill_names[$i]}
  if [[ ${skill_actions[$i]} != SAME ]]; then
    install_skill "$repo_skills_dir/$name" "$skills_dir/$name"
  fi
  if [[ ${link_actions[$i]} != SAME ]]; then
    make_link "$claude_dir/$name" "$skills_dir/$name"
  fi
done

if (( self_update )); then
  repo_script=$source_dir/scripts/skillsync.sh
  if [[ -f $repo_script && -f $self_path ]] && ! diff -q -- "$repo_script" "$self_path" >/dev/null 2>&1; then
    cp -- "$repo_script" "$self_path"
    chmod +x "$self_path" 2>/dev/null || true
    printf 'SELF     %s updated from repository\n' "$(pretty_path "$self_path")"
  fi
fi

if [[ -n $remote_sha ]]; then
  write_state "$remote_sha" "$source_label"
fi

printf '\nInstalled %d skill(s) with %d change(s) from %s.\n' \
  "${#skill_names[@]}" "$change_count" "$source_label"
if (( invalid_count > 0 )); then
  printf 'skillsync: %d skill(s) skipped as invalid; see warnings above.\n' "$invalid_count" >&2
  exit 1
fi
