--!nonstrict
-- ControllerKit: tuned player controllers ("feel profiles") that make a genre feel good when merely configured.
-- Pick a profile, override any number in its opts table, connect its events. Every profile works with no opts.
--
--   local ctl = ControllerKit.platformer()                         -- 3D platformer on the default Humanoid (client)
--   local ctl = ControllerKit.topDown({ view = "isometric" })        -- cozy / action / management (client)
--   local ctl = ControllerKit.shooter({ view = "fps", weapon = "rifle" })      -- FPS / TPS (client)
--   ControllerKit.shooterServer({ onDamage = function(attacker, humanoid, dmg, info) end })   -- validation (server)
--   local car = ControllerKit.vehicle(nil, { kind = "kart" })        -- kart | car | hover | boat (client or server)
--   ctl.Landed:Connect(function(impactSpeed) end); ctl:setEnabled(false); ctl:Destroy()
--
-- Client / server:
--   platformer, topDown, shooter: LocalScripts (StarterPlayerScripts / StarterCharacterScripts). They move the local
--     character, which the client already owns, so movement replicates with no server code.
--   shooterServer: a Script. It creates ReplicatedStorage.KitShooterRemote, owns ammo, re-checks every shot and
--     applies damage. Without it the client shooter still works locally (offline / single-player prototypes).
--   vehicle: on the SERVER, ControllerKit.vehicle(model|nil, opts) spawns (or adopts) the vehicle with a Seat and
--     gives network ownership of its root to whoever sits in it; on the CLIENT, ControllerKit.vehicle(model, opts)
--     drives that model while the local player sits in it. ControllerKit.vehicle(nil, opts) on the client builds a
--     client-only vehicle and drives it right away (single-player prototypes, demos).
-- Input: keyboard/mouse, gamepad and touch through ContextActionService; touch buttons are created only when
--   UserInputService.TouchEnabled. All motion is dt-scaled (vehicles run a fixed 120 Hz step, interpolated).
-- Cameras use Kit.CameraRig (one follow at a time); pass camera = false to keep your own, or camera = {...} to tune.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local PathfindingService = game:GetService("PathfindingService")
local TweenService = game:GetService("TweenService")

local Common = require((script.Parent :: Instance):WaitForChild("ControllerKit_Common"))
local Maid = require((script.Parent :: Instance):WaitForChild("Maid"))

local IS_CLIENT = RunService:IsClient()
local CameraRig = if IS_CLIENT then Common.sibling("CameraRig") else nil
local Debug = Common.sibling("Debug")

local merge, flat = Common.merge, Common.flat
local K = Enum.KeyCode
local INPUT_PRIORITY = Enum.RenderPriority.Input.Value + 1 -- just after the default controls

local ControllerKit = {}
ControllerKit.Common = Common

local function event(name, data)
	if Debug and Debug.event then
		pcall(Debug.event, name, data)
	end
end

local function startCamera(opts, defaults)
	if opts == false or not CameraRig then
		return nil
	end
	local cfg = merge(defaults, if type(opts) == "table" then opts else nil)
	local ok, rig = pcall(CameraRig.follow, cfg)
	return if ok then rig else nil
end

local function saveHumanoid(h)
	return { WalkSpeed = h.WalkSpeed, JumpHeight = h.JumpHeight, JumpPower = h.JumpPower, AutoRotate = h.AutoRotate,
		AutoJumpEnabled = h.AutoJumpEnabled }
end

local function restoreHumanoid(h, saved)
	if h and h.Parent and saved then
		for k, v in saved do
			pcall(function()
				h[k] = v
			end)
		end
	end
end

local function grounded(h)
	return h.FloorMaterial ~= Enum.Material.Air
end

local function cameraPunch(dir, studs)
	if CameraRig and studs > 0 then
		pcall(CameraRig.punch, dir, studs)
	end
end

local function cameraShake(trauma)
	if CameraRig and trauma > 0 then
		pcall(CameraRig.shake, trauma)
	end
end

