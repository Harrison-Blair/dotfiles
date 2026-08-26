#!/usr/bin/env bash

set -euo pipefail

die() {
  printf 'commit-and-push: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'Usage: %s "<commit message>"\n' "${0##*/}" >&2
  exit 2
}

[[ $# -eq 1 && -n $1 ]] || usage
commit_message=$1

command -v git >/dev/null 2>&1 || die "required command not found: git"

repo_dir=$(git rev-parse --show-toplevel 2>/dev/null) || die "current directory is not in a Git repository"
repo_status=$(git -C "$repo_dir" status --porcelain=v1 --untracked-files=all)
[[ -n $repo_status ]] || die "working tree is clean"

branch=$(git -C "$repo_dir" symbolic-ref --quiet --short HEAD) ||
  die "cannot commit and push from a detached HEAD"
remote_name=$(git -C "$repo_dir" config --get "branch.$branch.remote") ||
  die "branch $branch has no configured upstream remote"
[[ $remote_name != . ]] || die "branch $branch tracks a local branch, not a push remote"
merge_ref=$(git -C "$repo_dir" config --get "branch.$branch.merge") ||
  die "branch $branch has no configured upstream branch"
[[ $merge_ref == refs/heads/* ]] || die "unsupported upstream ref: $merge_ref"
upstream_branch=${merge_ref#refs/heads/}
git check-ref-format --branch "$upstream_branch" >/dev/null 2>&1 ||
  die "invalid upstream branch: $upstream_branch"
upstream=$(git -C "$repo_dir" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) ||
  die "configured upstream cannot be resolved"
push_url=$(git -C "$repo_dir" remote get-url --push "$remote_name") ||
  die "cannot resolve the push URL for $remote_name"

printf 'Repository: %s\nBranch: %s\nDestination: %s via %s\n' \
  "$repo_dir" "$branch" "$upstream" "$push_url"

git -C "$repo_dir" add -A
git -C "$repo_dir" diff --cached --check
git -C "$repo_dir" diff --cached --quiet && die "no staged changes after git add -A"
git -C "$repo_dir" diff --cached --stat
git -C "$repo_dir" commit -m "$commit_message"

commit_hash=$(git -C "$repo_dir" rev-parse --short HEAD)
commit_subject=$(git -C "$repo_dir" log -1 --format=%s)
if ! git -C "$repo_dir" push "$remote_name" "HEAD:refs/heads/$upstream_branch"; then
  printf 'commit-and-push: push failed; commit %s (%s) remains local on %s\n' \
    "$commit_hash" "$commit_subject" "$branch" >&2
  exit 1
fi

printf 'Commit: %s %s\nBranch: %s\nPushed to: %s via %s\n' \
  "$commit_hash" "$commit_subject" "$branch" "$upstream" "$push_url"
