--!nonstrict
-- ControllerKit_Vehicle: arcade vehicles (kart, car, hover, boat). Use through ControllerKit.vehicle(model, opts).
--
--   SERVER  ControllerKit.vehicle(nil | model, opts) -> handle   spawns the default chassis (or adopts your model) with a
--           Seat. Whoever sits gets network ownership of the root; the root is anchored while nobody drives.
--   CLIENT  ControllerKit.vehicle(model | "seated", opts) -> handle   drives `model` (or any KitVehicle) while the local
--           player sits in it. Pass the same opts as the server (kind + overrides).
--   CLIENT  ControllerKit.vehicle(nil, opts) -> handle   builds a client-only vehicle at opts.spawn and drives it now.
--
-- Simulation (client, the driver): a deterministic fixed 120 Hz step, rendered interpolated. Raycast suspension per
-- wheel / probe (stiffness as a natural frequency in Hz + damping ratio, so ride height never depends on mass), lateral
-- grip, drift with boost tiers, airborne / landing, wall slide via sphere casts, buoyancy on Terrain water or a height
-- function, hover over ground and water. Visual body squat / lean / bob and wheel travel are local Motor6D transforms.
-- A custom model needs a PrimaryPart (the root; its -Z is forward); optional: a Seat, Motor6D "Body" (root -> visible
-- body), Motor6Ds named "Wheel1".."WheelN" (root -> wheel); probe points default to the wheel joints or box corners.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Common = require((script.Parent :: Instance):WaitForChild("ControllerKit_Common"))
local Maid = require((script.Parent :: Instance):WaitForChild("Maid"))

local IS_CLIENT = RunService:IsClient()
local CameraRig = if IS_CLIENT then Common.sibling("CameraRig") else nil
local merge, flat, smoothstep, alpha = Common.merge, Common.flat, Common.smoothstep, Common.alpha
local K = Enum.KeyCode
local STEP = 1 / 120
local MAX_STEPS = 8
local YAXIS = Vector3.yAxis

local Vehicle = {}

-- Kind presets. Speeds studs/s, accelerations studs/s^2, rates 1/s, angles radians, times seconds.
--   size (root box), probes {Vector3} (root-local, at chassis centre height), wheelRadius, rest (suspension travel),
--   freq (Hz), ratio (damping), water = false | true (Terrain water + waterLevel / waterHeight), maxSpeed, accel,
--   brake, reverse (max), reverseAccel, drag, coast, grip, driftGrip, steer, steerHigh, steerFull (speed for full
--   steering), steerResponse, airSteer, align (how much velocity turns with the heading), hop, airGravity,
--   drift = {minSpeed, steerMin, steerMax, rate, tiers = {charge seconds}, boosts = {boost seconds}, colors} | false,
--   boost = {speed (max speed multiplier), accel, fov, shake}, squat, lean, wallBounce, wallScrape,
--   camera = {distance, height, pitch, fov, rotSpeed, speedFov, lookAtVelocity}, color, accent
local KINDS = {
	kart = {
		size = Vector3.new(4.4, 1.1, 6.2), wheelRadius = 0.85, rest = 0.9, freq = 3.4, ratio = 0.65, water = false,
		probes = { Vector3.new(-1.95, 0, -2.25), Vector3.new(1.95, 0, -2.25), Vector3.new(-1.95, 0, 2.25),
			Vector3.new(1.95, 0, 2.25) },
		maxSpeed = 88, accel = 75, brake = 150, reverse = 30, reverseAccel = 45, drag = 0.15, coast = 0.6,
		grip = 10, driftGrip = 2.2, steer = 2.7, steerHigh = 1.7, steerFull = 14, steerResponse = 12, airSteer = 0.35,
		align = 0.85, hop = 22, airGravity = 1.45,
		drift = { minSpeed = 30, steerMin = 0.35, steerMax = 1.25, rate = 2.4, tiers = { 0.6, 1.3, 2.2 },
			boosts = { 0.55, 1.0, 1.6 }, colors = { "#6FD3FF", "#FF9A3C", "#D07CFF" } },
		boost = { speed = 1.35, accel = 170, fov = 10, shake = 0.18 },
		squat = 0.0012, lean = 0.0011, wallBounce = 0.25, wallScrape = 0.25,
		camera = { distance = 14, height = 3, pitch = -12, fov = 70, rotSpeed = 5, lookAtVelocity = 0.35 },
		color = "#E8453C", accent = "#FFD23F",
	},
	car = {
		size = Vector3.new(5.2, 1.6, 9.6), wheelRadius = 1.1, rest = 1.2, freq = 2.5, ratio = 0.5, water = false,
		probes = { Vector3.new(-2.35, 0, -3.3), Vector3.new(2.35, 0, -3.3), Vector3.new(-2.35, 0, 3.3),
			Vector3.new(2.35, 0, 3.3) },
		maxSpeed = 120, accel = 62, brake = 140, reverse = 40, reverseAccel = 40, drag = 0.12, coast = 0.4,
		grip = 8, driftGrip = 2.6, steer = 2.1, steerHigh = 0.95, steerFull = 18, steerResponse = 9, airSteer = 0.2,
		align = 0.8, hop = 0, airGravity = 1.3,
		drift = { minSpeed = 40, steerMin = 0.3, steerMax = 1.2, rate = 2.0, tiers = { 0.8, 1.7, 2.8 },
			boosts = { 0.5, 0.9, 1.4 }, colors = { "#6FD3FF", "#FF9A3C", "#D07CFF" } },
		boost = { speed = 1.3, accel = 150, fov = 12, shake = 0.2 },
		squat = 0.0016, lean = 0.0014, wallBounce = 0.2, wallScrape = 0.3,
		camera = { distance = 19, height = 4, pitch = -11, fov = 70, rotSpeed = 4.5, lookAtVelocity = 0.3 },
		color = "#2F6FE4", accent = "#F2F4F8",
	},
	hover = {
		size = Vector3.new(4.6, 1.2, 7.2), wheelRadius = 0, rest = 3.8, freq = 2.0, ratio = 0.32, water = true,
		probes = { Vector3.new(-1.9, 0, -2.8), Vector3.new(1.9, 0, -2.8), Vector3.new(-1.9, 0, 2.8),
			Vector3.new(1.9, 0, 2.8) },
		maxSpeed = 105, accel = 58, brake = 90, reverse = 35, reverseAccel = 40, drag = 0.1, coast = 0.25,
		grip = 3.2, driftGrip = 1.1, steer = 2.4, steerHigh = 1.6, steerFull = 8, steerResponse = 7, airSteer = 0.6,
		align = 0.6, hop = 26, airGravity = 1.15,
		drift = { minSpeed = 30, steerMin = 0.4, steerMax = 1.3, rate = 2.6, tiers = { 0.7, 1.5, 2.4 },
			boosts = { 0.6, 1.0, 1.5 }, colors = { "#6FFFE9", "#FF6FD8", "#FFFFFF" } },
		boost = { speed = 1.35, accel = 150, fov = 12, shake = 0.15 },
		squat = 0.0016, lean = 0.0018, wallBounce = 0.45, wallScrape = 0.15,
		camera = { distance = 16, height = 3.5, pitch = -12, fov = 72, rotSpeed = 4, lookAtVelocity = 0.45 },
		color = "#7B5CF6", accent = "#6FFFE9",
	},
	boat = {
		size = Vector3.new(4.6, 1.6, 9.2), wheelRadius = 0, rest = 1.7, freq = 2.2, ratio = 0.3, water = true,
		probes = { Vector3.new(0, 0, -3.8), Vector3.new(-1.8, 0, -1.3), Vector3.new(1.8, 0, -1.3),
			Vector3.new(-1.9, 0, 2.4), Vector3.new(1.9, 0, 2.4), Vector3.new(0, 0, 3.9) },
		maxSpeed = 78, accel = 46, brake = 60, reverse = 22, reverseAccel = 30, drag = 0.25, coast = 0.5,
		grip = 2.4, driftGrip = 0.9, steer = 1.8, steerHigh = 1.25, steerFull = 10, steerResponse = 5, airSteer = 0.3,
		align = 0.55, hop = 0, airGravity = 1.25,
		drift = { minSpeed = 28, steerMin = 0.4, steerMax = 1.3, rate = 2.0, tiers = { 0.8, 1.7, 2.6 },
			boosts = { 0.6, 1.0, 1.5 }, colors = { "#BFF4FF", "#FFE08A", "#FF8AD8" } },
		boost = { speed = 1.3, accel = 120, fov = 10, shake = 0.15 },
		squat = 0.0035, lean = 0.0022, wallBounce = 0.35, wallScrape = 0.2, landDrag = 3.5, bob = 1,
		camera = { distance = 18, height = 4, pitch = -11, fov = 70, rotSpeed = 3.5, lookAtVelocity = 0.25 },
		color = "#F5F1E6", accent = "#1FA2B8",
	},
}
Vehicle.KINDS = KINDS

