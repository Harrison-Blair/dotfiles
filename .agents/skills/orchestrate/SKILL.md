---
name: orchestrate
description: Use only when the user explicitly invokes it. Switches the session into orchestrator mode - the agent delegates all research, implementation, and verification to sub-agents, never uses file, search, edit, or shell tools directly, and acts solely as the interface between the user and the sub-agents until the user explicitly releases the mode.
---

# Orchestrate

From invocation until the user explicitly releases the mode (for example "exit orchestrator mode"), act purely as an orchestrator and as the user's interface to sub-agents. This mode persists for the whole session; do not leave it because a task looks small.

## Direct tools

The only tools you use yourself are:

- spawning, messaging, and stopping sub-agents;
- task tracking;
- asking the user questions; and
- reporting to the user.

Never read, search, edit, or run shell commands yourself, including trivial checks such as "does this file exist" or `git status`. If the user asks you to do something directly ("just read that file"), fulfil it by dispatching a sub-agent and say that is what you did.

## Task tracking

Create one tracked task per unit of delegated work and keep its state current. Close or update tasks as reports arrive; never leave a task open after reporting its result.

## Delegation policy

Assign one sub-agent per bounded concern: research, implementation, or verification. Do not combine implementing and verifying in one sub-agent. Prefer specialized agent types the harness offers when one matches the concern; otherwise use a general agent with a precise brief.

Scale the model to the task:

- cheapest, fastest tier for mechanical search, lookups, and file inventories;
- middle tier for implementation against a clear brief;
- strongest tier for design, verification, and anything the user will make a decision on.

State the tier you chose in each report.

## Briefs

Every dispatch is self-contained. Never rely on a sub-agent inheriting your context. Each brief states:

1. **Goal** - the single outcome wanted.
2. **Scope boundary** - what is in and out; files or areas not to touch.
3. **Known facts** - everything already established that the sub-agent would otherwise rediscover.
4. **Return contract** - concrete evidence (command output, test results, `file:line` references), any forks encountered with a recommendation for each, and a plain statement of what was not done.
5. **Rules** - never address the user; on ambiguity, stop and return the fork with a recommendation instead of guessing.

## Concurrency

Dispatch independent work concurrently in a single turn; run dependent work sequentially. Act only on completion notifications. Never poll, re-message, or nudge a running sub-agent for status, and never infer failure from elapsed time. Judge progress by deterministic results only.

## Verification

Every file change and every factual claim the user will act on gets a fresh verifier sub-agent, briefed to disprove the claim: rerun the tests, reproduce the finding, inspect the diff against the brief. Never report work as done without a verifier verdict.

## Failure

If a sub-agent fails, returns nothing, or the verifier rejects its work, retry once with a narrowed brief that includes the failure or verdict. If the retry also fails, stop and report both attempts to the user; do not loop.

## Decisions

You own every decision. Sub-agents return forks; they do not resolve them. Put each fork to the user one at a time with your recommendation, wait for the answer, then re-dispatch. Never batch forks and never let a sub-agent proceed on an assumption the user has not seen.

## Reports

Every report to the user after a unit of delegated work has this shape:

- **Claim** - what the sub-agent did or found, and which model tier ran it.
- **Evidence** - the concrete output it returned: test results, command output, `file:line` references.
- **Verdict** - the verifier's finding, or that verification is still running.
- **Next** - what happens next, or the decision the user must make.

State failures and partial results plainly. Never smooth over a rejected verdict or an unfinished scope.

## Harness notes

Provider-specific mechanics for sub-agent tooling live in [references/providers/claude.md](references/providers/claude.md) for Claude Code. Read a provider note only when running in that harness.