------------------------------------------------------------------------------------------------ platformer
-- Options (all optional; speeds in studs/s, times in seconds, heights in studs):
--   runSpeed=32, accel=110, decel=150, turn=280 (skid rate when reversing), airControl=0.6 (accel multiplier in air)
--   jumpHeight=9.5, coyote=0.1, buffer=0.13, jumpCut=0.45 (vertical speed kept on early release),
--   fallGravity=1.7 (gravity multiplier falling), riseGravity=1, maxFall=190
--   doubleJump = {height=7.5, count=1} | false
--   longJump   = {speed=64, height=5, minSpeed=16} | false     (crouch + jump while running)
--   dive       = {speed=52, up=14} | false                     (dash in the air)
--   dash       = {speed=72, time=0.16, cooldown=0.6} | false   (dash on the ground)
--   groundPound= {hang=0.14, speed=160} | false                (crouch in the air)
--   wallKick   = {out=34, height=9.5, reach=2.4, grace=0.16} | false (off by default; jump into a wall in the air)
--   onLand = function(impactSpeed, ctl) end   landing squash / dust hook (default: small camera dip on hard landings)
--   camera = {CameraRig.follow opts} | false  (default overTheTop, lagging vertically so jumps read)
--   keys = {jump={...}, crouch={...}, dash={...}}  (KeyCode lists; touch buttons are added automatically)
-- Events: Jumped(kind: "jump"|"long"|"wall"), DoubleJumped(n), Landed(impactSpeed), GroundPound(position),
--   Dashed(kind: "dash"|"dive"). Methods: setEnabled(bool), set(opts), state() -> table, Destroy().
local PLATFORMER = {
	runSpeed = 32, accel = 110, decel = 150, turn = 280, airControl = 0.6,
	jumpHeight = 9.5, coyote = 0.1, buffer = 0.13, jumpCut = 0.45, fallGravity = 1.7, riseGravity = 1, maxFall = 190,
	doubleJump = { height = 7.5, count = 1 },
	longJump = { speed = 64, height = 5, minSpeed = 16 },
	dive = { speed = 52, up = 14 },
	dash = { speed = 72, time = 0.16, cooldown = 0.6 },
	groundPound = { hang = 0.14, speed = 160 },
	wallKick = false,
	onLand = nil,
	camera = nil,
	keys = {
		jump = { K.Space, K.ButtonA },
		crouch = { K.LeftControl, K.C, K.ButtonL2, K.ButtonB },
		dash = { K.LeftShift, K.ButtonX },
	},
}
local PLAT_CAMERA = { preset = "overTheTop", distance = 20, height = 2.5, pitch = -18, lookAhead = 3, verticalSpeed = 6,
	autoAlign = { delay = 1.6, speed = 1.4 }, zoom = { min = 10, max = 34 } }
local WALLKICK = { out = 34, height = 9.5, reach = 2.4, grace = 0.16 }

local Platformer = {}
Platformer.__index = Platformer

local function featureOpts(v, defaults)
	if v == false or v == nil then
		return nil
	elseif v == true then
		return table.clone(defaults)
	end
	return merge(defaults, v)
end

function ControllerKit.platformer(who, opts)
	if not IS_CLIENT then
		Common.warnOnce("platformer:server", "platformer runs on the client (a LocalScript)")
		return nil
	end
	if type(who) == "table" and opts == nil then
		who, opts = nil, who
	end
	local self = setmetatable({ maid = Maid.new(), enabled = true, s = nil }, Platformer)
	Common.signals(self, { "Jumped", "DoubleJumped", "Landed", "GroundPound", "Dashed" })
	self:set(opts)
	local input = Common.Input.new(self.maid, "KitPlat")
	self.input = input
	self.held = { jump = false, crouch = false }
	local keys = self.o.keys
	input:bind("Jump", keys.jump, function(began)
		self.held.jump = began
		if began then
			self.jumpQueued = os.clock()
		end
	end)
	input:bind("Crouch", keys.crouch, function(began)
		self.held.crouch = began
		if began then
			self.crouchQueued = os.clock()
		end
	end, { touch = "Crouch", slot = 2 })
	input:bind("Dash", keys.dash, function(began)
		if began then
			self.dashQueued = os.clock()
		end
	end, { touch = "Dash", slot = 1 })
	self.camera = startCamera(self.o.camera, PLAT_CAMERA)
	self.maid:Give(Common.eachCharacter(who, function(character, humanoid, root)
		self:_attach(character, humanoid, root)
	end))
	self.maid:Give(Common.renderStep("KitPlatformer", INPUT_PRIORITY, function(dt)
		self:_step(math.min(dt, 0.1))
	end))
	self.maid:Give(function()
		self:_detach()
		if self.camera then
			self.camera:stop()
		end
	end)
	event("controller", { profile = "platformer" })
	return self
