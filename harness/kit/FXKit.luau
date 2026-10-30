-- FXKit: a library of ready-made, tuned effects built on Kit.VFX, so games compose good effects instead of
-- hand-authoring them. Every preset has four looks (FXKit.setStyle or opts.style): "toon" (flat, opaque, chunky:
-- N64 / cel-shaded), "realistic" (soft smoke, lit, muted), "cozy" (pastel, warm, slow) and "neon" (additive, glowing).
--   FXKit.play("explosion", pos, { variant = "large" })        one-shots clean themselves up
--   local h = FXKit.play("boost_flame", exhaustPart)            continuous presets follow a part until h:stop()
--   h:set(0.4)                                                  continuous rate (e.g. by speed), 0..n
--   FXKit.playAll("level_up", character)                        from the server: every client plays it
--   FXKit.speedLines(speed / maxSpeed)   FXKit.weather("rain")   FXKit.tracer(muzzle, hitPos, { impact = "metal" })
--   FXKit.hitstop(0.6)   FXKit.punch(0.5)   FXKit.flash("#FFFFFF")   FXKit.slowmo(0.3, 0.8)
--   FXKit.texture("flame", "rbxassetid://123", { layout = "4x4", fps = 24 })   swap in generated sprites / flipbooks
-- opts: style, variant, color (the main colour: Color3 or "#RRGGBB"), scale, intensity, impact (0..1: land_dust),
-- normal (surface normal), direction (forward), follow, to (tracer / lightning / bolt end), area (weather size).
-- Names may carry the variant: "explosion_large", "muzzle_flash_shotgun", "fire_torch", "drift_sparks_3".
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Kit = script.Parent
local VFX = require(Kit:WaitForChild("VFX"))
local FxMath = require(Kit:WaitForChild("FxMath"))

-- (typed any: presets reference helpers defined further down)
local FXKit: any = {}
FXKit.STYLES = { "toon", "realistic", "cozy", "neon" }

local IS_CLIENT = RunService:IsClient()
local IS_SERVER = RunService:IsServer()
local REMOTE_NAME = "KitFXKit"
local currentStyle = "toon"

------------------------------------------------------------------------------------------------ helpers
local warned = {}
local function warnOnce(key, msg)
	if not warned[key] then
		warned[key] = true
		warn("[FXKit] " .. msg)
	end
end

local function optional(name)
	local inst = Kit:FindFirstChild(name)
	if inst and inst:IsA("ModuleScript") then
		local ok, mod = pcall(require, inst)
		if ok and type(mod) == "table" then
			return mod
		end
	end
	return nil
end

local function clamp01(x)
	return math.clamp(if type(x) == "number" and x == x then x else 0, 0, 1)
end

local function V(x, y, z)
	return Vector3.new(x, y, z)
end

------------------------------------------------------------------------------------------------ textures
-- Built-in Roblox content (present in every client install). FXKit.texture(slot, id) replaces any slot.
local TEX = {
	soft = "rbxasset://textures/particles/explosion01_implosion_main.dds", -- soft round glow
	circle = "rbxasset://textures/whiteCircle.png", -- hard disc (toon puffs, droplets)
	smoke = "rbxasset://textures/particles/smoke_main.dds", -- soft cloud
	puff = "rbxasset://textures/explosion.png", -- cloud puff
	star = "rbxasset://textures/particles/sparkles_main.dds", -- 4-point star
	glint = "rbxasset://textures/sparkle.png", -- small cross glint
	glow = "rbxasset://textures/glow.png", -- starburst glow
	ring = "rbxasset://textures/particles/explosion01_shockwave_main.dds", -- shockwave ring
	fireball = "rbxasset://textures/particles/explosion01_core_main.dds", -- fiery burst
	square = "rbxasset://textures/particles/SquareParticle.png",
	shard = "rbxasset://textures/triangle.png",
	vortex = "rbxasset://textures/particles/forcefield_vortex_main.dds", -- swirl ring
}
-- Semantic slots and the base texture they use unless overridden.
local ALIAS = { dust = "smoke", spark = "soft", flame = "soft", ember = "soft", drop = "soft", mist = "smoke",
	debris = "square", confetti = "square", leaf = "shard", petal = "circle", bubble = "ring", scorch = "smoke",
	streak = "soft", snow = "soft", magic = "soft" }
FXKit.SLOTS = {}
for k in TEX do
	table.insert(FXKit.SLOTS, k)
end
for k in ALIAS do
	table.insert(FXKit.SLOTS, k)
end
table.sort(FXKit.SLOTS)

local overrides = {} -- slot -> { id, flipbook }
local specCache = {} -- key -> spec

------------------------------------------------------------------------------------------------ styles
local STYLES = {
	toon = { name = "toon", emit = 0.1, influence = 0, fade = 0, life = 0.9, size = 1.15, count = 0.8, sat = 1.15,
		val = 1.04, warm = 0, light = 1, sparkGlow = 0.6, ringGlow = 0.5, bright = 1, opaque = true,
		slots = { dust = "circle", mist = "circle", spark = "circle", drop = "circle", streak = "circle", snow = "circle" },
		lines = { color = "#FFFFFF", thick = 5, alpha = 0.9 } },
	realistic = { name = "realistic", emit = 0, influence = 1, fade = 0.3, life = 1.1, size = 1, count = 1.2, sat = 0.8,
		val = 0.94, warm = 0, light = 1, sparkGlow = 1, ringGlow = 0.6, bright = 1, opaque = false,
		slots = {}, lines = { color = "#FFFFFF", thick = 2, alpha = 0.35 } },
	cozy = { name = "cozy", emit = 0.15, influence = 0.5, fade = 0.15, life = 1.25, size = 1.1, count = 0.9, sat = 0.72,
		val = 1.06, warm = 0.16, light = 0.75, sparkGlow = 0.8, ringGlow = 0.6, bright = 1, opaque = false,
		slots = { dust = "puff", spark = "soft" }, lines = { color = "#FFF1DC", thick = 3, alpha = 0.5 } },
	neon = { name = "neon", emit = 1, influence = 0, fade = 0.1, life = 0.9, size = 1, count = 1, sat = 1.3, val = 1.15,
		warm = 0, light = 1.5, sparkGlow = 1, ringGlow = 1, bright = 1.6, opaque = false, neutral = "#7FF3FF",
		slots = { dust = "soft", mist = "soft" }, lines = { color = "#7FF6FF", thick = 3, alpha = 0.8 } },
}

local function texOf(st, slot)
	local o = overrides[slot]
	if o then
		return o.id, o.flipbook
	end
	local base = st.slots[slot] or ALIAS[slot] or slot
	o = overrides[base]
	if o then
		return o.id, o.flipbook
	end
	return TEX[base] or TEX.soft, nil
end

------------------------------------------------------------------------------------------------ colour
local function toHSV(r, g, b)
	local mx, mn = math.max(r, g, b), math.min(r, g, b)
	local d = mx - mn
	local h = 0
	if d > 1e-6 then
		if mx == r then
			h = ((g - b) / d) % 6
		elseif mx == g then
			h = (b - r) / d + 2
		else
			h = (r - g) / d + 4
		end
		h /= 6
	end
	return h, if mx > 0 then d / mx else 0, mx
end

local function fromHSV(h, s, v)
	local i = math.floor(h * 6)
	local f = h * 6 - i
	local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
	i %= 6
	if i == 0 then
		return v, t, p
	elseif i == 1 then
		return q, v, p
	elseif i == 2 then
		return p, v, t
	elseif i == 3 then
		return p, q, v
	elseif i == 4 then
		return t, p, v
	end
	return v, p, q
end

local function hexOf(r, g, b)
	return string.format("#%02X%02X%02X", math.floor(math.clamp(r, 0, 1) * 255 + 0.5),
		math.floor(math.clamp(g, 0, 1) * 255 + 0.5), math.floor(math.clamp(b, 0, 1) * 255 + 0.5))
end

-- A colour (Color3 / "#hex") as "#RRGGBB", or nil.
local function asHex(c)
	if typeof(c) == "Color3" then
		return hexOf(c.R, c.G, c.B)
	end
	local r, g, b = FxMath.hex(c)
	if r then
		return hexOf(r, g :: number, b :: number)
	end
	return nil
end

-- Mixes a hex colour toward white (amount > 0) or black (amount < 0).
local function shade(hex, amount)
	local r, g, b = FxMath.hex(hex)
	if not r then
		return hex
	end
	local t = if amount > 0 then 1 else 0
	local a = math.abs(amount)
	return hexOf(r + (t - r) * a, (g :: number) + (t - (g :: number)) * a, (b :: number) + (t - (b :: number)) * a)
end

-- The style's take on a designed colour (saturation, value, warmth; neon recolours neutrals to its accent).
local function tone(st, hex)
	local r, g, b = FxMath.hex(hex)
	if not r then
		return hex
	end
	local h, s, v = toHSV(r, g :: number, b :: number)
	if st.neutral and s < 0.18 then
		local nr, ng, nb = FxMath.hex(st.neutral)
		local nh, ns = toHSV(nr :: number, ng :: number, nb :: number)
		h, s = nh, math.max(s, ns * 0.6)
	end
	s = math.clamp(s * st.sat, 0, 1)
	v = math.clamp(v * st.val, 0, 1)
	local rr, gg, bb = fromHSV(h, s, v)
	if st.warm > 0 then
		local w = st.warm
		rr, gg, bb = rr + (1 - rr) * w * 0.5, gg + (0.93 - gg) * w * 0.5, bb + (0.8 - bb) * w * 0.5
	end
	return hexOf(rr, gg, bb)
end

-- A colour or colour sequence through the style ("#hex", {"#a", "#b"} or {{t, "#a"}, ...}).
local function col(st, spec)
	if type(spec) == "string" then
		return tone(st, spec)
	elseif type(spec) == "table" then
		local out = {}
		for i, k in spec do
			if type(k) == "table" then
				out[i] = { k[1], tone(st, k[2]) }
			else
				out[i] = tone(st, k)
			end
		end
		return out
	end
	return spec
end

------------------------------------------------------------------------------------------------ layer builders
-- Particles with the style's texture, light response, counts and lifetimes applied.
local function particles(st, slot, t)
	t.kind = "particles"
	local id, flip = texOf(st, slot)
	t.texture = id
	if flip then
		t.flipbook = flip
	end
	if t.lightInfluence == nil then
		t.lightInfluence = st.influence
	end
	if t.count then
		t.count = math.max(1, math.floor(t.count * st.count + 0.5))
	end
	if t.rate then
		t.rate = t.rate * st.count
	end
	if type(t.lifetime) == "table" then
		t.lifetime = { t.lifetime[1] * st.life, t.lifetime[2] * st.life }
	end
	return t
end

-- Dust, steam and smoke puffs. Toon: opaque discs that pop and shrink; otherwise soft clouds that grow and fade.
-- t: count | rate (+duration), size, life, speed, spread, direction, color, drag, rise (up accel), alpha (extra fade),
-- slot ("dust"|"smoke"|"mist"), wind (Vector3), delay, offset, shape, fadeIn.
local function puff(st, t)
	local s = (t.size or 1) * st.size
	local toon = st.opaque
	local a = math.clamp(st.fade + (t.alpha or 0), 0, 0.95)
	local tr
	if toon then
		tr = if t.fadeIn then { { 0, 1 }, { 0.12, a }, { 0.8, a }, { 1, 1 } } else { { 0, a }, { 0.8, a }, { 1, 1 } }
	else
		tr = if t.fadeIn then { { 0, 1 }, { 0.15, a }, { 1, 1 } } else { { 0, math.min(a + 0.1, 0.95) }, { 0.3, a }, { 1, 1 } }
	end
	local accel = V(0, t.rise or 1.5, 0)
	if typeof(t.wind) == "Vector3" then
		accel += t.wind
	end
	return particles(st, t.slot or "dust", {
		delay = t.delay, offset = t.offset, count = t.count, rate = t.rate, duration = t.duration, shape = t.shape,
		lifetime = t.life or { 0.4, 0.7 }, speed = t.speed or { 4, 8 }, spread = t.spread or { 180, 8 },
		direction = t.direction or "forward",
		size = if toon then { { 0, s * 0.6 }, { 0.2, s }, { 1, s * (t.grow or 0.15) } } else { { 0, s * 0.5 }, { 1, s * (t.grow or 1.8) } },
		transparency = tr, color = col(st, t.color or "#E9E0D0"), lightEmission = if toon then 0 else st.emit * 0.4,
		drag = t.drag or 5, acceleration = accel, rotation = { 0, 360 }, rotSpeed = { -50, 50 }, zoffset = t.zoffset,
	})
end

-- Hot streaks that stretch along their velocity. t: count | rate, colors, size, life, speed, spread, direction,
-- gravity, drag, stretch, delay, offset, shape.
local function sparks(st, t)
	local s = t.size or 0.22
	return particles(st, t.slot or "spark", {
		delay = t.delay, offset = t.offset, count = t.count, rate = t.rate, duration = t.duration, shape = t.shape,
		lifetime = t.life or { 0.2, 0.45 }, speed = t.speed or { 18, 34 }, spread = t.spread or { 55, 55 },
		direction = t.direction or "up", size = { { 0, s }, { 1, 0 } },
		squash = { { 0, t.stretch or 2.2 }, { 1, 0.6 } }, orientation = "parallel",
		lightEmission = st.sparkGlow, lightInfluence = 0, brightness = st.bright,
		color = if t.exact then t.colors else col(st, t.colors or { "#FFF6C8", "#FFB23E" }),
		drag = t.drag or 3, acceleration = V(0, -(t.gravity or 40), 0), zoffset = t.zoffset or 0.5,
	})
end

-- Stars / glints that pop in, spin and shrink. t: count | rate, color, size, life, speed, spread, direction,
-- gravity, slot ("star"|"glint"|"glow"), delay, offset, shape.
local function glints(st, t)
	local s = (t.size or 0.8) * (if st.opaque then 1.15 else 1)
	return particles(st, t.slot or "star", {
		delay = t.delay, offset = t.offset, count = t.count, rate = t.rate, duration = t.duration, shape = t.shape,
		lifetime = t.life or { 0.35, 0.6 }, speed = t.speed or { 0, 0 }, spread = t.spread or { 180, 180 },
		direction = t.direction or "up", size = { { 0, 0 }, { 0.15, s }, { 1, 0 } },
		transparency = { { 0, 0 }, { 0.7, 0.1 }, { 1, 1 } }, rotation = { 0, 360 }, rotSpeed = t.rotSpeed or { -120, 120 },
		lightEmission = if st.opaque then 0.6 else 1, lightInfluence = 0, brightness = st.bright,
		color = if t.exact then t.color else col(st, t.color or { "#FFFFFF", "#FFE07A" }),
		drag = t.drag or 2, acceleration = V(0, -(t.gravity or 0), 0), zoffset = 0.6,
	})
