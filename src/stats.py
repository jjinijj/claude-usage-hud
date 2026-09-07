#!/usr/bin/env python3
"""Collects Claude Code usage, Codex usage, and Mac disk space into one JSON blob."""
import json, os, glob, re, time, subprocess, sys
from datetime import datetime, timezone

HOME = os.path.expanduser("~")
CFG_PATH = os.path.join(HOME, "Applications", "UsageHUD", "config.json")
DEFAULTS = {
    # cost ($) that counts as "full" for the rolling 5-hour Claude window
    "claude_5h_budget_usd": None,
    "disk_volume": "/System/Volumes/Data",
    # True: 직접 정한 세션 제목 사용 / False: Claude가 만든 짧은 이름 사용
    "prefer_custom_title": True,
}
# $ per 1M tokens: input, output, cache-write(5m), cache-read
PRICES = {
    "opus":   (15.0, 75.0, 18.75, 1.50),
    "sonnet": (3.0,  15.0,  3.75, 0.30),
    "haiku":  (1.0,   5.0,  1.25, 0.10),
}

def cfg():
    out = dict(DEFAULTS)
    try:
        with open(CFG_PATH) as f:
            out.update(json.load(f))
    except Exception:
        pass
    return out

def price_for(model):
    m = (model or "").lower()
    for k, v in PRICES.items():
        if k in m:
            return v
    return PRICES["sonnet"]

def parse_ts(s):
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except Exception:
        return None

def claude_usage(window_sec=5 * 3600):
    now = time.time()
    cutoff = now - window_sec
    tokens = 0
    cost = 0.0
    seen = set()
    files = glob.glob(os.path.join(HOME, ".claude", "projects", "**", "*.jsonl"), recursive=True)
    for f in files:
        try:
            if os.path.getmtime(f) < cutoff:
                continue
            fh = open(f, errors="ignore")
        except OSError:
            continue
        with fh:
            for line in fh:
                if '"usage"' not in line:
                    continue
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                msg = d.get("message")
                if not isinstance(msg, dict):
                    continue
                u = msg.get("usage")
                if not isinstance(u, dict):
                    continue
                ts = parse_ts(d.get("timestamp", ""))
                if ts is None or ts < cutoff:
                    continue
                key = (msg.get("id"), d.get("requestId"))
                if key[0] and key in seen:
                    continue
                seen.add(key)
                i = u.get("input_tokens", 0) or 0
                o = u.get("output_tokens", 0) or 0
                cw = u.get("cache_creation_input_tokens", 0) or 0
                cr = u.get("cache_read_input_tokens", 0) or 0
                tokens += i + o + cw + cr
                pi, po, pw, pr = price_for(msg.get("model"))
                cost += (i * pi + o * po + cw * pw + cr * pr) / 1_000_000
    return {"tokens": tokens, "cost": cost}

def codex_usage(max_files=12):
    """Newest Codex rate limits, by event timestamp rather than file mtime.

    Three things make the naive read wrong. Codex resumes old threads and appends
    to their original rollout file, so a June file can hold today's numbers — and
    a fresh session writes a rollout before it has any limits in it. So we cannot
    trust file order, and we cannot stop at the first file that happens to have a
    value. And a 5-hour-window percentage from days ago is not stale, it is
    meaningless: that window has reset many times since.
    """
    root = os.path.join(HOME, ".codex", "sessions")
    files = glob.glob(os.path.join(root, "**", "*.jsonl"), recursive=True)
    files.sort(key=lambda f: os.path.getmtime(f), reverse=True)

    best = None          # (event_ts, rate_limits dict)
    for f in files[:max_files]:
        try:
            fh = open(f, errors="ignore")
        except OSError:
            continue
        with fh:
            for line in fh:
                if "rate_limits" not in line:
                    continue
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                rl = find_rate_limits(d)
                if not (rl and rl.get("primary")):
                    continue
                ts = parse_ts(d.get("timestamp", "")) or os.path.getmtime(f)
                if best is None or ts > best[0]:
                    best = (ts, rl)
    if not best:
        return None

    as_of, rl = best
    p, sec = rl.get("primary") or {}, rl.get("secondary") or {}

    # Past one full window the number describes a window that no longer exists.
    window_s = (p.get("window_minutes") or 300) * 60
    if time.time() - as_of > window_s:
        return {"primary_pct": None, "secondary_pct": None, "as_of": as_of,
                "expired": True}

    return {
        "primary_pct": p.get("used_percent"),
        "primary_reset": p.get("resets_at"),
        "secondary_pct": sec.get("used_percent"),
        "secondary_reset": sec.get("resets_at"),
        "as_of": as_of,
        "expired": False,
    }


