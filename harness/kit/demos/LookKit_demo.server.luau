--!nonstrict
-- LookKit demo (server Script, e.g. ServerScriptService/LookKitDemo.server.luau). Builds one WorldKit2 showcase
-- scene around the origin (grassland, a pond, sand/snow/rock patches so terrain colours show, houses, a castle
-- tower, a shop, a neon tower, an obby, props) and cycles every LookKit look over it every 8 s. A sign by the spawn
-- names the current look; Lighting attribute KitLook carries it too. Frame the camera at (0, 30, -90) -> (0, 10, 30).
-- Requires ReplicatedStorage.Kit with WorldKit, LookKit, WorldKit2.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Kit = ReplicatedStorage:WaitForChild("Kit")
local LookKit = require(Kit:WaitForChild("LookKit"))
local WK2 = require(Kit:WaitForChild("WorldKit2"))

LookKit.apply("toon_bright")
local base = Workspace:FindFirstChild("Baseplate")
if base then
	base:Destroy()
end

local T = Workspace.Terrain
local scene, label

-- Props read LookKit.palette when they are built, so the scene is rebuilt after each look (same seeds, same layout).
local function build()
	if scene then
		scene:Destroy()
	end
	scene = Instance.new("Folder")
	scene.Name = "LookKitDemo"
	scene.Parent = Workspace
	WK2.biome("grassland", { center = Vector3.new(0, 0, 0), size = 260, seed = 4, parent = scene, density = 0.8 })
	T:FillCylinder(CFrame.new(-60, -1.5, 40), 3, 22, Enum.Material.Water)
	T:FillBall(Vector3.new(80, -10, 70), 22, Enum.Material.Sand)
	T:FillBall(Vector3.new(-90, -12, 90), 26, Enum.Material.Rock)
	T:FillBall(Vector3.new(-90, 6, 90), 10, Enum.Material.Snow)
	local function prop(kind, x, z, opts)
		opts = opts or {}
		opts.position = WK2.groundAt(x, z) or Vector3.new(x, 0, z)
		opts.parent = scene
		return WK2.prop(kind, opts)
	end
	prop("house", -30, 40, { rotation = 0, floors = 2 })
	prop("house", 0, 52, { rotation = 0, seed = 7 })
	prop("shop", 32, 44, { rotation = 0, text = "BAKERY" })
	prop("tower", 70, 20, { style = "castle", height = 30 })
	prop("tower", -70, 0, { style = "neon", height = 46 })
	prop("lamp", -12, 10)
	prop("lamp", 12, 10)
	prop("car", 20, -6, { rotation = 30 })
	prop("fence", -20, -10, { length = 16 })
	prop("bench", 0, 18, { rotation = 0 })
	prop("crate", 26, 14)
	prop("barrel", 30, 16)
	prop("flag", -40, 10)
	prop("pine", 45, 0, { snow = true })
	prop("palm", 80, 60)
	prop("mushroom", -6, -20)
	prop("cactus", 90, 70)
	prop("lollipop", -50, -30)
	prop("crystal", -60, 20)
	for i = 1, 5 do
		local coin = prop("coin", -8 + i * 3, -2)
		coin:PivotTo(coin:GetPivot() + Vector3.new(0, 3, 0))
	end
	WK2.platformingCourse({ start = Vector3.new(0, 16, 80), length = 8, difficulty = 2, direction = Vector3.new(0, 0, 1),
		parent = scene, seed = 3 })
	local sign = prop("sign", 0, -26, { width = 10, height = 8, text = LookKit.current or "", rotation = 0 })
	label = sign:FindFirstChildWhichIsA("TextLabel", true)
	local spawn = Instance.new("SpawnLocation")
	spawn.Anchored = true
	spawn.Size = Vector3.new(8, 1, 8)
	spawn.CFrame = CFrame.new((WK2.groundAt(0, -40) or Vector3.zero) + Vector3.new(0, 0.5, 0))
	spawn.Transparency = 1
	spawn.CanCollide = false
	spawn.Parent = scene
end

WK2.animate()

while true do
	for _, look in ipairs(LookKit.looks) do
		LookKit.apply(look, { tween = 1.5 })
		build()
		if label then
			label.Text = look
		end
		print("[LookKitDemo] look =", look)
		task.wait(8)
	end
end
