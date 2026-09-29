--!native
-- CameraRig: the gameplay camera, authored shots and camera feel (client only). No look of its own: distances,
-- heights, FOVs, speeds and timings come from the caller (the game's style tokens); presets are starting points.
--   local rig = CameraRig.follow({ preset = "shoulder", distance = 9, fov = 70 })    follow + orbit + collision
--   rig:set({ distance = 14 }); rig:switchShoulder(); rig:setAngles(yawDeg, pitchDeg); rig:stop()
--   CameraRig.shot({ from = cfA, to = cfB, duration = 1.2, hold = 0.4, blendOut = 0.6 }):andThen(fn)
--   CameraRig.sequence({ shot1, shot2, shot3 }, { letterbox = true, skipInput = true })   -> handle:skip()
--   CameraRig.kick(8, 0.3)         FOV kick (degrees, seconds)
--   CameraRig.punch(dir, 0.5)      spring kick of the camera along dir (peak displacement in studs)
--   CameraRig.shake(0.4)           trauma through Kit.Shake's shared shaker
--   CameraRig.slowmo(0.25, 0.8)    time-scale beat: CameraRig.timeScale, LocalPlayer attribute "KitTimeScale"
-- Kit.Shake.reduceMotion scales kicks, punches, handheld noise and speed-FOV by CameraRig.reducedMotionScale.
-- Runs in one render step bound just after Enum.RenderPriority.Camera; the camera is Scriptable only while a follow
-- or a shot owns it, and is handed back (type and FOV restored) when they end.
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local FxMath = require(script.Parent:WaitForChild("FxMath"))

local function sibling(name)
	local ok, mod = pcall(function()
		return require(script.Parent:WaitForChild(name, 5))
	end)
	return if ok then mod else nil
end
local Shake = sibling("Shake")
local Debug = sibling("Debug")

local CameraRig = {}
CameraRig.timeScale = 1 -- read by other modules (VFX slows its emitters); 1 = normal speed
CameraRig.reducedMotionScale = 0 -- kicks / punches / handheld / speed-FOV multiplier when Shake.reduceMotion is on
CameraRig.punchSpeed = 16 -- punch spring (angular frequency) and damping ratio
CameraRig.punchDamping = 0.45
CameraRig.punchTilt = math.rad(2) -- rig-owned camera: radians of tilt per stud of punch

local IS_CLIENT = RunService:IsClient()
local STEP_NAME = "KitCameraRig"
local PRIORITY = Enum.RenderPriority.Camera.Value + 1
local MOUSE_RATE = 0.0045 -- radians per pixel at sensitivity 1
local TOUCH_RATE = 0.0085
local STICK_YAW, STICK_PITCH = 3.8, 2.8 -- radians per second at full tilt
local STICK_DEADZONE = 0.15
local TELEPORT = 60 -- the subject moved this far in one frame: snap instead of flying across the map
local SKIP_BLEND = 0.3
local KICK_SLOTS, SLOW_SLOTS = 8, 4
local SCRIPTABLE = Enum.CameraType.Scriptable
local BLEND = FxMath.easeFn("Sine InOut") -- every blend in and out of shots and follows

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
	if warned[key] or warnCount >= 300 then
		return
	end
	warned[key] = true
	warnCount += 1
	warn("[CameraRig] " .. msg .. caller())
end

local function finite(x)
	return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end

local function num(v, default, lo, hi, name)
	if v == nil then
		return default
	end
	if type(v) ~= "number" or v ~= v then
		warnOnce(name .. ":type", name .. " must be a number, got " .. typeof(v))
		return default
	end
	if (lo and v < lo) or (hi and v > hi) then
		warnOnce(name .. ":range", name .. " must be in " .. tostring(lo) .. ".." .. tostring(hi) .. ", got " .. tostring(v))
		return math.clamp(v, lo or v, hi or v)
	end
	return v
end

local function pair(v, default, lo, hi, name)
	if type(v) == "table" then
		return num(v[1], default, lo, hi, name), num(v[2], default, lo, hi, name)
	end
	local x = num(v, default, lo, hi, name)
	return x, x
end

-- Canonical keys (case-insensitive) with a warning, once, for each key CameraRig does not know.
local function normalize(tbl, keys, where)
	if type(tbl) ~= "table" then
		if tbl ~= nil then
			warnOnce(where .. ":type", where .. " options must be a table, got " .. typeof(tbl))
		end
		return {}
	end
	local out, unknown = FxMath.normalizeKeys(tbl, keys)
	for _, u in unknown do
		warnOnce(where .. ":" .. u.key, "unknown " .. where .. " option '" .. u.key .. "'"
			.. (if u.suggestion then " (did you mean '" .. u.suggestion .. "'?)" else ""))
	end
	return out
end

local function toColor(v, default)
	if v == nil then
		return default
	elseif typeof(v) == "Color3" then
		return v
	end
	local r, g, b = FxMath.hex(v)
	if r then
		return Color3.new(r, g, b)
	end
	local name = FxMath.tokenName(v)
	if name then
		local shared = game:GetService("ReplicatedStorage"):FindFirstChild("Shared")
		local module = shared and shared:FindFirstChild("Tokens")
		local ok, tokens = false, nil
		if module then
			ok, tokens = pcall(require, module)
		end
		local c = ok and type(tokens) == "table" and type(tokens.color) == "table" and tokens.color[name]
		if typeof(c) == "Color3" then
			return c
		end
	end
	warnOnce("color:" .. tostring(v), "colour must be a Color3, \"#RRGGBB\" or \"Tokens.color.<name>\", got " .. tostring(v))
	return default
end

local function motionScale()
	if Shake and Shake.reduceMotion then
		return CameraRig.reducedMotionScale
	end
	return 1
end

local function safeLookAt(pos, target)
	local d = target - pos
	if d.Magnitude < 1e-4 then
		return CFrame.new(pos)
	end
	if math.abs(d.Unit.Y) > 0.999 then
		return CFrame.lookAt(pos, target, Vector3.zAxis * -1)
	end
	return CFrame.lookAt(pos, target)
end

-- Where a target is right now: Vector3, CFrame, BasePart, Attachment, Humanoid, Model or a function -> Vector3.
local function targetPosition(t)
	local ty = typeof(t)
	if ty == "Vector3" then
		return t
	elseif ty == "CFrame" then
		return t.Position
	elseif ty == "Instance" then
		if t:IsA("BasePart") then
			return t.Position
		elseif t:IsA("Attachment") then
			return t.WorldPosition
		elseif t:IsA("Humanoid") then
			local root = t.RootPart
			return root and root.Position
		elseif t:IsA("Model") then
			local p = t.PrimaryPart
			if p then
				return p.Position
			end
			return t:GetPivot().Position
		end
	elseif ty == "function" then
		local ok, v = pcall(t)
		if ok and typeof(v) == "Vector3" then
			return v
		end
	end
	return nil
end

local function targetFrame(t)
	local ty = typeof(t)
	if ty == "CFrame" then
		return t
	elseif ty == "Vector3" then
		return CFrame.new(t)
	elseif ty == "Instance" then
		if t:IsA("BasePart") then
			return t.CFrame
		elseif t:IsA("Attachment") then
			return t.WorldCFrame
		elseif t:IsA("Humanoid") then
			local root = t.RootPart
			return root and root.CFrame
		elseif t:IsA("Model") then
			return t:GetPivot()
		end
	end
	return nil
end

local userSettings
do
	local ok, s = pcall(function()
		return UserSettings():GetService("UserGameSettings")
	end)
	userSettings = if ok then s else nil
end

-- The player's invert-Y setting (Roblox's settings menu), read at most once a second. (The player's camera
-- sensitivity is already applied by the engine to mouse deltas, so the rig does not scale by it again.)
local invertValue, invertReadAt = false, -math.huge
local function userInvertedY()
	local now = os.clock()
	if now - invertReadAt < 1 then
		return invertValue
	end
	invertReadAt = now
	local ok, v = pcall(function()
		return userSettings:GetCameraYInvertValue()
	end)
	invertValue = ok and v == -1
	return invertValue
end

local function deadzone(x)
	local a = math.abs(x)
	if a < STICK_DEADZONE then
		return 0
	end
	local t = (a - STICK_DEADZONE) / (1 - STICK_DEADZONE)
	return math.sign(x) * t * t
end

------------------------------------------------------------------------------------------------ module state
local F = nil -- the active follow
local S = nil -- the active sequence
local saved = nil -- camera state before the rig took it: { cameraType, fov, cf }
local lastPoseCF, lastPoseFov = nil, nil -- the rig's pose before kicks / punches (where shots start from)
local wroteCF, wroteBaseCF = nil, nil -- effects layered over someone else's camera: what we wrote and its base
local wroteFov, wroteBaseFov = nil, nil
local punchPos, punchVel = Vector3.zero, Vector3.zero
local kickAmount = table.create(KICK_SLOTS, 0)
local kickLen = table.create(KICK_SLOTS, 0)
local kickT = table.create(KICK_SLOTS, 0)
local slowScale = table.create(SLOW_SLOTS, 1)
local slowLen = table.create(SLOW_SLOTS, 0)
local slowT = table.create(SLOW_SLOTS, 0)
local slowIn = table.create(SLOW_SLOTS, 0)
local slowOut = table.create(SLOW_SLOTS, 0)
local slowId = table.create(SLOW_SLOTS, 0)
local nextBeat = 0
local listeners = {}
local bound = false
local step -- forward declaration

-- Runs just before Roblox's camera scripts: if the camera still holds exactly what the rig layered on last frame,
-- put back the pose underneath, so camera scripts that build on the camera's last orientation never see the rig's
-- offsets or blends (no drift, and a blend back to the default camera ends where that camera would be).
local function preStep()
	local cam = workspace.CurrentCamera
	if cam and wroteCF ~= nil and cam.CFrame == wroteCF then
		cam.CFrame = wroteBaseCF
	end