def find_rate_limits(node):
    if isinstance(node, dict):
        if "rate_limits" in node and isinstance(node["rate_limits"], dict):
            return node["rate_limits"]
        for v in node.values():
            r = find_rate_limits(v)
            if r:
                return r
    elif isinstance(node, list):
        for v in node:
            r = find_rate_limits(v)
            if r:
                return r
    return None

def memory_usage():
    """Memory the way Activity Monitor reports it: app + wired + compressed."""
    try:
        out = subprocess.run(["vm_stat"], capture_output=True, text=True, timeout=5).stdout
        page = int(re.search(r"page size of (\d+)", out).group(1))
        v = {}
        for line in out.splitlines()[1:]:
            m = re.match(r'"?([^":]+)"?:\s+(\d+)', line.strip())
            if m:
                v[m.group(1).strip()] = int(m.group(2))
        total = int(subprocess.run(["sysctl", "-n", "hw.memsize"],
                                   capture_output=True, text=True, timeout=5).stdout)
        wired = v.get("Pages wired down", 0) * page
        comp = v.get("Pages occupied by compressor", 0) * page
        app = v.get("Anonymous pages", 0) * page - v.get("Pages purgeable", 0) * page
        used = max(app, 0) + wired + comp

        swap_used = swap_total = 0
        sw = subprocess.run(["sysctl", "-n", "vm.swapusage"],
                            capture_output=True, text=True, timeout=5).stdout
        mt = re.search(r"total = ([\d.]+)M.*used = ([\d.]+)M", sw)
        if mt:
            swap_total, swap_used = float(mt.group(1)) * 2**20, float(mt.group(2)) * 2**20

        try:
            pressure = int(subprocess.run(
                ["sysctl", "-n", "kern.memorystatus_vm_pressure_level"],
                capture_output=True, text=True, timeout=5).stdout.strip() or 1)
        except Exception:
            pressure = 1

        # macOS's own pressure level is the primary signal — it is what the
        # kernel actually acts on.
        severity = 2 if pressure >= 4 else (1 if pressure >= 2 else 0)
        # Secondary: heavy paging measured against physical RAM. Not against
        # swap_total — macOS resizes the swap file as usage falls, so the
        # used/total ratio can climb while actual paging drops.
        if severity == 0 and total and swap_used > total * 0.25:
            severity = 1

        return {"used": used, "total": total, "free": total - used,
                "pct": used / total * 100 if total else 0,
                "swap_used": swap_used, "swap_total": swap_total,
                "pressure": pressure, "severity": severity}
    except Exception:
        return None


DISKSCAN_PATH = os.path.join(HOME, "Applications", "UsageHUD", ".diskscan.json")

# Regenerable space, in the order it is worth reclaiming. Sizes come from `du`,
# which is slow enough (~3s all together) that the result is cached for an hour.
CACHE_TARGETS = [
    ("~/Library/Caches", os.path.join(HOME, "Library", "Caches"), True),
    ("~/.cache", os.path.join(HOME, ".cache"), True),
    ("Xcode DerivedData", os.path.join(HOME, "Library", "Developer", "Xcode", "DerivedData"), False),
    ("npm 캐시", os.path.join(HOME, ".npm", "_cacache"), False),
    ("~/Library/Logs", os.path.join(HOME, "Library", "Logs"), False),
    ("시뮬레이터 런타임", "/Library/Developer/CoreSimulator/Images", False),
]


def _du_mb(path, depth=None, timeout=45):
    cmd = ["du", "-k"] + (["-d", str(depth)] if depth is not None else ["-s"]) + [path]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except Exception:
        return []
    rows = []
    for line in out.splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2 and parts[0].isdigit():
            rows.append((int(parts[0]) / 1024.0, parts[1]))
    return rows


