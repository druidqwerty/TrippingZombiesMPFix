"""Trip / fall sync between the owner (simulates the zombies) and the observer (draws them from the network).

  python -I trips.py <results dir> [--json out.json]

Reads the harness logs (owner T rows, observer F rows, phase switches C rows) and, per phase mode:
  - trip episodes on each side: a zombie entering a fall state (falldown / bumped / staggerback) from an upright
    state; the episode lasts while the zombie stays in a down state (falldown, onground, getup, bumped, staggerback)
  - matched: owner episode with an observer episode of the same zombie starting -1.0..+2.0 s around it
    (offset = observer start - owner start); owner-only = the observer never showed the trip; observer-only =
    a trip the owner's zombie never had (a "ghost" trip)
  - teleports (teleports.csv from livetest.py analyze) split by whether a down state is involved
  - stuck: observer down episodes longer than 8 s, and observer copies still down 3 s after the owner's zombie
    got up
Zombie ids are the online ids; times are the server clock in ms (both logs use it).
"""
import bisect
import csv
import json
import os
import sys
from collections import Counter, defaultdict

START = {"ZombieFallDownState", "BumpedState", "StaggerBackState"}
DOWN = START | {"ZombieOnGroundState", "ZombieGetUpState"}
GAP = 300.0  # an upright stretch shorter than this does not end an episode


def rows(path, kind):
    out = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for ln in f:
            if not ln.startswith(kind + ","):
                continue
            r = ln.rstrip("\n").split(",")
            if len(r) >= 10:
                out.append(r)
    return out


def episodes(frames):
    """frames: sorted (t, state). Returns [(start, end, first_state, states_seen)]."""
    eps = []
    cur = None
    last_down = None
    for t, st in frames:
        if st in DOWN:
            if cur is None:
                if st in START:
                    cur = [t, t, st, {st}]
            else:
                cur[1] = t
                cur[3].add(st)
            last_down = t
        else:
            if cur is not None and last_down is not None and t - last_down > GAP:
                eps.append(tuple(cur))
                cur = None
    if cur is not None:
        eps.append(tuple(cur))
    return eps


