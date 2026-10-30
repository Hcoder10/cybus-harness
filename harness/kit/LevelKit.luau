--!nonstrict
-- LevelKit: one call builds a complete, dressed, gameplay-ready level from the other kits, so a game starts from a
-- crafted world instead of a pile of kit pieces. Server or edit mode; deterministic for a seed.
--
--   local info = LevelKit.build("sky_islands", {look = "toon_bright", seed = 7})
--
-- Live lesson that made this exist (Starbloom): a builder composed WorldKit islands itself and got islands in a
-- straight line, a garish orange grade, the player spawned on water beside a floating island and props clumped in
-- the middle. Every piece was fine; the LAYOUT was the problem. LevelKit owns the layout: a hub the player spawns ON,
-- further islands rising in an arc around it, jumpable stepping paths between them, dressing in clusters at the rims
-- (never on the paths or the spawn), and every gameplay spot tagged and returned.
--
-- Tags (CollectionService) + attributes on what it builds:
--   KitCheckpoint (Index)  one pad per island (hub = 1, at the spawn)
--   KitCoin (Value)        coins arcing over every jump and ringing the goal pedestals
--   KitGoal (Island, Final) a star per island; Final=true on the crown island's star
--   KitHazard (Damage)     thorn patches (touch parts, CanCollide off): GameplayKit Hazard.kill/zone them
--   KitMover / KitCrumble  stepping platforms at difficulty >= 2 / >= 3: run WorldKit2.animate() at runtime

local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")

local Kit = script.Parent
local LookKit = require(Kit:WaitForChild("LookKit"))
local WK2 = require(Kit:WaitForChild("WorldKit2"))

local LevelKit = {}
LevelKit.kinds = { "sky_islands", "meadow_course", "arena", "town" }

local V3 = Vector3.new
local CF = CFrame.new
local M = Enum.Material
local PI = math.pi
local FLAT = V3(1, 0, 1)
local T = Workspace.Terrain
local H = WK2._helpers

-- per look: terrain materials (top / band / body) and dressing (trees in rim clusters, small props around them)
local DRESS = {
	toon_bright = { top = M.Grass, band = M.Ground, body = M.Rock,
		trees = { { "round_tree", 4 }, { "blossom", 1 }, { "pine", 1 } },
		small = { { "bush", 3 }, { "flowers", 4 }, { "mushroom", 1 }, { "rock", 1 } } },
	cozy = { top = M.Grass, band = M.Ground, body = M.Rock,
		trees = { { "round_tree", 3 }, { "blossom", 2 } },
		small = { { "bush", 3 }, { "flowers", 5 }, { "mushroom", 1 } }, lanterns = true },
	candy = { top = M.Grass, band = M.Ground, body = M.Rock,
		trees = { { "lollipop", 3 }, { "blossom", 2 }, { "candy_cane", 2 } },
		small = { { "gumdrop", 3 }, { "flowers", 3 }, { "mushroom", 1 } } },
	realistic = { top = M.Grass, band = M.Ground, body = M.Rock,
		trees = { { "pine", 3 }, { "round_tree", 2 } },
		small = { { "rock", 2, { moss = true } }, { "bush", 3 }, { "grass", 3 } } },
	snow = { top = M.Snow, band = M.Rock, body = M.Slate,
		trees = { { "pine", 4, { snow = true } } },
		small = { { "rock", 2 }, { "snowman", 1 }, { "bush", 1 } } },
	desert = { top = M.Sand, band = M.Sandstone, body = M.Sandstone,
		trees = { { "palm", 2 }, { "cactus", 3 } },
		small = { { "rock", 3 }, { "bush", 1 } } },
	dark_fantasy = { top = M.Grass, band = M.Ground, body = M.Slate,
		trees = { { "dead_tree", 3 }, { "pine", 2 } },
		small = { { "rock", 3, { moss = true } }, { "mushroom", 2 }, { "crystal", 1 } }, lanterns = true },
	neon_night = { top = M.Grass, band = M.Rock, body = M.Basalt,
		trees = { { "crystal", 3, { height = 9 } }, { "palm", 1 } },
		small = { { "crystal", 2 }, { "rock", 1 } }, lanterns = true },
	space = { top = M.Basalt, band = M.Rock, body = M.Basalt,
		trees = { { "crystal", 3, { height = 10 } } },
		small = { { "rock", 3 }, { "crystal", 2 } }, lanterns = true, noWater = true },
}

local function tag(inst, t, attrs)
	CollectionService:AddTag(inst, t)
	for k, v in pairs(attrs or {}) do
		inst:SetAttribute(k, v)
	end
	return inst
end

local function folder(name, parent)
	local f = Instance.new("Folder")
	f.Name = name
	f.Parent = parent
	return f
