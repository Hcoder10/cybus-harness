--!nonstrict
-- LookKit: art direction from configuration. One call makes the whole place read as a look: Lighting, Atmosphere,
-- Sky, post (bloom, grade, sun rays, depth of field), clouds, terrain material colours, water, a part-material
-- palette, and a colour palette the rest of the game reads (LookKit.palette.<role>). Server or edit mode.
--
-- Looks: toon_bright, realistic, cozy, neon_night, dark_fantasy, snow, desert, candy, space.
-- Limits worth knowing (engine, not kit):
--   * Lighting.Technology is not scriptable. "realistic" assumes Future (set it in Studio); every look still reads
--     under ShadowMap/Voxel, just with softer local lights.
--   * MaterialVariant.ColorMap/NormalMap/... are only writable from plugin/command-bar security. LookKit.material
--     tries the variant first and falls back to tiled Texture instances on every face, so the look survives a
--     runtime script either way.
--   * Roblox renders at most 31 Highlights at once; LookKit.outline counts its own and refuses past the budget.
--     Highlight outlines have a fixed screen-space width (no thickness property): thickness is accepted for API
--     stability and ignored. Outline a parent Model once instead of each child to save budget.

local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")
local MaterialService = game:GetService("MaterialService")

local LookKit = {}

local function rgb(r, g, b)
	return Color3.fromRGB(r, g, b)
end
local function hex(h)
	return Color3.fromHex(h)
end

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

local M = Enum.Material

-- Roles every look defines (missing ones fall back to BASE_PALETTE). Builders in WorldKit2 colour with these.
local BASE_PALETTE = {
	primary = hex("#e8483a"), secondary = hex("#3b7be0"), accent = hex("#ffc93c"),
	ground = hex("#6fbf4f"), groundAlt = hex("#9fd36a"), dirt = hex("#9c6b44"), rock = hex("#8f8a84"),
	sand = hex("#e9d29a"), wood = hex("#9a6640"), woodDark = hex("#5e3d28"), leaf = hex("#5bb14a"),
	leafAlt = hex("#8fd25b"), blossom = hex("#ff9fc8"), flower = hex("#ffd84a"), water = hex("#2f9fd8"),
	wall = hex("#f1e6d2"), roof = hex("#c9473b"), floor = hex("#c89a6a"), trim = hex("#ffffff"),
	ink = hex("#1b2236"), light = hex("#fff4dc"), glow = hex("#ffd27a"), metal = hex("#b9bec9"),
	path = hex("#d9c08f"), danger = hex("#ff3b3b"), gold = hex("#ffc83a"), sky = hex("#86c8ff"),
	fabric = hex("#d9534f"), snow = hex("#f4f8ff"),
}

-- Part material per role. Toon looks keep SmoothPlastic so colour does the talking.
local TOON_MATS = {
	default = M.SmoothPlastic, ground = M.SmoothPlastic, stone = M.SmoothPlastic, wood = M.SmoothPlastic,
	metal = M.SmoothPlastic, fabric = M.SmoothPlastic, glass = M.Glass, roof = M.SmoothPlastic,
	floor = M.SmoothPlastic, wall = M.SmoothPlastic, glow = M.Neon, leaf = M.SmoothPlastic, road = M.SmoothPlastic,
}
local REAL_MATS = {
	default = M.Plastic, ground = M.Ground, stone = M.Slate, wood = M.Wood, metal = M.Metal, fabric = M.Fabric,
	glass = M.Glass, roof = M.Slate, floor = M.WoodPlanks, wall = M.Plaster, glow = M.Neon, leaf = M.Grass,
	road = M.Asphalt,
}

local function merge(a, b)
	local out = {}
	for k, v in pairs(a or {}) do out[k] = v end
	for k, v in pairs(b or {}) do out[k] = v end
	return out
end

-- ---------------------------------------------------------------------------------------------------- presets
-- lighting: Lighting props. atmosphere/bloom/grade/sunrays/dof/clouds/sky: instance props (dof=false -> removed).
-- terrain: Enum.Material name -> colour. water: Terrain water props. mats: part material per role. palette: roles.
local LOOKS = {}

LOOKS.toon_bright = {
	lighting = { ClockTime = 14.2, GeographicLatitude = 35, Brightness = 3, ExposureCompensation = 0.1,
		Ambient = rgb(138, 138, 158), OutdoorAmbient = rgb(172, 172, 192), ColorShift_Top = rgb(255, 244, 222),
		ColorShift_Bottom = rgb(120, 130, 170), EnvironmentDiffuseScale = 0.4, EnvironmentSpecularScale = 0.1,
		ShadowSoftness = 0.55 },
	atmosphere = { Density = 0.24, Offset = 0.18, Color = rgb(176, 220, 255), Decay = rgb(110, 168, 236),
		Glare = 0.15, Haze = 0.7 },
	sky = { StarCount = 0, SunAngularSize = 20, MoonAngularSize = 11, CelestialBodiesShown = true },
	clouds = { Enabled = true, Cover = 0.55, Density = 0.5, Color = rgb(255, 255, 255) },
	bloom = { Intensity = 0.35, Size = 24, Threshold = 2 },
	grade = { Brightness = 0.03, Contrast = 0.12, Saturation = 0.35, TintColor = rgb(255, 252, 246) },
	sunrays = { Intensity = 0.05, Spread = 0.3 },
	dof = false,
	terrain = { Grass = rgb(92, 200, 72), LeafyGrass = rgb(70, 184, 62), Ground = rgb(176, 122, 72),
		Mud = rgb(140, 96, 60), Rock = rgb(158, 146, 136), Slate = rgb(130, 126, 124), Sand = rgb(250, 226, 150),
		Sandstone = rgb(236, 170, 104), Snow = rgb(250, 252, 255), Basalt = rgb(90, 84, 92), Limestone = rgb(236, 222, 190),
		Cobblestone = rgb(170, 160, 150) },
	water = { WaterColor = rgb(36, 168, 232), WaterTransparency = 0.25, WaterReflectance = 0.3, WaterWaveSize = 0.1,
		WaterWaveSpeed = 8 },
	mats = TOON_MATS,
	palette = { primary = hex("#ff4f3d"), secondary = hex("#3d7bff"), accent = hex("#ffd23c"), ground = hex("#5ccf4a"),
		groundAlt = hex("#a8e05f"), dirt = hex("#b5793f"), rock = hex("#a8a097"), wood = hex("#a8683a"),
		leaf = hex("#4fc443"), leafAlt = hex("#93e05a"), water = hex("#2aa7e8"), wall = hex("#fff3dd"),
		roof = hex("#ef4a3c"), trim = hex("#ffffff"), ink = hex("#1b2340"), gold = hex("#ffc93c"), sky = hex("#7cc8ff") },
	toon = true,
}