end

local function flash(st, t)
	return { kind = "flash", delay = t.delay, offset = t.offset, color = if t.exact then t.color else tone(st, t.color or "#FFF6D6"),
		size = t.size or { 0.4, 2.5 }, transparency = t.transparency or { 0.05, 1 }, duration = t.duration or 0.1,
		ease = t.ease or "Quad Out", material = t.material, shape = t.shape }
end

local function ring(st, t)
	local id = texOf(st, "ring")
	return { kind = "ring", delay = t.delay, offset = t.offset, texture = id, size = t.size or { 1, 8 },
		duration = t.duration or 0.35, color = if t.exact then t.color else col(st, t.color or "#FFFFFF"),
		transparency = { { 0, t.alpha or 0.1 }, { 0.6, math.min((t.alpha or 0.1) + 0.3, 0.9) }, { 1, 1 } },
		lightEmission = st.ringGlow, brightness = st.bright, flat = t.flat ~= false, ease = t.ease or "Quint Out" }
end

local function light(st, t)
	return { kind = "light", delay = t.delay, offset = t.offset, color = if t.exact then t.color else tone(st, t.color or "#FFC266"),
		brightness = (t.brightness or 3) * st.light, range = t.range or 12, duration = t.duration, attack = t.attack }
end

-- Paper confetti in one colour: tumbling (squash flutter) squares or shards.
local FLUTTER = { { 0, 0 }, { 0.1, 0.9 }, { 0.2, -0.8 }, { 0.3, 0.9 }, { 0.4, -0.8 }, { 0.5, 0.9 }, { 0.6, -0.8 },
	{ 0.7, 0.9 }, { 0.8, -0.8 }, { 0.9, 0.9 }, { 1, 0 } }
local function confetti(st, t)
	local s = (t.size or 0.4) * st.size
	return particles(st, t.slot or "confetti", {
		delay = t.delay, offset = t.offset, count = t.count, rate = t.rate, duration = t.duration, shape = t.shape,
		lifetime = t.life or { 1.4, 2.2 }, speed = t.speed or { 18, 30 }, spread = t.spread or { 40, 40 },
		direction = t.direction or "up", size = { { 0, s }, { 0.85, s }, { 1, 0 } }, squash = FLUTTER,
		transparency = { { 0, 0 }, { 0.85, 0 }, { 1, 1 } }, color = col(st, t.color), lightEmission = if st.name == "neon" then 0.8 else 0,
		drag = t.drag or 2.4, acceleration = t.accel or V(0.5, -14, 0), rotation = { 0, 360 }, rotSpeed = { -360, 360 },
	})
end

------------------------------------------------------------------------------------------------ presets
-- Each preset: group, build(st, v, c, o) -> spec (cached per style / variant / colour), and optionally variants,
-- default variant, adapt(at, opts, v) (effect options), extra(at, opts, st, v, handle) (camera, debris...),
-- continuous (runs until :stop()), flicker (continuous lights flicker), weather (no `at`: follows the camera).
local P = {}
local ORDER = {}
local function def(name, meta)
	P[name] = meta
	table.insert(ORDER, name)
end

local PALETTE = { "#FF4D6D", "#FFD93D", "#4DD4FF", "#7CFF6B", "#B47CFF" }

-------------------------------------------------- movement
def("jump_puff", { group = "movement", build = function(st, _, c)
	return { layers = {
		puff(st, { count = 7, size = 1, life = { 0.3, 0.5 }, speed = { 7, 10 }, spread = { 180, 6 }, drag = 7, rise = 2, color = c }),
		puff(st, { count = 3, size = 0.7, life = { 0.3, 0.45 }, speed = { 3, 5 }, direction = "up", spread = { 25, 25 },
			color = shade(c or "#E9E0D0", 0.5), delay = 0.02 }),
	} }
end })

def("land_dust", { group = "movement",
	adapt = function(_, o)
		local i = clamp01(if o.impact == nil then 0.5 else o.impact)
		o.scale = (o.scale or 1) * (0.7 + i * 0.9)
		o.intensity = (o.intensity or 1) * (0.6 + i * 0.8)
	end,
	extra = function(at, o)
		local i = clamp01(if o.impact == nil then 0.5 else o.impact)
		if i > 0.6 then
			FXKit.shakeAt(at, (i - 0.6) * 0.8, 40)
		end
	end,
	build = function(st, _, c)
		return { layers = {
			puff(st, { count = 10, size = 1.3, life = { 0.45, 0.8 }, speed = { 10, 15 }, spread = { 180, 5 }, drag = 6, rise = 1.2, color = c }),
			puff(st, { count = 4, size = 1.6, life = { 0.6, 0.9 }, speed = { 2, 4 }, direction = "up", spread = { 40, 40 },
				color = c, delay = 0.03 }),
			particles(st, "debris", { count = 6, lifetime = { 0.45, 0.75 }, speed = { 8, 14 }, direction = "up", spread = { 50, 50 },
				size = { { 0, 0.22 }, { 0.8, 0.18 }, { 1, 0 } }, color = col(st, "#8C7A62"), acceleration = V(0, -55, 0),
				rotation = { 0, 360 }, rotSpeed = { -400, 400 }, drag = 0.5 }),
			ring(st, { size = { 1, 6 }, duration = 0.3, alpha = 0.55, color = c or "#F2E9DA" }),
		} }
	end })

def("double_jump_ring", { group = "movement", build = function(st, _, c)
	local main = c or tone(st, "#BFEFFF")
	return { layers = {
		flash(st, { size = { 0.5, 2.5 }, transparency = { 0.4, 1 }, duration = 0.12, color = "#FFFFFF" }),
		ring(st, { size = { 1.2, 7 }, duration = 0.35, color = { "#FFFFFF", main }, exact = c ~= nil, alpha = 0.05 }),
		ring(st, { delay = 0.06, size = { 0.8, 4.5 }, duration = 0.3, color = main, exact = true, alpha = 0.2 }),
		glints(st, { count = 6, direction = "forward", spread = { 180, 30 }, speed = { 6, 10 }, size = 0.6, life = { 0.25, 0.4 },
			color = { "#FFFFFF", main }, exact = c ~= nil }),
		puff(st, { count = 4, size = 0.8, life = { 0.3, 0.45 }, direction = "down", spread = { 35, 35 }, speed = { 4, 8 },
			color = "#FFFFFF", rise = 0 }),
	} }
end })

def("dash_streak", { group = "movement",
	adapt = function(_, o)
		if typeof(o.direction) == "Vector3" and o.direction.Magnitude > 1e-3 then
			o.normal = o.direction -- the effect's up is the dash direction: rings stand across it, "down" is behind
			o.direction = nil
		end
	end,
	build = function(st, _, c)
		local main = c or tone(st, "#DFF6FF")
		return { layers = {
			flash(st, { size = { 0.4, 2 }, transparency = { 0.3, 1 }, duration = 0.08, color = "#FFFFFF" }),
			ring(st, { size = { 1.5, 6.5 }, duration = 0.25, color = main, exact = true, alpha = 0.1 }),
			particles(st, "streak", { count = 10, direction = "down", spread = { 12, 12 }, speed = { 30, 48 },
				lifetime = { 0.16, 0.28 }, orientation = "parallel", size = { { 0, 0.35 }, { 1, 0.05 } },
				squash = { { 0, 2.8 }, { 1, 1.5 } }, color = { "#FFFFFF", main }, lightEmission = st.sparkGlow,
				lightInfluence = 0, drag = 4, transparency = { { 0, 0 }, { 1, 1 } } }),
			puff(st, { count = 5, size = 1.2, life = { 0.3, 0.5 }, direction = "down", spread = { 30, 30 }, speed = { 5, 9 }, rise = 0 }),
		} }
	end })

def("speed_lines", { group = "movement", screen = true })

def("boost_flame", { group = "movement", continuous = true, flicker = true, build = function(st, _, c)
	local hot = c or tone(st, if st.name == "neon" then "#3AF2FF" else "#FFC23A")
	local deep = shade(hot, -0.45)
	return { layers = {
		particles(st, "flame", { rate = 70, lifetime = { 0.1, 0.18 }, speed = { 14, 20 }, direction = "back", spread = { 6, 6 },
			size = { { 0, 1.1 }, { 1, 0.15 } }, transparency = { { 0, 0.05 }, { 1, 1 } },
			color = { { 0, "#FFFFFF" }, { 0.3, hot }, { 1, deep } }, lightEmission = 1, lightInfluence = 0, zoffset = 0.5 }),
		particles(st, "flame", { rate = 40, lifetime = { 0.16, 0.28 }, speed = { 10, 15 }, direction = "back", spread = { 12, 12 },
			size = { { 0, 1.7 }, { 1, 0.4 } }, transparency = { { 0, 0.4 }, { 1, 1 } }, color = { hot, deep },
			lightEmission = if st.opaque then 0.5 else 1, lightInfluence = 0, rotation = { 0, 360 } }),
		sparks(st, { rate = 18, direction = "back", speed = { 16, 28 }, spread = { 15, 15 }, gravity = 8, size = 0.18,
			colors = { "#FFFFFF", hot }, exact = true, life = { 0.2, 0.35 } }),
		light(st, { color = hot, exact = true, brightness = 3, range = 10, duration = 0 }),
	} }
end })

local DRIFT = { "#59B8FF", "#FF9A2E", "#C46BFF" }
def("drift_sparks", { group = "movement", continuous = true, variants = { "1", "2", "3" }, default = "1",
	build = function(st, v, c)
		local tier = math.clamp(tonumber(v) or 1, 1, 3)
		local hot = c or DRIFT[tier]
		local layers = {
			sparks(st, { rate = 30 + tier * 18, direction = "back", spread = { 35, 45 }, speed = { 10, 18 }, gravity = 50,
				size = 0.2 + tier * 0.03, colors = { "#FFFFFF", hot }, exact = true, life = { 0.15, 0.3 } }),
			particles(st, "spark", { rate = 22, lifetime = { 0.06, 0.1 }, speed = { 0, 0 }, size = { { 0, 0.6 + tier * 0.25 }, { 1, 0.2 } },
				transparency = { { 0, 0.1 }, { 1, 1 } }, color = { "#FFFFFF", hot }, lightEmission = 1, lightInfluence = 0,
				zoffset = 0.4 }),
			light(st, { color = hot, exact = true, brightness = 1.5 + tier * 0.5, range = 6, duration = 0 }),
		}
		if tier >= 3 then
			table.insert(layers, glints(st, { rate = 10, size = 0.7, life = { 0.2, 0.3 }, speed = { 3, 6 }, color = { "#FFFFFF", hot }, exact = true }))
		end
		return { layers = layers }
	end })

def("water_splash", { group = "movement", build = function(st, _, c)
	local water = c or tone(st, "#BFE9FF")
	return { layers = {
		flash(st, { shape = "sphere", size = { V(1, 0.2, 1), V(5, 0.3, 5) }, transparency = { 0.15, 1 }, duration = 0.3,
			color = "#FFFFFF", material = "smoothplastic" }),
		particles(st, "drop", { count = 22, direction = "up", spread = { 28, 28 }, speed = { 14, 24 }, lifetime = { 0.5, 0.85 },
			size = { { 0, 0.45 }, { 1, 0.2 } }, transparency = { { 0, 0 }, { 0.8, 0.15 }, { 1, 1 } }, color = { "#FFFFFF", water },
			acceleration = V(0, -55, 0), drag = 0.6, orientation = if st.opaque then nil else "parallel",
			squash = if st.opaque then nil else { { 0, 0.8 }, { 1, 0 } } }),
		puff(st, { count = 8, size = 1.4, life = { 0.5, 0.9 }, direction = "up", spread = { 60, 60 }, speed = { 6, 10 },
			rise = 0, drag = 3, color = "#EAF8FF", slot = "mist", alpha = 0.2 }),
		ring(st, { size = { 1.5, 8 }, duration = 0.6, color = "#FFFFFF", alpha = 0.2 }),
		ring(st, { delay = 0.15, size = { 1, 5 }, duration = 0.5, color = water, exact = true, alpha = 0.35 }),
	} }
end })

def("wake_spray", { group = "movement", continuous = true, build = function(st, _, c)
	local water = c or tone(st, "#D6F2FF")
	local function side(x, dir)
		return particles(st, "drop", { offset = V(x, 0, 1.2), rate = 35, direction = dir, spread = { 25, 30 }, speed = { 6, 11 },
			lifetime = { 0.4, 0.7 }, size = { { 0, 0.5 }, { 1, 0.15 } }, transparency = { { 0, 0.05 }, { 0.8, 0.2 }, { 1, 1 } },
			color = { "#FFFFFF", water }, acceleration = V(0, -30, 0), drag = 0.8 })
	end
	local function up(x)
		return particles(st, "drop", { offset = V(x, 0, 1.6), rate = 25, direction = "up", spread = { 30, 30 }, speed = { 8, 13 },
			lifetime = { 0.45, 0.7 }, size = { { 0, 0.35 }, { 1, 0.1 } }, transparency = { { 0, 0 }, { 0.8, 0.2 }, { 1, 1 } },
			color = "#FFFFFF", acceleration = V(0, -40, 0), drag = 0.6 })
	end
	return { layers = {
		side(-1.4, "left"), side(1.4, "right"), up(-1.2), up(1.2),
		puff(st, { offset = V(0, 0, 2.4), rate = 25, size = 1.6, life = { 0.6, 1 }, direction = "back", spread = { 25, 10 },
			speed = { 2, 4 }, rise = 0, color = "#FFFFFF", slot = "mist", alpha = 0.1 }),
	} }
end })

def("footstep_dust", { group = "movement", build = function(st, _, c)
	return { layers = {
		puff(st, { count = 4, size = 0.6, life = { 0.25, 0.4 }, speed = { 2.5, 4.5 }, spread = { 180, 8 }, drag = 6, rise = 1, color = c }),
		puff(st, { count = 2, size = 0.5, life = { 0.3, 0.45 }, speed = { 1, 2 }, direction = "up", spread = { 30, 30 },
			color = shade(c or "#E9E0D0", 0.5) }),
	} }
end })

def("skid_marks", { group = "movement", trail = true })