def disk_caches(refresh_after=3600):
    """Sizes of regenerable directories, cached hourly because du is slow."""
    try:
        with open(DISKSCAN_PATH) as f:
            d = json.load(f)
        if time.time() - d.get("at", 0) < refresh_after:
            return d.get("entries", [])
    except Exception:
        pass

    entries = []
    for label, path, detail in CACHE_TARGETS:
        if not os.path.isdir(path):
            continue
        if detail:
            rows = _du_mb(path, depth=1)
            if not rows:
                continue
            total = max(rows, key=lambda r: r[0])[0]
            kids = sorted((r for r in rows if r[1] != path), key=lambda r: -r[0])[:3]
            entries.append({"label": label, "mb": total,
                            "children": [{"label": os.path.basename(k[1]), "mb": k[0]}
                                         for k in kids if k[0] >= 100]})
        else:
            rows = _du_mb(path)
            if rows:
                entries.append({"label": label, "mb": rows[0][0], "children": []})
    entries.sort(key=lambda e: -e["mb"])
    try:
        with open(DISKSCAN_PATH, "w") as f:
            json.dump({"at": time.time(), "entries": entries}, f)
    except OSError:
        pass
    return entries


def top_memory(limit=8):
    """Memory grouped by owning app, plus each group's largest single process.

    Helpers are grouped by the outermost `.app` in their path, so Chrome's 30
    renderers and VS Code's extension hosts land under their parent. The largest
    single process is kept because that is usually what actually went wrong —
    one leaking extension host reads very differently from many small tabs.
    """
    try:
        out = subprocess.run(["ps", "-Ao", "rss=,comm="], capture_output=True,
                             text=True, timeout=8).stdout
    except Exception:
        return []
    groups = {}
    for line in out.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) != 2 or not parts[0].isdigit():
            continue
        rss_mb, path = int(parts[0]) / 1024.0, parts[1]
        if "claude-code" in path or "anthropic.claude-code" in path:
            name = "Claude Code"                         # sessions, not the app
        elif (idx := path.find(".app/")) != -1:
            name = os.path.basename(path[:idx])          # outermost bundle
        else:
            name = os.path.basename(path)
        g = groups.setdefault(name, {"name": name, "mb": 0.0, "max": 0.0, "count": 0})
        g["mb"] += rss_mb
        g["max"] = max(g["max"], rss_mb)
        g["count"] += 1
    ranked = sorted(groups.values(), key=lambda g: -g["mb"])
    return [g for g in ranked if g["mb"] >= 50][:limit]


def disk_usage(volume):
    try:
        out = subprocess.run(["df", "-k", volume], capture_output=True, text=True, timeout=5).stdout
        parts = out.strip().splitlines()[-1].split()
        total = int(parts[1]) * 1024
        avail = int(parts[3]) * 1024
        used = total - avail
        return {"used": used, "total": total, "free": avail,
                "pct": (used / total * 100) if total else 0}
    except Exception:
        return None

CEILING_PATH = os.path.join(HOME, "Applications", "UsageHUD", ".ceiling.json")
RATELIMIT_PATH = os.path.join(HOME, "Applications", "UsageHUD", ".ratelimits.json")


def _pct(v):
    """Two shapes seen in the wild: used_percentage (0-100) and utilization (0-1)."""
    if not isinstance(v, dict):
        return None, None
    if v.get("used_percentage") is not None:
        return float(v["used_percentage"]), v.get("resets_at")
    if v.get("utilization") is not None:
        u = float(v["utilization"])
        return (u * 100 if u <= 1 else u), v.get("resets_at")
    return None, None