LOOKS.realistic = {
	lighting = { ClockTime = 15.3, GeographicLatitude = 40, Brightness = 3.2, ExposureCompensation = -0.1,
		Ambient = rgb(70, 70, 76), OutdoorAmbient = rgb(122, 124, 130), ColorShift_Top = rgb(255, 238, 214),
		ColorShift_Bottom = rgb(60, 64, 72), EnvironmentDiffuseScale = 1, EnvironmentSpecularScale = 1,
		ShadowSoftness = 0.12 },
	atmosphere = { Density = 0.32, Offset = 0.25, Color = rgb(199, 206, 214), Decay = rgb(106, 112, 125),
		Glare = 0.3, Haze = 1.6 },
	sky = { StarCount = 0, SunAngularSize = 11, MoonAngularSize = 9, CelestialBodiesShown = true },
	clouds = { Enabled = true, Cover = 0.62, Density = 0.6, Color = rgb(236, 238, 242) },
	bloom = { Intensity = 0.22, Size = 24, Threshold = 2.2 },
	grade = { Brightness = 0, Contrast = 0.1, Saturation = -0.06, TintColor = rgb(255, 250, 244) },
	sunrays = { Intensity = 0.07, Spread = 0.16 },
	dof = { FarIntensity = 0.12, FocusDistance = 60, InFocusRadius = 90, NearIntensity = 0 },
	terrain = { Grass = rgb(84, 102, 60), LeafyGrass = rgb(72, 92, 52), Ground = rgb(98, 82, 64), Mud = rgb(72, 60, 48),
		Rock = rgb(112, 108, 102), Slate = rgb(92, 92, 92), Sand = rgb(190, 174, 140), Sandstone = rgb(160, 124, 92),
		Snow = rgb(232, 236, 242), Asphalt = rgb(62, 62, 64), Concrete = rgb(128, 126, 122), Basalt = rgb(60, 58, 60),
		Cobblestone = rgb(110, 104, 98) },
	water = { WaterColor = rgb(40, 76, 84), WaterTransparency = 0.6, WaterReflectance = 0.8, WaterWaveSize = 0.15,
		WaterWaveSpeed = 6 },
	mats = REAL_MATS,
	palette = { primary = hex("#6b705c"), secondary = hex("#3f4a3c"), accent = hex("#c2a878"), ground = hex("#58663c"),
		groundAlt = hex("#6f7a48"), dirt = hex("#62523f"), rock = hex("#706c66"), sand = hex("#bead8c"), wood = hex("#6e5440"),
		woodDark = hex("#3e3026"), leaf = hex("#4a5e34"), leafAlt = hex("#5f7040"), blossom = hex("#d8a8b8"),
		flower = hex("#d8c25a"), water = hex("#284c54"), wall = hex("#b8b0a2"), roof = hex("#5a4a42"), floor = hex("#7a5e44"),
		trim = hex("#d8d4cc"), ink = hex("#1e2022"), light = hex("#ffe9c4"), glow = hex("#ffcf8a"), metal = hex("#7c8088"),
		path = hex("#8c8270"), danger = hex("#c43c2c"), gold = hex("#c8a24a"), sky = hex("#9fb4c8"), fabric = hex("#5c6650") },
}