def main():
    res = sys.argv[1]
    files = os.listdir(res)
    own = [f for f in files if f.startswith("owner_ZSTest_")][0]
    obs = [f for f in files if f.startswith("observer_ZSTest_")][0]
    T = rows(os.path.join(res, own), "T")
    F = rows(os.path.join(res, obs), "F")
    C = []
    with open(os.path.join(res, obs), encoding="utf-8", errors="replace") as f:
        for ln in f:
            if ln.startswith("C,"):
                r = ln.rstrip("\n").split(",")
                C.append((float(r[1]), r[3]))
    C.sort()
    D = []
    E = []
    with open(os.path.join(res, own), encoding="utf-8", errors="replace") as f:
        for ln in f:
            if ln.startswith("D,"):
                D.append(float(ln.split(",")[1]))
            if ln.startswith("E,"):
                E.append(float(ln.split(",")[2]))
    t_start = E[0] if E else float("-inf")
    t_end = D[0] if D else float("inf")
    sw_t = [c[0] for c in C]

    def mode_at(t):
        if t < t_start or t > t_end:
            return ""
        i = bisect.bisect_right(sw_t, t) - 1
        if i < 0:
            return ""
        if t - sw_t[i] < 3000:  # settling after a switch
            return ""
        return C[i][1]

    def by_zombie(rr):
        d = defaultdict(list)
        for r in rr:
            d[r[2]].append((float(r[1]), r[8]))
        for v in d.values():
            v.sort()
        return d

    oz, bz = by_zombie(T), by_zombie(F)
    oe = {z: episodes(v) for z, v in oz.items()}
    be = {z: episodes(v) for z, v in bz.items()}

    # frames (and zombie-seconds) per mode, for rates
    def frame_time(d):
        acc = Counter()
        for v in d.values():
            for (t0, _), (t1, _) in zip(v, v[1:]):
                dt = t1 - t0
                if 0 < dt < 200:
                    acc[mode_at(t0)] += dt
        return acc

    own_time = frame_time(oz)
    obs_time = frame_time(bz)

    report = {}
    modes = sorted(set(c[1] for c in C) | {""})
    for mode in modes:
        if not mode:
            continue
        m = {"owner_trips": 0, "observer_trips": 0, "matched": 0, "owner_only": 0, "observer_only": 0,
             "offsets": [], "owner_states": Counter(), "observer_states": Counter(), "stuck_long": 0,
             "late_getup": 0, "owner_down_s": 0.0, "observer_down_s": 0.0, "owner_stuck_long": 0}
        used = set()
        for z, eps in oe.items():
            beps = be.get(z, [])
            bstarts = [e[0] for e in beps]
            for e in eps:
                if mode_at(e[0]) != mode:
                    continue
                m["owner_trips"] += 1
                m["owner_states"][e[2]] += 1
                m["owner_down_s"] += (e[1] - e[0]) / 1000.0
                if e[1] - e[0] > 8000:
                    m["owner_stuck_long"] += 1
                i = bisect.bisect_left(bstarts, e[0] - 1000)
                best = None
                while i < len(bstarts) and bstarts[i] <= e[0] + 2000:
                    if (z, i) not in used:
                        best = i
                        break
                    i += 1
                if best is None:
                    m["owner_only"] += 1
                    continue
                used.add((z, best))
                m["matched"] += 1
                m["offsets"].append(bstarts[best] - e[0])
                # observer copy still down well after the owner's zombie got up
                if beps[best][1] - e[1] > 3000:
                    m["late_getup"] += 1
        for z, eps in be.items():
            for i, e in enumerate(eps):
                if mode_at(e[0]) != mode:
                    continue
                m["observer_trips"] += 1
                m["observer_states"][e[2]] += 1
                m["observer_down_s"] += (e[1] - e[0]) / 1000.0
                if e[1] - e[0] > 8000:
                    m["stuck_long"] += 1
                if (z, i) not in used:
                    m["observer_only"] += 1
        offs = sorted(m["offsets"])
        m["offset_ms_p50"] = offs[len(offs) // 2] if offs else None
        m["offset_ms_p10"] = offs[len(offs) // 10] if offs else None
        m["offset_ms_p90"] = offs[(len(offs) * 9) // 10] if offs else None
        del m["offsets"]
        m["owner_zombie_min"] = own_time.get(mode, 0.0) / 60000.0
        m["observer_zombie_min"] = obs_time.get(mode, 0.0) / 60000.0
        m["owner_trips_per_zmin"] = m["owner_trips"] / m["owner_zombie_min"] if m["owner_zombie_min"] else None
        m["observer_trips_per_zmin"] = m["observer_trips"] / m["observer_zombie_min"] if m["observer_zombie_min"] else None
        m["owner_states"] = dict(m["owner_states"])
        m["observer_states"] = dict(m["observer_states"])
        report[mode] = m

    # teleports (needs livetest.py analyze to have written teleports.csv)
    tp = os.path.join(res, "teleports.csv")
    if os.path.isfile(tp):
        for r in csv.DictReader(open(tp, encoding="utf-8")):
            mode = r["mode"]
            if mode not in report:
                continue
            m = report[mode]
            down = r["state_before"] in DOWN or r["state_after"] in DOWN
            k = "teleports_down" if down else "teleports_other"
            m[k] = m.get(k, 0) + 1
    for mode, m in report.items():
        m.setdefault("teleports_down", 0)
        m.setdefault("teleports_other", 0)

    print(f"results: {res}")
    hdr = (f"{'mode':8s} {'zmin':>6s} {'own.trips':>9s} {'/zmin':>6s} {'obs.trips':>9s} {'/zmin':>6s} {'matched':>7s} "
           f"{'own.only':>8s} {'obs.only':>8s} {'off p10/50/90 ms':>18s} {'tele.down':>9s} {'tele.oth':>8s} "
           f"{'stuck>8s':>8s} {'(own)':>5s} {'lateUp':>6s}")
    print(hdr)
    for mode, m in report.items():
        off = "/".join("-" if v is None else f"{v:.0f}" for v in (m["offset_ms_p10"], m["offset_ms_p50"], m["offset_ms_p90"]))
        print(f"{mode:8s} {m['owner_zombie_min']:6.1f} {m['owner_trips']:9d} {m['owner_trips_per_zmin'] or 0:6.2f} "
              f"{m['observer_trips']:9d} {m['observer_trips_per_zmin'] or 0:6.2f} {m['matched']:7d} {m['owner_only']:8d} "
              f"{m['observer_only']:8d} {off:>18s} {m['teleports_down']:9d} {m['teleports_other']:8d} "
              f"{m['stuck_long']:8d} {m['owner_stuck_long']:5d} {m['late_getup']:6d}")
        print(f"         owner first states {m['owner_states']}  observer {m['observer_states']}")
    if "--json" in sys.argv:
        json.dump(report, open(sys.argv[sys.argv.index("--json") + 1], "w"), indent=2)


if __name__ == "__main__":
    main()