-------------------------------------------------- combat
local MUZZLE = { pistol = 0.7, rifle = 1, shotgun = 1.25 }
def("muzzle_flash", { group = "combat", variants = { "rifle", "pistol", "shotgun" }, default = "rifle",
	build = function(st, v, c)
		local k = MUZZLE[v] or 1
		local wide = v == "shotgun"
		local hot = c or tone(st, "#FFC24A")
		return { layers = {
			flash(st, { offset = V(0, 0, -0.7 * k), size = { V(0.5, 0.5, 1.4) * k, V(0.9, 0.9, 2.8) * k }, transparency = { 0, 1 },
				duration = 0.05, color = "#FFF4C2", material = "neon" }),
			particles(st, "star", { count = 1, lifetime = { 0.04, 0.06 }, speed = { 0, 0 }, size = { { 0, 2.4 * k }, { 1, 1.2 * k } },
				transparency = { { 0, 0 }, { 1, 0.8 } }, rotation = { 0, 360 }, color = { "#FFFFFF", hot }, lightEmission = 1,
				lightInfluence = 0, zoffset = 1 }),
			particles(st, "flame", { count = if wide then 7 else 4, direction = "forward", spread = if wide then { 22, 22 } else { 10, 10 },
				speed = { 12 * k, 22 * k }, lifetime = { 0.04, 0.08 }, size = { { 0, 0.8 * k }, { 1, 0.2 } }, orientation = "parallel",
				squash = { { 0, 1.5 }, { 1, 1 } }, color = { { 0, "#FFFFFF" }, { 0.4, hot }, { 1, shade(hot, -0.4) } },
				lightEmission = 1, lightInfluence = 0 }),
			sparks(st, { count = if wide then 10 else 3, direction = "forward", spread = if wide then { 25, 25 } else { 10, 10 },
				speed = { 40, 70 }, life = { 0.08, 0.15 }, size = 0.12, gravity = 20, colors = { "#FFFFFF", hot }, exact = true }),
			puff(st, { delay = 0.03, count = if wide then 4 else 2, size = 0.8 * k, life = { 0.5, 0.9 }, direction = "forward",
				spread = { 15, 15 }, speed = { 2, 4 }, rise = 2, color = "#BDB8B2", slot = "smoke", alpha = 0.45 }),
			light(st, { color = hot, exact = true, brightness = 4, range = 10 * k, duration = 0.06 }),
		} }
	end })

def("bullet_tracer", { group = "combat", dynamic = true })

local function scorchLayer(st, size, duration)
	return { kind = "decal", texture = (texOf(st, "scorch")), size = size, color = "#151210", transparency = { 0.2, 0.2 },
		duration = duration, fade = duration * 0.4, rotation = { 0, 360 } }
end

local IMPACT = {
	concrete = function(st, c)
		local dust = c or tone(st, "#B9B3AA")
		return {
			flash(st, { size = { 0.2, 1.2 }, duration = 0.05 }),
			puff(st, { count = 6, size = 1, life = { 0.4, 0.8 }, direction = "up", spread = { 45, 45 }, speed = { 4, 9 }, color = dust }),
			particles(st, "debris", { count = 8, direction = "up", spread = { 50, 50 }, speed = { 10, 18 }, lifetime = { 0.4, 0.7 },
				size = { { 0, 0.22 }, { 0.8, 0.16 }, { 1, 0 } }, color = col(st, "#8D8A84"), acceleration = V(0, -55, 0),
				rotation = { 0, 360 }, rotSpeed = { -500, 500 } }),
			sparks(st, { count = 3, speed = { 14, 22 }, size = 0.12, life = { 0.08, 0.16 } }),
			scorchLayer(st, { 0.5, 0.7 }, 5),
		}
	end,
	metal = function(st, c)
		local hot = c or "#FFB23E"
		return {
			flash(st, { size = { 0.2, 1.4 }, duration = 0.05, color = "#FFFBEA" }),
			particles(st, "star", { count = 1, lifetime = { 0.05, 0.07 }, speed = { 0, 0 }, size = { { 0, 1.6 }, { 1, 0.8 } },
				transparency = { { 0, 0 }, { 1, 0.6 } }, rotation = { 0, 360 }, color = "#FFFFFF", lightEmission = 1, lightInfluence = 0 }),
			sparks(st, { count = 14, speed = { 18, 34 }, spread = { 50, 50 }, gravity = 60, size = 0.16, life = { 0.2, 0.45 },
				colors = { "#FFFFFF", hot }, exact = c ~= nil }),
			puff(st, { count = 2, size = 0.6, life = { 0.4, 0.7 }, direction = "up", spread = { 30, 30 }, speed = { 2, 4 },
				color = "#9A9590", slot = "smoke", alpha = 0.4 }),
			light(st, { color = hot, brightness = 2, range = 6, duration = 0.08 }),
			scorchLayer(st, { 0.4, 0.5 }, 5),
		}
	end,
	wood = function(st, c)
		local wood = c or tone(st, "#A7774A")
		return {
			flash(st, { size = { 0.2, 1 }, duration = 0.05 }),
			particles(st, "shard", { count = 8, direction = "up", spread = { 45, 45 }, speed = { 8, 16 }, lifetime = { 0.5, 0.8 },
				size = { { 0, 0.32 }, { 0.8, 0.28 }, { 1, 0 } }, squash = { { 0, 1.2 }, { 1, 1.2 } }, color = wood,
				acceleration = V(0, -45, 0), rotation = { 0, 360 }, rotSpeed = { -600, 600 } }),
			puff(st, { count = 4, size = 0.8, life = { 0.35, 0.6 }, direction = "up", spread = { 40, 40 }, speed = { 3, 6 },
				color = shade(wood, 0.45) }),
			scorchLayer(st, { 0.4, 0.5 }, 5),
		}
	end,
	flesh = function(st, c) -- a cartoon hit: a soft coloured puff and a white hit star, no gore
		local hit = c or tone(st, "#E8707A")
		return {
			particles(st, "star", { count = 1, lifetime = { 0.08, 0.1 }, speed = { 0, 0 }, size = { { 0, 0.6 }, { 0.3, 1.8 }, { 1, 1.2 } },
				transparency = { { 0, 0 }, { 1, 1 } }, rotation = { 0, 360 }, color = "#FFFFFF", lightEmission = 0.6, lightInfluence = 0,
				zoffset = 1 }),
			puff(st, { count = 6, size = 0.7, life = { 0.25, 0.45 }, direction = "up", spread = { 60, 60 }, speed = { 4, 8 }, rise = 0,
				color = hit, slot = "mist" }),
			ring(st, { size = { 0.3, 2.2 }, duration = 0.15, color = "#FFFFFF", alpha = 0.1, flat = false }),
		}
	end,
	water = function(st, c)
		local water = c or tone(st, "#BFE9FF")
		return {
			particles(st, "drop", { count = 10, direction = "up", spread = { 20, 20 }, speed = { 8, 14 }, lifetime = { 0.35, 0.6 },
				size = { { 0, 0.3 }, { 1, 0.12 } }, transparency = { { 0, 0 }, { 0.8, 0.2 }, { 1, 1 } }, color = { "#FFFFFF", water },
				acceleration = V(0, -50, 0), drag = 0.5 }),
			ring(st, { size = { 0.5, 3 }, duration = 0.4, color = "#FFFFFF", alpha = 0.25 }),
			puff(st, { count = 3, size = 0.8, life = { 0.3, 0.6 }, direction = "up", spread = { 40, 40 }, speed = { 3, 5 }, rise = 0,
				color = "#EAF8FF", slot = "mist", alpha = 0.3 }),
		}
	end,
}
for _, kind in { "concrete", "metal", "wood", "flesh", "water" } do
	def("impact_" .. kind, { group = "combat", build = function(st, _, c)
		return { layers = IMPACT[kind](st, c) }
	end })
end

def("explosion", { group = "combat", variants = { "small", "large" }, default = "small",
	adapt = function(_, o, v)
		if v == "large" then
			o.scale = (o.scale or 1) * 2.2
			o.intensity = (o.intensity or 1) * 1.5
		end
	end,
	extra = function(at, o, st, v)
		local s = (o.scale or 1)
		FXKit.shakeAt(at, if v == "large" then 0.75 else 0.4, 30 * s)
		FXKit.flashAt(at, "#FFE6B0", if v == "large" then 0.35 else 0.18, 25 * s)
		FXKit.debris(at, { count = math.floor((if v == "large" then 9 else 4) * (o.intensity or 1)), size = 0.5 * math.sqrt(s),
			speed = 32 * math.sqrt(s), color = tone(st, "#3B3633") })
		FXKit.scorch(at, 3 * s, 6)
	end,
	build = function(st)
		local fire = { { 0, "#FFF3B0" }, { 0.2, "#FFB13A" }, { 0.55, "#D9481C" }, { 1, "#3A2A26" } }
		return { layers = {
			flash(st, { size = { 1.5, 6 }, transparency = { 0, 1 }, duration = 0.12, color = "#FFF6D6" }),
			light(st, { color = "#FF9A3A", brightness = 6, range = 24, duration = 0.5 }),
			particles(st, "fireball", { count = 12, direction = "up", spread = { 180, 180 }, speed = { 5, 10 }, drag = 5,
				lifetime = { 0.5, 0.9 }, size = { { 0, 2 }, { 0.2, 3.8 }, { 1, 4.6 } }, transparency = { { 0, 0 }, { 0.5, 0.1 }, { 1, 1 } },
				color = col(st, fire), lightEmission = if st.opaque then 0.3 else 0.8, lightInfluence = 0, rotation = { 0, 360 },
				rotSpeed = { -60, 60 }, zoffset = 1 }),
			ring(st, { delay = 0.02, size = { 2, 16 }, duration = 0.45, color = "#FFE6B0", alpha = 0.15 }),
			sparks(st, { count = 22, spread = { 180, 180 }, speed = { 25, 45 }, gravity = 35, size = 0.25, life = { 0.35, 0.8 },
				colors = { "#FFF6C8", "#FF8A2A" } }),
			particles(st, "debris", { count = 10, direction = "up", spread = { 70, 70 }, speed = { 20, 34 }, lifetime = { 0.8, 1.3 },
				size = { { 0, 0.45 }, { 0.85, 0.35 }, { 1, 0 } }, color = col(st, "#3B3633"), acceleration = V(0, -70, 0),
				rotation = { 0, 360 }, rotSpeed = { -500, 500 } }),
			ring(st, { delay = 0.06, size = { 1, 10 }, duration = 0.5, color = "#FFFFFF", alpha = 0.2, flat = false }),
			puff(st, { delay = 0.12, count = 12, size = 4, life = { 1.4, 2 }, direction = "up", spread = { 22, 22 }, speed = { 8, 14 },
				drag = 1.5, rise = 4, color = if st.opaque then "#6B6366" else "#4A4442", slot = "smoke", alpha = 0.2, grow = 2.2 }),
		} }
	end })

def("hit_spark", { group = "combat", build = function(st, _, c)
	local hot = c or tone(st, "#FFE27A")
	return { layers = {
		flash(st, { size = { 0.3, 2 }, duration = 0.06, color = "#FFFFFF" }),
		particles(st, "star", { count = 2, lifetime = { 0.07, 0.1 }, speed = { 0, 0 }, size = { { 0, 1 }, { 0.3, 2.4 }, { 1, 1.4 } },
			transparency = { { 0, 0 }, { 1, 1 } }, rotation = { 0, 360 }, color = { "#FFFFFF", hot }, lightEmission = 1,
			lightInfluence = 0, zoffset = 1 }),
		sparks(st, { count = 10, spread = { 60, 60 }, speed = { 16, 30 }, gravity = 30, size = 0.18, life = { 0.12, 0.25 },
			colors = { "#FFFFFF", hot }, exact = true }),
		ring(st, { size = { 0.5, 3.5 }, duration = 0.18, color = "#FFFFFF", alpha = 0.1, flat = false }),
	} }
end })

def("critical_hit", { group = "combat",
	extra = function(at)
		FXKit.hitstop(0.7)
		FXKit.flashAt(at, "#FFFFFF", 0.22, 60)
		FXKit.shakeAt(at, 0.35, 60)
	end,
	build = function(st, _, c)
		local hot = c or tone(st, "#FF4D4D")
		return { layers = {
			flash(st, { size = { 0.5, 4 }, duration = 0.08, color = "#FFFFFF" }),
			particles(st, "star", { count = 3, lifetime = { 0.1, 0.14 }, speed = { 0, 0 }, size = { { 0, 1.5 }, { 0.3, 4 }, { 1, 2.4 } },
				transparency = { { 0, 0 }, { 1, 1 } }, rotation = { 0, 360 }, color = { "#FFFFFF", "#FFE27A" }, lightEmission = 1,
				lightInfluence = 0, zoffset = 1 }),
			sparks(st, { count = 22, spread = { 180, 180 }, speed = { 20, 40 }, gravity = 25, size = 0.24, life = { 0.18, 0.35 },
				colors = { "#FFFFFF", "#FFD34A", hot }, exact = c ~= nil }),
			ring(st, { size = { 1, 7 }, duration = 0.25, color = hot, exact = true, alpha = 0.05, flat = false }),
			ring(st, { delay = 0.05, size = { 0.6, 5 }, duration = 0.25, color = "#FFD34A", alpha = 0.1, flat = false }),
			glints(st, { delay = 0.05, count = 6, speed = { 6, 12 }, size = 0.8, life = { 0.3, 0.5 }, color = { "#FFFFFF", "#FFD34A" } }),
			light(st, { color = hot, exact = true, brightness = 4, range = 14, duration = 0.2 }),
		} }
	end })

def("shield_hit", { group = "combat", build = function(st, _, c)
	local blue = c or tone(st, "#5BC8FF")
	return { layers = {
		flash(st, { size = { 2, 5.5 }, transparency = { 0, 1 }, duration = 0.3, color = blue, exact = true, material = "forcefield" }),
		ring(st, { size = { 0.5, 4.5 }, duration = 0.3, color = { "#FFFFFF", blue }, exact = c ~= nil, alpha = 0.05 }),
		sparks(st, { count = 10, spread = { 50, 50 }, speed = { 10, 22 }, gravity = 10, size = 0.16, life = { 0.15, 0.3 },
			colors = { "#FFFFFF", blue }, exact = true }),
		glints(st, { count = 4, size = 0.6, life = { 0.2, 0.35 }, speed = { 2, 5 }, slot = "glint", color = { "#FFFFFF", blue }, exact = true }),
		light(st, { color = blue, exact = true, brightness = 3, range = 10, duration = 0.25 }),
	} }
end })

