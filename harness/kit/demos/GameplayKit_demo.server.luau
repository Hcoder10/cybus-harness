--!nonstrict
-- GameplayKit demo (server Script, e.g. ServerScriptService/GameplayKitDemo.server.luau). Builds a tiny test level
-- that exercises: rounds, score/leaderstats, objectives, collectibles (magnet + respawn), a cooking line (carry,
-- stove with raw -> cooked -> burnt, recipe assembly, serving), an enemy wave arena, a checkpoint obby with a moving
-- platform, spinner, laser, crusher and lava, a door, and a 2-lap mini race with an AI kart.
-- Requires ReplicatedStorage.Kit with Maid, Spring and GameplayKit + GameplayKit_* siblings. The client side
-- (coin bob/spin, knockback) starts as soon as any LocalScript requires Kit.GameplayKit, e.g. a LocalScript with:
--   require(game.ReplicatedStorage.Kit.GameplayKit)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GK = require(ReplicatedStorage:WaitForChild("Kit"):WaitForChild("GameplayKit"))
local part = GK.Core.part
local level = GK.Core.folder("GameplayKitDemo")

-- ground + spawn ------------------------------------------------------------------------------------------------
if not Workspace:FindFirstChild("Baseplate") then
	part({ Name = "Baseplate", Size = Vector3.new(420, 1, 420), CFrame = CFrame.new(0, -0.5, 0), Color = "#6FA35A",
		Material = Enum.Material.Grass, Parent = level })
end
if not Workspace:FindFirstChildWhichIsA("SpawnLocation", true) then
	local sp = Instance.new("SpawnLocation")
	sp.Anchored, sp.Size, sp.CFrame, sp.Parent = true, Vector3.new(8, 1, 8), CFrame.new(0, 0.5, 0), level
end

-- core systems --------------------------------------------------------------------------------------------------
local score = GK.Score.new({ stats = { "Coins", "Burgers", "Kills" } })
GK.Health.players({ invuln = 0.8 })
local quests = GK.Objectives.new({
	list = {
		{ id = "coins", text = "Collect 10 coins", goal = 10 },
		{ id = "burger", text = "Serve a burger", goal = 1 },
		{ id = "kills", text = "Defeat 5 enemies", goal = 5 },
		{ id = "obby", text = "Reach the last checkpoint", goal = 1 },
		{ id = "race", text = "Finish the race", goal = 1 },
	},
	onComplete = function(player, id)
		print(("[demo] %s completed %s"):format(player.Name, id))
	end,
	onAll = function(player)
		print("[demo] " .. player.Name .. " completed every objective")
	end,
})
local rounds = GK.Rounds.new({ minPlayers = 1, lobby = 5, countdown = 3, duration = 600, results = 5 })
rounds.StateChanged:Connect(function(state)
	print("[demo] round state", state)
end)

-- collectibles: 12 coins in front of spawn, magnet 6 studs, respawn after 15 s ----------------------------------
GK.Collectibles.new({
	region = { center = Vector3.new(0, 3, 30), size = Vector3.new(40, 0, 20), count = 12 },
	magnet = 6, respawn = 15, score = score, stat = "Coins",
	onCollect = function(player)
		quests:progress(player, "coins")
	end,
})

-- cooking line ------------------------------------------------------------------------------------------------------
local colors = { ["Raw Patty"] = "#C8505A", ["Cooked Patty"] = "#7A4A2A", ["Burnt Patty"] = "#222222", Bun = "#E8B864", Burger = "#D9913F" }
local carry = GK.Carry.new({ colors = colors })
local function crate(name, x, item)
	local c = part({ Name = name, Size = Vector3.new(4, 3, 4), CFrame = CFrame.new(x, 1.5, -10), Color = "#8B5A2B",
		Material = Enum.Material.WoodPlanks, Parent = level })
	GK.prompt(c, { action = "Take " .. item, object = name, onUse = function(player)
		if not carry:held(player) then
			carry:give(player, carry:spawn(item, c.CFrame + Vector3.new(0, 3, 0)))
		end
	end })
end
crate("Patty Crate", 30, "Raw Patty")
crate("Bun Crate", 36, "Bun")
local stove = part({ Name = "Stove", Size = Vector3.new(4, 3, 4), CFrame = CFrame.new(42, 1.5, -10), Color = "#3A3A44",
	Material = Enum.Material.Metal, Parent = level })