local ALL_OPTS = { kind = "kart", spawn = nil, seat = true, camera = nil, input = nil, waterLevel = nil,
	waterHeight = nil, gravity = 1, keys = { drift = { K.Space, K.LeftShift, K.ButtonR1, K.ButtonL1 },
	reset = { K.R, K.ButtonY }, exit = { K.F, K.ButtonB } } }

local function config(opts, model)
	opts = opts or {}
	local kind = opts.kind or (model and model:GetAttribute("KitVehicle")) or "kart"
	kind = string.lower(tostring(kind))
	local base = KINDS[kind]
	if not base then
		Common.warnOnce("kind:" .. kind, "unknown vehicle kind '" .. kind .. "' (kart, car, hover, boat)")
		kind, base = "kart", KINDS.kart
	end
	local cfg = merge(merge(ALL_OPTS, base), opts)
	cfg.kind = kind
	if cfg.drift == true then
		cfg.drift = merge(base.drift or KINDS.kart.drift, {})
	end
	return cfg
end

------------------------------------------------------------------------------------------------ build
local function newPart(model, name, size, cf, color, material, class)
	local p = Instance.new(class or "Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.CanCollide, p.CanQuery, p.CanTouch, p.Massless = false, false, false, true
	p.TopSurface, p.BottomSurface = Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
	p.Parent = model
	return p
end

local function weld(a, b)
	local w = Instance.new("WeldConstraint")
	w.Part0, w.Part1 = a, b
	w.Parent = b
	return w
end

-- Builds the default chassis for a kind at CFrame `at`. Returns the model (PrimaryPart = Root).
function Vehicle.build(cfg, at)
	at = at or CFrame.new(0, 10, 0)
	local model = Instance.new("Model")
	model.Name = "Kit" .. cfg.kind:sub(1, 1):upper() .. cfg.kind:sub(2)
	local color = Common.color(cfg.color, Color3.new(0.9, 0.3, 0.25))
	local accent = Common.color(cfg.accent, Color3.new(1, 0.85, 0.3))
	local dark = Color3.fromRGB(32, 34, 40)
	local size = cfg.size
	local root = newPart(model, "Root", size, at, color)
	root.Transparency = 1
	root.Massless = false
	root.CanTouch = true
	root.CanCollide = true -- holds it up during the hand-off to the driver; the sim keeps it clear of the ground
	root.RootPriority = 127
	local body = newPart(model, "Body", Vector3.new(size.X * 0.9, size.Y * 0.55, size.Z * 0.92), at, color)
	local motor = Instance.new("Motor6D")
	motor.Name = "Body"
	motor.Part0, motor.Part1 = root, body
	motor.Parent = root
	local function attach(name, sz, offset, col, mat, class)
		local p = newPart(model, name, sz, at * offset, col, mat, class)
		weld(body, p)
		return p
	end
	local seatOffset
	if cfg.kind == "kart" then
		attach("Bumper", Vector3.new(size.X * 0.75, 0.45, 0.6), CFrame.new(0, -0.05, -size.Z * 0.5), dark)
		attach("PodL", Vector3.new(0.7, 0.6, size.Z * 0.55), CFrame.new(-size.X * 0.42, 0.05, 0.2), accent)
		attach("PodR", Vector3.new(0.7, 0.6, size.Z * 0.55), CFrame.new(size.X * 0.42, 0.05, 0.2), accent)
		attach("SeatBack", Vector3.new(1.6, 1.4, 0.35), CFrame.new(0, 0.85, 1.15) * CFrame.Angles(math.rad(-12), 0, 0), dark)
		attach("Column", Vector3.new(0.25, 0.25, 1.4), CFrame.new(0, 0.55, -0.9) * CFrame.Angles(math.rad(35), 0, 0), dark)
		attach("SteeringWheel", Vector3.new(0.15, 1.0, 1.0), CFrame.new(0, 0.95, -1.35) * CFrame.Angles(math.rad(-55), 0, 0)
			* CFrame.Angles(0, 0, math.rad(90)), dark, nil, "Part").Shape = Enum.PartType.Cylinder
		attach("Spoiler", Vector3.new(size.X * 0.8, 0.18, 0.7), CFrame.new(0, 1.05, size.Z * 0.48), accent)
		seatOffset = CFrame.new(0, 0.3, 0.55)
	elseif cfg.kind == "car" then
		attach("Cabin", Vector3.new(size.X * 0.8, size.Y * 0.55, size.Z * 0.42), CFrame.new(0, size.Y * 0.5, 0.6),
			Color3.fromRGB(40, 48, 62), Enum.Material.Glass).Transparency = 0.25
		attach("Roof", Vector3.new(size.X * 0.78, 0.15, size.Z * 0.36), CFrame.new(0, size.Y * 0.8, 0.7), color)
		for _, x in { -1, 1 } do
			attach("Head", Vector3.new(0.9, 0.3, 0.12), CFrame.new(x * size.X * 0.3, 0.05, -size.Z * 0.46),
				Color3.fromRGB(255, 248, 220), Enum.Material.Neon)
			attach("Tail", Vector3.new(0.9, 0.25, 0.12), CFrame.new(x * size.X * 0.3, 0.1, size.Z * 0.46),
				Color3.fromRGB(255, 50, 60), Enum.Material.Neon)
		end
		attach("Stripe", Vector3.new(0.7, 0.05, size.Z * 0.93), CFrame.new(0, size.Y * 0.28, 0), accent)
		attach("Spoiler", Vector3.new(size.X * 0.85, 0.15, 0.8), CFrame.new(0, size.Y * 0.62, size.Z * 0.43), dark)
		seatOffset = CFrame.new(-size.X * 0.2, 0.15, 0.4)
	elseif cfg.kind == "hover" then
		attach("Nose", Vector3.new(size.X * 0.9, size.Y * 0.55, 2.2), CFrame.new(0, 0, -size.Z * 0.46 - 1.1), color,
			nil, "WedgePart")
		attach("Glow", Vector3.new(size.X * 0.95, 0.12, size.Z * 0.9), CFrame.new(0, -size.Y * 0.3, 0), accent,
			Enum.Material.Neon)
		attach("Fin", Vector3.new(0.25, 1.4, 1.6), CFrame.new(0, 0.9, size.Z * 0.4), accent)
		for i, p in cfg.probes do
			local pod = attach("Pod" .. i, Vector3.new(0.9, 0.5, 0.9), CFrame.new(p.X, -size.Y * 0.35, p.Z), accent,
				Enum.Material.Neon)
			local light = Instance.new("PointLight")
			light.Color = accent
			light.Range = 9
			light.Brightness = 1.5
			light.Parent = pod
		end
		seatOffset = CFrame.new(0, 0.35, 0.6)
	else -- boat
		-- the hull sits a little lower than the root so it rides in the water, not on it
		motor.C0 = CFrame.new(0, -0.5, size.Z * 0.12)
		body.Size = Vector3.new(size.X * 0.92, size.Y * 0.7, size.Z * 0.72)
		body.CFrame = at * motor.C0
		local function hull(offset)
			return CFrame.new(0, -0.5, 0) * offset
		end
		attach("Bow", Vector3.new(size.X * 0.92, size.Y * 0.7, size.Z * 0.3), hull(CFrame.new(0, 0, -size.Z * 0.39)
			* CFrame.Angles(0, 0, math.rad(180))), color, nil, "WedgePart")
		attach("Stripe", Vector3.new(size.X * 0.94, 0.25, size.Z * 0.7), hull(CFrame.new(0, -size.Y * 0.1, size.Z * 0.12)),
			accent)
		attach("Deck", Vector3.new(size.X * 0.8, 0.12, size.Z * 0.6), hull(CFrame.new(0, size.Y * 0.36, size.Z * 0.14)),
			Color3.fromRGB(186, 140, 96), Enum.Material.WoodPlanks)
		attach("Screen", Vector3.new(size.X * 0.7, 1.0, 0.12), hull(CFrame.new(0, size.Y * 0.75, -size.Z * 0.12)
			* CFrame.Angles(math.rad(-25), 0, 0)), Color3.fromRGB(150, 200, 230), Enum.Material.Glass).Transparency = 0.4
		seatOffset = hull(CFrame.new(0, size.Y * 0.4, size.Z * 0.12))
	end
	-- wheels (Motor6D so suspension travel and spin are local transforms)
	if cfg.wheelRadius > 0 then
		for i, p in cfg.probes do
			local wheel = newPart(model, "Wheel" .. i, Vector3.new(0.9, cfg.wheelRadius * 2, cfg.wheelRadius * 2),
				at * CFrame.new(p), dark)
			wheel.Shape = Enum.PartType.Cylinder
			local hub = newPart(model, "Hub" .. i, Vector3.new(0.95, cfg.wheelRadius * 0.9, cfg.wheelRadius * 0.9),
				at * CFrame.new(p), accent)
			hub.Shape = Enum.PartType.Cylinder
			weld(wheel, hub)
			local m = Instance.new("Motor6D")
			m.Name = "Wheel" .. i
			m.Part0, m.Part1 = root, wheel
			m.C0 = CFrame.new(p)
			m.Parent = root
		end
	end
	-- drift sparks / boost flames at the rear
	local rearZ = size.Z * 0.5
	for _, x in { -1, 1 } do
		local a = Instance.new("Attachment")
		a.Name = "Spark"
		a.Position = Vector3.new(x * size.X * 0.42, -size.Y * 0.4, rearZ)
		a.Parent = root
		local e = Instance.new("ParticleEmitter")
		e.Name = "Sparks"
		e.Enabled = false
		e.Rate = 70
		e.Lifetime = NumberRange.new(0.12, 0.28)
		e.Speed = NumberRange.new(10, 18)
		e.SpreadAngle = Vector2.new(35, 35)
		e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 0) })
		e.LightEmission = 1
		e.Acceleration = Vector3.new(0, -60, 0)
		e.EmissionDirection = Enum.NormalId.Back
		e.Parent = a
		local f = Instance.new("ParticleEmitter")
		f.Name = "Flame"
		f.Enabled = false
		f.Rate = 90
		f.Lifetime = NumberRange.new(0.1, 0.2)
		f.Speed = NumberRange.new(14, 22)
		f.SpreadAngle = Vector2.new(8, 8)
		f.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.8), NumberSequenceKeypoint.new(1, 0.1) })
		f.Color = ColorSequence.new(Color3.fromRGB(255, 220, 120), Color3.fromRGB(255, 80, 40))
		f.LightEmission = 1
		f.EmissionDirection = Enum.NormalId.Back
		f.Parent = a
	end
	if cfg.seat ~= false then
		local seat = newPart(model, "Seat", Vector3.new(2, 0.4, 2), at * seatOffset, dark, nil, "Seat")
		seat.Transparency = 0.6
		weld(body, seat)
	end
	model.PrimaryPart = root
	model:SetAttribute("KitVehicle", cfg.kind)
	model:SetAttribute("KitBuilt", true)
	return model
