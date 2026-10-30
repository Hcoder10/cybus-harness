--!nonstrict
-- ControllerKit_Shooter: FPS / over-the-shoulder TPS controller (client) and its server half. Use through
-- ControllerKit.shooter(opts) / ControllerKit.shooterServer(opts) / ControllerKit.weapons().
--
-- Networking (client prediction, server authority), one RemoteEvent ReplicatedStorage.KitShooterRemote:
--   client -> server  ("fire", {id, w = weaponName, o = origin, d = {unit dirs, one per pellet}, c = {claimed part|false}})
--                     ("hit", {id, p = position, part = Instance?})      projectile impact (projectile weapons)
--                     ("reload", weaponName)
--   server -> shooter ("confirm", {damage, killed, head})                 hit marker
--                     ("ammo", weaponName, ammo, reserve)                 correction after a rejected shot or a reload
--   server -> others  ("fx", shooter, {w, o, e = {end points}} | {w, o, d, projectile = true})   tracers / projectiles
-- The client draws its own tracers, impacts and hit markers the instant it fires and predicts its own ammo. The server
-- owns ammo and fire rate, checks the origin is at the shooter, re-casts every ray, accepts a claimed hit only within
-- hitTolerance studs of its ray with nothing solid in between (lag tolerance), applies falloff and headshots, and
-- calls onDamage. Weapon stats come from the SERVER's table: pass the same `weapons` overrides to both halves.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local Common = require((script.Parent :: Instance):WaitForChild("ControllerKit_Common"))
local Maid = require((script.Parent :: Instance):WaitForChild("Maid"))
local Spring = require((script.Parent :: Instance):WaitForChild("Spring"))

local IS_CLIENT = RunService:IsClient()
local CameraRig = if IS_CLIENT then Common.sibling("CameraRig") else nil
local merge, flat = Common.merge, Common.flat
local K = Enum.KeyCode
local UT = Enum.UserInputType
local REMOTE_NAME = "KitShooterRemote"

local Shooter = {}

-- Weapon presets. Degrees for spread / recoil, studs for distances, rounds per minute for rate.
--   damage, headshot (multiplier), rpm, auto, pellets, magazine, reserve, reload (s), range, adsFov,
--   spread = {hip, ads, move (added at full speed), crouch (multiplier), bloom (per shot), bloomMax, recover (1/s)}
--   falloff = {start, finish, min} | false, recoil = {pitch, yaw, kick (view kick deg), recover (1/s), back (studs)}
--   mode = "hitscan" | "projectile", projectile = {speed, gravity (x workspace.Gravity), splash = {radius, damage, min}}
--   tracer = Color3 | "#hex"
Shooter.WEAPONS = {
	rifle = { damage = 24, headshot = 1.8, rpm = 600, auto = true, pellets = 1, magazine = 30, reserve = 180, reload = 2.0,
		range = 700, adsFov = 50, mode = "hitscan", tracer = "#FFE6A8",
		spread = { hip = 2.2, ads = 0.3, move = 1.8, crouch = 0.7, bloom = 0.35, bloomMax = 3, recover = 6 },
		falloff = { start = 120, finish = 420, min = 0.55 },
		recoil = { pitch = 1.0, yaw = 0.45, kick = 1.6, recover = 6, back = 0.12 } },
	smg = { damage = 15, headshot = 1.5, rpm = 900, auto = true, pellets = 1, magazine = 35, reserve = 210, reload = 1.7,
		range = 400, adsFov = 58, mode = "hitscan", tracer = "#FFE6A8",
		spread = { hip = 3.0, ads = 0.9, move = 1.2, crouch = 0.75, bloom = 0.25, bloomMax = 2.5, recover = 8 },
		falloff = { start = 50, finish = 180, min = 0.45 },
		recoil = { pitch = 0.55, yaw = 0.5, kick = 1.1, recover = 9, back = 0.08 } },
	pistol = { damage = 30, headshot = 2.0, rpm = 380, auto = false, pellets = 1, magazine = 12, reserve = 72, reload = 1.4,
		range = 500, adsFov = 60, mode = "hitscan", tracer = "#FFF2D0",
		spread = { hip = 1.4, ads = 0.2, move = 1.0, crouch = 0.8, bloom = 0.6, bloomMax = 2.5, recover = 7 },
		falloff = { start = 60, finish = 220, min = 0.5 },
		recoil = { pitch = 2.2, yaw = 0.6, kick = 2.4, recover = 8, back = 0.16 } },
	shotgun = { damage = 11, headshot = 1.3, rpm = 80, auto = false, pellets = 9, magazine = 6, reserve = 36, reload = 2.6,
		range = 160, adsFov = 62, mode = "hitscan", tracer = "#FFD9A0",
		spread = { hip = 5.5, ads = 4.0, move = 0.8, crouch = 0.9, bloom = 0, bloomMax = 0, recover = 6 },
		falloff = { start = 20, finish = 80, min = 0.2 },
		recoil = { pitch = 4.5, yaw = 1.0, kick = 5, recover = 5, back = 0.3 } },
	sniper = { damage = 95, headshot = 2.5, rpm = 45, auto = false, pellets = 1, magazine = 5, reserve = 25, reload = 2.8,
		range = 2000, adsFov = 22, mode = "hitscan", tracer = "#BFE8FF",
		spread = { hip = 6, ads = 0, move = 3, crouch = 0.6, bloom = 0, bloomMax = 0, recover = 4 },
		falloff = false,
		recoil = { pitch = 5, yaw = 0.8, kick = 6, recover = 4, back = 0.35 } },
	launcher = { damage = 30, headshot = 1, rpm = 50, auto = false, pellets = 1, magazine = 1, reserve = 12, reload = 2.4,
		range = 900, adsFov = 55, mode = "projectile", tracer = "#FF9A4A",
		projectile = { speed = 220, gravity = 0.25, splash = { radius = 12, damage = 90, min = 0.2 } },
		spread = { hip = 1.2, ads = 0.2, move = 1, crouch = 0.8, bloom = 0, bloomMax = 0, recover = 4 },
		falloff = false,
		recoil = { pitch = 3.5, yaw = 0.6, kick = 4, recover = 5, back = 0.3 } },
}

local function weaponByName(name, overrides)
	local base = Shooter.WEAPONS[name]
	local over = overrides and overrides[name]
	if base == nil and over == nil then
		return nil
	end
	local w = merge(base or Shooter.WEAPONS.rifle, over)
	w.name = name
	return w
