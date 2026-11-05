-- Route planner selection, path safety, cursor budget and spend estimate tests.
local function equal(actual, expected, message)
	assert(actual == expected, string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
end

local comp = {
	TOWN = "town", BASE_EDGE = "edge", BASE_EDGE_STREET = "street",
	PLAYER_OWNED = "owned", TRANSPORT_NETWORK = "network",
	GAME_TIME = "game_time",
}
local townData, edgeData = {}, {}
local pathPair
local currentYear = 2026
local componentTypes = {
	RoadType = { STREET = "street" },
	BaseEdgeType = { NORMAL = "normal" },
	TransportMode = { BUS = "bus" },
	LandUseType = { RESIDENTIAL = "residential", COMMERCIAL = "commercial", INDUSTRIAL = "industrial" },
}
api = {
	type = {
		ComponentType = comp,
		enum = componentTypes,
		Vec2f = { new = function(x, y) return { x = x, y = y } end },
	},
	engine = {
		getEntitiesWithComponent = function(kind)
			local ids = {}
			if kind == comp.TOWN then for id in pairs(townData) do ids[#ids + 1] = id end end
			table.sort(ids)
			return ids
		end,
		getRevision = function(entity) return { num = { entity, 2 } } end,
		getComponent = function(entity, kind)
			if kind == "game_time" then return { gameTime = 100 } end
			if kind == comp.TOWN then return townData[entity] end
			if kind == comp.BASE_EDGE or kind == comp.BASE_EDGE_STREET then
				return edgeData[entity] and edgeData[entity][kind]
			end
			if kind == comp.PLAYER_OWNED then return edgeData[entity] and edgeData[entity][kind] end
			if kind == comp.TRANSPORT_NETWORK and entity == 999 then return { edges = { { geometry = { length = 100 } } } } end
		end,
		util = {
			getWorld = function() return 9000 end,
			getYear = function() return currentYear end,
			getEntityName = function(entity) return "Town " .. tostring(entity) end,
			octree = {
				findEntitiesInCircle = function(center, radius)
					local result = {}
					for id, item in pairs(edgeData) do
						local e = item[comp.BASE_EDGE]
						if math.abs(e.position0.x - center.x) <= radius then result[#result + 1] = id end
					end
					return result
				end,
				findTransportNetworkNodesInCircle = function(center)
					local near = math.floor(center.x / 1000 + 0.5) + 1
					return { { town = near } }
				end,
			},
			town = {
				getTownCapacityUsage = function(entity) return { { used = 100, capacity = 200 } } end,
				getTownDistrictCenter = function(entity) return townData[entity].center end,
			},
			pathfinding = {
				findPathNodeToNode = function(start, finish, modes)
					assert(modes[1] == "bus", "pathfinding uses BUS mode")
					if pathPair and ((start[1].town == pathPair[1] and finish[1].town == pathPair[2])
						or (start[1].town == pathPair[2] and finish[1].town == pathPair[1])) then
						return { { { entity = 999, index = 0 }, true } }
					end
					return {}
				end,
			},
		},
		system = { streetSystem = {
			getNode2StreetEdgeMap = function()
				local map = {}
				for id, item in pairs(edgeData) do
					local edge = item[comp.BASE_EDGE]
					map[edge.node0] = { id }
					map[edge.node1] = { id }
				end
				return map
			end,
		} },
	},
	res = { constructionRep = {
		find = function(name)
			if name == "::/road/road_depot/road_depot.con" then return 1 end
			if name == "::/street/small_stops/small_new.con" then return 2 end
			if name == "::/street/small_stops/small_old.con" then return 3 end
			return -1
		end,
		getAll = function() return {
			[1] = "::/road/road_depot/road_depot.con",
			[2] = "::/street/small_stops/small_new.con",
			[3] = "::/street/small_stops/small_old.con",
		} end,
		get = function(id)
			if id == 1 then return {
				availability = {},
				constructionTemplates = {
					{ availability = { yearFrom = 1900, yearTo = 1940 } },
					{ availability = { yearFrom = 1940, yearTo = 1980 } },
					{ availability = { yearFrom = 1980, yearTo = -1 } },
				},
			} end
			if id == 3 then return { availability = { yearFrom = 1900, yearTo = 1920 } } end
			return { availability = { yearFrom = 1980, yearTo = -1 } }
		end,
	} },
}

for id = 1, 4 do
	local x = (id - 1) * 1000
	townData[id] = { center = { x = x, y = 0, z = 0 } }
	edgeData[id + 100] = {
		[comp.BASE_EDGE] = {
			roadType = "street", type = "normal", roadDevelopmentLocked = false,
			distance = 30, objects = {}, position0 = { x = x, y = 0, z = 0 },
			position1 = { x = x + 30, y = 0, z = 0 }, tangent0 = { x = 1, y = 0 },
			node0 = 10 + id, node1 = 20 + id,
		},
		[comp.BASE_EDGE_STREET] = {},
	}
end

local planner = dofile("content/ai/planner.lua")
local site = planner._depotSite(100, {}, 55, { x = 100, y = 200, z = 0 }, 0, -1)
equal(site.x, 100, "depot origin is offset from terminal along outward axis")
equal(site.y, 165, "local access endpoint aligns with terminal node")
equal(site.accessNode, 55, "depot site retains the public terminal node")
equal(planner.isAffordable(500, 100, 100), false, "reserve plus expansion percentage protects cash")
equal(planner.isAffordable(10000, 100, 1000), true, "affordable build estimate passes")

pathPair = nil
local plan, reason, cursor, finished = planner.scan(88, { stopSearchRadius = 50 })
equal(plan, nil, "no route without real path")
equal(reason, "no_bidirectional_bus_path", "rejected candidates have a concrete reason")
equal(cursor.index, 6, "exactly five town pairs scanned")
equal(finished, false, "cursor remains unfinished after first batch")

-- Only the final pair is connected. The next call resumes using opts.cursor.
pathPair = { 3, 4 }
plan, reason, cursor, finished = planner.scan(88, {
	cursor = cursor, stopSearchRadius = 50, stopResource = "::/street/small_stops/small_new.con",
})
equal(reason, nil, "connected pair selected")
equal(plan.key, "3:4", "best remaining town pair selected")
equal(plan.stopEdges[1], 103, "first stop belongs to town three")
equal(plan.stopEdges[2], 104, "second stop belongs to town four")
equal(plan.stopEdgeRevisions[1].num[1], 103, "first stop revision is captured")
equal(plan.stopEdgeRevisions[2].num[1], 104, "second stop revision is captured")
equal(plan.stopResource, "::/street/small_stops/small_new.con", "dynamic stop resource carried forward")
equal(plan.depotResource, "::/road/road_depot/road_depot.con", "registered depot resource path selected")
local depotNodePosition
local depotRoad = edgeData[plan.depotSite.accessEdge][comp.BASE_EDGE]
if plan.depotSite.accessNode == depotRoad.node0 then depotNodePosition = depotRoad.position0
else depotNodePosition = depotRoad.position1 end
local localX = plan.depotSite.x + 35 * math.sin(plan.depotSite.heading)
local localY = plan.depotSite.y - 35 * math.cos(plan.depotSite.heading)
equal(math.floor(localX + 0.5), math.floor(depotNodePosition.x + 0.5), "depot lane free node meets terminal x")
equal(math.floor(localY + 0.5), math.floor(depotNodePosition.y + 0.5), "depot lane free node meets terminal y")
equal(finished, true, "last pair marks scan complete")

plan, reason = planner.scan(88, {
	cursor = { index = 6 }, stopSearchRadius = 50, balance = 500,
	monthlyCost = 100, buildCostEstimate = 100,
})
equal(plan, nil, "budget reserve rejects expensive estimate")
equal(reason, "estimated_build_over_budget", "budget rejection reason is concrete")

edgeData[101][comp.PLAYER_OWNED] = { player = 7 }
equal(planner.isPublicPlainStreet(101), false, "owned road is excluded")
pathPair = { 1, 2 }
plan = planner.scan(88, { cursor = { index = 1 }, stopSearchRadius = 50 })
equal(plan, nil, "owned road is rejected")

local allKeys = { "1:2", "1:3", "1:4", "2:3", "2:4", "3:4" }
local blocked, routes = {}, {}
for _, key in ipairs(allKeys) do
	blocked[key] = 200
	routes[#routes + 1] = { key = key }
end
plan, reason, cursor, finished = planner.scan(88, {
	blocked = blocked, routes = {}, now = 100, stopSearchRadius = 50,
})
equal(plan, nil, "active cooldown filters all town pairs")
equal(reason, "all_town_pairs_filtered", "cooldown rejection has a concrete reason")
equal(finished, true, "filtered scan finishes")
plan, reason = planner.scan(88, { routes = routes, now = 100, stopSearchRadius = 50 })
equal(plan, nil, "existing route keys are filtered")
equal(reason, "all_town_pairs_filtered", "duplicate route rejection has a concrete reason")

currentYear = 1850
pathPair = { 3, 4 }
plan, reason = planner.scan(88, {
	cursor = { index = 6 }, now = 100, stopSearchRadius = 50,
})
equal(plan, nil, "empty base availability does not bypass depot template dates")
equal(reason, "depot_resource_unavailable_this_year", "pre-1900 depot templates are rejected")
currentYear = 1899
plan, reason = planner.scan(88, {
	cursor = { index = 6 }, now = 100, stopSearchRadius = 50,
})
equal(reason, "depot_resource_unavailable_this_year", "year before first depot template is rejected")
currentYear = 1900
pathPair = { 3, 4 }
plan, reason = planner.scan(88, {
	cursor = { index = 6 }, now = 100, stopSearchRadius = 50,
})
equal(reason, nil, "first depot template is available at its lower year boundary")
equal(plan.stopResource, "::/street/small_stops/small_old.con", "old stop variant selected at 1900")

-- Nearby sidewalk nodes must not crowd bus nodes out of the bounded search.
do
	local originalComponent=api.engine.getComponent
	api.type.EdgeGeometry={calcPos=function(geom) return {{x=geom.x,y=0,z=0}} end}
	api.engine.getComponent=function(entity,kind)
		if kind==comp.TRANSPORT_NETWORK and (entity==701 or entity==702) then
			return {edges={
				{transportModes={person=true},conns={{entity=entity,index=0},{entity=entity,index=1}},geometry={x=0}},
				{transportModes={person=true},conns={{entity=entity,index=2},{entity=entity,index=3}},geometry={x=0}},
				{transportModes={bus=true},conns={{entity=entity,index=10},{entity=entity,index=11}},geometry={x=2}},
			}}
		end
		return originalComponent(entity,kind)
	end
	api.engine.util.octree.findTransportNetworkNodesInCircle=function(center)
		local entity=center.x==0 and 701 or 702
		local nodes={}
		for _,index in ipairs({0,1,2,3,10,11}) do nodes[#nodes+1]={entity=entity,index=index} end
		return nodes
	end
	api.engine.util.pathfinding.findPathNodeToNode=function(starts,targets,modes)
		assert(modes[1]=="bus" and #starts==2 and #targets==2)
		for _,node in ipairs(starts) do assert(node.index>=10,"Sidewalk nodes excluded before bus-node cap") end
		return {{{entity=999,index=0},true}}
	end
	assert(planner._routeable({data={position0={x=0,y=0}}},{data={position0={x=1000,y=0}}}))
end
print("planner tests passed")