end

------------------------------------------------------------------------------------------------ server
local function serverVehicle(model, opts)
	local cfg = config(opts, model)
	local maid = Maid.new()
	if model == nil then
		model = Vehicle.build(cfg, if typeof(cfg.spawn) == "CFrame" then cfg.spawn
			elseif typeof(cfg.spawn) == "Vector3" then CFrame.new(cfg.spawn) else CFrame.new(0, 12, 0))
		model.Parent = workspace
		maid:Give(model)
	end
	model:SetAttribute("KitVehicle", cfg.kind)
	local root = model.PrimaryPart
	if not root then
		Common.warnOnce("vehicle:noroot", "vehicle model '" .. model.Name .. "' needs a PrimaryPart (its root)")
		return nil
	end
	root.Anchored = true
	local seat = model:FindFirstChildWhichIsA("Seat", true) or model:FindFirstChildWhichIsA("VehicleSeat", true)
	local handle = { model = model, root = root, seat = seat, driver = nil, Entered = Common.Signal.new(),
		Exited = Common.Signal.new() }
	if seat then
		maid:Give(seat:GetPropertyChangedSignal("Occupant"):Connect(function()
			local hum = seat.Occupant
			local player = hum and Players:GetPlayerFromCharacter(hum.Parent)
			if player then
				root.Anchored = false
				local ok = pcall(root.SetNetworkOwner, root, player)
				if not ok then
					Common.warnOnce("netowner", "could not give the vehicle to its driver (is a part anchored?)")
				end
				handle.driver = player
				model:SetAttribute("KitDriver", player.UserId)
				handle.Entered:Fire(player)
			else
				local was = handle.driver
				handle.driver = nil
				model:SetAttribute("KitDriver", nil)
				root.AssemblyLinearVelocity = Vector3.zero
				root.AssemblyAngularVelocity = Vector3.zero
				root.Anchored = true
				if was then
					handle.Exited:Fire(was)
				end
			end
		end))
	end
	function handle:Destroy()
		maid:Clean()
	end
	return handle
