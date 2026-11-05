-- Run from the mod directory with:
-- tools/lua/node_modules/.bin/fengari.cmd tests/panel_test.lua

local gameScriptState = {
	companyName = "Companhia Teste",
	status = "ativa",
	lastDecision = "comprou veículo",
	balance = 12000,
	monthlyProfit = nil,
	routes = {
		{ line = "Linha Azul", vehicles = 3 },
		{ line = "Linha Verde", vehicles = 1 },
	},
}

local expandedValue = false
local registeredRecipe
local requestedGameScript
local requestedComponent

_ = function(text)
	return text
end

local function builtinNode(kind)
	return function(params)
		params.kind = kind
		return params
	end
end

local builtin = {
	type = { Orientation = { Horizontal = "horizontal", Vertical = "vertical" } },
	Button = builtinNode("Button"),
	TextView = builtinNode("TextView"),
	BoxLayout = builtinNode("BoxLayout"),
}

local react = {
	useRefLazy = function(fn)
		local value = fn()
		return {get=function() return value end}
	end,
	RegisterPluginRecipe = function(_extension, name, recipe)
		registeredRecipe = { name = name, recipe = recipe }
		return recipe
	end,
	useState = function()
		return {
			old = function()
				return expandedValue
			end,
			set = function(_self, value)
				expandedValue = value
			end,
		}
	end,
}

local engineReactUtil = {
	useStepStateTimer = function(makeState)
		local state = makeState()
		return { old = function() return state end }
	end,
}

local gameBarWidgets = { GameBarInfoDisplayExtension = {} }
local langUtil = {
	format = function(template, values)
		return (template:gsub("{([%w_]+)}", function(key)
			return tostring(values[key])
		end))
	end,
}

ug_require = function(path)
	if path == "pichau_competitor_ai::/ai/preview.lua" then
		return {createSession=function() return {render=function() return nil end} end}
	end
	if path == "::/gui/main/react.lua" then return react end
	if path == "::/gui/main/builtin.lua" then return builtin end
	if path == "::/gui/main/engine_react_util.tl" then return engineReactUtil end
	if path == "::/gui/game_bar/game_bar_widgets.tl" then return gameBarWidgets end
	if path == "::/scripts/lang_util.tl" then return langUtil end
	error("unexpected ug_require path: " .. tostring(path))
end

api = {
	engine = {
		system = {
			gameScriptSystem = {
				getEntityForGameScript = function(name)
					requestedGameScript = name
					return "rival-entity"
				end,
			},
		},
		getComponent = function(entity, componentType)
			assert(entity == "rival-entity")
			requestedComponent = componentType
			return { state = gameScriptState }
		end,
	},
	util = {
		formatMoney = function(value)
			return "$" .. tostring(value)
		end,
	},
	type = { ComponentType = { GAME_SCRIPT = "GAME_SCRIPT" } },
}

local panel = dofile("content/ai/panel.script.lua")
assert(registeredRecipe and registeredRecipe.name == "CompetitorAIPanel")
assert(panel.CompetitorAIPanel == registeredRecipe.recipe)

local function walk(node, visit)
	if type(node) ~= "table" then return end
	visit(node)
	if type(node.children) == "table" then
		for _, child in ipairs(node.children) do walk(child, visit) end
	end
	if node.content then walk(node.content, visit) end
end

local function collectText(tree)
	local found = {}
	walk(tree, function(node)
		if node.kind == "TextView" then found[#found + 1] = node.text end
	end)
	return found
end

local compactTree = panel.CompetitorAIPanel()
assert(requestedGameScript == "pichau_competitor_ai::/ai/competitor.gs")
assert(requestedComponent == "GAME_SCRIPT")
local compactTexts = collectText(compactTree)
assert(compactTexts[1] == "Rival +", "collapsed panel should show rival toggle")
assert(#compactTexts == 1, "collapsed panel should stay compact")

local toggleButton
walk(compactTree, function(node)
	if node.kind == "Button" then toggleButton = node end
end)
assert(toggleButton and type(toggleButton.onClick) == "function", "button should use native onClick callback")
toggleButton.onClick()

local expandedTree = panel.CompetitorAIPanel()
local expandedTexts = collectText(expandedTree)
local combined = table.concat(expandedTexts, "\n")
assert(expandedTexts[1] == "Rival −", "expanded panel should show collapse toggle")
assert(combined:find("Companhia Teste", 1, true), "company name should be displayed")
assert(combined:find("Status: ativa", 1, true), "status should be displayed")
assert(combined:find("Decisão: comprou veículo", 1, true), "last decision should be displayed")
assert(combined:find("Saldo: $12000", 1, true), "balance should be formatted")
assert(combined:find("Lucro mensal: Indisponível", 1, true), "nullable profit should display as unavailable")
assert(combined:find("Linha Linha Azul: 3 veículos", 1, true), "route rows should be displayed")
assert(combined:find("Linha Linha Verde: 1 veículos", 1, true), "all routes should be displayed")

gameScriptState = nil
local missingTree = panel.CompetitorAIPanel()
local missingTexts = collectText(missingTree)
local missingCombined = table.concat(missingTexts, "\n")
assert(missingCombined:find("Sem dados da empresa rival", 1, true), "missing state should be handled")

print("panel mock tests passed")
