-- Native-shaped construction proposal and preview validation tests.
local function eq(a, b, message) assert(a == b, message .. ": expected " .. tostring(b) .. ", got " .. tostring(a)) end
local C = { owned="owned", edge="edge", street="street", group="group", station="station", depot="depot", construction="construction", edgeObject="edgeObject" }
local entities, revisions = {}, {}
local function entity(id, comps, rev) entities[id], revisions[id] = comps, rev or 1 end
api = {
 type = {
  ComponentType = { PLAYER_OWNED=C.owned, BASE_EDGE=C.edge, BASE_EDGE_STREET=C.street, STATION_GROUP=C.group, STATION=C.station, VEHICLE_DEPOT=C.depot, CONSTRUCTION=C.construction, EDGE_OBJECT=C.edgeObject },
  enum = { RoadType={STREET="street"}, BaseEdgeType={NORMAL="normal"} },
  SegmentAndEntity={new=function() return {} end},
  SimpleStreetProposal={new=function() return {} end, EdgeObject={new=function() return {} end}},
  SimpleProposal={new=function() return {} end, ConstructionEntity={new=function() return {} end}},
  Context={new=function() return {} end},
  Vec4f={new=function(...) return {...} end},
  Mat4f={new=function(...) return {cols={...}} end},
 },
 engine={
  getComponent=function(id, kind) return entities[id] and entities[id][kind] end,
  entityExists=function(id) return entities[id] ~= nil end,
  getRevision=function(id) return revisions[id] end,
  getEntitiesWithComponent=function(kind, filter)
   local found={}
   for id, comps in pairs(entities) do
    local owner=comps[C.owned]
    if comps[kind] and (not filter or not filter.requireOwnedByPlayer or (owner and owner.player==filter.requireOwnedByPlayer)) then found[#found+1]=id end
   end
   return found
  end,
  system={streetConnectorSystem={
   getConstructionEntityForDepot=function(id) return id==32 and 33 or -1 end,
   getConstructionEntityForStation=function(id) return id==31 and 33 or -1 end,
  }},
  util={getYear=function() return 2000 end, proposal={createProposalRemove=function(id, context) return {toRemove={id},context=context} end}},
 },
 res={constructionRep={find=function(name) return name=="bus_depot.con" and 7 or -1 end,get=function(id) return id==7 and {name="bus_depot.con"} end}},
}
local liveBalance=150
ug_require = function(path)
 if path == "pichau_competitor_ai::/ai/native.lua" then
  return {balance=function() return liveBalance end,canBuildResource=function() return true end}
 end
 error("unexpected require: " .. tostring(path))
end
local original = {roadType="street",type="normal",distance=40,objects={},node0=4,node1=5}
function original:clone() return {roadType=self.roadType,type=self.type,distance=self.distance,objects={},node0=self.node0,node1=self.node1} end
entity(10,{[C.edge]=original,[C.street]={precedenceNode0=2}}, {num={11,0,0}})
entity(30,{[C.owned]={player=9},[C.group]={stations={31}}})
entity(31,{[C.owned]={player=9},[C.station]={}})
entity(32,{[C.owned]={player=9},[C.depot]={}})
entity(33,{[C.owned]={player=9},[C.construction]={depots={32},stations={31}}})
entity(40,{[C.owned]={player=4},[C.construction]={}})
entity(34,{[C.owned]={player=9},[C.edgeObject]={}})
entity(35,{[C.owned]={player=9},[C.group]={stations={}}})
local publicRoad={roadType="street",type="normal",distance=40,objects={{34,"stop"}}}
entity(50,{[C.edge]=publicRoad,[C.street]={}})
local construction = dofile("content/ai/construction.lua")
local proposal = assert(construction.makeProposal(9,{kind="stop",edge={entity=10,revision={num={11,0,0}}},name="Central"}))
eq(proposal.streetProposal.edgesToRemove[1],10,"stop replaces selected edge")
eq(proposal.streetProposal.edgesToAdd[1].comp.node0,4,"edge geometry retained")
eq(proposal.streetProposal.edgesToAdd[1].streetEdge.precedenceNode0,2,"street component retained")
eq(proposal.streetProposal.edgeObjectsToAdd[1].playerEntity,9,"stop owner set")
eq(proposal.streetProposal.edgeObjectsToAdd[1].model,"::/street/small_stops/small_new.con","year-appropriate stop resource")
local ok, why, cost = construction.validatePreview(9,{kind="stop",edge={entity=10,revision={num={11,0,0}}}},proposal,{costs=120,errorState={critical=false},collisionInfo={collisionEntities={},buildingEntities={},autoRemovalEntity2models={}}},{remaining=200,reserve=30})
eq(ok,true,"safe stop preview accepted") eq(cost,120,"preview cost returned")
local safe = {errorState={critical=false},collisionInfo={collisionEntities={},buildingEntities={},autoRemovalEntity2models={}},costs=121}
ok,why = construction.validatePreview(9,{kind="stop",edge=10},proposal,safe,{remaining=150,reserve=30})
eq(ok,false,"reserve protected") eq(why,"preview_over_budget","reserve reason")
local changed = {kind="stop",edge={entity=10,revision=12}}
ok,why = construction.validatePreview(9,changed,proposal,safe,1000)
eq(ok,false,"changed edge rejected") eq(why,"source_edge_changed","stale edge reason")
local critical={errorState={critical=true},collisionInfo={},costs=5}
ok,why=construction.validatePreview(9,{kind="stop",edge=10},proposal,critical,100)
eq(ok,false,"critical proposal rejected") eq(why,"preview_critical_error","critical reason")
local building={errorState={critical=false},collisionInfo={buildingEntities={55},collisionEntities={},autoRemovalEntity2models={}},costs=5}
ok,why=construction.validatePreview(9,{kind="stop",edge=10},proposal,building,100)
eq(ok,false,"building removal rejected") eq(why,"preview_would_demolish_building","building reason")
local foreign={errorState={critical=false},collisionInfo={collisionEntities={},buildingEntities={},autoRemovalEntity2models={[40]={}}},costs=5}
ok,why=construction.validatePreview(9,{kind="stop",edge=10},proposal,foreign,100)
eq(ok,false,"foreign auto-removal rejected") eq(why,"preview_auto_removes_unexpected_entity","foreign removal reason")
local proposalError={costs=5,errorState={critical=false,messages={"overlap"}},collisionInfo={collisionEntities={},buildingEntities={},autoRemovalEntity2models={}}}
ok,why=construction.validatePreview(9,{kind="stop",edge=10},proposal,proposalError,100)
eq(ok,false,"proposal errors rejected") eq(why,"preview_error","proposal error reason")
local fullProposal={toRemove={},proposal={removedSegments={{entity=40}}}}
ok,why=construction.validatePreview(9,{kind="depot"},fullProposal,{costs=0,errorState={critical=false},collisionInfo={collisionEntities={},buildingEntities={},autoRemovalEntity2models={}}},100)
eq(ok,false,"full proposal unexpected removals rejected") eq(why,"preview_removes_unexpected_entity","full proposal removal reason")

local depot=assert(construction.makeProposal(9,{kind="depot",resource="bus_depot.con",params={x=2},site={x=4,y=7,z=1,heading=math.pi/2},name="Rival Depot"}))
local item=depot.constructionsToAdd[1]
eq(item.fileName,"bus_depot.con","construction resource") eq(item.playerEntity,9,"construction player") eq(item.params.x,2,"construction params")
eq(math.floor(item.transf.cols[1][2]+0.5),1,"yaw basis column") eq(item.transf.cols[4][1],4,"site translation x")
local _, missingReason=construction.makeProposal(9,{kind="depot",resource="missing.con",site={x=0,y=0}})
eq(missingReason,"construction_resource_missing","unknown construction rejected")
local _, ownerReason=construction.makeProposal(9,{kind="remove",entity=40})
eq(ownerReason,"remove_target_not_owned","cannot remove foreign object")
local remove=assert(construction.makeProposal(9,{kind="remove",entity=33}))
eq(remove.context.player,9,"removal context is competitor")
ok,why=construction.validatePreview(9,{kind="remove",entity=33},remove,{costs=0,errorState={critical=false},collisionInfo={collisionEntities={},buildingEntities={},autoRemovalEntity2models={}}},{remaining=10})
eq(ok,true,"owned removal preview accepted")
liveBalance=-25
ok,why,cost=construction.validatePreview(9,{kind="remove",entity=33},remove,{costs=-15,errorState={critical=false},collisionInfo={collisionEntities={},buildingEntities={},autoRemovalEntity2models={}}},{remaining=0,reserve=100,busCost=50})
eq(ok,true,"refund removal allowed while balance is negative") eq(cost,-15,"refund cost preserved")
ok,why=construction.validatePreview(9,{kind="remove",entity=33},remove,{costs=1,errorState={critical=false},collisionInfo={collisionEntities={},buildingEntities={},autoRemovalEntity2models={}}},{remaining=0})
eq(ok,false,"positive removal cost rejected at zero budget") eq(why,"preview_over_budget","positive removal budget reason")

local found=construction.identifyEntities(9,{{30,1},{31,2},{32,1},{33,2},{40,1}},"stop")
eq(#found.stationGroups,1,"station group identified once") eq(found.stationGroups[1],30,"station group id") eq(#found.infrastructure,2,"station assets retained")
eq(#found.cleanupEntities,1,"station resolves to single construction cleanup root") eq(found.cleanupEntities[1],33,"construction is physical cleanup root")
local built=construction.identifyEntities(9,{{32,1},{33,2},{40,1}},"depot")
eq(#built.depots,1,"depot filtered by owner") eq(built.depots[1],32,"depot id") eq(#built.infrastructure,2,"depot infrastructure tracked")
eq(#built.cleanupEntities,1,"depot and construction share cleanup root") eq(built.cleanupEntities[1],33,"depot physical root")
local roadOnly=construction.identifyEntities(9,{{50,11},{35,12}},"stop")
eq(#roadOnly.stationGroups,1,"station group returned alongside public road")
eq(roadOnly.stationGroups[1],35,"public road never becomes station group")
eq(#roadOnly.cleanupEntities,1,"public road receipt discovers owned edge object")
eq(roadOnly.cleanupEntities[1],34,"only edge object is cleanup target")
eq(roadOnly.infrastructure[1],34,"public road itself excluded from infrastructure")
eq(construction.getStationGroup(31,9),30,"station resolves parent group")
print("construction proposal tests passed")
