---
name: commit
description: Review current Git changes, summarize them, and commit; with the word "approve" in the request, commit and push to the configured upstream with no further questions. Use when wrapping up repository changes or when invoked directly.
---

# Commit

Inspect the repository with `git status --short`, `git diff`, and `git diff --cached`. Account for untracked files when describing the complete working tree, since Git diffs omit them.

If the working tree is clean, say so and stop.

## Fast path: `approve`

If the request contains the word `approve` (for example `/commit approve` or `$commit approve`), the user has already authorized both the commit and the push. Ask nothing. Do everything below in one pass, then report once.

When running in Codex, read [references/providers/codex.md](references/providers/codex.md) before invoking the helper.

1. Review all tracked and untracked changes and write a concise commit message that reflects them.
2. From anywhere inside the target repository, run the helper with that message as its single argument:

   ```sh
   "$HOME/.agents/skills/commit/scripts/commit-and-push.sh" "<commit message>"
   ```

3. Do not stage, commit, or push with separate commands. The helper resolves the local branch, configured upstream branch, and push URL before mutation; stages all changes; checks and commits the staged diff; then pushes with an explicit `git push <remote> HEAD:refs/heads/<upstream-branch>` refspec. It never guesses a destination, configures an upstream, or force-pushes.
4. Report the helper's result: commit hash and subject, local branch, and exact push destination. If it reports a push failure, make clear that the commit remains local.

Stop on any helper failure and do not retry or bypass it with ad hoc Git commands.

## Interactive path

Without `approve`:

1. Summarize the changes in 1–3 sentences.
2. Ask the user to choose **Commit**, **Commit and push**, or **More info**. Do not mutate Git before they choose.
3. **More info**: ask whether they want an expanded file-by-file summary or suggested code/test improvements, and provide it without changing files, committing, or pushing.
4. **Commit**: stage all changes with `git add -A`, review the staged diff, commit with a concise message, and report the hash and subject.
5. **Commit and push**: the choice itself is the push authorization; do not ask a second time. Run the fast path above and report the same way, including the destination that was used.

## Commit message rules

- Conventional style when the repository uses it (`feat:`, `fix:`, `chore:`, …); otherwise a short imperative subject.
- Never add `Co-Authored-By` or any other attribution trailer.
- Follow any repository guidance file (`AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md`) on commit format.