end

local function ensureBound()
	if bound or not IS_CLIENT then
		return
	end
	bound = true
	RunService:BindToRenderStep(STEP_NAME .. "Pre", Enum.RenderPriority.Camera.Value - 1, preStep)
	RunService:BindToRenderStep(STEP_NAME, PRIORITY, step)
end

local function unbind()
	if bound then
		bound = false
		RunService:UnbindFromRenderStep(STEP_NAME)
		RunService:UnbindFromRenderStep(STEP_NAME .. "Pre")
	end
end

-- Someone else's camera: what is there now, unless it is exactly what we wrote last frame (then our base).
local function idleBase(cam)
	local cf = cam.CFrame
	if wroteCF ~= nil and cf == wroteCF then
		cf = wroteBaseCF
	end
	local fov = cam.FieldOfView
	if wroteFov ~= nil and math.abs(fov - wroteFov) < 1e-3 then
		fov = wroteBaseFov
	end
	return cf, fov
end

-- Remembers the camera as the game had it (without any kick the rig layered on) before the rig takes it over.
local function takeCamera(cam)
	if not saved and cam then
		local cf, fov = idleBase(cam)
		saved = { cameraType = cam.CameraType, fov = fov, cf = cf }
	end
end

-- Gives the camera back to Roblox's camera scripts while a blend back is still running: they resume from the view the
-- player had before the rig took over (the pre-step shows them that pose), and the blend eases into their result.
local handBackBase = nil -- the pose the game's camera resumes from, until the step's next write records it
local function handBack()
	local cam = workspace.CurrentCamera
	if not (saved and cam and cam.CameraType == SCRIPTABLE and saved.cameraType ~= SCRIPTABLE) then
		return
	end
	cam.CameraType = saved.cameraType
	local current = cam.CFrame
	wroteCF = current
	wroteBaseCF = CFrame.new(current.Position) * saved.cf.Rotation
	handBackBase = wroteBaseCF
end

local function releaseCamera()
	local cam = workspace.CurrentCamera
	if saved and cam then
		if cam.CameraType == SCRIPTABLE and saved.cameraType ~= SCRIPTABLE then
			cam.CameraType = saved.cameraType
		end
		cam.FieldOfView = saved.fov
	end
	saved = nil
	lastPoseCF, lastPoseFov = nil, nil
end

------------------------------------------------------------------------------------------------ time scale
local function setTimeScale(ts)
	if ts == CameraRig.timeScale then
		return
	end
	CameraRig.timeScale = ts
	local player = Players.LocalPlayer
	if player then
		player:SetAttribute("KitTimeScale", ts)
	end
	for _, fn in listeners do
		local ok, err = pcall(fn, ts)
		if not ok then
			warnOnce("listener:" .. tostring(fn), "time-scale listener failed: " .. tostring(err))
		end
	end
end

-- Calls fn(timeScale) whenever CameraRig.timeScale changes. Returns an object with :Disconnect().
function CameraRig.onTimeScale(fn)
	if type(fn) ~= "function" then
		warnOnce("onTimeScale", "onTimeScale needs a function")
		return { Disconnect = function() end }
	end
	table.insert(listeners, fn)
	return {
		Disconnect = function()
			local i = table.find(listeners, fn)
			if i then
				table.remove(listeners, i)
			end
		end,
	}
end

-- A slow-motion beat: time scale eases to `scale`, holds, and eases back to 1 by `seconds` (real time).
-- opts: { rampIn = s, rampOut = s }. Overlapping beats take the slowest. Returns the beat's id; slowmo(1) clears
-- every beat. Nothing physical changes: other modules read CameraRig.timeScale (or the "KitTimeScale" attribute).
function CameraRig.slowmo(scale, seconds, opts)
	if not IS_CLIENT then
		return nil
	end
	scale = num(scale, 1, 0, 1, "slowmo scale")
	seconds = num(seconds, 0, 0, 60, "slowmo seconds")
	if scale >= 1 or seconds <= 0 then
		for i = 1, SLOW_SLOTS do
			slowLen[i] = 0
		end
		setTimeScale(1)
		return nil
	end
	opts = normalize(opts, FxMath.CAMERA_NESTED_KEYS.slowmo, "slowmo")
	local slot, most = 1, -1
	for i = 1, SLOW_SLOTS do
		if slowLen[i] == 0 then
			slot = i
			break
		end
		local progress = slowT[i] / slowLen[i]
		if progress > most then
			most, slot = progress, i
		end
	end
	nextBeat += 1
	slowId[slot] = nextBeat
	slowScale[slot] = scale
	slowLen[slot] = seconds
	slowT[slot] = 0
	slowIn[slot] = num(opts.rampIn, math.min(0.08, seconds * 0.2), 0, 60, "slowmo rampIn")
	slowOut[slot] = num(opts.rampOut, math.min(0.25, seconds * 0.4), 0, 60, "slowmo rampOut")
	if slowIn[slot] <= 0 then
		setTimeScale(math.min(CameraRig.timeScale, scale))
	end
	ensureBound()
	return nextBeat
end

-- Ends the beats a shot started (not the game's own, such as a hitstop's).
local function stopBeats(ids)
	for _, id in ids do
		for i = 1, SLOW_SLOTS do
			if slowId[i] == id and slowLen[i] > 0 then
				slowLen[i] = 0
				ensureBound() -- the next step recomputes the time scale
			end
		end
	end
end

local function stepSlowmo(dt)
	local ts, active = 1, false
	for i = 1, SLOW_SLOTS do
		local len = slowLen[i]
		if len > 0 then
			if slowT[i] >= len then
				slowLen[i] = 0
			else
				active = true
				ts = math.min(ts, FxMath.slowmoScale(slowT[i], slowScale[i], len, slowIn[i], slowOut[i]))
				slowT[i] += dt
			end
		end
	end
	setTimeScale(ts)
	return active
end

------------------------------------------------------------------------------------------------ kicks, punches, shake
-- FOV kick: adds fovDelta degrees with a quick rise and a smooth return over `seconds`. Kicks add up.
function CameraRig.kick(fovDelta, seconds)
	if not IS_CLIENT then
		return
	end
	if not finite(fovDelta) then
		warnOnce("kick", "kick(fovDelta, seconds) needs a number of degrees")
		return
	end
	seconds = num(seconds, 0.25, 0.02, 5, "kick seconds")
	local slot, most = 1, -1
	for i = 1, KICK_SLOTS do
		if kickLen[i] == 0 then
			slot = i
			break
		end
		local progress = kickT[i] / kickLen[i]
		if progress > most then
			most, slot = progress, i
		end
	end
	if math.abs(fovDelta) > 60 then
		warnOnce("kick:range", "kick fovDelta is limited to +-60 degrees, got " .. tostring(fovDelta))
	end
	kickAmount[slot] = math.clamp(fovDelta, -60, 60)
	kickLen[slot] = seconds
	kickT[slot] = 0
	ensureBound()
end

local function stepKicks(dt)
	local sum, active = 0, false
	for i = 1, KICK_SLOTS do
		local len = kickLen[i]
		if len > 0 then
			local t = kickT[i]
			if t >= len then
				kickLen[i] = 0
			else
				active = true
				sum += kickAmount[i] * FxMath.kickEnvelope(t, len)
				kickT[i] = t + dt
			end
		end
	end
	return sum, active
end

local function punchSpeed()
	local v = CameraRig.punchSpeed
	return if finite(v) then math.clamp(v, 1, 100) else 16
end

local function punchDamping()
	local v = CameraRig.punchDamping
	return if finite(v) then math.clamp(v, 0.05, 4) else 0.45
end

-- Positional kick along `direction` (world space), springing back; strength = peak displacement in studs.
function CameraRig.punch(direction, strength)
	if not IS_CLIENT then
		return
	end
	if typeof(direction) ~= "Vector3" then
		warnOnce("punch", "punch(direction, strength) needs a Vector3 direction")
		return
	end
	if not (direction.Magnitude > 1e-6 and direction.Magnitude < math.huge) then
		return
	end
	local peak = num(strength, 0.5, 0, 50, "punch strength")
	punchVel += direction.Unit * FxMath.impulseForPeak(peak, punchSpeed(), punchDamping())
	ensureBound()
end

local function stepPunch(dt)
	if punchPos == Vector3.zero and punchVel == Vector3.zero then
		return false
	end
	punchPos, punchVel = FxMath.springStep(punchPos, punchVel, Vector3.zero, punchSpeed(), punchDamping(), dt)
	if punchPos.Magnitude < 1e-3 and punchVel.Magnitude < 1e-2 then
		punchPos, punchVel = Vector3.zero, Vector3.zero
	end
	return true
end

local function applyPunch(cf, ms, rotate)
	if ms == 0 or punchPos == Vector3.zero then
		return cf
	end
	local offset = punchPos * ms
	local out = cf + offset
	if rotate then
		local tilt = CameraRig.punchTilt
		out = out * CFrame.Angles(cf.UpVector:Dot(offset) * tilt, -cf.RightVector:Dot(offset) * tilt, 0)
	end
	return out
end

-- Trauma shake (0..1) through Kit.Shake's shared shaker, which already honours Shake.reduceMotion.
function CameraRig.shake(trauma)
	if not finite(trauma) then
		warnOnce("shake", "shake(trauma) needs a number from 0 to 1")
		return
	end
	if trauma < 0 or trauma > 1 then
		warnOnce("shake:range", "shake trauma is 0..1, got " .. tostring(trauma))
	end
	if Shake then
		Shake.kick(math.clamp(trauma, 0, 1))
	end
end

