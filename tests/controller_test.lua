-- Run from the mod directory with:
-- tools/lua/node_modules/.bin/fengari.cmd tests/controller_test.lua
local controller = dofile("content/ai/controller.lua")
local policy = dofile("content/ai/policy.lua")

local function equal(actual, expected, message)
	assert(actual == expected, string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
end

local function harness(options)
	options = options or {}
	local now = options.now or 0
	local human = "human"
	local rival = "rival"
	local humanBalance = options.humanBalance
	if humanBalance == nil then humanBalance = 20000 end
	local balances = { [human] = humanBalance, [rival] = options.rivalBalance or 0 }
	local store = { value = options.state }
	function store:get() return self.value end
	function store:set(value) self.value = value end

	local counts = { newPlayer = 0, fund = 0, build = 0, scan = 0, manage = 0, readiness = 0 }
	local proofAvailable = false
	local route = {
		key = "route-key",
		name = "Linha Centro",
		line = "line-1",
		depot = "depot-1",
		createdAt = now,
		vehicles = 1,
		ageMonths = 0,
	}
	local native = {
		now = function() return now end,
		monthDuration = function() return 30 end,
		getPlayer = function() return human end,
		balance = function(player) return balances[player] end,
		startingCapital = function() return options.startingCapital or 10000000 end,
		newPlayer = function(_name, _color, callback)
			counts.newPlayer = counts.newPlayer + 1
			callback(rival)
		end,
		fundToBalance = function(player, amount, callback)
			counts.fund = counts.fund + 1
			balances[player] = amount
			if options.changeHumanDuringFund then balances[human] = balances[human] - 1 end
			callback(true, nil, balances[player])
		end,
		snapshot = function(player)
			if options.missingSnapshot then return nil end
			return { balance = balances[player], annualRunningCost = 120 }
		end,
		bestBus = function()
			return { modelId = "bus-1", purchaseCost = 100, runningCost = 120 }
		end,
		routeStats = function(_player, _route, _from, _to)
			return {
				valid = true,
				vehicles = { "vehicle-1" },
				occupancy = 0.9,
				profit = 0,
				income = proofAvailable and 100 or 0,
				expenses = proofAvailable and 50 or 0,
			}
		end,
		operatingProfit = function() return 0 end,
		setNow = function(value) now = value end,
		setProof = function(value) proofAvailable = value end,
		getBalance = function(player) return balances[player] end,
		counts = counts,
		store = store,
	}
	local routes = {
		readiness = function()
			counts.readiness = counts.readiness + 1
			if options.readiness ~= nil then return options.readiness end
			return { automaticPlacement = true }
		end,
		scan = function(_player, _options)
			counts.scan = counts.scan + 1
			if options.scanPlan and counts.scan == 1 then
				return { key = "candidate-1", name = "Linha Centro", buildCost = options.buildCost or 1000 }
			end
			return nil, "scan encerrado", nil, true
		end,
		stepBuild = function(_player, operation, callback)
			counts.build = counts.build + 1
			callback(true, nil, route)
		end,
		stepManage = function(_player, _management, callback)
			counts.manage = counts.manage + 1
			callback(true, nil)
		end,
	}
	return {
		controller = controller.create(native, routes, policy),
		native = native,
		routes = routes,
		store = store,
		counts = counts,
		human = human,
		rival = rival,
		getBalance = native.getBalance,
		setNow = native.setNow,
		setProof = native.setProof,
	}
end

local function initialize(h)
	h.controller.handleEvent(nil, h.store, nil, "", "initNewGame")
	return h.store:get()
end

local function update(h)
	h.controller.update(nil, h.store, 1)
	return h.store:get()
end

-- A zero-balance player still gets a separately funded rival account.
do
	local h = harness({ humanBalance = 0 })
	local state = initialize(h)
	equal(state.phase, "create_player", "new game begins with rival creation")
	local humanBefore = h.getBalance(h.human)
	equal(state.initialCapital, 10000000, "rival uses configured starting capital")
	update(h)
	equal(h.store:get().phase, "fund", "player creation advances to funding")
	equal(h.counts.newPlayer, 1, "creates one rival company")
	update(h)
	state = h.store:get()
	equal(state.phase, "plan", "funding advances to planning")
	equal(state.capitalized, true, "rival account capitalized")
	equal(h.counts.fund, 1, "funds rival once")
	equal(h.getBalance(h.rival), 10000000, "rival receives starting capital")
	equal(h.getBalance(h.human), humanBefore, "human balance is unchanged")
	h.controller.handleEvent(nil, h.store, nil, "", "initNewGame")
	equal(h.counts.fund, 1, "duplicate init does not fund again")
	update(h)
	equal(h.counts.fund, 1, "later updates do not fund again")
end

-- A failed placement preflight persists its reason and blocks before company
-- creation or funding.
do
	local h = harness({
		readiness = { automaticPlacement = false, reason = "O posicionamento automático não passou na validação" },
	})
	initialize(h)
	local state = update(h)
	equal(h.counts.readiness, 1, "readiness preflight runs before rival creation")
	equal(state.phase, "blocked", "failed readiness preflight blocks controller")
	equal(state.lastDecision, "O posicionamento automático não passou na validação", "preflight reason is persisted")
	equal(h.counts.newPlayer, 0, "failed preflight does not create a company")
	equal(h.counts.fund, 0, "failed preflight does not fund a company")
end

-- A funding side effect on the human account blocks the controller.
do
	local h = harness({ changeHumanDuringFund = true })
	initialize(h)
	update(h)
	local state = update(h)
	equal(state.phase, "blocked", "human balance mutation blocks integration")
	assert(state.lastDecision:find("conta humana", 1, true), "block reason should identify human account mutation")
	update(h)
	equal(h.counts.fund, 1, "blocked controller does not retry funding")
end

-- Closing the final route removes it from the owned registry and blacklists
-- its candidate key for three months so the planner cannot immediately rebuild it.
do
	local closedRoute = {
		key = "closed-candidate",
		line = "line-to-close",
		depot = "depot-1",
		createdAt = 0,
	}
	local h = harness({
		now = 45,
		state = {
			version = 1,
			phase = "manage",
			player = "rival",
			capitalized = true,
		routes = { closedRoute },
			blockedCandidates = {},
			history = {},
			management = { action = "close", line = "line-to-close", depot = "depot-1", modelId = "bus-1" },
			managementAction = "close",
			managementLine = "line-to-close",
		},
	})
	local state = update(h)
	equal(h.counts.manage, 1, "close operation is applied")
	equal(#state.routes, 0, "closed route is removed from registry")
	equal(state.blockedCandidates["closed-candidate"], 135, "closed candidate remains blocked for three months")
	equal(state.managementAction, nil, "completed close marker is cleared")
	equal(state.phase, "operate", "controller returns to operation after close")
end

-- An existing save without initialized rival state remains untouched.
do
	local original = {}
	local h = harness({ state = original })
	update(h)
	equal(h.store:get(), original, "empty existing save is not initialized")
	equal(h.counts.newPlayer, 0, "existing save does not create a company")
	equal(h.counts.fund, 0, "existing save is not funded")
end

-- Inactive/pause state and interrupted command markers cannot trigger commands.
do
	local paused = harness({ state = { version = 1, phase = "inactive" } })
	update(paused)
	equal(paused.counts.newPlayer, 0, "inactive controller issues no commands")
	local interrupted = harness({ state = {
		version = 1, phase = "fund", player = "rival", initialCapital = 20000, pending = "fund",
	} })
	local state = update(interrupted)
	equal(state.phase, "blocked", "interrupted pending command blocks")
	equal(interrupted.counts.fund, 0, "interrupted funding is never replayed")
end

-- A candidate above the reserve-adjusted expansion budget is rejected.
do
	local h = harness({
		now = 10,
		scanPlan = true,
		buildCost = 8000,
		state = {
			version = 1, phase = "plan", player = "rival", balance = 10000,
			monthlyCost = 0, capitalized = true, routes = {}, blockedCandidates = {}, history = {},
		},
	})
	local state = update(h)
	equal(h.counts.scan, 1, "planner inspects a candidate")
	equal(state.phase, "plan", "over-budget plan remains unbuilt")
	equal(h.counts.build, 0, "over-budget plan never invokes build")
	equal(state.nextScanAt, 40, "rejected plan waits before retrying")
end

-- A route can be built, but expansion stays locked until both real receipts
-- and expenses are observed from that owned route.
do
	local h = harness({ now = 0, scanPlan = true, buildCost = 1000 })
	initialize(h)
	update(h) -- create rival
	update(h) -- capitalize rival
	local state = update(h) -- scan and accept first plan
	equal(state.phase, "build", "affordable plan starts staged build")
	state = update(h) -- successful final build callback
	equal(state.phase, "operate", "successful build moves controller to operate")
	equal(#state.routes, 1, "built route is registered")
	equal(state.compatibilityVerified, false, "new route starts unverified")
	for month = 1, 4 do
		h.setNow(month * 30)
		state = update(h)
		equal(state.compatibilityVerified, false, "route remains unverified without receipts/expenses")
		equal(h.counts.scan, 1, "no expansion scan before financial proof")
	end
	h.setProof(true)
	h.setNow(150)
	state = update(h)
	equal(state.compatibilityVerified, true, "positive income and expense verify native integration")
	equal(h.counts.scan, 2, "planning can resume after financial proof")
end

-- A missing runtime account blocks safely before planning or purchase calls.
do
	local h = harness({
		missingSnapshot = true,
		state = {
			version = 1, phase = "operate", player = "rival", capitalized = true,
			routes = {}, blockedCandidates = {}, history = {},
		},
	})
	local state = update(h)
	equal(state.phase, "blocked", "missing rival account blocks controller")
	equal(h.counts.scan, 0, "missing account prevents route planning")
	equal(h.counts.build, 0, "missing account prevents purchases")
end

print("controller tests passed")
