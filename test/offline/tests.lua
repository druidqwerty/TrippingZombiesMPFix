-- Offline tests of TZMPFix.lua with the mocked game (mocks.lua) and a stand-in Tripping Zombies (fake_tz.lua).
local check = T.check
local M = TZMPFix

local function opsOf(sent)
    local e = sent.args.z[1]
    local t = {}
    for i, op in ipairs(e.o) do t[i] = tostring(op[1]) end
    return table.concat(t, ",")
end

local function hasCall(z, s)
    for _, c in ipairs(z.calls) do if c == s then return true end end
    return false
end

---------------------------------------------------------------- hooks
check(M.hooked.OnZombieUpdate and M.hooked.OnCharacterCollide and M.hooked.OnClientCommand, "TZ handlers hooked")
check(Events.OnZombieUpdate.handlers[1] ~= FAKE.OnZombieUpdate, "OnZombieUpdate handler is wrapped")
check(M.methodHooks == 11, "11 method hooks without Proper Ragdolls, got " .. tostring(M.methodHooks))
local other = function() end
Events.OnZombieUpdate.Add(other)
check(Events.OnZombieUpdate.handlers[2] == other, "other mods' handlers are added unchanged")
Events.OnZombieUpdate.Remove(other)

---------------------------------------------------------------- client: owner trips its own zombie
T.localPlayer = T.player(1, { isLocal = true, x = 10, y = 20 })
local friend = T.player(2, { x = 12, y = 22 })
T.setSide("client")
local z1 = T.zombie(101, { remote = false })
local z2 = T.zombie(102, { remote = true, x = 30.5 })
FAKE.tripOn[101] = true
FAKE.tripOn[102] = true
T.reset()
T.fire("OnZombieUpdate", z1)
check(#FAKE.updates == 1, "TZ ran for the zombie this client simulates")
check(hasCall(z1, "knockDown(true)"), "the owner's zombie fell")
check(#T.sentClient == 1 and T.sentClient[1].command == "ops", "the trip was sent to the server")
check(#T.sentClient == 1 and opsOf(T.sentClient[1]) == "hb,ff,kd,ap,hd", "ops in order, got " .. (T.sentClient[1] and opsOf(T.sentClient[1]) or "-"))
check(#T.sentClient == 1 and T.sentClient[1].args.s == 1 and T.sentClient[1].args.z[1].i == 101, "sender and zombie id")

T.reset()
T.fire("OnZombieUpdate", z2)
check(#FAKE.updates == 1, "TZ did not run for a zombie another game simulates")
check(#z2.calls == 0 and #T.sentClient == 0, "nothing happened to the remote copy")

-- Enabled = false: Tripping Zombies as without the add-on
SandboxVars.TrippingZombiesMPFix.Enabled = false
T.reset()
T.fire("OnZombieUpdate", z2)
check(#FAKE.updates == 2 and hasCall(z2, "knockDown(true)") and #T.sentClient == 0, "disabled: TZ runs everywhere, nothing sent")
local logged = false
for _, l in ipairs(T.logs) do if string.find(l, "local z=102 copy ops=hb,ff,kd,ap,hd", 1, true) then logged = true end end
check(logged, "disabled + debug log: the copy's own trip is logged as local")
SandboxVars.TrippingZombiesMPFix.Log = false
local nLogs = #T.logs
T.reset()
T.fire("OnZombieUpdate", z2)
check(#FAKE.updates == 3 and #T.logs == nLogs and #T.sentClient == 0, "disabled, no log: plain pass-through")
SandboxVars.TrippingZombiesMPFix.Log = true
SandboxVars.TrippingZombiesMPFix.Enabled = true

-- an error inside TZ: the error still surfaces, and recording is off afterwards
FAKE.errorOn = 101
T.reset()
T.fire("OnZombieUpdate", z1)
check(#T.errors == 1 and string.find(T.errors[1], "boom", 1, true) ~= nil, "TZ's error is passed on")
FAKE.errorOn = nil
T.reset()
z1:knockDown(true)   -- another mod's call, outside TZ
T.fire("OnTick")
check(#T.sentClient == 0, "calls outside TZ's handlers are not recorded")

---------------------------------------------------------------- client: receiving a trip
T.reset()
z2.state = "lunge-network"
z2.knocked = false
T.fire("OnServerCommand", "TZMPFix", "ops", { s = 2, z = { { i = 102, x = 30, y = 20, z = 0,
    o = { { "hb", true }, { "ff", true }, { "kd", true }, { "ap", "BEHIND" }, { "hd", { 0.5, -0.5 } } } } } })
check(table.concat(z2.calls, " ") == "setHitFromBehind(true) setFallOnFront(true) knockDown(true) setPlayerAttackPosition(BEHIND) setHitDir(0.5;-0.5)",
    "the copy got the same calls: " .. table.concat(z2.calls, " "))
-- it lands; the game gives it 1-3 s to lie: we cut that to the owner's get-up
z2.state = "onground"
z2.onFloor = true
z2.timer = 60
T.fire("OnTick")
if #T.errors > 0 then T.realPrint("tick errors: " .. table.concat(T.errors, " | ")) end
check(z2.timer == 2, "the copy's lying time is cut, got " .. tostring(z2.timer))
z2.timer = 1.5
T.fire("OnTick")
check(z2.timer == 1.5, "a shorter lying time is left alone")
T.now = T.now + 20000
T.fire("OnTick")
z2.timer = 60
T.fire("OnTick")
check(z2.timer == 60, "the get-up window ends")
SandboxVars.TrippingZombiesMPFix.SyncGetUp = false

-- a copy that is already down does not fall again
local z3 = T.zombie(103, { remote = true, onFloor = true, state = "onground" })
T.reset()
T.fire("OnServerCommand", "TZMPFix", "ops", { s = 2, z = { { i = 103, x = 10, y = 20, z = 0, o = { { "kd", true } } } } })
check(#z3.calls == 0, "already down: skipped")
-- an attacking copy is unlocked first
local z4 = T.zombie(104, { remote = true, attacking = true, x = 40.5 })
T.reset()
T.fire("OnServerCommand", "TZMPFix", "ops", { s = 2, z = { { i = 104, x = 40, y = 20, z = 0, o = { { "kd", true } } } } })
check(z4.calls[1] == "setStateMachineLocked(false)" and z4.calls[2] == "knockDown(true)", "attacking copy: unlock then knockDown")
-- the zombie is found by id even if it moved away from the reported square
local z5 = T.zombie(105, { remote = true, x = 70.5 })
T.reset()
T.fire("OnServerCommand", "TZMPFix", "ops", { s = 2, z = { { i = 105, x = 10, y = 20, z = 0, o = { { "bt", "left" } } } } })
check(hasCall(z5, "setBumpType(left)"), "found through the zombie list")
-- a bump on a copy: the game clears it when the copy enters the bumped state; we put it back once
local zb = T.zombie(110, { remote = true, x = 60.5 })
FAKE.tripOn[110] = nil
T.reset()
T.fire("OnServerCommand", "TZMPFix", "ops", { s = 2, z = { { i = 110, x = 60, y = 20, z = 0,
    o = { { "hb", true }, { "ff", true }, { "bt", "trippingFromSprint" } } } } })
check(table.concat(zb.calls, " ") == "setHitFromBehind(true) setFallOnFront(true) setBumpType(trippingFromSprint)",
    "the copy gets the bump: " .. table.concat(zb.calls, " "))
T.fire("OnZombieUpdate", zb)            -- not in the bumped state yet: nothing to do
check(#zb.calls == 3, "waits for the bumped state")
zb.state, zb.bump = "bumped", ""        -- entered it; BumpedState.setParams cleared the type
T.fire("OnZombieUpdate", zb)
check(zb.calls[4] == "setBumpType(trippingFromSprint)", "bump type put back after entering: " .. table.concat(zb.calls, " "))
-- and it slides forward like the real zombie does in the clip (2.28 tiles over 1.48 s)
local x0 = zb.nx or zb.x
T.now = T.now + 740
T.fire("OnZombieUpdate", zb)
check(math.abs((zb.nx - x0) - 1.14) < 0.01, "half way after 0.74 s: " .. tostring(zb.nx - x0))
T.now = T.now + 1000
T.fire("OnZombieUpdate", zb)
check(math.abs((zb.nx - x0) - 2.28) < 0.01 and (zb.ny or zb.y) == zb.y, "2.28 tiles forward in total: " .. tostring(zb.nx - x0))
T.fire("OnZombieUpdate", zb)
check(math.abs((zb.nx - x0) - 2.28) < 0.01, "and no further")
check(#zb.calls == 4, "only once")
-- with the sender's start and facing, the copy slides to where the real tumble ends (also closing its lag)
local zt = T.zombie(114, { remote = true, x = 66.5, y = 20.5 })
T.reset()
T.fire("OnServerCommand", "TZMPFix", "ops", { s = 2, z = { { i = 114, x = 66, y = 20, z = 0, px = 67.0, py = 20.5,
    fx = 0, fy = 1, o = { { "bt", "trippingFromSprint" } } } } })
zt.state, zt.bump = "bumped", ""
T.fire("OnZombieUpdate", zt)
T.now = T.now + 2000
T.fire("OnZombieUpdate", zt)
check(math.abs(zt.nx - 67.0) < 0.01 and math.abs(zt.ny - 22.78) < 0.01, "slid to the real tumble's end: " .. tostring(zt.nx) .. "," .. tostring(zt.ny))
-- too far away: left to the game
local zf = T.zombie(115, { remote = true, x = 68.5, y = 20.5 })
T.fire("OnServerCommand", "TZMPFix", "ops", { s = 2, z = { { i = 115, x = 68, y = 20, z = 0, px = 75.0, py = 20.5,
    fx = 1, fy = 0, o = { { "bt", "trippingFromSprint" } } } } })
zf.state, zf.bump = "bumped", ""
T.fire("OnZombieUpdate", zf)
T.now = T.now + 2000
T.fire("OnZombieUpdate", zf)
check(zf.nx == nil, "no slide from further than 4.5 tiles")
-- a copy that never gets into the bumped state is let go after 1.5 s
local zs = T.zombie(112, { remote = true, x = 62.5 })
T.reset()
T.fire("OnServerCommand", "TZMPFix", "ops", { s = 2, z = { { i = 112, x = 62, y = 20, z = 0, o = { { "bt", "left" } } } } })
T.now = T.now + 2000
T.fire("OnZombieUpdate", zs)
zs.state, zs.bump = "bumped", ""
T.fire("OnZombieUpdate", zs)
check(#zs.calls == 1, "expired: not touched again")
-- a copy that leaves the world before its bump starts is swept once a minute
local zg = T.zombie(116, { remote = true, x = 69.5 })
T.fire("OnServerCommand", "TZMPFix", "ops", { s = 2, z = { { i = 116, x = 69, y = 20, z = 0, o = { { "bt", "left" } } } } })
T.now = T.now + 70000
T.fire("OnTick")
zg.state, zg.bump = "bumped", ""
local before = #zg.calls
T.fire("OnZombieUpdate", zg)
check(#zg.calls == before and #T.errors == 0, "stale bump entry swept")
local zl = T.zombie(113, { remote = false, x = 64.5 })
T.reset()
T.fire("OnServerCommand", "TZMPFix", "ops", { s = 2, z = { { i = 113, x = 64, y = 20, z = 0, o = { { "bt", "left" } } } } })
check(table.concat(zl.calls, " ") == "setBumpType(left)", "a zombie we simulate gets the plain bump")
-- A-Life bodies are left alone
local npc = T.zombie(106, { remote = true, md = { ProjectALifeOwned = true }, x = 80.5 })
T.reset()
T.fire("OnServerCommand", "TZMPFix", "ops", { s = 2, z = { { i = 106, x = 80, y = 20, z = 0, o = { { "kd", true } } } } })
check(#npc.calls == 0, "A-Life body untouched")
-- garbage does not break anything
T.reset()
T.fire("OnServerCommand", "TZMPFix", "ops", { z = { { i = "x" }, 5 } })
T.fire("OnServerCommand", "TZMPFix", "ops", "nonsense")
check(#T.errors == 0, "bad input ignored: " .. table.concat(T.errors, " | "))

---------------------------------------------------------------- client: shoulder charges
T.reset()
local me = T.localPlayer
me.sprinting = true
local z8 = T.zombie(108, { remote = true, x = 90.5 })
T.fire("OnCharacterCollide", me, z8)
T.fire("OnCharacterCollide", me, z8)
check(#T.sentClient == 1 and T.sentClient[1].command == "act" and T.sentClient[1].args.k == "bump", "charge into a remote zombie handed to its owner, once")
check(#FAKE.collides == 0, "TZ did not roll the charge here")
T.now = T.now + 600
T.fire("OnCharacterCollide", me, z8)
check(#T.sentClient == 2, "again after 0.5 s")
T.reset()
local z9 = T.zombie(109, { remote = false, x = 91.5 })
FAKE.tripCharge = true
T.fire("OnCharacterCollide", me, z9)
check(#FAKE.collides == 1 and hasCall(z9, "setBumpType(trippingFromSprint)"), "charge into our own zombie rolled here")
check(#T.sentClient == 1 and opsOf(T.sentClient[1]) == "bt,bt", "and sent")
check(#T.sentClient == 1 and T.sentClient[1].args.z[1].px == z9.x and T.sentClient[1].args.z[1].fx == 1, "a tumble carries start and facing")
T.reset()
T.fire("OnCharacterCollide", friend, z9)
check(#FAKE.collides == 1, "another player's charge is not rolled here")
T.fire("OnCharacterCollide", z8, z9)
check(#FAKE.collides == 1, "zombie bump: rolled where the bumping zombie is simulated")
T.fire("OnCharacterCollide", z9, z8)
check(#FAKE.collides == 2, "our zombie bumping: rolled here")

---------------------------------------------------------------- server: relay, hits, server-owned zombies
T.setSide("server")
T.localPlayer = nil
local far = T.player(3, { x = 500, y = 500 })
T.reset()
T.fire("OnClientCommand", "TZMPFix", "ops", me, { s = 1, z = { { i = 101, x = 10, y = 20, z = 0, o = { { "kd", true } } } } })
check(#T.sentServer == 1 and T.sentServer[1].p == friend and T.sentServer[1].command == "ops", "relayed to the near player only, not back")

-- a hit on a zombie a client simulates: handed to its owner
local s1 = T.zombie(201, { remote = false, ownerPlayer = friend, x = 11.5 })   -- on the server: owned by a client
T.reset()
local nCmds = #FAKE.cmds
T.fire("OnClientCommand", "TrippingZombies", "hit", me, { id = 201, x = 11, y = 20, z = 0, kind = "melee", str = 7, wMod = 1 })
check(#FAKE.cmds == nCmds, "the server did not roll it")
check(#T.sentServer == 1 and T.sentServer[1].p == friend and T.sentServer[1].command == "act"
    and T.sentServer[1].args.k == "hit" and T.sentServer[1].args.a == 1 and T.sentServer[1].args.str == 7, "handed to the owner")
-- a possible stealth execution stays on the server
FAKE.SB.enableExecutions = true
me.sneaking, me.behind = true, true
T.reset()
T.fire("OnClientCommand", "TrippingZombies", "hit", me, { id = 201, x = 11, y = 20, z = 0, kind = "melee", str = 7, wMod = 1 })
check(#FAKE.cmds == nCmds + 1 and #T.sentServer == 2 and T.sentServer[1].command == "ops", "sneak hit from behind rolled on the server, its calls sent to everyone near")
me.sneaking, me.behind = false, false
-- a server-simulated zombie: rolled on the server, the fall is sent to the players near it
local s2 = T.zombie(202, { remote = true, x = 12.5 })
T.reset()
nCmds = #FAKE.cmds
T.fire("OnClientCommand", "TrippingZombies", "hit", me, { id = 202, x = 12, y = 20, z = 0, kind = "melee", str = 7, wMod = 1 })
check(#FAKE.cmds == nCmds + 1 and hasCall(s2, "knockDown(false)"), "server-simulated: rolled on the server")
check(#T.sentServer == 2 and T.sentServer[1].command == "ops", "and sent to both near players")
-- the server only rolls trips for zombies nobody owns
FAKE.updates = {}
FAKE.tripOn = {}
T.fire("OnZombieUpdate", s1)
T.fire("OnZombieUpdate", s2)
check(#FAKE.updates == 1 and FAKE.updates[1] == 202, "server: TZ runs only for server-simulated zombies")
-- a charge handed over by a client
T.reset()
T.fire("OnClientCommand", "TZMPFix", "act", me, { k = "bump", i = 201, x = 11, y = 20, z = 0, str = 6 })
check(#T.sentServer == 1 and T.sentServer[1].p == friend and T.sentServer[1].args.k == "bump" and T.sentServer[1].args.a == 1, "charge handed to the owner")

---------------------------------------------------------------- client: the owner rolls a handed-over hit
T.setSide("client")
T.localPlayer = friend
friend.isLocal = true
me.isLocal = false
me.perks.Strength = 2   -- what this game wrongly knows about the other player
FAKE.SB.enableExecutions = true
local c1 = T.zombie(301, { remote = false, x = 14.5 })
T.reset()
nCmds = #FAKE.cmds
T.fire("OnServerCommand", "TZMPFix", "act", { k = "hit", i = 301, x = 12, y = 20, z = 0, a = 1, kind = "melee", str = 9, wMod = 1 })
check(#FAKE.cmds == nCmds + 1, "the owner rolled the hit with TZ's handler")
check(FAKE.perkSeen == 9, "with the attacker's reported strength, got " .. tostring(FAKE.perkSeen))
check(FAKE.execSeen == false, "without executions")
check(FAKE.SB.enableExecutions == true and me:getPerkLevel(Perks.Strength) == 2, "both restored afterwards")
check(FAKE.cmds[#FAKE.cmds].args.x == 14, "TZ is pointed at where our zombie is now")
check(#T.sentClient == 1 and T.sentClient[1].command == "ops" and T.sentClient[1].args.z[1].i == 301, "the fall is sent on")
-- not ours any more: ignored
local c2 = T.zombie(302, { remote = true, x = 15.5 })
T.reset()
nCmds = #FAKE.cmds
T.fire("OnServerCommand", "TZMPFix", "act", { k = "hit", i = 302, x = 15, y = 20, z = 0, a = 1, kind = "melee", str = 9 })
check(#FAKE.cmds == nCmds and #T.sentClient == 0, "a hit for a zombie we do not simulate is ignored")
-- a handed-over charge
T.reset()
local nCol = #FAKE.collides
T.fire("OnServerCommand", "TZMPFix", "act", { k = "bump", i = 301, x = 14, y = 20, z = 0, a = 1, str = 4 })
check(#FAKE.collides == nCol + 1 and FAKE.collides[#FAKE.collides][1] == me, "the owner rolled the charge for the charging player")

---------------------------------------------------------------- single player: everything as without the add-on
T.setSide("sp")
T.localPlayer = me
FAKE.updates = {}
FAKE.tripOn = { [102] = true }
T.reset()
T.fire("OnZombieUpdate", z2)
check(#FAKE.updates == 1 and hasCall(z2, "knockDown(true)") and #T.sentClient == 0, "SP: TZ runs as before, nothing sent")

---------------------------------------------------------------- removing a TZ handler removes the wrapper
Events.OnZombieUpdate.Remove(FAKE.OnZombieUpdate)
check(#Events.OnZombieUpdate.handlers == 0, "Remove(TZ handler) removed the wrapper")

T.realPrint("offline tests: " .. T.passes .. " passed, " .. T.fails .. " failed")
if T.fails > 0 then error("offline tests failed") end
