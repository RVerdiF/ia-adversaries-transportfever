-- Read-only town-pair and road-site planner. All mutations and construction
-- previews are owned by the route executor.
local planner = {}

local function finite(v)
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function xy(pos)
	if not pos then return nil end
	local x, y = pos.x or pos[1], pos.y or pos[2]
	if finite(x) and finite(y) then return x, y end
end

local function distance2(a, b)
	local ax, ay = xy(a)
	local bx, by = xy(b)
	if not ax or not bx then return math.huge end
	return (ax - bx) ^ 2 + (ay - by) ^ 2
end

local function atan2(y, x)
	if math.atan2 then return math.atan2(y, x) end
	if x > 0 then return math.atan(y / x) end
	if x < 0 and y >= 0 then return math.atan(y / x) + math.pi end
	if x < 0 and y < 0 then return math.atan(y / x) - math.pi end
	if y > 0 then return math.pi / 2 end
	if y < 0 then return -math.pi / 2 end
	return 0
end

local function component(entity, name)
	return api.engine.getComponent(entity, api.type.ComponentType[name])
end

local function townPopulation(entity)
	local usage = api.engine.util.town.getTownCapacityUsage(entity) or {}
	local population, weight, bestUse = 0, -1, nil
	for _, item in ipairs(usage) do
		if item and finite(item.used) and item.used >= 0 then population = population + item.used end
		if item and finite(item.capacity) and item.capacity > weight then
			weight, bestUse = item.capacity, item
		end
	end
	return population, bestUse
end

local function townCenter(entity, bestUse)
	local landUses = api.type.enum.LandUseType
	local order = { landUses.RESIDENTIAL, landUses.COMMERCIAL, landUses.INDUSTRIAL }
	local best = bestUse and bestUse.landUseType
	if best then
		local ok, center = pcall(api.engine.util.town.getTownDistrictCenter, entity, best)
		if ok and center then return center end
	end
	for _, use in ipairs(order) do
		local ok, center = pcall(api.engine.util.town.getTownDistrictCenter, entity, use)
		if ok and center and finite(center.x) and finite(center.y) then return center end
	end
	return nil
end

local function towns()
	local result = {}
	for _, entity in ipairs(api.engine.getEntitiesWithComponent(api.type.ComponentType.TOWN)) do
		local population, use = townPopulation(entity)
		local center = townCenter(entity, use)
		if population > 0 and center then
			result[#result + 1] = {
				entity = entity,
				name = api.engine.util.getEntityName(entity),
				population = population,
				center = center,
			}
		end
	end
	table.sort(result, function(a, b)
		if a.population ~= b.population then return a.population > b.population end
		return a.entity < b.entity
	end)
	return result
end

