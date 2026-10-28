"""Live test of Tripping Zombies MP Fix on the zombie sync harness (workspace/pz-zombiesync/livetest).

  python -I run_live.py start <label> --fix on|off [--wan] [--hits SECONDS] [--tz "key=val,..."] [--no-zs]
                                      [--phases N] [--zombies N]
  python -I run_live.py wait [SECONDS]      follow the run (default 540 s); prints 'state: done' when finished
  python -I run_live.py finish              stop the game, collect, analyze, release the game lock
  python -I run_live.py analyze <results dir>

  --fix on|off   SandboxVars.TrippingZombiesMPFix.Enabled (the add-on is always loaded; off = TZ as without it)
  --wan          the observer plays over the friend-like internet profile (--wan friend --wan-seed 11)
  --hits S       TZFixTest reports a hit every S s from each client (owner: melee on its own zombie,
                 observer: firearm on the owner's zombies), the way Tripping Zombies' client reports hits
  --tz ...       overrides of the user's TrippingZombies sandbox values (PRALIFE_SandboxVars.lua)
  --no-zs        without ZombieSyncMP (default: ZombieSync 1.1.0 loaded, switched on/off every phase)
  --sprinters P  SandboxVars.ZombieLore.SprinterPercentage (the harness spawns random-speed zombies, 25 %)

start takes workspace/.pz-game.lock (and waits while ProjectZomboid64.exe or a java.exe started from the game
folder runs: never touches the user's game); finish releases it. Results: livetest/results/<stamp> with
tzfix_label.json; analysis/trips.py and analysis/fixlog.py output; a line in pz-tzfix/runs.csv.
"""
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(HERE)
WS = os.path.dirname(PROJ)
LIVE = os.path.join(WS, "pz-zombiesync", "livetest")
LOCK = os.path.join(WS, ".pz-game.lock")
PRALIFE = os.path.join(os.path.expanduser("~"), "Zomboid", "Server", "PRALIFE_SandboxVars.lua")
FIX_DIR = os.path.join(PROJ, "mod", "TrippingZombiesMPFix")
TEST_DIR = os.path.join(PROJ, "test", "TZFixTest")
STATE = os.path.join(PROJ, "build", "run_state.json")
PY = sys.executable


def arg(name, default=None):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default


def tz_block(overrides):
    """The user's TrippingZombies = { ... } block (comments dropped), with overrides."""
    text = open(PRALIFE, encoding="utf-8", errors="replace").read()
    m = re.search(r"\n(    TrippingZombies = \{\n.*?\n    \},)\n", text, re.S)
    if not m:
        raise SystemExit("no TrippingZombies block in " + PRALIFE)
    block = "\n".join(ln for ln in m.group(1).splitlines() if not ln.strip().startswith("--"))
    for k, v in overrides.items():
        block, n = re.subn(r"(\n        " + re.escape(k) + r" = )[^,\n]*,", r"\g<1>" + v + ",", block)
        if n != 1:
            raise SystemExit(f"TrippingZombies.{k} not found once in the block")
    return block


def game_busy():
    """Running Project Zomboid processes: the game itself, or a java started from the game folder
    (a co-op host's server, a dedicated server, another test)."""
    ps = ("Get-CimInstance Win32_Process | Where-Object { $_.Name -in @('ProjectZomboid64.exe','java.exe','javaw.exe') } "
          "| ForEach-Object { \"$($_.ProcessId)|$($_.Name)|$($_.CommandLine)\" }")
    out = subprocess.run(["powershell", "-NoProfile", "-Command", ps], capture_output=True, text=True, errors="replace").stdout
    busy = []
    for ln in out.splitlines():
        parts = ln.split("|", 2)
        if len(parts) < 3:
            continue
        pid, name, cmdline = parts
        if name.lower() == "projectzomboid64.exe" or "zomboid" in cmdline.lower():
            busy.append(f"{name} {pid}")
    return busy


def take_lock(max_wait_s):
    t0 = time.time()
    while True:
        busy = game_busy()
        if not busy:
            try:
                os.mkdir(LOCK)
                with open(os.path.join(LOCK, "owner.txt"), "w") as f:
                    f.write(f"pz-tzfix live test (Tripping Zombies MP Fix), {time.ctime()}\n")
                return True
            except FileExistsError:
                p = os.path.join(LOCK, "owner.txt")
                busy = ["lock held: " + (open(p).read().strip() if os.path.isfile(p) else "?")]
        if time.time() - t0 > max_wait_s:
            print("game busy:", ", ".join(busy), flush=True)
            return False
        print("waiting, game busy:", ", ".join(busy), flush=True)
        time.sleep(30)


def release_lock():
    try:
        os.remove(os.path.join(LOCK, "owner.txt"))
    except OSError:
        pass
    try:
        os.rmdir(LOCK)
    except OSError:
        pass


