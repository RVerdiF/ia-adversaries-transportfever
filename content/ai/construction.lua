-- Construction proposal adapter. Preview and application are performed by the GUI bridge.
local construction = {}
local native
if type(ug_require) == "function" then
	local ok, value = pcall(ug_require, "pichau_competitor_ai::/ai/native.lua")
	if ok then native = value end
end

local function finite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end
local function component(entity, kind)
	if type(entity) ~= "number" or entity < 0 or kind == nil then return nil end
	return api.engine.getComponent(entity, kind)
end
local function ownedBy(entity, player)
	local own = component(entity, api.type.ComponentType.PLAYER_OWNED)
	return own ~= nil and own.player == player
end
local function edgeId(edge) return type(edge) == "table" and (edge.entity or edge.id) or edge end
local function currentRevision(entity)
	if api.engine.getRevision ~= nil then
		local ok, value = pcall(api.engine.getRevision, entity)
		if ok then return value end
	end
end
local function sameRevision(current, expected)
	local currentType, expectedType = type(current), type(expected)
	local a = (currentType == "table" or currentType == "userdata") and current.num or current
	local b = (expectedType == "table" or expectedType == "userdata") and expected.num or expected
	local aType, bType = type(a), type(b)
	if (aType == "table" or aType == "userdata") and (bType == "table" or bType == "userdata") then
		return a[1] == b[1] and a[2] == b[2]
	end
	return current == expected
end
local function stationGroupForStation(player, stationEntity)
	local systems = api.engine.system
	local stationGroups = systems and systems.stationGroupSystem
	local getGroup = stationGroups and stationGroups.getStationGroup
	if type(getGroup) ~= "function" then return nil end
	local ok, groupEntity = pcall(getGroup, stationEntity)
	if not ok or type(groupEntity) ~= "number" or groupEntity < 0
		or not ownedBy(groupEntity, player) then return nil end
	local group = component(groupEntity, api.type.ComponentType.STATION_GROUP)
	if not group then return nil end
	for _, member in ipairs(group.stations or {}) do
		local ownership = component(member, api.type.ComponentType.PLAYER_OWNED)
		if not ownership then
			local connector = systems.streetConnectorSystem
			local callback = connector and connector.getConstructionEntityForStation
			if callback ~= nil then
				local parentOk, parent = pcall(callback, member)
				if parentOk and type(parent) == "number" and parent >= 0 then
					ownership = component(parent, api.type.ComponentType.PLAYER_OWNED)
				end
			end
		end
		if ownership and ownership.player ~= player then return nil end
	end
	return groupEntity
end
local function edgeCurrent(intent)
	if intent.kind ~= "stop" then return true end
	local id = edgeId(intent.edge)
	if type(id) ~= "number" or not api.engine.entityExists(id) then return false end
	local expected = intent.edgeRevision
	if expected == nil and type(intent.edge) == "table" then expected = intent.edge.revision end
	return expected == nil or sameRevision(currentRevision(id), expected)
end
local function stopAsset(year)
	if year < 1920 then return "::/street/small_stops/small_old.con" end
	if year < 1980 then return "::/street/small_stops/small_mid.con" end
	return "::/street/small_stops/small_new.con"
end