end

local function resolveWeapon(spec, overrides)
	if type(spec) == "table" then
		local name = spec.name or "custom"
		local w = merge(weaponByName(spec.base or name, overrides) or Shooter.WEAPONS.rifle, spec)
		w.name = name
		return w
	end
	return weaponByName(tostring(spec or "rifle"), overrides) or weaponByName("rifle")
end

local function falloffMult(w, dist)
	local f = w.falloff
	if not f then
		return 1
	end
	return 1 + (f.min - 1) * Common.smoothstep(f.start, f.finish, dist)
end

local function humanoidOf(part)
	if typeof(part) ~= "Instance" then
		return nil
	end
	local model = part:FindFirstAncestorOfClass("Model")
	while model do
		local h = model:FindFirstChildOfClass("Humanoid")
		if h then
			return h, model
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return nil
end

------------------------------------------------------------------------------------------------ local FX
local fxFolder
local function fx()
	if not fxFolder or not fxFolder.Parent then
		fxFolder = Instance.new("Folder")
		fxFolder.Name = "KitShooterFX"
		fxFolder.Parent = workspace
	end
	return fxFolder
end

local function fxPart(size, cf, color, shape)
	local p = Instance.new("Part")
	p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = true, false, false, false, false
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Size = size
	if shape then
		p.Shape = shape
	end
	p.CFrame = cf
	p.Parent = fx()
	return p
end

local function fade(p, seconds, goal)
	goal = goal or {}
	goal.Transparency = 1
	TweenService:Create(p, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), goal):Play()
	task.delay(seconds + 0.05, p.Destroy, p)
end

function Shooter.tracer(a, b, color)
	local len = (b - a).Magnitude
	if len < 0.5 then
		return
	end
	local p = fxPart(Vector3.new(0.07, 0.07, len), CFrame.lookAt((a + b) / 2, b), color)
	p.Transparency = 0.1
	fade(p, 0.09, { Size = Vector3.new(0.02, 0.02, len) })
end

function Shooter.impact(pos, normal, color, flesh)
	local c = if flesh then Color3.fromRGB(255, 70, 70) else color
	local p = fxPart(Vector3.one * 0.45, CFrame.new(pos), c, Enum.PartType.Ball)
	fade(p, 0.18, { Size = Vector3.one * 1.3 })
	if not flesh and normal then
		for i = 1, 3 do
			local dir = (normal + Vector3.new(math.sin(i * 2.1), math.cos(i * 1.7), math.sin(i * 3.3)) * 0.7).Unit
			local s = fxPart(Vector3.new(0.08, 0.08, 0.5), CFrame.lookAt(pos, pos + dir), c)
			fade(s, 0.16, { CFrame = CFrame.lookAt(pos + dir * 1.6, pos + dir * 3) })
		end
	end
end

function Shooter.flash(at, color)
	local p = fxPart(Vector3.new(0.5, 0.5, 0.9), at * CFrame.Angles(0, 0, math.random() * 6.28), color)
	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = 6
	light.Range = 12
	light.Parent = p
	p.Transparency = 0.15
	fade(p, 0.05)
end

function Shooter.explosion(pos, radius, color)
	local p = fxPart(Vector3.one * 2, CFrame.new(pos), color, Enum.PartType.Ball)
	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = 8
	light.Range = radius * 2.5
	light.Parent = p
	fade(p, 0.35, { Size = Vector3.one * radius * 2 })
	if CameraRig then
		local cam = workspace.CurrentCamera
		local d = cam and (cam.CFrame.Position - pos).Magnitude or 999
		if d < radius * 4 then
			pcall(CameraRig.shake, math.clamp(0.6 * (1 - d / (radius * 4)), 0, 0.6))
		end
	end
end

------------------------------------------------------------------------------------------------ viewmodel
local function buildViewmodel(color, accent)
	local model = Instance.new("Model")
	model.Name = "KitViewmodel"
	local metal = color or Color3.fromRGB(42, 44, 52)
	local accentC = accent or Color3.fromRGB(255, 176, 64)
	local skin = Color3.fromRGB(234, 184, 146)
	local function part(name, size, cf, col, mat, shape)
		local p = Instance.new("Part")
		p.Name = name
		p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = true, false, false, false, false
		p.Size = size
		p.Color = col
		p.Material = mat or Enum.Material.SmoothPlastic
		if shape then
			p.Shape = shape
		end
		p.CFrame = cf
		p.Parent = model
		return p
	end
	local body = part("Body", Vector3.new(0.32, 0.42, 1.5), CFrame.identity, metal, Enum.Material.Metal)
	part("Barrel", Vector3.new(0.9, 0.14, 0.14), CFrame.new(0, 0.08, -1.15) * CFrame.Angles(0, math.rad(90), 0), metal,
		Enum.Material.Metal, Enum.PartType.Cylinder)
	part("Grip", Vector3.new(0.2, 0.5, 0.26), CFrame.new(0, -0.38, 0.35) * CFrame.Angles(math.rad(-15), 0, 0), metal)
	part("Mag", Vector3.new(0.2, 0.55, 0.3), CFrame.new(0, -0.42, -0.3) * CFrame.Angles(math.rad(8), 0, 0), accentC)
	part("Sight", Vector3.new(0.08, 0.12, 0.25), CFrame.new(0, 0.27, 0.1), accentC, Enum.Material.Neon)
	part("Stock", Vector3.new(0.24, 0.34, 0.5), CFrame.new(0, -0.03, 0.95), metal)
	part("RightHand", Vector3.new(0.3, 0.3, 0.5), CFrame.new(0.05, -0.45, 0.45), skin)
	part("LeftHand", Vector3.new(0.28, 0.26, 0.5), CFrame.new(-0.02, -0.14, -0.72), skin)
	local muzzle = Instance.new("Attachment")
	muzzle.Name = "Muzzle"
	muzzle.Position = Vector3.new(0, 0.08, -1.62)
	muzzle.Parent = body
	model.PrimaryPart = body
	return model
end

