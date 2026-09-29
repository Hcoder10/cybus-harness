-- Spring: a damped spring for numbers, Vector2 and Vector3 (camera follow, UI wobble, recoil, sway).
--   local s = Spring.new(Vector3.zero, 12, 1)   -- initial, speed (angular frequency), damping ratio (1 = critical)
--   s.Target = goal; local pos = s:Step(dt); s:Impulse(Vector3.new(0, 5, 0))
-- Frame-rate independent: integrates in fixed substeps.
local Spring = {}
Spring.__index = Spring

local SUBSTEP = 1 / 240

function Spring.new(initial, speed, damping)
	local zero = initial * 0
	return setmetatable({
		Position = initial,
		Velocity = zero,
		Target = initial,
		Speed = speed or 12,
		Damping = damping or 1,
	}, Spring)
end

function Spring:Step(dt)
	local steps = math.clamp(math.ceil(dt / SUBSTEP), 1, 64)
	local h = dt / steps
	local k, d = self.Speed, self.Damping
	for _ = 1, steps do
		local accel = (self.Target - self.Position) * (k * k) - self.Velocity * (2 * d * k)
		self.Velocity += accel * h
		self.Position += self.Velocity * h
	end
	return self.Position
end

function Spring:Impulse(velocity)
	self.Velocity += velocity
end

function Spring:Snap(value)
	self.Position = value
	self.Target = value
	self.Velocity = value * 0
end

return Spring
