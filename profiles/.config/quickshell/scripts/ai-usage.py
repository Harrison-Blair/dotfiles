#!/usr/bin/env python3
"""AI usage aggregator for the AiUsage quickshell widget.

Prints one JSON object with per-provider usage (Claude Code, Cursor, OpenCode):
limits/resets where available, plus cost + tokens for day / week / month.
Always exits 0; each provider carries its own status/error so one failure
never blanks the widget. Never prints tokens or credentials.

Windows: day = since local midnight; week/month = last 7/30 calendar days
(Cursor uses exact ms ranges — close enough for a glance widget).
"""
import glob
import json
import os
import sqlite3
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta

HOME = os.path.expanduser("~")
CACHE_DIR = os.path.join(HOME, ".cache", "quickshell-ai-usage")
STATE_PATH = os.path.join(CACHE_DIR, "state.json")
API_TTL = 300  # min seconds between calls to any vendor API
HTTP_TIMEOUT = 5

# $/MTok: (input, output, cache_write, cache_read); matched by model-id prefix,
# longest prefix wins. Cache write = 1.25x input, cache read = 0.1x input.
CLAUDE_PRICES = {
    "claude-opus-4-8": (5.0, 25.0, 6.25, 0.50),
    "claude-fable-5": (10.0, 50.0, 12.50, 1.00),
    "claude-sonnet-5": (3.0, 15.0, 3.75, 0.30),
    "claude-sonnet-4-6": (3.0, 15.0, 3.75, 0.30),
    "claude-haiku-4-5": (1.0, 5.0, 1.25, 0.10),
}

EMPTY_WINDOW = {"cost": 0.0, "input": 0, "output": 0, "cache_read": 0, "cache_write": 0}

# OpenCode Go plan: $ limits per rolling window (opencode.ai/docs/go/).
OPENCODE_GO_LIMITS = (12.0, 30.0, 60.0)
OPENCODE_GO_WINDOWS_H = (5, 7 * 24, 30 * 24)


def load_state():
    try:
        with open(STATE_PATH) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_state(state):
    # Per-pid temp file: two widget instances (one per monitor) run this script
    # concurrently and must not clobber each other's rename.
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        tmp = "%s.tmp.%d" % (STATE_PATH, os.getpid())
        with open(tmp, "w") as f:
            json.dump(state, f)
        os.replace(tmp, STATE_PATH)
    except OSError:
        pass


def http_json(url, headers, body=None):
    data = json.dumps(body).encode() if body is not None else None
    if body is not None:
        headers = dict(headers, **{"Content-Type": "application/json"})
    req = urllib.request.Request(url, data=data, headers=headers)
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as r:
        return json.loads(r.read().decode())


def local_dates(days):
    """Today and the previous days-1 local calendar dates as YYYY-MM-DD strings."""
    today = datetime.now().date()
    return {str(today - timedelta(days=i)) for i in range(days)}


# --- Claude Code -------------------------------------------------------------

def claude_price(model):
    for prefix in sorted(CLAUDE_PRICES, key=len, reverse=True):
        if model.startswith(prefix):
            return CLAUDE_PRICES[prefix]
    return None


def claude_scan(state):
    """Incrementally aggregate ~/.claude/projects transcripts.

    Per-file cache: {mtime, size, buckets: {date: {model: [in, out, cw, cr]}},
    ids: [...]}. Dedupe on message.id + requestId across files (resumed
    sessions duplicate entries).
    """
    files_state = state.setdefault("claude_files", {})
    paths = glob.glob(os.path.join(HOME, ".claude", "projects", "**", "*.jsonl"),
                      recursive=True)
    path_set = set(paths)
    for p in list(files_state):
        if p not in path_set:
            del files_state[p]

    changed = []
    for p in paths:
        try:
            st = os.stat(p)
        except OSError:
            continue
        entry = files_state.get(p)
        if not entry or entry["mtime"] != st.st_mtime or entry["size"] != st.st_size:
            changed.append((st.st_mtime, st.st_size, p))

    changed_paths = {p for _, _, p in changed}
    seen_ids = set()
    for p, entry in files_state.items():
        if p not in changed_paths:
            seen_ids.update(entry["ids"])

    for mtime, size, p in sorted(changed):
        buckets, ids = {}, []
        try:
            with open(p, errors="replace") as f:
                for line in f:
                    try:
                        obj = json.loads(line)
                    except ValueError:
                        continue
                    msg = obj.get("message") or {}
                    usage = msg.get("usage")
                    model = msg.get("model") or ""
                    ts = obj.get("timestamp")
                    if not usage or not ts or model in ("", "<synthetic>"):
                        continue
                    uid = (msg.get("id") or "") + ":" + (obj.get("requestId") or "")
                    if uid != ":":
                        if uid in seen_ids:
                            continue
                        seen_ids.add(uid)
                        ids.append(uid)
                    try:
                        date = str(datetime.fromisoformat(
                            ts.replace("Z", "+00:00")).astimezone().date())
                    except ValueError:
                        continue
                    tok = buckets.setdefault(date, {}).setdefault(model, [0, 0, 0, 0])
                    tok[0] += usage.get("input_tokens") or 0
                    tok[1] += usage.get("output_tokens") or 0
                    tok[2] += usage.get("cache_creation_input_tokens") or 0
                    tok[3] += usage.get("cache_read_input_tokens") or 0
        except OSError:
            continue
        files_state[p] = {"mtime": mtime, "size": size, "buckets": buckets, "ids": ids}

    # Aggregate windows; cost computed here so price edits don't force rescans.
    windows = {"day": local_dates(1), "week": local_dates(7), "month": local_dates(30)}
    usage = {w: dict(EMPTY_WINDOW) for w in windows}
    unpriced = set()
    for entry in files_state.values():
        for date, models in entry["buckets"].items():
            for w, dates in windows.items():
                if date not in dates:
                    continue
                for model, (ti, to, cw, cr) in models.items():
                    agg = usage[w]
                    agg["input"] += ti
                    agg["output"] += to
                    agg["cache_write"] += cw
                    agg["cache_read"] += cr
                    price = claude_price(model)
                    if price:
                        agg["cost"] += (ti * price[0] + to * price[1]
                                        + cw * price[2] + cr * price[3]) / 1e6
                    else:
                        unpriced.add(model)
    for agg in usage.values():
        agg["cost"] = round(agg["cost"], 2)
    return usage, sorted(unpriced)