def cmd_start():
    label = sys.argv[2]
    fix = arg("--fix", "on") == "on"
    wan = "--wan" in sys.argv
    hits = float(arg("--hits", "0"))
    zs = "--no-zs" not in sys.argv
    phases = int(arg("--phases", "6"))
    zombies = int(arg("--zombies", "16"))
    tz = dict(kv.split("=", 1) for kv in arg("--tz", "").split(",") if "=" in kv)
    sprinters = arg("--sprinters", None)

    os.makedirs(os.path.join(PROJ, "build"), exist_ok=True)
    extra = os.path.join(PROJ, "build", "sandbox_extra.lua")
    with open(extra, "w", encoding="utf-8", newline="\n") as f:
        f.write(tz_block(tz) + "\n")
        f.write("    TrippingZombiesMPFix = {\n        Enabled = %s,\n        SyncGetUp = true,\n        Log = true,\n    },\n"
                % ("true" if fix else "false"))
        if sprinters:
            # a later key wins in a Lua table constructor: replaces the harness's ZombieLore
            f.write("    ZombieLore = {\n        Speed = 4,\n        SprinterPercentage = %d,\n    },\n" % int(sprinters))
    cfg = os.path.join(TEST_DIR, "42", "media", "lua", "shared", "TZFixTest_cfg.lua")
    os.makedirs(os.path.dirname(cfg), exist_ok=True)
    with open(cfg, "w", encoding="utf-8", newline="\n") as f:
        f.write("-- written by pz-tzfix/tools/run_live.py\nTZFixTest_cfg = { hitEvery = %g, startAfter = 75 }\n" % hits)

    cmd = [PY, "-I", "livetest.py", "start", "--walk", "--modpack", "--phases", str(phases), "--phase-ms", "60000",
           "--zombies", str(zombies), "--extra-mods", f"TrippingZombiesMPFix={FIX_DIR};TZFixTest={TEST_DIR}",
           "--sandbox-extra", extra]
    if zs:
        cmd.append("--mod")
    if wan:
        cmd += ["--wan", "friend", "--wan-seed", "11"]
    if not take_lock(float(arg("--max-wait", "420"))):
        raise SystemExit("not started: the game is busy")
    meta = {"label": label, "fix": fix, "wan": wan, "hits": hits, "zs": zs, "phases": phases, "zombies": zombies,
            "tz_overrides": tz, "sprinters": sprinters, "started": time.strftime("%Y-%m-%d %H:%M:%S")}
    json.dump(meta, open(STATE, "w"), indent=2)
    print("start:", " ".join(cmd[2:]), flush=True)
    r = subprocess.run(cmd, cwd=LIVE)
    if r.returncode != 0:
        release_lock()
        raise SystemExit("start failed")


def cmd_wait():
    secs = sys.argv[2] if len(sys.argv) > 2 else "540"
    subprocess.run([PY, "-I", "livetest.py", "wait", secs], cwd=LIVE)


def analyze(res):
    for script in ("trips.py", "fixlog.py"):
        p = os.path.join(PROJ, "analysis", script)
        o = subprocess.run([PY, "-I", p, res, "--json", os.path.join(res, script.replace(".py", ".json"))],
                           capture_output=True, text=True, errors="replace")
        print(o.stdout + o.stderr, flush=True)


def cmd_finish():
    try:
        out = subprocess.run([PY, "-I", "livetest.py", "finish"], cwd=LIVE, capture_output=True, text=True,
                             errors="replace").stdout
    finally:
        release_lock()
    print(out, flush=True)
    m = re.search(r"results: (\S+)", out)
    if not m:
        raise SystemExit("no results dir")
    res = m.group(1)
    meta = json.load(open(STATE)) if os.path.isfile(STATE) else {}
    meta["results"] = res
    json.dump(meta, open(os.path.join(res, "tzfix_label.json"), "w"), indent=2)
    analyze(res)
    with open(os.path.join(PROJ, "runs.csv"), "a", encoding="utf-8") as f:
        f.write(f"{time.strftime('%Y-%m-%d %H:%M')},{meta.get('label')},{os.path.basename(res)},"
                f"fix={'on' if meta.get('fix') else 'off'},wan={'friend' if meta.get('wan') else 'lan'},"
                f"zs={'yes' if meta.get('zs') else 'no'},hits={meta.get('hits')},tz={json.dumps(meta.get('tz_overrides'))}\n")


if __name__ == "__main__":
    c = sys.argv[1] if len(sys.argv) > 1 else ""
    if c == "start":
        cmd_start()
    elif c == "wait":
        cmd_wait()
    elif c == "finish":
        cmd_finish()
    elif c == "analyze":
        analyze(sys.argv[2])
    else:
        print(__doc__)
