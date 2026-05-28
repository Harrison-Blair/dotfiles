#!/usr/bin/env bash
# Single waybar sensors module. Emits one JSON payload:
#   text    -> three icon+temp pairs (CPU, GPU, SSD) in pango markup. Any
#              category that isn't detected is omitted from the bar.
#   tooltip -> every temperature reported by /sys/class/hwmon (+ nvidia-smi if
#              available), grouped by chip, with per-chip label-column padding.
#              Chip headers carry the same category icons the old per-module
#              setup used (CPU, dGPU, iGPU, NVMe).
#   class   -> "critical" when any of CPU/GPU/SSD exceeds its threshold.
#
# Portable across machines: enumerates whatever hwmon chips are present and
# disambiguates amdgpu by presence of temp3_input (dGPU vs iGPU). Same script
# runs on the AMD desktop and on the Razer Blade 15 (Intel + NVIDIA + Intel
# iGPU) without configuration.

set -euo pipefail
shopt -s nullglob

# Icons reused from the prior per-module setup. Don't introduce new glyphs.
readonly ICON_CPU=""
readonly ICON_DGPU="󰢮"
readonly ICON_IGPU="󰍛"
readonly ICON_GPU_MEM="󰧶"
readonly ICON_NVME="󰋊"

readonly CRIT_COLOR="#dd532e"
readonly CRIT_CPU=85
readonly CRIT_GPU_DGPU=90
readonly CRIT_GPU_IGPU=90
readonly CRIT_GPU_MEM=95
readonly CRIT_NVME=75

pango_escape() {
	local s="$1"
	s="${s//&/&amp;}"
	s="${s//</&lt;}"
	s="${s//>/&gt;}"
	s="${s//\"/&quot;}"
	printf '%s' "$s"
}

# millideg -> "NN.N" (one decimal place, no unit)
read_temp_decimal() {
	awk -v raw="$(<"$1")" 'BEGIN{ printf "%.1f", raw/1000 }'
}

# millideg -> rounded integer (for threshold comparisons)
read_temp_int() {
	local raw
	raw=$(<"$1")
	printf '%d' $(( (raw + 500) / 1000 ))
}

# Returns the critical threshold for a given chip name + temp file path.
# Echoes 0 (no threshold) when the chip+sensor combo isn't a CPU/GPU/SSD.
threshold_for() {
	local chip="$1" temp_input="$2" chip_dir="$3"
	case "$chip" in
		k10temp|coretemp|zenpower)
			printf '%d' "$CRIT_CPU" ;;
		amdgpu)
			if [[ "$temp_input" == *temp3_input ]]; then
				printf '%d' "$CRIT_GPU_MEM"
			elif [[ -e "$chip_dir/temp3_input" ]]; then
				printf '%d' "$CRIT_GPU_DGPU"
			else
				printf '%d' "$CRIT_GPU_IGPU"
			fi ;;
		i915)
			printf '%d' "$CRIT_GPU_IGPU" ;;
		nvidia)
			printf '%d' "$CRIT_GPU_DGPU" ;;
		nvme)
			printf '%d' "$CRIT_NVME" ;;
		*)
			printf '0' ;;
	esac
}

# Collect rows in parallel arrays. Each "group" is one chip header followed by
# its rows; we build the tooltip with per-group label padding at the end.
declare -a group_headers=()
declare -a group_icons=()    # per-group leading icon ("" when chip has none)
declare -a group_labels=()   # newline-joined labels per group
declare -a group_values=()   # newline-joined values per group (raw decimal)
declare -a group_crits=()    # newline-joined critical flags (0/1) per group
declare -a group_row_icons=() # newline-joined per-row leading icons (mostly "")

# Headline slots: CPU, GPU, SSD. Each captures the first matching reading
# (in hwmon scan order, with GPU preferring dGPU over iGPU via priority).
cpu_headline=""; cpu_headline_crit=0
gpu_headline=""; gpu_headline_crit=0; gpu_headline_icon=""; gpu_priority=99
ssd_headline=""; ssd_headline_crit=0
any_critical=0