end

function Platformer:set(opts)
	local o = merge(PLATFORMER, opts)
	o.doubleJump = featureOpts(o.doubleJump, PLATFORMER.doubleJump)
	o.longJump = featureOpts(o.longJump, PLATFORMER.longJump)
	o.dive = featureOpts(o.dive, PLATFORMER.dive)
	o.dash = featureOpts(o.dash, PLATFORMER.dash)
	o.groundPound = featureOpts(o.groundPound, PLATFORMER.groundPound)
	o.wallKick = featureOpts(o.wallKick, WALLKICK)
	self.o = o
	return self
end

function Platformer:_detach()
	local s = self.s
	if s then
		s.conn:Disconnect()
		restoreHumanoid(s.humanoid, s.saved)
		self.s = nil
	end
end

function Platformer:_attach(character, humanoid, root)
	self:_detach()
	local saved = saveHumanoid(humanoid)
	local s = { character = character, humanoid = humanoid, root = root, saved = saved,
		mover = Common.Mover.new(humanoid, root), lastGround = os.clock(), lastJump = -1, airJumps = 0,
		wasGrounded = true, minVy = 0, cutArmed = false, pound = nil, dashUntil = 0, dashReady = 0, wallAt = -1,
		wallNormal = nil, airDashed = false }
	-- the controller owns jumping (Space / A are sunk before the default controls see them); the touch jump button
	-- still sets Humanoid.Jump, which is turned into a buffered press here (touch jumps are always full height)
	s.conn = humanoid:GetPropertyChangedSignal("Jump"):Connect(function()
		if self.enabled and humanoid.Jump and not self.held.jump then
			self.jumpQueued = os.clock()
			self.touchQueued = true
		end
	end)
	self.s = s
	if self.enabled then
		self:_own(s)
	end
end

function Platformer:_own(s)
	local h = s.humanoid
	h.UseJumpPower = false
	h.JumpHeight = self.o.jumpHeight
	h.AutoJumpEnabled = false
	h.AutoRotate = true
end

function Platformer:setEnabled(on)
	on = on ~= false
	if on == self.enabled then
		return self
	end
	self.enabled = on
	self.input:setEnabled(on)
	local s = self.s
	if s then
		if on then
			self:_own(s)
		else
			restoreHumanoid(s.humanoid, s.saved)
		end
	end
	if self.camera then
		if on then
			self.camera = startCamera(self.o.camera, PLAT_CAMERA)
		else
			self.camera:stop()
		end
	end
	return self
end

local function jumpVelocity(height)
	return math.sqrt(2 * workspace.Gravity * math.max(height, 0))
end

function Platformer:_jump(s, vy, kind)
	local root, h = s.root, s.humanoid
	-- the Humanoid's own jump impulse and the velocity we write agree, so whichever lands first gives the same arc
	h.JumpHeight = vy * vy / (2 * workspace.Gravity)
	h:ChangeState(Enum.HumanoidStateType.Jumping)
	local v = root.AssemblyLinearVelocity
	root.AssemblyLinearVelocity = Vector3.new(v.X, vy, v.Z)
	s.lastJump = os.clock()
	s.cutArmed = not self.touchQueued
	s.wasGrounded = false
	self.jumpQueued = nil
	self.touchQueued = false
	if kind then
		self.Jumped:Fire(kind)
	end
