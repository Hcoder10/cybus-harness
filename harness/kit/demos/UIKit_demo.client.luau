-- UIKit demo: every component in every theme. Drop in StarterPlayerScripts (needs ReplicatedStorage.Kit.UIKit).
-- Cycles theme -> pages (HUD 9 s, MENUS 8 s, RESULTS 6 s). For screenshots, lock it with attributes on workspace:
--   workspace:SetAttribute("UIKitDemoTheme", "toon")   -- arcade | cozy | tactical | fantasy | toon
--   workspace:SetAttribute("UIKitDemoPage", "hud")      -- hud | menus | results
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local UIKit = require(ReplicatedStorage:WaitForChild("Kit"):WaitForChild("UIKit"))

local THEMES = { "arcade", "cozy", "tactical", "fantasy", "toon" }
local PAGES = { { "hud", 9 }, { "menus", 8 }, { "results", 6 } }
local player = Players.LocalPlayer

local layer = UIKit.layer("UIKitDemoLabel", 50)
local caption = Instance.new("TextLabel")
caption.BackgroundTransparency = 0.4
caption.BackgroundColor3 = Color3.new(0, 0, 0)
caption.TextColor3 = Color3.new(1, 1, 1)
caption.Font = Enum.Font.GothamBold
caption.TextSize = 18
caption.AnchorPoint = Vector2.new(0.5, 1)
caption.Position = UDim2.new(0.5, 0, 1, -4)
caption.Size = UDim2.fromOffset(420, 26)
caption.Parent = layer

local function worldPoint()
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if hrp then
		return hrp.Position + hrp.CFrame.LookVector * 6 + Vector3.new(math.random(-3, 3), 2, math.random(-2, 2))
	end
	local cam = workspace.CurrentCamera
	return (cam.CFrame * CFrame.new(math.random(-4, 4), math.random(-1, 2), -14)).Position
end

local ITEMS = {
	{ name = "Sword", glyph = "Sw", rarity = "legendary" },
	{ name = "Bow", glyph = "Bo", rarity = "epic", count = 1 },
	{ name = "Potion", glyph = "Po", rarity = "uncommon", count = 12 },
	{ name = "Shield", glyph = "Sh", rarity = "rare" },
	{ name = "Bread", glyph = "Br", rarity = "common", count = 5 },
	{ name = "Gem", glyph = "Ge", rarity = "mythic", count = 3 },
}

