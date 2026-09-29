-- Screen: fit a UI designed on the 1920x1080 canvas to any viewport, and tell compact (phone) layouts apart.
--   local gui = Screen.gui("Hud", 10)       a ScreenGui in PlayerGui with sane defaults and a FitScale
--   Screen.isCompact()                        true on small screens: switch to the compact layout
--   Screen.topInset()                         height of the Roblox top bar to keep clear
local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")

local Screen = {}
local CANVAS = Vector2.new(1920, 1080)
local MIN_SCALE = 0.55 -- keeps phone text readable; compact layouts must fit the larger effective canvas

function Screen.scale()
	local cam = workspace.CurrentCamera
	local v = cam and cam.ViewportSize or CANVAS
	return math.clamp(math.min(v.X / CANVAS.X, v.Y / CANVAS.Y), MIN_SCALE, 2)
end

-- The canvas size the UI actually has at the current scale (use it to fit panels on compact screens).
function Screen.canvas()
	local cam = workspace.CurrentCamera
	local v = cam and cam.ViewportSize or CANVAS
	return v / Screen.scale()
end

function Screen.isCompact()
	local cam = workspace.CurrentCamera
	local v = cam and cam.ViewportSize or CANVAS
	return math.min(v.X, v.Y) < 600
end

function Screen.topInset()
	local inset = GuiService:GetGuiInset()
	return inset.Y
end

function Screen.fit(gui)
	local scale = gui:FindFirstChild("FitScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Name = "FitScale"
		scale.Parent = gui
	end
	local function update()
		scale.Scale = Screen.scale()
	end
	update()
	local cam = workspace.CurrentCamera
	if cam then
		cam:GetPropertyChangedSignal("ViewportSize"):Connect(update)
	end
	return scale
end

function Screen.gui(name, displayOrder)
	local player = Players.LocalPlayer
	local pg = player:WaitForChild("PlayerGui")
	local gui = pg:FindFirstChild(name)
	if not gui then
		gui = Instance.new("ScreenGui")
		gui.Name = name
		gui.ResetOnSpawn = false
		gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		gui.IgnoreGuiInset = true
		gui.DisplayOrder = displayOrder or 0
		gui.Parent = pg
	end
	Screen.fit(gui)
	return gui
end

return Screen
