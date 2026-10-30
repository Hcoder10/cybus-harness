--!nonstrict
-- WorldKit: tested building blocks for good-looking Roblox worlds, so a game composes its world instead of inventing
-- geometry code. Server or edit mode. Terrain islands and water (smooth, sculpted, never voxel), part-built props,
-- and lighting presets whose values were tuned to actually read as the mood (ClockTime 16.5 is NOT golden hour in
-- Roblox: the sun only warms near 17.5-18).
--
-- Live lesson that made this exist: a 27B builder asked to "build floating islands" wrote Mesh.new() (no such class),
-- then MeshParts with no mesh (invisible). Every capture showed the default baseplate.

local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")

local WorldKit = {}

local function c3(v, fallback)
	if typeof(v) == "Color3" then
		return v
	end
	if type(v) == "string" then
		local ok, col = pcall(Color3.fromHex, v)
		if ok then
			return col
		end
	end
	return fallback
end

local function rng(seed)
	return Random.new(seed or 1)
end

function WorldKit.folder(name)
	local f = Workspace:FindFirstChild(name)
	if not f then
		f = Instance.new("Folder")
		f.Name = name
		f.Parent = Workspace
	end
	return f
end

local function part(props)
	local p = Instance.new(props.Shape and "Part" or (props.ClassName or "Part"))
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CastShadow = props.CastShadow ~= false
	if props.Shape then
		p.Shape = props.Shape                     -- before Size: setting Shape later re-squares a Ball
	end
	for k, v in pairs(props) do
		if k ~= "ClassName" and k ~= "Parent" and k ~= "CastShadow" and k ~= "Shape" and k ~= "CFrame" then
			p[k] = v
		end
	end
	if props.CFrame then
		p.CFrame = props.CFrame
	end
	p.Parent = props.Parent
	return p
end

-- ---------------------------------------------------------------------------------------------------- lighting