for h in /sys/class/hwmon/hwmon*; do
	[[ -r "$h/name" ]] || continue
	chip="$(<"$h/name")"

	# Collect this chip's temps
	labels=""
	values=""
	crits=""
	row_icons=""
	have_any=0

	for inp in "$h"/temp*_input; do
		[[ -r "$inp" ]] || continue
		base="${inp%_input}"
		short="$(basename "$base")"  # e.g. temp1
		label=""
		[[ -r "${base}_label" ]] && label="$(<"${base}_label")"
		[[ -z "$label" ]] && label="$short"

		val=$(read_temp_decimal "$inp")
		val_int=$(read_temp_int "$inp")

		crit_thresh=$(threshold_for "$chip" "$inp" "$h")
		crit_flag=0
		if (( crit_thresh > 0 )) && (( val_int >= crit_thresh )); then
			crit_flag=1
			any_critical=1
		fi

		row_icon=""
		# Surface the GPU-mem icon on the amdgpu dGPU's mem row only — that's
		# the row the old custom/temp-gpu-mem module showed.
		if [[ "$chip" == "amdgpu" ]] && [[ "$inp" == *temp3_input ]] && [[ -e "$h/temp3_input" ]]; then
			row_icon="$ICON_GPU_MEM"
		fi

		labels+="${label}"$'\n'
		values+="${val}"$'\n'
		crits+="${crit_flag}"$'\n'
		row_icons+="${row_icon}"$'\n'
		have_any=1

		# Headline captures: CPU (k10temp/coretemp/zenpower temp1), GPU edge
		# (dGPU preferred, then iGPU, then i915 — nvidia handled below), and
		# SSD (nvme temp1, the Composite reading).
		if [[ "$inp" == *temp1_input ]]; then
			case "$chip" in
				k10temp|coretemp|zenpower)
					if [[ -z "$cpu_headline" ]]; then
						cpu_headline="$val_int"
						cpu_headline_crit="$crit_flag"
					fi
					;;
				amdgpu)
					# Priority: dGPU=1, iGPU=2. Lower wins. Only the edge
					# reading (temp1) becomes the headline.
					if [[ -e "$h/temp3_input" ]]; then
						p=1; ico="$ICON_DGPU"
					else
						p=2; ico="$ICON_IGPU"
					fi
					if (( p < gpu_priority )); then
						gpu_headline="$val_int"
						gpu_headline_crit="$crit_flag"
						gpu_headline_icon="$ico"
						gpu_priority=$p
					fi
					;;
				i915)
					if (( 3 < gpu_priority )); then
						gpu_headline="$val_int"
						gpu_headline_crit="$crit_flag"
						gpu_headline_icon="$ICON_IGPU"
						gpu_priority=3
					fi
					;;
				nvme)
					if [[ -z "$ssd_headline" ]]; then
						ssd_headline="$val_int"
						ssd_headline_crit="$crit_flag"
					fi
					;;
			esac
		fi
	done

	(( have_any )) || continue

	header="$chip"
	icon=""
	case "$chip" in
		k10temp|coretemp|zenpower) icon="$ICON_CPU" ;;
		nvme)                      icon="$ICON_NVME" ;;
		i915)                      icon="$ICON_IGPU" ;;
		amdgpu)
			if [[ -e "$h/temp3_input" ]]; then
				header="amdgpu (dGPU)"
				icon="$ICON_DGPU"
			else
				header="amdgpu (iGPU)"
				icon="$ICON_IGPU"
			fi ;;
	esac

	group_headers+=("$header")
	group_icons+=("$icon")
	group_labels+=("${labels%$'\n'}")
	group_values+=("${values%$'\n'}")
	group_crits+=("${crits%$'\n'}")
	group_row_icons+=("${row_icons%$'\n'}")
done

# NVIDIA: synthetic group from nvidia-smi.
if command -v nvidia-smi >/dev/null 2>&1; then
	nv_raw="$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -d '[:space:]')"
	if [[ -n "$nv_raw" ]] && [[ "$nv_raw" =~ ^[0-9]+$ ]]; then
		nv_val=$(printf '%.1f' "$nv_raw")
		nv_crit=0
		if (( nv_raw >= CRIT_GPU_DGPU )); then
			nv_crit=1
			any_critical=1
		fi
		group_headers+=("nvidia")
		group_icons+=("$ICON_DGPU")
		group_labels+=("GPU")
		group_values+=("$nv_val")
		group_crits+=("$nv_crit")
		group_row_icons+=("")

		# Headline fallback if no amdgpu/i915 grabbed the GPU slot.
		if (( 4 < gpu_priority )); then
			gpu_headline="$nv_raw"
			gpu_headline_crit="$nv_crit"
			gpu_headline_icon="$ICON_DGPU"
			gpu_priority=4
		fi
	fi
fi

