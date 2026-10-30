--!nonstrict
-- ControllerKit_Common: shared plumbing for ControllerKit's profiles (you rarely need it directly).
--   Signal      tiny event: s:Connect(fn) -> conn (conn:Disconnect()); s:Once(fn); s:Fire(...); s:Wait()
--   Input       one ContextActionService front end for keyboard/mouse, gamepad and touch (touch buttons are built only
--               when UserInputService.TouchEnabled); every binding is undone by the owning Maid
--   Mover       tuned acceleration / deceleration for a Humanoid, applied through WalkSpeed + Humanoid:Move
--   merge, controls, moveIntent, flat, character helpers
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")

local Common = {}

------------------------------------------------------------------------------------------------ helpers
local warned = {}
function Common.warnOnce(key, msg)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("[ControllerKit] " .. msg)
end

local function isPlain(v)
	return type(v) == "table" and getmetatable(v) == nil
end

-- Deep-merges `over` onto a copy of `base` (plain tables only; arrays and instances are replaced, not merged).
function Common.merge(base, over)
	local out = {}
	for k, v in base do
		out[k] = if isPlain(v) then Common.merge(v, {}) else v
	end
	if type(over) == "table" then
		for k, v in over do
			if isPlain(v) and isPlain(out[k]) and #v == 0 then
				out[k] = Common.merge(out[k], v)
			else
				out[k] = v
			end
		end
	end
	return out
end

function Common.flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

function Common.clampMagnitude(v, max)
	local m = v.Magnitude
	if m > max and m > 0 then
		return v * (max / m)
	end
	return v
end

function Common.alpha(rate, dt)
	if rate <= 0 or dt <= 0 then
		return 0
	end
	return 1 - math.exp(-rate * dt)
end

function Common.damp(a, b, rate, dt)
	return a + (b - a) * Common.alpha(rate, dt)
end

function Common.wrap(a)
	return (a + math.pi) % (2 * math.pi) - math.pi
end

function Common.dampAngle(a, b, rate, dt)
	return a + Common.wrap(b - a) * Common.alpha(rate, dt)
end

function Common.smoothstep(e0, e1, x)
	if e1 == e0 then
		return if x >= e1 then 1 else 0
	end
	local t = math.clamp((x - e0) / (e1 - e0), 0, 1)
	return t * t * (3 - 2 * t)
end

-- Yaw (radians) of a look vector, matching CFrame.fromEulerAnglesYXZ(0, yaw, 0).
function Common.yawOf(v)
	return math.atan2(-v.X, -v.Z)
end

function Common.lookOfYaw(yaw)
	return Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))
end

function Common.color(v, default)
	if typeof(v) == "Color3" then
		return v
	elseif type(v) == "string" then
		local ok, c = pcall(Color3.fromHex, v)
		if ok then
			return c
		end
	end
	return default
end

function Common.sibling(name)
	local ok, mod = pcall(function()
		return require((script.Parent :: Instance):WaitForChild(name, 5))
	end)
	return if ok then mod else nil
end

-- The default PlayerModule controls (nil when a game replaced them).
function Common.controls()
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

-- Raw move input (keyboard WASD/arrows, gamepad left stick, touch thumbstick): Vector3 with X = right, Z = back
-- (so forward is -Z), magnitude 0..1. Read through the default controls so every device works the same.
local cachedControls, controlsAt = nil, -1
function Common.rawMove(humanoid)
	if cachedControls == nil and os.clock() - controlsAt > 2 then
		controlsAt = os.clock()
		cachedControls = Common.controls()
	end
	if cachedControls then
		local ok, v = pcall(cachedControls.GetMoveVector, cachedControls)
		if ok and typeof(v) == "Vector3" then
			return v
		end
	end
	-- fallback: world MoveDirection expressed in camera space
	if humanoid then
		local cam = workspace.CurrentCamera
		local md = humanoid.MoveDirection
		if cam and md.Magnitude > 0 then
			local yaw = Common.yawOf(cam.CFrame.LookVector)
			return CFrame.Angles(0, yaw, 0):VectorToObjectSpace(md)
		end
	end
	return Vector3.zero
end

-- Camera-relative move intent in world space (flat, magnitude 0..1).
function Common.moveIntent(humanoid)
	local raw = Common.rawMove(humanoid)
	if raw.Magnitude < 0.05 then
		return Vector3.zero
	end
	local cam = workspace.CurrentCamera
	local yaw = if cam then Common.yawOf(cam.CFrame.LookVector) else 0
	local w = CFrame.Angles(0, yaw, 0):VectorToWorldSpace(Vector3.new(raw.X, 0, raw.Z))
	return Common.clampMagnitude(w, 1)
end

