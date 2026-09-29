--!native
-- Anim: keyframe animation clips (authored as data with author_clip) on any Motor6D rig, plus procedural layers.
--   local Anim = require(ReplicatedStorage.Kit.Anim)
--   local rig = Anim.load(character)                     -- one player per rig (cached); R15, R6 or custom Motor6Ds
--   local track = rig:play("slash", { fade = 0.1 })      -- options: fade, speed, weight, priority, looped, hold, restart
--   track.Marker("hit"):Connect(function() Sound.play("hit") end)   -- sync sound / VFX to the contact frame
--   track.Ended:Connect(fn); track:stop(0.2); track:adjustSpeed(speed / 16); rig:stopAll(0.2)
--   rig:takeOver(true)     -- pause the rig's own AnimationTracks (the default Animate script) while clips play
--   rig:lean(1); rig:lookAt(target.Position); rig:breathe(true); rig:recoil("RightShoulder", { -30, 0, 0 }, 0.3)
-- Clips come from Anim.register(clip) or the generated ReplicatedStorage.Shared.ClipPack (loaded on first use).
-- Per joint, a higher priority (action > movement > idle > core) overrides lower ones; the same priority blends by
-- weight; fades are smooth. play() of a looped clip that is already playing returns that track (call it every
-- frame from a state machine if you like); play() of a one-shot restarts it, crossfading from the old one.
-- A one-shot holds its last pose while it fades out (fadeOut, default fade), or until stop() with hold = true.
--
-- With Roblox's Animator: Anim writes Motor6D.Transform in RunService.PreSimulation, which runs after the
-- Animator has posed the rig for the frame, and blends over that pose. Joints no clip poses keep the Animator's
-- animation (a clip keying only the arms plays over the default walk), and fades blend from and back to it.
-- takeOver(true) pauses the rig's own tracks instead (weight 0, speed 0) while clips play, and restores them after.
-- Motor6D.Transform does not replicate: play clips on every client that should see them (e.g. the server fires a
-- RemoteEvent with the clip name and each client plays it on that character). On the server it only moves the
-- server's copy of the rig (useful for hitboxes that follow a swing).
-- Bad data never errors: bad clips, unknown names and wrong arguments warn once and do nothing.
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnimCore = require(script.Parent:WaitForChild("AnimCore"))
local Spring = require(script.Parent:WaitForChild("Spring"))

local euler, mul, slerp, fromMatrix = AnimCore.euler, AnimCore.mul, AnimCore.slerp, AnimCore.fromMatrix
local rotateVector = AnimCore.rotate
local abs, clamp, sqrt, atan2, deg = math.abs, math.clamp, math.sqrt, math.atan2, math.deg

local Anim = {}
Anim.Core = AnimCore

local warned = {}
local function warnOnce(key, message)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("[Anim] " .. message)
end

local function finite(x)
	return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end

local function num(x, default)
	x = tonumber(x)
	if finite(x) then
		return x
	end
	return default
end

-- Signal -------------------------------------------------------------------------------------------------
-- Handlers run deferred (after the animation step), so they may play / stop tracks freely and an error in one
-- does not stop the others.
local Signal = {}
Signal.__index = Signal

function Signal.new()
	return setmetatable({ _handlers = {} }, Signal)
end

function Signal:Connect(fn)
	local handlers = self._handlers
	local connection
	connection = {
		Connected = true,
		Disconnect = function()
			connection.Connected = false
			handlers[connection] = nil
		end,
	}
	handlers[connection] = fn
	return connection
end

function Signal:Once(fn)
	local connection
	connection = self:Connect(function(...)
		connection.Disconnect()
		fn(...)
	end)
	return connection
end

