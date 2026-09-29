-- VFX: declarative layered effects (client-first) and screen accents. A spec lists layers (particles, beam, light,
-- flash, ring, decal), each with its own delay, so one call plays anticipation -> impact -> dissipation. No look of
-- its own: every colour, size and timing comes from the spec (colours as Color3, "#RRGGBB" or "Tokens.color.<name>").
--   VFX.preset("hit", { layers = { { kind = "flash", ... }, { kind = "particles", count = 24, ... } } })
--   VFX.play("hit", result.Position, { normal = result.Normal, scale = 1.2, intensity = 0.8 })
--   local h = VFX.effect(spec, part, { follow = true }); h:stop()      (continuous layers run until stop())
--   VFX.flashLight(pos, color, 4, 16, 0.2)   VFX.hitstop(0.08)   VFX.screenFlash(color, 0.15, 0.4)
--   local v = VFX.vignette(color, 0.6)   local t = VFX.trail(rootPart, { lifetime = 0.25 }); t:burst(0.4)
--   VFX.validate(spec) -> { "layers[2].lifetime: ..." }  (the same rules as the harness's check_fx_spec tool)
-- Effects live on attachments on one anchored host part under workspace.KitVFX (flash, ring and decal parts are
-- pooled) and clean themselves up after their longest layer. Budgets per family (VFX.budget(name, {effects,
-- particles, lights})) drop the oldest effect when exceeded; VFX.maxLights caps lights across all effects. Particle
-- emitters slow down with CameraRig.slowmo unless timeScaled = false (tweens and delays run in real time). With
-- follow, emitters, beams and lights ride the part; flash, ring and decal parts stay where they spawned.
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FxMath = require(script.Parent:WaitForChild("FxMath"))

local VFX = {}
VFX.maxLights = 6
VFX.defaultBudget = { effects = 16, particles = 800, lights = 3 }

local IS_CLIENT = RunService:IsClient()
local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.new(0, 0, 0)
local DIRS = { "up", "down", "forward", "back", "left", "right" }
local MATERIAL_CHOICES = { "neon", "forcefield", "glass", "smoothplastic", "plastic" }

------------------------------------------------------------------------------------------------ helpers
local warned, warnCount = {}, 0
local function caller()
	for level = 3, 10 do
		local src, line = debug.info(level, "sl")
		if src == nil then
			break
		end
		if src ~= "[C]" and not string.find(src, "^ReplicatedStorage%.Kit%.") then
			return " (" .. src .. ":" .. tostring(line) .. ")"
		end
	end
	return ""
end

local function warnOnce(key, msg)
	if warned[key] or warnCount > 500 then
		return
	end
	warned[key] = true
	warnCount += 1
	warn("[VFX] " .. msg .. caller())
end

-- A number or the default (validation already reported bad values), clamped.
local function n(v, default, lo, hi)
	if type(v) ~= "number" or v ~= v then
		return default
	end
	if lo and v < lo then
		return lo
	elseif hi and v > hi then
		return hi
	end
	return v
end

-- A number or the default, warning once when it is not one or is out of range.
local function num(v, default, lo, hi, name)
	if v ~= nil then
		if type(v) ~= "number" or v ~= v then
			warnOnce(name .. ":type", name .. " must be a number, got " .. typeof(v))
		elseif (lo and v < lo) or (hi and v > hi) then
			warnOnce(name .. ":range", name .. " must be in " .. tostring(lo) .. ".." .. tostring(hi) .. ", got "
				.. tostring(v))
		end
	end
	return n(v, default, lo, hi)
end

-- number | {a, b} -> a, b
local function pairOf(v, default)
	if type(v) == "table" then
		return n(v[1], default), n(v[2], n(v[1], default))
	end
	local x = n(v, default)
	return x, x
end

local function rangeMax(v, default)
	if typeof(v) == "NumberRange" then
		return v.Max
	end
	local a, b = pairOf(v, default)
	return math.max(a, b)
end

local function numberRange(v: any, default: number, mul: number, lo: number?, hi: number?)
	local a, b
	if typeof(v) == "NumberRange" then
		a, b = v.Min, v.Max
	else
		a, b = pairOf(v, default)
	end
	a, b = a * mul, b * mul
	if a > b then
		a, b = b, a
	end
	if lo then
		a, b = math.clamp(a, lo, hi), math.clamp(b, lo, hi)
	end
	return NumberRange.new(a, b)
end

local function normalize(tbl, keys, where)
	if type(tbl) ~= "table" then
		return {}
	end
	local out, unknown = FxMath.normalizeKeys(tbl, keys)
	for _, u in unknown do
		warnOnce(where .. ":" .. u.key, "unknown " .. where .. " option '" .. u.key .. "'"
			.. (if u.suggestion then " (did you mean '" .. u.suggestion .. "'?)" else ""))
	end
	return out
end

local function sibling(name)
	local ok, mod = pcall(function()
		return require(script.Parent:WaitForChild(name, 5))
	end)
	return if ok then mod else nil
end
local Debug = sibling("Debug")

-- Kit modules that may not exist (Textures, Assets, CameraRig): found lazily, retried at most every 2 s.
local found, retryAt = {}, {}
local function optional(parent, name)
	local key = parent.Name .. "." .. name
	local m = found[key]
	if m then
		return m
	end
	if os.clock() < (retryAt[key] or 0) then
		return nil
	end
	local inst = parent:FindFirstChild(name)
	if inst and inst:IsA("ModuleScript") then
		local ok, mod = pcall(require, inst)
		if ok and type(mod) == "table" then
			found[key] = mod
			return mod
		end
	end
	retryAt[key] = os.clock() + 2
	return nil
end

local function kit(name)
	return optional(script.Parent, name)
end

local function tokens()
	local shared = ReplicatedStorage:FindFirstChild("Shared")
	return shared and optional(shared, "Tokens")
end

local function toColor(v)
	if typeof(v) == "Color3" then
		return v
	end
	local r, g, b = FxMath.hex(v)
	if r then
		return Color3.new(r, g, b)
	end
	local name = FxMath.tokenName(v)
	if name then
		local T = tokens()
		local c = T and type(T.color) == "table" and T.color[name]
		if typeof(c) == "Color3" then
			return c
		end
		warnOnce("token:" .. name, "Tokens.color." .. name .. " does not exist")
	end
	return nil
end

local function applyNamed(inst: any, prop: string, tex: string, painted: boolean)
	if painted then
		local Textures = kit("Textures")
		if Textures and type(Textures.apply) == "function" then
			local ok, result = pcall(Textures.apply, inst, tex)
			if ok and result == true then
				return
			end
		end
	end
	local Assets = kit("Assets")
	if Assets and type(Assets.has) == "function" and Assets.has(tex) then
		pcall(function()
			inst[prop] = Assets.image(tex)
		end)
		return
	end
	warnOnce("texture:" .. tex, "texture '" .. tex .. "' is not a content id, "
		.. (if painted then "a painted texture " else "") .. "or a generated image")
end

-- Sets a texture: a content id / asset id directly; a name through Kit.Textures (painted textures; not for meshes)
-- or Kit.Assets (generated images). A name resolves on its own thread, so a first decode never holds up the caller.
local function applyTexture(inst: any, prop: string, tex: any, painted: boolean?)
	if tex == nil then
		return
	end
	if type(tex) == "number" then
		inst[prop] = "rbxassetid://" .. tostring(math.floor(tex))
		return
	end
	if FxMath.isContentId(tex) then
		inst[prop] = tex
		return
	end
	if type(tex) ~= "string" then
		return
	end
	task.spawn(applyNamed, inst, prop, tex, painted ~= false)
end

local function numberSequence(spec, lo, hi, mul, default)
	if typeof(spec) == "NumberSequence" then
		if mul == 1 then
			return spec
		end
		local kps = {}
		for i, k in spec.Keypoints do
			kps[i] = NumberSequenceKeypoint.new(k.Time, k.Value * mul, k.Envelope * mul)
		end
		return NumberSequence.new(kps)
	end
	local list = if spec ~= nil then FxMath.keypoints(spec, FxMath.isNumber) else nil
	if not list then
		list = FxMath.keypoints(default, FxMath.isNumber)
	end
	FxMath.clampKeypoints(list, lo, hi)
	local kps = table.create(#list)
	for i, k in list do
		kps[i] = NumberSequenceKeypoint.new(k.t, k.v * mul, k.e * mul)
	end
	return NumberSequence.new(kps)
end

local function colorSequence(spec)
	if typeof(spec) == "ColorSequence" then
		return spec
	end
	local list = if spec ~= nil then FxMath.keypoints(spec, FxMath.isColor) else nil
	if not list then
		return ColorSequence.new(WHITE)
	end
	local kps = table.create(#list)
	for i, k in list do
		kps[i] = ColorSequenceKeypoint.new(k.t, toColor(k.v) or WHITE)
	end
	return ColorSequence.new(kps)
end

local function firstLast(seq)
	local kps = seq.Keypoints
	return kps[1].Value, kps[#kps].Value
end

local function enumItem(enumName, itemName)
	local ok, item = pcall(function()
		return (Enum :: any)[enumName][itemName]
	end)
	return if ok then item else nil
end

local function enumMap(enumName, items)
	local m = {}
	for key, itemName in items do
		m[key] = enumItem(enumName, itemName)
	end
	return m
end

local NORMAL = enumMap("NormalId", { up = "Top", down = "Bottom", forward = "Front", back = "Back", left = "Left",
	right = "Right" })
local ORIENT = enumMap("ParticleOrientation", { facing = "FacingCamera", facingUp = "FacingCameraWorldUp",
	parallel = "VelocityParallel", perpendicular = "VelocityPerpendicular" })
local FLIP_LAYOUT = enumMap("ParticleFlipbookLayout", { ["2x2"] = "Grid2x2", ["4x4"] = "Grid4x4", ["8x8"] = "Grid8x8" })
local FLIP_MODE = enumMap("ParticleFlipbookMode", { loop = "Loop", oneshot = "OneShot", pingpong = "PingPong",
	random = "Random" })
local SHAPE = enumMap("ParticleEmitterShape", { sphere = "Sphere", box = "Box", disc = "Disc", cylinder = "Cylinder" })
local SHAPE_STYLE = enumMap("ParticleEmitterShapeStyle", { volume = "Volume", surface = "Surface" })
local SHAPE_INOUT = enumMap("ParticleEmitterShapeInOut", { outward = "Outward", inward = "Inward", both = "InAndOut" })
local TEXTURE_MODE = enumMap("TextureMode", { stretch = "Stretch", wrap = "Wrap", static = "Static" })
local MATERIAL = enumMap("Material", { neon = "Neon", forcefield = "ForceField", glass = "Glass",
	smoothplastic = "SmoothPlastic", plastic = "Plastic" })

local function choice(v, choices, default)
	return FxMath.enumValue(v, choices) or default
end

local function setIf(inst, prop, value)
	if value ~= nil then
		inst[prop] = value
	end
end

local function tweenInfo(seconds, ease, defaultStyle, defaultDirection)
	local style, dir = FxMath.easeNames(ease, nil, defaultStyle, defaultDirection)
	return TweenInfo.new(seconds, enumItem("EasingStyle", style) or Enum.EasingStyle.Quint,
		enumItem("EasingDirection", dir) or Enum.EasingDirection.Out)
end

------------------------------------------------------------------------------------------------ pools
local folder, host = nil, nil
local partPool = {}

local function getHost()
	if host and host.Parent and folder and folder.Parent then
		return host
	end
	for _, p in partPool do
		pcall(function()
			p:Destroy()
		end)
	end
	table.clear(partPool)
	folder = workspace:FindFirstChild("KitVFX")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "KitVFX"
		folder.Parent = workspace
	end
	host = Instance.new("Part")
	host.Name = "Host"
	host.Anchored = true
	host.CanCollide = false
	host.CanQuery = false
	host.CanTouch = false
	host.CastShadow = false
	host.Transparency = 1
	host.Size = Vector3.new(0.2, 0.2, 0.2)
	host.CFrame = CFrame.identity
	host.Parent = folder
	return host
end

-- A new attachment at cf, placed before it is parented so the engine never sees it anywhere else (an emitter bursting
-- in the same frame emits from the right place).
local function newAttachment(cf, parent)
	local holder = parent or getHost()
	local a = Instance.new("Attachment")
	a.Name = "KitVFX"
	a.CFrame = holder.CFrame:ToObjectSpace(cf)
	a.Parent = holder
	return a
end

local function makePart(cf)
	local p = Instance.new("Part")
	p.Name = "KitVFXPart"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Massless = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Transparency = 1
	p.Size = Vector3.one
	p.CFrame = cf or CFrame.identity
	return p
end

local function takePart()
	getHost()
	local p = table.remove(partPool)
	if p and p.Parent ~= folder then
		p = nil -- its folder is gone
	end
	if not p then
		p = makePart()
		p.Parent = folder
	end
	p.Size = Vector3.one
	p.Transparency = 1
	p.Material = Enum.Material.SmoothPlastic
	p.Color = WHITE
	return p
end

local function releasePart(p)
	for _, c in p:GetChildren() do
		c:Destroy()
	end
	if #partPool < 32 and folder and folder.Parent and p.Parent == folder then
		p.Transparency = 1
		table.insert(partPool, p)
	else
		p:Destroy()
	end
end

------------------------------------------------------------------------------------------------ effects
local Effect = {}
Effect.__index = Effect

local live = {} -- id -> effect
local emitterFx = setmetatable({}, { __mode = "k" }) -- emitter -> effect (for time scale and hitstop)
local frozen = {} -- hitstop: object -> { restore, untilT, track }
local budgets = {} -- family -> FxMath budget
local budgetCaps = {} -- family -> caps set with VFX.budget
local plans = setmetatable({}, { __mode = "k" }) -- spec table -> prepared plan (validated once)
local lightOrder = {}
local spins = {}
local spinConn = nil
local tsConn = nil
local nextId = 0

local NULL = setmetatable({ alive = false, id = 0, endReason = "invalid", emitters = {} }, Effect)

local function rig()
	return if IS_CLIENT then kit("CameraRig") else nil
end

local function currentTimeScale()
	local r = found[script.Parent.Name .. ".CameraRig"]
	local ts = r and r.timeScale
	return if type(ts) == "number" then ts else 1
end

local function hookTimeScale()
	if tsConn then
		return
	end
	local r = rig()
	if r and type(r.onTimeScale) == "function" then
		tsConn = r.onTimeScale(function(ts)
			local now = os.clock()
			for _, fx in live do
				if fx.timeScaled then
					fx.lag += (now - fx.tsAt) * (1 - fx.ts)
					fx.ts, fx.tsAt = ts, now
					for _, e in fx.emitters do
						if e.Parent and not frozen[e] then
							e.TimeScale = (fx.baseTS[e] or 1) * ts
						end
					end
				end
			end
		end)
	end
end

local function schedule(fx, delay, fn)
	local thread = task.delay(delay, function()
		if fx.alive then
			fn()
		end
	end)
	table.insert(fx.threads, thread)
end

local function tween(fx, inst, info, goal)
	local tw = TweenService:Create(inst, info, goal)
	table.insert(fx.tweens, tw)
	tw:Play()
	return tw
end

local function stepSpins()
	local now = os.clock()
	local i = 1
	while i <= #spins do
		local s = spins[i]
		local u = (now - s.t0) / s.duration
		if not s.fx.alive or u >= 1 or not s.part.Parent then
			if s.fx.alive and s.part.Parent then
				s.part.CFrame = s.base * CFrame.Angles(0, s.radians, 0)
			end
			spins[i] = spins[#spins]
			spins[#spins] = nil
		else
			s.part.CFrame = s.base * CFrame.Angles(0, s.radians * s.ease(u), 0)
			i += 1
		end
	end
	if #spins == 0 and spinConn then
		spinConn:Disconnect()
		spinConn = nil
	end
end

local function addSpin(fx, part, degrees, duration, ease)
	if degrees == 0 or duration <= 0 then
		return
	end
	table.insert(spins, { fx = fx, part = part, base = part.CFrame, radians = math.rad(degrees), duration = duration,
		t0 = os.clock(), ease = ease })
	if not spinConn then
		spinConn = RunService.Heartbeat:Connect(stepSpins)
	end
end

local function registerLight(light)
	for i = #lightOrder, 1, -1 do
		if lightOrder[i].Parent == nil then
			table.remove(lightOrder, i)
		end
	end
	table.insert(lightOrder, light)
	while #lightOrder > math.max(VFX.maxLights, 0) do
		table.remove(lightOrder, 1):Destroy()
	end
end

-- The effect's frame now (effects that follow a part move with it).
local function frameNow(fx)
	local part = fx.followPart
	if part and part.Parent then
		return part.CFrame * fx.localCF
	end
	return fx.cf
end

local function attachmentAt(fx, cf)
	local parent = if fx.followPart and fx.followPart.Parent then fx.followPart else nil
	local a = newAttachment(cf, parent)
	table.insert(fx.attachments, a)
	return a
end

-- The layer's frame: the effect's frame moved by the layer's offset.
local function layerCF(fx, L)
	local cf = frameNow(fx)
	if typeof(L.offset) == "Vector3" then
		cf *= CFrame.new(L.offset * fx.scale)
	end
	return cf
end

-- The layer's frame and an attachment there (layers without an offset share one).
local function layerFrame(fx, L)
	local cf = layerCF(fx, L)
	if typeof(L.offset) == "Vector3" then
		return cf, attachmentAt(fx, cf)
	end
	if not fx.mainAttach or fx.mainAttach.Parent == nil then
		fx.mainAttach = attachmentAt(fx, cf)
	end
	return cf, fx.mainAttach
end

local function addEmitter(fx, e, baseScale)
	table.insert(fx.emitters, e)
	fx.baseTS[e] = baseScale
	emitterFx[e] = fx
	e.TimeScale = baseScale * (if fx.timeScaled then currentTimeScale() else 1)
end

local function spawnParticles(fx, L)
	local s = fx.scale
	local cf, attach = layerFrame(fx, L)
	local cache = if s == 1 then L.__seq else nil
	if not cache then
		cache = {
			size = numberSequence(L.size, 0, 1000, s, 1),
			transparency = numberSequence(L.transparency, 0, 1, 1, { 0, 1 }),
			color = colorSequence(L.color),
			squash = if L.squash ~= nil then numberSequence(L.squash, -3, 3, 1, 0) else nil,
		}
		if s == 1 then
			L.__seq = cache
		end
	end
	local e = Instance.new("ParticleEmitter")
	e.Name = "L" .. L.index
	e.Enabled = false
	e.Rate = 0
	e.Lifetime = numberRange(L.lifetime, 1, 1, 0, 20)
	e.Speed = numberRange(L.speed, 5, s)
	local sx, sy = pairOf(L.spread, 0)
	e.SpreadAngle = Vector2.new(sx, sy)
	e.Size = cache.size
	e.Transparency = cache.transparency
	e.Color = cache.color
	setIf(e, "Squash", cache.squash)
	setIf(e, "LightEmission", if L.lightEmission ~= nil then n(L.lightEmission, 0, 0, 1) else nil)
	setIf(e, "LightInfluence", if L.lightInfluence ~= nil then n(L.lightInfluence, 1, 0, 1) else nil)
	setIf(e, "Brightness", if L.brightness ~= nil then n(L.brightness, 1, 0, 1000) else nil)
	setIf(e, "Drag", if L.drag ~= nil then n(L.drag, 0, -100, 100) else nil)
	if typeof(L.acceleration) == "Vector3" then
		e.Acceleration = L.acceleration * s
	end
	if L.rotation ~= nil then
		e.Rotation = numberRange(L.rotation, 0, 1)
	end
	if L.rotSpeed ~= nil then
		e.RotSpeed = numberRange(L.rotSpeed, 0, 1)
	end
	setIf(e, "Orientation", ORIENT[choice(L.orientation, { "facing", "facingUp", "parallel", "perpendicular" }, "")])
	setIf(e, "ZOffset", if L.zoffset ~= nil then n(L.zoffset, 0) else nil)
	setIf(e, "EmissionDirection", NORMAL[choice(L.direction, DIRS, "up")])
	if L.lockedToPart ~= nil then
		e.LockedToPart = L.lockedToPart == true
	end
	if type(L.flipbook) == "table" then
		local fb = FxMath.normalizeKeys(L.flipbook, FxMath.NESTED_KEYS.flipbook)
		setIf(e, "FlipbookLayout", FLIP_LAYOUT[choice(fb.layout, { "2x2", "4x4", "8x8" }, "4x4")])
		setIf(e, "FlipbookMode", FLIP_MODE[choice(fb.mode, { "loop", "oneshot", "pingpong", "random" }, "loop")])
		if fb.fps ~= nil then
			e.FlipbookFramerate = numberRange(fb.fps, 30, 1)
		end
		if fb.random ~= nil then
			e.FlipbookStartRandom = fb.random == true
		end
	end
	applyTexture(e, "Texture", L.texture)
	if type(L.shape) == "table" then
		local sh = FxMath.normalizeKeys(L.shape, FxMath.NESTED_KEYS.shape)
		local p = makePart(cf)
		table.insert(fx.owned, p)
		if typeof(sh.size) == "Vector3" then
			p.Size = Vector3.new(math.max(sh.size.X * s, 0.01), math.max(sh.size.Y * s, 0.01), math.max(sh.size.Z * s, 0.01))
		else
			p.Size = Vector3.one * math.max(n(sh.size, 1, 0, 1000) * s, 0.01)
		end
		getHost()
		p.Parent = folder
		setIf(e, "Shape", SHAPE[choice(sh.kind, { "sphere", "box", "disc", "cylinder" }, "sphere")])
		setIf(e, "ShapeStyle", SHAPE_STYLE[choice(sh.style, { "volume", "surface" }, "volume")])
		setIf(e, "ShapeInOut", SHAPE_INOUT[choice(sh.inOut, { "outward", "inward", "both" }, "outward")])
		if sh.partial ~= nil then
			e.ShapePartial = n(sh.partial, 1, 0, 1)
		end
		e.Parent = p
	else
		e.Parent = attach
	end
	addEmitter(fx, e, n(L.timeScale, 1, 0, 1))
	if L.count ~= nil then
		local count = math.floor(n(L.count, 10, 0, 1000) * fx.intensity + 0.5)
		if count > 0 then
			e:Emit(count)
		end
	else
		e.Rate = n(L.rate, 10, 0, 1000) * fx.intensity
		e.Enabled = true
		table.insert(fx.continuous, e)
		local d = n(L.duration, 0, 0, 600)
		if d > 0 then
			schedule(fx, d, function()
				e.Enabled = false
			end)
		end
	end
end

-- A beam end: a Vector3 offset in the effect's frame, or a part / attachment / model to reach.
local function beamEnd(fx, v, cf, axisCF)
	if typeof(v) == "Instance" then
		if v:IsA("Attachment") then
			return v, false
		end
		local part = if v:IsA("BasePart") then v elseif v:IsA("Model") then (v.PrimaryPart
			or v:FindFirstChildWhichIsA("BasePart", true)) else nil
		if part then
			local a = Instance.new("Attachment")
			a.Name = "KitVFXBeamEnd"
			a.CFrame = part.CFrame:ToObjectSpace(CFrame.new(part.Position) * axisCF)
			a.Parent = part
			table.insert(fx.owned, a)
			return a, false
		end
	end
	local offset = if typeof(v) == "Vector3" then v * fx.scale else Vector3.zero
	local pos = cf:PointToWorldSpace(offset)
	return attachmentAt(fx, CFrame.new(pos) * axisCF), true
end

local function spawnBeam(fx, L)
	local s = fx.scale
	local cf = layerCF(fx, L)
	-- the attachments' X axis points at the effect's up, so curve bows the beam toward up
	local axisCF = CFrame.fromMatrix(Vector3.zero, cf.UpVector, cf.LookVector)
	local a0, own0 = beamEnd(fx, L.from, cf, axisCF)
	local a1 = beamEnd(fx, L.to, cf, axisCF)
	local b = Instance.new("Beam")
	b.Attachment0, b.Attachment1 = a0, a1
	local w0, w1 = pairOf(L.width, 1)
	b.Width0, b.Width1 = w0 * s, w1 * s
	b.Color = colorSequence(L.color)
	b.Transparency = numberSequence(L.transparency, 0, 1, 1, 0)
	applyTexture(b, "Texture", L.texture)
	setIf(b, "TextureSpeed", if L.textureSpeed ~= nil then n(L.textureSpeed, 1) else nil)
	setIf(b, "TextureLength", if L.textureLength ~= nil then n(L.textureLength, 1, 0.001) * s else nil)
	setIf(b, "TextureMode", TEXTURE_MODE[choice(L.textureMode, { "stretch", "wrap", "static" }, "")])
	setIf(b, "LightEmission", if L.lightEmission ~= nil then n(L.lightEmission, 0, 0, 1) else nil)
	setIf(b, "LightInfluence", if L.lightInfluence ~= nil then n(L.lightInfluence, 1, 0, 1) else nil)
	setIf(b, "Brightness", if L.brightness ~= nil then n(L.brightness, 1, 0, 1000) else nil)
	local c0, c1 = pairOf(L.curve, 0)
	b.CurveSize0, b.CurveSize1 = c0 * s, -c1 * s
	b.Segments = math.floor(n(L.segments, 10, 1, 1000))
	b.FaceCamera = L.faceCamera ~= false
	setIf(b, "ZOffset", if L.zoffset ~= nil then n(L.zoffset, 0) else nil)
	if own0 then
		b.Parent = a0
	else
		b.Parent = getHost()
		table.insert(fx.owned, b)
	end
	table.insert(fx.beams, b)
	local d = n(L.duration, 0.3, 0, 600)
	if d > 0 then
		local fade = n(L.fadeOut, math.min(0.15, d * 0.5), 0, 10)
		schedule(fx, d, function()
			if fade > 0 then
				tween(fx, b, TweenInfo.new(fade, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Width0 = 0, Width1 = 0 })
			else
				b.Enabled = false
			end
		end)
	end
end

local function spawnLight(fx, L)
	local _, attach = layerFrame(fx, L)
	local spot = if type(L.spot) == "table" then FxMath.normalizeKeys(L.spot, FxMath.NESTED_KEYS.spot) else nil
	local light = Instance.new(if spot then "SpotLight" else "PointLight")
	light.Color = toColor(L.color) or WHITE
	light.Range = math.min(n(L.range, 12, 0, 60) * fx.scale, 60)
	light.Shadows = L.shadows == true
	if spot then
		light.Angle = n(spot.angle, 45, 0, 180)
		setIf(light, "Face", NORMAL[choice(spot.face, DIRS, "forward")])
	end
	local peak = n(L.brightness, 2, 0, 1000) * fx.intensity
	local d = n(L.duration, 0.25, 0, 600)
	local attack = math.min(n(L.attack, 0, 0, 10), d)
	light.Brightness = if attack > 0 then 0 else peak
	light.Parent = attach
	table.insert(fx.lights, light)
	registerLight(light)
	if attack > 0 then
		tween(fx, light, TweenInfo.new(attack, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Brightness = peak })
	end
	if d > attack then
		schedule(fx, attack, function()
			if light.Parent then
				tween(fx, light, TweenInfo.new(d - attack, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{ Brightness = 0 })
			end
		end)
	end
end

local function toSize(v, default, s)
	if typeof(v) == "Vector3" then
		return v * s
	end
	return Vector3.one * (n(v, default, 0) * s)
end

local function flashPart(fx, cf, meshType)
	local p = takePart()
	table.insert(fx.parts, p)
	p.CFrame = cf
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = meshType
	mesh.Parent = p
	return p, mesh
end

local function spawnFlash(fx, L)
	local s = fx.scale
	local cf = layerCF(fx, L)
	local shape = choice(L.shape, { "sphere", "block", "mesh" }, "sphere")
	local meshType = if shape == "mesh" then Enum.MeshType.FileMesh elseif shape == "block" then Enum.MeshType.Brick
		else Enum.MeshType.Sphere
	local p, mesh = flashPart(fx, cf, meshType)
	if shape == "mesh" then
		if type(L.mesh) == "number" then
			mesh.MeshId = "rbxassetid://" .. tostring(math.floor(L.mesh))
		elseif FxMath.isContentId(L.mesh) then
			mesh.MeshId = L.mesh
		end
		applyTexture(mesh, "TextureId", L.meshTexture, false)
	end
	local from, to
	if type(L.size) == "table" then
		from, to = toSize(L.size[1], 2, s), toSize(L.size[2] or L.size[1], 2, s)
	else
		from = toSize(L.size, 2, s)
		to = from
	end
	mesh.Scale = from
	p.Material = MATERIAL[choice(L.material, MATERIAL_CHOICES, "neon")] or Enum.Material.Neon
	p.Color = toColor(L.color) or WHITE
	local t0, t1 = 0, 1
	if L.transparency ~= nil then
		t0, t1 = pairOf(L.transparency, 0)
	end
	p.Transparency = math.clamp(t0, 0, 1)
	local d = n(L.duration, 0.12, 0, 10)
	if d > 0 then
		local info = tweenInfo(d, L.ease, "quint", "out")
		tween(fx, mesh, info, { Scale = to })
		tween(fx, p, info, { Transparency = math.clamp(t1, 0, 1) })
		if L.spin ~= nil then
			addSpin(fx, p, n(L.spin, 0), d, (FxMath.easeFn(L.ease, nil, "quint", "out")))
		end
	end
end

local function spawnRing(fx, L)
	local s = fx.scale
	local d0, d1 = pairOf(L.size, 1)
	if L.size == nil then
		d0, d1 = 1, 8
	end
	d0, d1 = d0 * s, d1 * s
	local d = n(L.duration, 0.35, 0.01, 10)
	local flat = L.flat ~= false
	local transparency = numberSequence(L.transparency, 0, 1, 1, { 0, 1 })
	local color = colorSequence(L.color)
	if L.texture ~= nil then
		-- a single particle that grows along the ease: the textured, crisp ring
		local _, attach = layerFrame(fx, L)
		local e = Instance.new("ParticleEmitter")
		e.Name = "Ring" .. L.index
		e.Enabled = false
		e.Rate = 0
		e.Lifetime = NumberRange.new(d)
		e.Speed = NumberRange.new(if flat then 0.001 else 0)
		e.SpreadAngle = Vector2.zero
		e.Rotation = NumberRange.new(0)
		e.RotSpeed = NumberRange.new(0)
		setIf(e, "EmissionDirection", NORMAL.up)
		setIf(e, "Orientation", if flat then ORIENT.perpendicular else ORIENT.facing)
		local list = FxMath.easeKeypoints(d0, d1, L.ease, 8)
		local kps = table.create(#list)
		for i, k in list do
			kps[i] = NumberSequenceKeypoint.new(k.t, math.max(k.v, 0))
		end
		e.Size = NumberSequence.new(kps)
		e.Transparency = transparency
		e.Color = color
		setIf(e, "LightEmission", if L.lightEmission ~= nil then n(L.lightEmission, 0, 0, 1) else nil)
		setIf(e, "Brightness", if L.brightness ~= nil then n(L.brightness, 1, 0, 1000) else nil)
		e.LockedToPart = true
		applyTexture(e, "Texture", L.texture)
		e.Parent = attach
		addEmitter(fx, e, 1)
		e:Emit(1)
		return
	end
	-- no texture: a flattened sphere (forcefield by default: bright rim, clear middle) that grows and fades
	local p, mesh = flashPart(fx, layerCF(fx, L), Enum.MeshType.Sphere)
	local th = n(L.thickness, 0.2, 0.01, 100) * s
	mesh.Scale = Vector3.new(d0, th, d0)
	p.Material = MATERIAL[choice(L.material, MATERIAL_CHOICES, "forcefield")] or Enum.Material.ForceField
	local c0 = color.Keypoints[1].Value
	local c1 = color.Keypoints[#color.Keypoints].Value
	local t0, t1 = firstLast(transparency)
	p.Color = c0
	p.Transparency = t0
	local info = tweenInfo(d, L.ease, "quint", "out")
	tween(fx, mesh, info, { Scale = Vector3.new(d1, th, d1) })
	tween(fx, p, TweenInfo.new(d, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Transparency = t1, Color = c1 })
end

local function spawnDecal(fx, L)
	local s = fx.scale
	local cf = layerCF(fx, L)
	local s0, s1 = pairOf(L.size, 4)
	s0, s1 = math.max(s0 * s, 0.05), math.max(s1 * s, 0.05)
	local lo, hi = pairOf(L.rotation, 0)
	local degrees = lo + (hi - lo) * math.random()
	local p = takePart()
	table.insert(fx.parts, p)
	p.Size = Vector3.new(s0, 0.05, s0)
	p.CFrame = cf * CFrame.new(0, 0.05, 0) * CFrame.Angles(0, math.rad(degrees), 0)
	local decal = Instance.new("Decal")
	decal.Face = Enum.NormalId.Top
	decal.Color3 = toColor(L.color) or WHITE
	local t0, t1 = 0, 0
	if L.transparency ~= nil then
		t0, t1 = pairOf(L.transparency, 0)
	end
	decal.Transparency = math.clamp(t0, 0, 1)
	applyTexture(decal, "Texture", L.texture)
	decal.Parent = p
	local grow = n(L.grow, 0.12, 0, 10)
	if s1 ~= s0 then
		tween(fx, p, TweenInfo.new(math.max(grow, 0.01), Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
			{ Size = Vector3.new(s1, 0.05, s1) })
	end
	local d = n(L.duration, 2, 0, 600)
	local fade = math.min(n(L.fade, math.min(0.5, d * 0.5), 0, 60), d)
	if d - fade > 0 and t1 ~= t0 then
		tween(fx, decal, TweenInfo.new(d - fade, Enum.EasingStyle.Linear), { Transparency = math.clamp(t1, 0, 1) })
	end
	schedule(fx, d - fade, function()
		tween(fx, decal, TweenInfo.new(math.max(fade, 0.01), Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Transparency = 1 })
	end)
end

local SPAWN = { particles = spawnParticles, beam = spawnBeam, light = spawnLight, flash = spawnFlash, ring = spawnRing,
	decal = spawnDecal }

-- How long a layer lives after its delay (math.huge: until stop()).
local function layerLife(L)
	local k = L.kind
	if k == "particles" then
		local life = math.clamp(rangeMax(L.lifetime, 1), 0, 20) / math.max(n(L.timeScale, 1, 0, 1), 0.05)
		if L.count ~= nil then
			return life
		end
		local d = n(L.duration, 0, 0, 600)
		return if d > 0 then d + life else math.huge
	elseif k == "beam" then
		local d = n(L.duration, 0.3, 0, 600)
		return if d > 0 then d + n(L.fadeOut, math.min(0.15, d * 0.5), 0, 10) else math.huge
	elseif k == "light" then
		local d = n(L.duration, 0.25, 0, 600)
		return if d > 0 then d else math.huge
	elseif k == "flash" then
		return n(L.duration, 0.12, 0, 10)
	elseif k == "ring" then
		return n(L.duration, 0.35, 0.01, 10)
	end
	return n(L.duration, 2, 0, 600)
end

-- Rough peak cost of a plan for the budget: particles alive at once, and lights.
local function planCost(plan)
	if plan.cost then
		return plan.cost
	end
	local particles, lights = 0, 0
	for _, L in plan.layers do
		if L.kind == "particles" then
			if L.count ~= nil then
				particles += n(L.count, 10, 0, 1000)
			else
				local life = math.clamp(rangeMax(L.lifetime, 1), 0, 20)
				local d = n(L.duration, 0, 0, 600)
				particles += n(L.rate, 10, 0, 1000) * (if d > 0 then math.min(d, life) else life)
			end
		elseif L.kind == "ring" and L.texture ~= nil then
			particles += 1
		elseif L.kind == "light" then
			lights += 1
		end
	end
	plan.cost = { particles = particles, lights = lights }
	return plan.cost
end

-- Validates a spec once (warning about each problem) and keeps a normalized copy of its layers.
local function prepare(spec, label)
	local plan = plans[spec]
	if plan ~= nil then
		return plan or nil
	end
	for _, p in FxMath.validateEffect(spec) do
		warnOnce("spec:" .. label .. ":" .. p, "effect '" .. label .. "': " .. p)
	end
	local root = spec
	if FxMath.findKey(spec, "layers") == nil and #spec > 0 then
		root = { layers = spec }
	end
	local top = FxMath.normalizeKeys(root, FxMath.EFFECT_KEYS)
	local layers = {}
	if type(top.layers) == "table" then
		for i, raw in ipairs(top.layers) do
			if type(raw) == "table" then
				local kind = FxMath.enumValue(FxMath.findKey(raw, "kind"), FxMath.KINDS)
				local keys = kind and FxMath.layerKeys(kind)
				if keys then
					local L = FxMath.normalizeKeys(raw, keys)
					L.kind = kind
					L.index = i
					L.delay = n(L.delay, 0, 0, 30)
					table.insert(layers, L)
				end
			end
		end
	end
	if #layers == 0 then
		plans[spec] = false
		return nil
	end
	plan = { layers = layers, family = if type(top.family) == "string" then top.family else nil,
		budget = if type(top.budget) == "table" then FxMath.normalizeKeys(top.budget, FxMath.NESTED_KEYS.budget) else nil }
	plans[spec] = plan
	return plan
end

local function budgetFor(family, plan)
	local b = budgets[family]
	if b then
		return b
	end
	local caps = table.clone(VFX.defaultBudget)
	local override = budgetCaps[family] or plan.budget
	if override then
		for _, k in { "effects", "particles", "lights" } do
			if FxMath.isNumber(override[k]) then
				caps[k] = override[k]
			end
		end
	end
	b = FxMath.budget(caps)
	budgets[family] = b
	return b
end

local function upFrame(pos, up, hint)
	local f = hint - up * hint:Dot(up)
	if f.Magnitude < 1e-4 then
		local other = if math.abs(up.Y) < 0.9 then Vector3.yAxis else Vector3.xAxis
		f = other - up * other:Dot(up)
	end
	f = f.Unit
	local back = -f
	return CFrame.fromMatrix(pos, up:Cross(back), up, back)
end

-- at (Vector3, CFrame, BasePart, Attachment or Model) -> the effect's frame, and the part to follow if any.
local function frameOf(at, o)
	local cf, follow = nil, nil
	local ty = typeof(at)
	if ty == "Vector3" then
		cf = CFrame.new(at)
	elseif ty == "CFrame" then
		cf = at
	elseif ty == "Instance" then
		if at:IsA("Attachment") then
			cf = at.WorldCFrame
			if o.follow ~= false and at.Parent and at.Parent:IsA("BasePart") then
				follow = at.Parent
			end
		elseif at:IsA("BasePart") then
			cf = at.CFrame
			if o.follow then
				follow = at
			end
		elseif at:IsA("Model") then
			cf = at:GetPivot()
			if o.follow then
				follow = at.PrimaryPart or at:FindFirstChildWhichIsA("BasePart", true)
			end
		end
	end
	if not cf then
		return nil, nil
	end
	local normal, direction = o.normal, o.direction
	if typeof(normal) == "Vector3" and normal.Magnitude > 1e-6 then
		cf = upFrame(cf.Position, normal.Unit, if typeof(direction) == "Vector3" then direction else cf.LookVector)
	elseif typeof(direction) == "Vector3" and direction.Magnitude > 1e-6 then
		local dir = direction.Unit
		cf = CFrame.lookAt(cf.Position, cf.Position + dir, if math.abs(dir.Y) > 0.999 then Vector3.zAxis else Vector3.yAxis)
	end
	return cf, follow
end

local function spawnLayer(fx, L)
	local ok, err = pcall(SPAWN[L.kind], fx, L)
	if not ok then
		warnOnce("spawn:" .. fx.label .. ":" .. L.index .. ":" .. tostring(err), "effect '" .. fx.label .. "': layer "
			.. L.index .. " (" .. L.kind .. ") failed: " .. tostring(err))
	end
end

local function finish(fx, tries)
	-- particles slowed by slow motion (or held by a hitstop) live longer in real time: wait out what they lost
	tries = tries or 0
	local now = os.clock()
	fx.lag += (now - fx.tsAt) * (1 - fx.ts)
	fx.tsAt = now
	if tries < 40 and #fx.emitters > 0 and fx.lag > 0.02 then
		local lost = fx.lag
		fx.lag = 0
		schedule(fx, lost, function()
			finish(fx, tries + 1)
		end)
		return
	end
	fx:destroy("done")
end

local debugLast = {}
local function debugEvent(name)
	if not Debug then
		return
	end
	local now = os.clock()
	if (debugLast[name] or -1) + 0.25 > now then
		return
	end
	debugLast[name] = now
	Debug.event("vfx", { name = name })
end

-- Plays an effect spec at `at` (Vector3, CFrame, BasePart, Attachment or Model) and returns a handle
-- (:stop(), :destroy(), :andThen(fn), .alive). opts: scale (sizes, speeds, ranges), intensity (counts, rates,
-- light brightness), normal (Vector3: the effect's up, e.g. a surface normal), direction (Vector3: its forward),
-- follow (move with the part; Attachments follow by default), timeScaled (default true), onDone(reason).
function VFX.effect(spec, at, opts, label)
	if type(spec) ~= "table" then
		warnOnce("effect:type:" .. typeof(spec), "effect needs a spec table (or use VFX.play with a preset name)")
		return NULL
	end
	label = if type(label) == "string" then label elseif type(spec.family) == "string" then spec.family else "effect"
	local plan = prepare(spec, label)
	if not plan then
		return NULL
	end
	local o = normalize(opts or {}, FxMath.EFFECT_OPTS, "effect")
	local cf, followPart = frameOf(at, o)
	if not cf then
		warnOnce("at:" .. label, "effect '" .. label .. "': at must be a Vector3, CFrame, BasePart, Attachment or Model, got "
			.. typeof(at))
		return NULL
	end
	getHost()
	if IS_CLIENT then
		hookTimeScale()
	end
	nextId += 1
	local fx = setmetatable({ id = nextId, label = label, family = plan.family or label, alive = true, stopped = false,
		cf = cf, followPart = followPart, localCF = if followPart then followPart.CFrame:ToObjectSpace(cf) else nil,
		scale = num(o.scale, 1, 0.01, 100, "effect scale"), intensity = num(o.intensity, 1, 0, 100, "effect intensity"),
		timeScaled = o.timeScaled ~= false, threads = {}, tweens = {}, attachments = {}, parts = {}, owned = {},
		emitters = {}, continuous = {}, lights = {}, beams = {}, baseTS = {}, waiters = {}, conns = {}, lag = 0,
		tsAt = os.clock(), ts = 1 }, Effect)
	if fx.timeScaled then
		fx.ts = currentTimeScale()
	end
	if followPart then
		table.insert(fx.conns, followPart.AncestryChanged:Connect(function()
			if not followPart:IsDescendantOf(game) then
				fx:stop()
			end
		end))
	end
	if type(o.onDone) == "function" then
		table.insert(fx.waiters, o.onDone)
	end
	live[fx.id] = fx
	local budget = budgetFor(fx.family, plan)
	fx.budget = budget
	local cost = planCost(plan)
	for _, id in budget:add(fx.id, { particles = cost.particles * fx.intensity, lights = cost.lights }) do
		local old = live[id]
		if old then
			old:destroy("evicted")
		end
	end
	local longest = 0
	for _, L in plan.layers do
		longest = math.max(longest, L.delay + layerLife(L))
		if L.delay > 0 then
			schedule(fx, L.delay, function()
				if not fx.stopped then
					spawnLayer(fx, L)
				end
			end)
		else
			spawnLayer(fx, L)
		end
	end
	if longest < math.huge then
		schedule(fx, longest + 0.05, function()
			finish(fx)
		end)
	end
	if label ~= "effect" then
		debugEvent(label)
	end
	return fx
end

-- Stops emitting (pending layers are skipped, lights and beams fade) and cleans up once live particles are gone.
function Effect:stop()
	if not self.alive or self.stopped then
		return self
	end
	self.stopped = true
	for _, th in self.threads do
		pcall(task.cancel, th)
	end
	table.clear(self.threads)
	for _, e in self.continuous do
		e.Enabled = false
	end
	local fadeInfo = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	for _, light in self.lights do
		if light.Parent then
			tween(self, light, fadeInfo, { Brightness = 0 })
		end
	end
	for _, b in self.beams do
		if b.Parent then
			tween(self, b, fadeInfo, { Width0 = 0, Width1 = 0 })
		end
	end
	local wait = 0.15
	for _, e in self.emitters do
		if e.Parent then
			local ts = math.max(e.TimeScale, 0.05)
			wait = math.max(wait, e.Lifetime.Max / ts)
		end
	end
	schedule(self, math.min(wait, 30) + 0.05, function()
		self:destroy("stopped")
	end)
	return self
end

-- Removes everything now. reason is passed to andThen callbacks ("destroyed" by default).
function Effect:destroy(reason)
	if not self.alive then
		return
	end
	self.alive = false
	self.endReason = if type(reason) == "string" then reason else "destroyed"
	live[self.id] = nil
	if self.budget then
		self.budget:remove(self.id)
	end
	for _, th in self.threads do
		if th ~= coroutine.running() then
			pcall(task.cancel, th)
		end
	end
	for _, tw in self.tweens do
		tw:Cancel()
	end
	for _, inst in self.owned do
		inst:Destroy()
	end
	for _, a in self.attachments do
		a:Destroy()
	end
	for _, p in self.parts do
		releasePart(p)
	end
	for _, e in self.emitters do
		emitterFx[e] = nil
	end
	for _, c in self.conns do
		c:Disconnect()
	end
	for _, fn in self.waiters do
		task.spawn(fn, self.endReason)
	end
	self.threads, self.tweens, self.owned, self.attachments, self.parts = {}, {}, {}, {}, {}
	self.emitters, self.continuous, self.lights, self.beams, self.waiters, self.conns = {}, {}, {}, {}, {}, {}
end
Effect.Destroy = Effect.destroy

-- Calls fn(reason) when the effect ends: "done", "stopped", "evicted", "destroyed" or "invalid".
function Effect:andThen(fn)
	if type(fn) ~= "function" then
		return self
	end
	if self.alive then
		table.insert(self.waiters, fn)
	else
		task.spawn(fn, self.endReason or "invalid")
	end
	return self
end

------------------------------------------------------------------------------------------------ presets
local presets = {}

-- Registers a named effect: a spec table (validated now) or a function(opts) -> spec for variants.
function VFX.preset(name, spec)
	if type(name) ~= "string" then
		warnOnce("preset:name", "preset needs a string name")
		return
	end
	if type(spec) ~= "table" and type(spec) ~= "function" then
		warnOnce("preset:" .. name, "preset '" .. name .. "' needs a spec table or a function returning one")
		return
	end
	presets[name] = spec
	if type(spec) == "table" then
		prepare(spec, name)
	end
end

function VFX.has(name)
	return presets[name] ~= nil
end

function VFX.names()
	local out = {}
	for name in presets do
		table.insert(out, name)
	end
	table.sort(out)
	return out
end

-- Plays a preset by name (see VFX.effect for at and opts).
function VFX.play(name, at, opts)
	local spec = presets[name]
	if spec == nil then
		local guess = if type(name) == "string" then FxMath.closest(name, VFX.names()) else nil
		warnOnce("play:" .. tostring(name), "no preset '" .. tostring(name) .. "'"
			.. (if guess then " (did you mean '" .. guess .. "'?)" else ""))
		return NULL
	end
	if type(spec) == "function" then
		local ok, built = pcall(spec, if type(opts) == "table" then opts else {})
		if not ok or type(built) ~= "table" then
			warnOnce("preset:fn:" .. name, "preset '" .. name .. "' function failed: " .. tostring(built))
			return NULL
		end
		-- the options may carry the variant's own keys: pass on only the effect options, without warnings
		return VFX.effect(built, at, if type(opts) == "table" then FxMath.normalizeKeys(opts, FxMath.EFFECT_OPTS) else nil,
			name)
	end
	return VFX.effect(spec, at, opts, name)
end

-- Caps for one effect family (a preset's name, or spec.family): { effects = n, particles = n, lights = n }.
function VFX.budget(family, caps)
	if type(family) ~= "string" or type(caps) ~= "table" then
		warnOnce("budget:args", "budget(family, { effects, particles, lights })")
		return
	end
	budgetCaps[family] = FxMath.normalizeKeys(caps, FxMath.NESTED_KEYS.budget)
	budgets[family] = nil
end

-- Every problem in a spec ("layers[2].lifetime: ..."); empty when valid.
function VFX.validate(spec)
	return FxMath.validateEffect(spec)
end

-- Ends every effect now (e.g. between rounds).
function VFX.clear()
	local all = {}
	for _, fx in live do
		table.insert(all, fx)
	end
	for _, fx in all do
		fx:destroy("destroyed")
	end
end

-- A short light pulse: brightness at once, fading out over seconds.
function VFX.flashLight(at, color, brightness, range, seconds)
	local d = num(seconds, 0.2, 0, 10, "flashLight seconds")
	return VFX.effect({ family = "flashLight", layers = { { kind = "light", color = color, brightness = brightness,
		range = range, duration = if d > 0 then d else 0.2 } } }, at, nil, "flashLight")
end

------------------------------------------------------------------------------------------------ hitstop
local function freeze(obj, isTrack, speed, untilT)
	local f = frozen[obj]
	if f then
		local fx = not f.track and emitterFx[obj]
		if fx and untilT > f.untilT then
			fx.lag += untilT - f.untilT
		end
		f.untilT = math.max(f.untilT, untilT)
		return
	end
	if isTrack then
		frozen[obj] = { restore = obj.Speed, untilT = untilT, track = true }
		obj:AdjustSpeed(speed)
	else
		frozen[obj] = { restore = obj.TimeScale, untilT = untilT, track = false }
		obj.TimeScale = 0
		local fx = emitterFx[obj]
		if fx then
			fx.lag += math.max(untilT - os.clock(), 0)
		end
	end
end

local releaseFrozen
releaseFrozen = function()
	local now = os.clock()
	local nextAt = math.huge
	for obj, f in frozen do
		if f.untilT > now + 1 / 60 then
			nextAt = math.min(nextAt, f.untilT)
		else
			frozen[obj] = nil
			pcall(function()
				if f.track then
					obj:AdjustSpeed(f.restore)
				else
					local fx = emitterFx[obj]
					obj.TimeScale = if fx and fx.alive and fx.timeScaled then (fx.baseTS[obj] or 1) * currentTimeScale()
						else f.restore
				end
			end)
		end
	end
	if nextAt < math.huge then
		task.delay(math.max(nextAt - os.clock(), 0) + 0.005, releaseFrozen)
	end
end

local function animatorOf(x)
	if typeof(x) ~= "Instance" then
		return nil
	end
	if x:IsA("Animator") then
		return x
	elseif x:IsA("Humanoid") or x:IsA("AnimationController") then
		return x:FindFirstChildOfClass("Animator")
	elseif x:IsA("Model") then
		local h = x:FindFirstChildOfClass("Humanoid") or x:FindFirstChildOfClass("AnimationController")
		return h and h:FindFirstChildOfClass("Animator")
	end
	return nil
end

-- Freezes the moment for `seconds` (40-120 ms reads as impact): the local character's playing animations (and any
-- animators / tracks / emitters / effects given) pause, and CameraRig.slowmo holds time. Physics is untouched.
-- opts: character (default true), animators, tracks, emitters (ParticleEmitters or effect handles), camera
-- (default true), timeScale (during the stop, default 0), speed (animation speed during the stop, default 0).
function VFX.hitstop(seconds, opts)
	if not IS_CLIENT then
		return
	end
	seconds = num(seconds, 0.08, 0, 1, "hitstop seconds")
	if seconds > 0.3 then
		warnOnce("hitstop:long", "hitstop of " .. seconds .. " s reads as lag; 0.04-0.12 s is the usual range")
	end
	if seconds <= 0 then
		return
	end
	local o = normalize(opts or {}, FxMath.HITSTOP_KEYS, "hitstop")
	local untilT = os.clock() + seconds
	local speed = n(o.speed, 0, 0, 1)
	local function freezeAnimator(animator)
		local ok, tracks = pcall(animator.GetPlayingAnimationTracks, animator)
		if ok then
			for _, t in tracks do
				freeze(t, true, speed, untilT)
			end
		end
	end
	if o.character ~= false then
		local player = Players.LocalPlayer
		local a = player and player.Character and animatorOf(player.Character)
		if a then
			freezeAnimator(a)
		end
	end
	if type(o.animators) == "table" then
		for _, x in o.animators do
			local a = animatorOf(x)
			if a then
				freezeAnimator(a)
			end
		end
	end
	if type(o.tracks) == "table" then
		for _, t in o.tracks do
			if typeof(t) == "Instance" and t:IsA("AnimationTrack") then
				freeze(t, true, speed, untilT)
			end
		end
	end
	if type(o.emitters) == "table" then
		for _, e in o.emitters do
			if typeof(e) == "Instance" and e:IsA("ParticleEmitter") then
				freeze(e, false, 0, untilT)
			elseif type(e) == "table" and getmetatable(e) == Effect then
				for _, em in e.emitters do
					if em.Parent then
						freeze(em, false, 0, untilT)
					end
				end
			end
		end
	end
	if o.camera ~= false then
		local r = rig()
		if r and type(r.slowmo) == "function" then
			r.slowmo(n(o.timeScale, 0, 0, 1), seconds, { rampIn = 0, rampOut = 0 })
		end
	end
	task.delay(seconds, releaseFrozen)
end

------------------------------------------------------------------------------------------------ screen accents
local overlay = nil
local function overlayGui()
	if overlay and overlay.gui.Parent then
		return overlay
	end
	local player = Players.LocalPlayer
	local pg = player and player:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return nil
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "KitVFXOverlay"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 90
	pcall(function()
		gui.ScreenInsets = Enum.ScreenInsets.None
	end)
	local flash = Instance.new("Frame")
	flash.Name = "Flash"
	flash.BorderSizePixel = 0
	flash.BackgroundColor3 = WHITE
	flash.BackgroundTransparency = 1
	flash.Size = UDim2.fromScale(1, 1)
	flash.ZIndex = 10
	flash.Parent = gui
	gui.Parent = pg
	overlay = { gui = gui, flash = flash, tween = nil }
	return overlay
end

-- A full-screen flash of colour that fades out over seconds; strength is its peak opacity (0..1).
function VFX.screenFlash(color, seconds, strength)
	if not IS_CLIENT then
		return
	end
	local ov = overlayGui()
	if not ov then
		return
	end
	local c = toColor(color)
	if not c then
		warnOnce("screenFlash:color", "screenFlash color must be a Color3, \"#RRGGBB\" or \"Tokens.color.<name>\"")
		c = WHITE
	end
	seconds = num(seconds, 0.15, 0.01, 10, "screenFlash seconds")
	strength = num(strength, 0.5, 0, 1, "screenFlash strength")
	local f = ov.flash
	if ov.tween then
		ov.tween:Cancel()
	end
	f.BackgroundColor3 = c
	f.BackgroundTransparency = math.min(f.BackgroundTransparency, 1 - strength)
	ov.tween = TweenService:Create(f, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundTransparency = 1 })
	ov.tween:Play()
end

local Vignette = {}
Vignette.__index = Vignette
local NULL_VIGNETTE = setmetatable({ alive = false, parts = {}, tweens = {} }, Vignette)

local EDGE_FALLOFF = nil
local function edgeFalloff()
	if not EDGE_FALLOFF then
		local kps = {}
		for i = 0, 6 do
			local t = i / 6
			kps[i + 1] = NumberSequenceKeypoint.new(t, t * t * (3 - 2 * t))
		end
		EDGE_FALLOFF = NumberSequence.new(kps)
	end
	return EDGE_FALLOFF
end

function Vignette:_to(target, seconds)
	for _, tw in self.tweens do
		tw:Cancel()
	end
	table.clear(self.tweens)
	local info = TweenInfo.new(math.max(seconds, 0.01), Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
	for _, part in self.parts do
		local tw = TweenService:Create(part.inst, info, { [part.prop] = target })
		table.insert(self.tweens, tw)
		tw:Play()
	end
end

-- Changes the vignette's strength (0..1) over seconds.
function Vignette:set(strength, seconds)
	if not self.alive then
		return self
	end
	self:_to(1 - n(strength, 0.6, 0, 1), n(seconds, 0.2, 0, 10))
	return self
end

-- Fades out over seconds and removes it.
function Vignette:stop(seconds)
	if not self.alive then
		return
	end
	self.alive = false
	local fade = n(seconds, 0.3, 0, 10)
	self:_to(1, fade)
	local holder = self.holder
	task.delay(fade + 0.05, function()
		holder:Destroy()
	end)
end
Vignette.Destroy = Vignette.stop

-- Edges darkened (or tinted) toward the centre: seconds = total time (nil: until :stop()). opts: strength (peak
-- opacity, 0.6), thickness (fraction of the screen, 0.3), fadeIn, fadeOut, texture (a painted vignette to use instead
-- of the gradient edges). Returns a handle with :set(strength, seconds) and :stop(seconds).
function VFX.vignette(color, seconds, opts)
	if not IS_CLIENT then
		return NULL_VIGNETTE
	end
	local ov = overlayGui()
	if not ov then
		return NULL_VIGNETTE
	end
	local o = normalize(opts or {}, FxMath.VIGNETTE_KEYS, "vignette")
	local c = toColor(color) or BLACK
	local strength = num(o.strength, 0.6, 0, 1, "vignette strength")
	local thickness = num(o.thickness, 0.3, 0.01, 1, "vignette thickness")
	local fadeIn = num(o.fadeIn, 0.08, 0, 10, "vignette fadeIn")
	local total = if seconds == nil or seconds == false then math.huge else num(seconds, 0.6, 0, 600, "vignette seconds")
	local fadeOut = num(o.fadeOut, if total < math.huge then math.min(0.4, total * 0.5) else 0.3, 0, 10, "vignette fadeOut")
	local holder = Instance.new("Frame")
	holder.Name = "Vignette"
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.fromScale(1, 1)
	holder.ZIndex = 5
	local parts = {}
	if o.texture ~= nil then
		local img = Instance.new("ImageLabel")
		img.BackgroundTransparency = 1
		img.Size = UDim2.fromScale(1, 1)
		img.ImageColor3 = c
		img.ImageTransparency = 1
		img.ScaleType = Enum.ScaleType.Stretch
		img.ZIndex = 5
		applyTexture(img, "Image", o.texture)
		img.Parent = holder
		table.insert(parts, { inst = img, prop = "ImageTransparency" })
	else
		local edges = {
			{ Vector2.new(0, 0), UDim2.fromScale(0, 0), UDim2.fromScale(1, thickness), 90 },
			{ Vector2.new(0, 1), UDim2.fromScale(0, 1), UDim2.fromScale(1, thickness), -90 },
			{ Vector2.new(0, 0), UDim2.fromScale(0, 0), UDim2.fromScale(thickness, 1), 0 },
			{ Vector2.new(1, 0), UDim2.fromScale(1, 0), UDim2.fromScale(thickness, 1), 180 },
		}
		for _, e in edges do
			local f = Instance.new("Frame")
			f.BorderSizePixel = 0
			f.BackgroundColor3 = c
			f.BackgroundTransparency = 1
			f.AnchorPoint = e[1]
			f.Position = e[2]
			f.Size = e[3]
			f.ZIndex = 5
			local g = Instance.new("UIGradient")
			g.Rotation = e[4]
			g.Transparency = edgeFalloff()
			g.Parent = f
			f.Parent = holder
			table.insert(parts, { inst = f, prop = "BackgroundTransparency" })
		end
	end
	holder.Parent = ov.gui
	local h = setmetatable({ holder = holder, parts = parts, tweens = {}, alive = true }, Vignette)
	h:_to(1 - strength, fadeIn)
	if total < math.huge then
		task.delay(math.max(total - fadeOut, fadeIn), function()
			h:stop(fadeOut)
		end)
	end
	return h
end

------------------------------------------------------------------------------------------------ trails
local Trail = {}
Trail.__index = Trail
local NULL_TRAIL = setmetatable({ alive = false }, Trail)

-- Turns the trail on or off (an off trail's ribbon fades out over its lifetime).
function Trail:enable(on)
	if self.alive then
		self.token = (self.token or 0) + 1
		self.trail.Enabled = on ~= false
	end
	return self
end

-- On for `seconds`, then off (a dash or a swing).
function Trail:burst(seconds)
	if not self.alive then
		return self
	end
	self.token = (self.token or 0) + 1
	local token = self.token
	self.trail.Enabled = true
	task.delay(n(seconds, 0.3, 0, 60), function()
		if self.alive and self.token == token then
			self.trail.Enabled = false
		end
	end)
	return self
end

function Trail:clear()
	if self.alive then
		self.trail:Clear()
	end
	return self
end

function Trail:destroy()
	if not self.alive then
		return
	end
	self.alive = false
	self.trail:Destroy()
	self.a0:Destroy()
	self.a1:Destroy()
end
Trail.Destroy = Trail.destroy

-- A Trail on `part` between two attachments `width` studs apart along the part's axis ("up", "right" or "forward")
-- around `offset`. spec: width, offset, axis, lifetime, color, transparency, widthScale, texture, textureMode,
-- textureLength, lightEmission, lightInfluence, brightness, minLength, maxLength, faceCamera, enabled (default true).
-- Returns a handle: :enable(on), :burst(seconds), :clear(), :destroy().
function VFX.trail(part, spec)
	if typeof(part) ~= "Instance" or not part:IsA("BasePart") then
		warnOnce("trail:part", "trail needs a BasePart to ride on, got " .. typeof(part))
		return NULL_TRAIL
	end
	spec = if type(spec) == "table" then spec else {}
	for _, p in FxMath.validateTrail(spec) do
		warnOnce("trail:" .. p, p)
	end
	local o = FxMath.normalizeKeys(spec, FxMath.NESTED_KEYS.trail)
	local width = n(o.width, 1, 0, 1000)
	local axis = choice(o.axis, { "up", "right", "forward" }, "up")
	local dir = if axis == "up" then Vector3.yAxis elseif axis == "right" then Vector3.xAxis else -Vector3.zAxis
	local center = if typeof(o.offset) == "Vector3" then o.offset else Vector3.zero
	local a0 = Instance.new("Attachment")
	a0.Name = "KitTrail0"
	a0.Position = center + dir * (width / 2)
	a0.Parent = part
	local a1 = Instance.new("Attachment")
	a1.Name = "KitTrail1"
	a1.Position = center - dir * (width / 2)
	a1.Parent = part
	local t = Instance.new("Trail")
	t.Attachment0, t.Attachment1 = a0, a1
	t.Lifetime = n(o.lifetime, 0.3, 0, 20)
	t.Color = colorSequence(o.color)
	t.Transparency = numberSequence(o.transparency, 0, 1, 1, { 0, 1 })
	if o.widthScale ~= nil then
		t.WidthScale = numberSequence(o.widthScale, 0, 1000, 1, 1)
	end
	applyTexture(t, "Texture", o.texture)
	setIf(t, "TextureMode", TEXTURE_MODE[choice(o.textureMode, { "stretch", "wrap", "static" }, "")])
	setIf(t, "TextureLength", if o.textureLength ~= nil then n(o.textureLength, 1, 0.001) else nil)
	setIf(t, "LightEmission", if o.lightEmission ~= nil then n(o.lightEmission, 0, 0, 1) else nil)
	setIf(t, "LightInfluence", if o.lightInfluence ~= nil then n(o.lightInfluence, 1, 0, 1) else nil)
	setIf(t, "Brightness", if o.brightness ~= nil then n(o.brightness, 1, 0, 1000) else nil)
	setIf(t, "MinLength", if o.minLength ~= nil then n(o.minLength, 0.1, 0) else nil)
	setIf(t, "MaxLength", if o.maxLength ~= nil then n(o.maxLength, 0, 0) else nil)
	if o.faceCamera ~= nil then
		t.FaceCamera = o.faceCamera == true
	end
	t.Enabled = o.enabled ~= false
	t.Parent = part
	return setmetatable({ trail = t, a0 = a0, a1 = a1, alive = true }, Trail)
end

------------------------------------------------------------------------------------------------ debug
if Debug and IS_CLIENT then
	Debug.register("__vfx", function(name, distance)
		if name == nil then
			return VFX.names()
		end
		local cam = workspace.CurrentCamera
		if not cam then
			return "no camera"
		end
		local pos = (cam.CFrame * CFrame.new(0, 0, -(tonumber(distance) or 12))).Position
		local h = VFX.play(tostring(name), pos)
		return if h.alive then "played " .. tostring(name) else "no preset " .. tostring(name)
	end, "play a VFX preset in front of the camera: name, distance (no arguments lists the presets)")
end

return VFX
