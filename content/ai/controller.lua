-- Simulation controller. Dependencies are injected to exercise recovery without
-- the game and to keep API commands out of the decision policy.
local controller = {}
local VERSION = 2
local DEFAULT_STARTING_CAPITAL = 10000000
local OLD_NO_CAPITAL_REASON = "A rival exige uma partida com capital inicial finito e positivo"

function controller.create(native, routes, policy)
    local ret = {}
    local function save(store, state) store:set(state) end
    local function block(store, state, reason)
        state.phase = "blocked"
        state.status = "Integração interrompida"
        state.lastDecision = tostring(reason)
        state.pending = nil
        save(store, state)
    end
    local function remember(state, message)
        state.lastDecision = message
        state.history = state.history or {}
        state.history[#state.history + 1] = {time = native.now(), message = message}
        if #state.history > 24 then table.remove(state.history, 1) end
    end

    local function failedOperation(store, state, operation, reason)
        operation = operation or state.operation or {}
        state.operation = operation
        state.pending = nil
        local now, month = native.now(), native.monthDuration()
        if operation.key then state.blockedCandidates[operation.key] = now + 3 * month end
        if operation.cleanupIncomplete or operation.unverifiedCreatedLine or operation.unverifiedCreatedVehicle then
            block(store, state, "A obra retornou entidades sem identificação; tentativa preservada: " .. tostring(reason))
        elseif operation.stage == "cleanup" and not operation.cleanupFailed then
            state.phase = "build"
            remember(state, "Desfazendo apenas os bens da tentativa: " .. tostring(reason))
            save(store, state)
        elseif operation.cleanupComplete or (#(operation.ownedEntities or {}) == 0 and #(operation.infrastructure or {}) == 0) then
            state.operation, state.scan, state.phase = nil, nil, "plan"
            state.nextScanAt = now + month
            state.status = "Procurando outra rota"
            remember(state, "Rota descartada: " .. tostring(reason))
            save(store, state)
        else
            block(store, state, "Tentativa preservada para conferência: " .. tostring(reason))
        end
    end

    function ret.handleEvent(_, store, _, id, name, payload)
        if id == "pichau_competitor_ai" then
            local state = store:get() or {}
            local request = state.operation and state.operation.preview
            if state.phase ~= "build" or not request or type(payload) ~= "table"
                or payload.token ~= request.token then return end
            if name == "pichauCompetitorPreviewStarted" then
                request.submitted = true
                request.submittedAt = native.now()
                save(store, state)
            elseif name == "pichauCompetitorPreviewResult" then
                local ok, operation, err = routes.acceptPreview(state.player, state.operation, payload)
                if not ok then failedOperation(store, state, operation, err); return end
                state.operation = operation
                remember(state, operation and operation.stage == "cleanup" and
                    "Retirando bens da tentativa rejeitada" or "Etapa de construção confirmada")
                save(store, state)
            end
            return
        end
        if id ~= "" or name ~= "initNewGame" then return end
        local state = store:get() or {}
        if state.version then return end
        local initialCapital = native.startingCapital and native.startingCapital() or DEFAULT_STARTING_CAPITAL
        state = {
            version = VERSION, companyName = "Viação Horizonte", phase = "create_player",
            status = "Inicializando", lastDecision = "Preparando empresa rival",
            initialCapital = initialCapital, routes = {}, blockedCandidates = {}, history = {},
            initializedAt = native.now(), compatibilityVerified = false,
        }
        if type(initialCapital) ~= "number" or initialCapital ~= initialCapital
            or initialCapital <= 0 or initialCapital == math.huge or initialCapital ~= math.floor(initialCapital) then
            block(store, state, "Capital inicial da rival inválido")
        else
            if store.subscribeToEvent then
                store:subscribeToEvent("pichauCompetitorPreviewStarted")
                store:subscribeToEvent("pichauCompetitorPreviewResult")
            end
            save(store, state)
        end
    end

    local function refresh(state)
        local snapshot = native.snapshot(state.player)
        if not snapshot then return false end
        state.balance = snapshot.balance
        state.monthlyCost = snapshot.monthlyCost or (snapshot.annualRunningCost or 0) / 12
        return type(state.balance) == "number" and state.balance == state.balance
    end

    local function accountMonth(state, now, month)
        if not state.lastMonthAt then state.lastMonthAt = now; return end
        if now - state.lastMonthAt < month then return end
        -- After a long gap, aggregate the interval but reset consecutive-month
        -- counters: missing observations must never fabricate three good months.
        local elapsed = (now - state.lastMonthAt) / month
        local fullObservation = elapsed < 1.25
        for _, route in ipairs(state.routes) do
            local stats = native.routeStats(state.player, route, state.lastMonthAt, now)
            route.ageMonths = (now - route.createdAt) / month
            route.vehicles = stats and #stats.vehicles or 0
            route.profit = stats and stats.profit or nil
            local average = route.samples and route.samples > 0 and route.occupancySum / route.samples or nil
            route.highMonths = fullObservation and average and average > .75 and (route.highMonths or 0) + 1 or 0
            route.lowLossMonths = fullObservation and average and average < .25 and route.profit and route.profit < 0 and (route.lowLossMonths or 0) + 1 or 0
            route.lossMonths = fullObservation and route.profit and route.profit < 0 and (route.lossMonths or 0) + 1 or 0
            route.occupancySum, route.samples = 0, 0
        end
        state.monthlyProfit = native.operatingProfit(state.player, state.lastMonthAt, now)
        state.lastMonthAt = now
        state.monthIndex = (state.monthIndex or 0) + 1
    end

    function ret.update(_, store, dt)
        if not dt or dt <= 0 then return end
        local state = store:get() or {}
        if not state.version then
            -- A script added to an existing save must not silently create a rival.
            return
        end
        if state.version == 1 then
            state.version = VERSION
            if state.phase == "blocked" and state.player == nil and state.lastDecision == OLD_NO_CAPITAL_REASON then
                state.initialCapital = native.startingCapital and native.startingCapital() or DEFAULT_STARTING_CAPITAL
                state.phase = "create_player"
                state.status = "Inicializando"
                state.pending = nil
                state.lastDecision = "Retomando inicialização com o capital configurado no mod"
            end
            save(store, state)
        end
        if state.version ~= VERSION then block(store, state, "Versão de estado incompatível"); return end
        if state.phase == "blocked" or state.phase == "inactive" then return end
        if state.pending then
            -- All commands execute synchronously in engine state. A saved pending
            -- marker means interrupted/unknown completion; never replay a purchase.
            block(store, state, "Comando interrompido: requer conferência de propriedade antes de retomar")
            return
        end
        if state.phase == "create_player" then
            if routes.readiness then
                local readiness = routes.readiness()
                if not readiness or not readiness.automaticPlacement then
                    block(store, state, readiness and (readiness.message or readiness.reason) or "Construção automática não validada")
                    return
                end
            end
            state.pending = "create_player"; save(store, state)
            native.newPlayer(state.companyName, {0.15, 0.55, 0.95}, function(player, err)
                state.pending = nil
                if not player then block(store, state, err); return end
                if player == native.getPlayer() then block(store, state, "A API retornou o jogador humano"); return end
                state.player, state.phase = player, "fund"
                remember(state, "Empresa criada; verificando conta própria")
                save(store, state)
            end)
            return
        end
        if state.phase == "fund" then
            if state.capitalized then state.phase = "plan"; save(store, state); return end
            local humanBefore = native.balance(native.getPlayer())
            state.pending = "fund"; save(store, state)
            native.fundToBalance(state.player, state.initialCapital, function(ok, err, balance)
                state.pending = nil
                if not ok then block(store, state, err); return end
                if native.balance(native.getPlayer()) ~= humanBefore then
                    block(store, state, "A capitalização alterou a conta humana; integração bloqueada"); return
                end
                state.balance, state.capitalized, state.phase = balance, true, "plan"
                state.status = "Procurando rota"
                remember(state, "Capital inicial registrado uma única vez na conta rival")
                save(store, state)
            end)
            return
        end
        if state.phase == "build" and state.operation and state.operation.preview then
            local request = state.operation.preview
            local now, month = native.now(), native.monthDuration()
            request.requestedAt = request.requestedAt or now
            if now - (request.submittedAt or request.requestedAt) > month then
                if request.submitted then
                    block(store, state, "Obra enviada sem confirmação do motor; não será repetida automaticamente")
                else
                    failedOperation(store, state, state.operation, "A interface não produziu uma prévia da obra")
                end
            else
                state.status = request.submitted and "Construindo" or "Conferindo custo e colisões"
                save(store, state)
            end
            return
        end
        if not refresh(state) then block(store, state, "Conta rival ausente ou inválida"); return end
        local now, month = native.now(), native.monthDuration()
        if type(now) ~= "number" or type(month) ~= "number" or month <= 0 then
            block(store, state, "Relógio da simulação indisponível"); return
        end

        if state.phase == "build" then
            state.pending = "build"; save(store, state)
            routes.stepBuild(state.player, state.operation, function(ok, operation, route, err)
                state.pending = nil
                if not ok then
                    failedOperation(store, state, operation, err or "Falha ao implantar rota"); return
                end
                state.operation = operation
                if route then
                    route.createdAt = now
                    route.highMonths, route.lowLossMonths, route.lossMonths = 0, 0, 0
                    route.samples, route.occupancySum, route.ageMonths = 0, 0, 0
                    state.routes[#state.routes + 1] = route
                    state.operation, state.phase = nil, "operate"
                    state.nextExpansionAt = now + 3 * month
                    state.status = "Verificando operação"
                    remember(state, "Linha inaugurada: " .. (route.name or tostring(route.line)))
                end
                save(store, state)
            end)
            return
        end

        if state.phase == "manage" then
            state.pending = "manage"; save(store, state)
            routes.stepManage(state.player, state.management, function(ok, op, err)
                state.pending = nil
                if not ok then
                    state.management = op or state.management
                    block(store, state, err); return
                end
                state.management = op
                if not op then
                    if state.managementAction == "close" then
                        for index = #state.routes, 1, -1 do
                            if state.routes[index].line == state.managementLine then
                                state.blockedCandidates[state.routes[index].key] = now + 3 * month
                                table.remove(state.routes, index)
                            end
                        end
                    end
                    state.managementAction, state.managementLine = nil, nil
                    state.phase = "operate"
                    remember(state, "Ajuste de frota concluído")
                end
                save(store, state)
            end)
            return
        end

        if #state.routes > 0 and (not state.lastSampleAt or now - state.lastSampleAt >= month / 30) then
            for _, route in ipairs(state.routes) do
                local stats = native.routeStats(state.player, route, now, now)
                if not stats or not stats.valid then block(store, state, "Rota perdeu propriedade ou infraestrutura: " .. tostring(route.line)); return end
                route.vehicles = #stats.vehicles
                if stats.occupancy then
                    route.occupancySum = (route.occupancySum or 0) + stats.occupancy
                    route.samples = (route.samples or 0) + 1
                end
                if stats.noPath then
                    state.status = "Rota sem caminho"
                    state.lastDecision = "Expansão suspensa até restabelecer o trajeto"
                    save(store, state); return
                end
            end
            state.lastSampleAt = now
        end
        accountMonth(state, now, month)

        if #state.routes > 0 and not state.compatibilityVerified then
            local first = state.routes[1]
            local stats = native.routeStats(state.player, first, first.createdAt, now)
            -- Before expansion there is exactly one line. Company cash-flow is
            -- valid evidence of independent operation, even if the engine does
            -- not publish account journals on individual route assets.
            local income = native.operatingIncome and native.operatingIncome(state.player, first.createdAt, now) or stats and stats.income
            local expenses = native.operatingExpenses and native.operatingExpenses(state.player, first.createdAt, now) or stats and stats.expenses
            if stats and stats.valid and income and income > 0 and expenses and expenses > 0 then
                state.compatibilityVerified = true
                remember(state, "Receitas e despesas próprias observadas; expansão liberada")
            elseif now - first.createdAt > 6 * month then
                block(store, state, "Sem comprovação de receitas e despesas após seis meses de operação"); return
            end
        end

        local vehicle = native.bestBus()
        if not vehicle then
            state.lastDecision = "Nenhum ônibus compatível e disponível neste ano"
            save(store, state); return
        end
        if state.phase == "operate" then
            if state.lastManagementMonth ~= state.monthIndex then
                state.lastManagementMonth = state.monthIndex
                for _, route in ipairs(state.routes) do
                    local action = policy.evaluateRoute({ageMonths=route.ageMonths, vehicleCount=route.vehicles,
                        highMonths=route.highMonths, lowLossMonths=route.lowLossMonths,
                        lossMonths=route.lossMonths, profit=route.profit},
                        {balance=state.balance, monthlyCost=state.monthlyCost, purchaseCost=vehicle.purchaseCost})
                    if action ~= "hold" then
                        state.management = {action=action, line=route.line, depot=route.depot, modelId=vehicle.modelId}
                        state.managementAction, state.managementLine = action, route.line
                        state.phase = "manage"
                        remember(state, "Ajustando frota: " .. action)
                        save(store, state); return
                    end
                end
            end
            if state.compatibilityVerified and #state.routes < policy.MAX_ROUTES and now >= (state.nextExpansionAt or now) then
                state.phase, state.scan = "plan", nil
            else state.status = "Operando"; save(store, state); return end
        end
        if state.phase == "plan" then
            if state.nextScanAt and now < state.nextScanAt then save(store, state); return end
            local plan, reason, cursor, finished = routes.scan(state.player, {
                routes=state.routes, blocked=state.blockedCandidates, cursor=state.scan,
                balance=state.balance, monthlyCost=state.monthlyCost, modelId=vehicle.modelId,
            })
            state.scan = cursor
            if plan then
                local cost = plan.buildCost + vehicle.purchaseCost
                -- Include the new bus in the reserve before committing any works.
                if policy.canSpend(state.balance, state.monthlyCost + vehicle.runningCost / 12, cost, true) then
                    state.attemptCounter = (state.attemptCounter or 0) + 1
                    plan.id = plan.key .. ":" .. tostring(now) .. ":" .. tostring(state.attemptCounter)
                    plan.modelId = vehicle.modelId
                    local reserve = policy.reserve(state.monthlyCost + vehicle.runningCost / 12)
                    local maxSpend = .4 * math.max(0, state.balance - reserve)
                    plan.budget = {maxSpend=maxSpend, remaining=maxSpend, reserve=reserve,
                        busCost=vehicle.purchaseCost, monthlyCost=state.monthlyCost,
                        busMonthlyCost=vehicle.runningCost / 12}
                    state.operation, state.phase = plan, "build"
                    remember(state, "Implantando " .. plan.name)
                else
                    state.nextScanAt = now + month
                    remember(state, "Aguardando capital e reserva para uma nova rota")
                end
            elseif finished then
                state.scan, state.nextScanAt = nil, now + month
                remember(state, reason or "Nenhuma rota viável encontrada")
            end
        end
        save(store, state)
    end
    return ret
end
return controller
