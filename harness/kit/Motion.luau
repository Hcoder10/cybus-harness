-- Motion: UI and object motion from the game's motion tokens.
--   Motion.tween(obj, {Position = ...}, "base")        eased tween using Tokens.motion
--   Motion.press(button) / Motion.hover(button, true)  tactile button response
--   Motion.enter(frame, {stagger = 0.04}) / Motion.exit(frame)   panel entrance / exit with staggered children
--   Motion.punch(gui, 0.12)                            scale bounce for rewards and hits
--   Motion.countUp(label, 0, 1250, 0.6, "%d")          number roll-up
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Tokens
do
	local ok, result = pcall(function()
		return require(ReplicatedStorage:WaitForChild("Shared", 5):WaitForChild("Tokens", 5))
	end)
	Tokens = ok and result or nil
end

local DUR = { fast = 0.12, base = 0.2, slow = 0.35, dramatic = 0.6 }

local Motion = {}

local function duration(kind)
	if type(kind) == "number" then
		return kind
	end
	local m = Tokens and Tokens.motion
	return (m and m[kind or "base"]) or DUR[kind or "base"] or DUR.base
end

function Motion.info(kind, style, direction, delay)
	local easeOut = (Tokens and Tokens.motion and Tokens.motion.easeOut) or Enum.EasingStyle.Quint
	return TweenInfo.new(duration(kind), style or easeOut, direction or Enum.EasingDirection.Out, 0, false, delay or 0)
end

function Motion.tween(obj, goal, kind, style, direction, delay)
	local tween = TweenService:Create(obj, Motion.info(kind, style, direction, delay), goal)
	tween:Play()
	return tween
end

-- A UIScale owned by Motion, so press / punch / enter never fight a layout's own UIScale.
function Motion.scaleOf(gui)
	local s = gui:FindFirstChild("MotionScale")
	if not s then
		s = Instance.new("UIScale")
		s.Name = "MotionScale"
		s.Parent = gui
	end
	return s
end

function Motion.press(gui)
	local s = Motion.scaleOf(gui)
	local down = Motion.tween(s, { Scale = 0.94 }, "fast", Enum.EasingStyle.Quad)
	down.Completed:Once(function()
		Motion.tween(s, { Scale = 1 }, "base", Enum.EasingStyle.Back)
	end)
end

function Motion.hover(gui, on)
	Motion.tween(Motion.scaleOf(gui), { Scale = on and 1.04 or 1 }, "fast", Enum.EasingStyle.Quad)
end

function Motion.punch(gui, amount)
	local s = Motion.scaleOf(gui)
	s.Scale = 1 + (amount or 0.12)
	Motion.tween(s, { Scale = 1 }, "slow", Enum.EasingStyle.Back)
end

local function basePosition(gui)
	local p = gui:GetAttribute("MotionBasePosition")
	if typeof(p) ~= "UDim2" then
		p = gui.Position
		gui:SetAttribute("MotionBasePosition", p)
	end
	return p
end

local function slideIn(gui, offsetY, kind, delay)
	local base = basePosition(gui)
	gui.Position = base + UDim2.fromOffset(0, offsetY)
	Motion.tween(gui, { Position = base }, kind, nil, nil, delay)
	local s = Motion.scaleOf(gui)
	s.Scale = 0.96
	Motion.tween(s, { Scale = 1 }, kind, nil, nil, delay)
	if gui:IsA("CanvasGroup") then
		gui.GroupTransparency = 1
		Motion.tween(gui, { GroupTransparency = 0 }, kind, nil, nil, delay)
	end
end

-- Shows a panel with a slide + scale (and fade for CanvasGroups); children in LayoutOrder are staggered.
function Motion.enter(gui, opts)
	opts = opts or {}
	gui.Visible = true
	slideIn(gui, opts.offset or 20, opts.kind or "slow", 0)
	if opts.stagger ~= false then
		local kids = {}
		for _, child in gui:GetChildren() do
			if child:IsA("GuiObject") and child.Visible then
				table.insert(kids, child)
			end
		end
		table.sort(kids, function(a, b)
			return a.LayoutOrder < b.LayoutOrder
		end)
		for i, child in kids do
			if not child.Parent:FindFirstChildWhichIsA("UIGridStyleLayout") then
				slideIn(child, opts.childOffset or 12, opts.kind or "slow", (opts.stagger or 0.04) * i)
			else
				local s = Motion.scaleOf(child)
				s.Scale = 0.9
				Motion.tween(s, { Scale = 1 }, opts.kind or "slow", Enum.EasingStyle.Back, nil, (opts.stagger or 0.04) * i)
			end
		end
	end
end

function Motion.exit(gui, opts)
	opts = opts or {}
	local base = basePosition(gui)
	local t = Motion.tween(gui, { Position = base + UDim2.fromOffset(0, opts.offset or 16) }, opts.kind or "base",
		Motion.info().EasingStyle, Enum.EasingDirection.In)
	Motion.tween(Motion.scaleOf(gui), { Scale = 0.97 }, opts.kind or "base", nil, Enum.EasingDirection.In)
	if gui:IsA("CanvasGroup") then
		Motion.tween(gui, { GroupTransparency = 1 }, opts.kind or "base", nil, Enum.EasingDirection.In)
	end
	t.Completed:Once(function()
		gui.Visible = false
		gui.Position = base
	end)
	return t
end

-- Rolls a TextLabel from one number to another with an ease-out curve.
function Motion.countUp(label, from, to, seconds, format)
	seconds = seconds or 0.6
	local start = os.clock()
	local conn
	conn = RunService.Heartbeat:Connect(function()
		local a = math.clamp((os.clock() - start) / seconds, 0, 1)
		local eased = 1 - (1 - a) ^ 4
		local v = from + (to - from) * eased
		label.Text = string.format(format or "%d", math.floor(v + 0.5))
		if a >= 1 then
			conn:Disconnect()
		end
	end)
	return conn
end

return Motion