------------------------------------------------------------------------------------------------ follow
-- Starting points per genre; every value can be overridden, and set({preset = ...}) switches between them.
local PRESETS = {
	shoulder = { distance = 7, height = 1.6, offset = Vector3.new(2, 0.4, 0), fov = 70, pitch = -6, pitchMin = -70,
		pitchMax = 70, orbit = "free", rotSpeed = 0, collision = true, lookAhead = 0 },
	overTheTop = { distance = 16, height = 2, offset = Vector3.new(0, 1, 0), fov = 70, pitch = -30, pitchMin = -75,
		pitchMax = 10, orbit = "drag", rotSpeed = 0, collision = true, lookAhead = 2 },
	sideScroller = { distance = 30, height = 2, offset = Vector3.new(0, 1, 0), fov = 45, yaw = 0, pitch = -4,
		orbit = "locked", rotSpeed = 6, collision = false, lookAhead = 6, fadeSubject = false },
	topDown = { distance = 48, height = 0, offset = Vector3.zero, fov = 40, yaw = 0, pitch = -70, orbit = "locked",
		rotSpeed = 6, collision = false, lookAhead = 4, fadeSubject = false },
}
local PRESET_ALIAS = { shoulder = "shoulder", overshoulder = "shoulder", overtheshoulder = "shoulder",
	overthetop = "overTheTop", chase = "overTheTop", third = "overTheTop", thirdperson = "overTheTop",
	sidescroller = "sideScroller", side = "sideScroller", topdown = "topDown", top = "topDown" }
local DEFAULTS = { distance = 12, height = 2, offset = Vector3.zero, fov = 70, pitch = -15, pitchMin = -75,
	pitchMax = 60, orbit = "drag", invertY = false, speed = 14, damping = 1, rotSpeed = 0, zoomSpeed = 8,
	lookAhead = 0, lookAheadSpeed = 24, lookAheadRate = 3, collision = true, collisionRadius = 0.6, minDistance = 1,
	returnSpeed = 5, shoulder = 1, fadeSubject = 3, blend = 0.35, input = true }

local function presetName(p)
	if type(p) ~= "string" then
		return nil
	end
	return PRESET_ALIAS[string.lower((string.gsub(p, "[^%a]", "")))]
end

local function resolveConfig(user)
	local raw = table.clone(DEFAULTS)
	if user.preset ~= nil then
		local name = presetName(user.preset)
		if name then
			for k, v in PRESETS[name] do
				raw[k] = v
			end
		else
			warnOnce("preset:" .. tostring(user.preset), "unknown camera preset '" .. tostring(user.preset)
				.. "' (shoulder, overTheTop, sideScroller, topDown)")
		end
	end
	for k, v in user do
		raw[k] = v
	end
	local c = {}
	c.subject = raw.subject
	c.distance = num(raw.distance, 12, 0, 2000, "distance")
	c.height = num(raw.height, 2, -1000, 1000, "height")
	if typeof(raw.offset) == "Vector3" then
		c.offset = raw.offset
	elseif type(raw.offset) == "number" then
		c.offset = Vector3.new(raw.offset, 0, 0)
	else
		if raw.offset ~= nil then
			warnOnce("offset", "offset must be a Vector3 (right, up, 0) or a number (right)")
		end
		c.offset = Vector3.zero
	end
	c.fov = num(raw.fov, 70, 1, 120, "fov")
	c.pitchMin = num(raw.pitchMin, -75, -89, 89, "pitchMin")
	c.pitchMax = num(raw.pitchMax, 60, -89, 89, "pitchMax")
	if c.pitchMin > c.pitchMax then
		c.pitchMin, c.pitchMax = c.pitchMax, c.pitchMin
	end
	c.pitch = math.clamp(num(raw.pitch, -15, -89, 89, "pitch"), c.pitchMin, c.pitchMax)
	c.yaw = if raw.yaw ~= nil then num(raw.yaw, 0, -100000, 100000, "yaw") else nil
	c.orbit = FxMath.enumValue(raw.orbit, { "free", "drag", "locked" })
	if not c.orbit then
		warnOnce("orbit:" .. tostring(raw.orbit), "orbit must be \"free\", \"drag\" or \"locked\"")
		c.orbit = "drag"
	end
	local sens = raw.sensitivity
	if type(sens) == "table" then
		sens = normalize(sens, FxMath.CAMERA_NESTED_KEYS.sensitivity, "sensitivity")
		c.sens = { mouse = num(sens.mouse, 1, 0, 20, "sensitivity.mouse"), touch = num(sens.touch, 1, 0, 20,
			"sensitivity.touch"), gamepad = num(sens.gamepad, 1, 0, 20, "sensitivity.gamepad") }
	else
		local k = num(sens, 1, 0, 20, "sensitivity")
		c.sens = { mouse = k, touch = k, gamepad = k }
	end
	c.invertY = raw.invertY == true
	c.speed = num(raw.speed, 14, 0.01, 200, "speed")
	c.damping = num(raw.damping, 1, 0.05, 10, "damping")
	c.verticalSpeed = num(raw.verticalSpeed, c.speed, 0.01, 200, "verticalSpeed")
	c.verticalLag = raw.verticalSpeed ~= nil and c.verticalSpeed < c.speed
	c.rotSpeed = num(raw.rotSpeed, 0, 0, 200, "rotSpeed")
	c.zoomSpeed = num(raw.zoomSpeed, 8, 0.01, 200, "zoomSpeed")
	c.lookAhead = num(raw.lookAhead, 0, 0, 200, "lookAhead")
	c.lookAheadSpeed = num(raw.lookAheadSpeed, 24, 0.01, 10000, "lookAheadSpeed")
	c.lookAheadRate = num(raw.lookAheadRate, 3, 0.01, 100, "lookAheadRate")
	c.collision = raw.collision ~= false
	c.collisionRadius = num(raw.collisionRadius, 0.6, 0, 20, "collisionRadius")
	c.minDistance = num(raw.minDistance, 1, 0, 1000, "minDistance")
	c.returnSpeed = num(raw.returnSpeed, 5, 0.01, 200, "returnSpeed")
	c.shoulder = if num(raw.shoulder, 1, -1, 1, "shoulder") < 0 then -1 else 1
	c.shoulderKey = if typeof(raw.shoulderKey) == "EnumItem" then raw.shoulderKey else nil
	c.input = raw.input ~= false
	c.blend = num(raw.blend, 0.35, 0, 30, "blend")
	c.fadeSubject = if raw.fadeSubject == false then nil else num(if raw.fadeSubject == true then 3 else raw.fadeSubject,
		3, 0, 100, "fadeSubject")
	c.ignore = {}
	if type(raw.ignore) == "table" then
		for _, x in raw.ignore do
			if typeof(x) == "Instance" then
				table.insert(c.ignore, x)
			end
		end
	end
	if type(raw.speedFov) == "table" then
		local s = normalize(raw.speedFov, FxMath.CAMERA_NESTED_KEYS.speedFov, "speedFov")
		c.speedFov = { from = num(s.from, 16, 0, 10000, "speedFov.from"), to = num(s.to, 48, 0, 10000, "speedFov.to"),
			fov = num(s.fov, 0, -60, 60, "speedFov.fov"), pull = num(s.pull, 0, -1000, 1000, "speedFov.pull") }
	end
	if raw.autoAlign ~= nil and raw.autoAlign ~= false then
		if type(raw.autoAlign) == "table" then
			local a = normalize(raw.autoAlign, FxMath.CAMERA_NESTED_KEYS.autoAlign, "autoAlign")
			c.autoAlign = { delay = num(a.delay, 1.2, 0, 60, "autoAlign.delay"), speed = num(a.speed, 2.5, 0.01, 50,
				"autoAlign.speed") }
		else
			c.autoAlign = { delay = num(if raw.autoAlign == true then 1.2 else raw.autoAlign, 1.2, 0, 60, "autoAlign"),
				speed = 2.5 }
		end
	end
	if type(raw.zoom) == "table" then
		local z = normalize(raw.zoom, FxMath.CAMERA_NESTED_KEYS.zoom, "zoom")
		local lo = num(z.min, c.distance * 0.5, 0, 2000, "zoom.min")
		local hi = num(z.max, c.distance * 2, 0, 2000, "zoom.max")
		c.zoom = { min = math.min(lo, hi), max = math.max(lo, hi), step = num(z.step, 2, 0, 1000, "zoom.step") }
	end
	return c
end

local inp = { dx = 0, dy = 0, tdx = 0, tdy = 0, stickX = 0, stickY = 0, rmb = false, touch = nil, zoom = 0, last = 0 }
local inputConns = {}
local mouseOwned = nil -- the MouseBehavior the rig last set (nil = the rig does not own the mouse)

local function setMouse(behavior)
	if UserInputService.MouseBehavior ~= behavior then
		UserInputService.MouseBehavior = behavior
	end
	mouseOwned = behavior
end

local function releaseMouse()
	if mouseOwned ~= nil then
		if UserInputService.MouseBehavior == mouseOwned then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		end
		mouseOwned = nil
	end
end

local THUMBSTICKS = { "DynamicThumbstickFrame", "ThumbstickFrame" }
local function inThumbstickArea(pos)
	local player = Players.LocalPlayer
	local pg = player and player:FindFirstChildOfClass("PlayerGui")
	local touchGui = pg and pg:FindFirstChild("TouchGui")
	local frame = touchGui and touchGui:FindFirstChild("TouchControlFrame")
	if not frame then
		return false
	end
	for _, name in THUMBSTICKS do
		local stick = frame:FindFirstChild(name)
		if stick and stick:IsA("GuiObject") and stick.Visible then
			local p0, size = stick.AbsolutePosition, stick.AbsoluteSize
			if pos.X >= p0.X and pos.Y >= p0.Y and pos.X <= p0.X + size.X and pos.Y <= p0.Y + size.Y then
				return true
			end
		end
	end
	return false
end

local FollowHandle = {}
FollowHandle.__index = FollowHandle