def claude_limits(state, now):
    """Session/weekly utilization from Anthropic's OAuth usage endpoint,
    throttled to API_TTL. Returns (limits|None, status, error)."""
    cached = state.get("claude_limits", {})
    if now - cached.get("fetched_at", 0) < API_TTL:
        return cached.get("data"), "ok", None

    def stale(err):
        return cached.get("data"), ("stale" if cached.get("data") else "error"), err

    try:
        with open(os.path.join(HOME, ".claude", ".credentials.json")) as f:
            oauth = json.load(f)["claudeAiOauth"]
    except (OSError, ValueError, KeyError):
        return stale("no Claude credentials")
    if oauth.get("expiresAt", 0) / 1000 < now:
        return stale("token expired — open Claude Code to refresh")

    try:
        resp = http_json(
            "https://api.anthropic.com/api/oauth/usage",
            {"Authorization": "Bearer " + oauth["accessToken"],
             "anthropic-beta": "oauth-2025-04-20",
             "User-Agent": "claude-code/2.1.199"})
    except Exception as e:
        return stale("usage fetch failed: " + type(e).__name__)

    def pct(block):
        return round(block["utilization"]) if block else None

    extra = resp.get("extra_usage") or {}
    data = {
        "session_pct": pct(resp.get("five_hour")),
        "session_resets_at": (resp.get("five_hour") or {}).get("resets_at"),
        "week_pct": pct(resp.get("seven_day")),
        "week_resets_at": (resp.get("seven_day") or {}).get("resets_at"),
        "week_opus_pct": pct(resp.get("seven_day_opus")),
        # No monthly limit on subscription plans; extra-usage credits are the
        # only monthly quota, present when enabled.
        "month_pct": round(extra["utilization"]) if extra.get("is_enabled") else None,
        "plan": oauth.get("subscriptionType"),
        "fetched_at": int(now),
    }
    state["claude_limits"] = {"fetched_at": now, "data": data}
    return data, "ok", None


def get_claude(state, now):
    out = {"status": "ok", "error": None, "limits": None,
           "usage": {w: dict(EMPTY_WINDOW) for w in ("day", "week", "month")},
           "unpriced_models": []}
    try:
        out["usage"], out["unpriced_models"] = claude_scan(state)
    except Exception as e:
        return {**out, "status": "error", "error": "transcript scan failed: " + type(e).__name__}
    out["limits"], out["status"], out["error"] = claude_limits(state, now)
    return out


# --- Cursor ------------------------------------------------------------------