end

-- A press just before touching down should become a ground jump (buffer), not burn the air jump.
function Platformer:_landingSoon(s, vel)
	if vel.Y >= 0 then
		return false
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { s.character }
	local stand = if s.humanoid.RigType == Enum.HumanoidRigType.R6 then 3 else s.humanoid.HipHeight + s.root.Size.Y / 2
	local reach = stand + -vel.Y * self.o.buffer + 0.5
	local hit = workspace:Raycast(s.root.Position, Vector3.new(0, -reach, 0), params)
	return hit ~= nil
end

function Platformer:_step(dt)
	local s = self.s
	if not s or not self.enabled or not s.root.Parent or s.humanoid.Health <= 0 then
		return
	end
	local o, h, root, now = self.o, s.humanoid, s.root, os.clock()
	local state = h:GetState()
	if state == Enum.HumanoidStateType.Seated or state == Enum.HumanoidStateType.Swimming
		or state == Enum.HumanoidStateType.Climbing then
		s.mover.vel = flat(root.AssemblyLinearVelocity)
		h.WalkSpeed = o.runSpeed
		return
	end
	local vel = root.AssemblyLinearVelocity
	local onGround = grounded(h) and now - s.lastJump > 0.1 and vel.Y < 12
	local facing = flat(root.CFrame.LookVector)
	facing = if facing.Magnitude > 0.01 then facing.Unit else Vector3.new(0, 0, -1)
	local g = workspace.Gravity

	-- landing
	if onGround and not s.wasGrounded then
		local impact = math.max(0, -s.minVy)
		s.airJumps, s.airDashed = 0, false
		if s.pound then
			s.pound = nil
			self.GroundPound:Fire(root.Position)
			cameraShake(0.35)
			cameraPunch(Vector3.new(0, -1, 0), 0.6)
		end
		self.Landed:Fire(impact)
		if o.onLand then
			task.spawn(o.onLand, impact, self)
		elseif impact > 70 then
			cameraPunch(Vector3.new(0, -1, 0), math.clamp((impact - 70) / 220, 0, 0.45))
		end
		s.minVy = 0
	end
	if onGround then
		s.lastGround = now
		s.minVy = 0
		if now - s.lastJump > 0.2 then
			h.JumpHeight = o.jumpHeight
		end
	else
		s.minVy = math.min(s.minVy, vel.Y)
	end
	s.wasGrounded = onGround

	-- wall contact (for wall kicks)
	if o.wallKick and not onGround then
		local dir = flat(vel)
		dir = if dir.Magnitude > 2 then dir.Unit else facing
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { s.character }
		local hit = workspace:Raycast(root.Position, dir * o.wallKick.reach, params)
		if hit and math.abs(hit.Normal.Y) < 0.35 then
			s.wallAt, s.wallNormal = now, flat(hit.Normal).Unit
		end
	end

	local buffered = self.jumpQueued and now - self.jumpQueued <= o.buffer
	local crouchPressed = self.crouchQueued and now - self.crouchQueued <= o.buffer
	local dashPressed = self.dashQueued and now - self.dashQueued <= o.buffer

	-- ground pound: hang, then slam
	if s.pound then
		if now < s.pound.untilT then
			s.mover:set(Vector3.zero)
			root.AssemblyLinearVelocity = Vector3.zero
			return
		end
		root.AssemblyLinearVelocity = Vector3.new(0, -o.groundPound.speed, 0)
		s.mover:set(Vector3.zero)
		return
	end
	if crouchPressed and not onGround and o.groundPound and now - s.lastGround > 0.12 then
		self.crouchQueued = nil
		s.pound = { untilT = now + o.groundPound.hang }
		cameraPunch(Vector3.new(0, 1, 0), 0.15)
		return
	end

	-- dash (ground) / dive (air)
	if dashPressed then
		self.dashQueued = nil
		if onGround and o.dash and now >= s.dashReady then
			s.dashUntil = now + o.dash.time
			s.dashReady = now + o.dash.cooldown
			s.mover:set(facing * o.dash.speed)
			self.Dashed:Fire("dash")
			cameraPunch(-facing, 0.25)
		elseif not onGround and o.dive and not s.airDashed then
			s.airDashed = true
			local speed = math.max(o.dive.speed, flat(vel).Magnitude)
			s.mover:set(facing * speed)
			root.AssemblyLinearVelocity = Vector3.new(facing.X * speed, math.max(vel.Y, 0) + o.dive.up, facing.Z * speed)
			s.cutArmed = false
			self.Dashed:Fire("dive")
		end
	end

	-- jumps: buffered presses, coyote time, long jump, wall kick, air jumps
	if buffered then
		local coyote = now - s.lastGround <= o.coyote and now - s.lastJump > o.coyote + 0.05
		if onGround or coyote then
			local speed = s.mover.vel.Magnitude
			if o.longJump and self.held.crouch and speed >= o.longJump.minSpeed then
				s.mover:set(facing * math.max(o.longJump.speed, speed))
				self:_jump(s, jumpVelocity(o.longJump.height), "long")
				s.cutArmed = false
			else
				self:_jump(s, jumpVelocity(o.jumpHeight), "jump")
			end
		elseif o.wallKick and s.wallNormal and now - s.wallAt <= o.wallKick.grace then
			local n = s.wallNormal
			s.mover:set(n * o.wallKick.out)
			root.CFrame = CFrame.lookAt(root.Position, root.Position + n)
			self:_jump(s, jumpVelocity(o.wallKick.height), "wall")
			s.wallNormal = nil
		elseif o.doubleJump and s.airJumps < (o.doubleJump.count or 1) and not self:_landingSoon(s, vel) then
			s.airJumps += 1
			self:_jump(s, jumpVelocity(o.doubleJump.height), nil)
			self.DoubleJumped:Fire(s.airJumps)
		end
	end

	-- variable jump height, heavier falls, terminal speed
	vel = root.AssemblyLinearVelocity
	local vy = vel.Y
	if s.cutArmed and vy > 0 and not self.held.jump then
		vy *= o.jumpCut
		s.cutArmed = false
	elseif vy <= 0 then
		s.cutArmed = false
	end
	if not onGround then
		local mult = if vy < 0 then o.fallGravity else o.riseGravity
		vy -= (mult - 1) * g * dt
		vy = math.max(vy, -o.maxFall)
	end
	if vy ~= vel.Y then
		root.AssemblyLinearVelocity = Vector3.new(vel.X, vy, vel.Z)
	end

	-- horizontal: accelerate toward the stick, skid when reversing, keep dash speed until the dash ends
	if now < s.dashUntil then
		s.mover:apply()
	else
		local intent = Common.moveIntent(h)
		s.mover:step(dt, intent, { speed = o.runSpeed, accel = o.accel, decel = o.decel, turn = o.turn,
			air = o.airControl }, onGround)
	end