local function connectInput()
	if #inputConns > 0 then
		return
	end
	table.insert(inputConns, UserInputService.InputBegan:Connect(function(io, processed)
		local t = io.UserInputType
		if t == Enum.UserInputType.MouseButton2 and not processed then
			inp.rmb = true
		elseif t == Enum.UserInputType.Touch and not processed and inp.touch == nil
			and not inThumbstickArea(io.Position) then
			inp.touch = io
		elseif F and F.cfg.shoulderKey and io.KeyCode == F.cfg.shoulderKey and not processed then
			F.handle:switchShoulder()
		end
	end))
	table.insert(inputConns, UserInputService.InputChanged:Connect(function(io, processed)
		local t = io.UserInputType
		if t == Enum.UserInputType.MouseMovement then
			if F and (F.cfg.orbit == "free" or inp.rmb) then
				inp.dx += io.Delta.X
				inp.dy += io.Delta.Y
			end
		elseif t == Enum.UserInputType.Touch then
			if io == inp.touch then
				inp.tdx += io.Delta.X
				inp.tdy += io.Delta.Y
			end
		elseif t == Enum.UserInputType.MouseWheel then
			if not processed then
				inp.zoom -= io.Position.Z
			end
		elseif io.KeyCode == Enum.KeyCode.Thumbstick2 then
			inp.stickX, inp.stickY = io.Position.X, io.Position.Y
		end
	end))
	table.insert(inputConns, UserInputService.InputEnded:Connect(function(io)
		if io.UserInputType == Enum.UserInputType.MouseButton2 then
			inp.rmb = false
		elseif io == inp.touch then
			inp.touch = nil
		elseif io.KeyCode == Enum.KeyCode.Thumbstick2 then
			inp.stickX, inp.stickY = 0, 0
		end
	end))
end

local function disconnectInput()
	for _, c in inputConns do
		c:Disconnect()
	end
	table.clear(inputConns)
	inp.dx, inp.dy, inp.tdx, inp.tdy, inp.zoom = 0, 0, 0, 0, 0
	inp.stickX, inp.stickY, inp.rmb, inp.touch = 0, 0, false, nil
	releaseMouse()
end

local function setFade(f, value)
	f.fade = value
	if not f.fadeParts then
		f.fadeParts = {}
		if f.character then
			for _, d in f.character:GetDescendants() do
				if d:IsA("BasePart") or d:IsA("Decal") then
					table.insert(f.fadeParts, d)
				end
			end
		end
	end
	for _, p in f.fadeParts do
		p.LocalTransparencyModifier = value
	end
end

local function resolveSubject(f)
	local s = f.cfg.subject
	if f.fade ~= 0 then
		setFade(f, 0)
	end
	f.part, f.attach, f.fn, f.vec, f.character, f.localCharacter = nil, nil, nil, nil, nil, false
	f.fadeParts = nil
	if s == nil or s == false then
		f.localCharacter = true
		local player = Players.LocalPlayer
		local ch = player and player.Character
		if ch then
			local hum = ch:FindFirstChildOfClass("Humanoid")
			f.part = (hum and hum.RootPart) or ch:FindFirstChild("HumanoidRootPart") or ch.PrimaryPart
			f.character = ch
		end
	elseif type(s) == "function" then
		f.fn = s
	elseif typeof(s) == "Vector3" then
		f.vec = s
	elseif typeof(s) == "Instance" then
		if s:IsA("Humanoid") then
			f.part, f.character = s.RootPart, s.Parent
		elseif s:IsA("BasePart") then
			f.part = s
			local model = s:FindFirstAncestorOfClass("Model")
			if model and model:FindFirstChildOfClass("Humanoid") then
				f.character = model
			end
		elseif s:IsA("Model") then
			local hum = s:FindFirstChildOfClass("Humanoid")
			f.part = (hum and hum.RootPart) or s.PrimaryPart or s:FindFirstChildWhichIsA("BasePart", true)
			f.character = s
		elseif s:IsA("Attachment") then
			f.attach = s
		else
			warnOnce("subject:" .. s.ClassName, "subject must be a Humanoid, BasePart, Model, Attachment, Vector3 or function")
		end
	else
		warnOnce("subject:" .. typeof(s), "subject must be a Humanoid, BasePart, Model, Attachment, Vector3 or function")
	end
	local filter = {}
	if f.character then
		table.insert(filter, f.character)
	elseif f.part then
		table.insert(filter, f.part)
	elseif f.attach then
		local holder = f.attach.Parent
		local model = holder and holder:FindFirstAncestorOfClass("Model")
		if model or holder then
			table.insert(filter, model or holder) -- what the attachment rides on (a vehicle) never blocks the view
		end
	end
	for _, x in f.cfg.ignore do
		table.insert(filter, x)
	end
	f.params.FilterDescendantsInstances = filter
	f.fade = -1 -- write the subject's transparency once (first person may have left it hidden)
end

local function needsResolve(f)
	if f.fn or f.vec then
		return false
	elseif f.attach then
		return f.attach.Parent == nil
	elseif f.part == nil or f.part.Parent == nil then
		return true
	elseif f.localCharacter then
		local player = Players.LocalPlayer
		return player ~= nil and player.Character ~= f.character
	end
	return false
end

local function finiteVector(v)
	return typeof(v) == "Vector3" and finite(v.X) and finite(v.Y) and finite(v.Z)
end

local function subjectPosition(f)
	if f.fn then
		local ok, p = pcall(f.fn)
		if ok and finiteVector(p) then
			return p, nil
		end
		warnOnce("subjectfn", "a subject function must return a finite Vector3")
		return nil, nil
	elseif f.vec then
		return f.vec, Vector3.zero
	elseif f.attach then
		local p = f.attach.WorldPosition
		return if finiteVector(p) then p else nil, nil
	end
	local part = f.part
	if part and part.Parent then
		local p = part.Position
		if not finiteVector(p) then
			return nil, nil
		end
		if part.Anchored then
			return p, nil
		end
		local v = part.AssemblyLinearVelocity
		return p, if finiteVector(v) then v else nil
	end
	return nil, nil
end

local hasSpherecast = nil
local function cast(origin, direction, radius, params)
	if hasSpherecast == nil then
		hasSpherecast = pcall(function()
			return workspace.Spherecast
		end)
	end
	local length = direction.Magnitude
	if length > 1000 then -- shape casts travel at most 1024 studs
		direction = direction * (1000 / length)
	end
	if hasSpherecast and radius > 0 then
		local ok, result = pcall(workspace.Spherecast, workspace, origin, math.min(radius, 256), direction, params)
		if ok then
			return result, true
		end
	end
	return workspace:Raycast(origin, direction, params), false
end

local function snapFollow(f, pos)
	local cfg = f.cfg
	local goal = pos + Vector3.new(0, cfg.height, 0)
	f.focusXZ, f.velXZ = Vector3.new(goal.X, 0, goal.Z), Vector3.zero
	f.focusY, f.velY = goal.Y, 0
	f.goalXZ, f.goalY = f.focusXZ, f.focusY
	f.look, f.lookVel = Vector3.zero, Vector3.zero
	f.dist, f.distVel = cfg.distance + f.zoomOffset, 0
	f.collDist = f.dist
	f.fov, f.fovVel = cfg.fov, 0
	f.side, f.sideVel = cfg.shoulder, 0
	f.vel = Vector3.zero
end

