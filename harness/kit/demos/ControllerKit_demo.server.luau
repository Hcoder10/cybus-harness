--!nonstrict
-- ControllerKit demo (server Script, e.g. ServerScriptService/ControllerKitDemo.server.luau). Builds one test map with a
-- zone per profile, starts the shooter's server half and spawns a networked car (sit in it to drive: tests the Seat ->
-- network-ownership path). Pair with demos/ControllerKit_demo.client.luau, which switches profiles with keys 1-8.
--   x -260..-120  platformer course: steps, a gap, a long-jump runway, two walls for wall kicks
--   x  -60..60    top-down yard: crates tagged "Interactable"
--   z  120..220   shooting range: dummies (Humanoids, respawn), cover
--   x  80..280    kart / car / hover pad: ramp, walls, a boost pad (tagged "KitBoostPad")
--   x  330..690   lake (Terrain water, surface y = 0) for the boat and hover
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local Kit = ReplicatedStorage:WaitForChild("Kit")
local ControllerKit = require(Kit:WaitForChild("ControllerKit"))
local okWorld, WorldKit = pcall(require, Kit:FindFirstChild("WorldKit"))

local level = Instance.new("Folder")
level.Name = "ControllerKitDemo"
level.Parent = Workspace

local function part(name, size, cf, color, material, class)
	local p = Instance.new(class or "Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface, p.BottomSurface = Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
	p.Parent = level
	return p
end

-- world -----------------------------------------------------------------------------------------------------------
local terrain = Workspace.Terrain
if okWorld and WorldKit then
	pcall(WorldKit.lighting, "golden_hour")
end
terrain:FillBlock(CFrame.new(0, -4, 0), Vector3.new(640, 8, 520), Enum.Material.Grass)
terrain:FillBlock(CFrame.new(510, -18, 0), Vector3.new(400, 8, 420), Enum.Material.Sand)
terrain:FillBlock(CFrame.new(510, -7, 0), Vector3.new(380, 14, 400), Enum.Material.Water)
if not Workspace:FindFirstChildWhichIsA("SpawnLocation", true) then
	local sp = Instance.new("SpawnLocation")
	sp.Anchored, sp.Size, sp.CFrame, sp.Parent = true, Vector3.new(10, 1, 10), CFrame.new(0, 0.5, 0), level
end

-- platformer course
local stone, accent = Color3.fromRGB(196, 186, 170), Color3.fromRGB(255, 196, 80)
for i = 0, 6 do
	part("Step" .. i, Vector3.new(14, 2 + i * 3, 14), CFrame.new(-140 - i * 16, (2 + i * 3) / 2, -40), stone,
		Enum.Material.Slate)
end
part("GapA", Vector3.new(16, 22, 16), CFrame.new(-260, 11, -40), accent)
part("Runway", Vector3.new(14, 1, 90), CFrame.new(-200, 0.5, 40), Color3.fromRGB(90, 96, 110))
part("WallL", Vector3.new(2, 46, 24), CFrame.new(-236, 23, 110), stone, Enum.Material.Slate)
part("WallR", Vector3.new(2, 46, 24), CFrame.new(-224, 23, 110), stone, Enum.Material.Slate)
part("WallTop", Vector3.new(16, 2, 24), CFrame.new(-230, 47, 130), accent)

-- top-down yard: interactables
local crateColors = { "#E07A5F", "#81B29A", "#F2CC8F", "#3D405B", "#9C6ADE" }
for i, hex in crateColors do
	local a = (i / #crateColors) * math.pi * 2
	local c = part("Crate" .. i, Vector3.new(4, 4, 4), CFrame.new(math.cos(a) * 30, 2, -80 + math.sin(a) * 30),
		Color3.fromHex(hex), Enum.Material.WoodPlanks)
	CollectionService:AddTag(c, "Interactable")
end
part("YardFence", Vector3.new(60, 3, 1), CFrame.new(0, 1.5, -122), stone)

-- shooting range: dummies that respawn
local function dummy(at)
	local model = Instance.new("Model")
	model.Name = "Dummy"
	local root = part("HumanoidRootPart", Vector3.new(2, 2, 1), at, Color3.fromRGB(80, 80, 90))
	root.Transparency = 1
	root.Parent = model
	local torso = part("Torso", Vector3.new(2, 2.4, 1), at, Color3.fromRGB(220, 90, 70))
	torso.Parent = model
	local head = part("Head", Vector3.new(1.3, 1.3, 1.3), at * CFrame.new(0, 1.9, 0), Color3.fromRGB(240, 220, 200))
	head.Parent = model
	local legs = part("Legs", Vector3.new(1.6, 2.4, 0.9), at * CFrame.new(0, -2.4, 0), Color3.fromRGB(60, 64, 80))
	legs.Parent = model
	local hum = Instance.new("Humanoid")
	hum.MaxHealth, hum.Health = 100, 100
	hum.Parent = model
	model.PrimaryPart = root
	model.Parent = level
	hum.Died:Connect(function()
		task.wait(2.5)
		model:Destroy()
		dummy(at)
	end)
end
for i = -2, 2 do
	dummy(CFrame.new(i * 12, 3.6, 200 + math.abs(i) * 8))
end
for i = -1, 1 do
	part("Cover" .. i, Vector3.new(8, 4, 2), CFrame.new(i * 18, 2, 150), stone, Enum.Material.Concrete)
end

-- driving pad: ramp, walls, boost pad
part("Ramp", Vector3.new(16, 6, 30), CFrame.new(180, 3, -40) * CFrame.Angles(0, math.rad(180), 0),
	Color3.fromRGB(110, 116, 130), Enum.Material.Concrete, "WedgePart")
part("Landing", Vector3.new(30, 1, 40), CFrame.new(180, 0.5, -110), Color3.fromRGB(90, 96, 110))
for i, z in { -140, 60 } do
	part("Barrier" .. i, Vector3.new(200, 4, 2), CFrame.new(180, 2, z), Color3.fromRGB(230, 70, 60))
end
local pad = part("BoostPad", Vector3.new(12, 0.3, 14), CFrame.new(130, 0.15, 10), Color3.fromRGB(80, 220, 255),
	Enum.Material.Neon)
CollectionService:AddTag(pad, "KitBoostPad")

-- systems ---------------------------------------------------------------------------------------------------------
ControllerKit.shooterServer({
	onDamage = function(attacker, humanoid, damage, info)
		print(string.format("[demo] %s hit %s for %.0f (%s%s)", attacker.Name, humanoid.Parent.Name, damage,
			info.weapon, if info.head then ", head" else ""))
		humanoid:TakeDamage(damage)
	end,
})

-- a networked car: whoever sits in it gets ownership of its root and drives it (client demo runs vehicle("seated"))
local car = ControllerKit.vehicle(nil, { kind = "car", spawn = CFrame.new(100, 6, -20) * CFrame.Angles(0, math.rad(-90), 0) })
if car then
	car.Entered:Connect(function(player)
		print("[demo] " .. player.Name .. " is driving the car")
	end)
	car.Exited:Connect(function(player)
		print("[demo] " .. player.Name .. " left the car")
	end)
end