GK.Station.new(stove, {
	carry = carry, colors = colors, accepts = { "Raw Patty", "Cooked Patty" },
	process = {
		{ from = "Raw Patty", to = "Cooked Patty", time = 5, label = "Cooking" },
		{ from = "Cooked Patty", to = "Burnt Patty", time = 6, label = "Burning" },
	},
	onChange = function(state, item)
		print("[demo] stove:", state, item)
	end,
})
local counter = part({ Name = "Counter", Size = Vector3.new(4, 3, 4), CFrame = CFrame.new(48, 1.5, -10), Color = "#D8D2C4",
	Parent = level })
GK.Station.new(counter, {
	carry = carry, colors = colors, name = "Assembly",
	recipes = GK.Recipes.new({ { inputs = { "Bun", "Cooked Patty" }, output = "Burger", time = 1 } }),
})
local window = part({ Name = "Serve", Size = Vector3.new(4, 3, 4), CFrame = CFrame.new(54, 1.5, -10), Color = "#4AA3DF",
	Material = Enum.Material.Neon, Parent = level })
GK.prompt(window, { action = "Serve", object = "Window", onUse = function(player)
	local held = carry:held(player)
	if held and held:GetAttribute("Item") == "Burger" then
		carry:take(player):Destroy()
		score:add(player, 1, "Burgers")
		quests:progress(player, "burger")
	end
end })

-- enemy arena: 2 waves (melee monsters, then a mix with ranged) --------------------------------------------------
local arenaCenter = Vector3.new(100, 0, 60)
part({ Name = "ArenaFloor", Size = Vector3.new(60, 1, 60), CFrame = CFrame.new(arenaCenter + Vector3.new(0, 0.05, 0)),
	Color = "#5B4E6E", Material = Enum.Material.Slate, Parent = level })
local spawner = GK.Spawner.new({
	points = { arenaCenter + Vector3.new(-20, 4, -20), arenaCenter + Vector3.new(20, 4, -20), arenaCenter + Vector3.new(0, 4, 22) },
	enemy = { rig = { style = "monster", color = "#7A3BD1" }, hp = 60, damage = 10, onDeath = function(_, killer)
		local p = GK.Core.playerOf(killer)
		if p then
			score:add(p, 1, "Kills")
			quests:progress(p, "kills")
		end
	end },
	waves = {
		{ count = 3 },
		{ count = 4, enemy = { kind = "ranged", rig = { style = "humanoid", color = "#B03A48" }, hp = 40 } },
	},
	between = 6,
	onWave = function(i)
		print("[demo] wave", i)
	end,
	onAllCleared = function()
		print("[demo] arena cleared")
	end,
})
local arenaSign = part({ Name = "ArenaStart", Size = Vector3.new(3, 5, 1), CFrame = CFrame.new(arenaCenter + Vector3.new(0, 2.5, -34)),
	Color = "#FF5A5A", Material = Enum.Material.Neon, Parent = level })
GK.prompt(arenaSign, { action = "Start waves", object = "Arena", onUse = function()
	spawner:start()
end })
-- a sword for the arena: press the prompt once to "equip" (demo: the server swings for you on each prompt use)
local sword = GK.Weapon.new("DemoSword", { kind = "melee", damage = 25, knockback = 40 })
GK.prompt(arenaSign, { action = "Swing (demo)", object = "Sword", key = Enum.KeyCode.F, distance = 60, onUse = function(player)
	local ch = GK.Core.character(player)
	if ch then
		sword:fireFrom(ch)
	end
end })

-- checkpoint obby over lava -------------------------------------------------------------------------------------
local lava = part({ Name = "Lava", Size = Vector3.new(110, 1, 24), CFrame = CFrame.new(-85, 0.6, 0), Color = "#FF5A1F",
	Material = Enum.Material.Neon, Parent = level })
GK.Hazard.kill(lava)
local cps = GK.Core.folder("Checkpoints", level)
local function pad(name, x, color, parent)
	return part({ Name = name, Size = Vector3.new(8, 1, 8), CFrame = CFrame.new(x, 6, 0), Color = color, Parent = parent or level })