local function stepFollow(f, dt, cam, allowInput)
	local cfg = f.cfg
	local fresh = f.freshSubject == true
	f.freshSubject = false
	if needsResolve(f) and os.clock() >= (f.nextResolve or 0) then
		resolveSubject(f)
		fresh = true
		f.nextResolve = os.clock() + 0.2
	end
	local pos, measured = subjectPosition(f)
	if not pos then
		releaseMouse()
		return f.cf, f.outFov, f.focus
	end
	if not f.started or (f.lastPos and (pos - f.lastPos).Magnitude > TELEPORT) then
		-- first frame, or a respawn / teleport far away: cut instead of flying across the map
		snapFollow(f, pos)
		f.started = true
	elseif measured == nil and f.lastPos and dt > 0 and not fresh then
		f.vel += ((pos - f.lastPos) / dt - f.vel) * FxMath.alpha(12, dt)
	end
	if measured ~= nil then
		f.vel = measured
	elseif fresh then
		f.vel = Vector3.zero
	end
	local vel = f.vel
	f.lastPos = pos

	-- orbit input
	local useInput = allowInput and cfg.input and cfg.orbit ~= "locked"
	if useInput then
		if cfg.orbit == "free" then
			setMouse(Enum.MouseBehavior.LockCenter)
		elseif inp.rmb then
			setMouse(Enum.MouseBehavior.LockCurrentPosition)
		else
			releaseMouse()
		end
		local mouseK = MOUSE_RATE * cfg.sens.mouse
		local touchK = TOUCH_RATE * cfg.sens.touch
		local yawIn = -(inp.dx * mouseK + inp.tdx * touchK) - deadzone(inp.stickX) * STICK_YAW * cfg.sens.gamepad * dt
		local pitchIn = -(inp.dy * mouseK + inp.tdy * touchK) + deadzone(inp.stickY) * STICK_PITCH * cfg.sens.gamepad * dt
		if cfg.invertY ~= userInvertedY() then
			pitchIn = -pitchIn
		end
		if yawIn ~= 0 or pitchIn ~= 0 then
			inp.last = os.clock()
		end
		f.yawGoal += yawIn
		f.pitchGoal += pitchIn
		if cfg.zoom and inp.zoom ~= 0 then
			f.zoomOffset = math.clamp(f.zoomOffset + inp.zoom * cfg.zoom.step, cfg.zoom.min - cfg.distance,
				cfg.zoom.max - cfg.distance)
		end
	else
		releaseMouse()
	end
	inp.dx, inp.dy, inp.tdx, inp.tdy, inp.zoom = 0, 0, 0, 0, 0
	if cfg.orbit == "locked" then
		f.yawGoal = if cfg.yaw then math.rad(cfg.yaw) else f.lockedYaw
		f.pitchGoal = math.rad(cfg.pitch)
	end
	f.pitchGoal = math.clamp(f.pitchGoal, math.rad(cfg.pitchMin), math.rad(cfg.pitchMax))
	local hv = Vector3.new(vel.X, 0, vel.Z)
	local hs = hv.Magnitude
	if cfg.autoAlign and cfg.orbit ~= "locked" and hs > 2 and os.clock() - inp.last > cfg.autoAlign.delay then
		local moveYaw = math.atan2(-hv.X, -hv.Z)
		f.yawGoal = FxMath.dampAngle(f.yawGoal, moveYaw, cfg.autoAlign.speed * math.min(hs / 16, 1), dt)
	end
	if cfg.rotSpeed > 0 then
		f.yaw = FxMath.dampAngle(f.yaw, f.yawGoal, cfg.rotSpeed, dt)
		f.pitch = FxMath.damp(f.pitch, f.pitchGoal, cfg.rotSpeed, dt)
	else
		f.yaw, f.pitch = f.yawGoal, f.pitchGoal
	end
	local rot = CFrame.fromEulerAnglesYXZ(f.pitch, f.yaw, 0)

	-- look-ahead: lead room in the direction of travel, on the screen plane
	local lookGoal = Vector3.zero
	if cfg.lookAhead > 0 and hs > 0.5 then
		local lv = rot.LookVector
		local dir = hv / hs
		dir -= lv * dir:Dot(lv)
		lookGoal = dir * (cfg.lookAhead * math.min(hs / cfg.lookAheadSpeed, 1))
	end
	f.look, f.lookVel = FxMath.springStep(f.look, f.lookVel, lookGoal, cfg.lookAheadRate, 1, dt)

	-- focus: springs in the frame moving with the subject. Each step starts from where the goal was and moves with the
	-- subject's velocity, so constant speed never lags; only motion the velocity does not explain (starts, stops,
	-- turns, jumps in the goal) is smoothed. A softer verticalSpeed also drops the vertical velocity, so jumps lag.
	local goal = pos + Vector3.new(0, cfg.height, 0) + f.look
	local a, b, c, d = FxMath.springCoefficients(cfg.speed, cfg.damping, dt)
	local gxz = Vector3.new(goal.X, 0, goal.Z)
	local vxz = Vector3.new(vel.X, 0, vel.Z)
	local exz, rxz = f.focusXZ - f.goalXZ, f.velXZ - vxz
	f.focusXZ = f.goalXZ + vxz * dt + exz * a + rxz * b
	f.velXZ = vxz + exz * c + rxz * d
	f.goalXZ = gxz
	local vy = if cfg.verticalLag then 0 else vel.Y
	if cfg.verticalSpeed ~= cfg.speed then
		a, b, c, d = FxMath.springCoefficients(cfg.verticalSpeed, cfg.damping, dt)
	end
	local ey, ry = f.focusY - f.goalY, f.velY - vy
	f.focusY = f.goalY + vy * dt + ey * a + ry * b
	f.velY = vy + ey * c + ry * d
	f.goalY = goal.Y
	local focus = Vector3.new(f.focusXZ.X, f.focusY, f.focusXZ.Z)

	-- distance, FOV and shoulder side ease together; speed widens the FOV and pulls back
	local k = 0
	if cfg.speedFov then
		k = FxMath.smoothstep(cfg.speedFov.from, cfg.speedFov.to, hs) * motionScale()
	end
	local distGoal = cfg.distance + f.zoomOffset + (if cfg.speedFov then cfg.speedFov.pull * k else 0)
	local fovGoal = cfg.fov + (if cfg.speedFov then cfg.speedFov.fov * k else 0)
	a, b, c, d = FxMath.springCoefficients(cfg.zoomSpeed, 1, dt)
	local e = f.dist - distGoal
	f.dist, f.distVel = distGoal + e * a + f.distVel * b, e * c + f.distVel * d
	e = f.fov - fovGoal
	f.fov, f.fovVel = fovGoal + e * a + f.fovVel * b, e * c + f.fovVel * d
	e = f.side - cfg.shoulder
	f.side, f.sideVel = cfg.shoulder + e * a + f.sideVel * b, e * c + f.sideVel * d

	-- pivot beside the subject (shoulder), then back along the view; pull in before geometry
	local off = cfg.offset
	local pivot = focus + rot:VectorToWorldSpace(Vector3.new(off.X * f.side, off.Y, 0))
	local back = -rot.LookVector
	local want = math.max(f.dist, 0)
	local camDist = want
	if cfg.collision then
		local side = pivot - focus
		local sideLen = side.Magnitude
		if sideLen > 1e-3 then
			local hit, sphere = cast(focus, side, cfg.collisionRadius, f.params)
			if hit then
				local allowed = if sphere then hit.Distance else hit.Distance - cfg.collisionRadius
				pivot = focus + side * (math.clamp(allowed, 0, sideLen) / sideLen)
			end
		end
		local allowed = want
		if want > 1e-3 then
			local hit, sphere = cast(pivot, back * want, cfg.collisionRadius, f.params)
			if hit then
				allowed = math.clamp(if sphere then hit.Distance else hit.Distance - cfg.collisionRadius, cfg.minDistance, want)
			end
		end
		f.collDist = FxMath.collisionDistance(f.collDist, allowed, cfg.returnSpeed, dt)
		camDist = math.min(want, f.collDist)
	else
		f.collDist = want
	end
	local cf = CFrame.new(pivot + back * camDist) * rot
	local fov = f.fov
	if f.blendDur > 0 and f.blendT < f.blendDur then
		f.blendT += dt
		local w = BLEND(f.blendT / f.blendDur)
		cf = f.blendFrom:Lerp(cf, w)
		fov = f.blendFromFov + (fov - f.blendFromFov) * w
	end
	if f.character and (cfg.fadeSubject or f.fade < 0) then
		-- see-through when the camera is pulled in close; never during shots (their camera is elsewhere)
		local fadeGoal = 0
		if cfg.fadeSubject and S == nil then
			fadeGoal = math.clamp((cfg.fadeSubject - camDist) / math.max(cfg.fadeSubject * 0.5, 0.01), 0, 1)
		end
		if math.abs(fadeGoal - f.fade) > 0.02 or (fadeGoal ~= f.fade and (fadeGoal == 0 or fadeGoal == 1)) then
			setFade(f, fadeGoal)
		end
	end
	f.cf, f.outFov, f.focus = cf, fov, focus
	return cf, fov, focus
end

local function stopFollow(f, release)
	if F ~= f then
		return
	end
	F = nil
	if f.fade ~= 0 then
		setFade(f, 0)
	end
	disconnectInput()
	if S ~= nil and S.phase == "out" then
		handBack() -- a shot was blending back to this follow: blend into the game's camera instead
	elseif release and S == nil then
		releaseCamera()
	end
end

-- Starts following the local character (or opts.subject) and returns a handle. Options (all optional):
-- preset ("shoulder" | "overTheTop" | "sideScroller" | "topDown"), subject, distance, height, offset (Vector3: right,
-- up), fov, yaw, pitch, pitchMin, pitchMax (degrees), orbit ("free" mouse-lock | "drag" hold right mouse / touch |
-- "locked"), sensitivity (number or {mouse, touch, gamepad}), invertY, speed, damping, verticalSpeed, rotSpeed,
-- zoomSpeed, lookAhead (studs), lookAheadSpeed, lookAheadRate, collision, collisionRadius, minDistance, returnSpeed,
-- speedFov ({from, to, fov, pull}), autoAlign (seconds or {delay, speed}), shoulder (1 | -1), shoulderKey,
-- zoom ({min, max, step}), ignore ({Instance}), fadeSubject (studs or false), blend (seconds), input (bool).
function CameraRig.follow(opts)
	if not IS_CLIENT then
		warnOnce("follow:server", "follow runs on the client only")
		return setmetatable({ _dead = true }, FollowHandle)
	end
	local user = normalize(opts or {}, FxMath.FOLLOW_KEYS, "follow")
	if F then
		stopFollow(F, false)
	end
	local cam = workspace.CurrentCamera
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	pcall(function()
		params.RespectCanCollide = true
	end)
	local handle = setmetatable({}, FollowHandle)
	local f = { handle = handle, user = user, cfg = resolveConfig(user), params = params, zoomOffset = 0, fade = 0,
		vel = Vector3.zero, started = false, blendT = 0, blendDur = 0 }
	handle._state = f
	local lv = cam and cam.CFrame.LookVector or Vector3.new(0, 0, -1)
	local camYaw = FxMath.yawPitch(lv.X, lv.Y, lv.Z)
	f.yaw = if f.cfg.yaw then math.rad(f.cfg.yaw) else camYaw
	f.pitch = math.rad(f.cfg.pitch)
	f.yawGoal, f.pitchGoal, f.lockedYaw = f.yaw, f.pitch, f.yaw
	if cam and f.cfg.blend > 0 and S == nil then
		f.blendFrom, f.blendFromFov, f.blendDur = lastPoseCF or cam.CFrame, lastPoseFov or cam.FieldOfView, f.cfg.blend
	end
	resolveSubject(f)
	F = f
	connectInput()
	ensureBound()
	if Debug then
		Debug.event("camera_follow", { preset = tostring(user.preset or "custom"), distance = f.cfg.distance,
			fov = f.cfg.fov })
	end
	return handle
end