local PRESETS = {
	golden_hour = {
		ClockTime = 17.55, GeographicLatitude = 30, Brightness = 2.4, ExposureCompensation = 0.15,
		Ambient = Color3.fromRGB(98, 74, 70), OutdoorAmbient = Color3.fromRGB(150, 118, 100),
		ColorShift_Top = Color3.fromRGB(255, 196, 140), ColorShift_Bottom = Color3.fromRGB(70, 40, 60),
		atmosphere = { Density = 0.2, Offset = 0.08, Color = Color3.fromRGB(255, 186, 140),
			Decay = Color3.fromRGB(196, 104, 92), Glare = 0.5, Haze = 1.1 },
		bloom = { Intensity = 0.65, Size = 30, Threshold = 1.5 },
		grade = { Brightness = 0.02, Contrast = 0.1, Saturation = 0.18, TintColor = Color3.fromRGB(255, 238, 220) },
		sunrays = { Intensity = 0.1, Spread = 0.55 },
		clouds = { Cover = 0.58, Density = 0.5, Color = Color3.fromRGB(255, 205, 178) },
	},
	dusk = {
		ClockTime = 18.15, GeographicLatitude = 30, Brightness = 1.8, ExposureCompensation = 0.25,
		Ambient = Color3.fromRGB(86, 70, 104), OutdoorAmbient = Color3.fromRGB(120, 96, 140),
		ColorShift_Top = Color3.fromRGB(255, 150, 140), ColorShift_Bottom = Color3.fromRGB(60, 40, 90),
		atmosphere = { Density = 0.24, Offset = 0.08, Color = Color3.fromRGB(232, 140, 150),
			Decay = Color3.fromRGB(96, 74, 150), Glare = 0.35, Haze = 1.4 },
		bloom = { Intensity = 0.8, Size = 32, Threshold = 1.3 },
		grade = { Brightness = 0.0, Contrast = 0.12, Saturation = 0.2, TintColor = Color3.fromRGB(250, 230, 245) },
		sunrays = { Intensity = 0.06, Spread = 0.5 },
		clouds = { Cover = 0.62, Density = 0.55, Color = Color3.fromRGB(230, 160, 180) },
	},
	night = {
		ClockTime = 0.3, GeographicLatitude = 30, Brightness = 0.9, ExposureCompensation = 0.4,
		Ambient = Color3.fromRGB(46, 50, 88), OutdoorAmbient = Color3.fromRGB(60, 70, 120),
		ColorShift_Top = Color3.fromRGB(120, 140, 255), ColorShift_Bottom = Color3.fromRGB(20, 20, 50),
		atmosphere = { Density = 0.22, Offset = 0.05, Color = Color3.fromRGB(70, 82, 150),
			Decay = Color3.fromRGB(22, 24, 60), Glare = 0, Haze = 1.4 },
		bloom = { Intensity = 1.0, Size = 36, Threshold = 1.0 },
		grade = { Brightness = 0.02, Contrast = 0.14, Saturation = 0.12, TintColor = Color3.fromRGB(225, 232, 255) },
		sunrays = { Intensity = 0, Spread = 0 },
		clouds = { Cover = 0.4, Density = 0.35, Color = Color3.fromRGB(90, 100, 160) },
	},
	noon = {
		ClockTime = 13.2, GeographicLatitude = 30, Brightness = 3, ExposureCompensation = 0,
		Ambient = Color3.fromRGB(110, 118, 130), OutdoorAmbient = Color3.fromRGB(140, 150, 165),
		ColorShift_Top = Color3.fromRGB(255, 248, 235), ColorShift_Bottom = Color3.fromRGB(90, 100, 120),
		atmosphere = { Density = 0.16, Offset = 0.05, Color = Color3.fromRGB(200, 222, 255),
			Decay = Color3.fromRGB(110, 134, 176), Glare = 0.15, Haze = 0.6 },
		bloom = { Intensity = 0.4, Size = 24, Threshold = 1.8 },
		grade = { Brightness = 0.02, Contrast = 0.08, Saturation = 0.15, TintColor = Color3.fromRGB(255, 252, 245) },
		sunrays = { Intensity = 0.05, Spread = 0.4 },
		clouds = { Cover = 0.5, Density = 0.4, Color = Color3.fromRGB(255, 255, 255) },
	},
	overcast = {
		ClockTime = 14, GeographicLatitude = 30, Brightness = 1.4, ExposureCompensation = 0.1,
		Ambient = Color3.fromRGB(110, 115, 125), OutdoorAmbient = Color3.fromRGB(130, 136, 146),
		ColorShift_Top = Color3.fromRGB(220, 225, 235), ColorShift_Bottom = Color3.fromRGB(80, 85, 95),
		atmosphere = { Density = 0.3, Offset = 0.04, Color = Color3.fromRGB(190, 196, 206),
			Decay = Color3.fromRGB(120, 126, 140), Glare = 0, Haze = 2.6 },
		bloom = { Intensity = 0.3, Size = 24, Threshold = 2 },
		grade = { Brightness = 0, Contrast = 0.06, Saturation = -0.05, TintColor = Color3.fromRGB(240, 244, 250) },
		sunrays = { Intensity = 0, Spread = 0 },
		clouds = { Cover = 0.85, Density = 0.7, Color = Color3.fromRGB(210, 214, 222) },
	},
}
WorldKit.moods = { "golden_hour", "dusk", "night", "noon", "overcast" }

local function ensure(parent, class, name)
	local inst = parent:FindFirstChild(name or class)
	if not inst or not inst:IsA(class) then
		inst = Instance.new(class)
		inst.Name = name or class
		inst.Parent = parent
	end
	return inst
end