def("heal_aura", { group = "combat", build = function(st, _, c)
	local green = c or tone(st, "#5BFF8A")
	local feet = { kind = "box", size = V(4, 0.2, 4) }
	return { layers = {
		ring(st, { size = { 1, 6 }, duration = 0.6, color = green, exact = true, alpha = 0.15 }),
		ring(st, { delay = 0.3, size = { 1, 5 }, duration = 0.6, color = { "#FFFFFF", green }, exact = c ~= nil, alpha = 0.2 }),
		particles(st, "magic", { rate = 30, duration = 1, shape = feet, direction = "up", spread = { 5, 5 }, speed = { 3, 6 },
			lifetime = { 0.8, 1.2 }, size = { { 0, 0 }, { 0.2, 0.45 }, { 1, 0 } }, transparency = { { 0, 0.1 }, { 1, 1 } },
			color = { "#EFFFE6", green }, lightEmission = 1, lightInfluence = 0 }),
		glints(st, { rate = 10, duration = 1, shape = feet, direction = "up", speed = { 2, 4 }, size = 0.6, life = { 0.6, 0.9 },
			color = { "#FFFFFF", green }, exact = c ~= nil }),
		light(st, { color = green, exact = true, brightness = 2, range = 10, duration = 1.2, attack = 0.2, offset = V(0, 2, 0) }),
	} }
end })

def("death_poof", { group = "combat", build = function(st, _, c)
	return { layers = {
		flash(st, { size = { 0.5, 3.5 }, duration = 0.08, color = "#FFFFFF" }),
		puff(st, { count = 12, size = 2.2, life = { 0.4, 0.7 }, speed = { 10, 16 }, direction = "up", spread = { 180, 180 }, drag = 6,
			rise = 2, color = c or "#FFFFFF", slot = "dust" }),
		puff(st, { delay = 0.05, count = 5, size = 1.6, life = { 0.5, 0.8 }, speed = { 3, 6 }, direction = "up", spread = { 30, 30 },
			rise = 3, color = c or "#F2F2F2", slot = "dust" }),
		glints(st, { count = 6, speed = { 8, 14 }, spread = { 180, 180 }, size = 0.9, life = { 0.4, 0.6 }, drag = 4,
			color = { "#FFFFFF", "#FFE07A" } }),
		ring(st, { size = { 1, 8 }, duration = 0.3, color = "#FFFFFF", alpha = 0.2, flat = false }),
	} }
end })

def("slash_arc", { group = "combat", variants = { "right", "left" }, default = "right",
	adapt = function(at, o)
		-- the effect's up is the swing's facing (so the beam bows forward), its forward is world up
		local look = if typeof(o.direction) == "Vector3" and o.direction.Magnitude > 1e-3 then o.direction
			elseif typeof(at) == "CFrame" then at.LookVector
			elseif typeof(at) == "Instance" and at:IsA("BasePart") then at.CFrame.LookVector
			elseif typeof(at) == "Instance" and at:IsA("Model") then at:GetPivot().LookVector
			else Vector3.zAxis * -1
		o.normal = look
		o.direction = Vector3.yAxis
	end,
	build = function(st, v, c)
		local edge = c or tone(st, "#9FE8FF")
		local a, b = V(-3.2, 1.2, 0), V(3.2, 1.2, 0)
		if v == "left" then
			a, b = b, a
		end
		local along = { { 0, 1 }, { 0.2, 0.5 }, { 0.75, 0 }, { 1, 0.2 } }
		return { layers = {
			{ kind = "beam", from = a, to = b, width = { 0.2, 1.8 }, curve = { 2.6, 2.6 }, segments = 16, color = { edge, "#FFFFFF" },
				transparency = along, lightEmission = if st.opaque then 0.3 else 1, lightInfluence = 0, duration = 0.07, fadeOut = 0.14 },
			{ kind = "beam", from = a, to = b, width = { 0.05, 0.7 }, curve = { 2.6, 2.6 }, segments = 16, color = "#FFFFFF",
				transparency = along, lightEmission = 1, lightInfluence = 0, duration = 0.06, fadeOut = 0.1, zoffset = 0.2 },
			glints(st, { offset = b + V(0, 0.6, 0), count = 4, size = 0.6, life = { 0.15, 0.3 }, speed = { 4, 8 }, slot = "glint",
				color = { "#FFFFFF", edge }, exact = true }),
		} }
	end })

def("magic_bolt", { group = "combat", continuous = true, projectile = true, build = function(st, _, c)
	local magic = c or tone(st, "#B36BFF")
	return { layers = {
		particles(st, "magic", { rate = 45, lifetime = { 0.12, 0.2 }, speed = { 0, 0 }, size = { { 0, 1.4 }, { 1, 0 } },
			transparency = { { 0, 0 }, { 1, 1 } }, color = { "#FFFFFF", magic }, lightEmission = 1, lightInfluence = 0, zoffset = 0.5 }),
		particles(st, "magic", { rate = 30, lifetime = { 0.25, 0.45 }, speed = { 0.5, 2 }, spread = { 180, 180 },
			size = { { 0, 0.7 }, { 1, 0 } }, transparency = { { 0, 0.3 }, { 1, 1 } }, color = magic, lightEmission = 1, lightInfluence = 0 }),
		glints(st, { rate = 20, size = 0.45, life = { 0.3, 0.5 }, speed = { 1, 3 }, color = { "#FFFFFF", magic }, exact = true }),
		light(st, { color = magic, exact = true, brightness = 3, range = 10, duration = 0 }),
	} }
end })

def("magic_impact", { group = "combat", build = function(st, _, c)
	local magic = c or tone(st, "#B36BFF")
	return { layers = {
		flash(st, { size = { 0.5, 3.5 }, duration = 0.1, color = shade(magic, 0.6), exact = true }),
		ring(st, { size = { 1, 6.5 }, duration = 0.35, color = magic, exact = true, alpha = 0.05, flat = false }),
		ring(st, { delay = 0.04, size = { 1, 5 }, duration = 0.35, color = { "#FFFFFF", magic }, exact = c ~= nil, alpha = 0.15 }),
		glints(st, { count = 10, speed = { 8, 16 }, size = 0.7, life = { 0.3, 0.55 }, drag = 4, color = { "#FFFFFF", magic }, exact = true }),
		particles(st, "magic", { count = 8, direction = "up", spread = { 180, 180 }, speed = { 5, 10 }, lifetime = { 0.3, 0.5 },
			size = { { 0, 1.2 }, { 1, 0 } }, transparency = { { 0, 0.2 }, { 1, 1 } }, color = magic, lightEmission = 1,
			lightInfluence = 0, drag = 4 }),
		light(st, { color = magic, exact = true, brightness = 4, range = 14, duration = 0.35 }),
	} }
end })

def("lightning", { group = "combat", dynamic = true })

-------------------------------------------------- pickups & rewards
def("coin_collect", { group = "pickups", build = function(st, _, c)
	local gold = c or tone(st, "#FFD34A")
	return { layers = {
		flash(st, { size = { 0.3, 2.2 }, duration = 0.08, color = "#FFF6C8" }),
		ring(st, { size = { 0.5, 4 }, duration = 0.25, color = gold, exact = true, alpha = 0.1, flat = false }),
		glints(st, { count = 8, direction = "up", spread = { 60, 60 }, speed = { 6, 12 }, gravity = 10, size = 0.7, life = { 0.35, 0.55 },
			color = { "#FFFFFF", gold }, exact = true }),
		particles(st, "spark", { count = 6, direction = "up", spread = { 30, 30 }, speed = { 2, 5 }, lifetime = { 0.6, 0.9 },
			size = { { 0, 0.3 }, { 1, 0 } }, transparency = { { 0, 0 }, { 1, 1 } }, color = gold, lightEmission = 1, lightInfluence = 0 }),
		light(st, { color = gold, exact = true, brightness = 2, range = 8, duration = 0.2 }),
	} }
end })

def("gem_sparkle", { group = "pickups", continuous = true, build = function(st, _, c)
	local gem = c or tone(st, "#7FE8FF")
	return { layers = {
		glints(st, { rate = 4, shape = { kind = "sphere", size = 2 }, size = 0.9, life = { 0.5, 0.8 },
			color = { "#FFFFFF", gem, tone(st, "#FF9CEB") }, exact = true }),
		particles(st, "magic", { rate = 3, shape = { kind = "sphere", size = 1.6 }, lifetime = { 0.8, 1.2 }, speed = { 0.2, 0.6 },
			spread = { 180, 180 }, size = { { 0, 0 }, { 0.3, 0.3 }, { 1, 0 } }, color = gem, lightEmission = 1, lightInfluence = 0 }),
		light(st, { color = gem, exact = true, brightness = 1, range = 6, duration = 0 }),
	} }
end })

def("star_burst", { group = "pickups", build = function(st, _, c)
	local gold = c or tone(st, "#FFE04A")
	return { layers = {
		flash(st, { size = { 0.5, 3 }, duration = 0.1, color = "#FFFBE0" }),
		glints(st, { count = 12, direction = "forward", spread = { 180, 180 }, speed = { 12, 20 }, drag = 4, size = 1.2,
			life = { 0.5, 0.8 }, color = { "#FFFFFF", gold }, exact = true }),
		glints(st, { count = 16, spread = { 180, 180 }, speed = { 4, 10 }, drag = 3, size = 0.4, slot = "glint",
			life = { 0.4, 0.7 }, color = gold, exact = true }),
		ring(st, { size = { 1, 7 }, duration = 0.35, color = gold, exact = true, alpha = 0.1, flat = false }),
	} }
end })

def("level_up", { group = "pickups",
	extra = function(at, _, st)
		FXKit.flashAt(at, tone(st, "#FFE9A8"), 0.18, 60)
	end,
	build = function(st, _, c)
		local gold = c or tone(st, "#FFD34A")
		local layers = {
			{ kind = "beam", from = V(0, 0, 0), to = V(0, 14, 0), width = { 3.2, 1 }, color = { "#FFFFFF", gold },
				transparency = { { 0, 0.15 }, { 1, 1 } }, lightEmission = 1, lightInfluence = 0, duration = 0.5, fadeOut = 0.4 },
			{ kind = "beam", from = V(0, 0, 0), to = V(0, 12, 0), width = { 1.2, 0.3 }, color = "#FFFFFF",
				transparency = { { 0, 0 }, { 1, 1 } }, lightEmission = 1, lightInfluence = 0, duration = 0.35, fadeOut = 0.3, zoffset = 0.2 },
			ring(st, { size = { 1, 10 }, duration = 0.6, color = gold, exact = true, alpha = 0.05 }),
			ring(st, { delay = 0.2, offset = V(0, 0.2, 0), size = { 1, 7 }, duration = 0.5, color = "#FFFFFF", alpha = 0.2 }),
			sparks(st, { rate = 60, duration = 0.7, shape = { kind = "box", size = V(3, 0.2, 3) }, direction = "up", spread = { 4, 4 },
				speed = { 10, 18 }, gravity = 0, drag = 1, size = 0.3, stretch = 2.5, life = { 0.5, 0.9 },
				colors = { "#FFFFFF", gold }, exact = true }),
			glints(st, { offset = V(0, 3, 0), count = 12, spread = { 180, 180 }, speed = { 5, 10 }, size = 0.9, life = { 0.5, 0.8 },
				drag = 3, color = { "#FFFFFF", gold }, exact = true }),
			light(st, { color = gold, exact = true, brightness = 4, range = 18, duration = 1.2, attack = 0.1, offset = V(0, 3, 0) }),
		}
		for i, hex in PALETTE do
			table.insert(layers, confetti(st, { delay = 0.15, offset = V(0, 7, 0), count = 8, color = hex,
				slot = if i % 2 == 0 then "shard" else "confetti", spread = { 70, 70 }, speed = { 10, 18 } }))
		end
		return { layers = layers }
	end })

def("confetti_burst", { group = "pickups", build = function(st)
	local layers = {}
	for i, hex in PALETTE do
		table.insert(layers, confetti(st, { count = 12, color = hex, slot = if i % 2 == 0 then "shard" else "confetti" }))
	end
	table.insert(layers, flash(st, { size = { 0.3, 2 }, duration = 0.08, color = "#FFFFFF" }))
	return { layers = layers }
end })

def("firework", { group = "pickups", build = function(st, _, c)
	local hue = c or tone(st, "#FF5DA2")
	local top = V(0, 24, 0)
	return { layers = {
		particles(st, "spark", { rate = 55, duration = 0.8, direction = "up", spread = { 2, 2 }, speed = { 30, 30 }, lifetime = { 0.78, 0.82 },
			size = { { 0, 0.5 }, { 1, 0 } }, transparency = { { 0, 0 }, { 1, 1 } }, color = { "#FFFFFF", "#FFD27A" },
			lightEmission = 1, lightInfluence = 0 }),
		flash(st, { delay = 0.8, offset = top, size = { 1, 6 }, duration = 0.12, color = shade(hue, 0.7), exact = true }),
		light(st, { delay = 0.8, offset = top, color = hue, exact = true, brightness = 5, range = 40, duration = 0.8 }),
		particles(st, "spark", { delay = 0.8, offset = top, count = 70, direction = "up", spread = { 180, 180 }, speed = { 18, 24 },
			lifetime = { 1, 1.6 }, drag = 2.5, acceleration = V(0, -8, 0), size = { { 0, 0.6 }, { 1, 0.1 } },
			transparency = { { 0, 0 }, { 0.7, 0 }, { 1, 1 } }, color = { "#FFFFFF", hue, shade(hue, -0.5) },
			lightEmission = 1, lightInfluence = 0 }),
		glints(st, { delay = 1.3, offset = top, count = 20, spread = { 180, 180 }, speed = { 3, 8 }, size = 0.5, slot = "glint",
			life = { 0.3, 0.6 }, color = { "#FFFFFF", hue }, exact = true }),
	} }
end })

def("checkpoint_activate", { group = "pickups", build = function(st, _, c)
	local hue = c or tone(st, "#5BFFB0")
	return { layers = {
		flash(st, { offset = V(0, 2, 0), size = { 0.5, 3 }, duration = 0.1, color = "#FFFFFF" }),
		ring(st, { size = { 1, 9 }, duration = 0.5, color = hue, exact = true, alpha = 0.05 }),
		{ kind = "beam", from = V(0, 0, 0), to = V(0, 10, 0), width = { 2.5, 0.5 }, color = { "#FFFFFF", hue },
			transparency = { { 0, 0.1 }, { 1, 1 } }, lightEmission = 1, lightInfluence = 0, duration = 0.35, fadeOut = 0.3 },
		sparks(st, { rate = 50, duration = 0.5, shape = { kind = "box", size = V(3, 0.2, 3) }, direction = "up", spread = { 4, 4 },
			speed = { 8, 14 }, gravity = 0, drag = 1, size = 0.25, life = { 0.4, 0.7 }, colors = { "#FFFFFF", hue }, exact = true }),
		glints(st, { offset = V(0, 2, 0), count = 10, speed = { 5, 9 }, size = 0.7, drag = 3, color = { "#FFFFFF", hue }, exact = true }),
		light(st, { color = hue, exact = true, brightness = 3, range = 14, duration = 0.6, offset = V(0, 2, 0) }),
	} }
end })