-- Changes options while following. Setting preset starts from that preset again (keeping subject, ignore, input,
-- sensitivity, invertY and shoulderKey); other options merge into the current ones and ease in.
function FollowHandle:set(opts)
	local f = self._state
	if not f or F ~= f then
		return self
	end
	local changes = normalize(opts or {}, FxMath.FOLLOW_KEYS, "follow")
	if changes.preset ~= nil then
		local u = f.user
		f.user = { subject = u.subject, ignore = u.ignore, input = u.input, sensitivity = u.sensitivity,
			invertY = u.invertY, shoulderKey = u.shoulderKey }
	end
	for k, v in changes do
		f.user[k] = v
	end
	local oldSubject = f.cfg.subject
	f.cfg = resolveConfig(f.user)
	if f.cfg.subject ~= oldSubject or changes.ignore ~= nil then
		resolveSubject(f)
		f.freshSubject = true
	end
	if changes.yaw ~= nil or changes.preset ~= nil then
		if f.cfg.yaw then
			f.yawGoal = math.rad(f.cfg.yaw)
			f.lockedYaw = f.yawGoal
		end
	end
	if changes.pitch ~= nil or changes.preset ~= nil then
		f.pitchGoal = math.rad(f.cfg.pitch)
	end
	return self
end

-- Points the camera (degrees); instant = true skips the smoothing.
function FollowHandle:setAngles(yawDeg, pitchDeg, instant)
	local f = self._state
	if not f or F ~= f then
		return self
	end
	if finite(yawDeg) then
		f.yawGoal = math.rad(yawDeg)
		f.lockedYaw = f.yawGoal
		if instant then
			f.yaw = f.yawGoal
		end
	end
	if finite(pitchDeg) then
		f.pitchGoal = math.rad(pitchDeg)
		if instant then
			f.pitch = math.clamp(f.pitchGoal, math.rad(f.cfg.pitchMin), math.rad(f.cfg.pitchMax))
		end
	end
	return self
end

-- Moves the camera to the other shoulder (or to `side`: 1 right, -1 left), easing across.
function FollowHandle:switchShoulder(side)
	local f = self._state
	if not f or F ~= f then
		return self
	end
	local s = if type(side) == "number" then (if side < 0 then -1 else 1) else -f.cfg.shoulder
	f.user.shoulder = s
	f.cfg.shoulder = s
	return self
end

-- The rig's current numbers (for debugging and tests).
function FollowHandle:state()
	local f = self._state
	if not f then
		return nil
	end
	return { active = F == f, cframe = f.cf, fov = f.outFov, focus = f.focus, distance = f.dist,
		yaw = math.deg(f.yaw or 0), pitch = math.deg(f.pitch or 0), speed = f.vel and f.vel.Magnitude or 0 }
end

-- Stops following and hands the camera back (type and FOV as they were), unless a shot is playing.
function FollowHandle:stop()
	local f = self._state
	if f then
		stopFollow(f, true)
	end
end
FollowHandle.Destroy = FollowHandle.stop

-- The active follow handle, if any.
function CameraRig.current()
	return F and F.handle or nil
end

------------------------------------------------------------------------------------------------ shots
local ShotHandle = {}
ShotHandle.__index = ShotHandle

local function newShotHandle()
	return setmetatable({ status = "playing", done = false, _waiters = {}, _threads = {} }, ShotHandle)
end

-- Callbacks and awaiting threads run deferred, after the rig's own state is settled (a callback may start the
-- next shot).
local function settle(h, status)
	if h.done then
		return
	end
	h.done = true
	h.status = status
	for _, fn in h._waiters do
		task.defer(fn, status)
	end
	for _, co in h._threads do
		task.defer(function()
			if coroutine.status(co) == "suspended" then
				task.spawn(co, status)
			end
		end)
	end
	h._waiters, h._threads = {}, {}
end

-- Calls fn(status) when the shot or sequence ends: "done", "skipped", "cancelled" or "interrupted".
function ShotHandle:andThen(fn)
	if type(fn) ~= "function" then
		return self
	end
	if self.done then
		task.defer(fn, self.status)
	else
		table.insert(self._waiters, fn)
	end
	return self
end

-- Yields until the shot or sequence ends; returns its status.
function ShotHandle:await()
	if self.done then
		return self.status
	end
	table.insert(self._threads, coroutine.running())
	return coroutine.yield()
end

local finishSequence, beginOut -- forward declarations

