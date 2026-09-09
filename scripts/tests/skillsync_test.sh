#!/usr/bin/env bash
#
# Tests for scripts/skillsync.sh. Builds a throwaway upstream repository and a
# fake HOME, then drives the client through the real clone path.

set -euo pipefail

test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
client=$test_dir/../skillsync.sh
fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/skillsync-tests.XXXXXX")
test_count=0

cleanup() {
  [[ -d $fixture_root ]] && rm -rf -- "$fixture_root"
  return 0
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
  [[ $1 == *"$2"* ]] || fail "$3 (missing: $2)"
}

assert_not_contains() {
  [[ $1 != *"$2"* ]] || fail "$3 (unexpected: $2)"
}

write_skill() {
  local root=$1 name=$2 body=${3:-Body for $2.}
  mkdir -p "$root/.agents/skills/$name"
  printf -- '---\nname: %s\ndescription: Test skill %s.\n---\n\n%s\n' \
    "$name" "$name" "$body" > "$root/.agents/skills/$name/SKILL.md"
}

upstream=$fixture_root/upstream
git init --quiet -b main "$upstream"
git -C "$upstream" config user.name test
git -C "$upstream" config user.email test@example.com
write_skill "$upstream" alpha
write_skill "$upstream" beta
mkdir -p "$upstream/.agents/skills/alpha/references"
printf 'ref v1\n' > "$upstream/.agents/skills/alpha/references/notes.md"
mkdir -p "$upstream/scripts"
cp "$client" "$upstream/scripts/skillsync.sh"
git -C "$upstream" add -A
git -C "$upstream" commit --quiet -m 'initial skills'
sha1=$(git -C "$upstream" rev-parse HEAD)

export HOME=$fixture_root/home
mkdir -p "$HOME/.agents/skills/local-only" "$HOME/.claude/skills/local-only"
printf -- '---\nname: local-only\ndescription: Not in the repo.\n---\n' \
  > "$HOME/.agents/skills/local-only/SKILL.md"
printf 'keep me\n' > "$HOME/.claude/skills/local-only/SKILL.md"
skills=$HOME/.agents/skills
claude=$HOME/.claude/skills
state=$HOME/.agents/.skillsync-state

run_client() {
  bash "$client" --repo "$upstream" "$@"
}

# --- 1. --check before any sync ---------------------------------------------
set +e
output=$(run_client --check 2>&1)
status=$?
set -e
[[ $status -eq 3 ]] || fail "--check should exit 3 when never synced (got $status)"
assert_contains "$output" "Never synced" "check output"
[[ ! -e $skills/alpha ]] || fail "--check must not install"
pass "--check reports an available update without installing"

# --- 2. dry run writes nothing ----------------------------------------------
output=$(run_client --dry-run 2>&1)
assert_contains "$output" "ADD      ~/.agents/skills/alpha" "dry-run manifest"
assert_contains "$output" "LINK     ~/.claude/skills/alpha -> ~/.agents/skills/alpha" "dry-run link"
assert_contains "$output" "nothing written" "dry-run summary"
[[ ! -e $skills/alpha && ! -e $claude/alpha && ! -e $state ]] || fail "dry-run wrote files"
pass "--dry-run prints the manifest and writes nothing"

# --- 3. fresh install -------------------------------------------------------
output=$(run_client 2>&1)
assert_contains "$output" "ADD      ~/.agents/skills/alpha" "install manifest"
assert_contains "$output" "ADD      ~/.agents/skills/beta" "install manifest"
[[ -f $skills/alpha/SKILL.md && -f $skills/alpha/references/notes.md ]] || fail "alpha not installed"
[[ -f $skills/beta/SKILL.md ]] || fail "beta not installed"
[[ -L $claude/alpha && $(readlink "$claude/alpha") == "$skills/alpha" ]] || fail "alpha adapter link wrong"
[[ -L $claude/beta ]] || fail "beta adapter link missing"
grep -q "sha=$sha1" "$state" || fail "state file missing sha"
pass "fresh install copies skills, links adapters, records the commit"

# --- 4. rerun is a no-op ----------------------------------------------------
output=$(run_client 2>&1)
assert_contains "$output" "Up to date at ${sha1:0:12}" "no-op output"
assert_not_contains "$output" "Fetching" "no-op must not clone"
pass "rerun with the same commit is a no-op"

# --- 5. --force reinstalls with SAME markers --------------------------------
output=$(run_client --force 2>&1)
assert_contains "$output" "SAME     ~/.agents/skills/alpha" "force manifest"
assert_contains "$output" "0 change(s)" "force summary"
pass "--force re-syncs and reports identical skills as SAME"