def cost_events_since(start):
    """[(ts, cost_usd, tokens)] for assistant messages after `start`, deduped."""
    ev, seen = [], set()
    for f in glob.glob(os.path.join(HOME, ".claude", "projects", "**", "*.jsonl"),
                       recursive=True):
        try:
            if os.path.getmtime(f) < start:
                continue
            fh = open(f, errors="ignore")
        except OSError:
            continue
        with fh:
            for line in fh:
                if '"usage"' not in line:
                    continue
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                msg = d.get("message")
                if not isinstance(msg, dict) or not isinstance(msg.get("usage"), dict):
                    continue
                ts = parse_ts(d.get("timestamp", ""))
                if ts is None or ts < start:
                    continue
                key = (msg.get("id"), d.get("requestId"))
                if key[0] and key in seen:
                    continue
                seen.add(key)
                u = msg["usage"]
                i = u.get("input_tokens", 0) or 0
                o = u.get("output_tokens", 0) or 0
                cw = u.get("cache_creation_input_tokens", 0) or 0
                cr = u.get("cache_read_input_tokens", 0) or 0
                pi, po, pw, pr = price_for(msg.get("model"))
                ev.append((ts, (i * pi + o * po + cw * pw + cr * pr) / 1_000_000,
                           i + o + cw + cr))
    ev.sort()
    return ev


def _save_implied_ceiling(value):
    """Back-calculated 5h ceiling in our cost units, from a real percentage."""
    if not (0 < value < 1e6):
        return
    try:
        data = {}
        try:
            with open(CEILING_PATH) as f:
                data = json.load(f)
        except Exception:
            pass
        data.update({"implied": value, "implied_at": time.time()})
        with open(CEILING_PATH, "w") as f:
            json.dump(data, f)
    except OSError:
        pass


PLAN_HISTORY = os.path.join(HOME, "Library", "Application Support", "Claude",
                            "plan-usage-history.json")


def _infer_reset(samples, window_s=5 * 3600):
    """Claude's 5h window has no resets_at in this file, so read it from the curve.

    Utilisation only ever climbs inside a window; a sharp drop is the window
    turning over. The last drop marks a block start, and blocks are `window_s`
    long — walk forward from there to the block that contains now.
    """
    prev, start = None, None
    for sample in samples:
        fh = (sample.get("u") or {}).get("fh")
        if fh is None:
            continue
        if prev is not None and fh < prev - 5:
            start = sample.get("t", 0) / 1000.0
        prev = fh
    if not start:
        return None
    now = time.time()
    while start + window_s <= now:
        start += window_s          # the observed block expired; step to the current one
    return start + window_s


def desktop_plan_usage():
    """The Claude desktop app samples real plan utilisation every ~15 minutes.

    Same numbers the statusLine hook reports, but recorded without a terminal
    session — so this keeps working while you live in VS Code or the app.
    Sampling stops when the app is idle, so a reading can outlive its own window.
    """
    try:
        with open(PLAN_HISTORY) as f:
            samples = json.load(f).get("samples") or []
    except Exception:
        return None
    if not samples:
        return None
    last = samples[-1]
    u = last.get("u") or {}
    if u.get("fh") is None:
        return None
    return {"five_hour": float(u["fh"]),
            "seven_day": float(u["sd"]) if u.get("sd") is not None else None,
            "five_reset": _infer_reset(samples),
            "as_of": last.get("t", 0) / 1000.0,
            "source": "desktop"}


def best_real_usage():
    """Freshest of the two real sources: the desktop history file or the hook cache."""
    cands = [c for c in (desktop_plan_usage(), claude_rate_limits()) if c]
    if not cands:
        return None
    best = max(cands, key=lambda c: c.get("as_of") or 0)
    # the hook is the only source that knows when the window resets — borrow it
    if not best.get("five_reset"):
        for c in cands:
            r = c.get("five_reset")
            if r and r > time.time():
                best = dict(best, five_reset=r)
                break
    return best


def anchored_claude(real, now):
    """Scale the last real reading by how much local usage grew since it was taken.

    Anthropic's 5h limit is a fixed block ending at resets_at, so we measure the
    same block locally and carry the ratio forward. Returns None if unusable.
    """
    if not real or real.get("five_hour") is None or not real.get("five_reset"):
        return None
    reset = float(real["five_reset"])
    if reset <= now:                       # the block already rolled over
        return None
    block_start = reset - 5 * 3600
    anchor_at = real.get("as_of") or 0
    if anchor_at < block_start:
        return None
    ev = cost_events_since(block_start)
    total = sum(c for _, c, _ in ev)
    upto = sum(c for ts, c, _ in ev if ts <= anchor_at)
    if upto <= 0:
        return None
    pct = min(real["five_hour"] * total / upto, 100.0)
    if real["five_hour"] > 5:            # too small a reading gives a wild ceiling
        _save_implied_ceiling(upto / (real["five_hour"] / 100.0))
    return {"pct": pct,
            "cost": total,
            "tokens": sum(t for _, _, t in ev),
            "fresh": (now - anchor_at) < 300,
            "anchor_pct": real["five_hour"],
            "anchor_at": anchor_at,
            "resets_at": reset}