local function makeStop(player, intent)
	local id = edgeId(intent.edge)
	local edge = component(id, api.type.ComponentType.BASE_EDGE)
	local street = component(id, api.type.ComponentType.BASE_EDGE_STREET)
	local hasPlayerOwnedObject = false
	for _, object in ipairs(edge and edge.objects or {}) do
		local objectEntity = type(object) == "table" and (object[1] or object.entity) or object
		if type(objectEntity) ~= "number"
			or component(objectEntity, api.type.ComponentType.PLAYER_OWNED) ~= nil then
			hasPlayerOwnedObject = true
			break
		end
	end
	if not edge or not street or edge.roadType ~= api.type.enum.RoadType.STREET
		or edge.type ~= api.type.enum.BaseEdgeType.NORMAL
		or (edge.distance or 0) < 20
		or hasPlayerOwnedObject
		or component(id, api.type.ComponentType.PLAYER_OWNED) ~= nil then return nil, "unsafe_stop_edge" end
	if not edgeCurrent(intent) then return nil, "source_edge_changed" end
	local asset = stopAsset(api.engine.util.getYear())
	if native and type(native.canBuildResource) == "function" then
		local allowed, why = native.canBuildResource(player, asset)
		if not allowed then return nil, why or "stop_resource_not_allowed" end
	end
	local replacement = api.type.SegmentAndEntity.new()
	-- Clone the complete municipal edge so existing attached objects and town
	-- development metadata carry over to the replacement. Preview remains the
	-- collision gate before the proposal is applied.
	replacement.entity, replacement.comp, replacement.type, replacement.streetEdge = -1, edge:clone(), 0, street
	local streetProposal = api.type.SimpleStreetProposal.new()
	streetProposal.edgesToRemove, streetProposal.edgesToAdd = { id }, { replacement }
	local stop = api.type.SimpleStreetProposal.EdgeObject.new()
	stop.edgeEntity, stop.param, stop.oneWay, stop.left = -1, 0.5, false, false
	stop.model, stop.playerEntity, stop.name = asset, player, intent.name or ""
	streetProposal.edgeObjectsToAdd = { stop }
	local proposal = api.type.SimpleProposal.new()
	proposal.streetProposal = streetProposal
	return proposal
end

local function makeBuild(player, intent)
	local resource = intent.resource
	if type(resource) ~= "string" or resource == "" then return nil, "construction_resource_missing" end
	local id = api.res.constructionRep.find(resource)
	if type(id) ~= "number" or id < 0 or not api.res.constructionRep.get(id) then return nil, "construction_resource_missing" end
	if native and type(native.canBuildResource) == "function" then
		local ok, why = native.canBuildResource(player, resource)
		if not ok then return nil, why or "construction_resource_not_allowed" end
	end
	local site = intent.site
	if type(site) ~= "table" or not finite(site.x) or not finite(site.y)
		or not finite(site.z or 0) or not finite(site.heading or 0) then return nil, "invalid_construction_site" end
	local angle, c, s = site.heading or 0, math.cos(site.heading or 0), math.sin(site.heading or 0)
	local transf = api.type.Mat4f.new(
		api.type.Vec4f.new(c, s, 0, 0), api.type.Vec4f.new(-s, c, 0, 0),
		api.type.Vec4f.new(0, 0, 1, 0), api.type.Vec4f.new(site.x, site.y, site.z or 0, 1))
	local item = api.type.SimpleProposal.ConstructionEntity.new()
	item.fileName, item.params, item.transf = resource, intent.params or {}, transf
	item.name, item.playerEntity, item.autoFillSlots = intent.name or "", player, false
	local proposal = api.type.SimpleProposal.new()
	proposal.constructionsToAdd = { item }
	return proposal
end

function construction.makeProposal(player, intent)
	if type(player) ~= "number" or type(intent) ~= "table" then return nil, "invalid_arguments" end
	if intent.kind == "stop" then return makeStop(player, intent) end
	if intent.kind == "depot" then return makeBuild(player, intent) end
	if intent.kind == "remove" then
		local target = intent.entity
		if type(target) ~= "number" or not api.engine.entityExists(target) then return nil, "remove_target_missing" end
		if not ownedBy(target, player) then return nil, "remove_target_not_owned" end
		local context = api.type.Context.new()
		context.player = player
		local proposal = api.engine.util.proposal.createProposalRemove(target, context)
		if not proposal then return nil, "remove_proposal_unavailable" end
		return proposal
	end
	return nil, "unknown_construction_kind"
end

