-- FXKit demo: lays out a labelled grid of pads (client-side, away from the map) and plays every FXKit preset in turn
-- with the camera framing each one, then an overview wave. For recording; put it in StarterPlayerScripts.
--   attributes on this script: Styles = "toon,neon" (default "toon"), Seconds = 2.6 (per preset), Origin = Vector3
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local FXKit = require(ReplicatedStorage:WaitForChild("Kit"):WaitForChild("FXKit"))
FXKit.register()

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera
local SECONDS = tonumber(script:GetAttribute("Seconds")) or 2.6
local ORIGIN = script:GetAttribute("Origin")
ORIGIN = if typeof(ORIGIN) == "Vector3" then ORIGIN else Vector3.new(0, 40, 900)
local STYLES = {}
for s in string.gmatch(tostring(script:GetAttribute("Styles") or "toon"), "[%a]+") do
	table.insert(STYLES, s)
end
local COLS, SPACING = 8, 22

-- what each preset is shown with: variants to step through, how to aim it, where it starts / ends
local SHOW = {
	land_dust = { opts = { impact = 1 } },
	dash_streak = { opts = { direction = Vector3.xAxis } },
	muzzle_flash = { variants = { "rifle", "pistol", "shotgun" }, at = Vector3.new(-3, 3, 0), opts = { direction = Vector3.xAxis } },
	explosion = { variants = { "small", "large" }, wide = true },
	drift_sparks = { variants = { "1", "2", "3" } },
	fire = { variants = { "campfire", "torch" } },
	slash_arc = { variants = { "right", "left" }, at = Vector3.new(0, 2.5, 0), opts = { direction = Vector3.new(0.7, 0, -0.7) } },
	bullet_tracer = { from = Vector3.new(-9, 3, 0), to = Vector3.new(7, 0.5, 0), opts = { impact = "concrete" } },
	lightning = { from = Vector3.new(-2, 24, -4), to = Vector3.new(0, 0.5, 0), wide = true },
	magic_bolt = { from = Vector3.new(-9, 3, 0), to = Vector3.new(6, 2, 0) },
	impact_metal = { at = Vector3.new(0, 0.5, 0) },
	critical_hit = { at = Vector3.new(0, 3, 0) },
	hit_spark = { at = Vector3.new(0, 3, 0) },
	shield_hit = { at = Vector3.new(0, 3, 0), opts = { normal = Vector3.new(0, 0, 1) } },
	magic_impact = { at = Vector3.new(0, 2, 0) },
	star_burst = { at = Vector3.new(0, 3, 0), opts = { direction = Vector3.new(0, 0, 1) } },
	coin_collect = { at = Vector3.new(0, 2, 0) },
	firework = { wide = true, hold = 1.2 },
	death_poof = { at = Vector3.new(0, 2, 0) },
	gem_sparkle = { at = Vector3.new(0, 2.5, 0) },
	sparkles = { at = Vector3.new(0, 2.5, 0) },
	portal_swirl = { at = Vector3.new(0, 4, 0), face = true },
	rain = { weather = true },
	snowfall = { opts = { area = 26 } },
	falling_leaves = { opts = { area = 26 } },
	falling_petals = { opts = { area = 26 } },
	fireflies = { opts = { area = 18 } },
	dust_motes = { opts = { area = 18 } },
	lava_embers = { opts = { area = 12 } },
}

------------------------------------------------------------------------------------------------ stage
local stage = Instance.new("Folder")
stage.Name = "FXKitDemo"
stage.Parent = workspace

local function block(size, cf, color, material)
	local p = Instance.new("Part")
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.Parent = stage
	return p
end

