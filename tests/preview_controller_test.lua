-- Inter-module test of the engine controller and GUI preview bridge.
local controllerFactory = dofile("content/ai/controller.lua")
local policy = dofile("content/ai/policy.lua")

local function equal(actual, expected, message)
	assert(actual == expected, string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
end

local function harness()
	local now, constructionValid = 1000, true
	local trace, queuedEvents, economicCommands = {}, {}, {}
	local buildCalls, accepted, scanCalls = 0, 0, 0
	local rivalExists, rivalBalance = false, 0
	local store = { state = nil, subscriptions = {} }
	function store:get() return self.state end
	function store:set(state) self.state = state end
	function store:subscribeToEvent(name) self.subscriptions[name] = true end

	local native = {
		now = function() return now end,
		monthDuration = function() return 100 end,
		getPlayer = function() return 1 end,
		balance = function(player) return player == 1 and 10000 or rivalBalance end,
		playersNamed = function() return rivalExists and { 2 } or {} end,
		snapshot = function(player)
			return { balance = 10000, monthlyCost = 100, annualRunningCost = 1200 }
		end,
		newPlayer = function() rivalExists = true; return true end,
		fundToBalance = function(_, target) rivalBalance = target; return true, nil, target end,
		bestBus = function()
			return { modelId = 7, purchaseCost = 100, runningCost = 1200 }
		end,
		operatingProfit = function() return 0 end,
	}

	local routes = {
		readiness = function() return { automaticPlacement = true } end,
		scan = function(player, opts)
			scanCalls = scanCalls + 1
			if scanCalls == 1 then
				return { key = "1:2", name = "Town A - Town B", stage = "stop_a", buildCost = 1000 }, nil, nil, false
			end
			return nil, "no_candidate", nil, true
		end,
		stepBuild = function(player, operation, done)
			buildCalls = buildCalls + 1
			if not operation.preview then
				operation.preview = {
					token = "token-" .. operation.stage,
					intent = { kind = "depot", resource = "::/road/road_depot/road_depot.con",
						site = { x = 20, y = 30, z = 0, heading = 0 }, params = {} },
					budget = { remaining = 5000, reserve = 300, busCost = 100 },
				}
			end
			done(true, operation)
		end,
		acceptPreview = function(player, operation, payload)
			accepted = accepted + 1
			if not payload.success then return false, operation, payload.reason or "preflight_rejected" end
			operation.preview = nil
			operation.stage = "stop_b"
			operation.lastReceipt = payload.token
			return true, operation
		end,
		stepManage = function(_, operation, done) done(true, operation) end,
	}

	local instance = controllerFactory.create(native, routes, policy)
	local construction = {
		makeProposal = function(player, intent)
			assert(player == 2 and intent.kind == "depot")
			return { kind = intent.kind }
		end,
		validatePreview = function(player, intent, full, data, budget)
			assert(player == 2 and full.native and data.costs == 500)
			assert(budget.remaining == 5000)
			if not constructionValid then return false, "preview_collision" end
			return true, nil, 500
		end,
	}
	function ug_require(name)
		assert(name == "pichau_competitor_ai::/ai/construction.lua")
		return construction
	end

	api = {
		engine = { util = { getPlayer = function() return 1 end } },
		type = { Context = { new = function() return {} end } },
		cmd = {
			makeScriptingSendEventCmd = function(source, id, name, payload)
				assert(source == "pichau_competitor_ai::/ai/competitor.gs")
				assert(id == "pichau_competitor_ai")
				return { event = name, payload = payload }
			end,
			makeWorldBuildProposalCmd = function(full, context, ignore, economic)
				assert(full.native and context.player == 2 and ignore == false and economic == true)
				return { build = true }
			end,
			sendCommand = function(command, done)
				if command.event then
					trace[#trace + 1] = "event:" .. command.event
					queuedEvents[#queuedEvents + 1] = command
				else
					economicCommands[#economicCommands + 1] = command
					trace[#trace + 1] = "economic_build"
					done({ resultEntities = { 40, 41 }, resultProposalData = { costs = 500 } }, true)
				end
			end,
		},
	}
	local preview = dofile("content/ai/preview.lua")
	local viewer = { ProposalViewer = function(params) return params end }
	local session = preview.createSession(viewer, function() return store:get() end)
	local function deliver(index)
		local event = queuedEvents[index]
		assert(event, "expected queued event " .. tostring(index))
		instance.handleEvent(nil, store, nil, "pichau_competitor_ai", event.event, event.payload)
	end
	local function setupOperation()
		instance.handleEvent(nil, store, nil, "", "initNewGame", {})
		instance.update(nil, store, 1) -- create player
		instance.update(nil, store, 1) -- fund
		instance.update(nil, store, 1) -- choose plan
		instance.update(nil, store, 1) -- create preview request
		return store:get()
	end
	local function render()
		return session.render(store:get())
	end
	local function resolveViewer(node)
		assert(node and node.simpleProposal, "GUI worker should create a ProposalViewer")
		node.onCreateProposalData({ costs = 500 }, { native = true })
	end
	return {
		instance = instance, store = store, preview = preview, render = render,
		resolveViewer = resolveViewer, deliver = deliver, setupOperation = setupOperation,
		setNow = function(value) now = value end,
		setConstructionValid = function(value) constructionValid = value end,
		trace = trace, events = queuedEvents, economicCommands = economicCommands,
		counts = function() return buildCalls, accepted, scanCalls end,
	}
end

-- Build a preview request, validate it on the GUI side, then confirm that the
-- engine receives START before the economic mutation and RESULT afterward.
local h = harness()
local state = h.setupOperation()
equal(state.phase, "build", "planner hands a concrete operation to builder")
equal(state.operation.stage, "stop_a", "first stage is active")
equal(h.store.subscriptions[h.preview.START_EVENT], true, "controller subscribes to preview START")
equal(h.store.subscriptions[h.preview.RESULT_EVENT], true, "controller subscribes to preview RESULT")
local viewer = h.render()
h.resolveViewer(viewer)
equal(h.trace[1], "event:" .. h.preview.START_EVENT, "START is queued first")
equal(h.trace[2], "economic_build", "economic build follows START")
equal(h.trace[3], "event:" .. h.preview.RESULT_EVENT, "RESULT follows build callback")
equal(#h.economicCommands, 1, "one native economic build submitted")

h.deliver(1)
state = h.store:get()
equal(state.operation.preview.submitted, true, "START persists submitted marker")
equal(state.operation.preview.submittedAt, 1000, "START records timeout clock")
h.deliver(2)
state = h.store:get()
equal(state.operation.stage, "stop_b", "valid RESULT advances to next stage")
equal(state.operation.preview, nil, "accepted preview token is consumed")
equal(state.operation.lastReceipt, "token-stop_a", "receipt token is retained")
h.deliver(2) -- duplicate receipt after request consumption
h.instance.handleEvent(nil, h.store, nil, "pichau_competitor_ai", h.preview.RESULT_EVENT,
	{ token = "stale-token", success = true, entities = { 50 }, cost = 1 })
local _, accepted = h.counts()
equal(accepted, 1, "duplicate and stale events are ignored")

-- A submitted command with no RESULT times out into a durable blocked state.
local timeout = harness()
timeout.setupOperation()
local timeoutViewer = timeout.render()
timeout.resolveViewer(timeoutViewer)
timeout.deliver(1) -- START only; drop RESULT
local timeoutState = timeout.store:get()
local savedOperation = timeoutState.operation
timeout.setNow(1101)
timeout.instance.update(nil, timeout.store, 1)
timeoutState = timeout.store:get()
equal(timeoutState.phase, "blocked", "submitted preview timeout blocks automatic retry")
equal(timeoutState.operation, savedOperation, "submitted operation is preserved for reconciliation")
equal(timeoutState.operation.preview.submitted, true, "submitted marker remains durable")
timeout.instance.update(nil, timeout.store, 1)
local steps = timeout.counts()
equal(steps, 1, "timeout never calls builder a second time")
equal(#timeout.economicCommands, 1, "timeout does not duplicate economic command")

-- A preflight collision submits no assets, blacklists only the route, and
-- allows the controller to enter planning again after its scan delay.
local reject = harness()
reject.setupOperation()
reject.setConstructionValid(false)
local rejectViewer = reject.render()
reject.resolveViewer(rejectViewer)
equal(#reject.economicCommands, 0, "rejected preflight sends no construction command")
equal(#reject.events, 1, "preflight rejection emits RESULT without START")
reject.deliver(1)
local rejectedState = reject.store:get()
equal(rejectedState.phase, "plan", "asset-free rejection returns to planning")
equal(rejectedState.operation, nil, "asset-free operation is discarded")
equal(rejectedState.blockedCandidates["1:2"], 1300, "failed route is cooled down")
reject.instance.update(nil, reject.store, 1)
local _, _, scansAfterWait = reject.counts()
equal(scansAfterWait, 1, "scan delay prevents immediate duplicate planning")
reject.setNow(rejectedState.nextScanAt)
reject.instance.update(nil, reject.store, 1)
rejectedState = reject.store:get()
local _, _, scansAfterReplan = reject.counts()
equal(scansAfterReplan, 2, "controller resumes route planning after delay")
equal(rejectedState.phase, "plan", "exhausted alternate scan remains in planning phase")
print("preview-controller integration tests passed")