def("portal_swirl", { group = "pickups", continuous = true, build = function(st, _, c)
	local hue = c or tone(st, "#9A6BFF")
	local id = texOf(st, "vortex")
	return { layers = {
		{ kind = "particles", texture = id, rate = 3, lifetime = { 1.2, 1.2 }, speed = { 0.001, 0.001 }, direction = "forward",
			orientation = "perpendicular", size = { { 0, 4.5 }, { 1, 5.2 } }, transparency = { { 0, 1 }, { 0.3, 0.15 }, { 0.7, 0.15 }, { 1, 1 } },
			rotation = { 0, 360 }, rotSpeed = { 120, 160 }, color = { "#FFFFFF", hue }, lightEmission = 1, lightInfluence = 0,
			lockedToPart = true },
		particles(st, "magic", { rate = 30, shape = { kind = "sphere", size = V(6, 6, 0.5), style = "surface", inOut = "inward" },
			speed = { 3, 5 }, lifetime = { 0.6, 0.9 }, size = { { 0, 0 }, { 0.3, 0.35 }, { 1, 0 } }, color = { "#FFFFFF", hue },
			lightEmission = 1, lightInfluence = 0 }),
		particles(st, "magic", { rate = 4, lifetime = { 0.8, 1 }, speed = { 0, 0 }, size = { { 0, 2.5 }, { 0.5, 3.2 }, { 1, 2.5 } },
			transparency = { { 0, 1 }, { 0.5, 0.4 }, { 1, 1 } }, color = hue, lightEmission = 1, lightInfluence = 0 }),
		light(st, { color = hue, exact = true, brightness = 2.5, range = 14, duration = 0 }),
	} }
end })

-------------------------------------------------- ambient & world
def("steam", { group = "ambient", continuous = true, build = function(st, _, c)
	return { layers = {
		puff(st, { rate = 6, size = 1.4, life = { 1.6, 2.4 }, direction = "up", spread = { 12, 12 }, speed = { 2, 3.5 }, drag = 0.5,
			rise = 0.8, wind = V(0.6, 0, 0), color = c or "#FFFFFF", slot = "mist", alpha = 0.45, fadeIn = true, grow = 2.4 }),
		puff(st, { rate = 3, size = 0.8, life = { 1, 1.5 }, direction = "up", spread = { 6, 6 }, speed = { 3, 4.5 }, drag = 0.5,
			rise = 1, color = c or "#FFF8EE", slot = "mist", alpha = 0.3, fadeIn = true, grow = 3 }),
	} }
end })

def("cooking_sizzle", { group = "ambient", continuous = true, build = function(st, _, c)
	local oil = c or tone(st, "#FFE9A8")
	local pan = { kind = "box", size = V(2.4, 0.1, 2.4) }
	return { layers = {
		particles(st, "drop", { rate = 22, shape = pan, direction = "up", spread = { 50, 50 }, speed = { 4, 8 }, lifetime = { 0.3, 0.5 },
			size = { { 0, 0.14 }, { 1, 0.04 } }, transparency = { { 0, 0 }, { 1, 0.6 } }, color = { "#FFFFFF", oil },
			acceleration = V(0, -30, 0), lightEmission = 0.6, lightInfluence = 0 }),
		puff(st, { rate = 4, shape = pan, size = 0.9, life = { 0.8, 1.2 }, direction = "up", spread = { 15, 15 }, speed = { 1.5, 3 },
			rise = 1, drag = 0.5, color = "#FFFFFF", slot = "mist", alpha = 0.5, fadeIn = true }),
		glints(st, { rate = 3, shape = pan, size = 0.35, slot = "glint", life = { 0.1, 0.2 }, color = { "#FFFFFF", oil }, exact = true }),
	} }
end })

def("smoke_plume", { group = "ambient", continuous = true, build = function(st, _, c)
	return { layers = {
		puff(st, { rate = 5, size = 3, life = { 3, 4.5 }, direction = "up", spread = { 8, 8 }, speed = { 3, 5 }, drag = 0.3, rise = 0.5,
			wind = V(1.2, 0, 0), color = c or "#5A5654", slot = "smoke", alpha = 0.35, fadeIn = true, grow = 2.5 }),
		puff(st, { rate = 2, size = 4, life = { 3.5, 5 }, direction = "up", spread = { 14, 14 }, speed = { 2, 3.5 }, drag = 0.3,
			rise = 0.4, wind = V(1.6, 0, 0), color = shade(c or "#5A5654", 0.35), slot = "smoke", alpha = 0.55, fadeIn = true,
			grow = 3 }),
	} }
end })

def("fire", { group = "ambient", continuous = true, flicker = true, variants = { "campfire", "torch" }, default = "campfire",
	adapt = function(_, o, v)
		if v == "torch" then
			o.scale = (o.scale or 1) * 0.45
		end
	end,
	build = function(st, _, c)
		local hot = c or "#FFB43A"
		local flame = { { 0, "#FFF6C0" }, { 0.3, hot }, { 0.7, "#FF5A1F" }, { 1, "#B0200C" } }
		local base = { kind = "box", size = V(1.6, 0.3, 1.6) }
		return { layers = {
			particles(st, "flame", { rate = 40, shape = base, direction = "up", spread = { 8, 8 }, speed = { 3, 5 }, lifetime = { 0.4, 0.7 },
				size = { { 0, 1.6 }, { 0.5, 1.1 }, { 1, 0 } }, transparency = { { 0, 0.5 }, { 0.15, 0.05 }, { 1, 1 } }, color = col(st, flame),
				lightEmission = if st.opaque then 0.6 else 1, lightInfluence = 0, acceleration = V(0, 4, 0), rotation = { 0, 360 },
				rotSpeed = { -30, 30 }, zoffset = 0.2 }),
			particles(st, "flame", { rate = 18, shape = base, direction = "up", spread = { 12, 12 }, speed = { 2.5, 4 }, lifetime = { 0.5, 0.8 },
				size = { { 0, 2.4 }, { 1, 0.4 } }, transparency = { { 0, 0.6 }, { 0.2, 0.35 }, { 1, 1 } },
				color = col(st, { "#FF9A2E", "#C2401A" }), lightEmission = if st.opaque then 0.4 else 0.9, lightInfluence = 0,
				acceleration = V(0, 3, 0), rotation = { 0, 360 } }),
			particles(st, "ember", { rate = 6, direction = "up", spread = { 25, 25 }, speed = { 4, 8 }, lifetime = { 1, 1.8 },
				size = { { 0, 0.14 }, { 1, 0 } }, transparency = { { 0, 0 }, { 0.3, 0.5 }, { 0.5, 0 }, { 0.75, 0.5 }, { 1, 1 } },
				color = col(st, { "#FFE08A", "#FF6A1A" }), lightEmission = 1, lightInfluence = 0, drag = 1, acceleration = V(0.5, 3, 0) }),
			puff(st, { offset = V(0, 2.5, 0), rate = 4, size = 1.5, life = { 2, 3 }, direction = "up", spread = { 10, 10 }, speed = { 2, 3 },
				rise = 0.5, drag = 0.3, color = "#3B3634", slot = "smoke", alpha = 0.55, fadeIn = true, grow = 3 }),
			light(st, { offset = V(0, 1.5, 0), color = "#FF9A3A", brightness = 2.5, range = 14, duration = 0 }),
		} }
	end })

local function areaBox(o, height)
	local a = math.clamp(tonumber(o.area) or 60, 4, 400)
	return { kind = "box", size = V(a, height, a) }, a
end

def("fireflies", { group = "ambient", continuous = true, weather = true, build = function(st, _, c, o)
	local box, a = areaBox(o, 6)
	return { layers = {
		particles(st, "magic", { offset = V(0, 3, 0), shape = box, rate = math.max(1, a * a / 400), lifetime = { 4, 7 },
			speed = { 0.3, 1 }, spread = { 180, 180 }, drag = 0.3, acceleration = V(0, 0.15, 0), size = { { 0, 0.22 }, { 0.5, 0.34 }, { 1, 0.22 } },
			transparency = { { 0, 1 }, { 0.15, 0 }, { 0.3, 0.85 }, { 0.45, 0.05 }, { 0.6, 0.9 }, { 0.75, 0.1 }, { 1, 1 } },
			color = c or tone(st, "#D8FF6A"), lightEmission = 1, lightInfluence = 0 }),
	} }
end })

local LEAVES = { leaves = { "#E07A2E", "#C9472B", "#E8B13A" }, petals = { "#FFC4D6", "#FFE1EA", "#FF9EBB" } }
local function fallers(st, v, c, o)
	local box, a = areaBox(o, 1)
	local petals = v == "petals"
	local layers = {}
	for _, hex in (if c then { c } else LEAVES[v] or LEAVES.leaves) do
		table.insert(layers, particles(st, if petals then "petal" else "leaf", { offset = V(0, 14, 0), shape = box,
			rate = math.max(1, a * a / 900), direction = "down", speed = { 2, 4 }, lifetime = { 5, 7 },
			acceleration = V(1, -1.2, 0.5), drag = 0.4, size = { { 0, 0.55 }, { 0.9, 0.55 }, { 1, 0 } },
			squash = if petals then { { 0, 0.3 }, { 0.25, -0.4 }, { 0.5, 0.3 }, { 0.75, -0.4 }, { 1, 0.3 } } else FLUTTER,
			transparency = { { 0, 1 }, { 0.05, 0 }, { 0.9, 0 }, { 1, 1 } }, color = col(st, hex),
			rotation = { 0, 360 }, rotSpeed = { -140, 140 } }))
	end
	return { layers = layers }
end
def("falling_leaves", { group = "ambient", continuous = true, weather = true, variants = { "leaves", "petals" },
	default = "leaves", build = fallers })
def("falling_petals", { group = "ambient", continuous = true, weather = true, build = function(st, _, c, o)
	return fallers(st, "petals", c, o)
end })

def("snowfall", { group = "ambient", continuous = true, weather = true, build = function(st, _, c, o)
	local box, a = areaBox(o, 1)
	return { layers = {
		particles(st, "snow", { offset = V(0, 16, 0), shape = box, rate = math.max(2, a * a / 90), direction = "down", speed = { 3, 5 },
			lifetime = { 5, 7 }, acceleration = V(0.6, 0, 0.3), size = { { 0, 0.26, 0.1 }, { 0.5, 0.32, 0.1 }, { 1, 0.24, 0.1 } },
			transparency = { { 0, 1 }, { 0.1, 0.1 }, { 0.9, 0.1 }, { 1, 1 } }, color = c or "#FFFFFF",
			lightEmission = if st.name == "neon" then 0.6 else 0.2, rotSpeed = { -30, 30 } }),
		particles(st, "snow", { offset = V(0, 12, 0), shape = box, rate = math.max(1, a * a / 600), direction = "down",
			speed = { 2, 3 }, lifetime = { 5, 6 }, acceleration = V(0.8, 0, 0.4), size = { { 0, 0.45 }, { 0.5, 0.55 }, { 1, 0.4 } },
			transparency = { { 0, 1 }, { 0.1, 0 }, { 0.9, 0 }, { 1, 1 } }, color = c or "#FFFFFF", lightEmission = 0.3,
			rotSpeed = { -60, 60 } }),
	} }
end })

def("rain", { group = "ambient", continuous = true, weather = true, splash = true, build = function(st, _, c, o)
	local box, a = areaBox(o, 1)
	return { layers = {
		particles(st, "drop", { offset = V(0, 22, 0), shape = box, rate = math.max(5, a * a / 12), direction = "down",
			speed = { 70, 80 }, lifetime = { 0.32, 0.36 }, orientation = "parallel", size = { { 0, 0.16 }, { 1, 0.14 } },
			squash = { { 0, 3 }, { 1, 3 } }, transparency = { { 0, 0.45 }, { 1, 0.6 } }, color = c or tone(st, "#C9D8E8"),
			lightInfluence = 0.6, lightEmission = if st.name == "neon" then 0.6 else 0 }),
		particles(st, "drop", { offset = V(0, 22, 0), shape = box, rate = math.max(3, a * a / 30), direction = "down",
			speed = { 55, 62 }, lifetime = { 0.4, 0.45 }, orientation = "parallel", size = { { 0, 0.1 }, { 1, 0.08 } },
			squash = { { 0, 3 }, { 1, 3 } }, transparency = { { 0, 0.7 }, { 1, 0.8 } }, color = c or tone(st, "#E3ECF5"),
			lightInfluence = 0.6 }),
	} }
end })

def("rain_splash", { group = "ambient", hidden = true, build = function(st, _, c)
	return { budget = { effects = 40, particles = 400, lights = 0 }, layers = {
		ring(st, { size = { 0.1, 1.2 }, duration = 0.25, color = c or "#DCEBFA", alpha = 0.3 }),
		particles(st, "drop", { count = 3, direction = "up", spread = { 30, 30 }, speed = { 4, 7 }, lifetime = { 0.2, 0.3 },
			size = { { 0, 0.14 }, { 1, 0.06 } }, transparency = { { 0, 0.2 }, { 1, 1 } }, color = c or "#DCEBFA",
			acceleration = V(0, -40, 0) }),
	} }
end })

def("dust_motes", { group = "ambient", continuous = true, weather = true, build = function(st, _, c, o)
	local box, a = areaBox(o, 8)
	return { layers = {
		particles(st, "magic", { offset = V(0, 4, 0), shape = box, rate = math.max(1, a * a / 300), lifetime = { 4, 6 },
			speed = { 0.2, 0.6 }, spread = { 180, 180 }, size = { { 0, 0 }, { 0.2, 0.16 }, { 0.8, 0.16 }, { 1, 0 } },
			transparency = { { 0, 1 }, { 0.3, 0.3 }, { 0.7, 0.3 }, { 1, 1 } }, color = c or tone(st, "#FFF3D1"),
			lightEmission = 0.6, lightInfluence = 0 }),
	} }
end })