end

------------------------------------------------------------------------------------------------ simulation
local Sim = {}
Sim.__index = Sim

local function basis(pos, yaw, up)
	local look = Common.lookOfYaw(yaw)
	local fwd = look - up * look:Dot(up)
	fwd = if fwd.Magnitude > 1e-3 then fwd.Unit else look
	local right = fwd:Cross(up).Unit
	return CFrame.fromMatrix(pos, right, up, -fwd), fwd, right
end

function Sim.new(cfg, model, root)
	local self = setmetatable({ cfg = cfg, model = model, root = root }, Sim)
	local cf = root.CFrame
	self.pos = cf.Position
	self.yaw = Common.yawOf(cf.LookVector)
	self.up = YAXIS
	self.vel = Vector3.zero
	self.yawRate = 0
	self.comp = {}
	self.dist = {}
	self.probes = cfg.probes
	for i = 1, #self.probes do
		self.comp[i] = 0
		self.dist[i] = cfg.rest + cfg.wheelRadius
	end
	local n = #self.probes
	local g = workspace.Gravity * cfg.gravity
	local L = cfg.rest + cfg.wheelRadius
	-- stiffness from a natural frequency, raised if the vehicle would bottom out at rest
	local omega = 2 * math.pi * cfg.freq
	if g / (omega * omega) > cfg.rest * 0.75 then
		omega = math.sqrt(g / (cfg.rest * 0.75))
	end
	self.k = omega * omega / n
	self.c = 2 * cfg.ratio * omega / n
	self.g = g
	self.L = L
	self.rideHeight = L - g / (omega * omega)
	self.grounded, self.airTime, self.traction = false, 0, 0
	self.drifting, self.driftDir, self.charge, self.tier = false, 0, 0, 0
	self.boostT, self.onWater = 0, false
	self.prevCF, self.curCF = cf, cf
	self.accF, self.lastVF = 0, 0
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { model }
	params.IgnoreWater = not cfg.water
	self.params = params
	local half = math.min(cfg.size.X * 0.5 * 0.9, 2.6)
	self.wallR = half
	self.wallZ = math.max(cfg.size.Z * 0.5 - half, 0)
	self.wallLift = half + 0.45 - self.rideHeight
	return self
end

function Sim:addIgnore(inst)
	local list = self.params.FilterDescendantsInstances
	table.insert(list, inst)
	self.params.FilterDescendantsInstances = list
end

function Sim:waterAt(x, z)
	local cfg = self.cfg
	if cfg.waterHeight then
		local ok, y = pcall(cfg.waterHeight, x, z)
		return if ok and type(y) == "number" then y else nil
	end
	return cfg.waterLevel
end