LOOKS.cozy = {
	lighting = { ClockTime = 17.45, GeographicLatitude = 28, Brightness = 2.2, ExposureCompensation = 0.15,
		Ambient = rgb(132, 112, 102), OutdoorAmbient = rgb(168, 142, 126), ColorShift_Top = rgb(255, 214, 170),
		ColorShift_Bottom = rgb(110, 80, 96), EnvironmentDiffuseScale = 0.6, EnvironmentSpecularScale = 0.2,
		ShadowSoftness = 0.8 },
	atmosphere = { Density = 0.26, Offset = 0.12, Color = rgb(255, 216, 186), Decay = rgb(224, 156, 144), Glare = 0.4,
		Haze = 1.2 },
	sky = { StarCount = 0, SunAngularSize = 18, MoonAngularSize = 11, CelestialBodiesShown = true },
	clouds = { Enabled = true, Cover = 0.5, Density = 0.45, Color = rgb(255, 222, 206) },
	bloom = { Intensity = 0.6, Size = 32, Threshold = 1.4 },
	grade = { Brightness = 0.03, Contrast = 0.02, Saturation = 0.08, TintColor = rgb(255, 240, 226) },
	sunrays = { Intensity = 0.08, Spread = 0.5 },
	dof = { FarIntensity = 0.08, FocusDistance = 40, InFocusRadius = 70, NearIntensity = 0 },
	terrain = { Grass = rgb(150, 196, 120), LeafyGrass = rgb(130, 180, 108), Ground = rgb(196, 150, 112),
		Mud = rgb(150, 112, 90), Rock = rgb(186, 170, 160), Sand = rgb(246, 222, 178), Snow = rgb(255, 250, 246),
		Cobblestone = rgb(200, 182, 168), WoodPlanks = rgb(200, 150, 108) },
	water = { WaterColor = rgb(110, 190, 196), WaterTransparency = 0.35, WaterReflectance = 0.35 },
	mats = merge(TOON_MATS, { wood = M.Wood, fabric = M.Fabric, floor = M.WoodPlanks }),
	palette = { primary = hex("#f2a07b"), secondary = hex("#8ec5b5"), accent = hex("#f7d488"), ground = hex("#a4cc84"),
		groundAlt = hex("#c3dd9a"), dirt = hex("#c49670"), rock = hex("#bcaea2"), sand = hex("#f6dfb4"), wood = hex("#c08a5c"),
		woodDark = hex("#8a5c40"), leaf = hex("#8fc27a"), leafAlt = hex("#b5d98e"), blossom = hex("#ffb7c5"),
		flower = hex("#ffd27a"), water = hex("#6ebec4"), wall = hex("#fbeee0"), roof = hex("#d9776a"), floor = hex("#d9a77a"),
		trim = hex("#fff8ee"), ink = hex("#4a3a3a"), light = hex("#fff1d6"), glow = hex("#ffc98a"), metal = hex("#c9c2bc"),
		path = hex("#e6c9a0"), danger = hex("#e8645a"), gold = hex("#f2c14e"), sky = hex("#ffd9c0"), fabric = hex("#e98e8e") },
}

LOOKS.neon_night = {
	lighting = { ClockTime = 0.2, GeographicLatitude = 30, Brightness = 0.7, ExposureCompensation = 0.35,
		Ambient = rgb(42, 32, 72), OutdoorAmbient = rgb(54, 44, 96), ColorShift_Top = rgb(140, 120, 255),
		ColorShift_Bottom = rgb(20, 10, 40), EnvironmentDiffuseScale = 0.5, EnvironmentSpecularScale = 1,
		ShadowSoftness = 0.3 },
	atmosphere = { Density = 0.36, Offset = 0.05, Color = rgb(96, 44, 150), Decay = rgb(22, 10, 54), Glare = 0, Haze = 2.2 },
	sky = { StarCount = 2500, SunAngularSize = 0, MoonAngularSize = 9, CelestialBodiesShown = true },
	clouds = { Enabled = true, Cover = 0.35, Density = 0.3, Color = rgb(70, 46, 120) },
	bloom = { Intensity = 1.2, Size = 40, Threshold = 0.9 },
	grade = { Brightness = 0.02, Contrast = 0.2, Saturation = 0.35, TintColor = rgb(236, 226, 255) },
	sunrays = { Intensity = 0, Spread = 0 },
	dof = false,
	terrain = { Asphalt = rgb(26, 24, 36), Concrete = rgb(44, 42, 58), Grass = rgb(30, 60, 70), Ground = rgb(36, 30, 50),
		Rock = rgb(50, 46, 66), Slate = rgb(40, 38, 54), Pavement = rgb(48, 44, 64), Basalt = rgb(30, 28, 40) },
	water = { WaterColor = rgb(30, 16, 70), WaterTransparency = 0.2, WaterReflectance = 1 },
	mats = merge(TOON_MATS, { metal = M.Metal, glass = M.Glass, road = M.Asphalt }),
	palette = { primary = hex("#ff2bd6"), secondary = hex("#00e5ff"), accent = hex("#fff94a"), ground = hex("#16141f"),
		groundAlt = hex("#211d33"), dirt = hex("#2a2438"), rock = hex("#34304a"), sand = hex("#3a3550"), wood = hex("#3a2a3e"),
		woodDark = hex("#22182a"), leaf = hex("#1fbf8f"), leafAlt = hex("#39ffb0"), blossom = hex("#ff5fd0"),
		flower = hex("#fff94a"), water = hex("#1e1046"), wall = hex("#1c1a2e"), roof = hex("#2a2742"), floor = hex("#1a1828"),
		trim = hex("#00e5ff"), ink = hex("#07060d"), light = hex("#e8e0ff"), glow = hex("#ff2bd6"), metal = hex("#5a5878"),
		path = hex("#2d2a40"), danger = hex("#ff3355"), gold = hex("#ffd84a"), sky = hex("#3a1a6e"), fabric = hex("#7a2bff") },
	neon = { hex("#ff2bd6"), hex("#00e5ff"), hex("#fff94a"), hex("#7a5cff"), hex("#39ffb0") },
}

