#!/usr/bin/env bash
# Claude Code status line — context window + compaction proximity + rate limits
# JSON is parsed with the system python3 (no jq dependency).
input=$(cat)

# Extract every field in a single python3 pass. Outputs 9 lines, in order:
#   model, cw_size, used_pct, input_tokens, cache_write, cache_read,
#   has_usage, five_pct, five_resets
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
rl = (d.get("rate_limits") or {}).get("five_hour") or {}
def s(v):
    return "" if v is None else v
print(s((d.get("model") or {}).get("display_name")))
print(s(cw.get("context_window_size")))
print(s(cw.get("used_percentage")))
print(u.get("input_tokens", 0))
print(u.get("cache_creation_input_tokens", 0))
print(u.get("cache_read_input_tokens", 0))
print("no" if usage is None else "yes")
print(s(rl.get("used_percentage")))
print(s(rl.get("resets_at")))
')

{ read -r model
  read -r cw_size
  read -r used_pct
  read -r input_tokens
  read -r cache_write
  read -r cache_read
  read -r has_usage
  read -r five_pct
  read -r five_resets
} <<EOF
$fields
EOF

# Total context tokens = input_tokens + cache_creation_input_tokens + cache_read_input_tokens
# input_tokens alone undercounts when caching is active (cached tokens move to cache_read_input_tokens)
total_ctx_tokens=""
if [ "$has_usage" = "yes" ]; then
  total_ctx_tokens=$(awk "BEGIN { print $input_tokens + $cache_write + $cache_read }")
fi

# Format token count in K
tokens_k=""
if [ -n "$total_ctx_tokens" ] && [ "$total_ctx_tokens" -gt 0 ] 2>/dev/null; then
  tokens_k=$(awk "BEGIN { printf \"%.0fk\", $total_ctx_tokens / 1000 }")
fi

# Format context window size in K
cw_k=""
if [ -n "$cw_size" ]; then
  cw_k=$(awk "BEGIN { printf \"%.0fk\", $cw_size / 1000 }")
fi

# Build the context display
if [ -n "$tokens_k" ] && [ -n "$cw_k" ]; then
  ctx_part="${tokens_k} / ${cw_k}"

  if [ -n "$used_pct" ]; then
    used_int=$(printf '%.0f' "$used_pct")

    # Color the compaction proximity indicator
    # Claude Code compacts around 85-90% used; warn at >= 70%, danger at >= 85%
    if [ "$used_int" -ge 85 ]; then
      # Red — imminent compaction
      compact_label=$(printf '\033[31m(%d%% — compact soon)\033[0m' "$used_int")
    elif [ "$used_int" -ge 70 ]; then
      # Yellow — getting close
      compact_label=$(printf '\033[33m(%d%%)\033[0m' "$used_int")
    else
      # Dim — no concern
      compact_label=$(printf '\033[2m(%d%%)\033[0m' "$used_int")
    fi

    printf '\033[36mctx:\033[0m %s %s' "$ctx_part" "$compact_label"
  else
    printf '\033[36mctx:\033[0m %s' "$ctx_part"
  fi
elif [ -n "$model" ]; then
  printf '\033[2m%s\033[0m' "$model"
fi

# Rate limit section (5-hour session limit)
if [ -n "$five_pct" ]; then
  five_int=$(printf '%.0f' "$five_pct")
  remaining_int=$((100 - five_int))

  # Color based on how much is used
  if [ "$five_int" -ge 90 ]; then
    limit_color='\033[31m'   # Red — nearly exhausted
  elif [ "$five_int" -ge 70 ]; then
    limit_color='\033[33m'   # Yellow — getting low
  else
    limit_color='\033[32m'   # Green — plenty left
  fi

  # Format reset time as HH:MM if available
  reset_str=""
  if [ -n "$five_resets" ]; then
    reset_str=$(date -d "@${five_resets}" +"%H:%M" 2>/dev/null || date -r "${five_resets}" +"%H:%M" 2>/dev/null)
    [ -n "$reset_str" ] && reset_str=" resets ${reset_str}"
  fi

  printf '  \033[36m5h:\033[0m '"${limit_color}"'%d%% used (%d%% left)\033[0m\033[2m%s\033[0m' \
    "$five_int" "$remaining_int" "$reset_str"
fi
