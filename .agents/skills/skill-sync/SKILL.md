---
name: skill-sync
description: Synchronize user-scoped portable agent skills between ~/.agents/skills and the fixed ~/source/dotfiles Git repository. Use when asked to pull and install the repository's latest skills or push canonical skill updates.
---

# Skill Sync

Use these fixed locations; do not search for alternatives:

- canonical skills: `$HOME/.agents/skills`;
- Git repository: `$HOME/source/dotfiles`;
- repository skills: `$HOME/source/dotfiles/.agents/skills`; and
- live Claude adapters: `$HOME/.claude/skills`.

## Direction

Require one explicit direction before changing files or Git state:

- **Pull** means fast-forward the dotfiles repository, copy its skills into the canonical directory, and install any missing live Claude adapters.
- **Push** means fast-forward the dotfiles repository, copy all canonical skills into it, maintain its tracked Claude adapters, commit the managed paths, and push the configured upstream.

If the request merely says "sync" and the direction is not already clear, ask whether to pull or push. A request that explicitly says `push` authorizes the script's managed commit and normal Git push; never infer that authorization from a pull or a generic sync request.

## Run

For a human working from the dotfiles repository, run one of the interactive
entry points:

```sh
"$HOME/source/dotfiles/scripts/pull.sh"
"$HOME/source/dotfiles/scripts/push.sh"
```

Both commands fast-forward the repository, print an `ADD`, `UPDATE`, and `LINK`
file manifest without content diffs, and ask for confirmation before changing
managed files. Canceling leaves the fast-forwarded repository in place but does
not copy, commit, or push anything.

When acting for a user who explicitly requested a direction, run exactly one of
the noninteractive forms below. `--yes` still prints the preview; it only skips
the terminal prompt.

```sh
"$HOME/.agents/skills/skill-sync/scripts/sync.sh" pull --yes
"$HOME/.agents/skills/skill-sync/scripts/sync.sh" push --yes
```

Do not recreate the synchronization with ad hoc copy or Git commands. The
script checks the repository and upstream, requires a clean worktree for pull,
and permits push to adopt pending changes only under `.agents/skills` and
`.claude/skills`. It refuses unrelated changes or a newer upstream, uses only
fast-forward pulls and a plain push, stages only those managed paths, preserves
target-only files, and refuses conflicting adapter paths. It never force-pushes
or deletes skills.

Stop on any script failure and report the blocking output without bypassing its safeguards. After success, report the direction, skill count, repository path, commit created if any, and push destination or pull result.