def cursor_fetch(now):
    with open(os.path.join(HOME, ".config", "cursor", "auth.json")) as f:
        jwt = json.load(f)["accessToken"]
    import base64
    payload = jwt.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    user_id = json.loads(base64.urlsafe_b64decode(payload))["sub"].split("|")[-1]
    headers = {
        "Cookie": "WorkosCursorSessionToken=%s%%3A%%3A%s" % (user_id, jwt),
        "Origin": "https://cursor.com",
        "Referer": "https://cursor.com/dashboard",
        "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36",
    }

    summary = http_json("https://cursor.com/api/usage-summary", headers)
    plan = summary.get("individualUsage", {}).get("plan", {})
    limits = {
        # Cursor has no session/weekly limits; the billing-cycle % fills the
        # monthly slot so all providers share the same triple shape.
        "session_pct": None,
        "week_pct": None,
        "month_pct": round(plan.get("totalPercentUsed") or 0),
        "plan_pct": round(plan.get("totalPercentUsed") or 0, 1),
        "plan_used_usd": round((plan.get("used") or 0) / 100, 2),
        "plan_limit_usd": round((plan.get("limit") or 0) / 100, 2),
        "cycle_end": summary.get("billingCycleEnd"),
        "membership": summary.get("membershipType"),
    }

    midnight = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
    now_ms = int(now * 1000)
    starts = {"day": int(midnight.timestamp() * 1000),
              "week": now_ms - 7 * 86400_000,
              "month": now_ms - 30 * 86400_000}
    usage = {}
    for w, start in starts.items():
        # NB: adding userId/teamId to this body makes the endpoint 500.
        resp = http_json("https://cursor.com/api/dashboard/get-aggregated-usage-events",
                         headers, {"startDate": str(start), "endDate": str(now_ms)})
        usage[w] = {
            "cost": round((resp.get("totalCostCents") or 0) / 100, 2),
            "input": int(resp.get("totalInputTokens") or 0),
            "output": int(resp.get("totalOutputTokens") or 0),
            "cache_read": int(resp.get("totalCacheReadTokens") or 0),
            "cache_write": int(resp.get("totalCacheWriteTokens") or 0),
        }
    return {"limits": limits, "usage": usage}


def get_cursor(state, now):
    cached = state.get("cursor", {})
    if now - cached.get("fetched_at", 0) < API_TTL:
        return {"status": "ok", "error": None, **cached["data"]}
    try:
        data = cursor_fetch(now)
        state["cursor"] = {"fetched_at": now, "data": data}
        return {"status": "ok", "error": None, **data}
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            err = "Cursor auth rejected — re-run cursor-agent login"
        else:
            err = "Cursor API HTTP %d" % e.code
    except Exception as e:
        err = "Cursor fetch failed: " + type(e).__name__
    if cached.get("data"):
        return {"status": "stale", "error": err, **cached["data"]}
    return {"status": "error", "error": err, "limits": None,
            "usage": {w: dict(EMPTY_WINDOW) for w in ("day", "week", "month")}}


# --- OpenCode ----------------------------------------------------------------

def get_opencode(now):
    usage = {w: dict(EMPTY_WINDOW) for w in ("day", "week", "month")}
    db = os.path.join(HOME, ".local", "share", "opencode", "opencode.db")
    try:
        # mode=ro (not immutable): the db is live WAL, read-only is correct.
        con = sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=2)
        rows = con.execute("SELECT data FROM message").fetchall()
        con.close()
    except sqlite3.Error as e:
        return {"status": "error", "error": "opencode db: " + type(e).__name__,
                "usage": usage, "limits": None}
    windows = {"day": local_dates(1), "week": local_dates(7), "month": local_dates(30)}
    now_ms = now * 1000
    # Rolling opencode-go spend for the Go plan limit windows (5h/7d/30d).
    go_spend = [0.0, 0.0, 0.0]
    for (raw,) in rows:
        try:
            msg = json.loads(raw)
        except ValueError:
            continue
        if msg.get("role") != "assistant":
            continue
        created = (msg.get("time") or {}).get("created")
        if not created:
            continue
        cost = msg.get("cost") or 0
        if msg.get("providerID") == "opencode-go":
            for i, hours in enumerate(OPENCODE_GO_WINDOWS_H):
                if created >= now_ms - hours * 3600_000:
                    go_spend[i] += cost
        date = str(datetime.fromtimestamp(created / 1000).date())
        tok = msg.get("tokens") or {}
        cache = tok.get("cache") or {}
        for w, dates in windows.items():
            if date not in dates:
                continue
            agg = usage[w]
            agg["cost"] += cost
            agg["input"] += tok.get("input") or 0
            agg["output"] += (tok.get("output") or 0) + (tok.get("reasoning") or 0)
            agg["cache_read"] += cache.get("read") or 0
            agg["cache_write"] += cache.get("write") or 0
    for agg in usage.values():
        agg["cost"] = round(agg["cost"], 2)
    # Local approximation of the Go plan limits: only counts this machine's usage.
    limits = {
        "session_pct": round(go_spend[0] / OPENCODE_GO_LIMITS[0] * 100),
        "week_pct": round(go_spend[1] / OPENCODE_GO_LIMITS[1] * 100),
        "month_pct": round(go_spend[2] / OPENCODE_GO_LIMITS[2] * 100),
        "session_usd": round(go_spend[0], 2),
        "week_usd": round(go_spend[1], 2),
        "month_usd": round(go_spend[2], 2),
    }
    return {"status": "ok", "error": None, "usage": usage, "limits": limits}


# --- main --------------------------------------------------------------------

def main():
    mock = os.environ.get("AI_USAGE_MOCK")
    if mock:
        sys.stdout.write(open(mock).read())
        return
    now = time.time()
    state = load_state()
    out = {
        "generated_at": int(now),
        "claude": get_claude(state, now),
        "cursor": get_cursor(state, now),
        "opencode": get_opencode(now),
    }
    # Print before saving: the widget's data must never depend on the cache write.
    print(json.dumps(out), flush=True)
    save_state(state)


if __name__ == "__main__":
    main()
