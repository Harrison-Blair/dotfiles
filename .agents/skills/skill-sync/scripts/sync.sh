#!/usr/bin/env bash

set -euo pipefail

# Pull may update this script. Run a private copy so overwriting the canonical
# file cannot truncate the active Bash program.
if [[ ${SKILL_SYNC_RUNTIME_COPY:-0} != 1 ]]; then
  runtime_script=$(mktemp /tmp/skill-sync-runtime.XXXXXX)
  trap 'rm -f "$runtime_script"' EXIT
  cp "$0" "$runtime_script"
  chmod 700 "$runtime_script"
  if SKILL_SYNC_RUNTIME_COPY=1 "$runtime_script" "$@"; then
    exit 0
  else
    exit $?
  fi
fi

die() {
  printf 'skill-sync: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'Usage: %s {pull|push}\n' "${0##*/}" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
direction=$1
[[ $direction == pull || $direction == push ]] || usage

for command_name in awk cp git ln mkdir readlink; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
done

home_dir=${HOME:?HOME is not set}
repo_dir=$home_dir/source/dotfiles
canonical_dir=$home_dir/.agents/skills
live_claude_dir=$home_dir/.claude/skills
repo_skills_dir=$repo_dir/.agents/skills
repo_claude_dir=$repo_dir/.claude/skills

[[ -d $repo_dir/.git ]] || die "expected Git repository at $repo_dir"
repo_root=$(git -C "$repo_dir" rev-parse --show-toplevel)
[[ $repo_root == "$repo_dir" ]] || die "repository root is $repo_root, expected $repo_dir"

upstream=$(git -C "$repo_dir" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) ||
  die "the current branch has no configured upstream"
remote_name=${upstream%%/*}
push_url=$(git -C "$repo_dir" remote get-url --push "$remote_name") ||
  die "cannot resolve the push URL for $remote_name"

repo_status=$(git -C "$repo_dir" status --porcelain=v1 --untracked-files=all)
managed_status=''
if [[ $direction == pull && -n $repo_status ]]; then
  printf '%s\n' "$repo_status" >&2
  die "dotfiles worktree must be clean before pull"
fi
if [[ $direction == push && -n $repo_status ]]; then
  outside_status=$(git -C "$repo_dir" status --porcelain=v1 --untracked-files=all -- \
    . ':(exclude).agents/skills' ':(exclude).claude/skills')
  if [[ -n $outside_status ]]; then
    printf '%s\n' "$outside_status" >&2
    die "push refuses pending changes outside the managed skill paths"
  fi
  managed_status=$(git -C "$repo_dir" status --porcelain=v1 --untracked-files=all -- \
    .agents/skills .claude/skills)
fi

skill_count=0

validate_skill_dir() {
  local skill_dir=$1
  local directory_name=${skill_dir##*/}
  local declared_name

  [[ $directory_name =~ ^[a-z0-9-]+$ ]] || die "invalid skill directory name: $directory_name"
  [[ -f $skill_dir/SKILL.md ]] || die "missing SKILL.md in $skill_dir"

  declared_name=$(awk '
    NR == 1 && $0 == "---" { frontmatter = 1; next }
    frontmatter && $0 == "---" { exit }
    frontmatter && /^name:[[:space:]]*/ {
      sub(/^name:[[:space:]]*/, "")
      gsub(/^['\''"]|['\''"]$/, "")
      print
      exit
    }
  ' "$skill_dir/SKILL.md")
  [[ $declared_name == "$directory_name" ]] ||
    die "frontmatter name '$declared_name' does not match $directory_name"
}

copy_skills() {
  local source_dir=$1
  local destination_dir=$2
  local source_skill destination_skill
  local found=0

  [[ -d $source_dir ]] || die "skill source does not exist: $source_dir"
  [[ ! -L $destination_dir ]] || die "skill destination is a symlink: $destination_dir"
  mkdir -p "$destination_dir"

  shopt -s nullglob
  for source_skill in "$source_dir"/*; do
    [[ -d $source_skill && -f $source_skill/SKILL.md ]] || continue
    validate_skill_dir "$source_skill"
    destination_skill=$destination_dir/${source_skill##*/}
    [[ ! -L $destination_skill ]] || die "skill destination is a symlink: $destination_skill"
    [[ ! -e $destination_skill || -d $destination_skill ]] ||
      die "skill destination is not a directory: $destination_skill"
    mkdir -p "$destination_skill"
    cp -a "$source_skill/." "$destination_skill/"
    found=$((found + 1))
  done
  shopt -u nullglob

  ((found > 0)) || die "no skills found in $source_dir"
  skill_count=$found
}