def("sparkles", { group = "ambient", continuous = true, build = function(st, _, c)
	return { layers = {
		glints(st, { rate = 8, shape = { kind = "sphere", size = 3 }, size = 0.5, life = { 0.4, 0.7 },
			color = { "#FFFFFF", c or tone(st, "#FFF4B0") }, exact = true }),
		glints(st, { rate = 14, shape = { kind = "sphere", size = 3.5 }, size = 0.2, slot = "glint", life = { 0.2, 0.4 },
			speed = { 0.5, 1.5 }, color = c or tone(st, "#FFE9A0"), exact = true }),
	} }
end })

def("bubbles", { group = "ambient", continuous = true, build = function(st, _, c)
	return { layers = {
		particles(st, "bubble", { rate = 6, shape = { kind = "box", size = V(1.5, 0.2, 1.5) }, direction = "up", spread = { 15, 15 },
			speed = { 2, 4 }, lifetime = { 1.5, 2.5 }, size = { { 0, 0.15 }, { 1, 0.5 } },
			squash = { { 0, 0 }, { 0.25, 0.25 }, { 0.5, -0.2 }, { 0.75, 0.2 }, { 1, 0 } }, transparency = { { 0, 0.2 }, { 0.9, 0.2 }, { 1, 1 } },
			color = c or tone(st, "#E0F6FF"), lightEmission = 0.4, lightInfluence = 0.3, drag = 0.5, acceleration = V(0, 1, 0) }),
		particles(st, "bubble", { rate = 10, shape = { kind = "box", size = V(1.8, 0.2, 1.8) }, direction = "up", spread = { 25, 25 },
			speed = { 3, 5 }, lifetime = { 0.8, 1.4 }, size = { { 0, 0.06 }, { 1, 0.18 } }, transparency = { { 0, 0.3 }, { 0.9, 0.3 }, { 1, 1 } },
			color = c or tone(st, "#FFFFFF"), lightEmission = 0.5, lightInfluence = 0.3, acceleration = V(0, 1.5, 0) }),
	} }
end })

def("waterfall_mist", { group = "ambient", continuous = true, build = function(st, _, c)
	local base = { kind = "box", size = V(8, 1, 2) }
	return { layers = {
		puff(st, { rate = 12, shape = base, size = 3, life = { 1.5, 2.5 }, direction = "up", spread = { 50, 50 }, speed = { 3, 7 },
			drag = 1, rise = 0.5, color = c or "#F2FAFF", slot = "mist", alpha = 0.55, fadeIn = true, grow = 2.6 }),
		particles(st, "drop", { rate = 20, shape = base, direction = "up", spread = { 40, 40 }, speed = { 6, 10 }, lifetime = { 0.5, 0.8 },
			size = { { 0, 0.25 }, { 1, 0.1 } }, transparency = { { 0, 0.1 }, { 1, 1 } }, color = "#FFFFFF", acceleration = V(0, -30, 0) }),
	} }
end })

def("lava_embers", { group = "ambient", continuous = true, flicker = true, build = function(st, _, c, o)
	local box, a = areaBox(o, 0.5)
	return { layers = {
		particles(st, "ember", { shape = box, rate = math.max(2, a * a / 35), direction = "up", spread = { 20, 20 }, speed = { 2, 5 },
			lifetime = { 1.5, 3 }, acceleration = V(0.4, 1.5, 0), size = { { 0, 0.22 }, { 1, 0 } },
			transparency = { { 0, 0 }, { 0.3, 0.4 }, { 0.5, 0 }, { 0.8, 0.4 }, { 1, 1 } },
			color = col(st, { { 0, "#FFF0A0" }, { 0.3, "#FF8A2A" }, { 1, "#B0200C" } }), lightEmission = 1, lightInfluence = 0 }),
		puff(st, { shape = box, rate = math.max(1, a * a / 200), size = 2, life = { 2, 3 }, direction = "up", spread = { 10, 10 },
			speed = { 1, 2 }, rise = 0.5, drag = 0.3, color = "#4A2A22", slot = "smoke", alpha = 0.6, fadeIn = true }),
		light(st, { offset = V(0, 2, 0), color = c or "#FF6A2A", exact = c ~= nil, brightness = 2, range = math.min(a, 30), duration = 0 }),
	} }
end })

def("neon_flicker", { group = "ambient", controller = true })

FXKit.PRESETS = ORDER

------------------------------------------------------------------------------------------------ resolve & build
local function styleOf(o)
	local s = o and o.style
	if type(s) == "string" and STYLES[s] then
		return STYLES[s]
	end
	return STYLES[currentStyle]
end

-- name (maybe "explosion_large") -> preset name, meta, variant
local function resolve(name, o)
	if type(name) ~= "string" then
		return nil, nil, nil
	end
	local meta = P[name]
	local variant = o and (o.variant or o.tier or o.kind)
	if not meta then
		local base, suffix = string.match(name, "^(.-)_([%w]+)$")
		if base and P[base] then
			name, meta, variant = base, P[base], variant or suffix
		end
	end
	if not meta then
		return nil, nil, nil
	end
	variant = if variant ~= nil then tostring(variant) else meta.default
	if meta.variants and variant and not table.find(meta.variants, variant) then
		warnOnce("variant:" .. name .. variant, "'" .. name .. "' has no variant '" .. variant .. "' (" .. table.concat(meta.variants,
			", ") .. ")")
		variant = meta.default
	end
	return name, meta, variant
end

-- Readability pass (from a Studio review at 20-40 studs): presets are authored at "small" scale, then sizes, counts,
-- lifetimes, opacity and light are pushed up here so effects read big, punchy and held. Change FXKit.tuning, then
-- call FXKit.retune() to rebuild.
FXKit.tuning = { size = 2.3, count = 1.7, life = 1.5, light = 2.6, flash = 2.2, opacity = 0.7, ambient = 0.55 }

local function scaleSeq(seq, k)
	if type(seq) == "number" then
		return seq * k
	elseif type(seq) == "table" then
		local out = {}
		for i, kp in seq do
			if type(kp) == "table" then
				out[i] = { kp[1], kp[2] * k, if kp[3] then kp[3] * k else nil }
			elseif type(kp) == "number" then
				out[i] = kp * k
			else
				out[i] = kp
			end
		end
		return out
	end
	return seq
end

-- transparency keypoints pulled toward opaque (the last keypoint, the fade-out, is kept)
local function opaqueSeq(seq, k)
	if type(seq) ~= "table" then
		return seq
	end
	local out = {}
	for i, kp in seq do
		if type(kp) == "table" and i < #seq then
			out[i] = { kp[1], kp[2] * k }
		else
			out[i] = kp
		end
	end
	return out
end

local function pairScale(v, k)
	if type(v) == "table" then
		local a, b = v[1], v[2]
		return { if typeof(a) == "Vector3" or type(a) == "number" then a * k else a,
			if typeof(b) == "Vector3" or type(b) == "number" then b * k else b }
	elseif type(v) == "number" or typeof(v) == "Vector3" then
		return v * k
	end
	return v
end

local function punchUp(spec, meta)
	local T = FXKit.tuning
	-- ambient fields and weather grow less (many small things, not one event)
	local a = if meta.weather then T.ambient elseif meta.group == "ambient" then 0.75 else 1
	local function lerpK(k)
		return 1 + (k - 1) * a
	end
	local size, count, life = lerpK(T.size), lerpK(T.count), lerpK(T.life)
	for _, L in spec.layers do
		local k = L.kind
		if k == "particles" then
			L.size = scaleSeq(L.size, size)
			if type(L.shape) == "table" and meta.group ~= "ambient" then
				L.shape = table.clone(L.shape)
				L.shape.size = pairScale(L.shape.size, math.sqrt(size))
			end
			if L.count then
				L.count = math.min(math.floor(L.count * count + 0.5), 400)
			end
			if L.rate and not meta.weather then
				L.rate = math.min(L.rate * count * 0.85, 400)
			end
			if type(L.lifetime) == "table" and not meta.weather then
				L.lifetime = { math.min(math.max(L.lifetime[1] * life, 0.14), 2.4), math.min(math.max(L.lifetime[2] * life, 0.24), 3) }
			end
			if L.duration then
				L.duration *= life
			end
			if not meta.weather then
				L.transparency = opaqueSeq(L.transparency, T.opacity)
				if (L.lightEmission or 0) >= 0.5 then
					L.brightness = math.min((L.brightness or 1) * 1.8, 4)
				end
			end
			-- bursts open up with their size
			if L.count and type(L.speed) == "table" then
				L.speed = { L.speed[1] * math.sqrt(size), L.speed[2] * math.sqrt(size) }
			end
		elseif k == "flash" then
			L.size = pairScale(L.size, T.flash)
			L.duration = math.clamp((L.duration or 0.1) * 2.2, 0.15, 0.4)
		elseif k == "ring" then
			L.size = pairScale(L.size, size * 0.9)
			L.duration = math.clamp((L.duration or 0.35) * 1.6, 0.4, 1.2)
			L.transparency = opaqueSeq(L.transparency, 0.5)
			L.brightness = math.min((L.brightness or 1) * 2, 6)
			L.lightEmission = math.max(L.lightEmission or 0, 0.6)
		elseif k == "beam" then
			L.width = pairScale(L.width, 1.8)
			L.duration = (L.duration or 0.3) * 1.8
			L.fadeOut = math.min((L.fadeOut or 0.15) * 1.6, 1)
		elseif k == "light" then
			L.brightness = math.min((L.brightness or 2) * T.light, 10)
			L.range = math.min((L.range or 12) * 1.6, 60)
			if L.duration and L.duration > 0 then
				L.duration = math.max(L.duration * 2, 0.35)
			end
		elseif k == "decal" then
			L.size = pairScale(L.size, 1.6)
		end
	end
	return spec
end

function FXKit.retune()
	table.clear(specCache)
end

local function build(name, meta, st, variant, o)
	local c = asHex(o and o.color)
	local area = if meta.weather or name == "lava_embers" then tostring(math.floor(tonumber(o and o.area) or 60)) else ""
	local key = name .. "|" .. st.name .. "|" .. tostring(variant) .. "|" .. tostring(c) .. "|" .. area
	local spec = specCache[key]
	if spec then
		return spec
	end
	local ok, result = pcall(meta.build, st, variant, c, o or {})
	if not ok or type(result) ~= "table" then
		warnOnce("build:" .. key, "preset '" .. name .. "' failed to build: " .. tostring(result))
		return nil
	end
	result.family = result.family or name
	punchUp(result, meta)
	for _, problem in VFX.validate(result) do
		warnOnce("spec:" .. key .. problem, "preset '" .. name .. "' (" .. st.name .. "): " .. problem)
	end
	specCache[key] = result
	return result
end

-- The spec a preset builds for a style (nil for screen / dynamic / controller presets); for tools and tests.
function FXKit.spec(name, opts)
	local o = if type(opts) == "table" then opts else {}
	local n, meta, variant = resolve(name, o)
	if not meta or not meta.build then
		return nil
	end
	return build(n, meta, styleOf(o), variant, o)
end

------------------------------------------------------------------------------------------------ handles
local Handle = {}
Handle.__index = Handle

local function newHandle(fx, cleanup)
	return setmetatable({ fx = fx, cleanup = cleanup or {}, alive = true, base = nil }, Handle)
end

-- Continuous emission rate as a multiple of the preset's own (0 pauses, 1 = as tuned; e.g. by speed).
function Handle:set(k)
	local fx = self.fx
	if not fx or not fx.alive or type(k) ~= "number" then
		return self
	end
	if not self.base then
		self.base = {}
		for _, e in fx.continuous do
			self.base[e] = e.Rate
		end
	end
	for e, rate in self.base do
		if e.Parent then
			e.Rate = rate * math.max(k, 0)
			e.Enabled = k > 0
		end
	end
	return self
end

function Handle:stop()
	if not self.alive then
		return self
	end
	self.alive = false
	if self.fx then
		self.fx:stop()
	end
	for _, fn in self.cleanup do
		task.spawn(fn)
	end
	table.clear(self.cleanup)
	return self
end
Handle.Destroy = Handle.stop
Handle.destroy = Handle.stop

function Handle:andThen(fn)
	if self.fx then
		self.fx:andThen(fn)
	end
	return self
end

local NULL = setmetatable({ alive = false, cleanup = {} }, Handle)

------------------------------------------------------------------------------------------------ juice helpers
local function cameraRig()
	return if IS_CLIENT then optional("CameraRig") else nil
end

local function positionOf(at)
	local ty = typeof(at)
	if ty == "Vector3" then
		return at
	elseif ty == "CFrame" then
		return at.Position
	elseif ty == "Instance" then
		if at:IsA("Attachment") then
			return at.WorldPosition
		elseif at:IsA("BasePart") then
			return at.Position
		elseif at:IsA("Model") then
			return at:GetPivot().Position
		end
	end
	return nil
end

local function cameraFalloff(at, radius)
	local pos = positionOf(at)
	local cam = workspace.CurrentCamera
	if not pos or not cam then
		return 1
	end
	return math.clamp(1 - (cam.CFrame.Position - pos).Magnitude / math.max(radius, 1), 0, 1)
end

-- Camera shake (trauma 0..1), fading to nothing `radius` studs from the camera.
function FXKit.shakeAt(at, trauma, radius)
	if not IS_CLIENT then
		return
	end
	local t = trauma * cameraFalloff(at, radius or 60)
	if t <= 0.01 then
		return
	end
	local rig = cameraRig()
	if rig and type(rig.shake) == "function" then
		rig.shake(math.clamp(t, 0, 1))
		return
	end
	local Shake = optional("Shake")
	if Shake and type(Shake.kick) == "function" then
		Shake.kick(math.clamp(t, 0, 1))
	end
end

function FXKit.flashAt(at, color, strength, radius)
	local k = cameraFalloff(at, radius or 60)
	if k > 0.05 then
		FXKit.flash(color, strength * k)
	end
end

-- Freeze-frame: intensity 0..1 -> 30..120 ms.
function FXKit.hitstop(intensity)
	VFX.hitstop(0.03 + 0.09 * clamp01(intensity or 0.5))
end

-- Camera punch: an FOV snap, a shake and (with a direction) a positional kick. intensity 0..1.
function FXKit.punch(intensity, direction)
	if not IS_CLIENT then
		return
	end
	local i = clamp01(intensity or 0.5)
	local rig = cameraRig()
	if rig then
		if type(rig.kick) == "function" then
			rig.kick(-(2 + 6 * i), 0.2 + 0.15 * i)
		end
		if type(rig.shake) == "function" then
			rig.shake(0.15 + 0.45 * i)
		end
		if typeof(direction) == "Vector3" and type(rig.punch) == "function" then
			rig.punch(direction, 0.15 + 0.5 * i)
		end
		return
	end
	local Shake = optional("Shake")
	if Shake and type(Shake.kick) == "function" then
		Shake.kick(0.15 + 0.45 * i)
	end