-- WorldKit.lighting(mood, {sky=Color3|"#hex", haze=Color3, sun=Color3, strength=0..1}) applies a tuned preset; the
-- optional tints pull the atmosphere, haze and sun toward the game's palette by `strength` (default 0.35).
function WorldKit.lighting(mood, tint)
	local p = PRESETS[mood or "golden_hour"] or PRESETS.golden_hour
	tint = tint or {}
	local k = tint.strength or 0.35
	for _, prop in ipairs({ "ClockTime", "GeographicLatitude", "Brightness", "ExposureCompensation", "Ambient",
		"OutdoorAmbient", "ColorShift_Top", "ColorShift_Bottom" }) do
		pcall(function() Lighting[prop] = p[prop] end)
	end
	pcall(function()
		Lighting.EnvironmentDiffuseScale = 1
		Lighting.EnvironmentSpecularScale = 1
		Lighting.GlobalShadows = true
	end)
	local atm = ensure(Lighting, "Atmosphere")
	for prop, v in pairs(p.atmosphere) do
		atm[prop] = v
	end
	local sky = c3(tint.sky, nil)
	if sky then atm.Color = atm.Color:Lerp(sky, k) end
	local haze = c3(tint.haze, nil)
	if haze then atm.Decay = atm.Decay:Lerp(haze, k) end
	local bloom = ensure(Lighting, "BloomEffect", "KitBloom")
	for prop, v in pairs(p.bloom) do bloom[prop] = v end
	local grade = ensure(Lighting, "ColorCorrectionEffect", "KitGrade")
	for prop, v in pairs(p.grade) do grade[prop] = v end
	local sun = c3(tint.sun, nil)
	if sun then grade.TintColor = grade.TintColor:Lerp(sun, k * 0.5) end
	local rays = ensure(Lighting, "SunRaysEffect", "KitSunRays")
	for prop, v in pairs(p.sunrays) do rays[prop] = v end
	local terrain = Workspace.Terrain
	local clouds = terrain:FindFirstChildOfClass("Clouds") or Instance.new("Clouds")
	for prop, v in pairs(p.clouds) do clouds[prop] = v end
	clouds.Parent = terrain
	-- Other games' leftovers fight the preset: an old Sky with a fixed skybox, or a second Atmosphere.
	for _, ch in ipairs(Lighting:GetChildren()) do
		if ch:IsA("Atmosphere") and ch ~= atm then ch:Destroy() end
	end
	return atm
end

-- ---------------------------------------------------------------------------------------------------- terrain

-- WorldKit.water({level=0, size=2048, color, depth=24}): a Terrain sea under everything (hides the void, reflects
-- the sky). Call once.
function WorldKit.water(opts)
	opts = opts or {}
	local terrain = Workspace.Terrain
	local level, size, depth = opts.level or 0, opts.size or 2048, opts.depth or 24
	terrain:FillBlock(CFrame.new(0, level - depth / 2, 0), Vector3.new(size, depth, size), Enum.Material.Water)
	terrain.WaterColor = c3(opts.color, Color3.fromRGB(46, 118, 132))
	terrain.WaterTransparency = opts.transparency or 0.35
	terrain.WaterReflectance = opts.reflectance or 0.55
	terrain.WaterWaveSize = opts.waveSize or 0.12
	terrain.WaterWaveSpeed = opts.waveSpeed or 6
	return level
end

-- WorldKit.ground({center, size=Vector3(512,8,512), material=Grass}) a flat terrain ground slab.
function WorldKit.ground(opts)
	opts = opts or {}
	local center = opts.center or Vector3.new(0, 0, 0)
	local size = opts.size or Vector3.new(512, 8, 512)
	Workspace.Terrain:FillBlock(CFrame.new(center - Vector3.new(0, size.Y / 2, 0)), size,
		opts.material or Enum.Material.Grass)
	return center
end

