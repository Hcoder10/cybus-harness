--!nonstrict
-- UIKit: themed, animated game UI components on the 1920x1080 canvas (client).
--   UIKit.theme("arcade" | "cozy" | "tactical" | "fantasy" | "toon", overrides?) -> theme (becomes current)
--   local hp = UIKit.bar({label = "HEALTH", value = 80, max = 100}); hp:set(55)
--   UIKit.banner("GO!"):flash(1.2); UIKit.toast("Quest complete", {kind = "good"}); UIKit.damage(part, 42, {kind = "crit"})
-- Every component returns an object with :set(...), :show(), :hide(), :Destroy(), animates in/out and on change,
-- and looks finished with no images: panels are layered gradients, strokes and hard shadows. Optional `image`/`icon`
-- fields take an Assets name ("coin_icon"), an rbxassetid string or a number.
-- Slanted panels are stacks of horizontal strips: Roblox cannot clip rotated frames, so a skew is built, not rotated.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local TextService = game:GetService("TextService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")

local Kit = script.Parent
local Spring = require(Kit:WaitForChild("Spring"))
local Screen = require(Kit:WaitForChild("Screen"))
local Assets = require(Kit:WaitForChild("Assets"))

local Tokens
do
	local ok, result = pcall(function()
		return require(ReplicatedStorage:WaitForChild("Shared", 5):WaitForChild("Tokens", 5))
	end)
	Tokens = ok and result or nil
end

local UIKit: any = {}
UIKit.onSound = nil -- function(name, component?) : "hover" | "click" | "pop" | "tick" | "banner" | "go" | "check" | "hit" | "kill" | "toast" | "type" | "reload" | "stamp" | "deny"

local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.new(0, 0, 0)
local V2 = Vector2.new
local H = Color3.fromHex

-- ── helpers ──────────────────────────────────────────────────────────────────
local function mk(className: string, props: { [string]: any }?, parent: Instance?): any
	local inst: any = Instance.new(className)
	if className == "Frame" or className == "TextLabel" or className == "ImageLabel" or className == "TextButton" then
		inst.BorderSizePixel = 0
	end
	if props then
		for k, v in props do
			inst[k] = v
		end
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local function lighten(c: Color3, a: number): Color3
	return c:Lerp(WHITE, a)
end
local function darken(c: Color3, a: number): Color3
	return c:Lerp(BLACK, a)
end
local function corner(parent, r)
	return mk("UICorner", { CornerRadius = typeof(r) == "UDim" and r or UDim.new(0, r or 0) }, parent)
end
local function stroke(parent, color, thickness, transparency, border)
	return mk("UIStroke", {
		Color = color,
		Thickness = thickness,
		Transparency = transparency or 0,
		LineJoinMode = Enum.LineJoinMode.Round,
		ApplyStrokeMode = border and Enum.ApplyStrokeMode.Border or Enum.ApplyStrokeMode.Contextual,
	}, parent)
end
local function vgrad(parent, top, bottom)
	return mk("UIGradient", { Color = ColorSequence.new(top, bottom), Rotation = 90 }, parent)
end
local function tw(obj, goal, t, style, dir, delay)
	local tween = TweenService:Create(
		obj,
		TweenInfo.new(t or 0.2, style or Enum.EasingStyle.Quint, dir or Enum.EasingDirection.Out, 0, false, delay or 0),
		goal
	)
	tween:Play()
	return tween
end
local function commas(n: number): string
	local s = tostring(math.floor(math.abs(n) + 0.5))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if out:sub(1, 1) == "," then
		out = out:sub(2)
	end
	return (n < 0 and "-" or "") .. out
end
local function fmtNum(v, format)
	if type(format) == "function" then
		return format(v)
	elseif type(format) == "string" then
		return string.format(format, v)
	end
	return commas(v)
end
local function clockText(s: number, tenths: boolean?): string
	s = math.max(0, s)
	if tenths and s < 10 then
		return string.format("%.1f", s)
	end
	local m = math.floor(s / 60)
	return string.format("%d:%02d", m, math.floor(s - m * 60))
end
local function sfx(name, comp)
	local cb = UIKit.onSound
	if cb then
		task.spawn(cb, name, comp)
	end
end
local function resolveImage(img): string
	if img == nil or img == "" then
		return ""
	elseif type(img) == "number" then
		return "rbxassetid://" .. img
	elseif type(img) == "string" and (string.find(img, "://", 1, true) or string.find(img, "^%d+$")) then
		return string.find(img, "^%d+$") and ("rbxassetid://" .. img) or img
	elseif type(img) == "string" then
		return Assets.image(img, "")
	end
	return ""
end
local function rarityColor(t, rarity)
	if typeof(rarity) == "Color3" then
		return rarity
	end
	return t.rarity[rarity or "common"] or t.rarity.common
end

-- ── springs: one Heartbeat drives every live UI spring ───────────────────────
local driven = {}
RunService.Heartbeat:Connect(function(dt)
	dt = math.min(dt, 1 / 20)
	for h in driven do
		local s = h.s
		local p = s:Step(dt)
		if not pcall(h.apply, p) then
			driven[h] = nil
			continue
		end
		if math.abs(s.Target - p) < 1e-3 and math.abs(s.Velocity) < 1e-3 then
			s:Snap(s.Target)
			h.apply(s.Target)
			driven[h] = nil
		end
	end
end)

local function springValue(initial: number, speed: number, damping: number, apply: (number) -> ()): any
	local h: any = { s = Spring.new(initial, speed, damping), apply = apply }
	function h.to(_, v)
		h.s.Target = v
		driven[h] = true
	end
	function h.snap(_, v)
		h.s:Snap(v)
		h.apply(v)
		driven[h] = nil
	end
	function h.kick(_, v)
		h.s:Impulse(v)
		driven[h] = true
	end
	function h.stop()
		driven[h] = nil
	end
	apply(initial)
	return h
end

-- ── fades without CanvasGroups (they clip shadows): scale every descendant's transparency ──
local bases = setmetatable({}, { __mode = "k" })
local function record(inst, force)
	local b = bases[inst]
	if b and not force then
		return b
	end
	if inst:IsA("GuiObject") then
		b = { bg = inst.BackgroundTransparency }
		if inst:IsA("TextLabel") or inst:IsA("TextButton") or inst:IsA("TextBox") then
			b.tx = inst.TextTransparency
		end
		if inst:IsA("ImageLabel") or inst:IsA("ImageButton") then
			b.im = inst.ImageTransparency
		end
	elseif inst:IsA("UIStroke") then
		b = { st = inst.Transparency }
	else
		return nil
	end
	bases[inst] = b
	return b
end
local function applyAlpha(root, a, rerecord)
	local function one(inst)
		if inst:GetAttribute("NoFade") then
			return
		end
		local b = record(inst, rerecord)
		if not b then
			return
		end
		if b.bg then
			inst.BackgroundTransparency = 1 - (1 - b.bg) * a
		end
		if b.tx then
			inst.TextTransparency = 1 - (1 - b.tx) * a
		end
		if b.im then
			inst.ImageTransparency = 1 - (1 - b.im) * a
		end
		if b.st then
			inst.Transparency = 1 - (1 - b.st) * a
		end
	end
	one(root)
	for _, d in root:GetDescendants() do
		one(d)
	end
end
local function noFade(inst)
	inst:SetAttribute("NoFade", true)
	for _, d in inst:GetDescendants() do
		d:SetAttribute("NoFade", true)
	end
	return inst
end

-- ── themes ───────────────────────────────────────────────────────────────────
local function fam(enum)
	return Font.fromEnum(enum).Family
end
local function F(enum, weight, italic)
	return Font.new(fam(enum), weight, italic and Enum.FontStyle.Italic or Enum.FontStyle.Normal)
end

local RARITY = {
	common = H("#b8c2cc"),
	uncommon = H("#5bd67a"),
	rare = H("#4fa8ff"),
	epic = H("#b46cff"),
	legendary = H("#ffb02e"),
	mythic = H("#ff4f8b"),
}

-- Shape language: skew = slant as a fraction of height (0 = upright), radius px, stroke = ink outline px,
-- rim = inner light edge px, shadow = hard drop-shadow px, gloss = top highlight 0..1, tilt = header rotation deg.
local PRESETS = {
	arcade = {
		skew = 0.24, radius = 0, stroke = 3, rim = 2, rimT = 0.1, shadow = 5, shadowT = 0.2, softShadow = false,
		gloss = 0.12, panelT = 0, caps = true, tilt = -4, textStroke = 3, textShadow = 5, corners = "none",
		spring = { speed = 26, damping = 0.5 }, punch = 0.28,
		font = {
			display = F(Enum.Font.GothamBlack, Enum.FontWeight.Heavy, true),
			heading = F(Enum.Font.GothamBlack, Enum.FontWeight.Bold, true),
			body = F(Enum.Font.GothamBlack, Enum.FontWeight.Bold, false),
			numeric = F(Enum.Font.GothamBlack, Enum.FontWeight.Heavy, true),
		},
		c = {
			ink = H("#061020"), panelTop = H("#11284a"), panelBottom = H("#081426"), raisedTop = H("#24508f"),
			raisedBottom = H("#12305c"), rim = H("#f2fbff"), text = H("#f2fbff"), textDim = H("#7fa4c8"),
			dispTop = H("#ffffff"), dispBottom = H("#c9f0ff"), textShadow = H("#ffd23c"), accent = H("#3cff9e"),
			accent2 = H("#2ae8c4"), good = H("#3cff9e"), warn = H("#ffd23c"), bad = H("#ff3d5a"), gold = H("#ffd86b"),
			track = H("#050d1a"), backdrop = H("#040a14"),
		},
	},
	cozy = {
		skew = 0, radius = 18, stroke = 3, rim = 0, rimT = 0, shadow = 6, shadowT = 0.72, softShadow = true,
		gloss = 0.35, panelT = 0, caps = false, tilt = 0, textStroke = 3, textShadow = 3, corners = "none",
		spring = { speed = 20, damping = 0.62 }, punch = 0.18,
		font = {
			display = F(Enum.Font.FredokaOne, Enum.FontWeight.Regular),
			heading = F(Enum.Font.FredokaOne, Enum.FontWeight.Regular),
			body = F(Enum.Font.Nunito, Enum.FontWeight.ExtraBold),
			numeric = F(Enum.Font.FredokaOne, Enum.FontWeight.Regular),
		},
		c = {
			ink = H("#5a3826"), panelTop = H("#fff6e6"), panelBottom = H("#f4dcb8"), raisedTop = H("#ffffff"),
			raisedBottom = H("#fbe8cc"), rim = H("#ffffff"), text = H("#5a3826"), textDim = H("#a07f63"),
			dispTop = H("#ffffff"), dispBottom = H("#ffe7c2"), textShadow = H("#5a3826"), accent = H("#ff8a5b"),
			accent2 = H("#6cc4a1"), good = H("#6cc16a"), warn = H("#f6b73c"), bad = H("#e5604d"), gold = H("#f6c453"),
			track = H("#e3c79f"), backdrop = H("#3b2418"),
		},
	},
	tactical = {
		skew = 0, radius = 2, stroke = 1, rim = 0, rimT = 0, shadow = 0, shadowT = 1, softShadow = false,
		gloss = 0, panelT = 0.3, caps = true, tilt = 0, textStroke = 0, textShadow = 2, corners = "brackets",
		spring = { speed = 34, damping = 0.9 }, punch = 0.08, outlineT = 0.65,
		font = {
			display = F(Enum.Font.TitilliumWeb, Enum.FontWeight.Bold),
			heading = F(Enum.Font.TitilliumWeb, Enum.FontWeight.SemiBold),
			body = F(Enum.Font.RobotoCondensed, Enum.FontWeight.Medium),
			numeric = F(Enum.Font.RobotoMono, Enum.FontWeight.Bold),
		},
		c = {
			ink = H("#c9d4dc"), panelTop = H("#18212b"), panelBottom = H("#0a0f14"), raisedTop = H("#2a3846"),
			raisedBottom = H("#18222c"), rim = H("#ffffff"), text = H("#e8eef2"), textDim = H("#8797a3"),
			dispTop = H("#ffffff"), dispBottom = H("#d7e2ea"), textShadow = H("#000000"), accent = H("#e8b33a"),
			accent2 = H("#5ad1ff"), good = H("#7be07b"), warn = H("#ffb02e"), bad = H("#ff4b3e"), gold = H("#e8b33a"),
			track = H("#05080b"), backdrop = H("#000000"), shade = H("#000000"), onAccent = H("#0a0f14"),
		},
	},
	fantasy = {
		skew = 0, radius = 6, stroke = 3, rim = 2, rimT = 0.15, shadow = 5, shadowT = 0.35, softShadow = false,
		gloss = 0.1, panelT = 0, caps = true, tilt = 0, textStroke = 2, textShadow = 3, corners = "gems",
		spring = { speed = 22, damping = 0.68 }, punch = 0.2,
		font = {
			display = F(Enum.Font.Merriweather, Enum.FontWeight.Heavy),
			heading = F(Enum.Font.Merriweather, Enum.FontWeight.Bold),
			body = F(Enum.Font.SourceSans, Enum.FontWeight.SemiBold),
			numeric = F(Enum.Font.Merriweather, Enum.FontWeight.Bold),
		},
		c = {
			ink = H("#140b06"), panelTop = H("#3d2b4d"), panelBottom = H("#1b1226"), raisedTop = H("#5a4170"),
			raisedBottom = H("#2c1f3c"), rim = H("#d6a94a"), text = H("#f4e9d0"), textDim = H("#b4a284"),
			dispTop = H("#fff4c9"), dispBottom = H("#e3a93c"), textShadow = H("#140b06"), accent = H("#e9b949"),
			accent2 = H("#8fd3ff"), good = H("#7fd66b"), warn = H("#f0a33c"), bad = H("#d9483b"), gold = H("#ffd773"),
			track = H("#0f0915"), backdrop = H("#0c0712"),
		},
	},
	toon = {
		skew = 0, radius = 22, stroke = 4, rim = 0, rimT = 0, shadow = 6, shadowT = 0, softShadow = false,
		gloss = 0.4, panelT = 0, caps = true, tilt = -3, textStroke = 4, textShadow = 5, corners = "none",
		spring = { speed = 19, damping = 0.4 }, punch = 0.34,
		font = {
			display = F(Enum.Font.LuckiestGuy, Enum.FontWeight.Regular),
			heading = F(Enum.Font.FredokaOne, Enum.FontWeight.Regular),
			body = F(Enum.Font.FredokaOne, Enum.FontWeight.Regular),
			numeric = F(Enum.Font.LuckiestGuy, Enum.FontWeight.Regular),
		},
		c = {
			ink = H("#1b1030"), panelTop = H("#5aa0ff"), panelBottom = H("#2c5ed8"), raisedTop = H("#ffe066"),
			raisedBottom = H("#ffb420"), rim = H("#ffffff"), text = H("#ffffff"), textDim = H("#d4e3ff"),
			dispTop = H("#ffffff"), dispBottom = H("#fff1a6"), textShadow = H("#1b1030"), accent = H("#ffcf3a"),
			accent2 = H("#ff5fa2"), good = H("#4be07a"), warn = H("#ff9f1c"), bad = H("#ff4b5c"), gold = H("#ffd93a"),
			track = H("#1b1030"), backdrop = H("#150c28"),
		},
	},
}
UIKit.presets = PRESETS

local function merge(dst, src)
	for k, v in src do
		if type(v) == "table" and type(dst[k]) == "table" then
			merge(dst[k], v)
		else
			dst[k] = v
		end
	end
	return dst
end
local function copy(t)
	local out = {}
	for k, v in t do
		out[k] = type(v) == "table" and copy(v) or v
	end
	return out
end

-- theme(name, overrides?): a preset layered over the game's Tokens. overrides.tokens = "accents" (default: Tokens'
-- primary/secondary/success/warning/danger drive accents), "all" (also panels, text, fonts) or "none".
function UIKit.theme(name, overrides)
	local preset = PRESETS[name or "arcade"] or PRESETS.arcade
	local t = copy(preset)
	t.name = PRESETS[name] and name or "arcade"
	t.rarity = copy(RARITY)
	t.font = preset.font -- Font values are immutable; share them
	overrides = overrides or {}
	local mode = overrides.tokens or "accents"
	local tc = Tokens and Tokens.color
	if tc and mode ~= "none" then
		t.c.accent = tc.primary or t.c.accent
		t.c.accent2 = tc.secondary or t.c.accent2
		t.c.good = tc.success or t.c.good
		t.c.warn = tc.warning or t.c.warn
		t.c.bad = tc.danger or t.c.bad
		if mode == "all" then
			t.c.panelTop, t.c.panelBottom = tc.surface_raised or t.c.panelTop, tc.surface or t.c.panelBottom
			t.c.text, t.c.textDim = tc.text or t.c.text, tc.text_muted or t.c.textDim
			if Tokens.font then
				t.font = { display = Tokens.font.display, heading = Tokens.font.heading, body = Tokens.font.body, numeric = Tokens.font.numeric }
			end
		end
	end
	local fontOverride = overrides.font
	local o = table.clone(overrides)
	o.font, o.tokens = nil, nil
	merge(t, o)
	if fontOverride then
		t.font = table.clone(t.font)
		for k, v in fontOverride do
			t.font[k] = v
		end
	end
	UIKit.current = t
	return t
end
UIKit.current = nil
UIKit.theme("arcade")

-- ── layer, layout helpers ────────────────────────────────────────────────────
local layers = {}
function UIKit.layer(name, displayOrder)
	name = name or "UIKit"
	local g = layers[name]
	if not g or not g.Parent then -- cached: Screen.gui connects a resize handler on every call
		g = Screen.gui(name, displayOrder or 20)
		layers[name] = g
	end
	return g
