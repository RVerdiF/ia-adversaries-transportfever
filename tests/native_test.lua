-- Run from the mod directory with tools/lua/node_modules/.bin/fengari tests/native_test.lua
-- These mocks test adapter behavior and API argument shapes, not the game engine.
local function eq(actual, expected, label)
	assert(actual == expected, string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)))
end
local function near(actual, expected, label)
	assert(type(actual) == "number" and math.abs(actual - expected) < 1e-12,
		string.format("%s: expected %.12g, got %s", label, expected, tostring(actual)))
end

local players, accounts = { [1] = true, [2] = true }, { [1] = 700, [2] = 300 }
local playerNames = { [1] = "Player", [2] = "Rival" }
local owners, journalCommands = { [41] = 2, [42] = 2, [43] = 1 }, {}
local maintenanceCosts = { [41] = 1200, [61] = 60 }
local sendSuccess, nextPlayer, lastColor = true, 3, nil
local routeVehicles, failRouteFinance = { 41 }, false
local C = { PLAYER = "PLAYER", GAME_TIME = "GAME_TIME", TRANSPORT_VEHICLE = "TRANSPORT_VEHICLE",
	LINE = "LINE", PLAYER_OWNED = "PLAYER_OWNED", STATION_GROUP = "STATION_GROUP",
	MAINTENANCE_COST = "MAINTENANCE_COST" }
local function model(id, carrier, modes, yearFrom, yearTo)
	return { metadata = {
		transportVehicle = { carrier = carrier, transportModes = modes, compartments = { {}, {} } },
		availability = { yearFrom = yearFrom, yearTo = yearTo }, cost = { price = 1000 + id },
		maintenance = { runningCosts = 100 + id }, landVehicle = { topSpeed = 20 + id },
	} }
end
local models = {
	[10] = model(10, "ROAD", { "BUS" }, 1900, -1),
	[11] = model(11, "ROAD", { "TRUCK" }, 1900, -1),
	[12] = model(12, "ROAD", { "BUS" }, 2020, 2025),
	[13] = model(13, "RAIL", {}, 1900, -1),
}
local cons = {
	free = { metadata = {} },
	needs_rank = { metadata = { ["company.meta"] = { companyRank = 3 } } },
	needs_permit = { metadata = { ["company.meta"] = { permitKey = "::permit" } } },
	initial_rank = { metadata = { ["company.meta"] = { companyRank = 0, permitKey = "", rankAndPermits = {} } } },
	first_rank = { metadata = { ["company.meta"] = { companyRank = 1 } } },
}
local consById = { [1] = cons.free, [2] = cons.needs_rank, [3] = cons.needs_permit, [4] = cons.initial_rank, [5] = cons.first_rank }
local capacityCalls = 0

