-- Thin adapter around APIs confirmed in the Transport Fever 3 API definitions
-- and vanilla scripts. Keep decision policy outside this module.
local native = {}
local DEFAULT_STARTING_CAPITAL = 10000000
-- getModParams returns the selected ScriptParam index, not its number value.
-- Keep this order aligned with mod.json's startingCapital numbers array.
local STARTING_CAPITAL_BY_INDEX = { 5000000, 10000000, 20000000, 50000000 }

local function finite(value)
	return type(value) == "number" and value == value
		and value ~= math.huge and value ~= -math.huge
end

function native.getPlayer()
	return api.engine.util.getPlayer()
end

function native.balance(playerEntity)
	if type(playerEntity) ~= "number" then
		return nil
	end
	return api.engine.util.finance.getPlayersBalance(playerEntity)
end

function native.startingCapital()
	local config = api.engine and api.engine.config
	if not config or config.getModParams == nil then
		return DEFAULT_STARTING_CAPITAL
	end
	local ok, allParams = pcall(config.getModParams)
	local modParams = ok and type(allParams) == "table" and allParams.pichau_competitor_ai or nil
	local index = type(modParams) == "table" and modParams.startingCapital or nil
	if not finite(index) or index ~= math.floor(index)
		or index < 1 or index > #STARTING_CAPITAL_BY_INDEX then
		return DEFAULT_STARTING_CAPITAL
	end
	return STARTING_CAPITAL_BY_INDEX[index]
end

function native.now()
	local world = api.engine.util.getWorld()
	local gameTime = api.engine.getComponent(world, api.type.ComponentType.GAME_TIME)
	return gameTime and gameTime.gameTime or nil
end

function native.monthDuration()
	return api.util.getDefaultMonthDuration()
end