end
pad("Stair", -26, "#BBBBBB")
for k, y in ipairs({ 1.5, 3, 4.5 }) do
	part({ Name = "Step", Size = Vector3.new(4, 1, 8), CFrame = CFrame.new(-10 - k * 4, y - 0.5, 0), Color = "#BBBBBB", Parent = level })
end
pad("1", -36, "#E6E6E6", cps)
pad("Hop", -48, "#BBBBBB")
local mover = pad("Platform", -60, "#4AA3DF")
GK.Mover.new(mover, { offset = Vector3.new(-16, 0, 0), time = 3, pause = 0.8 })
pad("2", -88, "#E6E6E6", cps)
GK.Hazard.spinner({ position = Vector3.new(-88, 7.5, 0), length = 14, speed = 120, parent = level })
part({ Name = "Bridge", Size = Vector3.new(24, 1, 6), CFrame = CFrame.new(-104, 6, 0), Color = "#BBBBBB", Parent = level })
GK.Hazard.laser({ from = Vector3.new(-100, 7.2, -4), to = Vector3.new(-100, 7.2, 4), on = 1.2, off = 1.6, parent = level })
GK.Hazard.crusher({ position = Vector3.new(-110, 14, 0), size = Vector3.new(6, 2, 6), drop = 6.5, phase = 0.5, parent = level })
pad("3", -122, "#E6E6E6", cps)
local checkpoints = GK.Checkpoints.new({ parts = cps, fallY = -20, onReached = function(player, i)
	print("[demo] checkpoint", player.Name, i)
	if i == 3 then
		quests:progress(player, "obby")
	end
end })
local door = part({ Name = "Door", Size = Vector3.new(6, 8, 1), CFrame = CFrame.new(-122, 10.5, -4), Color = "#8B5A2B", Parent = level })
GK.Door.new(door, { proximity = 10, prompt = false })

-- mini race: 8 gates in a ring, 2 laps, one AI kart ---------------------------------------------------------------
local gates = GK.Core.folder("Gates", level)
local center, radius = Vector3.new(0, 0, 150), 45
for i = 1, 8 do
	local a = (i - 1) / 8 * math.pi * 2
	local p = center + Vector3.new(math.sin(a) * radius, 4, -math.cos(a) * radius)
	local tangent = Vector3.new(math.cos(a), 0, math.sin(a))
	part({ Name = tostring(i), Size = Vector3.new(16, 8, 1), CFrame = CFrame.lookAt(p, p + tangent), Color = i == 1 and "#FFFFFF" or "#FFD24A",
		Transparency = 0.7, CanCollide = false, Parent = gates })
end
local race = GK.Race.new({ gates = gates, laps = 2, countdown = 3,
	onLap = function(r, lap, t)
		print(("[demo] %s lap %d in %.2f"):format(r.name, lap, t))
	end,
	onFinish = function(r, place, t)
		print(("[demo] %s finished P%d in %s"):format(r.name, place, GK.Timer.format(t, true)))
		if r.player then
			quests:progress(r.player, "race")
		end
	end,
})
local kart = Instance.new("Model")
kart.Name = "AIKart"
local body = part({ Name = "Body", Size = Vector3.new(4, 1.5, 6), Color = "#2EC4B6", CanCollide = false, Parent = kart })
part({ Name = "Seat", Size = Vector3.new(2, 1.5, 2), CFrame = body.CFrame * CFrame.new(0, 1.4, 0.8), Color = "#111111", CanCollide = false, Parent = kart })
kart.PrimaryPart = body
kart.Parent = level
race:addFollower(kart, { speed = 34, height = 1.2, name = "Kart Bot" })
local startSign = part({ Name = "RaceStart", Size = Vector3.new(3, 5, 1), CFrame = CFrame.new(0, 2.5, 96), Color = "#2EC4B6",
	Material = Enum.Material.Neon, Parent = level })
GK.prompt(startSign, { action = "Start race", object = "Race", onUse = function()
	race:start()
end })

print("[demo] GameplayKit demo ready: coins ahead, kitchen east (+X), arena far east, obby west (-X), race north (+Z)")
_G.GameplayKitDemo = { score = score, quests = quests, rounds = rounds, spawner = spawner, checkpoints = checkpoints, race = race }