-- Each page builds its components and returns a step(i) run every 0.5 s.
local function hudPage()
	local safe = UIKit.safeTop()
	local coins = UIKit.counter({ label = "COINS", value = 1250, glyph = "$" })
	local gems = UIKit.counter({ label = "GEMS", value = 40, glyph = "G", color = UIKit.current.c.accent2, position = UDim2.fromOffset(40, safe + 116) })
	local ring = UIKit.ring({ size = 110, value = 0.1, label = "CHARGE", position = UDim2.fromOffset(470, safe + 70) })
	local timer = UIKit.timer({ seconds = 14, warnAt = 10 })
	local mini = UIKit.minimap({ range = 120, parts = workspace:FindFirstChild("Map") or workspace, label = "COURSE" })
	mini:mark("goal", { at = worldPoint() + Vector3.new(40, 0, -60), color = UIKit.current.c.good, glyph = "!", pulse = true })
	local standings = UIKit.standings({ title = "STANDINGS", rows = {
		{ name = "YOU", value = 0, you = true }, { name = "KAIRA", value = 0 }, { name = "NOX", value = 0 }, { name = "PIP", value = 0 },
	} })
	local objectives = UIKit.objectiveTracker({ items = {
		"Reach the lighthouse", { text = "Collect stars", progress = 0, max = 3 }, "Defeat the boss",
	} })
	local hp = UIKit.bar({ label = "HEALTH", value = 100, max = 100, segments = 5, position = UDim2.new(0, 40, 1, -40) })
	local stamina = UIKit.bar({ label = "STAMINA", value = 70, max = 100, height = 22, width = 340, color = UIKit.current.c.accent2, format = "percent", position = UDim2.new(0, 40, 1, -130) })
	local hotbar = UIKit.hotbar({ items = ITEMS })
	local dial = UIKit.dial({ max = 160, redline = 130, unit = "KM/H", label = "SPEED" })
	local ammo = UIKit.ammo({ mag = 30, magSize = 30, reserve = 120, weapon = "VANDAL", position = UDim2.new(1, -40, 1, -350) })
	local cross = UIKit.crosshair({})
	local prompt = UIKit.prompt({ key = "E", label = "Open chest" })
	local toasts = UIKit.toasts({ position = UDim2.new(1, -330, 0, safe + 20) })
	local banner = UIKit.banner("ROUND 1", { sub = "FIGHT!", hidden = true })
	local count = UIKit.countdown({})
	count:start(3, function()
		task.delay(0.7, function()
			banner:flash(1.4)
		end)
	end, 0.6)
	local scores = { YOU = 0, KAIRA = 0, NOX = 0, PIP = 0 }
	local mag, hpv, charge = 30, 100, 0.1
	return function(i)
		dial:set(60 + math.sin(i * 0.7) * 50 + math.random(0, 30))
		cross:set({ spread = math.random() * 0.4 })
		cross:kick(0.6)
		if i % 3 == 0 then
			cross:hit(i % 9 == 0 and "kill" or "hit")
		end
		mag -= 3
		if mag <= 0 then
			ammo:set(0)
			if not ammo.reloading then
				ammo:reload(1.2, function()
					mag = 30
					ammo:set(30, 90)
				end)
			end
		else
			ammo:set(mag)
		end
		prompt:progress((i % 6) / 5)
		if i % 6 == 5 then
			prompt:press()
		end
		if i % 2 == 0 then
			coins:set(coins.value + math.random(5, 60))
			hpv = hpv > 30 and hpv - math.random(12, 30) or 100
			hp:set(hpv)
			stamina:set(math.random(10, 100))
			charge = charge >= 1 and 0 or math.min(1, charge + 0.22)
			ring:set(charge)
			for name in scores do
				scores[name] += math.random(0, 5)
			end
			local rows = {}
			for name, v in scores do
				table.insert(rows, { name = name, value = v, you = name == "YOU" })
			end
			table.sort(rows, function(a, b)
				return a.value > b.value
			end)
			standings:set(rows)
			UIKit.damage(worldPoint(), math.random(8, 140), { kind = ({ "normal", "normal", "crit", "heal" })[i % 4 + 1] })
			hotbar:select((i / 2) % #ITEMS + 1)
		end
		if i == 4 then
			objectives:progress(2, 1)
			gems:set(45)
		elseif i == 6 then
			objectives:check(1)
			toasts:push("Lighthouse reached", { kind = "good", body = "+250 XP" })
		elseif i == 8 then
			objectives:progress(2, 3)
			toasts:push("Low health", { kind = "bad" })
		elseif i == 10 then
			toasts:push("Legendary drop!", { kind = "reward", glyph = "*" })
			UIKit.popup("+1", { at = UDim2.fromScale(0.5, 0.6) })
		elseif i == 12 then
			objectives:check(3)
			timer:set(5)
		end
	end
end

local function menusPage()
	local panel = UIKit.panel({ title = "BACKPACK", tabs = { "ITEMS", "SHOP", "QUESTS" }, size = Vector2.new(1040, 560) })
	local grid = UIKit.grid({ parent = panel.pages.ITEMS, columns = 6, rows = 2, items = ITEMS, position = UDim2.fromScale(0.5, 0.45), anchor = Vector2.new(0.5, 0.5) })
	grid:select(1)
	local cards = {}
	for i, spec in {
		{ name = "Storm Blade", rarity = "legendary", price = 1200, badge = "NEW" },
		{ name = "Pet Fox", rarity = "epic", price = 650, badge = "-30%" },
		{ name = "Old Boots", rarity = "common", price = 40, owned = true },
	} do
		spec.parent = panel.pages.SHOP
		spec.position = UDim2.new(0, 150 + (i - 1) * 330, 0.5, 0)
		spec.anchor = Vector2.new(0.5, 0.5)
		spec.affordable = i ~= 1
		spec.onBuy = function(card)
			card:set({ owned = true })
		end
		cards[i] = UIKit.shopCard(spec)
	end
	local dialog
	return function(i)
		if i == 2 then
			dialog = UIKit.dialog({})
			dialog:say("Mira", "The lighthouse went dark last night. Will you climb up and relight the lantern before the boats come in?", {
				choices = { "I'll do it!", "Not now" },
			})
		elseif i == 5 then
			grid:setItem(3, { name = "Potion", glyph = "Po", rarity = "uncommon", count = 13 })
		elseif i == 7 then
			panel:select("SHOP")
		elseif i == 11 then
			cards[2]:set({ owned = true })
		elseif i == 13 then
			panel:select("QUESTS")
		end
		if i % 2 == 0 then
			grid:select(i % 12 + 1)
		end
	end
end

local function resultsPage()
	UIKit.results({
		title = "VICTORY",
		sub = "Lantern Isles - Stage 3",
		stats = { { label = "Time", value = "2:14" }, { label = "Coins", value = 1840 }, { label = "Stars", value = 3 }, { label = "Score", value = 98450 } },
		rank = "S",
		rewards = { { glyph = "$", count = 500 }, { glyph = "G", count = 25, color = UIKit.current.c.accent2 }, { glyph = "*", count = 1, color = UIKit.current.rarity.legendary } },
		buttons = { { text = "CONTINUE" }, { text = "RETRY" } },
	})
	return function() end
end

local BUILD = { hud = hudPage, menus = menusPage, results = resultsPage }

local themeIndex = 0
while true do
	themeIndex = themeIndex % #THEMES + 1
	for _, page in PAGES do
		local themeName = workspace:GetAttribute("UIKitDemoTheme") or THEMES[themeIndex]
		local pageName = workspace:GetAttribute("UIKitDemoPage") or page[1]
		UIKit.clear()
		UIKit.theme(themeName)
		caption.Text = string.format("UIKit demo  -  theme: %s  -  page: %s", themeName, pageName)
		local ok, step = pcall(BUILD[pageName] or hudPage)
		if not ok then
			warn("[UIKit demo] build failed:", step)
			step = function() end
		end
		for i = 1, math.floor(page[2] / 0.5) do
			local ok2, err = pcall(step, i)
			if not ok2 then
				warn("[UIKit demo] step failed:", err)
			end
			task.wait(0.5)
		end
	end
end
