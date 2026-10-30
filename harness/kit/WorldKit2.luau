--!nonstrict
-- WorldKit2: genre-general world builders on top of WorldKit (every WorldKit.* call still works through this module).
-- Biomes, course/obby/arena/room/town/dungeon builders, and a part-built prop library. Everything is palette-aware:
-- colours come from LookKit.palette (call LookKit.apply first) unless opts.palette / opts.color override them.
-- All geometry is anchored; tiny bits never cast shadows and decorative bits never collide. Server or edit mode.
--
-- Engine facts this file is written around:
--   * Part Shape=Cylinder lies along X: vertical cylinders are rotated 90 degrees about Z (vcyl below).
--   * Part Shape=Ball is always a sphere: flattened blobs (canopies, caps, bushes) use a block Part with a
--     SpecialMesh(MeshType=Sphere), which renders the part's full non-uniform size.
--   * No MeshParts and no mesh asset ids anywhere: an empty MeshPart is invisible.
-- Gameplay hooks are CollectionService tags (KitMover, KitSpinner, KitCrumble, KitBounce, KitCoin, KitGem, KitGoal,
-- KitCheckpoint, KitGate, KitSpawn, KitStation) plus attributes; WorldKit2.animate() drives the moving ones.

local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local Kit = script.Parent
local WorldKit = require(Kit:WaitForChild("WorldKit"))
local LookKit = require(Kit:WaitForChild("LookKit"))

local WK2 = setmetatable({}, { __index = WorldKit })
WK2.WorldKit = WorldKit
WK2.LookKit = LookKit

local M = Enum.Material
local V3 = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles
local PI = math.pi
local rad = math.rad

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

local function toCF(v)
	if typeof(v) == "Vector3" then
		return CF(v)
	end
	return v
end

local function folder(name, parent)
	parent = parent or Workspace
	local f = parent:FindFirstChild(name)
	if not f then
		f = Instance.new("Folder")
		f.Name = name
		f.Parent = parent
	end
	return f
end
WK2.folder = function(name)
	return folder(name)
end

-- palette for one call: the look's palette, then opts.palette overrides
local function palOf(o)
	local pal = {}
	for k, v in pairs(LookKit.palette) do pal[k] = v end
	if o and o.palette then
		for k, v in pairs(o.palette) do pal[k] = c3(v, pal[k]) end
	end
	return pal
end

local function mat(role)
	return LookKit.mat(role)
end

local function shade(col, k)
	-- k < 0 darkens, k > 0 lightens
	if k < 0 then
		return col:Lerp(Color3.new(0, 0, 0), -k)
	end
	return col:Lerp(Color3.new(1, 1, 1), k)
end

local function jitter(col, r, amt)
	local h, s, v = col:ToHSV()
	return Color3.fromHSV((h + r:NextNumber(-amt, amt) * 0.15) % 1, math.clamp(s + r:NextNumber(-amt, amt), 0, 1),
		math.clamp(v + r:NextNumber(-amt, amt), 0, 1))
end

local function mk(m, size, cf, color, material, shape, class)
	local p = Instance.new(class or "Part")
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if shape then
		(p :: any).Shape = shape -- before Size: a later Shape write re-squares the part
	end
	p.Size = size
	p.CFrame = toCF(cf)
	p.Color = color
	p.Material = material or mat("default")
	local big = math.max(size.X, size.Y, size.Z)
	p.CastShadow = big >= 1.6
	if big < 0.6 then
		p.CanCollide = false
	end
	p.Parent = m
	return p
end

local function box(m, size, cf, color, material)
	return mk(m, size, cf, color, material)
end
-- vertical cylinder centred at cf
local function vcyl(m, h, d, cf, color, material)
	return mk(m, V3(h, d, d), toCF(cf) * ANG(0, 0, PI / 2), color, material, Enum.PartType.Cylinder)
end
-- cylinder along cf's X axis
local function hcyl(m, len, d, cf, color, material)
	return mk(m, V3(len, d, d), cf, color, material, Enum.PartType.Cylinder)
end
local function ball(m, d, cf, color, material)
	return mk(m, V3(d, d, d), cf, color, material, Enum.PartType.Ball)
end
-- ellipsoid of any size (block part rendered through a SpecialMesh sphere; collides as its box)
local function blob(m, size, cf, color, material)
	local p = mk(m, size, cf, color, material)
	local sm = Instance.new("SpecialMesh")
	sm.MeshType = Enum.MeshType.Sphere
	sm.Parent = p
	return p
end
local function wedge(m, size, cf, color, material)
	return mk(m, size, cf, color, material, nil, "WedgePart")
end
local function light(parent, color, brightness, range, kind)
	local l = Instance.new(kind or "PointLight")
	l.Color = color
	l.Brightness = brightness or 1.5
	l.Range = range or 14
	l.Shadows = false
	l.Parent = parent
	return l
end
local function decor(m)
	for _, d in ipairs(m:GetDescendants()) do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.CanQuery = false
			d.CastShadow = false
		end
	end
end
local function tag(inst, t, attrs)
	CollectionService:AddTag(inst, t)
	for k, v in pairs(attrs or {}) do
		inst:SetAttribute(k, v)
	end
	return inst
end
WK2._helpers = { box = box, vcyl = vcyl, hcyl = hcyl, ball = ball, blob = blob, wedge = wedge, light = light }

-- ---------------------------------------------------------------------------------------------------- props
-- Each builder makes the prop around the origin (ground at y=0, front facing -Z) and returns its main part.

local PROPS = {}

local function canopy(m, r, pal, h, size, leafA, leafB, material)
	local main = blob(m, V3(size, size * 0.82, size), V3(0, h, 0), leafA, material)
	local n = 4
	for i = 1, n do
		local a = i / n * PI * 2 + r:NextNumber(-0.4, 0.4)
		local d = size * r:NextNumber(0.28, 0.4)
		local s = size * r:NextNumber(0.5, 0.68)
		blob(m, V3(s, s * 0.8, s), V3(math.cos(a) * d, h + r:NextNumber(-0.15, 0.2) * size, math.sin(a) * d),
			i % 2 == 0 and leafB or leafA, material)
	end
	-- lit top highlight: reads as toon shading from any camera
	blob(m, V3(size * 0.6, size * 0.4, size * 0.6), V3(size * 0.08, h + size * 0.3, -size * 0.05),
		shade(leafB, 0.12), material)
	return main
end

PROPS.tree = function(m, o, r, pal)
	local style = o.style or "round"
	local h = o.height or r:NextNumber(12, 18)
	local wood, woodDark = c3(o.trunk, pal.wood), pal.woodDark
	local leafA = c3(o.color, style == "blossom" and pal.blossom or pal.leaf)
	local leafB = style == "blossom" and shade(leafA, 0.25) or pal.leafAlt
	local leafMat = mat("leaf")
	if style == "pine" then
		local trunk = vcyl(m, h * 0.3, h * 0.09, V3(0, h * 0.15, 0), woodDark, mat("wood"))
		local tiers = 4
		for i = 0, tiers - 1 do
			local t = i / tiers
			local d = h * (0.62 - t * 0.42)
			local y = h * (0.26 + t * 0.19)
			local col = leafA:Lerp(leafB, t * 0.6)
			vcyl(m, h * 0.13, d, V3(0, y, 0), col, leafMat)
			vcyl(m, h * 0.06, d * 0.78, V3(0, y + h * 0.09, 0), shade(col, -0.08), leafMat)
			if o.snow then
				vcyl(m, h * 0.03, d * 0.86, V3(0, y + h * 0.075, 0), pal.snow or Color3.new(1, 1, 1), mat("default"))
			end
		end
		ball(m, h * 0.12, V3(0, h * 0.98, 0), o.snow and (pal.snow or Color3.new(1, 1, 1)) or leafB, leafMat)
		return trunk
	elseif style == "palm" then
		local seg, lean = 6, r:NextNumber(0.08, 0.16)
		local pos, last = V3(0, 0, 0), nil
		for i = 1, seg do
			local up = CFrame.fromAxisAngle(V3(1, 0, 0), lean * i * 0.6)
			local step = up:VectorToWorldSpace(V3(0, h / seg, 0))
			local mid = pos + step / 2
			local p = vcyl(m, h / seg + 0.3, h * (0.085 - i * 0.006), CF(mid) * up,
				i % 2 == 0 and wood or shade(wood, -0.1), mat("wood"))
			last = last or p
			pos += step
		end
		for i = 1, 7 do
			local a = i / 7 * PI * 2 + r:NextNumber(-0.2, 0.2)
			local dir = V3(math.cos(a), 0, math.sin(a))
			local len = h * r:NextNumber(0.42, 0.55)
			local f1 = CFrame.lookAt(pos, pos + dir + V3(0, 0.35, 0))
			box(m, V3(h * 0.12, 0.35, len * 0.55), f1 * CF(0, 0, -len * 0.27), i % 2 == 0 and leafA or leafB, leafMat)
			local tip = f1 * CF(0, 0, -len * 0.55)
			local f2 = CFrame.lookAt(tip.Position, tip.Position + dir - V3(0, 0.9, 0))
			box(m, V3(h * 0.1, 0.3, len * 0.5), f2 * CF(0, 0, -len * 0.22), shade(leafA, -0.06), leafMat)
		end
		for i = 1, 3 do
			local a = i / 3 * PI * 2
			ball(m, h * 0.06, pos + V3(math.cos(a) * 0.7, -0.6, math.sin(a) * 0.7), pal.woodDark, mat("default"))
		end
		return last
	elseif style == "dead" then
		local trunk = vcyl(m, h * 0.75, h * 0.1, V3(0, h * 0.375, 0), shade(woodDark, -0.1), mat("wood"))
		for i = 1, 4 do
			local a = i / 4 * PI * 2 + r:NextNumber(-0.5, 0.5)
			local y = h * r:NextNumber(0.4, 0.72)
			local len = h * r:NextNumber(0.25, 0.4)
			local dir = V3(math.cos(a), r:NextNumber(0.5, 1.1), math.sin(a)).Unit
			local base = V3(0, y, 0)
			local cfb = CFrame.lookAt(base + dir * len / 2, base + dir * len)
			box(m, V3(h * 0.05, h * 0.05, len), cfb, shade(woodDark, -0.1), mat("wood"))
		end
		return trunk
	end
	-- round / blossom
	local trunk = vcyl(m, h * 0.6, h * 0.12, V3(0, h * 0.3, 0), wood, mat("wood"))
	vcyl(m, h * 0.1, h * 0.19, V3(0, h * 0.05, 0), shade(wood, -0.12), mat("wood"))
	canopy(m, r, pal, h * 0.72, h * 0.62, leafA, leafB, style == "blossom" and mat("default") or leafMat)
	if style == "blossom" then
		for _ = 1, 5 do
			local a = r:NextNumber(0, PI * 2)
			ball(m, 0.5, V3(math.cos(a) * h * 0.25, 0.25, math.sin(a) * h * 0.25), leafA, mat("default"))
		end
	end
	return trunk
end
for _, s in ipairs({ "round", "pine", "palm", "blossom", "dead" }) do
	PROPS[s == "dead" and "dead_tree" or (s == "round" and "round_tree" or s)] = function(m, o, r, pal)
		o.style = s
		return PROPS.tree(m, o, r, pal)
	end
end

PROPS.bush = function(m, o, r, pal)
	local s = o.size or r:NextNumber(3.5, 6)
	local a, b = c3(o.color, pal.leaf), pal.leafAlt
	local main = blob(m, V3(s, s * 0.7, s), V3(0, s * 0.3, 0), a, mat("leaf"))
	for i = 1, 3 do
		local ang = i / 3 * PI * 2 + r:NextNumber(-0.4, 0.4)
		local ss = s * r:NextNumber(0.55, 0.75)
		blob(m, V3(ss, ss * 0.75, ss), V3(math.cos(ang) * s * 0.35, ss * 0.32, math.sin(ang) * s * 0.35),
			i == 2 and b or a, mat("leaf"))
	end
	if o.berries or r:NextNumber() < 0.3 then
		for _ = 1, 4 do
			local ang = r:NextNumber(0, PI * 2)
			ball(m, 0.45, V3(math.cos(ang) * s * 0.45, s * r:NextNumber(0.3, 0.6), math.sin(ang) * s * 0.45),
				pal.flower, mat("default"))
		end
	end
	return main
end

PROPS.rock = function(m, o, r, pal)
	local s = o.size or r:NextNumber(3, 7)
	local col = c3(o.color, pal.rock)
	local main = box(m, V3(s * 1.2, s * 0.8, s), CF(0, s * 0.25, 0) * ANG(r:NextNumber(-0.3, 0.3),
		r:NextNumber(0, PI), r:NextNumber(-0.3, 0.3)), col, mat("stone"))
	box(m, V3(s * 0.7, s * 0.6, s * 0.65), CF(s * 0.5, s * 0.15, s * 0.2) * ANG(r:NextNumber(-0.5, 0.5),
		r:NextNumber(0, PI), r:NextNumber(-0.5, 0.5)), shade(col, -0.1), mat("stone"))
	if r:NextNumber() < 0.6 then
		box(m, V3(s * 0.45, s * 0.35, s * 0.4), CF(-s * 0.55, s * 0.08, -s * 0.3) * ANG(r:NextNumber(-0.5, 0.5),
			r:NextNumber(0, PI), 0), shade(col, 0.08), mat("stone"))
	end
	if o.moss then
		blob(m, V3(s * 0.9, s * 0.25, s * 0.8), V3(0, s * 0.62, 0), pal.leaf, mat("leaf"))
	end
	return main
end