local function roadEdges(center, player, radius)
	local found = api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(center.x, center.y), radius,
		api.type.ComponentType.BASE_EDGE) or {}
	local result = {}
	for _, entity in ipairs(found) do
		local edge = component(entity, "BASE_EDGE")
		local street = component(entity, "BASE_EDGE_STREET")
		if edge and street and planner.isPublicPlainStreet(entity)
			and finite(edge.distance) and edge.distance >= 20 then
			result[#result + 1] = { entity = entity, data = edge }
		end
	end
	table.sort(result, function(a, b)
		local da = math.min(distance2(center, a.data.position0), distance2(center, a.data.position1))
		local db = math.min(distance2(center, b.data.position0), distance2(center, b.data.position1))
		if da ~= db then return da < db end
		return a.entity < b.entity
	end)
	while #result > 20 do table.remove(result) end
	return result
end

-- Town district centers can be several blocks away from a usable public road.
-- Expand only when the smaller search found no safe segment, keeping stops
-- close to town whenever a nearby candidate exists.
local function nearbySafeRoads(center, player, initialRadius, maximumRadius)
	local radius = finite(initialRadius) and initialRadius > 0 and initialRadius or 250
	local maxRadius = math.max(radius, finite(maximumRadius) and maximumRadius or 3000)
	while true do
		local result = roadEdges(center, player, radius)
		if #result > 0 or radius >= maxRadius then return result, radius end
		radius = math.min(radius * 2, maxRadius)
	end
end

function planner.isPublicPlainStreet(entity)
	local edge = component(entity, "BASE_EDGE")
	local street = component(entity, "BASE_EDGE_STREET")
	for _, object in ipairs(edge and edge.objects or {}) do
		local objectEntity = type(object) == "table" and (object[1] or object.entity) or object
		if type(objectEntity) ~= "number" or component(objectEntity, "PLAYER_OWNED") ~= nil then return false end
	end
	return edge ~= nil and street ~= nil
		and component(entity, "PLAYER_OWNED") == nil
		and edge.roadType == api.type.enum.RoadType.STREET
		and edge.type == api.type.enum.BaseEdgeType.NORMAL
		and finite(edge.distance) and edge.distance >= 20
end

local function nodeIdsNear(position, radius)
	local ids = api.engine.util.octree.findTransportNetworkNodesInCircle(
		api.type.Vec2f.new(position.x, position.y), radius) or {}
	local function nodeInfo(node)
		local network = node and node.entity
			and api.engine.getComponent(node.entity, api.type.ComponentType.TRANSPORT_NETWORK)
		if not network then return math.huge, true end
		for index, edge in ipairs(network.edges or {}) do
			for endpointIndex, endpointNode in ipairs(edge.transportModes and edge.transportModes[api.type.enum.TransportMode.BUS] and edge.conns or {}) do
				if endpointNode.entity == node.entity and endpointNode.index == node.index then
					local param = endpointIndex == 1 and 0 or 1
					local ok, sample = pcall(api.type.EdgeGeometry.calcPos, edge.geometry, param)
					local point = ok and sample and sample[1]
					if point then return distance2(point, position), true end
					return math.huge, true
				end
			end
		end
		return math.huge, false
	end
	local candidates = {}
	for _, node in ipairs(ids) do
		local distance, supportsBus = nodeInfo(node)
		if supportsBus then candidates[#candidates + 1] = {node=node,distance=distance} end
	end
	table.sort(candidates, function(a, b)
		if a.distance ~= b.distance then return a.distance < b.distance end
		local ae, be = tostring(a.node.entity), tostring(b.node.entity)
		if ae ~= be then return ae < be end
		return tostring(a.node.index) < tostring(b.node.index)
	end)
	local selected = {}
	for index=1,math.min(4,#candidates) do selected[#selected+1]=candidates[index].node end
	return selected
end

local function connectedBothWays(a, b, maxLength, pathBudget)
	local bSet = {}
	for _, node in ipairs(b) do
		if node.entity ~= nil and node.index ~= nil then
			bSet[tostring(node.entity) .. ":" .. tostring(node.index)] = true
		end
		if node.town ~= nil then bSet["town:" .. tostring(node.town)] = true end
	end
	for _, node in ipairs(a) do
		if (node.entity ~= nil and node.index ~= nil
			and bSet[tostring(node.entity) .. ":" .. tostring(node.index)])
			or (node.town ~= nil and bSet["town:" .. tostring(node.town)]) then return true end
	end
	local mode = api.type.enum.TransportMode.BUS
	if pathBudget and pathBudget.remaining < 2 then return false, "path_query_limit" end
	if pathBudget then pathBudget.remaining = pathBudget.remaining - 1 end
	local forward = api.engine.util.pathfinding.findPathNodeToNode(a, b, { mode })
	if not forward or #forward == 0 then return false end
	if pathBudget then pathBudget.remaining = pathBudget.remaining - 1 end
	local backward = api.engine.util.pathfinding.findPathNodeToNode(b, a, { mode })
	if not backward or #backward == 0 then return false end
	local function length(path)
		local total = 0
		for _, item in ipairs(path) do
			local edgeId = item[1]
			local network = edgeId and api.engine.getComponent(edgeId.entity, api.type.ComponentType.TRANSPORT_NETWORK)
			local edge = network and network.edges and network.edges[(edgeId.index or -1) + 1]
			local geom = edge and edge.geometry
			if not geom or not finite(geom.length) then return nil end
			total = total + geom.length
		end
		return total
	end
	local routeLength = length(forward)
	local reverseLength = length(backward)
	if finite(maxLength) and maxLength > 0 then
		if routeLength == nil or reverseLength == nil then return false, "path_length_unavailable" end
		return math.max(routeLength, reverseLength) <= maxLength
	end
	return true
end

local function routeable(stopA, stopB, maxLength, pathBudget)
	local nodesA = nodeIdsNear(stopA.data.position0, 45)
	local nodesB = nodeIdsNear(stopB.data.position0, 45)
	return connectedBothWays(nodesA, nodesB, maxLength, pathBudget)
end

local function endpoint(edge, node)
	if edge.node0 == node then return edge.position0, edge.position1 end
	if edge.node1 == node then return edge.position1, edge.position0 end
	return nil, nil
end

local function endpointOutward(edge, node)
	local position, other = endpoint(edge, node)
	if not position or not other then return nil end
	local dx, dy = other.x - position.x, other.y - position.y
	local length = math.sqrt(dx * dx + dy * dy)
	if length < 0.01 then return nil end
	return position, -dx / length, -dy / length
end

local function depotSite(edgeEntity, edge, node, position, outX, outY)
	if not position or not finite(position.x) or not finite(position.y) or not finite(position.z or 0) then return nil end
	-- road_depot's lane1 free node and snap point sit at local y=-35 and -30.
	-- Rotate local +Y away from the existing terminal street, then place the
	-- construction origin 35m back along that same axis so lane1 node 0 lands
	-- exactly on the public terminal node.
	local heading = atan2(-outX, outY)
	return {
		x = position.x + 35 * outX,
		y = position.y + 35 * outY,
		z = position.z or 0,
		heading = heading,
		accessNode = node,
		accessEdge = edgeEntity,
		localAccess = { x = 0, y = -35, z = 0 },
		snapPointLocal = { x = 0, y = -30, z = 0 },
	}
end

local function stopResourceForYear(year)
	if year < 1920 then return "::/street/small_stops/small_old.con" end
	if year < 1980 then return "::/street/small_stops/small_mid.con" end
	return "::/street/small_stops/small_new.con"
end

local function availabilityMatches(availability, year)
	if not availability then return true end
	local from = availability.yearFrom or -1
	local to = availability.yearTo or -1
	return not ((from > 0 and year < from) or (to > 0 and year >= to))
end

local function resourceAvailable(desc, year)
	if not desc or not availabilityMatches(desc.availability, year) then return false end
	local templates = desc.constructionTemplates or {}
	if #templates == 0 then return true end
	for _, template in ipairs(templates) do
		if availabilityMatches(template.availability, year) then return true end
	end
	return false
end

local function revisionToken(entity)
	local revision = api.engine.getRevision(entity)
	local parts = revision and revision.num
	if type(parts) ~= "table" then return nil end
	return { num = { parts[1], parts[2] } }
end

local function collectPairs(allTowns)
	local pairs = {}
	for i = 1, #allTowns - 1 do
		for j = i + 1, #allTowns do
			local a, b = allTowns[i], allTowns[j]
			local dist = math.sqrt(distance2(a.center, b.center))
			if dist >= 250 then
				local first, second = a.entity, b.entity
				if first > second then first, second = second, first end
				pairs[#pairs + 1] = {
					a = a, b = b, distance = dist,
					key = tostring(first) .. ":" .. tostring(second),
				}
			end
		end
	end
	return pairs
end

local function gameTime()
	local world = api.engine.util.getWorld()
	local time = world and api.engine.getComponent(world, api.type.ComponentType.GAME_TIME)
	return time and time.gameTime or 0
end

local function nodeIdsAt(position, radius)
	return api.engine.util.octree.findTransportNetworkNodesInCircle(
		api.type.Vec2f.new(position.x, position.y), radius) or {}
end

local function depotForTown(town, stopA, stopB, player, opts, pathBudget, nodeToEdges)
	local radius = opts.depotSearchRadius or 750
	local candidates
	candidates, radius = nearbySafeRoads(town.center, player, radius, opts.maxDepotSearchRadius or 2500)
	local best, bestDistance
	local testedTerminals = 0
	for _, candidate in ipairs(candidates) do
		local edge = candidate.data
		for _, node in ipairs({ edge.node0, edge.node1 }) do
			local incident = nodeToEdges[node] or {}
			-- Allow junction endpoints as well as dead ends. The construction
			-- preview checks collisions before any depot proposal is applied.
			if #incident > 0 then
				local position, outX, outY = endpointOutward(edge, node)
				if position then
					local d2 = distance2(position, town.center)
					if d2 <= radius * radius and (not bestDistance or d2 < bestDistance) then
						local siteNodes = nodeIdsAt(position, 30)
						local stopNodesA = nodeIdsNear(stopA.data.position0, 45)
						local stopNodesB = nodeIdsNear(stopB.data.position0, 45)
						local reachable = false
						if testedTerminals < 8 then
							testedTerminals = testedTerminals + 1
							local reachesA, reasonA = connectedBothWays(siteNodes, stopNodesA, opts.maxRouteLength, pathBudget)
							if reasonA == "path_query_limit" then return nil, reasonA end
							local reachesB, reasonB = false, nil
							if reachesA then reachesB, reasonB = connectedBothWays(siteNodes, stopNodesB, opts.maxRouteLength, pathBudget) end
							if reasonB == "path_query_limit" then return nil, reasonB end
							reachable = reachesA and reachesB
						end
						if reachable then
							best = depotSite(candidate.entity, edge, node, position, outX, outY)
							bestDistance = d2
						end
					end
				end
			end
		end
		if best then break end
	end
	return best, best and nil or "depot_access_geometry_unavailable"
end

local function candidateFor(pair, player, opts, pathBudget, nodeToEdges)
	local radius = opts.stopSearchRadius or 250
	local maxStopRadius = opts.maxStopSearchRadius or 3000
	local roadsA = nearbySafeRoads(pair.a.center, player, radius, maxStopRadius)
	local roadsB = nearbySafeRoads(pair.b.center, player, radius, maxStopRadius)
	if #roadsA == 0 or #roadsB == 0 then return nil, "no_safe_stop_road" end
	local a, b
	local pathReason
	local edgePairsChecked = 0
	for _, edgeA in ipairs(roadsA) do
		for _, edgeB in ipairs(roadsB) do
			edgePairsChecked = edgePairsChecked + 1
			local reachable, limitReason
			if edgeA.entity ~= edgeB.entity then
				reachable, limitReason = routeable(edgeA, edgeB, opts.maxRouteLength, pathBudget)
			end
			if reachable then a, b = edgeA, edgeB; break end
			if limitReason == "path_query_limit" then return nil, limitReason end
			if limitReason == "path_length_unavailable" then pathReason = limitReason end
			if edgePairsChecked >= 20 then break end
		end
		if a or edgePairsChecked >= 20 then break end
	end
	if not a then return nil, pathReason or "no_bidirectional_bus_path" end
	local site, siteReason = depotForTown(pair.a, a, b, player, opts, pathBudget, nodeToEdges)
	if not site then return nil, siteReason end
	local estimatedCost = opts.buildCostEstimate or opts.depotCostEstimate or 0
	if finite(opts.balance) and finite(opts.monthlyCost)
		and not planner.isAffordable(opts.balance, opts.monthlyCost, estimatedCost) then
		return nil, "estimated_build_over_budget"
	end
	local resource = opts.depotResource or "::/road/road_depot/road_depot.con"
	local registered = api.res.constructionRep.getAll()
	local rid = api.res.constructionRep.find(resource)
	if type(rid) ~= "number" or rid < 0 or not registered or registered[rid] ~= resource then
		return nil, "depot_resource_missing"
	end
	local desc = api.res.constructionRep.get(rid)
	if not desc then return nil, "depot_resource_missing" end
	local year = api.engine.util.getYear()
	if not resourceAvailable(desc, year) then return nil, "depot_resource_unavailable_this_year" end
	if opts.canBuildResource then
		local allowed, reason = opts.canBuildResource(player, resource)
		if not allowed then return nil, reason or "depot_resource_restricted" end
	end
	local stopResource = opts.stopResource or stopResourceForYear(year)
	local stopId = api.res.constructionRep.find(stopResource)
	if type(stopId) ~= "number" or stopId < 0 then return nil, "stop_resource_missing" end
	local stopDesc = api.res.constructionRep.get(stopId)
	if not stopDesc then return nil, "stop_resource_missing" end
	if not resourceAvailable(stopDesc, year) then return nil, "stop_resource_unavailable_this_year" end
	return {
		key = tostring(pair.a.entity) .. ":" .. tostring(pair.b.entity),
		name = (pair.a.name or "Town") .. " - " .. (pair.b.name or "Town"),
		modelId = opts.modelId,
		stage = "stop_a",
		towns = { pair.a.entity, pair.b.entity },
		stopEdges = { a.entity, b.entity },
		stopEdgeRevisions = {
			revisionToken(a.entity),
			revisionToken(b.entity),
		},
		stopResource = stopResource,
		depotSite = site,
		depotResource = resource,
		buildCost = estimatedCost,
		estimatedTravelDistance = pair.distance,
		population = { pair.a.population, pair.b.population },
		score = math.sqrt(pair.a.population * pair.b.population) / math.max(1, pair.distance),
	}
end

-- cursor is a plain serializable table containing the next pair index. At most
-- five pairs are inspected in one update, even when the map has many towns.
function planner.scan(player, opts, cursor)
	opts = opts or {}
	if type(player) ~= "number" then return nil, "invalid_player", cursor, true end
	local allPairs = collectPairs(towns())
	cursor = opts.cursor or cursor
	local index = type(cursor) == "table" and math.max(1, math.floor(cursor.index or 1)) or 1
	local finish = math.min(#allPairs, index + 4)
	local now = finite(opts.now) and opts.now or gameTime()
	local existing, filtered = {}, {}
	for _, route in ipairs(opts.routes or {}) do
		if type(route) == "table" and type(route.key) == "string" then existing[route.key] = true end
	end
	for _, pair in ipairs(allPairs) do
		local blockedUntil = opts.blocked and opts.blocked[pair.key]
		local isBlocked = blockedUntil == true or (finite(blockedUntil) and blockedUntil > now)
		if not existing[pair.key] and not isBlocked then filtered[#filtered + 1] = pair end
	end
	local last = math.min(#filtered, index + 4)
	local nextCursor = { index = last + 1 }
	local pathBudget = { remaining = opts.maxPathQueries or 512 }
	local nodeToEdges = api.engine.system.streetSystem.getNode2StreetEdgeMap()
	local bestPlan, bestScore, lastReason
	for i = index, last do
		local plan, reason = candidateFor(filtered[i], player, opts, pathBudget, nodeToEdges)
		if plan and (not bestPlan or plan.score > bestScore) then
			bestPlan, bestScore = plan, plan.score
		end
		lastReason = reason
		if opts.onReject and reason then opts.onReject(filtered[i].a.entity, filtered[i].b.entity, reason) end
		if pathBudget.remaining <= 0 or reason == "path_query_limit" then
			last = i
			nextCursor = { index = i + 1 }
			lastReason = "path_query_limit"
			break
		end
	end
	local isFinished = last >= #filtered
	if bestPlan then return bestPlan, nil, nextCursor, isFinished end
	local reason = #allPairs == 0 and "no_town_pairs"
		or #filtered == 0 and "all_town_pairs_filtered"
		or lastReason or "no_candidate_in_batch"
	return nil, reason, nextCursor, isFinished
end

planner._distance2 = distance2
planner._routeable = routeable
planner._depotSite = depotSite
planner._collectPairs = collectPairs
planner._depotForTown = depotForTown

function planner.isAffordable(balance, monthlyCost, amount)
	if not finite(balance) or balance < 0 or not finite(monthlyCost)
		or not finite(amount) or amount < 0 then return false end
	local available = balance - 3 * math.max(0, monthlyCost)
	return available >= amount and amount <= 0.4 * available
end

return planner