end

function Platformer:state()
	local s = self.s
	if not s then
		return { attached = false }
	end
	return { attached = true, grounded = s.wasGrounded, speed = s.mover.vel.Magnitude, airJumps = s.airJumps,
		pounding = s.pound ~= nil, velocity = s.root.AssemblyLinearVelocity }
end

function Platformer:Destroy()
	self.maid:Clean()
	for _, n in { "Jumped", "DoubleJumped", "Landed", "GroundPound", "Dashed" } do
		self[n]:Destroy()
	end
end

------------------------------------------------------------------------------------------------ topDown
-- Options:
--   speed=22, accel=95, decel=120, turn=220, turnRate=14 (smooth facing, 1/s)
--   view = "isometric" (45 deg, telephoto) | "topDown"; camera = {CameraRig.follow opts} | false
--   clickToMove = true (mouse click / touch tap on the ground; WASD or stick cancels), pathfind = true, arrive = 3
--   marker = true (a ring where you clicked), markerColor
--   interact = {radius=10, tag="Interactable", keys={E, ButtonX}, highlight=true, prompt="E", filter=fn(inst)->bool,
--     candidates=fn()->{Instance}} | false   nearest tagged BasePart / Model inside radius becomes the focus
-- Events: FocusChanged(inst|nil), Interacted(inst), MoveTargetSet(position), Arrived(position).
-- Methods: moveTo(position), stop(), setEnabled(bool), set(opts), focus() -> inst?, Destroy().
local TOPDOWN = {
	speed = 22, accel = 95, decel = 120, turn = 220, turnRate = 14,
	view = "isometric", camera = nil,
	clickToMove = true, pathfind = true, arrive = 3, marker = true, markerColor = "#7CE0FF",
	interact = { radius = 10, tag = "Interactable", keys = { K.E, K.ButtonX }, highlight = true, prompt = "E" },
}
local VIEWS = {
	isometric = { preset = "topDown", yaw = 45, pitch = -38, distance = 70, fov = 32, speed = 7, lookAhead = 3 },
	topdown = { preset = "topDown", distance = 52, fov = 40, pitch = -68, speed = 7, lookAhead = 4 },
}