PROPS.flowers = function(m, o, r, pal)
	local cols = { pal.flower, pal.blossom, pal.accent, pal.trim }
	local main
	for i = 1, o.count or 6 do
		local a, d = r:NextNumber(0, PI * 2), r:NextNumber(0, 1.6)
		local h = r:NextNumber(0.9, 1.6)
		local x, z = math.cos(a) * d, math.sin(a) * d
		local stem = box(m, V3(0.15, h, 0.15), V3(x, h / 2, z), pal.leaf, mat("default"))
		main = main or stem
		ball(m, 0.55, V3(x, h + 0.1, z), c3(o.color, cols[r:NextInteger(1, #cols)]), mat("default"))
		ball(m, 0.25, V3(x, h + 0.3, z), pal.gold, mat("default"))
	end
	decor(m)
	return main
end

PROPS.grass = function(m, o, r, pal)
	local main
	for i = 1, o.count or 7 do
		local a = r:NextNumber(0, PI * 2)
		local h = r:NextNumber(1, 2.2)
		local x, z = math.cos(a) * r:NextNumber(0, 0.9), math.sin(a) * r:NextNumber(0, 0.9)
		local bl = box(m, V3(0.25, h, 0.12), CF(x, h / 2 - 0.1, z) * ANG(r:NextNumber(-0.35, 0.35), a, r:NextNumber(-0.35, 0.35)),
			i % 2 == 0 and pal.leaf or pal.leafAlt, mat("default"))
		main = main or bl
	end
	decor(m)
	return main
end

PROPS.mushroom = function(m, o, r, pal)
	local h = o.height or r:NextNumber(2, 4)
	local stem = vcyl(m, h, h * 0.3, V3(0, h / 2, 0), pal.trim:Lerp(pal.sand, 0.3), mat("default"))
	local capCol = c3(o.color, pal.primary)
	blob(m, V3(h * 1.1, h * 0.55, h * 1.1), V3(0, h, 0), capCol, mat("default"))
	for i = 1, 5 do
		local a = i / 5 * PI * 2 + r:NextNumber(-0.3, 0.3)
		ball(m, h * 0.16, V3(math.cos(a) * h * 0.32, h + h * 0.17, math.sin(a) * h * 0.32), pal.trim, mat("default"))
	end
	return stem
end

PROPS.cactus = function(m, o, r, pal)
	local h = o.height or r:NextNumber(6, 10)
	local col = c3(o.color, pal.leaf)
	local d = h * 0.18
	local main = vcyl(m, h, d, V3(0, h / 2, 0), col, mat("leaf"))
	ball(m, d, V3(0, h, 0), shade(col, 0.08), mat("leaf"))
	for _, side in ipairs({ -1, 1 }) do
		if side == 1 or r:NextNumber() < 0.7 then
			local y = h * r:NextNumber(0.35, 0.55)
			local ad = d * 0.75
			hcyl(m, d * 1.3, ad, CF(side * d * 0.9, y, 0), col, mat("leaf"))
			local uh = h * r:NextNumber(0.25, 0.35)
			vcyl(m, uh, ad, V3(side * d * 1.5, y + uh / 2, 0), col, mat("leaf"))
			ball(m, ad, V3(side * d * 1.5, y + uh, 0), shade(col, 0.08), mat("leaf"))
		end
	end
	if r:NextNumber() < 0.5 then
		ball(m, d * 0.5, V3(0, h + d * 0.45, 0), pal.blossom, mat("default"))
	end
	return main
end

PROPS.crystal = function(m, o, r, pal)
	local h = o.height or r:NextNumber(4, 8)
	local col = c3(o.color, pal.glow)
	local main
	for i = 1, o.count or 4 do
		local hh = h * (i == 1 and 1 or r:NextNumber(0.4, 0.7))
		local w = hh * 0.28
		local a = i == 1 and 0 or r:NextNumber(0, PI * 2)
		local tilt = i == 1 and 0 or r:NextNumber(0.3, 0.6)
		local cfc = CF(math.cos(a) * w * 0.6, 0, math.sin(a) * w * 0.6) * ANG(0, a, 0) * ANG(tilt, 0, 0)
			* CF(0, hh / 2, 0) * ANG(0, PI / 4, 0)
		local p = box(m, V3(w, hh, w), cfc, i == 1 and col or shade(col, -0.15), M.Neon)
		p.Transparency = 0.15
		main = main or p
	end
	light(main, col, 1.6, h * 2.5)
	return main
end

PROPS.lollipop = function(m, o, r, pal)
	local h = o.height or r:NextNumber(8, 14)
	local stick = vcyl(m, h, h * 0.06, V3(0, h / 2, 0), pal.trim, mat("default"))
	local cols = pal.candy or { pal.primary, pal.secondary, pal.accent }
	local a, b = c3(o.color, cols[r:NextInteger(1, #cols)]), pal.trim
	local d = h * 0.55
	local face = CF(0, h + d * 0.35, 0) * ANG(0, r:NextNumber(0, PI), 0)
	for i = 0, 4 do
		hcyl(m, h * 0.08 + i * 0.12, d * (1 - i * 0.19), face, i % 2 == 0 and a or b, mat("default"))
	end
	return stick
end

PROPS.candy_cane = function(m, o, r, pal)
	local h = o.height or r:NextNumber(9, 14)
	local d = h * 0.11
	local a, b = c3(o.color, pal.primary), pal.trim
	local n = 8
	local main
	for i = 0, n - 1 do
		local p = vcyl(m, h / n, d, V3(0, (i + 0.5) * h / n, 0), i % 2 == 0 and a or b, mat("default"))
		main = main or p
	end
	local rr = h * 0.16
	for i = 0, 5 do
		local t = i / 5 * PI
		local pos = V3(rr - math.cos(t) * rr, h + math.sin(t) * rr, 0)
		ball(m, d, pos, i % 2 == 0 and b or a, mat("default"))
	end
	return main
end

PROPS.gumdrop = function(m, o, r, pal)
	local s = o.size or r:NextNumber(3, 6)
	local cols = pal.candy or { pal.primary, pal.secondary, pal.accent }
	local col = c3(o.color, cols[r:NextInteger(1, #cols)])
	local base = vcyl(m, s * 0.4, s, V3(0, s * 0.2, 0), col, mat("default"))
	blob(m, V3(s, s * 0.9, s), V3(0, s * 0.42, 0), col, mat("default"))
	for _ = 1, 6 do
		local a, y = r:NextNumber(0, PI * 2), r:NextNumber(0.3, 0.8)
		ball(m, s * 0.08, V3(math.cos(a) * s * 0.45 * (1.1 - y * 0.5), s * y, math.sin(a) * s * 0.45 * (1.1 - y * 0.5)),
			pal.trim, mat("default"))
	end
	return base
end

PROPS.asteroid = function(m, o, r, pal)
	local s = o.size or r:NextNumber(6, 16)
	local col = c3(o.color, pal.rock)
	local main = box(m, V3(s, s * 0.85, s * 0.9), CF(0, 0, 0) * ANG(r:NextNumber(0, PI), r:NextNumber(0, PI), 0), col,
		mat("stone"))
	for _ = 1, 3 do
		local off = V3(r:NextNumber(-1, 1), r:NextNumber(-1, 1), r:NextNumber(-1, 1)).Unit * s * 0.4
		box(m, V3(s, s, s) * r:NextNumber(0.45, 0.65), CF(off) * ANG(r:NextNumber(0, PI), r:NextNumber(0, PI), 0),
			shade(col, r:NextNumber(-0.15, 0.08)), mat("stone"))
	end
	if r:NextNumber() < 0.4 then
		local cr = box(m, V3(s * 0.15, s * 0.5, s * 0.15), CF(0, s * 0.5, 0) * ANG(0.3, 0, 0.2), pal.glow, M.Neon)
		light(cr, pal.glow, 1.2, s)
	end
	return main
end

PROPS.reeds = function(m, o, r, pal)
	local main
	for i = 1, o.count or 6 do
		local h = r:NextNumber(3, 6)
		local x, z = r:NextNumber(-1.2, 1.2), r:NextNumber(-1.2, 1.2)
		local st = box(m, V3(0.2, h, 0.2), CF(x, h / 2, z) * ANG(r:NextNumber(-0.15, 0.15), 0, r:NextNumber(-0.15, 0.15)),
			pal.leafAlt, mat("default"))
		main = main or st
		if i % 2 == 0 then
			vcyl(m, 0.9, 0.4, V3(x, h, z), pal.woodDark, mat("default"))
		end
	end
	decor(m)
	return main
end

PROPS.lily_pad = function(m, o, r, pal)
	local d = o.size or r:NextNumber(2.5, 4)
	local pad = vcyl(m, 0.15, d, V3(0, 0.1, 0), pal.leaf, mat("default"))
	if r:NextNumber() < 0.4 then
		ball(m, 0.6, V3(d * 0.15, 0.4, 0), pal.blossom, mat("default"))
	end
	decor(m)
	return pad
end

PROPS.log = function(m, o, r, pal)
	local len = o.length or r:NextNumber(6, 10)
	local d = len * 0.18
	local main = hcyl(m, len, d, CF(0, d / 2, 0) * ANG(0, r:NextNumber(0, PI), 0), pal.wood, mat("wood"))
	hcyl(m, 0.1, d * 0.8, main.CFrame * CF(len / 2, 0, 0), pal.sand, mat("default"))
	hcyl(m, 0.1, d * 0.8, main.CFrame * CF(-len / 2, 0, 0), pal.sand, mat("default"))
	return main
end

PROPS.snowman = function(m, o, r, pal)
	local s = o.size or 3
	local white = pal.snow or Color3.new(1, 1, 1)
	local base = ball(m, s * 1.4, V3(0, s * 0.65, 0), white, mat("default"))
	ball(m, s * 1.05, V3(0, s * 1.75, 0), white, mat("default"))
	ball(m, s * 0.75, V3(0, s * 2.55, 0), white, mat("default"))
	local nose = box(m, V3(0.25, 0.25, s * 0.45), V3(0, s * 2.55, -s * 0.5), pal.accent, mat("default"))
	nose.CanCollide = false
	for _, x in ipairs({ -0.15, 0.15 }) do
		ball(m, 0.25, V3(x * s, s * 2.7, -s * 0.33), pal.ink, mat("default"))
	end
	box(m, V3(s * 1.1, s * 0.22, s * 0.9), V3(0, s * 2.18, 0), pal.primary, mat("fabric"))
	return base
end

-- ---- structures

PROPS.fence = function(m, o, r, pal)
	local len = o.length or 12
	local col = c3(o.color, o.style == "picket" and pal.trim or pal.wood)
	local n = math.max(1, math.floor(len / 4 + 0.5))
	local main = box(m, V3(len, 0.4, 0.3), V3(0, 2.4, 0), col, mat("wood"))
	box(m, V3(len, 0.4, 0.3), V3(0, 1.2, 0), col, mat("wood"))
	for i = 0, n do
		local x = -len / 2 + i * len / n
		box(m, V3(0.6, 3.2, 0.6), V3(x, 1.6, 0), shade(col, -0.08), mat("wood"))
		box(m, V3(0.8, 0.25, 0.8), V3(x, 3.3, 0), shade(col, 0.1), mat("wood"))
	end
	return main
end

PROPS.lamp = function(m, o, r, pal)
	local h = o.height or 11
	local col = c3(o.color, pal.glow)
	local post = c3(o.post, pal.ink:Lerp(pal.metal, 0.3))
	local base = vcyl(m, 0.8, 1.6, V3(0, 0.4, 0), post, mat("metal"))
	vcyl(m, h, 0.5, V3(0, h / 2, 0), post, mat("metal"))
	if o.style == "street" then
		box(m, V3(0.4, 0.4, 3), V3(0, h, -1.3), post, mat("metal"))
		local head = box(m, V3(1.4, 0.5, 2), V3(0, h - 0.2, -2.6), post, mat("metal"))
		local bulb = box(m, V3(1, 0.2, 1.6), V3(0, h - 0.5, -2.6), col, M.Neon)
		light(bulb, col, 2, 24, "SpotLight").Face = Enum.NormalId.Bottom
		local _ = head
	else
		box(m, V3(1.6, 0.3, 1.6), V3(0, h + 0.15, 0), post, mat("metal"))
		local glow = box(m, V3(1.2, 1.6, 1.2), V3(0, h + 1.1, 0), col, M.Neon)
		glow.CastShadow = false
		box(m, V3(1.8, 0.4, 1.8), V3(0, h + 2.1, 0), post, mat("metal"))
		ball(m, 0.5, V3(0, h + 2.5, 0), post, mat("metal"))
		light(glow, col, 1.8, 20)
	end
	return base
end
PROPS.streetlight = function(m, o, r, pal)
	o.style = "street"
	return PROPS.lamp(m, o, r, pal)
end

PROPS.torch = function(m, o, r, pal)
	local h = o.height or 5
	local stick = vcyl(m, h, 0.4, V3(0, h / 2, 0), pal.woodDark, mat("wood"))
	vcyl(m, 0.5, 0.8, V3(0, h, 0), pal.metal, mat("metal"))
	local flame = ball(m, 0.9, V3(0, h + 0.5, 0), c3(o.color, Color3.fromRGB(255, 150, 60)), M.Neon)
	flame.CanCollide = false
	local f = Instance.new("Fire")
	f.Size = 2
	f.Heat = 4
	f.Color = Color3.fromRGB(255, 140, 50)
	f.SecondaryColor = Color3.fromRGB(255, 60, 20)
	f.Parent = flame
	light(flame, Color3.fromRGB(255, 160, 80), 2, 18)
	return stick
end

PROPS.crate = function(m, o, r, pal)
	local s = o.size or 4
	local col = c3(o.color, pal.wood)
	local main = box(m, V3(s, s, s), V3(0, s / 2, 0), col, mat("wood"))
	local trim = shade(col, -0.22)
	local e = s * 0.12
	for _, x in ipairs({ -1, 1 }) do
		for _, z in ipairs({ -1, 1 }) do
			box(m, V3(e, s + 0.02, e), V3(x * (s / 2 - e / 2 + 0.02), s / 2, z * (s / 2 - e / 2 + 0.02)), trim, mat("wood"))
		end
	end
	box(m, V3(s + 0.06, e, s + 0.06), V3(0, s - e / 2, 0), trim, mat("wood"))
	box(m, V3(s + 0.06, e, s + 0.06), V3(0, e / 2, 0), trim, mat("wood"))
	box(m, V3(e * 0.8, s * 1.25, 0.15), CF(0, s / 2, -s / 2 - 0.05) * ANG(0, 0, PI / 4), trim, mat("wood"))
	return main
end

PROPS.barrel = function(m, o, r, pal)
	local h = o.height or 4.4
	local col = c3(o.color, pal.wood)
	local main = vcyl(m, h, h * 0.7, V3(0, h / 2, 0), col, mat("wood"))
	vcyl(m, h * 0.7, h * 0.76, V3(0, h / 2, 0), shade(col, 0.06), mat("wood"))
	for _, y in ipairs({ 0.15, 0.85 }) do
		vcyl(m, 0.3, h * 0.74, V3(0, h * y, 0), pal.metal:Lerp(pal.ink, 0.4), mat("metal"))
	end
	vcyl(m, 0.12, h * 0.62, V3(0, h + 0.03, 0), shade(col, -0.15), mat("wood"))
	return main
end

PROPS.bench = function(m, o, r, pal)
	local w = o.length or 7
	local col = c3(o.color, pal.wood)
	local frame = pal.ink:Lerp(pal.metal, 0.4)
	local seat = box(m, V3(w, 0.35, 2), V3(0, 2, 0), col, mat("wood"))
	box(m, V3(w, 0.35, 0.9), CF(0, 3.3, 1.05) * ANG(rad(-12), 0, 0), col, mat("wood"))
	box(m, V3(w, 0.35, 0.9), CF(0, 4.1, 1.2) * ANG(rad(-12), 0, 0), col, mat("wood"))
	for _, x in ipairs({ -w / 2 + 0.6, w / 2 - 0.6 }) do
		box(m, V3(0.4, 2, 2), V3(x, 1, 0), frame, mat("metal"))
		box(m, V3(0.4, 2.6, 0.4), CF(x, 3.1, 1.15) * ANG(rad(-12), 0, 0), frame, mat("metal"))
	end
	return seat
end

PROPS.sign = function(m, o, r, pal)
	local w, h = o.width or 6, o.height or 6
	local col = c3(o.color, pal.wood)
	local post = vcyl(m, h, 0.5, V3(0, h / 2, 0), shade(col, -0.2), mat("wood"))
	local board = box(m, V3(w, w * 0.45, 0.4), V3(0, h - w * 0.15, -0.3), col, mat("wood"))
	box(m, V3(w + 0.3, 0.25, 0.5), V3(0, h - w * 0.15 + w * 0.235, -0.3), shade(col, -0.2), mat("wood"))
	if o.text then
		local gui = Instance.new("SurfaceGui")
		gui.Face = Enum.NormalId.Front
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = 40
		gui.Parent = board
		local t = Instance.new("TextLabel")
		t.BackgroundTransparency = 1
		t.Size = UDim2.fromScale(1, 1)
		t.Text = o.text
		t.TextScaled = true
		t.Font = Enum.Font.FredokaOne
		t.TextColor3 = pal.trim
		t.Parent = gui
	end
	return post
end

PROPS.flag = function(m, o, r, pal)
	local h = o.height or 12
	local pole = vcyl(m, h, 0.4, V3(0, h / 2, 0), pal.trim, mat("metal"))
	ball(m, 0.8, V3(0, h + 0.3, 0), pal.gold, mat("metal"))
	local col = c3(o.color, pal.primary)
	local cloth = box(m, V3(4.5, 2.8, 0.15), V3(2.4, h - 1.6, 0), col, mat("fabric"))
	box(m, V3(4.5, 0.5, 0.18), V3(2.4, h - 1.6, 0), pal.trim, mat("fabric"))
	cloth.CanCollide = false
	vcyl(m, 0.5, 1.6, V3(0, 0.25, 0), pal.ink:Lerp(pal.metal, 0.4), mat("metal"))
	return pole
end

local function gableRoof(m, w, d, y, rh, col, overhang)
	overhang = overhang or 1
	local half = d / 2 + overhang
	-- two wedges back to back: each slope faces outward, tall faces meet at the ridge
	wedge(m, V3(w + overhang * 2, rh, half), CF(0, y + rh / 2, -half / 2), col, mat("roof"))
	wedge(m, V3(w + overhang * 2, rh, half), CF(0, y + rh / 2, half / 2) * ANG(0, PI, 0), col, mat("roof"))
	box(m, V3(w + overhang * 2 + 0.2, 0.5, 0.7), V3(0, y + rh + 0.1, 0), shade(col, -0.2), mat("roof"))
end

local function window(m, cf, w, h, pal, lit)
	box(m, V3(w + 0.5, h + 0.5, 0.25), cf * CF(0, 0, -0.1), pal.trim, mat("default"))
	local g = box(m, V3(w, h, 0.3), cf * CF(0, 0, -0.15), lit and pal.glow or pal.sky:Lerp(pal.ink, 0.35),
		lit and M.Neon or M.Glass)
	g.CastShadow = false
	box(m, V3(0.2, h, 0.35), cf * CF(0, 0, -0.2), pal.trim, mat("default"))
	box(m, V3(w, 0.2, 0.35), cf * CF(0, 0, -0.2), pal.trim, mat("default"))
	box(m, V3(w + 0.9, 0.3, 0.7), cf * CF(0, -h / 2 - 0.25, -0.3), pal.trim, mat("default"))
	return g
end

PROPS.house = function(m, o, r, pal)
	local w, d = o.width or r:NextNumber(14, 20), o.depth or r:NextNumber(12, 16)
	local floors = o.floors or 1
	local fh = 9
	local h = fh * floors
	local wallCol = c3(o.color, jitter(pal.wall, r, 0.05))
	local main = box(m, V3(w, h, d), V3(0, h / 2, 0), wallCol, mat("wall"))
	box(m, V3(w + 0.4, 1, d + 0.4), V3(0, 0.5, 0), shade(wallCol, -0.25), mat("stone"))
	gableRoof(m, w, d, h, math.min(w, d) * 0.45, c3(o.roof, pal.roof), 1.2)
	-- door + step
	box(m, V3(3.6, 6.4, 0.4), V3(0, 3.6, -d / 2 - 0.1), pal.woodDark, mat("wood"))
	box(m, V3(4.4, 0.4, 0.5), V3(0, 6.9, -d / 2 - 0.15), pal.trim, mat("default"))
	ball(m, 0.4, V3(1.2, 3.4, -d / 2 - 0.35), pal.gold, mat("metal"))
	box(m, V3(5, 0.5, 2), V3(0, 0.25, -d / 2 - 1), pal.path, mat("stone"))
	for f = 0, floors - 1 do
		for _, x in ipairs({ -w * 0.3, w * 0.3 }) do
			window(m, CF(x, fh * f + 5, -d / 2), 3, 3, pal, o.lit)
		end
		if f > 0 then
			window(m, CF(0, fh * f + 5, -d / 2), 3, 3, pal, o.lit)
		end
		for _, z in ipairs({ -d * 0.2, d * 0.2 }) do
			window(m, CF(w / 2, fh * f + 5, z) * ANG(0, -PI / 2, 0), 2.6, 3, pal, o.lit)
			window(m, CF(-w / 2, fh * f + 5, z) * ANG(0, PI / 2, 0), 2.6, 3, pal, o.lit)
		end
	end
	if o.chimney ~= false then
		box(m, V3(2.2, h * 0.6 + 4, 2.2), V3(w * 0.28, h + 2, d * 0.15), pal.rock:Lerp(pal.roof, 0.3), mat("stone"))
	end
	return main
end

PROPS.shop = function(m, o, r, pal)
	local w, d, h = o.width or 18, o.depth or 14, o.height or 11
	local wallCol = c3(o.color, jitter(pal.wall, r, 0.06))
	local main = box(m, V3(w, h, d), V3(0, h / 2, 0), wallCol, mat("wall"))
	box(m, V3(w + 1, 1.2, d + 1), V3(0, h + 0.6, 0), pal.trim, mat("default"))
	box(m, V3(w + 1.2, 2.5, 0.6), V3(0, h + 1.8, -d / 2 - 0.1), wallCol, mat("wall")) -- false front
	window(m, CF(-w * 0.22, 4.2, -d / 2), w * 0.36, 4.4, pal, o.lit)
	box(m, V3(3.8, 6.6, 0.4), V3(w * 0.27, 3.5, -d / 2 - 0.1), pal.woodDark, mat("wood"))
	-- striped awning
	local stripes = math.max(4, math.floor(w / 2.2))
	local sw = (w + 1) / stripes
	for i = 0, stripes - 1 do
		local x = -w / 2 - 0.5 + (i + 0.5) * sw
		box(m, V3(sw, 0.3, 3.4), CF(x, 7.8, -d / 2 - 1.5) * ANG(rad(-25), 0, 0),
			i % 2 == 0 and c3(o.accent, pal.primary) or pal.trim, mat("fabric"))
	end
	local sign = box(m, V3(w * 0.6, 2, 0.5), V3(0, h - 1.4, -d / 2 - 0.3), c3(o.accent, pal.secondary), mat("default"))
	if o.text then
		local gui = Instance.new("SurfaceGui")
		gui.Face = Enum.NormalId.Front
		gui.Parent = sign
		local t = Instance.new("TextLabel")
		t.BackgroundTransparency = 1
		t.Size = UDim2.fromScale(1, 1)
		t.TextScaled = true
		t.Font = Enum.Font.FredokaOne
		t.Text = o.text
		t.TextColor3 = pal.trim
		t.Parent = gui
	end
	return main
end

PROPS.tower = function(m, o, r, pal)
	local style = o.style or "castle"
	local h = o.height or r:NextNumber(24, 36)
	if style == "skyscraper" or style == "neon" then
		local w = o.width or r:NextNumber(14, 22)
		local col = c3(o.color, style == "neon" and pal.wall or jitter(pal.wall, r, 0.05))
		local main = box(m, V3(w, h, w), V3(0, h / 2, 0), col, mat("wall"))
		local neon = pal.neon or { pal.primary, pal.secondary }
		local stripCol = neon[r:NextInteger(1, #neon)]
		local floors = math.floor(h / 6)
		for f = 1, floors - 1 do
			local y = f * 6
			local g = box(m, V3(w + 0.2, 2.4, w + 0.2), V3(0, y - 1.6, 0), style == "neon" and pal.ink:Lerp(stripCol, 0.15)
				or pal.sky:Lerp(pal.ink, 0.4), M.Glass)
			g.CastShadow = false
			if style == "neon" and f % 3 == 0 then
				local s = box(m, V3(w + 0.4, 0.3, w + 0.4), V3(0, y, 0), stripCol, M.Neon)
				s.CastShadow = false
			end
		end
		box(m, V3(w * 0.6, 3, w * 0.6), V3(0, h + 1.5, 0), shade(col, -0.15), mat("metal"))
		if style == "neon" then
			for _, c in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
				local e = box(m, V3(0.4, h, 0.4), V3(c[1] * (w / 2 + 0.1), h / 2, c[2] * (w / 2 + 0.1)), stripCol, M.Neon)
				e.CastShadow = false
			end
			light(main, stripCol, 2, 30)
		end
		return main
	elseif style == "watchtower" then
		local w = 8
		local main
		for _, c in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
			local p = box(m, V3(0.9, h, 0.9), V3(c[1] * w / 2, h / 2, c[2] * w / 2), pal.wood, mat("wood"))
			main = main or p
		end
		box(m, V3(w + 3, 0.8, w + 3), V3(0, h, 0), pal.wood, mat("wood"))
		for _, c in ipairs({ { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } }) do
			box(m, c[1] == 0 and V3(w + 3, 2.5, 0.4) or V3(0.4, 2.5, w + 3), V3(c[1] * (w + 3) / 2, h + 1.6,
				c[2] * (w + 3) / 2), shade(pal.wood, -0.1), mat("wood"))
		end
		gableRoof(m, w + 2, w + 2, h + 6, 4, pal.roof, 0.5)
		for _, c in ipairs({ { -1, -1 }, { 1, 1 } }) do
			box(m, V3(0.5, 6, 0.5), V3(c[1] * (w / 2 + 1), h + 3, c[2] * (w / 2 + 1)), pal.wood, mat("wood"))
		end
		return main
	end
	-- castle: round tower, crenellations, stepped cone roof
	local d = o.width or 12
	local stone = c3(o.color, pal.rock:Lerp(pal.wall, 0.4))
	local main = vcyl(m, h, d, V3(0, h / 2, 0), stone, mat("stone"))
	vcyl(m, 2, d + 1.6, V3(0, 1, 0), shade(stone, -0.15), mat("stone"))
	vcyl(m, 1.4, d + 1.4, V3(0, h, 0), shade(stone, 0.06), mat("stone"))
	for i = 0, 9 do
		local a = i / 10 * PI * 2
		box(m, V3(1.6, 1.8, 1.2), CF(math.cos(a) * (d / 2 + 0.3), h + 1.6, math.sin(a) * (d / 2 + 0.3)) * ANG(0, -a, 0),
			stone, mat("stone"))
	end
	if o.roof ~= false then
		for i = 0, 5 do
			vcyl(m, 1.6, (d + 1) * (1 - i / 6.5), V3(0, h + 2.5 + i * 1.5, 0), i % 2 == 0 and pal.roof or shade(pal.roof, -0.1),
				mat("roof"))
		end
		vcyl(m, 3, 0.3, V3(0, h + 12, 0), pal.metal, mat("metal"))
		box(m, V3(2, 1.2, 0.1), V3(1, h + 13, 0), pal.primary, mat("fabric"))
	end
	for i = 1, math.floor(h / 10) do
		window(m, CF(0, i * 9, -d / 2 - 0.05), 1.4, 2.6, pal, o.lit)
	end
	return main
end
PROPS.skyscraper = function(m, o, r, pal)
	o.style = o.style or "skyscraper"
	return PROPS.tower(m, o, r, pal)
end

PROPS.bridge = function(m, o, r, pal)
	local len, w = o.length or 30, o.width or 8
	local col = c3(o.color, pal.wood)
	local n = math.floor(len / 2)
	local main
	for i = 0, n - 1 do
		local z = -len / 2 + (i + 0.5) * len / n
		local arch = math.sin((i + 0.5) / n * PI) * len * 0.06
		local p = box(m, V3(w, 0.6, len / n - 0.15), V3(0, arch + 0.3, z), i % 2 == 0 and col or shade(col, -0.07),
			mat("wood"))
		main = main or p
		if i % 3 == 0 then
			for _, x in ipairs({ -w / 2, w / 2 }) do
				box(m, V3(0.5, 3, 0.5), V3(x, arch + 1.8, z), shade(col, -0.2), mat("wood"))
			end
		end
	end
	for _, x in ipairs({ -w / 2, w / 2 }) do
		for i = 0, n - 1 do
			local z0 = -len / 2 + i * len / n
			local z1 = z0 + len / n
			local y0 = math.sin(i / n * PI) * len * 0.06 + 3.1
			local y1 = math.sin((i + 1) / n * PI) * len * 0.06 + 3.1
			local a, b = V3(x, y0, z0), V3(x, y1, z1)
			box(m, V3(0.4, 0.4, (b - a).Magnitude + 0.1), CFrame.lookAt((a + b) / 2, b), shade(col, -0.2), mat("wood"))
		end
	end
	return main
end

PROPS.ramp = function(m, o, r, pal)
	local w, h, len = o.width or 10, o.height or 5, o.length or 14
	local col = c3(o.color, pal.accent)
	local main = wedge(m, V3(w, h, len), CF(0, h / 2, 0), col, mat("default"))
	for _, x in ipairs({ -w / 2 - 0.3, w / 2 + 0.3 }) do
		wedge(m, V3(0.6, h + 0.3, len), CF(x, (h + 0.3) / 2, 0), pal.trim, mat("default"))
	end
	tag(main, "KitRamp")
	return main
end

PROPS.coin = function(m, o, r, pal)
	local d = o.size or 2.4
	local coin = hcyl(m, 0.35, d, CF(0, 0, 0) * ANG(0, PI / 2, 0), c3(o.color, pal.gold), M.SmoothPlastic)
	hcyl(m, 0.45, d * 0.62, CF(0, 0, 0) * ANG(0, PI / 2, 0), shade(c3(o.color, pal.gold), 0.25), M.SmoothPlastic)
	decor(m)
	coin.CanQuery = true
	coin.CanTouch = true
	tag(coin, "KitCoin", { Value = o.value or 1 })
	return coin
end

PROPS.gem = function(m, o, r, pal)
	local s = o.size or 2
	local col = c3(o.color, pal.secondary)
	local g = box(m, V3(s, s, s), CF(0, 0, 0) * ANG(PI / 4, 0, PI / 4), col, M.Neon)
	g.Transparency = 0.1
	box(m, V3(s * 0.55, s * 0.55, s * 0.55), CF(0, 0, 0) * ANG(PI / 4, PI / 4, 0), shade(col, 0.35), M.Neon)
	light(g, col, 1.2, 8)
	decor(m)
	g.CanTouch = true
	g.CanQuery = true
	tag(g, "KitGem", { Value = o.value or 5 })
	return g
end

PROPS.chest = function(m, o, r, pal)
	local w = o.size or 4
	local col = c3(o.color, pal.wood)
	local main = box(m, V3(w, w * 0.55, w * 0.62), V3(0, w * 0.275, 0), col, mat("wood"))
	hcyl(m, w, w * 0.62, CF(0, w * 0.55, 0), shade(col, 0.05), mat("wood"))
	for _, x in ipairs({ -w * 0.35, w * 0.35 }) do
		box(m, V3(w * 0.1, w * 0.58, w * 0.66), V3(x, w * 0.29, 0), pal.gold, mat("metal"))
		hcyl(m, w * 0.1, w * 0.66, CF(x, w * 0.55, 0), pal.gold, mat("metal"))
	end
	box(m, V3(w * 0.18, w * 0.22, 0.2), V3(0, w * 0.5, -w * 0.32), pal.gold, mat("metal"))
	return main
end

-- ---- kitchen / interior (character is ~5 studs tall; counters 3.4)

local function station(main, kind)
	tag(main, "KitStation", { Station = kind })
	return main
end

local function cabinet(m, w, pal, col, top)
	local body = box(m, V3(w, 3.2, 3), V3(0, 1.6, 0), col, mat("wood"))
	box(m, V3(w + 0.3, 0.35, 3.3), V3(0, 3.38, -0.1), top, mat("stone"))
	box(m, V3(w - 0.2, 0.3, 0.1), V3(0, 0.15, -1.52), shade(col, -0.3), mat("default"))
	local doors = math.max(1, math.floor(w / 2))
	for i = 0, doors - 1 do
		local x = -w / 2 + (i + 0.5) * w / doors
		box(m, V3(w / doors - 0.3, 2.4, 0.1), V3(x, 1.75, -1.53), shade(col, 0.06), mat("wood"))
		box(m, V3(0.15, 0.6, 0.2), V3(x + (w / doors) * 0.3, 2.2, -1.62), pal.metal, mat("metal"))
	end
	return body
end

PROPS.counter = function(m, o, r, pal)
	local w = o.width or 4
	return station(cabinet(m, w, pal, c3(o.color, pal.secondary), pal.trim:Lerp(pal.rock, 0.25)), "counter")
end

PROPS.stove = function(m, o, r, pal)
	local w = o.width or 4
	local body = box(m, V3(w, 3.3, 3), V3(0, 1.65, 0), c3(o.color, pal.metal), mat("metal"))
	box(m, V3(w + 0.1, 0.25, 3.1), V3(0, 3.42, 0), pal.ink:Lerp(pal.metal, 0.2), mat("metal"))
	for _, x in ipairs({ -w * 0.24, w * 0.24 }) do
		for _, z in ipairs({ -0.6, 0.6 }) do
			vcyl(m, 0.15, 1.3, V3(x, 3.6, z), pal.ink, mat("metal"))
			local hot = vcyl(m, 0.17, 0.6, V3(x, 3.61, z), o.on == false and pal.ink or Color3.fromRGB(255, 90, 40), M.Neon)
			hot.CastShadow = false
		end
	end
	local glass = box(m, V3(w * 0.7, 1.4, 0.12), V3(0, 1.6, -1.52), pal.ink:Lerp(pal.glow, 0.25), M.Glass)
	glass.CastShadow = false
	box(m, V3(w * 0.6, 0.2, 0.3), V3(0, 2.55, -1.65), pal.metal, mat("metal"))
	for i = 0, 3 do
		vcyl(m, 0.15, 0.35, CF(-w * 0.36 + i * w * 0.24, 3.05, -1.6) * ANG(PI / 2, 0, 0), pal.ink, mat("metal"))
	end
	box(m, V3(w, 1.6, 0.3), V3(0, 4.2, 1.4), pal.metal, mat("metal"))
	return station(body, "stove")
end

PROPS.sink = function(m, o, r, pal)
	local w = o.width or 4
	local body = cabinet(m, w, pal, c3(o.color, pal.secondary), pal.trim:Lerp(pal.rock, 0.25))
	local basin = box(m, V3(w * 0.6, 0.12, 1.8), V3(0, 3.6, -0.1), pal.metal:Lerp(pal.ink, 0.2), mat("metal"))
	basin.CastShadow = false
	box(m, V3(w * 0.66, 0.35, 0.15), V3(0, 3.7, -1.05), pal.metal, mat("metal"))
	box(m, V3(w * 0.66, 0.35, 0.15), V3(0, 3.7, 0.85), pal.metal, mat("metal"))
	vcyl(m, 1.4, 0.3, V3(0, 4.3, 1.1), pal.metal, mat("metal"))
	box(m, V3(0.25, 0.25, 1), V3(0, 5, 0.65), pal.metal, mat("metal"))
	local water = box(m, V3(w * 0.55, 0.05, 1.6), V3(0, 3.68, -0.1), pal.water, M.Glass)
	water.Transparency = 0.4
	return station(body, "sink")
end

PROPS.fridge = function(m, o, r, pal)
	local col = c3(o.color, pal.trim:Lerp(pal.secondary, 0.25))
	local body = box(m, V3(3.6, 8, 3.2), V3(0, 4, 0), col, mat("default"))
	box(m, V3(3.5, 0.12, 0.1), V3(0, 5.2, -1.62), shade(col, -0.3), mat("default"))
	box(m, V3(0.25, 1.6, 0.35), V3(1.4, 6.4, -1.75), pal.metal, mat("metal"))
	box(m, V3(0.25, 2.4, 0.35), V3(1.4, 3.6, -1.75), pal.metal, mat("metal"))
	for i = 1, 3 do
		vcyl(m, 0.1, 0.45, CF(-0.8 + i * 0.4, 6.8 - i * 0.3, -1.62) * ANG(PI / 2, 0, 0),
			({ pal.primary, pal.accent, pal.secondary })[i], mat("default"))
	end
	return station(body, "fridge")
end

PROPS.table = function(m, o, r, pal)
	local w, d = o.width or 6, o.depth or 4
	local col = c3(o.color, pal.wood)
	local top
	if o.round then
		top = vcyl(m, 0.4, w, V3(0, 3.2, 0), col, mat("wood"))
		vcyl(m, 3, 0.7, V3(0, 1.5, 0), shade(col, -0.15), mat("wood"))
		vcyl(m, 0.3, w * 0.45, V3(0, 0.15, 0), shade(col, -0.15), mat("wood"))
	else
		top = box(m, V3(w, 0.4, d), V3(0, 3.2, 0), col, mat("wood"))
		for _, x in ipairs({ -w / 2 + 0.4, w / 2 - 0.4 }) do
			for _, z in ipairs({ -d / 2 + 0.4, d / 2 - 0.4 }) do
				box(m, V3(0.5, 3, 0.5), V3(x, 1.5, z), shade(col, -0.15), mat("wood"))
			end
		end
	end
	if o.cloth then
		local c = box(m, V3((o.round and w * 0.7 or w * 0.5), 0.05, (o.round and w * 0.7 or d + 0.2)), V3(0, 3.42, 0),
			c3(o.cloth, pal.fabric), mat("fabric"))
		c.CanCollide = false
	end
	return station(top, "table")
end

PROPS.chair = function(m, o, r, pal)
	local col = c3(o.color, pal.wood)
	local seat = box(m, V3(2.2, 0.3, 2.2), V3(0, 2, 0), col, mat("wood"))
	box(m, V3(2.2, 2.4, 0.3), V3(0, 3.3, 0.95), col, mat("wood"))
	for _, x in ipairs({ -0.9, 0.9 }) do
		for _, z in ipairs({ -0.9, 0.9 }) do
			box(m, V3(0.3, 2, 0.3), V3(x, 1, z), shade(col, -0.15), mat("wood"))
		end
	end
	return seat
end

PROPS.plate = function(m, o, r, pal)
	local d = o.size or 1.6
	local plate = vcyl(m, 0.12, d, V3(0, 0.06, 0), pal.trim, mat("default"))
	vcyl(m, 0.13, d * 0.65, V3(0, 0.07, 0), shade(pal.trim, -0.06), mat("default"))
	if o.food then
		blob(m, V3(d * 0.5, d * 0.25, d * 0.5), V3(0, 0.2, 0), c3(o.food, pal.accent), mat("default"))
	end
	decor(m)
	plate.CanQuery = true
	tag(plate, "KitPlate")
	return plate
end

PROPS.pot = function(m, o, r, pal)
	local col = c3(o.color, pal.ink:Lerp(pal.metal, 0.5))
	local body = vcyl(m, 1.3, 1.8, V3(0, 0.65, 0), col, mat("metal"))
	vcyl(m, 0.12, 1.9, V3(0, 1.36, 0), shade(col, -0.2), mat("metal"))
	ball(m, 0.35, V3(0, 1.5, 0), pal.ink, mat("metal"))
	for _, x in ipairs({ -1.05, 1.05 }) do
		box(m, V3(0.4, 0.2, 0.5), V3(x, 1.1, 0), shade(col, -0.2), mat("metal"))
	end
	return body
end

PROPS.shelf = function(m, o, r, pal)
	local w, h = o.width or 6, o.height or 7
	local col = c3(o.color, pal.wood)
	local back = box(m, V3(w, h, 0.3), V3(0, h / 2, 0.85), shade(col, -0.12), mat("wood"))
	for _, x in ipairs({ -w / 2, w / 2 }) do
		box(m, V3(0.3, h, 2), V3(x, h / 2, 0), col, mat("wood"))
	end
	local shelves = math.floor(h / 2.2)
	for i = 0, shelves do
		local y = 0.2 + i * (h - 0.4) / shelves
		box(m, V3(w, 0.25, 2), V3(0, y, 0), col, mat("wood"))
		if i < shelves then
			local x = -w / 2 + 0.4
			while x < w / 2 - 0.6 do
				local bw = r:NextNumber(0.35, 0.7)
				local bh = r:NextNumber(1, 1.7)
				if o.jars then
					local j = vcyl(m, bh * 0.8, 0.6, V3(x + 0.3, y + bh * 0.4 + 0.12, -0.1), jitter(pal.accent, r, 0.3), M.Glass)
					j.Transparency = 0.2
					x += 0.9
				else
					box(m, V3(bw, bh, 1.5), V3(x + bw / 2, y + bh / 2 + 0.12, 0),
						jitter(({ pal.primary, pal.secondary, pal.accent, pal.fabric })[r:NextInteger(1, 4)], r, 0.1), mat("default"))
					x += bw + 0.05
				end
			end
		end
	end
	return back
end
PROPS.bookshelf = PROPS.shelf

PROPS.bed = function(m, o, r, pal)
	local col = c3(o.color, pal.wood)
	local frame = box(m, V3(5, 1.4, 8), V3(0, 0.9, 0), col, mat("wood"))
	box(m, V3(5.4, 4, 0.5), V3(0, 2, 4), col, mat("wood"))
	box(m, V3(4.6, 0.8, 7.4), V3(0, 1.9, -0.1), pal.trim, mat("fabric"))
	box(m, V3(4.8, 0.5, 4.8), V3(0, 2.3, -1.4), c3(o.blanket, pal.primary), mat("fabric"))
	blob(m, V3(3.4, 0.8, 1.4), V3(0, 2.6, 2.9), pal.trim, mat("fabric"))
	return frame
end

PROPS.desk = function(m, o, r, pal)
	local w = o.width or 6
	local col = c3(o.color, pal.wood)
	local top = box(m, V3(w, 0.35, 3), V3(0, 3.1, 0), col, mat("wood"))
	box(m, V3(1.8, 2.9, 2.8), V3(w / 2 - 1, 1.45, 0), shade(col, -0.1), mat("wood"))
	box(m, V3(0.35, 2.9, 2.8), V3(-w / 2 + 0.3, 1.45, 0), shade(col, -0.1), mat("wood"))
	if o.computer ~= false then
		box(m, V3(2.6, 1.6, 0.2), V3(-0.4, 4.4, 0.6), pal.ink, mat("default"))
		local scr = box(m, V3(2.3, 1.3, 0.05), V3(-0.4, 4.4, 0.48), pal.secondary:Lerp(pal.light, 0.4), M.Neon)
		scr.CastShadow = false
		box(m, V3(0.3, 0.8, 0.3), V3(-0.4, 3.6, 0.7), pal.ink, mat("default"))
		box(m, V3(2, 0.1, 0.7), V3(-0.4, 3.32, -0.5), pal.ink:Lerp(pal.metal, 0.3), mat("default"))
	end
	return station(top, "desk")
end

PROPS.rug = function(m, o, r, pal)
	local w, d = o.width or 10, o.depth or 7
	local col = c3(o.color, pal.fabric)
	local rug
	if o.round then
		rug = vcyl(m, 0.1, w, V3(0, 0.05, 0), col, mat("fabric"))
		vcyl(m, 0.11, w * 0.7, V3(0, 0.06, 0), shade(col, 0.2), mat("fabric"))
	else
		rug = box(m, V3(w, 0.1, d), V3(0, 0.05, 0), col, mat("fabric"))
		box(m, V3(w - 1.2, 0.11, d - 1.2), V3(0, 0.06, 0), shade(col, 0.2), mat("fabric"))
		box(m, V3(w - 2.2, 0.12, d - 2.2), V3(0, 0.07, 0), col, mat("fabric"))
	end
	decor(m)
	return rug
end

PROPS.fireplace = function(m, o, r, pal)
	local w = o.width or 8
	local stone = pal.rock:Lerp(pal.wall, 0.2)
	local body = box(m, V3(w, 7, 3), V3(0, 3.5, 0.5), stone, mat("stone"))
	box(m, V3(w * 0.55, 3.6, 0.4), V3(0, 1.8, -1.05), pal.ink, mat("default"))
	box(m, V3(w + 1, 0.6, 3.6), V3(0, 7.2, 0.3), pal.wood, mat("wood"))
	box(m, V3(w * 0.6, 10, 2.4), V3(0, 12, 0.8), stone, mat("stone"))
	local fire = blob(m, V3(w * 0.3, 1.6, 0.8), V3(0, 1, -0.9), Color3.fromRGB(255, 140, 50), M.Neon)
	fire.CanCollide = false
	fire.CastShadow = false
	local f = Instance.new("Fire")
	f.Size = 3
	f.Heat = 6
	f.Parent = fire
	light(fire, Color3.fromRGB(255, 160, 90), 2.5, 24)
	return body
end

PROPS.plant = function(m, o, r, pal)
	local pot = vcyl(m, 1.6, 1.8, V3(0, 0.8, 0), c3(o.color, pal.primary:Lerp(pal.dirt, 0.4)), mat("default"))
	vcyl(m, 0.3, 2, V3(0, 1.6, 0), shade(pal.primary:Lerp(pal.dirt, 0.4), -0.1), mat("default"))
	for i = 1, 5 do
		local a = i / 5 * PI * 2
		blob(m, V3(0.9, 2.6, 0.4), CF(math.cos(a) * 0.4, 2.8, math.sin(a) * 0.4) * ANG(0, -a, 0) * ANG(0, 0, 0.5),
			i % 2 == 0 and pal.leaf or pal.leafAlt, mat("leaf"))
	end
	return pot
end

PROPS.lab_bench = function(m, o, r, pal)
	local w = o.width or 6
	local body = cabinet(m, w, pal, c3(o.color, pal.trim:Lerp(pal.metal, 0.4)), pal.ink:Lerp(pal.metal, 0.3))
	local cols = { pal.secondary, pal.primary, pal.leafAlt, pal.accent }
	for i = 1, 4 do
		local x = -w / 2 + i * w / 5
		local col = cols[(i - 1) % #cols + 1]
		local v = vcyl(m, 1.2, 0.5, V3(x, 4.15, 0.4), col, M.Neon)
		v.Transparency = 0.25
		v.CastShadow = false
	end
	light(body, pal.secondary, 1, 10)
	return station(body, "lab_bench")
end

PROPS.weapon_rack = function(m, o, r, pal)
	local w = o.width or 6
	local col = c3(o.color, pal.ink:Lerp(pal.metal, 0.35))
	local back = box(m, V3(w, 5, 0.4), V3(0, 2.5, 0.6), col, mat("metal"))
	box(m, V3(w, 0.5, 1.4), V3(0, 0.25, 0), col, mat("metal"))
	box(m, V3(w, 0.3, 0.8), V3(0, 3.6, 0.2), shade(col, 0.1), mat("metal"))
	local gun = pal.ink:Lerp(pal.metal, 0.15)
	for i = 1, o.count or 4 do
		local x = -w / 2 + i * w / ((o.count or 4) + 1)
		box(m, V3(0.35, 3.6, 0.5), V3(x, 2.2, 0.1), gun, mat("metal"))
		box(m, V3(0.4, 1, 0.7), V3(x, 0.95, 0.05), pal.woodDark, mat("wood"))
		box(m, V3(0.3, 0.6, 0.5), V3(x, 2.4, -0.3), gun, mat("metal"))
	end
	return station(back, "weapon_rack")
end

PROPS.sandbags = function(m, o, r, pal)
	local len = o.length or 8
	local col = c3(o.color, pal.sand:Lerp(pal.dirt, 0.3))
	local main
	for row = 0, 2 do
		local n = math.floor(len / 2)
		for i = 0, n - 1 do
			local x = -len / 2 + (i + 0.5) * len / n + (row % 2) * 0.5
			local b = blob(m, V3(len / n + 0.3, 1.1, 1.8), V3(x, 0.5 + row * 0.95, 0), jitter(col, r, 0.04), mat("fabric"))
			main = main or b
		end
	end
	return main
end

PROPS.low_wall = function(m, o, r, pal)
	local len, h = o.length or 10, o.height or 4.5
	local col = c3(o.color, pal.wall:Lerp(pal.rock, 0.4))
	local wall = box(m, V3(len, h, 1.6), V3(0, h / 2, 0), col, mat("stone"))
	box(m, V3(len + 0.3, 0.4, 2), V3(0, h + 0.2, 0), shade(col, 0.12), mat("stone"))
	return wall
end

-- ---- vehicles / water

PROPS.car = function(m, o, r, pal)
	local col = c3(o.color, pal.primary)
	local body = box(m, V3(6, 1.8, 11), V3(0, 2.1, 0), col, mat("metal"))
	box(m, V3(5.4, 1.8, 5.5), V3(0, 3.9, 0.6), col, mat("metal"))
	local glass = box(m, V3(5.5, 1.3, 5.2), V3(0, 3.95, 0.6), pal.sky:Lerp(pal.ink, 0.55), M.Glass)
	glass.CastShadow = false
	box(m, V3(5.6, 0.25, 5.7), V3(0, 4.85, 0.6), col, mat("metal"))
	box(m, V3(6.2, 0.5, 0.6), V3(0, 1.4, -5.6), pal.metal, mat("metal"))
	box(m, V3(6.2, 0.5, 0.6), V3(0, 1.4, 5.6), pal.metal, mat("metal"))
	for _, x in ipairs({ -2, 2 }) do
		local hl = box(m, V3(1.2, 0.6, 0.2), V3(x, 2.4, -5.55), pal.light, M.Neon)
		hl.CastShadow = false
		local tl = box(m, V3(1.2, 0.5, 0.2), V3(x, 2.4, 5.55), pal.danger, M.Neon)
		tl.CastShadow = false
	end
	for _, x in ipairs({ -3, 3 }) do
		for _, z in ipairs({ -3.4, 3.4 }) do
			hcyl(m, 1.2, 2.6, CF(x, 1.3, z), pal.ink, mat("default"))
			hcyl(m, 1.25, 1.3, CF(x, 1.3, z), pal.metal, mat("metal"))
		end
	end
	return body
end

PROPS.boat = function(m, o, r, pal)
	local col = c3(o.color, pal.primary)
	local hull = box(m, V3(5, 1.6, 9), V3(0, 0.6, 1), col, mat("default"))
	box(m, V3(3.54, 1.6, 3.54), CF(0, 0.6, -3.5) * ANG(0, PI / 4, 0), col, mat("default")) -- pointed bow
	box(m, V3(5.2, 0.4, 9.2), V3(0, 1.5, 1), pal.trim, mat("default"))
	box(m, V3(4, 0.3, 7.5), V3(0, 1.3, 1.3), pal.wood, mat("wood"))
	box(m, V3(3, 1.4, 1.2), V3(0, 2.2, 0.5), pal.ink:Lerp(pal.metal, 0.3), mat("default"))
	box(m, V3(3.6, 1.4, 0.2), CF(0, 3, -0.6) * ANG(rad(-20), 0, 0), pal.sky:Lerp(pal.ink, 0.3), M.Glass)
	box(m, V3(1.4, 2.2, 1.4), V3(0, 1.4, 5.8), pal.ink, mat("metal"))
	return hull
end

PROPS.buoy = function(m, o, r, pal)
	local col = c3(o.color, pal.primary)
	local float = vcyl(m, 2, 3.2, V3(0, 0.6, 0), col, mat("default"))
	vcyl(m, 0.7, 3.3, V3(0, 1.1, 0), pal.trim, mat("default"))
	vcyl(m, 4, 0.4, V3(0, 3.5, 0), pal.ink:Lerp(pal.metal, 0.4), mat("metal"))
	for _, a in ipairs({ 0, PI / 2 }) do
		box(m, V3(1.4, 2.6, 0.2), CF(0, 4, 0) * ANG(0, a, 0), col, mat("default"))
	end
	local lamp = ball(m, 0.8, V3(0, 5.8, 0), pal.glow, M.Neon)
	light(lamp, pal.glow, 1, 12)
	return float
end

PROPS.umbrella = function(m, o, r, pal)
	local pole = vcyl(m, 7, 0.3, V3(0, 3.5, 0), pal.trim, mat("default"))
	local col = c3(o.color, pal.primary)
	for i = 0, 7 do
		local a = i / 8 * PI * 2
		wedge(m, V3(2.5, 1.2, 3.4), CF(0, 6.6, 0) * ANG(0, a, 0) * CF(0, 0, -1.7),
			i % 2 == 0 and col or pal.trim, mat("fabric"))
	end
	return pole
end

PROPS.platform = function(m, o, r, pal)
	local d = o.size or 10
	local th = o.thickness or 3
	local top = c3(o.color, pal.ground)
	local main = vcyl(m, 1.2, d, V3(0, -0.6, 0), top, mat("ground"))
	vcyl(m, th, d * 0.92, V3(0, -1.2 - th / 2, 0), pal.dirt, mat("stone"))
	vcyl(m, th * 0.6, d * 0.6, V3(0, -1.2 - th - th * 0.3, 0), shade(pal.dirt, -0.15), mat("stone"))
	vcyl(m, 0.3, d + 0.25, V3(0, -1.05, 0), shade(top, -0.15), mat("ground"))
	return main
end

PROPS.pillar = function(m, o, r, pal)
	local h = o.height or 14
	local col = c3(o.color, pal.wall:Lerp(pal.rock, 0.3))
	local main = box(m, V3(2.4, h, 2.4), V3(0, h / 2, 0), col, mat("stone"))
	box(m, V3(3.2, 1, 3.2), V3(0, 0.5, 0), shade(col, -0.12), mat("stone"))
	box(m, V3(3.2, 1, 3.2), V3(0, h - 0.5, 0), shade(col, -0.12), mat("stone"))
	return main
end

WK2.propKinds = {}
for k in pairs(PROPS) do
	table.insert(WK2.propKinds, k)
end
table.sort(WK2.propKinds)

-- WorldKit2.prop(kind, {position, rotation=deg, cframe?, scale=1, color, palette, seed, parent, ...kind opts}) -> Model
-- The model's pivot is its ground centre, so model:PivotTo(CFrame.new(groundPoint)) re-places it.
function WK2.prop(kind, o)
	o = o or {}
	local fn = PROPS[kind]
	if not fn then
		warn("[WorldKit2] unknown prop " .. tostring(kind) .. "; using crate")
		kind = "crate"
		fn = PROPS.crate
	end
	local m = Instance.new("Model")
	m.Name = o.name or kind
	local r = Random.new(o.seed or 1)
	local main = fn(m, o, r, palOf(o)) or m:FindFirstChildWhichIsA("BasePart")
	m.PrimaryPart = main
	main.PivotOffset = main.CFrame:Inverse()
	m:SetAttribute("Prop", kind)
	if o.scale and o.scale ~= 1 then
		pcall(function() m:ScaleTo(o.scale) end)
	end
	local cf = o.cframe or (CF(o.position or Vector3.zero) * ANG(0, rad(o.rotation or 0), 0))
	m:PivotTo(cf)
	m.Parent = o.parent or folder("WorldKit2")
	return m
end

-- ---------------------------------------------------------------------------------------------------- placement

local function rayParams(include)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = include or { Workspace.Terrain }
	params.IgnoreWater = false
	return params
end

-- WorldKit2.groundAt(x, z, {top=500, bottom=-500, include={Workspace.Terrain}}) -> position?, material?
function WK2.groundAt(x, z, o)
	o = o or {}
	local top, bottom = o.top or 500, o.bottom or -500
	local res = Workspace:Raycast(V3(x, top, z), V3(0, bottom - top, 0), rayParams(o.include))
	if res then
		return res.Position, res.Material
	end
	return nil, nil
end

local function gauss(r)
	return math.sqrt(-2 * math.log(math.max(1e-6, r:NextNumber()))) * math.cos(2 * PI * r:NextNumber())
end

local GAP = { tree = 9, round_tree = 9, pine = 8, palm = 9, blossom = 9, dead_tree = 7, house = 22, shop = 22,
	tower = 18, skyscraper = 22, rock = 5, bush = 4, flowers = 2.5, grass = 2, mushroom = 3, cactus = 5,
	lollipop = 7, candy_cane = 6, gumdrop = 5, asteroid = 14, crystal = 4, log = 6, lily_pad = 3, reeds = 2.5,
	snowman = 5, buoy = 10, boat = 16, umbrella = 6 }

-- WorldKit2.populate({center, size=number|Vector2, kinds={{"tree", weight, {opts}}, ...}, count=40, clusters=6,
-- spread=0.1, clear=0, seed, parent, onWater=false, scale={0.8,1.25}, include={Workspace.Terrain}, float={min,max}})
-- -> {models}. Clustered scatter with negative space: props group around cluster centres (plus a few loners),
-- keep their footprint apart, sit on the ground found by raycast, and skip water unless onWater (then ONLY water).
function WK2.populate(o)
	local r = Random.new(o.seed or 5)
	local center = o.center or Vector3.zero
	local sx = typeof(o.size) == "Vector2" and o.size.X or (o.size or 128)
	local sz = typeof(o.size) == "Vector2" and o.size.Y or (o.size or 128)
	local kinds = o.kinds or { { "tree", 1 } }
	local total = 0
	for _, k in ipairs(kinds) do total += k[2] or 1 end
	local function pick()
		local x = r:NextNumber(0, total)
		for _, k in ipairs(kinds) do
			x -= k[2] or 1
			if x <= 0 then return k end
		end
		return kinds[1]
	end
	local clusters = {}
	for _ = 1, o.clusters or 6 do
		for _ = 1, 12 do
			local p = V3(r:NextNumber(-0.45, 0.45) * sx, 0, r:NextNumber(-0.45, 0.45) * sz)
			if p.Magnitude > (o.clear or 0) + 6 then
				table.insert(clusters, p)
				break
			end
		end
	end
	local placed, made = {}, {}
	local spread = (o.spread or 0.1) * math.max(sx, sz)
	local sc = o.scale or { 0.8, 1.25 }
	local include = o.include
	for _ = 1, (o.count or 40) * 3 do
		if #made >= (o.count or 40) then break end
		local k = pick()
		local off
		if #clusters > 0 and r:NextNumber() < 0.82 then
			local cc = clusters[r:NextInteger(1, #clusters)]
			off = cc + V3(gauss(r) * spread, 0, gauss(r) * spread)
		else
			off = V3(r:NextNumber(-0.5, 0.5) * sx, 0, r:NextNumber(-0.5, 0.5) * sz)
		end
		if math.abs(off.X) > sx / 2 or math.abs(off.Z) > sz / 2 or off.Magnitude < (o.clear or 0) then
			continue
		end
		local gap = (k[3] and k[3].gap) or GAP[k[1]] or 4
		local ok = true
		for _, q in ipairs(placed) do
			if (q[1] - off).Magnitude < (q[2] + gap) / 2 then
				ok = false
				break
			end
		end
		if not ok then continue end
		local pos
		if o.float then
			pos = center + off + V3(0, r:NextNumber(o.float[1], o.float[2]), 0)
		else
			local hit, material = WK2.groundAt(center.X + off.X, center.Z + off.Z,
				{ top = center.Y + 300, bottom = center.Y - 200, include = include })
			if not hit then continue end
			local isWater = material == M.Water
			if (o.onWater and not isWater) or (not o.onWater and isWater) then continue end
			pos = hit - V3(0, o.sink or 0.3, 0)
		end
		local opts = {}
		for kk, vv in pairs(k[3] or {}) do opts[kk] = vv end
		opts.position = pos
		opts.rotation = opts.rotation or r:NextNumber(0, 360)
		opts.scale = opts.scale or r:NextNumber(sc[1], sc[2])
		opts.seed = r:NextInteger(1, 1e6)
		opts.parent = o.parent
		opts.palette = opts.palette or o.palette
		table.insert(made, WK2.prop(k[1], opts))
		table.insert(placed, { off, gap })
	end
	return made
end

-- ---------------------------------------------------------------------------------------------------- biomes

local T = Workspace.Terrain

local function disc(center, y0, y1, radius, material)
	T:FillCylinder(CF(center.X, (y0 + y1) / 2, center.Z), y1 - y0, radius, material)
end

local BIOMES = {}

BIOMES.grassland = function(b)
	local c, S, r = b.center, b.size, b.r
	disc(c, c.Y - 14, c.Y - 3, S / 2, M.Ground)
	disc(c, c.Y - 3, c.Y, S / 2, M.Grass)
	for _ = 1, 5 do
		local a, d = r:NextNumber(0, PI * 2), r:NextNumber(0.25, 0.42) * S
		local R = r:NextNumber(0.08, 0.16) * S
		T:FillBall(c + V3(math.cos(a) * d, -R * 0.62, math.sin(a) * d), R, M.Grass)
	end
	for i = 0, 24 do -- a winding dirt path through the clearing
		local t = i / 24
		disc(c + V3((t - 0.5) * S * 0.9, 0, math.sin(t * PI * 2.2) * S * 0.08), c.Y - 1.6, c.Y + 0.1, 3.5, M.Ground)
	end
	b.pop({ kinds = { { "round_tree", 4 }, { "blossom", 1 }, { "bush", 4 }, { "flowers", 5 }, { "grass", 6 }, { "rock", 2 } },
		count = 80, clusters = 8, clear = S * 0.12 })
end

BIOMES.forest = function(b)
	local c, S, r = b.center, b.size, b.r
	disc(c, c.Y - 14, c.Y - 3, S / 2, M.Ground)
	disc(c, c.Y - 3, c.Y, S / 2, M.Grass)
	for _ = 1, 10 do
		local a, d = r:NextNumber(0, PI * 2), r:NextNumber(0.1, 0.45) * S
		disc(c + V3(math.cos(a) * d, 0, math.sin(a) * d), c.Y - 1.5, c.Y + 0.2, r:NextNumber(8, 20), M.LeafyGrass)
	end
	b.pop({ kinds = { { "pine", 5 }, { "round_tree", 3 }, { "bush", 4 }, { "mushroom", 2 }, { "log", 1 }, { "rock", 2, { moss = true } },
		{ "grass", 4 }, { "flowers", 1 } }, count = 120, clusters = 12, spread = 0.09, clear = S * 0.1 })
end

BIOMES.beach = function(b)
	local c, S = b.center, b.size
	local wl = c.Y - 4
	T:FillBlock(CF(c.X + S * 0.25, wl - 7, c.Z), V3(S * 0.5, 14, S), M.Water)
	T:FillBlock(CF(c.X + S * 0.25, wl - 18, c.Z), V3(S * 0.5, 8, S), M.Sand)
	T:FillBlock(CF(c.X - S * 0.25, c.Y - 8, c.Z), V3(S * 0.5, 16, S), M.Sand)
	local run, steps = S * 0.22, 8
	for i = 0, steps - 1 do -- stepped fills smooth into one gentle slope
		local top = c.Y - (i + 1) * (c.Y - (wl - 8)) / steps
		local x0 = c.X + i * run / steps
		T:FillBlock(CF(x0 + run / steps / 2, (top + wl - 14) / 2, c.Z), V3(run / steps + 1, top - (wl - 14), S), M.Sand)
	end
	T:FillBlock(CF(c.X - S * 0.38, c.Y - 1.5, c.Z), V3(S * 0.24, 3, S), M.Grass)
	b.pop({ center = c + V3(-S * 0.1, 0, 0), size = Vector2.new(S * 0.3, S),
		kinds = { { "palm", 5 }, { "rock", 2 }, { "umbrella", 1 }, { "grass", 1 } }, count = 26, clusters = 5 })
	b.pop({ center = c + V3(-S * 0.38, 0, 0), size = Vector2.new(S * 0.22, S),
		kinds = { { "round_tree", 3 }, { "bush", 3 }, { "flowers", 2 } }, count = 24, clusters = 4 })
	b.pop({ center = c + V3(S * 0.3, 0, 0), size = Vector2.new(S * 0.35, S), onWater = true, sink = 0.6,
		kinds = { { "buoy", 3 }, { "boat", 1, { scale = 1 } } }, count = 6, clusters = 0 })
	b.out.spawn = c + V3(-S * 0.08, 4, 0)
end

BIOMES.islands = function(b)
	local c, S, r = b.center, b.size, b.r
	T:FillBlock(CF(c.X, c.Y - 12, c.Z), V3(S, 24, S), M.Water)
	T:FillBlock(CF(c.X, c.Y - 28, c.Z), V3(S, 8, S), M.Sand)
	local tops = {}
	local n = 5
	for i = 1, n do
		local a = i / n * PI * 2 + r:NextNumber(-0.3, 0.3)
		local d = i == 1 and 0 or S * r:NextNumber(0.25, 0.34)
		local rad_ = i == 1 and S * 0.14 or S * r:NextNumber(0.07, 0.1)
		local pos = c + V3(math.cos(a) * d, 2, math.sin(a) * d)
		local isl = WorldKit.island({ position = pos, radius = rad_, height = rad_ * 0.35, floating = false,
			top = M.Grass, side = M.Sand, seed = b.seed + i })
		table.insert(tops, isl)
		b.pop({ center = isl.top, size = rad_ * 1.5, kinds = { { "palm", 3 }, { "round_tree", 2 }, { "bush", 3 },
			{ "rock", 1 }, { "flowers", 2 } }, count = math.floor(rad_ / 2.5), clusters = 2 })
	end
	for i = 2, #tops do
		local a, bb = tops[1], tops[i]
		local dir = (bb.top - a.top) * V3(1, 0, 1)
		if dir.Magnitude > 1 then
			local u = dir.Unit
			WorldKit.bridge({ from = a.top + u * a.radius * 0.8, to = bb.top - u * bb.radius * 0.8, width = 6,
				parent = b.folder })
		end
	end
	b.out.spawn = tops[1].top + V3(0, 4, 0)
	b.out.islands = tops
end

local function mesa(center, baseY, R, H, r)
	local layers = math.max(3, math.floor(H / 6))
	local lh = H / layers
	for k = 0, layers - 1 do
		local rr = R * (1 - k * 0.035) + r:NextNumber(-1, 1)
		disc(center, baseY + k * lh, baseY + (k + 1) * lh + 0.5, rr, k % 2 == 0 and M.Sandstone or M.Rock)
	end
	disc(center, baseY + H, baseY + H + 2, R * (1 - layers * 0.035) - 1, M.Sand)
end

BIOMES.desert = function(b)
	local c, S, r = b.center, b.size, b.r
	disc(c, c.Y - 14, c.Y, S / 2, M.Sand)
	for _ = 1, 6 do -- dunes
		local a, d = r:NextNumber(0, PI * 2), r:NextNumber(0.15, 0.45) * S
		local R = r:NextNumber(0.06, 0.12) * S
		T:FillBall(c + V3(math.cos(a) * d, -R * 0.75, math.sin(a) * d), R, M.Sand)
	end
	for i = 1, 5 do
		local a = i / 5 * PI * 2 + r:NextNumber(-0.3, 0.3)
		local d = r:NextNumber(0.3, 0.42) * S
		mesa(c + V3(math.cos(a) * d, 0, math.sin(a) * d), c.Y - 4, r:NextNumber(0.05, 0.09) * S, r:NextNumber(18, 42), r)
	end
	b.pop({ kinds = { { "cactus", 4 }, { "rock", 3 }, { "dead_tree", 1 }, { "bush", 1, { berries = false } } },
		count = 40, clusters = 6, clear = S * 0.12 })
end

BIOMES.canyon = function(b)
	local c, S, r = b.center, b.size, b.r
	disc(c, c.Y - 14, c.Y, S / 2, M.Sand)
	for _, side in ipairs({ -1, 1 }) do -- two banded walls with a dry river between
		for i = 0, 7 do
			local z = (i / 7 - 0.5) * S * 0.85
			mesa(c + V3(side * S * (0.24 + r:NextNumber(-0.03, 0.03)), 0, z), c.Y - 4, S * r:NextNumber(0.09, 0.12),
				r:NextNumber(26, 44), r)
		end
	end
	for i = 0, 20 do
		local t = i / 20
		disc(c + V3(math.sin(t * PI * 3) * S * 0.04, 0, (t - 0.5) * S), c.Y - 2, c.Y + 0.2, 5, M.Ground)
	end
	b.pop({ size = Vector2.new(S * 0.3, S), kinds = { { "cactus", 3 }, { "rock", 4 }, { "dead_tree", 1 } },
		count = 26, clusters = 5, clear = S * 0.08 })
end

BIOMES.snowy_mountains = function(b)
	local c, S, r = b.center, b.size, b.r
	disc(c, c.Y - 14, c.Y, S / 2, M.Snow)
	for i = 1, 4 do
		local a = i / 4 * PI * 2 + r:NextNumber(-0.4, 0.4)
		local d = r:NextNumber(0.3, 0.4) * S
		local base = c + V3(math.cos(a) * d, 0, math.sin(a) * d)
		local R = r:NextNumber(0.13, 0.18) * S
		for k = 0, 6 do
			local rr = R * (1 - k * 0.14)
			local p = base + V3(r:NextNumber(-2, 2), -R * 0.4 + k * R * 0.32, r:NextNumber(-2, 2))
			T:FillBall(p, rr, k >= 4 and M.Snow or M.Rock)
		end
		T:FillBall(base + V3(0, R * 1.55, 0), R * 0.2, M.Snow)
	end
	local lake = c + V3(S * 0.12, 0, -S * 0.1)
	disc(lake, c.Y - 1, c.Y + 0.3, S * 0.08, M.Ice)
	b.pop({ kinds = { { "pine", 6, { snow = true } }, { "rock", 3 }, { "dead_tree", 1 }, { "snowman", 0.4 } },
		count = 60, clusters = 8, clear = S * 0.14 })
end

BIOMES.swamp = function(b)
	local c, S, r = b.center, b.size, b.r
	disc(c, c.Y - 14, c.Y, S / 2, M.Mud)
	for _ = 1, 8 do
		local a, d = r:NextNumber(0, PI * 2), r:NextNumber(0.1, 0.42) * S
		disc(c + V3(math.cos(a) * d, 0, math.sin(a) * d), c.Y - 1.4, c.Y + 0.2, r:NextNumber(8, 16), M.LeafyGrass)
	end
	for _ = 1, 7 do
		local a, d = r:NextNumber(0, PI * 2), r:NextNumber(0.18, 0.42) * S
		disc(c + V3(math.cos(a) * d, 0, math.sin(a) * d), c.Y - 4, c.Y - 0.6, r:NextNumber(10, 22), M.Water)
		disc(c + V3(math.cos(a) * d, 0, math.sin(a) * d), c.Y - 0.6, c.Y + 1, r:NextNumber(10, 22), M.Air)
	end
	b.pop({ kinds = { { "dead_tree", 3 }, { "round_tree", 1, { color = b.pal.leaf:Lerp(b.pal.dirt, 0.4) } },
		{ "reeds", 4 }, { "mushroom", 2 }, { "log", 1 }, { "grass", 3 } }, count = 60, clusters = 8, clear = S * 0.1 })
	b.pop({ kinds = { { "lily_pad", 5 }, { "reeds", 1 } }, count = 30, clusters = 6, onWater = true, sink = 0.05 })
end

BIOMES.volcanic = function(b)
	local c, S, r = b.center, b.size, b.r
	disc(c, c.Y - 14, c.Y, S / 2, M.Basalt)
	local vc = c + V3(S * 0.18, 0, S * 0.18)
	local R, H = S * 0.2, S * 0.28
	local tiers = 9
	for k = 0, tiers - 1 do
		disc(vc, c.Y + k * H / tiers - 1, c.Y + (k + 1) * H / tiers, R * (1 - k * 0.095), k % 3 == 2 and M.Rock or M.Basalt)
	end
	T:FillBall(vc + V3(0, H + R * 0.08, 0), R * 0.24, M.Air)
	disc(vc, c.Y + H - R * 0.2, c.Y + H - R * 0.1, R * 0.2, M.CrackedLava)
	for i = 0, 2 do -- lava rivers running from the cone
		local a = r:NextNumber(0, PI * 2)
		for j = 0, 14 do
			local d = R * 0.9 + j * S * 0.025
			local wob = math.sin(j * 0.7 + i) * 0.25
			disc(vc + V3(math.cos(a + wob) * d, 0, math.sin(a + wob) * d), c.Y - 1.5, c.Y + 0.1, 3.2, M.CrackedLava)
		end
	end
	local glow = box(b.folder, V3(1, 1, 1), CF(vc + V3(0, H + 6, 0)), Color3.fromRGB(255, 120, 40), M.Neon)
	glow.Transparency = 1
	glow.CanCollide = false
	light(glow, Color3.fromRGB(255, 120, 50), 4, 60)
	b.pop({ kinds = { { "rock", 4 }, { "crystal", 2, { color = Color3.fromRGB(255, 120, 50) } }, { "dead_tree", 2 } },
		count = 45, clusters = 7, clear = S * 0.1 })
end

BIOMES.candy = function(b)
	local c, S, r = b.center, b.size, b.r
	disc(c, c.Y - 14, c.Y, S / 2, M.Grass)
	for _ = 1, 6 do
		local a, d = r:NextNumber(0, PI * 2), r:NextNumber(0.25, 0.42) * S
		local R = r:NextNumber(0.07, 0.13) * S
		local p = c + V3(math.cos(a) * d, -R * 0.5, math.sin(a) * d)
		T:FillBall(p, R, M.Ground)
		T:FillBall(p + V3(0, R * 0.55, 0), R * 0.55, M.Snow) -- frosting cap
	end
	b.pop({ kinds = { { "lollipop", 3 }, { "candy_cane", 2 }, { "gumdrop", 4 }, { "mushroom", 2 },
		{ "blossom", 2 }, { "flowers", 3 } }, count = 60, clusters = 8, clear = S * 0.12 })
end

BIOMES.neon_city = function(b)
	local c, S = b.center, b.size
	disc(c, c.Y - 10, c.Y - 1, S / 2 + 8, M.Asphalt)
	local blocks = math.max(1, math.floor((S - 16) / 72))
	local town = WK2.town({ center = c, blocks = blocks, blockSize = 56, street = 16, style = "neon", seed = b.seed,
		parent = b.folder, palette = b.o.palette })
	b.out.spawn = town.spawn
	b.out.town = town
end

BIOMES.space_asteroids = function(b)
	local c, S, r = b.center, b.size, b.r
	local pad = vcyl(b.folder, 2, 40, c - V3(0, 1, 0), b.pal.metal, mat("metal"))
	vcyl(b.folder, 2.1, 30, c - V3(0, 1, 0), b.pal.ink:Lerp(b.pal.metal, 0.3), mat("metal"))
	local ring = vcyl(b.folder, 2.2, 32, c - V3(0, 1.05, 0), b.pal.glow, M.Neon)
	ring.CastShadow = false
	vcyl(b.folder, 2.3, 28, c - V3(0, 1, 0), b.pal.ink:Lerp(b.pal.metal, 0.3), mat("metal"))
	local _ = pad
	for _ = 1, 9 do
		local p = c + V3(r:NextNumber(-0.45, 0.45) * S, r:NextNumber(10, 70), r:NextNumber(-0.45, 0.45) * S)
		if (p - c).Magnitude > 40 then
			local R = r:NextNumber(8, 18)
			T:FillBall(p, R, M.Basalt)
			for _ = 1, 3 do
				T:FillBall(p + V3(r:NextNumber(-1, 1), r:NextNumber(-0.6, 0.6), r:NextNumber(-1, 1)) * R * 0.7,
					R * r:NextNumber(0.4, 0.7), r:NextNumber() < 0.5 and M.Rock or M.Basalt)
			end
			if r:NextNumber() < 0.5 then
				T:FillBall(p + V3(0, R * 0.6, 0), R * 0.3, M.Glacier)
			end
		end
	end
	b.pop({ kinds = { { "asteroid", 1 } }, count = 30, clusters = 5, spread = 0.12, clear = 30, float = { 6, 90 } })
	b.pop({ kinds = { { "crystal", 1 } }, count = 14, clusters = 6, clear = 24 })
	b.out.spawn = c + V3(0, 4, 0)
end

BIOMES.island = BIOMES.islands
BIOMES.mountains = BIOMES.snowy_mountains
BIOMES.snow = BIOMES.snowy_mountains
BIOMES.space = BIOMES.space_asteroids
BIOMES.city = BIOMES.neon_city
WK2.biomeKinds = { "grassland", "beach", "islands", "desert", "canyon", "snowy_mountains", "forest", "swamp", "volcanic",
	"neon_city", "candy", "space_asteroids" }

-- WorldKit2.biome(kind, {center=Vector3, size=256, seed, density=1, palette, parent}) ->
-- {folder, center, size, spawn=Vector3, props={Model}, ...}. Terrain + clustered dressing; centre kept clear.
function WK2.biome(kind, o)
	o = o or {}
	local fn = BIOMES[kind]
	if not fn then
		warn("[WorldKit2] unknown biome " .. tostring(kind) .. "; using grassland")
		kind = "grassland"
		fn = BIOMES.grassland
	end
	local center = o.center or Vector3.zero
	local size = o.size or 256
	local seed = o.seed or 1
	local f = folder(o.name or ("Biome_" .. kind), o.parent or folder("WorldKit2"))
	local out = { kind = kind, folder = f, center = center, size = size, spawn = center + V3(0, 4, 0), props = {} }
	local b = { center = center, size = size, seed = seed, r = Random.new(seed), pal = palOf(o), folder = f, out = out, o = o }
	local popN = 0
	b.pop = function(spec)
		popN += 1
		spec.center = spec.center or center
		spec.size = spec.size or size
		spec.seed = seed * 97 + popN
		spec.parent = f
		spec.palette = spec.palette or o.palette
		spec.count = math.max(1, math.floor((spec.count or 30) * (o.density or 1) * (size / 256) ^ 2 + 0.5))
		for _, m in ipairs(WK2.populate(spec)) do
			table.insert(out.props, m)
		end
	end
	fn(b)
	return out
end

-- ---------------------------------------------------------------------------------------------------- course

local function catmull(p0, p1, p2, p3, t)
	local t2, t3 = t * t, t * t * t
	return 0.5 * ((2 * p1) + (p2 - p0) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (3 * p1 - p0 - 3 * p2 + p3) * t3)
end

local function sampleSpline(points, closed, step)
	local n = #points
	local out = {}
	local segs = closed and n or n - 1
	for i = 1, segs do
		local p0 = points[closed and ((i - 2) % n + 1) or math.max(1, i - 1)]
		local p1 = points[i]
		local p2 = points[i % n + 1]
		local p3 = points[closed and ((i + 1) % n + 1) or math.min(n, i + 2)]
		local k = math.max(1, math.ceil((p2 - p1).Magnitude / step))
		for j = 0, k - 1 do
			table.insert(out, catmull(p0, p1, p2, p3, j / k))
		end
	end
	if closed then
		table.insert(out, points[1])
	else
		table.insert(out, points[n])
	end
	return out
end

local function gateArch(m, cf, w, pal, index, isStart, onWater)
	local postCol = isStart and pal.trim or pal.secondary
	for _, side in ipairs({ -1, 1 }) do
		local base = cf * CF(side * (w / 2 + 2), 0, 0)
		if onWater then
			vcyl(m, 2.5, 4.5, base * CF(0, 0.5, 0), pal.primary, mat("default"))
		end
		vcyl(m, 13, 1.4, base * CF(0, 6.5, 0), postCol, mat("metal"))
		ball(m, 2, base * CF(0, 13.2, 0), pal.accent, mat("default"))
	end
	local beam = box(m, V3(w + 4, 2.2, 1.2), cf * CF(0, 12, 0), isStart and pal.ink or pal.primary, mat("default"))
	if isStart then
		for i = 0, 9 do
			box(m, V3((w + 4) / 10, 1, 1.3), cf * CF(-(w + 4) / 2 + (i + 0.5) * (w + 4) / 10, 12 + ((i % 2) - 0.5),
				0), i % 2 == 0 and pal.trim or pal.ink, mat("default"))
		end
	end
	local strip = box(m, V3(w + 3, 0.35, 1.3), cf * CF(0, 10.7, 0), pal.glow, M.Neon)
	strip.CastShadow = false
	local trig = box(m, V3(w + 4, 14, 2), cf * CF(0, 7, 0), pal.glow, M.SmoothPlastic)
	trig.Transparency = 1
	trig.CanCollide = false
	trig.CanQuery = false
	trig.Name = "Gate" .. index
	tag(trig, "KitGate", { GateIndex = index, IsStart = isStart })
	local _ = beam
	return trig
end

-- WorldKit2.course(points={Vector3...}, {width=16, style="road"|"water"|"rail"|"platforms", gates=true|n|false,
-- closed=false, step=6, spacing=14, supports=true, palette, parent}) -> {model, samples={CFrame}, gates={Part}, length,
-- start=CFrame}. Catmull-Rom spline through the points. Gate triggers are invisible parts tagged KitGate
-- (attributes GateIndex, IsStart) for lap/checkpoint logic.
function WK2.course(points, o)
	o = o or {}
	local w = o.width or 16
	local style = o.style or "road"
	local pal = palOf(o)
	local m = Instance.new("Model")
	m.Name = o.name or ("Course_" .. style)
	m.Parent = o.parent or folder("WorldKit2")
	local s = sampleSpline(points, o.closed, o.step or 6)
	local samples, length = {}, 0
	for i = 1, #s - 1 do
		local a, b = s[i], s[i + 1]
		if (b - a).Magnitude > 0.05 then
			table.insert(samples, CFrame.lookAt(a, b))
			length += (b - a).Magnitude
		end
	end
	local roadCol = c3(o.color, pal.ink:Lerp(pal.metal, 0.3))
	local spacingK = math.max(1, math.floor((o.spacing or 14) / (o.step or 6) + 0.5))
	for i = 1, #s - 1 do
		local a, b = s[i], s[i + 1]
		local len = (b - a).Magnitude
		if len <= 0.05 then continue end
		local cf = CFrame.lookAt((a + b) / 2, b)
		if style == "road" then
			box(m, V3(w, 1, len + 0.6), cf * CF(0, -0.5, 0), roadCol, mat("road"))
			for _, side in ipairs({ -1, 1 }) do
				box(m, V3(1.6, 0.7, len + 0.6), cf * CF(side * (w / 2 + 0.8), -0.15, 0),
					i % 2 == 0 and pal.primary or pal.trim, mat("default"))
			end
			if i % 2 == 0 then
				local dash = box(m, V3(0.5, 0.05, len * 0.6), cf * CF(0, 0.02, 0), pal.trim, mat("default"))
				dash.CanCollide = false
			end
			if o.supports ~= false and i % 8 == 0 then
				local hit = WK2.groundAt(cf.Position.X, cf.Position.Z, { top = cf.Position.Y - 1.5, bottom = cf.Position.Y - 120 })
				local drop = hit and (cf.Position.Y - hit.Y) or 0
				if drop > 4 then
					vcyl(m, drop, 3, CF(cf.Position - V3(0, drop / 2 + 0.5, 0)), pal.wall:Lerp(pal.rock, 0.4), mat("stone"))
				end
			end
		elseif style == "water" then
			T:FillBlock(cf * CF(0, -2.5, 0), V3(w, 5, len + 1), M.Water)
			for _, side in ipairs({ -1, 1 }) do
				T:FillBlock(cf * CF(side * (w / 2 + 3), -2.5, 0), V3(6, 6, len + 1), M.Sand)
			end
			if i % (spacingK * 3) == 0 then
				for _, side in ipairs({ -1, 1 }) do
					WK2.prop("buoy", { cframe = cf * CF(side * (w / 2 - 1), -0.6, 0), parent = m, palette = o.palette,
						color = side < 0 and pal.primary or pal.leaf })
				end
			end
		elseif style == "rail" then
			box(m, V3(w * 0.6, 0.6, len + 0.4), cf * CF(0, -0.3, 0), pal.rock, mat("stone"))
			box(m, V3(w * 0.48, 0.4, 1.2), cf * CF(0, 0.15, 0), pal.woodDark, mat("wood"))
			for _, side in ipairs({ -1, 1 }) do
				box(m, V3(0.5, 0.6, len + 0.4), cf * CF(side * w * 0.16, 0.6, 0), pal.metal, mat("metal"))
			end
		elseif style == "platforms" then
			if i % spacingK == 1 or spacingK == 1 then
				WK2.prop("platform", { position = a, size = w * 0.7, parent = m, palette = o.palette })
			end
		end
	end
	local gates = {}
	local nG = o.gates == false and 0 or (type(o.gates) == "number" and o.gates or math.max(3, math.floor(length / 140)))
	for g = 1, nG do
		local idx = math.floor((g - 1) / nG * #samples) + 1
		local cf = samples[idx]
		if cf then
			table.insert(gates, gateArch(m, cf, w, pal, g, g == 1, style == "water"))
		end
	end
	return { model = m, samples = samples, gates = gates, length = length, start = samples[1] }
end

-- ---------------------------------------------------------------------------------------------------- obby

local THEMES = {
	grass = { top = "ground", side = "dirt", decor = { "flowers", "grass", "mushroom", "bush" } },
	candy = { top = "blossom", side = "trim", decor = { "gumdrop", "lollipop", "candy_cane" } },
	lava = { top = "rock", side = "woodDark", decor = { "crystal", "torch", "rock" } },
	ice = { top = "snow", side = "secondary", decor = { "crystal", "pine", "rock" } },
	sky = { top = "trim", side = "sky", decor = { "flowers", "bush" } },
	neon = { top = "ink", side = "wall", decor = { "crystal" } },
}

-- WorldKit2.platformingCourse({start=Vector3, length=14 platforms, difficulty=1..5, theme="grass"|"candy"|"lava"|"ice"|
-- "sky"|"neon", direction=Vector3, seed, coins=true, palette, parent}) -> {model, platforms={Model}, start=CFrame,
-- goal=Part, checkpoints={Part}}. N64-style floating discs with tuned jump gaps (edge-to-edge 3..11 studs, rises <= 4).
-- Hooks: KitMover (MoveOffset, MovePeriod), KitSpinner (SpinSpeed), KitCrumble, KitBounce (BouncePower), KitCoin,
-- KitCheckpoint (Index), KitGoal. Call WorldKit2.animate() once (server) to run movers/spinners/crumblers.
function WK2.platformingCourse(o)
	o = o or {}
	local r = Random.new(o.seed or 3)
	local diff = math.clamp(o.difficulty or 2, 1, 5)
	local pal = palOf(o)
	local th = THEMES[o.theme or "grass"] or THEMES.grass
	local topCol, sideCol = pal[th.top] or pal.ground, pal[th.side] or pal.dirt
	local m = Instance.new("Model")
	m.Name = o.name or "PlatformingCourse"
	m.Parent = o.parent or folder("WorldKit2")
	local dir = (o.direction or V3(0, 0, -1)) * V3(1, 0, 1)
	dir = dir.Magnitude > 0 and dir.Unit or V3(0, 0, -1)
	local baseDir, yaw = dir, 0
	local pos = o.start or V3(0, 30, 0)
	local platforms, checkpoints = {}, {}
	local prevR = 0
	local prevTop
	local count = o.length or 14
	local function disc_(p, d, kind)
		local pm = WK2.prop("platform", { position = p, size = d, color = topCol, parent = m, seed = r:NextInteger(1, 1e6),
			palette = { dirt = sideCol } })
		pm.Name = "Platform_" .. kind
		return pm
	end
	for i = 0, count do
		local d
		if i == 0 or i == count then
			d = 18
		else
			d = math.max(6, 14 - diff * 1.4 + r:NextNumber(-1.5, 1.5))
		end
		local kind = "static"
		if i > 0 and i < count then
			local roll = r:NextNumber()
			if i % 5 == 0 then
				kind = "checkpoint"
			elseif diff >= 2 and roll < 0.12 + diff * 0.04 then
				kind = "moving"
			elseif diff >= 3 and roll < 0.3 + diff * 0.03 then
				kind = "spinner"
			elseif diff >= 2 and roll < 0.42 then
				kind = "crumble"
			elseif roll < 0.5 then
				kind = "bounce"
			end
		end
		if i > 0 then
			local gap = math.min(11, r:NextNumber(3, 4 + diff * 1.4))
			local rise = math.min(4, r:NextNumber(-3, 1 + diff * 0.6))
			if platforms[#platforms] and platforms[#platforms]:GetAttribute("Kind") == "bounce" then
				rise = r:NextNumber(8, 13)
			end
			yaw = math.clamp(yaw + r:NextNumber(-0.35, 0.35), -0.9, 0.9) -- winds, but never doubles back
			dir = CFrame.Angles(0, yaw, 0):VectorToWorldSpace(baseDir).Unit
			pos = pos + dir * (prevR + gap + d / 2) + V3(0, rise, 0)
		end
		local pm
		if kind == "spinner" then
			pm = Instance.new("Model")
			pm.Name = "Platform_spinner"
			local hub = vcyl(pm, 1.4, 5, CF(pos - V3(0, 0.7, 0)), pal.accent, mat("default"))
			box(pm, V3(d * 1.8, 1.2, 3.2), CF(pos - V3(0, 0.6, 0)), topCol, mat("default"))
			box(pm, V3(d * 1.8 + 0.3, 0.3, 3.5), CF(pos - V3(0, 1.3, 0)), sideCol, mat("default"))
			pm.PrimaryPart = hub
			hub.PivotOffset = hub.CFrame:Inverse() * CF(pos) -- upright pivot: spin about world Y, not the cylinder axis
			pm.Parent = m
			tag(pm, "KitSpinner", { SpinSpeed = 0.5 + diff * 0.22 })
		else
			pm = disc_(pos, d, kind)
		end
		pm:SetAttribute("Kind", kind)
		local top = pm.PrimaryPart
		if kind == "moving" then
			local right = dir:Cross(V3(0, 1, 0))
			tag(pm, "KitMover", { MoveOffset = right * (5 + diff * 1.5), MovePeriod = 4.2 - diff * 0.35 })
			local stripe = vcyl(pm, 0.32, d * 0.5, CF(pos + V3(0, 0.02, 0)), pal.secondary, mat("default"))
			stripe.CanCollide = false
		elseif kind == "crumble" then
			top.Color = topCol:Lerp(pal.danger, 0.25)
			for k = 1, 3 do
				local crack = box(pm, V3(d * 0.5, 0.05, 0.25), CF(pos + V3(0, 0.03, (k - 2) * d * 0.15)) * ANG(0, k * 0.7, 0),
					shade(topCol, -0.35), mat("default"))
				crack.CanCollide = false
			end
			tag(pm, "KitCrumble")
		elseif kind == "bounce" then
			local pad = vcyl(pm, 0.6, d * 0.55, CF(pos + V3(0, 0.25, 0)), pal.accent, M.Neon)
			pad.CastShadow = false
			pad.CanCollide = false
			tag(top, "KitBounce", { BouncePower = 85 + diff * 5 })
		elseif kind == "checkpoint" then
			local ring = vcyl(pm, 0.3, d * 0.75, CF(pos + V3(0, 0.05, 0)), pal.secondary, M.Neon)
			ring.CanCollide = false
			ring.CastShadow = false
			WK2.prop("flag", { position = pos + dir * (d * 0.35), parent = pm, color = pal.secondary, height = 8, palette = o.palette })
			tag(top, "KitCheckpoint", { Index = #checkpoints + 1 })
			table.insert(checkpoints, top)
		elseif kind == "static" and i > 0 and i < count and r:NextNumber() < 0.45 then
			local dk = th.decor[r:NextInteger(1, #th.decor)]
			local a = r:NextNumber(0, PI * 2)
			WK2.prop(dk, { position = pos + V3(math.cos(a), 0, math.sin(a)) * d * 0.32, parent = pm, scale = 0.6,
				seed = r:NextInteger(1, 1e6), palette = o.palette })
		end
		if o.coins ~= false and prevTop and kind ~= "spinner" then
			for k = 1, 3 do
				local t = k / 4
				local p = prevTop:Lerp(pos, t) + V3(0, 3 + 3.5 * math.sin(t * PI), 0)
				WK2.prop("coin", { position = p, parent = m, palette = o.palette })
			end
		end
		table.insert(platforms, pm)
		prevR = kind == "spinner" and d * 0.9 or d / 2
		prevTop = pos
	end
	local last = platforms[#platforms]
	WK2.prop("flag", { position = prevTop + V3(0, 0, 0), parent = m, color = pal.gold, height = 14, palette = o.palette })
	local goal = box(m, V3(14, 10, 14), CF(prevTop + V3(0, 5, 0)), pal.gold, M.SmoothPlastic)
	goal.Transparency = 1
	goal.CanCollide = false
	goal.CanQuery = false
	goal.Name = "Goal"
	tag(goal, "KitGoal")
	local _ = last
	local s0 = platforms[1].PrimaryPart.Position
	return { model = m, platforms = platforms, checkpoints = checkpoints, goal = goal,
		start = CF(s0 + V3(0, 3.5, 0), s0 + V3(0, 3.5, 0) + (o.direction or V3(0, 0, -1))) }
end

-- ---------------------------------------------------------------------------------------------------- arena

-- WorldKit2.arena({center, shape="square"|"circle", size=160, wallHeight=14, style="military"|"scifi"|"fantasy"|"toon",
-- cover=true, ramps=true, seed, palette, parent}) -> {model, spawns={CFrame}, center, size}. Cover is laid out in one
-- quadrant and mirrored four ways (fair sightlines); a raised centre platform with ramps holds the high ground.
-- Spawns are invisible parts tagged KitSpawn around the edge, each marked by a glowing pad.
function WK2.arena(o)
	o = o or {}
	local c = o.center or Vector3.zero
	local S = o.size or 160
	local H = o.wallHeight or 14
	local style = o.style or (LookKit.isToon and "toon" or "military")
	local r = Random.new(o.seed or 11)
	local pal = palOf(o)
	local m = Instance.new("Model")
	m.Name = o.name or "Arena"
	m.Parent = o.parent or folder("WorldKit2")
	local circle = o.shape == "circle"
	local floorCol = style == "toon" and pal.ground or (style == "scifi" and pal.floor or pal.path:Lerp(pal.rock, 0.5))
	local floorMat = style == "toon" and mat("ground") or (style == "military" and M.Concrete or mat("floor"))
	if circle then
		vcyl(m, 2, S, CF(c - V3(0, 1, 0)), floorCol, floorMat)
	else
		box(m, V3(S, 2, S), CF(c - V3(0, 1, 0)), floorCol, floorMat)
	end
	local lineCol = style == "scifi" and pal.glow or shade(floorCol, -0.12)
	local lineStep = style == "scifi" and 32 or 16
	for x = -S / 2 + lineStep, S / 2 - lineStep, lineStep do
		for _, axis in ipairs({ "x", "z" }) do
			local half = circle and math.sqrt(math.max(0, (S / 2) ^ 2 - x * x)) or S / 2
			local sz = axis == "x" and V3(0.4, 0.06, half * 2) or V3(half * 2, 0.06, 0.4)
			local p = axis == "x" and V3(x, 0.03, 0) or V3(0, 0.03, x)
			local ln = box(m, sz, CF(c + p), lineCol, style == "scifi" and M.Neon or floorMat)
			ln.CanCollide = false
			ln.CastShadow = false
		end
	end
	local wallCol = style == "toon" and pal.secondary or pal.wall:Lerp(pal.rock, 0.35)
	local capCol = style == "scifi" and pal.glow or (style == "toon" and pal.trim or shade(wallCol, 0.12))
	local function wallSeg(cf, len)
		box(m, V3(len, H, 3), cf * CF(0, H / 2, 0), wallCol, mat("wall"))
		local cap = box(m, V3(len + 0.2, 0.8, 3.6), cf * CF(0, H + 0.4, 0), capCol, style == "scifi" and M.Neon or mat("default"))
		cap.CastShadow = false
	end
	local pillars = {}
	if circle then
		local n = math.max(16, math.floor(PI * S / 14))
		local R = S / 2 + 1.5
		local segLen = 2 * R * math.tan(PI / n) + 0.4
		for i = 0, n - 1 do
			local a = i / n * PI * 2
			local p = c + V3(math.cos(a) * R, 0, math.sin(a) * R)
			wallSeg(CFrame.lookAt(p, c), segLen)
			if i % 4 == 0 then table.insert(pillars, p) end
		end
	else
		for _, sd in ipairs({ { 0, 1 }, { 0, -1 }, { 1, 0 }, { -1, 0 } }) do
			local p = c + V3(sd[1] * (S / 2 + 1.5), 0, sd[2] * (S / 2 + 1.5))
			wallSeg(CFrame.lookAt(p, c), S + 6)
			for k = -2, 2 do
				local along = V3(sd[2], 0, sd[1]) * (k * S / 4)
				table.insert(pillars, p + along)
			end
		end
	end
	for _, p in ipairs(pillars) do
		local pl = box(m, V3(4.5, H + 3, 4.5), CF(p + V3(0, (H + 3) / 2, 0)), shade(wallCol, -0.12), mat("stone"))
		if style == "scifi" or style == "fantasy" then
			local lamp = box(m, V3(2, 1.2, 2), CF(p + V3(0, H + 3.6, 0)), style == "scifi" and pal.glow
				or Color3.fromRGB(255, 150, 60), M.Neon)
			lamp.CastShadow = false
			light(lamp, lamp.Color, 1.6, 30)
		end
		local _ = pl
	end
	-- mirrored cover
	if o.cover ~= false then
		local items = {}
		local nItems = math.floor(S / 36) + 3
		local placed = {}
		for _ = 1, nItems * 6 do
			if #items >= nItems then break end
			local x, z = r:NextNumber(10, S / 2 - 12), r:NextNumber(10, S / 2 - 12)
			if circle and math.sqrt(x * x + z * z) > S / 2 - 12 then continue end
			if math.sqrt(x * x + z * z) < 22 then continue end
			local ok = true
			for _, q in ipairs(placed) do
				if (q - V3(x, 0, z)).Magnitude < 14 then
					ok = false
					break
				end
			end
			if not ok then continue end
			table.insert(placed, V3(x, 0, z))
			local kinds = style == "military" and { "crates", "low_wall", "sandbags", "barrels", "pillar" }
				or (style == "scifi" and { "crates", "low_wall", "pillar", "crates" }
				or { "crates", "low_wall", "barrels", "pillar", "rock" })
			table.insert(items, { kind = kinds[r:NextInteger(1, #kinds)], x = x, z = z, rot = r:NextInteger(0, 1) * 90,
				seed = r:NextInteger(1, 1e6) })
		end
		local crateCol = style == "scifi" and pal.metal or (style == "toon" and pal.accent or nil)
		for _, mir in ipairs({ { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 } }) do
			for _, it in ipairs(items) do
				local p = c + V3(it.x * mir[1], 0, it.z * mir[2])
				local common = { parent = m, palette = o.palette, seed = it.seed, rotation = it.rot }
				local function put(kind, pos, extra)
					local opts = {}
					for k, v in pairs(common) do opts[k] = v end
					for k, v in pairs(extra or {}) do opts[k] = v end
					opts.position = pos
					return WK2.prop(kind, opts)
				end
				if it.kind == "crates" then
					put("crate", p, { color = crateCol })
					put("crate", p + V3(4.2, 0, 0), { color = crateCol })
					put("crate", p + V3(2.1, 4, 0), { color = crateCol, rotation = it.rot + 20 })
				elseif it.kind == "low_wall" then
					put("low_wall", p, { length = 12 })
				elseif it.kind == "sandbags" then
					put("sandbags", p, { length = 10 })
				elseif it.kind == "barrels" then
					put("barrel", p, {})
					put("barrel", p + V3(3.4, 0, 0.6), {})
					put("barrel", p + V3(1.4, 0, 3), {})
				elseif it.kind == "pillar" then
					put("pillar", p, { height = H })
				else
					put("rock", p, { size = 7 })
				end
			end
		end
	end
	-- centre high ground
	if o.ramps ~= false then
		local ph = 6
		box(m, V3(22, ph, 22), CF(c + V3(0, ph / 2, 0)), wallCol, mat("wall"))
		box(m, V3(22.6, 0.6, 22.6), CF(c + V3(0, ph + 0.3, 0)), capCol, style == "scifi" and M.Neon or mat("default"))
		for _, sgn in ipairs({ 1, -1 }) do
			WK2.prop("ramp", { position = c + V3(0, 0, sgn * (11 + 8)), rotation = sgn > 0 and 180 or 0, width = 10, height = ph,
				length = 16, parent = m, palette = o.palette, color = shade(wallCol, 0.1) })
		end
		WK2.prop("crate", { position = c + V3(6, ph + 0.6, 6), parent = m, palette = o.palette })
		WK2.prop("crate", { position = c + V3(-6, ph + 0.6, -6), parent = m, palette = o.palette })
	end
	local spawns = {}
	local n = o.spawns or 8
	for i = 0, n - 1 do
		local a = i / n * PI * 2 + PI / n
		local R = circle and S / 2 - 9 or (S / 2 - 9) / math.max(math.abs(math.cos(a)), math.abs(math.sin(a)))
		R = math.min(R, S / 2 - 9) * (circle and 1 or 1)
		local p = c + V3(math.cos(a) * R, 0, math.sin(a) * R)
		local cf = CFrame.lookAt(p + V3(0, 3, 0), c + V3(0, 3, 0))
		local padp = vcyl(m, 0.2, 6, CF(p + V3(0, 0.1, 0)), pal.glow, M.Neon)
		padp.CanCollide = false
		padp.CastShadow = false
		local sp = box(m, V3(4, 1, 4), cf, pal.glow, M.SmoothPlastic)
		sp.Transparency = 1
		sp.CanCollide = false
		sp.CanQuery = false
		sp.Name = "SpawnPoint" .. (i + 1)
		tag(sp, "KitSpawn", { Index = i + 1 })
		table.insert(spawns, cf)
	end
	return { model = m, spawns = spawns, center = c, size = S }
end

-- ---------------------------------------------------------------------------------------------------- room

local SIDES = {
	north = { n = V3(0, 0, 1), yaw = 0 }, south = { n = V3(0, 0, -1), yaw = 180 },
	east = { n = V3(1, 0, 0), yaw = 90 }, west = { n = V3(-1, 0, 0), yaw = -90 },
}

-- WorldKit2.room({center (floor centre), size=Vector3(40,14,32), theme="kitchen"|"tavern"|"office"|"lab"|"bedroom",
-- doors={"south"}, windows=true, ceiling=false, lights=true, seed, palette, parent}) -> {model, stations={{kind, part,
-- position}}, spawn, floorY, bounds}. Walls with door gaps, wainscot + trim, themed floor, furniture against the
-- walls facing in. Stations (stove, sink, counter, fridge, table, desk, ...) are tagged KitStation for prompts.
-- No ceiling by default so top-down / follow cameras see in.
function WK2.room(o)
	o = o or {}
	local c = o.center or Vector3.zero
	local size = o.size or V3(40, 14, 32)
	local W, H, D = size.X, size.Y, size.Z
	local theme = o.theme or "kitchen"
	local r = Random.new(o.seed or 21)
	local pal = palOf(o)
	local m = Instance.new("Model")
	m.Name = o.name or ("Room_" .. theme)
	m.Parent = o.parent or folder("WorldKit2")
	local doors = {}
	for _, d in ipairs(o.doors or { "south" }) do doors[d] = true end

	-- floor
	if theme == "kitchen" or theme == "lab" then
		local t = theme == "lab" and 8 or 4
		local a = pal.trim
		local b = theme == "lab" and shade(pal.trim, -0.08) or pal.secondary:Lerp(pal.trim, 0.45)
		for ix = 0, math.ceil(W / t) - 1 do
			for iz = 0, math.ceil(D / t) - 1 do
				local tw, td = math.min(t, W - ix * t), math.min(t, D - iz * t)
				box(m, V3(tw, 1, td), CF(c + V3(-W / 2 + ix * t + tw / 2, -0.5, -D / 2 + iz * t + td / 2)),
					(ix + iz) % 2 == 0 and a or b, mat("floor") == M.WoodPlanks and M.SmoothPlastic or mat("default"))
			end
		end
	elseif theme == "office" then
		box(m, V3(W, 1, D), CF(c - V3(0, 0.5, 0)), pal.secondary:Lerp(pal.ink, 0.45), M.Fabric)
	else
		local n = math.ceil(D / 2)
		for i = 0, n - 1 do
			box(m, V3(W, 1, 2), CF(c + V3(0, -0.5, -D / 2 + i * 2 + 1)), jitter(pal.floor, r, 0.04), mat("floor"))
		end
	end

	-- walls
	local wallCol = c3(o.wallColor, theme == "lab" and pal.trim or pal.wall)
	local lowCol = theme == "lab" and pal.secondary:Lerp(pal.trim, 0.5) or (theme == "office" and shade(wallCol, -0.1) or pal.wood)
	for name, sd in pairs(SIDES) do
		local L = (name == "north" or name == "south") and W + 2 or D
		local half = (name == "north" or name == "south") and D / 2 or W / 2
		local base = CF(c + sd.n * (half + 0.5)) * ANG(0, rad(sd.yaw), 0)
		local inward = -sd.n
		local segs
		if doors[name] then
			local dw = 6
			segs = { { -L / 4 - dw / 4, L / 2 - dw / 2 }, { L / 4 + dw / 4, L / 2 - dw / 2 } }
			box(m, V3(dw, H - 8, 1), base * CF(0, 8 + (H - 8) / 2, 0), wallCol, mat("wall"))
			for _, x in ipairs({ -dw / 2 - 0.3, dw / 2 + 0.3 }) do
				box(m, V3(0.6, 8.4, 1.4), base * CF(x, 4.2, 0), pal.trim, mat("default"))
			end
			box(m, V3(dw + 1.2, 0.6, 1.4), base * CF(0, 8.3, 0), pal.trim, mat("default"))
		else
			segs = { { 0, L } }
		end
		for _, sg in ipairs(segs) do
			local x, len = sg[1], sg[2]
			box(m, V3(len, H, 1), base * CF(x, H / 2, 0), wallCol, mat("wall"))
			local inner = base * CF(x, 0, 0) + inward * 0.6
			box(m, V3(len, 3.6, 0.25), inner + V3(0, 1.8, 0), lowCol, theme == "lab" and mat("default") or mat("wood"))
			box(m, V3(len, 0.3, 0.45), inner + V3(0, 3.7, 0), pal.trim, mat("default"))
			box(m, V3(len, 0.6, 0.4), inner + V3(0, 0.3, 0), shade(lowCol, -0.2), mat("default"))
			box(m, V3(len, 0.5, 0.5), inner + V3(0, H - 0.25, 0), pal.trim, mat("default"))
		end
		if not doors[name] and o.windows ~= false and name ~= "north" then
			for _, x in ipairs({ -L / 4, L / 4 }) do
				local wp = (base * CF(x, H * 0.55, 0)).Position + inward * 0.5
				window(m, CFrame.lookAt(wp, wp + inward), 4, 4, pal, false)
			end
		end
	end
	if o.ceiling then
		box(m, V3(W + 2, 1, D + 2), CF(c + V3(0, H + 0.5, 0)), shade(wallCol, 0.1), mat("default"))
	end

	-- furniture
	local function put(kind, x, z, rot, extra)
		local opts = { position = c + V3(x, 0, z), rotation = rot or 0, parent = m, palette = o.palette,
			seed = r:NextInteger(1, 1e6) }
		for k, v in pairs(extra or {}) do opts[k] = v end
		return WK2.prop(kind, opts)
	end
	local zN = D / 2 - 1.6
	local xE = W / 2 - 1.6
	if theme == "kitchen" then
		local run = { "counter", "stove", "counter", "sink", "counter", "stove", "counter" }
		local x = -W / 2 + 2.1
		for _, k in ipairs(run) do
			if x > W / 2 - 7 then break end
			put(k, x, zN, 0)
			if k == "stove" then put("pot", x - 0.9, zN - 0.6, 0, { position = c + V3(x - 0.9, 3.7, zN - 0.6) }) end
			if k == "counter" and r:NextNumber() < 0.6 then
				put("plate", x, zN - 0.3, 0, { position = c + V3(x, 3.56, zN - 0.3), food = pal.accent })
			end
			x += 4.05
		end
		put("fridge", W / 2 - 2.2, zN + 0.1, 0)
		put("shelf", -W / 2 + 1.2, 0, -90, { jars = true, width = 8, height = 7 })
		for i = 0, 2 do
			put("counter", xE, -2 + i * 4.05, 90, { width = 4 })
		end
		put("table", 0, -D * 0.12, 0, { width = 10, depth = 5, cloth = pal.primary })
		for _, x2 in ipairs({ -3, 0, 3 }) do
			put("chair", x2, -D * 0.12 - 3.4, 180)
			put("chair", x2, -D * 0.12 + 3.4, 0)
			put("plate", x2, -D * 0.12 - 1.4, 0, { position = c + V3(x2, 3.42, -D * 0.12 - 1.4) })
			put("plate", x2, -D * 0.12 + 1.4, 0, { position = c + V3(x2, 3.42, -D * 0.12 + 1.4) })
		end
		put("plant", -W / 2 + 2, -D / 2 + 2, 0)
		put("rug", 0, -D / 2 + 3, 0, { width = 8, depth = 3.5, color = pal.primary })
	elseif theme == "tavern" then
		for x = -W / 2 + 3, W / 2 - 4, 4.05 do
			put("counter", x, zN - 5, 0, { color = pal.wood })
		end
		for x = -W / 2 + 3, W / 2 - 3, 4 do
			put("barrel", x, zN, 0, { scale = 0.9 })
		end
		put("fireplace", -W / 2 + 2, 0, -90, { width = 9 })
		put("rug", -W / 2 + 8, 0, 90, { width = 10, depth = 7, color = pal.primary })
		for _, t in ipairs({ { 4, -4 }, { 10, 4 }, { 2, -D / 2 + 6 }, { -4, -D / 2 + 7 } }) do
			if math.abs(t[1]) < W / 2 - 5 then
				put("table", t[1], t[2], 0, { round = true, width = 5, cloth = r:NextNumber() < 0.5 and pal.fabric or nil })
				for k = 0, 3 do
					local a = k / 4 * PI * 2 + PI / 4
					put("chair", t[1] + math.cos(a) * 3.6, t[2] + math.sin(a) * 3.6, 90 - math.deg(a))
				end
			end
		end
		put("shelf", xE, 4, 90, { jars = true })
	elseif theme == "office" then
		for ix = -1, 1 do
			for iz = 0, 1 do
				local x, z = ix * (W / 3.2), -D * 0.18 + iz * 10
				put("desk", x, z, 0)
				put("chair", x - 0.4, z - 2.8, 180, { color = pal.ink:Lerp(pal.metal, 0.3) })
			end
		end
		put("bookshelf", -W / 4, zN - 0.3, 0, { width = 8, height = 8 })
		put("bookshelf", W / 4, zN - 0.3, 0, { width = 8, height = 8 })
		for _, cc in ipairs({ { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } }) do
			put("plant", cc[1] * (W / 2 - 2), cc[2] * (D / 2 - 2), 0)
		end
	elseif theme == "lab" then
		for x = -W / 2 + 4, W / 2 - 4, 6.2 do
			put("lab_bench", x, zN, 0, { width = 6 })
		end
		for z = -D / 2 + 5, D / 2 - 8, 6.2 do
			put("lab_bench", xE, z, 90, { width = 6 })
		end
		put("lab_bench", 0, -2, 0, { width = 8 })
		put("lab_bench", 0, 1.2, 180, { width = 8 })
		put("shelf", -W / 2 + 1.2, 0, -90, { jars = true, width = 10 })
		put("crystal", -W / 4, -D / 2 + 5, 0, { height = 3, color = pal.secondary })
	else -- bedroom
		put("bed", -W / 6, D / 2 - 4.2, 0)
		put("rug", -W / 6, -1, 0, { round = true, width = 10, color = pal.primary })
		put("desk", xE - 0.2, -D / 6, 90)
		put("chair", xE - 3.4, -D / 6, -90)
		put("bookshelf", -W / 2 + 1.2, -D / 6, -90, { width = 7, height = 8 })
		put("plant", W / 2 - 2, D / 2 - 2, 0)
		put("table", -W / 6 + 4.5, D / 2 - 2.2, 0, { width = 2.4, depth = 2.4 })
		put("chest", W / 6, D / 2 - 2.5, 0, { size = 3.6 })
	end

	-- lights: warm fill + sconces (or pendants when there is a ceiling)
	if o.lights ~= false then
		local warm = pal.glow:Lerp(Color3.new(1, 1, 1), 0.35)
		local fill = box(m, V3(1, 1, 1), CF(c + V3(0, H - 2, 0)), warm, M.SmoothPlastic)
		fill.Transparency = 1
		fill.CanCollide = false
		fill.CanQuery = false
		light(fill, warm, 0.9, math.max(W, D) * 0.9)
		for _, x in ipairs({ -W / 4, W / 4 }) do
			if o.ceiling then
				vcyl(m, 3, 0.15, CF(c + V3(x, H - 1.5, 0)), pal.ink, mat("default"))
				blob(m, V3(3, 1.6, 3), CF(c + V3(x, H - 3.3, 0)), pal.primary, mat("default"))
				local bulb = ball(m, 1, CF(c + V3(x, H - 4, 0)), warm, M.Neon)
				light(bulb, warm, 1.2, 22)
			else
				local wp = c + V3(x, H * 0.62, D / 2 - 0.4)
				box(m, V3(1.2, 1.6, 0.5), CF(wp), pal.metal, mat("metal"))
				local bulb = box(m, V3(1, 1, 0.6), CF(wp - V3(0, 0, 0.4)), warm, M.Neon)
				bulb.CastShadow = false
				light(bulb, warm, 1.2, 20)
			end
		end
	end

	local stations = {}
	for _, d in ipairs(m:GetDescendants()) do
		if d:IsA("BasePart") and CollectionService:HasTag(d, "KitStation") then
			table.insert(stations, { kind = d:GetAttribute("Station"), part = d, position = d.Position })
		end
	end
	return { model = m, stations = stations, spawn = c + V3(0, 3, -D / 2 + 4), floorY = c.Y,
		bounds = { center = c, size = size } }
end
WK2.interior = WK2.room

-- ---------------------------------------------------------------------------------------------------- town

-- WorldKit2.town({center, blocks=3 (n x n), blockSize=56, street=16, style="suburb"|"city"|"neon"|"medieval"|"western",
-- seed, palette, parent}) -> {model, blocks={Vector3}, intersections={Vector3}, spawn}. Street grid with sidewalks,
-- lane dashes and streetlights; each block holds four lots whose buildings face the street.
function WK2.town(o)
	o = o or {}
	local c = o.center or Vector3.zero
	local n = o.blocks or 3
	local B, St = o.blockSize or 56, o.street or 16
	local style = o.style or "suburb"
	local r = Random.new(o.seed or 31)
	local pal = palOf(o)
	local m = Instance.new("Model")
	m.Name = o.name or ("Town_" .. style)
	m.Parent = o.parent or folder("WorldKit2")
	local total = n * B + (n + 1) * St
	local x0, z0 = c.X - total / 2, c.Z - total / 2
	local roadCol, roadMat = pal.ink:Lerp(pal.metal, 0.25), mat("road")
	if style == "medieval" then
		roadCol, roadMat = pal.path:Lerp(pal.rock, 0.4), M.Cobblestone
	elseif style == "western" then
		roadCol, roadMat = pal.sand:Lerp(pal.dirt, 0.3), M.Sand
	end
	local intersections = {}
	for i = 0, n do
		local p = i * (B + St) + St / 2
		box(m, V3(St, 1, total), CF(x0 + p, c.Y - 0.5, c.Z), roadCol, roadMat)
		box(m, V3(total, 1, St), CF(c.X, c.Y - 0.5, z0 + p), roadCol, roadMat)
		for j = 0, n do
			table.insert(intersections, V3(x0 + p, c.Y, z0 + j * (B + St) + St / 2))
		end
		if style ~= "medieval" and style ~= "western" then
			for k = 0, math.floor(total / 10) - 1 do
				local q = -total / 2 + k * 10 + 5
				if (k % 2) == 0 then
					local d1 = box(m, V3(0.5, 0.05, 4), CF(x0 + p, c.Y + 0.02, c.Z + q), pal.accent, mat("default"))
					local d2 = box(m, V3(4, 0.05, 0.5), CF(c.X + q, c.Y + 0.02, z0 + p), pal.accent, mat("default"))
					d1.CanCollide = false
					d2.CanCollide = false
				end
			end
		end
	end
	local blocks = {}
	local walkCol = style == "western" and pal.wood or pal.path:Lerp(pal.trim, 0.3)
	for bi = 0, n - 1 do
		for bj = 0, n - 1 do
			local bc = V3(x0 + St + bi * (B + St) + B / 2, c.Y, z0 + St + bj * (B + St) + B / 2)
			table.insert(blocks, bc)
			box(m, V3(B, 1, B), CF(bc - V3(0, 0.25, 0)), walkCol, style == "western" and mat("wood") or M.Concrete)
			if style == "suburb" or style == "medieval" then
				box(m, V3(B - 5, 1, B - 5), CF(bc - V3(0, 0.15, 0)), pal.ground, mat("ground"))
			end
			for _, lot in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
				local lp = bc + V3(lot[1] * B / 4, 0.35, lot[2] * B / 4)
				local facesX = r:NextNumber() < 0.5
				local rot = facesX and (lot[1] > 0 and -90 or 90) or (lot[2] > 0 and 180 or 0)
				local seed = r:NextInteger(1, 1e6)
				local common = { position = lp, rotation = rot, parent = m, palette = o.palette, seed = seed }
				local function put(kind, extra)
					local opts = {}
					for k, v in pairs(common) do opts[k] = v end
					for k, v in pairs(extra or {}) do opts[k] = v end
					return WK2.prop(kind, opts)
				end
				if style == "suburb" then
					put("house", { width = B * 0.32, depth = B * 0.26, floors = r:NextInteger(1, 2),
						roof = ({ pal.roof, pal.secondary, pal.primary })[r:NextInteger(1, 3)] })
					local tp = lp + V3(-lot[1] * B * 0.17, 0, -lot[2] * B * 0.17)
					WK2.prop("round_tree", { position = tp, parent = m, seed = seed + 1, palette = o.palette, scale = 0.9 })
				elseif style == "medieval" then
					put("house", { width = B * 0.3, depth = B * 0.24, floors = r:NextInteger(1, 2), lit = true,
						color = pal.wall:Lerp(pal.wood, r:NextNumber(0, 0.4)) })
				elseif style == "western" then
					put("shop", { width = B * 0.36, depth = B * 0.3, height = r:NextNumber(9, 13),
						color = pal.wood:Lerp(pal.wall, r:NextNumber(0.2, 0.7)), accent = pal.primary })
					WK2.prop("barrel", { position = lp + V3(lot[1] * 4, 0, -lot[2] * B * 0.2), parent = m, palette = o.palette })
				elseif style == "neon" then
					if r:NextNumber() < 0.75 then
						put("tower", { style = "neon", height = r:NextNumber(30, 80), width = B * 0.36 })
					else
						put("shop", { width = B * 0.36, depth = B * 0.3, lit = true, accent = pal.primary })
					end
				else -- city
					if r:NextNumber() < 0.55 then
						put("skyscraper", { height = r:NextNumber(30, 70), width = B * 0.36 })
					else
						put("shop", { width = B * 0.36, depth = B * 0.3, accent = ({ pal.primary, pal.secondary, pal.accent })[r:NextInteger(1, 3)] })
					end
				end
			end
		end
	end
	for _, ip in ipairs(intersections) do
		local corner = ip + V3(St / 2 + 1, 0.35, St / 2 + 1)
		if math.abs(corner.X - c.X) < total / 2 - 2 and math.abs(corner.Z - c.Z) < total / 2 - 2 then
			if style == "medieval" then
				WK2.prop("lamp", { position = corner, parent = m, palette = o.palette, height = 8 })
			elseif style ~= "western" then
				WK2.prop("streetlight", { position = corner, rotation = 45, parent = m, palette = o.palette,
					color = style == "neon" and pal.secondary or nil })
			end
		end
	end
	return { model = m, blocks = blocks, intersections = intersections, spawn = intersections[1] + V3(0, 4, 0) }
end

-- ---------------------------------------------------------------------------------------------------- dungeon

-- WorldKit2.dungeon({center, rooms=8, cell=8, roomCells={2,4}, height=12, torches=true, seed, palette, parent}) ->
-- {model, rooms={{center, size}}, start=Vector3, finish=Vector3}. Rooms on a grid joined by L corridors; floors per
-- room, walls only on open edges; pillars in big rooms, torches, crates/barrels; a chest + gem in the final room
-- (tagged KitGoal). Open-topped for third-person/top-down cameras.
function WK2.dungeon(o)
	o = o or {}
	local c = o.center or Vector3.zero
	local cell = o.cell or 8
	local H = o.height or 12
	local r = Random.new(o.seed or 41)
	local pal = palOf(o)
	local m = Instance.new("Model")
	m.Name = o.name or "Dungeon"
	m.Parent = o.parent or folder("WorldKit2")
	local rc = o.roomCells or { 2, 4 }
	local occ = {}
	local function key(x, z) return x .. "," .. z end
	local rooms = {}
	local function overlaps(x, z, w, h)
		for _, rm in ipairs(rooms) do
			if x - 1 < rm.x + rm.w and x + w + 1 > rm.x and z - 1 < rm.z + rm.h and z + h + 1 > rm.z then
				return true
			end
		end
		return false
	end
	local dirs = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
	for i = 1, o.rooms or 8 do
		local w, h = r:NextInteger(rc[1], rc[2]), r:NextInteger(rc[1], rc[2])
		if i == 1 then
			table.insert(rooms, { x = -math.floor(w / 2), z = -math.floor(h / 2), w = w, h = h })
		else
			local prev = rooms[#rooms]
			local placedRoom = false
			for _ = 1, 12 do
				local d = dirs[r:NextInteger(1, 4)]
				local gap = r:NextInteger(2, 4)
				local x = d[1] == 0 and prev.x + r:NextInteger(-1, 1) or (d[1] > 0 and prev.x + prev.w + gap or prev.x - gap - w)
				local z = d[2] == 0 and prev.z + r:NextInteger(-1, 1) or (d[2] > 0 and prev.z + prev.h + gap or prev.z - gap - h)
				if not overlaps(x, z, w, h) then
					table.insert(rooms, { x = x, z = z, w = w, h = h })
					placedRoom = true
					break
				end
			end
			if not placedRoom then break end
		end
	end
	for _, rm in ipairs(rooms) do
		for x = rm.x, rm.x + rm.w - 1 do
			for z = rm.z, rm.z + rm.h - 1 do
				occ[key(x, z)] = "room"
			end
		end
	end
	local corridorCells = {}
	for i = 2, #rooms do
		local a, b = rooms[i - 1], rooms[i]
		local ax, az = a.x + math.floor(a.w / 2), a.z + math.floor(a.h / 2)
		local bx, bz = b.x + math.floor(b.w / 2), b.z + math.floor(b.h / 2)
		local x, z = ax, az
		while x ~= bx do
			x += (bx > x) and 1 or -1
			if not occ[key(x, z)] then occ[key(x, z)] = "corr"; table.insert(corridorCells, { x, z }) end
		end
		while z ~= bz do
			z += (bz > z) and 1 or -1
			if not occ[key(x, z)] then occ[key(x, z)] = "corr"; table.insert(corridorCells, { x, z }) end
		end
	end
	local function world(gx, gz)
		return c + V3(gx * cell, 0, gz * cell)
	end
	local floorCol = pal.floor:Lerp(pal.rock, 0.5)
	local wallCol = pal.wall:Lerp(pal.rock, 0.3)
	local out = {}
	for _, rm in ipairs(rooms) do
		local ctr = world(rm.x + (rm.w - 1) / 2, rm.z + (rm.h - 1) / 2)
		box(m, V3(rm.w * cell, 1, rm.h * cell), CF(ctr - V3(0, 0.5, 0)), floorCol, mat("floor"))
		table.insert(out, { center = ctr, size = V3(rm.w * cell, H, rm.h * cell) })
	end
	for _, cc in ipairs(corridorCells) do
		box(m, V3(cell, 1, cell), CF(world(cc[1], cc[2]) - V3(0, 0.5, 0)), shade(floorCol, -0.08), mat("floor"))
	end
	local wallSegs = {}
	for k in pairs(occ) do
		local gx, gz = string.match(k, "(-?%d+),(-?%d+)")
		local x, z = tonumber(gx), tonumber(gz)
		for _, d in ipairs(dirs) do
			if not occ[key(x + d[1], z + d[2])] then
				local p = world(x, z) + V3(d[1], 0, d[2]) * (cell / 2 + 0.75)
				local sz = d[1] ~= 0 and V3(1.5, H, cell + 1.5) or V3(cell + 1.5, H, 1.5)
				box(m, sz, CF(p + V3(0, H / 2, 0)), jitter(wallCol, r, 0.03), mat("wall"))
				box(m, sz * V3(1, 0, 1) + V3(0.3, 0.6, 0.3), CF(p + V3(0, H + 0.3, 0)), shade(wallCol, -0.15), mat("stone"))
				table.insert(wallSegs, { p = p, inward = -V3(d[1], 0, d[2]) })
			end
		end
	end
	if o.torches ~= false then
		for i, ws in ipairs(wallSegs) do
			if i % 5 == 0 then
				local tp = ws.p + ws.inward * 1.2 + V3(0, H * 0.35, 0)
				WK2.prop("torch", { position = tp, parent = m, scale = 0.6, palette = o.palette })
			end
		end
	end
	for i, rm in ipairs(rooms) do
		local info = out[i]
		if rm.w >= 3 and rm.h >= 3 then
			for _, cc in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
				WK2.prop("pillar", { position = info.center + V3(cc[1] * (info.size.X / 2 - cell * 0.75), 0,
					cc[2] * (info.size.Z / 2 - cell * 0.75)), height = H, parent = m, palette = o.palette, color = wallCol })
			end
		end
		if i > 1 and i < #rooms then
			for _ = 1, r:NextInteger(1, 3) do
				local p = info.center + V3(r:NextNumber(-0.35, 0.35) * info.size.X, 0, r:NextNumber(-0.35, 0.35) * info.size.Z)
				WK2.prop(r:NextNumber() < 0.5 and "crate" or "barrel", { position = p, parent = m, palette = o.palette,
					seed = r:NextInteger(1, 1e6), rotation = r:NextNumber(0, 90) })
			end
			if info.size.X >= cell * 3 then
				WK2.prop("rug", { position = info.center, parent = m, width = info.size.X * 0.5, depth = info.size.Z * 0.4,
					palette = o.palette, color = pal.primary })
			end
		end
	end
	local finish = out[#out].center
	WK2.prop("chest", { position = finish, parent = m, palette = o.palette, size = 5 })
	local gem = WK2.prop("gem", { position = finish + V3(0, 6, 0), parent = m, palette = o.palette, size = 2.4 })
	tag(gem.PrimaryPart, "KitGoal")
	return { model = m, rooms = out, start = out[1].center + V3(0, 3, 0), finish = finish }
end

-- ---------------------------------------------------------------------------------------------------- animate

local animConn
-- WorldKit2.animate({movers=true, spinners=true, crumble=true, bounce=true, coins=false}) runs the gameplay hooks:
-- KitMover models swing by MoveOffset over MovePeriod, KitSpinner models turn at SpinSpeed (rad/s) - both set
-- AssemblyLinearVelocity/AngularVelocity so standing players ride along; KitCrumble drops 0.6 s after a player lands
-- and returns after 3 s; KitBounce launches with BouncePower. Characters are client-owned: also call
-- WorldKit2.animate({movers=false, spinners=false, crumble=false}) from a LocalScript so bounce pads launch.
-- coins=true spins KitCoin/KitGem (do that on the client too, not the server). Call once per side; returns a stop fn.
function WK2.animate(o)
	o = o or {}
	if animConn then
		animConn:Disconnect()
	end
	local t0 = os.clock()
	local origins = {}
	local touched = {}
	local function originOf(inst)
		local cf = origins[inst]
		if not cf then
			cf = inst:IsA("Model") and inst:GetPivot() or inst.CFrame
			origins[inst] = cf
		end
		return cf
	end
	local function mainPart(inst)
		return inst:IsA("Model") and inst.PrimaryPart or inst
	end
	local function charOf(hit)
		local model = hit:FindFirstAncestorOfClass("Model")
		if model and model:FindFirstChildOfClass("Humanoid") then
			return model
		end
		return nil
	end
	local function hook(tagName, fn)
		local function attach(inst)
			local parts = inst:IsA("BasePart") and { inst } or {}
			if inst:IsA("Model") then
				for _, d in ipairs(inst:GetDescendants()) do
					if d:IsA("BasePart") and d.CanCollide then table.insert(parts, d) end
				end
			end
			for _, p in ipairs(parts) do
				if not touched[p] then
					touched[p] = true
					p.Touched:Connect(function(hit) fn(inst, hit) end)
				end
			end
		end
		for _, inst in ipairs(CollectionService:GetTagged(tagName)) do attach(inst) end
		CollectionService:GetInstanceAddedSignal(tagName):Connect(attach)
	end
	if o.crumble ~= false then
		local busy = {}
		hook("KitCrumble", function(inst, hit)
			if busy[inst] or not charOf(hit) then return end
			busy[inst] = true
			task.delay(0.6, function()
				local saved = {}
				for _, d in ipairs(inst:GetDescendants()) do
					if d:IsA("BasePart") then
						saved[d] = { d.Transparency, d.CanCollide }
						d.Transparency = 0.85
						d.CanCollide = false
					end
				end
				task.wait(3)
				for d, s in pairs(saved) do
					d.Transparency = s[1]
					d.CanCollide = s[2]
				end
				busy[inst] = nil
			end)
		end)
	end
	if o.bounce ~= false then
		local cool = {}
		hook("KitBounce", function(inst, hit)
			local ch = charOf(hit)
			if not ch then return end
			if RunService:IsClient() then
				local lp = Players.LocalPlayer
				if not lp or lp.Character ~= ch then return end
			end
			local root = ch:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") and (cool[ch] or 0) < os.clock() then
				cool[ch] = os.clock() + 0.4
				local v = root.AssemblyLinearVelocity
				root.AssemblyLinearVelocity = V3(v.X, inst:GetAttribute("BouncePower") or 90, v.Z)
			end
		end)
	end
	animConn = RunService.Heartbeat:Connect(function()
		local t = os.clock() - t0
		if o.movers ~= false then
			for _, inst in ipairs(CollectionService:GetTagged("KitMover")) do
				if inst:IsDescendantOf(Workspace) then
					local off = inst:GetAttribute("MoveOffset") or V3(0, 0, 10)
					local per = inst:GetAttribute("MovePeriod") or 4
					local w = 2 * PI / per
					local cf = originOf(inst) + off * math.sin(t * w)
					if inst:IsA("Model") then inst:PivotTo(cf) else inst.CFrame = cf end
					local mp = mainPart(inst)
					if mp then mp.AssemblyLinearVelocity = off * w * math.cos(t * w) end
				end
			end
		end
		if o.spinners ~= false then
			for _, inst in ipairs(CollectionService:GetTagged("KitSpinner")) do
				if inst:IsDescendantOf(Workspace) then
					local sp = inst:GetAttribute("SpinSpeed") or 1
					local cf = originOf(inst) * ANG(0, t * sp, 0)
					if inst:IsA("Model") then
						inst:PivotTo(cf)
						for _, d in ipairs(inst:GetDescendants()) do
							if d:IsA("BasePart") then d.AssemblyAngularVelocity = V3(0, sp, 0) end
						end
					else
						inst.CFrame = cf
						inst.AssemblyAngularVelocity = V3(0, sp, 0)
					end
				end
			end
		end
		if o.coins then
			for _, tg in ipairs({ "KitCoin", "KitGem" }) do
				for _, p in ipairs(CollectionService:GetTagged(tg)) do
					local mdl = p:FindFirstAncestorOfClass("Model")
					if mdl and mdl.PrimaryPart == p then
						local base = originOf(mdl)
						mdl:PivotTo(base * CF(0, math.sin(t * 2) * 0.4, 0) * ANG(0, t * 2.5, 0))
					end
				end
			end
		end
	end)
	return function()
		if animConn then
			animConn:Disconnect()
			animConn = nil
		end
	end
end

return WK2
