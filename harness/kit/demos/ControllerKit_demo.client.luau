--!nonstrict
-- ControllerKit demo (LocalScript, e.g. StarterPlayerScripts/ControllerKitDemo.client.luau). Needs the server demo's map.
-- Keys: 1 platformer  2 top-down  3 FPS (rifle)  4 TPS (shotgun)  5 kart  6 car  7 hover  8 boat  0 none
-- (touch / gamepad: the on-screen profile buttons). The networked car on the pad is driven by sitting in it.
-- Each switch destroys the previous controller (exercises :Destroy()) and teleports you to that profile's zone.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local Kit = ReplicatedStorage:WaitForChild("Kit")
local ControllerKit = require(Kit:WaitForChild("ControllerKit"))
local okDebug, Debug = pcall(require, Kit:FindFirstChild("Debug"))

local player = Players.LocalPlayer
local current, currentName = nil, "none"

local gui = Instance.new("ScreenGui")
gui.Name = "ControllerKitDemo"
gui.ResetOnSpawn = false
gui.Parent = player:WaitForChild("PlayerGui")
local label = Instance.new("TextLabel")
label.Position = UDim2.fromOffset(16, 16)
label.Size = UDim2.fromOffset(520, 64)
label.BackgroundColor3 = Color3.fromRGB(20, 22, 30)
label.BackgroundTransparency = 0.3
label.TextColor3 = Color3.new(1, 1, 1)
label.Font = Enum.Font.GothamMedium
label.TextSize = 16
label.TextXAlignment = Enum.TextXAlignment.Left
label.TextWrapped = true
label.Parent = gui
local pad = Instance.new("UIPadding")
pad.PaddingLeft = UDim.new(0, 10)
pad.Parent = label

local function teleport(cf)
	local character = player.Character or player.CharacterAdded:Wait()
	local hrp = character:WaitForChild("HumanoidRootPart")
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.CFrame = cf
end

local PROFILES = {}
PROFILES.platformer = function()
	teleport(CFrame.new(-140, 8, -10))
	local c = ControllerKit.platformer({ wallKick = true })
	c.Jumped:Connect(function(kind)
		print("[demo] jumped", kind)
	end)
	c.DoubleJumped:Connect(function(n)
		print("[demo] double jump", n)
	end)
	c.Landed:Connect(function(speed)
		if speed > 60 then
			print(string.format("[demo] landed hard %.0f", speed))
		end
	end)
	c.GroundPound:Connect(function()
		print("[demo] ground pound")
	end)
	c.Dashed:Connect(function(kind)
		print("[demo]", kind)
	end)
	return c, "Platformer: Space jump (hold = higher, again = double, crouch+jump = long jump, jump at a wall = kick), "
		.. "Ctrl/C in air = ground pound, Shift = dash / dive"
end
PROFILES.topDown = function()
	teleport(CFrame.new(0, 4, -60))
	local c = ControllerKit.topDown({ view = "isometric" })
	c.Interacted:Connect(function(inst)
		print("[demo] interacted with", inst.Name)
		inst.Color = Color3.fromHSV(math.random(), 0.5, 0.9)
	end)
	return c, "Top-down: WASD / stick, or click / tap the ground to walk; E near a crate to use it"
end
PROFILES.fps = function()
	teleport(CFrame.new(0, 4, 130))
	local c = ControllerKit.shooter({ view = "fps", weapon = "rifle" })
	c.HitConfirmed:Connect(function(info)
		print(string.format("[demo] server confirmed %.0f damage%s", info.damage, if info.killed then " (kill)" else ""))
	end)
	return c, "FPS rifle: LMB fire, RMB aim, R reload, Shift sprint, C crouch"
end
PROFILES.tps = function()
	teleport(CFrame.new(0, 4, 130))
	local c = ControllerKit.shooter({ view = "tps", weapon = "shotgun" })
	return c, "TPS shotgun: LMB fire, RMB aim, R reload, Shift sprint, C crouch"