def claude_rate_limits(max_age=None):
    """Real server-reported limits, cached by the statusLine hook."""
    try:
        with open(RATELIMIT_PATH) as f:
            d = json.load(f)
    except Exception:
        return None
    if max_age is not None and time.time() - d.get("at", 0) > max_age:
        return None
    rl = d.get("rate_limits") or {}
    five, five_reset = _pct(rl.get("five_hour"))
    week, week_reset = _pct(rl.get("seven_day"))
    if five is None and week is None:
        return None
    now = time.time()
    if five_reset is not None and not (now - 86400 < float(five_reset) < now + 8 * 86400):
        five_reset = None                 # implausible -> treat as unknown
    return {"five_hour": five, "five_reset": five_reset,
            "seven_day": week, "seven_reset": week_reset,
            "as_of": d.get("at"), "source": "hook"}


def _all_cost_events(days=30):
    cut = time.time() - days * 86400
    ev = []
    for f in glob.glob(os.path.join(HOME, ".claude", "projects", "**", "*.jsonl"),
                       recursive=True):
        try:
            if os.path.getmtime(f) < cut:
                continue
            fh = open(f, errors="ignore")
        except OSError:
            continue
        with fh:
            for line in fh:
                if '"usage"' not in line:
                    continue
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                m = d.get("message")
                if not isinstance(m, dict) or not isinstance(m.get("usage"), dict):
                    continue
                ts = parse_ts(d.get("timestamp", ""))
                if ts is None or ts < cut:
                    continue
                u = m["usage"]
                pi, po, pw, pr = price_for(m.get("model"))
                ev.append((ts, ((u.get("input_tokens", 0) or 0) * pi
                                + (u.get("output_tokens", 0) or 0) * po
                                + (u.get("cache_creation_input_tokens", 0) or 0) * pw
                                + (u.get("cache_read_input_tokens", 0) or 0) * pr) / 1_000_000))
    ev.sort()
    return ev


def _compute_ceiling(days=30, window=5 * 3600):
    """Highest 5-hour rolling spend observed — a lower bound on the real plan limit."""
    ev = _all_cost_events(days)
    best = run = 0.0
    j = 0
    for i, (t, c) in enumerate(ev):
        run += c
        while ev[j][0] < t - window:
            run -= ev[j][1]
            j += 1
        best = max(best, run)
    return best


def calibrate_ceiling_from_history():
    """Back-calculate the 5h ceiling from the newest usable real reading.

    Anchoring only calibrates while a reading is live. When the app has been idle
    the reading expires before that happens, so derive it here too: take the last
    sample with a meaningful percentage and the local spend in its own block.
    """
    try:
        with open(PLAN_HISTORY) as f:
            samples = json.load(f).get("samples") or []
    except Exception:
        return
    reset = _infer_reset(samples)
    if not reset:
        return
    # walk back to the block that the newest usable sample belongs to
    for sample in reversed(samples):
        pct = (sample.get("u") or {}).get("fh")
        ts = sample.get("t", 0) / 1000.0
        if pct is None or pct <= 5 or not ts:
            continue
        block_start = reset - 5 * 3600
        while ts < block_start:
            block_start -= 5 * 3600
        spend = sum(c for t, c, _ in cost_events_since(block_start) if t <= ts)
        if spend > 0:
            _save_implied_ceiling(spend / (pct / 100.0))
        return