-- One fixed step. input = {throttle -1..1, steer -1..1, drift bool}. Returns events {name, value} for the caller.
function Sim:step(h, input, events)
	local cfg = self.cfg
	local up = self.up
	local cf, fwd, right = basis(self.pos, self.yaw, up)
	local n = #self.probes
	local hits, normalSum, accelUp, water = 0, Vector3.zero, 0, false
	local L = self.L
	-- cast from above the probe so a probe that sank under the surface (hard landings, water) still finds it
	local lift = if cfg.water then L else 0.6
	local floor = if cfg.wheelRadius > 0 then cfg.wheelRadius * 0.4 else -0.5
	for i, p in self.probes do
		local o = cf:PointToWorldSpace(p)
		local d, normal = L, nil
		local hit = workspace:Raycast(o + up * lift, -up * (L + lift), self.params)
		if hit then
			d, normal = hit.Distance - lift, hit.Normal
			if hit.Material == Enum.Material.Water then
				water = true
			end
		end
		if cfg.water then
			local wy = self:waterAt(o.X, o.Z)
			if wy then
				local dw = (o.Y - wy) / math.max(up.Y, 0.3)
				if dw < d then
					d, normal, water = math.max(dw, -L), YAXIS, true
				end
			end
		end
		local comp = L - d
		if comp > 0 and normal then
			local compVel = (comp - self.comp[i]) / h
			local f = self.k * comp + self.c * compVel
			accelUp += math.max(f, 0)
			hits += 1
			normalSum += normal
			-- hard stop: never let the body sink through the surface
			if d < floor then
				self.pos += up * ((floor - d) / n)
			end
			self.comp[i] = comp
		else
			self.comp[i] = 0
		end
		self.dist[i] = math.clamp(d, -L, L)
	end
	local wasGrounded = self.grounded
	local grounded = hits > 0
	self.grounded, self.traction, self.onWater = grounded, hits / n, water
	local vel = self.vel

	-- landing / take-off
	if grounded and not wasGrounded then
		local nrm = normalSum.Unit
		local impact = math.max(0, -vel:Dot(nrm))
		if self.airTime > 0.12 then
			table.insert(events, { "Landed", impact })
		end
		self.airTime = 0
	elseif not grounded then
		self.airTime += h
		if wasGrounded then
			table.insert(events, { "Airborne", 0 })
		end
	end

	vel += up * (accelUp * h)
	vel += Vector3.new(0, -self.g * (if grounded then 1 else cfg.airGravity), 0) * h
	local hard = 0
	for i = 1, n do
		if self.dist[i] < floor then
			hard += 1
		end
	end
	if hard > 0 then
		local vu = vel:Dot(up)
		if vu < 0 then
			vel -= up * vu
		end
	end

	-- attitude: follow the ground normal; level out slowly in the air
	local targetUp = if grounded then normalSum.Unit else YAXIS
	if targetUp.Y < 0.2 then
		targetUp = YAXIS
	end
	up = (up + (targetUp - up) * alpha(if grounded then 12 else 2.2, h)).Unit
	self.up = up
	cf, fwd, right = basis(self.pos, self.yaw, up)

	-- drive
	local throttle = math.clamp(input.throttle or 0, -1, 1)
	local steer = math.clamp(input.steer or 0, -1, 1)
	local vF, vR, vU = vel:Dot(fwd), vel:Dot(right), vel:Dot(up)
	local t = self.traction
	local boosting = self.boostT > 0
	local maxS = cfg.maxSpeed * (if boosting then cfg.boost.speed else 1)
	local drag = cfg.drag + (if cfg.landDrag and grounded and not water then cfg.landDrag else 0)
	if t > 0 then
		local dv = 0
		if throttle > 0.05 then
			if vF < -1 then
				dv += cfg.brake * throttle
			else
				local frac = math.clamp(vF / maxS, 0, 1)
				dv += cfg.accel * (1 - frac * frac) * throttle
			end
		elseif throttle < -0.05 then
			if vF > 1 then
				dv -= cfg.brake * -throttle
			elseif vF > -cfg.reverse then
				dv -= cfg.reverseAccel * -throttle
			end
		else
			dv -= vF * cfg.coast
		end
		if boosting and vF < maxS then
			dv += cfg.boost.accel
		end
		vF += dv * t * h
		vF -= vF * drag * h
		if vF > maxS then
			vF += (maxS - vF) * alpha(1.5, h)
		end
		local grip = if self.drifting then cfg.driftGrip else cfg.grip
		vR *= math.exp(-grip * t * h)
	else
		vF -= vF * 0.05 * h
		vR -= vR * 0.05 * h
	end
	self.accF = (vF - self.lastVF) / h
	self.lastVF = vF

	-- drift: press while turning at speed (karts hop first); charge tiers; release to boost
	local drift = cfg.drift
	if drift then
		local pressed = input.drift and not self.driftHeld
		self.driftHeld = input.drift
		if pressed and grounded and cfg.hop > 0 then
			vU += cfg.hop
		end
		if not self.drifting and input.drift and math.abs(steer) > 0.3 and vF > drift.minSpeed
			and (grounded or self.airTime < 0.4) then
			self.drifting, self.driftDir, self.charge, self.tier = true, if steer > 0 then 1 else -1, 0, 0
			table.insert(events, { "DriftStarted", self.driftDir })
		elseif self.drifting then
			if grounded then
				local k = (steer * self.driftDir + 1) / 2
				self.charge += h * (0.6 + 0.8 * k)
				local tier = 0
				for i, need in drift.tiers do
					if self.charge >= need then
						tier = i
					end
				end
				if tier > self.tier then
					self.tier = tier
					table.insert(events, { "DriftTier", tier })
				end
			end
			if not input.drift or vF < drift.minSpeed * 0.5 or self.airTime > 0.6 then
				local tier = self.tier
				self.drifting, self.tier, self.charge = false, 0, 0
				table.insert(events, { "DriftEnded", tier })
				if tier > 0 then
					self:boost(drift.boosts[tier] or 0.5)
					table.insert(events, { "Boosted", tier })
				end
			end
		end
	end

	-- steering: yaw-rate model, full lock at low speed tapering at the top end, reversed when reversing
	local speedAbs = math.abs(vF)
	local sf = smoothstep(0, cfg.steerFull, speedAbs)
	local hs = smoothstep(cfg.maxSpeed * 0.3, cfg.maxSpeed, speedAbs)
	local rate = (cfg.steer + (cfg.steerHigh - cfg.steer) * hs) * sf
	local s = steer
	if self.drifting and drift then
		local k = (steer * self.driftDir + 1) / 2
		s = self.driftDir * (drift.steerMin + (drift.steerMax - drift.steerMin) * k)
		rate = drift.rate * sf
	end
	local sign = if vF >= -0.5 then 1 else -1
	local target = -s * rate * sign * (if grounded then 1 else cfg.airSteer)
	self.yawRate += (target - self.yawRate) * alpha(cfg.steerResponse, h)
	local dyaw = self.yawRate * h
	self.yaw = Common.wrap(self.yaw + dyaw)

	vel = fwd * vF + right * vR + up * vU
	if t > 0 then
		local align = cfg.align * (if self.drifting then 0.55 else 1) * t
		vel = CFrame.fromAxisAngle(up, dyaw * align):VectorToWorldSpace(vel)
	end

	-- move, sliding along walls (two sphere casts: nose and tail)
	local disp = vel * h
	local planar = disp - up * disp:Dot(up)
	local plen = planar.Magnitude
	if plen > 1e-4 then
		local best = nil
		for _, z in { -self.wallZ, self.wallZ } do
			local from = self.pos + up * self.wallLift + fwd * -z
			local hit = workspace:Spherecast(from, self.wallR, planar, self.params)
			if hit and math.abs(hit.Normal:Dot(up)) < 0.6 and (not best or hit.Distance < best.Distance) then
				best = hit
			end
		end
		if best then
			local nrm = best.Normal
			local vn = vel:Dot(nrm)
			if vn < 0 then
				local speed = vel.Magnitude
				vel -= nrm * vn * (1 + cfg.wallBounce)
				vel *= 1 - cfg.wallScrape * math.clamp(-vn / math.max(speed, 1), 0, 1)
				if -vn > 12 then
					table.insert(events, { "Bumped", -vn })
				end
			end
			planar = planar.Unit * math.max(best.Distance - 0.05, 0)
		end
	end
	self.pos += planar + up * disp:Dot(up)
	self.vel = vel
	if self.boostT > 0 then
		self.boostT = math.max(self.boostT - h, 0)
	end
	-- fell out of the world: put it back where it was a while ago
	if self.pos.Y < workspace.FallenPartsDestroyHeight + 50 then
		table.insert(events, { "Fell", 0 })
	end
	self.prevCF = self.curCF
	self.curCF = basis(self.pos, self.yaw, up)
