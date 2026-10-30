--!nonstrict
-- WorldKit2 demo (server Script, e.g. ServerScriptService/WorldKit2Demo.server.luau). Lays out everything WorldKit2
-- builds on a grid so each piece can be screenshotted:
--   row z = 0      every prop kind, 24 studs apart along +X, each with a sign naming it (camera ~ (x, 14, -30))
--   row z = 400    the 12 biomes, 320 studs apart along +X (size 256 each)
--   row z = -400   builders: road loop + gates, water course, rail, platform course, obby, arena (square, circle)
--   row z = -900   rooms (kitchen, tavern, office, lab, bedroom), towns (suburb, medieval, western), dungeon
-- Workspace attribute WK2DemoSpots holds a JSON map name -> {x, y, z} of a good camera target for each piece.
-- Requires ReplicatedStorage.Kit with WorldKit, LookKit, WorldKit2. Pass a look by setting the Workspace attribute
-- WK2DemoLook before Play (default toon_bright).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")

local Kit = ReplicatedStorage:WaitForChild("Kit")
local LookKit = require(Kit:WaitForChild("LookKit"))
local WK2 = require(Kit:WaitForChild("WorldKit2"))

LookKit.apply(Workspace:GetAttribute("WK2DemoLook") or "toon_bright")
local base = Workspace:FindFirstChild("Baseplate")
if base then
	base:Destroy()
end
local root = WK2.folder("WorldKit2Demo")
local spots = {}
local function spot(name, v)
	spots[name] = { math.floor(v.X), math.floor(v.Y), math.floor(v.Z) }
	Workspace:SetAttribute("WK2DemoSpots", HttpService:JSONEncode(spots))
end
local V3 = Vector3.new

-- props ------------------------------------------------------------------------------------------------------
local propRow = Instance.new("Folder")
propRow.Name = "Props"
propRow.Parent = root
local slab = Instance.new("Part")
slab.Anchored = true
slab.Size = V3(#WK2.propKinds * 24 + 40, 2, 60)
slab.CFrame = CFrame.new(#WK2.propKinds * 12, -1, 10)
slab.Color = LookKit.color("ground")
slab.Material = LookKit.mat("ground")
slab.Parent = propRow
for i, kind in ipairs(WK2.propKinds) do
	local x = (i - 1) * 24 + 12
	local y = (kind == "coin" or kind == "gem" or kind == "asteroid") and 4 or 0
	if kind == "platform" then y = 4 end
	WK2.prop(kind, { position = V3(x, y, 0), rotation = 0, seed = i, parent = propRow })
	WK2.prop("sign", { position = V3(x, 0, -10), width = 7, height = 4, text = kind, parent = propRow })
	spot("prop_" .. kind, V3(x, 4, 0))
	if i % 8 == 0 then task.wait() end
end

-- biomes -----------------------------------------------------------------------------------------------------
for i, kind in ipairs(WK2.biomeKinds) do
	local c = V3((i - 1) * 320, 0, 400)
	local b = WK2.biome(kind, { center = c, size = 256, seed = i * 13, parent = root })
	spot("biome_" .. kind, b.spawn)
	task.wait()
end

-- builders ---------------------------------------------------------------------------------------------------
local loop = {}
for k = 0, 7 do
	local a = k / 8 * math.pi * 2
	table.insert(loop, V3(math.cos(a) * 110, 6 + math.sin(a * 2) * 6, -400 + math.sin(a) * 70))
end
local road = WK2.course(loop, { style = "road", width = 18, closed = true, gates = 6, parent = root })
spot("course_road", road.start.Position)
task.wait()
local water = WK2.course({ V3(300, 0, -480), V3(360, 0, -420), V3(420, 0, -400), V3(500, 0, -360), V3(560, 0, -300) },
	{ style = "water", width = 22, gates = 4, parent = root })
spot("course_water", water.start.Position)
local rail = WK2.course({ V3(650, 4, -480), V3(700, 8, -400), V3(780, 12, -380), V3(860, 6, -320) },
	{ style = "rail", width = 10, gates = false, parent = root })
spot("course_rail", rail.start.Position)
local plats = WK2.course({ V3(950, 20, -480), V3(990, 26, -420), V3(1040, 32, -400), V3(1100, 30, -340) },
	{ style = "platforms", width = 14, spacing = 16, gates = 3, parent = root })
spot("course_platforms", plats.start.Position)
task.wait()
for d = 1, 3 do
	local obby = WK2.platformingCourse({ start = V3(1250 + (d - 1) * 130, 20, -380), length = 12, difficulty = d * 2 - 1,
		theme = ({ "grass", "candy", "lava" })[d], seed = d, parent = root, direction = V3(0, 0, -1) })
	spot("obby_d" .. (d * 2 - 1), obby.start.Position)
end
task.wait()
local sq = WK2.arena({ center = V3(1820, 0, -420), size = 160, shape = "square", style = "military", parent = root })
spot("arena_square", sq.center + V3(0, 10, 0))
local ci = WK2.arena({ center = V3(2060, 0, -420), size = 150, shape = "circle", style = "scifi", parent = root })
spot("arena_circle", ci.center + V3(0, 10, 0))
task.wait()

-- interiors, towns, dungeon ----------------------------------------------------------------------------------
for i, theme in ipairs({ "kitchen", "tavern", "office", "lab", "bedroom" }) do
	local room = WK2.room({ center = V3((i - 1) * 60, 0, -900), size = V3(40, 14, 32), theme = theme, doors = { "south" },
		parent = root })
	spot("room_" .. theme, room.bounds.center + V3(0, 4, 0))
	task.wait()
end
for i, style in ipairs({ "suburb", "medieval", "western", "city" }) do
	local town = WK2.town({ center = V3(400 + (i - 1) * 260, 0, -1000), blocks = 2, style = style, parent = root, seed = i })
	spot("town_" .. style, town.spawn)
	task.wait()
end
local dg = WK2.dungeon({ center = V3(1500, 0, -1000), rooms = 9, parent = root })
spot("dungeon", dg.start)

WK2.animate()
print("[WorldKit2Demo] built; spots:", HttpService:JSONEncode(spots))