def claude_ceiling(current, refresh_after=86400):
    """Cached ceiling, recomputed daily; raised immediately if today exceeds it."""
    data = {}
    try:
        with open(CEILING_PATH) as f:
            data = json.load(f)
    except Exception:
        pass
    if time.time() - data.get("at", 0) > refresh_after:
        try:
            # merge, do not replace — the implied ceiling is calibrated against a
            # real reading and is far better than the history estimate.
            data.update({"at": time.time(), "ceiling": _compute_ceiling(),
                         "source": "history"})
            with open(CEILING_PATH, "w") as f:
                json.dump(data, f)
        except Exception:
            pass
    implied, implied_at = data.get("implied"), data.get("implied_at", 0)
    if implied and time.time() - implied_at < 7 * 86400:
        return max(implied, 1.0)          # calibrated against a real reading
    ceiling = data.get("ceiling", 0)
    if current > ceiling:                 # new record — the ceiling was too low
        ceiling = current
        try:
            data.update({"ceiling": ceiling, "source": "current"})
            with open(CEILING_PATH, "w") as f:
                json.dump(data, f)
        except Exception:
            pass
    return max(ceiling, 1.0)


# ---------------------------------------------------------------- sessions

def _tail_lines(path, nbytes=200_000):
    """Read the last chunk of a file and return its complete lines."""
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            if size > nbytes:
                f.seek(size - nbytes)
                f.readline()          # drop the partial first line
            return f.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return []


def _transcript_index():
    idx = {}
    for f in glob.glob(os.path.join(HOME, ".claude", "projects", "**", "*.jsonl"),
                       recursive=True):
        idx[os.path.splitext(os.path.basename(f))[0]] = f
    return idx


def _titles(path):
    """(user-set title, Claude's auto title) — last of each kind wins."""
    custom = ai = None
    try:
        fh = open(path, errors="ignore")
    except OSError:
        return None, None
    with fh:
        for line in fh:
            if '"custom-title"' in line:
                try:
                    custom = (json.loads(line).get("customTitle") or "").strip() or custom
                except Exception:
                    pass
            elif '"ai-title"' in line:
                try:
                    ai = (json.loads(line).get("aiTitle") or "").strip() or ai
                except Exception:
                    pass
    return custom, ai


TOOLSTATS_PATH = os.path.join(HOME, "Applications", "UsageHUD", ".toolstats.json")


def _compute_tool_baseline(days=14):
    """p99 duration per tool, learned from tool_use -> tool_result timestamps."""
    cut = time.time() - days * 86400
    durs = {}
    for f in glob.glob(os.path.join(HOME, ".claude", "projects", "**", "*.jsonl"),
                       recursive=True):
        try:
            if os.path.getmtime(f) < cut:
                continue
            fh = open(f, errors="ignore")
        except OSError:
            continue
        pend = {}
        with fh:
            for line in fh:
                if len(line) > 300_000 or '"message"' not in line:
                    continue
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                t = parse_ts(d.get("timestamp", ""))
                m = d.get("message")
                if not (t and isinstance(m, dict)):
                    continue
                content = m.get("content")
                if not isinstance(content, list):
                    continue
                if d.get("type") == "assistant":
                    for c in content:
                        if isinstance(c, dict) and c.get("type") == "tool_use":
                            pend[c.get("id")] = (c.get("name"), t)
                elif d.get("type") == "user":
                    for c in content:
                        if isinstance(c, dict) and c.get("type") == "tool_result":
                            k = pend.pop(c.get("tool_use_id"), None)
                            if k:
                                durs.setdefault(k[0], []).append(t - k[1])
    out = {}
    for name, v in durs.items():
        if len(v) < 10:
            continue
        v.sort()
        out[name] = v[min(int(len(v) * 0.99), len(v) - 1)]
    return out


def tool_baseline(refresh_after=86400):
    try:
        with open(TOOLSTATS_PATH) as f:
            d = json.load(f)
        if time.time() - d.get("at", 0) < refresh_after:
            return d.get("p99", {})
    except Exception:
        pass
    try:
        p99 = _compute_tool_baseline()
        with open(TOOLSTATS_PATH, "w") as f:
            json.dump({"at": time.time(), "p99": p99}, f)
        return p99
    except Exception:
        return {}