end

function Sim:boost(seconds)
	self.boostT = math.max(self.boostT, seconds)
end

function Sim:reset(cf)
	cf = cf or CFrame.new(self.pos + Vector3.new(0, 4, 0)) * CFrame.Angles(0, self.yaw, 0)
	self.pos = cf.Position
	self.yaw = Common.yawOf(cf.LookVector)
	self.up, self.vel, self.yawRate = YAXIS, Vector3.zero, 0
	self.drifting, self.boostT, self.airTime = false, 0, 0
	self.prevCF, self.curCF = basis(self.pos, self.yaw, YAXIS), basis(self.pos, self.yaw, YAXIS)
end

------------------------------------------------------------------------------------------------ client driver
-- Options (client; every kind preset value above can be overridden too):
--   kind = "kart"|"car"|"hover"|"boat", spawn = CFrame|Vector3 (built vehicles), seat = true (sit the local character)
--   waterLevel = number | waterHeight = function(x, z) -> y   (boats / hovers; Terrain water is found by raycast)
--   input = function() -> (throttle, steer, drift)   replaces player input (AI, replays, tests)
--   camera = {distance, height, pitch, fov, rotSpeed, lookAtVelocity, speedFov, ...CameraRig.follow} | false
--   keys = {drift = {...}, reset = {...}, exit = {...}}
-- Events: Entered(), Exited(), Landed(impactSpeed), Airborne(), DriftStarted(dir), DriftTier(tier),
--   DriftEnded(tier), Boosted(tierOrSource), Bumped(impactSpeed), Fell()
-- Methods: boost(seconds) (boost pads), reset(cframe?), setEnabled(bool), exit(), state() -> {speed, forwardSpeed,
--   grounded, airTime, drifting, tier, boosting, onWater, throttle, steer}, model, Destroy().
local EVENTS = { "Entered", "Exited", "Landed", "Airborne", "DriftStarted", "DriftTier", "DriftEnded", "Boosted",
	"Bumped", "Fell" }

local Driver = {}
Driver.__index = Driver

local function probesFromModel(cfg, model, root)
	local pts = {}
	for i = 1, 12 do
		local m = root:FindFirstChild("Wheel" .. i)
		if m and m:IsA("Motor6D") then
			local p = m.C0.Position
			table.insert(pts, Vector3.new(p.X, 0, p.Z))
		end
	end
	if #pts >= 3 then
		return pts
	end
	local _, size = model:GetBoundingBox()
	local hx, hz = size.X * 0.4, size.Z * 0.4
	return { Vector3.new(-hx, 0, -hz), Vector3.new(hx, 0, -hz), Vector3.new(-hx, 0, hz), Vector3.new(hx, 0, hz) }
end

function Driver.new(model, opts)
	local cfg = config(opts, if typeof(model) == "Instance" then model else nil)
	local self = setmetatable({ cfg = cfg, maid = Maid.new(), enabled = true, session = nil, held = {},
		userProbes = type(opts) == "table" and opts.probes ~= nil }, Driver)
	Common.signals(self, EVENTS)
	local localOnly = model == nil
	if localOnly then
		local player = Players.LocalPlayer
		local character = player and player.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart")
		local at = if typeof(cfg.spawn) == "CFrame" then cfg.spawn
			elseif typeof(cfg.spawn) == "Vector3" then CFrame.new(cfg.spawn)
			elseif hrp then hrp.CFrame * CFrame.new(0, 2, -12)
			else CFrame.new(0, 12, 0)
		model = Vehicle.build(cfg, at)
		model.PrimaryPart.Anchored = true
		model.Parent = workspace
		self.maid:Give(model)
	end
	self.model = if typeof(model) == "Instance" then model else nil

	local input = Common.Input.new(self.maid, "KitVehicle")
	self.input = input
	input:bind("Drift", cfg.keys.drift, function(began)
		self.held.drift = began
	end, { touch = "Drift", slot = 2 })
	input:bind("Reset", cfg.keys.reset, function(began)
		if began and self.session then
			self:reset()
		end
	end, { touch = "Reset", slot = 4 })
	input:bind("Exit", cfg.keys.exit, function(began)
		if began then
			self:exit()
		end
	end, { touch = "Exit", slot = 5 })
	input:bind("Throttle", { K.ButtonR2 }, function(began, io)
		self.held.rt = if began then math.max(io.Position.Z, 0.5) else 0
	end, { sink = false })
	input:bind("Brake", { K.ButtonL2 }, function(began, io)
		self.held.lt = if began then math.max(io.Position.Z, 0.5) else 0
	end, { sink = false })
	input:setEnabled(false)

	if localOnly then
		self:_start(self.model, true)
	else
		-- drive whichever matching vehicle the local character sits in
		self.maid:Give(Common.eachCharacter(nil, function(_, humanoid)
			local function check(active, seatPart)
				if active and seatPart then
					local m = seatPart:FindFirstAncestorOfClass("Model")
					while m and m:GetAttribute("KitVehicle") == nil do
						m = m:FindFirstAncestorOfClass("Model")
					end
					if m and (self.model == nil or m == self.model) and m.PrimaryPart then
						self:_start(m, false)
					end
				elseif self.session then
					self:_stop()
				end
			end
			self.maid:Give(humanoid.Seated:Connect(check))
			if humanoid.SeatPart then
				check(true, humanoid.SeatPart)
			end
		end))
	end
	self.maid:Give(function()
		self:_stop()
	end)
	return self