------------------------------------------------------------------------------------------------ client
-- ControllerKit.shooter(opts). Options:
--   view = "fps" | "tps", weapon = "rifle"|"smg"|"pistol"|"shotgun"|"sniper"|"launcher" | {name, base, ...overrides},
--   weapons = {name = overrides} (same table you give shooterServer)
--   walkSpeed=18, sprintSpeed=28, crouchSpeed=10, adsSpeed=11, accel=120, decel=150
--   fov = 78 (fps) / 70 (tps), sensitivity=1, adsSensitivity=0.6, adsTime=0.16, aimToggle=false
--   viewmodel = true | Model (PrimaryPart + Attachment "Muzzle") | false (fps only), hip = CFrame, ads = CFrame (offsets)
--   crosshair = true, hud = true, camera = {CameraRig.follow overrides} | false
--   keys = {fire, aim, reload, sprint, crouch} (KeyCode / UserInputType lists; touch buttons added automatically)
-- Events: Fired(info), Hit(result), HitConfirmed({damage, killed, head}), ReloadStarted(seconds), Reloaded(),
--   AmmoChanged(ammo, reserve), Aimed(bool), StateChanged(state: "ready"|"reloading"|"empty"|"sprinting")
-- Methods: setEnabled(bool), equip(weapon), reload(), ammo() -> (ammo, reserve), weapon() -> table, state(), Destroy()
local CLIENT = {
	view = "fps", weapon = "rifle", weapons = nil,
	walkSpeed = 18, sprintSpeed = 28, crouchSpeed = 10, adsSpeed = 11, accel = 120, decel = 150,
	fov = nil, sensitivity = 1, adsSensitivity = 0.6, adsTime = 0.16, aimToggle = false,
	viewmodel = true, hip = CFrame.new(0.75, -0.72, -1.55), ads = CFrame.new(0, -0.33, -1.25),
	crosshair = true, hud = true, camera = nil,
	keys = {
		fire = { UT.MouseButton1, K.ButtonR2 },
		aim = { UT.MouseButton2, K.ButtonL2 },
		reload = { K.R, K.ButtonX },
		sprint = { K.LeftShift, K.ButtonL3 },
		crouch = { K.C, K.LeftControl, K.ButtonB },
	},
}
local EVENTS = { "Fired", "Hit", "HitConfirmed", "ReloadStarted", "Reloaded", "AmmoChanged", "Aimed", "StateChanged" }

local Client = {}
Client.__index = Client

function Shooter.client(opts)
	if not IS_CLIENT then
		Common.warnOnce("shooter:server", "shooter runs on the client; use shooterServer on the server")
		return nil
	end
	local o = merge(CLIENT, opts)
	o.fps = string.lower(tostring(o.view)) ~= "tps"
	o.fov = o.fov or (if o.fps then 78 else 70)
	local self = setmetatable({ o = o, maid = Maid.new(), enabled = true, s = nil, held = {}, aiming = false,
		adsAlpha = 0, sprintAlpha = 0, bloom = 0, nextFire = 0, shotId = 0, mags = {}, projectiles = {},
		rng = Random.new(7), recoilPitch = 0, lastShot = -1, stateName = "ready", bobT = 0 }, Client)
	Common.signals(self, EVENTS)
	self.camKick = Spring.new(Vector3.zero, 20, 0.5)
	self.gunKick = Spring.new(Vector3.zero, 24, 0.55)
	self.sway = Spring.new(Vector3.zero, 13, 0.6)

	-- remote (optional: without shooterServer the controller runs offline)
	task.spawn(function()
		local remote = ReplicatedStorage:WaitForChild(REMOTE_NAME, 8)
		if remote and remote:IsA("RemoteEvent") and self.maid then
			self.remote = remote
			self.maid:Give(remote.OnClientEvent:Connect(function(kind, a, b, c)
				self:_onServer(kind, a, b, c)
			end))
		end
	end)

	self:equip(o.weapon)
	local input = Common.Input.new(self.maid, "KitShoot")
	self.input = input
	local keys = o.keys
	input:bind("Fire", keys.fire, function(began)
		self.held.fire = began
		if began then
			self.firePressed = true
		end
	end, { touch = "Fire", slot = 2, sink = false })
	input:bind("Aim", keys.aim, function(began)
		if o.aimToggle or UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
			if began then
				self:_setAim(not self.aiming)
			end
		else
			self:_setAim(began)
		end
	end, { touch = "Aim", slot = 1, sink = false })
	input:bind("Reload", keys.reload, function(began)
		if began then
			self:reload()
		end
	end, { touch = "R", slot = 4 })
	input:bind("Sprint", keys.sprint, function(began)
		self.held.sprint = began
	end, { touch = "Run", slot = 6 })
	input:bind("Crouch", keys.crouch, function(began)
		if began then
			self.crouched = not self.crouched
			self:_cameraHeight()
		end
	end, { touch = "Duck", slot = 3 })

	self.baseCam = merge(if o.fps
		then { preset = "shoulder", distance = 0, height = 1.6, offset = Vector3.zero, fov = o.fov, pitch = 0,
			pitchMin = -80, pitchMax = 80, orbit = "free", collision = false, fadeSubject = 4, speed = 60,
			sensitivity = o.sensitivity }
		else { preset = "shoulder", distance = 8, height = 1.6, offset = Vector3.new(2.3, 0.5, 0), fov = o.fov,
			orbit = "free", sensitivity = o.sensitivity }, o.camera)
	if o.camera ~= false and CameraRig then
		self.camera = CameraRig.follow(self.baseCam)
	end
	if o.fps and o.viewmodel then
		local vm = if typeof(o.viewmodel) == "Instance" then o.viewmodel:Clone() else buildViewmodel()
		vm.Parent = workspace.CurrentCamera
		self.viewmodel = vm
		self.maid:Give(vm)
	end
	self:_buildHud()

	self.maid:Give(Common.eachCharacter(nil, function(character, humanoid, root)
		self:_attach(character, humanoid, root)
	end))
	self.maid:Give(Common.renderStep("KitShooter", Enum.RenderPriority.Input.Value + 1, function(dt)
		self:_step(math.min(dt, 0.1))
	end))
	self.maid:Give(Common.renderStep("KitShooterView", Enum.RenderPriority.Camera.Value + 3, function(dt)
		self:_view(math.min(dt, 0.1))
	end))
	self.maid:Give(function()
		self:_detach()
		if self.camera then
			self.camera:stop()
		end
	end)
	return self
end

function Client:_attach(character, humanoid, root)
	self:_detach()
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character, fx(), workspace.CurrentCamera }
	self.s = { character = character, humanoid = humanoid, root = root, saved = { AutoRotate = humanoid.AutoRotate,
		WalkSpeed = humanoid.WalkSpeed }, mover = Common.Mover.new(humanoid, root), params = params }
	humanoid.AutoRotate = false
