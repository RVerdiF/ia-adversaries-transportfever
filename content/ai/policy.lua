-- Pure decision helpers for the competitor AI. This module intentionally has
-- no game API or loader dependencies so it can also be exercised in isolation.
local policy = {
    MAX_ROUTES = 8,
}

local function finiteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function nonNegative(value)
    return finiteNumber(value) and value >= 0
end

function policy.reserve(monthlyCost)
    if not finiteNumber(monthlyCost) then
        return nil
    end
    return 3 * math.max(0, monthlyCost)
end

function policy.canSpend(balance, monthlyCost, amount, expansion)
    if not nonNegative(balance) or not finiteNumber(monthlyCost)
        or not nonNegative(amount) or type(expansion) ~= "boolean" then
        return false
    end

    local reserve = policy.reserve(monthlyCost)
    local available = balance - reserve
    return available >= amount
        and (not expansion or amount <= 0.4 * available)
end

local function idLess(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then
        return ta < tb
    end
    return a < b
end

function policy.chooseVehicle(candidates)
    if type(candidates) ~= "table" then
        return nil
    end

    local best
    local bestTotal
    for _, candidate in ipairs(candidates) do
        if type(candidate) == "table"
            and (type(candidate.id) == "string" or (finiteNumber(candidate.id) and candidate.id == candidate.id))
            and nonNegative(candidate.purchaseCost)
            and nonNegative(candidate.runningCost)
            and nonNegative(candidate.speed) then
            -- runningCost is already the annual total; purchase plus annual
            -- running cost is the requested twelve-month comparison.
            local total = candidate.purchaseCost + candidate.runningCost
            if finiteNumber(total) and (best == nil
                or total < bestTotal
                or (total == bestTotal and candidate.speed > best.speed)
                or (total == bestTotal and candidate.speed == best.speed and idLess(candidate.id, best.id))) then
                best = candidate
                bestTotal = total
            end
        end
    end
    return best and best.id or nil
end

function policy.scoreRoute(popA, popB, travelSeconds, buildCost, coverage)
    if not nonNegative(popA) or not nonNegative(popB)
        or not nonNegative(travelSeconds) or not nonNegative(buildCost)
        or not nonNegative(coverage) then
        return nil
    end
    return math.sqrt(popA * popB) / math.max(60, travelSeconds)
        / (1 + buildCost / 1000000)
        / (1 + 0.25 * coverage)
end

local function decision(action, reason)
    return action, reason
end

function policy.evaluateRoute(route, budget)
    if type(route) ~= "table" or type(budget) ~= "table"
        or not nonNegative(route.ageMonths)
        or not nonNegative(route.vehicleCount)
        or not nonNegative(route.highMonths)
        or not nonNegative(route.lowLossMonths)
        or not nonNegative(route.lossMonths)
        or not finiteNumber(route.profit)
        or not nonNegative(budget.balance)
        or not finiteNumber(budget.monthlyCost)
        or not nonNegative(budget.purchaseCost) then
        return decision("hold", "invalid_input")
    end

    -- Close long-running single-vehicle routes first. This takes precedence
    -- over adding vehicles to an unprofitable route.
    if route.ageMonths >= 6 and route.vehicleCount == 1 and route.lossMonths >= 6 then
        return decision("close", "persistent_loss")
    end
    if route.lowLossMonths >= 3 and route.vehicleCount > 1 then
        return decision("sell", "sustained_low_loss")
    end
    if route.highMonths >= 3 and route.vehicleCount < 6
        and route.profit > 0 and route.lossMonths == 0
        and policy.canSpend(budget.balance, budget.monthlyCost, budget.purchaseCost, true) then
        return decision("buy", "sustained_high_profit")
    end
    return decision("hold", "no_action_threshold_met")
end

return policy
