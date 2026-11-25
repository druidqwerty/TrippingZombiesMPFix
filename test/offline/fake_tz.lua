-- Offline test bench: stands in for Tripping Zombies v2.6.1's media/lua/server file (same handler shapes,
-- trivial logic). Its functions are reported as coming from TZ's file through the mocked getFilenameOfClosure.
local FILE = "G:/Steam/steamapps/workshop/content/108600/3746603021/mods/TrippingZombies/42/media/lua/server/TrippingZombies/TrippingZombies.lua"
local SB = { enabled = true, compatibilityOnly = false, enableExecutions = true, strengthScaling = true,
             firearmScaling = false, ragdollChance = 100 }
FAKE = { updates = {}, collides = {}, cmds = {}, deaths = 0, tripOn = {}, staged = {},
         perkSeen = nil, execSeen = nil, chargeMode = nil, SB = SB }

local function onZombieUpdate(z)
    FAKE.updates[#FAKE.updates + 1] = z.id
    if not SB.enabled or SB.compatibilityOnly then return end
    if FAKE.errorOn == z.id then
        z:setHitFromBehind(true) -- partial op before error
        error("boom in onZombieUpdate")
    end
    local mode = FAKE.tripOn[z.id]
    if mode == "staged" then
        if not FAKE.staged[z.id] then
            FAKE.staged[z.id] = true
            z:setUsePhysicHitReaction(false)
            z:setHitFromBehind(true)
            z:setPlayerAttackPosition("BEHIND")
            z:setHitForce(1.0)
            z:setStaggerBack(true)
        else
            FAKE.staged[z.id] = nil
            z:setUsePhysicHitReaction(true)
            z:setHitFromBehind(true)
            z:setFallOnFront(true)
            z:knockDown(true)
            z:setPlayerAttackPosition("BEHIND")
            local hd = z:getHitDir()
            hd:set(0.4, 0.2)
            z:setHitDir(hd)
        end
    elseif mode then
        if FAKE.prdVars then
            z:setVariable("prdWall", "")
            z:setVariable("prdRun", "true")
            z:setVariable("prdWeapon", "")
            z:setVariable("prdKDWall", "")
        end
        z:setHitFromBehind(true)
        z:setFallOnFront(true)
        z:knockDown(true)
        z:setPlayerAttackPosition("BEHIND")
        local hd = z:getHitDir()
        hd:set(0.5, -0.5)
        z:setHitDir(hd)
    end
end

local function onCharacterCollide(a, b)
    FAKE.collides[#FAKE.collides + 1] = { a, b }
    if not SB.enabled or SB.compatibilityOnly then return end
    if instanceof(a, "IsoPlayer") and instanceof(b, "IsoZombie") and FAKE.tripCharge then
        FAKE.perkSeen = a:getPerkLevel(Perks.Strength)
        if a:isSprinting() then
            FAKE.chargeMode = "sprint"
        elseif a:isRunning() then
            FAKE.chargeMode = "run"
        else
            FAKE.chargeMode = "walk"
            return
        end
        b:setBumpType("")
        b:setBumpType("trippingFromSprint")
    end
end

local function onClientCommand(module, command, player, args)
    if module ~= "TrippingZombies" or command ~= "hit" then return end
    if not SB.enabled or SB.compatibilityOnly then return end
    FAKE.cmds[#FAKE.cmds + 1] = { player = player, args = args }
    FAKE.perkSeen = player:getPerkLevel(Perks.Strength)
    FAKE.execSeen = SB.enableExecutions
    for _, z in ipairs(T.zombies) do
        if z.id == args.id and math.abs(math.floor(z.x) - args.x) <= 2 then
            z:setHitFromBehind(false)
            z:knockDown(false)
            z:setPlayerAttackPosition("FRONT")
        end
    end
end

local function onHitZombie() end
local function onZombieDead(z)
    if isClient() or isServer() then return end
    FAKE.deaths = FAKE.deaths + 1
end

for name, fn in pairs({ OnZombieUpdate = onZombieUpdate, OnCharacterCollide = onCharacterCollide,
                        OnClientCommand = onClientCommand, OnZombieDead = onZombieDead }) do
    T.fileOf[fn] = FILE
    FAKE[name] = fn
    Events[name].Add(fn)
end
T.fileOf[onHitZombie] = FILE

TrippingZombies = { getSandbox = function() return SB end, loadSandbox = function() return SB end }