-- WorldKit.island({position, radius=40, height=16, top=Grass, side=Rock, seed, floating=true}) -> info
-- A smooth sculpted island: a domed grass cap over a lumpy rock body that tapers to a point underneath when
-- floating (or into the water when not). info = {top = Vector3 (centre of the walkable top), radius, position}.
function WorldKit.island(opts)
	opts = opts or {}
	local terrain = Workspace.Terrain
	local pos = opts.position or Vector3.new(0, 30, 0)
	local r = opts.radius or 40
	local h = opts.height or 16
	local top = opts.top or Enum.Material.Grass
	local side = opts.side or Enum.Material.Rock
	local rand = rng(opts.seed or math.floor(pos.X * 7 + pos.Z * 13))
	-- rock body: stacked shrinking balls, jittered so the silhouette is organic
	local layers = opts.floating == false and 2 or 5
	for i = 0, layers do
		local t = i / math.max(1, layers)
		local lr = r * (1 - 0.75 * t)
		for _ = 1, 3 do
			local off = Vector3.new(rand:NextNumber(-0.25, 0.25) * lr, 0, rand:NextNumber(-0.25, 0.25) * lr)
			terrain:FillBall(pos + off - Vector3.new(0, h * 0.35 + t * r * 0.9, 0), lr * rand:NextNumber(0.55, 0.75), side)
		end
	end
	-- flat-ish walkable top: a wide low cylinder, then a soft grass cap so edges round over
	terrain:FillCylinder(CFrame.new(pos), h * 0.6, r, side)
	terrain:FillCylinder(CFrame.new(pos + Vector3.new(0, h * 0.3, 0)), h * 0.25, r * 0.97, top)
	for _ = 1, 5 do
		local a = rand:NextNumber(0, math.pi * 2)
		local d = rand:NextNumber(0.2, 0.7) * r
		terrain:FillBall(pos + Vector3.new(math.cos(a) * d, h * 0.25, math.sin(a) * d), r * rand:NextNumber(0.25, 0.4), top)
	end
	return { position = pos, radius = r, top = pos + Vector3.new(0, h * 0.42, 0) }
end

-- WorldKit.hill / WorldKit.rock: terrain bumps for variety
function WorldKit.hill(opts)
	opts = opts or {}
	Workspace.Terrain:FillBall(opts.position or Vector3.zero, opts.radius or 20, opts.material or Enum.Material.Grass)
end

function WorldKit.rock(opts)
	opts = opts or {}
	local rand = rng(opts.seed)
	local s = opts.size or 6
	local p = part({ Shape = Enum.PartType.Ball, Size = Vector3.new(s * 1.3, s, s * 1.1),
		Material = Enum.Material.Slate, Color = c3(opts.color, Color3.fromRGB(122, 112, 104)),
		CFrame = CFrame.new(opts.position or Vector3.zero)
			* CFrame.Angles(rand:NextNumber(-0.4, 0.4), rand:NextNumber(0, 6.28), rand:NextNumber(-0.4, 0.4)),
		Parent = opts.parent or WorldKit.folder("WorldKit") })
	return p
end

-- ---------------------------------------------------------------------------------------------------- props

-- WorldKit.tree({position, height=16, style="blossom"|"round"|"pine", leaf=Color3, trunk=Color3, seed}) -> Model
function WorldKit.tree(opts)
	opts = opts or {}
	local rand = rng(opts.seed)
	local h = opts.height or 16
	local style = opts.style or "round"
	local leafDefault = style == "blossom" and Color3.fromRGB(255, 176, 198)
		or style == "pine" and Color3.fromRGB(58, 110, 74) or Color3.fromRGB(96, 160, 82)
	local leaf = c3(opts.leaf, leafDefault)
	local trunkCol = c3(opts.trunk, Color3.fromRGB(110, 76, 58))
	local base = opts.position or Vector3.zero
	local m = Instance.new("Model")
	m.Name = "Tree"
	local trunk = part({ Shape = Enum.PartType.Cylinder, Size = Vector3.new(h * 0.7, h * 0.12, h * 0.12),
		CFrame = CFrame.new(base + Vector3.new(0, h * 0.35, 0)) * CFrame.Angles(0, 0, math.rad(90))
			* CFrame.Angles(rand:NextNumber(-0.06, 0.06), 0, 0),
		Material = Enum.Material.Wood, Color = trunkCol, Parent = m })
	m.PrimaryPart = trunk
	if style == "pine" then
		for i = 0, 3 do
			local w = h * (0.7 - i * 0.15)
			part({ ClassName = "WedgePart", Size = Vector3.new(w, h * 0.3, w), Material = Enum.Material.SmoothPlastic,
				Color = leaf:Lerp(Color3.new(1, 1, 1), i * 0.04),
				CFrame = CFrame.new(base + Vector3.new(0, h * (0.4 + i * 0.17), 0)) * CFrame.Angles(0, i * 0.8, 0),
				Parent = m })
		end
	else
		local n = style == "blossom" and 7 or 5
		for i = 1, n do
			local a = (i / n) * math.pi * 2 + rand:NextNumber(-0.4, 0.4)
			local d = i == 1 and 0 or h * rand:NextNumber(0.15, 0.3)
			local s = h * rand:NextNumber(0.38, 0.55)
			part({ Shape = Enum.PartType.Ball, Size = Vector3.new(s, s * 0.85, s),
				Material = style == "blossom" and Enum.Material.SmoothPlastic or Enum.Material.Grass,
				Color = leaf:Lerp(Color3.new(1, 1, 1), rand:NextNumber(0, 0.12)),
				CFrame = CFrame.new(base + Vector3.new(math.cos(a) * d, h * rand:NextNumber(0.72, 0.92), math.sin(a) * d)),
				Parent = m })
		end
	end
	m.Parent = opts.parent or WorldKit.folder("WorldKit")
	return m
