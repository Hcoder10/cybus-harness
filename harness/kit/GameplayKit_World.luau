--!nonstrict
-- GameplayKit_World: moving platforms (players ride them), doors, and hazards for obbies/platformers: spinners,
-- lasers, crushers, kill/lava parts. Server only. Platforms and spinners are physics-driven (AlignPosition /
-- HingeConstraint motors) so characters standing on them are carried and pushed for real.

local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")

local Core = require((script.Parent :: Instance):WaitForChild("GameplayKit_Core"))
local Combat = require((script.Parent :: Instance):WaitForChild("GameplayKit_Combat"))
local Items = require((script.Parent :: Instance):WaitForChild("GameplayKit_Items"))
local Maid = require((script.Parent :: Instance):WaitForChild("Maid"))
local Signal = Core.Signal
local Health = Combat.Health

local World = {}

local function easing(style)
	if typeof(style) == "EnumItem" then
		return style
	end
	return Enum.EasingStyle[style or "Sine"] or Enum.EasingStyle.Sine
end

----------------------------------------------------------------------------------------------------------------
-- Mover: platforms that travel between points
----------------------------------------------------------------------------------------------------------------
local Mover = {}
Mover.__index = Mover
World.Mover = Mover
-- Mover.new(part | model, {offset=Vector3.new(0, 0, 20) | points={Vector3|CFrame...} (absolute, first = start),
--   time=3 (s per leg), pause=0.6, style="Sine", mode="pingpong"|"loop", physics=true (BaseParts: riders are
--   carried), rotate=nil (degrees/leg about Y)}) -> m (m:stop(); m.Arrived: Signal(index))
function Mover.new(target, opts)
	opts = opts or {}
	local self = setmetatable({ target = target, maid = Maid.new(), Arrived = Signal.new() }, Mover)
	local start = Core.cframe(target)
	local pts = { start }
	if opts.points then
		pts = {}
		for _, p in ipairs(opts.points) do
			local cf = Core.cframe(p)
			if cf and typeof(p) == "Vector3" then
				cf = CFrame.new(p) * start.Rotation
			end
			table.insert(pts, cf)
		end
	else
		table.insert(pts, start + (opts.offset or Vector3.new(0, 0, 20)))
	end
	if opts.rotate then
		for i = 2, #pts do
			pts[i] = pts[i] * CFrame.Angles(0, math.rad(opts.rotate * (i - 1)), 0)
		end
	end
	local driver
	if target:IsA("BasePart") and opts.physics ~= false then
		-- an anchored invisible driver is tweened; the real platform follows it with rigid constraints
		driver = Core.part({ Name = target.Name .. "Driver", Size = Vector3.one, Transparency = 1, CanCollide = false,
			CanQuery = false, CanTouch = false, CFrame = start, Parent = target.Parent })
		self.maid:Give(driver)
		local a0 = Instance.new("Attachment")
		a0.Parent = target
		local a1 = Instance.new("Attachment")
		a1.Parent = driver
		local ap = Instance.new("AlignPosition")
		ap.Attachment0, ap.Attachment1 = a0, a1
		ap.RigidityEnabled = true
		ap.Parent = target
		local ao = Instance.new("AlignOrientation")
		ao.Attachment0, ao.Attachment1 = a0, a1
		ao.RigidityEnabled = true
		ao.Parent = target
		self.maid:Give(a0)
		self.maid:Give(ap)
		self.maid:Give(ao)
		target.Anchored = false
		pcall(function()
			target:SetNetworkOwner(nil)
		end)
	end
	local cfv = Instance.new("CFrameValue")
	cfv.Value = start
	self.maid:Give(cfv)
	if not driver then
		self.maid:Give(cfv.Changed:Connect(function(v)
			if target.Parent then
				if target:IsA("Model") then
					target:PivotTo(v)
				else
					target.CFrame = v
				end
			end
		end))
	end
	local info = TweenInfo.new(opts.time or 3, easing(opts.style), Enum.EasingDirection.InOut)
	local pause = opts.pause or 0.6
	local mode = opts.mode or "pingpong"
	self.maid:Give(task.spawn(function()
		local i, dir = 1, 1
		while target.Parent do
			local ni = i + dir
			if ni > #pts then
				if mode == "loop" then
					ni = 1
				else
					dir = -1
					ni = i - 1
				end
			elseif ni < 1 then
				dir = 1
				ni = 2
			end
			local goal = pts[ni]
			local tw = driver and TweenService:Create(driver, info, { CFrame = goal }) or TweenService:Create(cfv, info, { Value = goal })
			tw:Play()
			tw.Completed:Wait()
			i = ni
			self.Arrived:Fire(i)
			task.wait(pause)
		end
	end))
	return self
