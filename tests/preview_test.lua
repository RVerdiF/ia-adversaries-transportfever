local makeFails, previewValid = false, true
local construction = {
    makeProposal=function(player,intent)
        assert(player == 2)
        if makeFails then return nil,"site_changed" end
        return {kind=intent.kind}
    end,
    validatePreview=function(player,intent,full,data,budget)
        assert(player == 2 and full.native and budget.remaining == 1000)
        if not previewValid then return false,"collision" end
        return true,nil,data.costs
    end,
}
function ug_require(name)
    assert(name == "pichau_competitor_ai::/ai/construction.lua")
    return construction
end
local events, builds, buildSuccess = {}, {}, true
api = {
    engine={util={getPlayer=function() return 1 end}},
    type={Context={new=function() return {} end}},
    cmd={
        makeScriptingSendEventCmd=function(src,id,name,payload)
            assert(id == "pichau_competitor_ai")
            return {event=name,payload=payload}
        end,
        makeWorldBuildProposalCmd=function(full,context,ignore,economic)
            assert(full.native and context.player == 2)
            assert(ignore == false and economic == true)
            return {build=true}
        end,
        sendCommand=function(cmd,done)
            if cmd.event then events[#events+1]=cmd
            else
                builds[#builds+1]=cmd
                done({resultEntities={{30,{}},{30,{}},{31,{}}},resultProposalData={costs=100}},buildSuccess)
            end
        end,
    },
}
local preview=dofile("content/ai/preview.lua")
local builtin={ProposalViewer=function(params) return params end}
local function state(token,kind)
    return {phase="build",player=2,operation={preview={token=token,
        intent={kind=kind or "stop"},budget={remaining=1000}}}}
end
local current
local function session() return preview.createSession(builtin,function() return current end) end
local function reset() events,builds={},{}; makeFails=false;previewValid=true;buildSuccess=true end

-- The renderer only previews; a validated callback is the mutation boundary.
reset();current=state("one")
local worker=session()
local node=worker.render(current)
assert(node.simpleProposal and #builds==0 and #events==0)
node.onCreateProposalData({costs=100},{native=true})
assert(#builds==1 and #events==2)
assert(events[1].event==preview.START_EVENT)
local receipt=events[2].payload
assert(events[2].event==preview.RESULT_EVENT and receipt.success)
assert(receipt.token=="one" and receipt.cost==100 and #receipt.entities==2)
assert(receipt.entities[1]==30 and receipt.entities[2]==31)
node.onCreateProposalData({costs=100},{native=true})
assert(#builds==1,"Repeated preview callbacks must never duplicate a build")
assert(worker.render(current)==nil)

-- Callbacks for an abandoned/replaced operation cannot authorize construction.
reset();current=state("old")
worker=session();node=worker.render(current)
current=state("new")
node.onCreateProposalData({costs=100},{native=true})
assert(#builds==0 and #events==0)

reset();current=state("collision");previewValid=false
node=session().render(current)
node.onCreateProposalData({costs=100},{native=true})
assert(#builds==0 and #events==1 and events[1].payload.reason=="collision")

reset();current=state("missing_full")
node=session().render(current)
node.onCreateProposalData({costs=100},nil)
assert(#builds==0 and events[1].payload.success==false)

-- After reload, a submitted marker is authoritative even with an empty GUI cache.
reset();current=state("submitted");current.operation.preview.submitted=true
assert(session().render(current)==nil and #events==0)

reset();current=state("changed_site");makeFails=true
assert(session().render(current)==nil)
assert(#builds==0 and events[1].payload.reason=="site_changed")

reset();current=state("rejected");buildSuccess=false
node=session().render(current)
node.onCreateProposalData({costs=100},{native=true})
assert(#builds==1 and events[2].payload.success==false)

reset();current=state("remove","remove")
node=session().render(current)
assert(node.proposal and node.simpleProposal==nil,"Cleanup uses a processed Proposal")

reset();current=state("human");current.player=1
assert(session().render(current)==nil and #builds==0)
print("preview bridge tests passed")
