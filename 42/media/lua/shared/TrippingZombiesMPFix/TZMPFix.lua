--*****************************************************************************
-- Tripping Zombies MP Fix (TrippingZombiesMPFix) - add-on for Tripping Zombies, Build 42 multiplayer.
--
-- The problem (B42.21, read from the game code and measured in live tests):
--  * Every zombie near a player is simulated by ONE game, its owner: the client of the player it chases.
--    Everybody else draws a copy from the owner's updates. The server does not update zombies at all
--    (MovingObjectUpdateScheduler.startFrame skips them), it only relays.
--  * Tripping Zombies keeps its logic in media/lua/server, but the game loads that folder on every
--    client as well (GameLoadingState.enter -> LuaManager.LoadDirBase("server")). So each client rolls
--    its own trips for every zombie it has, its copies included, and the server never rolls any.
--  * knockDown(), bump types and staggers are not part of the zombie update the owner sends. Each game
--    therefore shows only its own trips: the owner's trips never reach the other players, and a copy
--    tripped by the other player's own game lies there while the real zombie runs on (the game then
--    teleports it every 3 tiles). Hit knockdowns, which the server rolls, are queued for its own copy and
--    never happen.
--
-- What this add-on does (Lua only; Tripping Zombies itself is neither changed nor copied):
--  1. Tripping Zombies' per-zombie handlers run only on the game that simulates that zombie. A shoulder
--     charge into a zombie that another game simulates, and a hit a player reports, are handed to that
--     game: the owner rolls them with Tripping Zombies' own handler.
--  2. While one of those handlers runs, the zombie state calls it makes (knockDown, setBumpType,
--     setStaggerBack, fall side and direction, ...) are recorded, and right after the handler they are
--     sent through the server to the other players. Their copy of the zombie gets the same calls.
--  3. A copy that fell this way gets up as soon as the real zombie gets up (the game already keeps a
--     copy down while its owner's zombie is down; we only stop it from lying longer than that). A copy's
--     bump is put back after the game clears it, and a sprint tumble slides the copy like the real one.
-- Project A-Life NPC bodies are left alone. Single player: nothing changes.
-- Settings: Sandbox page "Tripping Zombies MP Fix" (Enabled, SyncGetUp, Log), read live.
--*****************************************************************************

if TZMPFix and TZMPFix.loaded then return end
TZMPFix = TZMPFix or {}
local M = TZMPFix
M.loaded = true
M.VERSION = "1.0.0"
M.hooked = {}

local MODULE = "TZMPFix"
local TZ_FILE = "media/lua/server/trippingzombies/trippingzombies.lua"  -- Tripping Zombies' own file
local RELAY_RANGE_SQ = 120 * 120   -- players further than this from the zombie do not get its ops
local SEARCH_R = 3                 -- squares searched around the reported position for a zombie id
local MAX_ENTRIES = 32             -- zombies per message
local MAX_OPS = 32                 -- calls per zombie
local GETUP_WINDOW_MS = 12000      -- how long a copy we knocked down is kept in step for its get-up
local CHARGE_REPEAT_MS = 500       -- one shoulder-charge report per zombie per this

--=============================================================================
-- settings (Sandbox page TrippingZombiesMPFix; read on every use, so admin changes apply at once)
--=============================================================================
local function settings()
    return SandboxVars and SandboxVars.TrippingZombiesMPFix
end

local function enabled()
    local v = settings()
    return v == nil or v.Enabled ~= false
end

local function syncGetUp()
    local v = settings()
    return v == nil or v.SyncGetUp ~= false
end

local function logOn()
    local v = settings()
    return v ~= nil and v.Log == true
end

local function log(msg)
    print("[TZMPFix] " .. msg)
end

local function wall()
    return getTimestampMs()
end

local function ms(t)
    return string.format("%.0f", t)
end

--=============================================================================
-- where we run
--=============================================================================
local SIDE -- "server" | "client" | "sp"; decided in game (the main menu is neither)
local function side()
    if SIDE == nil then
        if isServer() then
            SIDE = "server"
        elseif isClient() then
            SIDE = "client"
        else
            SIDE = "sp"
        end
    end
    return SIDE
end

-- Does this game simulate the zombie? On a client a zombie it simulates has an owner (its own
-- connection) and is not "remote". On the server isRemoteZombie() means the opposite way round: no
-- client owns it, so the server simulates it.
local function simulatedHere(z, s)
    if s == "client" then return not z:isRemoteZombie() end
    if s == "server" then return z:isRemoteZombie() end
    return true
end

-- Project A-Life NPC bodies are IsoZombies too. Tripping Zombies leaves them alone itself; we never
-- send or apply anything for them.
local function isNpcBody(z)
    if not z:hasModData() then return false end
    local md = z:getModData()
    return md.ProjectALifeOwned == true or md.ProjectALifeActor == true or md.ProjectALifeUID ~= nil
end

local function modActive(id)
    local mods = getActivatedMods and getActivatedMods()
    if not mods then return false end
    for i = 0, mods:size() - 1 do
        local m = tostring(mods:get(i))
        if m == id or m == "\\" .. id then return true end
    end
    return false
end

-- Tripping Zombies' live settings table (its getSandbox() returns the table it uses).
local function tzSandbox()
    local tz = TrippingZombies
    if type(tz) ~= "table" then return nil end
    if tz.getSandbox then
        local ok, sb = pcall(tz.getSandbox)
        if ok and type(sb) == "table" then return sb end
    end
    if tz.loadSandbox then
        local ok, sb = pcall(tz.loadSandbox)
        if ok and type(sb) == "table" then return sb end
    end
    return nil
end

local stats = {
    ran = 0, skipped = 0, tx = 0, txMsg = 0, relayed = 0,
    rxApplied = 0, rxDown = 0, rxMiss = 0, rxOther = 0,
    actTx = 0, actFwd = 0, actRun = 0, actNotMine = 0, actMiss = 0, getUp = 0, bumpsKept = 0,
}

--=============================================================================
-- recording Tripping Zombies' zombie state calls
--=============================================================================
-- While depth > 0 we are inside one of Tripping Zombies' handlers on the game that simulates the
-- zombie. The wrapped IsoZombie methods then record their call (and still make it, unchanged).
-- Outside its handlers they only pass the call on, so other mods' calls are never touched.
local depth = 0
local batch, batchN, batchOf = {}, 0, {}

local function record(z, code, arg)
    local e = batchOf[z]
    if e == nil then
        e = { z = z, o = {} }
        batchOf[z] = e
        batchN = batchN + 1
        batch[batchN] = e
    end
    local o = e.o
    if #o < MAX_OPS then o[#o + 1] = { code, arg } end
end

-- code -> IsoZombie method, all with one argument
local CODES = {
    kd = "knockDown",
    bt = "setBumpType",
    sb = "setStaggerBack",
    hb = "setHitFromBehind",
    ff = "setFallOnFront",
    ap = "setPlayerAttackPosition",
    hf = "setHitForce",
    ph = "setUsePhysicHitReaction",
    sl = "setStateMachineLocked",
    cr = "setCrawler",
}
local ORIG = {}   -- method name -> the game's own method (used to apply received calls)

local function installMethodHooks()
    local mt = __classmetatables and IsoZombie and IsoZombie.class and __classmetatables[IsoZombie.class]
    local idx = mt and mt.__index
    if type(idx) ~= "table" then
        log("cannot reach the IsoZombie methods - the fix stays off")
        return false
    end
    local n = 0
    for code, name in pairs(CODES) do
        local orig = idx[name]
        if orig ~= nil then
            ORIG[name] = orig
            local c = code
            idx[name] = function(self, a)
                if depth > 0 then record(self, c, a) end
                return orig(self, a)
            end
            n = n + 1
        end
    end
    -- setHitDir(Vector2): Tripping Zombies aims Project Real Limbs' body with it (recorded as x, y)
    local hd = idx.setHitDir
    if hd ~= nil then
        ORIG.setHitDir = hd
        idx.setHitDir = function(self, v)
            if depth > 0 and v ~= nil then record(self, "hd", { v:getX(), v:getY() }) end
            return hd(self, v)
        end
        n = n + 1
    end
    -- setVariable: only Proper Ragdolls' prd* variables, which Tripping Zombies sets when that mod is on
    local sv = idx.setVariable
    if sv ~= nil and modActive("ProperRagdolls") then
        ORIG.setVariable = sv
        idx.setVariable = function(self, k, v)
            if depth > 0 and type(k) == "string" and string.sub(k, 1, 3) == "prd" then record(self, "sv", { k, v }) end
            return sv(self, k, v)
        end
        n = n + 1
    end
    M.methodHooks = n
    return true
end

local function opCodes(o)
    local t = {}
    for i = 1, #o do
        local c = tostring(o[i][1])
        if c == "bt" then c = "bt=" .. tostring(o[i][2]) end
        t[i] = c
    end
    return table.concat(t, ",")
end

local function nearbyPlayers(x, y, except)
    local out = {}
    local list = getOnlinePlayers()
    if list == nil then return out end
    for i = 0, list:size() - 1 do
        local p = list:get(i)
        if p ~= nil and p ~= except then
            local dx, dy = p:getX() - x, p:getY() - y
            if dx * dx + dy * dy <= RELAY_RANGE_SQ then out[#out + 1] = p end
        end
    end
    return out
end

-- With the fix switched off but the debug log on, Tripping Zombies runs everywhere as without the add-on
-- and its calls are only logged ("local", nothing sent): which game tripped which zombie, for comparisons.
local logOnly = false

-- Send what the last handler did to the other games.
local function flush()
    local list, n = {}, 0
    local t = wall()
    local verbose = logOn()
    for i = 1, batchN do
        local e = batch[i]
        batch[i] = nil
        local z = e.z
        batchOf[z] = nil
        local id = z:getOnlineID()
        if n < MAX_ENTRIES and id ~= nil and id >= 0 and #e.o > 0 and not isNpcBody(z) then
            n = n + 1
            local entry = { i = id, x = math.floor(z:getX()), y = math.floor(z:getY()), z = math.floor(z:getZ()), o = e.o }
            -- a sprint tumble also carries where it starts and which way it goes (see keepCopyBump)
            for k = 1, #e.o do
                if e.o[k][1] == "bt" and e.o[k][2] == "trippingFromSprint" then
                    local f = z:getForwardDirection()
                    entry.px, entry.py = z:getX(), z:getY()
                    entry.fx, entry.fy = f:getX(), f:getY()
                end
            end
            list[n] = entry
            if logOnly then
                log("local z=" .. id .. " " .. (simulatedHere(z, side()) and "own" or "copy") .. " ops=" .. opCodes(e.o)
                    .. " wall=" .. ms(t))
            else
                stats.tx = stats.tx + 1
                if verbose then log("tx z=" .. id .. " ops=" .. opCodes(e.o) .. " wall=" .. ms(t)) end
            end
        end
    end
    batchN = 0
    if n == 0 or logOnly then return end
    local s = side()
    if s == "client" then
        local p = getPlayer()
        if p ~= nil then
            sendClientCommand(p, MODULE, "ops", { s = p:getOnlineID(), z = list })
            stats.txMsg = stats.txMsg + 1
        end
    elseif s == "server" then
        local args = { s = -1, z = list }
        local ps = nearbyPlayers(list[1].x, list[1].y, nil)
        for i = 1, #ps do sendServerCommand(ps[i], MODULE, "ops", args) end
        stats.txMsg = stats.txMsg + 1
    end
end

-- Run one of Tripping Zombies' handlers with recording on, then send what it did.
local function runTZ(fn, a, b, c, d)
    depth = depth + 1
    local ok, err = pcall(fn, a, b, c, d)
    depth = depth - 1
    if depth == 0 and batchN > 0 then
        local ok2, err2 = pcall(flush)
        if not ok2 then
            log("sending failed: " .. tostring(err2))
            batch, batchN, batchOf = {}, 0, {}
        end
    end
    if not ok then error(err) end
end

local function runLogOnly(fn, a, b, c, d)
    logOnly = true
    local ok, err = pcall(runTZ, fn, a, b, c, d)
    logOnly = false
    if not ok then error(err) end
end

--=============================================================================
-- finding a zombie by online id
--=============================================================================
local function findZombie(id, x, y, z)
    id = tonumber(id)
    local cell = getCell()
    if id == nil or cell == nil then return nil end
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if x and y and z then
        x, y, z = math.floor(x), math.floor(y), math.floor(z)
        for dx = -SEARCH_R, SEARCH_R do
            for dy = -SEARCH_R, SEARCH_R do
                local sq = cell:getGridSquare(x + dx, y + dy, z)
                if sq ~= nil then
                    local mos = sq:getMovingObjects()
                    for i = 0, mos:size() - 1 do
                        local mo = mos:get(i)
                        if instanceof(mo, "IsoZombie") and mo:getOnlineID() == id then return mo end
                    end
                end
            end
        end
    end
    local list = cell:getZombieList()
    for i = 0, list:size() - 1 do
        local mo = list:get(i)
        if mo ~= nil and mo:getOnlineID() == id then return mo end
    end
    return nil
end

--=============================================================================
-- applying received calls to our copy
--=============================================================================
local getUpSync = {}  -- zombie -> deadline (wall ms): copies we knocked down, kept in step for their get-up
local getUpN = 0      -- entries in getUpSync (the game's Lua has no next())
local getUpSeen = {}  -- copies whose lying time we already cut (counted once per fall)

local function isDown(z)
    if z:isOnFloor() or z:isKnockedDown() or z:isGettingUp() then return true end
    local st = z:getActionStateName()
    if st == nil then return false end
    st = string.lower(st)
    return string.find(st, "falldown", 1, true) ~= nil or string.find(st, "onground", 1, true) ~= nil
        or string.find(st, "getup", 1, true) ~= nil or string.find(st, "knockeddown", 1, true) ~= nil
end

-- Bumps on a copy: when a zombie another game simulates enters the bumped state, BumpedState.setParams
-- replaces its bump type with the state parameter "bump_type", which only the simulating game fills in (the
-- game syncs it for players, not for zombies; neither the parameter nor BumpedState is reachable from Lua).
-- So the copy's bump is cleared the moment it starts (measured: 9 of 114 played). That happens once, on
-- entering the state: we put the bump type back at the start of the copy's next update (OnZombieUpdate runs
-- before the state transitions), and the bump plays.
-- A copy gets no root motion in the bumped state (IsoGameCharacter.doDeferredMovement moves a remote zombie
-- only while it climbs, staggers, falls, lies or attacks), so it would tumble on the spot while the real
-- zombie slides forward with the clip: measured 2.28 tiles straight ahead over 1.48 s for the sprint tumble
-- (a shoulder stumble moves it 0.1-0.2 tiles), enough for the game's 3-tile teleport. The sender adds where
-- the tumble starts and which way the zombie faces; the copy slides from where it is to where the real
-- zombie's tumble ends, through its movement target (setNextX/Y: the game's own collision and floor
-- handling apply). Further than SLIDE_MAX away it is left to the game's own correction.
local TUMBLE_TILES, TUMBLE_MS, SLIDE_MAX = 2.28, 1480, 4.5
local pendingBump = {}   -- copy -> { bump type, deadline (wall ms), entered, slide, tumble end x, y }
local pendingBumpN = 0

local function watchCopyBump(z, bumpType, t, e)
    if pendingBump[z] == nil then pendingBumpN = pendingBumpN + 1 end
    local p = { bumpType, t + 1500, false, nil, nil, nil }
    local px, py, fx, fy = tonumber(e.px), tonumber(e.py), tonumber(e.fx), tonumber(e.fy)
    if bumpType == "trippingFromSprint" and px and py and fx and fy then
        p[5], p[6] = px + fx * TUMBLE_TILES, py + fy * TUMBLE_TILES
    end
    pendingBump[z] = p
end

local function dropCopyBump(z)
    pendingBump[z] = nil
    pendingBumpN = pendingBumpN - 1
end

-- from the OnZombieUpdate wrapper, for copies, while some bumps are pending
local function keepCopyBump(z)
    local p = pendingBump[z]
    if p == nil then return end
    if z:getActionStateName() ~= "bumped" then
        if p[3] or wall() > p[2] then dropCopyBump(z) end   -- the bump is over, or it never started
        return
    end
    if not p[3] then
        p[3] = true
        local bt = z:getBumpType()
        if bt == nil or bt == "" then
            ORIG.setBumpType(z, p[1])
            stats.bumpsKept = stats.bumpsKept + 1
        end
        if p[1] ~= "trippingFromSprint" then
            dropCopyBump(z)
            return
        end
        local dx, dy
        if p[5] ~= nil then
            dx, dy = p[5] - z:getX(), p[6] - z:getY()
        else
            local f = z:getForwardDirection()
            dx, dy = f:getX() * TUMBLE_TILES, f:getY() * TUMBLE_TILES
        end
        if dx * dx + dy * dy > SLIDE_MAX * SLIDE_MAX then
            dropCopyBump(z)
            return
        end
        p[4] = { wall(), dx, dy, 0 }   -- start, whole slide x / y, fraction done
    end
    local sl = p[4]
    if sl == nil then return end
    local k = (wall() - sl[1]) / TUMBLE_MS
    if k > 1 then k = 1 end
    local step = k - sl[4]
    if step > 0 then
        z:setNextX(z:getNextX() + sl[2] * step)
        z:setNextY(z:getNextY() + sl[3] * step)
        sl[4] = k
    end
    if k >= 1 then dropCopyBump(z) end
end

local function applyOp(z, code, arg)
    if code == "hd" then
        if type(arg) == "table" and ORIG.setHitDir ~= nil then
            local v = z:getHitDir()
            if v ~= nil then
                v:set(tonumber(arg[1]) or 0, tonumber(arg[2]) or 0)
                ORIG.setHitDir(z, v)
            end
        end
        return
    end
    if code == "sv" then
        if type(arg) == "table" and type(arg[1]) == "string" and ORIG.setVariable ~= nil then
            ORIG.setVariable(z, arg[1], arg[2])
        end
        return
    end
    local name = CODES[code]
    local m = name and ORIG[name]
    if m == nil then return end
    if arg == nil and code ~= "ap" and code ~= "bt" then return end
    m(z, arg)
end

local function applyEntry(e, t, verbose)
    if type(e) ~= "table" or type(e.o) ~= "table" then return end
    local id = tonumber(e.i)
    local z = findZombie(id, e.x, e.y, e.z)
    if z == nil then
        stats.rxMiss = stats.rxMiss + 1
        if verbose then log("rx z=" .. tostring(id) .. " miss wall=" .. ms(t)) end
        return
    end
    if z:isDead() or isNpcBody(z) then
        stats.rxOther = stats.rxOther + 1
        return
    end
    local remote = z:isRemoteZombie()
    local o = e.o
    local fall, move = false, false
    for i = 1, MAX_OPS do
        local op = o[i]
        if op == nil then break end
        local c, a = op[1], op[2]
        if c == "kd" and a ~= nil then fall = true end
        if (c == "sb" and a == true) or (c == "bt" and a ~= nil and a ~= "") then move = true end
    end
    -- our copy is already down (it fell, or a hit floored it here): the owner's game decides the rest
    if (fall or move) and isDown(z) then
        stats.rxDown = stats.rxDown + 1
        if verbose then log("rx z=" .. id .. " down ops=" .. opCodes(o) .. " wall=" .. ms(t)) end
        return
    end
    -- an attacking zombie's state machine is locked and would swallow the knockdown
    if fall and z:isAttacking() and ORIG.setStateMachineLocked ~= nil then
        ORIG.setStateMachineLocked(z, false)
    end
    for i = 1, MAX_OPS do
        local op = o[i]
        if op == nil then break end
        applyOp(z, op[1], op[2])
        if remote and op[1] == "bt" and type(op[2]) == "string" and op[2] ~= "" and ORIG.setBumpType ~= nil then
            watchCopyBump(z, op[2], t, e)
        end
    end
    if fall and remote then
        if getUpSync[z] == nil then getUpN = getUpN + 1 end
        getUpSync[z] = t + GETUP_WINDOW_MS
        getUpSeen[z] = nil
    end
    stats.rxApplied = stats.rxApplied + 1
    if verbose then log("rx z=" .. id .. " applied ops=" .. opCodes(o) .. " wall=" .. ms(t)) end
end

local function applyOps(args)
    if type(args) ~= "table" or type(args.z) ~= "table" then return end
    local t = wall()
    local verbose = logOn()
    for i = 1, MAX_ENTRIES do
        local e = args.z[i]
        if e == nil then break end
        local ok, err = pcall(applyEntry, e, t, verbose)
        if not ok then log("applying failed: " .. tostring(err)) end
    end
end

-- A copy we knocked down: the game lets a copy get up only once its owner's zombie is up, but also
-- only after the copy's own random lying time (1-3 s). Shorten the latter, so the copy gets up when
-- the real zombie does instead of lying on while it runs off (that is what got it teleported).
local function keepGetUpsInStep()
    if getUpN <= 0 then return end
    if not syncGetUp() then
        getUpSync, getUpN, getUpSeen = {}, 0, {}
        return
    end
    local t = wall()
    for z, deadline in pairs(getUpSync) do
        if t > deadline or z:isDead() or not z:isRemoteZombie() then
            getUpSync[z] = nil
            getUpSeen[z] = nil
            getUpN = getUpN - 1
        elseif z:getActionStateName() == "onground" and z:getReanimateTimer() > 2 then
            z:setReanimateTimer(2)
            if getUpSeen[z] == nil then
                getUpSeen[z] = true
                stats.getUp = stats.getUp + 1
            end
        end
    end
end

--=============================================================================
-- handing a roll to the zombie's owner
--=============================================================================
local captured = {}    -- event name -> Tripping Zombies' own handler

-- Run a handed-over roll as the attacker's game would have: with the strength it reported (a remote
-- player's skills are not known here) and without stealth executions (those stay on the server).
local function withAttacker(attacker, str, f)
    local sb = tzSandbox()
    local savedExec
    if sb ~= nil then
        savedExec = sb.enableExecutions
        sb.enableExecutions = false
    end
    local idx, orig
    if type(str) == "number" and str >= 0 and str <= 10 and Perks and Perks.Strength then
        local mt = __classmetatables and IsoPlayer and IsoPlayer.class and __classmetatables[IsoPlayer.class]
        idx = mt and mt.__index
        orig = type(idx) == "table" and idx.getPerkLevel or nil
        if orig ~= nil then
            local strength = Perks.Strength
            idx.getPerkLevel = function(self, perk)
                if perk == strength and self == attacker then return str end
                return orig(self, perk)
            end
        end
    end
    local ok, err = pcall(f)
    if orig ~= nil then idx.getPerkLevel = orig end
    if sb ~= nil then sb.enableExecutions = savedExec end
    if not ok then log("handed-over roll failed: " .. tostring(err)) end
end

local function strengthOf(p)
    local ok, v = pcall(function() return p:getPerkLevel(Perks.Strength) end)
    if ok and type(v) == "number" then return v end
    return nil
end

-- server: send a roll to the game that simulates the zombie
local function sendToOwner(z, msg)
    local owner = z:getOwnerPlayer()
    if owner ~= nil then
        sendServerCommand(owner, MODULE, "act", msg)
        return true
    end
    local ps = nearbyPlayers(z:getX(), z:getY(), nil)
    for i = 1, #ps do sendServerCommand(ps[i], MODULE, "act", msg) end
    return #ps > 0
end

-- server: a player reported a hit (Tripping Zombies' own client command). If a player's game simulates
-- the zombie, that game rolls the knockdown, so the fall is the real zombie's and everyone sees it.
local function hitToOwner(player, args)
    if player == nil or type(args) ~= "table" then return false end
    local id, x, y, zz = tonumber(args.id), tonumber(args.x), tonumber(args.y), tonumber(args.z)
    if not (id and x and y and zz) then return false end
    local z = findZombie(id, x, y, zz)
    if z == nil or isNpcBody(z) then return false end
    if z:isRemoteZombie() then return false end   -- nobody owns it: the server simulates it and rolls it
    -- a sneak attack from behind may be a stealth execution (opt-in): that stays with the server, as before
    local sb = tzSandbox()
    if sb ~= nil and sb.enableExecutions == true and player:isSneaking() and player:isBehind(z) then return false end
    local msg = {
        k = "hit", i = id, x = math.floor(z:getX()), y = math.floor(z:getY()), z = math.floor(z:getZ()),
        a = player:getOnlineID(), kind = args.kind, str = tonumber(args.str), wMod = tonumber(args.wMod),
    }
    if not sendToOwner(z, msg) then return false end
    stats.actFwd = stats.actFwd + 1
    if logOn() then log("act hit z=" .. id .. " -> owner wall=" .. ms(wall())) end
    return true
end

-- client: a shoulder charge into a zombie another game simulates; that game rolls it
local lastCharge = {}
local function chargeToOwner(p, z)
    if not (p:isSprinting() or p:isRunning()) then return end
    local id = z:getOnlineID()
    if id == nil or id < 0 or isNpcBody(z) then return end
    local t = wall()
    local last = lastCharge[z]
    if last ~= nil and t - last < CHARGE_REPEAT_MS then return end
    lastCharge[z] = t
    sendClientCommand(p, MODULE, "act", {
        k = "bump", i = id, x = math.floor(z:getX()), y = math.floor(z:getY()), z = math.floor(z:getZ()),
        str = strengthOf(p),
    })
    stats.actTx = stats.actTx + 1
    if logOn() then log("act bump z=" .. id .. " sent wall=" .. ms(t)) end
end

-- the owner's game: roll a handed-over hit or charge with Tripping Zombies' own handler
local function runAct(args, attacker)
    local id = tonumber(args.i)
    local z = findZombie(id, args.x, args.y, args.z)
    if z == nil then
        stats.actMiss = stats.actMiss + 1
        return
    end
    if not simulatedHere(z, side()) or isNpcBody(z) then
        stats.actNotMine = stats.actNotMine + 1
        return
    end
    if attacker == nil then return end
    local str = tonumber(args.str)
    if args.k == "hit" then
        local fn = captured.OnClientCommand
        if fn == nil then return end
        -- Tripping Zombies looks for the zombie around the given square: give it where ours is now
        local hit = { id = id, x = math.floor(z:getX()), y = math.floor(z:getY()), z = math.floor(z:getZ()),
                      kind = args.kind, str = args.str, wMod = args.wMod }
        withAttacker(attacker, str, function() runTZ(fn, "TrippingZombies", "hit", attacker, hit) end)
    elseif args.k == "bump" then
        local fn = captured.OnCharacterCollide
        if fn == nil then return end
        withAttacker(attacker, str, function() runTZ(fn, attacker, z) end)
    else
        return
    end
    stats.actRun = stats.actRun + 1
    if logOn() then log("act " .. tostring(args.k) .. " z=" .. tostring(id) .. " rolled wall=" .. ms(wall())) end
end

--=============================================================================
-- wrappers around Tripping Zombies' handlers
--=============================================================================
local function wrapZombieUpdate(fn)
    return function(z)
        local s = SIDE or side()
        if s == "sp" then return fn(z) end
        if not enabled() then
            if logOn() then return runLogOnly(fn, z) end
            return fn(z)
        end
        if simulatedHere(z, s) then
            stats.ran = stats.ran + 1
            return runTZ(fn, z)
        end
        stats.skipped = stats.skipped + 1   -- another game simulates it and rolls its trips
        if pendingBumpN > 0 then keepCopyBump(z) end
    end
end

local function wrapCollide(fn)
    return function(a, b)
        local s = SIDE or side()
        if s == "sp" then return fn(a, b) end
        if not enabled() then
            if logOn() then return runLogOnly(fn, a, b) end
            return fn(a, b)
        end
        if instanceof(a, "IsoZombie") then
            -- zombie bumping into something: rolled where that zombie is simulated
            if simulatedHere(a, s) then return runTZ(fn, a, b) end
            return
        end
        if instanceof(a, "IsoPlayer") and instanceof(b, "IsoZombie") then
            -- shoulder charge: rolled once, by the charging player's game or by the zombie's owner
            if s ~= "client" or not a:isLocalPlayer() then return end
            if b:isRemoteZombie() then return chargeToOwner(a, b) end
            return runTZ(fn, a, b)
        end
        return fn(a, b)
    end
end

local function wrapClientCommand(fn)
    return function(module, command, player, args)
        if module == "TrippingZombies" and command == "hit" and (SIDE or side()) == "server" and enabled() then
            local ok, handed = pcall(hitToOwner, player, args)
            if not ok then log("handing a hit over failed: " .. tostring(handed)) end
            if ok and handed then return end
            return runTZ(fn, module, command, player, args)
        end
        return fn(module, command, player, args)
    end
end

local function isTZHandler(fn)
    if type(fn) ~= "function" or getFilenameOfClosure == nil then return false end
    local ok, name = pcall(getFilenameOfClosure, fn)
    if not ok or type(name) ~= "string" then return false end
    local slashes = string.gsub(name, "\\", "/")
    return string.find(string.lower(slashes), TZ_FILE, 1, true) ~= nil
end

-- Events.<name>.Add/Remove: wrap the handlers that come from Tripping Zombies' file, pass the rest on.
local function hookEvent(name, make)
    local ev = Events and Events[name]
    if ev == nil or ev.Add == nil then return end
    local add, remove = ev.Add, ev.Remove
    local wrapped = {}
    ev.Add = function(fn)
        if isTZHandler(fn) then
            local w = make(fn)
            wrapped[fn] = w
            captured[name] = fn
            M.hooked[name] = true
            return add(w)
        end
        return add(fn)
    end
    if remove ~= nil then
        ev.Remove = function(fn)
            local w = wrapped[fn]
            if w ~= nil then
                wrapped[fn] = nil
                if captured[name] == fn then captured[name] = nil end
                return remove(w)
            end
            return remove(fn)
        end
    end
end

--=============================================================================
-- our own commands
--=============================================================================
local function onClientCommand(module, command, player, args)   -- server
    if module ~= MODULE or not enabled() then return end
    if type(args) ~= "table" then return end
    if command == "ops" then
        -- a client's Tripping Zombies tripped a zombie it simulates: pass the calls to everyone near
        local first = type(args.z) == "table" and args.z[1]
        if type(first) ~= "table" then return end
        local x, y = tonumber(first.x), tonumber(first.y)
        if not (x and y) then return end
        local ps = nearbyPlayers(x, y, player)
        for i = 1, #ps do sendServerCommand(ps[i], MODULE, "ops", args) end
        stats.relayed = stats.relayed + 1
    elseif command == "act" and args.k == "bump" then
        -- a shoulder charge into a zombie the charging player does not simulate
        local z = findZombie(args.i, args.x, args.y, args.z)
        if z == nil or isNpcBody(z) then return end
        if z:isRemoteZombie() then
            -- nobody owns it: the server simulates it, so it rolls here
            local fn = captured.OnCharacterCollide
            if fn ~= nil then withAttacker(player, tonumber(args.str), function() runTZ(fn, player, z) end) end
            return
        end
        local msg = { k = "bump", i = z:getOnlineID(), x = math.floor(z:getX()), y = math.floor(z:getY()),
                      z = math.floor(z:getZ()), a = player:getOnlineID(), str = tonumber(args.str) }
        if sendToOwner(z, msg) then stats.actFwd = stats.actFwd + 1 end
    end
end

local function onServerCommand(module, command, args)   -- client
    if module ~= MODULE or not enabled() then return end
    if command == "ops" then
        applyOps(args)
    elseif command == "act" and type(args) == "table" then
        local ok, err = pcall(runAct, args, getPlayerByOnlineID(tonumber(args.a) or -1))
        if not ok then log("handed-over roll failed: " .. tostring(err)) end
    end
end

--=============================================================================
-- status, stats
--=============================================================================
local nextStats = nil
local function statsLine()
    return "stats (" .. tostring(SIDE) .. "): handlers run " .. stats.ran .. ", skipped " .. stats.skipped
        .. " | sent " .. stats.tx .. " zombies in " .. stats.txMsg .. " msgs, relayed " .. stats.relayed
        .. " | received: applied " .. stats.rxApplied .. ", already down " .. stats.rxDown
        .. ", not found " .. stats.rxMiss .. ", other " .. stats.rxOther
        .. " | rolls handed over " .. (stats.actTx + stats.actFwd) .. ", rolled here " .. stats.actRun
        .. ", not ours " .. stats.actNotMine .. ", missing " .. stats.actMiss
        .. " | get-ups kept in step " .. stats.getUp .. ", copy bumps kept " .. stats.bumpsKept
end

local function onTick()
    local s = SIDE or side()
    if s == "sp" then return end
    if s == "client" then keepGetUpsInStep() end
    local t = wall()
    if nextStats == nil then nextStats = t + 60000 end
    if t >= nextStats then
        nextStats = t + 60000
        if logOn() then log(statsLine()) end
        lastCharge = {}
        -- a copy that left the world before its bump started never updates again
        for z, p in pairs(pendingBump) do
            if t > p[2] + 5000 then dropCopyBump(z) end
        end
    end
end

local function onStart()
    SIDE = nil
    local s = side()
    local h = M.hooked
    local status = "OnZombieUpdate " .. (h.OnZombieUpdate and "yes" or "no")
        .. ", OnCharacterCollide " .. (h.OnCharacterCollide and "yes" or "no")
        .. ", OnClientCommand " .. (h.OnClientCommand and "yes" or "no")
    log(M.VERSION .. " on " .. s .. ": Tripping Zombies handlers " .. status .. "; method hooks "
        .. tostring(M.methodHooks) .. "; " .. (enabled() and "enabled" or "disabled in Sandbox"))
    if s ~= "sp" and type(TrippingZombies) == "table" and not h.OnZombieUpdate then
        log("WARNING: Tripping Zombies is loaded but its handlers were registered before this fix - the fix is not active")
    end
end

--=============================================================================
-- wiring (this file is in media/lua/shared, so it loads before Tripping Zombies' media/lua/server file)
--=============================================================================
if installMethodHooks() then
    hookEvent("OnZombieUpdate", wrapZombieUpdate)
    hookEvent("OnCharacterCollide", wrapCollide)
    hookEvent("OnClientCommand", wrapClientCommand)
    Events.OnClientCommand.Add(onClientCommand)
    Events.OnServerCommand.Add(onServerCommand)
    Events.OnTick.Add(onTick)
    Events.OnGameStart.Add(onStart)
    if Events.OnServerStarted then Events.OnServerStarted.Add(onStart) end
end

M.stats = stats
M.statsLine = statsLine
