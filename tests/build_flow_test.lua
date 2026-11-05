-- Serialized route construction and preview handoff tests.
local modules = {}
ug_require = function(name) return modules[name] end

local owned = "owned"
local lineComp = { new = function() return {} end, Stop = { new = function() return {} end } }
local commands = {}
local entities = {
	[1101] = { group = { stations = { 2101 } } }, [2101] = { station = { terminals = {
		{ vehicleNodeId = {entity=2101,index=0}, transportModes = { bus = true } },
	} } },
	[1102] = { group = { stations = { 2102 } } }, [2102] = { station = { terminals = {
		{ vehicleNodeId = {entity=2102,index=0}, transportModes = { bus = true } },
	} } },
	[200] = { owned = { player = 9 }, depot = { inNodes = { {entity=200,index=0} }, outNodes = { {entity=200,index=1} } } },
}
api = {
	type = {
		Line = lineComp,
		Vec3f = { new = function(x, y, z) return { x = x, y = y, z = z } end },
		StationTerminal = { new = function(station, terminal) return { station = station, terminal = terminal } end },
		ComponentType = { PLAYER_OWNED = owned, LINE = "line", VEHICLE_DEPOT = "depot", TRANSPORT_VEHICLE = "vehicle",
			STATION_GROUP = "group", STATION = "station" },
		enum = { Carrier = { ROAD = "road" }, TransportMode = { BUS = "bus" } },
	},
	engine = {
		getComponent = function(entity, kind) return entities[entity] and entities[entity][kind] end,
		entityExists = function(entity) return entities[entity] ~= nil end,
		getRevision = function() return { num = { 1, 2, 3 } } end,
		util = { pathfinding = { findPathNodeToNode = function() return { { 1, false } } end } },
	},
	cmd = {
		makeWorldBuildProposalCmd = function() return {} end,
		makeLineCreateCmd = function(name, color, player, line) return { kind = "line", line = line } end,
		makeVehicleBuyCmd = function() return { kind = "buy" } end,
		makeVehicleSetLineCmd = function() return { kind = "assign" } end,
		makeVehicleSellCmd = function() return { kind = "sell" } end,
		makeLineDestroyCmd = function() return { kind = "destroy" } end,
		sendCommand = function(command, callback)
			commands[#commands + 1] = command
			if command.kind == "line" then
				entities[300] = { owned = { player = 9 }, line = command.line }
				callback({ resultEntity = 300 }, true)
			elseif command.kind == "buy" then
				entities[400] = { owned = { player = 9 }, vehicle = { depot = 200, line = -1 } }
				callback({ resultVehicleEntity = 400 }, true)
			else callback({}, true) end
		end,
	},
}

modules["pichau_competitor_ai::/ai/planner.lua"] = { scan = function() return nil, "none", 1, true end }
modules["pichau_competitor_ai::/ai/construction.lua"] = {
	makeProposal = function() return {} end,
	identifyEntities = function(_, resultEntities, kind)
		if kind == "stop" then return { stationGroups = { resultEntities[1] + 1000 }, infrastructure = { resultEntities[1] },
			cleanupEntities = { resultEntities[1] } } end
		return { depots = { resultEntities[1] }, infrastructure = { resultEntities[1] }, cleanupEntities = { resultEntities[1] } }
	end,
}
modules["pichau_competitor_ai::/ai/native.lua"] = {
	canBuildResource = function() return true end,
	balance = function() return 1000 end,
	vehicleCandidates = function() return { { modelId = 7, purchaseCost = 15, config = { vehicle = 1 } } } end,
}
entities[501] = { owned = { player = 9 }, construction = {} }
local routes = dofile("content/ai/routes.lua")
assert(routes.readiness().automaticPlacement, "required adapter APIs enable staged placement")

local function preview(player, operation, stage, entity)
	local operationOut
	routes.stepBuild(player, operation, function(ok, nextOperation, route, err)
		assert(ok, err)
		operationOut = nextOperation
	end)
	assert(operationOut.preview and operationOut.awaitingStage == stage, "stage emits GUI preview")
	local ok, nextOperation, reason = routes.acceptPreview(player, operationOut, {
		token = operationOut.preview.token, success = true, entities = { entity }, cost = 20,
	})
	assert(ok, reason)
	return nextOperation
end

local operation = {
	id = "candidate:1", key = "candidate", name = "Teste", modelId = 7, stage = "stop_a",
	stopEdges = { 10, 20 }, stopEdgeRevisions = { { num = { 1, 2 } }, { num = { 2, 3 } } },
	stopResource = "stop.con", depotSite = { x = 0, y = 0, z = 0, heading = 0 },
	depotResource = "depot.con", budget = { maxSpend = 1000, remaining = 1000, reserve = 100, busCost = 15 },
}
operation = preview(9, operation, "stop_a", 101)
assert(operation.stage == "stop_b" and operation.stops[1] == 1101, "first owned stop identified")
operation = preview(9, operation, "stop_b", 102)
assert(operation.stage == "depot" and operation.stops[2] == 1102, "second owned stop identified")
operation = preview(9, operation, "depot", 200)
assert(operation.stage == "create_line" and operation.depot == 200,
	"depot is connected both ways: stage=" .. tostring(operation.stage) .. " err=" .. tostring(operation.cleanupError))
assert(operation.selectedStops[1].station == 0 and operation.selectedStops[2].station == 0,
	"connected station terminal selections are retained for the line")
assert(operation.selectedStops[1].node == nil, "native NodeId must not enter persisted operations")

local function advance(expectedStage)
	local nextOperation, route
	routes.stepBuild(9, operation, function(ok, updated, completedRoute, err)
		assert(ok, err)
		nextOperation, route = updated, completedRoute
	end)
	assert(nextOperation and nextOperation.stage == expectedStage,
		"single stage transition: expected=" .. expectedStage .. " got=" .. tostring(nextOperation and nextOperation.stage)
			.. " cleanup=" .. tostring(nextOperation and nextOperation.cleanupError))
	operation = nextOperation
	return route
end
advance("buy")
advance("assign")
local route
routes.stepBuild(9, operation, function(ok, updated, completedRoute, err)
	assert(ok, err)
	assert(updated == nil, "completed operation is cleared")
	route = completedRoute
end)
assert(route and route.line == 300 and route.depot == 200 and #route.infrastructure == 3,
	"final route retains owned assets")

-- A failed later preview starts serialized cleanup of already built assets.
local cleanupOp = {
	id = "cleanup:1", key = "cleanup", stage = "awaiting_preview", awaitingStage = "stop_b",
	preview = { token = "cleanup:1:stop_b" }, ownedEntities = { 501 },
}
local ok, cleanupNext = routes.acceptPreview(9, cleanupOp, {
	token = cleanupOp.preview.token, success = false, reason = "collision",
})
assert(ok and cleanupNext.stage == "cleanup", "partial build failure enters cleanup")
local cleanupPreview
routes.stepBuild(9, cleanupNext, function(success, nextOperation) assert(success); cleanupPreview = nextOperation end)
assert(cleanupPreview.preview.intent.kind == "remove", "cleanup requests owned-only removal preview")
local removed, cleanupDone = routes.acceptPreview(9, cleanupPreview, {
	token = cleanupPreview.preview.token, success = true, entities = {}, cost = -1,
})
assert(removed and cleanupDone.stage == "cleanup_done", "cleanup preserves completed queue state")
local cleanupComplete
routes.stepBuild(9, cleanupDone, function(success, operationAfter, _, reason)
	assert(not success and reason:find("collision", 1, true))
	cleanupComplete = operationAfter.cleanupComplete
end)
assert(cleanupComplete, "cleaned failure is diagnostic and replan-safe")

-- A current vehicle quote that differs from the reserved quote triggers
-- rollback before the purchase command is sent.
local beforeChangedQuote = #commands
local quoteCleanup
routes.stepBuild(9, { id = "changed-quote", key = "quote", stage = "buy", line = 300, depot = 200,
	modelId = 7, ownedEntities = { 501 }, budget = { remaining = 1000, reserve = 100, busCost = 14 } },
	function(success, nextOperation, _, err)
		assert(success, err)
		quoteCleanup = nextOperation
	end)
assert(quoteCleanup.stage == "cleanup_destroy_line" and quoteCleanup.cleanupError == "vehicle_quote_changed",
	"changed quote starts cleanup")
assert(#commands == beforeChangedQuote, "changed quote issues no purchase command")

-- Cleanup refuses to destroy a line if ownership changes before rollback.
entities[999] = { owned = { player = 1 }, line = { stops = { {}, {} } } }
local commandCount = #commands
routes.stepBuild(9, { id = "foreign-line", stage = "cleanup_destroy_line", line = 999, depot = 200 },
	function(success, _, _, reason)
		assert(not success and reason == "cleanup_line_not_owned", "foreign line cleanup is rejected")
	end)
assert(#commands == commandCount, "foreign line receives no destroy command")

print("route build flow tests passed")
