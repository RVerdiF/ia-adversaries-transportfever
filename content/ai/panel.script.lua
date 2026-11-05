local react = ug_require "/gui/main/react.lua"
local builtin = ug_require "/gui/main/builtin.lua"
local engine_react_util = ug_require "/gui/main/engine_react_util.tl"
local game_bar_widgets = ug_require "/gui/game_bar/game_bar_widgets.tl"
local lang_util = ug_require "/scripts/lang_util.tl"
local preview = ug_require "pichau_competitor_ai::/ai/preview.lua"

local function makeSnapshot()
	local entity = api.engine.system.gameScriptSystem.getEntityForGameScript("pichau_competitor_ai::/ai/competitor.gs")
	if entity == nil or entity == -1 then
		return nil
	end

	local gameScript = api.engine.getComponent(entity, api.type.ComponentType.GAME_SCRIPT)
	return gameScript and gameScript.state or nil
end

local function displayValue(value)
	if value == nil then
		return _("Indisponível")
	end
	return tostring(value)
end

local function displayMoney(value)
	if value == nil then
		return _("Indisponível")
	end
	return api.util.formatMoney(value)
end

local CompetitorAIPanel = react.RegisterPluginRecipe(game_bar_widgets.GameBarInfoDisplayExtension, "CompetitorAIPanel", function()
	local expanded = react.useState(false)
	local previewSession = react.useRefLazy(function() return preview.createSession(builtin, makeSnapshot) end)
	local snapshotState = engine_react_util.useStepStateTimer(makeSnapshot)
	local snapshot = snapshotState:old()
	local children = {
		builtin.Button{
			content = builtin.TextView{
				meta = { class = "font-scale-headline" },
				text = expanded:old() and _("Rival −") or _("Rival +"),
			},
			onClick = function()
				expanded:set(not expanded:old())
			end,
		},
	}
	-- The placement worker runs even when the informational panel is collapsed.
	local proposalPreview = previewSession:get().render(snapshot)
	if proposalPreview then children[#children + 1] = proposalPreview end

	if expanded:old() then
		local detailChildren = {}
		if snapshot then
			detailChildren[#detailChildren + 1] = builtin.TextView{
				meta = { class = "font-scale-body" },
				text = displayValue(snapshot.companyName),
			}
			detailChildren[#detailChildren + 1] = builtin.TextView{
				meta = { class = "font-scale-body" },
				text = lang_util.format(_("Status: {status}"), { status = displayValue(snapshot.status) }),
			}
			detailChildren[#detailChildren + 1] = builtin.TextView{
				meta = { class = "font-scale-body" },
				text = lang_util.format(_("Decisão: {decision}"), { decision = displayValue(snapshot.lastDecision) }),
			}
			detailChildren[#detailChildren + 1] = builtin.TextView{
				meta = { class = "font-scale-body" },
				text = lang_util.format(_("Saldo: {balance}"), { balance = displayMoney(snapshot.balance) }),
			}
			detailChildren[#detailChildren + 1] = builtin.TextView{
				meta = { class = "font-scale-body" },
				text = lang_util.format(_("Lucro mensal: {profit}"), { profit = displayMoney(snapshot.monthlyProfit) }),
			}

			for routeIndex, route in ipairs(snapshot.routes or {}) do
				detailChildren[#detailChildren + 1] = builtin.TextView{
					meta = { class = "font-scale-body" },
					text = lang_util.format(_("Linha {line}: {vehicles} veículos"), {
						line = displayValue(route.line),
						vehicles = displayValue(route.vehicles),
					}),
				}
			end
		else
			detailChildren[#detailChildren + 1] = builtin.TextView{
				meta = { class = "font-scale-body" },
				text = _("Sem dados da empresa rival"),
			}
		end

		children[#children + 1] = builtin.BoxLayout{
			orientation = builtin.type.Orientation.Vertical,
			children = detailChildren,
		}
	end

	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Horizontal,
		children = children,
	}
end)

return {
	CompetitorAIPanel = CompetitorAIPanel,
}