end
-- Canvas px to keep clear of the Roblox top bar (the kit's ScreenGuis ignore the inset).
function UIKit.safeTop()
	return Screen.topInset() / Screen.scale() + 12
end
function UIKit.compact()
	return Screen.isCompact()
end

local function caps(t, role, s)
	if t.caps and (role == "display" or role == "heading") then
		return string.upper(s)
	end
	return s
end

-- Text with the theme's chunky treatment: font role, ink outline, offset shadow, optional vertical gradient.
local function text(parent, t, o)
	local role = o.role or "body"
	local holder = mk("Frame", {
		Name = o.name or "Text",
		BackgroundTransparency = 1,
		Size = o.size or UDim2.fromScale(1, 1),
		Position = o.position or UDim2.new(),
		AnchorPoint = o.anchor or Vector2.zero,
		Rotation = o.rotation or 0,
	}, parent)
	local loud = role == "display" or role == "numeric" or role == "heading"
	local strokePx = o.stroke or (loud and t.textStroke or 0)
	local shadowPx = o.shadow or (loud and t.textShadow or (t.textShadow > 0 and 2 or 0))
	local base = {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		FontFace = o.font or t.font[role],
		TextSize = o.textSize or 24,
		Text = caps(t, role, o.text or ""),
		TextXAlignment = o.x or Enum.TextXAlignment.Center,
		TextYAlignment = o.y or Enum.TextYAlignment.Center,
		TextWrapped = o.wrap or false,
		TextTruncate = o.truncate and Enum.TextTruncate.AtEnd or Enum.TextTruncate.None,
	}
	local L = { holder = holder, role = role }
	if shadowPx > 0 then
		local sh = mk("TextLabel", base, holder)
		sh.Name = "Shadow"
		sh.Position = UDim2.fromOffset(o.shadowX or (role == "display" and math.floor(shadowPx * 0.6) or 0), shadowPx)
		sh.TextColor3 = o.shadowColor or (role == "display" and t.c.textShadow or t.c.shade or t.c.ink)
		sh.TextTransparency = (t.name == "tactical" or not loud) and 0.45 or 0
		if strokePx > 0 then
			stroke(sh, t.c.ink, strokePx)
		end
		L.shadow = sh
	end
	local lab = mk("TextLabel", base, holder)
	lab.Name = "Label"
	lab.TextColor3 = o.gradient and WHITE or (o.color or t.c.text)
	if strokePx > 0 then
		L.stroke = stroke(lab, o.strokeColor or t.c.ink, strokePx)
	end
	if o.gradient then
		L.grad = mk("UIGradient", { Color = o.gradient, Rotation = 90 }, lab)
	end
	L.label = lab
	function L.set(_, s)
		s = caps(t, role, tostring(s))
		lab.Text = s
		if L.shadow then
			L.shadow.Text = s
		end
	end
	function L.color(_, c)
		if L.grad then
			L.grad.Color = ColorSequence.new(lighten(c, 0.55), c)
		else
			lab.TextColor3 = c
		end
	end
	return L
end

local function measure(s: string, font: Font, size: number, cb: (number) -> ())
	cb(#s * size * 0.62)
	task.spawn(function()
		local ok, v = pcall(function()
			local p = Instance.new("GetTextBoundsParams")
			p.Text = s
			p.Font = font
			p.Size = size
			p.Width = 4000
			return TextService:GetTextBoundsAsync(p)
		end)
		if ok and v then
			cb(v.X)
		end
	end)
end

-- ── plates: the kit's panel (slanted strip stack or rounded frame) ──────────
local function shade(top, bottom, y, gloss)
	local c = top:Lerp(bottom, y)
	if gloss > 0 and y < 0.5 then
		c = c:Lerp(WHITE, gloss * (1 - y * 2) ^ 2)
	end
	return c
end

local function stack(parent, x, y, dw, dh, h, skewPx, top, bottom, gloss, transparency, grad)
	local box = mk("Frame", {
		Name = "Stack",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(x, y),
		Size = UDim2.new(1, dw, 1, dh),
	}, parent)
	local n = math.clamp(math.floor(h / 3), 6, 32)
	local strips = table.create(n)
	for i = 1, n do
		local yc = (i - 0.5) / n
		local s = mk("Frame", {
			BackgroundColor3 = shade(top, bottom, yc, gloss),
			BackgroundTransparency = transparency,
			Position = UDim2.new(0, skewPx * (1 - yc), (i - 1) / n, 0),
			Size = UDim2.new(1, -skewPx, 1 / n, transparency > 0 and 0 or 1),
		}, box)
		if grad then
			mk("UIGradient", { Color = grad }, s)
		end
		strips[i] = s
	end
	return box, strips
end

-- plate(parent, t, {size = Vector2, position, anchor, top, bottom | fill, grad = ColorSequence, outline, stroke,
--   skew, radius, shadow, rim, gloss, transparency, deco, image}) -> P {root, setColor(top, bottom), skewPx, k}
local function plate(parent, t, o)
	local w, h = o.size.X, o.size.Y
	local k = o.skew or t.skew
	local strokePx = o.stroke or t.stroke
	local fill = o.fill
	local top = o.top or (fill and lighten(fill, 0.12)) or t.c.panelTop
	local bottom = o.bottom or (fill and darken(fill, 0.22)) or t.c.panelBottom
	local gloss = o.gloss or t.gloss
	local alpha = o.transparency or t.panelT
	local shadowPx = o.shadow or t.shadow
	local rimPx = o.rim or t.rim
	local outline = o.outline or t.c.ink
	local outlineT = o.outlineT or t.outlineT or 0
	local root = mk("Frame", {
		Name = o.name or "Plate",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(w, h),
		Position = o.position or UDim2.new(),
		AnchorPoint = o.anchor or Vector2.zero,
	}, parent)
	local P: any = { root = root, k = k, skewPx = k * h, h = h }
	if k > 0 then
		local s = strokePx
		local rs = rimPx
		if shadowPx > 0 then
			stack(root, -s - k * s, -s + shadowPx, 2 * s + 2 * k * s, 2 * s, h + 2 * s, k * (h + 2 * s), outline, outline, 0, t.shadowT, nil)
		end
		if s > 0 then
			stack(root, -s - k * s, -s, 2 * s + 2 * k * s, 2 * s, h + 2 * s, k * (h + 2 * s), outline, outline, 0, outlineT, nil)
		end
		if rs > 0 and alpha < 0.5 then
			stack(root, 0, 0, 0, 0, h, k * h, t.c.rim, t.c.rim, 0, t.rimT, nil)
		end
		local inset = rs > 0 and alpha < 0.5 and rs or 0
		local _, strips = stack(root, inset + k * inset, inset, -2 * inset - 2 * k * inset, -2 * inset, h - 2 * inset,
			k * (h - 2 * inset), top, bottom, gloss, alpha, o.grad)
		P.strips = strips
		function P.setColor(_, a, b)
			b = b or darken(a, 0.22)
			local n = #strips
			for i, st in strips do
				st.BackgroundColor3 = shade(a, b, (i - 0.5) / n, gloss)
			end
		end
	else
		local r = o.radius or t.radius
		if shadowPx > 0 then
			if t.softShadow then
				for i, tr in { 0.82, 0.9, 0.95 } do
					local g = (i - 1) * 4
					local sh = mk("Frame", {
						Name = "Shadow",
						BackgroundColor3 = outline,
						BackgroundTransparency = tr,
						Position = UDim2.fromOffset(-g, shadowPx - g + 2),
						Size = UDim2.new(1, 2 * g, 1, 2 * g),
					}, root)
					corner(sh, r + g)
				end
			else
				local sh = mk("Frame", {
					Name = "Shadow",
					BackgroundColor3 = outline,
					BackgroundTransparency = t.shadowT,
					Position = UDim2.fromOffset(-strokePx, shadowPx - strokePx),
					Size = UDim2.new(1, 2 * strokePx, 1, 2 * strokePx),
				}, root)
				corner(sh, r + strokePx)
			end
		end
		local body = mk("Frame", {
			Name = "Fill",
			BackgroundColor3 = WHITE,
			BackgroundTransparency = alpha,
			Size = UDim2.fromScale(1, 1),
		}, root)
		corner(body, r)
		local g = mk("UIGradient", { Color = o.grad or ColorSequence.new(top, bottom), Rotation = o.grad and 0 or 90 }, body)
		if strokePx > 0 then
			stroke(body, outline, strokePx, outlineT, true)
		end
		if o.grad then -- vertical shade over a horizontal colour gradient
			local sh = mk("Frame", { Name = "Shade", BackgroundColor3 = BLACK, Size = UDim2.fromScale(1, 1) }, body)
			corner(sh, r)
			mk("UIGradient", { Rotation = 90, Transparency = NumberSequence.new(1, 0.7) }, sh)
		end
		if gloss > 0 then
			local gl = mk("Frame", {
				Name = "Gloss",
				BackgroundColor3 = WHITE,
				Position = UDim2.fromOffset(3, 3),
				Size = UDim2.new(1, -6, 0.48, -3),
			}, body)
			corner(gl, math.max(0, r - 3))
			mk("UIGradient", { Rotation = 90, Transparency = NumberSequence.new(1 - gloss * 0.9, 1) }, gl)
		end
		if rimPx > 0 then
			local rim = mk("Frame", {
				Name = "Rim",
				BackgroundTransparency = 1,
				Position = UDim2.fromOffset(rimPx + 1, rimPx + 1),
				Size = UDim2.new(1, -2 * rimPx - 2, 1, -2 * rimPx - 2),
			}, body)
			corner(rim, math.max(0, r - rimPx))
			stroke(rim, t.c.rim, rimPx, t.rimT, true)
		end
		P.body = body
		function P.setColor(_, a, b)
			if o.grad then
				return
			end
			g.Color = ColorSequence.new(a, b or darken(a, 0.22))
		end
	end
	if o.image and resolveImage(o.image) ~= "" then
		local img = mk("ImageLabel", {
			Name = "Art",
			BackgroundTransparency = 1,
			Image = resolveImage(o.image),
			Size = UDim2.fromScale(1, 1),
			ScaleType = Enum.ScaleType.Stretch,
		}, root)
		local slice = type(o.image) == "string" and Assets.slice(o.image)
		if slice then
			img.ScaleType = Enum.ScaleType.Slice
			img.SliceCenter = slice
		end
	end
	if o.deco and t.corners ~= "none" then
		local acc = t.corners == "gems" and t.c.rim or t.c.accent
		for _, cxy in { { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } } do
			local cx, cy = cxy[1], cxy[2]
			if t.corners == "brackets" then
				local L = 16
				mk("Frame", {
					BackgroundColor3 = acc,
					AnchorPoint = V2(cx, cy),
					Position = UDim2.new(cx, cx == 0 and -4 or 4, cy, cy == 0 and -4 or 4),
					Size = UDim2.fromOffset(L, 2),
				}, root)
				mk("Frame", {
					BackgroundColor3 = acc,
					AnchorPoint = V2(cx, cy),
					Position = UDim2.new(cx, cx == 0 and -4 or 4, cy, cy == 0 and -4 or 4),
					Size = UDim2.fromOffset(2, L),
				}, root)
			else
				local gem = mk("Frame", {
					BackgroundColor3 = acc,
					AnchorPoint = V2(0.5, 0.5),
					Position = UDim2.fromScale(cx, cy),
					Size = UDim2.fromOffset(14, 14),
					Rotation = 45,
				}, root)
				stroke(gem, t.c.ink, 2, 0, true)
				vgrad(gem, WHITE, darken(WHITE, 0.35))
			end
		end
	end
	return P
end

-- A disc (or tactical square) icon: gradient, outline, gloss, then the image or a glyph.
local function iconDisc(parent, t, o)
	local size = o.size or 64
	local color = o.color or t.c.accent
	local root = mk("Frame", {
		Name = "Icon",
		BackgroundColor3 = WHITE,
		Size = UDim2.fromOffset(size, size),
		Position = o.position or UDim2.new(),
		AnchorPoint = o.anchor or Vector2.zero,
	}, parent)
	local r = t.name == "tactical" and UDim.new(0, 3) or UDim.new(1, 0)
	corner(root, r)
	vgrad(root, lighten(color, 0.3), darken(color, 0.25))
	if t.stroke > 0 then
		stroke(root, t.c.ink, math.max(2, t.stroke), t.outlineT or 0, true)
	end
	if t.gloss > 0 then
		local gl = mk("Frame", { BackgroundColor3 = WHITE, Position = UDim2.fromScale(0.15, 0.06), Size = UDim2.fromScale(0.7, 0.42) }, root)
		corner(gl, UDim.new(1, 0))
		mk("UIGradient", { Rotation = 90, Transparency = NumberSequence.new(0.55, 1) }, gl)
	end
	local img = resolveImage(o.image)
	local I = { root = root }
	if img ~= "" then
		I.image = mk("ImageLabel", {
			BackgroundTransparency = 1,
			Image = img,
			AnchorPoint = V2(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(o.fill or 0.82, o.fill or 0.82),
			ScaleType = Enum.ScaleType.Fit,
		}, root)
	else
		I.glyph = text(root, t, {
			role = "heading",
			text = o.glyph or "?",
			textSize = math.floor(size * 0.52),
			color = WHITE,
			stroke = math.max(2, t.textStroke - 1),
			shadow = 2,
		})
	end
	return I
end

-- ── components: shared base ──────────────────────────────────────────────────
local live = {}
local Base: any = {}
Base.__index = Base
local function class()
	local c: any = setmetatable({}, { __index = Base })
	c.__index = c
	return c
end

local function newBase(o, w, h, pos, anchor, kind)
	o = o or {}
	local t = o.theme or UIKit.current
	local root = mk("Frame", {
		Name = o.name or kind or "UIKit",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(w, h),
		Position = o.position or pos,
		AnchorPoint = o.anchor or anchor,
	}, o.parent or UIKit.layer())
	local body = mk("Frame", {
		Name = "Body",
		BackgroundTransparency = 1,
		AnchorPoint = V2(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
	}, root)
	local scale = mk("UIScale", {}, body)
	local self: any = { t = t, o = o, root = root, body = body, conns = {}, springs = {}, _alpha = 1, _shown = true, _ver = 0 }
	self.scale = scale
	self._pop = springValue(1, t.spring.speed, t.spring.damping, function(v)
		scale.Scale = v
	end)
	self._slide = springValue(0, t.spring.speed * 0.8, 1, function(v)
		body.Position = UDim2.new(0.5, 0, 0.5, v)
	end)
	self.springs = { self._pop, self._slide }
	live[self] = true
	return self
end

function Base:spring(initial, speed, damping, apply)
	local s = springValue(initial, speed or self.t.spring.speed, damping or self.t.spring.damping, apply)
	table.insert(self.springs, s)
	return s
end
function Base:on(signal, fn)
	local c = signal:Connect(fn)
	table.insert(self.conns, c)
	return c
end
function Base:later(seconds, fn)
	local ver = self._ver
	task.delay(seconds, function()
		if not self._dead and self._ver == ver then
			fn()
		end
	end)
end
function Base:_fade(target, dur, done)
	if self._fadeConn then
		self._fadeConn:Disconnect()
		self._fadeConn = nil
	end
	if target < self._alpha and self._alpha >= 0.999 then
		applyAlpha(self.root, 1, true)
	end
	local from, start = self._alpha, os.clock()
	if dur <= 0 or self.noFade then
		self._alpha = target
		if not self.noFade then
			applyAlpha(self.root, target)
		end
		if done then
			done()
		end
		return
	end
	self._fadeConn = RunService.Heartbeat:Connect(function()
		local a = math.clamp((os.clock() - start) / dur, 0, 1)
		self._alpha = from + (target - from) * a
		applyAlpha(self.root, self._alpha)
		if a >= 1 then
			self._fadeConn:Disconnect()
			self._fadeConn = nil
			if done then
				done()
			end
		end
	end)
end
function Base:show(instant)
	if self._dead then
		return self
	end
	self._shown = true
	self._hideTok = (self._hideTok or 0) + 1
	self.root.Visible = true
	if instant then
		self._pop:snap(1)
		self._slide:snap(0)
		self:_fade(1, 0)
		return self
	end
	if self._alpha < 0.05 then
		self._pop:snap(self.popFrom or 0.72)
		self._slide:snap(self.slideFrom or 26)
	end
	self._pop:to(1)
	self._slide:to(0)
	self:_fade(1, 0.18)
	if self.onShow then
		self:onShow()
	end
	return self
end
function Base:hide(instant)
	if self._dead then
		return self
	end
	self._shown = false
	self._hideTok = (self._hideTok or 0) + 1
	local tok = self._hideTok
	if instant then
		self:_fade(0, 0)
		self.root.Visible = false
		return self
	end
	self._pop:to(0.88)
	self._slide:to(14)
	self:_fade(0, 0.16, function()
		if self._hideTok == tok and not self._dead then
			self.root.Visible = false
		end
	end)
	return self
end
function Base:punch(amount)
	self._pop.s.Position = 1 + (amount or self.t.punch)
	self._pop:to(1)
	return self
end
function Base:setPosition(p)
	self.root.Position = p
	return self
end
function Base:Destroy()
	if self._dead then
		return
	end
	self._dead = true
	self._ver += 1
	for _, c in self.conns do
		c:Disconnect()
	end
	for _, s in self.springs do
		s:stop()
	end
	if self._fadeConn then
		self._fadeConn:Disconnect()
	end
	if self.onDestroy then
		self:onDestroy()
	end
	live[self] = nil
	self.root:Destroy()
end
Base.destroy = Base.Destroy
function Base:_enter()
	if self.o.hidden then
		self:hide(true)
	else
		self._alpha = 0
		if not self.noFade then
			applyAlpha(self.root, 0)
		end
		self:show()
	end
	return self
end

-- Destroys every live component (use when switching screens or themes).
function UIKit.clear()
	for c in live do
		c:Destroy()
	end
end

-- ── button: lip button with hover lift and press squish ─────────────────────
local Button = class()
function UIKit.button(o)
	o = o or {}
	local t = o.theme or UIKit.current
	local w, h = (o.size and o.size.X) or 260, (o.size and o.size.Y) or 72
	local lip = math.max(4, math.floor(h * 0.1))
	local self = setmetatable(newBase(o, w, h + lip, UDim2.fromScale(0.5, 0.8), V2(0.5, 0.5), "Button"), Button)
	self.noFade = o.parent ~= nil and o.nested ~= false
	self.lip = lip
	self.enabled = o.enabled ~= false
	local function kindColor(kind)
		local c = t.c
		return ({ primary = c.accent, secondary = c.accent2, good = c.good, danger = c.bad, warn = c.warn, neutral = c.raisedTop })[kind or "primary"]
			or (typeof(kind) == "Color3" and kind)
			or c.accent
	end
	self.kindColor = kindColor
	self.color = o.color or kindColor(o.kind)
	local base = plate(self.body, t, {
		size = V2(w, h),
		position = UDim2.fromOffset(0, lip),
		fill = darken(self.color, 0.45),
		gloss = 0,
		shadow = t.shadow > 0 and t.shadow or 0,
		rim = 0,
	})
	self.base = base
	local faceHolder = mk("Frame", { Name = "Face", BackgroundTransparency = 1, Size = UDim2.fromOffset(w, h) }, self.body)
	self.faceHolder = faceHolder
	self.face = plate(faceHolder, t, { size = V2(w, h), fill = self.color, shadow = 0 })
	local tx = 0
	if o.icon or o.glyph then
		local s = math.floor(h * 0.62)
		iconDisc(faceHolder, t, {
			size = s,
			image = o.icon,
			glyph = o.glyph,
			color = lighten(self.color, 0.2),
			position = UDim2.new(0, 14 + base.skewPx * 0.5, 0.5, 0),
			anchor = V2(0, 0.5),
		})
		tx = s + 10
	end
	self.label = text(faceHolder, t, {
		role = "heading",
		text = o.text or "BUTTON",
		textSize = o.textSize or math.floor(h * 0.42),
		color = t.name == "cozy" and WHITE or t.c.text,
		position = UDim2.fromOffset(tx, 0),
		size = UDim2.new(1, -tx, 1, 0),
	})
	local lift = self:spring(0, 32, 0.55, function(v)
		faceHolder.Position = UDim2.fromOffset(0, v)
	end)
	self.lift = lift
	local hit = mk("TextButton", {
		Name = "Hit",
		Text = "",
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Size = UDim2.new(1, 0, 1, 0),
		ZIndex = 5,
	}, self.body)
	self.hit = hit
	local hovering = false
	self:on(hit.MouseEnter, function()
		if not self.enabled then
			return
		end
		hovering = true
		lift:to(-3)
		self._pop:to(1.04)
		sfx("hover", self)
	end)
	self:on(hit.MouseLeave, function()
		hovering = false
		lift:to(0)
		self._pop:to(1)
	end)
	self:on(hit.MouseButton1Down, function()
		if not self.enabled then
			return
		end
		lift:to(lip - 1)
		self._pop:to(0.97)
	end)
	self:on(hit.MouseButton1Up, function()
		lift:to(hovering and -3 or 0)
		self._pop:to(hovering and 1.04 or 1)
	end)
	self:on(hit.Activated, function()
		if not self.enabled then
			sfx("deny", self)
			self:shake()
			return
		end
		lift.s.Position = lip
		lift:to(hovering and -3 or 0)
		sfx("click", self)
		if o.onClick then
			task.spawn(o.onClick, self)
		end
	end)
	if not self.enabled then
		self:set({ enabled = false })
	end
	return self:_enter()
end
function Button:shake()
	local s = self:spring(0, 40, 0.25, function(v)
		self.faceHolder.Position = UDim2.fromOffset(v, self.faceHolder.Position.Y.Offset)
	end)
	s:kick(260)
end
-- set({text, color, kind, enabled})
function Button:set(p)
	if type(p) == "string" then
		p = { text = p }
	end
	if p.text then
		self.label:set(p.text)
	end
	if p.enabled ~= nil then
		self.enabled = p.enabled
	end
	if p.color or p.kind then
		self.color = p.color or self.kindColor(p.kind)
	end
	local c = self.enabled and self.color or self.t.c.textDim:Lerp(self.t.c.panelBottom, 0.4)
	self.face:setColor(lighten(c, 0.12), darken(c, 0.22))
	self.base:setColor(darken(c, 0.45), darken(c, 0.55))
	return self
end

-- ── banner: big centre text with a slanted band, punch-in and a shine sweep ─
local Banner = class()
function UIKit.banner(textValue, o)
	o = o or {}
	local t = o.theme or UIKit.current
	local self = setmetatable(newBase(o, 1600, 360, UDim2.fromScale(0.5, 0.4), V2(0.5, 0.5), "Banner"), Banner)
	self.popFrom = 2.2
	self.slideFrom = 0
	local size = o.textSize or 150
	self.textSize = size
	local tilt = mk("Frame", { Name = "Tilt", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Rotation = o.tilt or t.tilt }, self.body)
	local bandH = math.floor(size * 1.05)
	self.color = o.color or t.c.accent
	local bandHolder = mk("Frame", {
		Name = "Band",
		BackgroundTransparency = 1,
		AnchorPoint = V2(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.45),
		Size = UDim2.fromOffset(600, bandH),
	}, tilt)
	self.bandHolder = bandHolder
	local band = plate(bandHolder, t, {
		size = V2(600, bandH),
		top = t.name == "arcade" and t.c.panelTop or lighten(self.color, 0.1),
		bottom = t.name == "arcade" and t.c.panelBottom or darken(self.color, 0.3),
		deco = true,
	})
	band.root.Size = UDim2.fromScale(1, 1)
	self.band = band
	local textColor = t.name == "arcade" and self.color or nil
	self.text = text(tilt, t, {
		role = "display",
		text = textValue or "",
		textSize = size,
		gradient = ColorSequence.new(textColor and lighten(textColor, 0.35) or t.c.dispTop, textColor or t.c.dispBottom),
		position = UDim2.fromScale(0.5, 0.45),
		anchor = V2(0.5, 0.5),
		size = UDim2.new(1, 0, 0, size + 20),
	})
	local shine = mk("TextLabel", {
		Name = "Shine",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		FontFace = t.font.display,
		TextSize = size,
		Text = self.text.label.Text,
		TextColor3 = WHITE,
	}, self.text.holder)
	self.shineGrad = mk("UIGradient", {
		Rotation = 25,
		Offset = V2(-1, 0),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.42, 1),
			NumberSequenceKeypoint.new(0.5, 0.05),
			NumberSequenceKeypoint.new(0.58, 1),
			NumberSequenceKeypoint.new(1, 1),
		}),
	}, shine)
	noFade(shine)
	self.shine = shine
	self.sub = text(tilt, t, {
		role = "heading",
		text = o.sub or "",
		textSize = math.floor(size * 0.28),
		position = UDim2.new(0.5, 0, 0.45, bandH * 0.5 + 34),
		anchor = V2(0.5, 0.5),
		size = UDim2.new(1, 0, 0, 50),
	})
	self:_layout(textValue or "")
	return self:_enter()
end
function Banner:_layout(s)
	local t = self.t
	measure(caps(t, "display", s), t.font.display, self.textSize, function(wpx)
		if self._dead then
			return
		end
		local target = UDim2.fromOffset(math.min(1500, wpx + 170 + self.band.skewPx), self.bandHolder.Size.Y.Offset)
		local changed = self._bandTarget and self._bandTarget ~= target
		self._bandTarget = target
		if changed and self._shown and self.bandHolder.Size.X.Offset > 0 then
			tw(self.bandHolder, { Size = target }, 0.2)
		end
	end)
end
function Banner:onShow()
	local target = self._bandTarget or UDim2.fromOffset(700, self.bandHolder.Size.Y.Offset)
	self.bandHolder.Size = UDim2.fromOffset(0, target.Y.Offset)
	task.defer(function()
		if self._dead then
			return
		end
		tw(self.bandHolder, { Size = self._bandTarget or target }, 0.32, Enum.EasingStyle.Back)
	end)
	self.shineGrad.Offset = V2(-1, 0)
	tw(self.shineGrad, { Offset = V2(1, 0) }, 0.55, Enum.EasingStyle.Quad, nil, 0.18)
	sfx("banner", self)
end
-- set(text, {sub, color})
function Banner:set(s, p)
	p = p or {}
	self.text:set(s)
	self.shine.Text = self.text.label.Text
	if p.sub then
		self.sub:set(p.sub)
	end
	if p.color then
		self.color = p.color
		self.text:color(p.color)
	end
	self:_layout(s)
	if self._shown then
		self._pop.s.Position = 1.6
		self._pop:to(1)
		self:onShow()
	end
	return self
end
-- flash(seconds, text?): show, hold, hide.
function Banner:flash(seconds, s, p)
	if s then
		self:set(s, p)
	end
	self:show()
	local tok = (self._flashTok or 0) + 1
	self._flashTok = tok
	self:later(seconds or 1.4, function()
		if self._flashTok == tok then
			self:hide()
		end
	end)
	return self
end

-- ── countdown: 3-2-1-GO with punch and pulse ring ───────────────────────────
local Countdown = class()
function UIKit.countdown(o)
	o = o or {}
	local t = o.theme or UIKit.current
	local self = setmetatable(newBase(o, 600, 400, UDim2.fromScale(0.5, 0.42), V2(0.5, 0.5), "Countdown"), Countdown)
	self.popFrom = 2
	self.slideFrom = 0
	local ring = mk("Frame", {
		Name = "Pulse",
		BackgroundTransparency = 1,
		AnchorPoint = V2(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(260, 260),
	}, self.body)
	corner(ring, UDim.new(1, 0))
	self.ringStroke = stroke(ring, t.c.accent, 10, 1, true)
	self.ringScale = mk("UIScale", {}, ring)
	noFade(ring)
	self.num = text(self.body, t, {
		role = "display",
		text = "",
		textSize = o.textSize or 240,
		gradient = ColorSequence.new(t.c.dispTop, t.c.dispBottom),
		rotation = t.tilt,
	})
	self.goText = o.go or "GO!"
	return self:_enter()
end
function Countdown:set(v)
	local t = self.t
	local isGo = type(v) ~= "number"
	local c = isGo and t.c.good or (v <= 1 and t.c.warn or v == 2 and t.c.warn or t.c.bad)
	self.num:set(isGo and v or tostring(v))
	self.num:color(c)
	if not self._shown then
		self:show()
	end
	self._pop.s.Position = isGo and 2.4 or 1.9
	self._pop:to(1)
	self.ringStroke.Color = c
	self.ringStroke.Transparency = 0
	self.ringScale.Scale = 0.5
	tw(self.ringScale, { Scale = isGo and 2.2 or 1.5 }, 0.6, Enum.EasingStyle.Quart)
	tw(self.ringStroke, { Transparency = 1 }, 0.6, Enum.EasingStyle.Quad)
	sfx(isGo and "go" or "tick", self)
	return self
end
-- start(from = 3, onDone?, step = 1): counts down, shows GO, then hides.
function Countdown:start(from, onDone, step)
	self._ver += 1
	from, step = from or 3, step or 1
	local ver = self._ver
	task.spawn(function()
		for i = from, 1, -1 do
			if self._dead or self._ver ~= ver then
				return
			end
			self:set(i)
			task.wait(step)
		end
		if self._dead or self._ver ~= ver then
			return
		end
		self:set(self.goText)
		if onDone then
			task.spawn(onDone)
		end
		task.wait(step * 0.8)
		if not self._dead and self._ver == ver then
			self:hide()
		end
	end)
	return self
end

-- ── counter: icon + number that rolls and pops ──────────────────────────────
local Counter = class()
function UIKit.counter(o)
	o = o or {}
	local t = o.theme or UIKit.current
	local w, h = o.width or 280, o.height or 64
	local self = setmetatable(newBase(o, w + 40, h + 30, UDim2.fromOffset(40, UIKit.safeTop() + 20), V2(0, 0), "Counter"), Counter)
	self.format = o.format
	self.value = o.value or 0
	self.color = o.color or t.c.gold
	plate(self.body, t, { size = V2(w, h), position = UDim2.fromOffset(40, 20) })
	local isz = math.floor(h * 1.3)
	self.icon = iconDisc(self.body, t, {
		size = isz,
		image = o.icon,
		glyph = o.glyph or (o.label and string.sub(o.label, 1, 1)) or "$",
		color = self.color,
		position = UDim2.fromOffset(isz * 0.5 + 6, 20 + h * 0.5),
		anchor = V2(0.5, 0.5),
	})
	self.iconRot = self:spring(0, 22, 0.3, function(v)
		self.icon.root.Rotation = v
	end)
	local tx = isz + 18
	if o.label then
		text(self.body, t, {
			role = "heading",
			text = o.label,
			textSize = 16,
			color = t.c.textDim,
			x = Enum.TextXAlignment.Left,
			position = UDim2.fromOffset(tx, 2),
			size = UDim2.fromOffset(w, 18),
			stroke = 0,
			shadow = 0,
		})
	end
	local numHolder = mk("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(tx, 20),
		Size = UDim2.fromOffset(w + 40 - tx - 16, h),
	}, self.body)
	self.numScale = mk("UIScale", {}, numHolder)
	self.numPop = self:spring(1, 30, 0.45, function(v)
		self.numScale.Scale = v
	end)
	self.num = text(numHolder, t, {
		role = "numeric",
		text = fmtNum(self.value, self.format),
		textSize = math.floor(h * 0.68),
		x = Enum.TextXAlignment.Left,
		color = t.c.text,
	})
	return self:_enter()
end
-- set(value, {silent}): rolls to value, pops, and floats the delta.
function Counter:set(v, p)
	p = p or {}
	local from = self.value
	self.value = v
	if self._roll then
		self._roll:Disconnect()
	end
	local start = os.clock()
	self._roll = self:on(RunService.Heartbeat, function()
		local a = math.clamp((os.clock() - start) / 0.5, 0, 1)
		local e = 1 - (1 - a) ^ 4
		self.num:set(fmtNum(math.floor(from + (v - from) * e + 0.5), self.format))
		if a >= 1 then
			self._roll:Disconnect()
		end
	end)
	if p.silent or v == from then
		return self
	end
	self.numPop.s.Position = 1 + self.t.punch
	self.numPop:to(1)
	self.iconRot:kick(v > from and -260 or 260)
	local d = v - from
	UIKit.popup((d > 0 and "+" or "") .. fmtNum(d, self.format), {
		at = self.root,
		offset = V2(self.root.Size.X.Offset * 0.55, 10),
		color = d > 0 and self.t.c.good or self.t.c.bad,
		theme = self.t,
		parent = self.root.Parent,
	})
	sfx("pop", self)
	return self
end

-- ── bar: health / stamina / progress with lag-trail chip ────────────────────
local Bar = class()
function UIKit.bar(o)
	o = o or {}
	local t = o.theme or UIKit.current
	local w, h = o.width or 440, o.height or 34
	local labelH = o.label and 26 or 0
	local self = setmetatable(newBase(o, w + 30, h + labelH + 16, UDim2.new(0, 40, 1, -60), V2(0, 1), "Bar"), Bar)
	self.max = o.max or 100
	self.value = o.value or self.max
	self.color = o.color or t.c.good
	self.format = o.format
	self.showText = o.showText ~= false
	if o.label then
		text(self.body, t, {
			role = "heading",
			text = o.label,
			textSize = 20,
			x = Enum.TextXAlignment.Left,
			position = UDim2.fromOffset(t.skew * h + 6, 0),
			size = UDim2.fromOffset(w, 22),
			stroke = math.min(2, t.textStroke),
			shadow = 2,
		})
	end
	local shake = mk("Frame", {
		Name = "Shake",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, labelH),
		Size = UDim2.fromOffset(w, h),
	}, self.body)
	self.shakeFrame = shake
	local bg = plate(shake, t, { size = V2(w, h), top = t.c.track, bottom = lighten(t.c.track, 0.08), gloss = 0, rim = 0 })
	local k = t.skew
	local p = math.max(3, math.floor(h * 0.12))
	local cx = p + k * p
	local innerH = h - 2 * p
	local innerW = w - 2 * p - 2 * k * p
	self.inner = { x = cx, y = p, w = innerW, h = innerH, skew = k * innerH }
	local function fillPlate(color)
		local pl = plate(bg.root, t, {
			size = V2(innerW, innerH),
			position = UDim2.fromOffset(cx, p),
			fill = color,
			stroke = 0,
			shadow = 0,
			rim = 0,
			radius = math.max(0, t.radius - p),
			transparency = 0,
		})
		return pl
	end
	self.trail = fillPlate(WHITE)
	self.fill = fillPlate(self.color)
	if o.segments and o.segments > 1 then
		for i = 1, o.segments - 1 do
			mk("Frame", {
				BackgroundColor3 = t.c.track,
				BackgroundTransparency = 0.2,
				AnchorPoint = V2(0.5, 0),
				Position = UDim2.fromOffset(cx + self.inner.skew * 0.5 + (innerW - self.inner.skew) * i / o.segments, p),
				Size = UDim2.fromOffset(3, innerH),
				Rotation = math.deg(math.atan(k)),
			}, bg.root)
		end
	end
	self.txt = text(bg.root, t, {
		role = "numeric",
		text = "",
		textSize = math.floor(h * 0.6),
		x = Enum.TextXAlignment.Right,
		position = UDim2.fromOffset(-14 - k * h * 0.5, 0),
		stroke = 2,
		shadow = 0,
	})
	self.txt.holder.Visible = self.showText
	local function width(frac)
		frac = math.clamp(frac, 0, 1)
		local s = self.inner.skew
		return s + frac * (self.inner.w - s)
	end
	self.fillS = self:spring(self.value / self.max, 26, 1, function(v)
		self.fill.root.Size = UDim2.fromOffset(width(v), innerH)
		self.fill.root.Visible = v > 0.002
	end)
	self.trailS = self:spring(self.value / self.max, 7, 1, function(v)
		self.trail.root.Size = UDim2.fromOffset(width(v), innerH)
		self.trail.root.Visible = v > 0.002
	end)
	self.shakeS = self:spring(0, 45, 0.3, function(v)
		shake.Position = UDim2.fromOffset(v, labelH)
	end)
	self:_text()
	self.low = o.lowAt or 0.25
	self:on(RunService.Heartbeat, function()
		local frac = self.value / self.max
		if frac <= self.low and frac > 0 and o.pulseLow ~= false then
			local a = 0.5 + 0.5 * math.sin(os.clock() * 10)
			self.fill:setColor(lighten(self.color:Lerp(self.t.c.bad, 0.6), 0.12 + a * 0.3))
			self._pulsing = true
		elseif self._pulsing then
			self._pulsing = false
			self.fill:setColor(lighten(self.color, 0.12), darken(self.color, 0.22))
		end
	end)
	return self:_enter()