end

local function pick(r, list)
	local total = 0
	for _, k in ipairs(list) do total += k[2] or 1 end
	local x = r:NextNumber(0, total)
	for _, k in ipairs(list) do
		x -= k[2] or 1
		if x <= 0 then return k end
	end
	return list[1]
end

local function o_or(v, d)
	if v == nil then return d end
	return v
end

local function angleOf(v)
	return math.atan2(v.Z, v.X)
end

local function angDist(a, b)
	local d = (a - b) % (2 * PI)
	return math.min(d, 2 * PI - d)
end

-- ---------------------------------------------------------------------------------------------------- terrain

-- A sky island: a flat walkable grass top at y = pos.Y (radius r), a soil band, and a rock body tapering to a point.
-- Low rim hills only away from the exits, so paths always leave from flat ground.
local function skyIsland(L, pos, r, exits, floating)
	local d, rr = L.dress, L.r
	T:FillCylinder(CF(pos - V3(0, 2.5, 0)), 5, r, d.top)
	T:FillCylinder(CF(pos - V3(0, 7.5, 0)), 6, r * 0.97, d.band)
	if floating then
		-- every ball's top stays under the soil band (live, first try: rock domes rose 20 studs over the grass top
		-- and the player spawned on a boulder)
		local y = pos.Y - 6
		for k = 1, 5 do
			local lr = r * (0.95 - k * 0.15)
			for _ = 1, 3 do
				local off = V3(rr:NextNumber(-0.2, 0.2) * lr, 0, rr:NextNumber(-0.2, 0.2) * lr)
				local br = lr * rr:NextNumber(0.75, 0.95)
				T:FillBall(V3(pos.X, math.min(y - lr * 0.5, pos.Y - 6 - br), pos.Z) + off, br, d.body)
			end
			y -= lr * 0.75
		end
		for _ = 1, 3 do -- hanging rocks under the rim give the silhouette some bite
			local a = rr:NextNumber(0, 2 * PI)
			local p = pos + V3(math.cos(a) * r * 0.6, -17 - rr:NextNumber(0, r * 0.25), math.sin(a) * r * 0.6)
			T:FillBall(p, r * rr:NextNumber(0.14, 0.22), d.body)
		end
	else
		-- a plateau rising from the valley floor (y = L.floorY): wider at the foot, cliff sides
		local h = pos.Y - 10 - L.floorY
		if h > 0 then
			T:FillCylinder(CF(pos.X, L.floorY + h / 2 - 2, pos.Z), h + 4, r * 0.98, d.body)
			T:FillCylinder(CF(pos.X, L.floorY + h * 0.2, pos.Z), h * 0.4 + 4, r * 1.12, d.body)
		end
	end
	for _ = 1, 3 do
		local a = rr:NextNumber(0, 2 * PI)
		local ok = true
		for _, e in ipairs(exits) do
			if angDist(a, e) < 0.9 then ok = false end
		end
		if ok then
			local R = r * rr:NextNumber(0.2, 0.28)
			T:FillBall(pos + V3(math.cos(a) * r * 0.74, -R * 0.62, math.sin(a) * r * 0.74), R, d.top)
		end
	end
end

local function ground(L, x, z, near)
	local hit, mat = WK2.groundAt(x, z, { top = (near or 300) + 60, bottom = (near or 0) - 80 })
	if hit and mat ~= M.Water and (not near or math.abs(hit.Y - near) < 7) then
		return hit
	end
	-- Terrain filled a moment ago is not always raycastable yet (live, first build of a place: every island came out
	-- bare). The island tops are flat at `near` by construction, so stand there.
	if near and not hit then
		return V3(x, near, z)
	end
	return nil
end

-- ---------------------------------------------------------------------------------------------------- pieces

local function prop(L, kind, pos, o)
	o = o or {}
	o.position = pos
	o.rotation = o.rotation or L.r:NextNumber(0, 360)
	o.seed = o.seed or L.r:NextInteger(1, 1e6)
	o.parent = o.parent or L.dressF
	o.palette = o.palette or L.o.palette
	return WK2.prop(kind, o)
end

local function cloud(L, pos, s)
	local m = Instance.new("Model")
	m.Name = "Cloud"
	local white = Color3.new(1, 1, 1):Lerp(L.pal.sky, 0.12)
	for i = 1, 5 do
		local a = i / 5 * 2 * PI + L.r:NextNumber(-0.3, 0.3)
		local ss = s * L.r:NextNumber(0.45, 0.7)
		local p = H.blob(m, V3(ss * 1.4, ss * 0.7, ss), CF(pos + V3(math.cos(a) * s * 0.45, L.r:NextNumber(-0.1, 0.25) * s,
			math.sin(a) * s * 0.3)), i % 2 == 0 and white or white:Lerp(Color3.new(1, 1, 1), 0.5), M.SmoothPlastic)
		p.CanCollide = false
		p.CanQuery = false
		p.CastShadow = false
	end
	m.Parent = L.decoF
	return m
