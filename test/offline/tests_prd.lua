-- Regression tests when Proper Ragdolls is active (workshop-prefixed mod id).
local check = T.check
local M = TZMPFix

check(M.methodHooks == 12, "12 method hooks with workshop-prefixed ProperRagdolls, got " .. tostring(M.methodHooks))

T.localPlayer = T.player(1, { isLocal = true, x = 10, y = 20 })
T.setSide("client")
local z1 = T.zombie(601, { remote = false, x = 15.5 })
local z2 = T.zombie(602, { remote = true, x = 16.5 })

FAKE.tripOn[601] = true
FAKE.prdVars = true
T.reset()
T.fire("OnZombieUpdate", z1)
check(#T.sentClient == 1, "ProperRagdolls trip sent")
local o = #T.sentClient == 1 and T.sentClient[1].args.z[1].o or {}
local svCount = 0
for _, op in ipairs(o) do
    if op[1] == "sv" then svCount = svCount + 1 end
end
check(svCount == 4, "all 4 prd* setVariable calls recorded, got " .. tostring(svCount))

-- non-prd setVariable calls are NOT recorded
T.reset()
FAKE.tripOn[601] = nil
z1:setVariable("otherVar", "x")
check(#T.sentClient == 0, "non-prd setVariable not recorded")

-- applying sv ops on copy sets prd* variables, and ignores sv with nil value
T.reset()
T.fire("OnServerCommand", "TZMPFix", "ops", { s = 2, z = { { i = 602, x = 16, y = 20, z = 0,
    o = { { "sv", { "prdWall", "front_near" } }, { "sv", { "prdRun", "false" } }, { "sv", { "prdBad", nil } } } } } })
check(z2.vars and z2.vars.prdWall == "front_near" and z2.vars.prdRun == "false" and z2.vars.prdBad == nil,
    "copy receives prd* setVariable ops and ignores nil value")

T.realPrint("offline prd tests: " .. T.passes .. " passed, " .. T.fails .. " failed")
if T.fails > 0 then error("offline prd tests failed") end
