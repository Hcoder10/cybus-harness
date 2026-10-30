--!strict
-- PropKit: spawns generated props (the builder tool generate_prop writes one ModuleScript per prop to
-- ReplicatedStorage.Shared.Props.<Name>) as anchored part-built Models. Server or client.
--   PropKit.spawn("Mushroom", { position = Vector3.new(0, 0, 10), scale = 8 })   bottom centre sits on position
--   PropKit.scatter(Props.Rock, { center = Vector3.zero, radius = 60 }, 20, { minSpacing = 8 })
--   for _, o in PropKit.variants(asset, 5, 1) do PropKit.spawn(asset, o) end
-- Asset format: { name, style = "voxel"|"blob", size = Vector3 (longest side 1), palette = {Color3},
--   parts = {{ shape = "Block"|"Ball"|"Ellipsoid" (nil = Block), p = {x,y,z} centre, s = {x,y,z} full size,
--   r = {rx,ry,rz} degrees (optional, XYZ Euler), c = palette index }} }. Y up, origin at the bbox bottom centre, front = -Z.
--
-- Engine facts this file is written around:
--   * Shape=Ball is always a sphere; ellipsoids are block Parts with a SpecialMesh(MeshType=Sphere), which stretches to
--     the part's full non-uniform size. No MeshParts and no asset ids anywhere.
--   * The PrimaryPart is an invisible root at the bottom centre, so model:PivotTo(CFrame.new(groundPoint)) grounds it.
--   * Each visual part keeps its palette index in the attribute PropColor; PropKit.recolor uses it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local PropKit = {}
PropKit.DEFAULT_SCALE = 6 -- longest side in studs
PropKit.LOW_DETAIL = 0.04 -- detail="low" drops parts whose largest side is under this fraction of the prop

local V3 = Vector3.new
local rad = math.rad

type Opts = { [string]: any }
type Piece = { shape: string, p: Vector3, s: Vector3, rot: CFrame?, c: number, big: number }
type Prepared = { name: string, size: Vector3, longest: number, palette: { Color3 }, pieces: { Piece } }

local prepared: { [any]: Prepared } = setmetatable({}, { __mode = "k" }) :: any
local byName: { [string]: any } = {}

------------------------------------------------------------------------------------------------ assets
local function propsFolder(wait: boolean): Instance?
	local shared = ReplicatedStorage:FindFirstChild("Shared")
	if not shared and wait and RunService:IsClient() then
		shared = ReplicatedStorage:WaitForChild("Shared", 5)
	end
	if not shared then
		return nil
	end
	local props = shared:FindFirstChild("Props")
	if not props and wait and RunService:IsClient() then
		props = shared:WaitForChild("Props", 5)
	end
	return props
end

local function vec(v: any, what: string): Vector3
	if typeof(v) == "Vector3" then
		return v
	end
	if type(v) == "table" and type(v[1]) == "number" and type(v[2]) == "number" and type(v[3]) == "number" then
		return V3(v[1], v[2], v[3])
	end
	error("[PropKit] " .. what .. " must be {x, y, z} or a Vector3, got " .. typeof(v), 4)
end

local function prepare(asset: any): Prepared
	local cached = prepared[asset]
	if cached then
		return cached
	end
	local name = type(asset.name) == "string" and asset.name or "Prop"
	local pal = asset.palette
	if type(pal) ~= "table" or #pal == 0 then
		error("[PropKit] asset '" .. name .. "' has no palette (array of Color3)", 3)
	end
	for i, c in pal do
		if typeof(c) ~= "Color3" then
			error(("[PropKit] asset '%s' palette[%s] is not a Color3"):format(name, tostring(i)), 3)
		end
	end
	if type(asset.parts) ~= "table" or #asset.parts == 0 then
		error("[PropKit] asset '" .. name .. "' has no parts", 3)
	end
	local size = vec(asset.size, "asset '" .. name .. "'.size")
	local pieces: { Piece } = {}
	for i, part in asset.parts do
		local where = ("asset '%s' parts[%d]"):format(name, i)
		if type(part) ~= "table" then
			error("[PropKit] " .. where .. " is not a table", 3)
		end
		local shape: string = part.shape or "Block"
		if shape ~= "Block" and shape ~= "Ball" and shape ~= "Ellipsoid" then
			error("[PropKit] " .. where .. " has unknown shape " .. tostring(shape), 3)
		end
		local c = part.c or 1
		if type(c) ~= "number" or not pal[c] then
			error("[PropKit] " .. where .. " colour index " .. tostring(c) .. " is outside the palette", 3)
		end
		local s = vec(part.s, where .. ".s")
		local rot: CFrame? = nil
		if part.r then
			local r = vec(part.r, where .. ".r")
			if r ~= Vector3.zero then
				rot = CFrame.fromEulerAnglesXYZ(rad(r.X), rad(r.Y), rad(r.Z))
			end
		end
		table.insert(pieces, {
			shape = shape :: string,
			p = vec(part.p, where .. ".p"),
			s = s,
			rot = rot,
			c = c,
			big = math.max(s.X, s.Y, s.Z),
		})
	end
	local longest = math.max(size.X, size.Y, size.Z)
	if longest <= 0 then
		error("[PropKit] asset '" .. name .. "' has an empty size", 3)
	end
	local out: Prepared = { name = name, size = size, longest = longest, palette = pal, pieces = pieces }
	prepared[asset] = out
	return out