end

function Client:_detach()
	local s = self.s
	if s and s.humanoid.Parent then
		s.humanoid.AutoRotate = s.saved.AutoRotate
		s.humanoid.WalkSpeed = s.saved.WalkSpeed
	end
	self.s = nil
end

function Client:equip(spec)
	local w = resolveWeapon(spec, self.o.weapons)
	self.w = w
	local mag = self.mags[w.name]
	if not mag then
		mag = { ammo = w.magazine, reserve = w.reserve }
		self.mags[w.name] = mag
	end
	self.mag = mag
	self.reloading = nil
	self.bloom = 0
	self.AmmoChanged:Fire(mag.ammo, mag.reserve)
	return self
end

function Client:weapon()
	return self.w
end

function Client:ammo()
	return self.mag.ammo, self.mag.reserve
end

function Client:reload()
	local w, mag = self.w, self.mag
	if self.reloading or mag.ammo >= w.magazine or mag.reserve <= 0 then
		return false
	end
	self.reloading = os.clock() + w.reload
	self:_setAim(false)
	self.ReloadStarted:Fire(w.reload)
	if self.remote then
		self.remote:FireServer("reload", w.name)
	end
	return true
end

function Client:_setAim(on)
	on = on == true
	if on and (self.reloading or self.sprinting) then
		on = false
	end
	if on == self.aiming then
		return
	end
	self.aiming = on
	if self.camera then
		local o = self.o
		self.camera:set({ fov = if on then self.w.adsFov else o.fov,
			sensitivity = o.sensitivity * (if on then o.adsSensitivity else 1),
			distance = if o.fps then 0 else (if on then 4.5 else self.baseCam.distance),
			zoomSpeed = 1 / math.max(o.adsTime, 0.02) * 2.2 })
	end
	self.Aimed:Fire(on)
end

function Client:_cameraHeight()
	if self.camera then
		self.camera:set({ height = self.baseCam.height - (if self.crouched then 1.3 else 0) })
	end
end

function Client:setEnabled(on)
	on = on ~= false
	self.enabled = on
	self.input:setEnabled(on)
	self.held = {}
	self:_setAim(false)
	if self.hud then
		self.hud.Enabled = on
	end
	if self.viewmodel then
		self.viewmodel.Parent = if on then workspace.CurrentCamera else nil
	end
	if self.s then
		self.s.humanoid.AutoRotate = not on
	end
	if self.camera and not on then
		self.camera:stop()
		self.camera = nil
	elseif on and not self.camera and self.o.camera ~= false and CameraRig then
		self.camera = CameraRig.follow(self.baseCam)
	end
	return self
end

function Client:_setState(name)
	if name ~= self.stateName then
		self.stateName = name
		self.StateChanged:Fire(name)
	end
end

function Client:state()
	return { state = self.stateName, aiming = self.aiming, sprinting = self.sprinting == true, crouched = self.crouched == true,
		ammo = self.mag.ammo, reserve = self.mag.reserve, weapon = self.w.name, spread = self:_spread() }
end

function Client:_spread()
	local sp = self.w.spread
	local base = sp.hip + (sp.ads - sp.hip) * self.adsAlpha
	local s = self.s
	local speedFrac = if s then math.clamp(s.mover.vel.Magnitude / self.o.walkSpeed, 0, 1.5) else 0
	base += sp.move * speedFrac * (1 - 0.7 * self.adsAlpha)
	if self.crouched then
		base *= sp.crouch
	end
	return base + self.bloom
end

-- Muzzle world position for tracers.
function Client:_muzzle(cam)
	local vm = self.viewmodel
	if vm and vm.Parent then
		local m = vm:FindFirstChild("Muzzle", true)
		if m and m:IsA("Attachment") then
			return m.WorldPosition
		end
	end
	local s = self.s
	if s then
		return (s.root.CFrame * CFrame.new(1.1, 1.0, -1.4)).Position
	end
	return cam.CFrame.Position
end

function Client:_fire(cam)
	local o, w, s, mag = self.o, self.w, self.s, self.mag
	local camCF = cam.CFrame
	local origin = camCF.Position
	local aimDir = camCF.LookVector
	if not o.fps then
		-- TPS: find what the crosshair is on, then shoot at it from the head (never from behind the character)
		local hit = workspace:Raycast(origin, aimDir * w.range, s.params)
		local aimPoint = if hit then hit.Position else origin + aimDir * w.range
		local head = s.character:FindFirstChild("Head")
		origin = if head then head.Position else s.root.Position + Vector3.new(0, 1.5, 0)
		aimDir = (aimPoint - origin).Unit
	end
	local spreadRad = math.rad(self:_spread())
	local dirs, claims, ends = {}, {}, {}
	local muzzle = self:_muzzle(cam)
	local color = Common.color(w.tracer, Color3.fromRGB(255, 230, 168))
	self.shotId += 1
	local id = self.shotId
	local look = CFrame.lookAt(Vector3.zero, aimDir)
	for i = 1, math.max(1, w.pellets) do
		local a = self.rng:NextNumber() * math.pi * 2
		local r = spreadRad * math.sqrt(self.rng:NextNumber())
		local dir = (look * CFrame.Angles(0, 0, a) * CFrame.Angles(r, 0, 0)).LookVector
		dirs[i] = dir
		if w.mode == "projectile" then
			claims[i] = false
		else
			local hit = workspace:Raycast(origin, dir * w.range, s.params)
			local endPos = if hit then hit.Position else origin + dir * w.range
			ends[i] = endPos
			claims[i] = if hit then hit.Instance else false
			Shooter.tracer(muzzle, endPos, color)
			if hit then
				local hum = humanoidOf(hit.Instance)
				Shooter.impact(hit.Position, hit.Normal, color, hum ~= nil)
				self.Hit:Fire({ part = hit.Instance, position = hit.Position, normal = hit.Normal,
					distance = (hit.Position - origin).Magnitude, humanoid = hum,
					damage = w.damage * falloffMult(w, (hit.Position - origin).Magnitude)
						* (if hit.Instance.Name == "Head" then w.headshot else 1) })
			end
		end
	end
	if w.mode == "projectile" then
		self:_launch(id, muzzle, dirs[1], w, true, color)
	end
	Shooter.flash(CFrame.lookAt(muzzle, muzzle + aimDir), color)
	mag.ammo -= 1
	self.AmmoChanged:Fire(mag.ammo, mag.reserve)
	self.bloom = math.min(self.bloom + w.spread.bloom, w.spread.bloomMax)
	if self.remote then
		self.remote:FireServer("fire", { id = id, w = w.name, o = origin, d = dirs, c = claims })
	end
	-- recoil: a permanent climb the player pulls down (recovered when they stop), and a springy view kick on top
	local rc = w.recoil
	local adsK = 1 - 0.45 * self.adsAlpha
	local yawK = (self.rng:NextNumber() * 2 - 1) * rc.yaw * adsK
	if self.camera then
		local st = self.camera:state()
		if st then
			self.camera:setAngles(st.yaw + yawK, st.pitch + rc.pitch * adsK, true)
			self.recoilPitch += rc.pitch * adsK
		end
	end
	self.camKick:Impulse(Vector3.new(math.rad(rc.kick) * 14 * adsK, math.rad(yawK) * 6, math.rad(yawK) * 10))
	self.gunKick:Impulse(Vector3.new(0, math.rad(rc.kick) * 10, rc.back * 30))
	self.lastShot = os.clock()
	self.Fired:Fire({ weapon = w.name, origin = origin, directions = dirs, ends = ends, id = id })
