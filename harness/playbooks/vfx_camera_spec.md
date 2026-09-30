# VFX and camera kit: reference

`Kit.VFX` and `Kit.CameraRig` (client) have no look of their own: colours, sizes and timings come from you (Tokens).
Colours: `Color3`, `"#RRGGBB"` or `"Tokens.color.<name>"`. Bad values become one `[VFX]` / `[CameraRig]` warning
naming your script, and a default is used.

## VFX
- `VFX.preset(name, spec)` once; `VFX.play(name, at, opts) -> h`; `VFX.effect(spec, at, opts) -> h`. h: `:stop()`
  (ends continuous layers), `:destroy()`, `:andThen(fn)`, `.alive`.
- `at`: Vector3, CFrame (+Y = the effect's up, -Z = forward), part, Attachment (followed) or Model. `opts`: `scale`
  (sizes, speeds), `intensity` (counts, light), `normal` (up, e.g. a hit's normal), `direction` (forward), `follow`,
  `timeScaled` (slows with slow-mo, default true), `onDone`.
- spec: `{ layers = {...}, family, budget = { effects, particles, lights } }` (over budget: the oldest effect goes).
  Every layer: `kind`, `delay` (seconds: anticipation -> impact -> dissipation), `offset` (Vector3).
- `particles`: `count` (burst) or `rate` + `duration`; `lifetime`, `speed`, `rotation`, `rotSpeed` (n or {min, max});
  `spread` (deg or {x, y}); `size`, `transparency`, `squash` (keypoints); `color` (colours); `lightEmission`,
  `lightInfluence`, `brightness`, `drag`, `acceleration` (Vector3), `orientation` (facing, facingUp, parallel,
  perpendicular), `direction` (up, down, forward, back, left, right), `zoffset`, `texture`, `flipbook` {layout
  "4x4", mode, fps, random}, `shape` {kind sphere/box/disc/cylinder, size, style, inOut, partial}, `lockedToPart`.
- `beam`: `to` (Vector3 offset, part or attachment), `from`, `width` ({w0, w1}: two numbers, start and end width, e.g. `width = {0.3, 0.05}`; never `{start=, end=}`: `end` is a Luau keyword), `color`, `transparency`,
  `curve` (bows toward up), `texture`, `textureSpeed`, `textureLength`, `textureMode`, `segments`, `faceCamera`,
  `lightEmission`, `brightness`, `duration`, `fadeOut`.
- `light`: `color`, `brightness`, `range` (max 60), `duration`, `attack`, `shadows`, `spot` {angle, face}.
- `flash` (a neon/forcefield sphere, block or mesh that scales and fades): `shape`, `mesh`, `meshTexture`,
  `material`, `color`, `size` {from, to}, `transparency` {from, to}, `duration`, `ease`, `spin`.
- `ring`: with `texture` a crisp flat particle, else a forcefield disc: `size` {from, to} (diameters), `thickness`,
  `color`, `transparency`, `duration`, `ease`, `flat`, `lightEmission`, `brightness`, `material`.
- `decal` (scorch, crack): `texture`, `size` {from, to}, `color`, `transparency`, `duration`, `fade`, `grow`,
  `rotation` (random in {min, max}).
- Keypoints: `0.5`, `{0, 1}` (spread over the life) or `{{0, 0}, {0.1, 1}, {1, 0}}` ({time, value}); at most 20.
  Easing: `"Quint Out"`, `"Sine InOut"`. Textures: a content id or a painted / generated texture name.
- `VFX.flashLight(at, color, brightness, range, s)`; `VFX.screenFlash(color, s, strength)`; `VFX.vignette(color,
  s, {strength, thickness})` -> `:stop()` (s = nil: until stopped); `VFX.hitstop(s)` (pauses your character's
  animations, holds CameraRig time); `VFX.trail(part, {width, lifetime, color, transparency, widthScale})` ->
  `:burst(s)`, `:enable(on)`; `VFX.validate(spec)`; Debug command `__vfx <preset>` plays one before the camera.

## CameraRig
- `CameraRig.follow(opts) -> rig` (`rig:set(opts)` eases over, `:switchShoulder()`, `:setAngles(yaw, pitch)`,
  `:stop()`). Presets `shoulder`, `overTheTop`, `sideScroller`, `topDown`. Options: `distance`, `height`, `offset`
  (Vector3 right, up), `fov`, `pitch`, `yaw`, `pitchMin/Max`, `orbit` ("free" mouse-lock, "drag", "locked"),
  `lookAhead` (studs of lead room), `speedFov` {from, to, fov, pull}, `speed`, `verticalSpeed` (lower: jumps lag),
  `collision`, `autoAlign` (seconds), `zoom` {min, max, step}, `sensitivity`, `subject`, `ignore`, `blend`, `input`.
- `CameraRig.shot(shot)` / `CameraRig.sequence({shot, ...}, {letterbox, skipInput, lockControls, onDone})` -> h
  (`:andThen(fn)`, `:await()`, `:skip()`, `:cancel()`). A shot: `{from = CFrame | "current", to = CFrame}`,
  `{path = {Vector3...}, lookAt = target}` or `{orbit = {target, radius, height, from, to}}` (degrees, 0 = behind),
  plus `duration`, `hold`, `ease`, `fov` (n or {from, to}), `roll`, `handheld`, `relativeTo` (positions in that
  part's space), `lookOffset`, `blendIn` (0 = cut), `blendOut`, `letterbox`, `slowmo` (scale or {scale, seconds,
  rampIn, rampOut}), `onStart(i)`.
- `CameraRig.kick(fovDegrees, s)`, `CameraRig.punch(direction, studs)`, `CameraRig.shake(trauma)`,
  `CameraRig.slowmo(scale, s)`; others read `CameraRig.timeScale`; player attribute `KitCinematic` is true during
  shots (hide the HUD). `Shake.reduceMotion` turns kicks, punches and handheld off.

```lua
local CameraRig = require(game:GetService("ReplicatedStorage").Kit.CameraRig)
local rig = CameraRig.follow({ preset = "overTheTop", distance = 16, fov = 70, lookAhead = 3, autoAlign = 1.5,
	speedFov = { from = 16, to = 40, fov = 8, pull = 2 } })
```

## Taste rules
- Impact: a strong first frame within 1-3 frames (flash + light), secondaries, then dissipation; fast in, slow out;
  lifetimes as ranges, gone within ~1 s. A value hierarchy: bright core, body colour, a darker contrast layer.
- Size, transparency and colour change over life; one emitter is a 4 at best.
- Scale feedback by magnitude (`intensity`, kick, shake); hitstop (40-120 ms), shake and slow-mo on payoffs only.
- FOV widens with speed and kicks on dashes; cutscenes: authored shots, letterbox, skippable, blended back.

## Example 1: impact (glint -> core flash -> sparks -> smoke, light pulse, camera kick)
```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VFX = require(ReplicatedStorage.Kit.VFX)
local CameraRig = require(ReplicatedStorage.Kit.CameraRig)
local Tokens = require(ReplicatedStorage.Shared.Tokens)

VFX.preset("impact", { budget = { effects = 6, particles = 300, lights = 2 }, layers = {
	{ kind = "flash", color = Tokens.color.highlight, size = { 0.3, 1.6 }, transparency = { 0.2, 1 }, duration = 0.05 },
	{ kind = "flash", delay = 0.03, color = Tokens.color.primary, size = { 1, 5 }, transparency = { 0, 1 }, duration = 0.12 },
	{ kind = "light", delay = 0.03, color = Tokens.color.primary, brightness = 5, range = 16, duration = 0.25 },
	{ kind = "ring", delay = 0.03, size = { 1, 9 }, color = Tokens.color.primary, transparency = { 0.2, 1 }, duration = 0.3 },
	{ kind = "particles", delay = 0.03, count = 18, lifetime = { 0.15, 0.35 }, speed = { 35, 60 }, spread = 70,
		size = { { 0, 0.35 }, { 1, 0 } }, transparency = { { 0, 0 }, { 0.8, 0.2 }, { 1, 1 } },
		color = { Tokens.color.highlight, Tokens.color.primary }, lightEmission = 1, drag = 6,
		acceleration = Vector3.new(0, -40, 0), orientation = "parallel", texture = "spark" },
	{ kind = "particles", delay = 0.06, count = 6, lifetime = { 0.6, 1.1 }, speed = { 2, 5 }, spread = 180,
		size = { { 0, 1 }, { 1, 3.5 } }, transparency = { { 0, 0.45 }, { 1, 1 } }, color = Tokens.color.shadow,
		rotation = { 0, 360 }, rotSpeed = { -40, 40 }, texture = "smoke_puff" },
} })

local function onHit(result: RaycastResult, damage: number)
	local k = math.clamp(damage / 50, 0.5, 1.5)
	VFX.play("impact", result.Position, { normal = result.Normal, intensity = k, scale = 0.8 + 0.2 * k })
	CameraRig.kick(3 * k, 0.2)
	CameraRig.punch(-result.Normal, 0.3 * k)
	if damage >= 40 then -- only the top tier earns hitstop and shake
		VFX.hitstop(0.07)
		CameraRig.shake(0.35)
	end
end
```

## Example 2: pickup / reward sparkle
```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VFX = require(ReplicatedStorage.Kit.VFX)
local Motion = require(ReplicatedStorage.Kit.Motion)
local Tokens = require(ReplicatedStorage.Shared.Tokens)

VFX.preset("pickup", { layers = {
	{ kind = "flash", color = Tokens.color.reward, size = { 0.5, 3 }, transparency = { 0.1, 1 }, duration = 0.15 },
	{ kind = "ring", size = { 0.5, 5 }, color = Tokens.color.reward, transparency = { 0.3, 1 }, duration = 0.35,
		texture = "ring_soft", flat = false },
	{ kind = "particles", count = 12, lifetime = { 0.4, 0.8 }, speed = { 4, 9 }, spread = 180,
		size = { { 0, 0 }, { 0.2, 0.5 }, { 1, 0 } }, color = { Tokens.color.reward, Tokens.color.text },
		lightEmission = 0.8, drag = 4, acceleration = Vector3.new(0, 6, 0), texture = "sparkle_star" },
	{ kind = "light", color = Tokens.color.reward, brightness = 3, range = 10, duration = 0.4, attack = 0.05 },
} })

local function collect(item: BasePart, value: number, label: TextLabel)
	local k = math.clamp(value / 100, 0.6, 2) -- bigger rewards, bigger feedback
	VFX.play("pickup", item.Position, { scale = k, intensity = k })
	Motion.punch(label, 0.1 * k)
end
```

## Example 3: dash trail with an FOV kick
```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VFX = require(ReplicatedStorage.Kit.VFX)
local CameraRig = require(ReplicatedStorage.Kit.CameraRig)
local Tokens = require(ReplicatedStorage.Shared.Tokens)

VFX.preset("dash_burst", { layers = {
	{ kind = "particles", count = 10, lifetime = { 0.15, 0.3 }, speed = { 20, 30 }, spread = 15, direction = "back",
		size = { { 0, 0.6 }, { 1, 0 } }, transparency = { 0.3, 1 }, color = Tokens.color.secondary,
		orientation = "parallel", texture = "streak" },
	{ kind = "ring", size = { 2, 7 }, color = Tokens.color.secondary, transparency = { 0.4, 1 }, duration = 0.25 },
} })

local function setupDash(character: Model)
	local root = character:WaitForChild("HumanoidRootPart")
	local trail = VFX.trail(root, { width = 2.5, lifetime = 0.22, color = { Tokens.color.secondary, Tokens.color.primary },
		transparency = { { 0, 0.2 }, { 1, 1 } }, widthScale = { { 0, 1 }, { 1, 0 } }, enabled = false })
	return function(direction: Vector3) -- call on each dash
		trail:burst(0.3)
		VFX.play("dash_burst", root, { direction = direction })
		CameraRig.kick(8, 0.35) -- speed without shake
	end
end
```

## Example 4: signature moment (three shots, letterbox, slow motion)
```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CameraRig = require(ReplicatedStorage.Kit.CameraRig)
local VFX = require(ReplicatedStorage.Kit.VFX)

-- shots 1 and 3 sit in the hero's space, so they frame the moment wherever it happens (playtest near walls)
local function signatureMoment(hero: BasePart, target: BasePart)
	return CameraRig.sequence({
		{ relativeTo = hero, from = CFrame.lookAt(Vector3.new(4, 1, -7), Vector3.new(0, 2, 0)),
			to = CFrame.lookAt(Vector3.new(3, 1.2, -5), Vector3.new(0, 2.2, 0)), duration = 0.7, fov = { 55, 50 } },
		{ orbit = { target = target, radius = { 11, 9 }, height = { 3, 4 }, from = -30, to = 20 }, duration = 1.1,
			lookOffset = Vector3.new(0, 1.5, 0), ease = "Quad Out", fov = 62, handheld = 0.08,
			slowmo = { scale = 0.25, seconds = 0.9, rampIn = 0.05, rampOut = 0.35 },
			onStart = function()
				VFX.play("impact", target.Position, { scale = 2, intensity = 1.5 })
				VFX.screenFlash(Color3.new(1, 1, 1), 0.18, 0.35)
				CameraRig.shake(0.6)
			end },
		{ relativeTo = hero, from = CFrame.lookAt(Vector3.new(-6, 3, -9), Vector3.new(0, 2, 4)), duration = 0.6,
			hold = 0.5, blendIn = 0.25, blendOut = 0.7, fov = 58 },
	}, { letterbox = { ratio = 2.39 }, skipInput = true, lockControls = true })
end
```