LOOKS.dark_fantasy = {
	lighting = { ClockTime = 17.9, GeographicLatitude = 55, Brightness = 1.3, ExposureCompensation = 0.05,
		Ambient = rgb(52, 56, 72), OutdoorAmbient = rgb(70, 78, 96), ColorShift_Top = rgb(176, 196, 255),
		ColorShift_Bottom = rgb(40, 28, 50), EnvironmentDiffuseScale = 0.5, EnvironmentSpecularScale = 0.6,
		ShadowSoftness = 0.25 },
	atmosphere = { Density = 0.46, Offset = 0.1, Color = rgb(92, 102, 124), Decay = rgb(38, 40, 62), Glare = 0, Haze = 2.6 },
	sky = { StarCount = 600, SunAngularSize = 8, MoonAngularSize = 14, CelestialBodiesShown = true },
	clouds = { Enabled = true, Cover = 0.8, Density = 0.75, Color = rgb(96, 100, 116) },
	bloom = { Intensity = 0.55, Size = 30, Threshold = 1.3 },
	grade = { Brightness = -0.03, Contrast = 0.18, Saturation = -0.35, TintColor = rgb(214, 224, 255) },
	sunrays = { Intensity = 0.12, Spread = 0.6 },
	dof = { FarIntensity = 0.22, FocusDistance = 50, InFocusRadius = 60, NearIntensity = 0 },
	terrain = { Grass = rgb(62, 72, 56), LeafyGrass = rgb(54, 64, 50), Ground = rgb(62, 56, 52), Mud = rgb(46, 42, 40),
		Rock = rgb(74, 74, 82), Slate = rgb(60, 62, 72), Basalt = rgb(40, 40, 46), Snow = rgb(196, 204, 220),
		CrackedLava = rgb(255, 90, 40), Cobblestone = rgb(72, 70, 76) },
	water = { WaterColor = rgb(26, 36, 44), WaterTransparency = 0.5, WaterReflectance = 0.9 },
	mats = merge(REAL_MATS, { stone = M.Slate, metal = M.CorrodedMetal, wall = M.Cobblestone, floor = M.Cobblestone }),
	palette = { primary = hex("#6a2c3a"), secondary = hex("#4b5a6b"), accent = hex("#8fd0ff"), ground = hex("#3b3f35"),
		groundAlt = hex("#4a4d40"), dirt = hex("#3e3630"), rock = hex("#4a4a52"), sand = hex("#6a6258"), wood = hex("#4b3a2e"),
		woodDark = hex("#2b211b"), leaf = hex("#33402f"), leafAlt = hex("#46523c"), blossom = hex("#8a5a7a"),
		flower = hex("#9ab0d8"), water = hex("#1a242c"), wall = hex("#55545c"), roof = hex("#2e2a33"), floor = hex("#3c3a40"),
		trim = hex("#8a8796"), ink = hex("#0c0b10"), light = hex("#c8d8ff"), glow = hex("#ff8a3d"), metal = hex("#5c5f68"),
		path = hex("#4d4a48"), danger = hex("#b0202e"), gold = hex("#a8873e"), sky = hex("#5a6478"), fabric = hex("#5a2430") },
}

LOOKS.snow = {
	lighting = { ClockTime = 10.4, GeographicLatitude = 62, Brightness = 2.6, ExposureCompensation = -0.1,
		Ambient = rgb(150, 164, 190), OutdoorAmbient = rgb(170, 184, 210), ColorShift_Top = rgb(255, 240, 222),
		ColorShift_Bottom = rgb(120, 140, 190), EnvironmentDiffuseScale = 0.8, EnvironmentSpecularScale = 0.6,
		ShadowSoftness = 0.4 },
	atmosphere = { Density = 0.38, Offset = 0.2, Color = rgb(214, 230, 250), Decay = rgb(148, 174, 212), Glare = 0.45,
		Haze = 2 },
	sky = { StarCount = 0, SunAngularSize = 14, MoonAngularSize = 11, CelestialBodiesShown = true },
	clouds = { Enabled = true, Cover = 0.72, Density = 0.6, Color = rgb(236, 242, 252) },
	bloom = { Intensity = 0.4, Size = 26, Threshold = 1.6 },
	grade = { Brightness = 0.02, Contrast = 0.06, Saturation = -0.04, TintColor = rgb(236, 245, 255) },
	sunrays = { Intensity = 0.1, Spread = 0.35 },
	dof = false,
	terrain = { Snow = rgb(242, 247, 255), Glacier = rgb(170, 214, 240), Ice = rgb(190, 226, 248), Rock = rgb(108, 114, 130),
		Slate = rgb(90, 96, 112), Grass = rgb(120, 150, 130), Ground = rgb(120, 110, 104), Basalt = rgb(70, 74, 88) },
	water = { WaterColor = rgb(70, 130, 170), WaterTransparency = 0.4, WaterReflectance = 0.7 },
	mats = merge(TOON_MATS, { wood = M.Wood, stone = M.Slate, ground = M.Snow }),
	palette = { primary = hex("#d64545"), secondary = hex("#2f6fb3"), accent = hex("#ffb03b"), ground = hex("#eef4fb"),
		groundAlt = hex("#cfdff0"), dirt = hex("#8a7a70"), rock = hex("#6f7789"), sand = hex("#d8dde6"), wood = hex("#6b4a3a"),
		woodDark = hex("#45302a"), leaf = hex("#2f5d4a"), leafAlt = hex("#3f7560"), blossom = hex("#ffd0dc"),
		flower = hex("#ff8a5a"), water = hex("#4682aa"), wall = hex("#c9a07a"), roof = hex("#f4f8ff"), floor = hex("#8a6448"),
		trim = hex("#ffffff"), ink = hex("#1c2433"), light = hex("#fff2d8"), glow = hex("#ffb35a"), metal = hex("#9aa4b4"),
		path = hex("#b8c6d8"), danger = hex("#e04040"), gold = hex("#f2c14e"), sky = hex("#bcd8f4"), fabric = hex("#b73a3a") },
}