end
function Mover:stop()
	self.maid:Clean()
	if self.target:IsA("BasePart") then
		self.target.Anchored = true
	end
end
Mover.destroy = Mover.stop

----------------------------------------------------------------------------------------------------------------
-- Door
----------------------------------------------------------------------------------------------------------------
local Door = {}
Door.__index = Door
World.Door = Door
-- Door.new(part | model, {open=CFrame (relative offset; default slides up by its height), time=0.6, prompt=true,
--   proximity=nil (studs: auto-open when a player is near), closeAfter=nil (s), locked=false,
--   key=nil (item type the player must be holding / have: player attribute "Holding" or Inventory),
--   inventory=Inventory?}) -> d (d:open(); d:close(); d:toggle(); d.locked; d.Changed: Signal(isOpen))
function Door.new(target, opts)
	opts = opts or {}
	local closed = Core.cframe(target)
	local size = target:IsA("BasePart") and target.Size or target:GetExtentsSize()
	local self = setmetatable({
		target = target, closedCF = closed, openCF = closed * (opts.open or CFrame.new(0, size.Y - 0.2, 0)),
		isOpen = false, locked = opts.locked or false, key = opts.key, inventory = opts.inventory,
		info = TweenInfo.new(opts.time or 0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		closeAfter = opts.closeAfter, Changed = Signal.new(), maid = Maid.new(),
	}, Door)
	self.cfv = Instance.new("CFrameValue")
	self.cfv.Value = closed
	self.maid:Give(self.cfv)
	self.maid:Give(self.cfv.Changed:Connect(function(v)
		if target:IsA("Model") then
			target:PivotTo(v)
		else
			target.CFrame = v
		end
	end))
	if opts.prompt ~= false then
		local anchorPart = target:IsA("BasePart") and target or Core.root(target)
		self.promptH = Items.prompt(anchorPart, { action = "Open", object = opts.name or "Door", cooldown = 0.5 })
		self.maid:Give(self.promptH)
		self.promptH.Used:Connect(function(player)
			if self:allowed(player) then
				self:toggle()
			end
		end)
	end
	if opts.proximity then
		self.maid:Give(Core.every(0.25, function()
			local near = false
			for _, e in ipairs(Core.alivePlayers()) do
				if (e.root.Position - closed.Position).Magnitude <= opts.proximity and self:allowed(e.player) then
					near = true
					break
				end
			end
			if near ~= self.isOpen then
				if near then
					self:open()
				else
					self:close()
				end
			end
		end))
	end
	return self
end
function Door:allowed(player)
	if self.locked then
		return false
	end
	if not self.key then
		return true
	end
	if player:GetAttribute("Holding") == self.key then
		return true
	end
	return self.inventory ~= nil and self.inventory:has(player, self.key)
end
function Door:open()
	if self.isOpen then
		return
	end
	self.isOpen = true
	TweenService:Create(self.cfv, self.info, { Value = self.openCF }):Play()
	if self.promptH then
		self.promptH.prompt.ActionText = "Close"
	end
	self.Changed:Fire(true)
	if self.closeAfter then
		local token = {}
		self.token = token
		task.delay(self.closeAfter, function()
			if self.token == token then
				self:close()
			end
		end)
	end
end
function Door:close()
	if not self.isOpen then
		return
	end
	self.isOpen = false
	TweenService:Create(self.cfv, self.info, { Value = self.closedCF }):Play()
	if self.promptH then
		self.promptH.prompt.ActionText = "Open"
	end
	self.Changed:Fire(false)
end
function Door:toggle()
	if self.isOpen then
		self:close()
	else
		self:open()
	end
end
function Door:destroy()
	self.maid:Clean()
end

----------------------------------------------------------------------------------------------------------------
-- Hazards. All share one damage scanner (10 Hz spatial query per active hazard; per-target cooldown).
----------------------------------------------------------------------------------------------------------------
local Hazard = {}
World.Hazard = Hazard
local zones = {}
local scanner

local function ensureScanner()
	if scanner then
		return
	end
	scanner = Core.every(0.1, function()
		local now = os.clock()
		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		for z in pairs(zones) do
			if not z.part.Parent then
				zones[z] = nil
			elseif z.active == nil or z.active() then
				params.FilterDescendantsInstances = { z.part }
				local seen = {}
				for _, hit in ipairs(Workspace:GetPartsInPart(z.part, params)) do
					local m = Core.modelOf(hit)
					if m and not seen[m] and now - (z.last[m] or 0) >= z.cooldown then
						seen[m] = true
						z.last[m] = now
						local kb
						if z.knockback > 0 then
							local r = Core.root(m)
							local away = r and (r.Position - z.part.Position) * Vector3.new(1, 0, 1)
							kb = away and away.Magnitude > 0.1 and away.Unit * z.knockback or nil
						end
						Health.damage(m, z.damage, z.part, { knockback = kb, ignoreInvuln = z.damage == math.huge })
						z.Hit:Fire(m)
					end
				end
			end
		end
		if next(zones) == nil then
			scanner = nil
			return false
		end
		return true
	end)
end

-- Hazard.zone(part, {damage=25, cooldown=0.6, knockback=0, active=fn() -> bool}) -> z (z.Hit: Signal(model); z:destroy())
function Hazard.zone(part, o)
	o = o or {}
	local z = { part = part, damage = o.damage or 25, cooldown = o.cooldown or 0.6, knockback = o.knockback or 0,
		active = o.active, last = setmetatable({}, { __mode = "k" }), Hit = Signal.new() }
	zones[z] = true
	ensureScanner()
	function z.destroy()
		zones[z] = nil
	end
	z.Destroy = z.destroy
	return z
end

-- Hazard.kill(part, {damage=math.huge (instant kill), cooldown=0.5}) : lava / kill bricks
function Hazard.kill(part, o)
	o = o or {}
	return Hazard.zone(part, { damage = o.damage or math.huge, cooldown = o.cooldown or 0.5 })
end

-- Hazard.spinner({position=Vector3, length=18, thickness=1.2, speed=90 (deg/s), damage=20, knockback=70,
--   color="#FF4B3E", parent}) -> {bar, hub, zone}. Physics motor: the bar really sweeps players.
function Hazard.spinner(o)
	o = o or {}
	local pos = o.position or Vector3.new(0, 3, 0)
	local parent = o.parent or Core.folder("Hazards")
	local hub = Core.part({ Name = "SpinnerHub", Shape = Enum.PartType.Cylinder, Size = Vector3.new(1.6, 2, 2),
		Color = "#2B2B33", CanCollide = false, CFrame = CFrame.new(pos) * CFrame.Angles(0, 0, math.rad(90)), Parent = parent })
	local len = o.length or 18
	local t = o.thickness or 1.2
	local bar = Core.part({ Name = "SpinnerBar", Size = Vector3.new(len, t, t), Color = o.color or "#FF4B3E",
		Material = Enum.Material.Neon, Anchored = false, CFrame = CFrame.new(pos), Parent = parent })
	local a0 = Instance.new("Attachment")
	a0.CFrame = CFrame.Angles(0, 0, math.rad(90)) -- hinge axis = world Y
	a0.Parent = bar
	local a1 = Instance.new("Attachment")
	a1.CFrame = CFrame.new()
	a1.Parent = hub
	local hinge = Instance.new("HingeConstraint")
	hinge.Attachment0, hinge.Attachment1 = a0, a1
	hinge.ActuatorType = Enum.ActuatorType.Motor
	hinge.AngularVelocity = math.rad(o.speed or 90)
	hinge.MotorMaxTorque = 1e9
	hinge.MotorMaxAcceleration = 1e4
	hinge.Parent = bar
	pcall(function()
		bar:SetNetworkOwner(nil)
	end)
	local zone = Hazard.zone(bar, { damage = o.damage or 20, knockback = o.knockback or 70, cooldown = 0.8 })
	return { bar = bar, hub = hub, zone = zone }
end

-- Hazard.laser({from=Vector3, to=Vector3, on=1.5, off=1.5, warn=0.4, damage=100, width=0.4, color="#FF3355",
--   phase=0, parent}) -> {part, zone}: blinks on/off; harmless (and faint) while off, flickers during `warn`
function Hazard.laser(o)
	o = o or {}
	local a, b = o.from or Vector3.new(-10, 3, 0), o.to or Vector3.new(10, 3, 0)
	local len = (b - a).Magnitude
	local w = o.width or 0.4
	local part = Core.part({ Name = "Laser", Size = Vector3.new(w, w, len), Color = o.color or "#FF3355",
		Material = Enum.Material.Neon, CanCollide = false, CastShadow = false,
		CFrame = CFrame.lookAt(a, b) * CFrame.new(0, 0, -len / 2), Parent = o.parent or Core.folder("Hazards") })
	local on = false
	local zone = Hazard.zone(part, { damage = o.damage or 100, cooldown = 0.5, active = function()
		return on
	end })
	task.spawn(function()
		task.wait(o.phase or 0)
		while part.Parent do
			on = true
			part.Transparency = 0
			task.wait(o.on or 1.5)
			on = false
			part.Transparency = 0.9
			local offT, warnT = o.off or 1.5, math.min(o.warn or 0.4, o.off or 1.5)
			task.wait(offT - warnT)
			local tEnd = os.clock() + warnT
			while os.clock() < tEnd and part.Parent do
				part.Transparency = part.Transparency > 0.5 and 0.4 or 0.9
				task.wait(0.08)
			end
		end
	end)
	return { part = part, zone = zone }
end

-- Hazard.crusher(part? | nil, {position, size=Vector3.new(8,2,8), drop=10, down=0.25, hold=0.5, up=1.2,
--   pause=1, damage=100, phase=0, color="#5A5A66", parent}) -> {part, zone}: slams down, rises slowly
function Hazard.crusher(part, o)
	if type(part) == "table" and o == nil then
		o, part = part, nil
	end
	o = o or {}
	part = part or Core.part({ Name = "Crusher", Size = o.size or Vector3.new(8, 2, 8), Color = o.color or "#5A5A66",
		Material = Enum.Material.Metal, CFrame = CFrame.new(o.position or Vector3.new(0, 12, 0)), Parent = o.parent or Core.folder("Hazards") })
	part.Anchored = true
	local top = part.CFrame
	local bottom = top - Vector3.new(0, o.drop or 10, 0)
	local moving = false
	local zone = Hazard.zone(part, { damage = o.damage or 100, cooldown = 0.5, active = function()
		return moving
	end })
	task.spawn(function()
		task.wait(o.phase or 0)
		while part.Parent do
			moving = true
			local tw = TweenService:Create(part, TweenInfo.new(o.down or 0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { CFrame = bottom })
			tw:Play()
			tw.Completed:Wait()
			task.wait(o.hold or 0.5)
			moving = false
			tw = TweenService:Create(part, TweenInfo.new(o.up or 1.2, Enum.EasingStyle.Sine), { CFrame = top })
			tw:Play()
			tw.Completed:Wait()
			task.wait(o.pause or 1)
		end
	end)
	return { part = part, zone = zone }
end

-- Maid-friendly aliases (maid:Give(obj) calls obj:Destroy())
Mover.Destroy = Mover.destroy
Door.Destroy = Door.destroy

return World