# --- 6. upstream change: wholesale replace, untouched extras ----------------
printf 'local edit\n' >> "$skills/alpha/SKILL.md"
printf 'stray\n' > "$skills/alpha/stray.txt"
rm -rf "$claude/beta"
mkdir -p "$claude/beta"                # same name, real directory: must be replaced
printf 'stale\n' > "$claude/beta/SKILL.md"

write_skill "$upstream" alpha 'Body for alpha, revised.'
rm -rf "$upstream/.agents/skills/alpha/references"
write_skill "$upstream" gamma
git -C "$upstream" add -A
git -C "$upstream" commit --quiet -m 'revise alpha, add gamma'
sha2=$(git -C "$upstream" rev-parse HEAD)

set +e
output=$(run_client --check 2>&1)
status=$?
set -e
[[ $status -eq 3 ]] || fail "--check should exit 3 after upstream change"
assert_contains "$output" "${sha1:0:12} -> ${sha2:0:12}" "check shows both commits"

output=$(run_client 2>&1)
assert_contains "$output" "UPDATE   ~/.agents/skills/alpha" "update manifest"
assert_contains "$output" "SAME     ~/.agents/skills/beta" "beta unchanged"
assert_contains "$output" "ADD      ~/.agents/skills/gamma" "gamma added"
assert_contains "$output" "RELINK   ~/.claude/skills/beta" "beta adapter relinked"
grep -q 'revised' "$skills/alpha/SKILL.md" || fail "alpha not updated"
grep -q 'local edit' "$skills/alpha/SKILL.md" && fail "local edit survived wholesale replace"
[[ ! -e $skills/alpha/stray.txt ]] || fail "stray file survived wholesale replace"
[[ ! -e $skills/alpha/references ]] || fail "upstream-deleted directory survived"
[[ -f $skills/gamma/SKILL.md && -L $claude/gamma ]] || fail "gamma not installed"
[[ -L $claude/beta && $(readlink "$claude/beta") == "$skills/beta" ]] || fail "beta adapter not replaced"
[[ -f $skills/local-only/SKILL.md ]] || fail "local-only skill was touched"
[[ $(cat "$claude/local-only/SKILL.md") == "keep me" ]] || fail "local-only adapter was touched"
grep -q "sha=$sha2" "$state" || fail "state not advanced"
pass "upstream changes replace same-named skills wholesale and leave others alone"

# --- 7. skill removed upstream stays local ----------------------------------
git -C "$upstream" rm -r --quiet .agents/skills/beta
git -C "$upstream" commit --quiet -m 'drop beta'
output=$(run_client 2>&1)
assert_not_contains "$output" "beta" "removed skill must not appear"
[[ -f $skills/beta/SKILL.md && -L $claude/beta ]] || fail "beta was pruned"
pass "a skill removed upstream is never deleted locally"

# --- 8. invalid skill is skipped, others install, exit 1 --------------------
mkdir -p "$upstream/.agents/skills/bad-name"
printf -- '---\nname: other-name\ndescription: Mismatch.\n---\n' > "$upstream/.agents/skills/bad-name/SKILL.md"
write_skill "$upstream" delta
git -C "$upstream" add -A
git -C "$upstream" commit --quiet -m 'add bad-name and delta'
set +e
output=$(run_client 2>&1)
status=$?
set -e
[[ $status -eq 1 ]] || fail "invalid skill should make the run exit 1 (got $status)"
assert_contains "$output" "skipping bad-name" "invalid warning"
assert_contains "$output" "1 skill(s) skipped" "invalid summary"
[[ ! -e $skills/bad-name ]] || fail "invalid skill was installed"
[[ -f $skills/delta/SKILL.md ]] || fail "valid sibling not installed"
pass "an invalid skill is skipped with a warning while valid skills install"

# --- 9. --source installs from a local checkout -----------------------------
checkout=$fixture_root/checkout
git clone --quiet "$upstream" "$checkout"
write_skill "$checkout" epsilon
output=$(bash "$client" --source "$checkout" --force 2>&1) || true
assert_contains "$output" "ADD      ~/.agents/skills/epsilon" "source manifest"
[[ -f $skills/epsilon/SKILL.md ]] || fail "epsilon not installed from --source"
pass "--source installs from a local checkout without cloning"

# --- 10. --self-update replaces the installed script ------------------------
installed=$fixture_root/bin/skillsync.sh
mkdir -p "$(dirname "$installed")"
cp "$client" "$installed"
printf '\n# upstream marker\n' >> "$upstream/scripts/skillsync.sh"
git -C "$upstream" add -A
git -C "$upstream" commit --quiet -m 'touch client'
output=$(bash "$installed" --repo "$upstream" --self-update 2>&1) || true
assert_contains "$output" "SELF     " "self-update line"
grep -q 'upstream marker' "$installed" || fail "installed script not updated"
pass "--self-update overwrites the running script from the repository"

printf '1..%d\n' "$test_count"