end
function Bar:_text()
	if self.showText then
		local f = self.format
		self.txt:set(f == "percent" and string.format("%d%%", math.floor(self.value / self.max * 100 + 0.5))
			or (fmtNum(self.value, f ~= "percent" and f or nil) .. " / " .. fmtNum(self.max, f ~= "percent" and f or nil)))
	end
end
-- set(value, max?): fill springs; losses leave a white chip that drains, gains lead with a good-coloured chip.
function Bar:set(v, max)
	local t = self.t
	self.max = max or self.max
	local old = self.fillS.s.Target
	self.value = math.clamp(v, 0, self.max)
	local frac = self.value / self.max
	self:_text()
	if frac < old then
		self.trail:setColor(WHITE, lighten(t.c.bad, 0.5))
		self.trailS:snap(math.max(self.trailS.s.Position, old))
		self.fillS:to(frac)
		self:later(0.35, function()
			self.trailS:to(self.value / self.max)
		end)
		if old - frac > 0.08 then
			self.shakeS:kick((math.random() < 0.5 and -1 or 1) * 220)
		end
	elseif frac > old then
		self.trail:setColor(lighten(t.c.good, 0.35), t.c.good)
		self.trailS:snap(frac)
		self.fillS.s.Speed = 8
		self.fillS:to(frac)
		self:later(0.6, function()
			self.fillS.s.Speed = 26
		end)
	end
	return self
