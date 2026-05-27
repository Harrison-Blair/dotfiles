#!/usr/bin/env bash
# Detects the geometric center monitor (sorting all monitors by their
# horizontal center, picking the middle one) and writes
#   $CENTER = <name>
# to ~/.cache/hyprlock-monitors.conf, which hyprlock.conf sources.
# Then execs hyprlock.

set -euo pipefail

cache="${XDG_CACHE_HOME:-$HOME/.cache}"
mkdir -p "$cache"

center=$(hyprctl monitors | awk '
    /^Monitor / { name = $2 }
    $1 ~ /^[0-9]+x[0-9]+@/ {
        split($1, mode, /[x@]/); w = mode[1] + 0
        split($3, pos, /x/);     x = pos[1] + 0
        n++; names[n] = name; cx[n] = x + w / 2
    }
    END {
        for (i = 1; i <= n; i++)
            for (j = i + 1; j <= n; j++)
                if (cx[j] < cx[i]) {
                    t = cx[i];    cx[i]    = cx[j];    cx[j]    = t
                    t = names[i]; names[i] = names[j]; names[j] = t
                }
        print names[int((n - 1) / 2) + 1]
    }
')

if [[ -z "$center" ]]; then
    echo "hyprlock-launch: could not detect center monitor" >&2
    exit 1
fi

printf '$CENTER = %s\n' "$center" > "$cache/hyprlock-monitors.conf"

exec hyprlock "$@"
