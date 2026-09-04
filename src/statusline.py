#!/usr/bin/env python3
"""Claude Code statusLine hook.

Claude Code hands this script a JSON payload on stdin that includes the real
`rate_limits` the server returned. We stash that for the HUD and print a line.
"""
import json, os, sys, time

CACHE = os.path.join(os.path.expanduser("~"), "Applications", "UsageHUD", ".ratelimits.json")

def main():
    raw = sys.stdin.read()
    try:
        p = json.loads(raw)
    except Exception:
        return

    rl = p.get("rate_limits")
    if isinstance(rl, dict) and rl:
        try:
            with open(CACHE, "w") as f:
                json.dump({"at": time.time(), "rate_limits": rl,
                           "session": p.get("session_id")}, f)
        except OSError:
            pass

    bits = []
    if isinstance(rl, dict):
        for key, label in (("five_hour", "5h"), ("seven_day", "주")):
            v = rl.get(key)
            if not isinstance(v, dict):
                continue
            if v.get("used_percentage") is not None:
                bits.append(f"{label} {float(v['used_percentage']):.0f}%")
            elif v.get("utilization") is not None:
                u = float(v["utilization"])
                bits.append(f"{label} {(u * 100 if u <= 1 else u):.0f}%")
    cost = (p.get("cost") or {}).get("total_cost_usd")
    if cost:
        bits.append(f"${cost:.2f}")
    print(" · ".join(bits))

if __name__ == "__main__":
    main()
