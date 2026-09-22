# ai-statusline

This directory captures the current status-line setup for Claude Code and
Codex. The provider fragments live at `.claude/statusline.settings.json` and
`.codex/statusline.toml`; they are deliberately partial configurations so that
restoring the status line does not overwrite unrelated settings.

Claude Code sends session JSON to `.claude/statusline-command.sh`, which invokes
`statusline.py`. The shared `config.json` renders these segments in order:
model, context tokens, five-hour capacity remaining, and weekly capacity
remaining. Quota values include the local reset time when available.

The captured Codex layout uses its native footer fields in this exact order:

```text
model-with-reasoning, project-name, git-branch, context-remaining,
used-tokens, total-input-tokens, total-output-tokens, five-hour-limit,
weekly-limit, thread-name
```

`.codex/statusline.toml` is the authoritative snapshot for restoring this
current ten-field Codex layout.

## Requirements

- Python 3.11 or newer
- Bash

The Python renderer and tests use only the standard library.

## Restore

Run these copy commands from the root of this dotfiles repository:

```bash
mkdir -p "$HOME/.claude" "$HOME/.config/ai-statusline"
cp .claude/statusline-command.sh "$HOME/.claude/statusline-command.sh"
cp .config/ai-statusline/config.json \
  .config/ai-statusline/statusline.py \
  .config/ai-statusline/test_statusline.py \
  .config/ai-statusline/README.md \
  "$HOME/.config/ai-statusline/"
chmod +x "$HOME/.claude/statusline-command.sh" \
  "$HOME/.config/ai-statusline/statusline.py"
```

Then merge the provider fragments into the full provider configurations:

- Merge only the `statusLine` object from
  `.claude/statusline.settings.json` into `~/.claude/settings.json`. Preserve
  every other setting.
- Merge the `status_line` assignment from `.codex/statusline.toml` into the
  existing `[tui]` table in `~/.codex/config.toml`. Replace an existing
  `status_line` assignment if present, and do not create a duplicate `[tui]`
  table. Preserve every other setting.

Do not replace either full provider configuration with these fragments.

## Verify

```bash
PYTHONDONTWRITEBYTECODE=1 \
  python3 "$HOME/.config/ai-statusline/test_statusline.py"
bash -n "$HOME/.claude/statusline-command.sh"
```

`statusline.py sync codex` and `statusline.py check codex` remain available as
optional helpers. They derive a smaller native Codex mapping from the four
shared `config.json` segments. That generated mapping differs from the captured
ten-field layout, so do not use `sync codex` to restore the snapshot above.
