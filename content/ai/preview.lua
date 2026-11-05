-- GUI-side SimpleProposal -> Proposal bridge. The native ProposalViewer
-- performs the same conversion and collision/cost preview as the game UI.
-- Native userdata never crosses the GUI/engine event boundary: only the
-- checked build command runs here, and its primitive receipt is sent back.
local construction = ug_require "pichau_competitor_ai::/ai/construction.lua"
local preview = {}
preview.START_EVENT = "pichauCompetitorPreviewStarted"
preview.RESULT_EVENT = "pichauCompetitorPreviewResult"

local function emit(name, payload)
    api.cmd.sendCommand(api.cmd.makeScriptingSendEventCmd(
        "pichau_competitor_ai::/ai/competitor.gs", "pichau_competitor_ai", name, payload))
end

local function ids(result)
    local output, seen = {}, {}
    for _, entry in ipairs(result or {}) do
        local entity = type(entry) == "number" and entry or entry[1]
        if type(entity) == "number" and entity >= 0 and not seen[entity] then
            seen[entity], output[#output + 1] = true, entity
        end
    end
    return output
end

function preview.createSession(builtin, getCurrentSnapshot)
    local session = {submitted = {}}

    local function isCurrent(player, token)
        local state = getCurrentSnapshot()
        local request = state and state.operation and state.operation.preview
        return state and state.phase == "build" and state.player == player
            and request and request.token == token and not request.submitted
    end

    function session.render(snapshot)
        local request = snapshot and snapshot.operation and snapshot.operation.preview
        if not request or not request.token or request.submitted
            or snapshot.phase ~= "build" or session.submitted[request.token] then return nil end
        if session.currentToken ~= request.token then
            session.currentToken, session.submitted = request.token, {}
        end
        local player, token = snapshot.player, request.token
        if player == api.engine.util.getPlayer() then return nil end
        local ok, simple, reason = pcall(construction.makeProposal, player, request.intent)
        if not ok or not simple then
            session.submitted[token] = true
            emit(preview.RESULT_EVENT, {token=token, success=false, entities={}, cost=0,
                reason=ok and reason or tostring(simple)})
            return nil
        end
        local params = {
            entityForRefundableContext = player,
            proposalId = "pichau_competitor_ai:" .. token,
            onCreateProposalData = function(data, full)
                if session.submitted[token] or not isCurrent(player, token) then return end
                session.submitted[token] = true
                if not full then
                    emit(preview.RESULT_EVENT, {token=token,success=false,entities={},cost=0,
                        reason="A prévia nativa não retornou a proposta processada"})
                    return
                end
                local checked, valid, why, cost = pcall(construction.validatePreview,
                    player, request.intent, full, data, request.budget)
                if not checked or not valid then
                    emit(preview.RESULT_EVENT, {token=token,success=false,entities={},cost=0,
                        reason=checked and why or tostring(valid)})
                    return
                end
                -- Persist the intent before queueing its mutation. A loaded save
                -- containing this marker must reconcile instead of resubmitting.
                emit(preview.START_EVENT, {token=token})
                local context = api.type.Context.new()
                context.player = player
                -- Fourth argument true is also used by native economic builders
                -- (bridge_and_tunnel.tl), enabling normal construction accounting.
                local command = api.cmd.makeWorldBuildProposalCmd(full, context, false, true)
                api.cmd.sendCommand(command, function(result, success, resultEntities)
                    local actualCost = result and result.resultProposalData and result.resultProposalData.costs or cost
                    local entities = ids(result and result.resultEntities or resultEntities)
                    local withinQuote = type(actualCost) == "number" and actualCost == actualCost
                        and actualCost <= cost
                    emit(preview.RESULT_EVENT, {token=token,success=success == true and withinQuote,
                        entities=entities,cost=actualCost,
                        reason=not success and "O motor rejeitou a construção" or
                            not withinQuote and "O custo executado excedeu a prévia aprovada" or nil})
                end)
            end,
        }
        if request.intent.kind == "remove" then params.proposal = simple
        else params.simpleProposal = simple end
        return builtin.ProposalViewer(params)
    end
    return session
end
return preview