end

-- asset: the module table, its ModuleScript, or a name under ReplicatedStorage.Shared.Props.
local function resolve(asset: any): any
	if type(asset) == "string" then
		local hit = byName[asset]
		if hit then
			return hit
		end
		local folder = propsFolder(true)
		if not folder then
			error("[PropKit] no ReplicatedStorage.Shared.Props folder (looking for prop '" .. asset .. "')", 3)
		end
		local mod = folder:FindFirstChild(asset)
		if not mod and RunService:IsClient() then
			mod = folder:WaitForChild(asset, 5)
		end
		if not mod or not mod:IsA("ModuleScript") then
			error("[PropKit] no prop named '" .. asset .. "' under ReplicatedStorage.Shared.Props", 3)
		end
		local t = require(mod :: ModuleScript) :: any
		if type(t) ~= "table" then
			error("[PropKit] prop module '" .. asset .. "' did not return a table", 3)
		end
		byName[asset] = t
		return t
	elseif typeof(asset) == "Instance" and (asset :: Instance):IsA("ModuleScript") then
		return resolve((asset :: Instance).Name)
	elseif type(asset) == "table" then
		return asset
	end
	error("[PropKit] asset must be a prop table, ModuleScript or prop name, got " .. typeof(asset), 3)
end

-- palette: array or map index -> Color3; entries that are not Color3 are ignored.
local function remap(base: { Color3 }, palette: any): { Color3 }
	local out = table.clone(base)
	if type(palette) == "table" then
		for i, c in palette do
			if type(i) == "number" and typeof(c) == "Color3" and out[i] then
				out[i] = c
			end
		end
	end
	return out
end

------------------------------------------------------------------------------------------------ spawn
local function rotationCF(r: any): CFrame
	if type(r) == "number" then
		return CFrame.Angles(0, rad(r), 0)
	elseif typeof(r) == "Vector3" then
		return CFrame.fromEulerAnglesXYZ(rad(r.X), rad(r.Y), rad(r.Z))
	end
	return CFrame.identity
end

local function invisible(name: string, size: Vector3, cf: CFrame, anchored: boolean): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Anchored = anchored
	p.Transparency = 1
	p.CastShadow = false
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	return p
end

