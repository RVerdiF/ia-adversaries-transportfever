-- Load the real module graph, reject an incomplete API, then exercise the
-- actual native bootstrap once the required engine functions are available.
local modules = {}
function ug_require(name)
    local relative = name:match("^pichau_competitor_ai::/(.+)$")
    assert(relative, "Unexpected native dependency during bootstrap: " .. tostring(name))
    if not modules[name] then modules[name] = dofile("content/" .. relative) end
    return modules[name]
end
local mutations, errors = 0, 0
api = {
    type = {ComponentType={GAME_TIME="time"}},
    engine = {
        util = {
            getPlayer=function() return 1 end,
            getWorld=function() return 0 end,
            finance={getPlayersBalance=function() return 1000000 end},
        },
        getComponent=function(_, kind)
            if kind == "time" then return {gameTime=0} end
            return nil
        end,
    },
    cmd = setmetatable({}, {__index=function()
        return function() mutations=mutations+1; error("No mutation allowed before readiness") end
    end}),
}
log = {error=function() errors=errors+1 end}
local script = dofile("content/ai/competitor.script.lua")
local store = {value={}}
function store:get() return self.value end
function store:set(value) self.value=value end
script.handleEvent({}, store, "", "", "initNewGame")
script.update({}, store, 1)
assert(store.value.phase == "blocked", "Missing native APIs must prevent company creation")
assert(store.value.player == nil, "No rival should be created before readiness")
assert(not store.value.capitalized, "No funding should occur before readiness")
assert(type(store.value.lastDecision) == "string" and #store.value.lastDecision > 0)
assert(mutations == 0, "Bootstrap attempted an engine mutation")
assert(errors == 0, "Bootstrap failed due to an unintended Lua error")
local diagnostic = store.value.lastDecision
script.update({}, store, 1)
assert(store.value.lastDecision == diagnostic, "Blocked state should stay inspectable")
assert(mutations == 0)

-- Positive path: every real module remains in use; only the C++ APIs below
-- are replaced. This catches a permanent readiness=false or a bad constructor
-- alias that an isolated controller mock would hide.
local cash = {[1]=1000000,[2]=0}
api.type.ComponentType.STATION="station"
api.type.ComponentType.STATION_GROUP="group"
api.type.ComponentType.VEHICLE_DEPOT="depot"
api.type.Line={new=function() return {} end,Stop={new=function() return {} end}}
api.type.StationTerminal={new=function() return {} end}
api.type.Vec3f={new=function(x,y,z) return {x=x,y=y,z=z} end}
api.type.JournalEntry={new=function() return {category={}} end,Type={INCOME="income",OTHER="other"}}
api.type.enum={TransportMode={BUS="bus"}}
api.engine.getRevision=function() return {num={1,2}} end
api.engine.util.pathfinding={findPathNodeToNode=function() return {} end}
api.engine.util.finance.getPlayersBalance=function(player) return cash[player] end
local created, funded = 0,0
api.cmd.makeGameAddPlayerCmd=function(name,color)
    assert(type(name)=="string" and color.x==.15)
    return {kind="create"}
end
api.cmd.makeJournalBookAssetCmd=function(player,entry)
    assert(player==2 and entry.category.type=="income")
    return {kind="fund",player=player,amount=entry.amount}
end
api.cmd.sendCommand=function(command,done)
    mutations=mutations+1
    if command.kind=="create" then created=created+1;done({resultEntity=2},true)
    elseif command.kind=="fund" then
        funded=funded+1;cash[command.player]=cash[command.player]+command.amount;done({},true)
    else error("Unexpected mutation during bootstrap") end
end
store.value={}
local subscriptions={}
function store:subscribeToEvent(name) subscriptions[name]=true end
script.handleEvent({},store,"","","initNewGame")
script.update({},store,1)
assert(store.value.player==2 and store.value.phase=="fund","Actual module graph must permit rival creation")
script.update({},store,1)
assert(store.value.capitalized and store.value.phase=="plan")
assert(cash[2]==1000000 and cash[1]==1000000 and created==1 and funded==1)
assert(subscriptions.pichauCompetitorPreviewStarted and subscriptions.pichauCompetitorPreviewResult)
script.handleEvent({},store,"","","initNewGame")
store.value.phase="fund"
script.update({},store,1)
assert(created==1 and funded==1,"Duplicate initialization must never repeat capital")
assert(errors==0)
print("entrypoint tests passed (real graph: capability check, create and fund once)")
