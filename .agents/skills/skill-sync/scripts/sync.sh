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
  printf 'Usage: %s {pull|push} [--yes]\n' "${0##*/}" >&2
  exit 2
}

(( $# == 1 || $# == 2 )) || usage
direction=$1
[[ $direction == pull || $direction == push ]] || usage
assume_yes=0
if (( $# == 2 )); then
  [[ $2 == --yes ]] || usage
  assume_yes=1
fi

for command_name in awk cmp cp find git ln mkdir mktemp readlink stat; do
  command -v "$command_name" >/dev/null 2>&1 ||
    die "required command not found: $command_name"
done

home_dir=${HOME:?HOME is not set}
repo_dir=$home_dir/source/dotfiles
canonical_dir=$home_dir/.agents/skills
live_claude_dir=$home_dir/.claude/skills
repo_skills_dir=$repo_dir/.agents/skills
repo_claude_dir=$repo_dir/.claude/skills

[[ -d $repo_dir/.git ]] || die "expected Git repository at $repo_dir"
repo_root=$(git -C "$repo_dir" rev-parse --show-toplevel)
[[ $repo_root == "$repo_dir" ]] ||
  die "repository root is $repo_root, expected $repo_dir"

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

printf 'Repository: %s\nUpstream: %s via %s\n' "$repo_dir" "$upstream" "$push_url"
if [[ -z $managed_status ]]; then
  git -C "$repo_dir" pull --ff-only
else
  git -C "$repo_dir" fetch "$remote_name"
  read -r local_ahead remote_ahead < <(
    git -C "$repo_dir" rev-list --left-right --count HEAD..."@{upstream}"
  )
  (( remote_ahead == 0 )) ||
    die "upstream is $remote_ahead commit(s) ahead while managed changes are pending"
  printf 'Adopting existing managed skill changes; local branch is %d commit(s) ahead.\n' \
    "$local_ahead"
fi

declare -a planned_actions=()
declare -a planned_kinds=()
declare -a planned_sources=()
declare -a planned_destinations=()
declare -a planned_display_paths=()
declare -a planned_destination_directories=()
skill_count=0

pretty_path() {
  local path=$1

  if [[ $path == "$repo_dir" ]]; then
    printf '.'
  elif [[ $path == "$repo_dir"/* ]]; then
    printf '%s' "${path#"$repo_dir"/}"
  elif [[ $path == "$home_dir" ]]; then
    printf '~'
  elif [[ $path == "$home_dir"/* ]]; then
    printf '~/%s' "${path#"$home_dir"/}"
  else
    printf '%s' "$path"
  fi
}

validate_skill_dir() {
  local skill_dir=$1
  local directory_name=${skill_dir##*/}
  local declared_name

  [[ $directory_name =~ ^[a-z0-9-]+$ ]] ||
    die "invalid skill directory name: $directory_name"
  [[ -f $skill_dir/SKILL.md ]] || die "missing SKILL.md in $skill_dir"

  declared_name=$(awk '
    NR == 1 && $0 == "---" { frontmatter = 1; next }
    frontmatter && $0 == "---" { exit }
    frontmatter && /^name:[[:space:]]*/ {
      sub(/^name:[[:space:]]*/, "")
      gsub(/^[\047"]|[\047"]$/, "")
      print
      exit
    }
  ' "$skill_dir/SKILL.md")
  [[ $declared_name == "$directory_name" ]] ||
    die "frontmatter name '$declared_name' does not match $directory_name"
}

add_planned_change() {
  local action=$1
  local kind=$2
  local source=$3
  local destination=$4

  planned_actions+=("$action")
  planned_kinds+=("$kind")
  planned_sources+=("$source")
  planned_destinations+=("$destination")
  planned_display_paths+=("$(pretty_path "$destination")")
}

plan_directory() {
  local destination=$1

  if [[ -L $destination || ( -e $destination && ! -d $destination ) ]]; then
    die "directory type conflict: $(pretty_path "$destination")"
  fi
  planned_destination_directories+=("$destination")
}

plan_regular_file() {
  local source=$1
  local destination=$2

  if [[ -L $destination || ( -e $destination && ! -f $destination ) ]]; then
    die "file type conflict: $(pretty_path "$destination")"
  fi
  if [[ ! -e $destination ]]; then
    add_planned_change ADD file "$source" "$destination"
    return
  fi
  if ! cmp -s -- "$source" "$destination" ||
    [[ $(stat -c '%a' -- "$source") != $(stat -c '%a' -- "$destination") ]]; then
    add_planned_change UPDATE file "$source" "$destination"
  fi
}

plan_source_link() {
  local source=$1
  local destination=$2
  local source_target

  source_target=$(readlink "$source")
  if [[ -L $destination ]]; then
    if [[ $(readlink "$destination") != "$source_target" ]]; then
      add_planned_change UPDATE source-link "$source" "$destination"
    fi
    return
  fi
  [[ ! -e $destination ]] ||
    die "symlink type conflict: $(pretty_path "$destination")"
  add_planned_change ADD source-link "$source" "$destination"
}

plan_skills() {
  local source_dir=$1
  local destination_dir=$2
  local source_skill destination_skill unsupported_path source_path relative_path
  local found=0

  [[ -d $source_dir ]] || die "skill source does not exist: $source_dir"
  if [[ -L $destination_dir || ( -e $destination_dir && ! -d $destination_dir ) ]]; then
    die "skill destination is not a directory: $destination_dir"
  fi
  plan_directory "$destination_dir"

  shopt -s nullglob
  for source_skill in "$source_dir"/*; do
    [[ -d $source_skill && -f $source_skill/SKILL.md ]] || continue
    [[ ! -L $source_skill ]] || die "skill source is a symlink: $source_skill"
    validate_skill_dir "$source_skill"
    destination_skill=$destination_dir/${source_skill##*/}
    if [[ -L $destination_skill || ( -e $destination_skill && ! -d $destination_skill ) ]]; then
      die "skill destination is not a directory: $destination_skill"
    fi

    unsupported_path=$(find "$source_skill" ! -type d ! -type f ! -type l -print -quit)
    [[ -z $unsupported_path ]] || die "unsupported skill entry: $unsupported_path"

    while IFS= read -r -d '' source_path; do
      relative_path=${source_path#"$source_dir"/}
      plan_directory "$destination_dir/$relative_path"
    done < <(find "$source_skill" -type d -print0)

    while IFS= read -r -d '' source_path; do
      relative_path=${source_path#"$source_dir"/}
      if [[ -L $source_path ]]; then
        plan_source_link "$source_path" "$destination_dir/$relative_path"
      else
        plan_regular_file "$source_path" "$destination_dir/$relative_path"
      fi
    done < <(find "$source_skill" \( -type f -o -type l \) -print0)
    found=$((found + 1))
  done
  shopt -u nullglob

  (( found > 0 )) || die "no skills found in $source_dir"
  skill_count=$found
}

plan_adapter_link() {
  local link_path=$1
  local target=$2
  local index

  for index in "${!planned_destinations[@]}"; do
    if [[ ${planned_kinds[$index]} == adapter &&
      ${planned_destinations[$index]} == "$link_path" ]]; then
      [[ ${planned_sources[$index]} == "$target" ]] ||
        die "conflicting planned adapter target: $(pretty_path "$link_path")"
      return
    fi
  done

  if [[ -L $link_path ]]; then
    [[ $(readlink "$link_path") == "$target" ]] ||
      die "conflicting symlink: $(pretty_path "$link_path") -> $(readlink "$link_path")"
    return
  fi
  [[ ! -e $link_path ]] ||
    die "adapter path already exists and is not a symlink: $(pretty_path "$link_path")"
  add_planned_change LINK adapter "$target" "$link_path"
}

plan_claude_links() {
  local source_dir=$1
  local link_dir=$2
  local target_prefix=$3
  local skill_dir

  if [[ -L $link_dir || ( -e $link_dir && ! -d $link_dir ) ]]; then
    die "Claude skills path is not a directory: $(pretty_path "$link_dir")"
  fi
  shopt -s nullglob
  for skill_dir in "$source_dir"/*; do
    [[ -d $skill_dir && -f $skill_dir/SKILL.md ]] || continue
    validate_skill_dir "$skill_dir"
    plan_adapter_link "$link_dir/${skill_dir##*/}" "$target_prefix/${skill_dir##*/}"
  done
  shopt -u nullglob
}

show_preview() {
  local index

  printf '\nPlanned managed-file changes:\n'
  if (( ${#planned_actions[@]} == 0 )); then
    printf '  (none)\n'
  else
    for index in "${!planned_actions[@]}"; do
      printf '  %-6s %s\n' \
        "${planned_actions[$index]}" "${planned_display_paths[$index]}"
    done
  fi

  if [[ $direction == push && -n $managed_status ]]; then
    printf '\nExisting managed repository changes to adopt:\n'
    while IFS= read -r status_line; do
      printf '  PENDING %s\n' "$status_line"
    done <<<"$managed_status"
  fi

  local ahead_count
  ahead_count=$(git -C "$repo_dir" rev-list --count "@{upstream}..HEAD")
  if [[ $direction == push && $ahead_count -gt 0 ]]; then
    printf '\nExisting local commits to publish:\n'
    git -C "$repo_dir" log --format='  PUBLISH %h %s' "@{upstream}..HEAD"
  fi
}

confirm_changes() {
  local response

  (( assume_yes == 0 )) || {
    printf '\nApproved by --yes.\n'
    return
  }
  [[ -t 0 ]] ||
    die "confirmation requires an interactive terminal; rerun with --yes"
  printf '\nApply these changes? [y/N] '
  IFS= read -r response || response=''
  case ${response,,} in
    y | yes) ;;
    *)
      printf 'Canceled; no managed files were changed.\n'
      exit 0
      ;;
  esac
}

apply_plan() {
  local index source destination

  for index in "${!planned_destination_directories[@]}"; do
    mkdir -p -- "${planned_destination_directories[$index]}"
  done

  for index in "${!planned_actions[@]}"; do
    source=${planned_sources[$index]}
    destination=${planned_destinations[$index]}
    case ${planned_kinds[$index]} in
      file)
        cp -a -- "$source" "$destination"
        ;;
      source-link)
        ln -sfn -- "$(readlink "$source")" "$destination"
        ;;
      adapter)
        mkdir -p -- "${destination%/*}"
        ln -s -- "$source" "$destination"
        ;;
      *)
        die "internal error: unsupported planned change kind"
        ;;
    esac
  done
}

if [[ $direction == pull ]]; then
  plan_skills "$repo_skills_dir" "$canonical_dir"
  # Preserve canonical-only skills and make sure their live adapters exist too.
  if [[ -d $canonical_dir ]]; then
    plan_claude_links "$canonical_dir" "$live_claude_dir" "$canonical_dir"
  fi
  plan_claude_links "$repo_skills_dir" "$live_claude_dir" "$canonical_dir"
else
  plan_skills "$canonical_dir" "$repo_skills_dir"
  plan_claude_links "$canonical_dir" "$repo_claude_dir" "../../.agents/skills"
fi

ahead_count=$(git -C "$repo_dir" rev-list --count "@{upstream}..HEAD")
needs_confirmation=0
(( ${#planned_actions[@]} > 0 )) && needs_confirmation=1
if [[ $direction == push && ( -n $managed_status || $ahead_count -gt 0 ) ]]; then
  needs_confirmation=1
fi

show_preview
if (( needs_confirmation == 0 )); then
  if [[ $direction == pull ]]; then
    printf '\nNo managed changes to install; %d skills are already synchronized.\n' "$skill_count"
  else
    printf '\nNo managed changes or local commits to push; %d skills are already synchronized.\n' \
      "$skill_count"
  fi
  exit 0
fi

confirm_changes
apply_plan

if [[ $direction == pull ]]; then
  printf 'Pulled and installed %d skills with %d managed change(s) from %s.\n' \
    "$skill_count" "${#planned_actions[@]}" "$repo_dir"
  exit 0
fi

git -C "$repo_dir" add -A -- .agents/skills .claude/skills
git -C "$repo_dir" diff --cached --check

commit_created=0
if ! git -C "$repo_dir" diff --cached --quiet; then
  printf '\nManaged changes to commit:\n'
  git -C "$repo_dir" diff --cached --name-status
  git -C "$repo_dir" commit -m 'sync agent skills'
  commit_created=1
fi

ahead_count=$(git -C "$repo_dir" rev-list --count "@{upstream}..HEAD")
if (( ahead_count == 0 )); then
  printf 'No commit or push was needed; %d skills are already synchronized.\n' "$skill_count"
  exit 0
fi

commit_hash=$(git -C "$repo_dir" rev-parse --short HEAD)
commit_subject=$(git -C "$repo_dir" log -1 --format=%s)
if ! git -C "$repo_dir" push; then
  printf 'skill-sync: push failed; commit %s (%s) remains local\n' \
    "$commit_hash" "$commit_subject" >&2
  exit 1
fi

if (( commit_created == 1 )); then
  printf 'Commit: %s %s\n' "$commit_hash" "$commit_subject"
else
  printf 'Published existing local commits through %s %s.\n' "$commit_hash" "$commit_subject"
fi
printf 'Synced %d skills and pushed to %s via %s.\n' \
  "$skill_count" "$upstream" "$push_url"