local names = FXKit.names()
local rows = math.ceil(#names / COLS)
local width, depth = COLS * SPACING, rows * SPACING
block(Vector3.new(width + 40, 1, depth + 40), CFrame.new(ORIGIN + Vector3.new(width / 2 - SPACING / 2, -0.5, depth / 2 - SPACING / 2)),
	Color3.fromRGB(46, 52, 64), Enum.Material.Slate)

local cells, labels = {}, {}
for i, name in names do
	local col, row = (i - 1) % COLS, (i - 1) // COLS
	local center = ORIGIN + Vector3.new(col * SPACING, 0, row * SPACING)
	cells[name] = center
	block(Vector3.new(12, 0.3, 12), CFrame.new(center + Vector3.new(0, 0.15, 0)), Color3.fromRGB(70, 78, 94))
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromOffset(220, 40)
	bb.StudsOffsetWorldSpace = Vector3.new(0, 9, 0)
	bb.AlwaysOnTop = true
	bb.MaxDistance = 400
	local anchor = block(Vector3.new(0.2, 0.2, 0.2), CFrame.new(center), Color3.new(), nil)
	anchor.Transparency = 1
	anchor.CanCollide = false
	bb.Adornee = anchor
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = 1
	t.Text = name
	t.TextScaled = true
	t.Font = Enum.Font.GothamBold
	t.TextColor3 = Color3.fromRGB(200, 208, 222)
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(20, 22, 28)
	stroke.Parent = t
	t.Parent = bb
	bb.Parent = stage
	labels[name] = t
end

-- title bar
local gui = Instance.new("ScreenGui")
gui.Name = "FXKitDemoTitle"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 50
local title = Instance.new("TextLabel")
title.AnchorPoint = Vector2.new(0.5, 0)
title.Position = UDim2.new(0.5, 0, 0, 24)
title.Size = UDim2.fromOffset(900, 56)
title.BackgroundColor3 = Color3.fromRGB(18, 20, 26)
title.BackgroundTransparency = 0.25
title.TextColor3 = Color3.new(1, 1, 1)
title.Font = Enum.Font.GothamBold
title.TextScaled = true
title.Parent = gui
local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 12)
corner.Parent = title
gui.Parent = player:WaitForChild("PlayerGui")