def _thresholds(tool, baseline):
    """(slow, stuck) seconds for a tool, floored so short tools do not cry wolf."""
    p99 = baseline.get(tool, 0)
    return max(p99 * 3, 300), max(p99 * 10, 1800)


def _proc_info(pids):
    """{pid: (rss_mb, is_claude)} in one ps call.

    `is_claude` gates the "kill idle sessions" actions: the pid comes from a file
    on disk, so verify it really is a Claude Code process before signalling it.
    """
    if not pids:
        return {}
    try:
        out = subprocess.run(["ps", "-o", "pid=,rss=,command=", "-p", ",".join(map(str, pids))],
                             capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return {}
    m = {}
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and parts[0].isdigit():
            m[int(parts[0])] = (int(parts[1]) / 1024.0, "claude" in parts[2].lower())
    return m


def _has_running_tool(pid):
    """A live child process means a tool is still running, not waiting on a human."""
    try:
        out = subprocess.run(["pgrep", "-P", str(pid)], capture_output=True,
                             text=True, timeout=3).stdout.split()
        return len(out) > 0
    except Exception:
        return False


def _classify(path):
    """Everything the state machine needs: last role, pending tool, recent API errors."""
    try:
        age = time.time() - os.path.getmtime(path)
    except OSError:
        return None
    last_role, has_tool_use, pend, errors = None, False, {}, []
    for line in _tail_lines(path):
        try:
            d = json.loads(line)
        except Exception:
            continue
        if d.get("isSidechain"):
            continue
        t = parse_ts(d.get("timestamp", ""))
        if d.get("subtype") == "api_error" and t:
            errors.append(t)
        typ, m = d.get("type"), d.get("message")
        if typ not in ("assistant", "user") or not isinstance(m, dict):
            continue
        content = m.get("content")
        kinds = ([c.get("type") for c in content if isinstance(c, dict)]
                 if isinstance(content, list) else ["text"])
        if typ == "assistant" and kinds == ["thinking"]:
            continue
        last_role, has_tool_use = typ, (typ == "assistant" and "tool_use" in kinds)
        if isinstance(content, list):
            for c in content:
                if not isinstance(c, dict):
                    continue
                if c.get("type") == "tool_use":
                    pend[c.get("id")] = (c.get("name"), t)
                elif c.get("type") == "tool_result":
                    pend.pop(c.get("tool_use_id"), None)
    oldest = min((v for v in pend.values() if v[1]), key=lambda x: x[1], default=None)
    return {"age": age, "last_role": last_role, "has_tool_use": has_tool_use,
            "pending": oldest, "errors": errors}


def session_state(info, pid, baseline, now):
    """working | running | slow | attention | error | stuck | idle"""
    if not info or info["last_role"] is None:
        return "idle", None
    if info["last_role"] == "assistant" and not info["has_tool_use"]:
        return "idle", None                       # the turn finished

    pending = info["pending"]
    tool = pending[0] if pending else None
    elapsed = (now - pending[1]) if pending else info["age"]

    if len([t for t in info["errors"] if now - t < 300]) >= 3:
        return "error", tool                      # retrying against a failing API
    if info["age"] < 90:
        return "working", tool

    slow_at, stuck_at = _thresholds(tool, baseline)
    if _has_running_tool(pid):
        if elapsed > stuck_at:
            return "stuck", tool                  # far beyond anything normal
        return ("slow" if elapsed > slow_at else "running"), tool
    return ("stuck" if info["age"] > 600 else "attention"), tool


def claude_sessions(prefer_custom=True):
    idx = _transcript_index()
    baseline = tool_baseline()
    now = time.time()
    out = []
    for f in glob.glob(os.path.join(HOME, ".claude", "sessions", "*.json")):
        try:
            s = json.load(open(f))
        except Exception:
            continue
        pid = s.get("pid")
        if not isinstance(pid, int):
            continue
        try:
            os.kill(pid, 0)           # still alive?
        except OSError:
            continue
        path = idx.get(s.get("sessionId", ""))
        custom = ai = None
        tool = None
        if path:
            info = _classify(path)
            state, tool = session_state(info, pid, baseline, now)
            age = info["age"] if info else None
            if info and info["pending"] and state in ("running", "slow", "stuck"):
                age = now - info["pending"][1]
            custom, ai = _titles(path)
        else:
            state, age = "idle", None  # session opened but nothing said yet
        derived = s.get("name") or str(pid)
        # user-set title > Claude's auto title > the derived slug
        if prefer_custom and custom:
            name, source = custom, "custom"
        elif ai:
            name, source = ai, "ai"
        else:
            name, source = derived, "derived"
        out.append({
            "pid": pid,
            "name": name,
            "title_source": source,
            "derived": derived,
            "cwd": os.path.basename(s.get("cwd", "")) or "/",
            "where": s.get("entrypoint", ""),
            "state": state,
            "age": age,
            "tool": tool,
        })
    info = _proc_info([r["pid"] for r in out])
    for r in out:
        rss, is_claude = info.get(r["pid"], (None, False))
        r["mem"] = rss
        r["killable"] = bool(is_claude)
    order = {"stuck": 0, "error": 1, "attention": 2, "slow": 3,
             "working": 4, "running": 5, "idle": 6}
    out.sort(key=lambda r: (order.get(r["state"], 3), r["age"] if r["age"] is not None else 1e9))
    return out


def main():
    c = cfg()
    cl = claude_usage()
    calibrate_ceiling_from_history()
    if c.get("claude_5h_budget_usd"):
        budget = max(c["claude_5h_budget_usd"], 0.01)   # manual override
    else:
        budget = claude_ceiling(cl["cost"])             # auto-calibrated from history
    claude = {
        "pct": min(cl["cost"] / budget * 100, 100),
        "value": cl["cost"],
        "tokens": cl["tokens"],
        "budget": budget,
        "measured": False,
    }
    now = time.time()
    real = best_real_usage()
    anchored = anchored_claude(real, now)

    # A reading only describes its own 5-hour block. The desktop app stops
    # sampling while it is idle, so the newest reading can outlive its block —
    # showing that percentage afterwards is not stale, it is simply wrong.
    expired_block_start = None
    if not anchored and real and real["five_hour"] is not None:
        reset = real.get("five_reset")
        block_start = (reset - 5 * 3600) if reset else None
        if block_start and (real.get("as_of") or 0) < block_start:
            expired_block_start = block_start
        else:
            anchored = {"pct": real["five_hour"], "cost": cl["cost"], "tokens": cl["tokens"],
                        "fresh": now - (real.get("as_of") or 0) < 300,
                        "anchor_pct": real["five_hour"], "anchor_at": real.get("as_of") or 0,
                        "resets_at": reset}

    if anchored:
        claude.update({
            "pct": anchored["pct"],
            "value": anchored["cost"],
            "tokens": anchored["tokens"],
            "measured": True,
            "mode": "live" if anchored["fresh"] else "anchored",
            "weekly": real["seven_day"],
            "resets_at": anchored["resets_at"],
            "source": real.get("source", "hook"),
            "anchor_pct": anchored["anchor_pct"],
            "anchor_at": anchored["anchor_at"],
        })
    elif expired_block_start:
        # No usable reading for the block we are in — fall back to local tokens
        # measured over this block, scaled by the ceiling back-calculated from
        # earlier real readings. Approximate, and labelled as such.
        ev = cost_events_since(expired_block_start)
        cost = sum(c for _, c, _ in ev)
        claude.update({
            "pct": min(cost / budget * 100, 100),
            "value": cost,
            "tokens": sum(t for _, _, t in ev),
            "measured": False,
            "mode": "estimate",
            "weekly": real.get("seven_day"),
            "resets_at": real.get("five_reset"),
            "block_start": expired_block_start,
            "stale_reading_at": real.get("as_of"),
        })
    else:
        claude["mode"] = "estimate"

    result = {
        "generated_at": time.time(),
        "claude": claude,
        "codex": codex_usage(),
        "memory": memory_usage(),
        "top_memory": top_memory(),
        "disk": disk_usage(c["disk_volume"]),
        "disk_caches": disk_caches(),
        "sessions": claude_sessions(c.get("prefer_custom_title", True)),
    }
    json.dump(result, sys.stdout)
    print()

if __name__ == "__main__":
    main()