LOOKS.desert = {
	lighting = { ClockTime = 13.6, GeographicLatitude = 20, Brightness = 3.4, ExposureCompensation = -0.05,
		Ambient = rgb(150, 120, 92), OutdoorAmbient = rgb(184, 150, 116), ColorShift_Top = rgb(255, 232, 196),
		ColorShift_Bottom = rgb(150, 90, 60), EnvironmentDiffuseScale = 0.7, EnvironmentSpecularScale = 0.4,
		ShadowSoftness = 0.2 },
	atmosphere = { Density = 0.3, Offset = 0.05, Color = rgb(250, 216, 162), Decay = rgb(212, 142, 92), Glare = 0.5,
		Haze = 1.8 },
	sky = { StarCount = 0, SunAngularSize = 16, MoonAngularSize = 11, CelestialBodiesShown = true },
	clouds = { Enabled = true, Cover = 0.3, Density = 0.3, Color = rgb(255, 240, 222) },
	bloom = { Intensity = 0.4, Size = 26, Threshold = 1.7 },
	grade = { Brightness = 0.02, Contrast = 0.1, Saturation = 0.12, TintColor = rgb(255, 240, 216) },
	sunrays = { Intensity = 0.1, Spread = 0.4 },
	dof = false,
	terrain = { Sand = rgb(228, 192, 132), Sandstone = rgb(204, 130, 82), Rock = rgb(170, 110, 76), Ground = rgb(196, 146, 98),
		Salt = rgb(240, 232, 214), Limestone = rgb(230, 206, 160), Grass = rgb(150, 160, 84), Mud = rgb(150, 100, 70) },
	water = { WaterColor = rgb(40, 150, 150), WaterTransparency = 0.3, WaterReflectance = 0.4 },
	mats = merge(TOON_MATS, { stone = M.Sandstone, wood = M.Wood, wall = M.Sandstone, ground = M.Sand }),
	palette = { primary = hex("#d9542e"), secondary = hex("#2b8c8c"), accent = hex("#f2c14e"), ground = hex("#e2be82"),
		groundAlt = hex("#d6a066"), dirt = hex("#b07a50"), rock = hex("#b8714a"), sand = hex("#ead0a0"), wood = hex("#8a5a3a"),
		woodDark = hex("#5a3a26"), leaf = hex("#6f8f3e"), leafAlt = hex("#8aa84a"), blossom = hex("#ff8fa8"),
		flower = hex("#ff5a4a"), water = hex("#2a9696"), wall = hex("#e8cfa4"), roof = hex("#b8603a"), floor = hex("#c89a6a"),
		trim = hex("#fff2d8"), ink = hex("#3a2216"), light = hex("#fff2d0"), glow = hex("#ffb84a"), metal = hex("#a8a094"),
		path = hex("#d8b07a"), danger = hex("#d83a2a"), gold = hex("#e8b030"), sky = hex("#9cd2f0"), fabric = hex("#2b8c8c") },
}

LOOKS.candy = {
	lighting = { ClockTime = 14, GeographicLatitude = 30, Brightness = 3, ExposureCompensation = 0.12,
		Ambient = rgb(190, 160, 200), OutdoorAmbient = rgb(222, 186, 230), ColorShift_Top = rgb(255, 236, 246),
		ColorShift_Bottom = rgb(170, 120, 200), EnvironmentDiffuseScale = 0.4, EnvironmentSpecularScale = 0.3,
		ShadowSoftness = 0.9 },
	atmosphere = { Density = 0.3, Offset = 0.15, Color = rgb(255, 204, 236), Decay = rgb(255, 150, 212), Glare = 0.3,
		Haze = 1 },
	sky = { StarCount = 0, SunAngularSize = 22, MoonAngularSize = 12, CelestialBodiesShown = true },
	clouds = { Enabled = true, Cover = 0.6, Density = 0.55, Color = rgb(255, 232, 246) },
	bloom = { Intensity = 0.5, Size = 30, Threshold = 1.6 },
	grade = { Brightness = 0.04, Contrast = 0.05, Saturation = 0.3, TintColor = rgb(255, 246, 252) },
	sunrays = { Intensity = 0.06, Spread = 0.4 },
	dof = false,
	terrain = { Grass = rgb(150, 240, 190), LeafyGrass = rgb(130, 230, 176), Ground = rgb(255, 172, 202),
		Mud = rgb(150, 92, 70), Sand = rgb(255, 230, 180), Snow = rgb(255, 255, 255), Rock = rgb(200, 156, 255),
		Sandstone = rgb(255, 190, 150), Ice = rgb(190, 240, 255), Glacier = rgb(170, 230, 255) },
	water = { WaterColor = rgb(255, 128, 196), WaterTransparency = 0.2, WaterReflectance = 0.25 },
	mats = TOON_MATS,
	palette = { primary = hex("#ff5fa2"), secondary = hex("#6fd6ff"), accent = hex("#ffe066"), ground = hex("#9df2c4"),
		groundAlt = hex("#ffc2dd"), dirt = hex("#a8664a"), rock = hex("#c79bff"), sand = hex("#ffe6b4"), wood = hex("#ffb3c7"),
		woodDark = hex("#7a4a3a"), leaf = hex("#ff8fc1"), leafAlt = hex("#9df2c4"), blossom = hex("#ffd1e8"),
		flower = hex("#ffe066"), water = hex("#ff80c4"), wall = hex("#fff0f6"), roof = hex("#ff5fa2"), floor = hex("#ffd6a5"),
		trim = hex("#ffffff"), ink = hex("#5a2a4a"), light = hex("#fff8fc"), glow = hex("#ffe066"), metal = hex("#d8d0f0"),
		path = hex("#fff1c4"), danger = hex("#ff4a6a"), gold = hex("#ffd23c"), sky = hex("#ffd1ee"), fabric = hex("#b38cff") },
	candy = { hex("#ff5fa2"), hex("#6fd6ff"), hex("#ffe066"), hex("#9df2c4"), hex("#c79bff"), hex("#ff9a5f") },
}

