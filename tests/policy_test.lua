-- Run from the mod directory with: lua tests/policy_test.lua
local policy = dofile("content/ai/policy.lua")

local function equal(actual, expected, label)
    assert(actual == expected, string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)))
end

local function near(actual, expected, label)
    assert(type(actual) == "number" and math.abs(actual - expected) < 1e-12,
        string.format("%s: expected %.12g, got %s", label, expected, tostring(actual)))
end

equal(policy.MAX_ROUTES, 8, "route cap")
equal(policy.reserve(100), 300, "reserve")
equal(policy.reserve(-10), 0, "negative monthly cost reserve")
equal(policy.reserve(math.huge), nil, "infinite reserve input")

equal(policy.canSpend(1000, 100, 700, false), true, "spend at reserve boundary")
equal(policy.canSpend(1000, 100, 701, false), false, "spend past reserve boundary")
equal(policy.canSpend(1000, 100, 280, true), true, "expansion at 40 percent boundary")
equal(policy.canSpend(1000, 100, 281, true), false, "expansion past 40 percent boundary")
equal(policy.canSpend(1000, 100, 0, true), true, "zero cost expansion")
equal(policy.canSpend(-1, 0, 0, false), false, "negative balance")
equal(policy.canSpend(1000, 0, math.huge, false), false, "infinite spend")
equal(policy.canSpend(1000, 0, 0, "yes"), false, "invalid expansion flag")
equal(policy.canSpend(1000, math.nan, 0, false), false, "NaN monthly cost")

equal(policy.chooseVehicle({
    { id = "slow", purchaseCost = 100, runningCost = 200, speed = 50 },
    { id = "fast", purchaseCost = 250, runningCost = 10, speed = 60 },
    { id = "cheap", purchaseCost = 100, runningCost = 190, speed = 40 },
}), "fast", "12 month total cost")
equal(policy.chooseVehicle({
    { id = "b", purchaseCost = 100, runningCost = 10, speed = 60 },
    { id = "a", purchaseCost = 100, runningCost = 10, speed = 60 },
}), "a", "vehicle ID tie break")
equal(policy.chooseVehicle({ { id = "bad", purchaseCost = -1, runningCost = 1, speed = 1 } }), nil,
    "invalid vehicle ignored")

near(policy.scoreRoute(100, 400, 30, 0, 0), 200 / 60, "minimum travel-time floor")
near(policy.scoreRoute(100, 400, 120, 1000000, 4), (200 / 120) / 4, "route score formula")
equal(policy.scoreRoute(1, 1, math.huge, 0, 0), nil, "invalid route score input")

local action, reason = policy.evaluateRoute({
    ageMonths = 3, vehicleCount = 2, highMonths = 3, lowLossMonths = 0, lossMonths = 0, profit = 1,
}, { balance = 1000, monthlyCost = 100, purchaseCost = 280 })
equal(action, "buy", "buy decision")
equal(reason, "sustained_high_profit", "buy reason")

action = policy.evaluateRoute({
    ageMonths = 3, vehicleCount = 2, highMonths = 3, lowLossMonths = 0, lossMonths = 0, profit = 1,
}, { balance = 1000, monthlyCost = 100, purchaseCost = 281 })
equal(action, "hold", "unaffordable expansion")

action = policy.evaluateRoute({
    ageMonths = 3, vehicleCount = 2, highMonths = 3, lowLossMonths = 0, lossMonths = 1, profit = 10,
}, { balance = 1000, monthlyCost = 0, purchaseCost = 1 })
equal(action, "hold", "route with losses does not expand")

action = policy.evaluateRoute({
    ageMonths = 3, vehicleCount = 3, highMonths = 0, lowLossMonths = 3, lossMonths = 2, profit = -1,
}, { balance = 0, monthlyCost = 0, purchaseCost = 0 })
equal(action, "sell", "sell decision")

action = policy.evaluateRoute({
    ageMonths = 6, vehicleCount = 1, highMonths = 3, lowLossMonths = 0, lossMonths = 6, profit = -1,
}, { balance = 1000, monthlyCost = 0, purchaseCost = 0 })
equal(action, "close", "close decision precedence")

action = policy.evaluateRoute({
    ageMonths = 6, vehicleCount = 1, highMonths = 0, lowLossMonths = 0, lossMonths = 5, profit = -1,
}, { balance = 0, monthlyCost = 0, purchaseCost = 0 })
equal(action, "hold", "close below loss threshold")

action, reason = policy.evaluateRoute({}, {})
equal(action, "hold", "invalid route safely holds")
equal(reason, "invalid_input", "invalid route reason")

print("policy tests passed")