-- Jumps to the end and blends back to the gameplay camera.
function ShotHandle:skip()
	local s = S
	if s and s.handle == self and s.phase == "shot" then
		s.skipped = true
		stopBeats(s.beats)
		local last = s.shots[#s.shots]
		beginOut(s, s.lastCF or lastPoseCF, s.lastFov or lastPoseFov, math.min(last.blendOut, SKIP_BLEND))
	end
	return self
end

-- Stops now and snaps back.
function ShotHandle:cancel()
	local s = S
	if s and s.handle == self then
		finishSequence(s, "cancelled")
	end
	return self
end
ShotHandle.Destroy = ShotHandle.cancel

local bars = nil
local function letterboxBars()
	if bars and bars.gui.Parent then
		return bars
	end
	local player = Players.LocalPlayer
	local pg = player and player:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return nil
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "KitLetterbox"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 95
	pcall(function()
		gui.ScreenInsets = Enum.ScreenInsets.None
	end)
	local function bar(y)
		local f = Instance.new("Frame")
		f.Name = if y == 0 then "Top" else "Bottom"
		f.BorderSizePixel = 0
		f.BackgroundColor3 = Color3.new(0, 0, 0)
		f.AnchorPoint = Vector2.new(0, y)
		f.Position = UDim2.fromScale(0, y)
		f.Size = UDim2.fromScale(1, 0)
		f.Parent = gui
		return f
	end
	bars = { gui = gui, top = bar(0), bottom = bar(1) }
	gui.Parent = pg
	return bars
end

-- Letterbox bars: spec true or { ratio = 2.39, color = Color3, seconds = 0.45, displayOrder = 95, maxFraction = 0.25 }.
local function setLetterbox(on, spec)
	local b = letterboxBars()
	if not b then
		return
	end
	local o = normalize(if type(spec) == "table" then spec else {}, FxMath.CAMERA_NESTED_KEYS.letterbox, "letterbox")
	local seconds = num(o.seconds, 0.45, 0, 10, "letterbox.seconds")
	local frac = 0
	if on then
		local vp = workspace.CurrentCamera.ViewportSize
		frac = FxMath.letterbox(vp.X, vp.Y, num(o.ratio, 2.39, 1, 10, "letterbox.ratio"),
			num(o.maxFraction, 0.25, 0, 0.5, "letterbox.maxFraction"))
		local color = toColor(o.color, Color3.new(0, 0, 0))
		b.top.BackgroundColor3, b.bottom.BackgroundColor3 = color, color
		b.gui.DisplayOrder = num(o.displayOrder, 95, -1000, 100000, "letterbox.displayOrder")
	end
	local info = TweenInfo.new(seconds, Enum.EasingStyle.Quint,
		if on then Enum.EasingDirection.Out else Enum.EasingDirection.InOut)
	TweenService:Create(b.top, info, { Size = UDim2.fromScale(1, frac) }):Play()
	TweenService:Create(b.bottom, info, { Size = UDim2.fromScale(1, frac) }):Play()
end

local function controls()
	local player = Players.LocalPlayer
	local ps = player and player:FindFirstChildOfClass("PlayerScripts")
	local pm = ps and ps:FindFirstChild("PlayerModule")
	if not pm then
		return nil
	end
	local ok, mod = pcall(require, pm)
	if not ok or type(mod) ~= "table" or type(mod.GetControls) ~= "function" then
		return nil
	end
	local ok2, c = pcall(mod.GetControls, mod)
	return if ok2 then c else nil
end

local function lockControls(on)
	local c = controls()
	if c then
		pcall(function()
			if on then
				c:Disable()
			else
				c:Enable()
			end
		end)
	end
end

local SKIP_INPUTS = { [Enum.KeyCode.Space] = true, [Enum.KeyCode.Return] = true, [Enum.KeyCode.ButtonA] = true,
	[Enum.KeyCode.ButtonStart] = true }

local function prepareShot(spec, index)
	local s = normalize(spec, FxMath.SHOT_KEYS, "shot")
	local shot = { spec = s, index = index }
	shot.move = num(s.duration, 1, 0, 600, "shot duration")
	shot.hold = num(s.hold, 0, 0, 600, "shot hold")
	shot.blendIn = num(s.blendIn, 0, 0, 60, "shot blendIn")
	shot.blendOut = num(s.blendOut, 0.6, 0, 60, "shot blendOut")
	local fn, problem = FxMath.easeFn(s.ease, nil, "sine", "inout")
	if problem then
		warnOnce("ease:" .. problem, "shot ease: " .. problem)
	end
	shot.ease = fn
	shot.timeScaled = s.timeScaled == true
	shot.track = s.track == true
	shot.lookOffset = if typeof(s.lookOffset) == "Vector3" then s.lookOffset else Vector3.zero
	if s.orbit ~= nil then
		shot.mode = "orbit"
		local o = normalize(s.orbit, FxMath.CAMERA_NESTED_KEYS.orbit, "shot orbit")
		shot.orbitTarget = o.target
		shot.r0, shot.r1 = pair(o.radius, 12, 0, 10000, "orbit radius")
		shot.h0, shot.h1 = pair(o.height, 3, -10000, 10000, "orbit height")
		shot.a0 = num(o.from, 0, -100000, 100000, "orbit from")
		shot.a1 = num(o.to, shot.a0 + 90, -100000, 100000, "orbit to")
		if targetPosition(o.target) == nil then
			warnOnce("orbit:target", "shot orbit needs target (a part, model, attachment or Vector3)")
		end
	elseif s.path ~= nil or typeof(s.from) == "Vector3" or typeof(s.to) == "Vector3" then
		shot.mode = "path"
	else
		shot.mode = "frames"
		if s.from ~= nil and s.from ~= "current" and typeof(s.from) ~= "CFrame" then
			warnOnce("from:type", "shot from must be a CFrame, a Vector3 or \"current\"")
		end
		if s.to ~= nil and typeof(s.to) ~= "CFrame" then
			warnOnce("to:type", "shot to must be a CFrame or a Vector3")
		end
	end
	if type(s.handheld) == "number" then
		shot.handAmount = num(s.handheld, 0, 0, 50, "handheld")
		shot.handRot, shot.handFreq = shot.handAmount * 4, 0.9
	elseif type(s.handheld) == "table" then
		local h = normalize(s.handheld, FxMath.CAMERA_NESTED_KEYS.handheld, "handheld")
		shot.handAmount = num(h.amount, 0.15, 0, 50, "handheld.amount")
		shot.handRot = num(h.rotation, 0.4, 0, 45, "handheld.rotation")
		shot.handFreq = num(h.frequency, 0.9, 0.01, 30, "handheld.frequency")
	else
		shot.handAmount, shot.handRot, shot.handFreq = 0, 0, 1
	end
	shot.seed = index * 7.31
	return shot
end

local function sampleShot(shot, tau)
	local u = if shot.move > 0 then math.clamp(tau / shot.move, 0, 1) else 1
	local e = shot.ease(u)
	local anchor = shot.anchor
	if shot.track and shot.anchorTarget then
		anchor = targetFrame(shot.anchorTarget) or anchor
	end
	local cf
	if shot.mode == "frames" then
		cf = shot.from:Lerp(shot.to, e)
		if anchor then
			cf = anchor * cf
		end
	elseif shot.mode == "path" then
		local p = FxMath.pathAt(shot.path, e)
		local ahead = FxMath.pathAt(shot.path, math.min(e + 0.02, 1))
		local behind = FxMath.pathAt(shot.path, math.max(e - 0.02, 0))
		if anchor then
			p = anchor:PointToWorldSpace(p)
			ahead = anchor:PointToWorldSpace(ahead)
			behind = anchor:PointToWorldSpace(behind)
		end
		local look = nil
		local la = shot.spec.lookAt
		if type(la) == "table" and typeof(la[1]) == "Vector3" and typeof(la[2]) == "Vector3" then
			look = la[1]:Lerp(la[2], e)
			if anchor then
				look = anchor:PointToWorldSpace(look)
			end
		elseif typeof(la) == "Vector3" and anchor then
			look = anchor:PointToWorldSpace(la)
		elseif la ~= nil then
			look = targetPosition(la)
		end
		if look then
			look += shot.lookOffset
			shot.lastLook = look
		elseif la ~= nil then
			look = shot.lastLook
		end
		if not look then
			local dir = ahead - behind
			look = p + (if dir.Magnitude > 1e-4 then dir.Unit else Vector3.new(0, 0, -1))
		end
		cf = safeLookAt(p, look)
	else
		local center = targetPosition(shot.orbitTarget) or shot.orbitCenter or Vector3.zero
		shot.orbitCenter = center
		local ox, oy, oz = FxMath.orbitOffset(shot.r0 + (shot.r1 - shot.r0) * e, shot.h0 + (shot.h1 - shot.h0) * e,
			shot.a0 + (shot.a1 - shot.a0) * e)
		cf = safeLookAt(center + shot.orbitFrame:VectorToWorldSpace(Vector3.new(ox, oy, oz)), center + shot.lookOffset)
	end
	local roll = shot.roll0 + (shot.roll1 - shot.roll0) * e
	if roll ~= 0 then
		cf *= CFrame.Angles(0, 0, math.rad(roll))
	end
	if shot.handAmount > 0 or shot.handRot > 0 then
		local ms = motionScale()
		if ms > 0 then
			local nx, ny, nz = FxMath.handheld(shot.clock, shot.handFreq, shot.seed)
			local a, r = shot.handAmount * ms, math.rad(shot.handRot) * ms
			cf *= CFrame.new(nx * a, ny * a, 0) * CFrame.Angles(ny * r, nx * r, nz * r * 0.5)
		end
	end
	return cf, shot.fov0 + (shot.fov1 - shot.fov0) * e
end

local function beginShot(s, i, fromCF, fromFov)
	local shot = s.shots[i]
	local spec = shot.spec
	s.i, s.t = i, 0
	shot.clock = 0
	shot.startCF, shot.startFov = fromCF, fromFov
	shot.anchor, shot.anchorTarget = nil, nil
	if spec.relativeTo ~= nil then
		shot.anchor = targetFrame(spec.relativeTo)
		shot.anchorTarget = spec.relativeTo
		if not shot.anchor then
			warnOnce("relativeTo", "shot relativeTo must be a part, model, attachment, humanoid or CFrame")
		end
	end
	local anchor = shot.anchor
	if shot.mode == "frames" then
		local from = spec.from
		if typeof(from) == "CFrame" then
			shot.from = from
		else
			shot.from = if anchor then anchor:ToObjectSpace(fromCF) else fromCF
		end
		shot.to = if typeof(spec.to) == "CFrame" then spec.to else shot.from
	elseif shot.mode == "path" then
		local points = {}
		if type(spec.path) == "table" then
			for _, p in spec.path do
				if typeof(p) == "Vector3" then
					table.insert(points, p)
				end
			end
		else
			local here = if anchor then anchor:PointToObjectSpace(fromCF.Position) else fromCF.Position
			table.insert(points, if typeof(spec.from) == "Vector3" then spec.from else here)
			if typeof(spec.to) == "Vector3" then
				table.insert(points, spec.to)
			end
		end
		if #points == 0 then
			warnOnce("path:empty", "shot path needs Vector3 points")
			table.insert(points, if anchor then anchor:PointToObjectSpace(fromCF.Position) else fromCF.Position)
		end
		shot.path = FxMath.path(points)
		shot.lastLook = nil
	else
		local tf = targetFrame(shot.orbitTarget)
		if tf and typeof(shot.orbitTarget) ~= "Vector3" then
			local lv = tf.LookVector
			shot.orbitFrame = CFrame.fromEulerAnglesYXZ(0, math.atan2(-lv.X, -lv.Z), 0)
		else
			shot.orbitFrame = CFrame.identity
		end
		shot.orbitCenter = nil
	end
	if type(spec.fov) == "table" then
		shot.fov0, shot.fov1 = pair(spec.fov, fromFov, 1, 120, "shot fov")
	else
		local fov = num(spec.fov, fromFov, 1, 120, "shot fov")
		shot.fov0, shot.fov1 = fov, fov
	end
	shot.roll0, shot.roll1 = pair(spec.roll, 0, -180, 180, "shot roll")
	local lb = spec.letterbox
	if lb == nil then
		lb = s.letterbox
	end
	if lb and lb ~= false then
		if not s.letterboxOn then
			setLetterbox(true, lb)
			s.letterboxOn, s.letterboxSpec = true, lb
		end
	elseif s.letterboxOn then
		setLetterbox(false, s.letterboxSpec)
		s.letterboxOn = false
	end
	if spec.slowmo ~= nil and shot.move + shot.hold > 0 then
		local sm = spec.slowmo
		local id = nil
		if type(sm) == "number" then
			id = CameraRig.slowmo(sm, shot.move + shot.hold)
		elseif type(sm) == "table" then
			local o = normalize(sm, FxMath.CAMERA_NESTED_KEYS.slowmo, "shot slowmo")
			id = CameraRig.slowmo(num(o.scale, 0.3, 0, 1, "slowmo.scale"), num(o.seconds, shot.move + shot.hold, 0.01, 60,
				"slowmo.seconds"), { rampIn = o.rampIn, rampOut = o.rampOut })
		else
			warnOnce("shot slowmo:type", "shot slowmo must be a scale (number) or { scale, seconds, rampIn, rampOut }")
		end
		if id then
			table.insert(s.beats, id)
		end
	end
	if type(spec.onStart) == "function" then
		task.spawn(spec.onStart, i)
	end
	if Debug then
		Debug.event("camera_shot", { sequence = s.name, shot = spec.name or i, index = i, count = #s.shots,
			seconds = shot.move + shot.hold })
	end
end

beginOut = function(s, cf, fov, duration)
	s.phase = "out"
	s.outCF, s.outFov = cf, fov
	s.outT, s.outDur = 0, duration
	if s.letterboxOn then
		setLetterbox(false, s.letterboxSpec)
		s.letterboxOn = false
	end
	if s.controlsLocked then
		lockControls(false)
		s.controlsLocked = false
	end
	if s.skipConn then
		s.skipConn:Disconnect()
		s.skipConn = nil
	end
	-- no follow to return to: hand the camera back now so the default camera can be blended into
	if F == nil then
		handBack()
	end
end

finishSequence = function(s, status)
	if S == s then
		S = nil
	end
	if s.letterboxOn then
		setLetterbox(false, s.letterboxSpec)
		s.letterboxOn = false
	end
	if s.controlsLocked then
		lockControls(false)
		s.controlsLocked = false
	end
	if s.skipConn then
		s.skipConn:Disconnect()
		s.skipConn = nil
	end
	if status ~= "done" then
		stopBeats(s.beats)
	end
	local player = Players.LocalPlayer
	if status ~= "interrupted" then
		if player and S == nil then
			player:SetAttribute("KitCinematic", nil)
		end
		if S == nil and F == nil then
			releaseCamera()
		end
	end
	if type(s.onDone) == "function" then
		task.defer(s.onDone, status)
	end
	settle(s.handle, status)
	if Debug then
		Debug.event("camera_sequence_done", { sequence = s.name, status = status })
	end
end

local function stepSequence(s, dt, baseCF, baseFov)
	if s.phase == "shot" then
		local shot = s.shots[s.i]
		s.t += dt * (if shot.timeScaled then CameraRig.timeScale else 1)
		shot.clock += dt
		while s.t >= shot.move + shot.hold do
			local over = s.t - (shot.move + shot.hold)
			local endCF, endFov = sampleShot(shot, shot.move + shot.hold)
			if s.i < #s.shots then
				beginShot(s, s.i + 1, endCF, endFov)
				shot = s.shots[s.i]
				s.t = over
			else
				beginOut(s, endCF, endFov, shot.blendOut)
				break
			end
		end
	end
	if s.phase == "shot" then
		local shot = s.shots[s.i]
		local cf, fov = sampleShot(shot, s.t)
		if shot.blendIn > 0 and s.t < shot.blendIn then
			local w = BLEND(s.t / shot.blendIn)
			cf = shot.startCF:Lerp(cf, w)
			fov = shot.startFov + (fov - shot.startFov) * w
		end
		s.lastCF, s.lastFov = cf, fov
		return cf, fov
	end
	s.outT += dt
	local w = if s.outDur > 0 then BLEND(s.outT / s.outDur) else 1
	local cf = s.outCF:Lerp(baseCF, w)
	local fov = s.outFov + (baseFov - s.outFov) * w
	if s.outT >= s.outDur then
		finishSequence(s, if s.skipped then "skipped" else "done")
	end
	return cf, fov
end

local function resolvedHandle(status)
	local h = newShotHandle()
	settle(h, status)
	return h
end

-- Plays authored shots back to back and returns a promise-like handle (:andThen(fn), :await(), :skip(), :cancel()).
-- Each shot is one of:
--   frames: { from = CFrame | "current", to = CFrame }
--   path:   { path = {Vector3...} or from = Vector3, to = Vector3, lookAt = target | {Vector3, Vector3} }
--   orbit:  { orbit = { target =, radius = n | {a, b}, height = n | {a, b}, from = deg, to = deg } }  0 = behind
-- plus duration, hold, ease ("Sine InOut"), fov (n | {from, to}), roll (deg | {a, b}), handheld (studs or
-- {amount, rotation, frequency}), relativeTo (part / model / CFrame: positions are in its space), track, lookOffset,
-- blendIn (0 = cut), blendOut (last shot: back to the gameplay camera), letterbox, slowmo (scale or {scale,
-- seconds, rampIn, rampOut}), timeScaled, onStart(i).
-- opts: letterbox (true | {ratio, color, seconds}), skipInput, lockControls, onDone(status), blendOut, name.
function CameraRig.sequence(shots, opts)
	if not IS_CLIENT then
		warnOnce("sequence:server", "shots run on the client only")
		return resolvedHandle("cancelled")
	end
	if type(shots) ~= "table" or #shots == 0 then
		warnOnce("sequence:empty", "sequence needs a list of shots")
		return resolvedHandle("cancelled")
	end
	local o = normalize(opts or {}, FxMath.SEQUENCE_KEYS, "sequence")
	local prepared = {}
	for i, spec in ipairs(shots) do
		if type(spec) == "table" then
			table.insert(prepared, prepareShot(spec, i))
		else
			warnOnce("shot:type", "every shot must be a table")
		end
	end
	if #prepared == 0 then
		return resolvedHandle("cancelled")
	end
	if o.blendOut ~= nil then
		prepared[#prepared].blendOut = num(o.blendOut, 0.6, 0, 60, "sequence blendOut")
	end
	local barsOn, barsSpec = false, nil
	if S then
		barsOn, barsSpec = S.letterboxOn, S.letterboxSpec
		S.letterboxOn = false -- the new sequence takes the bars over
		finishSequence(S, "interrupted")
	end
	local cam = workspace.CurrentCamera
	takeCamera(cam)
	local h = newShotHandle()
	local s = { shots = prepared, handle = h, phase = "shot", i = 1, t = 0, letterbox = o.letterbox,
		onDone = o.onDone, name = o.name, started = os.clock(), letterboxOn = barsOn, letterboxSpec = barsSpec,
		beats = {} }
	S = s
	local fromCF = lastPoseCF or (cam and cam.CFrame) or CFrame.identity
	local fromFov = lastPoseFov or (cam and cam.FieldOfView) or 70
	beginShot(s, 1, fromCF, fromFov)
	s.lastCF, s.lastFov = fromCF, fromFov
	if o.lockControls then
		lockControls(true)
		s.controlsLocked = true
	end
	if o.skipInput then
		s.skipConn = UserInputService.InputBegan:Connect(function(io, processed)
			if processed or os.clock() - s.started < 0.3 then
				return
			end
			if SKIP_INPUTS[io.KeyCode] or io.UserInputType == Enum.UserInputType.Touch
				or io.UserInputType == Enum.UserInputType.MouseButton1 then
				h:skip()
			end
		end)
	end
	local player = Players.LocalPlayer
	if player then
		player:SetAttribute("KitCinematic", true)
	end
	ensureBound()
	return h
end

-- One authored shot (see sequence); the shot's own letterbox / skipInput / lockControls / onDone apply.
function CameraRig.shot(spec)
	if type(spec) ~= "table" then
		warnOnce("shot:type", "shot needs a table")
		return resolvedHandle("cancelled")
	end
	local s = normalize(spec, FxMath.SHOT_KEYS, "shot")
	return CameraRig.sequence({ spec }, { skipInput = s.skipInput, lockControls = s.lockControls, onDone = s.onDone,
		name = s.name })
end

-- True while a shot or sequence runs (the LocalPlayer attribute "KitCinematic" says the same, for HUD scripts).
function CameraRig.isCinematic()
	return S ~= nil
end

-- The rig's last camera pose and FOV (before kicks and punches), or nil when idle.
function CameraRig.pose()
	return lastPoseCF, lastPoseFov
end

------------------------------------------------------------------------------------------------ the render step
-- The pose the camera goes back to without the rig: the game's camera as it is now, or where a scriptable game
-- camera was when the rig took over; and the FOV it had then.
local function restoreBase(cam)
	local cf, fov = idleBase(cam)
	if saved then
		fov = saved.fov
		if saved.cameraType == SCRIPTABLE then
			cf = saved.cf
		end
	end
	return cf, fov
end

local function owning()
	return F ~= nil or (S ~= nil and S.phase == "shot")
end

step = function(dt)
	dt = if finite(dt) then math.clamp(dt, 0, 0.1) else 0
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local slowing = stepSlowmo(dt)
	local ms = motionScale()
	local kick, kicking = stepKicks(dt)
	kick *= ms
	local punching = stepPunch(dt)
	if owning() then
		takeCamera(cam)
		if cam.CameraType ~= SCRIPTABLE then
			cam.CameraType = SCRIPTABLE
		end
	end
	-- the base pose: the follow rig's, else the camera the game has (what shots start from and blend back to)
	local cf, fov, focus = nil, nil, nil
	if F then
		cf, fov, focus = stepFollow(F, dt, cam, S == nil)
		cf = cf or lastPoseCF or cam.CFrame -- no subject yet: hold still
		fov = fov or lastPoseFov or cam.FieldOfView
	elseif S ~= nil or kicking or punching then
		cf, fov = restoreBase(cam)
	end
	if cf == nil then
		-- idle: take back what we added last frame (if nobody replaced it), hand the camera back, stop stepping
		if wroteCF ~= nil then
			if cam.CFrame == wroteCF then
				cam.CFrame = wroteBaseCF
			end
			wroteCF = nil
		end
		if wroteFov ~= nil then
			if math.abs(cam.FieldOfView - wroteFov) < 1e-3 then
				cam.FieldOfView = wroteBaseFov
			end
			wroteFov = nil
		end
		if saved then
			releaseCamera()
		end
		lastPoseCF, lastPoseFov = nil, nil
		if not slowing and CameraRig.timeScale == 1 then
			unbind()
		end
		return
	end
	local baseCF, baseFov = cf, fov
	if S then
		cf, fov = stepSequence(S, dt, cf, fov) -- may finish the sequence (and hand the camera back)
		focus = nil
	end
	local p = cf.Position
	if not (finite(p.X) and finite(p.Y) and finite(p.Z) and finite(fov)) then
		-- a bad value got in somewhere (a NaN target, a broken spring): never hand it to the camera; reset and retry
		warnOnce("nan", "the camera pose became invalid (NaN); reset")
		punchPos, punchVel = Vector3.zero, Vector3.zero
		if F then
			F.started = false
		end
		return
	end
	if owning() then
		lastPoseCF, lastPoseFov = cf, fov
		wroteCF, wroteFov = nil, nil
		cam.CFrame = applyPunch(cf, ms, true)
		cam.Focus = CFrame.new(focus or (cf.Position + cf.LookVector * 12))
		cam.FieldOfView = math.clamp(fov + kick, 1, 120)
	else
		-- someone else's camera (blending out of a shot, or kicks over the default camera): translation only, so
		-- camera scripts that read the camera's orientation back never drift; remember what we wrote to undo it
		if S then
			lastPoseCF, lastPoseFov = cf, fov
		else
			lastPoseCF, lastPoseFov = nil, nil
		end
		local out = applyPunch(cf, ms, false)
		cam.CFrame = out
		wroteCF, wroteBaseCF = out, handBackBase or baseCF -- right after a hand-back, the pose to resume from
		handBackBase = nil
		local outFov = math.clamp(fov + kick, 1, 120)
		cam.FieldOfView = outFov
		wroteFov, wroteBaseFov = outFov, baseFov
	end
end

if Debug then
	Debug.register("__camera_rig", function()
		local f = F
		return { follow = f ~= nil, preset = f and tostring(f.user.preset or "custom") or nil,
			distance = f and f.dist or nil, fov = f and f.outFov or nil, cinematic = S ~= nil,
			timeScale = CameraRig.timeScale }
	end, "the camera rig's state (follow, cinematic, time scale)")
end

return CameraRig
