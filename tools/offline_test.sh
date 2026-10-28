#!/usr/bin/env bash
# Offline tests: syntax check with the game's Kahlua compiler, then the add-on against a mocked game API
# (test/offline: mocks.lua, fake_tz.lua, tests.lua) in the game's own Kahlua VM and stdlib.
# JDK=<jdk bin folder> GAME=<Project Zomboid folder> override the defaults. Works in the dev workspace
# (mod/TrippingZombiesMPFix/42) and in the GitHub repo (42/ at the root).
set -euo pipefail
export MSYS_NO_PATHCONV=1
HERE="$(cd "$(dirname "$0")/.." && (pwd -W 2>/dev/null || pwd))"
JDK="${JDK:-C:/Users/druid/.openclaw/workspace/_ext/jdk/jdk-25.0.4.1+1/bin}"
GAME="${GAME:-G:/Steam/steamapps/common/ProjectZomboid}"
CP="$HERE/build/luacheck;$GAME/projectzomboid.jar"
MOD="$HERE/mod/TrippingZombiesMPFix"
[ -d "$MOD" ] || MOD="$HERE"
MODLUA="$MOD/42/media/lua/shared/TrippingZombiesMPFix/TZMPFix.lua"

mkdir -p "$HERE/build/luacheck"
"$JDK/javac" -encoding UTF-8 -cp "$GAME/projectzomboid.jar" -d "$HERE/build/luacheck" "$HERE/tools/LuaCheck.java" "$HERE/tools/LuaRun.java"
"$JDK/java" -cp "$CP" LuaCheck "$MODLUA" "$HERE/test/TZFixTest/42/media/lua/client/TZFixTest.lua"
# stdlib.lua is read from the working directory
cd "$GAME"
"$JDK/java" -cp "$CP" LuaRun "$HERE/test/offline/mocks.lua" "$MODLUA" "$HERE/test/offline/fake_tz.lua" "$HERE/test/offline/tests.lua"