end
function Bar:setColor(c)
	self.color = c
	self.fill:setColor(lighten(c, 0.12), darken(c, 0.22))
	return self
end

-- ── ring: radial progress (two clipped half-discs with hard-step gradients) ─
local Ring = class()
local HALF = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0),
	NumberSequenceKeypoint.new(0.5, 0),
	NumberSequenceKeypoint.new(0.501, 1),
	NumberSequenceKeypoint.new(1, 1),
})
function UIKit.ring(o)
	o = o or {}
	local t = o.theme or UIKit.current
	local S = o.size or 128
	local th = o.thickness or math.floor(S * 0.13)
	local self = setmetatable(newBase(o, S, S, UDim2.fromScale(0.5, 0.5), V2(0.5, 0.5), "Ring"), Ring)
	self.color = o.color or t.c.accent
	self.value = o.value or 0
	local track = mk("Frame", { Name = "Track", BackgroundColor3 = t.c.track, Size = UDim2.fromScale(1, 1) }, self.body)
	corner(track, UDim.new(1, 0))
	if t.stroke > 0 then
		stroke(track, t.c.ink, t.stroke, t.outlineT or 0, true)
	end
	local grads = {}
	for i, side in { "Right", "Left" } do
		local clip = mk("Frame", {
			Name = side,
			BackgroundTransparency = 1,
			ClipsDescendants = true,
			Position = UDim2.fromScale(i == 1 and 0.5 or 0, 0),
			Size = UDim2.fromScale(0.5, 1),
		}, track)
		local disc = mk("Frame", {
			BackgroundColor3 = self.color,
			Position = UDim2.fromScale(i == 1 and -1 or 0, 0),
			Size = UDim2.fromScale(2, 1),
		}, clip)
		corner(disc, UDim.new(1, 0))
		grads[i] = mk("UIGradient", { Transparency = HALF }, disc)
		self["disc" .. i] = disc
	end
	self.grads = grads
	local inner = mk("Frame", {
		Name = "Inner",
		BackgroundColor3 = WHITE,
		AnchorPoint = V2(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(S - 2 * th, S - 2 * th),
	}, track)
	corner(inner, UDim.new(1, 0))
	vgrad(inner, t.c.panelTop, t.c.panelBottom)
	if t.stroke > 0 then
		stroke(inner, t.c.ink, math.max(1, t.stroke - 1), t.outlineT or 0, true)
	end
	if o.icon or o.glyph then
		iconDisc(inner, t, {
			size = math.floor((S - 2 * th) * 0.62),
			image = o.icon,
			glyph = o.glyph,
			color = self.color,
			position = UDim2.fromScale(0.5, 0.5),
			anchor = V2(0.5, 0.5),
		})
	else
		self.txt = text(inner, t, { role = "numeric", text = "0%", textSize = math.floor(S * 0.24) })
	end
	if o.label then
		text(self.body, t, {
			role = "heading",
			text = o.label,
			textSize = 18,
			position = UDim2.new(0.5, 0, 1, 6),
			anchor = V2(0.5, 0),
			size = UDim2.fromOffset(S + 80, 22),
			stroke = math.min(2, t.textStroke),
		})
	end
	self.fmt = o.format
	self.valS = self:spring(self.value, 14, 1, function(v)
		local a = math.clamp(v, 0, 1) * 360
		grads[1].Rotation = math.min(a, 180)
		grads[2].Rotation = math.max(a, 180)
		if self.txt then
			self.txt:set(self.fmt and fmtNum(v, self.fmt) or (math.floor(v * 100 + 0.5) .. "%"))
		end
	end)
	return self:_enter()
end
-- set(fraction 0..1, {color})
function Ring:set(v, p)
	local prev = self.valS.s.Target
	self.valS:to(math.clamp(v, 0, 1))
	if p and p.color then
		self.disc1.BackgroundColor3 = p.color
		self.disc2.BackgroundColor3 = p.color
	end
	if v >= 1 and prev < 1 then
		self:punch()
		sfx("pop", self)
	end
	return self
end

-- ── dial: speedometer / gauge with lit segment band and sprung needle ───────
local Dial = class()
function UIKit.dial(o)
	o = o or {}
	local t = o.theme or UIKit.current
	local S = o.size or 300
	local R = S / 2
	local self = setmetatable(newBase(o, S, S, UDim2.new(1, -40, 1, -40), V2(1, 1), "Dial"), Dial)
	self.max = o.max or 200
	self.red = o.redline or self.max * 0.8
	self.A0, self.SW = -135, 270
	local face = mk("Frame", { Name = "Face", BackgroundColor3 = WHITE, Size = UDim2.fromScale(1, 1) }, self.body)
	corner(face, UDim.new(1, 0))
	vgrad(face, t.c.panelTop, t.c.panelBottom)
	if t.stroke > 0 then
		stroke(face, t.c.ink, t.stroke + 1, t.outlineT or 0, true)
	end
	if t.shadow > 0 then
		local sh = mk("Frame", {
			Name = "Shadow",
			BackgroundColor3 = t.c.ink,
			BackgroundTransparency = t.shadowT,
			Position = UDim2.fromOffset(0, t.shadow),
			Size = UDim2.fromScale(1, 1),
			ZIndex = 0,
		}, self.body)
		corner(sh, UDim.new(1, 0))
		face.ZIndex = 1
	end
	local rimRing = mk("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = V2(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(S - 16, S - 16),
	}, face)
	corner(rimRing, UDim.new(1, 0))
	stroke(rimRing, t.c.rim, 2, 0.75, true)
	local SEG = o.segments or 30
	self.segs = {}
	for j = 1, SEG do
		local frac = (j - 0.5) / SEG
		local a = self.A0 + self.SW * frac
		local holder = mk("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Rotation = a }, face)
		local seg = mk("Frame", {
			BackgroundColor3 = t.c.track,
			AnchorPoint = V2(0.5, 0),
			Position = UDim2.fromOffset(R, 16),
			Size = UDim2.fromOffset(math.max(4, S * 0.022), S * 0.085),
		}, holder)
		corner(seg, 2)
		self.segs[j] = { f = seg, red = frac * self.max >= self.red }
	end
	local majors = o.majors or 5
	for j = 0, majors do
		local frac = j / majors
		local a = math.rad(self.A0 + self.SW * frac)
		local r2 = R * 0.6
		text(face, t, {
			role = "numeric",
			text = tostring(math.floor(self.max * frac + 0.5)),
			textSize = math.floor(S * 0.065),
			color = (frac * self.max >= self.red) and t.c.bad or t.c.textDim,
			position = UDim2.fromOffset(R + math.sin(a) * r2, R - math.cos(a) * r2),
			anchor = V2(0.5, 0.5),
			size = UDim2.fromOffset(60, 30),
			stroke = 0,
			shadow = 0,
		})
	end
	local needleHolder = mk("Frame", { Name = "Needle", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, face)
	local needle = mk("Frame", {
		BackgroundColor3 = WHITE,
		AnchorPoint = V2(0.5, 1),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(math.max(6, S * 0.03), R * 0.74),
	}, needleHolder)
	corner(needle, 3)
	vgrad(needle, lighten(t.c.bad, 0.3), t.c.bad)
	stroke(needle, t.c.ink, 2, 0, true)
	local hub = mk("Frame", {
		BackgroundColor3 = WHITE,
		AnchorPoint = V2(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(S * 0.13, S * 0.13),
	}, face)
	corner(hub, UDim.new(1, 0))
	vgrad(hub, t.c.raisedTop, t.c.raisedBottom)
	stroke(hub, t.c.ink, 2, 0, true)
	self.readout = text(face, t, {
		role = "numeric",
		text = "0",
		textSize = math.floor(S * 0.2),
		position = UDim2.fromScale(0.5, 0.74),
		anchor = V2(0.5, 0.5),
		size = UDim2.fromOffset(S * 0.6, S * 0.22),
	})
	text(face, t, {
		role = "heading",
		text = o.unit or "KM/H",
		textSize = math.floor(S * 0.055),
		color = t.c.textDim,
		position = UDim2.fromScale(0.5, 0.89),
		anchor = V2(0.5, 0.5),
		size = UDim2.fromOffset(S * 0.6, 20),
		stroke = 0,
		shadow = 0,
	})
	if o.label then
		text(face, t, {
			role = "heading",
			text = o.label,
			textSize = math.floor(S * 0.05),
			color = t.c.textDim,
			position = UDim2.fromScale(0.5, 0.3),
			anchor = V2(0.5, 0.5),
			size = UDim2.fromOffset(S * 0.6, 20),
			stroke = 0,
			shadow = 0,
		})
	end
	self.lit = -1
	self.valS = self:spring(o.value or 0, 12, 0.55, function(v)
		local frac = math.clamp(v / self.max, -0.02, 1.03)
		needleHolder.Rotation = self.A0 + self.SW * frac
		self.readout:set(tostring(math.max(0, math.floor(v + 0.5))))
		local lit = math.floor(math.clamp(frac, 0, 1) * SEG + 0.5)
		if lit ~= self.lit then
			self.lit = lit
			for j, sg in self.segs do
				sg.f.BackgroundColor3 = j <= lit and (sg.red and t.c.bad or t.c.accent) or t.c.track
			end
		end
	end)
	return self:_enter()
end
function Dial:set(v)
	self.valS:to(v)
	return self
end

-- ── timer: clock plate; countdown or stopwatch; warns and ticks near zero ───
local Timer = class()
function UIKit.timer(o)
	o = o or {}
	local t = o.theme or UIKit.current
	local w, h = o.width or 230, o.height or 68
	local self = setmetatable(newBase(o, w, h, UDim2.new(0.5, 0, 0, UIKit.safeTop() + 16), V2(0.5, 0), "Timer"), Timer)
	self.countdown = o.countdown ~= false
	self.seconds = o.seconds or 60
	self.warnAt = o.warnAt or 10
	self.onDone = o.onDone
	plate(self.body, t, { size = V2(w, h), deco = true })
	local cs = h - 18
	local clock = mk("Frame", {
		BackgroundColor3 = WHITE,
		Position = UDim2.fromOffset(12 + t.skew * h * 0.5, 9),
		Size = UDim2.fromOffset(cs, cs),
	}, self.body)
	corner(clock, UDim.new(1, 0))
	vgrad(clock, lighten(t.c.accent, 0.3), t.c.accent)
	stroke(clock, t.c.ink, 2, t.outlineT or 0, true)
	for i, len in { 0.32, 0.22 } do
		local hand = mk("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Rotation = i == 1 and 0 or 120 }, clock)
		mk("Frame", {
			BackgroundColor3 = t.c.ink,
			AnchorPoint = V2(0.5, 1),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.new(0, 4, len, 0),
		}, hand)
		if i == 1 then
			self.hand = hand
		end
	end
	self.txt = text(self.body, t, {
		role = "numeric",
		text = clockText(self.seconds),
		textSize = math.floor(h * 0.62),
		position = UDim2.fromOffset(cs + 18, 0),
		size = UDim2.new(1, -cs - 30, 1, 0),
	})
	self.lastWhole = math.ceil(self.seconds)
	self:on(RunService.Heartbeat, function(dt)
		if not self.running then
			return
		end
		self.seconds = self.countdown and math.max(0, self.seconds - dt) or self.seconds + dt
		self:_render()
		if self.countdown and self.seconds <= 0 then
			self.running = false
			self:punch(0.3)
			if self.onDone then
				task.spawn(self.onDone)
			end
		end
	end)
	if o.autoStart ~= false then
		self.running = true
	end
	return self:_enter()
end
function Timer:_render()
	local t = self.t
	local s = self.seconds
	self.txt:set(clockText(s, self.countdown))
	self.hand.Rotation = (s % 60) * 6
	local warn = self.countdown and s <= self.warnAt
	self.txt:color(warn and t.c.bad or t.c.text)
	local whole = math.ceil(s)
	if whole ~= self.lastWhole then
		self.lastWhole = whole
		if warn and s > 0 then
			self:punch(0.14)
			sfx("tick", self)
		end
	end
end
-- set(seconds) / start() / stop()
function Timer:set(s)
	self.seconds = s
	self.lastWhole = math.ceil(s)
	self:_render()
	return self
end
function Timer:start()
	self.running = true
	return self
end
function Timer:stop()
	self.running = false
	return self
end

-- ── objectiveTracker: checklist with check-off animation ────────────────────
local Tracker = class()
function UIKit.objectiveTracker(o)
	o = o or {}
	local t = o.theme or UIKit.current
	local w = o.width or 400
	local self = setmetatable(newBase(o, w, 400, UDim2.new(0, 40, 0.3, 0), V2(0, 0), "Objectives"), Tracker)
	self.w, self.rowH, self.headH = w, 46, 44
	local head = plate(self.body, t, { size = V2(w * 0.72, self.headH), fill = t.c.accent })
	head.root.Rotation = t.tilt * 0.5
	text(head.root, t, {
		role = "heading",
		text = o.title or "OBJECTIVES",
		textSize = 24,
		x = Enum.TextXAlignment.Left,
		position = UDim2.fromOffset(16 + head.skewPx * 0.5, 0),
		size = UDim2.new(1, -20, 1, 0),
		color = t.c.onAccent or WHITE,
	})
	self.rows = {}
	self:set(o.items or {})
	return self:_enter()
end
function Tracker:_row(item, i)
	local t = self.t
	local y = self.headH + 10 + (i - 1) * (self.rowH + 6)
	local r = plate(self.body, t, {
		size = V2(self.w - 20, self.rowH),
		position = UDim2.fromOffset(10, y),
		shadow = 0,
		stroke = math.max(1, t.stroke - 1),
		transparency = math.max(t.panelT, 0.15),
		gloss = t.gloss * 0.5,
	})
	local row: any = { plate = r, item = item, done = false }
	local box = mk("Frame", {
		BackgroundColor3 = t.c.track,
		Position = UDim2.fromOffset(12 + r.skewPx * 0.5, (self.rowH - 26) / 2),
		Size = UDim2.fromOffset(26, 26),
	}, r.root)
	corner(box, t.name == "tactical" and 2 or 6)
	stroke(box, t.name == "tactical" and t.c.textDim or t.c.ink, 2, 0, true)
	row.box = box
	local check = mk("Frame", { Name = "Check", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Rotation = 45 }, box)
	mk("Frame", { BackgroundColor3 = WHITE, Position = UDim2.fromScale(0.52, 0.12), Size = UDim2.new(0, 5, 0.66, 0) }, check)
	mk("Frame", { BackgroundColor3 = WHITE, Position = UDim2.fromScale(0.26, 0.64), Size = UDim2.new(0.3, 0, 0, 5) }, check)
	row.checkScale = mk("UIScale", { Scale = 0 }, check)
	row.label = text(r.root, t, {
		role = "body",
		text = item.text or tostring(item),
		textSize = 20,
		x = Enum.TextXAlignment.Left,
		position = UDim2.fromOffset(50 + r.skewPx * 0.5, 0),
		size = UDim2.new(1, -120, 1, 0),
		truncate = true,
	})
	row.strike = mk("Frame", {
		BackgroundColor3 = t.c.textDim,
		AnchorPoint = V2(0, 0.5),
		Position = UDim2.new(0, 50 + r.skewPx * 0.5, 0.5, 0),
		Size = UDim2.fromOffset(0, 3),
	}, r.root)
	row.prog = text(r.root, t, {
		role = "numeric",
		text = item.max and string.format("%d/%d", item.progress or 0, item.max) or "",
		textSize = 20,
		x = Enum.TextXAlignment.Right,
		position = UDim2.fromOffset(-14 - r.skewPx * 0.5, 0),
		color = t.c.accent,
		stroke = math.min(2, t.textStroke),
		shadow = 0,
	})
	return row
end
-- set(items): items = { "text" | {id, text, progress, max, done} }
function Tracker:set(items)
	for _, row in self.rows do
		row.plate.root:Destroy()
	end
	self.rows = {}
	for i, item in items do
		if type(item) == "string" then
			item = { text = item }
		end
		self.rows[i] = self:_row(item, i)
		if item.done then
			self:check(i, true)
		end
	end
	self.root.Size = UDim2.fromOffset(self.w, self.headH + 16 + #items * (self.rowH + 6))
	return self
end
function Tracker:_find(key)
	if type(key) == "number" then
		return self.rows[key]
	end
	for _, row in self.rows do
		if row.item.id == key or row.item.text == key then
			return row
		end
	end
	return nil
end
-- check(index | id, instant?): ticks the box with a pop, strikes the text through, flashes the row.
function Tracker:check(key, instant)
	local row = self:_find(key)
	if not row or row.done then
		return self
	end
	local t = self.t
	row.done = true
	row.box.BackgroundColor3 = t.c.good
	row.label:color(t.c.textDim)
	local strikeW = math.min(self.w - 150, (#tostring(row.item.text or "") * 10) + 10)
	if instant then
		row.checkScale.Scale = 1
		row.strike.Size = UDim2.fromOffset(strikeW, 3)
		return self
	end
	local s = self:spring(0, 26, 0.4, function(v)
		row.checkScale.Scale = v
	end)
	s:to(1)
	tw(row.strike, { Size = UDim2.fromOffset(strikeW, 3) }, 0.35, Enum.EasingStyle.Quad, nil, 0.12)
	local flash = mk("Frame", { BackgroundColor3 = t.c.good, BackgroundTransparency = 0.35, Size = UDim2.fromScale(1, 1) }, row.plate.root)
	corner(flash, math.max(t.radius, 0))
	noFade(flash)
	tw(flash, { BackgroundTransparency = 1 }, 0.6).Completed:Once(function()
		flash:Destroy()
	end)
	sfx("check", self)
	return self
end
function Tracker:progress(key, value, max)
	local row = self:_find(key)
	if row then
		row.item.progress, row.item.max = value, max or row.item.max
		row.prog:set(string.format("%d/%d", value, row.item.max or value))
		local s = mk("UIScale", {}, row.prog.holder)
		local sp = self:spring(1.4, 30, 0.4, function(v)
			s.Scale = v
		end)
		sp:to(1)
		if row.item.max and value >= row.item.max then
			self:check(key)
		end
	end
	return self
end

-- ── standings: leaderboard rows that spring to their new rank ───────────────
local Standings = class()
function UIKit.standings(o)
	o = o or {}
	local t = o.theme or UIKit.current
	local w = o.width or 320
	local s = setmetatable(newBase(o, w, 420, UDim2.new(1, -40, 0, UIKit.safeTop() + 300), V2(1, 0), "Standings"), Standings)
	s.w, s.rowH, s.max = w, 44, o.max or 8
	s.headH = o.title and 38 or 0
	if o.title then
		local head = plate(s.body, t, { size = V2(w * 0.7, 32), fill = t.c.accent, shadow = 0, position = UDim2.fromOffset(w * 0.3, 0) })
		text(head.root, t, { role = "heading", text = o.title, textSize = 20, color = t.c.onAccent or WHITE })
	end
	s.rows = {}
	s.sortBy = o.sortBy
	s.format = o.format
	s:set(o.rows or {})
	return s:_enter()
end
function Standings:_make(r)
	local t = self.t
	local you = r.you
	local h = self.rowH
	local holder = mk("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(self.w, h) }, self.body)
	local pl = plate(holder, t, {
		size = V2(self.w, h),
		top = you and lighten(t.c.accent, 0.1) or nil,
		bottom = you and darken(t.c.accent, 0.3) or nil,
		shadow = you and t.shadow or 0,
		stroke = math.max(1, t.stroke - 1),
	})
	local chip = mk("Frame", {
		BackgroundColor3 = WHITE,
		Position = UDim2.fromOffset(6 + pl.skewPx * 0.5, 5),
		Size = UDim2.fromOffset(h - 10, h - 10),
	}, pl.root)
	corner(chip, t.name == "tactical" and 2 or math.min(t.radius, 10))
	local grad = vgrad(chip, t.c.raisedTop, t.c.raisedBottom)
	local rank = text(chip, t, { role = "numeric", text = "1", textSize = 24 })
	mk("Frame", {
		BackgroundColor3 = r.color or t.c.accent2,
		Position = UDim2.fromOffset(h + 2 + pl.skewPx * 0.5, 8),
		Size = UDim2.fromOffset(5, h - 16),
	}, pl.root)
	local name = text(pl.root, t, {
		role = "heading",
		text = r.name,
		textSize = 20,
		x = Enum.TextXAlignment.Left,
		position = UDim2.fromOffset(h + 14 + pl.skewPx * 0.5, 0),
		size = UDim2.new(0.6, -h, 1, 0),
		color = you and WHITE or t.c.text,
		stroke = math.min(2, t.textStroke),
		shadow = 0,
		truncate = true,
	})
	local val = text(pl.root, t, {
		role = "numeric",
		text = "",
		textSize = 20,
		x = Enum.TextXAlignment.Right,
		position = UDim2.fromOffset(-12 - pl.skewPx * 0.5, 0),
		color = you and WHITE or t.c.textDim,
		stroke = math.min(2, t.textStroke),
		shadow = 0,
	})
	local row: any = { holder = holder, rank = rank, chipGrad = grad, name = name, val = val, you = you }
	row.yS = self:spring(0, 18, 0.75, function(v)
		holder.Position = UDim2.fromOffset(you and -14 or 0, v)
	end)
	return row
end
-- set(rows): rows = {{name, value, color?, you?}} in rank order (or opts.sortBy = "value" sorts descending).
function Standings:set(rows)
	local t = self.t
	rows = table.clone(rows)
	if self.sortBy then
		local key = self.sortBy
		table.sort(rows, function(a, b)
			return (a[key] or 0) > (b[key] or 0)
		end)
	end
	local seen = {}
	for i, r in rows do
		if i > self.max then
			break
		end
		seen[r.name] = true
		local row = self.rows[r.name]
		local y = self.headH + (i - 1) * (self.rowH + 6)
		if not row then
			row = self:_make(r)
			self.rows[r.name] = row
			row.yS:snap(y + 30)
			row.rankN = i
		end
		row.yS:to(y)
		row.rank:set(tostring(i))
		row.val:set(r.value ~= nil and (type(r.value) == "number" and fmtNum(r.value, self.format) or tostring(r.value)) or "")
		local medal = ({ t.c.gold, H("#d8e2ec"), H("#e09a5b") })[i]
		row.chipGrad.Color = medal and ColorSequence.new(lighten(medal, 0.3), darken(medal, 0.25)) or ColorSequence.new(t.c.raisedTop, t.c.raisedBottom)
		if row.rankN and row.rankN ~= i then
			local up = i < row.rankN
			local tag = text(row.holder, t, {
				role = "numeric",
				text = up and ("+" .. (row.rankN - i)) or ("-" .. (i - row.rankN)),
				textSize = 20,
				color = up and t.c.good or t.c.bad,
				position = UDim2.new(0, -10, 0.5, 0),
				anchor = V2(1, 0.5),
				size = UDim2.fromOffset(40, 24),
				stroke = 2,
			})
			noFade(tag.holder)
			task.delay(0.9, function()
				tag.holder:Destroy()
			end)
			if up and row.you then
				sfx("pop", self)
			end
		end
		row.rankN = i
	end
	for name, row in self.rows do
		if not seen[name] then
			row.holder:Destroy()
			row.yS:stop()
			self.rows[name] = nil
		end
	end
	self.root.Size = UDim2.fromOffset(self.w, self.headH + math.min(#rows, self.max) * (self.rowH + 6))
	return self
end

-- ── minimap: top-down view of given parts with tracked markers ──────────────
local Minimap = class()
local function collectParts(src, out)
	if typeof(src) == "Instance" then
		if src:IsA("BasePart") and not src:IsA("Terrain") then
			table.insert(out, src)
		else
			for _, d in src:GetDescendants() do
				if d:IsA("BasePart") and not d:IsA("Terrain") and d.Transparency < 0.95 and #out < 300 then
					table.insert(out, d)
				end
			end
		end
	elseif type(src) == "table" then
		for _, v in src do
			collectParts(v, out)
		end
	end
	return out
end
local function worldPos(at)
	if typeof(at) == "Vector3" then
		return at
	elseif typeof(at) == "CFrame" then
		return at.Position
	elseif typeof(at) == "Instance" then
		if at:IsA("BasePart") then
			return at.Position
		elseif at:IsA("Model") then
			return at:GetPivot().Position
		elseif at:IsA("Attachment") then
			return at.WorldPosition
		end
	end
	return nil
end
function UIKit.minimap(o)
	o = o or {}
	local t = o.theme or UIKit.current
	local S = o.size or (UIKit.compact() and 200 or 250)
	local self = setmetatable(newBase(o, S, S + 24, UDim2.new(1, -40, 0, UIKit.safeTop() + 16), V2(1, 0), "Minimap"), Minimap)
	self.S, self.range = S, o.range or 300
	self.square = o.shape == "square"
	self.center = o.center
	self.follow = o.follow ~= false and o.center == nil
	local rad = self.square and UDim.new(0, math.max(t.radius, 4)) or UDim.new(1, 0)
	if t.shadow > 0 then
		local sh = mk("Frame", {
			BackgroundColor3 = t.c.ink,
			BackgroundTransparency = t.shadowT,
			Position = UDim2.fromOffset(0, t.shadow),
			Size = UDim2.fromOffset(S, S),
		}, self.body)
		corner(sh, rad)
	end
	local map = mk("Frame", { Name = "Map", BackgroundColor3 = WHITE, Size = UDim2.fromOffset(S, S), ClipsDescendants = true }, self.body)
	corner(map, rad)
	local mapColor = o.color or t.c.panelBottom:Lerp(t.c.accent2, 0.18)
	vgrad(map, lighten(mapColor, 0.08), darken(mapColor, 0.2))
	stroke(map, t.c.ink, math.max(2, t.stroke + 1), t.outlineT or 0, true)
	local ring = mk("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = V2(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -10, 1, -10),
	}, map)
	corner(ring, rad)
	stroke(ring, t.c.rim, 2, 0.7, true)
	for i = 1, 3 do -- range rings / grid
		local g = mk("Frame", {
			BackgroundTransparency = 1,
			AnchorPoint = V2(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(i / 3, i / 3),
		}, map)
		corner(g, rad)
		stroke(g, t.c.text, 1, 0.88, true)
	end
	self.map = map
	self.geo = mk("Frame", { Name = "Geometry", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, map)
	self.markLayer = mk("Frame", { Name = "Markers", BackgroundTransparency = 1, Size = UDim2.fromOffset(S, S) }, self.body)
	self.parts = {}
	for _, p in collectParts(o.parts or {}, {}) do
		local f = mk("Frame", {
			BackgroundColor3 = (p.Color):Lerp(mapColor, 0.35),
			AnchorPoint = V2(0.5, 0.5),
		}, self.geo)
		stroke(f, darken(mapColor, 0.5), 1, 0.4, true)
		table.insert(self.parts, { part = p, f = f })
	end
	-- player arrow
	local me = mk("Frame", {
		Name = "Me",
		BackgroundTransparency = 1,
		AnchorPoint = V2(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(30, 30),
	}, self.markLayer)
	local dot = mk("Frame", {
		BackgroundColor3 = WHITE,
		AnchorPoint = V2(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(16, 16),
	}, me)
	corner(dot, UDim.new(1, 0))
	stroke(dot, t.c.ink, 3, 0, true)
	local nose = mk("Frame", {
		BackgroundColor3 = t.c.accent,
		AnchorPoint = V2(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0, 2),
		Size = UDim2.fromOffset(12, 12),
		Rotation = 45,
	}, me)
	stroke(nose, t.c.ink, 2, 0, true)
	self.me = me
	text(self.body, t, {
		role = "heading",
		text = "N",
		textSize = 20,
		position = UDim2.new(0.5, 0, 0, -4),
		anchor = V2(0.5, 0.5),
		size = UDim2.fromOffset(30, 26),
		color = t.c.accent,
	})
	if o.label then
		text(self.body, t, {
			role = "heading",
			text = o.label,
			textSize = 16,
			color = t.c.textDim,
			position = UDim2.new(0.5, 0, 0, S + 4),
			anchor = V2(0.5, 0),
			size = UDim2.fromOffset(S, 20),
			stroke = 0,
		})
	end
	self.markers = {}
	local acc = 0
	self:on(RunService.Heartbeat, function(dt)
		acc += dt
		if acc < 1 / 20 then
			return
		end
		acc = 0
		self:_update()
	end)
	self:_update()
	return self:_enter()
end
function Minimap:_toMap(p: Vector3, c: Vector3)
	local s = (self.S * 0.5) / self.range
	return V2((p.X - c.X) * s, (p.Z - c.Z) * s)
end
function Minimap:_inside(v: Vector2, margin)
	local r = self.S * 0.5 - margin
	if self.square then
		return math.abs(v.X) <= r and math.abs(v.Y) <= r
	end
	return v.Magnitude <= r
end
function Minimap:_update()
	local char = Players.LocalPlayer and Players.LocalPlayer.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local c = (self.follow and hrp and hrp.Position) or self.center or Vector3.zero
	local half = self.S * 0.5
	local s = half / self.range
	for _, e in self.parts do
		local p = e.part
		if p.Parent then
			local v = self:_toMap(p.Position, c)
			local size = p.Size
			local inside = self:_inside(v, 0)
			e.f.Visible = inside
			if inside then
				local _, yaw = p.CFrame:ToOrientation()
				e.f.Position = UDim2.fromOffset(half + v.X, half + v.Y)
				e.f.Size = UDim2.fromOffset(math.max(2, size.X * s), math.max(2, size.Z * s))
				e.f.Rotation = -math.deg(yaw)
			end
		else
			e.f.Visible = false
		end
	end
	if hrp then
		local look = hrp.CFrame.LookVector
		local mv = self.follow and Vector2.zero or self:_toMap(hrp.Position, c)
		self.me.Position = UDim2.fromOffset(half + mv.X, half + mv.Y)
		self.me.Rotation = math.deg(math.atan2(look.X, -look.Z))
		self.me.Visible = self:_inside(mv, 6)
	end
	for _, m in self.markers do
		local wp = worldPos(m.at)
		if wp then
			local v = self:_toMap(wp, c)
			local edge = not self:_inside(v, 12)
			if edge then
				local r = half - 12
				v = self.square and V2(math.clamp(v.X, -r, r), math.clamp(v.Y, -r, r)) or v.Unit * r
			end
			m.f.Position = UDim2.fromOffset(half + v.X, half + v.Y)
			m.scale.Scale = (edge and 0.75 or 1) * (m.pulse and (1 + 0.15 * math.sin(os.clock() * 6)) or 1)
		end
	end
end
-- mark(id, {at = Vector3 | BasePart | Model, color, glyph, pulse}) / unmark(id)
function Minimap:mark(id, p)
	self:unmark(id)
	local t = self.t
	local f = mk("Frame", { BackgroundColor3 = WHITE, AnchorPoint = V2(0.5, 0.5), Size = UDim2.fromOffset(22, 22) }, self.markLayer)
	corner(f, t.name == "tactical" and UDim.new(0, 2) or UDim.new(1, 0))
	local c = p.color or t.c.bad
	vgrad(f, lighten(c, 0.3), c)
	stroke(f, t.c.ink, 2, 0, true)
	if p.glyph then
		text(f, t, { role = "heading", text = p.glyph, textSize = 14, color = WHITE, stroke = 1, shadow = 0 })
	end
	self.markers[id] = { at = p.at, f = f, scale = mk("UIScale", {}, f), pulse = p.pulse }
	return self
end
function Minimap:unmark(id)
	local m = self.markers[id]
	if m then
		m.f:Destroy()
		self.markers[id] = nil
	end
	return self
end
-- set({center, range, follow})
function Minimap:set(p)
	if p.center then
		self.center, self.follow = p.center, false
	end
	if p.follow ~= nil then
		self.follow = p.follow
	end
	self.range = p.range or self.range
	self:_update()
	return self
end

-- ── crosshair: dynamic spread, kick, hit markers ────────────────────────────
local Crosshair = class()
function UIKit.crosshair(o)
	o = o or {}
	local self = setmetatable(newBase(o, 240, 240, UDim2.fromScale(0.5, 0.5), V2(0.5, 0.5), "Crosshair"), Crosshair)
	self.style = o.style or "cross"
	self.gap0, self.maxSpread = o.gap or 8, o.spread or 40
	local len, th = o.length or 14, o.thickness or 3
	local color = o.color or WHITE
	self.arms = {}
	local function bar(parent, w, h)
		local f = mk("Frame", { BackgroundColor3 = color, AnchorPoint = V2(0.5, 0.5), Size = UDim2.fromOffset(w, h) }, parent)
		stroke(f, BLACK, 1, 0.35, true)
		return f
	end
	if self.style == "circle" then
		local c = mk("Frame", { BackgroundTransparency = 1, AnchorPoint = V2(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5) }, self.body)
		corner(c, UDim.new(1, 0))
		stroke(c, color, 2, 0, true)
		self.circle = c
	elseif self.style ~= "dot" then
		for i, d in { V2(0, -1), V2(1, 0), V2(0, 1), V2(-1, 0) } do
			if not (self.style == "tee" and i == 1) then
				local a = bar(self.body, d.X ~= 0 and len or th, d.Y ~= 0 and len or th)
				table.insert(self.arms, { f = a, d = d, len = len })
			end
		end
	end
	local dot = bar(self.body, 4, 4)
	dot.Position = UDim2.fromScale(0.5, 0.5)
	corner(dot, UDim.new(1, 0))
	-- hit marker: an X of four short bars
	local hit = mk("Frame", {
		Name = "Hit",
		BackgroundTransparency = 1,
		AnchorPoint = V2(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(60, 60),
		Rotation = 45,
		Visible = false,
	}, self.body)
	self.hitBars = {}
	for _, d in { V2(0, -1), V2(1, 0), V2(0, 1), V2(-1, 0) } do
		local b = mk("Frame", {
			BackgroundColor3 = WHITE,
			AnchorPoint = V2(0.5, 0.5),
			Position = UDim2.new(0.5, d.X * 16, 0.5, d.Y * 16),
			Size = UDim2.fromOffset(d.X ~= 0 and 12 or 3, d.Y ~= 0 and 12 or 3),
		}, hit)
		stroke(b, BLACK, 1, 0.3, true)
		table.insert(self.hitBars, b)
	end
	self.hitScale = mk("UIScale", {}, hit)
	noFade(hit)
	self.hitFrame = hit
	self.gapS = self:spring(self.gap0, 28, 0.8, function(g)
		for _, a in self.arms do
			local off = g + a.len * 0.5
			a.f.Position = UDim2.new(0.5, a.d.X * off, 0.5, a.d.Y * off)
		end
		if self.circle then
			self.circle.Size = UDim2.fromOffset(g * 2 + 12, g * 2 + 12)
		end
	end)
	return self:_enter()
end
-- set({spread = 0..1, color})
function Crosshair:set(p)
	if type(p) == "number" then
		p = { spread = p }
	end
	if p.spread then
		self.gapS:to(self.gap0 + p.spread * self.maxSpread)
	end
	if p.color then
		for _, a in self.arms do
			a.f.BackgroundColor3 = p.color
		end
	end
	return self
end
-- kick(amount = 1): momentary bloom when firing.
function Crosshair:kick(amount)
	self.gapS:kick(260 * (amount or 1))
	return self
end
-- hit("hit" | "kill" | "headshot")
function Crosshair:hit(kind)
	local t = self.t
	kind = kind or "hit"
	local c = kind == "kill" and t.c.bad or kind == "headshot" and t.c.warn or WHITE
	for _, b in self.hitBars do
		b.BackgroundColor3 = c
		b.BackgroundTransparency = 0
	end
	self.hitFrame.Visible = true
	self.hitScale.Scale = kind == "hit" and 1.5 or 2
	tw(self.hitScale, { Scale = kind == "hit" and 1 or 1.3 }, 0.12, Enum.EasingStyle.Back)
	local hold = kind == "hit" and 0.08 or 0.3
	for _, b in self.hitBars do
		tw(b, { BackgroundTransparency = 1 }, 0.22, Enum.EasingStyle.Quad, nil, hold)
	end
	sfx(kind == "hit" and "hit" or "kill", self)
	return self
end

-- ── ammo: magazine pips, reserve, reload state ──────────────────────────────
local Ammo = class()
function UIKit.ammo(o)
	o = o or {}
	local t = o.theme or UIKit.current
	local w, h = 400, 150
	local self = setmetatable(newBase(o, w, h, UDim2.new(1, -40, 1, -40), V2(1, 1), "Ammo"), Ammo)
	self.magSize = o.magSize or 30
	self.mag = o.mag or self.magSize
	self.reserve = o.reserve or 90
	local panel = plate(self.body, t, { size = V2(w, 96), position = UDim2.fromOffset(0, 54), deco = true })
	local name = plate(self.body, t, { size = V2(220, 40), position = UDim2.fromOffset(w - 230, 6), fill = t.c.accent, shadow = 0 })
	name.root.Rotation = t.tilt * 0.5
	self.nameText = text(name.root, t, {
		role = "heading",
		text = o.weapon or "RIFLE",
		textSize = 22,
		color = t.c.onAccent or WHITE,
	})
	local holder = mk("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(w - 200, 54), Size = UDim2.fromOffset(120, 96) }, self.body)
	self.magScale = mk("UIScale", {}, holder)
	self.magPop = self:spring(1, 30, 0.45, function(v)
		self.magScale.Scale = v
	end)
	self.magText = text(holder, t, {
		role = "numeric",
		text = tostring(self.mag),
		textSize = 72,
		x = Enum.TextXAlignment.Right,
	})
	self.resText = text(panel.root, t, {
		role = "numeric",
		text = "/ " .. self.reserve,
		textSize = 30,
		color = t.c.textDim,
		x = Enum.TextXAlignment.Left,
		position = UDim2.fromOffset(w - 72, 16),
		size = UDim2.fromOffset(70, 60),
		stroke = math.min(2, t.textStroke),
		shadow = 0,
	})
	self.pips = {}
	local n = math.min(self.magSize, 30)
	self.pipN = n
	local pipArea = w - 230
	local pw = math.clamp(math.floor(pipArea / n) - 3, 3, 10)
	for i = 1, n do
		local p = mk("Frame", {
			BackgroundColor3 = t.c.text,
			AnchorPoint = V2(0, 1),
			Position = UDim2.fromOffset(18 + (i - 1) * (pw + 3), 76),
			Size = UDim2.fromOffset(pw, 36),
			Rotation = t.skew > 0 and 12 or 0,
		}, panel.root)
		corner(p, t.name == "tactical" and 0 or 2)
		stroke(p, t.c.ink, 1, t.outlineT or 0.2, true)
		self.pips[i] = p
	end
	self.reloadBar = UIKit.bar({
		parent = self.body,
		theme = t,
		width = pipArea - 10,
		height = 14,
		value = 0,
		max = 1,
		showText = false,
		color = t.c.accent2,
		pulseLow = false,
		position = UDim2.fromOffset(14, 150),
		anchor = V2(0, 0),
	})
	self.reloadBar:hide(true)
	self.status = text(self.body, t, {
		role = "heading",
		text = "",
		textSize = 22,
		color = t.c.bad,
		position = UDim2.fromOffset(0, 14),
		size = UDim2.fromOffset(w - 240, 30),
		x = Enum.TextXAlignment.Left,
	})
	self:on(RunService.Heartbeat, function()
		if self.mag == 0 and not self.reloading then
			self.status.holder.Visible = math.sin(os.clock() * 8) > -0.3
		end
	end)
	self:set(self.mag, self.reserve, true)
	return self:_enter()
end
-- set(mag, reserve?): spent pips flick out; low ammo warns, empty blinks RELOAD.
function Ammo:set(mag, reserve, silent)
	local t = self.t
	local prev = self.mag
	self.mag, self.reserve = mag, reserve or self.reserve
	self.magText:set(tostring(mag))
	self.resText:set("/ " .. tostring(self.reserve))
	local frac = mag / self.magSize
	self.magText:color(mag == 0 and t.c.bad or frac <= 0.3 and t.c.warn or t.c.text)
	local lit = math.ceil(frac * self.pipN)
	for i, p in self.pips do
		local on = i <= lit
		if not on and p:GetAttribute("On") ~= false and not silent then
			local ghost = p:Clone()
			ghost.Parent = p.Parent
			noFade(ghost)
			tw(ghost, { Position = p.Position + UDim2.fromOffset(6, -26), BackgroundTransparency = 1, Rotation = 40 }, 0.3)
			local gs = ghost:FindFirstChildOfClass("UIStroke")
			if gs then
				tw(gs, { Transparency = 1 }, 0.3)
			end
			task.delay(0.32, function()
				ghost:Destroy()
			end)
		end
		p:SetAttribute("On", on)
		p.BackgroundColor3 = on and (frac <= 0.3 and t.c.warn or t.c.text) or t.c.track
	end
	self.status:set(mag == 0 and "RELOAD" or (frac <= 0.3 and "LOW AMMO" or ""))
	self.status:color(mag == 0 and t.c.bad or t.c.warn)
	self.status.holder.Visible = true
	if not silent and mag ~= prev then
		self.magPop.s.Position = mag < prev and 1.12 or 1.3
		self.magPop:to(1)
	end
	return self
end
-- reload(seconds, onDone?): fills a reload bar; the game sets the new counts in onDone.
function Ammo:reload(seconds, onDone)
	seconds = seconds or 1.6
	self.reloading = true
	self.status:set("RELOADING")
	self.status:color(self.t.c.accent2)
	self.status.holder.Visible = true
	self.reloadBar:show()
	self.reloadBar.fillS:snap(0)
	self.reloadBar.trailS:snap(0)
	self.reloadBar.fillS.s.Speed = 6
	self.reloadBar.fillS:to(1)
	sfx("reload", self)
	self:later(seconds, function()
		self.reloading = false
		self.reloadBar:hide()
		if onDone then
			onDone()
		end
	end)
	return self
end

-- ── toasts: stacked notifications that slide in, push down, and time out ────
local Toasts = class()
function UIKit.toasts(o)
	o = o or {}
	local self = setmetatable(newBase(o, 420, 600, UDim2.new(1, -40, 0, UIKit.safeTop() + 330), V2(1, 0), "Toasts"), Toasts)
	self.items = {}
	self.max = o.max or 5
	return self:_enter()
end
function Toasts:_reflow()
	local y = 0
	for _, it in self.items do
		it.yS:to(y)
		y += it.h + 10
	end
end
-- push(text, {body, kind = "info"|"good"|"warn"|"bad"|"reward", icon, glyph, duration = 3}) -> toast {dismiss()}
function Toasts:push(s, p)
	p = p or {}
	local t = self.t
	local kind = p.kind or "info"
	local color = p.color or ({ info = t.c.accent2, good = t.c.good, warn = t.c.warn, bad = t.c.bad, reward = t.c.gold })[kind] or t.c.accent2
	local h = p.body and 84 or 64
	local holder = mk("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(400, h) }, self.body)
	local pl = plate(holder, t, { size = V2(400, h) })
	local stripe = plate(pl.root, t, {
		size = V2(14 + pl.skewPx, h),
		fill = color,
		stroke = 0,
		shadow = 0,
		rim = 0,
		radius = t.radius,
	})
	stripe.root.Position = UDim2.fromOffset(0, 0)
	local isz = 44
	iconDisc(pl.root, t, {
		size = isz,
		image = p.icon,
		glyph = p.glyph or ({ info = "i", good = "+", warn = "!", bad = "!", reward = "*" })[kind] or "i",
		color = color,
		position = UDim2.new(0, 26 + pl.skewPx * 0.5, 0.5, 0),
		anchor = V2(0, 0.5),
	})
	local tx = 26 + isz + 12 + pl.skewPx * 0.5
	text(pl.root, t, {
		role = "heading",
		text = s,
		textSize = 22,
		x = Enum.TextXAlignment.Left,
		position = UDim2.fromOffset(tx, p.body and 10 or 0),
		size = UDim2.new(1, -tx - 14, 0, p.body and 30 or h),
		truncate = true,
		stroke = math.min(2, t.textStroke),
		shadow = 2,
	})
	if p.body then
		text(pl.root, t, {
			role = "body",
			text = p.body,
			textSize = 18,
			color = t.c.textDim,
			x = Enum.TextXAlignment.Left,
			position = UDim2.fromOffset(tx, 42),
			size = UDim2.new(1, -tx - 14, 0, 26),
			truncate = true,
		})
	end
	local timeBar = mk("Frame", {
		Name = "Time",
		BackgroundColor3 = color,
		Position = UDim2.new(0, 14 + pl.skewPx, 1, -6),
		Size = UDim2.new(1, -40 - pl.skewPx, 0, 3),
	}, pl.root)
	local it: any = { holder = holder, h = h }
	it.xS = self:spring(460, 24, 0.7, function(v)
		holder.Position = UDim2.fromOffset(v, holder.Position.Y.Offset)
	end)
	it.yS = self:spring(0, 22, 0.8, function(v)
		holder.Position = UDim2.fromOffset(holder.Position.X.Offset, v)
	end)
	table.insert(self.items, 1, it)
	it.yS:snap(0)
	it.xS:to(0)
	self:_reflow()
	local dur = p.duration or 3
	tw(timeBar, { Size = UDim2.new(0, 0, 0, 3) }, dur, Enum.EasingStyle.Linear)
	function it.dismiss()
		if it.gone then
			return
		end
		it.gone = true
		it.xS:to(480)
		task.delay(0.35, function()
			local idx = table.find(self.items, it)
			if idx then
				table.remove(self.items, idx)
			end
			holder:Destroy()
			if not self._dead then
				self:_reflow()
			end
		end)
	end
	task.delay(dur, it.dismiss)
	while #self.items > self.max do
		local last = self.items[#self.items]
		table.remove(self.items, #self.items)
		last.gone = true
		last.holder:Destroy()
	end
	sfx("toast", self)
	return it
end
Toasts.set = Toasts.push
local defaultToasts
-- UIKit.toast(text, opts): push onto a shared stack.
function UIKit.toast(s, p)
	if not defaultToasts or defaultToasts._dead then
		defaultToasts = UIKit.toasts({ theme = p and p.theme })
	end
	return defaultToasts:push(s, p)
end

-- ── dialog: speaker plate, portrait, typewriter text, choices ────────────────
local Dialog = class()
function UIKit.dialog(o)
	o = o or {}
	local t = o.theme or UIKit.current
	local compact = UIKit.compact()
	local w = o.width or (compact and math.min(1100, Screen.canvas().X - 60) or 1100)
	local h = 220
	local self = setmetatable(newBase(o, w, h + 60, UDim2.new(0.5, 0, 1, -30), V2(0.5, 1), "Dialog"), Dialog)
	self.w, self.h = w, h
	local panel = plate(self.body, t, { size = V2(w, h), position = UDim2.fromOffset(0, 60), deco = true })
	self.panel = panel
	local ps = 170
	self.portraitHolder = mk("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(28, 0), Size = UDim2.fromOffset(ps, ps) }, self.body)
	self.namePlateHolder = mk("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(ps + 40, 26), Size = UDim2.fromOffset(320, 52) }, self.body)
	self.body_ = text(panel.root, t, {
		role = "body",
		text = "",
		textSize = 28,
		wrap = true,
		x = Enum.TextXAlignment.Left,
		y = Enum.TextYAlignment.Top,
		position = UDim2.fromOffset(ps + 50 + panel.skewPx * 0.3, 34),
		size = UDim2.new(1, -ps - 100, 1, -60),
		shadow = t.textShadow > 0 and 2 or 0,
	})
	local more = mk("Frame", {
		BackgroundColor3 = t.c.accent,
		AnchorPoint = V2(0.5, 0.5),
		Position = UDim2.new(1, -40 - panel.skewPx * 0.2, 1, -30),
		Size = UDim2.fromOffset(16, 16),
		Rotation = 45,
	}, panel.root)
	stroke(more, t.c.ink, 2, 0, true)
	self.more = more
	local hit = mk("TextButton", { Text = "", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), AutoButtonColor = false }, panel.root)
	self:on(hit.Activated, function()
		self:skip()
	end)
	self.choiceButtons = {}
	self:on(RunService.Heartbeat, function()
		more.Visible = not self.typing and self.text ~= nil and #self.choiceButtons == 0
		more.Position = UDim2.new(1, -40 - panel.skewPx * 0.2, 1, -30 + math.sin(os.clock() * 6) * 4)
	end)
	if o.speaker or o.text then
		self:say(o.speaker, o.text or "", o)
	end
	return self:_enter()
end
-- say(speaker, text, {choices = {"Yes", "No"}, onChoice(i, label), onNext(), portrait, color, speed = 45})
function Dialog:say(speaker, s, p)
	p = p or {}
	local t = self.t
	self._ver += 1
	for _, b in self.choiceButtons do
		b:Destroy()
	end
	self.choiceButtons = {}
	self.p = p
	local color = p.color or t.c.accent
	for _, c in self.portraitHolder:GetChildren() do
		c:Destroy()
	end
	for _, c in self.namePlateHolder:GetChildren() do
		c:Destroy()
	end
	local ps = self.portraitHolder.Size.X.Offset
	local frame = plate(self.portraitHolder, t, { size = V2(ps, ps), fill = color, skew = 0, radius = t.radius > 0 and math.max(t.radius, 14) or 0 })
	frame.root.Rotation = t.tilt * 0.6
	local img = resolveImage(p.portrait)
	if img ~= "" then
		mk("ImageLabel", {
			BackgroundTransparency = 1,
			Image = img,
			Position = UDim2.fromOffset(8, 8),
			Size = UDim2.new(1, -16, 1, -16),
			ScaleType = Enum.ScaleType.Crop,
		}, frame.root)
	else
		text(frame.root, t, { role = "display", text = string.sub(speaker or "?", 1, 1), textSize = 96, color = WHITE })
	end
	if speaker and speaker ~= "" then
		local np = plate(self.namePlateHolder, t, { size = V2(300, 50), fill = color })
		np.root.Rotation = t.tilt * 0.5
		text(np.root, t, { role = "heading", text = speaker, textSize = 28, color = WHITE })
		local s2 = mk("UIScale", { Scale = 0.6 }, np.root)
		tw(s2, { Scale = 1 }, 0.3, Enum.EasingStyle.Back)
	end
	self.text = s
	self.body_:set(s)
	local lab = self.body_.label
	local shadow = self.body_.shadow
	local n = utf8.len(s) or #s
	lab.MaxVisibleGraphemes = 0
	if shadow then
		shadow.MaxVisibleGraphemes = 0
	end
	self.typing = true
	local speed = p.speed or 45
	local ver = self._ver
	task.spawn(function()
		local shown = 0
		while shown < n and self._ver == ver and not self._dead do
			shown += 1
			lab.MaxVisibleGraphemes = shown
			if shadow then
				shadow.MaxVisibleGraphemes = shown
			end
			if shown % 3 == 0 then
				sfx("type", self)
			end
			local ch = string.sub(s, shown, shown)
			task.wait((ch == "." or ch == "!" or ch == "?" or ch == ",") and 6 / speed or 1 / speed)
		end
		if self._ver == ver and not self._dead then
			self:_finish()
		end
	end)
	return self
end
Dialog.set = Dialog.say
function Dialog:_finish()
	if not self.typing then
		return
	end
	self.typing = false
	self.body_.label.MaxVisibleGraphemes = -1
	if self.body_.shadow then
		self.body_.shadow.MaxVisibleGraphemes = -1
	end
	local p = self.p or {}
	if p.choices then
		local n = #p.choices
		for i, label in p.choices do
			local b = UIKit.button({
				parent = self.body,
				theme = self.t,
				text = label,
				kind = i == 1 and "primary" or "neutral",
				size = V2(340, 58),
				position = UDim2.new(1, -20, 0, 50 - (n - i + 1) * 74),
				anchor = V2(1, 0),
				onClick = function()
					if p.onChoice then
						p.onChoice(i, label)
					end
				end,
			})
			b._pop:snap(0.3)
			b._slide:snap(30)
			task.delay(0.06 * i, function()
				b._pop:to(1)
				b._slide:to(0)
			end)
			table.insert(self.choiceButtons, b)
		end
	end
end
-- skip(): finishes the line, or (when finished) calls onNext.
function Dialog:skip()
	if self.typing then
		self:_finish()
	elseif self.p and self.p.onNext and #self.choiceButtons == 0 then
		self.p.onNext()
	end
	return self
end
function Dialog:onDestroy()
	for _, b in self.choiceButtons do
		b:Destroy()
	end
end

-- ── prompt hint: key cap + label (screen or world-anchored) ─────────────────
local Prompt = class()
function UIKit.prompt(o)
	o = o or {}
	local t = o.theme or UIKit.current
	local bb
	if o.adornee then
		bb = mk("BillboardGui", {
			Name = "UIKitPrompt",
			Adornee = o.adornee,
			AlwaysOnTop = true,
			LightInfluence = 0,
			ResetOnSpawn = false,
			Size = UDim2.fromOffset(420 * Screen.scale(), 110 * Screen.scale()),
			StudsOffset = o.offset or Vector3.new(0, 3, 0),
			MaxDistance = o.maxDistance or 40,
		}, Players.LocalPlayer:WaitForChild("PlayerGui"))
		mk("UIScale", { Scale = Screen.scale() }, bb)
		o.parent = bb
		o.position = o.position or UDim2.fromScale(0.5, 0.5)
	end
	local self = setmetatable(newBase(o, 420, 90, UDim2.fromScale(0.5, 0.7), V2(0.5, 0.5), "Prompt"), Prompt)
	self.billboard = bb
	local ks = 64
	local lip = 6
	local capHolder = mk("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 10), Size = UDim2.fromOffset(ks, ks + lip) }, self.body)
	plate(capHolder, t, { size = V2(ks, ks), position = UDim2.fromOffset(0, lip), fill = darken(t.c.raisedBottom, 0.45), skew = 0, gloss = 0, rim = 0 })
	local face = mk("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(ks, ks) }, capHolder)
	plate(face, t, { size = V2(ks, ks), top = lighten(t.c.raisedTop, 0.25), bottom = t.c.raisedBottom, skew = 0, shadow = 0 })
	self.face = face
	self.key = text(face, t, { role = "heading", text = o.key or "E", textSize = 32 })
	self.capPress = self:spring(0, 34, 0.5, function(v)
		face.Position = UDim2.fromOffset(0, v)
	end)
	local lab = plate(self.body, t, { size = V2(300, 50), position = UDim2.fromOffset(ks + 4, 17), transparency = math.max(t.panelT, 0.1) })
	self.label = text(lab.root, t, {
		role = "heading",
		text = o.label or "Interact",
		textSize = 24,
		x = Enum.TextXAlignment.Left,
		position = UDim2.fromOffset(16 + lab.skewPx * 0.5, 0),
		size = UDim2.new(1, -24, 1, 0),
	})
	self.holdBar = mk("Frame", {
		BackgroundColor3 = t.c.accent,
		Position = UDim2.new(0, 10 + lab.skewPx * 0.5, 1, -7),
		Size = UDim2.fromOffset(0, 4),
	}, lab.root)
	self.holdW = 300 - 30 - lab.skewPx
	return self:_enter()
end
function Prompt:set(key, label)
	if key then
		self.key:set(key)
	end
	if label then
		self.label:set(label)
	end
	return self
end
-- progress(0..1) for hold-to-interact; press() squishes the key cap.
function Prompt:progress(p)
	self.holdBar.Size = UDim2.fromOffset(self.holdW * math.clamp(p, 0, 1), 4)
	return self
end
function Prompt:press()
	self.capPress.s.Position = 6
	self.capPress:to(0)
	sfx("click", self)
	return self
end
function Prompt:onDestroy()
	if self.billboard then
		self.billboard:Destroy()
	end
end

-- ── panel: menu screen with title plate, tabs, close X, backdrop ────────────
local Panel = class()
function UIKit.panel(o)
	o = o or {}
	local t = o.theme or UIKit.current
	local size = o.size or V2(960, 620)
	local backdrop = o.backdrop ~= false
	local self
	if backdrop then
		self = setmetatable(newBase(o, 0, 0, UDim2.fromScale(0.5, 0.5), V2(0.5, 0.5), "Panel"), Panel)
		self.root.Size = UDim2.fromScale(1, 1)
		self.root.Position = UDim2.fromScale(0.5, 0.5)
		self.body.Size = UDim2.fromOffset(size.X, size.Y)
		local dim = mk("Frame", { Name = "Backdrop", BackgroundColor3 = t.c.backdrop, BackgroundTransparency = 0.35, Size = UDim2.fromScale(1, 1), ZIndex = 0 }, self.root)
		mk("UIGradient", { Rotation = 90, Transparency = NumberSequence.new(0.2, 0.55) }, dim)
		for i = -8, 30 do -- diagonal stripe pattern
			mk("Frame", {
				BackgroundColor3 = t.c.accent,
				BackgroundTransparency = 0.94,
				AnchorPoint = V2(0.5, 0.5),
				Position = UDim2.new(0, i * 90, 0.5, 0),
				Size = UDim2.new(0, 26, 2, 0),
				Rotation = 30,
				ZIndex = 0,
			}, dim)
		end
		self.body.ZIndex = 1
	else
		self = setmetatable(newBase(o, size.X, size.Y, UDim2.fromScale(0.5, 0.5), V2(0.5, 0.5), "Panel"), Panel)
	end
	self.popFrom = 0.85
	local P = plate(self.body, t, { size = size, skew = 0, deco = true, radius = t.radius > 0 and t.radius + 6 or 0 })
	P.root.Size = UDim2.fromScale(1, 1)
	local titleW = math.max(260, #(o.title or "MENU") * 26 + 80)
	local title = plate(self.body, t, { size = V2(titleW, 64), fill = t.c.accent, position = UDim2.fromOffset(-14, -30) })
	title.root.Rotation = t.tilt
	text(title.root, t, {
		role = "display",
		text = o.title or "MENU",
		textSize = 40,
		gradient = ColorSequence.new(WHITE, lighten(t.c.accent, 0.6)),
		position = UDim2.fromOffset(title.skewPx * 0.5, 0),
	})
	-- close X overlapping the corner
	if o.onClose ~= false then
		local close = UIKit.button({
			parent = self.body,
			theme = t,
			text = "",
			kind = "danger",
			size = V2(64, 58),
			position = UDim2.new(1, 18, 0, -22),
			anchor = V2(1, 0),
			onClick = function()
				if o.onClose then
					o.onClose(self)
				else
					self:hide()
				end
			end,
		})
		local x = mk("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Rotation = 45 }, close.faceHolder)
		for _, sz in { UDim2.fromOffset(30, 8), UDim2.fromOffset(8, 30) } do
			local b = mk("Frame", { BackgroundColor3 = WHITE, AnchorPoint = V2(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = sz }, x)
			stroke(b, t.c.ink, 2, 0, true)
		end
		self.close = close
	end
	local top = 52
	self.pages = {}
	self.tabs = {}
	if o.tabs and #o.tabs > 0 then
		local tw_ = math.min(220, (size.X - 80) / #o.tabs - 10)
		for i, name in o.tabs do
			local b = UIKit.button({
				parent = self.body,
				theme = t,
				text = name,
				kind = "neutral",
				size = V2(tw_, 50),
				textSize = 22,
				position = UDim2.fromOffset(40 + (i - 1) * (tw_ + 10), top),
				anchor = V2(0, 0),
				onClick = function()
					self:select(name)
				end,
			})
			self.tabs[name] = b
		end
		self.ind = mk("Frame", { BackgroundColor3 = t.c.accent, Size = UDim2.fromOffset(tw_ - 20, 5), Position = UDim2.fromOffset(50, top + 62) }, self.body)
		corner(self.ind, 3)
		self.indX = self:spring(50, 26, 0.75, function(v)
			self.ind.Position = UDim2.fromOffset(v, top + 62)
		end)
		self.tabW = tw_
		top += 80
	end
	self.content = mk("Frame", {
		Name = "Content",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(32, top + 8),
		Size = UDim2.new(1, -64, 1, -top - 36),
	}, self.body)
	for _, name in o.tabs or {} do
		self.pages[name] = mk("Frame", { Name = name, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false }, self.content)
	end
	self.onTab = o.onTab
	if o.tabs and o.tabs[1] then
		self:select(o.tab or o.tabs[1], true)
	end
	return self:_enter()
end
-- select(tab): raises the tab, slides the indicator, swaps the page.
function Panel:select(name, instant)
	local t = self.t
	if not self.pages[name] then
		return self
	end
	local idx = 0
	for i, n in self.o.tabs do
		if n == name then
			idx = i
		end
		self.tabs[n]:set({ color = n == name and t.c.accent or t.c.raisedTop })
		self.pages[n].Visible = n == name
	end
	local x = 40 + (idx - 1) * (self.tabW + 10) + 10
	if instant then
		self.indX:snap(x)
	else
		self.indX:to(x)
		local page = self.pages[name]
		page.Position = UDim2.fromOffset(24, 0)
		tw(page, { Position = UDim2.fromOffset(0, 0) }, 0.25)
		self.tabs[name]:punch(0.12)
	end
	self.tab = name
	if self.onTab and not instant then
		task.spawn(self.onTab, name)
	end
	return self
end
function Panel:set(p)
	if p.tab then
		self:select(p.tab)
	end
	return self
end

-- ── grid / hotbar: slots with rarity, counts, selection ─────────────────────
local Grid = class()
function UIKit.grid(o)
	o = o or {}
	local t = o.theme or UIKit.current
	local cols = o.columns or 5
	local items = o.items or {}
	local rows = o.rows or math.max(1, math.ceil(math.max(#items, o.slots or 0) / cols))
	local slot = o.slot or (o.hotbar and (UIKit.compact() and 80 or 92) or 100)
	local gap = o.gap or 12
	local w, h = cols * slot + (cols - 1) * gap, rows * slot + (rows - 1) * gap
	local self = setmetatable(newBase(o, w + 20, h + 20, UDim2.fromScale(0.5, 0.5), V2(0.5, 0.5), o.hotbar and "Hotbar" or "Grid"), Grid)
	self.cols, self.rows, self.slotSize, self.gap = cols, rows, slot, gap
	self.slots = {}
	self.onSelect = o.onSelect
	self.hotbar = o.hotbar
	local sel = mk("Frame", { Name = "Selector", BackgroundTransparency = 1, Size = UDim2.fromOffset(slot + 14, slot + 14), AnchorPoint = V2(0.5, 0.5), ZIndex = 3 }, self.body)
	corner(sel, t.radius > 0 and t.radius + 6 or 0)
	stroke(sel, t.c.accent, 4, 0, true)
	local selGlow = stroke(mk("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 8, 1, 8), Position = UDim2.fromOffset(-4, -4) }, sel), t.c.accent, 3, 0.6, true)
	corner(selGlow.Parent, t.radius > 0 and t.radius + 10 or 0)
	sel.Visible = false
	self.sel = sel
	self.selX = self:spring(0, 30, 0.7, function(v)
		sel.Position = UDim2.fromOffset(v, sel.Position.Y.Offset)
	end)
	self.selY = self:spring(0, 30, 0.7, function(v)
		sel.Position = UDim2.fromOffset(sel.Position.X.Offset, v)
	end)
	for i = 1, cols * rows do
		self:_slot(i)
	end
	self:set(items)
	if o.hotbar and o.bindKeys ~= false then
		local keys = { Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three, Enum.KeyCode.Four, Enum.KeyCode.Five,
			Enum.KeyCode.Six, Enum.KeyCode.Seven, Enum.KeyCode.Eight, Enum.KeyCode.Nine }
		self:on(UserInputService.InputBegan, function(input, processed)
			if processed then
				return
			end
			local idx = table.find(keys, input.KeyCode)
			if idx and idx <= #self.slots then
				self:select(idx, true)
			end
		end)
	end
	if o.selected then
		self:select(o.selected)
	end
	return self:_enter()
end
function Grid:_slot(i)
	local s, gap = self.slotSize, self.gap
	local c, r = (i - 1) % self.cols, math.floor((i - 1) / self.cols)
	local cx, cy = 10 + c * (s + gap) + s / 2, 10 + r * (s + gap) + s / 2
	local holder = mk("Frame", { BackgroundTransparency = 1, AnchorPoint = V2(0.5, 0.5), Position = UDim2.fromOffset(cx, cy), Size = UDim2.fromOffset(s, s) }, self.body)
	local scale = mk("UIScale", {}, holder)
	local slot: any = { holder = holder, cx = cx, cy = cy }
	slot.pop = self:spring(1, 28, 0.5, function(v)
		scale.Scale = v
	end)
	local hit = mk("TextButton", { Text = "", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), AutoButtonColor = false, ZIndex = 4 }, holder)
	self:on(hit.Activated, function()
		self:select(i, true)
	end)
	self:on(hit.MouseEnter, function()
		if self.selected ~= i then
			slot.pop:to(1.05)
		end
	end)
	self:on(hit.MouseLeave, function()
		if self.selected ~= i then
			slot.pop:to(1)
		end
	end)
	self.slots[i] = slot
	return slot
end
function Grid:_fill(i, item)
	local t = self.t
	local slot = self.slots[i]
	if not slot then
		return
	end
	if slot.content then
		slot.content:Destroy()
	end
	local s = self.slotSize
	local content = mk("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, slot.holder)
	slot.content = content
	slot.item = item
	local rc = item and rarityColor(t, item.rarity) or nil
	plate(content, t, {
		size = V2(s, s),
		skew = 0,
		top = item and t.c.raisedTop:Lerp(rc, 0.25) or t.c.track,
		bottom = item and t.c.panelBottom:Lerp(rc, 0.55) or lighten(t.c.track, 0.06),
		outline = item and darken(rc, 0.55) or t.c.ink,
		shadow = item and t.shadow or 0,
		radius = t.radius > 0 and math.min(t.radius, 16) or 0,
		transparency = item and t.panelT or math.max(t.panelT, 0.25),
		gloss = item and t.gloss or 0,
	})
	if item then
		local strip = mk("Frame", { BackgroundColor3 = rc, AnchorPoint = V2(0.5, 1), Position = UDim2.new(0.5, 0, 1, -5), Size = UDim2.new(1, -14, 0, 5) }, content)
		corner(strip, 3)
		local img = resolveImage(item.icon)
		if img ~= "" then
			mk("ImageLabel", {
				BackgroundTransparency = 1,
				Image = img,
				AnchorPoint = V2(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.47),
				Size = UDim2.fromScale(0.72, 0.72),
				ScaleType = Enum.ScaleType.Fit,
			}, content)
		else
			text(content, t, {
				role = "display",
				text = item.glyph or string.sub(item.name or "?", 1, 2),
				textSize = math.floor(s * 0.36),
				color = WHITE,
				gradient = ColorSequence.new(WHITE, lighten(rc, 0.4)),
				position = UDim2.fromScale(0.5, 0.45),
				anchor = V2(0.5, 0.5),
				size = UDim2.fromScale(1, 0.6),
				stroke = math.max(2, t.textStroke - 1),
				shadow = 3,
			})
		end
		if item.count and item.count ~= 1 then
			slot.countText = text(content, t, {
				role = "numeric",
				text = "x" .. fmtNum(item.count),
				textSize = math.floor(s * 0.22),
				x = Enum.TextXAlignment.Right,
				y = Enum.TextYAlignment.Bottom,
				position = UDim2.fromOffset(-8, -10),
				size = UDim2.fromScale(1, 1),
				stroke = 2,
				shadow = 0,
			})
		end
	end
	if self.hotbar then
		text(content, t, {
			role = "numeric",
			text = tostring(i),
			textSize = math.floor(s * 0.2),
			color = t.c.textDim,
			x = Enum.TextXAlignment.Left,
			y = Enum.TextYAlignment.Top,
			position = UDim2.fromOffset(8, 6),
			size = UDim2.fromOffset(30, 24),
			stroke = 2,
			shadow = 0,
		})
	end
end
-- set(items): items = {{name, icon?, glyph?, count?, rarity = "common".."mythic" | Color3}}
function Grid:set(items)
	for i = 1, #self.slots do
		self:_fill(i, items[i])
	end
	return self
end
function Grid:setItem(i, item)
	self:_fill(i, item)
	local slot = self.slots[i]
	if slot then
		slot.pop.s.Position = 1.25
		slot.pop:to(self.selected == i and 1.1 or 1)
	end
	return self
end
-- select(index, fromInput?): selector springs over, slot lifts.
function Grid:select(i, fromInput)
	local slot = self.slots[i]
	if not slot then
		return self
	end
	local prev = self.slots[self.selected or 0]
	if prev and self.selected ~= i then
		prev.pop:to(1)
	end
	self.selected = i
	local first = not self.sel.Visible
	self.sel.Visible = true
	if first then
		self.selX:snap(slot.cx)
		self.selY:snap(slot.cy)
	else
		self.selX:to(slot.cx)
		self.selY:to(slot.cy)
	end
	slot.pop.s.Position = 1.2
	slot.pop:to(1.1)
	sfx("click", self)
	if fromInput and self.onSelect then
		task.spawn(self.onSelect, i, slot.item)
	end
	return self
end
function UIKit.hotbar(o)
	o = o or {}
	o.hotbar = true
	o.columns = o.columns or math.max(#(o.items or {}), o.slots or 6)
	o.rows = 1
	o.position = o.position or UDim2.new(0.5, 0, 1, -24)
	o.anchor = o.anchor or V2(0.5, 1)
	o.selected = o.selected or 1
	return UIKit.grid(o)
end

-- ── shop card: art window, rarity, ribbon badge, price button ───────────────
local Card = class()
function UIKit.shopCard(o)
	o = o or {}
	local t = o.theme or UIKit.current
	local w, h = 270, 380
	local self = setmetatable(newBase(o, w, h, UDim2.fromScale(0.5, 0.5), V2(0.5, 0.5), "ShopCard"), Card)
	local rc = rarityColor(t, o.rarity)
	self.rc = rc
	plate(self.body, t, { size = V2(w, h), skew = 0, top = t.c.raisedTop, bottom = t.c.panelBottom, radius = t.radius > 0 and t.radius + 4 or 0 })
	local art = plate(self.body, t, {
		size = V2(w - 24, 220),
		position = UDim2.fromOffset(12, 12),
		skew = 0,
		top = lighten(rc, 0.15),
		bottom = darken(rc, 0.45),
		shadow = 0,
		stroke = math.max(2, t.stroke - 1),
		radius = t.radius,
	})
	for i, tr in { 0.55, 0.72, 0.85 } do -- radial glow from stacked discs
		local g = mk("Frame", {
			BackgroundColor3 = lighten(rc, 0.6),
			BackgroundTransparency = tr,
			AnchorPoint = V2(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(70 + i * 45, 70 + i * 45),
		}, art.root)
		corner(g, UDim.new(1, 0))
	end
	local img = resolveImage(o.icon)
	local artHolder = mk("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, art.root)
	self.artScale = mk("UIScale", {}, artHolder)
	if img ~= "" then
		mk("ImageLabel", {
			BackgroundTransparency = 1,
			Image = img,
			AnchorPoint = V2(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.52),
			Size = UDim2.fromScale(0.85, 0.85),
			ScaleType = Enum.ScaleType.Fit,
		}, artHolder)
	else
		text(artHolder, t, {
			role = "display",
			text = o.glyph or string.sub(o.name or "?", 1, 1),
			textSize = 120,
			gradient = ColorSequence.new(WHITE, lighten(rc, 0.5)),
			position = UDim2.fromScale(0.5, 0.52),
			anchor = V2(0.5, 0.5),
			size = UDim2.fromScale(1, 0.8),
		})
	end
	local rplate = plate(art.root, t, { size = V2(120, 28), fill = rc, shadow = 0, position = UDim2.fromOffset(10, 10), stroke = 2 })
	text(rplate.root, t, { role = "heading", text = o.rarity and tostring(o.rarity) or "common", textSize = 15, color = WHITE, stroke = 2, shadow = 0 })
	if o.badge then
		local b = plate(self.body, t, { size = V2(120, 40), fill = t.c.bad, position = UDim2.new(1, 22, 0, -12), anchor = V2(1, 0) })
		b.root.Rotation = 12
		text(b.root, t, { role = "heading", text = o.badge, textSize = 22, color = WHITE })
		self.badge = b
	end
	self.nameText = text(self.body, t, {
		role = "heading",
		text = o.name or "Item",
		textSize = 26,
		position = UDim2.fromOffset(0, 238),
		size = UDim2.new(1, 0, 0, 34),
		truncate = true,
	})
	self.onBuy = o.onBuy
	self.price = o.price or 100
	self.currency = o.currency or "$"
	self.buy = UIKit.button({
		parent = self.body,
		theme = t,
		text = self.currency .. " " .. fmtNum(self.price),
		kind = "good",
		size = V2(w - 40, 62),
		textSize = 26,
		position = UDim2.new(0.5, 0, 1, -14),
		anchor = V2(0.5, 1),
		onClick = function()
			if self.onBuy and not self.owned then
				self.onBuy(self)
			end
		end,
	})
	local hover = mk("TextButton", { Text = "", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 280), AutoButtonColor = false }, self.body)
	self.tiltS = self:spring(0, 20, 0.5, function(v)
		self.body.Rotation = v
	end)
	self:on(hover.MouseEnter, function()
		self._slide:to(-8)
		self.tiltS:to(-1.5)
		self.artScale.Scale = 1.08
		sfx("hover", self)
	end)
	self:on(hover.MouseLeave, function()
		self._slide:to(0)
		self.tiltS:to(0)
		self.artScale.Scale = 1
	end)
	self:set({ owned = o.owned, affordable = o.affordable })
	return self:_enter()
end
-- set({price, owned, affordable})
function Card:set(p)
	if p.price then
		self.price = p.price
	end
	if p.owned ~= nil then
		self.owned = p.owned
	end
	if p.affordable ~= nil then
		self.affordable = p.affordable
	end
	if self.owned then
		self.buy:set({ text = "OWNED", kind = "neutral", enabled = false })
	else
		self.buy:set({ text = self.currency .. " " .. fmtNum(self.price), kind = "good", enabled = self.affordable ~= false })
	end
	return self
end

-- ── results: banner, staggered stat rows with count-up, rank stamp, rewards ─
local Results = class()
function UIKit.results(o)
	o = o or {}
	local self = setmetatable(newBase(o, 0, 0, UDim2.fromScale(0.5, 0.5), V2(0.5, 0.5), "Results"), Results)
	self.root.Size = UDim2.fromScale(1, 1)
	self.popFrom = 1
	self.slideFrom = 0
	self:set(o)
	return self:_enter()
end
-- set({title, sub, stats = {{label, value, format?}}, rank, rewards = {{glyph|icon, count, color}}, buttons = {{text, kind, onClick}}})
function Results:set(o)
	local t = self.t
	self._ver += 1
	for _, c in self.body:GetChildren() do
		if not c:IsA("UIScale") then
			c:Destroy()
		end
	end
	for _, b in self._buttons or {} do
		b:Destroy()
	end
	self._buttons = {}
	self.spec = o
	local dim = mk("Frame", { Name = "Backdrop", BackgroundColor3 = t.c.backdrop, BackgroundTransparency = 0.25, Size = UDim2.fromScale(1, 1) }, self.body)
	mk("UIGradient", { Rotation = 90, Transparency = NumberSequence.new(0.1, 0.5) }, dim)
	for i = -8, 30 do
		mk("Frame", {
			BackgroundColor3 = o.color or t.c.accent,
			BackgroundTransparency = 0.93,
			AnchorPoint = V2(0.5, 0.5),
			Position = UDim2.new(0, i * 90, 0.5, 0),
			Size = UDim2.new(0, 26, 2, 0),
			Rotation = 30,
		}, dim)
	end
	local center = mk("Frame", { BackgroundTransparency = 1, AnchorPoint = V2(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(1100, 860) }, self.body)
	self.center = center
	local title = text(center, t, {
		role = "display",
		text = o.title or "VICTORY",
		textSize = 130,
		gradient = ColorSequence.new(t.c.dispTop, o.color or t.c.gold),
		position = UDim2.new(0.5, 0, 0, 90),
		anchor = V2(0.5, 0.5),
		size = UDim2.fromOffset(1100, 150),
		rotation = t.tilt,
	})
	self.titleScale = mk("UIScale", { Scale = 0 }, title.holder)
	if o.sub then
		text(center, t, { role = "heading", text = o.sub, textSize = 30, color = t.c.textDim, position = UDim2.new(0.5, 0, 0, 175), anchor = V2(0.5, 0.5), size = UDim2.fromOffset(900, 40) })
	end
	local stats = o.stats or {}
	local rowH = 64
	local panelH = #stats * (rowH + 10) + 30
	local panel = plate(center, t, { size = V2(640, panelH), position = UDim2.fromOffset(100, 220), deco = true })
	self.rows = {}
	for i, st in stats do
		local row = mk("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(30, 15 + (i - 1) * (rowH + 10)), Size = UDim2.new(1, -60, 0, rowH), Visible = false }, panel.root)
		text(row, t, { role = "heading", text = st.label or st[1] or "", textSize = 28, x = Enum.TextXAlignment.Left, color = t.c.textDim, stroke = math.min(2, t.textStroke), shadow = 2 })
		local v = text(row, t, { role = "numeric", text = "0", textSize = 40, x = Enum.TextXAlignment.Right })
		mk("Frame", { BackgroundColor3 = t.c.text, BackgroundTransparency = 0.88, AnchorPoint = V2(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 2) }, row)
		self.rows[i] = { row = row, v = v, st = st }
	end
	if o.rank then
		local stamp = mk("Frame", { BackgroundTransparency = 1, AnchorPoint = V2(0.5, 0.5), Position = UDim2.fromOffset(900, 220 + panelH * 0.45), Size = UDim2.fromOffset(240, 240), Rotation = -12, Visible = false }, center)
		local disc = iconDisc(stamp, t, { size = 230, glyph = "", color = o.rankColor or t.c.gold, position = UDim2.fromScale(0.5, 0.5), anchor = V2(0.5, 0.5) })
		text(disc.root, t, { role = "display", text = tostring(o.rank), textSize = #tostring(o.rank) > 1 and 96 or 150, gradient = ColorSequence.new(WHITE, lighten(o.rankColor or t.c.gold, 0.5)) })
		text(stamp, t, { role = "heading", text = o.rankLabel or "RANK", textSize = 26, position = UDim2.new(0.5, 0, 1, 10), anchor = V2(0.5, 0), size = UDim2.fromOffset(240, 30) })
		self.stamp = stamp
		self.stampScale = mk("UIScale", {}, stamp)
	end
	self.rewards = {}
	local rewards = o.rewards or {}
	local rw = 150
	local ry = 220 + panelH + 30
	for i, r in rewards do
		local chip = mk("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(100 + (i - 1) * (rw + 16), ry), Size = UDim2.fromOffset(rw, 70), Visible = false }, center)
		plate(chip, t, { size = V2(rw, 64), top = t.c.raisedTop, bottom = t.c.raisedBottom })
		iconDisc(chip, t, { size = 58, image = r.icon, glyph = r.glyph or "*", color = r.color or t.c.gold, position = UDim2.fromOffset(-8, 3) })
		text(chip, t, { role = "numeric", text = "+" .. fmtNum(r.count or 1), textSize = 30, position = UDim2.fromOffset(56, 0), size = UDim2.new(1, -60, 0, 64) })
		self.rewards[i] = { chip = chip, scale = mk("UIScale", {}, chip) }
	end
	self.buttonsY = ry + (#rewards > 0 and 100 or 10)
	return self
end
function Results:onShow()
	local t = self.t
	local o = self.spec or {}
	local ver = self._ver
	local function alive()
		return not self._dead and self._ver == ver and self._shown
	end
	self.titleScale.Scale = 2.4
	tw(self.titleScale, { Scale = 1 }, 0.45, Enum.EasingStyle.Back)
	sfx("banner", self)
	task.spawn(function()
		task.wait(0.4)
		for _, r in self.rows do
			if not alive() then
				return
			end
			r.row.Visible = true
			r.row.Position += UDim2.fromOffset(-40, 0)
			tw(r.row, { Position = r.row.Position + UDim2.fromOffset(40, 0) }, 0.3, Enum.EasingStyle.Back)
			local value = r.st.value or r.st[2] or 0
			if type(value) == "number" then
				local start = os.clock()
				local fmt = r.st.format
				while alive() do
					local a = math.clamp((os.clock() - start) / 0.5, 0, 1)
					r.v:set(fmtNum(math.floor(value * (1 - (1 - a) ^ 3) + 0.5), fmt))
					if a >= 1 then
						break
					end
					task.wait()
				end
			else
				r.v:set(tostring(value))
			end
			sfx("tick", self)
			task.wait(0.08)
		end
		if self.stamp and alive() then
			task.wait(0.15)
			self.stamp.Visible = true
			self.stampScale.Scale = 3
			tw(self.stampScale, { Scale = 1 }, 0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			task.wait(0.22)
			sfx("stamp", self)
			local s = self:spring(0, 40, 0.3, function(v)
				self.center.Position = UDim2.new(0.5, v, 0.5, v * 0.5)
			end)
			s:kick(300)
		end
		for _, r in self.rewards do
			if not alive() then
				return
			end
			r.chip.Visible = true
			r.scale.Scale = 0.2
			tw(r.scale, { Scale = 1 }, 0.35, Enum.EasingStyle.Back)
			sfx("pop", self)
			task.wait(0.1)
		end
		if not alive() then
			return
		end
		for i, b in o.buttons or {} do
			local btn = UIKit.button({
				parent = self.center,
				theme = t,
				text = b.text or b[1],
				kind = b.kind or (i == 1 and "primary" or "neutral"),
				size = V2(300, 72),
				position = UDim2.fromOffset(100 + (i - 1) * 320, self.buttonsY),
				anchor = V2(0, 0),
				onClick = b.onClick,
			})
			table.insert(self._buttons, btn)
			task.wait(0.08)
		end
	end)
end
function Results:onDestroy()
	for _, b in self._buttons or {} do
		b:Destroy()
	end
end

-- ── world popups: damage numbers and floating "+1" ──────────────────────────
local function anchorFor(at)
	if typeof(at) == "Instance" then
		if at:IsA("BasePart") or at:IsA("Attachment") then
			return at, nil
		elseif at:IsA("Model") then
			local p = at.PrimaryPart or at:FindFirstChildWhichIsA("BasePart", true)
			if p then
				return p, nil
			end
		end
	end
	local pos = worldPos(at)
	if pos then
		local a = Instance.new("Attachment")
		a.Name = "UIKitAnchor"
		a.Parent = workspace.Terrain
		a.WorldPosition = pos
		return a, a
	end
	return nil, nil
end

local function worldText(at, s, o)
	local t = o.theme or UIKit.current
	local adornee, temp = anchorFor(at)
	if not adornee then
		return nil
	end
	local sc = Screen.scale()
	local big = o.big
	local bb = mk("BillboardGui", {
		Name = "UIKitPopup",
		Adornee = adornee,
		AlwaysOnTop = true,
		LightInfluence = 0,
		ResetOnSpawn = false,
		Size = UDim2.fromOffset(320 * sc, 140 * sc),
		StudsOffset = Vector3.new(0, 1.5, 0),
		MaxDistance = 250,
	}, Players.LocalPlayer:WaitForChild("PlayerGui"))
	local holder = mk("Frame", { BackgroundTransparency = 1, AnchorPoint = V2(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(320, 140) }, bb)
	local scale = mk("UIScale", { Scale = 0.2 * sc }, holder)
	local L = text(holder, t, {
		role = "numeric",
		text = s,
		textSize = o.textSize or (big and 72 or 46),
		gradient = ColorSequence.new(lighten(o.color, 0.55), o.color),
		rotation = big and (math.random() * 16 - 8) or 0,
		stroke = math.max(3, t.textStroke),
		shadow = 4,
	})
	if o.tag then
		text(holder, t, {
			role = "heading",
			text = o.tag,
			textSize = 26,
			color = WHITE,
			position = UDim2.new(0.5, 0, 0, 6),
			anchor = V2(0.5, 0),
			size = UDim2.fromOffset(200, 30),
			stroke = 3,
		})
	end
	tw(scale, { Scale = (big and 1.15 or 1) * sc }, 0.22, Enum.EasingStyle.Back)
	local dx = (math.random() - 0.5) * 2.2
	tw(bb, { StudsOffset = Vector3.new(dx, big and 3.4 or 2.8, 0) }, 0.9, Enum.EasingStyle.Quad)
	task.delay(0.55, function()
		for _, d in holder:GetDescendants() do
			if d:IsA("TextLabel") then
				tw(d, { TextTransparency = 1 }, 0.3)
			elseif d:IsA("UIStroke") then
				tw(d, { Transparency = 1 }, 0.3)
			end
		end
		tw(scale, { Scale = 0.6 * sc }, 0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	end)
	task.delay(0.95, function()
		bb:Destroy()
		if temp then
			temp:Destroy()
		end
	end)
	return L
end

-- damage(at = Vector3 | BasePart | Model, amount, {kind = "normal"|"crit"|"heal"|"block"|"miss", color})
function UIKit.damage(at, amount, o)
	o = o or {}
	local t = o.theme or UIKit.current
	local kind = o.kind or "normal"
	local color = o.color or ({ normal = WHITE, crit = t.c.warn, heal = t.c.good, block = t.c.textDim, miss = t.c.textDim })[kind] or WHITE
	local s = kind == "miss" and "MISS" or (kind == "heal" and "+" or "") .. fmtNum(amount or 0)
	return worldText(at, s, { theme = t, color = color, big = kind == "crit", tag = kind == "crit" and "CRIT!" or nil })
end

-- popup(text, {at = Vector3 | BasePart | GuiObject | UDim2, color, offset = Vector2, parent}): a floating "+1".
function UIKit.popup(s, o)
	o = o or {}
	local t = o.theme or UIKit.current
	local color = o.color or t.c.good
	local at = o.at
	if typeof(at) == "Vector3" or (typeof(at) == "Instance" and not at:IsA("GuiObject")) then
		return worldText(at, s, { theme = t, color = color, textSize = o.textSize or 40 })
	end
	local parent = o.parent or UIKit.layer()
	local pos = UDim2.fromScale(0.5, 0.5)
	if typeof(at) == "UDim2" then
		pos = at
	elseif typeof(at) == "Instance" and at:IsA("GuiObject") then
		local sc = Screen.scale()
		local base = parent:IsA("GuiObject") and parent.AbsolutePosition or Vector2.zero
		local p = (at.AbsolutePosition - base) / sc + (o.offset or Vector2.new(at.AbsoluteSize.X / sc * 0.5, 0))
		pos = UDim2.fromOffset(p.X, p.Y)
	end
	local holder = mk("Frame", { BackgroundTransparency = 1, AnchorPoint = V2(0.5, 0.5), Position = pos, Size = UDim2.fromOffset(240, 60), ZIndex = 10 }, parent)
	local scale = mk("UIScale", { Scale = 0.3 }, holder)
	text(holder, t, { role = "numeric", text = s, textSize = o.textSize or 34, gradient = ColorSequence.new(lighten(color, 0.55), color), stroke = math.max(2, t.textStroke) })
	tw(scale, { Scale = 1 }, 0.25, Enum.EasingStyle.Back)
	tw(holder, { Position = pos + UDim2.fromOffset(0, -70) }, 0.8, Enum.EasingStyle.Quad)
	task.delay(0.5, function()
		for _, d in holder:GetDescendants() do
			if d:IsA("TextLabel") then
				tw(d, { TextTransparency = 1 }, 0.3)
			elseif d:IsA("UIStroke") then
				tw(d, { Transparency = 1 }, 0.3)
			end
		end
	end)
	task.delay(0.85, function()
		holder:Destroy()
	end)
	return holder
end

return UIKit
