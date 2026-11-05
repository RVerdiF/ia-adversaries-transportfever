local native = ug_require "pichau_competitor_ai::/ai/native.lua"
local routes = ug_require "pichau_competitor_ai::/ai/routes.lua"
local policy = ug_require "pichau_competitor_ai::/ai/policy.lua"
local controller = ug_require "pichau_competitor_ai::/ai/controller.lua"
local implementation = controller.create(native, routes, policy)
local result = {}
local function guarded(name)
    return function(params, store, ...)
        local ok, err = pcall(implementation[name], params, store, ...)
        if not ok then
            local state = store:get() or {}
            state.status = "Erro do script"
            state.phase = "blocked"
            state.lastDecision = tostring(err)
            state.pending = nil
            store:set(state)
            log.error("[pichau_competitor_ai] " .. tostring(err))
        end
    end
end
result.update = guarded("update")
result.handleEvent = guarded("handleEvent")
return result
