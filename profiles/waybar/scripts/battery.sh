#!/usr/bin/env bash
# Emit waybar custom-module JSON for /sys/class/power_supply/BAT*. Empty
# (class "empty") on machines with no battery, so the same waybar config
# works on the desktop without showing a phantom module.

set -euo pipefail
shopt -s nullglob

emit() {
	local text="${1:-}" tooltip="${2:-}" cls="${3:-}"
	text="${text//\"/\\\"}"
	tooltip="${tooltip//\"/\\\"}"
	printf '{"text":"%s","tooltip":"%s","class":"%s"}\n' "$text" "$tooltip" "$cls"
	exit 0
}

bats=(/sys/class/power_supply/BAT*)
[[ ${#bats[@]} -gt 0 ]] || emit "" "" "empty"

bat="${bats[0]}"
[[ -r "$bat/capacity" && -r "$bat/status" ]] || emit "" "" "empty"

cap=$(<"$bat/capacity")
status=$(<"$bat/status")

case "$status" in
	Charging|Full)
		icon="󰂄"
		;;
	*)
		if   (( cap < 10 )); then icon="󰂎"
		elif (( cap < 25 )); then icon="󰁻"
		elif (( cap < 50 )); then icon="󰁾"
		elif (( cap < 75 )); then icon="󰂀"
		else                      icon="󰂂"
		fi
		;;
esac

cls=""
span="<span size=\"x-large\">${icon}</span>"
if (( cap < 15 )) && [[ "$status" != Charging && "$status" != Full ]]; then
	cls="critical"
	span="<span size=\"x-large\" color=\"#dd532e\">${icon}</span>"
	emit "${span}  <span color=\"#dd532e\">${cap}%</span>" "Battery: ${cap}% (${status})" "$cls"
fi

emit "${span}  ${cap}%" "Battery: ${cap}% (${status})" "$cls"
