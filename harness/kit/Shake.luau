-- Shake: trauma-based camera shake (client only). Trauma decays; shake grows with trauma squared, so small
-- events barely move the camera and big ones land.
--   Shake.kick(0.4)             add trauma to the shared shaker (auto-binds after the camera each frame)
--   Shake.reduceMotion = true   a settings toggle scales every shake to zero
--   local s = Shake.new(); local offset = s:Step(dt)   for a custom camera module (multiply into its CFrame)
local RunService = game:GetService("RunService")

local Shake = {}
Shake.__index = Shake
Shake.reduceMotion = false

function Shake.new(opts)
	opts = opts or {}
	return setmetatable({
		trauma = 0,
		decay = opts.decay or 1.8, -- trauma lost per second
		maxAngle = opts.maxAngle or math.rad(2.5),
		maxOffset = opts.maxOffset or 0.3, -- studs
		frequency = opts.frequency or 18,
		t = 0,
	}, Shake)
end

function Shake:Add(amount)
	self.trauma = math.clamp(self.trauma + amount, 0, 1)
end

function Shake:Step(dt)
	self.t += dt
	self.trauma = math.max(0, self.trauma - self.decay * dt)
	if Shake.reduceMotion or self.trauma <= 0 then
		return CFrame.identity
	end
	local s = self.trauma * self.trauma
	local f = self.t * self.frequency
	local x = math.noise(f, 1.37) * self.maxOffset * s
	local y = math.noise(f, 7.91) * self.maxOffset * s
	local roll = math.noise(f, 13.3) * self.maxAngle * s
	local pitch = math.noise(f, 21.7) * self.maxAngle * 0.5 * s
	return CFrame.new(x, y, 0) * CFrame.Angles(pitch, 0, roll)
end

local shared
function Shake.kick(amount)
	if not RunService:IsClient() then
		return
	end
	if not shared then
		shared = Shake.new()
		RunService:BindToRenderStep("KitShake", Enum.RenderPriority.Camera.Value + 2, function(dt)
			local cam = workspace.CurrentCamera
			if cam then
				cam.CFrame = cam.CFrame * shared:Step(dt)
			end
		end)
	end
	shared:Add(amount)
end

return Shake