local function addUnique(out, seen, entity)
	if type(entity) == "number" and not seen[entity] then seen[entity] = true; out[#out + 1] = entity end
end
local function removals(proposal)
	local out, seen = {}, {}
	for _, id in ipairs(proposal.toRemove or {}) do addUnique(out, seen, id) end
	local street = proposal.streetProposal or proposal.proposal or {}
	for _, id in ipairs(street.edgesToRemove or {}) do addUnique(out, seen, id) end
	for _, item in ipairs(street.removedSegments or {}) do addUnique(out, seen, item.entity) end
	for _, item in ipairs(street.removedNodes or {}) do addUnique(out, seen, item.entity) end
	for _, id in ipairs(street.nodeConfigsToRemove or {}) do addUnique(out, seen, id) end
	for _, id in ipairs(proposal.constructionsToRemove or {}) do addUnique(out, seen, id) end
	return out
end
local function removalAllowed(player, intent, entity)
	if intent.kind == "stop" and entity == edgeId(intent.edge) then return component(entity, api.type.ComponentType.PLAYER_OWNED) == nil end
	return ownedBy(entity, player)
end
local function validateSource(player, intent)
	if intent.kind == "stop" then
		local id = edgeId(intent.edge)
		local edge = component(id, api.type.ComponentType.BASE_EDGE)
		if not edgeCurrent(intent) or not edge or not component(id, api.type.ComponentType.BASE_EDGE_STREET)
			or component(id, api.type.ComponentType.PLAYER_OWNED) ~= nil or #(edge.objects or {}) > 0 then return false, "source_edge_changed" end
	elseif intent.kind == "remove" and (not api.engine.entityExists(intent.entity) or not ownedBy(intent.entity, player)) then
		return false, "remove_target_not_owned"
	end
	return true
end

function construction.validatePreview(player, intent, proposal, data, budget)
	local proposalType, dataType = type(proposal), type(data)
	if type(player) ~= "number" or type(intent) ~= "table"
		or (proposalType ~= "table" and proposalType ~= "userdata")
		or (dataType ~= "table" and dataType ~= "userdata") then return false, "invalid_preview_arguments" end
	local ok, why = validateSource(player, intent)
	if not ok then return false, why end
	local errors = data.errorState
	if errors == nil or data.collisionInfo == nil then return false, "preview_data_incomplete" end
	if errors and errors.critical then return false, "preview_critical_error" end
	if errors and #(errors.messages or {}) > 0 then return false, "preview_error" end
	local collision = data.collisionInfo or {}
	if #(collision.buildingEntities or {}) > 0 then return false, "preview_would_demolish_building" end
	for entity in pairs(collision.autoRemovalEntity2models or {}) do
		if not removalAllowed(player, intent, entity) then return false, "preview_auto_removes_unexpected_entity" end
	end
	for _, entity in ipairs(removals(proposal)) do
		if not removalAllowed(player, intent, entity) then return false, "preview_removes_unexpected_entity" end
	end
	for _, entry in ipairs(collision.collisionEntities or {}) do
		local entity = type(entry) == "table" and entry.entity or entry
		local owner = component(entity, api.type.ComponentType.PLAYER_OWNED)
		if owner and owner.player ~= player then return false, "preview_foreign_entity_collision" end
	end
	local cost = data.costs
	if not finite(cost) then return false, "preview_cost_unavailable", cost end
	local available, reserve, busCost
	if type(budget) == "number" then available, reserve, busCost = budget, 0, 0
	elseif type(budget) == "table" then
		available = budget.remaining or budget.maxSpend or budget.balance or budget.available
		reserve, busCost = budget.reserve or 0, budget.busCost or 0
	end
	local spend = math.max(cost, 0)
	if not finite(available) or not finite(reserve) or not finite(busCost)
		or reserve < 0 or busCost < 0 or (spend > 0 and spend > available - busCost) then
		return false, "preview_over_budget", cost
	end
	if spend > 0 and native and type(native.balance) == "function" then
		local liveBalance = native.balance(player)
		if not finite(liveBalance) or liveBalance - spend < reserve + busCost then
			return false, "preview_over_budget", cost
		end
	end
	return true, nil, cost
end

function construction.identifyEntities(player, resultEntities, kind)
	local out = { stationGroups = {}, depots = {}, infrastructure = {}, cleanupEntities = {} }
	local seen, seenGroups, seenInfrastructure, seenDepots, seenCleanup = {}, {}, {}, {}, {}
	local function add(list, values, id)
		if id and not values[id] then values[id] = true; list[#list + 1] = id end
	end
	local function addCleanup(id)
		if not ownedBy(id, player) then return end
		if not component(id, api.type.ComponentType.CONSTRUCTION)
			and not component(id, api.type.ComponentType.EDGE_OBJECT) then return end
		add(out.cleanupEntities, seenCleanup, id)
	end
	local function constructionForChild(child, method)
		local system = api.engine.system and api.engine.system.streetConnectorSystem
		local callback = system and system[method]
		if callback == nil then return nil end
		local ok, parent = pcall(callback, child)
		if ok and type(parent) == "number" and parent >= 0 and ownedBy(parent, player)
			and component(parent, api.type.ComponentType.CONSTRUCTION) then return parent end
		return nil
	end
	local function inspectOwned(entity)
		if not api.engine.entityExists(entity) or not ownedBy(entity, player) then return end
		local group = component(entity, api.type.ComponentType.STATION_GROUP)
		local station = component(entity, api.type.ComponentType.STATION)
		local depot = component(entity, api.type.ComponentType.VEHICLE_DEPOT)
		local constructionEntity = component(entity, api.type.ComponentType.CONSTRUCTION)
		local edgeObject = component(entity, api.type.ComponentType.EDGE_OBJECT)
		if (kind == "stop" or kind == "station") and group then
			add(out.stationGroups, seenGroups, entity)
		elseif (kind == "stop" or kind == "station") and station then
			add(out.stationGroups, seenGroups, stationGroupForStation(player, entity))
		end
		if depot and (kind == "depot" or kind == nil) then
			add(out.depots, seenDepots, entity)
			add(out.infrastructure, seenInfrastructure, entity)
			addCleanup(constructionForChild(entity, "getConstructionEntityForDepot"))
		end
		if constructionEntity and (kind == "depot" or kind == "construction" or kind == nil) then
			add(out.infrastructure, seenInfrastructure, entity)
			addCleanup(entity)
		end
		if station and (kind == "stop" or kind == "station") then
			add(out.infrastructure, seenInfrastructure, entity)
			addCleanup(constructionForChild(entity, "getConstructionEntityForStation"))
		end
		if group and (kind == "stop" or kind == "station") then
			add(out.infrastructure, seenInfrastructure, entity)
		end
		if edgeObject and (kind == "stop" or kind == "station" or kind == nil) then
			add(out.infrastructure, seenInfrastructure, entity)
			addCleanup(entity)
		end
		-- Parent construction lists are authoritative for discovering useful
		-- child entities when the command receipt contains only the parent.
		if constructionEntity then
			for _, child in ipairs(constructionEntity.depots or {}) do
				if component(child, api.type.ComponentType.VEHICLE_DEPOT) and (kind == "depot" or kind == nil) then
					add(out.depots, seenDepots, child)
					add(out.infrastructure, seenInfrastructure, child)
				end
			end
			for _, child in ipairs(constructionEntity.stations or {}) do
				if component(child, api.type.ComponentType.STATION) and (kind == "stop" or kind == "station") then
					add(out.infrastructure, seenInfrastructure, child)
					add(out.stationGroups, seenGroups, stationGroupForStation(player, child))
				end
			end
		end
	end
	for _, pair in ipairs(resultEntities or {}) do
		local entity = type(pair) == "table" and pair[1] or pair
		if type(entity) == "number" and entity >= 0 and not seen[entity] then
			seen[entity] = true
			-- A stop replacement can yield only its public street in the result
			-- list. Resolve edge objects independently; the street itself is never
			-- treated as rival-owned or as a cleanup target.
			local edge = component(entity, api.type.ComponentType.BASE_EDGE)
			for _, object in ipairs(edge and edge.objects or {}) do
				local child = type(object) == "table" and (object[1] or object.entity) or object
				if type(child) == "number" and ownedBy(child, player)
					and component(child, api.type.ComponentType.EDGE_OBJECT) then inspectOwned(child) end
			end
			inspectOwned(entity)
		end
	end
	return out
end

function construction.getStationGroup(entity, player)
	if component(entity, api.type.ComponentType.STATION_GROUP) then return entity end
	if component(entity, api.type.ComponentType.STATION) then return stationGroupForStation(player, entity) end
	return nil
end

return construction
