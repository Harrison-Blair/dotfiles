---
name: commit
description: Review current Git changes, summarize them, and commit; with the word "approve" in the request, commit and push to the configured upstream with no further questions. Use when wrapping up repository changes or when invoked directly.
---

# Commit

Inspect the repository with `git status --short`, `git diff`, and `git diff --cached`. Account for untracked files when describing the complete working tree, since Git diffs omit them.

If the working tree is clean, say so and stop.

## Fast path: `approve`

If the request contains the word `approve` (for example `/commit approve` or `$commit approve`), the user has already authorized both the commit and the push. Ask nothing. Do everything below in one pass, then report once.

1. Resolve the current local branch and its configured upstream (`git rev-parse --abbrev-ref --symbolic-full-name @{upstream}`) and the push URL of that remote. Do not change Git configuration.
2. Stage all repository changes with `git add -A`, review the staged diff, write a concise commit message that reflects it, and commit. Stop and report any staging or commit failure.
3. If an upstream is configured, run a plain `git push` — no remote or branch arguments, no `-u`, no force. If no upstream is configured, skip the push; never guess a remote or branch.
4. Report in a few lines: the commit hash and subject, the branch, and either "pushed to `<upstream>` via `<push-url>`", "push failed: <reason> (commit is local)", or "not pushed: no upstream configured for `<branch>`".

Only a staging or commit failure interrupts the fast path; a push failure is reported, not retried.

## Interactive path

Without `approve`:

1. Summarize the changes in 1–3 sentences.
2. Ask the user to choose **Commit**, **Commit and push**, or **More info**. Do not mutate Git before they choose.
3. **More info**: ask whether they want an expanded file-by-file summary or suggested code/test improvements, and provide it without changing files, committing, or pushing.
4. **Commit**: stage all changes with `git add -A`, review the staged diff, commit with a concise message, and report the hash and subject.
5. **Commit and push**: the choice itself is the push authorization; do not ask a second time. Run the fast path above from step 1 and report the same way, including the destination that was used.

## Commit message rules

- Conventional style when the repository uses it (`feat:`, `fix:`, `chore:`, …); otherwise a short imperative subject.
- Never add `Co-Authored-By` or any other attribution trailer.
- Follow any repository guidance file (`AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md`) on commit format.
