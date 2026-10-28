-- Offline test bench: stands in for Tripping Zombies' media/lua/server file (same handler shapes, trivial
-- logic). Its functions are reported as coming from TZ's file through the mocked getFilenameOfClosure.
local FILE = "G:/Steam/steamapps/workshop/content/108600/3746603021/mods/TrippingZombies/42/media/lua/server/TrippingZombies/TrippingZombies.lua"
local SB = { enableExecutions = true }
FAKE = { updates = {}, collides = {}, cmds = {}, tripOn = {}, perkSeen = nil, execSeen = nil, SB = SB }

local function onZombieUpdate(z)
    FAKE.updates[#FAKE.updates + 1] = z.id
    if FAKE.errorOn == z.id then error("boom in onZombieUpdate") end
    if FAKE.tripOn[z.id] then
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
    if instanceof(a, "IsoPlayer") and instanceof(b, "IsoZombie") and FAKE.tripCharge then
        b:setBumpType("")
        b:setBumpType("trippingFromSprint")
    end
end

local function onClientCommand(module, command, player, args)
    if module ~= "TrippingZombies" or command ~= "hit" then return end
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

for name, fn in pairs({ OnZombieUpdate = onZombieUpdate, OnCharacterCollide = onCharacterCollide,
                        OnClientCommand = onClientCommand }) do
    T.fileOf[fn] = FILE
    FAKE[name] = fn
    Events[name].Add(fn)
end
T.fileOf[onHitZombie] = FILE

TrippingZombies = { getSandbox = function() return SB end, loadSandbox = function() return SB end }