end

function FXKit.flash(color, strength, seconds)
	VFX.screenFlash(color or "#FFFFFF", seconds or 0.15, strength or 0.35)
end

-- Slow motion for things that read CameraRig.timeScale (VFX particles, camera moves); physics is untouched.
function FXKit.slowmo(scale, seconds)
	local rig = cameraRig()
	if rig and type(rig.slowmo) == "function" then
		rig.slowmo(scale, seconds)
	end
end

------------------------------------------------------------------------------------------------ world helpers
local function fxFolder(name)
	local f = workspace:FindFirstChild(name)
	if not f then
		f = Instance.new("Folder")
		f.Name = name
		f.Parent = workspace
	end
	return f
end

local function rayParams()
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore = {}
	for _, n in { "KitVFX", "KitFXDebris", "KitFXWorld" } do
		local f = workspace:FindFirstChild(n)
		if f then
			table.insert(ignore, f)
		end
	end
	for _, plr in Players:GetPlayers() do
		if plr.Character then
			table.insert(ignore, plr.Character)
		end
	end
	params.FilterDescendantsInstances = ignore
	return params
end

-- A scorch mark on the ground below `at` (when there is ground within reach).
function FXKit.scorch(at, size, seconds)
	local pos = positionOf(at)
	if not pos then
		return
	end
	local hit = workspace:Raycast(pos + Vector3.new(0, 1, 0), Vector3.new(0, -(size + 3), 0), rayParams())
	if hit then
		local st = STYLES[currentStyle]
		VFX.effect({ family = "scorch", layers = { scorchLayer(st, { size * 0.6, size }, seconds or 6) } }, hit.Position,
			{ normal = hit.Normal }, "scorch")
	end
end

-- Physical chunks flung from `at` that bounce, fade and disappear (client-side, ignored by queries and touches).
function FXKit.debris(at, opts)
	local pos = positionOf(at)
	if not pos then
		return
	end
	opts = opts or {}
	local folder = fxFolder("KitFXDebris")
	local count = math.clamp(opts.count or 5, 0, 24)
	local color = asHex(opts.color) or "#3B3633"
	local r, g, b = FxMath.hex(color)
	for _ = 1, count do
		local p = Instance.new("Part")
		p.Name = "Debris"
		local s = (opts.size or 0.5) * (0.6 + math.random() * 0.8)
		p.Size = Vector3.new(s, s * (0.6 + math.random() * 0.6), s)
		p.Color = Color3.new(r :: number, g :: number, b :: number)
		p.Material = Enum.Material.Slate
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.CFrame = CFrame.new(pos + Vector3.new(math.random() - 0.5, 0.5, math.random() - 0.5))
			* CFrame.Angles(math.random() * 6.28, math.random() * 6.28, 0)
		p.CustomPhysicalProperties = PhysicalProperties.new(0.3, 0.5, 0.3)
		p.Parent = folder
		local dir = Vector3.new(math.random() - 0.5, 0.9 + math.random() * 0.6, math.random() - 0.5).Unit
		p.AssemblyLinearVelocity = dir * (opts.speed or 30) * (0.6 + math.random() * 0.6)
		p.AssemblyAngularVelocity = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * 30
		task.delay(1.6 + math.random() * 0.6, function()
			if p.Parent then
				TweenService:Create(p, TweenInfo.new(0.5), { Transparency = 1, Size = p.Size * 0.3 }):Play()
				task.delay(0.55, function()
					p:Destroy()
				end)
			end
		end)
	end
end

------------------------------------------------------------------------------------------------ dynamic presets
local function lookFrame(from, to)
	local d = to - from
	if d.Magnitude < 1e-3 then
		return CFrame.new(from), 0
	end
	local up = if math.abs(d.Unit.Y) > 0.99 then Vector3.zAxis else Vector3.yAxis
	return CFrame.lookAt(from, to, up), d.Magnitude
end

-- A bullet tracer from `from` to `to` (Vector3s / parts / attachments). opts: color, width, impact = "concrete" |
-- "metal" | "wood" | "flesh" | "water" (plays that impact at the end, facing opts.normal), style.
function FXKit.tracer(from, to, opts)
	opts = opts or {}
	local a, b = positionOf(from), positionOf(to)
	if not a or not b then
		warnOnce("tracer:args", "tracer(from, to) needs two positions")
		return NULL
	end
	local st = styleOf(opts)
	local cf, dist = lookFrame(a, b)
	local hot = asHex(opts.color) or tone(st, "#FFC04D")
	local w = tonumber(opts.width) or 0.22
	local life = math.clamp(dist / 600, 0.06, 0.16)
	local fx = VFX.effect({ family = "bullet_tracer", layers = {
		{ kind = "beam", from = V(0, 0, 0), to = V(0, 0, -dist), width = { w * 0.4, w }, color = { hot, "#FFF7D6" },
			transparency = { { 0, 0.8 }, { 1, 0 } }, lightEmission = 1, lightInfluence = 0, duration = 0.08, fadeOut = 0.12 },
		{ kind = "beam", from = V(0, 0, 0), to = V(0, 0, -dist), width = { w * 1.2, w * 2.5 }, color = hot,
			transparency = { { 0, 0.95 }, { 1, 0.6 } }, lightEmission = 1, lightInfluence = 0, duration = 0.06, fadeOut = 0.1 },
		{ kind = "particles", texture = (texOf(st, "streak")), count = 1, direction = "forward", spread = 0,
			speed = math.min(dist / life, 1000), lifetime = life, orientation = "parallel", size = { { 0, w * 3 }, { 1, w * 2 } },
			squash = { { 0, 3 }, { 1, 3 } }, color = "#FFFFFF", lightEmission = 1, lightInfluence = 0, transparency = { { 0, 0 }, { 1, 0.4 } } },
	} }, cf, nil, "bullet_tracer")
	if type(opts.impact) == "string" then
		local delay = life
		task.delay(delay, function()
			FXKit.play("impact_" .. opts.impact, b, { normal = opts.normal or (a - b), style = opts.style })
		end)
	end
	return newHandle(fx)
end

-- A forked lightning strike from `from` to `to`. opts: color, width, segments, style.
function FXKit.lightning(from, to, opts)
	opts = opts or {}
	local a, b = positionOf(from), positionOf(to)
	if not a or not b then
		warnOnce("lightning:args", "lightning(from, to) needs two positions")
		return NULL
	end
	local st = styleOf(opts)
	local cf, dist = lookFrame(a, b)
	local hue = asHex(opts.color) or tone(st, "#9CC8FF")
	local n = math.clamp(math.floor(tonumber(opts.segments) or dist / 3), 4, 14)
	local w = tonumber(opts.width) or 0.6
	local layers = {}
	local function bolt(delay, width, jitter, alpha)
		local prev = V(0, 0, 0)
		for i = 1, n do
			local z = -dist * i / n
			local p = if i == n then V(0, 0, -dist) else V((math.random() - 0.5) * jitter, (math.random() - 0.5) * jitter, z)
			table.insert(layers, { kind = "beam", delay = delay, from = prev, to = p, width = { width, width * 0.8 },
				color = { "#FFFFFF", hue }, transparency = alpha, lightEmission = 1, lightInfluence = 0, duration = 0.1, fadeOut = 0.12,
				faceCamera = true })
			prev = p
		end
	end
	local jitter = math.clamp(dist * 0.12, 0.5, 6)
	bolt(0, w, jitter, 0)
	bolt(0, w * 3, jitter * 0.2, 0.75)
	bolt(0.08, w * 0.7, jitter, 0.1)
	bolt(0.16, w * 0.9, jitter, 0.05)
	table.insert(layers, flash(st, { offset = V(0, 0, -dist), size = { 1.5, 7 }, duration = 0.2, color = "#FFFFFF" }))
	table.insert(layers, ring(st, { offset = V(0, 0, -dist), size = { 2, 14 }, duration = 0.5, color = hue, exact = true, alpha = 0 }))
	table.insert(layers, light(st, { offset = V(0, 0, -dist), color = hue, exact = true, brightness = 12, range = 40, duration = 0.5 }))
	table.insert(layers, sparks(st, { offset = V(0, 0, -dist), count = 24, direction = "back", spread = { 70, 70 }, speed = { 20, 40 },
		size = 0.45, gravity = 30, colors = { "#FFFFFF", hue }, exact = true, life = { 0.3, 0.6 } }))
	local fx = VFX.effect({ family = "lightning", layers = layers }, cf, nil, "lightning")
	FXKit.flashAt(b, shade(hue, 0.6), 0.15, 50)
	FXKit.shakeAt(b, 0.2, 50)
	return newHandle(fx)
end

-- A magic projectile from `from` to `to`: a glowing bolt flies (opts.speed studs/s, default 60), then plays
-- magic_impact. opts: color, speed, arc (studs of rise mid-flight), style, onHit(position).
function FXKit.bolt(from, to, opts)
	opts = opts or {}
	local a, b = positionOf(from), positionOf(to)
	if not a or not b then
		warnOnce("bolt:args", "bolt(from, to) needs two positions")
		return NULL
	end
	local carrier = Instance.new("Part")
	carrier.Name = "KitBolt"
	carrier.Anchored = true
	carrier.CanCollide = false
	carrier.CanQuery = false
	carrier.CanTouch = false
	carrier.Transparency = 1
	carrier.Size = Vector3.new(0.2, 0.2, 0.2)
	carrier.CFrame = CFrame.new(a)
	carrier.Parent = fxFolder("KitFXWorld")
	local fx = VFX.play("magic_bolt", carrier, { follow = true, style = opts.style, color = opts.color })
	local h = newHandle(fx)
	local dist = (b - a).Magnitude
	local duration = dist / math.max(tonumber(opts.speed) or 60, 1)
	local arc = tonumber(opts.arc) or 0
	local t = 0
	local conn
	conn = RunService.Heartbeat:Connect(function(dt)
		t += dt
		local u = math.min(t / math.max(duration, 1e-3), 1)
		carrier.CFrame = CFrame.new(a:Lerp(b, u) + Vector3.new(0, arc * 4 * u * (1 - u), 0))
		if u >= 1 then
			conn:Disconnect()
			if fx.alive then
				fx:stop()
			end
			fx:andThen(function()
				carrier:Destroy()
			end)
			FXKit.play("magic_impact", b, { style = opts.style, color = opts.color })
			if type(opts.onHit) == "function" then
				task.spawn(opts.onHit, b)
			end
		end
	end)
	table.insert(h.cleanup, function()
		conn:Disconnect()
		task.delay(1, function()
			carrier:Destroy()
		end)
	end)
	return h
end

-- Skid marks: a dark ribbon trail on `part` (attach it to the chassis or a non-spinning part at the wheel, not to
-- a spinning wheel). opts: width, lifetime, color, offset (Vector3 in part space; default: the part's underside).
function FXKit.skid(part, opts)
	opts = opts or {}
	if typeof(part) ~= "Instance" or not part:IsA("BasePart") then
		warnOnce("skid:part", "skid needs a BasePart")
		return VFX.trail(part, {})
	end
	return VFX.trail(part, { width = opts.width or 0.7, axis = "right", lifetime = opts.lifetime or 4,
		color = asHex(opts.color) or "#1E1E1E", transparency = { { 0, 0.35 }, { 0.8, 0.6 }, { 1, 1 } }, faceCamera = false,
		offset = if typeof(opts.offset) == "Vector3" then opts.offset else Vector3.new(0, -part.Size.Y / 2 + 0.05, 0),
		minLength = 0.2, enabled = opts.enabled })
end

-- A flickering neon sign or lamp: a BasePart (its own light is added) or a position (a small glowing bulb is
-- made). opts: color, brightness, range, rate (dropouts per second). Returns a handle; :stop() restores the part.
function FXKit.flicker(target, opts)
	opts = opts or {}
	local made = nil
	local part = if typeof(target) == "Instance" and target:IsA("BasePart") then target else nil
	if not part then
		local pos = positionOf(target)
		if not pos then
			warnOnce("flicker:args", "flicker needs a BasePart or a position")
			return NULL
		end
		made = Instance.new("Part")
		made.Name = "KitNeon"
		made.Anchored = true
		made.CanCollide = false
		made.CanQuery = false
		made.CanTouch = false
		made.Material = Enum.Material.Neon
		made.Shape = Enum.PartType.Ball
		made.Size = Vector3.new(0.6, 0.6, 0.6)
		made.CFrame = CFrame.new(pos)
		local hex = asHex(opts.color) or tone(styleOf(opts), "#FF4FD8")
		local r, g, b = FxMath.hex(hex)
		made.Color = Color3.new(r :: number, g :: number, b :: number)
		made.Parent = fxFolder("KitFXWorld")
		part = made
	end
	local p = part :: BasePart
	local lightInst = Instance.new("PointLight")
	lightInst.Color = p.Color
	lightInst.Range = tonumber(opts.range) or 12
	local peak = tonumber(opts.brightness) or 2
	lightInst.Brightness = peak
	lightInst.Parent = p
	local baseT = p.Transparency
	local rate = tonumber(opts.rate) or 0.6
	local offUntil, nextDrop, burst = 0, os.clock() + math.random() / rate, 0
	local conn = RunService.Heartbeat:Connect(function()
		local now = os.clock()
		if now >= nextDrop then
			burst = math.random(1, 3)
			nextDrop = now + 0.06
			offUntil = now + 0.03 + math.random() * 0.06
		end
		local on = now >= offUntil
		if on and burst > 0 and now >= nextDrop - 0.0001 then
			burst -= 1
			if burst <= 0 then
				nextDrop = now + (0.5 + math.random()) / rate
			end
		end
		p.Transparency = if on then baseT else math.max(baseT, 0.65)
		lightInst.Brightness = if on then peak * (0.92 + math.random() * 0.08) else peak * 0.1
	end)
	return newHandle(nil, { function()
		conn:Disconnect()
		lightInst:Destroy()
		if made then
			made:Destroy()
		elseif p.Parent then
			p.Transparency = baseT
		end
	end })
end

------------------------------------------------------------------------------------------------ speed lines
local lines = nil
local LINE_COUNT = 34

local function lineState(i, fresh)
	local a = math.random() * math.pi * 2
	return { a = a, r = if fresh then 0.35 + math.random() * 0.75 else 0.45 + math.random() * 0.25, v = 0.9 + math.random() * 0.9,
		len = 0.08 + math.random() * 0.16, w = 0.6 + math.random() * 0.8, i = i }
end

local function stepLines(dt)
	local L = lines
	if not L then
		return
	end
	L.level += (L.target - L.level) * math.min(dt * 8, 1)
	local cam = workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1920, 1080)
	local half = math.sqrt(vp.X * vp.X + vp.Y * vp.Y) / 2
	local active = math.floor(LINE_COUNT * math.clamp(L.level, 0, 1) + 0.5)
	local sty = L.style
	for i, s in L.state do
		local f = L.frames[i]
		if i <= active then
			s.r += s.v * dt * (0.7 + L.level)
			if s.r > 1.15 then
				L.state[i] = lineState(i, false)
				s = L.state[i]
			end
			local edge = math.clamp((s.r - 0.4) / 0.25, 0, 1) -- fade in past the centre region
			f.Visible = true
			f.Position = UDim2.fromOffset(vp.X / 2 + math.cos(s.a) * s.r * half, vp.Y / 2 + math.sin(s.a) * s.r * half)
			f.Size = UDim2.fromOffset(half * s.len * (0.6 + L.level), sty.thick * s.w)
			f.Rotation = math.deg(s.a)
			f.BackgroundTransparency = 1 - sty.alpha * edge * math.clamp(L.level * 1.5, 0, 1)
		else
			f.Visible = false
		end
	end
	if L.target <= 0 and L.level < 0.02 then
		L.gui.Enabled = false
		if L.conn then
			L.conn:Disconnect()
			L.conn = nil
		end
	end