function Signal:Wait()
	local thread = coroutine.running()
	self:Once(function(...)
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

function Signal:Fire(...)
	for _, fn in self._handlers do
		task.defer(fn, ...)
	end
end

-- Tracks -------------------------------------------------------------------------------------------------
-- A track is AnimCore's track state (time, speed, weight, looped, ...) with methods and signals:
--   track.name, track.length, track.looped, track.time, track.speed, track.weight, track.isPlaying
--   track:stop(fade), track:adjustSpeed(x), track:adjustWeight(w, fade), track:setTime(t)
--   track.Marker(name) -> signal (also track:Marker(name), track:GetMarkerReachedSignal(name))
--   track.MarkerReached (name), track.Stopped (starts fading out), track.Ended / track.ended (gone)
local Track = {}
Track.__index = Track

local function wrapTrack(core)
	local track = setmetatable(core, Track)
	track.Ended = Signal.new()
	track.Stopped = Signal.new()
	track.MarkerReached = Signal.new()
	track.ended = track.Ended
	track.stopped = track.Stopped
	local markers = {}
	track._markers = markers
	track.Marker = function(a, b)
		local name = tostring(if a == track then b else a)
		local signal = markers[name]
		if signal == nil then
			signal = Signal.new()
			markers[name] = signal
		end
		return signal
	end
	return track
end

function Track:GetMarkerReachedSignal(name)
	return self.Marker(name)
end

function Track:stop(fade)
	if AnimCore.stop(self, fade) then
		self.Stopped:Fire()
		local player = self._player
		if player then
			player:_wake()
		end
	end
end
Track.Stop = Track.stop

function Track:adjustSpeed(speed)
	speed = num(speed, nil)
	if speed ~= nil then
		self.speed = clamp(speed, -100, 100)
	end
end
Track.AdjustSpeed = Track.adjustSpeed

function Track:adjustWeight(weight, fade)
	AnimCore.setWeight(self, weight, fade)
end
Track.AdjustWeight = Track.adjustWeight

-- Jumps to time t (seconds) without firing the markers in between.
function Track:setTime(t)
	t = num(t, nil)
	if t == nil or self.state == "ended" then
		return
	end
	local length = self.clip.length
	if self.looped then
		t -= math.floor(t / length) * length
	else
		t = clamp(t, 0, length)
	end
	self.time = t
end

local function onTrackEvent(track, kind, name)
	if kind == "marker" then
		track.MarkerReached:Fire(name)
		local signal = track._markers[name]
		if signal then
			signal:Fire(name)
		end
	elseif kind == "stopped" then
		track.Stopped:Fire()
	elseif kind == "ended" then
		track.Ended:Fire()
	end
end

local NULL_CLIP = {
	_compiled = true, name = "", length = 1, looped = false, priority = 1, priorityName = "core",
	channels = {}, index = {}, joints = {}, count = 0, markers = {},
}

-- A track that is already over: returned when there is nothing to play, so calling code never errors.
local function nullTrack(name)
	local core = AnimCore.newTrack(NULL_CLIP)
	core.state = "ended"
	core.isPlaying = false
	core.w = 0
	core.name = name or ""
	return wrapTrack(core)
end

-- Clips --------------------------------------------------------------------------------------------------
local registry = {} -- name -> compiled clip
local compiledFor = setmetatable({}, { __mode = "k" }) -- clip table -> compiled clip, or false if it is bad
local pack = { loaded = false, tried = -math.huge }

local function labelOf(data)
	if type(data) == "table" and type(data.name) == "string" then
		return "'" .. data.name .. "'"
	end
	return "(unnamed)"
end

local function compile(data)
	local ok, clip, problems = pcall(AnimCore.compile, data)
	if not ok then
		warnOnce("bad:" .. labelOf(data), "clip " .. labelOf(data) .. " could not be read: " .. tostring(clip))
		return nil
	end
	if clip == nil then
		local shown = table.concat(problems, "; ", 1, math.min(#problems, 5))
		warnOnce("bad:" .. labelOf(data), "clip " .. labelOf(data) .. " rejected: " .. shown
			.. (if #problems > 5 then " ..." else ""))
		return nil
	end
	return clip
end

-- Validates and registers a clip table under its name. Returns the compiled clip, or nil (warned once).
function Anim.register(data)
	local clip = compile(data)
	if clip ~= nil then
		registry[clip.name] = clip
		if type(data) == "table" then
			compiledFor[data] = clip
		end
	end
	return clip
end

-- ReplicatedStorage.Shared.ClipPack: required on first need, looked up again at most once a second until it
-- exists (it may replicate after the first play). Clips registered from code win over the pack's.
local function loadPack()
	if pack.loaded then
		return
	end
	local now = os.clock()
	if now - pack.tried < 1 then
		return
	end
	pack.tried = now
	local shared = ReplicatedStorage:FindFirstChild("Shared")
	local module = shared and shared:FindFirstChild("ClipPack")
	if module == nil or not module:IsA("ModuleScript") then
		return
	end
	pack.loaded = true
	local ok, clips = pcall(require, module)
	if not ok or type(clips) ~= "table" then
		warnOnce("pack", "ReplicatedStorage.Shared.ClipPack failed to load: " .. tostring(clips))
		return
	end
	for name, data in clips do
		if type(data) == "table" and registry[name] == nil then
			if data.name == nil then
				data.name = name
			end
			Anim.register(data)
		end
	end
end

-- The compiled clip registered (or packed) under name, or nil.
function Anim.clip(name)
	local clip = registry[name]
	if clip == nil and type(name) == "string" then
		loadPack()
		clip = registry[name]
	end
	return clip
end

-- Names of every known clip (registered and packed), sorted.
function Anim.clips()
	loadPack()
	local names = {}
	for name in registry do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

local function resolve(clipOrName)
	if type(clipOrName) == "string" then
		local clip = Anim.clip(clipOrName)
		if clip == nil then
			warnOnce("missing:" .. clipOrName, "no clip named '" .. clipOrName
				.. "': author it with author_clip (ReplicatedStorage.Shared.ClipPack) or Anim.register it")
		end
		return clip
	elseif type(clipOrName) == "table" then
		if clipOrName._compiled == true then
			return clipOrName
		end
		local clip = compiledFor[clipOrName]
		if clip == nil then
			clip = compile(clipOrName) or false
			compiledFor[clipOrName] = clip
		end
		return clip or nil
	end
	warnOnce("arg:" .. typeof(clipOrName), "play() needs a clip name or a clip table, got " .. typeof(clipOrName))
	return nil
end

-- Math helpers -------------------------------------------------------------------------------------------
local IDENTITY = CFrame.identity

local function quatOf(cf)
	local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
	return fromMatrix(r00, r01, r02, r10, r11, r12, r20, r21, r22)
end

local function sameCFrame(a, b)
	if a == b then
		return true
	end
	local ax, ay, az, a00, a01, a02, a10, a11, a12, a20, a21, a22 = a:GetComponents()
	local bx, by, bz, b00, b01, b02, b10, b11, b12, b20, b21, b22 = b:GetComponents()
	return abs(ax - bx) + abs(ay - by) + abs(az - bz) < 1e-4
		and abs(a00 - b00) + abs(a01 - b01) + abs(a02 - b02) + abs(a10 - b10) + abs(a11 - b11) + abs(a12 - b12)
				+ abs(a20 - b20) + abs(a21 - b21) + abs(a22 - b22)
			< 1e-4
end

-- At rest at 0: within eps (degrees for the rotation springs, where 0.01 is invisible) and barely moving.
local function settled(spring, eps)
	eps = eps or 1e-3
	return spring.Target == 0 and abs(spring.Position) < eps and abs(spring.Velocity) < eps * 5
end
local DEG_EPS = 0.01

-- A rotation given as { rx, ry, rz }, { rx = .., ry = .., rz = .. } or a Vector3 (degrees) -> rx, ry, rz.
local function rotationOf(value)
	if typeof(value) == "Vector3" then
		return value.X, value.Y, value.Z
	elseif type(value) == "table" then
		return num(value[1] or value.rx, 0), num(value[2] or value.ry, 0), num(value[3] or value.rz, 0)
	end
	return nil
end

local function targetPosition(target)
	local kind = typeof(target)
	if kind == "Vector3" then
		return target
	elseif kind == "Instance" then
		if target:IsA("BasePart") then
			return target.Position
		elseif target:IsA("Attachment") then
			return target.WorldPosition
		elseif target:IsA("Model") then
			return target:GetPivot().Position
		end
	end
	return nil
end

-- Players ------------------------------------------------------------------------------------------------
local Player = {}
Player.__index = Player

local players = setmetatable({}, { __mode = "k" }) -- rig -> player
local active = {} -- players with work to do this frame
local stepConnection = nil
local nextId = 0

local function newPlayer(rig)
	nextId += 1
	local self = setmetatable({
		id = nextId,
		rig = rig,
		tracks = {},
		nTracks = 0,
		slots = 0,
		motors = {},
		names = {},
		slotOf = {},
		axis = {},
		last = {},
		maps = {},
		mixer = AnimCore.newMixer(0),
		dirty = true,
		active = false,
		destroyed = false,
		connections = {},
		-- procedural layers
		leanAmount = 0,
		leanRoll = Spring.new(0, 9, 0.9),
		leanPitch = Spring.new(0, 9, 0.9),
		prevYaw = nil,
		look = nil,
		lookNeckYaw = Spring.new(0, 12, 1),
		lookNeckPitch = Spring.new(0, 12, 1),
		lookWaistYaw = Spring.new(0, 10, 1),
		lookWaistPitch = Spring.new(0, 10, 1),
		breath = false,
		breathRate = 0.25,
		breathDepth = 1,
		breathPhase = 0,
		breathWeight = Spring.new(0, 3, 1),
		recoils = {},
		squashState = nil,
		addX = {},
		addY = {},
		addZ = {},
		addW = {},
		addOn = {},
		takeover = false,
		suppressed = nil,
		animatorConnection = nil,
	}, Player)
	self.lookSprings = { self.lookNeckYaw, self.lookNeckPitch, self.lookWaistYaw, self.lookWaistPitch }
	if rig ~= nil then
		local function changed(d)
			if d:IsA("Motor6D") then
				self.dirty = true
			end
		end
		table.insert(self.connections, rig.DescendantAdded:Connect(changed))
		table.insert(self.connections, rig.DescendantRemoving:Connect(changed))
		table.insert(self.connections, rig.Destroying:Connect(function()
			self:destroy()
		end))
	end
	return self
end

-- The player for a rig (a character or any Model whose joints are Motor6Ds; a Humanoid means its character).
-- Always returns a player; for something that is not a rig it does nothing (warned once).
function Anim.load(rig)
	if typeof(rig) == "Instance" and rig:IsA("Humanoid") then
		rig = rig.Parent
	end
	if typeof(rig) ~= "Instance" then
		warnOnce("load:" .. typeof(rig), "Anim.load needs a character or rig Model, got " .. typeof(rig))
		return newPlayer(nil)
	end
	local player = players[rig]
	if player ~= nil and not player.destroyed then
		return player
	end
	player = newPlayer(rig)
	players[rig] = player
	return player
end

-- The rig's player if Anim.load made one, else nil.
function Anim.get(rig)
	local player = players[rig]
	if player ~= nil and not player.destroyed then
		return player
	end
	return nil
end

function Player:_rebuild()
	self.dirty = false
	local rig = self.rig
	if rig == nil then
		return
	end
	local lastByMotor = {}
	for s, cf in self.last do
		if self.motors[s] then
			lastByMotor[self.motors[s]] = cf
		end
	end
	local motors, names, slotOf = {}, {}, {}
	local incomplete, otherJoints = false, false
	for _, d in rig:GetDescendants() do
		if d:IsA("Motor6D") then
			if d.Part0 ~= nil and d.Part1 ~= nil then
				if slotOf[d.Name] == nil then
					table.insert(motors, d)
					table.insert(names, d.Name)
					slotOf[d.Name] = #motors
				else
					warnOnce("dup:" .. rig:GetFullName() .. ":" .. d.Name,
						rig:GetFullName() .. " has two joints named " .. d.Name .. "; Anim drives the first")
				end
			else
				incomplete = true
			end
		elseif d:IsA("AnimationConstraint") or d:IsA("Bone") then
			otherJoints = true
		end
	end
	self.motors, self.names, self.slotOf, self.slots = motors, names, slotOf, #motors
	self.last = {}
	for s, motor in motors do
		self.last[s] = lastByMotor[motor]
	end
	self.mixer = AnimCore.newMixer(#motors)
	self.addX, self.addY, self.addZ, self.addW, self.addOn = {}, {}, {}, {}, {}
	self.maps = {}
	for i = 1, self.nTracks do
		self.tracks[i].map = self:_mapFor(self.tracks[i].clip)
	end
	self:_restFrames()
	if #motors == 0 then
		if otherJoints then
			warnOnce("bones:" .. rig:GetFullName(), rig:GetFullName()
				.. " is jointed with AnimationConstraints or Bones, not Motor6Ds; Anim skips it")
		elseif not incomplete then
			warnOnce("nojoints:" .. rig:GetFullName(), rig:GetFullName() .. " has no Motor6D joints (yet)")
		end
	end
	self.rescanAt = if incomplete then os.clock() + 1 else nil
end

-- Each joint's axis frame: the character's axes at rest, carried into the joint (rest orientation of Part0 times
-- C0's rotation, relative to the character frame: the root part for humanoids, the model's pivot otherwise). Pose
-- rotations are given in these axes and conjugated into C0 space; on R15 every axis frame is the identity.
function Player:_restFrames()
	local rig = self.rig
	local motors = self.motors
	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	local root = humanoid and humanoid.RootPart or nil
	if root == nil and rig:IsA("Model") then
		root = rig.PrimaryPart
	end
	local isChild = {}
	for _, m in motors do
		isChild[m.Part1] = true
	end
	if root == nil then
		for _, m in motors do
			if not isChild[m.Part0] then
				root = m.Part0
				break
			end
		end
	end
	if root == nil and motors[1] ~= nil then
		root = motors[1].Part0
	end
	self.root = root
	local rest = {}
	if root ~= nil then
		if humanoid ~= nil or not rig:IsA("Model") then
			rest[root] = { 0, 0, 0, 1 }
		else
			local px, py, pz, pw = quatOf(rig:GetPivot())
			rest[root] = { mul(-px, -py, -pz, pw, quatOf(root.CFrame)) }
		end
		local changed, passes = true, 0
		while changed and passes < 64 do
			changed, passes = false, passes + 1
			for _, m in motors do
				local r0 = rest[m.Part0]
				if r0 ~= nil and rest[m.Part1] == nil then
					local cx, cy, cz, cw = quatOf(m.C0)
					local x, y, z, w = mul(r0[1], r0[2], r0[3], r0[4], cx, cy, cz, cw)
					local dx, dy, dz, dw = quatOf(m.C1)
					rest[m.Part1] = { mul(x, y, z, w, -dx, -dy, -dz, dw) }
					changed = true
				end
			end
		end
	end
	for s, m in motors do
		local r0 = rest[m.Part0]
		local x, y, z, w = 0, 0, 0, 1
		if r0 ~= nil then
			x, y, z, w = mul(r0[1], r0[2], r0[3], r0[4], quatOf(m.C0))
		elseif root ~= nil then -- not linked to the root through joints: use how it sits now
			local rx, ry, rz, rw = quatOf(root.CFrame)
			local px, py, pz, pw = quatOf(m.Part0.CFrame)
			local ax, ay, az, aw = mul(px, py, pz, pw, quatOf(m.C0))
			x, y, z, w = mul(-rx, -ry, -rz, rw, ax, ay, az, aw)
		end
		if w < 0 then
			x, y, z, w = -x, -y, -z, -w
		end
		self.axis[s] = if w > 0.999999 then false else { x, y, z, w }
	end
	for s = #motors + 1, #self.axis do
		self.axis[s] = nil
	end
end

function Player:_mapFor(clip)
	local map = self.maps[clip]
	if map == nil then
		map = table.create(clip.count, 0)
		local missing = nil
		for i, ch in clip.channels do
			local s = self.slotOf[ch.joint]
			if s ~= nil then
				map[i] = s
			else
				missing = missing or {}
				table.insert(missing, ch.joint)
			end
		end
		if missing ~= nil and self.slots > 0 then
			warnOnce("miss:" .. self.id .. ":" .. clip.name, "clip '" .. clip.name .. "' poses joints "
				.. self.rig.Name .. " does not have: " .. table.concat(missing, ", "))
		end
		self.maps[clip] = map
	end
	return map
end

local function stepAll(dt)
	local i = 1
	while i <= #active do
		local p = active[i]
		local keep = false
		if not p.destroyed then
			local ok, result = pcall(p._step, p, dt)
			if ok then
				keep = result
			else
				warnOnce("step:" .. p.id, "animating " .. (if p.rig then p.rig:GetFullName() else "?") .. " failed: "
					.. tostring(result))
				keep = true
			end
		end
		if keep then
			i += 1
		else
			p.active = false
			active[i] = active[#active]
			active[#active] = nil
		end
	end
end

function Player:_wake()
	if self.active or self.destroyed or self.rig == nil then
		return
	end
	self.active = true
	table.insert(active, self)
	if stepConnection == nil then
		local ok, signal = pcall(function()
			return RunService.PreSimulation
		end)
		if ok and signal ~= nil then
			stepConnection = signal:Connect(stepAll)
		else
			stepConnection = RunService.Stepped:Connect(function(_, dt)
				stepAll(dt)
			end)
		end
	end
end

-- Plays a clip (a name or a clip table) and returns its track. See the header for the options.
function Player:play(clipOrName, opts)
	local clip = resolve(clipOrName)
	if clip == nil or self.destroyed or self.rig == nil then
		return nullTrack(if type(clipOrName) == "string" then clipOrName else nil)
	end
	if self.dirty then
		self:_rebuild()
	end
	opts = if type(opts) == "table" then opts else {}
	local looped = if opts.looped == nil then clip.looped else opts.looped == true
	local tracks = self.tracks
	for i = 1, self.nTracks do
		local tr = tracks[i]
		if tr.clip == clip and tr.state == "playing" then
			if looped and not opts.restart then
				if opts.speed ~= nil then
					tr:adjustSpeed(opts.speed)
				end
				if opts.weight ~= nil then
					tr:adjustWeight(opts.weight, opts.fade)
				end
				return tr
			end
			tr:stop(opts.fade)
		end
	end
	local track = wrapTrack(AnimCore.newTrack(clip, opts))
	track._player = self
	track.map = self:_mapFor(clip)
	-- keep tracks sorted by priority; a new track goes after the others of its priority
	local at = self.nTracks + 1
	while at > 1 and tracks[at - 1].prio > track.prio do
		tracks[at] = tracks[at - 1]
		at -= 1
	end
	tracks[at] = track
	self.nTracks += 1
	self:_wake()
	return track
end
Player.Play = Player.play

-- The playing track of a clip (by name), or nil.
function Player:getTrack(name)
	for i = 1, self.nTracks do
		local tr = self.tracks[i]
		if tr.name == name and tr.state == "playing" then
			return tr
		end
	end
	return nil
end

function Player:isPlaying(name)
	return self:getTrack(name) ~= nil
end

function Player:stopAll(fade)
	for i = self.nTracks, 1, -1 do
		self.tracks[i]:stop(fade)
	end
end
Player.StopAll = Player.stopAll

-- Procedural layers ----------------------------------------------------------------------------------------

-- Lean into turns (roll) and forward with speed, from the root part's motion. amount: 0 off, 1 normal, up to 3.
function Player:lean(amount)
	self.leanAmount = clamp(num(amount, 0), 0, 3)
	self:_wake()
end

-- Turn the head (and a little of the chest) toward a Vector3, BasePart, Attachment or Model; nil lets go.
function Player:lookAt(target)
	if target ~= nil and targetPosition(target) == nil then
		warnOnce("look:" .. typeof(target), "lookAt needs a Vector3, BasePart, Attachment or Model (or nil), got "
			.. typeof(target))
		target = nil
	end
	self.look = target
	self:_wake()
end

-- A slow breath in the chest, shoulders and neck. opts: rate (breaths per second, 0.25), depth (1).
function Player:breathe(on, opts)
	self.breath = on ~= false
	if type(opts) == "table" then
		self.breathRate = clamp(num(opts.rate, self.breathRate), 0.05, 2)
		self.breathDepth = clamp(num(opts.depth, self.breathDepth), 0, 4)
	end
	self:_wake()
end

-- A kick on one joint that springs back: rotation { rx, ry, rz } degrees (or a Vector3), peaking quickly and
-- settling within recoverSeconds (default 0.25) with a little overshoot.
function Player:recoil(jointName, rotation, recoverSeconds)
	local rx, ry, rz = rotationOf(rotation)
	if type(jointName) ~= "string" or rx == nil then
		warnOnce("recoil:args", "recoil(jointName, { rx, ry, rz }, recoverSeconds) got bad arguments")
		return
	end
	if self.dirty then
		self:_rebuild()
	end
	if self.slotOf[jointName] == nil then
		warnOnce("recoil:" .. jointName, "recoil: this rig has no joint named " .. jointName)
		return
	end
	local speed = 5 / clamp(num(recoverSeconds, 0.25), 0.05, 3)
	local state = self.recoils[jointName]
	if state == nil then
		state = { Spring.new(0, speed, 0.6), Spring.new(0, speed, 0.6), Spring.new(0, speed, 0.6) }
		self.recoils[jointName] = state
	end
	for k, v in { rx, ry, rz } do
		local s = state[k]
		s.Speed = speed
		s.Damping = 0.6
		s:Impulse(v * speed * 2) -- an impulse of 2 * speed * v peaks near v at this damping
	end
	self:_wake()
end

-- Squash (amount > 0, e.g. 0.3) or stretch (< 0) a part's SpecialMesh, volume-preserving, springing back with a
-- wobble. For blobby non-humanoid rigs; partName defaults to the rig's root part.
function Player:squash(amount, partName)
	amount = clamp(num(amount, 0), -0.8, 0.8)
	if self.dirty then
		self:_rebuild()
	end
	local part = if type(partName) == "string" and self.rig ~= nil then self.rig:FindFirstChild(partName, true)
		else self.root
	local mesh = part and part:FindFirstChildWhichIsA("SpecialMesh")
	if mesh == nil then
		warnOnce("squash:" .. tostring(partName), "squash needs a SpecialMesh in the part ("
			.. (if part then part:GetFullName() else tostring(partName)) .. ")")
		return
	end
	local state = self.squashState
	if state == nil or state.mesh ~= mesh then
		if state ~= nil then
			state.mesh.Scale, state.mesh.Offset = state.scale, state.offset
		end
		state = { mesh = mesh, scale = mesh.Scale, offset = mesh.Offset, half = part.Size.Y * 0.5,
			spring = Spring.new(0, 16, 0.4) }
		self.squashState = state
	end
	state.spring.Position = amount
	state.spring.Velocity = 0
	self:_wake()
end

local function addRotation(self, slot, x, y, z, w)
	if slot == nil then
		return
	end
	if self.addOn[slot] then
		x, y, z, w = mul(x, y, z, w, self.addX[slot], self.addY[slot], self.addZ[slot], self.addW[slot])
	end
	self.addX[slot], self.addY[slot], self.addZ[slot], self.addW[slot] = x, y, z, w
	self.addOn[slot] = true
end

local function addEuler(self, slot, rx, ry, rz)
	if slot ~= nil then
		addRotation(self, slot, euler(rx, ry, rz))
	end
end

-- Additive rotations (in character axes) from the procedural layers. Returns true while any layer is active.
function Player:_procedural(dt)
	local addOn = self.addOn
	for s in addOn do
		addOn[s] = nil
	end
	local busy = false
	local slotOf = self.slotOf
	local root = self.root
	local waist = slotOf.Waist
	local rootJoint = slotOf.Root or slotOf.RootJoint
	if rootJoint == nil and root ~= nil then
		for s, m in self.motors do
			if m.Part0 == root then
				rootJoint = s
				break
			end
		end
	end

	-- lean: bank into turns (from the yaw rate) and lean forward with speed
	if root ~= nil and (self.leanAmount > 0 or not settled(self.leanRoll, DEG_EPS) or not settled(self.leanPitch, DEG_EPS)) then
		local _, _, _, _, _, r02, _, _, _, _, _, r22 = root.CFrame:GetComponents()
		local lx, lz = -r02, -r22
		local flat = sqrt(lx * lx + lz * lz)
		local yaw = atan2(-lx, -lz)
		local yawRate = 0
		if self.prevYaw ~= nil and dt > 0 then
			local d = yaw - self.prevYaw
			if d > math.pi then
				d -= 2 * math.pi
			elseif d < -math.pi then
				d += 2 * math.pi
			end
			yawRate = d / dt
		end
		self.prevYaw = yaw
		local v = root.AssemblyLinearVelocity
		local speed = sqrt(v.X * v.X + v.Z * v.Z)
		local forward = if flat > 1e-6 then (v.X * lx + v.Z * lz) / flat else 0
		local amount = self.leanAmount
		self.leanRoll.Target = clamp(0.25 * speed * yawRate, -14, 14) * amount
		self.leanPitch.Target = -clamp(forward / 16, -1, 1.5) * 4 * amount
		local roll, pitch = self.leanRoll:Step(dt), self.leanPitch:Step(dt)
		if amount == 0 and settled(self.leanRoll, DEG_EPS) and settled(self.leanPitch, DEG_EPS) then
			self.leanRoll:Snap(0)
			self.leanPitch:Snap(0)
			self.prevYaw = nil
		else
			addEuler(self, rootJoint, 0, 0, roll * 0.5)
			addEuler(self, waist or rootJoint, pitch, 0, roll * 0.5)
			busy = true
		end
	end

	-- lookAt: yaw / pitch toward the target in the root's frame, shared between the neck and the waist
	local neck = slotOf.Neck
	local lookSprings = self.lookSprings
	local looking = self.look ~= nil
	if not looking then
		for _, s in lookSprings do
			if not settled(s, DEG_EPS) then
				looking = true
				break
			end
		end
	end
	if looking and root ~= nil and (neck ~= nil or waist ~= nil) then
		local yawT, pitchT = 0, 0
		local target = if self.look ~= nil then targetPosition(self.look) else nil
		if target ~= nil then
			local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = root.CFrame:GetComponents()
			local head = if neck ~= nil then self.motors[neck].Part1 else nil
			local ox, oy, oz = x, y + 1.5, z
			if head ~= nil then
				local hp = head.Position
				ox, oy, oz = hp.X, hp.Y, hp.Z
			end
			local dx, dy, dz = target.X - ox, target.Y - oy, target.Z - oz
			local lx = r00 * dx + r10 * dy + r20 * dz
			local ly = r01 * dx + r11 * dy + r21 * dz
			local lz = r02 * dx + r12 * dy + r22 * dz
			yawT = clamp(deg(atan2(-lx, -lz)), -110, 110)
			pitchT = clamp(deg(atan2(ly, sqrt(lx * lx + lz * lz))), -60, 60)
		end
		local waistYaw = if waist ~= nil then clamp(yawT * 0.35, -35, 35) else 0
		self.lookWaistYaw.Target = waistYaw
		self.lookNeckYaw.Target = clamp(yawT - waistYaw, -75, 75)
		self.lookNeckPitch.Target = clamp(pitchT * (if waist ~= nil then 0.75 else 1), -45, 45)
		self.lookWaistPitch.Target = if waist ~= nil then clamp(pitchT * 0.25, -15, 15) else 0
		local ny, np = self.lookNeckYaw:Step(dt), self.lookNeckPitch:Step(dt)
		local wy, wp = self.lookWaistYaw:Step(dt), self.lookWaistPitch:Step(dt)
		if self.look == nil and settled(self.lookNeckYaw, DEG_EPS) and settled(self.lookNeckPitch, DEG_EPS)
			and settled(self.lookWaistYaw, DEG_EPS) and settled(self.lookWaistPitch, DEG_EPS) then
			for _, s in lookSprings do
				s:Snap(0)
			end
		else
			-- yaw about the parent's up axis, then pitch about the turned head's own right axis
			local ax, ay, az, aw = euler(0, ny, 0)
			addRotation(self, neck, mul(ax, ay, az, aw, euler(np, 0, 0)))
			ax, ay, az, aw = euler(0, wy, 0)
			addRotation(self, waist, mul(ax, ay, az, aw, euler(wp, 0, 0)))
			busy = true
		end
	end

	-- breathe: chest lifts, head stays level, arms float out a touch
	if self.breath or not settled(self.breathWeight) then
		self.breathWeight.Target = if self.breath then 1 else 0
		local w = self.breathWeight:Step(dt)
		if not self.breath and settled(self.breathWeight) then
			self.breathWeight:Snap(0)
			self.breathPhase = 0
		else
			self.breathPhase = (self.breathPhase + dt * self.breathRate) % 1
			local s = math.sin(self.breathPhase * 2 * math.pi) * w * self.breathDepth
			addEuler(self, waist or rootJoint, 1.4 * s, 0, 0)
			addEuler(self, neck, -1.1 * s, 0, 0)
			addEuler(self, slotOf.RightShoulder, 0, 0, 1.2 * s)
			addEuler(self, slotOf.LeftShoulder, 0, 0, -1.2 * s)
			busy = true
		end
	end

	-- recoil springs
	for name, state in self.recoils do
		local x, y, z = state[1]:Step(dt), state[2]:Step(dt), state[3]:Step(dt)
		if settled(state[1], DEG_EPS) and settled(state[2], DEG_EPS) and settled(state[3], DEG_EPS) then
			self.recoils[name] = nil
		else
			addEuler(self, slotOf[name], x, y, z)
			busy = true
		end
	end

	-- squash
	local sq = self.squashState
	if sq ~= nil then
		local s = sq.spring:Step(dt)
		if settled(sq.spring) or sq.mesh.Parent == nil then
			sq.mesh.Scale, sq.mesh.Offset = sq.scale, sq.offset
			self.squashState = nil
		else
			local sy = math.max(0.2, 1 - s)
			local sxz = 1 / sqrt(sy)
			sq.mesh.Scale = Vector3.new(sq.scale.X * sxz, sq.scale.Y * sy, sq.scale.Z * sxz)
			sq.mesh.Offset = sq.offset + Vector3.new(0, (sy - 1) * sq.half, 0)
			busy = true
		end
	end
	return busy
end

-- takeOver --------------------------------------------------------------------------------------------------

-- On: while any clip plays, the rig's own AnimationTracks (e.g. the default Animate script's) are held at weight
-- 0 and speed 0, and restored when the clips stop. Off: clips blend over them (the default).
function Player:takeOver(on)
	self.takeover = on ~= false
	if not self.takeover then
		self:_release()
	end
	self:_wake()
end

function Player:_suppress()
	self.suppressed = {}
	local animator = self.rig:FindFirstChildWhichIsA("Animator", true)
	if animator == nil then
		return
	end
	local function hold(track)
		local saved = self.suppressed
		if saved == nil then
			return
		end
		pcall(function()
			if saved[track] == nil then
				saved[track] = { weight = track.WeightTarget, speed = track.Speed }
			end
			track:AdjustWeight(0, 0.1)
			track:AdjustSpeed(0)
		end)
	end
	local ok, playing = pcall(function()
		return animator:GetPlayingAnimationTracks()
	end)
	if ok and type(playing) == "table" then
		for _, track in playing do
			hold(track)
		end
	end
	self.animatorConnection = animator.AnimationPlayed:Connect(hold)
end

function Player:_release(fade)
	local saved = self.suppressed
	self.suppressed = nil
	if self.animatorConnection ~= nil then
		self.animatorConnection:Disconnect()
		self.animatorConnection = nil
	end
	if saved == nil then
		return
	end
	for track, was in saved do
		pcall(function()
			if track.IsPlaying then
				track:AdjustWeight(if was.weight > 0 then was.weight else 1, fade or 0.2)
				track:AdjustSpeed(was.speed)
			end
		end)
	end
end

-- Frame step ------------------------------------------------------------------------------------------------

function Player:_write()
	local mixer = self.mixer
	local cover, mqx, mqy, mqz, mqw = mixer.c, mixer.qx, mixer.qy, mixer.qz, mixer.qw
	local mpx, mpy, mpz = mixer.px, mixer.py, mixer.pz
	local motors, axis, last, addOn = self.motors, self.axis, self.last, self.addOn
	for s = 1, self.slots do
		local c = cover[s]
		local add = addOn[s] == true
		local motor = motors[s]
		if c > 0 or add then
			local qx, qy, qz, qw = mqx[s], mqy[s], mqz[s], mqw[s]
			local px, py, pz = mpx[s], mpy[s], mpz[s]
			local a = axis[s]
			if a and c > 0 then -- character axes -> this joint's C0 axes: a^-1 * q * a
				local ax, ay, az, aw = a[1], a[2], a[3], a[4]
				qx, qy, qz, qw = mul(-ax, -ay, -az, aw, qx, qy, qz, qw)
				qx, qy, qz, qw = mul(qx, qy, qz, qw, ax, ay, az, aw)
				px, py, pz = rotateVector(-ax, -ay, -az, aw, px, py, pz)
			end
			if c < 1 then
				-- blend over the base: the Animator's pose if it wrote this joint this frame, else the rest pose
				local bx, by, bz, bw, bpx, bpy, bpz = 0, 0, 0, 1, 0, 0, 0
				local seen = motor.Transform
				local prev = last[s]
				if prev == nil or not sameCFrame(seen, prev) then
					local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = seen:GetComponents()
					bx, by, bz, bw = fromMatrix(r00, r01, r02, r10, r11, r12, r20, r21, r22)
					bpx, bpy, bpz = x, y, z
				end
				qx, qy, qz, qw = slerp(bx, by, bz, bw, qx, qy, qz, qw, c)
				px, py, pz = bpx + (px - bpx) * c, bpy + (py - bpy) * c, bpz + (pz - bpz) * c
			end
			if add then
				local x, y, z, w = self.addX[s], self.addY[s], self.addZ[s], self.addW[s]
				if a then
					x, y, z, w = mul(-a[1], -a[2], -a[3], a[4], x, y, z, w)
					x, y, z, w = mul(x, y, z, w, a[1], a[2], a[3], a[4])
				end
				qx, qy, qz, qw = mul(x, y, z, w, qx, qy, qz, qw)
			end
			local cf = CFrame.new(px, py, pz, qx, qy, qz, qw)
			motor.Transform = cf
			last[s] = cf
		elseif last[s] ~= nil then
			-- ours last frame, nobody's now: hand it back at rest unless the Animator already wrote it
			if sameCFrame(motor.Transform, last[s]) then
				motor.Transform = IDENTITY
			end
			last[s] = nil
		end
	end
end

-- One frame for this rig; returns whether it still has work (tracks, layers, joints to hand back).
function Player:_step(dt)
	if self.dirty or (self.rescanAt ~= nil and os.clock() >= self.rescanAt) then
		self:_rebuild()
	end
	local tracks, n = self.tracks, self.nTracks
	local k = 0
	for i = 1, n do
		local tr = tracks[i]
		if not AnimCore.advance(tr, dt, onTrackEvent) then
			k += 1
			tracks[k] = tr
		end
	end
	for i = k + 1, n do
		tracks[i] = nil
	end
	self.nTracks = k
	if self.slots == 0 then
		return k > 0 or self.rescanAt ~= nil
	end
	self.mixer:mix(tracks, k)
	local busy = self:_procedural(dt)
	if self.takeover and k > 0 then
		if self.suppressed == nil then
			self:_suppress()
		end
	elseif self.suppressed ~= nil then
		self:_release()
	end
	self:_write()
	return k > 0 or busy or next(self.last) ~= nil or self.suppressed ~= nil
end

-- Stops everything, restores the rig's own tracks and joints, and forgets the rig (automatic when it is destroyed).
function Player:destroy()
	if self.destroyed then
		return
	end
	self.destroyed = true
	for _, connection in self.connections do
		connection:Disconnect()
	end
	self.connections = {}
	self:_release(0)
	for i = 1, self.nTracks do
		local tr = self.tracks[i]
		if tr.state ~= "ended" then
			tr.state, tr.isPlaying, tr.w = "ended", false, 0
			tr.Ended:Fire()
		end
	end
	self.tracks, self.nTracks = {}, 0
	for s, cf in self.last do
		local motor = self.motors[s]
		if motor ~= nil and motor.Parent ~= nil and sameCFrame(motor.Transform, cf) then
			motor.Transform = IDENTITY
		end
	end
	self.last = {}
	local sq = self.squashState
	if sq ~= nil then
		sq.mesh.Scale, sq.mesh.Offset = sq.scale, sq.offset
		self.squashState = nil
	end
	if self.rig ~= nil and players[self.rig] == self then
		players[self.rig] = nil
	end
end
Player.Destroy = Player.destroy

return Anim