-- Resolves player | character | nil (local player) to (player, character, humanoid, root); waits for a character.
function Common.resolveCharacter(who)
	local player, character
	if typeof(who) == "Instance" and who:IsA("Player") then
		player = who
	elseif typeof(who) == "Instance" and who:IsA("Model") then
		character = who
		player = Players:GetPlayerFromCharacter(who)
	else
		player = Players.LocalPlayer
	end
	if not character and player then
		character = player.Character or player.CharacterAdded:Wait()
	end
	local humanoid = character and character:WaitForChild("Humanoid", 10)
	local root = humanoid and (humanoid.RootPart or character:WaitForChild("HumanoidRootPart", 10))
	return player, character, humanoid, root
end

-- Calls fn(character, humanoid, root) for the current and every future character of `player` (or once for a
-- bare character). Returns a cleanup function.
function Common.eachCharacter(who, fn)
	local conns = {}
	local function run(character)
		task.spawn(function()
			local humanoid = character:WaitForChild("Humanoid", 10)
			local root = humanoid and (humanoid.RootPart or character:WaitForChild("HumanoidRootPart", 10))
			if humanoid and root then
				fn(character, humanoid, root)
			end
		end)
	end
	local player = if typeof(who) == "Instance" and who:IsA("Player") then who else nil
	if typeof(who) == "Instance" and who:IsA("Model") then
		run(who)
		player = nil
	elseif who == nil then
		player = Players.LocalPlayer
	end
	if player then
		if player.Character then
			run(player.Character)
		end
		table.insert(conns, player.CharacterAdded:Connect(run))
	end
	return function()
		for _, c in conns do
			c:Disconnect()
		end
	end
end

------------------------------------------------------------------------------------------------ Signal
local Signal = {}
Signal.__index = Signal
Common.Signal = Signal

function Signal.new()
	return setmetatable({ _handlers = {} }, Signal)
end

function Signal:Connect(fn)
	local handlers = self._handlers
	local entry = { fn = fn }
	table.insert(handlers, entry)
	return {
		Connected = true,
		Disconnect = function(conn)
			conn.Connected = false
			local i = table.find(handlers, entry)
			if i then
				table.remove(handlers, i)
			end
		end,
	}
end

function Signal:Once(fn)
	local conn
	conn = self:Connect(function(...)
		conn:Disconnect()
		fn(...)
	end)
	return conn
end

function Signal:Fire(...)
	for _, entry in table.clone(self._handlers) do
		task.spawn(entry.fn, ...)
	end
end