end
local function vehicleProfile(kind, spawn, help)
	return function()
		teleport(spawn + Vector3.new(0, 4, 0))
		task.wait(0.1)
		local c = ControllerKit.vehicle(nil, { kind = kind, spawn = spawn })
		c.Boosted:Connect(function(tier)
			print("[demo] boost", tier)
		end)
		c.DriftTier:Connect(function(tier)
			print("[demo] drift tier", tier)
		end)
		c.Landed:Connect(function(speed)
			print(string.format("[demo] landed %.0f", speed))
		end)
		-- boost pads: a plain distance check (anchored client vehicles do not fire Touched)
		local conn = RunService.Heartbeat:Connect(function()
			local st = c:state()
			if not st.driving then
				return
			end
			for _, p in CollectionService:GetTagged("KitBoostPad") do
				local rel = p.CFrame:PointToObjectSpace(st.cframe.Position)
				if math.abs(rel.X) < p.Size.X / 2 and math.abs(rel.Z) < p.Size.Z / 2 and math.abs(rel.Y) < 6 then
					if not st.boosting then
						c:boost(1.2)
					end
				end
			end
		end)
		local destroy = c.Destroy
		c.Destroy = function(self)
			conn:Disconnect()
			destroy(self)
		end
		return c, help
	end
end
local driveHelp = "WASD / stick / thumbstick, Space or Shift = drift (hold while turning, release to boost), R reset, F exit"
PROFILES.kart = vehicleProfile("kart", CFrame.new(140, 4, 30) * CFrame.Angles(0, math.rad(180), 0), "Kart: " .. driveHelp)
PROFILES.car = vehicleProfile("car", CFrame.new(220, 4, 30) * CFrame.Angles(0, math.rad(180), 0), "Car: " .. driveHelp)
PROFILES.hover = vehicleProfile("hover", CFrame.new(300, 6, 0) * CFrame.Angles(0, math.rad(-90), 0),
	"Hover (flies over the lake too): " .. driveHelp)
PROFILES.boat = vehicleProfile("boat", CFrame.new(420, 4, 0) * CFrame.Angles(0, math.rad(-90), 0), "Boat: " .. driveHelp)

local ORDER = { "platformer", "topDown", "fps", "tps", "kart", "car", "hover", "boat" }

local function switch(name)
	if current then
		current:Destroy()
		current = nil
	end
	currentName = name
	local make = PROFILES[name]
	if not make then
		label.Text = "ControllerKit demo: 1 platformer  2 top-down  3 FPS  4 TPS  5 kart  6 car  7 hover  8 boat"
		return
	end
	local ok, ctl, help = pcall(make)
	if ok then
		current = ctl
		label.Text = "[" .. name .. "]  " .. tostring(help) .. "\n1-8 switch profile, 0 none"
	else
		label.Text = "[" .. name .. "] failed: " .. tostring(ctl)
		warn("[ControllerKit demo] " .. name .. " failed: " .. tostring(ctl))
	end
end

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	local n = input.KeyCode.Value - Enum.KeyCode.Zero.Value
	if n == 0 then
		switch("none")
	elseif n >= 1 and n <= #ORDER then
		switch(ORDER[n])
	end
end)

-- touch / gamepad: a row of profile buttons
local row = Instance.new("Frame")
row.Position = UDim2.fromOffset(16, 88)
row.Size = UDim2.fromOffset(520, 30)
row.BackgroundTransparency = 1
row.Parent = gui
local layout = Instance.new("UIListLayout")
layout.FillDirection = Enum.FillDirection.Horizontal
layout.Padding = UDim.new(0, 4)
layout.Parent = row
for _, name in ORDER do
	local b = Instance.new("TextButton")
	b.Size = UDim2.fromOffset(60, 30)
	b.Text = name
	b.TextSize = 12
	b.Font = Enum.Font.GothamBold
	b.TextColor3 = Color3.new(1, 1, 1)
	b.BackgroundColor3 = Color3.fromRGB(40, 44, 60)
	b.Parent = row
	b.Activated:Connect(function()
		switch(name)
	end)
end

-- the networked car on the driving pad (server demo spawns it): drive it while seated in it
ControllerKit.vehicle("seated", { kind = "car" })

if okDebug and Debug and Debug.register then
	for _, name in ORDER do
		Debug.register("controller_" .. name, function()
			switch(name)
		end, "ControllerKit demo: switch to the " .. name .. " profile")
	end
end

player.CharacterAdded:Connect(function()
	-- profiles follow respawns themselves; the vehicle ones are rebuilt so the new character gets seated
	if currentName == "kart" or currentName == "car" or currentName == "hover" or currentName == "boat" then
		task.wait(0.5)
		switch(currentName)
	end
end)

switch("platformer")
