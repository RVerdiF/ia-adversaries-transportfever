-- Native route adapter for the competitor AI.
--
-- Road stops and depots pass through a native cost/collision preview. The
-- serialized state machine checks ownership and road connectivity before
-- creating a line, purchasing a bus or returning a completed route.
local routes = {}
local vehicleIsOwned
local validLineAndDepot

local function finiteNumber(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function loadModule(path)
	if type(ug_require) ~= "function" then return nil end
	local ok, value = pcall(ug_require, path)
	return ok and value or nil
end

local function plannerModule()
	return loadModule("pichau_competitor_ai::/ai/planner.lua")
end

local function constructionModule()
	return loadModule("pichau_competitor_ai::/ai/construction.lua")
end

local function nativeModule()
	return loadModule("pichau_competitor_ai::/ai/native.lua")
end

local function policyModule()
	return loadModule("pichau_competitor_ai::/ai/policy.lua")
end

local function busCandidate(modelId, native)
	if not native or type(native.vehicleCandidates) ~= "function" then
		return nil, "vehicle_catalog_unavailable"
	end
	local ok, candidates = pcall(native.vehicleCandidates, api.type.enum.Carrier.ROAD, api.type.enum.TransportMode.BUS)
	if not ok or type(candidates) ~= "table" then return nil, "vehicle_catalog_unavailable" end
	for _, candidate in ipairs(candidates) do
		if candidate.modelId == modelId then return candidate end
	end
	local model = api.res and api.res.modelRep and api.res.modelRep.get(modelId)
	local vehicle = model and model.metadata and model.metadata.transportVehicle
	if not vehicle or vehicle.carrier ~= api.type.enum.Carrier.ROAD then
		return nil, "bus_model_invalid_or_unavailable"
	end
	local isBus = false
	for _, mode in ipairs(vehicle.transportModes or {}) do
		if mode == api.type.enum.TransportMode.BUS then isBus = true; break end
	end
	if not isBus then return nil, "bus_model_invalid_or_unavailable" end
	local availability = model.metadata.availability or {}
	local year = api.engine.util.getYear()
	if (availability.yearFrom and availability.yearFrom > 0 and year < availability.yearFrom)
		or (availability.yearTo and availability.yearTo > 0 and year >= availability.yearTo) then
		return nil, "vehicle_model_unavailable_this_year"
	end
	return nil, "bus_model_invalid_or_unavailable"
end

local function pathfindingModule()
	return api and api.engine and api.engine.util and api.engine.util.pathfinding
end

local function safeCall(callback, ...)
	if type(callback) == "function" then
		callback(...)
	end
end

local function component(entity, componentType)
	if type(entity) ~= "number" or entity < 0 then
		return nil
	end
	return api.engine.getComponent(entity, componentType)
end

local function isOwnedBy(entity, player)
	local owned = component(entity, api.type.ComponentType.PLAYER_OWNED)
	return owned ~= nil and owned.player == player
end

local function isPublicPlainStreet(edgeEntity)
	local edge = component(edgeEntity, api.type.ComponentType.BASE_EDGE)
	local street = component(edgeEntity, api.type.ComponentType.BASE_EDGE_STREET)
	for _, object in ipairs(edge and edge.objects or {}) do
		local objectEntity = type(object) == "table" and (object[1] or object.entity) or object
		if type(objectEntity) ~= "number" or component(objectEntity, api.type.ComponentType.PLAYER_OWNED) ~= nil then
			return false
		end
	end
	if not edge or not street or edge.roadType ~= api.type.enum.RoadType.STREET
		or edge.type ~= api.type.enum.BaseEdgeType.NORMAL
		or (edge.distance or 0) < 20
		or component(edgeEntity, api.type.ComponentType.PLAYER_OWNED) ~= nil then
		return false
	end
	return true
end

local function stopResourceForYear(year)
	if year < 1920 then
		return "::/street/small_stops/small_old.con"
	elseif year < 1980 then
		return "::/street/small_stops/small_mid.con"
	end
	return "::/street/small_stops/small_new.con"
end

-- Build the documented remove-and-add street proposal for an unowned,
-- unoccupied, normal municipal street segment. The replacement keeps the
-- exact road geometry/template/precedence and gives only the new stop to the
-- rival. This helper is intentionally not called by stepBuild while the full
-- preflight gate is closed.
local function makeStopReplacement(edgeEntity, player, year, name)
	if not isPublicPlainStreet(edgeEntity) or type(player) ~= "number" then
		return nil, "unsafe_stop_edge"
	end
	local baseEdge = component(edgeEntity, api.type.ComponentType.BASE_EDGE)
	local baseStreet = component(edgeEntity, api.type.ComponentType.BASE_EDGE_STREET)
	local replacement = api.type.SegmentAndEntity.new()
	replacement.entity = -1
	replacement.comp = baseEdge:clone()
	replacement.type = 0 -- street, as defined by SimpleStreetProposal
	replacement.streetEdge = baseStreet

	local streetProposal = api.type.SimpleStreetProposal.new()
	streetProposal.edgesToRemove = { edgeEntity }
	streetProposal.edgesToAdd = { replacement }
	local stop = api.type.SimpleStreetProposal.EdgeObject.new()
	stop.edgeEntity = -1
	stop.param = 0.5
	stop.oneWay = false
	stop.left = false
	stop.model = stopResourceForYear(year)
	stop.playerEntity = player
	stop.name = name
	streetProposal.edgeObjectsToAdd = { stop }

	local proposal = api.type.SimpleProposal.new()
	proposal.streetProposal = streetProposal
	return proposal
end

-- Read-only helper; mutations must pass through the checked preview bridge.
routes.makeStopProposal = makeStopReplacement

function routes.readiness()
	local planner = plannerModule()
	local construction = constructionModule()
	local native = nativeModule()
	local pathfinding = pathfindingModule()
	local missing = {}
	local function needFunction(value, name)
		if type(value) ~= "function" then missing[#missing + 1] = name end
	end
	local function needNative(value, name)
		-- The engine's bound calls are callable userdata in game scripts.
		if value == nil then missing[#missing + 1] = name end
	end
	local function needValue(value, name)
		if value == nil then missing[#missing + 1] = name end
	end
	local apiTable = type(api) == "table" and api or nil
	local cmd = apiTable and type(apiTable.cmd) == "table" and apiTable.cmd or nil
	local engine = apiTable and type(apiTable.engine) == "table" and apiTable.engine or nil
	local typeApi = apiTable and type(apiTable.type) == "table" and apiTable.type or nil
	if not apiTable then
		missing[#missing + 1] = "api"
	else
		if not cmd then missing[#missing + 1] = "api.cmd" end
		if not engine then missing[#missing + 1] = "api.engine" end
		if not typeApi then missing[#missing + 1] = "api.type" end
	end
	local function command(name)
		needNative(cmd and cmd[name], "api.cmd." .. name)
	end
	command("sendCommand")
	command("makeWorldBuildProposalCmd")
	command("makeLineCreateCmd")
	command("makeVehicleBuyCmd")
	command("makeVehicleSetLineCmd")
	command("makeVehicleSellCmd")
	command("makeLineDestroyCmd")
	needNative(engine and engine.getComponent, "api.engine.getComponent")
	needNative(engine and engine.getRevision, "api.engine.getRevision")
	local systems = engine and engine.system
	needNative(systems and systems.lineSystem and systems.lineSystem.getLinesForPlayer, "api.engine.system.lineSystem.getLinesForPlayer")
	needNative(systems and systems.transportVehicleSystem and systems.transportVehicleSystem.getDepotVehicles, "api.engine.system.transportVehicleSystem.getDepotVehicles")
	local line = typeApi and typeApi.Line
	needFunction(line and line.new, "api.type.Line.new")
	needFunction(line and line.Stop and line.Stop.new, "api.type.Line.Stop.new")
	local terminal = typeApi and typeApi.StationTerminal
	needFunction(terminal and terminal.new, "api.type.StationTerminal.new")
	local transportMode = typeApi and typeApi.enum and typeApi.enum.TransportMode
	needValue(transportMode and transportMode.BUS, "api.type.enum.TransportMode.BUS")
	local componentType = typeApi and typeApi.ComponentType
	needValue(componentType and componentType.STATION, "api.type.ComponentType.STATION")
	needValue(componentType and componentType.STATION_GROUP, "api.type.ComponentType.STATION_GROUP")
	needValue(componentType and componentType.VEHICLE_DEPOT, "api.type.ComponentType.VEHICLE_DEPOT")
	needValue(componentType and componentType.NAME, "api.type.ComponentType.NAME")
	if not planner then missing[#missing + 1] = "module /ai/planner.lua"
	else needFunction(planner.scan, "planner.scan") end
	if not construction then missing[#missing + 1] = "module /ai/construction.lua"
	else
		needFunction(construction.makeProposal, "construction.makeProposal")
		needFunction(construction.identifyEntities, "construction.identifyEntities")
	end
	if not pathfinding then missing[#missing + 1] = "api.engine.util.pathfinding"
	else needNative(pathfinding.findPathNodeToNode, "pathfinding.findPathNodeToNode") end
	if not native then missing[#missing + 1] = "module /ai/native.lua"
	else
		needFunction(native.canBuildResource, "native.canBuildResource")
		needFunction(native.vehicleCandidates, "native.vehicleCandidates")
		needFunction(native.balance, "native.balance")
	end
	local ready = #missing == 0
	local reason
	if not ready then reason = "native_route_api_unavailable: " .. table.concat(missing, ", ") end
	return {
		automaticPlacement = ready,
		reason = reason,
		message = ready
			and "APIs de construção disponíveis; a validação da prévia ocorre em cada etapa."
			or "APIs ausentes: " .. table.concat(missing, ", "),
		requires = { proposalPreviewChecked = true, depotRoadConnectionVerified = true },
	}
end

function routes.scan(player, state)
	state = type(state) == "table" and state or {}
	local planner = plannerModule()
	if not planner or type(planner.scan) ~= "function" then
		return nil, "route_planner_unavailable", state.cursor, true
	end
	local native = nativeModule()
	if native and type(native.canBuildResource) == "function" then
		state.canBuildResource = native.canBuildResource
	end
	return planner.scan(player, state)
end

local function copyOperation(operation)
	local copy = {}
	for key, value in pairs(operation or {}) do copy[key] = value end
	return copy
end

local function stopStage(stage)
	return stage == "stop_a" or stage == "stop_b"
end

local function stageIntent(operation)
	if operation.stage == "stop_a" or operation.stage == "stop_b" then
		local index = operation.stage == "stop_a" and 1 or 2
		return { kind = "stop", edge = operation.stopEdges and operation.stopEdges[index],
			edgeRevision = operation.stopEdgeRevisions and operation.stopEdgeRevisions[index],
			resource = operation.stopResource, name = operation.name }
	end
	if operation.stage == "depot" then
		return { kind = "depot", site = operation.depotSite,
			resource = operation.depotResource, name = operation.name }
	end
	return nil
end

local function stageToken(operation)
	return tostring(operation.id or operation.key) .. ":" .. tostring(operation.stage)
end

local function budgetRemaining(operation)
	local budget = operation.budget or {}
	local cap = budget.remaining or budget.maxSpend
	if type(cap) ~= "number" then return math.huge end
	return math.max(0, cap)
end

local function charge(operation, amount)
	if type(amount) ~= "number" or amount < 0 or amount ~= amount or amount == math.huge then
		return false, "preview_cost_invalid"
	end
	local budget = operation.budget or {}
	local busCost = budget.busCost or 0
	if amount > math.max(0, budgetRemaining(operation) - busCost) then return false, "route_budget_exceeded" end
	if type(budget.reserve) == "number" and type(budget.balance) == "number"
		and budget.balance - amount < budget.reserve + busCost then
		return false, "route_balance_reserve_breached"
	end
	local nextOperation = copyOperation(operation)
	nextOperation.budget = copyOperation(budget)
	if type(nextOperation.budget.remaining) == "number" then
		nextOperation.budget.remaining = math.max(0, nextOperation.budget.remaining - amount)
	end
	return true, nil, nextOperation
end

local function entityIds(entities)
	local result = {}
	for _, item in ipairs(entities or {}) do
		local id = type(item) == "table" and (item.id or item.entity) or item
		if type(id) == "number" and id >= 0 then result[#result + 1] = id end
	end
	return result
end

local function appendUnique(target, values)
	for _, entity in ipairs(values or {}) do
		local found = false
		for _, existing in ipairs(target) do
			if existing == entity then found = true; break end
		end
		if not found and type(entity) == "number" then target[#target + 1] = entity end
	end
end

local function identify(player, entities, kind)
	local construction = constructionModule()
	if not construction or type(construction.identifyEntities) ~= "function" then
		return nil, "entity_identification_unavailable"
	end
	local ok, found = pcall(construction.identifyEntities, player, entityIds(entities), kind)
	if not ok or type(found) ~= "table" then return nil, "built_entities_unidentified" end
	return found
end

local function getPathfinding()
	return pathfindingModule()
end

local function routeConnections(operation)
	local pathfinding = getPathfinding()
	local findPath = pathfinding and pathfinding.findPathNodeToNode
	if findPath == nil then return false, "depot_pathfinder_unavailable" end
	local depot = component(operation.depot, api.type.ComponentType.VEHICLE_DEPOT)
	if not depot or #(depot.inNodes or {}) == 0 or #(depot.outNodes or {}) == 0 then
		return false, "depot_nodes_missing"
	end
	local selected = {}
	for stopIndex, groupEntity in ipairs(operation.stops or {}) do
		local group = component(groupEntity, api.type.ComponentType.STATION_GROUP)
		if not group then return false, "station_group_missing" end
		local chosen
		for stationIndex, stationEntity in ipairs(group.stations or {}) do
			local station = component(stationEntity, api.type.ComponentType.STATION)
			for terminalIndex, terminal in ipairs(station and station.terminals or {}) do
				local modes = terminal.transportModes or {}
				if modes[api.type.enum.TransportMode.BUS] and terminal.vehicleNodeId ~= nil then
					chosen = { station = stationIndex - 1, terminal = terminalIndex - 1, node = terminal.vehicleNodeId }
					break
				end
			end
			if chosen then break end
		end
		if not chosen then return false, "bus_station_terminal_missing" end
		selected[stopIndex] = chosen
	end
	if #selected ~= 2 then return false, "route_stops_incomplete" end
	local function connected(starts, targets)
		local ok, path = pcall(findPath, starts, targets, { api.type.enum.TransportMode.BUS })
		return ok and type(path) == "table" and #path > 0
	end
	if not connected(depot.outNodes, { selected[1].node })
		or not connected({ selected[1].node }, { selected[2].node })
		or not connected({ selected[2].node }, { selected[1].node })
		or not connected({ selected[1].node }, depot.inNodes)
		or not connected(depot.outNodes, { selected[2].node })
		or not connected({ selected[2].node }, depot.inNodes) then
		return false, "depot_and_stops_not_connected_both_directions"
	end
	-- Native NodeId objects are only used during this query, never persisted.
	operation.selectedStops = {}
	for _, selection in ipairs(selected) do
		operation.selectedStops[#operation.selectedStops + 1] = {
			station = selection.station, terminal = selection.terminal,
		}
	end
	return true
end

-- Engine-state commands execute synchronously. Their optional callback is a
-- GUI/console convenience; inspect the engine state after dispatch instead.
local function sendNow(command)
	local ok, err = pcall(api.cmd.sendCommand, command)
	if not ok then return false, tostring(err) end
	return true, nil
end

local function ownedPlayerLines(player)
	local system = api.engine.system and api.engine.system.lineSystem
	if not system or not system.getLinesForPlayer then return {} end
	local ok, lines = pcall(system.getLinesForPlayer, player)
	return ok and type(lines) == "table" and lines or {}
end

local function depotVehicles(depot)
	local system = api.engine.system and api.engine.system.transportVehicleSystem
	if not system or not system.getDepotVehicles then return {} end
	local ok, vehicles = pcall(system.getDepotVehicles, depot)
	return ok and type(vehicles) == "table" and vehicles or {}
end

local function lineMatches(lineEntity, operation)
	local line = component(lineEntity, api.type.ComponentType.LINE)
	local name = component(lineEntity, api.type.ComponentType.NAME)
	if not line or not name or name.name ~= (operation.name or "Linha rival")
		or #(line.stops or {}) ~= 2 then return false end
	for index, group in ipairs(operation.stops or {}) do
		local stop = line.stops[index]
		local selected = operation.selectedStops and operation.selectedStops[index]
		if not stop or stop.stationGroup ~= group
			or (selected and (stop.station ~= selected.station or stop.terminal ~= selected.terminal)) then
			return false
		end
	end
	return true
end

local function setStage(operation, stage)
	local nextOperation = copyOperation(operation)
	nextOperation.stage = stage
	nextOperation.preview = nil
	nextOperation.previewResult = nil
	return nextOperation
end

local function startCleanup(operation, reason)
	local nextOperation = copyOperation(operation)
	nextOperation.cleanupError = reason or "route_build_failed"
	nextOperation.cleanupQueue = nextOperation.cleanupQueue or {}
	if #nextOperation.cleanupQueue == 0 then
		for index = #(nextOperation.ownedEntities or {}), 1, -1 do
			nextOperation.cleanupQueue[#nextOperation.cleanupQueue + 1] = nextOperation.ownedEntities[index]
		end
	end
	if nextOperation.vehicle then
		nextOperation.stage = "cleanup_sell_vehicle"
	elseif nextOperation.line then
		nextOperation.stage = "cleanup_destroy_line"
	else
		nextOperation.stage = "cleanup"
	end
	nextOperation.preview = nil
	nextOperation.awaitingStage = nil
	return nextOperation
end

local function queueCleanupPreview(operation)
	local nextOperation = copyOperation(operation)
	local entity = nextOperation.cleanupQueue and nextOperation.cleanupQueue[1]
	if not entity then
		nextOperation.stage = "cleanup_done"
		return nextOperation
	end
	nextOperation.awaitingStage = "cleanup"
	nextOperation.preview = {
		token = tostring(operation.id or operation.key) .. ":cleanup:" .. tostring(entity),
		intent = { kind = "remove", entity = entity },
		budget = { remaining = 0 },
	}
	nextOperation.stage = "awaiting_preview"
	return nextOperation
end

local function failBuild(operation, reason, done)
	if #(operation and operation.ownedEntities or {}) > 0 then
		safeCall(done, true, startCleanup(operation, reason), nil)
	else
		safeCall(done, false, operation, nil, reason)
	end
end

-- GUI calls this after ProposalViewer validates and applies the proposal. The
-- returned operation contains primitives only and is saved by the controller.
function routes.acceptPreview(player, operation, result)
	if type(operation) ~= "table" or type(operation.preview) ~= "table"
		or type(result) ~= "table" or result.token ~= operation.preview.token then
		return false, operation, "preview_token_mismatch"
	end
	local nextOperation = copyOperation(operation)
	local acceptedStage = nextOperation.awaitingStage or nextOperation.stage
	local kind = stopStage(acceptedStage) and "stop" or "depot"
	if result.success ~= true then
		local failure = result.reason or "preview_build_failed"
		if acceptedStage == "cleanup" then return false, nextOperation, "cleanup_failed:" .. failure end
		-- A completed build may be reported as a failure if its price changed.
		-- Include every discoverable owned asset from that receipt in rollback.
		if #(result.entities or {}) > 0 then
			local found = identify(player, result.entities, kind)
			if not found then
				nextOperation.cleanupIncomplete = true
				return false, nextOperation, "failed_build_receipt_unidentified:" .. failure
			end
			nextOperation.ownedEntities = nextOperation.ownedEntities or {}
			appendUnique(nextOperation.ownedEntities, found.cleanupEntities or found.infrastructure)
		end
		if #(nextOperation.ownedEntities or {}) > 0 then
			return true, startCleanup(nextOperation, failure)
		end
		return false, nextOperation, failure
	end
	if acceptedStage == "cleanup" then
		table.remove(nextOperation.cleanupQueue, 1)
		nextOperation.preview = nil
		nextOperation.awaitingStage = nil
		if #(nextOperation.cleanupQueue or {}) > 0 then
			nextOperation.stage = "cleanup"
		else
			nextOperation.stage = "cleanup_done"
		end
		return true, nextOperation
	end
	local found, identifyError = identify(player, result.entities, kind)
	if not found then
		local failed = copyOperation(nextOperation)
		failed.cleanupIncomplete = true
		failed.cleanupError = identifyError
		return false, failed, "built_entities_unidentified:" .. tostring(identifyError)
	end
	nextOperation.ownedEntities = nextOperation.ownedEntities or {}
	if found.cleanupEntities then
		appendUnique(nextOperation.ownedEntities, found.cleanupEntities)
	elseif kind == "stop" then
		-- Remove station children before their owning station-group entity.
		appendUnique(nextOperation.ownedEntities, found.stationGroups)
		appendUnique(nextOperation.ownedEntities, found.infrastructure)
	else
		-- Remove depot children before their owning construction entity.
		appendUnique(nextOperation.ownedEntities, found.infrastructure)
		appendUnique(nextOperation.ownedEntities, found.depots)
	end
	local ok, err, charged = charge(nextOperation, result.cost)
	if not ok then
		if #nextOperation.ownedEntities > 0 then return true, startCleanup(nextOperation, err) end
		return false, nextOperation, err
	end
	nextOperation = charged
	if kind == "stop" then
		local groups = found.stationGroups or found.stations or {}
		if #groups ~= 1 then return true, startCleanup(nextOperation, "stop_station_group_not_unique") end
		nextOperation.stops = nextOperation.stops or {}
		nextOperation.stops[#nextOperation.stops + 1] = groups[1]
		nextOperation.infrastructure = nextOperation.infrastructure or {}
		for _, entity in ipairs(found.infrastructure or {}) do
			nextOperation.infrastructure[#nextOperation.infrastructure + 1] = entity
		end
		if acceptedStage == "stop_a" then
			nextOperation = setStage(nextOperation, "stop_b")
		else
			nextOperation = setStage(nextOperation, "depot")
		end
	else
		local depots = found.depots or found.depotEntities or {}
		if #depots ~= 1 then return true, startCleanup(nextOperation, "depot_entity_not_unique") end
		nextOperation.depot = depots[1]
		nextOperation.infrastructure = nextOperation.infrastructure or {}
		for _, entity in ipairs(found.infrastructure or {}) do
			nextOperation.infrastructure[#nextOperation.infrastructure + 1] = entity
		end
		local connected, pathError = routeConnections(nextOperation)
		if not connected then return true, startCleanup(nextOperation, pathError) end
		nextOperation = setStage(nextOperation, "create_line")
	end
	nextOperation.awaitingStage = nil
	return true, nextOperation
end

local function createLine(player, operation, done)
	if #((operation.stops) or {}) ~= 2 or not operation.depot then
		safeCall(done, false, operation, nil, "route_assets_incomplete")
		return
	end
	local line = api.type.Line.new()
	line.stops = {}
	for _, group in ipairs(operation.stops) do
		local stop = api.type.Line.Stop.new()
		stop.stationGroup = group
		local selection = operation.selectedStops and operation.selectedStops[#line.stops + 1] or { station = 0, terminal = 0 }
		stop.station = selection.station
		stop.terminal = selection.terminal
		line.stops[#line.stops + 1] = stop
	end
	local name = operation.name or "Linha rival"
	local color = api.type.Vec3f.new(0.15, 0.55, 0.95)
	local before = {}
	for _, entity in ipairs(ownedPlayerLines(player)) do before[entity] = true end
	local sent, sendError = sendNow(api.cmd.makeLineCreateCmd(name, color, player, line))
	if not sent then
		local unresolved = copyOperation(operation)
		unresolved.stage = "command_indeterminate"
		unresolved.indeterminateCommand = "create_line"
		unresolved.indeterminateReason = "command_error:" .. tostring(sendError)
		safeCall(done, true, unresolved, nil)
		return
	end
	local matches = {}
	for _, entity in ipairs(ownedPlayerLines(player)) do
		if not before[entity] and isOwnedBy(entity, player) and lineMatches(entity, operation) then
			matches[#matches + 1] = entity
		end
	end
	if #matches ~= 1 then
		local unresolved = copyOperation(operation)
		unresolved.stage = "command_indeterminate"
		unresolved.indeterminateCommand = "create_line"
		unresolved.indeterminateReason = #matches == 0 and "line_creation_not_observed" or "created_line_not_unique"
		safeCall(done, true, unresolved, nil)
		return
	end
	local nextOperation = copyOperation(operation)
	nextOperation.line = matches[1]
	nextOperation.stage = "buy"
	safeCall(done, true, nextOperation, nil)
end

-- One serialized transition/command per controller update. Preview work is
-- requested through a GUI event; no proposal userdata is stored in save state.
function routes.stepBuild(player, operation, done)
	if type(operation) ~= "table" or type(player) ~= "number" then
		safeCall(done, false, operation, nil, "build_operation_invalid")
		return
	end
	if operation.stage == "command_indeterminate" then
		safeCall(done, false, operation, nil, "command_result_indeterminate")
		return
	end
	local gate = routes.readiness()
	if not gate.automaticPlacement then
		safeCall(done, false, operation, nil, gate.reason)
		return
	end
	if operation.previewResult then
		local ok, nextOperation, err = routes.acceptPreview(player, operation, operation.previewResult)
		if not ok then safeCall(done, false, nextOperation, nil, err); return end
		safeCall(done, true, nextOperation, nil)
		return
	end
	if stopStage(operation.stage) or operation.stage == "depot" then
		if operation.preview then safeCall(done, true, operation, nil); return end
		local nextOperation = copyOperation(operation)
		local intent = stageIntent(nextOperation)
		if not intent or type(intent.resource) ~= "string" then
			safeCall(done, false, operation, nil, "build_stage_intent_invalid"); return
		end
		nextOperation.preview = { token = stageToken(operation), intent = intent,
		budget = { remaining = budgetRemaining(operation), reserve = operation.budget and operation.budget.reserve,
			busCost = operation.budget and operation.budget.busCost } }
		nextOperation.stage = "awaiting_preview"
		nextOperation.awaitingStage = operation.stage
		safeCall(done, true, nextOperation, nil)
		return
	end
	if operation.stage == "awaiting_preview" then
		if operation.preview then safeCall(done, true, operation, nil); return end
		local nextOperation = copyOperation(operation)
		nextOperation.stage = nextOperation.awaitingStage
		nextOperation.awaitingStage = nil
		nextOperation.preview = { token = stageToken(nextOperation), intent = stageIntent(nextOperation),
			budget = { remaining = budgetRemaining(nextOperation), reserve = nextOperation.budget and nextOperation.budget.reserve,
				busCost = nextOperation.budget and nextOperation.budget.busCost } }
		nextOperation.stage = "awaiting_preview"
		safeCall(done, true, nextOperation, nil)
		return
	end
	if operation.stage == "create_line" then createLine(player, operation, done); return end
	if operation.stage == "buy" then
		local budget = operation.budget or {}
		local native = nativeModule()
		if not validLineAndDepot(player, operation) then
			local failed = copyOperation(operation)
			if not isOwnedBy(operation.line, player) then failed.unverifiedCreatedLine, failed.line = operation.line, nil end
			if not isOwnedBy(operation.depot, player) then failed.unverifiedCreatedDepot, failed.depot = operation.depot, nil end
			failBuild(failed, "build_target_not_owned", done)
			return
		end
		local candidate, candidateError = busCandidate(operation.modelId, native)
		if not candidate or not candidate.config then failBuild(operation, candidateError, done); return end
		if type(budget.busCost) == "number" and candidate.purchaseCost ~= budget.busCost
			or type(budget.busMonthlyCost) == "number" and candidate.runningCost / 12 ~= budget.busMonthlyCost then
			failBuild(operation, "vehicle_quote_changed", done); return
		end
		local balance = native and type(native.balance) == "function" and native.balance(player) or nil
		local reserve = budget.reserve or 0
		if candidate.purchaseCost > budgetRemaining(operation)
			or type(balance) ~= "number" or balance - candidate.purchaseCost < reserve then
			failBuild(operation, "vehicle_purchase_exceeds_route_budget", done); return
		end
		local before = {}
		for _, entity in ipairs(depotVehicles(operation.depot)) do before[entity] = true end
		local sent, sendError = sendNow(api.cmd.makeVehicleBuyCmd(player, operation.depot, candidate.config))
		if not sent then
			local unresolved = copyOperation(operation)
			unresolved.stage = "command_indeterminate"
			unresolved.indeterminateCommand = "buy_vehicle"
			unresolved.indeterminateReason = "command_error:" .. tostring(sendError)
			safeCall(done, true, unresolved, nil)
			return
		end
		local matches = {}
		for _, entity in ipairs(depotVehicles(operation.depot)) do
			if not before[entity] and vehicleIsOwned(player, entity)
				and component(entity, api.type.ComponentType.TRANSPORT_VEHICLE).depot == operation.depot then
				matches[#matches + 1] = entity
			end
		end
		if #matches ~= 1 then
			local unresolved = copyOperation(operation)
			unresolved.stage = "command_indeterminate"
			unresolved.indeterminateCommand = "buy_vehicle"
			unresolved.indeterminateReason = #matches == 0 and "purchased_vehicle_not_observed" or "purchased_vehicle_not_unique"
			safeCall(done, true, unresolved, nil)
			return
		end
		local nextOperation = copyOperation(operation)
		nextOperation.budget = copyOperation(budget)
		if type(nextOperation.budget.remaining) == "number" then
			nextOperation.budget.remaining = math.max(0, nextOperation.budget.remaining - candidate.purchaseCost)
		end
		nextOperation.vehicle = matches[1]
		nextOperation.stage = "assign"
		safeCall(done, true, nextOperation, nil)
		return
	end
	if operation.stage == "assign" then
		if not validLineAndDepot(player, operation) then
			local failed = copyOperation(operation)
			if not isOwnedBy(operation.line, player) then failed.unverifiedCreatedLine, failed.line = operation.line, nil end
			if not isOwnedBy(operation.depot, player) then failed.unverifiedCreatedDepot, failed.depot = operation.depot, nil end
			failBuild(failed, "build_target_not_owned", done)
			return
		end
		if not vehicleIsOwned(player, operation.vehicle)
			or component(operation.vehicle, api.type.ComponentType.TRANSPORT_VEHICLE).depot ~= operation.depot then
			local failed = copyOperation(operation)
			if not vehicleIsOwned(player, operation.vehicle) then failed.unverifiedCreatedVehicle, failed.vehicle = operation.vehicle, nil end
			failBuild(failed, "purchased_vehicle_not_in_expected_depot", done)
			return
		end
		local sent, sendError = sendNow(api.cmd.makeVehicleSetLineCmd(operation.vehicle, operation.line, 0))
		local vehicle = component(operation.vehicle, api.type.ComponentType.TRANSPORT_VEHICLE)
		if not sent or not vehicle or vehicle.line ~= operation.line then
			failBuild(operation, "vehicle_line_assignment_failed:" .. tostring(sendError or "assignment_not_observed"), done)
			return
		end
		local route = { key = operation.key, name = operation.name, line = operation.line,
			depot = operation.depot, infrastructure = operation.infrastructure or {}, vehicles = 1 }
		safeCall(done, true, nil, route)
		return
	end
	if operation.stage == "cleanup" then
		local cleanup = copyOperation(operation)
		cleanup.cleanupQueue = cleanup.cleanupQueue or {}
		while #cleanup.cleanupQueue > 0 and not api.engine.entityExists(cleanup.cleanupQueue[1]) do
			table.remove(cleanup.cleanupQueue, 1)
		end
		if #cleanup.cleanupQueue == 0 then
			local failed = cleanup
			failed.stage = "cleanup_done"
			safeCall(done, true, failed, nil)
		else
			safeCall(done, true, queueCleanupPreview(cleanup), nil)
		end
		return
	end
	if operation.stage == "cleanup_sell_vehicle" then
		if not vehicleIsOwned(player, operation.vehicle) then
			safeCall(done, false, operation, nil, "cleanup_vehicle_not_owned")
			return
		end
		local sent, err = sendNow(api.cmd.makeVehicleSellCmd({ operation.vehicle }))
		if not sent or api.engine.entityExists(operation.vehicle) then
			safeCall(done, false, operation, nil, "cleanup_vehicle_sale_failed:" .. tostring(err or "sale_not_observed")); return
		end
		local nextOperation = copyOperation(operation)
		nextOperation.vehicle = nil
		nextOperation.stage = nextOperation.line and "cleanup_destroy_line" or "cleanup"
		safeCall(done, true, nextOperation, nil)
		return
	end
	if operation.stage == "cleanup_destroy_line" then
		if not isOwnedBy(operation.line, player) then
			safeCall(done, false, operation, nil, "cleanup_line_not_owned")
			return
		end
		local sent, err = sendNow(api.cmd.makeLineDestroyCmd(operation.line))
		if not sent or component(operation.line, api.type.ComponentType.LINE) then
			safeCall(done, false, operation, nil, "cleanup_line_destroy_failed:" .. tostring(err or "destroy_not_observed")); return
		end
		local nextOperation = copyOperation(operation)
		nextOperation.line = nil
		nextOperation.stage = "cleanup"
		safeCall(done, true, nextOperation, nil)
		return
	end
	if operation.stage == "cleanup_done" then
		local completed = copyOperation(operation)
		completed.cleanupComplete = true
		safeCall(done, false, completed, nil, "build_cleanup_complete:" .. tostring(operation.cleanupError))
		return
	end
	safeCall(done, false, operation, nil, "unknown_build_stage:" .. tostring(operation.stage))
end

validLineAndDepot = function(player, operation)
	if type(operation.line) ~= "number" or type(operation.depot) ~= "number"
		or not isOwnedBy(operation.line, player) or not isOwnedBy(operation.depot, player) then
		return false
	end
	local line = component(operation.line, api.type.ComponentType.LINE)
	local depot = component(operation.depot, api.type.ComponentType.VEHICLE_DEPOT)
 	return line ~= nil and depot ~= nil
end

vehicleIsOwned = function(player, vehicleEntity)
	return type(vehicleEntity) == "number"
		and component(vehicleEntity, api.type.ComponentType.TRANSPORT_VEHICLE) ~= nil
		and isOwnedBy(vehicleEntity, player)
end

local function issueSendToDepot(player, operation, vehicleEntity, done)
	if not vehicleIsOwned(player, vehicleEntity) then
		safeCall(done, false, operation, "vehicle_not_owned")
		return
	end
	local vehicle = component(vehicleEntity, api.type.ComponentType.TRANSPORT_VEHICLE)
	if vehicle.line ~= operation.line then
		safeCall(done, false, operation, "vehicle_not_on_expected_line")
		return
	end
	local nextOperation = {}
	for key, value in pairs(operation) do nextOperation[key] = value end
	nextOperation.phase = "wait_sell"
	nextOperation.vehicle = vehicleEntity
	local command
	local sellingNow = vehicle.depot == operation.depot
	if sellingNow then
		command = api.cmd.makeVehicleSellCmd({ vehicleEntity })
	else
		command = api.cmd.makeVehicleSendToDepotCmd(vehicleEntity, true)
	end
	local sent, err = sendNow(command)
	local exists = api.engine.entityExists(vehicleEntity)
	local validOutcome = sellingNow and not exists
		or (not sellingNow and exists and vehicleIsOwned(player, vehicleEntity))
	if not sent or not validOutcome then
		safeCall(done, false, operation, "vehicle_send_to_depot_failed:" .. tostring(err or "command_outcome_not_observed"))
		return
	end
	safeCall(done, true, nextOperation, nil)
end

-- Handles one discrete fleet command per controller update. The operation is
-- a serializable state machine so reloads do not repeat purchases or sales.
function routes.stepManage(player, operation, done)
	if type(operation) ~= "table" or type(player) ~= "number"
		or not validLineAndDepot(player, operation) then
		safeCall(done, false, operation, "management_target_not_owned")
		return
	end

	local action = operation.action
	if action == "buy" then
		if operation.phase == "purchase_indeterminate" then
			safeCall(done, false, operation, "purchase_result_indeterminate")
			return
		end
		if operation.phase == "assign" then
			local vehicleEntity = operation.vehicle
			if not vehicleIsOwned(player, vehicleEntity)
				or component(vehicleEntity, api.type.ComponentType.TRANSPORT_VEHICLE).depot ~= operation.depot then
				safeCall(done, false, operation, "purchased_vehicle_not_in_expected_depot")
				return
			end
			local line = component(operation.line, api.type.ComponentType.LINE)
			if #line.stops < 2 then
				safeCall(done, false, operation, "line_has_fewer_than_two_stops")
				return
			end
			local sent, err = sendNow(api.cmd.makeVehicleSetLineCmd(vehicleEntity, operation.line, 0))
			local assigned = component(vehicleEntity, api.type.ComponentType.TRANSPORT_VEHICLE)
			if not sent or not assigned or assigned.line ~= operation.line then
				safeCall(done, false, operation, "vehicle_line_assignment_failed:" .. tostring(err or "assignment_not_observed"))
				return
			end
			safeCall(done, true, nil, nil)
			return
		end
		local native = nativeModule()
		local candidate, candidateError = busCandidate(operation.modelId, native)
		if not candidate or not candidate.config then
			safeCall(done, false, operation, candidateError)
			return
		end
		if type(operation.purchaseCost) == "number" and candidate.purchaseCost ~= operation.purchaseCost then
			safeCall(done, false, operation, "vehicle_quote_changed")
			return
		end
		local snapshot = native and type(native.snapshot) == "function" and native.snapshot(player) or nil
		local balance = native and type(native.balance) == "function" and native.balance(player) or nil
		local policy = policyModule()
		if not snapshot or not finiteNumber(snapshot.monthlyCost) or not finiteNumber(balance)
			or not finiteNumber(candidate.purchaseCost) or not finiteNumber(candidate.runningCost)
			or not policy or type(policy.canSpend) ~= "function" then
			safeCall(done, false, operation, "vehicle_affordability_unavailable")
			return
		end
		local newMonthlyCost = snapshot.monthlyCost + candidate.runningCost / 12
		if not policy.canSpend(balance, newMonthlyCost, candidate.purchaseCost, true) then
			safeCall(done, false, operation, "insufficient_funds_after_reserve")
			return
		end
		local before = {}
		for _, entity in ipairs(depotVehicles(operation.depot)) do before[entity] = true end
		local sent, sendError = sendNow(api.cmd.makeVehicleBuyCmd(player, operation.depot, candidate.config))
		if not sent then
			local unresolved = copyOperation(operation)
			unresolved.phase = "purchase_indeterminate"
			unresolved.indeterminateReason = "command_error:" .. tostring(sendError)
			safeCall(done, false, unresolved, "purchase_result_indeterminate")
			return
		end
		local matches = {}
		for _, entity in ipairs(depotVehicles(operation.depot)) do
			if not before[entity] and vehicleIsOwned(player, entity)
				and component(entity, api.type.ComponentType.TRANSPORT_VEHICLE).depot == operation.depot then
				matches[#matches + 1] = entity
			end
		end
		if #matches ~= 1 then
			local unresolved = copyOperation(operation)
			unresolved.phase = "purchase_indeterminate"
			unresolved.indeterminateReason = #matches == 0 and "purchased_vehicle_not_observed" or "purchased_vehicle_not_unique"
			safeCall(done, false, unresolved, "purchase_result_indeterminate")
			return
		end
		local nextOperation = {}
		for key, value in pairs(operation) do nextOperation[key] = value end
		nextOperation.phase = "assign"
		nextOperation.vehicle = matches[1]
		safeCall(done, true, nextOperation, nil)
		return
	end

	if action == "sell" then
		if operation.phase == "wait_sell" then
			if api.engine.entityExists(operation.vehicle) then
				safeCall(done, true, operation, nil)
			else
				safeCall(done, true, nil, nil)
			end
			return
		end
		local vehicles = api.engine.system.transportVehicleSystem.getLineVehicles(operation.line) or {}
		local target
		for index = #vehicles, 1, -1 do
			if vehicleIsOwned(player, vehicles[index]) then target = vehicles[index]; break end
		end
		if not target then
			safeCall(done, true, nil, nil)
			return
		end
		issueSendToDepot(player, operation, target, done)
		return
	end

	if action == "close" then
		if operation.phase == "send_vehicles" then
			local remaining = operation.sendQueue or {}
			local vehicleEntity = remaining[1]
			if not vehicleEntity then
				local nextOperation = {}
				for key, value in pairs(operation) do nextOperation[key] = value end
				nextOperation.phase = "wait_sell"
				safeCall(done, true, nextOperation, nil)
				return
			end
			local vehicle = component(vehicleEntity, api.type.ComponentType.TRANSPORT_VEHICLE)
			if not vehicleIsOwned(player, vehicleEntity) or not vehicle or vehicle.line ~= operation.line then
				safeCall(done, false, operation, "vehicle_changed_during_close")
				return
			end
			local nextOperation = {}
			for key, value in pairs(operation) do nextOperation[key] = value end
			nextOperation.sendQueue = {}
			for index = 2, #remaining do nextOperation.sendQueue[#nextOperation.sendQueue + 1] = remaining[index] end
			local sellingNow = vehicle.depot == operation.depot
			local command = sellingNow
				and api.cmd.makeVehicleSellCmd({ vehicleEntity })
				or api.cmd.makeVehicleSendToDepotCmd(vehicleEntity, true)
			local sent, err = sendNow(command)
			local exists = api.engine.entityExists(vehicleEntity)
			local validOutcome = sellingNow and not exists
				or (not sellingNow and exists and vehicleIsOwned(player, vehicleEntity))
			if not sent or not validOutcome then
				safeCall(done, false, operation, "vehicle_send_to_depot_failed:" .. tostring(err or "command_outcome_not_observed"))
				return
			end
			safeCall(done, true, nextOperation, nil)
			return
		end
		if operation.phase == "wait_sell" then
			for _, vehicleEntity in ipairs(operation.vehicles or {}) do
				if api.engine.entityExists(vehicleEntity) then
					safeCall(done, true, operation, nil)
					return
				end
			end
			local nextOperation = {}
			for key, value in pairs(operation) do nextOperation[key] = value end
			nextOperation.phase = "destroy_line"
			safeCall(done, true, nextOperation, nil)
			return
		elseif operation.phase == "destroy_line" then
			if not isOwnedBy(operation.line, player) then
				safeCall(done, false, operation, "line_not_owned_for_close")
				return
			end
			local sent, err = sendNow(api.cmd.makeLineDestroyCmd(operation.line))
			if not sent or component(operation.line, api.type.ComponentType.LINE) then
				safeCall(done, false, operation, "line_destroy_failed:" .. tostring(err or "destroy_not_observed"))
				return
			end
			safeCall(done, true, nil, nil)
			return
		end

		local vehicles = api.engine.system.transportVehicleSystem.getLineVehicles(operation.line) or {}
		if #vehicles == 0 then
			local nextOperation = {}
			for key, value in pairs(operation) do nextOperation[key] = value end
			nextOperation.phase = "destroy_line"
			safeCall(done, true, nextOperation, nil)
			return
		end
		local ownedVehicles = {}
		for _, vehicleEntity in ipairs(vehicles) do
			if not vehicleIsOwned(player, vehicleEntity) then
				safeCall(done, false, operation, "line_has_vehicle_not_owned_by_rival")
				return
			end
			ownedVehicles[#ownedVehicles + 1] = vehicleEntity
		end
		local nextOperation = {}
		for key, value in pairs(operation) do nextOperation[key] = value end
		nextOperation.vehicles = ownedVehicles
		nextOperation.sendQueue = ownedVehicles
		nextOperation.phase = "send_vehicles"
		safeCall(done, true, nextOperation, nil)
		return
	end

	safeCall(done, false, operation, "unknown_management_action")
end

return routes