end

-- WorldKit.lamp({position, color, height=9, brightness=2, range=18}) -> Model: a post with a glowing head
function WorldKit.lamp(opts)
	opts = opts or {}
	local base = opts.position or Vector3.zero
	local h = opts.height or 9
	local col = c3(opts.color, Color3.fromRGB(255, 196, 110))
	local m = Instance.new("Model")
	m.Name = "Lamp"
	part({ Size = Vector3.new(0.6, h, 0.6), CFrame = CFrame.new(base + Vector3.new(0, h / 2, 0)),
		Material = Enum.Material.Metal, Color = c3(opts.post, Color3.fromRGB(58, 46, 44)), Parent = m })
	local head = part({ Shape = Enum.PartType.Ball, Size = Vector3.new(1.8, 1.8, 1.8),
		CFrame = CFrame.new(base + Vector3.new(0, h + 0.6, 0)), Material = Enum.Material.Neon, Color = col,
		CastShadow = false, Parent = m })
	local light = Instance.new("PointLight")
	light.Color = col
	light.Brightness = opts.brightness or 2
	light.Range = opts.range or 18
	light.Shadows = false
	light.Parent = head
	m.PrimaryPart = head
	m.Parent = opts.parent or WorldKit.folder("WorldKit")
	return m
end

-- WorldKit.lantern({position, size=3, color, paper, glow=true}) -> Model: a paper lantern (glowing core, ribs, cap)
function WorldKit.lantern(opts)
	opts = opts or {}
	local s = opts.size or 3
	local pos = opts.position or Vector3.zero
	local col = c3(opts.color, Color3.fromRGB(255, 170, 80))
	local m = Instance.new("Model")
	m.Name = "Lantern"
	local body = part({ Shape = Enum.PartType.Ball, Size = Vector3.new(s, s * 1.25, s), CFrame = CFrame.new(pos),
		Material = Enum.Material.Neon, Color = col, CastShadow = false, Transparency = 0.05, Parent = m })
	for _, y in ipairs({ -0.62, 0.62 }) do
		part({ Shape = Enum.PartType.Cylinder, Size = Vector3.new(s * 0.12, s * 0.62, s * 0.62),
			CFrame = CFrame.new(pos + Vector3.new(0, y * s, 0)) * CFrame.Angles(0, 0, math.rad(90)),
			Material = Enum.Material.Wood, Color = c3(opts.cap, Color3.fromRGB(90, 40, 36)), Parent = m })
	end
	if opts.glow ~= false then
		local light = Instance.new("PointLight")
		light.Color = col
		light.Brightness = opts.brightness or 2.2
		light.Range = opts.range or s * 6
		light.Parent = body
	end
	m.PrimaryPart = body
	m.Parent = opts.parent or WorldKit.folder("WorldKit")
	return m
end