# Build tooltip
tooltip=""
for i in "${!group_headers[@]}"; do
	header="${group_headers[$i]}"
	header_icon="${group_icons[$i]}"
	# mapfile (not IFS+read) so leading/consecutive empty rows are preserved —
	# row_icons in particular is mostly empty for non-mem rows.
	mapfile -t labels_arr    <<< "${group_labels[$i]}"
	mapfile -t values_arr    <<< "${group_values[$i]}"
	mapfile -t crits_arr     <<< "${group_crits[$i]}"
	mapfile -t row_icons_arr <<< "${group_row_icons[$i]}"

	# Find max label width within this group (min 18 for wider tooltip, cap at 24).
	maxw=0
	for lbl in "${labels_arr[@]}"; do
		w=${#lbl}
		(( w > maxw )) && maxw=$w
	done
	(( maxw < 18 )) && maxw=18
	(( maxw > 24 )) && maxw=24

	[[ -n "$tooltip" ]] && tooltip+=$'\n'
	if [[ -n "$header_icon" ]]; then
		tooltip+="${header_icon}  $(pango_escape "$header")"
	else
		tooltip+="$(pango_escape "$header")"
	fi

	for j in "${!labels_arr[@]}"; do
		lbl="${labels_arr[$j]}"
		val="${values_arr[$j]}"
		crit="${crits_arr[$j]}"
		row_icon="${row_icons_arr[$j]:-}"
		esc_lbl="$(pango_escape "$lbl")"
		pad=$(( maxw - ${#lbl} ))
		(( pad < 0 )) && pad=0
		spaces=""
		if (( pad > 0 )); then
			spaces=$(printf '%*s' "$pad" '')
		fi
		row_prefix="  "
		[[ -n "$row_icon" ]] && row_prefix="${row_icon} "
		if [[ "$crit" == "1" ]]; then
			tooltip+=$'\n'"${row_prefix}${esc_lbl}${spaces}  <span color=\"${CRIT_COLOR}\">${val}°C</span>"
		else
			tooltip+=$'\n'"${row_prefix}${esc_lbl}${spaces}  ${val}°C"
		fi
	done
done

[[ -z "$tooltip" ]] && tooltip="no sensors detected"

# Build text: CPU, GPU, SSD pairs side-by-side. Each pair is omitted entirely
# if that category isn't detected on this machine. Critical color applies
# per-pair.
make_pair() {
	local icon="$1" temp="$2" crit="$3"
	if [[ "$crit" == "1" ]]; then
		printf '<span size="x-large" color="%s">%s</span>  <span color="%s">%s°</span>' \
			"$CRIT_COLOR" "$icon" "$CRIT_COLOR" "$temp"
	else
		printf '<span size="x-large">%s</span>  %s°' "$icon" "$temp"
	fi
}

parts=()
[[ -n "$cpu_headline" ]] && parts+=("$(make_pair "$ICON_CPU" "$cpu_headline" "$cpu_headline_crit")")
[[ -n "$gpu_headline" ]] && parts+=("$(make_pair "$gpu_headline_icon" "$gpu_headline" "$gpu_headline_crit")")
[[ -n "$ssd_headline" ]] && parts+=("$(make_pair "$ICON_NVME" "$ssd_headline" "$ssd_headline_crit")")

if (( ${#parts[@]} > 0 )); then
	text="${parts[0]}"
	for ((k=1; k<${#parts[@]}; k++)); do
		text+="  ${parts[$k]}"
	done
else
	# No CPU/GPU/SSD detected — show CPU icon alone (placeholder) so module
	# stays visible. Tooltip still shows whatever sensors did report.
	if (( any_critical )); then
		text="<span size=\"x-large\" color=\"${CRIT_COLOR}\">${ICON_CPU}</span>"
	else
		text="<span size=\"x-large\">${ICON_CPU}</span>"
	fi
fi

cls=""
(( any_critical )) && cls="critical"

# Hand-roll JSON (jq isn't guaranteed installed). Escape backslash, quote,
# newline, carriage return, tab, and any other control chars.
json_escape() {
	local s="$1"
	s="${s//\\/\\\\}"
	s="${s//\"/\\\"}"
	s="${s//$'\n'/\\n}"
	s="${s//$'\r'/\\r}"
	s="${s//$'\t'/\\t}"
	printf '%s' "$s"
}

printf '{"text":"%s","tooltip":"%s","class":"%s"}\n' \
	"$(json_escape "$text")" \
	"$(json_escape "$tooltip")" \
	"$(json_escape "$cls")"
