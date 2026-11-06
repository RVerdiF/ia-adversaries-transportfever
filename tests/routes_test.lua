-- Route adapter safety and management state-machine tests.
local function equal(actual, expected, message)
	assert(actual == expected, string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
end

local components = {
	owned = "owned",
	edge = "edge",
	street = "street",
	line = "line",
	depot = "depot",
	vehicle = "vehicle",
}
local entities = {}
local commands = {}
local lineVehicles = {}
local sendTargetArgs = {}
local purchaseResult, purchaseDepot = 303, 200

api = {
	type = {
		ComponentType = {
			PLAYER_OWNED = components.owned,
			BASE_EDGE = components.edge,
			BASE_EDGE_STREET = components.street,
			LINE = components.line,
			VEHICLE_DEPOT = components.depot,
			TRANSPORT_VEHICLE = components.vehicle,
			NAME = "name",
		},
		enum = {
			RoadType = { STREET = "street" },
			BaseEdgeType = { NORMAL = "normal" },
			Carrier = { ROAD = "road" },
			TransportMode = { BUS = "bus" },
		},
		SegmentAndEntity = {
			new = function() return {} end,
		},
		SimpleStreetProposal = {
			new = function() return {} end,
			EdgeObject = { new = function() return {} end },
		},
		SimpleProposal = { new = function() return {} end },
		Line = { new = function() return {} end, Stop = { new = function() return {} end } },
		StationTerminal = { new = function() return {} end },
	},
	engine = {
		util = { getYear = function() return 2000 end, pathfinding = { findPathNodeToNode = function() return {} end } },
		getComponent = function(entity, kind)
			return entities[entity] and entities[entity][kind] or nil
		end,
		entityExists = function(entity) return entities[entity] ~= nil end,
		system = {
			transportVehicleSystem = {
				getLineVehicles = function() return lineVehicles end,
				getDepotVehicles = function(depot)
					local result = {}
					for entity, state in pairs(entities) do
						if state.vehicle and state.vehicle.depot == depot then result[#result + 1] = entity end
					end
					return result
				end,
			},
			lineSystem = { getLinesForPlayer = function() return {} end },
		},
		getRevision = function() return { num = { 1, 2, 3 } } end,
	},
	cmd = {
		makeVehicleSendToDepotCmd = function(vehicle, sellOnArrival, jumpToDepot)
			sendTargetArgs[#sendTargetArgs + 1] = jumpToDepot
			return { kind = "send", vehicle = vehicle, sell = sellOnArrival }
		end,
		makeVehicleSellCmd = function(vehicles) return { kind = "sell", vehicles = vehicles } end,
		makeLineDestroyCmd = function(line) return { kind = "destroy", line = line } end,
		makeVehicleBuyCmd = function(player, depot, config)
			return { kind = "buy", player = player, depot = depot, config = config }
		end,
		makeVehicleSetLineCmd = function(vehicle, line, stopIndex)
			return { kind = "assign", vehicle = vehicle, line = line, stopIndex = stopIndex }
		end,
		sendCommand = function(command, callback)
			assert(callback == nil, "GameScript commands must not receive callbacks")
			commands[#commands + 1] = command
			if command.kind == "buy" then
				entities[purchaseResult] = { owned = { player = command.player }, vehicle = { depot = purchaseDepot, line = -1 } }
				command.resultVehicleEntity = purchaseResult
			elseif command.kind == "assign" then
				entities[command.vehicle].vehicle.line = command.line
			elseif command.kind == "sell" then
				for _, vehicle in ipairs(command.vehicles) do entities[vehicle] = nil end
			elseif command.kind == "destroy" then
				entities[command.line] = nil
			end
		end,
	},
	res = { modelRep = { get = function() return nil end } },
	util = { getDefaultMonthDuration = function() return 2400 end },
}

local routes = dofile("content/ai/routes.lua")

local gate = routes.readiness()
equal(gate.automaticPlacement, false, "placement stays gated")
equal(gate.requires.proposalPreviewChecked, true, "preview requirement")
equal(gate.requires.depotRoadConnectionVerified, true, "depot connection requirement")
local plan, reason, cursor, finished = routes.scan(1, { cursor = 17 })
equal(plan, nil, "no route plan while gated")
equal(reason, "route_planner_unavailable", "missing planner reason")
equal(cursor, 17, "scan cursor preserved")
equal(finished, true, "scan is finished while gated")

-- A stop proposal preserves the plain municipal street and refuses unsafe
-- edges before allocating a replacement entity.
local originalEdge = {
	roadType = "street",
	type = "normal",
	roadDevelopmentLocked = false,
	distance = 36,
	objects = {},
	node0 = 20,
	node1 = 21,
}
function originalEdge:clone()
	return {
		roadType = self.roadType, type = self.type, roadDevelopmentLocked = self.roadDevelopmentLocked,
		distance = self.distance, objects = {}, node0 = self.node0, node1 = self.node1,
	}
end
local precedence = { precedenceNode0 = "auto0", precedenceNode1 = "auto1" }
entities[10] = { edge = originalEdge, street = precedence }
local proposal = routes.makeStopProposal(10, 9, 2000, "Rival Bus Stop")
assert(proposal, "public plain street should be eligible")
equal(proposal.streetProposal.edgesToRemove[1], 10, "replaces selected road only")
local replacement = proposal.streetProposal.edgesToAdd[1]
equal(replacement.entity, -1, "new edge uses negative entity id")
equal(replacement.type, 0, "street segment type")
equal(replacement.comp.node0, 20, "street start node preserved")
equal(replacement.comp.node1, 21, "street end node preserved")
equal(replacement.streetEdge, precedence, "street precedence preserved")
local stop = proposal.streetProposal.edgeObjectsToAdd[1]
equal(stop.edgeEntity, -1, "stop is attached to replacement edge")
equal(stop.param, 0.5, "stop position")
equal(stop.playerEntity, 9, "stop owner is rival")
equal(stop.model, "::/street/small_stops/small_new.con", "current-era stop asset")
originalEdge.objects = { { 30, "stop" } }
equal(routes.makeStopProposal(10, 9, 2000, "unsafe"), nil, "occupied road rejected")
originalEdge.objects = {}
entities[10].owned = { player = 4 }
equal(routes.makeStopProposal(10, 9, 2000, "unsafe"), nil, "owned road rejected")
entities[10].owned = nil

-- Build is explicitly a diagnostic until placement preflight is verified.
local buildCallbackCalled = false
routes.stepBuild(9, { key = "no-build" }, function(ok, operation, route, err)
	buildCallbackCalled = true
	equal(ok, false, "gated build fails closed")
	equal(operation.key, "no-build", "operation preserved")
	equal(route, nil, "no route created")
	equal(err, gate.reason, "gated build reports reason")
end)
equal(buildCallbackCalled, true, "build callback runs")

-- Fleet closure uses one send command per step and waits for every owned
-- vehicle to disappear before destroying the line. The optional depot
-- parameter is intentionally omitted because it means teleport in this API.
entities[100] = { owned = { player = 9 }, line = { stops = { {}, {} } } }
entities[200] = { owned = { player = 9 }, depot = {} }

local candidateAvailable = true
local candidateCost, candidateRunningCost, liveBalance, liveMonthlyCost = 1000, 1200, 5000, 100
local nativeStub = {
	vehicleCandidates = function()
		if not candidateAvailable then return {} end
		return { { modelId = 7, purchaseCost = candidateCost, runningCost = candidateRunningCost,
			config = { exactCurrentConfig = true } } }
	end,
	snapshot = function() return { monthlyCost = liveMonthlyCost } end,
	balance = function() return liveBalance end,
}
local modules = {
	["pichau_competitor_ai::/ai/native.lua"] = nativeStub,
	["pichau_competitor_ai::/ai/policy.lua"] = dofile("content/ai/policy.lua"),
}
ug_require = function(path) if modules[path] then return modules[path] end; error("unexpected module " .. tostring(path)) end

-- Management buys recheck the live quote, reserve, and date availability.
local managementError, managementNext
liveBalance = 500
routes.stepManage(9, { action = "buy", line = 100, depot = 200, modelId = 7 }, function(ok, _, err)
	equal(ok, false, "insufficient management funds refused")
	managementError = err
end)
equal(managementError, "insufficient_funds_after_reserve", "live reserve error")
equal(#commands, 0, "insufficient funds issue no purchase command")
candidateAvailable = false
api.res.modelRep.get = function() return { metadata = {
	transportVehicle = { carrier = "road", transportModes = { "bus" } }, availability = { yearTo = 1990 },
} } end
routes.stepManage(9, { action = "buy", line = 100, depot = 200, modelId = 7 }, function(ok, _, err)
	equal(ok, false, "out of date bus refused")
	managementError = err
end)
equal(managementError, "vehicle_model_unavailable_this_year", "date availability error")
equal(#commands, 0, "out of date model issues no purchase command")
candidateAvailable = true
liveBalance = 5000
api.res.modelRep.get = function() return nil end
local buyOperation = { action = "buy", line = 100, depot = 200, modelId = 7 }
routes.stepManage(9, buyOperation, function(ok, nextOp, err)
	assert(ok, err); managementNext = nextOp
end)
equal(managementNext.phase, "assign", "managed bus purchase advances to assignment")
equal(commands[1].kind, "buy", "managed bus uses native candidate configuration")
equal(commands[1].config.exactCurrentConfig, true, "current config passed to purchase")
routes.stepManage(9, managementNext, function(ok, nextOp, err)
	assert(ok, err); equal(nextOp, nil, "managed bus assignment completes")
end)
equal(commands[2].kind, "assign", "managed bus assigned after ownership validation")
for index = #commands, 1, -1 do commands[index] = nil end

entities[301] = { owned = { player = 9 }, vehicle = { line = 100, depot = -1 } }
entities[302] = { owned = { player = 9 }, vehicle = { line = 100, depot = -1 } }
lineVehicles = { 301, 302 }
local operation = { action = "close", line = 100, depot = 200 }
routes.stepManage(9, operation, function(ok, nextOperation) assert(ok); operation = nextOperation end)
equal(operation.phase, "send_vehicles", "close enters send phase")
equal(#operation.vehicles, 2, "close retains full wait list")
routes.stepManage(9, operation, function(ok, nextOperation) assert(ok); operation = nextOperation end)
equal(#operation.sendQueue, 1, "one vehicle sent per update")
routes.stepManage(9, operation, function(ok, nextOperation) assert(ok); operation = nextOperation end)
equal(#operation.sendQueue, 0, "second vehicle sent on next update")
routes.stepManage(9, operation, function(ok, nextOperation) assert(ok); operation = nextOperation end)
equal(operation.phase, "wait_sell", "close waits for sale")
routes.stepManage(9, operation, function(ok, nextOperation) assert(ok); operation = nextOperation end)
equal(operation.phase, "wait_sell", "line retained while vehicles remain")
equal(#commands, 2, "two sends, no premature line destruction")
equal(sendTargetArgs[1], nil, "send does not teleport")
equal(sendTargetArgs[2], nil, "send does not teleport")
entities[301], entities[302] = nil, nil
routes.stepManage(9, operation, function(ok, nextOperation) assert(ok); operation = nextOperation end)
equal(operation.phase, "destroy_line", "destroy only after both vehicle sales")
routes.stepManage(9, operation, function(ok, nextOperation) assert(ok); operation = nextOperation end)
equal(operation, nil, "close completes after line destruction")
equal(commands[3].kind, "destroy", "line destroyed last")

print("routes adapter tests passed")
