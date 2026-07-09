#!/usr/bin/env bash
# Claude Code status line
# Layout: model: effort | tk / max | 5h: % [H:M] | w: % [d:h:m]
# JSON is parsed with the system python3 (no jq dependency).
input=$(cat)

# Extract every field in a single python3 pass. Outputs 12 lines, in order:
#   model, effort, cw_size, used_pct, input_tokens, cache_write, cache_read,
#   has_usage, five_pct, week_pct, five_reset, week_reset
# An empty line means the field is absent.
fields=$(printf '%s' "$input" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
cw = d.get("context_window") or {}
usage = cw.get("current_usage")
u = usage or {}
rl = d.get("rate_limits") or {}
five = rl.get("five_hour") or {}
week = rl.get("seven_day") or {}

# Persist the latest rate_limits capture for the usage monitor (cc-push.sh
# ships this to the homelab aggregator). Must never break the status line.
try:
    import os, socket, time, tempfile
    if rl:
        state_dir = os.path.expanduser("~/.local/state/claude-usage")
        os.makedirs(state_dir, exist_ok=True)
        cap = {
            "host": socket.gethostname(),
            "captured_at": int(time.time()),
            "five_hour_pct": five.get("used_percentage"),
            "five_hour_reset": five.get("resets_at"),
            "seven_day_pct": week.get("used_percentage"),
            "seven_day_reset": week.get("resets_at"),
            "model": (d.get("model") or {}).get("display_name"),
        }
        fd, tmp = tempfile.mkstemp(dir=state_dir)
        with os.fdopen(fd, "w") as f:
            json.dump(cap, f)
        os.replace(tmp, os.path.join(state_dir, "capture.json"))
except Exception:
    pass

def s(v):
    return "" if v is None else v
print(s((d.get("model") or {}).get("display_name")))
print(s((d.get("effort") or {}).get("level")))
print(s(cw.get("context_window_size")))
print(s(cw.get("used_percentage")))
print(u.get("input_tokens", 0))
print(u.get("cache_creation_input_tokens", 0))
print(u.get("cache_read_input_tokens", 0))
print("no" if usage is None else "yes")
print(s(five.get("used_percentage")))
print(s(week.get("used_percentage")))
print(s(five.get("resets_at")))
print(s(week.get("resets_at")))
')

{ read -r model
  read -r effort
  read -r cw_size
  read -r used_pct
  read -r input_tokens
  read -r cache_write
  read -r cache_read
  read -r has_usage
  read -r five_pct
  read -r week_pct
  read -r five_reset
  read -r week_reset
} <<EOF
$fields
EOF

# Total context tokens = input_tokens + cache_creation_input_tokens + cache_read_input_tokens
# input_tokens alone undercounts when caching is active (cached tokens move to cache_read_input_tokens)
total_ctx_tokens=""
if [ "$has_usage" = "yes" ]; then
  total_ctx_tokens=$(awk "BEGIN { print $input_tokens + $cache_write + $cache_read }")
fi

# Format a token count with k/M suffix, rounding sensibly so e.g. 999500
# rounds up to 1M rather than truncating to 1000k.
format_count() {
  awk -v n="$1" 'BEGIN {
    if (n >= 1000000) {
      m = n / 1000000
      rm = int(m * 10 + 0.5) / 10
      if (rm == int(rm)) printf "%dM", rm
      else printf "%.1fM", rm
      exit
    }
    rk = int(n / 1000 + 0.5)
    if (rk >= 1000) {
      m = rk / 1000
      if (m == int(m)) printf "%dM", m
      else printf "%.1fM", m
    } else {
      printf "%dk", rk
    }
  }'
}

parts=()

# model: effort — always first
if [ -n "$model" ]; then
  model_str=$(printf '\033[36m%s\033[0m' "$model")
  [ -n "$effort" ] && model_str="$model_str$(printf '\033[2m: %s\033[0m' "$effort")"
  parts+=("$model_str")
fi

# ctx: tk/max — colored by compaction proximity (used_percentage thresholds)
if [ -n "$total_ctx_tokens" ] && [ -n "$cw_size" ]; then
  ctx_color='\033[36m'       # Cyan — no concern
  if [ -n "$used_pct" ]; then
    used_int=$(printf '%.0f' "$used_pct")

    # Claude Code compacts around 85-90% used; warn at >= 70%, danger at >= 85%
    if [ "$used_int" -ge 85 ]; then
      ctx_color='\033[31m'   # Red — imminent compaction
    elif [ "$used_int" -ge 70 ]; then
      ctx_color='\033[33m'   # Yellow — getting close
    fi
  fi
  ctx_str=$(printf "${ctx_color}%s\033[0m\033[2m / %s\033[0m" "$(format_count "$total_ctx_tokens")" "$(format_count "$cw_size")")

  parts+=("$ctx_str")
fi

# Format an absolute unix-epoch reset time in 24-hour clock. Style "time"
# renders "19:00"; style "date" prefixes the date, e.g. "Jul 9 19:00".
fmt_reset() {
  if [ "$2" = "date" ]; then
    date -d "@$1" '+%b %-d %H:%M'
  else
    date -d "@$1" '+%H:%M'
  fi
}

# Rate limit segments: used-percentage colored by usage thresholds, followed by
# the reset time ("[7pm]" for 5h, "[Jul 9]" for weekly) when present.
rate_part() {
  local label="$1" pct="$2" reset="$3" style="$4"
  [ -z "$pct" ] && return
  local pct_int color seg
  pct_int=$(printf '%.0f' "$pct")
  if [ "$pct_int" -ge 90 ]; then
    color='\033[31m'   # Red — nearly exhausted
  elif [ "$pct_int" -ge 70 ]; then
    color='\033[33m'   # Yellow — getting low
  else
    color='\033[32m'   # Green — plenty left
  fi
  seg=$(printf '\033[36m%s:\033[0m '"${color}"'%d%%\033[0m' "$label" "$pct_int")
  if [ -n "$reset" ]; then
    seg="$seg$(printf ' \033[2m[%s]\033[0m' "$(fmt_reset "$reset" "$style")")"
  fi
  printf '%s' "$seg"
}

p=$(rate_part "5h" "$five_pct" "$five_reset" "time"); [ -n "$p" ] && parts+=("$p")
p=$(rate_part "w" "$week_pct" "$week_reset" "date");  [ -n "$p" ] && parts+=("$p")

out=""
for i in "${!parts[@]}"; do
  if [ "$i" -eq 0 ]; then
    out="${parts[$i]}"
  else
    out="${out} | ${parts[$i]}"
  fi
done
printf '%s' "$out"
