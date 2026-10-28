"""What the add-on did in a live run, from its own log lines and the harness logs.

  python -I fixlog.py <results dir> [--json out.json]

- tx: a game sent the calls Tripping Zombies made on a zombie it simulates ([TZMPFix] tx z=.. ops=.. wall=..)
- rx: the other client applied them to its copy (applied), or skipped them (down: its copy was already down;
  miss: no such zombie there). Latency = rx wall - tx wall (all processes run on one PC: one wall clock).
- for each tx that knocks down / bumps / staggers: did the owner's zombie fall (episode start -0.2..+0.4 s),
  and did the observer's copy fall (-0.2..+2.5 s)? offset = observer start - owner start.
- hits ([TZFixTest] hit z=.. by=owner|observer): did the owner's zombie fall within 1.5 s, the observer's copy
  within 2.5 s.
Episodes come from analysis/trips.py (same definitions).
"""
import bisect
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import trips  # noqa: E402

RX_TX = re.compile(r"\[TZMPFix\] tx z=(\d+) ops=(\S+) wall=(\d+)")
RX_RX = re.compile(r"\[TZMPFix\] rx z=(\d+) (applied|down|miss)(?: ops=(\S+))? wall=(\d+)")
RX_LOCAL = re.compile(r"\[TZMPFix\] local z=(\d+) (own|copy) ops=(\S+) wall=(\d+)")
RX_HIT = re.compile(r"\[TZFixTest\] hit z=(\d+) by=(\w+) kind=(\w+) n=\d+ wall=(\d+)")
RX_ACT = re.compile(r"\[TZMPFix\] act (\w+) z=(\d+) (-> owner|rolled|sent) wall=(\d+)")
RX_ERR = re.compile(r"(?:TZMPFix|TrippingZombies|TrippingZombiesClient|TrippingZombiesCompatibility|TZFixTest)\.lua:\d+"
                    r"|\[TZMPFix\] (?:WARNING|sending failed|applying failed|handed-over roll failed|handing)")
RX_LUAERR = re.compile(r"attempted index|tried to call nil|LuaException|Error found in LUA|non-table")
FALL_OPS = ("kd", "bt", "sb")


def lines(path):
    if not os.path.isfile(path):
        return []
    return open(path, encoding="utf-8", errors="replace").read().splitlines()


def wall_offset(csv_path):
    """median(server ms - wall ms) from the harness W rows"""
    d = []
    for ln in lines(csv_path):
        if ln.startswith("W,"):
            r = ln.split(",")
            if len(r) >= 3:
                d.append(float(r[1]) - float(r[2]))
    d.sort()
    return d[len(d) // 2] if d else None


def pct(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, int(len(v) * p))] if v else None


