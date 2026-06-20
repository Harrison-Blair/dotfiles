#!/bin/sh
# Wallpaper helper for awww (https://github.com/many-people/awww).
#
# Why this wrapper exists:
#   * awww derives its cache directory from $HOMEBREW_PREFIX. This user's
#     interactive shell sources Homebrew (~/.bashrc), which would send the cache
#     to an unwritable $HOMEBREW_PREFIX/.cache/awww ("failed to store cache").
#     We unset that ONE variable for the awww process only -- PATH, brew, and the
#     interactive shell are left completely untouched -- so the cache lands in
#     ~/.cache/awww, where `awww restore` can read it.
#   * awww-daemon does NOT auto-restore on startup, and at login Hyprland brings
#     the outputs up one by one, so the no-arg path waits for the output list to
#     settle before restoring -- otherwise a late monitor (e.g. the focused DP-1)
#     is missed. This is the startup race the old WallRizz kitty script hit.
#
# Usage:
#   wallpaper.sh <image>   set the wallpaper on all outputs and cache it
#   wallpaper.sh           restore the cached wallpaper (used at login)

unset HOMEBREW_PREFIX

# Ensure the daemon is running.
if ! awww query >/dev/null 2>&1; then
    awww-daemon >/dev/null 2>&1 &
    n=0
    while [ "$n" -lt 30 ] && ! awww query >/dev/null 2>&1; do
        n=$((n + 1))
        sleep 0.2
    done
fi

# Set a new wallpaper (default resize is cover-crop / "fill").
if [ "$#" -ge 1 ]; then
    exec awww img "$(realpath "$1")"
fi

# No argument: login restore. Wait until the output list is stable for three
# consecutive polls so every monitor is present before we paint.
prev=""
stable=0
n=0
while [ "$n" -lt 50 ]; do
    cur=$(awww query 2>/dev/null | sort)
    if [ -n "$cur" ] && [ "$cur" = "$prev" ]; then
        stable=$((stable + 1))
        [ "$stable" -ge 3 ] && break
    else
        stable=0
    fi
    prev="$cur"
    n=$((n + 1))
    sleep 0.2
done

awww restore
