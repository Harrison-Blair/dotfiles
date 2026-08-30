#!/usr/bin/env bash

set -euo pipefail

test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
engine=$test_dir/../scripts/sync.sh
repo_root=$(cd -- "$test_dir/../../../.." && pwd)
pull_wrapper=$repo_root/scripts/pull.sh
send_wrapper=$repo_root/scripts/send.sh
fixture_root=$(mktemp -d /tmp/skill-sync-tests.XXXXXX)
test_count=0

cleanup() {
  if [[ $fixture_root == /tmp/skill-sync-tests.* && -d $fixture_root ]]; then
    rm -rf -- "$fixture_root"
  fi
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

pass() {
  test_count=$((test_count + 1))
  printf 'ok %d - %s\n' "$test_count" "$1"
}

assert_contains() {
  local actual=$1
  local expected=$2
  local message=$3

  [[ $actual == *"$expected"* ]] ||
    fail "$message (missing: $expected)"
}

assert_file_contains() {
  local path=$1
  local expected=$2
  local message=$3

  [[ -f $path ]] || fail "$message (missing file: $path)"
  grep -Fq -- "$expected" "$path" ||
    fail "$message (missing content: $expected)"
}

assert_absent() {
  local path=$1
  local message=$2

  [[ ! -e $path && ! -L $path ]] || fail "$message (unexpected path: $path)"
}

write_skill() {
  local skills_dir=$1
  local name=$2
  local body=$3

  mkdir -p -- "$skills_dir/$name"
  printf '%s\n' \
    '---' \
    "name: $name" \
    "description: Test skill $name." \
    '---' \
    '' \
    "$body" >"$skills_dir/$name/SKILL.md"
}

git_identity() {
  git -C "$1" config user.name 'Skill Sync Tests'
  git -C "$1" config user.email 'skill-sync-tests@example.invalid'
}

test_home=$fixture_root/home
remote=$fixture_root/remote.git
seed=$fixture_root/seed
repo=$test_home/source/dotfiles
canonical=$test_home/.agents/skills
live_claude=$test_home/.claude/skills

git init --bare --quiet "$remote"
git --git-dir="$remote" symbolic-ref HEAD refs/heads/main
git init --quiet --initial-branch=main "$seed"
git_identity "$seed"
write_skill "$seed/.agents/skills" alpha 'remote-v1'
mkdir -p -- "$seed/.claude/skills"
ln -s ../../.agents/skills/alpha "$seed/.claude/skills/alpha"
git -C "$seed" add -A
git -C "$seed" commit --quiet -m 'initial skills'
git -C "$seed" remote add origin "$remote"
git -C "$seed" push --quiet --set-upstream origin main

mkdir -p -- "$test_home/source"
git clone --quiet "$remote" "$repo"
git_identity "$repo"

output=$(HOME="$test_home" "$pull_wrapper" --yes 2>&1)
assert_contains "$output" 'ADD' 'initial pull previews additions'
assert_contains "$output" '~/.agents/skills/alpha/SKILL.md' 'initial pull names the destination file'
assert_contains "$output" 'LINK' 'initial pull previews the Claude adapter'
assert_file_contains "$canonical/alpha/SKILL.md" 'remote-v1' 'initial pull installs the skill'
[[ -L $live_claude/alpha ]] || fail 'initial pull creates the live Claude adapter'
[[ $(readlink "$live_claude/alpha") == "$canonical/alpha" ]] ||
  fail 'live Claude adapter points at the canonical skill'
pass 'pull wrapper installs skills and live Claude adapters'

write_skill "$canonical" local-only 'local-only-v1'
printf '%s\n' 'preserve me' >"$canonical/alpha/machine-only.txt"
output=$(HOME="$test_home" "$engine" pull --yes 2>&1)
assert_contains "$output" '~/.claude/skills/local-only' 'pull previews an adapter for a preserved skill'
[[ -L $live_claude/local-only ]] || fail 'pull creates an adapter for a canonical-only skill'
assert_file_contains "$canonical/alpha/machine-only.txt" 'preserve me' 'pull preserves destination-only files'
pass 'pull preserves canonical-only content and maintains its adapter'

write_skill "$seed/.agents/skills" alpha 'remote-v2'
printf '%s\n' 'from remote' >"$seed/.agents/skills/alpha/remote-only.txt"
git -C "$seed" add -A
git -C "$seed" commit --quiet -m 'update remote skill'
git -C "$seed" push --quiet

if output=$(HOME="$test_home" "$engine" pull 2>&1); then
  fail 'noninteractive pull without --yes should fail when changes are pending'
fi
assert_contains "$output" 'UPDATE' 'noninteractive pull still prints its preview'
assert_contains "$output" 'rerun with --yes' 'noninteractive pull explains how to approve'
assert_file_contains "$repo/.agents/skills/alpha/SKILL.md" 'remote-v2' 'pull fast-forwards before preview'
assert_file_contains "$canonical/alpha/SKILL.md" 'remote-v1' 'failed confirmation leaves canonical content unchanged'
assert_absent "$canonical/alpha/remote-only.txt" 'failed confirmation does not add files'
pass 'noninteractive pull requires --yes after fast-forwarding the repository'

cancel_output=$(printf 'n\n' | script -qfec \
  "env HOME='$test_home' '$engine' pull" /dev/null 2>&1)
assert_contains "$cancel_output" 'Canceled; no managed files were changed.' 'interactive cancellation is reported'
assert_file_contains "$canonical/alpha/SKILL.md" 'remote-v1' 'interactive cancellation leaves canonical content unchanged'
assert_absent "$canonical/alpha/remote-only.txt" 'interactive cancellation does not add files'
pass 'interactive rejection cancels managed-file changes'

output=$(HOME="$test_home" "$engine" pull --yes 2>&1)
assert_contains "$output" 'UPDATE' 'approved pull previews an update'
assert_contains "$output" 'ADD' 'approved pull previews a new file'
assert_file_contains "$canonical/alpha/SKILL.md" 'remote-v2' 'approved pull updates canonical content'
assert_file_contains "$canonical/alpha/remote-only.txt" 'from remote' 'approved pull adds canonical content'
assert_file_contains "$canonical/alpha/machine-only.txt" 'preserve me' 'approved pull still preserves destination-only files'
pass 'approved pull applies only the previewed additions and updates'

rm -- "$live_claude/alpha"
ln -s /tmp/wrong-skill-target "$live_claude/alpha"
if output=$(HOME="$test_home" "$engine" pull --yes 2>&1); then
  fail 'pull should reject a conflicting Claude adapter'
fi
assert_contains "$output" 'conflicting symlink' 'adapter conflict reports the blocking path'
rm -- "$live_claude/alpha"
ln -s "$canonical/alpha" "$live_claude/alpha"
pass 'pull refuses to replace a conflicting Claude adapter'

write_skill "$canonical" alpha 'machine-v3'
write_skill "$canonical" beta 'machine-beta-v1'
mkdir -p -- "$canonical/beta/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'printf beta\\n' >"$canonical/beta/scripts/run.sh"
chmod 644 "$canonical/beta/scripts/run.sh"
rm -- "$canonical/alpha/remote-only.txt"

if output=$(HOME="$test_home" "$engine" push 2>&1); then
  fail 'noninteractive push without --yes should fail when changes are pending'
fi
assert_contains "$output" 'UPDATE' 'noninteractive push previews updates'
assert_contains "$output" '.agents/skills/beta/SKILL.md' 'noninteractive push names added repo files'
assert_file_contains "$repo/.agents/skills/alpha/SKILL.md" 'remote-v2' 'failed push confirmation leaves repo content unchanged'
assert_absent "$repo/.agents/skills/beta" 'failed push confirmation does not add skills'
pass 'noninteractive push requires --yes without changing managed files'

output=$(HOME="$test_home" "$send_wrapper" --yes 2>&1)
assert_contains "$output" 'Managed changes to commit:' 'approved push shows the staged file list'
assert_contains "$output" 'Commit:' 'approved push reports its commit'
assert_file_contains "$repo/.agents/skills/alpha/SKILL.md" 'machine-v3' 'approved push updates repo content'
assert_file_contains "$repo/.agents/skills/alpha/remote-only.txt" 'from remote' 'push preserves repo-only files'
assert_file_contains "$repo/.agents/skills/beta/SKILL.md" 'machine-beta-v1' 'approved push adds repo skills'
[[ -L $repo/.claude/skills/beta ]] || fail 'approved push creates the tracked Claude adapter'
[[ $(readlink "$repo/.claude/skills/beta") == '../../.agents/skills/beta' ]] ||
  fail 'tracked Claude adapter uses the expected relative target'
[[ -z $(git -C "$repo" status --porcelain=v1) ]] || fail 'approved push leaves the repo clean'
[[ $(git -C "$repo" log -1 --format=%s) == 'sync agent skills' ]] ||
  fail 'approved push uses the managed commit message'
remote_alpha=$(git --git-dir="$remote" show main:.agents/skills/alpha/SKILL.md)
assert_contains "$remote_alpha" 'machine-v3' 'approved push publishes canonical content to the remote'
pass 'send wrapper copies, commits, and publishes managed changes'

output=$(HOME="$test_home" "$engine" push 2>&1)
assert_contains "$output" 'No managed changes or local commits to push' 'no-change push reports a no-op'
pass 'push needs no confirmation when there is nothing to change or publish'

chmod 755 "$canonical/beta/scripts/run.sh"
output=$(HOME="$test_home" "$engine" push --yes 2>&1)
assert_contains "$output" 'UPDATE' 'mode-only changes appear in the preview'
[[ -x $repo/.agents/skills/beta/scripts/run.sh ]] || fail 'mode-only update reaches the repo'
remote_mode=$(git --git-dir="$remote" ls-tree main .agents/skills/beta/scripts/run.sh | awk '{print $1}')
[[ $remote_mode == 100755 ]] || fail "executable mode was not pushed (found: $remote_mode)"
pass 'push detects and publishes executable-mode changes'

printf '%s\n' 'dirty' >"$repo/unrelated.txt"
if output=$(HOME="$test_home" "$engine" pull --yes 2>&1); then
  fail 'pull should reject a dirty repository'
fi
assert_contains "$output" 'worktree must be clean before pull' 'dirty pull reports its safeguard'
if output=$(HOME="$test_home" "$engine" push --yes 2>&1); then
  fail 'push should reject unrelated repository changes'
fi
assert_contains "$output" 'refuses pending changes outside' 'dirty push reports its safeguard'
rm -- "$repo/unrelated.txt"
pass 'pull and push reject unsafe unrelated worktree changes'

git -C "$seed" pull --quiet --ff-only
printf '%s\n' 'remote advance' >"$seed/.agents/skills/alpha/upstream.txt"
git -C "$seed" add -A
git -C "$seed" commit --quiet -m 'advance upstream'
git -C "$seed" push --quiet
printf '%s\n' 'pending local change' >"$repo/.agents/skills/alpha/pending.txt"
if output=$(HOME="$test_home" "$engine" push --yes 2>&1); then
  fail 'push should reject a newer upstream while managed changes are pending'
fi
assert_contains "$output" 'upstream is 1 commit(s) ahead' 'remote-ahead rejection reports the commit count'
pass 'push refuses to combine pending managed changes with a newer upstream'

printf '1..%d\n' "$test_count"
