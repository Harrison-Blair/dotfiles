<!-- Canonical global instructions. Edit the tracked .agents/AGENTS.md in the dotfiles repository, not installed symlinks. -->

# Global Agent Instructions

## User Preferences

- I dictate with a speech-to-text tool that inserts text by pasting, so my messages often arrive as pasted content.
- Explicit model or tool choices in the current request override stored defaults. If the requested choice is unavailable and a substitution is necessary, disclose it.
- Commits are allowed when authorized, but never add the agent as a co-author or include a `Co-Authored-By` trailer attributing work to an agent.
- Parallelize independent work, including with useful available subagents. Sequence dependent work and coordinate edits that could conflict.
- Use task tracking when available. Keep tasks current, close completed work, and preserve enough state for a reliable handoff.
- Ask clarifying questions when an unresolved choice would materially change the result. State assumptions and surface meaningful tradeoffs.

## Work Boundaries and Verification

- Honor the requested phase. Investigate, plan, review, explain, or validate without implementing unless implementation is also authorized.
- Treat suspected bugs and review findings as hypotheses. Check actual behavior and intended design before changing code.
- Before declaring work complete, verify the actual user-visible behavior when practical, not only an indirect proxy. State any limits that remain unverified.
- Remove temporary files, data, and resources created for the task once the result is recorded in the required format and verified, and those items are no longer needed for delivery or verification. Preserve final deliverables and pre-existing user data. Verify cleanup before declaring the task complete.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:

- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop and name what is unclear.

## 2. Simplicity First

**Write the minimum code that solves the problem. Nothing speculative.**

- Add no features beyond what was asked.
- Avoid abstractions for single-use code.
- Do not add flexibility or configurability that was not requested.
- Do not add error handling for impossible scenarios.
- If the implementation is much larger than necessary, simplify it.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:

- Do not improve adjacent code, comments, or formatting without need.
- Do not refactor unrelated code.
- Match the existing style.
- Mention unrelated dead code instead of deleting it.
- Remove imports, variables, and functions made unused by your changes.

Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria and loop until they are verified.**

For multi-step tasks, keep a brief plan with a verification check for each step. Examples:

- Add validation: test invalid inputs, then make the tests pass.
- Fix a bug: reproduce it with a failing test, then make the test pass.
- Refactor behavior: verify relevant tests before and after.

Strong success criteria support independent execution. Ask when a decision materially changes the intended result.

## Test Verification

A test counts only if it fails when the behavior breaks and passes when the behavior is correct.

- For a bug fix, run the new test against the unfixed or deliberately broken behavior and confirm it fails, then confirm it passes with the fix.
- For a feature, temporarily break or stub the feature and confirm the new test fails, then restore it and confirm the test passes.
- Never trust a test that has only been observed passing.
