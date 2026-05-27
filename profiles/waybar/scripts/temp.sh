#!/usr/bin/env bash
# Resolve a temperature sensor by chip name (k10temp, coretemp, amdgpu, nvme,
# i915, nvidia, ...) and emit waybar custom-module JSON. Silent (empty text,
# class "empty") when no matching sensor is present on this machine, so the
# same waybar config works on the AMD desktop and the Intel/NVIDIA laptop
# without throwing errors.
#
# Usage: temp.sh <module-key>
# Module keys are defined in the case statement below.

set -euo pipefail
shopt -s nullglob

emit() {
	local text="${1:-}" tooltip="${2:-}" cls="${3:-}"
	text="${text//\"/\\\"}"
	tooltip="${tooltip//\"/\\\"}"
	printf '{"text":"%s","tooltip":"%s","class":"%s"}\n' "$text" "$tooltip" "$cls"
	exit 0
}

empty() { emit "" "" "empty"; }

# find_hwmon NAME REQUIRE_FILE EXCLUDE_FILE
# Prints the first /sys/class/hwmon/hwmonN whose `name` matches NAME and which
# satisfies the optional require/exclude file constraints. Empty stdout if
# none match.
find_hwmon() {
	local want="$1" require="${2:-}" exclude="${3:-}"
	local h
	for h in /sys/class/hwmon/hwmon*; do
		[[ -r "$h/name" ]] || continue
		[[ "$(<"$h/name")" == "$want" ]] || continue
		[[ -n "$require" && ! -e "$h/$require" ]] && continue
		[[ -n "$exclude" && -e "$h/$exclude" ]] && continue
		printf '%s\n' "$h"
		return 0
	done
	return 1
}

read_temp_c() {
	# raw millideg -> rounded deg C
	local raw
	raw=$(<"$1")
	printf '%d\n' $(( (raw + 500) / 1000 ))
}

format_temp() {
	local icon="$1" t="$2" crit="$3" label="$4"
	local cls=""
	local span_icon="<span size=\"x-large\">${icon}</span>"
	if (( crit > 0 && t >= crit )); then
		cls="critical"
		span_icon="<span size=\"x-large\" color=\"#dd532e\">${icon}</span>"
		emit "${span_icon}  <span color=\"#dd532e\">${t}°</span>" "${label}: ${t}°C" "$cls"
	fi
	emit "${span_icon}  ${t}°" "${label}: ${t}°C" "$cls"
}

# Try a list of (chip,require,exclude) probes in order; first that resolves
# wins. probes is a packed array: "chip|require|exclude" entries.
probe_hwmon() {
	local input="$1" icon="$2" crit="$3" label="$4"
	shift 4
	local entry chip require exclude h t
	for entry in "$@"; do
		IFS='|' read -r chip require exclude <<<"$entry"
		if h=$(find_hwmon "$chip" "$require" "$exclude"); then
			[[ -r "$h/$input" ]] || continue
			t=$(read_temp_c "$h/$input")
			format_temp "$icon" "$t" "$crit" "$label"
		fi
	done
}

probe_nvidia() {
	local icon="$1" crit="$2" label="$3"
	command -v nvidia-smi >/dev/null 2>&1 || return 1
	local t
	t=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -d '[:space:]')
	[[ -n "$t" ]] || return 1
	format_temp "$icon" "$t" "$crit" "$label"
}

case "${1:-}" in
	cpu)
		probe_hwmon temp1_input "" 85 "CPU" \
			"k10temp||" "coretemp||" "zenpower||"
		empty
		;;

	gpu)
		# Discrete GPU. AMD dGPU's hwmon has temp3_input (VRAM); APU hwmon
		# does not -- the require filter picks the dGPU on the desktop and
		# ignores the iGPU. Falls through to NVIDIA on the laptop.
		probe_hwmon temp1_input "󰢮" 90 "dGPU edge" \
			"amdgpu|temp3_input|"
		probe_nvidia "󰢮" 90 "NVIDIA GPU" || true
		empty
		;;

	gpu-mem)
		# AMD dGPU VRAM only -- no NVIDIA equivalent we expose here.
		probe_hwmon temp3_input "󰧶" 95 "dGPU memory" \
			"amdgpu||"
		empty
		;;

	igpu)
		# Integrated GPU. AMD APU has amdgpu hwmon WITHOUT temp3_input; the
		# exclude filter avoids matching the dGPU. Intel iGPUs occasionally
		# expose an i915 hwmon, fall back to that.
		probe_hwmon temp1_input "󰍛" 90 "iGPU" \
			"amdgpu||temp3_input" "i915||"
		empty
		;;

	nvme)
		probe_hwmon temp1_input "󰋊" 75 "NVMe" \
			"nvme||"
		empty
		;;

	*)
		empty
		;;
esac
