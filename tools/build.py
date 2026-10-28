"""Build Tripping Zombies MP Fix: offline tests, dist folder + release zip, local install, Steam staging.
Nothing is uploaded or published.

  python -I build.py [--no-tests] [--no-install] [--no-staging]
  JDK=<jdk bin folder> GAME=<Project Zomboid folder> override the defaults below.

Works in the dev workspace (mod/TrippingZombiesMPFix/, docs/README*.md) and in the GitHub repo (the mod's
42/ at the root, README*.md at the root).
- dist/TrippingZombiesMPFix/ (common/ + 42/) and dist/TrippingZombiesMPFix_<version>.zip with README.md,
  README_RU.txt, LICENSE and the mod folder
- installs a copy to ~/Zomboid/mods/TrippingZombiesMPFix
- Steam staging ~/Zomboid/Workshop/TrippingZombiesMPFix: Contents/mods/TrippingZombiesMPFix, preview.png,
  workshop.txt (EN, visibility=public, id=) and workshop_russian.txt (RU, for pz-vehsync/tools/wsdesc) from docs/
"""
import hashlib
import os
import re
import shutil
import subprocess
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(HERE)
MOD = os.path.join(PROJ, "mod", "TrippingZombiesMPFix")
if not os.path.isdir(MOD):  # GitHub repo: the mod folder is the repo root
    MOD = PROJ
DIST = os.path.join(PROJ, "dist")
HOME = os.path.expanduser("~")
INSTALL = os.path.join(HOME, "Zomboid", "mods", "TrippingZombiesMPFix")
STAGING = os.path.join(HOME, "Zomboid", "Workshop", "TrippingZombiesMPFix")


def version():
    text = open(os.path.join(MOD, "42", "mod.info"), encoding="utf-8").read()
    return re.search(r"^modversion=(\S+)", text, re.M).group(1)


def doc(name):
    """docs/<name> in the dev workspace, <name> at the root of the GitHub repo"""
    path = os.path.join(PROJ, "docs", name)
    return path if os.path.isfile(path) else os.path.join(PROJ, name)


def copy_mod(dest):
    """the mod folder: 42/ and an empty common/ (B42 needs it)"""
    if os.path.isdir(dest):
        shutil.rmtree(dest)
    shutil.copytree(os.path.join(MOD, "42"), os.path.join(dest, "42"))
    os.makedirs(os.path.join(dest, "common"), exist_ok=True)


def sha(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


JDK = os.environ.get("JDK") or os.path.join(os.path.dirname(PROJ), "_ext", "jdk", "jdk-25.0.4.1+1", "bin")
GAME = os.environ.get("GAME") or r"G:\Steam\steamapps\common\ProjectZomboid"


def offline_tests():
    """the same as tools/offline_test.sh: the game's Kahlua compiler, then test/offline in the game's VM"""
    out = os.path.join(PROJ, "build", "luacheck")
    os.makedirs(out, exist_ok=True)
    jar = os.path.join(GAME, "projectzomboid.jar")
    subprocess.run([os.path.join(JDK, "javac"), "-encoding", "UTF-8", "-cp", jar, "-d", out,
                    os.path.join(HERE, "LuaCheck.java"), os.path.join(HERE, "LuaRun.java")], check=True)
    cp = out + ";" + jar
    lua = os.path.join(MOD, "42", "media", "lua", "shared", "TrippingZombiesMPFix", "TZMPFix.lua")
    r1 = subprocess.run([os.path.join(JDK, "java"), "-cp", cp, "LuaCheck", lua], capture_output=True, text=True)
    t = os.path.join(PROJ, "test", "offline")
    r2 = subprocess.run([os.path.join(JDK, "java"), "-cp", cp, "LuaRun", os.path.join(t, "mocks.lua"), lua,
                         os.path.join(t, "fake_tz.lua"), os.path.join(t, "tests.lua")],
                        capture_output=True, text=True, cwd=GAME)   # stdlib.lua is read from the game folder
    lines = [ln for ln in (r1.stdout + r2.stdout).splitlines() if ln.startswith("ok ") or "offline tests" in ln
             or "FAIL" in ln or "ERROR" in ln]
    print("\n".join(lines))
    return r1.returncode == 0 and r2.returncode == 0


def main():
    if "--no-tests" not in sys.argv and not offline_tests():
        raise SystemExit("offline tests failed")
    v = version()
    os.makedirs(DIST, exist_ok=True)
    out = os.path.join(DIST, "TrippingZombiesMPFix")
    copy_mod(out)
    zpath = os.path.join(DIST, f"TrippingZombiesMPFix_{v}.zip")
    with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as z:
        z.write(doc("README.md"), "README.md")
        z.write(doc("README_RU.md"), "README_RU.txt")
        z.write(os.path.join(PROJ, "LICENSE"), "LICENSE")
        for root, dirs, files in os.walk(out):
            rel = os.path.relpath(root, DIST).replace("\\", "/")
            if not files and not dirs:
                z.writestr(rel + "/", "")
            for f in sorted(files):
                z.write(os.path.join(root, f), rel + "/" + f)
    lua = os.path.join(out, "42", "media", "lua", "shared", "TrippingZombiesMPFix", "TZMPFix.lua")
    print(f"version {v}\n  {zpath} {os.path.getsize(zpath)} bytes sha256 {sha(zpath)}\n  TZMPFix.lua sha256 {sha(lua)}")
    if "--no-install" not in sys.argv:
        copy_mod(INSTALL)
        print("installed:", INSTALL)
    if "--no-staging" not in sys.argv:
        os.makedirs(STAGING, exist_ok=True)
        copy_mod(os.path.join(STAGING, "Contents", "mods", "TrippingZombiesMPFix"))
        shutil.copy(os.path.join(PROJ, "docs", "preview.png"), os.path.join(STAGING, "preview.png"))
        for name in ("workshop.txt", "workshop_russian.txt"):
            src = os.path.join(PROJ, "docs", name)
            if os.path.isfile(src):
                shutil.copy(src, os.path.join(STAGING, name))
                n = len(open(src, encoding="utf-8").read().encode("utf-8"))
                desc = sum(len(ln[len("description="):].encode("utf-8")) + 1
                           for ln in open(src, encoding="utf-8") if ln.startswith("description="))
                print(f"staging {name}: {n} bytes, description {desc} bytes (Steam limit 8000)")
        print("staging:", STAGING)


if __name__ == "__main__":
    main()