LOOKS.space = {
	lighting = { ClockTime = 0.5, GeographicLatitude = 0, Brightness = 2.6, ExposureCompensation = 0.6,
		Ambient = rgb(70, 72, 104), OutdoorAmbient = rgb(98, 100, 140), ColorShift_Top = rgb(206, 214, 255),
		ColorShift_Bottom = rgb(40, 30, 70), EnvironmentDiffuseScale = 0.5, EnvironmentSpecularScale = 1,
		ShadowSoftness = 0.05 },
	atmosphere = { Density = 0, Offset = 0, Color = rgb(0, 0, 0), Decay = rgb(0, 0, 0), Glare = 0, Haze = 0 },
	sky = { StarCount = 5000, SunAngularSize = 0, MoonAngularSize = 4, CelestialBodiesShown = true },
	clouds = { Enabled = false },
	bloom = { Intensity = 0.8, Size = 36, Threshold = 1.1 },
	grade = { Brightness = 0, Contrast = 0.16, Saturation = 0.15, TintColor = rgb(230, 236, 255) },
	sunrays = { Intensity = 0, Spread = 0 },
	dof = false,
	terrain = { Basalt = rgb(58, 58, 74), Rock = rgb(92, 92, 112), Slate = rgb(70, 70, 86), Ground = rgb(80, 74, 90),
		CrackedLava = rgb(80, 200, 255), Glacier = rgb(120, 200, 255), Salt = rgb(150, 150, 170) },
	water = { WaterColor = rgb(40, 60, 120), WaterTransparency = 0.3, WaterReflectance = 1 },
	mats = merge(TOON_MATS, { metal = M.Metal, stone = M.Basalt, ground = M.Basalt }),
	palette = { primary = hex("#ff7a2f"), secondary = hex("#4ad6ff"), accent = hex("#b06bff"), ground = hex("#2a2c3a"),
		groundAlt = hex("#3a3c4e"), dirt = hex("#45404e"), rock = hex("#585a70"), sand = hex("#6a6878"), wood = hex("#5a4a44"),
		woodDark = hex("#2e2626"), leaf = hex("#3fd6a0"), leafAlt = hex("#7affd0"), blossom = hex("#ff8ad8"),
		flower = hex("#4ad6ff"), water = hex("#28407a"), wall = hex("#c0c6d6"), roof = hex("#4a4e62"), floor = hex("#3a3e50"),
		trim = hex("#e8ecf8"), ink = hex("#05060c"), light = hex("#e6ecff"), glow = hex("#4ad6ff"), metal = hex("#c0c6d6"),
		path = hex("#4a4c60"), danger = hex("#ff4a3a"), gold = hex("#ffc84a"), sky = hex("#0a0c1e"), fabric = hex("#ff7a2f") },
}

LookKit.presets = LOOKS
LookKit.looks = { "toon_bright", "realistic", "cozy", "neon_night", "dark_fantasy", "snow", "desert", "candy", "space" }
LookKit.current = nil
LookKit.palette = merge(BASE_PALETTE, LOOKS.toon_bright.palette)
LookKit.materials = TOON_MATS
LookKit.isToon = true

-- ---------------------------------------------------------------------------------------------------- apply

local function ensure(parent, class, name)
	local inst = parent:FindFirstChild(name)
	if not inst or not inst:IsA(class) then
		inst = Instance.new(class)
		inst.Name = name
		inst.Parent = parent
	end
	return inst
end