-- WorldKit.bridge({from, to, width=6, style="planks"|"glow", color}) -> Model: a plank bridge (or glowing tiles)
function WorldKit.bridge(opts)
	opts = opts or {}
	local a, b = opts.from or Vector3.zero, opts.to or Vector3.new(0, 0, 40)
	local w = opts.width or 6
	local dir = b - a
	local len = dir.Magnitude
	local n = math.max(2, math.floor(len / 2.2))
	local m = Instance.new("Model")
	m.Name = "Bridge"
	local cf = CFrame.lookAt(a, b)
	for i = 0, n - 1 do
		local t = (i + 0.5) / n
		local sag = math.sin(t * math.pi) * len * 0.04
		local glow = opts.style == "glow"
		part({ Size = Vector3.new(w, 0.6, len / n * 0.82),
			CFrame = cf * CFrame.new(0, -sag, -t * len) * CFrame.Angles(0, 0, (i % 2 == 0 and 0.015 or -0.015)),
			Material = glow and Enum.Material.Neon or Enum.Material.WoodPlanks,
			Color = c3(opts.color, glow and Color3.fromRGB(255, 200, 120) or Color3.fromRGB(150, 104, 72)),
			Parent = m })
	end
	for _, side in ipairs({ -1, 1 }) do
		local rope = part({ Size = Vector3.new(0.25, 0.25, len), CFrame = cf * CFrame.new(side * w / 2, 1.8, -len / 2),
			Material = Enum.Material.Fabric, Color = Color3.fromRGB(196, 168, 128), Parent = m })
		rope.CastShadow = false
	end
	m.Parent = opts.parent or WorldKit.folder("WorldKit")
	return m
end

-- WorldKit.scatter(island, {trees=6, rocks=3, lamps=2, style="blossom", leaf, seed}): dress an island's top
function WorldKit.scatter(island, opts)
	opts = opts or {}
	local rand = rng(opts.seed or math.floor(island.position.X + island.position.Z))
	local function spot(minF, maxF)
		local a = rand:NextNumber(0, math.pi * 2)
		local d = rand:NextNumber(minF, maxF) * island.radius
		return island.top + Vector3.new(math.cos(a) * d, 0, math.sin(a) * d)
	end
	local made = {}
	for i = 1, opts.trees or 4 do
		table.insert(made, WorldKit.tree({ position = spot(0.25, 0.75), height = rand:NextNumber(12, 20),
			style = opts.style or "round", leaf = opts.leaf, seed = rand:NextInteger(1, 1e6), parent = opts.parent }))
	end
	for i = 1, opts.rocks or 2 do
		table.insert(made, WorldKit.rock({ position = spot(0.5, 0.85), size = rand:NextNumber(3, 7),
			seed = rand:NextInteger(1, 1e6), parent = opts.parent }))
	end
	for i = 1, opts.lamps or 0 do
		table.insert(made, WorldKit.lamp({ position = spot(0.55, 0.85), color = opts.lampColor, parent = opts.parent }))
	end
	return made
end

-- WorldKit.archipelago({count=6, center, spread=180, height=40, radius={24,48}, seed, style, water=true}) -> {islands}
-- One call for a whole floating-island world: water, islands at varied heights, dressing on each.
function WorldKit.archipelago(opts)
	opts = opts or {}
	local rand = rng(opts.seed or 7)
	local center = opts.center or Vector3.new(0, 0, 0)
	if opts.water ~= false then
		WorldKit.water({ level = center.Y, color = opts.waterColor })
	end
	local islands = {}
	local count = opts.count or 6
	for i = 1, count do
		local a = (i / count) * math.pi * 2 + rand:NextNumber(-0.3, 0.3)
		local d = i == 1 and 0 or (opts.spread or 180) * rand:NextNumber(0.55, 1)
		local r = i == 1 and (opts.radius and opts.radius[2] or 48) or rand:NextNumber(
			opts.radius and opts.radius[1] or 24, opts.radius and opts.radius[2] or 44)
		local pos = center + Vector3.new(math.cos(a) * d, (opts.height or 40) + rand:NextNumber(-12, 18), math.sin(a) * d)
		local isl = WorldKit.island({ position = pos, radius = r, height = r * 0.4, seed = i * 101 + (opts.seed or 7),
			top = opts.top, side = opts.side })
		WorldKit.scatter(isl, { trees = math.floor(r / 10), rocks = 2, lamps = opts.lamps or 1, style = opts.style,
			leaf = opts.leaf, lampColor = opts.lampColor, seed = i * 31 })
		table.insert(islands, isl)
	end
	return islands
end

return WorldKit