end

-- a gold star (goal) floating over a small pedestal; the star's core is the touch part tagged KitGoal
local function star(L, pos, index, final)
	local m = Instance.new("Model")
	m.Name = final and "CrownStar" or ("Star" .. index)
	local pal = L.pal
	local s = final and 1.6 or 1
	H.vcyl(m, 1.2, 6 * s, CF(pos + V3(0, 0.6, 0)), pal.trim, LookKit.mat("stone"))
	H.vcyl(m, 0.4, 7 * s, CF(pos + V3(0, 0.2, 0)), pal.gold, LookKit.mat("default"))
	local c = pos + V3(0, 5 * s, 0)
	local core = H.ball(m, 2.2 * s, CF(c), pal.gold, M.Neon)
	for k = 0, 4 do
		local arm = H.wedge(m, V3(0.9 * s, 2.6 * s, 1.4 * s), CF(c) * CFrame.Angles(0, 0, k * 2 * PI / 5) * CF(0, 1.9 * s, 0),
			pal.gold, M.Neon)
		arm.CanCollide = false
		local arm2 = H.wedge(m, V3(0.9 * s, 2.6 * s, 1.4 * s), CF(c) * CFrame.Angles(0, PI, -k * 2 * PI / 5) * CF(0, 1.9 * s, 0),
			pal.gold, M.Neon)
		arm2.CanCollide = false
	end
	core.CanCollide = false
	core.CanTouch = true
	H.light(core, pal.gold, 2, 18)
	m.PrimaryPart = core
	tag(core, "KitGoal", { Island = index, Final = final == true })
	m.Parent = L.playF
	return core
end

local function checkpoint(L, pos, index)
	local m = Instance.new("Model")
	m.Name = "Checkpoint" .. index
	local pad = H.vcyl(m, 0.6, 9, CF(pos + V3(0, 0.1, 0)), L.pal.trim, LookKit.mat("stone"))
	local ring = H.vcyl(m, 0.3, 7.4, CF(pos + V3(0, 0.45, 0)), L.pal.secondary, M.Neon)
	ring.CanCollide = false
	ring.CastShadow = false
	m.PrimaryPart = pad
	tag(pad, "KitCheckpoint", { Index = index })
	m.Parent = L.playF
	WK2.prop("flag", { position = pos + V3(5, 0, 0), color = L.pal.secondary, height = 9, parent = m, palette = L.o.palette })
	table.insert(L.info.checkpoints, pos + V3(0, 3, 0))
	return pad
end

local function thorns(L, pos, radius)
	local m = Instance.new("Model")
	m.Name = "Thorns"
	local base = H.vcyl(m, 0.5, radius * 2, CF(pos + V3(0, 0.05, 0)), L.pal.woodDark, LookKit.mat("ground"))
	base.CanCollide = false
	for _ = 1, math.floor(radius * 2.2) do
		local a, d = L.r:NextNumber(0, 2 * PI), L.r:NextNumber(0, radius * 0.85)
		local h = L.r:NextNumber(1.6, 3)
		local spike = H.wedge(m, V3(0.7, h, 0.7), CF(pos + V3(math.cos(a) * d, h / 2, math.sin(a) * d))
			* CFrame.Angles(L.r:NextNumber(-0.25, 0.25), L.r:NextNumber(0, 2 * PI), 0), L.pal.danger, LookKit.mat("default"))
		spike.CanCollide = false
	end
	local hit = H.box(m, V3(radius * 2, 3, radius * 2), CF(pos + V3(0, 1.5, 0)), L.pal.danger, M.SmoothPlastic)
	hit.Transparency = 1
	hit.CanCollide = false
	hit.Name = "HazardZone"
	tag(hit, "KitHazard", { Damage = 25 })
	m.Parent = L.playF
	table.insert(L.info.hazards, { kind = "thorns", part = hit, position = pos, radius = radius })
	return hit
end

local function coin(L, pos)
	WK2.prop("coin", { position = pos, parent = L.coinF, palette = L.o.palette })
	table.insert(L.info.collectibles, pos)
end