local TopDown = {}
TopDown.__index = TopDown

function ControllerKit.topDown(who, opts)
	if not IS_CLIENT then
		Common.warnOnce("topdown:server", "topDown runs on the client (a LocalScript)")
		return nil
	end
	if type(who) == "table" and opts == nil then
		who, opts = nil, who
	end
	local self = setmetatable({ maid = Maid.new(), enabled = true, s = nil, target = nil, path = nil }, TopDown)
	Common.signals(self, { "FocusChanged", "Interacted", "MoveTargetSet", "Arrived" })
	self:set(opts)
	self.input = Common.Input.new(self.maid, "KitTop")
	local io = self.o.interact
	if io then
		self.input:bind("Interact", io.keys or TOPDOWN.interact.keys, function(began)
			if began and self.focused then
				self.Interacted:Fire(self.focused)
				event("interact", { name = self.focused.Name })
			end
		end, { touch = "Use", slot = 1 })
	end
	local view = VIEWS[string.lower(tostring(self.o.view))] or VIEWS.isometric
	self.camera = startCamera(self.o.camera, view)
	self.maid:Give(Common.eachCharacter(who, function(character, humanoid, root)
		self:_attach(character, humanoid, root)
	end))
	self.maid:Give(UserInputService.InputBegan:Connect(function(inp, processed)
		if processed or not self.enabled or not self.o.clickToMove then
			return
		end
		if inp.UserInputType == Enum.UserInputType.MouseButton1 then
			local p = UserInputService:GetMouseLocation()
			self:_click(workspace.CurrentCamera:ViewportPointToRay(p.X, p.Y))
		end
	end))
	self.maid:Give(UserInputService.TouchTap:Connect(function(positions, processed)
		if processed or not self.enabled or not self.o.clickToMove or #positions == 0 then
			return
		end
		local p = positions[1]
		self:_click(workspace.CurrentCamera:ScreenPointToRay(p.X, p.Y))
	end))
	self.maid:Give(Common.renderStep("KitTopDown", INPUT_PRIORITY, function(dt)
		self:_step(math.min(dt, 0.1))
	end))
	self.maid:Give(function()
		self:_setFocus(nil)
		self:_detach()
		if self.camera then
			self.camera:stop()
		end
	end)
	event("controller", { profile = "topDown" })
	return self
end

function TopDown:set(opts)
	local o = merge(TOPDOWN, opts)
	o.interact = featureOpts(o.interact, TOPDOWN.interact)
	self.o = o
	return self
end

function TopDown:_attach(character, humanoid, root)
	self:_detach()
	self.s = { character = character, humanoid = humanoid, root = root, saved = saveHumanoid(humanoid),
		mover = Common.Mover.new(humanoid, root), scan = 0 }
	if self.enabled then
		humanoid.AutoRotate = false
	end
end

function TopDown:_detach()
	if self.s then
		restoreHumanoid(self.s.humanoid, self.s.saved)
		self.s = nil
	end
end