end

function Client:_launch(id, from, dir, w, own, color)
	local pr = w.projectile or {}
	local ball = fxPart(Vector3.one * 0.6, CFrame.new(from), color, Enum.PartType.Ball)
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = 10
	light.Brightness = 3
	light.Parent = ball
	table.insert(self.projectiles, { id = id, pos = from, vel = dir * (pr.speed or 200), t = 0, own = own, part = ball,
		w = w, color = color })
end

function Client:_stepProjectiles(dt)
	local list = self.projectiles
	local params = self.s and self.s.params
	for i = #list, 1, -1 do
		local p = list[i]
		local pr = p.w.projectile or {}
		p.vel -= Vector3.new(0, workspace.Gravity * (pr.gravity or 0) * dt, 0)
		local step = p.vel * dt
		local hit = workspace:Raycast(p.pos, step, params)
		p.t += dt
		if hit or p.t > 8 then
			local at = if hit then hit.Position else p.pos
			table.remove(list, i)
			p.part:Destroy()
			local splash = pr.splash
			Shooter.explosion(at, if splash then splash.radius else 3, p.color)
			if p.own then
				if self.remote then
					self.remote:FireServer("hit", { id = p.id, p = at, part = hit and hit.Instance })
				end
				self.Hit:Fire({ part = hit and hit.Instance, position = at, normal = hit and hit.Normal,
					humanoid = hit and humanoidOf(hit.Instance), projectile = true })
			end
		else
			p.pos += step
			p.part.CFrame = CFrame.new(p.pos)
		end
	end
end

function Client:_onServer(kind, a, b, c)
	if kind == "confirm" and type(a) == "table" then
		self.HitConfirmed:Fire(a)
		self:_hitmarker(a.killed, a.head)
	elseif kind == "ammo" then
		local mag = self.mags[a]
		if mag and type(b) == "number" and type(c) == "number" then
			mag.ammo, mag.reserve = b, c
			if mag == self.mag then
				self.AmmoChanged:Fire(b, c)
			end
		end
	elseif kind == "fx" and typeof(a) == "Instance" and a ~= Players.LocalPlayer and type(b) == "table" then
		local w = resolveWeapon(b.w, self.o.weapons)
		local color = Common.color(w.tracer, Color3.new(1, 0.9, 0.7))
		if b.projectile and typeof(b.o) == "Vector3" and typeof(b.d) == "Vector3" then
			self:_launch(-1, b.o, b.d.Unit, w, false, color)
		elseif typeof(b.o) == "Vector3" and type(b.e) == "table" then
			for _, e in b.e do
				if typeof(e) == "Vector3" then
					Shooter.tracer(b.o, e, color)
				end
			end
		end
	end
end

------------------------------------------------------------------------------------------------ HUD
function Client:_buildHud()
	local o = self.o
	if not o.crosshair and not o.hud then
		return
	end
	local pg = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "KitShooterHud"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 4
	gui.Parent = pg
	self.hud = gui
	self.maid:Give(gui)
	local center = Instance.new("Frame")
	center.AnchorPoint = Vector2.new(0.5, 0.5)
	center.Position = UDim2.fromScale(0.5, 0.5)
	center.Size = UDim2.fromOffset(0, 0)
	center.BackgroundTransparency = 1
	center.Parent = gui
	self.bars = {}
	if o.crosshair then
		for i, d in { Vector2.new(1, 0), Vector2.new(-1, 0), Vector2.new(0, 1), Vector2.new(0, -1) } do
			local bar = Instance.new("Frame")
			bar.AnchorPoint = Vector2.new(0.5, 0.5)
			bar.Size = if d.X ~= 0 then UDim2.fromOffset(10, 2) else UDim2.fromOffset(2, 10)
			bar.BackgroundColor3 = Color3.new(1, 1, 1)
			bar.BorderSizePixel = 0
			local stroke = Instance.new("UIStroke")
			stroke.Transparency = 0.5
			stroke.Parent = bar
			bar.Parent = center
			self.bars[i] = { frame = bar, dir = d }
		end
		local marker = Instance.new("Frame")
		marker.AnchorPoint = Vector2.new(0.5, 0.5)
		marker.Size = UDim2.fromOffset(26, 26)
		marker.BackgroundTransparency = 1
		marker.Rotation = 45
		marker.Visible = false
		marker.Parent = center
		for _, d in { Vector2.new(1, 0), Vector2.new(-1, 0), Vector2.new(0, 1), Vector2.new(0, -1) } do
			local tick = Instance.new("Frame")
			tick.AnchorPoint = Vector2.new(0.5, 0.5)
			tick.Position = UDim2.new(0.5, d.X * 9, 0.5, d.Y * 9)
			tick.Size = if d.X ~= 0 then UDim2.fromOffset(8, 2) else UDim2.fromOffset(2, 8)
			tick.BorderSizePixel = 0
			tick.BackgroundColor3 = Color3.new(1, 1, 1)
			tick.Parent = marker
		end
		self.marker = marker
	end
	if o.hud then
		local ammo = Instance.new("TextLabel")
		ammo.AnchorPoint = Vector2.new(1, 1)
		ammo.Position = UDim2.new(1, -40, 1, -36)
		ammo.Size = UDim2.fromOffset(260, 56)
		ammo.BackgroundTransparency = 1
		ammo.Font = Enum.Font.GothamBlack
		ammo.TextSize = 44
		ammo.TextXAlignment = Enum.TextXAlignment.Right
		ammo.TextColor3 = Color3.new(1, 1, 1)
		ammo.RichText = true
		local stroke = Instance.new("UIStroke")
		stroke.Transparency = 0.6
		stroke.Thickness = 2
		stroke.Parent = ammo
		ammo.Parent = gui
		self.ammoLabel = ammo
		local function refresh(a, r)
			local col = if a <= math.ceil(self.w.magazine * 0.25) then "#FF6A5A" else "#FFFFFF"
			ammo.Text = string.format('<font color="%s">%d</font><font size="26" transparency="0.4">  /  %d</font>', col,
				a, r)
		end
		self.maid:Give(self.AmmoChanged:Connect(refresh))
		self.maid:Give(self.ReloadStarted:Connect(function()
			ammo.Text = '<font size="26">RELOADING</font>'
		end))
		refresh(self.mag.ammo, self.mag.reserve)
	end
