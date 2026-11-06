local react = ug_require "::/gui/main/react.lua"
local builtin = ug_require "::/gui/main/builtin.lua"
local engine_react_util = ug_require "::/gui/main/engine_react_util.tl"
local game_bar_widgets = ug_require "::/gui/game_bar/game_bar_widgets.tl"
local game_react_globals = ug_require "::/gui/main/game_react_globals.tl"
local lang_util = ug_require "::/scripts/lang_util.tl"
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

local function addWrappedText(children, value)
	local line = ""
	for word in tostring(value):gmatch("%S+") do
		if line ~= "" and #line + #word + 1 > 58 then
			children[#children + 1] = builtin.TextView{ meta = { class = "font-scale-body" }, text = line }
			line = word
		else
			line = line == "" and word or line .. " " .. word
		end
	end
	if line ~= "" then
		children[#children + 1] = builtin.TextView{ meta = { class = "font-scale-body" }, text = line }
	end
end

local RivalWindow
RivalWindow = react.RegisterWrapperRecipe("CompetitorAIWindow", builtin.Window, function()
	local snapshotState = engine_react_util.useStepStateTimer(makeSnapshot)
	local snapshot = snapshotState:old()
	local detailChildren = {}
		if snapshot then
			addWrappedText(detailChildren, lang_util.format(_("Decisão: {decision}"), { decision = displayValue(snapshot.lastDecision) }))
			addWrappedText(detailChildren, lang_util.format(_("Status: {status}"), { status = displayValue(snapshot.status) }))
			addWrappedText(detailChildren, lang_util.format(_("Empresa: {company}"), { company = displayValue(snapshot.companyName) }))
			addWrappedText(detailChildren, lang_util.format(_("Saldo: {balance}"), { balance = displayMoney(snapshot.balance) }))
			addWrappedText(detailChildren, lang_util.format(_("Capital inicial: {capital}"), { capital = displayMoney(snapshot.initialCapital) }))
			addWrappedText(detailChildren, lang_util.format(_("Lucro mensal: {profit}"), { profit = displayMoney(snapshot.monthlyProfit) }))

			for routeIndex, route in ipairs(snapshot.routes or {}) do
				addWrappedText(detailChildren, lang_util.format(_("Linha {line}: {vehicles} veículos"), {
						line = displayValue(route.line),
						vehicles = displayValue(route.vehicles),
					}))
			end
		else
			addWrappedText(detailChildren, _("Sem dados da empresa rival"))
		end
	return builtin.Window{
		title = _("Empresa rival"),
		closable = true,
		movable = true,
		onClose = function()
			local windowApi = game_react_globals.getDefaultWindowApi()
			if windowApi then windowApi.removeAllWindows(RivalWindow) end
		end,
		content = builtin.BoxLayout{
			orientation = builtin.type.Orientation.Vertical,
			children = detailChildren,
		},
	}
end)

local CompetitorAIPanel = react.RegisterPluginRecipe(game_bar_widgets.GameBarInfoDisplayExtension, "CompetitorAIPanel", function()
	local previewSession = react.useRefLazy(function() return preview.createSession(builtin, makeSnapshot) end)
	local snapshotState = engine_react_util.useStepStateTimer(makeSnapshot)
	local snapshot = snapshotState:old()
	local children = {
		builtin.Button{
			content = builtin.TextView{ meta = { class = "font-scale-headline" }, text = _("Rival") },
			onClick = function()
				local windowApi = game_react_globals.getDefaultWindowApi()
				if windowApi then
					windowApi.addSingletonWindow(RivalWindow, {})
					windowApi.moveSingletonWindowToFront(RivalWindow)
				end
			end,
		},
	}
	-- Keep the placement worker active while the window is closed.
	local proposalPreview = previewSession:get().render(snapshot)
	if proposalPreview then children[#children + 1] = proposalPreview end

	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Horizontal,
		children = children,
	}
end)

return {
	CompetitorAIPanel = CompetitorAIPanel,
}