end

function Driver:_start(model, localOnly)
	if self.session then
		self:_stop()
	end
	local cfg = self.cfg
	local root = model.PrimaryPart
	if not model:GetAttribute("KitBuilt") then
		-- your own model: probes from its wheel joints (or its box corners) unless opts.probes was given
		if not self.userProbes then
			cfg.probes = probesFromModel(cfg, model, root)
		end
		local _, size = model:GetBoundingBox()
		cfg.size = Vector3.new(math.max(size.X, 2), math.max(size.Y, 1), math.max(size.Z, 2))
	end
	local sm = Maid.new()
	local session = { model = model, root = root, maid = sm, localOnly = localOnly, wheels = {}, spin = 0,
		pitchV = 0, rollV = 0, pitchVel = 0, rollVel = 0, t = 0, acc = 0, tierShown = 0 }
	self.session = session
	-- client vehicles of other players' servers: wait until the server hands the root to us
	if not localOnly then
		local t0 = os.clock()
		while root.Anchored and os.clock() - t0 < 2 do
			task.wait()
		end
		if self.session ~= session then
			return
		end
	end
	local sim = Sim.new(cfg, model, root)
	session.sim = sim
	session.spawnCF = root.CFrame + Vector3.new(0, 3, 0)
	local player = Players.LocalPlayer
	local character = player and player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if character then
		sim:addIgnore(character)
	end
	if humanoid then
		session.humanoid = humanoid
		session.saved = { WalkSpeed = humanoid.WalkSpeed }
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
		if localOnly then
			humanoid.WalkSpeed = 0
			local seat = model:FindFirstChildWhichIsA("Seat", true)
			if seat and cfg.seat ~= false then
				pcall(seat.Sit, seat, humanoid)
			end
		end
	end
	session.bodyMotor = root:FindFirstChild("Body")
	for i = 1, #cfg.probes do
		local m = root:FindFirstChild("Wheel" .. i)
		if m and m:IsA("Motor6D") then
			session.wheels[i] = m
		end
	end
	session.sparks, session.flames = {}, {}
	for _, a in root:GetChildren() do
		if a:IsA("Attachment") and a.Name == "Spark" then
			local sp, fl = a:FindFirstChild("Sparks"), a:FindFirstChild("Flame")
			if sp then
				table.insert(session.sparks, sp)
			end
			if fl then
				table.insert(session.flames, fl)
			end
		end
	end
	-- chase camera: CameraRig follows the root, we steer its yaw to the heading (leaning toward the slide)
	local cc = cfg.camera
	if cc ~= false and CameraRig then
		local camOpts = merge({ preset = "overTheTop", subject = root, orbit = "locked", distance = cc.distance,
			height = cc.height, pitch = cc.pitch, fov = cc.fov, rotSpeed = cc.rotSpeed, speed = 20, lookAhead = 0,
			collision = true, fadeSubject = false, ignore = { model, character },
			speedFov = { from = cfg.maxSpeed * 0.3, to = cfg.maxSpeed * 1.25, fov = 14, pull = 3 } }, cc)
		camOpts.lookAtVelocity = nil
		local ok, rig = pcall(CameraRig.follow, camOpts)
		if ok and rig then
			session.camera = rig
			rig:setAngles(math.deg(sim.yaw), cc.pitch, true)
		end
	end
	self.input:setEnabled(self.enabled)
	sm:Give(Common.renderStep("KitVehicleSim", Enum.RenderPriority.Camera.Value - 1, function(dt)
		self:_frame(session, math.min(dt, 0.25))
	end))
	self.Entered:Fire()
end

function Driver:_stop()
	local session = self.session
	if not session then
		return
	end
	self.session = nil
	session.maid:Clean()
	if session.camera then
		session.camera:stop()
	end
	local h = session.humanoid
	if h and h.Parent then
		h:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
		if session.saved then
			h.WalkSpeed = session.saved.WalkSpeed
		end
	end
	for _, e in session.sparks or {} do
		e.Enabled = false
	end
	for _, e in session.flames or {} do
		e.Enabled = false
	end
	self.input:setEnabled(false)
	self.Exited:Fire()
end

function Driver:_readInput()
	if self.cfg.input then
		local ok, th, st, dr = pcall(self.cfg.input)
		if ok then
			return { throttle = th or 0, steer = st or 0, drift = dr == true }
		end
	end
	if not self.enabled then
		return { throttle = 0, steer = 0, drift = false }
	end
	local raw = Common.rawMove(self.session and self.session.humanoid)
	local throttle = -raw.Z
	local rt, lt = self.held.rt or 0, self.held.lt or 0
	if rt > 0 or lt > 0 then
		throttle = rt - lt
	end
	return { throttle = throttle, steer = raw.X, drift = self.held.drift == true }
end

local TIER_DEFAULT = { "#6FD3FF", "#FF9A3C", "#D07CFF" }