-- Stepping platforms from island a's rim to island b's rim, bowed sideways so the path arcs. Gaps and rises are
-- player-scale (never scaled with the level): edge gaps 4..8 studs by difficulty, rises <= 3.5.
local function steps(L, a, b, bow)
	local pal, diff, r = L.pal, L.diff, L.r
	local dir = ((b.center - a.center) * FLAT).Unit
	local side = dir:Cross(V3(0, 1, 0))
	local p0 = a.center + dir * (a.radius - 1)
	local p1 = b.center - dir * (b.radius - 1)
	p0 = V3(p0.X, a.top.Y, p0.Z)
	p1 = V3(p1.X, b.top.Y, p1.Z)
	local len = ((p1 - p0) * FLAT).Magnitude
	local size = math.max(8, 13 - diff)
	local gap = 3.5 + diff * 1.1
	local n = math.max(1, math.floor(len / (size + gap) + 0.5) - 1)
	while math.abs(p1.Y - p0.Y) / (n + 1) > 3.5 do
		n += 1
	end
	local m = Instance.new("Model")
	m.Name = "Path_" .. a.name .. "_" .. b.name
	m.Parent = L.pathF
	local cols = { pal.accent, pal.secondary, pal.primary }
	local prev = p0
	local pts = {}
	for k = 1, n do
		local t = k / (n + 1)
		local pos = p0:Lerp(p1, t) + side * bow * len * math.sin(t * PI) + V3(0, r:NextNumber(-0.4, 0.4), 0)
		local col = cols[(k - 1) % #cols + 1]:Lerp(Color3.new(1, 1, 1), 0.12)
		local pm = WK2.prop("platform", { position = pos, size = size + r:NextNumber(-1, 1), color = col, parent = m,
			seed = r:NextInteger(1, 1e6), palette = L.o.palette })
		if diff >= 2 and n >= 3 and k == math.ceil(n / 2) then
			pm.Name = "Platform_moving"
			tag(pm, "KitMover", { MoveOffset = side * (4 + diff), MovePeriod = 4.6 - diff * 0.3 })
		elseif diff >= 3 and n >= 4 and k == n - 1 then
			pm.Name = "Platform_crumble"
			tag(pm, "KitCrumble")
		end
		table.insert(pts, pos)
		-- coins arc over each jump
		for c = 1, 2 do
			local tt = c / 3
			coin(L, prev:Lerp(pos, tt) + V3(0, 3.2 + 2.5 * math.sin(tt * PI), 0))
		end
		prev = pos
	end
	for c = 1, 2 do
		local tt = c / 3
		coin(L, prev:Lerp(p1, tt) + V3(0, 3.2 + 2.5 * math.sin(tt * PI), 0))
	end
	-- gateway lamps on both rims: the path reads from far away
	for _, e in ipairs({ { p0, dir, a }, { p1, -dir, b } }) do
		local at, d = e[1], e[2]
		for _, sgn in ipairs({ -1, 1 }) do
			local q = at - d * 4 + d:Cross(V3(0, 1, 0)) * sgn * 7
			local g = ground(L, q.X, q.Z, at.Y)
			if g then
				prop(L, "lamp", g, { height = 8, rotation = 0 })
			end
		end
	end
	table.insert(L.info.courses, { from = a.name, to = b.name, platforms = pts, model = m })
	return pts
end

-- trees in clusters at the rim, away from exits and the spawn; small props around each cluster; flower patches
local function dress(L, isl, exits, keepClear)
	local r, d = L.r, L.dress
	local nClusters = math.clamp(math.floor(isl.radius / 10), 3, 5)
	local placed = {}
	local function free(p, gap)
		for _, q in ipairs(placed) do
			if ((q - p) * FLAT).Magnitude < gap then return false end
		end
		for _, kc in ipairs(keepClear) do
			if ((kc[1] - p) * FLAT).Magnitude < kc[2] then return false end
		end
		return true
	end
	local tries = 0
	local clusters = 0
	while clusters < nClusters and tries < 40 do
		tries += 1
		local a = r:NextNumber(0, 2 * PI)
		local ok = true
		for _, e in ipairs(exits) do
			if angDist(a, e) < 0.75 then ok = false end
		end
		if ok then
			clusters += 1
			local cdist = isl.radius * r:NextNumber(0.6, 0.78)
			local cc = isl.center + V3(math.cos(a) * cdist, 0, math.sin(a) * cdist)
			local nt = r:NextInteger(2, 4)
			for _ = 1, nt * 3 do
				if nt <= 0 then break end
				local p = cc + V3(r:NextNumber(-1, 1) * 9, 0, r:NextNumber(-1, 1) * 9)
				if ((p - isl.center) * FLAT).Magnitude < isl.radius * 0.9 and free(p, 8) then
					local g = ground(L, p.X, p.Z, isl.top.Y)
					if g then
						local k = pick(r, d.trees)
						local o = {}
						for kk, vv in pairs(k[3] or {}) do o[kk] = vv end
						o.scale = o.scale or r:NextNumber(1.05, 1.5)
						prop(L, k[1], g - V3(0, 0.3, 0), o)
						table.insert(placed, p)
						nt -= 1
					end
				end
			end
			for _ = 1, r:NextInteger(3, 5) do
				local aa, dd = r:NextNumber(0, 2 * PI), r:NextNumber(6, 13)
				local p = cc + V3(math.cos(aa) * dd, 0, math.sin(aa) * dd)
				if ((p - isl.center) * FLAT).Magnitude < isl.radius * 0.92 and free(p, 3.5) then
					local g = ground(L, p.X, p.Z, isl.top.Y)
					if g then
						local k = pick(r, d.small)
						local o = {}
						for kk, vv in pairs(k[3] or {}) do o[kk] = vv end
						prop(L, k[1], g - V3(0, 0.2, 0), o)
						table.insert(placed, p)
					end
				end
			end
		end
	end
	-- flower patches in the open (they never collide)
	for _ = 1, math.floor(isl.radius / 8) do
		local aa, dd = r:NextNumber(0, 2 * PI), r:NextNumber(0.25, 0.85) * isl.radius
		local p = isl.center + V3(math.cos(aa) * dd, 0, math.sin(aa) * dd)
		local g = ground(L, p.X, p.Z, isl.top.Y)
		if g and free(p, 4) then
			prop(L, d.top == M.Grass and "flowers" or pick(r, d.small)[1], g - V3(0, 0.1, 0), { count = 7 })
		end
	end
	if d.lanterns then
		for _ = 1, 2 do
			local aa = r:NextNumber(0, 2 * PI)
			WK2.lantern({ position = isl.top + V3(math.cos(aa) * isl.radius * 0.5, r:NextNumber(9, 13),
				math.sin(aa) * isl.radius * 0.5), color = L.pal.glow, size = 2.6, parent = L.dressF })
		end
	end
end

-- ---------------------------------------------------------------------------------------------------- layouts

local function newLevel(kind, o)
	o = o or {}
	local look = o.look or LookKit.current or "toon_bright"
	if o.applyLook ~= false then
		LookKit.apply(look, o.lookOverrides or (o.palette and { palette = o.palette }) or nil)
	end
	local parentRoot = o.parent or Workspace:FindFirstChild("StudioWorld") or Workspace
	local name = o.name or "Level"
	local old = parentRoot:FindFirstChild(name)
	if old then old:Destroy() end
	if o.clearTerrain ~= false then
		T:Clear()
	end
	local root = folder(name, parentRoot)
	root:SetAttribute("LevelKind", kind)
	local L = {
		o = o, kind = kind, look = look, seed = o.seed or 7, r = Random.new(o.seed or 7), scale = o.scale or 1,
		diff = math.clamp(o.difficulty or 1, 1, 4), pal = LookKit.palette,
		dress = DRESS[look] or DRESS.toon_bright, root = root,
		info = { kind = kind, look = look, folder = root, islands = {}, courses = {}, checkpoints = {}, collectibles = {},
			goals = {}, hazards = {} },
	}
	L.dressF = folder("Dressing", root)
	L.pathF = folder("Paths", root)
	L.playF = folder("Gameplay", root)
	L.coinF = folder("Coins", L.playF)
	L.decoF = folder("Sky", root)
	return L
end

local function finish(L, spawnPos)
	local info = L.info
	local spawn = WK2.claimSpawn(spawnPos, true)
	info.spawn = spawn.Position + V3(0, 3, 0)
	tag(spawn, "KitSpawn")
	local lo, hi = V3(math.huge, math.huge, math.huge), V3(-math.huge, -math.huge, -math.huge)
	for _, isl in ipairs(info.islands) do
		lo = lo:Min(isl.center - V3(isl.radius, isl.radius, isl.radius))
		hi = hi:Max(isl.top + V3(isl.radius, 30, isl.radius))
	end
	info.bounds = { min = lo, max = hi }
	L.root:SetAttribute("Spawn", info.spawn)
	L.root:SetAttribute("BoundsMin", lo)
	L.root:SetAttribute("BoundsMax", hi)
	return info
end

-- The arc: islands around the hub at increasing angle, distance and height, so from the hub every island is in
-- view (no "tower" from the spawn camera) and the overview reads as a rising crescent.
local function arcLayout(L, hubCenter, hubR, count, rise0, floating)
	local r, S = L.r, L.scale
	local isls = {}
	local hub = { name = "Hub", center = hubCenter, radius = hubR, top = hubCenter }
	table.insert(isls, hub)
	local a0 = r:NextNumber(0, 2 * PI)
	local sweep = math.rad(o_or(L.o.arc, 200))
	for i = 1, count do
		local final = i == count
		local a = a0 + (i - 0.5) / count * sweep + r:NextNumber(-0.08, 0.08)
		local dist = (108 + i * 24) * S
		local rad = (final and 30 or r:NextNumber(26, 34)) * math.sqrt(S)
		local y = hubCenter.Y + rise0 + (i - 1) * 13 * S + r:NextNumber(-2, 2)
		local c = hubCenter + V3(math.cos(a) * dist, 0, math.sin(a) * dist)
		c = V3(c.X, y, c.Z)
		table.insert(isls, { name = final and "Crown" or ("Island" .. i), center = c, radius = rad, top = c, final = final })
	end
	-- exits: each island leaves toward the next and arrives from the previous
	for i, isl in ipairs(isls) do
		isl.exits = {}
		if isls[i - 1] then table.insert(isl.exits, angleOf(isls[i - 1].center - isl.center)) end
		if isls[i + 1] then table.insert(isl.exits, angleOf(isls[i + 1].center - isl.center)) end
	end
	local _ = floating
	return isls
end

local function islandsLevel(L, floating)
	local S, r, info, pal = L.scale, L.r, L.info, L.pal
	local count = math.clamp(L.o.islands or 4, 2, 7)
	local hubR = 46 * math.sqrt(S)
	local hubY = floating and 70 * S or 0
	L.floorY = 0
	local hubCenter = V3(0, hubY, 0)
	local isls = arcLayout(L, hubCenter, hubR, count, floating and 12 or 12, floating)
	-- terrain
	if floating then
		if not L.dress.noWater then
			T:FillBlock(CF(0, -30, 0), V3(4096, 60, 4096), M.Water)
			-- seen from above the whole sea is one flat colour: a deeper shade than the look's shore water keeps
			-- it from washing the frame out (live, first try: toon_bright read as a neon-cyan plane)
			T.WaterColor = L.pal.water:Lerp(Color3.new(0, 0.05, 0.15), 0.4)
		end
	else
		-- the valley: a wide grass floor, a ring of big hills for walls
		local R = 340 * S
		T:FillCylinder(CF(0, -6, 0), 12, R, L.dress.top)
		T:FillCylinder(CF(0, -16, 0), 10, R, L.dress.band)
		for k = 1, 14 do
			local a = k / 14 * 2 * PI + r:NextNumber(-0.15, 0.15)
			local HR = r:NextNumber(55, 85) * S
			T:FillBall(V3(math.cos(a) * R * 0.98, -HR * 0.45, math.sin(a) * R * 0.98), HR, L.dress.top)
		end
	end
	for i, isl in ipairs(isls) do
		if floating or i > 1 then
			skyIsland(L, isl.center, isl.radius, isl.exits, floating)
		end
	end
	-- spawn on the hub, facing the first path
	local first = isls[2]
	local toFirst = ((first.center - hubCenter) * FLAT).Unit
	local spawnXZ = hubCenter - toFirst * hubR * 0.25
	local spawnG = WK2.groundAt(spawnXZ.X, spawnXZ.Z) or (spawnXZ + V3(0, 0.5, 0))
	-- paths
	for i = 1, #isls - 1 do
		local bow = (i % 2 == 0 and 1 or -1) * 0.12
		steps(L, isls[i], isls[i + 1], bow)
	end
	-- islands: dressing, checkpoints, stars, hazards
	for i, isl in ipairs(isls) do
		local keep = {}
		local arrive = isls[i - 1] and ((isls[i - 1].center - isl.center) * FLAT).Unit or -toFirst
		local cp = i == 1 and spawnG or (isl.center + arrive * isl.radius * 0.55)
		local cpG = ground(L, cp.X, cp.Z, isl.top.Y) or cp
		table.insert(keep, { cpG, i == 1 and 16 or 9 })
		-- the walking line across the island stays clear
		if isls[i + 1] then
			local leave = ((isls[i + 1].center - isl.center) * FLAT).Unit
			for t = -1, 1, 0.25 do
				table.insert(keep, { isl.center + leave * isl.radius * t, 7 })
			end
		end
		for t = -1, 0, 0.25 do
			table.insert(keep, { isl.center + arrive * isl.radius * t, 7 })
		end
		local starPos
		if i > 1 then
			local sideDir = arrive:Cross(V3(0, 1, 0)) * (i % 2 == 0 and 1 or -1)
			local sp = isl.final and isl.center or (isl.center + sideDir * isl.radius * 0.4)
			starPos = ground(L, sp.X, sp.Z, isl.top.Y) or sp
			table.insert(keep, { starPos, isl.final and 14 or 8 })
		end
		if i > 1 and not isl.final then
			local hz = isl.center - arrive:Cross(V3(0, 1, 0)) * (i % 2 == 0 and 1 or -1) * isl.radius * 0.4
			local hg = ground(L, hz.X, hz.Z, isl.top.Y)
			if hg then
				thorns(L, hg, 4.5)
				table.insert(keep, { hg, 8 })
			end
		end
		dress(L, isl, isl.exits, keep)
		checkpoint(L, cpG, i)
		if starPos then
			local core = star(L, starPos, i, isl.final)
			table.insert(info.goals, core.Position)
			if isl.final then
				info.goal = core.Position
				-- the crown: a ring of pillars around the final star, a landmark seen from the hub
				for k = 1, 6 do
					local a = k / 6 * 2 * PI
					local p = isl.center + V3(math.cos(a) * 13, 0, math.sin(a) * 13)
					local g = ground(L, p.X, p.Z, isl.top.Y)
					if g then
						WK2.prop("pillar", { position = g - V3(0, 0.3, 0), height = 12, parent = L.playF, palette = L.o.palette })
						local tip = g + V3(0, 12.6, 0)
						local orb = H.ball(L.playF, 1.6, CF(tip + V3(0, 0.8, 0)), pal.gold, M.Neon)
						orb.CastShadow = false
					end
				end
			end
			for k = 1, 6 do -- a coin ring around every star
				local a = k / 6 * 2 * PI
				coin(L, starPos + V3(math.cos(a) * 6, 3, math.sin(a) * 6))
			end
		end
		table.insert(info.islands, { name = isl.name, top = ground(L, isl.center.X, isl.center.Z, isl.top.Y) or isl.top,
			center = isl.center, radius = isl.radius })
	end
	-- spawn dressing: a flag beside the start, a lamp pair already flanks the first path
	WK2.prop("flag", { position = spawnG - toFirst:Cross(V3(0, 1, 0)) * 9, color = pal.primary, height = 14,
		parent = L.dressF, palette = L.o.palette })
	-- sky dressing: cloud puffs below / around the islands, a few floating rocks
	if floating and L.look ~= "space" then
		for k = 1, 14 do
			local a = r:NextNumber(0, 2 * PI)
			local d = r:NextNumber(90, 330) * S
			cloud(L, V3(math.cos(a) * d, hubY - r:NextNumber(18, 45) * S, math.sin(a) * d), r:NextNumber(18, 34))
		end
	end
	if not floating then
		-- the valley floor: clustered trees and props, kept off the paths, the plateaus and the hub
		local blockers = {}
		for _, c in ipairs(info.courses) do
			for _, p in ipairs(c.platforms) do table.insert(blockers, { p, 14 }) end
		end
		for _, isl in ipairs(isls) do table.insert(blockers, { isl.center, isl.radius + 8 }) end
		for _, set in ipairs({ { L.dress.trees, 70 }, { L.dress.small, 60 } }) do
			for _, m in ipairs(WK2.populate({ center = V3(0, 0, 0), size = 600 * S, kinds = set[1], count = set[2],
				clusters = 12, seed = L.seed + set[2], parent = L.dressF, palette = L.o.palette })) do
				local p = m:GetPivot().Position
				local bad = p.Magnitude > 330 * S
				for _, b in ipairs(blockers) do
					if ((b[1] - p) * FLAT).Magnitude < b[2] then bad = true; break end
				end
				if bad then m:Destroy() end
			end
		end
	end
	if floating then
		for k = 1, 8 do
			local isl = isls[r:NextInteger(1, #isls)]
			local a = r:NextNumber(0, 2 * PI)
			local d = isl.radius + r:NextNumber(10, 30)
			T:FillBall(isl.center + V3(math.cos(a) * d, r:NextNumber(-25, -5), math.sin(a) * d), r:NextNumber(3, 6),
				L.dress.body)
		end
	end
	return finish(L, spawnG)
end

-- ---------------------------------------------------------------------------------------------------- wrappers

local function arenaLevel(L)
	local S = L.scale
	local size = 170 * S
	local R = size * 1.4
	T:FillCylinder(CF(0, -6, 0), 12, R, L.dress.top)
	T:FillCylinder(CF(0, -16, 0), 10, R, L.dress.band)
	for k = 1, 12 do
		local a = k / 12 * 2 * PI + L.r:NextNumber(-0.2, 0.2)
		local HR = L.r:NextNumber(45, 70) * S
		T:FillBall(V3(math.cos(a) * R * 0.95, -HR * 0.4, math.sin(a) * R * 0.95), HR, L.dress.top)
	end
	local style = L.o.style or (L.look == "neon_night" or L.look == "space") and "scifi"
		or (L.look == "dark_fantasy" or L.look == "cozy") and "fantasy" or (LookKit.isToon and "toon" or "military")
	local ar = WK2.arena({ center = V3(0, 0, 0), size = size, style = style, seed = L.seed, parent = L.root,
		palette = L.o.palette, spawns = L.o.spawns or 8 })
	L.info.arena = ar
	L.info.spawns = ar.spawns
	-- dressing outside the walls only
	local made = WK2.populate({ center = V3(0, 0, 0), size = R * 1.8, kinds = L.dress.trees, count = 60, clusters = 10,
		clear = size * 0.75, seed = L.seed, parent = L.dressF, palette = L.o.palette })
	local _ = made
	WK2.populate({ center = V3(0, 0, 0), size = R * 1.8, kinds = L.dress.small, count = 50, clusters = 10,
		clear = size * 0.75, seed = L.seed + 1, parent = L.dressF, palette = L.o.palette })
	table.insert(L.info.islands, { name = "Arena", top = V3(0, 0, 0), center = V3(0, 0, 0), radius = size / 2 })
	local sp = ar.spawns and ar.spawns[1]
	return finish(L, sp and sp.Position or V3(0, 1, 0))
end

local function townLevel(L)
	local S = L.scale
	local blocks = L.o.blocks or 3
	local style = L.o.style or (L.look == "neon_night" and "neon") or (L.look == "dark_fantasy" and "medieval")
		or (L.look == "desert" and "western") or "suburb"
	local span = blocks * 56 + (blocks + 1) * 16
	local R = span * 0.9 + 80 * S
	T:FillCylinder(CF(0, -6, 0), 12, R, L.dress.top)
	T:FillCylinder(CF(0, -16, 0), 10, R, L.dress.band)
	for k = 1, 12 do
		local a = k / 12 * 2 * PI + L.r:NextNumber(-0.2, 0.2)
		local HR = L.r:NextNumber(45, 70) * S
		T:FillBall(V3(math.cos(a) * R * 0.95, -HR * 0.4, math.sin(a) * R * 0.95), HR, L.dress.top)
	end
	local town = WK2.town({ center = V3(0, 0, 0), blocks = blocks, style = style, seed = L.seed, parent = L.root,
		palette = L.o.palette })
	L.info.town = town
	WK2.populate({ center = V3(0, 0, 0), size = R * 1.8, kinds = L.dress.trees, count = 70, clusters = 12,
		clear = span * 0.62, seed = L.seed, parent = L.dressF, palette = L.o.palette })
	WK2.populate({ center = V3(0, 0, 0), size = R * 1.8, kinds = L.dress.small, count = 60, clusters = 12,
		clear = span * 0.62, seed = L.seed + 1, parent = L.dressF, palette = L.o.palette })
	table.insert(L.info.islands, { name = "Town", top = V3(0, 0, 0), center = V3(0, 0, 0), radius = span / 2 })
	return finish(L, town.spawn or V3(0, 1, 0))
end

-- LevelKit.build(kind, opts) -> info. kinds: "sky_islands" | "meadow_course" | "arena" | "town".
-- opts: look (LookKit look; applied unless applyLook=false), lookOverrides, palette, seed=7, scale=1, islands=4,
-- difficulty=1..4, arc=200 (degrees the islands sweep around the hub), parent (default workspace.StudioWorld),
-- name="Level", clearTerrain=true (the level owns the Terrain: build it FIRST, then add on top), style/blocks/spawns
-- (arena, town).
function LevelKit.build(kind, opts)
	kind = kind or "sky_islands"
	local L = newLevel(kind, opts)
	if kind == "sky_islands" or kind == "islands" then
		return islandsLevel(L, true)
	elseif kind == "meadow_course" or kind == "meadow" then
		return islandsLevel(L, false)
	elseif kind == "arena" then
		return arenaLevel(L)
	elseif kind == "town" then
		return townLevel(L)
	end
	warn("[LevelKit] unknown kind " .. tostring(kind) .. "; building sky_islands")
	return islandsLevel(L, true)
end

-- LevelKit.describe(info) -> string: a short readable summary (spawn, islands, spot counts) to print or return
function LevelKit.describe(info)
	local function v(p) return p and string.format("(%d, %d, %d)", p.X, p.Y, p.Z) or "nil" end
	local out = { string.format("%s/%s spawn=%s", info.kind, info.look, v(info.spawn)) }
	for _, isl in ipairs(info.islands) do
		table.insert(out, string.format("  %s top=%s radius=%d", isl.name, v(isl.top), isl.radius))
	end
	table.insert(out, string.format("  %d courses, %d checkpoints, %d coins, %d goals (final %s), %d hazards; bounds %s..%s",
		#info.courses, #info.checkpoints, #info.collectibles, #info.goals, v(info.goal), #info.hazards,
		v(info.bounds.min), v(info.bounds.max)))
	return table.concat(out, "\n")
end

LevelKit.level = LevelKit.build
return LevelKit
