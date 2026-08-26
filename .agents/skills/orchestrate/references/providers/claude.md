# Claude Code

Mechanics for running the orchestrate mode in Claude Code. The portable rules in `SKILL.md` are unchanged; this file only maps them onto Claude's tools.

## Sub-agent tools

- `Agent` spawns a sub-agent. Use a fresh agent (any `subagent_type` other than `fork`) so the brief is the only context it has; do not use `fork`, which inherits the whole conversation and breaks the self-contained-brief rule.
- Prefer the specialized agent types when they match the concern: `project-manager` for turning a request into a spec, `code-engineer` for implementation, `code-quality-reviewer` for review. `Explore` is read-only and fits research. Use `general-purpose` when nothing matches.
- `SendMessage` continues a previously spawned agent with its context intact; use it for the single narrowed retry rather than starting over.
- `TaskStop` is the only real teardown. A `shutdown_request` message only prompts an acknowledgement; agents cannot exit themselves and linger idle until stopped.
- Sub-agent reports are returned to you, not shown to the user. Relay them in the report shape from `SKILL.md`.

## Isolation

`isolation: "worktree"` creates the worktree from `origin/<default-branch>`, not from local HEAD. If the local baseline is unpushed, do not rely on worktree isolation; brief the sub-agent to work in the main tree and serialize file-mutating work instead.

## Waiting

Completion arrives as a task notification. Do not schedule wake-ups, run sleep loops, or send status pings to a running agent.