end

-- Screen-space speed lines streaming out from the centre. intensity 0..1 (e.g. speed / topSpeed; call it as speed
-- changes, 0 fades them out). opts: color, thick (px), alpha, style. Returns a handle (:set(i), :stop()).
function FXKit.speedLines(intensity, opts)
	if not IS_CLIENT then
		return NULL
	end
	opts = opts or {}
	local player = Players.LocalPlayer
	local pg = player and player:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return NULL
	end
	if not lines or not lines.gui.Parent then
		local gui = Instance.new("ScreenGui")
		gui.Name = "KitSpeedLines"
		gui.ResetOnSpawn = false
		gui.IgnoreGuiInset = true
		gui.DisplayOrder = 80
		gui.Parent = pg
		local frames, state = {}, {}
		for i = 1, LINE_COUNT do
			local f = Instance.new("Frame")
			f.Name = "Line"
			f.AnchorPoint = Vector2.new(0.5, 0.5)
			f.BorderSizePixel = 0
			f.BackgroundTransparency = 1
			f.Visible = false
			local g = Instance.new("UIGradient")
			g.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.55, 0),
				NumberSequenceKeypoint.new(1, 0.4) })
			g.Parent = f
			f.Parent = gui
			frames[i] = f
			state[i] = lineState(i, true)
		end
		lines = { gui = gui, frames = frames, state = state, level = 0, target = 0, conn = nil, style = STYLES.toon.lines }
	end
	local L = lines :: any
	local base = styleOf(opts).lines
	local hex = asHex(opts.color) or base.color
	L.style = { thick = tonumber(opts.thick) or base.thick, alpha = tonumber(opts.alpha) or base.alpha }
	local r, g, b = FxMath.hex(hex)
	for _, f in L.frames do
		f.BackgroundColor3 = Color3.new(r :: number, g :: number, b :: number)
	end
	L.target = clamp01(intensity)
	if L.target > 0 then
		L.gui.Enabled = true
		if not L.conn then
			L.conn = RunService.RenderStepped:Connect(stepLines)
		end
	end
	local h = newHandle(nil, { function()
		L.target = 0
	end })
	function h.set(_, k)
		L.target = clamp01(k)
		if L.target > 0 and not L.conn then
			L.gui.Enabled = true
			L.conn = RunService.RenderStepped:Connect(stepLines)
		end
		return h
	end
	return h
end

------------------------------------------------------------------------------------------------ weather
-- An ambient field that follows the camera: "rain" (with splashes), "snowfall", "falling_leaves",
-- "falling_petals", "fireflies", "dust_motes". opts: area (studs, default 60), intensity, color, style.
function FXKit.weather(name, opts)
	if not IS_CLIENT then
		return NULL
	end
	opts = table.clone(opts or {})
	local n, meta = resolve(name, opts)
	if not meta or not meta.weather then
		warnOnce("weather:" .. tostring(name), "weather needs one of rain, snowfall, falling_leaves, falling_petals, fireflies, dust_motes")
		return NULL
	end
	local anchor = Instance.new("Part")
	anchor.Name = "KitWeather"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	local function place()
		local cam = workspace.CurrentCamera
		if cam then
			local look = cam.CFrame.LookVector
			local flat = Vector3.new(look.X, 0, look.Z)
			local ahead = if flat.Magnitude > 1e-3 then flat.Unit * (tonumber(opts.area) or 60) * 0.2 else Vector3.zero
			anchor.CFrame = CFrame.new(cam.CFrame.Position + ahead)
		end
	end
	place()
	anchor.Parent = fxFolder("KitFXWorld")
	opts.follow = true
	local h = FXKit.play(n, anchor, opts)
	if not h.alive then
		anchor:Destroy()
		return h
	end
	local splashAcc = 0
	local area = tonumber(opts.area) or 60
	local params = rayParams()
	local conn = RunService.RenderStepped:Connect(function(dt)
		place()
		if meta.splash then
			splashAcc += dt * 30 * (tonumber(opts.intensity) or 1)
			while splashAcc >= 1 do
				splashAcc -= 1
				local p = anchor.Position + Vector3.new((math.random() - 0.5) * area * 0.6, 30, (math.random() - 0.5) * area * 0.6)
				local hit = workspace:Raycast(p, Vector3.new(0, -80, 0), params)
				if hit then
					FXKit.play("rain_splash", hit.Position, { normal = hit.Normal, style = opts.style })
				end
			end
		end
	end)
	table.insert(h.cleanup, function()
		conn:Disconnect()
		task.delay(8, function()
			anchor:Destroy()
		end)
	end)
	return h
end

------------------------------------------------------------------------------------------------ play
local EFFECT_OPTS = { "scale", "intensity", "normal", "direction", "follow", "timeScaled", "onDone" }

local function startFlicker(h)
	local fx = h.fx
	if not fx or #fx.lights == 0 then
		return
	end
	local base = {}
	for _, l in fx.lights do
		base[l] = l.Brightness
	end
	local seed = math.random() * 100
	local conn = RunService.Heartbeat:Connect(function()
		local t = os.clock() * 9 + seed
		local k = 0.82 + 0.18 * math.noise(t, 0.5) + 0.08 * math.noise(t * 2.3, 4.1)
		for l, b in base do
			if l.Parent then
				l.Brightness = b * k
			end
		end
	end)
	table.insert(h.cleanup, function()
		conn:Disconnect()
	end)
	fx:andThen(function()
		conn:Disconnect()
	end)
end

local remote = nil

local function sanitize(o)
	if type(o) ~= "table" then
		return nil
	end
	local out = {}
	for k, v in o do
		local t = typeof(v)
		if type(k) == "string" and (t == "number" or t == "string" or t == "boolean" or t == "Vector3" or t == "CFrame"
			or t == "Color3" or t == "Instance") then
			out[k] = v
		end
	end
	return out
end

-- Plays a preset at `at` (Vector3, CFrame, BasePart, Attachment or Model) and returns a handle (:stop(), :set(k),
-- :andThen(fn), .alive). On the server it plays on every client (see playAll) and returns an inert handle.
function FXKit.play(name, at, opts)
	if IS_SERVER and not IS_CLIENT then
		FXKit.playAll(name, at, opts)
		return NULL
	end
	local o = if type(opts) == "table" then table.clone(opts) else {}
	local n, meta, variant = resolve(name, o)
	if not meta then
		local guess = if type(name) == "string" then FxMath.closest(name, ORDER) else nil
		warnOnce("play:" .. tostring(name), "no preset '" .. tostring(name) .. "'" .. (if guess then " (did you mean '" .. guess .. "'?)" else ""))
		return NULL
	end
	local st = styleOf(o)
	if meta.screen then
		return FXKit.speedLines(if o.intensity == nil then 1 else o.intensity, o)
	elseif meta.trail then
		local t = FXKit.skid(at, o)
		return setmetatable({ alive = t.alive, cleanup = { function()
			t:destroy()
		end } }, Handle)
	elseif meta.controller then
		return FXKit.flicker(at, o)
	elseif meta.dynamic then
		if n == "bullet_tracer" then
			return FXKit.tracer(at, o.to, o)
		end
		return FXKit.lightning(at, o.to, o)
	elseif meta.projectile and o.to ~= nil then
		return FXKit.bolt(at, o.to, o)
	elseif meta.weather and at == nil then
		return FXKit.weather(n, o)
	end
	if at == nil then
		warnOnce("play:at:" .. n, "'" .. n .. "' needs a position, CFrame, part or attachment")
		return NULL
	end
	local spec = build(n, meta, st, variant, o)
	if not spec then
		return NULL
	end
	if meta.adapt then
		meta.adapt(at, o, variant)
	end
	if meta.continuous and o.follow == nil and typeof(at) == "Instance" then
		o.follow = true
	end
	local fxOpts = FxMath.normalizeKeys(o, EFFECT_OPTS)
	local fx = VFX.effect(spec, at, fxOpts, n)
	local h = newHandle(fx)
	if meta.flicker then
		startFlicker(h)
	end
	if meta.extra and o.juice ~= false then
		local ok, err = pcall(meta.extra, at, o, st, variant, h)
		if not ok then
			warnOnce("extra:" .. n, "'" .. n .. "' extras failed: " .. tostring(err))
		end
	end
	return h
end

-- Plays on every client. From the server: fires the kit remote. From a client: plays here and asks the server to
-- relay it to everyone else (rate-limited per player).
function FXKit.playAll(name, at, opts)
	if IS_SERVER and not IS_CLIENT then
		if remote then
			remote:FireAllClients(name, at, sanitize(opts))
		end
		return NULL
	end
	local h = FXKit.play(name, at, opts)
	local r = ReplicatedStorage:FindFirstChild(REMOTE_NAME)
	if r and r:IsA("RemoteEvent") then
		r:FireServer(name, at, sanitize(opts))
	end
	return h
end

------------------------------------------------------------------------------------------------ setup
function FXKit.setStyle(style)
	if type(style) ~= "string" or not STYLES[style] then
		warnOnce("style:" .. tostring(style), "style must be one of " .. table.concat(FXKit.STYLES, ", "))
		return
	end
	currentStyle = style
end

function FXKit.getStyle()
	return currentStyle
end

-- Replaces a texture slot (e.g. "flame", "smoke", "spark", "star", "ring", "dust", "confetti") with an image id,
-- optionally a flipbook ({ layout = "2x2"|"4x4"|"8x8", fps = 24, mode = "loop"|"oneshot"|"pingpong"|"random" }).
function FXKit.texture(slot, imageId, flipbook)
	if type(slot) ~= "string" then
		warnOnce("texture:slot", "texture(slot, imageId) needs a slot name (" .. table.concat(FXKit.SLOTS, ", ") .. ")")
		return
	end
	if imageId == nil then
		overrides[slot] = nil
	else
		local id = if type(imageId) == "number" then "rbxassetid://" .. tostring(math.floor(imageId)) else imageId
		overrides[slot] = { id = id, flipbook = if type(flipbook) == "table" then flipbook else nil }
	end
	table.clear(specCache)
end

function FXKit.has(name)
	return (resolve(name, nil)) ~= nil
end

-- Preset names (hidden helpers left out), optionally only one group: "movement" | "combat" | "pickups" | "ambient".
function FXKit.names(group)
	local out = {}
	for _, n in ORDER do
		local m = P[n]
		if not m.hidden and (group == nil or m.group == group) then
			table.insert(out, n)
		end
	end
	return out
end

function FXKit.info(name)
	local n, meta = resolve(name, nil)
	if not meta then
		return nil
	end
	return { name = n, group = meta.group, variants = meta.variants, continuous = meta.continuous == true,
		weather = meta.weather == true }
end

local registered = false
-- Registers the presets with VFX (so VFX.play("explosion", pos, {variant = "large", style = "neon"}) works too;
-- camera extras only run through FXKit.play) and starts listening for server-played effects. Safe to call twice.
function FXKit.register()
	if registered then
		return FXKit
	end
	registered = true
	for _, n in ORDER do
		local meta = P[n]
		if meta.build then
			VFX.preset(n, function(o)
				local _, _, variant = resolve(n, o)
				return build(n, meta, styleOf(o), variant, o) or { layers = {} }
			end)
		end
	end
	VFX.budget("rain_splash", { effects = 40, particles = 400, lights = 0 })
	return FXKit
end

if IS_SERVER and not IS_CLIENT then
	remote = ReplicatedStorage:FindFirstChild(REMOTE_NAME)
	if not remote then
		remote = Instance.new("RemoteEvent")
		remote.Name = REMOTE_NAME
		remote.Parent = ReplicatedStorage
	end
	local budget = {}
	remote.OnServerEvent:Connect(function(player, name, at, opts)
		if type(name) ~= "string" or not P[(resolve(name, nil))] then
			return
		end
		local now = os.clock()
		local b = budget[player] or { t = now, n = 0 }
		if now - b.t > 1 then
			b.t, b.n = now, 0
		end
		b.n += 1
		budget[player] = b
		if b.n > 20 then
			return
		end
		for _, other in Players:GetPlayers() do
			if other ~= player then
				remote:FireClient(other, name, at, sanitize(opts))
			end
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		budget[player] = nil
	end)
elseif IS_CLIENT then
	local function listen(r)
		if r.Name == REMOTE_NAME and r:IsA("RemoteEvent") then
			r.OnClientEvent:Connect(function(name, at, opts)
				FXKit.play(name, at, opts)
			end)
			return true
		end
		return false
	end
	local existing = ReplicatedStorage:FindFirstChild(REMOTE_NAME)
	if not (existing and listen(existing)) then
		local conn
		conn = ReplicatedStorage.ChildAdded:Connect(function(child)
			if listen(child) then
				conn:Disconnect()
			end
		end)
	end
	local Debug = optional("Debug")
	if Debug and type(Debug.register) == "function" then
		Debug.register("fxkit", function(name, style)
			if name == nil then
				return FXKit.names()
			end
			local cam = workspace.CurrentCamera
			local pos = if cam then (cam.CFrame * CFrame.new(0, -2, -14)).Position else Vector3.zero
			local h = FXKit.play(tostring(name), pos, { style = style })
			return if h.alive then "played " .. tostring(name) else "could not play " .. tostring(name)
		end, "play an FXKit preset in front of the camera: name, style (no arguments lists the presets)")
	end
end

return FXKit