end

function Client:_hitmarker(killed, head)
	local m = self.marker
	if not m then
		return
	end
	m.Visible = true
	local col = if killed then Color3.fromRGB(255, 70, 70) elseif head then Color3.fromRGB(255, 210, 80)
		else Color3.new(1, 1, 1)
	for _, t in m:GetChildren() do
		if t:IsA("Frame") then
			t.BackgroundColor3 = col
		end
	end
	m.Size = UDim2.fromOffset(34, 34)
	TweenService:Create(m, TweenInfo.new(0.12), { Size = UDim2.fromOffset(24, 24) }):Play()
	local token = {}
	self.markerToken = token
	task.delay(if killed then 0.35 else 0.15, function()
		if self.markerToken == token then
			m.Visible = false
		end
	end)
end

------------------------------------------------------------------------------------------------ per-frame
function Client:_step(dt)
	local s, o, w = self.s, self.o, self.w
	local now = os.clock()
	self:_stepProjectiles(dt)
	if not s or not self.enabled or not s.root.Parent or s.humanoid.Health <= 0 then
		return
	end
	local cam = workspace.CurrentCamera
	local h, root, mag = s.humanoid, s.root, self.mag

	-- reload state machine
	if self.reloading and now >= self.reloading then
		local need = w.magazine - mag.ammo
		local take = math.min(need, mag.reserve)
		mag.ammo += take
		mag.reserve -= take
		self.reloading = nil
		self.Reloaded:Fire()
		self.AmmoChanged:Fire(mag.ammo, mag.reserve)
	end

	-- movement: sprint only forward, never while aiming; crouch and ADS slow you down
	local raw = Common.rawMove(h)
	local wantSprint = self.held.sprint and raw.Z < -0.5 and not self.aiming and not self.crouched
	if wantSprint and not self.sprinting then
		self.sprinting = true
	elseif not wantSprint and self.sprinting then
		self.sprinting = false
		self.sprintEnd = now
	end
	local speed = if self.sprinting then o.sprintSpeed elseif self.crouched then o.crouchSpeed
		elseif self.aiming then o.adsSpeed else o.walkSpeed
	s.mover:step(dt, Common.moveIntent(h), { speed = speed, accel = o.accel, decel = o.decel, turn = o.accel * 1.5,
		air = 0.35 }, h.FloorMaterial ~= Enum.Material.Air)
	-- body faces where the camera looks
	local yaw = Common.yawOf(cam.CFrame.LookVector)
	root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, yaw, 0)

	-- ADS / sprint blends, bloom recovery
	self.adsAlpha = Common.damp(self.adsAlpha, if self.aiming then 1 else 0, 1 / math.max(o.adsTime, 0.02) * 2.5, dt)
	self.sprintAlpha = Common.damp(self.sprintAlpha, if self.sprinting then 1 else 0, 10, dt)
	self.bloom = Common.damp(self.bloom, 0, w.spread.recover, dt)

	-- fire
	local canFire = not self.reloading and not self.sprinting and now - (self.sprintEnd or -1) > 0.12
	local trigger = if w.auto then self.held.fire else self.firePressed
	self.firePressed = false
	if trigger and canFire then
		if mag.ammo <= 0 then
			if not self:reload() and self.held.fire then
				self.held.fire = w.auto -- dry: hold for autos, click again for semis
			end
		else
			local interval = 60 / w.rpm
			if now >= self.nextFire then
				local shots = 0
				while now >= self.nextFire and mag.ammo > 0 and shots < 3 do
					self:_fire(cam)
					shots += 1
					self.nextFire = math.max(self.nextFire + interval, now - interval)
					if not w.auto then
						self.nextFire = now + interval
						break
					end
				end
			end
		end
	end
	-- recoil recovery once the trigger is released
	if self.camera and self.recoilPitch > 0 and now - self.lastShot > 0.08 then
		local st = self.camera:state()
		if st then
			local rec = self.recoilPitch * Common.alpha(w.recoil.recover, dt)
			self.recoilPitch -= rec
			self.camera:setAngles(st.yaw, st.pitch - rec, true)
		end
	end
	self:_setState(if self.reloading then "reloading" elseif mag.ammo <= 0 then "empty"
		elseif self.sprinting then "sprinting" else "ready")
end