function Driver:_frame(session, dt)
	local sim, cfg, root = session.sim, self.cfg, session.root
	if not sim or not root.Parent then
		return
	end
	local inp = self:_readInput()
	session.input = inp
	session.acc += dt
	local steps = 0
	local events = {}
	while session.acc >= STEP and steps < MAX_STEPS do
		sim:step(STEP, inp, events)
		session.acc -= STEP
		steps += 1
	end
	if steps == MAX_STEPS then
		session.acc = 0
	end
	local a = math.clamp(session.acc / STEP, 0, 1)
	local cf = sim.prevCF:Lerp(sim.curCF, a)
	if root.Anchored then
		root.CFrame = cf
	else
		root.CFrame = cf
		root.AssemblyLinearVelocity = sim.vel
		root.AssemblyAngularVelocity = sim.up * sim.yawRate
	end
	for _, ev in events do
		self:_event(session, ev[1], ev[2])
	end

	-- visuals: body squat (accel), lean (cornering), boat bob; wheel travel and spin
	session.t += dt
	local vF = sim.vel:Dot(cf.LookVector)
	local pitchGoal = math.clamp(sim.accF * cfg.squat, -0.12, 0.12)
	local rollGoal = math.clamp(-vF * sim.yawRate * cfg.lean, -0.16, 0.16)
	if sim.drifting then
		rollGoal += sim.driftDir * 0.05
	end
	if cfg.bob and sim.onWater then
		local speedFrac = math.clamp(math.abs(vF) / cfg.maxSpeed, 0, 1)
		pitchGoal += speedFrac * 0.09 + math.sin(session.t * 1.9) * 0.025 * cfg.bob
		rollGoal += math.sin(session.t * 1.3 + 0.7) * 0.03 * cfg.bob
	end
	if not sim.grounded then
		pitchGoal, rollGoal = pitchGoal * 0.3, rollGoal * 0.3
	end
	local k, d = 90, 2 * 0.55 * math.sqrt(90)
	session.pitchVel += ((pitchGoal - session.pitchV) * k - session.pitchVel * d) * dt
	session.pitchV += session.pitchVel * dt
	session.rollVel += ((rollGoal - session.rollV) * k - session.rollVel * d) * dt
	session.rollV += session.rollVel * dt
	local bm = session.bodyMotor
	if bm and bm:IsA("Motor6D") then
		local hoverBob = if cfg.wheelRadius == 0 and not cfg.bob then math.sin(session.t * 2.4) * 0.12 else 0
		bm.Transform = CFrame.new(0, hoverBob, 0) * CFrame.Angles(session.pitchV, 0, session.rollV)
	end
	session.spin -= vF / math.max(cfg.wheelRadius, 0.3) * dt
	for i, m in session.wheels do
		local drop = math.max(sim.dist[i], cfg.wheelRadius * 0.3) - cfg.wheelRadius
		local steerA = 0
		if cfg.probes[i].Z < 0 then
			steerA = -(inp.steer or 0) * 0.45
		end
		m.Transform = CFrame.new(0, -drop, 0) * CFrame.Angles(0, steerA, 0) * CFrame.Angles(session.spin, 0, 0)
	end
	-- drift sparks by tier, boost flames
	local tier = if sim.drifting then sim.tier else 0
	if tier ~= session.tierShown then
		session.tierShown = tier
		local colors = (cfg.drift and cfg.drift.colors) or TIER_DEFAULT
		for _, e in session.sparks do
			e.Enabled = tier > 0 and sim.grounded
			if tier > 0 then
				e.Color = ColorSequence.new(Common.color(colors[tier], Color3.new(1, 1, 1)))
			end
		end
	end
	local boosting = sim.boostT > 0
	if boosting ~= session.flameOn then
		session.flameOn = boosting
		for _, e in session.flames do
			e.Enabled = boosting
		end
	end
	-- camera heading: behind the vehicle, leaning into the slide; does not flip when reversing
	local rig = session.camera
	if rig then
		local camYaw = sim.yaw
		local hv = flat(sim.vel)
		if hv.Magnitude > 8 and vF > 0 then
			camYaw += Common.wrap(Common.yawOf(hv) - sim.yaw) * (cfg.camera.lookAtVelocity or 0.3)
		end
		rig:setAngles(math.deg(camYaw), cfg.camera.pitch)
	end
end

function Driver:_event(session, name, value)
	local cfg = self.cfg
	if name == "Landed" then
		if CameraRig and value > 30 then
			pcall(CameraRig.shake, math.clamp(value / 260, 0, 0.5))
			pcall(CameraRig.punch, Vector3.new(0, -1, 0), math.clamp(value / 300, 0, 0.6))
		end
		self.Landed:Fire(value)
	elseif name == "Boosted" then
		if CameraRig then
			pcall(CameraRig.kick, cfg.boost.fov, 0.45)
			pcall(CameraRig.shake, cfg.boost.shake)
		end
		self.Boosted:Fire(value)
	elseif name == "Bumped" then
		if CameraRig then
			pcall(CameraRig.shake, math.clamp(value / 200, 0.05, 0.4))
		end
		self.Bumped:Fire(value)
	elseif name == "Fell" then
		self.Fell:Fire()
		self:reset(session.lastSafe or session.spawnCF)
	elseif self[name] then
		self[name]:Fire(value)
	end
	if name == "Landed" or (name == "DriftEnded" and session.sim.grounded) then
		session.lastSafe = session.sim.curCF + Vector3.new(0, 4, 0)
	end
end

-- Boost pads / pickups: adds `seconds` of boost (FOV kick + shake + flames).
function Driver:boost(seconds)
	local s = self.session
	if s and s.sim then
		s.sim:boost(seconds or 1)
		self:_event(s, "Boosted", "pad")
	end
end

-- Puts the vehicle upright (at cframe, or a little above where it is), zero speed.
function Driver:reset(cframe)
	local s = self.session
	if s and s.sim then
		s.sim:reset(cframe)
		s.root.CFrame = s.sim.curCF
	end
end

function Driver:exit()
	local s = self.session
	if not s then
		return
	end
	local h = s.humanoid
	if s.localOnly then
		self:_stop()
		if h then
			h.Sit = false
		end
	elseif h then
		h:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
		h.Sit = false
		h.Jump = true
	end
end

function Driver:setEnabled(on)
	self.enabled = on ~= false
	self.input:setEnabled(self.enabled and self.session ~= nil)
	return self
end

function Driver:state()
	local s = self.session
	local sim = s and s.sim
	if not sim then
		return { driving = false }
	end
	local inp = s.input or {}
	return { driving = true, speed = sim.vel.Magnitude, forwardSpeed = sim.vel:Dot(sim.curCF.LookVector),
		grounded = sim.grounded, airTime = sim.airTime, drifting = sim.drifting, tier = sim.tier,
		boosting = sim.boostT > 0, onWater = sim.onWater, throttle = inp.throttle or 0, steer = inp.steer or 0,
		cframe = sim.curCF }
end

function Driver:Destroy()
	self.maid:Clean()
	for _, n in EVENTS do
		self[n]:Destroy()
	end
end

------------------------------------------------------------------------------------------------ entry
function Vehicle.new(model, opts)
	if type(model) == "table" and opts == nil then
		model, opts = nil, model
	end
	if model == "seated" or model == "auto" then
		model = nil
		if IS_CLIENT then
			-- watch for any KitVehicle the local player sits in
			local d = Driver.new(false, opts)
			return d
		end
	end
	if IS_CLIENT then
		return Driver.new(model, opts)
	end
	return serverVehicle(model, opts)
end

Vehicle.Sim = Sim
return Vehicle