api = {
	type = {
		ComponentType = C,
		["enum"] = { Carrier = { ROAD = "ROAD", RAIL = "RAIL" }, TransportMode = { BUS = "BUS", TRUCK = "TRUCK" } },
		Vec3f = { new = function(x, y, z) return { x = x, y = y, z = z } end },
		JournalEntry = {
			Type = { INCOME = "INCOME", OTHER = "OTHER" },
			Maintenance = { VEHICLE = "VEHICLE", INFRASTRUCTURE = "INFRASTRUCTURE", OTHER = "OTHER_MAINT",
				VEHICLE_MAINTENANCE = "VEHICLE_MAINTENANCE" },
			new = function() return { category = {} } end,
		},
		TransportVehiclePart = { new = function() return { part = { color = { x = -1, y = -1, z = -1 } } } end },
		LoadConfig = { new = function() return {} end },
		TransportVehicleConfig = { new = function() return {} end },
	},
	util = { getDefaultMonthDuration = function() return 2400 end },
	res = {
		modelRep = {
			getAll = function() return { [10] = "bus", [11] = "truck", [12] = "expired_bus", [13] = "train" } end,
			get = function(id) return models[id] end,
			getName = function(id) return ({ [10] = "bus", [11] = "truck", [12] = "expired_bus", [13] = "train" })[id] end,
		},
		constructionRep = { find = function(name) return ({ free = 1, needs_rank = 2, needs_permit = 3, initial_rank = 4, first_rank = 5 })[name] or -1 end,
			get = function(id) return consById[id] end },
	},
	cmd = {
		makeGameAddPlayerCmd = function(name, color) lastColor = color; return { kind = "add", name = name, color = color } end,
		makeJournalBookAssetCmd = function(playerEntity, entry, position)
			return { kind = "journal", playerEntity = playerEntity, entry = entry, position = position }
		end,
		sendCommand = function(command, callback)
			assert(callback == nil, "engine-state commands must not use callbacks")
			if not sendSuccess then error("command rejected") end
			if command.kind == "add" then
				local entity = nextPlayer; nextPlayer = nextPlayer + 1
				players[entity], accounts[entity], playerNames[entity] = true, 0, command.name
			elseif command.kind == "journal" then
				journalCommands[#journalCommands + 1] = command
				accounts[command.playerEntity] = accounts[command.playerEntity] + command.entry.amount
			end
		end,
	},
	engine = {
		util = {
			getPlayer = function() return 1 end, getWorld = function() return 99 end,
			getYear = function() return 2010 end,
			getEntityName = function(entity) return playerNames[entity] or "Player" end,
			finance = {
				getPlayersBalance = function(entity) return accounts[entity] end,
				calculateBalance = function(entities, startTime, endTime, maintenanceIncomeOnly, maintenanceType)
					assert(#entities > 0, "finance entity list must not be empty")
					eq(maintenanceIncomeOnly, true, "maintenance and income filter")
					if entities[1] == 2 then
						eq(#entities, 1, "company finance entity count")
						if maintenanceType == "VEHICLE" then return -100 end
						if maintenanceType == "INFRASTRUCTURE" then return -50 end
						if maintenanceType ~= nil then return 0 end
						return startTime == 10 and endTime == 20 and 250 or 0
					end
					if entities[1] == 41 then
						eq(#entities, 1, "line finance uses exactly the vanilla line vehicle list")
						if failRouteFinance then error("mock line ledger failure") end
						if maintenanceType == "VEHICLE" then return -50 end
						if maintenanceType ~= nil then return 0 end
						return 200
					end
					return 0
				end,
			},
			vehicle = { getRunningCost = function(entity) return entity == 41 and 1200 or 300 end },
			line = {
				getLineCapacityUsages = function(route, all)
					capacityCalls = capacityCalls + 1; eq(route, 50, "capacity route"); eq(all, true, "all capacity")
					return { [1] = { used = 25, capacity = 100 }, [2] = { used = 0, capacity = 0 } }
				end,
				getDetailedLineProblems = function() return { { { noPath = false, noPathToAlternative = { [1] = {} } } } } end,
			},
			maintenance = { calcMaintenanceForStationGroup = function(entity)
				eq(entity, 60, "station-group maintenance entity"); return 30
			end },
		},
		system = { transportVehicleSystem = { getLineVehicles = function(route)
			eq(route, 50, "line vehicles route"); return routeVehicles
		end } },
		entityExists = function(entity) return players[entity] == true or owners[entity] ~= nil
			or entity == 99 or entity == 60 or entity == 61 end,
		getComponent = function(entity, type)
			if entity == 99 and type == C.GAME_TIME then return { gameTime = 500 } end
			if players[entity] and type == C.PLAYER then return {} end
			if entity == 50 and type == C.LINE then return {} end
			if entity == 50 and type == C.PLAYER_OWNED then return { player = 2 } end
			if owners[entity] and type == C.PLAYER_OWNED then return { player = owners[entity] } end
			if (entity == 60 or entity == 61) and type == C.PLAYER_OWNED then return { player = 2 } end
			if maintenanceCosts[entity] and type == C.MAINTENANCE_COST then
				return { maintenanceCost = maintenanceCosts[entity] }
			end
			if entity == 60 and type == C.STATION_GROUP then return {} end
			if entity == 61 and type == C.MAINTENANCE_COST then return { maintenanceCost = 60 } end
			return nil
		end,
		getEntitiesWithComponent = function(componentType, filters)
			local result = {}
			if componentType == C.PLAYER then
				error("Cannot loop over this component type")
			elseif componentType == C.TRANSPORT_VEHICLE or componentType == C.LINE then
				for entity, owner in pairs(owners) do
					if owner == filters.requireOwnedByPlayer then result[#result + 1] = entity end
				end
			elseif componentType == C.MAINTENANCE_COST then
				for entity in pairs(maintenanceCosts) do if entity ~= 41 and filters.requireOwnedByPlayer == 2 then result[#result + 1] = entity end end
			end
			table.sort(result); return result
		end,
		forEachEntity = function(callback)
			for _, entity in ipairs({ 1, 2, 3, 41, 42, 43, 60, 61, 99 }) do
				if players[entity] or entity ~= 3 then callback(entity) end
			end
		end,
	},
}

ug_require = function(path)
	if path == "/game_mechanics/company/company_metadata.tl" then return { getKey = function() return "company.meta" end } end
	if path == "/game_mechanics/company/company_progression_util.tl" then
		return { getCompanyProgressionState = function(entity) return entity == 2 and { level = 4 } or nil end }
	end
	error("unexpected ug_require path: " .. tostring(path))
end

local native = dofile("content/ai/native.lua")
api.engine.config = { getModParams = function()
	return { pichau_competitor_ai = { startingCapital = 3 } }
end }
eq(native.startingCapital(), 20000000, "selected capital index maps to amount")
eq(native.getPlayer(), 1, "local player")
eq(native.balance(2), 300, "player balance")
eq(native.now(), 500, "game time")
eq(native.monthDuration(), 2400, "month duration")

local created, createError = native.newPlayer("New Rival", { 1, 0, 0 })
eq(created, true, "created player command"); eq(createError, nil, "create player error")
eq(native.playersNamed("New Rival")[1], 3, "created player observed by name")
eq(lastColor.x, 1, "player color x component"); eq(lastColor.z, 0, "player color z component")

local funded, fundingError, fundedBalance = native.fundToBalance(2, 1000)
eq(funded, true, "fund command succeeds"); eq(fundingError, nil, "fund error")
eq(fundedBalance, 1000, "confirmed balance"); eq(accounts[2], 1000, "target balance reached")
eq(journalCommands[1].playerEntity, 2, "journal targets rival")
eq(journalCommands[1].entry.amount, 700, "journal uses balance delta")
eq(journalCommands[1].entry.category.type, "INCOME", "positive entry category")
local count = #journalCommands
funded = native.fundToBalance(2, 1000)
eq(funded, true, "repeat funding succeeds without change"); eq(#journalCommands, count, "repeat does not journal")
funded = native.fundToBalance(2, 400)
eq(funded, true, "exact target reduction"); eq(accounts[2], 400, "reduced target reached")
eq(journalCommands[#journalCommands].entry.amount, -600, "negative delta")
eq(journalCommands[#journalCommands].entry.category.type, "OTHER", "negative entry category")

funded, fundingError = native.fundToBalance(1, 900)
eq(funded, false, "human account mutation refused"); eq(fundingError, "refusing_local_player_funding", "human refusal reason")
eq(#journalCommands, count + 1, "human account not journaled")
funded, fundingError = native.fundToBalance(2, math.huge)
eq(funded, false, "infinite target refused"); eq(fundingError, "invalid_funding_arguments", "infinite target reason")
funded, fundingError = native.fundToBalance(2, 1.5)
eq(funded, false, "fractional target refused")
sendSuccess = false
funded, fundingError = native.fundToBalance(2, 500)
eq(funded, false, "journal failure reported")
assert(fundingError:find("journal_command_failed:", 1, true) == 1, "journal failure reason")
eq(accounts[2], 400, "failed command does not mutate balance"); sendSuccess = true

eq(#native.ownedVehicles(2), 2, "owned vehicle filter")
eq(#native.ownedLines(2), 2, "owned line filter")
local snapshot = native.snapshot(2)
eq(snapshot.name, "Rival", "snapshot name"); eq(snapshot.balance, 400, "snapshot balance")
eq(snapshot.annualRunningCost, 1500, "snapshot running cost"); eq(native.snapshot(99), nil, "snapshot rejects world entity")
eq(snapshot.annualInfrastructureCost, 60, "snapshot excludes vehicle component maintenance to avoid double count")
near(snapshot.monthlyCost, (1500 + 60) / 12, "snapshot monthly operating cost")

local candidates = native.vehicleCandidates("ROAD")
eq(#candidates, 1, "bus candidates exclude truck and unavailable vehicle")
eq(candidates[1].modelId, 10, "bus model selected"); eq(candidates[1].id, "bus", "vehicle resource name")
eq(candidates[1].purchaseCost, 1010, "model cost metadata")
eq(candidates[1].runningCost, 110, "maintenance metadata")
eq(candidates[1].speed, 30, "speed metadata")
local config = candidates[1].config
eq(config.vehicleGroups[1], 1, "single-part vehicle group"); eq(#config.muFileNames, 0, "not a multiple unit")
eq(config.vehicles[1].part.modelId, 10, "config model id")
eq(config.vehicles[1].purchaseTime, 500, "config purchase time")
eq(config.vehicles[1].part.compartment2loadConfig[1].loadConfigIndex, 0, "automatic load selection")
eq(config.vehicles[1].autoLoadConfig[2], true, "automatic loading enabled")
eq(native.bestBus().modelId, 10, "bestBus returns cheapest 12-month candidate")

local allowed, reason = native.canBuildResource(2, "free")
eq(allowed, true, "no company metadata is unrestricted")
allowed, reason = native.canBuildResource(2, "needs_rank")
eq(allowed, true, "rank metadata uses actual company accessor key")
allowed, reason = native.canBuildResource(3, "needs_rank")
eq(allowed, false, "missing progression fails closed"); eq(reason, "company_rank_unavailable", "missing rank reason")
allowed, reason = native.canBuildResource(3, "initial_rank")
eq(allowed, true, "rank zero with empty permit defaults needs no singleton progression")
allowed, reason = native.canBuildResource(3, "first_rank")
eq(allowed, true, "rival without vanilla singleton state starts at native tier one")
allowed, reason = native.canBuildResource(2, "needs_permit")
eq(allowed, false, "permit resource fails closed")
eq(reason, "vanilla_company_permits_not_initialized_for_competitor", "permit reason")
allowed, reason = native.canBuildResource(2, "missing")
eq(allowed, false, "unknown resource fails closed"); eq(reason, "construction_resource_missing", "unknown resource reason")

local stats, statsError = native.routeStats(2, { line = 50, infrastructure = { 60, 60, 61 } }, 10, 20)
eq(statsError, nil, "route stats error"); eq(stats.valid, true, "owned route is valid")
eq(stats.profit, 200, "line finance works without an ACCOUNT component")
eq(stats.income, 250, "route income derives from the vehicle ledger")
eq(stats.expenses, 50, "route expenses use the vehicle ledger")
eq(stats.profitScope, "vehicles", "vanilla line finance scope is explicit")
eq(stats.vehicles[1], 41, "route vehicle ids"); near(stats.occupancy, 0.25, "capacity occupancy")
near(stats.occupancySample.ratio, 0.25, "capacity sample ratio")
eq(stats.noPath, true, "alternative path issue detected")
near(stats.monthlyCost, (1200 + 30 + 60) / 12, "vehicle and deduplicated infrastructure cost")
eq(capacityCalls, 1, "capacity queried once")
local lineProfitCalls = 0
local originalCalculateBalance = api.engine.util.finance.calculateBalance
api.engine.util.finance.calculateBalance = function(entities, ...)
	if entities[1] == 41 then lineProfitCalls = lineProfitCalls + 1 end
	return originalCalculateBalance(entities, ...)
end
native.routeStats(2, { line = 50, infrastructure = { 60, 60, 61 } }, 10, 20)
assert(lineProfitCalls >= 5, "vehicle finance is queried for net balance and expenses")
routeVehicles = { 43 }
local invalidVehicleStats = native.routeStats(2, { line = 50, infrastructure = { 60, 61 } }, 10, 20)
eq(invalidVehicleStats.valid, false, "foreign vehicle invalidates route finance")
routeVehicles = { 41 }
failRouteFinance = true
local ledgerFailureStats = native.routeStats(2, { line = 50, infrastructure = { 60, 61 } }, 10, 20)
eq(ledgerFailureStats.valid, true, "finance failure preserves valid ownership snapshot")
eq(ledgerFailureStats.profit, nil, "failed native ledger query has no fabricated profit")
eq(ledgerFailureStats.profitScope, nil, "failed ledger query has no finance scope")
eq(ledgerFailureStats.expenses, nil, "failed maintenance query remains unavailable")
failRouteFinance = false
eq(native.companyProfit(2, 10, 20), 250, "company profit helper")
eq(native.operatingProfit(2, 10, 20), 250, "controller operating profit helper")
eq(native.operatingExpenses(2, 10, 20), 150, "company maintenance expense helper")
eq(native.operatingIncome(2, 10, 20), 400, "company operating income helper")
local invalidOwnerStats = native.routeStats(1, 50, 10, 20)
eq(invalidOwnerStats.valid, false, "foreign route is rejected")
local badStats, badReason = native.routeStats(2, 50, 20, 10)
eq(badStats, nil, "invalid interval returns no stats"); eq(badReason, "invalid_route_stats_arguments", "invalid interval reason")

print("native adapter mock tests passed")
