-- Focused test: enabling the mod on an EXISTING save (no initNewGame event ever
-- arrives) must still bootstrap the rival, and must do it only once.
-- Run from the mod directory with:
-- tools/lua/node_modules/.bin/fengari.cmd tests/update_init_test.lua
local controller = dofile("content/ai/controller.lua")
local policy = dofile("content/ai/policy.lua")

local function equal(actual, expected, message)
	assert(actual == expected, string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
end

local balances = { human = 50000, rival = 0 }
local counts = { newPlayer = 0, fund = 0, subscribe = 0 }

local store = { value = nil } -- existing save: no state written by this mod yet
function store:get() return self.value end
function store:set(value) self.value = value end
function store:subscribeToEvent() counts.subscribe = counts.subscribe + 1 end

local native = {
	now = function() return 0 end,
	monthDuration = function() return 30 end,
	getPlayer = function() return "human" end,
	balance = function(player) return balances[player] end,
	playersNamed = function() return counts.newPlayer > 0 and { "rival" } or {} end,
	startingCapital = function() return 10000000 end,
	newPlayer = function()
		counts.newPlayer = counts.newPlayer + 1
		return true
	end,
	fundToBalance = function(player, amount)
		counts.fund = counts.fund + 1
		balances[player] = amount
		return true, nil, balances[player]
	end,
	snapshot = function(player) return { balance = balances[player], annualRunningCost = 120 } end,
	bestBus = function() return { modelId = "bus-1", purchaseCost = 100, runningCost = 120 } end,
	routeStats = function() return { valid = true, vehicles = {}, occupancy = 0, profit = 0 } end,
	operatingProfit = function() return 0 end,
}

local routes = {
	readiness = function() return { automaticPlacement = true } end,
	scan = function() return nil, "scan encerrado", nil, true end,
}

local instance = controller.create(native, routes, policy)

-- 1. First tick on an existing save: update alone must initialize the rival.
instance.update(nil, store, 1)
local state = store:get()
equal(type(state), "table", "update bootstraps state without initNewGame")
equal(state.version, 2, "bootstrapped state is versioned")
equal(counts.newPlayer, 1, "rival company created on an existing save")
equal(state.phase, "create_player", "creation awaits confirmation from world state")
equal(state.pending, "create_player", "creation marker is durable")
equal(state.initialCapital, 10000000, "capital taken from the same path as initNewGame")
equal(counts.subscribe, 2, "preview events subscribed once")

-- 2. Funding completes on the next tick, exactly once.
instance.update(nil, store, 1)
equal(counts.fund, 1, "rival is funded once")
equal(balances.rival, 10000000, "rival account receives the configured capital")
equal(store:get().phase, "plan", "funded rival starts planning routes")

-- 3. Idempotency: further ticks must not re-initialize, re-create or re-fund.
instance.update(nil, store, 1)
instance.update(nil, store, 1)
local again = store:get()
equal(again.initializedAt, state.initializedAt, "state is not re-initialized")
equal(counts.newPlayer, 1, "no duplicate rival company")
equal(counts.fund, 1, "no duplicate funding")
equal(counts.subscribe, 2, "no duplicate event subscription")
equal(balances.human, 50000, "human balance is never touched")

print("update_init_test: OK")