def main():
    res = sys.argv[1]
    files = os.listdir(res)
    own_csv = os.path.join(res, [f for f in files if f.startswith("owner_ZSTest_")][0])
    obs_csv = os.path.join(res, [f for f in files if f.startswith("observer_ZSTest_")][0])
    off = {"owner": wall_offset(own_csv), "observer": wall_offset(obs_csv)}
    if off["owner"] is None:
        off["owner"] = off["observer"]
    if off["observer"] is None:
        off["observer"] = off["owner"]

    T = trips.rows(own_csv, "T")
    F = trips.rows(obs_csv, "F")
    C = []
    for ln in lines(obs_csv):
        if ln.startswith("C,"):
            r = ln.split(",")
            C.append((float(r[1]), r[3]))
    C.sort()
    sw_t = [c[0] for c in C]

    def mode_at(t):
        i = bisect.bisect_right(sw_t, t) - 1
        return C[i][1] if i >= 0 else ""

    def eps(rr):
        d = {}
        for r in rr:
            d.setdefault(r[2], []).append((float(r[1]), r[8]))
        out = {}
        for z, v in d.items():
            v.sort()
            out[z] = [e[0] for e in trips.episodes(v)]
        return out

    own_eps, obs_eps = eps(T), eps(F)

    def first_start(starts, lo, hi):
        if not starts:
            return None
        i = bisect.bisect_left(starts, lo)
        if i < len(starts) and starts[i] <= hi:
            return starts[i]
        return None

    logs = {role: lines(os.path.join(res, role + ".out.log")) for role in ("owner", "observer", "server")}
    tx = {"owner": [], "observer": []}
    rx = {"owner": [], "observer": []}
    loc = {"owner": [], "observer": [], "server": []}
    hits = []
    acts = []
    errors = {}
    anyerr = {}
    for role, ll in logs.items():
        errs = []
        for ln in ll:
            m = RX_TX.search(ln)
            if m and role in tx:
                tx[role].append((float(m.group(3)), m.group(1), m.group(2)))
                continue
            m = RX_RX.search(ln)
            if m and role in rx:
                rx[role].append((float(m.group(4)), m.group(1), m.group(2), m.group(3) or ""))
                continue
            m = RX_LOCAL.search(ln)
            if m and role in loc:
                loc[role].append((float(m.group(4)), m.group(1), m.group(2), m.group(3)))
                continue
            m = RX_HIT.search(ln)
            if m:
                hits.append((float(m.group(4)), m.group(1), m.group(2), m.group(3)))
                continue
            m = RX_ACT.search(ln)
            if m:
                acts.append((role, m.group(1), m.group(2), m.group(3), float(m.group(4))))
                continue
            if RX_ERR.search(ln):
                errs.append(ln.strip()[:240])
            if RX_LUAERR.search(ln):
                anyerr[role] = anyerr.get(role, 0) + 1
        errors[role] = errs

    report = {"wall_offset_ms": off, "errors": {k: len(v) for k, v in errors.items()}, "lua_errors_any_mod": anyerr,
              "error_samples": {k: v[:5] for k, v in errors.items() if v}}
    print(f"results: {res}")
    for sender, receiver in (("owner", "observer"), ("observer", "owner")):
        if not tx[sender]:
            continue
        rxl = {}
        for t, z, kind, ops in rx[receiver]:
            rxl.setdefault(z, []).append((t, kind))
        lat, kinds, both, own_only, none_, offsets = [], {}, 0, 0, 0, []
        per_mode = {}
        for t, z, ops in tx[sender]:
            r = None
            for rt, kind in rxl.get(z, []):
                if 0 <= rt - t <= 3000:
                    r = (rt, kind)
                    break
            kinds[r[1] if r else "lost"] = kinds.get(r[1] if r else "lost", 0) + 1
            if r:
                lat.append(r[0] - t)
            codes = [c.split("=")[0] for c in ops.split(",")]
            if not any(c in FALL_OPS for c in codes):
                continue
            ts = t + off[sender]
            mode = mode_at(ts)
            pm = per_mode.setdefault(mode, {"falls_sent": 0, "owner_fell": 0, "observer_fell": 0, "both": 0, "offsets": []})
            pm["falls_sent"] += 1
            sim_eps = (own_eps if sender == "owner" else obs_eps).get(z, [])
            copy_eps = (obs_eps if sender == "owner" else own_eps).get(z, [])
            a = first_start(sim_eps, ts - 200, ts + 400)
            b = first_start(copy_eps, ts - 200, ts + 2500)
            pm["owner_fell"] += a is not None
            pm["observer_fell"] += b is not None
            if a is not None and b is not None:
                pm["both"] += 1
                pm["offsets"].append(b - a)
        for mode, pm in per_mode.items():
            o = pm.pop("offsets")
            pm["offset_ms_p10_p50_p90"] = [pct(o, .1), pct(o, .5), pct(o, .9)]
        key = f"{sender}->{receiver}"
        report[key] = {"tx": len(tx[sender]), "rx": kinds, "latency_ms_p50_p90_max": [pct(lat, .5), pct(lat, .9),
                       max(lat) if lat else None], "falls_by_mode": per_mode}
        print(f"{key}: sent {len(tx[sender])} zombies, received {kinds}, latency p50/p90/max "
              f"{report[key]['latency_ms_p50_p90_max']} ms")
        for mode, pm in sorted(per_mode.items()):
            print(f"   {mode or '-':8s} falls sent {pm['falls_sent']}, simulating side fell {pm['owner_fell']}, "
                  f"copy fell {pm['observer_fell']}, both {pm['both']}, copy-after-owner ms p10/50/90 "
                  f"{pm['offset_ms_p10_p50_p90']}")

    # bump trips (setBumpType): how long the owner's zombie and the copy stay in BumpedState
    def bump_runs(rr):
        d = {}
        for r in rr:
            d.setdefault(r[2], []).append((float(r[1]), r[8]))
        out = {}
        for z, v in d.items():
            v.sort()
            runs, cur = [], None
            for t, st in v:
                if st == "BumpedState":
                    cur = [t, t] if cur is None else [cur[0], t]
                elif cur is not None:
                    runs.append(tuple(cur))
                    cur = None
            if cur is not None:
                runs.append(tuple(cur))
            out[z] = runs
        return out
    ob = bump_runs(T)

    def episodes_full(rr):
        d = {}
        for r in rr:
            d.setdefault(r[2], []).append((float(r[1]), r[8]))
        out = {}
        for z, v in d.items():
            v.sort()
            out[z] = trips.episodes(v)
        return out
    obs_full = episodes_full(F)
    own_full = episodes_full(T)
    bumps = {}
    for t, z, ops in tx["owner"]:
        bts = [c.split("=", 1)[1] for c in ops.split(",") if c.startswith("bt=") and c != "bt="]
        if not bts:
            continue
        kind = "tumble" if bts[-1] == "trippingFromSprint" else "stumble"
        row = bumps.setdefault(kind, {"sent": 0, "owner_bumped": 0, "copy_reacted": 0, "copy_states": {},
                                      "owner_ms": [], "copy_ms": []})
        ts = t + off["owner"]
        o = [e for e in own_full.get(z, []) if ts - 100 <= e[0] <= ts + 400]
        b = [e for e in obs_full.get(z, []) if ts - 100 <= e[0] <= ts + 1500]
        row["sent"] += 1
        if o:
            row["owner_bumped"] += 1
            row["owner_ms"].append(o[0][1] - o[0][0])
            if b:
                row.setdefault("copy_minus_owner_ms", []).append((b[0][1] - b[0][0]) - (o[0][1] - o[0][0]))
        if b:
            row["copy_reacted"] += 1
            row["copy_states"][b[0][2]] = row["copy_states"].get(b[0][2], 0) + 1
            row["copy_ms"].append(b[0][1] - b[0][0])
    for kind, row in bumps.items():
        om, cm = row.pop("owner_ms"), row.pop("copy_ms")
        dm = row.pop("copy_minus_owner_ms", [])
        row["copy_minus_owner_ms_p10_p50_p90"] = [pct(dm, .1), pct(dm, .5), pct(dm, .9)]
        row["owner_ms_p50"], row["copy_ms_p10_p50"] = pct(om, .5), [pct(cm, .1), pct(cm, .5)]
        print(f"bump trips ({kind}) sent {row['sent']}: owner's zombie bumped {row['owner_bumped']} (p50 "
              f"{row['owner_ms_p50']} ms); copy reacted {row['copy_reacted']} {row['copy_states']}, lasting p10/p50 "
              f"{row['copy_ms_p10_p50']} ms; copy - owner episode length p10/50/90 {row['copy_minus_owner_ms_p10_p50_p90']} ms")
    if bumps:
        report["bumps"] = bumps

    # fix off (debug log on): each game's own TZ trips, nothing sent
    for role, other in (("owner", "observer"), ("observer", "owner")):
        if not loc[role]:
            continue
        per = {}
        for t, z, kind, ops in loc[role]:
            if not any(c.split("=")[0] in FALL_OPS for c in ops.split(",")):
                continue
            ts = t + off[role]
            mode = mode_at(ts)
            row = per.setdefault(mode, {"own_trips": 0, "own_seen_by_other": 0, "copy_trips": 0, "copy_with_real_fall": 0})
            mine = (own_eps if role == "owner" else obs_eps).get(z, [])
            theirs = (obs_eps if role == "owner" else own_eps).get(z, [])
            if kind == "own":
                row["own_trips"] += 1
                if first_start(theirs, ts - 200, ts + 2500) is not None:
                    row["own_seen_by_other"] += 1
            else:
                row["copy_trips"] += 1
                if first_start(theirs, ts - 1000, ts + 1000) is not None:
                    row["copy_with_real_fall"] += 1
        report["local_" + role] = per
        for mode, row in sorted(per.items()):
            print(f"fix off, {role}'s own TZ rolls [{mode or '-'}]: trips of zombies it simulates {row['own_trips']} "
                  f"(the other player saw {row['own_seen_by_other']}), trips of its copies of the other's zombies "
                  f"{row['copy_trips']} (real zombie also fell within 1 s: {row['copy_with_real_fall']})")

    # hit knockdowns: TZ's directional fall (knockDownToward) is "...,kd,ap". Decided on the server's copy
    # (fix off: the server's local lines) or on the owner (fix on: its tx lines) after a reported hit.
    if hits:
        dec = {"server": [(t, z) for t, z, kind, ops in loc["server"] if ops.endswith(",ap") and ",kd" in ops],
               "owner": [(t, z) for t, z, ops in tx["owner"] if ops.endswith(",ap") and ",kd" in ops]}
        hf = {}
        for t, z, by, kind in hits:
            hf.setdefault(by, {"hits": 0, "falls_decided_on_server": 0, "falls_decided_on_owner": 0,
                               "owner_fell": 0, "copy_fell": 0, "both": 0, "decide_ms": [], "copy_ms": []})
            hf[by]["hits"] += 1
        # each decided fall belongs to the latest hit on that zombie before it (within 1.5 s)
        for where in ("server", "owner"):
            for td, z in dec[where]:
                prior = [(t, by) for t, zz, by, kind in hits if zz == z and 0 <= td - t <= 1500]
                if not prior:
                    continue
                t, by = max(prior)
                row = hf[by]
                row["falls_decided_on_" + where] += 1
                row["decide_ms"].append(td - t)
                ts = td + off["owner"]
                a = first_start(own_eps.get(z, []), ts - 200, ts + 600)
                b = first_start(obs_eps.get(z, []), ts - 200, ts + 2500)
                row["owner_fell"] += a is not None
                row["copy_fell"] += b is not None
                if a is not None and b is not None:
                    row["both"] += 1
                    row["copy_ms"].append(b - a)
        for by, row in hf.items():
            d, c = row.pop("decide_ms"), row.pop("copy_ms")
            row["hit_to_fall_decided_ms_p50_p90"] = [pct(d, .5), pct(d, .9)]
            row["copy_after_owner_ms_p50_p90"] = [pct(c, .5), pct(c, .9)]
            print(f"hit falls, hits by {by}: {row['hits']} hits -> TZ decided a fall on the server's copy "
                  f"{row['falls_decided_on_server']}, on the owner {row['falls_decided_on_owner']} "
                  f"(after p50/p90 {row['hit_to_fall_decided_ms_p50_p90']} ms); owner's zombie fell {row['owner_fell']}, "
                  f"observer's copy fell {row['copy_fell']}, both {row['both']}, copy after owner "
                  f"{row['copy_after_owner_ms_p50_p90']} ms")
        report["hit_falls"] = hf

    if hits:
        h = {}
        for t, z, by, kind in hits:
            ts = t + off["owner" if by == "owner" else "observer"]
            row = h.setdefault(by, {"hits": 0, "owner_fell": 0, "observer_fell": 0, "both": 0, "delay": [], "copy_delay": []})
            row["hits"] += 1
            a = first_start(own_eps.get(z, []), ts, ts + 1500)
            b = first_start(obs_eps.get(z, []), ts, ts + 2500)
            row["owner_fell"] += a is not None
            row["observer_fell"] += b is not None
            if a is not None:
                row["delay"].append(a - ts)
            if a is not None and b is not None:
                row["both"] += 1
                row["copy_delay"].append(b - a)
        for by, row in h.items():
            d, cd = row.pop("delay"), row.pop("copy_delay")
            row["owner_fall_after_hit_ms_p50_p90"] = [pct(d, .5), pct(d, .9)]
            row["copy_after_owner_ms_p50_p90"] = [pct(cd, .5), pct(cd, .9)]
            print(f"hits by {by}: {row['hits']}, owner's zombie fell {row['owner_fell']}, observer's copy fell "
                  f"{row['observer_fell']}, both {row['both']}, owner fall after hit p50/p90 "
                  f"{row['owner_fall_after_hit_ms_p50_p90']} ms, copy after owner {row['copy_after_owner_ms_p50_p90']} ms")
        report["hits"] = h
    if acts:
        a = {}
        for role, k, z, what, t in acts:
            key = f"{role} {k} {what}"
            a[key] = a.get(key, 0) + 1
        report["acts"] = a
        print("handed-over rolls:", a)
    print("errors in TZ / fix / helper Lua:", report["errors"], "| Lua errors of any mod:", anyerr)
    for role, s in report["error_samples"].items():
        for ln in s:
            print(f"   {role}: {ln}")
    stats = {}
    for role, ll in logs.items():
        for ln in reversed(ll):
            if "[TZMPFix] stats" in ln:
                stats[role] = ln[ln.index("[TZMPFix]"):][:400]
                break
    report["last_stats"] = stats
    for role, s in stats.items():
        print(f"   {role}: {s}")
    if "--json" in sys.argv:
        json.dump(report, open(sys.argv[sys.argv.index("--json") + 1], "w"), indent=2)


if __name__ == "__main__":
    main()