------------------------------------------------------------------------------------------------ camera
camera.CameraType = Enum.CameraType.Scriptable
local function frame(center, wide)
	local back = if wide then Vector3.new(0, 16, 40) else Vector3.new(0, 8, 21)
	local look = center + Vector3.new(0, if wide then 8 else 2.5, 0)
	TweenService:Create(camera, TweenInfo.new(0.45, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
		{ CFrame = CFrame.lookAt(center + back, look) }):Play()
	task.wait(0.5)
end

local function carrier(center, offset, face)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.Size = Vector3.new(1.4, 0.8, 2.6)
	p.Color = Color3.fromRGB(230, 80, 60)
	local pos = center + (offset or Vector3.new(0, 1.5, 0))
	-- faces -X so effects emitted "back" stream off to the right of the frame
	p.CFrame = if face then CFrame.lookAt(pos, pos + Vector3.new(0, 0, 1)) else CFrame.lookAt(pos, pos - Vector3.xAxis)
	p.Transparency = if face then 1 else 0
	p.Parent = stage
	return p
end

------------------------------------------------------------------------------------------------ playing one preset
local function playOne(name, center, style, variant)
	local show = SHOW[name] or {}
	local info = FXKit.info(name)
	local opts = table.clone(show.opts or {})
	opts.style = style
	opts.variant = variant
	local handles, temp = {}, {}
	local hold = SECONDS + (show.hold or 0)

	if name == "speed_lines" then
		local h = FXKit.speedLines(0.95, { style = style })
		task.wait(hold)
		h:set(0)
		task.wait(0.4)
		return
	elseif name == "skid_marks" then
		local car = carrier(center, Vector3.new(-6, 0.6, -2))
		table.insert(temp, car)
		local trail = FXKit.skid(car)
		local t0 = os.clock()
		while os.clock() - t0 < hold do
			local u = (os.clock() - t0) / hold
			local pos = center + Vector3.new(-6 + 12 * u, 0.6, math.sin(u * math.pi * 2) * 3)
			car.CFrame = CFrame.lookAt(pos, pos + Vector3.new(1, 0, math.cos(u * math.pi * 2) * 1.5))
			RunService.RenderStepped:Wait()
		end
		task.wait(0.6)
		trail:destroy()
		car:Destroy()
		return
	elseif name == "neon_flicker" then
		local sign = block(Vector3.new(6, 1.4, 0.4), CFrame.new(center + Vector3.new(0, 3, 0)), Color3.fromRGB(255, 79, 216),
			Enum.Material.Neon)
		local h = FXKit.flicker(sign, { rate = 1.2 })
		task.wait(hold)
		h:stop()
		sign:Destroy()
		return
	elseif name == "rain" then
		local h = FXKit.weather("rain", { style = style, area = 50 })
		task.wait(hold + 0.6)
		h:stop()
		task.wait(0.4)
		return
	elseif show.from then
		opts.to = center + show.to
		table.insert(handles, FXKit.play(name, center + show.from, opts))
		task.wait(hold * 0.5)
		table.insert(handles, FXKit.play(name, center + show.from + Vector3.new(0, 1.5, 0), opts))
		task.wait(hold * 0.5)
		return
	end

	local at
	if info.continuous and not info.weather then
		local c = carrier(center, show.at, show.face)
		table.insert(temp, c)
		at = c
	else
		at = center + (show.at or Vector3.new(0, 0.05, 0))
	end
	table.insert(handles, FXKit.play(name, at, opts))
	if info.continuous then
		task.wait(hold)
	else
		task.wait(math.min(1.4, hold * 0.5))
		table.insert(handles, FXKit.play(name, at, opts)) -- a second take for the recording
		task.wait(hold - math.min(1.4, hold * 0.5))
	end
	for _, h in handles do
		h:stop()
	end
	task.delay(2, function()
		for _, p in temp do
			p:Destroy()
		end
	end)
end

------------------------------------------------------------------------------------------------ run
task.wait(2)
for _, style in STYLES do
	FXKit.setStyle(style)
	for _, name in names do
		local show = SHOW[name] or {}
		local info = FXKit.info(name)
		local variants = show.variants or { false }
		frame(cells[name], show.wide)
		labels[name].TextColor3 = Color3.fromRGB(255, 214, 90)
		for _, v in variants do
			title.Text = string.upper(info.group) .. "  ·  " .. name .. (if v then " (" .. v .. ")" else "") .. "  ·  " .. style
			playOne(name, cells[name], style, if v then v else nil)
		end
		labels[name].TextColor3 = Color3.fromRGB(200, 208, 222)
	end
	-- overview: the whole grid, one-shots rippling across it
	title.Text = "FXKit  ·  " .. #names .. " presets  ·  " .. style
	local mid = ORIGIN + Vector3.new(width / 2 - SPACING / 2, 0, depth / 2 - SPACING / 2)
	TweenService:Create(camera, TweenInfo.new(1.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
		{ CFrame = CFrame.lookAt(mid + Vector3.new(0, depth * 0.9 + 30, depth * 0.9 + 40), mid) }):Play()
	task.wait(1.3)
	for _, name in names do
		local info = FXKit.info(name)
		local show = SHOW[name] or {}
		local special = name == "speed_lines" or name == "skid_marks" or name == "neon_flicker" or show.from ~= nil
		if not info.continuous and not special then
			FXKit.play(name, cells[name] + (show.at or Vector3.new(0, 0.05, 0)), { style = style, juice = false,
				variant = if show.variants then show.variants[#show.variants] else nil })
			task.wait(0.08)
		end
	end
	task.wait(3)
end
title.Text = "FXKit demo done"
task.wait(2)
gui:Destroy()
camera.CameraType = Enum.CameraType.Custom
