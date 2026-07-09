#!/usr/bin/env bash
# Safety-net helper for the Claude Code agent-team leader pane.
# Called (deferred) from an after-resize-pane tmux hook in 3+ pane windows.
# Forces the leftmost pane to ~50% width; no-ops when already close, so the
# self-triggered resize settles after one correction instead of looping.
#
# $1 is the target window id (#{window_id}), passed by the hook so every tmux
# call is scoped explicitly and never depends on an ambiguous "current" session.
set -euo pipefail

win="${1:-}"
[ -n "$win" ] || exit 0

win_width="$(tmux display-message -p -t "$win" '#{window_width}')" || exit 0
[ -n "$win_width" ] || exit 0

# leftmost pane: pane_at_left == 1
read -r left_id left_width < <(
  tmux list-panes -t "$win" -F '#{pane_at_left} #{pane_id} #{pane_width}' \
    | awk '$1==1 {print $2, $3; exit}'
) || exit 0
[ -n "${left_id:-}" ] || exit 0

target=$(( win_width / 2 ))
diff=$(( left_width - target ))
[ "$diff" -lt 0 ] && diff=$(( -diff ))

# Tolerance of 2 cells avoids oscillation from integer rounding.
if [ "$diff" -gt 2 ]; then
  tmux resize-pane -t "$left_id" -x 50% 2>/dev/null || true
fi