function TopDown:setEnabled(on)
	on = on ~= false
	self.enabled = on
	self.input:setEnabled(on)
	if self.s then
		if on then
			self.s.humanoid.AutoRotate = false
		else
			restoreHumanoid(self.s.humanoid, self.s.saved)
		end
	end
	if not on then
		self:stop()
		self:_setFocus(nil)
	end
	return self
end

function TopDown:_click(ray)
	local s = self.s
	if not s then
		return
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { s.character }
	local hit = workspace:Raycast(ray.Origin, ray.Direction * 1000, params)
	if hit and hit.Normal.Y > 0.5 then
		self:moveTo(hit.Position)
	end
end

function TopDown:_marker(pos)
	if not self.o.marker then
		return
	end
	local ring = Instance.new("Part")
	ring.Name = "KitMoveMarker"
	ring.Shape = Enum.PartType.Cylinder
	ring.Anchored, ring.CanCollide, ring.CanQuery, ring.CanTouch, ring.CastShadow = true, false, false, false, false
	ring.Material = Enum.Material.Neon
	ring.Color = Common.color(self.o.markerColor, Color3.fromRGB(124, 224, 255))
	ring.Size = Vector3.new(0.12, 1, 1)
	ring.CFrame = CFrame.new(pos + Vector3.new(0, 0.08, 0)) * CFrame.Angles(0, 0, math.rad(90))
	ring.Transparency = 0.15
	ring.Parent = workspace
	TweenService:Create(ring, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(0.12, 4.5, 4.5), Transparency = 1 }):Play()
	task.delay(0.5, ring.Destroy, ring)
end

-- Walks to a point (pathfinding around obstacles when pathfind is on). WASD / stick input cancels it.
function TopDown:moveTo(pos)
	local s = self.s
	if not s then
		return
	end
	self.target = pos
	self.path = nil
	self:_marker(pos)
	self.MoveTargetSet:Fire(pos)
	if self.o.pathfind then
		local token = {}
		self.pathToken = token
		task.spawn(function()
			local path = PathfindingService:CreatePath({ AgentRadius = 2, AgentHeight = 5, AgentCanJump = true })
			local ok = pcall(path.ComputeAsync, path, s.root.Position, pos)
			if ok and self.pathToken == token and path.Status == Enum.PathStatus.Success then
				local pts = {}
				for i, wp in path:GetWaypoints() do
					if i > 1 then
						table.insert(pts, wp)
					end
				end
				self.path = pts
			end
		end)
	end
end

function TopDown:stop()
	self.target, self.path, self.pathToken = nil, nil, nil
end

local function instPosition(inst)
	if inst:IsA("BasePart") then
		return inst.Position
	elseif inst:IsA("Model") then
		return inst:GetPivot().Position
	elseif inst:IsA("Attachment") then
		return inst.WorldPosition
	end
	return nil
end

function TopDown:_setFocus(inst)
	if inst == self.focused then
		return
	end
	if self.focusFx then
		self.focusFx:Destroy()
		self.focusFx = nil
	end
	self.focused = inst
	local io = self.o.interact
	if inst and io then
		local folder = Instance.new("Folder")
		folder.Name = "KitFocus"
		if io.highlight and (inst:IsA("BasePart") or inst:IsA("Model")) then
			local hl = Instance.new("Highlight")
			hl.FillTransparency = 0.85
			hl.OutlineColor = Color3.new(1, 1, 1)
			hl.DepthMode = Enum.HighlightDepthMode.Occluded
			hl.Adornee = inst
			hl.Parent = folder
		end
		if io.prompt and not UserInputService.TouchEnabled then
			local bb = Instance.new("BillboardGui")
			bb.Size = UDim2.fromOffset(44, 44)
			bb.StudsOffsetWorldSpace = Vector3.new(0, 4, 0)
			bb.AlwaysOnTop = true
			bb.Adornee = if inst:IsA("Model") then inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true)
				else inst
			local key = Instance.new("TextLabel")
			key.Size = UDim2.fromScale(1, 1)
			key.BackgroundColor3 = Color3.fromRGB(20, 22, 30)
			key.BackgroundTransparency = 0.2
			key.Text = tostring(io.prompt)
			key.TextColor3 = Color3.new(1, 1, 1)
			key.Font = Enum.Font.GothamBold
			key.TextScaled = true
			local c = Instance.new("UICorner")
			c.CornerRadius = UDim.new(0.3, 0)
			c.Parent = key
			key.Parent = bb
			bb.Parent = folder
		end
		folder.Parent = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui") or workspace
		self.focusFx = folder
	end
	self.FocusChanged:Fire(inst)
