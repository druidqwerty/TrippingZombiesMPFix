-- TEST ONLY (never shipped): live-test helper for Tripping Zombies MP Fix on the zombie sync harness.
-- Reports player hits the way Tripping Zombies' own client file does (client command TrippingZombies/hit),
-- so the hit-knockdown path can be measured without real melee: the owner client reports hits on zombies
-- next to it (melee), the observer on zombies the owner simulates (firearm, from its watch spot).
-- Settings: TZFixTest_cfg (shared/TZFixTest_cfg.lua, written by tools/run_live.py): hitEvery seconds (0 = off),
-- startAfter seconds after the first player tick.
if not isClient() then return end

local function log(msg) print("[TZFixTest] " .. tostring(msg)) end

local role
local function readRole()
    if role ~= nil then return role end
    role = ""
    local r = getFileReader("ZSTest.txt", false)
    if not r then return role end
    local line = r:readLine()
    while line do
        local k, v = string.match(line, "^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k == "role" then role = v end
        line = r:readLine()
    end
    r:close()
    return role
end

local cfg = TZFixTest_cfg or {}
local every = (tonumber(cfg.hitEvery) or 0) * 1000
local startAfter = (tonumber(cfg.startAfter) or 90) * 1000
local firstTick, nextHit
local sent = 0

local function upright(z)
    return not z:isDead() and not z:isOnFloor() and not z:isKnockedDown() and not z:isGettingUp()
end

local function pick(p, wantRemote, maxDist)
    local list = getCell():getZombieList()
    local best, bestD
    local n = list:size()
    local start = ZombRand(math.max(1, n))
    for k = 0, n - 1 do
        local z = list:get((start + k) % n)
        if z and z:isRemoteZombie() == wantRemote and upright(z) and z:getOnlineID() >= 0 then
            local dx, dy = z:getX() - p:getX(), z:getY() - p:getY()
            local d = dx * dx + dy * dy
            if d <= maxDist * maxDist then
                if wantRemote then return z end   -- any of them, in random order
                if bestD == nil or d < bestD then best, bestD = z, d end
            end
        end
    end
    return best
end

Events.OnTick.Add(function()
    if every <= 0 then return end
    local p = getPlayer()
    if not p then return end
    local now = getTimestampMs()
    firstTick = firstTick or now
    if now - firstTick < startAfter then return end
    local r = readRole()
    nextHit = nextHit or (now + (r == "observer" and every / 2 or 0))
    if now < nextHit then return end
    nextHit = now + every
    local z, kind
    if r == "owner" then
        z, kind = pick(p, false, 2.5), "melee"
    elseif r == "observer" then
        z, kind = pick(p, true, 40), "firearm"
    end
    if not z then return end
    sent = sent + 1
    sendClientCommand(p, "TrippingZombies", "hit", {
        id = z:getOnlineID(), x = math.floor(z:getX()), y = math.floor(z:getY()), z = math.floor(z:getZ()),
        kind = kind, str = 5, wMod = 1,
    })
    log("hit z=" .. z:getOnlineID() .. " by=" .. r .. " kind=" .. kind .. " n=" .. sent .. " wall=" .. string.format("%.0f", now))
end)

log("loaded, hitEvery=" .. tostring(cfg.hitEvery))
