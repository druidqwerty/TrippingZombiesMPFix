"""One line per live run (from runs.csv and each results dir's trips.json / fixlog.json).

  python -I summary.py [label ...]
Columns: TZ falls of the owner's zombies (fix off: the owner's own TZ rolls, from its log; fix on: the falls it
sent) and how many the other player saw (its copy fell within -0.2..+2.5 s); ghost trips (fix off: the
observer's TZ tripping its copies on its own; fix on: observer-only fall episodes); copy delay; teleports while
a zombie is down; hit knockdowns decided / shown on both; bumps shown; Lua errors; trip rate per zombie-minute.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(HERE)
RESULTS = os.path.join(os.path.dirname(PROJ), "pz-zombiesync", "livetest", "results")


def load(res, name):
    p = os.path.join(res, name)
    return json.load(open(p)) if os.path.isfile(p) else {}


def main():
    want = set(sys.argv[1:])
    rows = []
    for ln in open(os.path.join(PROJ, "runs.csv"), encoding="utf-8"):
        p = ln.strip().split(",")
        if len(p) < 3 or (want and p[1] not in want):
            continue
        res = os.path.join(RESULTS, p[2])
        tr, fl = load(res, "trips.json"), load(res, "fixlog.json")
        if not tr:
            continue
        for mode in ("mod", "vanilla", "none"):
            m = tr.get(mode)
            if not m:
                continue
            r = {"label": p[1], "res": p[2], "mode": {"mod": "ZS on", "vanilla": "ZS off", "none": "no ZS"}[mode],
                 "zmin": m["owner_zombie_min"], "tele_down": m["teleports_down"], "obs_only": m["observer_only"]}
            lo = fl.get("local_owner", {}).get(mode)
            sent = fl.get("owner->observer", {}).get("falls_by_mode", {}).get(mode)
            if lo:
                r["falls"], r["seen"] = lo["own_trips"], lo["own_seen_by_other"]
            elif sent:
                r["falls"], r["seen"] = sent["falls_sent"], sent["observer_fell"]
                r["delay_p50"] = (sent.get("offset_ms_p10_p50_p90") or [None, None, None])[1]
            lobs = fl.get("local_observer", {}).get(mode)
            r["ghost"] = lobs["copy_trips"] if lobs else (m["observer_only"] if sent else 0)
            r["rate"] = r.get("falls", 0) / r["zmin"] if r["zmin"] else None
            rows.append(r)
        hf = fl.get("hit_falls", {})
        dec = sum(v.get("falls_decided_on_owner", 0) + v.get("falls_decided_on_server", 0) for v in hf.values())
        both = sum(v.get("both", 0) for v in hf.values())
        hits = sum(v.get("hits", 0) for v in hf.values())
        b = fl.get("bumps", {})
        bumps = " ".join(f"{k} {v['copy_reacted']}/{v['sent']}" for k, v in b.items())
        err = sum(fl.get("errors", {}).values())
        rows.append({"label": p[1], "res": p[2], "mode": "run", "hits": hits, "hit_falls": dec, "hit_both": both,
                     "bumps": bumps, "errors": err})
    print(f"{'run':24s} {'phase':7s} {'falls':>5s} {'seen':>5s} {'%':>4s} {'delay':>5s} {'ghost':>5s} "
          f"{'tele.dn':>7s} {'rate':>5s}")
    for r in rows:
        if r["mode"] == "run":
            print(f"{'':24s} {'':7s} hits {r['hits']}, hit falls {r['hit_falls']} (both {r['hit_both']}), "
                  f"bumps shown {r['bumps'] or '-'}, Lua errors {r['errors']}   [{r['res']}]")
            continue
        f, s = r.get("falls"), r.get("seen")
        pct = f"{100 * s / f:.0f}" if f else "-"
        d = r.get("delay_p50")
        print(f"{r['label']:24s} {r['mode']:7s} {f if f is not None else '-':>5} {s if s is not None else '-':>5} "
              f"{pct:>4s} {('%.0f' % d) if d is not None else '-':>5s} {r['ghost']:>5d} {r['tele_down']:>7d} "
              f"{r['rate'] if r['rate'] is None else round(r['rate'], 2):>5}")


if __name__ == "__main__":
    main()
