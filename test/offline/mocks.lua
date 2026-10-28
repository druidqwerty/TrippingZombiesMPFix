-- Offline test bench: a minimal fake of the game API that TZMPFix.lua uses. Runs in the game's Kahlua VM
-- (tools/LuaRun.java). Zombies and players are Lua tables whose methods live in fake class method tables,
-- the same way the game exposes IsoZombie / IsoPlayer (__classmetatables[Class.class].__index).
T = { now = 1000, side = "client", sentClient = {}, sentServer = {}, logs = {}, zombies = {}, players = {},
      fileOf = {}, errors = {}, fails = 0, passes = 0 }

local realPrint = print
T.realPrint = realPrint
function print(s)
    T.logs[#T.logs + 1] = tostring(s)
    if T.echo then realPrint(s) end
end

function getTimestampMs() return T.now end
function isServer() return T.side == "server" end
function isClient() return T.side == "client" end
SandboxVars = { TrippingZombiesMPFix = { Enabled = true, SyncGetUp = true, Log = true } }

local ZCLASS, PCLASS = { name = "IsoZombie" }, { name = "IsoPlayer" }
IsoZombie = { class = ZCLASS }
IsoPlayer = { class = PCLASS }
ZIDX, PIDX = {}, {}
local ZMT, PMT = { __index = ZIDX }, { __index = PIDX }
__classmetatables = { [ZCLASS] = ZMT, [PCLASS] = PMT }
Perks = { Strength = { name = "Strength" } }

local function list(items)
    local l = { items = items }
    function l:size() return #self.items end
    function l:get(i) return self.items[i + 1] end
    return l
end
T.list = list

function getActivatedMods() return list({ "\\TrippingZombies", "\\TrippingZombiesMPFix" }) end

-- the game's own (Java) zombie methods: log the call, keep a little state
local function rec(self, name, a) self.calls[#self.calls + 1] = name .. "(" .. tostring(a) .. ")" end
ZIDX.knockDown = function(self, a) rec(self, "knockDown", a); self.knocked = true end
ZIDX.setBumpType = function(self, a) rec(self, "setBumpType", a); self.bump = a; T.order[#T.order + 1] = "setBumpType:" .. tostring(a) end
ZIDX.setStaggerBack = function(self, a) rec(self, "setStaggerBack", a) end
ZIDX.setHitFromBehind = function(self, a) rec(self, "setHitFromBehind", a) end
ZIDX.setFallOnFront = function(self, a) rec(self, "setFallOnFront", a) end
ZIDX.setPlayerAttackPosition = function(self, a) rec(self, "setPlayerAttackPosition", a) end
ZIDX.setHitForce = function(self, a) rec(self, "setHitForce", a) end
ZIDX.setUsePhysicHitReaction = function(self, a) rec(self, "setUsePhysicHitReaction", a) end
ZIDX.setStateMachineLocked = function(self, a) rec(self, "setStateMachineLocked", a) end
ZIDX.setCrawler = function(self, a) rec(self, "setCrawler", a) end
ZIDX.setHitDir = function(self, v) rec(self, "setHitDir", v and (v.x .. ";" .. v.y)) end
ZIDX.setVariable = function(self, k, v) rec(self, "setVariable", tostring(k) .. "=" .. tostring(v)) end
ZIDX.getHitDir = function(self)
    self.hd = self.hd or { x = 0, y = 0, set = function(v, x, y) v.x, v.y = x, y end,
                           getX = function(v) return v.x end, getY = function(v) return v.y end }
    return self.hd
end
ZIDX.getOnlineID = function(self) return self.id end
ZIDX.getX = function(self) return self.x end
ZIDX.getY = function(self) return self.y end
ZIDX.getZ = function(self) return self.z end
ZIDX.isRemoteZombie = function(self) return self.remote end
ZIDX.isOnFloor = function(self) return self.onFloor == true end
ZIDX.isKnockedDown = function(self) return self.knocked == true end
ZIDX.isGettingUp = function(self) return self.gettingUp == true end
ZIDX.getActionStateName = function(self) return self.state end
ZIDX.isDead = function(self) return self.dead == true end
ZIDX.isAttacking = function(self) return self.attacking == true end
ZIDX.hasModData = function(self) return self.md ~= nil end
ZIDX.getModData = function(self) self.md = self.md or {}; return self.md end
ZIDX.getReanimateTimer = function(self) return self.timer end
ZIDX.setReanimateTimer = function(self, v) self.timer = v end
ZIDX.getOwnerPlayer = function(self) return self.ownerPlayer end
ZIDX.getBumpType = function(self) return self.bump end
ZIDX.getForwardDirection = function(self)
    local f = { x = self.fx or 1, y = self.fy or 0 }
    function f:getX() return self.x end
    function f:getY() return self.y end
    return f
end
ZIDX.getNextX = function(self) return self.nx or self.x end
ZIDX.getNextY = function(self) return self.ny or self.y end
ZIDX.setNextX = function(self, v) self.nx = v end
ZIDX.setNextY = function(self, v) self.ny = v end
-- the game's state objects: getCurrentState() returns them; State:loadFrom sets a state's parameters by name
-- (StateMachineComponent is not exposed to Lua in the game, so it is not mocked either)
local function stateObject(name)
    local st = { name = name }
    function st:loadFrom(m, who)
        if self.name ~= "BumpedState" then error("loadFrom on " .. self.name) end
        T.order[#T.order + 1] = "param:" .. tostring(m.data.bump_type)
        who.bumpParam = m.data.bump_type
    end
    return setmetatable(st, { __tostring = function(t) return "zombie.ai.states." .. t.name .. "@1f2e" end })
end
T.states = { bumped = stateObject("BumpedState"), walk = stateObject("WalkTowardNetworkState") }
ZIDX.getCurrentState = function(self) return self.cur or T.states.walk end
HashMap = { new = function()
    local m = { data = {} }
    function m:put(k, v) self.data[k] = v end
    return m
end }
T.order = {}

function T.zombie(id, opts)
    local z = { kind = "IsoZombie", id = id, x = 10.5, y = 20.5, z = 0, remote = false, calls = {}, state = "walktoward",
                timer = 50 }
    for k, v in pairs(opts or {}) do z[k] = v end
    setmetatable(z, ZMT)
    T.zombies[#T.zombies + 1] = z
    return z
end

PIDX.getOnlineID = function(self) return self.id end
PIDX.getX = function(self) return self.x end
PIDX.getY = function(self) return self.y end
PIDX.isLocalPlayer = function(self) return self.isLocal == true end
PIDX.isSprinting = function(self) return self.sprinting == true end
PIDX.isRunning = function(self) return self.running == true end
PIDX.isSneaking = function(self) return self.sneaking == true end
PIDX.isBehind = function(self, z) return self.behind == true end
PIDX.getPerkLevel = function(self, perk) return self.perks[perk.name] or 0 end

function T.player(id, opts)
    local p = { kind = "IsoPlayer", id = id, x = 10, y = 20, perks = { Strength = 5 } }
    for k, v in pairs(opts or {}) do p[k] = v end
    setmetatable(p, PMT)
    T.players[#T.players + 1] = p
    return p
end

function instanceof(o, name)
    return type(o) == "table" and o.kind == name
end

-- cell: squares hold the zombies standing on them
local cell = {}
function cell:getGridSquare(x, y, z)
    local sq = { items = {} }
    for _, zz in ipairs(T.zombies) do
        if math.floor(zz.x) == x and math.floor(zz.y) == y and math.floor(zz.z) == z then sq.items[#sq.items + 1] = zz end
    end
    function sq:getMovingObjects() return list(self.items) end
    return sq
end
function cell:getZombieList() return list(T.zombies) end
function getCell() return cell end

function getPlayer() return T.localPlayer end
function getOnlinePlayers() return list(T.players) end
function getPlayerByOnlineID(id)
    for _, p in ipairs(T.players) do if p.id == id then return p end end
    return nil
end
function sendClientCommand(p, module, command, args)
    if T.side == "server" then error("sendClientCommand on the server") end
    T.sentClient[#T.sentClient + 1] = { p = p, module = module, command = command, args = args }
end
function sendServerCommand(p, module, command, args)
    if T.side ~= "server" then error("sendServerCommand off the server") end
    T.sentServer[#T.sentServer + 1] = { p = p, module = module, command = command, args = args }
end

function getFilenameOfClosure(fn)
    return T.fileOf[fn] or "C:/Users/x/Zomboid/mods/Other/42/media/lua/shared/Other.lua"
end

-- Events: Add/Remove keep a handler list; T.fire runs the handlers like the game (errors are caught)
Events = {}
for _, name in ipairs({ "OnZombieUpdate", "OnCharacterCollide", "OnClientCommand", "OnServerCommand", "OnTick",
                        "OnGameStart", "OnServerStarted" }) do
    local ev = { handlers = {} }
    ev.Add = function(fn) ev.handlers[#ev.handlers + 1] = fn end
    ev.Remove = function(fn)
        for i = #ev.handlers, 1, -1 do if ev.handlers[i] == fn then table.remove(ev.handlers, i) end end
    end
    Events[name] = ev
end
function T.fire(name, a, b, c, d)
    for _, fn in ipairs(Events[name].handlers) do
        local ok, err = pcall(fn, a, b, c, d)
        if not ok then T.errors[#T.errors + 1] = tostring(err) end
    end
end

function T.check(cond, what)
    if cond then
        T.passes = T.passes + 1
    else
        T.fails = T.fails + 1
        realPrint("FAIL: " .. what)
    end
end

function T.reset()
    T.sentClient, T.sentServer, T.errors = {}, {}, {}
    for _, z in ipairs(T.zombies) do z.calls = {} end
end

function T.setSide(s)
    T.side = s
    T.fire("OnGameStart")   -- the add-on decides its side again
end
