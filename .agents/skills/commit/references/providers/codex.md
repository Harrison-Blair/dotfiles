# Codex

Invoke `scripts/commit-and-push.sh` as one escalated command with the target repository as the command's working directory.

Resolve `$HOME` before the tool call and use the helper's absolute path, such as `/home/user/.agents/skills/commit/scripts/commit-and-push.sh`. Scope reusable approval to that exact script path; pass the generated commit message as its single argument. The user's `approve` or **Commit and push** choice supplies the push authorization.

Do not run or request approval for separate `git add`, `git commit`, or `git push` commands. The helper resolves and prints the configured destination, and its internal push includes the explicit remote and upstream branch refspec.