-- PropKit.spawn(asset, opts?) -> Model. See the header / docs/PropKit.md for opts.
function PropKit.spawn(asset: any, opts: Opts?): Model
	local o: Opts = opts or {}
	local data = prepare(resolve(asset))
	local scale = tonumber(o.scale) or PropKit.DEFAULT_SCALE
	if scale <= 0 then
		error("[PropKit] scale must be > 0", 2)
	end
	local k = scale / data.longest
	local anchored = o.anchored ~= false
	local collide = o.collide or "box"
	if collide ~= "box" and collide ~= "parts" and collide ~= "none" then
		error("[PropKit] collide must be \"box\", \"parts\" or \"none\", got " .. tostring(collide), 2)
	end
	local material: Enum.Material = Enum.Material.SmoothPlastic
	local mat: any = o.material
	if typeof(mat) == "EnumItem" and mat.EnumType == Enum.Material then
		material = mat :: any
	end

	local colors = remap(data.palette, o.palette)
	if typeof(o.tint) == "Color3" then
		local amt = tonumber(o.tintAmount) or 0.35
		for i, c in colors do
			colors[i] = c:Lerp(o.tint, amt)
		end
	end

	local base: CFrame
	if typeof(o.cframe) == "CFrame" then
		base = o.cframe
	else
		base = CFrame.new(typeof(o.position) == "Vector3" and o.position or Vector3.zero)
	end
	base *= rotationCF(o.rotation)

	local minBig = if o.detail == "low" then PropKit.LOW_DETAIL * data.longest else 0
	local keep: { Piece } = {}
	for _, piece in data.pieces do
		if piece.big >= minBig then
			table.insert(keep, piece)
		end
	end
	if #keep == 0 then
		keep = data.pieces
	end

	local model = Instance.new("Model")
	model.Name = if type(o.name) == "string" then o.name else data.name
	local root = invisible("Root", V3(0.2, 0.2, 0.2), base, anchored)
	root.Parent = model
	model.PrimaryPart = root

	local solid = collide == "parts"
	for i, piece in keep do
		local part = Instance.new("Part")
		local s = piece.s * k
		if piece.shape == "Ball" then
			part.Shape = Enum.PartType.Ball
			local d = math.max(piece.big * k, 0.05)
			s = V3(d, d, d)
		else
			s = V3(math.max(s.X, 0.05), math.max(s.Y, 0.05), math.max(s.Z, 0.05))
		end
		part.Name = "P" .. i
		part.Size = s
		local cf = base * CFrame.new(piece.p * k)
		part.CFrame = if piece.rot then cf * piece.rot else cf
		part.Color = colors[piece.c]
		part.Material = material
		part.Anchored = anchored
		part.CastShadow = true
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.CanCollide = solid
		part.CanQuery = solid
		part.CanTouch = solid
		part.Massless = not solid
		part:SetAttribute("PropColor", piece.c)
		if piece.shape == "Ellipsoid" then
			local mesh = Instance.new("SpecialMesh")
			mesh.MeshType = Enum.MeshType.Sphere
			mesh.Parent = part
		end
		part.Parent = model
	end

	if collide == "box" then
		local size = data.size * k
		local box = invisible("Hitbox", size, base * CFrame.new(0, size.Y / 2, 0), anchored)
		box.CanCollide = true
		box.CanQuery = true
		box.CanTouch = true
		box.Parent = model
	end

	if not anchored then
		for _, child in model:GetChildren() do
			if child ~= root and child:IsA("BasePart") then
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = root
				weld.Part1 = child
				weld.Parent = child
			end
		end
	end

	model:SetAttribute("PropName", data.name)
	model:SetAttribute("PropScale", scale)
	model.Parent = if typeof(o.parent) == "Instance" then o.parent else Workspace
	return model
end

-- PropKit.recolor(model, palette): palette = array or map index -> Color3 (missing indices keep their colour).
function PropKit.recolor(model: Instance, palette: { [number]: Color3 })
	if typeof(model) ~= "Instance" or type(palette) ~= "table" then
		error("[PropKit] recolor(model, palette) expects a Model and a table of Color3", 2)
	end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			local idx = d:GetAttribute("PropColor")
			local c = if type(idx) == "number" then palette[idx] else nil
			if typeof(c) == "Color3" then
				d.Color = c
			end
		end
	end
end

-- PropKit.bounds(asset, scale = 6) -> Vector3 bounding-box size in studs.
function PropKit.bounds(asset: any, scale: number?): Vector3
	local data = prepare(resolve(asset))
	return data.size * ((scale or PropKit.DEFAULT_SCALE) / data.longest)
end

-- PropKit.list() -> sorted names of the prop ModuleScripts under ReplicatedStorage.Shared.Props ({} if none).
function PropKit.list(): { string }
	local names = {}
	local folder = propsFolder(false)
	if folder then
		for _, child in folder:GetChildren() do
			if child:IsA("ModuleScript") then
				table.insert(names, child.Name)
			end
		end
	end
	table.sort(names)
	return names
end