local function setProps(inst, props, tweenTime)
	local tweenable, direct = {}, {}
	for k, v in pairs(props) do
		local t = typeof(v)
		if tweenTime and tweenTime > 0 and (t == "number" or t == "Color3") then
			tweenable[k] = v
		else
			direct[k] = v
		end
	end
	for k, v in pairs(direct) do
		pcall(function() inst[k] = v end)
	end
	if next(tweenable) then
		local ok = pcall(function()
			TweenService:Create(inst, TweenInfo.new(tweenTime, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
				tweenable):Play()
		end)
		if not ok then
			for k, v in pairs(tweenable) do
				pcall(function() inst[k] = v end)
			end
		end
	end
end

local function deepMerge(base, over)
	local out = {}
	for k, v in pairs(base) do
		out[k] = v
	end
	for k, v in pairs(over or {}) do
		if type(v) == "table" and type(out[k]) == "table" then
			out[k] = deepMerge(out[k], v)
		else
			out[k] = v
		end
	end
	return out
end

-- LookKit.apply(look, overrides?) -> palette. overrides may replace any preset section
-- ({lighting={}, atmosphere={}, sky={}, clouds={}, bloom={}, grade={}, sunrays={}, dof=false|{}, terrain={Grass=Color3},
-- water={}, palette={role=Color3|"#hex"}, mats={role=Enum.Material}}) plus tween=seconds to blend from the current look.
function LookKit.apply(look, overrides)
	local base = LOOKS[look or "toon_bright"]
	if not base then
		warn("[LookKit] unknown look " .. tostring(look) .. "; using toon_bright")
		look = "toon_bright"
		base = LOOKS.toon_bright
	end
	overrides = overrides or {}
	local p = deepMerge(base, overrides)
	local tw = overrides.tween

	Lighting.GlobalShadows = true
	setProps(Lighting, p.lighting, tw)
	-- an Atmosphere makes legacy Fog inert; park it far so a leftover FogEnd never greys the look
	Lighting.FogEnd = 100000
	Lighting.FogStart = 0

	-- remove leftovers that fight the look (another game's Sky / second Atmosphere)
	for _, ch in ipairs(Lighting:GetChildren()) do
		local keep = { KitSky = true, Atmosphere = true }
		if (ch:IsA("Sky") or ch:IsA("Atmosphere")) and not keep[ch.Name] then
			ch:Destroy()
		end
	end
	setProps(ensure(Lighting, "Atmosphere", "Atmosphere"), p.atmosphere, tw)
	local sky = ensure(Lighting, "Sky", "KitSky")
	setProps(sky, p.sky, nil)
	if LookKit._skybox then
		LookKit.skybox(LookKit._skybox)
	end
	setProps(ensure(Lighting, "BloomEffect", "KitBloom"), p.bloom, tw)
	local grade = ensure(Lighting, "ColorCorrectionEffect", "KitGrade")
	setProps(grade, p.grade, tw)
	setProps(ensure(Lighting, "SunRaysEffect", "KitSunRays"), p.sunrays, tw)
	if p.dof then
		local dof = ensure(Lighting, "DepthOfFieldEffect", "KitDOF")
		dof.Enabled = true
		setProps(dof, p.dof, tw)
	else
		local dof = Lighting:FindFirstChild("KitDOF")
		if dof then dof:Destroy() end
	end

	local terrain = Workspace.Terrain
	local clouds = terrain:FindFirstChildOfClass("Clouds")
	if p.clouds and p.clouds.Enabled ~= false then
		if not clouds then
			clouds = Instance.new("Clouds")
			clouds.Parent = terrain
		end
		clouds.Enabled = true
		setProps(clouds, p.clouds, tw)
	elseif clouds then
		clouds.Enabled = false
	end
	for matName, col in pairs(p.terrain or {}) do
		pcall(function() -- an unknown Enum.Material name throws; skip it
			terrain:SetMaterialColor((Enum.Material :: any)[matName], c3(col, Color3.new(1, 1, 1)))
		end)
	end
	setProps(terrain, p.water or {}, nil)

	local pal = merge(BASE_PALETTE, base.palette)
	for k, v in pairs(overrides.palette or {}) do
		pal[k] = c3(v, pal[k])
	end
	pal.neon = p.neon or { pal.primary, pal.secondary, pal.accent, pal.glow }
	pal.candy = p.candy or { pal.primary, pal.secondary, pal.accent, pal.groundAlt }
	LookKit.palette = pal
	LookKit.materials = merge(TOON_MATS, p.mats)
	LookKit.isToon = p.toon == true or p.mats == TOON_MATS
	LookKit.current = look
	Lighting:SetAttribute("KitLook", look)
	return pal
end

-- LookKit.color(role, fallback?) -> Color3 from the current look's palette.
function LookKit.color(role, fallback)
	return LookKit.palette[role] or c3(fallback, BASE_PALETTE[role] or Color3.new(1, 0, 1))
end

-- LookKit.mat(role) -> Enum.Material the current look uses for that role
-- (default, ground, stone, wood, metal, fabric, glass, roof, floor, wall, glow, leaf, road).
function LookKit.mat(role)
	return LookKit.materials[role] or LookKit.materials.default or M.SmoothPlastic
end

-- LookKit.style(part, colorRole, materialRole?) paints a part from the look (materialRole defaults to "default").
function LookKit.style(part, colorRole, materialRole)
	part.Color = LookKit.color(colorRole)
	part.Material = LookKit.mat(materialRole or "default")
	return part
end

local function asId(v)
	if type(v) == "number" then
		return "rbxassetid://" .. tostring(v)
	end
	if type(v) == "string" and v:match("^%d+$") then
		return "rbxassetid://" .. v
	end
	return v
end

-- LookKit.skybox({bk, dn, ft, lf, rt, up} image ids or rbxassetid strings, orientation=Vector3?) sets the six faces
-- (e.g. generated art). It persists across later LookKit.apply calls; LookKit.skybox(nil) returns to the default sky.
function LookKit.skybox(faces)
	LookKit._skybox = faces
	local sky = ensure(Lighting, "Sky", "KitSky")
	if not faces then
		return sky
	end
	local map = { bk = "SkyboxBk", dn = "SkyboxDn", ft = "SkyboxFt", lf = "SkyboxLf", rt = "SkyboxRt", up = "SkyboxUp" }
	for k, prop in pairs(map) do
		if faces[k] then
			pcall(function() (sky :: any)[prop] = asId(faces[k]) end)
		end
	end
	if faces.orientation then
		sky.SkyboxOrientation = faces.orientation
	end
	return sky
end

-- ---------------------------------------------------------------------------------------------------- materials

local customMats = {}

-- LookKit.material(name, {base=Enum.Material, colorMap=imageId, normalMap?, roughnessMap?, metalnessMap?,
-- studsPerTile=8, overrideBase=false}) registers a tileable material. Creates a MaterialVariant in MaterialService when
-- the engine lets this script set its maps (plugin / edit-mode builds); otherwise LookKit.useMaterial tiles Texture
-- instances on the faces instead. overrideBase=true also makes terrain/parts of that base material use it.
function LookKit.material(name, spec)
	spec = spec or {}
	local rec = { name = name, base = spec.base or M.SmoothPlastic, colorMap = asId(spec.colorMap),
		studs = spec.studsPerTile or 8, color = c3(spec.color, nil), variant = nil }
	local old = MaterialService:FindFirstChild(name)
	if old and old:IsA("MaterialVariant") then
		old:Destroy()
	end
	local ok = pcall(function()
		local mv = Instance.new("MaterialVariant")
		mv.Name = name
		mv.BaseMaterial = rec.base
		mv.StudsPerTile = rec.studs
		local any = mv :: any
		if rec.colorMap then any.ColorMap = rec.colorMap end
		if spec.normalMap then any.NormalMap = asId(spec.normalMap) end
		if spec.roughnessMap then any.RoughnessMap = asId(spec.roughnessMap) end
		if spec.metalnessMap then any.MetalnessMap = asId(spec.metalnessMap) end
		mv.Parent = MaterialService
		rec.variant = mv
	end)
	if not ok and rec.variant == nil then
		local stray = MaterialService:FindFirstChild(name)
		if stray then stray:Destroy() end
	end
	if rec.variant and spec.overrideBase then
		pcall(function() MaterialService:SetBaseMaterialOverride(rec.base, name) end)
	end
	customMats[name] = rec
	return rec
end

local FACES = { Enum.NormalId.Top, Enum.NormalId.Bottom, Enum.NormalId.Front, Enum.NormalId.Back, Enum.NormalId.Left,
	Enum.NormalId.Right }

-- LookKit.useMaterial(partOrModel, name) applies a registered material (variant, or tiled textures as fallback).
function LookKit.useMaterial(target, name)
	local rec = customMats[name]
	if not rec then
		warn("[LookKit] material not registered: " .. tostring(name))
		return false
	end
	local parts = {}
	if target:IsA("BasePart") then
		table.insert(parts, target)
	else
		for _, d in ipairs(target:GetDescendants()) do
			if d:IsA("BasePart") then table.insert(parts, d) end
		end
	end
	for _, p in ipairs(parts) do
		p.Material = rec.base
		if rec.color then p.Color = rec.color end
		if rec.variant then
			p.MaterialVariant = name
		elseif rec.colorMap then
			for _, face in ipairs(FACES) do
				local t = p:FindFirstChild("LookTex_" .. face.Name)
				if not t then
					t = Instance.new("Texture")
					t.Name = "LookTex_" .. face.Name
					t.Face = face
					t.Parent = p
				end
				t.Texture = rec.colorMap
				t.StudsPerTileU = rec.studs
				t.StudsPerTileV = rec.studs
			end
		end
	end
	return true
end

-- ---------------------------------------------------------------------------------------------------- cel helpers

local HIGHLIGHT_BUDGET = 31
local liveHighlights = 0
LookKit.highlightBudget = HIGHLIGHT_BUDGET

-- LookKit.outline(model, color=palette.ink, thickness?) -> Highlight? Cel outline via Highlight (fill hidden).
-- Budget: 31 Highlights render at once engine-wide; this returns nil past the budget (counted for LookKit's own).
-- thickness is ignored (Highlight outlines are fixed-width). Outline a parent Model to cover many props with one.
function LookKit.outline(model, color, thickness)
	local _ = thickness
	local existing = model:FindFirstChild("KitOutline")
	if existing and existing:IsA("Highlight") then
		existing.OutlineColor = c3(color, LookKit.palette.ink)
		return existing
	end
	if liveHighlights >= HIGHLIGHT_BUDGET then
		warn("[LookKit] Highlight budget (31) reached; outline the parent model instead")
		return nil
	end
	local h = Instance.new("Highlight")
	h.Name = "KitOutline"
	h.FillTransparency = 1
	h.OutlineTransparency = 0
	h.OutlineColor = c3(color, LookKit.palette.ink)
	h.DepthMode = Enum.HighlightDepthMode.Occluded
	h.Adornee = model
	h.Parent = model
	liveHighlights += 1
	h.Destroying:Connect(function()
		liveHighlights -= 1
	end)
	return h
end

local function nearest(col, list)
	local best, bestD = col, math.huge
	for _, c in ipairs(list) do
		-- weighted RGB distance (cheap perceptual approximation)
		local dr, dg, db = col.R - c.R, col.G - c.G, col.B - c.B
		local d = 0.3 * dr * dr + 0.59 * dg * dg + 0.11 * db * db
		if d < bestD then
			best, bestD = c, d
		end
	end
	return best
end

-- LookKit.toonify(model, {quantize=true, palette?, keepNeon=true, outline=false}) flattens a model to the cel look:
-- SmoothPlastic, no reflectance, each colour snapped to the nearest palette colour. Returns the model.
function LookKit.toonify(model, opts)
	opts = opts or {}
	local list = {}
	for k, v in pairs(opts.palette or LookKit.palette) do
		if typeof(v) == "Color3" and k ~= "sky" then
			table.insert(list, v)
		end
	end
	local parts = model:IsA("BasePart") and { model } or model:GetDescendants()
	for _, p in ipairs(parts) do
		if p:IsA("BasePart") and p.Material ~= M.Neon and p.Material ~= M.Glass and p.Material ~= M.ForceField then
			p.Material = M.SmoothPlastic
			p.Reflectance = 0
			p.MaterialVariant = ""
			if opts.quantize ~= false and #list > 0 then
				p.Color = nearest(p.Color, list)
			end
		end
	end
	if opts.outline then
		LookKit.outline(model, opts.outlineColor)
	end
	return model
end

return LookKit