function Signal:Wait()
	local thread = coroutine.running()
	self:Once(function(...)
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

function Signal:Destroy()
	table.clear(self._handlers)
end

-- Creates one Signal per name on `obj`.
function Common.signals(obj, names)
	for _, n in names do
		obj[n] = Signal.new()
	end
end

------------------------------------------------------------------------------------------------ Input
-- Input.new(maid, prefix) -> input
--   input:bind(name, {keys}, fn(began: boolean, inputObject), {touch = "Label", slot = 1..6, sink = true})
--   input:axis() etc. are profile-specific; Input only owns bindings, the touch pad and their cleanup.
local Input = {}
Input.__index = Input
Common.Input = Input

local PRIORITY = Enum.ContextActionPriority.High.Value + 50
local counter = 0

-- Touch button slots (scale positions, right side of the screen, around the default jump button).
local SLOTS = {
	{ 0.80, 0.56 }, -- 1: above the jump button
	{ 0.68, 0.70 }, -- 2: left of the jump button
	{ 0.68, 0.56 }, -- 3
	{ 0.92, 0.44 }, -- 4
	{ 0.80, 0.42 }, -- 5
	{ 0.56, 0.70 }, -- 6
	{ 0.90, 0.72 }, -- 7: where the jump button sits (used when the profile owns jumping)
}

function Input.new(maid, prefix)
	counter += 1
	local self = setmetatable({ maid = maid, prefix = (prefix or "Kit") .. counter .. "_", names = {}, gui = nil,
		buttons = {}, enabled = true }, Input)
	maid:Give(function()
		self:unbindAll()
	end)
	return self
end

function Input:_pad()
	if self.gui then
		return self.gui
	end
	local player = Players.LocalPlayer
	local pg = player and player:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return nil
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "KitControls"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 5
	gui.Parent = pg
	self.gui = gui
	self.maid:Give(gui)
	return gui
end

local function makeTouchButton(gui, label, slot)
	local pos = SLOTS[math.clamp(slot or 1, 1, #SLOTS)]
	local b = Instance.new("TextButton")
	b.Name = label
	b.AnchorPoint = Vector2.new(0.5, 0.5)
	b.Position = UDim2.fromScale(pos[1], pos[2])
	b.Size = UDim2.fromOffset(74, 74)
	b.BackgroundColor3 = Color3.fromRGB(20, 22, 30)
	b.BackgroundTransparency = 0.35
	b.Text = label
	b.TextColor3 = Color3.new(1, 1, 1)
	b.TextScaled = true
	b.Font = Enum.Font.GothamBold
	b.AutoButtonColor = false
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = b
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.new(1, 1, 1)
	stroke.Transparency = 0.55
	stroke.Thickness = 2
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = b
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0.18, 0)
	pad.PaddingRight = UDim.new(0.18, 0)
	pad.PaddingTop = UDim.new(0.3, 0)
	pad.PaddingBottom = UDim.new(0.3, 0)
	pad.Parent = b
	b.Parent = gui
	return b
end

-- Binds an action. fn(began, inputObject) runs on press (true) and release (false).
function Input:bind(name, keys, fn, opts)
	opts = opts or {}
	local action = self.prefix .. name
	local sink = opts.sink ~= false
	local function handler(_, state, obj)
		if not self.enabled then
			return Enum.ContextActionResult.Pass
		end
		if state == Enum.UserInputState.Begin then
			fn(true, obj)
		elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
			fn(false, obj)
		end
		return if sink then Enum.ContextActionResult.Sink else Enum.ContextActionResult.Pass
	end
	if #keys > 0 then
		ContextActionService:BindActionAtPriority(action, handler, false, opts.priority or PRIORITY, table.unpack(keys))
		table.insert(self.names, action)
	end
	if opts.touch and UserInputService.TouchEnabled then
		local gui = self:_pad()
		if gui then
			local b = makeTouchButton(gui, opts.touch, opts.slot)
			self.buttons[name] = b
			b.InputBegan:Connect(function(io)
				if self.enabled and (io.UserInputType == Enum.UserInputType.Touch
					or io.UserInputType == Enum.UserInputType.MouseButton1) then
					b.BackgroundTransparency = 0.1
					fn(true, io)
				end
			end)
			b.InputEnded:Connect(function(io)
				if io.UserInputType == Enum.UserInputType.Touch or io.UserInputType == Enum.UserInputType.MouseButton1 then
					b.BackgroundTransparency = 0.35
					fn(false, io)
				end
			end)
		end
	end
end

function Input:setEnabled(on)
	self.enabled = on
	if self.gui then
		self.gui.Enabled = on
	end
end

function Input:unbindAll()
	for _, action in self.names do
		ContextActionService:UnbindAction(action)
	end
	table.clear(self.names)
end

------------------------------------------------------------------------------------------------ Mover
-- Humanoid movement with real acceleration: keeps its own horizontal velocity and feeds it to the Humanoid
-- (WalkSpeed = |velocity|, Move(direction)), after the default controls each render step, so it wins.
local Mover = {}
Mover.__index = Mover
Common.Mover = Mover

function Mover.new(humanoid, root)
	return setmetatable({ humanoid = humanoid, root = root, vel = Vector3.zero }, Mover)
end

-- intent: flat world vector (magnitude 0..1). p: {speed, accel, decel, turn, air (0..1 multiplier)}.
function Mover:step(dt, intent, p, grounded)
	local target = intent * p.speed
	local vel = self.vel
	-- in the air, speed above the run speed (long jumps, dives, dashes) is kept while you steer along it
	local cur = vel.Magnitude
	if not grounded and cur > p.speed and intent:Dot(vel) > 0 then
		target = intent.Unit * cur
	end
	local rate
	if intent.Magnitude > 0.05 then
		rate = if vel:Dot(target) < 0 then p.turn else p.accel
	else
		rate = p.decel
	end
	if not grounded then
		rate *= p.air
	end
	vel += Common.clampMagnitude(target - vel, rate * dt)
	-- blocked (walls, slopes): let the real velocity pull ours back so speed is not stored up against a wall
	local actual = Common.flat(self.root.AssemblyLinearVelocity)
	local speed = vel.Magnitude
	if speed > 1 and grounded and actual:Dot(vel / speed) < speed * 0.5 then
		vel = Common.damp(vel, actual, 6, dt)
	end
	self.vel = vel
	self:apply()
end

function Mover:apply()
	local speed = self.vel.Magnitude
	self.humanoid.WalkSpeed = speed
	self.humanoid:Move(if speed > 0.05 then self.vel / speed else Vector3.zero, false)
end

-- Sets the horizontal velocity now (dashes, long jumps, wall kicks), on the body too.
function Mover:set(v)
	v = Common.flat(v)
	self.vel = v
	local cur = self.root.AssemblyLinearVelocity
	self.root.AssemblyLinearVelocity = Vector3.new(v.X, cur.Y, v.Z)
	self:apply()
end

------------------------------------------------------------------------------------------------ render steps
-- Binds fn(dt) to a render step; returns the unbind function.
function Common.renderStep(prefix, priority, fn)
	counter += 1
	local name = prefix .. counter
	RunService:BindToRenderStep(name, priority, fn)
	return function()
		RunService:UnbindFromRenderStep(name)
	end
end

return Common