------------------------------------------------------------------------------------------------ variety
-- PropKit.variants(asset, n, seed?, base?) -> {opts}: copies of base with scale = (base.scale or 6) * (1 +- 15%),
-- a random yaw, and the whole palette (after base.palette) hue-shifted by up to +-0.04 and value by +-8%, one
-- shift per variant so the prop stays coherent.
function PropKit.variants(asset: any, n: number, seed: number?, base: Opts?): { Opts }
	local data = prepare(resolve(asset))
	local rng = if seed then Random.new(seed) else Random.new()
	local b: Opts = base or {}
	local pal = remap(data.palette, b.palette)
	local scale = tonumber(b.scale) or PropKit.DEFAULT_SCALE
	local out = {}
	for _ = 1, math.max(0, math.floor(n)) do
		local o = table.clone(b)
		o.scale = scale * (1 + rng:NextNumber(-0.15, 0.15))
		o.rotation = rng:NextNumber(0, 360)
		local dh, dv = rng:NextNumber(-0.04, 0.04), rng:NextNumber(0.92, 1.08)
		local shifted = {}
		for i, c in pal do
			local h, s, v = c:ToHSV()
			shifted[i] = Color3.fromHSV((h + dh) % 1, s, math.clamp(v * dv, 0, 1))
		end
		o.palette = shifted
		table.insert(out, o)
	end
	return out
end

local SCATTER_KEYS = { "jitter", "seed", "minSpacing", "castHeight", "exclude", "position", "cframe", "rotation" }

-- PropKit.scatter(asset, area, count, opts?) -> {Model}. area = {center, radius} | {min, max} | BasePart (top face).
-- Raycasts down from castHeight (default 200) above the area; points with no ground are skipped. opts: jitter=0.2
-- (scale +-), seed, minSpacing (studs, XZ), exclude = {Instance} (extra ray filter), plus any spawn opts.
function PropKit.scatter(asset: any, area: any, count: number, opts: Opts?): { Model }
	local o: Opts = opts or {}
	local a = resolve(asset)
	prepare(a)
	local rng = if o.seed then Random.new(o.seed) else Random.new()
	local castHeight = tonumber(o.castHeight) or 200
	local sample: () -> Vector3
	if typeof(area) == "Instance" and (area :: Instance):IsA("BasePart") then
		local p = area :: BasePart
		sample = function()
			return (p.CFrame * CFrame.new(rng:NextNumber(-0.5, 0.5) * p.Size.X, p.Size.Y / 2, rng:NextNumber(-0.5, 0.5) * p.Size.Z)).Position
		end
	elseif type(area) == "table" and typeof(area.center) == "Vector3" and type(area.radius) == "number" then
		sample = function()
			local r, t = area.radius * math.sqrt(rng:NextNumber()), rng:NextNumber(0, 2 * math.pi)
			return area.center + V3(r * math.cos(t), 0, r * math.sin(t))
		end
	elseif type(area) == "table" and typeof(area.min) == "Vector3" and typeof(area.max) == "Vector3" then
		local lo, hi = area.min:Min(area.max), area.min:Max(area.max)
		sample = function()
			return V3(rng:NextNumber(lo.X, hi.X), hi.Y, rng:NextNumber(lo.Z, hi.Z))
		end
	else
		error("[PropKit] scatter area must be {center, radius}, {min, max} or a BasePart", 2)
	end

	local pass: Opts = table.clone(o)
	for _, key in SCATTER_KEYS do
		pass[key] = nil
	end
	local jitter = tonumber(o.jitter) or 0.2
	local baseScale = tonumber(o.scale) or PropKit.DEFAULT_SCALE
	local spacing = tonumber(o.minSpacing) or 0
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local filter: { Instance } = {}
	if type(o.exclude) == "table" then
		for _, inst in o.exclude do
			if typeof(inst) == "Instance" then
				table.insert(filter, inst)
			end
		end
	end
	params.FilterDescendantsInstances = filter

	local placed: { Vector3 } = {}
	local models: { Model } = {}
	local tries = 0
	while #models < count and tries < count * 10 do
		tries += 1
		local at = sample()
		local hit = Workspace:Raycast(at + V3(0, castHeight, 0), V3(0, -(castHeight + 1000), 0), params)
		if hit then
			local ok = true
			if spacing > 0 then
				for _, q in placed do
					if V3(q.X - hit.Position.X, 0, q.Z - hit.Position.Z).Magnitude < spacing then
						ok = false
						break
					end
				end
			end
			if ok then
				local so = table.clone(pass)
				so.position = hit.Position
				so.rotation = rng:NextNumber(0, 360)
				so.scale = baseScale * (1 + rng:NextNumber(-jitter, jitter))
				local m = PropKit.spawn(a, so)
				table.insert(models, m)
				table.insert(placed, hit.Position)
				table.insert(filter, m)
				params.FilterDescendantsInstances = filter
			end
		end
	end
	return models
end

return PropKit
