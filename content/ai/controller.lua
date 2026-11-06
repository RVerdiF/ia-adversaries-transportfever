-- Simulation controller. Dependencies are injected to exercise recovery without
-- the game and to keep API commands out of the decision policy.
local controller = {}
local VERSION = 2
local DEFAULT_STARTING_CAPITAL = 10000000
local OLD_NO_CAPITAL_REASON = "A rival exige uma partida com capital inicial finito e positivo"
local READINESS_VERSION = 3
local OLD_READINESS_REASON = "APIs necessárias para planejar, pré-visualizar ou conectar a rota indisponíveis."

function controller.create(native, routes, policy)
    local ret = {}
    local function save(store, state) store:set(state) end
    local function block(store, state, reason, category)
        state.phase = "blocked"
        state.status = "Integração interrompida"
        state.lastDecision = tostring(reason)
        state.blockedReasonCategory = category
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
        if operation.stage == "command_indeterminate" then
            block(store, state, "Comando de rota sem confirmação; tentativa preservada: " ..
                tostring(operation.indeterminateReason or reason))
        elseif operation.cleanupIncomplete or operation.unverifiedCreatedLine or operation.unverifiedCreatedVehicle then
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

    -- Single bootstrap path. initNewGame covers new games; update covers the mod
    -- being enabled on an existing save, where no init event is ever delivered.
    local function initialize(store)
        local initialCapital = native.startingCapital and native.startingCapital() or DEFAULT_STARTING_CAPITAL
        local state = {
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
        return state
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
        initialize(store)
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
            -- A script enabled on an existing save never receives initNewGame, so
            -- bootstrap exactly like a new game instead of staying silently inert.
            -- initialize() persists the versioned state, keeping this idempotent.
            state = initialize(store)
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
        -- Recover only the two bootstrap actions. A marker is written before
        -- sending either command; if completion cannot be proven from world
        -- state, stop rather than issuing it again.
        if state.version == VERSION and state.pending == "create_player" then
            local matches = native.playersNamed and native.playersNamed(state.companyName) or {}
            if #matches == 1 and matches[1] ~= native.getPlayer() then
                state.player, state.phase, state.pending = matches[1], "fund", nil
                remember(state, "Empresa encontrada após comando de criação")
                save(store, state)
            elseif #matches > 1 then
                block(store, state, "Mais de uma empresa corresponde ao nome da rival")
                return
            else
                block(store, state, "Criação enviada sem confirmação; não será repetida automaticamente")
                return
            end
        elseif state.version == VERSION and state.pending == "fund" then
            local balance = state.player and native.balance(state.player)
            local humanBalance = native.balance(native.getPlayer())
            if type(balance) == "number" and balance == state.initialCapital
                and state.humanBalanceBeforeFunding ~= nil
                and humanBalance == state.humanBalanceBeforeFunding then
                state.balance, state.capitalized, state.phase, state.pending = balance, true, "plan", nil
                state.humanBalanceBeforeFunding = nil
                state.status = "Procurando rota"
                remember(state, "Capital inicial confirmada na conta rival")
                save(store, state)
            elseif state.fundSentAt ~= nil and balance == state.fundBalanceBefore
                and humanBalance == state.humanBalanceBeforeFunding
                and native.now() - state.fundSentAt < native.monthDuration() / 4 then
                state.status = "Aguardando registro do capital"
                save(store, state)
                return
            else
                block(store, state, "Capitalização enviada sem confirmação; não será repetida automaticamente")
                return
            end
        elseif state.version == VERSION and state.phase == "blocked" and state.player ~= nil
            and state.lastDecision == "balance_did_not_reach_target" then
            -- Older revisions sent the journal command, then checked the balance
            -- before the engine applied it. Reconcile without another deposit.
            local balance = native.balance(state.player)
            local humanBalance = native.balance(native.getPlayer())
            if balance == state.initialCapital and state.humanBalanceBeforeFunding ~= nil
                and humanBalance == state.humanBalanceBeforeFunding then
                state.balance, state.capitalized, state.phase = balance, true, "plan"
                state.humanBalanceBeforeFunding = nil
                state.status = "Procurando rota"
                remember(state, "Capital anterior confirmado na conta rival")
                save(store, state)
            else
                return
            end
        elseif state.version == VERSION and state.phase == "blocked" and state.player == nil
            and state.pending == nil and state.lastDecision
            and (tostring(state.lastDecision):find("Callbacks are currently disallowed", 1, true)
                or tostring(state.lastDecision):find("Cannot loop over this component type", 1, true)) then
            -- Upgrade path for saves blocked by former bootstrap API mistakes.
            state.phase, state.status = "create_player", "Recuperando empresa rival"
            state.lastDecision = "Verificando se a empresa já foi criada"
            save(store, state)
        end
        if state.version ~= VERSION then block(store, state, "Versão de estado incompatível"); return end
        if state.phase == "blocked" then
            local oldReadinessBlock = state.blockedReasonCategory == nil
                and state.player == nil and state.pending == nil and state.operation == nil
                and state.lastDecision == OLD_READINESS_REASON
            local retryReadiness = state.blockedReasonCategory == "readiness" or oldReadinessBlock
            if retryReadiness and state.player == nil and state.pending == nil
                and state.operation == nil and state.readinessVersion ~= READINESS_VERSION then
                state.readinessVersion = READINESS_VERSION
                state.blockedReasonCategory = nil
                state.phase = "create_player"
                state.status = "Validando integração"
                state.lastDecision = "Revalidando APIs de rota após atualização"
                state.initialCapital = native.startingCapital and native.startingCapital() or DEFAULT_STARTING_CAPITAL
                save(store, state)
            else
                return
            end
        end
        if state.phase == "inactive" then return end
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
                    state.readinessVersion = READINESS_VERSION
                    block(store, state,
                        readiness and (readiness.message or readiness.reason) or "Construção automática não validada",
                        "readiness")
                    return
                end
            end
            local matches = native.playersNamed and native.playersNamed(state.companyName) or {}
            if #matches == 1 and matches[1] ~= native.getPlayer() then
                state.player, state.phase = matches[1], "fund"
                remember(state, "Empresa rival existente reconciliada")
                save(store, state); return
            elseif #matches == 1 then
                block(store, state, "O nome da rival corresponde ao jogador humano"); return
            elseif #matches > 1 then
                block(store, state, "Mais de uma empresa corresponde ao nome da rival"); return
            end
            state.pending = "create_player"; save(store, state)
            local sent, err = native.newPlayer(state.companyName, {0.15, 0.55, 0.95})
            if not sent then block(store, state, err); return end
            return
        end
        if state.phase == "fund" then
            if state.capitalized then state.phase = "plan"; save(store, state); return end
            local humanBefore = native.balance(native.getPlayer())
            local rivalBefore = native.balance(state.player)
            state.humanBalanceBeforeFunding = humanBefore
            state.fundBalanceBefore = rivalBefore
            state.fundSentAt = native.now()
            state.pending = "fund"; save(store, state)
            local ok, err, balance = native.fundToBalance(state.player, state.initialCapital)
            if not ok then block(store, state, err); return end
            local humanAfter = native.balance(native.getPlayer())
            if humanBefore == nil or humanAfter ~= humanBefore then
                block(store, state, "A capitalização alterou ou não confirmou a conta humana; integração bloqueada"); return
            end
            if balance == state.initialCapital then
                state.pending = nil
                state.humanBalanceBeforeFunding = nil
                state.balance, state.capitalized, state.phase = balance, true, "plan"
                state.status = "Procurando rota"
                remember(state, "Capital inicial registrado uma única vez na conta rival")
                save(store, state)
            end
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