end

function TopDown:_scan(s)
	local io = self.o.interact
	if not io then
		return
	end
	local list = if io.candidates then io.candidates() else CollectionService:GetTagged(io.tag or "Interactable")
	local best, bestD = nil, io.radius
	local here = s.root.Position
	for _, inst in list or {} do
		if typeof(inst) == "Instance" and inst:IsDescendantOf(workspace) and (not io.filter or io.filter(inst)) then
			local p = instPosition(inst)
			if p then
				local d = (p - here).Magnitude
				if d < bestD then
					best, bestD = inst, d
				end
			end
		end
	end
	self:_setFocus(best)
end

function TopDown:focus()
	return self.focused
end

function TopDown:_step(dt)
	local s = self.s
	if not s or not self.enabled or not s.root.Parent or s.humanoid.Health <= 0 then
		return
	end
	local o, h, root = self.o, s.humanoid, s.root
	local intent = Common.moveIntent(h)
	if intent.Magnitude > 0.1 then
		self:stop()
	elseif self.target then
		local goal = self.target
		local wp = self.path and self.path[1]
		if wp then
			goal = wp.Position
			if wp.Action == Enum.PathWaypointAction.Jump then
				h.Jump = true
			end
		end
		local to = flat(goal - root.Position)
		local d = to.Magnitude
		if wp and d < 2 then
			table.remove(self.path, 1)
		elseif not wp and d < 0.6 then
			local at = self.target
			self:stop()
			self.Arrived:Fire(at)
		else
			-- ease in over the last few studs so arrivals settle instead of overshooting
			local slow = if wp then 1 else math.clamp(d / o.arrive, 0.25, 1)
			intent = to.Unit * slow
		end
	end
	s.mover:step(dt, intent, { speed = o.speed, accel = o.accel, decel = o.decel, turn = o.turn, air = 0.8 }, grounded(h))
	-- smooth facing toward travel
	local v = s.mover.vel
	if v.Magnitude > 1 then
		local yaw = Common.yawOf(root.CFrame.LookVector)
		local goalYaw = Common.yawOf(v)
		yaw = Common.dampAngle(yaw, goalYaw, o.turnRate, dt)
		root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, yaw, 0)
	end
	s.scan += dt
	if s.scan >= 0.1 then
		s.scan = 0
		self:_scan(s)
	end
end

function TopDown:Destroy()
	self.maid:Clean()
	for _, n in { "FocusChanged", "Interacted", "MoveTargetSet", "Arrived" } do
		self[n]:Destroy()
	end
end

------------------------------------------------------------------------------------------------ shooter / vehicle
local function sub(name)
	local mod = require((script.Parent :: Instance):WaitForChild(name))
	return mod
end

-- See ControllerKit_Shooter for the opts tables.
function ControllerKit.shooter(opts)
	return sub("ControllerKit_Shooter").client(opts)
end

function ControllerKit.shooterServer(opts)
	return sub("ControllerKit_Shooter").server(opts)
end

-- Weapon presets shared by client and server (rifle, smg, pistol, shotgun, sniper, launcher).
function ControllerKit.weapons()
	return sub("ControllerKit_Shooter").WEAPONS
end

-- See ControllerKit_Vehicle for the opts table.
function ControllerKit.vehicle(model, opts)
	return sub("ControllerKit_Vehicle").new(model, opts)
end

-- The tuned defaults of each profile (read-only reference for games and for the builder).
ControllerKit.defaults = { platformer = PLATFORMER, topDown = TOPDOWN }

return ControllerKit