-- After the camera: view kick, viewmodel (bob, sway, ADS, sprint pose, recoil), crosshair spread.
function Client:_view(dt)
	local cam = workspace.CurrentCamera
	if not cam or not self.enabled then
		return
	end
	local kick = self.camKick:Step(dt)
	cam.CFrame = cam.CFrame * CFrame.Angles(kick.X, kick.Y, kick.Z)
	local look = cam.CFrame.LookVector
	local yaw, pitch = Common.yawOf(look), math.asin(math.clamp(look.Y, -1, 1))
	if self.lastYaw then
		local dyaw, dpitch = Common.wrap(yaw - self.lastYaw), pitch - self.lastPitch
		self.sway:Impulse(Vector3.new(math.clamp(dyaw, -0.2, 0.2), math.clamp(dpitch, -0.2, 0.2), 0) * 1.6)
	end
	self.lastYaw, self.lastPitch = yaw, pitch
	local sway = self.sway:Step(dt)
	local gk = self.gunKick:Step(dt)
	local vm = self.viewmodel
	if vm and vm.Parent and vm.PrimaryPart then
		local s = self.s
		local speedFrac = if s then math.clamp(flat(s.root.AssemblyLinearVelocity).Magnitude / self.o.walkSpeed, 0, 1.6)
			else 0
		local grounded = s and s.humanoid.FloorMaterial ~= Enum.Material.Air
		if not grounded then
			speedFrac *= 0.2
		end
		self.bobT += dt * (6 + 5 * speedFrac)
		local bobK = speedFrac * (1 - 0.85 * self.adsAlpha)
		local bob = CFrame.new(math.sin(self.bobT) * 0.045 * bobK, -math.abs(math.cos(self.bobT)) * 0.05 * bobK, 0)
			* CFrame.Angles(0, 0, math.sin(self.bobT) * 0.02 * bobK)
		local swayK = 1 - 0.7 * self.adsAlpha
		local swayCF = CFrame.Angles(sway.Y * 0.6 * swayK, sway.X * 0.8 * swayK, sway.X * 0.9 * swayK)
		local base = self.o.hip:Lerp(self.o.ads, self.adsAlpha)
		local sprintPose = CFrame.new(-0.1, -0.15, 0.1) * CFrame.Angles(math.rad(-18), math.rad(38), math.rad(12))
		local pose = CFrame.identity:Lerp(sprintPose, self.sprintAlpha)
		local dip = CFrame.identity
		if self.reloading then
			local w = self.w
			local t = 1 - math.clamp((self.reloading - os.clock()) / w.reload, 0, 1)
			local k = math.sin(t * math.pi)
			dip = CFrame.new(0, -0.35 * k, 0) * CFrame.Angles(math.rad(-25) * k, 0, math.rad(20) * k)
		end
		local recoil = CFrame.new(0, 0, gk.Z * 0.1) * CFrame.Angles(gk.Y * 0.1, 0, 0)
		vm:PivotTo(cam.CFrame * swayCF * base * bob * pose * dip * recoil)
	end
	-- crosshair
	if self.bars and #self.bars > 0 then
		local vp = cam.ViewportSize
		local gap = math.tan(math.rad(self:_spread())) / math.tan(math.rad(cam.FieldOfView / 2)) * (vp.Y / 2) + 4
		local show = self.adsAlpha < 0.5 and not self.sprinting
		for _, b in self.bars do
			b.frame.Visible = show
			b.frame.Position = UDim2.fromOffset(b.dir.X * (gap + 5), b.dir.Y * (gap + 5))
		end
	end
end

function Client:Destroy()
	self.maid:Clean()
	for _, p in self.projectiles do
		p.part:Destroy()
	end
	table.clear(self.projectiles)
	for _, n in EVENTS do
		self[n]:Destroy()
	end
end

