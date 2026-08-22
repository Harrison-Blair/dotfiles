---
name: commit
description: Review current Git changes, summarize them, and let the user commit, explicitly authorize a push to the configured destination, or request more detail. Use when wrapping up repository changes or when invoked directly.
---

# Commit

Inspect the repository with `git status --short`, `git diff`, and `git diff --cached`. Account for untracked files when describing the complete working tree, since Git diffs omit them.

If the working tree is clean, say so and stop. Otherwise:

1. Summarize the changes in 1–3 sentences.
2. Ask the user to choose **Commit**, **Commit and push**, or **More info**. Do not mutate Git before the user selects a commit option.
3. If they choose **More info**, ask whether they want an expanded file-by-file summary or suggested code/test improvements. Provide the requested guidance without changing files, committing, or pushing.
4. If they choose **Commit and push**, resolve the current local branch, its configured upstream branch, and that remote's push URL without changing Git configuration. If any destination detail is missing or ambiguous, stop and explain that a push cannot be offered without a configured destination; do not guess a remote, branch, or upstream. Show the exact destination and ask a separate question: **Push `<local-branch>` to `<upstream-branch>` via `<push-url>` after committing all changes?** Only an unambiguous affirmative response grants push permission. The earlier generic **Commit and push** choice is not destination-specific authorization. If the user declines, ask whether they want a local commit instead.
5. After **Commit** or destination-specific push permission, stage all repository changes with `git add -A`. Review the resulting staged diff, generate a concise commit message that reflects it, and commit it. Stop and report any staging or commit failure.
6. Before an authorized push, confirm that the local branch, configured upstream branch, and push URL still match the approved destination. If any changed, stop and request permission for the new exact destination. Otherwise, run a normal `git push` only after the commit succeeds. Do not add command-line remote or branch arguments, change configuration, or create an upstream automatically. If pushing fails, explain that the local commit succeeded and report the push failure.