ensure_link() {
  local link_path=$1
  local target=$2

  if [[ -L $link_path ]]; then
    [[ $(readlink "$link_path") == "$target" ]] ||
      die "conflicting symlink: $link_path -> $(readlink "$link_path")"
    return
  fi
  [[ ! -e $link_path ]] || die "adapter path already exists and is not a symlink: $link_path"
  ln -s "$target" "$link_path"
}

install_live_claude_links() {
  local skill_dir

  [[ ! -L $live_claude_dir ]] || die "Claude skills directory is a symlink: $live_claude_dir"
  mkdir -p "$live_claude_dir"
  shopt -s nullglob
  for skill_dir in "$canonical_dir"/*; do
    [[ -d $skill_dir && -f $skill_dir/SKILL.md ]] || continue
    validate_skill_dir "$skill_dir"
    ensure_link "$live_claude_dir/${skill_dir##*/}" "$skill_dir"
  done
  shopt -u nullglob
}

install_repo_claude_links() {
  local skill_dir

  [[ ! -L $repo_claude_dir ]] || die "repository Claude skills directory is a symlink: $repo_claude_dir"
  mkdir -p "$repo_claude_dir"
  shopt -s nullglob
  for skill_dir in "$canonical_dir"/*; do
    [[ -d $skill_dir && -f $skill_dir/SKILL.md ]] || continue
    ensure_link "$repo_claude_dir/${skill_dir##*/}" "../../.agents/skills/${skill_dir##*/}"
  done
  shopt -u nullglob
}

printf 'Repository: %s\nUpstream: %s via %s\n' "$repo_dir" "$upstream" "$push_url"
if [[ -z $managed_status ]]; then
  git -C "$repo_dir" pull --ff-only
else
  git -C "$repo_dir" fetch "$remote_name"
  read -r local_ahead remote_ahead < <(
    git -C "$repo_dir" rev-list --left-right --count HEAD..."@{upstream}"
  )
  ((remote_ahead == 0)) ||
    die "upstream is $remote_ahead commit(s) ahead while managed changes are pending"
  printf 'Adopting existing managed skill changes; local branch is %d commit(s) ahead.\n' "$local_ahead"
fi

if [[ $direction == pull ]]; then
  copy_skills "$repo_skills_dir" "$canonical_dir"
  install_live_claude_links
  printf 'Pulled and installed %d skills from %s.\n' "$skill_count" "$repo_dir"
  exit 0
fi

copy_skills "$canonical_dir" "$repo_skills_dir"
install_repo_claude_links
git -C "$repo_dir" add -A -- .agents/skills .claude/skills
git -C "$repo_dir" diff --cached --check

if git -C "$repo_dir" diff --cached --quiet; then
  git -C "$repo_dir" push
  printf 'No skill changes to commit; pushed existing commits to %s.\n' "$upstream"
  exit 0
fi

git -C "$repo_dir" diff --cached --stat
git -C "$repo_dir" commit -m 'sync agent skills'
git -C "$repo_dir" push
git -C "$repo_dir" log -1 --oneline
printf 'Synced %d skills and pushed to %s via %s.\n' "$skill_count" "$upstream" "$push_url"