------------------------------------------------------------------------------------------------ server
-- ControllerKit.shooterServer(opts). Options:
--   weapons = {name = overrides}, hitTolerance = 7 (studs a claimed hit may sit off the server ray),
--   maxOriginError = 9 (studs between the claimed origin and the shooter's head), friendlyFire = false,
--   onDamage = function(attacker: Player, humanoid, damage, info) -> false to cancel (default: humanoid:TakeDamage),
--   onKill = function(attacker, humanoid, info)
-- info = {weapon, part, position, distance, head, splash}. Returns server with :Destroy().
local SERVER = { weapons = nil, hitTolerance = 7, maxOriginError = 9, friendlyFire = false, onDamage = nil,
	onKill = nil }

function Shooter.server(opts)
	if IS_CLIENT then
		Common.warnOnce("shooterServer:client", "shooterServer runs on the server (a Script)")
		return nil
	end
	local o = merge(SERVER, opts)
	local maid = Maid.new()
	local remote = ReplicatedStorage:FindFirstChild(REMOTE_NAME)
	if not remote then
		remote = Instance.new("RemoteEvent")
		remote.Name = REMOTE_NAME
		remote.Parent = ReplicatedStorage
		maid:Give(remote)
	end
	local players = {} -- player -> {mags = {name -> {ammo, reserve, reloadUntil}}, tokens, last, shots = {id -> shot}}
	local function stateOf(player)
		local st = players[player]
		if not st then
			st = { mags = {}, tokens = 2, last = os.clock(), shots = {} }
			players[player] = st
		end
		return st
	end
	local function magOf(st, w)
		local m = st.mags[w.name]
		if not m then
			m = { ammo = w.magazine, reserve = w.reserve, reloadUntil = 0 }
			st.mags[w.name] = m
		end
		if m.pending and os.clock() >= m.reloadUntil then
			local take = math.min(w.magazine - m.ammo, m.reserve)
			m.ammo += take
			m.reserve -= take
			m.pending = false
		end
		return m
	end
	local function teammates(a, b)
		if o.friendlyFire or not a or not b or a == b then
			return false
		end
		return a.Team ~= nil and a.Team == b.Team and not a.Neutral
	end
	local function damage(attacker, hum, amount, info)
		if not hum or hum.Health <= 0 or amount <= 0 then
			return nil
		end
		local victim = Players:GetPlayerFromCharacter(hum.Parent)
		if teammates(attacker, victim) or hum.Parent == attacker.Character then
			return nil
		end
		if o.onDamage then
			local ok, res = pcall(o.onDamage, attacker, hum, amount, info)
			if ok and res == false then
				return nil
			end
		else
			hum:TakeDamage(amount)
		end
		local killed = hum.Health <= 0
		if killed and o.onKill then
			task.spawn(o.onKill, attacker, hum, info)
		end
		return killed
	end
	local function broadcast(shooter, payload)
		for _, p in Players:GetPlayers() do
			if p ~= shooter then
				remote:FireClient(p, "fx", shooter, payload)
			end
		end
	end
	local function lineDistance(origin, dir, point)
		local t = math.max((point - origin):Dot(dir), 0)
		return (origin + dir * t - point).Magnitude, t
	end

	maid:Give(remote.OnServerEvent:Connect(function(player, kind, data)
		local character = player.Character
		local myHum = character and character:FindFirstChildOfClass("Humanoid")
		local head = character and character:FindFirstChild("Head")
		if not myHum or myHum.Health <= 0 or not head then
			return
		end
		local st = stateOf(player)
		if kind == "reload" then
			local w = weaponByName(tostring(data), o.weapons)
			if w then
				local m = magOf(st, w)
				if m.ammo < w.magazine and m.reserve > 0 and not m.pending then
					m.pending = true
					m.reloadUntil = os.clock() + w.reload * 0.85
				end
			end
			return
		end
		if type(data) ~= "table" then
			return
		end
		if kind == "fire" then
			local w = weaponByName(tostring(data.w), o.weapons)
			if not w then
				Common.warnOnce("weapon:" .. tostring(data.w), "unknown weapon '" .. tostring(data.w)
					.. "' fired; pass the same weapons table to shooterServer")
				return
			end
			local m = magOf(st, w)
			local now = os.clock()
			local interval = 60 / w.rpm
			st.tokens = math.min(st.tokens + (now - st.last) / interval, 2)
			st.last = now
			local origin, dirs = data.o, data.d
			if m.ammo <= 0 or now < m.reloadUntil or st.tokens < 0.8 or typeof(origin) ~= "Vector3"
				or type(dirs) ~= "table" or #dirs < 1 or #dirs > math.max(1, w.pellets) then
				remote:FireClient(player, "ammo", w.name, m.ammo, m.reserve)
				return
			end
			local root = character:FindFirstChild("HumanoidRootPart")
			local slack = o.maxOriginError + (if root then root.AssemblyLinearVelocity.Magnitude * 0.25 else 0)
			if (origin - head.Position).Magnitude > slack then
				remote:FireClient(player, "ammo", w.name, m.ammo, m.reserve)
				return
			end
			st.tokens -= 1
			m.ammo -= 1
			if w.mode == "projectile" then
				local d = dirs[1]
				if typeof(d) ~= "Vector3" or d.Magnitude < 0.5 then
					return
				end
				st.shots[data.id] = { origin = origin, dir = d.Unit, t = now, w = w }
				broadcast(player, { w = w.name, o = origin, d = d.Unit, projectile = true })
				return
			end
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.FilterDescendantsInstances = { character }
			local claims = if type(data.c) == "table" then data.c else {}
			local ends = {}
			local total, anyKill, anyHead = 0, false, false
			local perHum, infos = {}, {}
			for i, d in dirs do
				if typeof(d) ~= "Vector3" or d.Magnitude < 0.5 then
					continue
				end
				d = d.Unit
				local hit = workspace:Raycast(origin, d * w.range, params)
				local part, pos = hit and hit.Instance, hit and hit.Position
				local hum = part and humanoidOf(part)
				local claim = claims[i]
				if not hum and typeof(claim) == "Instance" and claim:IsA("BasePart") and claim:IsDescendantOf(workspace) then
					-- lag tolerance: the client saw a hit the server ray just missed; accept it if it sits close to the
					-- ray, in range, with nothing solid between the shooter and it
					local chum, cmodel = humanoidOf(claim)
					local off, along = lineDistance(origin, d, claim.Position)
					if chum and off <= o.hitTolerance and along <= w.range then
						local los = RaycastParams.new()
						los.FilterType = Enum.RaycastFilterType.Exclude
						los.FilterDescendantsInstances = { character, cmodel }
						if not workspace:Raycast(origin, claim.Position - origin, los) then
							part, pos, hum = claim, claim.Position, chum
						end
					end
				end
				ends[i] = pos or origin + d * w.range
				if hum and pos then
					local dist = (pos - origin).Magnitude
					local isHead = part.Name == "Head"
					local amount = w.damage * falloffMult(w, dist) * (if isHead then w.headshot else 1)
					perHum[hum] = (perHum[hum] or 0) + amount
					anyHead = anyHead or isHead
					infos[hum] = infos[hum] or { weapon = w.name, part = part, position = pos, distance = dist, head = isHead }
				end
			end
			for hum, amount in perHum do
				local killed = damage(player, hum, amount, infos[hum])
				if killed ~= nil then
					total += amount
					anyKill = anyKill or killed
				end
			end
			if total > 0 then
				remote:FireClient(player, "confirm", { damage = total, killed = anyKill, head = anyHead })
			end
			broadcast(player, { w = w.name, o = origin, e = ends })
		elseif kind == "hit" then
			local shot = st.shots[data.id]
			local pos = data.p
			if not shot or typeof(pos) ~= "Vector3" then
				return
			end
			st.shots[data.id] = nil
			local w = shot.w
			local pr = w.projectile or {}
			local elapsed = os.clock() - shot.t
			local dist = (pos - shot.origin).Magnitude
			if dist > (pr.speed or 200) * (elapsed + 0.5) + 10 or dist > w.range + 10 then
				return
			end
			local total, anyKill = 0, false
			local direct = data.part
			local dhum = typeof(direct) == "Instance" and direct:IsA("BasePart") and (direct.Position - pos).Magnitude < 8
				and humanoidOf(direct)
			if dhum then
				local killed = damage(player, dhum, w.damage, { weapon = w.name, part = direct, position = pos,
					distance = dist, head = false })
				if killed ~= nil then
					total += w.damage
					anyKill = anyKill or killed
				end
			end
			local splash = pr.splash
			if splash then
				local seen = {}
				for _, part in workspace:GetPartBoundsInRadius(pos, splash.radius) do
					local hum, model = humanoidOf(part)
					if hum and not seen[hum] and model then
						seen[hum] = true
						local pivot = model:GetPivot().Position
						local k = 1 - math.clamp((pivot - pos).Magnitude / splash.radius, 0, 1)
						local amount = splash.damage * ((splash.min or 0) + (1 - (splash.min or 0)) * k)
						local killed = damage(player, hum, amount, { weapon = w.name, part = part, position = pos,
							distance = dist, head = false, splash = true })
						if killed ~= nil then
							total += amount
							anyKill = anyKill or killed
						end
					end
				end
			end
			if total > 0 then
				remote:FireClient(player, "confirm", { damage = total, killed = anyKill, head = false })
			end
		end
	end))
	maid:Give(Players.PlayerRemoving:Connect(function(p)
		players[p] = nil
	end))
	-- forget projectile shots that never reported an impact
	maid:Give(task.spawn(function()
		while true do
			task.wait(5)
			local now = os.clock()
			for _, st in players do
				for id, shot in st.shots do
					if now - shot.t > 10 then
						st.shots[id] = nil
					end
				end
			end
		end
	end))
	-- refill on respawn
	maid:Give(Players.PlayerAdded:Connect(function(p)
		p.CharacterAdded:Connect(function()
			players[p] = nil
		end)
	end))
	for _, p in Players:GetPlayers() do
		maid:Give(p.CharacterAdded:Connect(function()
			players[p] = nil
		end))
	end
	return { remote = remote, Destroy = function()
		maid:Clean()
	end }
end

return Shooter