function native.playersNamed(name)
	local matches = {}
	if type(name) ~= "string" then return matches end
	-- PLAYER is readable on an entity but cannot be used as a loop index by
	-- the engine. Enumerate entities instead, then inspect that component.
	api.engine.forEachEntity(function(entity)
		if api.engine.getComponent(entity, api.type.ComponentType.PLAYER)
			and api.engine.util.getEntityName(entity) == name then
			matches[#matches + 1] = entity
		end
	end)
	table.sort(matches)
	return matches
end

-- Engine state executes commands immediately. Never provide a callback here:
-- GameScript callbacks are disallowed, and command results are not read back.
function native.newPlayer(name, color)
	if type(name) ~= "string" or color == nil then
		return false, "invalid_player_arguments"
	end
	if type(color) == "table" then
		color = api.type.Vec3f.new(color[1] or color.x, color[2] or color.y, color[3] or color.z)
	end

	local command = api.cmd.makeGameAddPlayerCmd(name, color)
	local ok, err = pcall(api.cmd.sendCommand, command)
	if not ok then return false, "game_add_player_command_failed:" .. tostring(err) end
	return true, nil
end

-- JournalBookAsset changes the account through the normal finance ledger.
-- Re-read the account first so reloads or retries do not blindly add funds.
function native.fundToBalance(playerEntity, targetBalance)
	if type(playerEntity) ~= "number" or not finite(targetBalance)
		or targetBalance < 0 or targetBalance ~= math.floor(targetBalance) then
		return false, "invalid_funding_arguments"
	end
	if playerEntity == native.getPlayer() then
		return false, "refusing_local_player_funding"
	end

	local currentBalance = native.balance(playerEntity)
	if not finite(currentBalance) then
		return false, "balance_unavailable"
	end

	local delta = targetBalance - currentBalance
	if delta == 0 then
		return true, nil, currentBalance
	end

	local entry = api.type.JournalEntry.new()
	entry.amount = delta
	entry.time = -1
	if delta > 0 then
		entry.category.type = api.type.JournalEntry.Type.INCOME
	else
		entry.category.type = api.type.JournalEntry.Type.OTHER
	end

	local command = api.cmd.makeJournalBookAssetCmd(
		playerEntity,
		entry,
		api.type.Vec3f.new(0, 0, 0)
	)
	local ok, err = pcall(api.cmd.sendCommand, command)
	if not ok then return false, "journal_command_failed:" .. tostring(err), native.balance(playerEntity) end
	local updatedBalance = native.balance(playerEntity)
	if updatedBalance ~= targetBalance then return false, "balance_did_not_reach_target", updatedBalance end
	return true, nil, updatedBalance
end

function native.ownedEntities(playerEntity, componentType)
	if type(playerEntity) ~= "number" or componentType == nil then
		return {}
	end
	return api.engine.getEntitiesWithComponent(componentType, {
		requireOwnedByPlayer = playerEntity,
	})
end

function native.ownedVehicles(playerEntity)
	return native.ownedEntities(playerEntity, api.type.ComponentType.TRANSPORT_VEHICLE)
end

function native.ownedLines(playerEntity)
	return native.ownedEntities(playerEntity, api.type.ComponentType.LINE)
end

function native.snapshot(playerEntity)
	if type(playerEntity) ~= "number"
		or not api.engine.entityExists(playerEntity)
		or not api.engine.getComponent(playerEntity, api.type.ComponentType.PLAYER) then
		return nil
	end

	local balance = native.balance(playerEntity)
	local vehicles = native.ownedVehicles(playerEntity)
	local lines = native.ownedLines(playerEntity)
	local annualRunningCost = 0
	local vehicleIds = {}
	for _, vehicleEntity in ipairs(vehicles) do
		vehicleIds[vehicleEntity] = true
		local runningCost = api.engine.util.vehicle.getRunningCost(vehicleEntity)
		if finite(runningCost) then
			annualRunningCost = annualRunningCost + runningCost
		end
	end
	local annualInfrastructureCost = 0
	for _, entity in ipairs(native.ownedEntities(playerEntity, api.type.ComponentType.MAINTENANCE_COST)) do
		local maintenance = api.engine.getComponent(entity, api.type.ComponentType.MAINTENANCE_COST)
		if not vehicleIds[entity] and maintenance and finite(maintenance.maintenanceCost) then
			annualInfrastructureCost = annualInfrastructureCost + maintenance.maintenanceCost
		end
	end
	for _, entity in ipairs(native.ownedEntities(playerEntity, api.type.ComponentType.STATION_GROUP)) do
		if not api.engine.getComponent(entity, api.type.ComponentType.MAINTENANCE_COST) then
			local cost = api.engine.util.maintenance.calcMaintenanceForStationGroup(entity)
			if finite(cost) and cost > 0 then annualInfrastructureCost = annualInfrastructureCost + cost end
		end
	end

	return {
		playerEntity = playerEntity,
		name = api.engine.util.getEntityName(playerEntity),
		balance = balance,
		now = native.now(),
		vehicles = vehicles,
		lines = lines,
		annualRunningCost = annualRunningCost,
		annualInfrastructureCost = annualInfrastructureCost,
		monthlyCost = (annualRunningCost + annualInfrastructureCost) / 12,
	}
end

local function companyMetadata(constructionDesc)
	local metadata = constructionDesc and constructionDesc.metadata
	if not metadata then
		return nil, nil
	end
	local ok, metadataApi = pcall(ug_require, "/game_mechanics/company/company_metadata.tl")
	if not ok or not metadataApi or type(metadataApi.getKey) ~= "function" then
		return nil, "company_metadata_key_unavailable"
	end
	local key = metadataApi.getKey()
	if type(key) ~= "string" then
		return nil, "company_metadata_key_unavailable"
	end
	return metadata[key], nil
end

-- Rank-only restrictions can be checked from the native progression state.
-- Permit consumption is tied to vanilla's local-player company system, so
-- this intentionally declines permit-limited resources for another player.
function native.canBuildResource(playerEntity, resourceName)
	if type(playerEntity) ~= "number" or type(resourceName) ~= "string" then
		return false, "invalid_resource_arguments"
	end
	if not api.engine.entityExists(playerEntity)
		or not api.engine.getComponent(playerEntity, api.type.ComponentType.PLAYER) then
		return false, "player_entity_missing"
	end

	local constructionId = api.res.constructionRep.find(resourceName)
	if type(constructionId) ~= "number" or constructionId < 0 then
		return false, "construction_resource_missing"
	end
	local desc = api.res.constructionRep.get(constructionId)
	local meta, metadataError = companyMetadata(desc)
	if metadataError then
		return false, metadataError
	end
	if not meta then
		return true
	end

	local requiresPermit = (type(meta.permitKey) == "string" and meta.permitKey ~= "")
		or (meta.rankAndPermits ~= nil and next(meta.rankAndPermits) ~= nil)
	if requiresPermit then
		return false, "vanilla_company_permits_not_initialized_for_competitor"
	end

	-- Rank zero is the unrestricted initial tier. The vanilla singleton's
	-- missing progression record must not disable every basic bus building.
	if type(meta.companyRank) == "number" and meta.companyRank > 0 then
		local ok, progressionUtil = pcall(ug_require, "/game_mechanics/company/company_progression_util.tl")
		if not ok or not progressionUtil or type(progressionUtil.getCompanyProgressionState) ~= "function" then
			return false, "company_rank_unavailable"
		end
		local readOk, progression = pcall(progressionUtil.getCompanyProgressionState, playerEntity)
		-- Vanilla company_growth.script initializes new companies at level 1.
		-- Its loop only initializes the human, so use that same initial tier for
		-- a rival without granting higher ranks or additional permit allocations.
		if (not readOk or not progression) and meta.companyRank <= 1 then return true end
		if not readOk then progression = nil end
		if not progression or type(progression.level) ~= "number" then
			return false, "company_rank_unavailable"
		end
		if progression.level < meta.companyRank then
			return false, "company_rank_too_low"
		end
	end

	return true
end

local function vehicleSpeed(metadata)
	local land = metadata.landVehicle
	local water = metadata.waterVehicle
	local air = metadata.airVehicle
	if land and finite(land.topSpeed) then
		return land.topSpeed
	elseif water and finite(water.topSpeed) then
		return water.topSpeed
	elseif air and finite(air.topSpeed) then
		return air.topSpeed
	end
	return nil
end

local function makeSingleVehicleConfig(modelId, transportVehicle, now)
	local part = api.type.TransportVehiclePart.new()
	part.part.modelId = modelId
	part.part.reversed = false
	part.purchaseTime = now or 0

	local loadConfigs = {}
	for _ in ipairs(transportVehicle.compartments or {}) do
		local loadConfig = api.type.LoadConfig.new()
		loadConfig.loadConfigIndex = 0
		loadConfigs[#loadConfigs + 1] = loadConfig
	end
	part.part.compartment2loadConfig = loadConfigs
	local autoLoad = {}
	for index in ipairs(loadConfigs) do
		autoLoad[index] = true
	end
	part.autoLoadConfig = autoLoad

	local config = api.type.TransportVehicleConfig.new()
	config.vehicles = { part }
	config.vehicleGroups = { 1 }
	config.muFileNames = {}
	return config
end

local function contains(values, wanted)
	for _, value in ipairs(values or {}) do
		if value == wanted then
			return true
		end
	end
	return false
end

function native.vehicleCandidates(carrier, transportMode)
	local candidates = {}
	-- ROAD also covers trucks. The rival routes are passenger routes, so only
	-- include road vehicles explicitly configured for BUS transport.
	if carrier == api.type["enum"].Carrier.ROAD and transportMode == nil then
		transportMode = api.type["enum"].TransportMode.BUS
	end
	local currentYear = api.engine.util.getYear()
	local now = native.now()
	for modelId in pairs(api.res.modelRep.getAll()) do
		local model = api.res.modelRep.get(modelId)
		local metadata = model and model.metadata
		local transportVehicle = metadata and metadata.transportVehicle
		local availability = metadata and metadata.availability
		local cost = metadata and metadata.cost
		local maintenance = metadata and metadata.maintenance
		local speed = metadata and vehicleSpeed(metadata)
		if transportVehicle and transportVehicle.carrier == carrier
			and (transportMode == nil or contains(transportVehicle.transportModes, transportMode))
			and cost and finite(cost.price) and cost.price >= 0
			and maintenance and finite(maintenance.runningCosts) and maintenance.runningCosts >= 0
			and speed and speed >= 0 then
			local yearFrom = availability and availability.yearFrom or -1
			local yearTo = availability and availability.yearTo or -1
			local available = (yearFrom <= 0 or currentYear >= yearFrom)
				and (yearTo <= 0 or currentYear < yearTo)
			if available then
				local config = makeSingleVehicleConfig(modelId, transportVehicle, now)
				candidates[#candidates + 1] = {
					id = api.res.modelRep.getName(modelId),
					modelId = modelId,
					purchaseCost = cost.price,
					runningCost = maintenance.runningCosts,
					speed = speed,
					config = config,
				}
			end
		end
	end
	return candidates
end

function native.bestBus()
	local candidates = native.vehicleCandidates(api.type["enum"].Carrier.ROAD, api.type["enum"].TransportMode.BUS)
	local best
	for _, candidate in ipairs(candidates) do
		local totalCost = candidate.purchaseCost + candidate.runningCost
		if not best then
			best = candidate
		else
			local bestTotalCost = best.purchaseCost + best.runningCost
			if totalCost < bestTotalCost
				or (totalCost == bestTotalCost and candidate.speed > best.speed)
				or (totalCost == bestTotalCost and candidate.speed == best.speed and candidate.id < best.id) then
				best = candidate
			end
		end
	end
	return best
end

local function maintenanceExpenses(playerEntity, startTime, endTime)
	local maintenanceTypes = api.type.JournalEntry.Maintenance
	local values = {
		maintenanceTypes.VEHICLE,
		maintenanceTypes.INFRASTRUCTURE,
		maintenanceTypes.OTHER,
		maintenanceTypes.VEHICLE_MAINTENANCE,
	}
	local total = 0
	for _, maintenanceType in ipairs(values) do
		if maintenanceType ~= nil then
			local balance = api.engine.util.finance.calculateBalance(
				{ playerEntity }, startTime, endTime, true, maintenanceType
			)
			if finite(balance) and balance < 0 then
				total = total - balance
			end
		end
	end
	return total
end

function native.operatingProfit(playerEntity, startTime, endTime)
	return native.companyProfit(playerEntity, startTime, endTime)
end

function native.operatingExpenses(playerEntity, startTime, endTime)
	if type(playerEntity) ~= "number" or not finite(startTime)
		or not finite(endTime) or endTime < startTime then
		return nil, "invalid_finance_interval"
	end
	return maintenanceExpenses(playerEntity, startTime, endTime)
end

function native.operatingIncome(playerEntity, startTime, endTime)
	local profit, profitError = native.operatingProfit(playerEntity, startTime, endTime)
	if not finite(profit) then return nil, profitError or "operating_profit_unavailable" end
	local expenses, expenseError = native.operatingExpenses(playerEntity, startTime, endTime)
	if not finite(expenses) then return nil, expenseError or "operating_expenses_unavailable" end
	return profit + expenses
end

-- Match vanilla's line statistics: calculate the line balance on the line's
-- currently assigned vehicles. The GUI calls calculateBalance on precisely
-- this list and does not require ACCOUNT components. Infrastructure upkeep is
-- reserved at company level; attributing shared infrastructure to every line
-- would double count it.
function native.routeStats(playerEntity, routeEntity, startTime, endTime, infrastructureEntities)
	local routeRecord
	if type(routeEntity) == "table" then
		routeRecord = routeEntity
		infrastructureEntities = infrastructureEntities or routeRecord.infrastructure
		routeEntity = routeRecord.line
	end
	if type(playerEntity) ~= "number" or type(routeEntity) ~= "number"
		or not finite(startTime) or not finite(endTime) or endTime < startTime then
		return nil, "invalid_route_stats_arguments"
	end

	local line = api.engine.getComponent(routeEntity, api.type.ComponentType.LINE)
	local ownership = api.engine.getComponent(routeEntity, api.type.ComponentType.PLAYER_OWNED)
	if not line or not ownership or ownership.player ~= playerEntity then
		return { valid = false, vehicles = {}, noPath = true }, nil
	end
	if routeRecord and type(infrastructureEntities) ~= "table" then
		return { valid = false, vehicles = {}, noPath = true }, nil
	end

	local vehicles = api.engine.system.transportVehicleSystem.getLineVehicles(routeEntity) or {}
	local annualVehicleCost = 0
	for _, vehicleEntity in ipairs(vehicles) do
		if not api.engine.entityExists(vehicleEntity) then
			return { valid = false, vehicles = vehicles, noPath = true }, nil
		end
		local vehicleOwner = api.engine.getComponent(vehicleEntity, api.type.ComponentType.PLAYER_OWNED)
		if not vehicleOwner or vehicleOwner.player ~= playerEntity then
			return { valid = false, vehicles = vehicles, noPath = true }, nil
		end
		local runningCost = api.engine.util.vehicle.getRunningCost(vehicleEntity)
		if finite(runningCost) then
			annualVehicleCost = annualVehicleCost + runningCost
		end
	end

	local annualInfrastructureCost = 0
	local seenInfrastructure = {}
	for _, infrastructureEntity in ipairs(infrastructureEntities or {}) do
		if not seenInfrastructure[infrastructureEntity] then
			seenInfrastructure[infrastructureEntity] = true
			if not api.engine.entityExists(infrastructureEntity) then
				return { valid = false, vehicles = vehicles, noPath = true }, nil
			end
			local infrastructureOwner = api.engine.getComponent(infrastructureEntity, api.type.ComponentType.PLAYER_OWNED)
			if not infrastructureOwner or infrastructureOwner.player ~= playerEntity then
				return { valid = false, vehicles = vehicles, noPath = true }, nil
			end
			local stationGroup = api.engine.getComponent(infrastructureEntity, api.type.ComponentType.STATION_GROUP)
			local annualCost
			if stationGroup then
				annualCost = api.engine.util.maintenance.calcMaintenanceForStationGroup(infrastructureEntity)
			else
				local maintenance = api.engine.getComponent(infrastructureEntity, api.type.ComponentType.MAINTENANCE_COST)
				annualCost = maintenance and maintenance.maintenanceCost or 0
			end
			if finite(annualCost) and annualCost > 0 then
				annualInfrastructureCost = annualInfrastructureCost + annualCost
			end
		end
	end

	local capacityUsage = api.engine.util.line.getLineCapacityUsages(routeEntity, true) or {}
	local used, capacity = 0, 0
	for _, usage in pairs(capacityUsage) do
		if usage and finite(usage.used) and finite(usage.capacity) then
			used = used + usage.used
			capacity = capacity + usage.capacity
		end
	end

	local noPath = false
	local stopProblems = api.engine.util.line.getDetailedLineProblems(routeEntity) or {}
	for _, stopList in ipairs(stopProblems) do
		for _, stop in ipairs(stopList or {}) do
			if stop.noPath or next(stop.noPathFromAlternative or {}) ~= nil
				or next(stop.noPathToAlternative or {}) ~= nil then
				noPath = true
			end
		end
	end

	local profit, expenses, income
	if #vehicles > 0 then
		local finance = api.engine.util.finance
		local profitOk, vehicleBalance = pcall(finance.calculateBalance, vehicles, startTime, endTime, true)
		if profitOk and finite(vehicleBalance) then profit = vehicleBalance end
		local maintenanceTypes = api.type.JournalEntry.Maintenance
		local types = { maintenanceTypes.VEHICLE, maintenanceTypes.INFRASTRUCTURE,
			maintenanceTypes.OTHER, maintenanceTypes.VEHICLE_MAINTENANCE }
		expenses = 0
		for _, maintenanceType in ipairs(types) do
			if maintenanceType ~= nil then
				local expenseOk, balance = pcall(finance.calculateBalance,
					vehicles, startTime, endTime, true, maintenanceType)
				if not expenseOk or not finite(balance) then
					expenses = nil
					break
				end
				if balance < 0 then expenses = expenses - balance end
			end
		end
		income = finite(profit) and finite(expenses) and profit + expenses or nil
	end
	return {
		valid = true,
		profit = profit,
		income = income,
		expenses = expenses,
		profitScope = finite(profit) and "vehicles" or nil,
		vehicles = vehicles,
		occupancy = capacity > 0 and used / capacity or nil,
		occupancySample = {
			used = used,
			capacity = capacity,
			ratio = capacity > 0 and used / capacity or nil,
			sampledAt = native.now(),
		},
		noPath = noPath,
		monthlyCost = (annualVehicleCost + annualInfrastructureCost) / 12,
		annualVehicleCost = annualVehicleCost,
		annualInfrastructureCost = annualInfrastructureCost,
	}, nil
end

function native.companyProfit(playerEntity, startTime, endTime)
	if type(playerEntity) ~= "number" or not finite(startTime)
		or not finite(endTime) or endTime < startTime then
		return nil, "invalid_finance_interval"
	end
	return api.engine.util.finance.calculateBalance({ playerEntity }, startTime, endTime, true)
end

return native
