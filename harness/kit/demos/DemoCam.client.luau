-- Demo camera for kit screenshots (blocksfield.kit_demo). Workspace attributes drive it:
--   DemoCam = "x,y,z,tx,ty,tz"          a fixed shot
--   WK2DemoSpots = JSON {name: {x,y,z}}  a tour, one spot every DemoCamEvery seconds (default 5), orbit-framed
-- Waits for the character first: the PlayerModule resets the camera to Custom when the character spawns.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local player = Players.LocalPlayer
if not player.Character then
	player.CharacterAdded:Wait()
end
task.wait(2)
local camera = workspace.CurrentCamera
local target: CFrame? = nil
RunService:BindToRenderStep("KitDemoCam", Enum.RenderPriority.Camera.Value + 2, function()
	if target then
		camera.CameraType = Enum.CameraType.Scriptable
		camera.CFrame = camera.CFrame:Lerp(target, 0.15)
	end
end)
local function fixed()
	local s = workspace:GetAttribute("DemoCam")
	if type(s) ~= "string" then
		return false
	end
	local v = {}
	for n in string.gmatch(s, "[-%d%.]+") do
		table.insert(v, tonumber(n))
	end
	if #v >= 6 then
		target = CFrame.lookAt(Vector3.new(v[1], v[2], v[3]), Vector3.new(v[4], v[5], v[6]))
		return true
	end
	return false
end
while true do
	if not fixed() then
		local spots = workspace:GetAttribute("WK2DemoSpots")
		if type(spots) == "string" then
			local ok, map = pcall(function() return HttpService:JSONDecode(spots) end)
			if ok and type(map) == "table" then
				local names = {}
				for name in pairs(map) do
					table.insert(names, name)
				end
				table.sort(names)
				for _, name in ipairs(names) do
					local p = map[name]
					local at = Vector3.new(p[1] or p.x or 0, p[2] or p.y or 0, p[3] or p.z or 0)
					target = CFrame.lookAt(at + Vector3.new(-55, 38, -55), at)
					workspace:SetAttribute("DemoCamSpot", name)
					task.wait(workspace:GetAttribute("DemoCamEvery") or 5)
				end
			end
		end
	end
	task.wait(1)
end
