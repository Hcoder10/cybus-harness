--!strict
--!native
-- FxMath: the pure math and data behind CameraRig and VFX. No Roblox APIs, so it also runs (and is tested)
-- outside Roblox. Values may be numbers or vectors (Vector3): lerps, springs and paths only use arithmetic.
--   FxMath.ease(0.3, "Quint Out")                         eased 0..1 ("Quint", "Quint Out", {"Back", "In"}, Enum)
--   local x, v = FxMath.springStep(x, v, goal, 12, 1, dt)  exact damped spring (speed = angular freq., damping ratio)
--   FxMath.keypoints({0.2, 1, 0}, isNumber)               -> {{t, v, e}, ...} ready for a NumberSequence
--   FxMath.validateEffect(spec)                           -> {"layers[2].lifetime: ..."} (the rules VFX applies)
local FxMath = {}

local PI = math.pi
local HALF_PI = PI * 0.5
local TAU = PI * 2
local HUGE = math.huge

export type Keypoint = { t: number, v: any, e: number }
export type Path = { points: { any }, cum: { number }, params: { number }, length: number }

local function isNum(v: any): boolean
	return type(v) == "number" and v == v and v ~= HUGE and v ~= -HUGE
end
FxMath.isNumber = isNum

local function isVec(v: any): boolean
	local t = typeof(v)
	return t == "Vector3" or t == "vector"
end
FxMath.isVector = isVec

function FxMath.clamp(x: number, lo: number, hi: number): number
	if x ~= x or x < lo then
		return lo
	elseif x > hi then
		return hi
	end
	return x
end
local clamp = FxMath.clamp

function FxMath.lerp(a: any, b: any, t: number): any
	return a + (b - a) * t
end

function FxMath.smoothstep(e0: number, e1: number, x: number): number
	if e1 == e0 then
		return if x >= e1 then 1 else 0
	end
	local t = clamp((x - e0) / (e1 - e0), 0, 1)
	return t * t * (3 - 2 * t)
end

-- Exponential smoothing factor for a rate (1/s): alpha = 1 - e^(-rate * dt). rate <= 0 never moves.
function FxMath.alpha(rate: number, dt: number): number
	if not (rate > 0) or not (dt > 0) then
		return 0
	elseif rate == HUGE then
		return 1
	end
	return 1 - math.exp(-rate * dt)
end

function FxMath.damp(current: any, target: any, rate: number, dt: number): any
	return current + (target - current) * FxMath.alpha(rate, dt)
end

-- Wraps an angle (radians) into [-pi, pi).
function FxMath.wrapAngle(a: number): number
	return (a + PI) % TAU - PI
end

function FxMath.dampAngle(current: number, target: number, rate: number, dt: number): number
	return current + FxMath.wrapAngle(target - current) * FxMath.alpha(rate, dt)
end

-- Distance between two numbers or two vectors.
function FxMath.distance(a: any, b: any): number
	if type(a) == "number" then
		return math.abs((b :: number) - a)
	end
	local d = b - a
	return math.sqrt(d.X * d.X + d.Y * d.Y + d.Z * d.Z)
end
local distance = FxMath.distance

------------------------------------------------------------------------------------------------ easing
-- The same styles and directions as TweenService (Enum.EasingStyle / Enum.EasingDirection). Out and InOut are
-- built from In, so every style is defined once: Out(t) = 1 - In(1 - t).
local function bounceOut(t: number): number
	local n1, d1 = 7.5625, 2.75
	if t < 1 / d1 then
		return n1 * t * t
	elseif t < 2 / d1 then
		t -= 1.5 / d1
		return n1 * t * t + 0.75
	elseif t < 2.5 / d1 then
		t -= 2.25 / d1
		return n1 * t * t + 0.9375
	end
	t -= 2.625 / d1
	return n1 * t * t + 0.984375
end

local EASE_IN: { [string]: (number) -> number } = {
	linear = function(t: number): number
		return t
	end,
	sine = function(t: number): number
		return 1 - math.cos(t * HALF_PI)
	end,
	quad = function(t: number): number
		return t * t
	end,
	cubic = function(t: number): number
		return t * t * t
	end,
	quart = function(t: number): number
		return t * t * t * t
	end,
	quint = function(t: number): number
		return t * t * t * t * t
	end,
	exponential = function(t: number): number
		return if t <= 0 then 0 else 2 ^ (10 * t - 10)
	end,
	circular = function(t: number): number
		return 1 - math.sqrt(math.max(0, 1 - t * t))
	end,
	back = function(t: number): number
		return 2.70158 * t * t * t - 1.70158 * t * t
	end,
	elastic = function(t: number): number
		if t <= 0 then
			return 0
		elseif t >= 1 then
			return 1
		end
		return -(2 ^ (10 * t - 10)) * math.sin((t * 10 - 10.75) * (TAU / 3))
	end,
	bounce = function(t: number): number
		return 1 - bounceOut(1 - t)
	end,
}

local function c01(t: number): number
	if t ~= t or t < 0 then
		return 0
	elseif t > 1 then
		return 1
	end
	return t
end

local EASE: { [string]: { [string]: (number) -> number } } = {}
for name, f in EASE_IN do
	EASE[name] = {
		["in"] = function(t: number): number
			return f(c01(t))
		end,
		out = function(t: number): number
			return 1 - f(1 - c01(t))
		end,
		inout = function(t: number): number
			t = c01(t)
			if t < 0.5 then
				return f(2 * t) * 0.5
			end
			return 1 - f(2 - 2 * t) * 0.5
		end,
	}
end

FxMath.EASE_STYLES = { "Linear", "Sine", "Quad", "Cubic", "Quart", "Quint", "Exponential", "Circular", "Back",
	"Bounce", "Elastic" }
FxMath.EASE_DIRECTIONS = { "In", "Out", "InOut" }
local STYLE_ALIAS: { [string]: string } = { expo = "exponential", circ = "circular", sin = "sine" }
local DIR_ALIAS: { [string]: string } = { inandout = "inout", both = "inout" }

local function nameOf(v: any): string?
	local ty: string = typeof(v)
	if ty == "string" then
		return v
	elseif ty == "EnumItem" then
		return (v :: any).Name
	end
	return nil
end

-- "QuintOut" / "Quint Out" / "quint.inout" -> "quint", "out"
local function splitEase(s: string): (string?, string?)
	local a, b = string.match(s, "^%s*(%a+)[%s%._:%-]+(%a+)%s*$")
	if a then
		return string.lower(a), string.lower(b :: string)
	end
	local whole = string.match(s, "^%s*(%a+)%s*$")
	if not whole then
		return nil, nil
	end
	local w = string.lower(whole)
	if EASE[w] or STYLE_ALIAS[w] then
		return w, nil
	end
	for _, suffix in { "inout", "out", "in" } do
		if #w > #suffix and string.sub(w, -#suffix) == suffix then
			local stem = string.sub(w, 1, #w - #suffix)
			if EASE[stem] or STYLE_ALIAS[stem] then
				return stem, suffix
			end
		end
	end
	return w, nil
end

local STYLE_NAMES: { [string]: string } = {}
for _, name in FxMath.EASE_STYLES do
	STYLE_NAMES[string.lower(name)] = name
end
local DIRECTION_NAMES: { [string]: string } = { ["in"] = "In", out = "Out", inout = "InOut" }

-- Canonical names for an easing spec, as Enum.EasingStyle / Enum.EasingDirection item names ("Quint", "Out").
-- ease may be "Quint", "Quint Out", "SineInOut", Enum.EasingStyle.Quint, or {style, direction}. On a problem the
-- defaults (defaultStyle / defaultDirection, else Sine InOut) are returned with the problem.
function FxMath.easeNames(ease: any, direction: any?, defaultStyle: string?, defaultDirection: string?): (string, string, string?)
	local dStyle = STYLE_NAMES[string.lower(defaultStyle or "sine")] or "Sine"
	local dDir = DIRECTION_NAMES[string.lower(defaultDirection or "inout")] or "InOut"
	local style: string?, dir: string? = nil, nil
	local problem: string? = nil
	local raw: any = ease
	if type(ease) == "table" then
		raw = ease[1]
		dir = nameOf(ease[2])
		if ease[2] ~= nil and dir == nil then
			problem = "easing direction must be In, Out or InOut"
		end
	end
	if raw ~= nil then
		local n = nameOf(raw)
		if n == nil then
			problem = "expected an easing name like \"Quint Out\" or {\"Back\", \"In\"}"
		else
			local st, d = splitEase(n)
			if st == nil then
				problem = "expected an easing name like \"Quint Out\", got \"" .. n .. "\""
			else
				style = st
				if d and dir == nil then
					dir = d
				end
			end
		end
	end
	if dir == nil then
		dir = nameOf(direction)
	end
	local styleName = dStyle
	if style then
		local key = STYLE_ALIAS[style] or style
		if STYLE_NAMES[key] then
			styleName = STYLE_NAMES[key]
		else
			local guess = FxMath.closest(style, FxMath.EASE_STYLES)
			problem = problem or ("unknown easing style \"" .. style .. "\"" .. (if guess then " (did you mean " .. guess .. "?)" else ""))
		end
	end
	local dirName = dDir
	if dir then
		local key = string.lower(dir)
		key = DIR_ALIAS[key] or key
		if DIRECTION_NAMES[key] then
			dirName = DIRECTION_NAMES[key]
		else
			problem = problem or ("unknown easing direction \"" .. dir .. "\" (In, Out or InOut)")
		end
	end
	return styleName, dirName, problem
end

-- Resolves an easing spec once (hot paths call the returned function); see easeNames for the forms accepted.
function FxMath.easeFn(ease: any, direction: any?, defaultStyle: string?, defaultDirection: string?): ((number) -> number, string?)
	local style, dir, problem = FxMath.easeNames(ease, direction, defaultStyle, defaultDirection)
	local key = if dir == "InOut" then "inout" else string.lower(dir)
	return EASE[string.lower(style)][key], problem
end

function FxMath.ease(t: number, ease: any?, direction: any?): number
	local fn = FxMath.easeFn(ease, direction)
	return fn(t)
end

-- n keypoints sampling an eased move from a to b (e.g. a ring particle's size growing with Quint Out).
function FxMath.easeKeypoints(a: number, b: number, ease: any?, n: number?): { Keypoint }
	local fn = FxMath.easeFn(ease, nil, "quint", "out")
	local count = math.clamp(math.floor(n or 8), 2, 20)
	local out: { Keypoint } = {}
	for i = 1, count do
		local t = (i - 1) / (count - 1)
		out[i] = { t = t, v = a + (b - a) * fn(t), e = 0 }
	end
	return out
end

------------------------------------------------------------------------------------------------ springs
-- Exact solution of x'' = -speed^2 (x - target) - 2 damping speed x' over dt, as coefficients:
-- x1 - target = a (x0 - target) + b v0;  v1 = c (x0 - target) + d v0. Stable for any dt, no substeps.
function FxMath.springCoefficients(speed: number, damping: number, dt: number): (number, number, number, number)
	local w = if isNum(speed) and speed > 0 then speed else 0
	local z = if isNum(damping) and damping > 0 then damping else 0
	if not (dt > 0) then
		return 1, 0, 0, 1
	end
	if w < 1e-6 then
		return 1, dt, 0, 1
	end
	if math.abs(z - 1) < 1e-4 then
		local e = math.exp(-w * dt)
		return e * (1 + w * dt), e * dt, -e * w * w * dt, e * (1 - w * dt)
	elseif z < 1 then
		local wd = w * math.sqrt(1 - z * z)
		local e = math.exp(-z * w * dt)
		local c, s = math.cos(wd * dt), math.sin(wd * dt)
		local k = z * w / wd
		return e * (c + k * s), e * s / wd, -e * (w * w / wd) * s, e * (c - k * s)
	end
	local r = w * math.sqrt(z * z - 1)
	local r1, r2 = -z * w + r, -z * w - r
	local e1, e2 = math.exp(r1 * dt), math.exp(r2 * dt)
	local inv = 1 / (r1 - r2)
	return (r1 * e2 - r2 * e1) * inv, (e1 - e2) * inv, r1 * r2 * (e2 - e1) * inv, (r1 * e1 - r2 * e2) * inv
end

-- One step of a damped spring for numbers or vectors. Returns the new position and velocity.
function FxMath.springStep(x: any, v: any, target: any, speed: number, damping: number, dt: number): (any, any)
	local a, b, c, d = FxMath.springCoefficients(speed, damping, dt)
	local y = x - target
	return target + y * a + v * b, y * c + v * d
end

-- Peak displacement per unit of initial velocity for a spring starting at rest on its target, and when it happens.
function FxMath.springPeak(speed: number, damping: number): (number, number)
	local w = if isNum(speed) and speed > 1e-3 then speed else 1e-3
	local z = if isNum(damping) and damping > 0 then damping else 0
	if math.abs(z - 1) < 1e-4 then
		return 1 / (w * math.exp(1)), 1 / w
	elseif z < 1 then
		local wd = w * math.sqrt(1 - z * z)
		local t = math.atan2(wd, z * w) / wd
		return math.exp(-z * w * t) * math.sin(wd * t) / wd, t
	end
	local r = w * math.sqrt(z * z - 1)
	local r1, r2 = -z * w + r, -z * w - r
	local t = math.log(r2 / r1) / (r1 - r2)
	return (math.exp(r1 * t) - math.exp(r2 * t)) / (r1 - r2), t
end

-- The initial velocity that makes a spring at rest peak at `peak` (so a punch's strength reads in studs).
function FxMath.impulseForPeak(peak: number, speed: number, damping: number): number
	local p = FxMath.springPeak(speed, damping)
	return peak / p
end

------------------------------------------------------------------------------------------------ envelopes
-- 0..1..0 shape of an FOV kick: a quick rise over `attack` seconds, then a smooth fall to 0 at `seconds`.
function FxMath.kickEnvelope(t: number, seconds: number, attack: number?): number
	if not (seconds > 0) or not (t >= 0) or t >= seconds then
		return 0
	end
	local a = clamp(attack or math.min(0.08, seconds * 0.3), 0, seconds)
	if t < a then
		local u = t / a
		return 1 - (1 - u) * (1 - u)
	end
	local u = (t - a) / (seconds - a)
	return 0.5 * (1 + math.cos(u * PI))
end

-- Time scale of a slow-motion beat at time t: eases from 1 to `scale` over rampIn, holds, and returns to 1 over
-- rampOut, ending at `seconds`. Ramps longer than the beat are shortened proportionally.
function FxMath.slowmoScale(t: number, scale: number, seconds: number, rampIn: number?, rampOut: number?): number
	if not (seconds > 0) or not (t >= 0) or t >= seconds then
		return 1
	end
	local s = clamp(scale, 0, 1)
	local rin = math.max(rampIn or 0, 0)
	local rout = math.max(rampOut or 0, 0)
	if rin + rout > seconds then
		local k = seconds / (rin + rout)
		rin *= k
		rout *= k
	end
	if t < rin then
		local u = t / rin
		return 1 + (s - 1) * (1 - (1 - u) * (1 - u))
	elseif rout > 0 and t > seconds - rout then
		local u = (t - (seconds - rout)) / rout
		return s + (1 - s) * u * u * (3 - 2 * u)
	end
	return s
end

-- Linear progress (0..1) of a camera move and its phase: "move" while moving, "hold" after, "done" past both.
function FxMath.shotProgress(t: number, move: number, hold: number): (number, string)
	local u = if move > 0 then clamp(t / move, 0, 1) else 1
	if t < move then
		return u, "move"
	elseif t < move + math.max(hold, 0) then
		return 1, "hold"
	end
	return 1, "done"
end

-- Fraction of the screen height each letterbox bar covers to show a `ratio` (e.g. 2.39) frame.
function FxMath.letterbox(width: number, height: number, ratio: number, maxFraction: number?): number
	if not (width > 0) or not (height > 0) or not (ratio > 0) then
		return 0
	end
	local content = width / ratio
	if content >= height then
		return 0
	end
	return math.min((height - content) / (2 * height), maxFraction or 0.25)
end

-- Camera collision: pull in to `allowed` at once (never sit inside geometry), ease back out at returnRate (1/s).
function FxMath.collisionDistance(current: number, allowed: number, returnRate: number, dt: number): number
	if allowed <= current then
		return allowed
	end
	return current + (allowed - current) * FxMath.alpha(returnRate, dt)
end

-- Yaw and pitch (radians) of a unit look vector, matching CFrame.fromEulerAnglesYXZ(pitch, yaw, 0).
function FxMath.yawPitch(x: number, y: number, z: number): (number, number)
	return math.atan2(-x, -z), math.asin(clamp(y, -1, 1))
end

-- Offset of a point on an orbit: angle 0 is +Z (behind a part facing -Z), 90 is +X (its right side).
function FxMath.orbitOffset(radius: number, height: number, degrees: number): (number, number, number)
	local a = math.rad(degrees)
	return math.sin(a) * radius, height, math.cos(a) * radius
end

-- Smooth handheld-camera noise in about [-1, 1] per axis; frequency in cycles per second.
function FxMath.handheld(t: number, frequency: number, seed: number?): (number, number, number)
	local f = t * frequency
	local s = (seed or 0) + 0.5
	local x = math.noise(f, s * 1.37, 0.31) * 2
	local y = math.noise(s * 2.11, f, 1.77) * 2
	local z = math.noise(3.13, s * 0.71, f) * 2
	return clamp(x, -1, 1), clamp(y, -1, 1), clamp(z, -1, 1)
end

------------------------------------------------------------------------------------------------ paths
-- Uniform Catmull-Rom point between p1 and p2.
function FxMath.catmullRom(p0: any, p1: any, p2: any, p3: any, t: number): any
	local t2 = t * t
	local t3 = t2 * t
	return (p1 * 2 + (p2 - p0) * t + (p0 * 2 - p1 * 5 + p2 * 4 - p3) * t2 + (p1 * 3 - p0 - p2 * 3 + p3) * t3) * 0.5
end

-- Point at parameter s in [0, #points - 1] of the curve through every point (ends extended by reflection).
function FxMath.pathPoint(points: { any }, s: number): any
	local n = #points
	if n == 1 then
		return points[1]
	elseif n == 2 then
		return points[1] + (points[2] - points[1]) * clamp(s, 0, 1)
	end
	s = clamp(s, 0, n - 1)
	local i = math.min(math.floor(s), n - 2)
	local t = s - i
	local p1, p2 = points[i + 1], points[i + 2]
	local p0 = if i >= 1 then points[i] else p1 * 2 - p2
	local p3 = if i + 3 <= n then points[i + 3] else p2 * 2 - p1
	return FxMath.catmullRom(p0, p1, p2, p3, t)
end

-- A path through points with an arc-length table, so FxMath.pathAt moves at an even speed along it.
function FxMath.path(points: { any }, samples: number?): Path
	local n = #points
	local per = math.clamp(math.floor(samples or 16), 1, 256)
	local cum, params = { 0 }, { 0 }
	local total = 0
	if n >= 2 then
		local prev = points[1]
		local steps = (n - 1) * per
		for j = 1, steps do
			local s = j / per
			local p = FxMath.pathPoint(points, s)
			total += distance(prev, p)
			cum[j + 1] = total
			params[j + 1] = s
			prev = p
		end
	end
	return { points = points, cum = cum, params = params, length = total }
end

-- Point at fraction u (0..1) of the path's length.
function FxMath.pathAt(path: Path, u: number): any
	local pts = path.points
	if #pts < 2 or path.length <= 0 then
		return pts[1]
	end
	local target = clamp(u, 0, 1) * path.length
	local cum = path.cum
	local lo, hi = 1, #cum
	while hi - lo > 1 do
		local mid = (lo + hi) // 2
		if cum[mid] <= target then
			lo = mid
		else
			hi = mid
		end
	end
	local span = cum[hi] - cum[lo]
	local f = if span > 0 then (target - cum[lo]) / span else 0
	local s = path.params[lo] + (path.params[hi] - path.params[lo]) * f
	return FxMath.pathPoint(pts, s)
end

------------------------------------------------------------------------------------------------ keypoints
-- Turns a keypoint spec into sorted {t, v, e} keypoints spanning 0..1 (at most 20, like NumberSequence):
--   5                         constant
--   {0.2, 1, 0}               values spread evenly over the lifetime
--   {{0, 1}, {0.3, 2, 0.5}}   {time, value, envelope?}; {time =, value =, envelope =} works too
-- isValue says what a single value is (a number, a colour...). Returns nil and problems if nothing is usable.
function FxMath.keypoints(spec: any, isValue: (any) -> boolean): ({ Keypoint }?, { string })
	local problems: { string } = {}
	if isValue(spec) then
		return { { t = 0, v = spec, e = 0 }, { t = 1, v = spec, e = 0 } }, problems
	end
	if type(spec) ~= "table" then
		table.insert(problems, "expected a value, a list of values, or {time, value} keypoints")
		return nil, problems
	end
	local n = #spec
	if n == 0 then
		table.insert(problems, "empty keypoint list")
		return nil, problems
	end
	local list: { Keypoint } = {}
	local allValues = true
	for i = 1, n do
		if not isValue(spec[i]) then
			allValues = false
			break
		end
	end
	if allValues then
		for i = 1, n do
			list[i] = { t = if n == 1 then 0 else (i - 1) / (n - 1), v = spec[i], e = 0 }
		end
		if n == 1 then
			list[2] = { t = 1, v = spec[1], e = 0 }
		end
	else
		local order: { number } = {}
		local lastT = -HUGE
		local unsorted = false
		for i = 1, n do
			local k = spec[i]
			local t, v, e = nil, nil, nil
			if type(k) == "table" then
				if k[1] ~= nil or k[2] ~= nil then
					t, v, e = k[1], k[2], k[3]
				else
					t, v, e = k.t or k.time, k.v or k.value, k.e or k.envelope
				end
			end
			if not isNum(t) or not isValue(v) then
				table.insert(problems, "keypoint " .. i .. ": expected {time, value} (time 0..1)")
			else
				local tt = t :: number
				if tt < 0 or tt > 1 then
					table.insert(problems, "keypoint " .. i .. ": time " .. tt .. " is outside 0..1")
					tt = clamp(tt, 0, 1)
				end
				if tt < lastT then
					unsorted = true
				end
				lastT = tt
				local env = 0
				if e ~= nil then
					if not isNum(e) then
						table.insert(problems, "keypoint " .. i .. ": envelope must be a number")
					else
						env = math.max(e :: number, 0)
					end
				end
				table.insert(list, { t = tt, v = v, e = env })
				table.insert(order, #list)
			end
		end
		if #list == 0 then
			return nil, problems
		end
		if unsorted then
			table.insert(problems, "keypoint times must go up from 0 to 1 (sorted them)")
			local rank: { [Keypoint]: number } = {}
			for i, k in list do
				rank[k] = order[i]
			end
			table.sort(list, function(a: Keypoint, b: Keypoint): boolean
				if a.t ~= b.t then
					return a.t < b.t
				end
				return rank[a] < rank[b]
			end)
		end
		if list[1].t > 0 then
			table.insert(list, 1, { t = 0, v = list[1].v, e = list[1].e })
		end
		if list[#list].t < 1 then
			table.insert(list, { t = 1, v = list[#list].v, e = list[#list].e })
		end
	end
	if #list > 20 then
		table.insert(problems, #list .. " keypoints; sequences hold at most 20 (resampled)")
		local out: { Keypoint } = {}
		for k = 1, 20 do
			out[k] = list[1 + math.floor((k - 1) * (#list - 1) / 19 + 0.5)]
		end
		list = out
	end
	return list, problems
end

-- Clamps number keypoints into [lo, hi] (envelopes too, so value +- envelope stays inside). Returns problems.
function FxMath.clampKeypoints(list: { Keypoint }, lo: number, hi: number): { string }
	local problems: { string } = {}
	local reported = false
	for _, k in list do
		local v = k.v :: number
		if v < lo or v > hi then
			if not reported then
				table.insert(problems, "value " .. v .. " is outside " .. lo .. ".." .. hi)
				reported = true
			end
			v = clamp(v, lo, hi)
			k.v = v
		end
		k.e = math.max(0, math.min(k.e, v - lo, hi - v))
	end
	return problems
end

------------------------------------------------------------------------------------------------ colours, content
-- "#RRGGBB" / "RRGGBB" / "#RGB" -> r, g, b in 0..1 (nil if not a hex colour).
function FxMath.hex(s: any): (number?, number?, number?)
	if type(s) ~= "string" then
		return nil, nil, nil
	end
	local h = string.match(s, "^%s*#?(%x%x%x%x%x%x)%s*$")
	if h then
		return tonumber(string.sub(h, 1, 2), 16) :: number / 255, tonumber(string.sub(h, 3, 4), 16) :: number / 255,
			tonumber(string.sub(h, 5, 6), 16) :: number / 255
	end
	local short = string.match(s, "^%s*#(%x%x%x)%s*$")
	if short then
		local r = tonumber(string.sub(short, 1, 1), 16) :: number
		local g = tonumber(string.sub(short, 2, 2), 16) :: number
		local b = tonumber(string.sub(short, 3, 3), 16) :: number
		return r * 17 / 255, g * 17 / 255, b * 17 / 255
	end
	return nil, nil, nil
end

-- "Tokens.color.primary" -> "primary"
function FxMath.tokenName(s: any): string?
	if type(s) ~= "string" then
		return nil
	end
	return string.match(s, "^%s*Tokens%.color%.([%w_]+)%s*$")
end

function FxMath.isColor(v: any): boolean
	local ty: string = typeof(v)
	if ty == "Color3" then
		return true
	end
	return FxMath.hex(v) ~= nil or FxMath.tokenName(v) ~= nil
end

function FxMath.isContentId(v: any): boolean
	if type(v) ~= "string" then
		return false
	end
	return string.match(v, "^rbxassetid://%d+$") ~= nil or string.match(v, "^rbxasset://%S+$") ~= nil
		or string.match(v, "^rbxthumb://%S+$") ~= nil or string.match(v, "^https?://%S+$") ~= nil
end

-- A texture is a content id, a positive asset id number, or the name of a kit texture / generated image.
function FxMath.isTexture(v: any): boolean
	if isNum(v) then
		return v > 0 and v % 1 == 0
	end
	return FxMath.isContentId(v) or (type(v) == "string" and string.match(v, "^[%a_][%w_%-%.]*$") ~= nil)
end

------------------------------------------------------------------------------------------------ budgets
-- A first-in-first-out budget: caps per resource ({effects = 12, particles = 600, lights = 3}); every entry counts
-- one "effects". add() returns the ids evicted (oldest first) to get back under every cap; the new entry stays even
-- if it alone is over.
local Budget = {}
Budget.__index = Budget

function FxMath.budget(caps: { [string]: number }): any
	return setmetatable({ caps = caps, totals = {}, costs = {}, order = {}, head = 1 }, Budget)
end

function Budget.over(self: any): boolean
	for k, cap in self.caps do
		if (self.totals[k] or 0) > cap then
			return true
		end
	end
	return false
end

function Budget.remove(self: any, id: any): boolean
	local cost = self.costs[id]
	if not cost then
		return false
	end
	self.costs[id] = nil
	for k, v in cost do
		self.totals[k] = (self.totals[k] or 0) - v
	end
	return true
end

function Budget.add(self: any, id: any, cost: { [string]: number }?): { any }
	if self.costs[id] then
		-- re-added: it becomes the newest entry
		self:remove(id)
		for i = self.head, #self.order do
			if self.order[i] == id then
				table.remove(self.order, i)
				break
			end
		end
	end
	local c: { [string]: number } = { effects = 1 }
	if cost then
		for k, v in cost do
			if k ~= "effects" and isNum(v) then
				c[k] = v
			end
		end
	end
	self.costs[id] = c
	for k, v in c do
		self.totals[k] = (self.totals[k] or 0) + v
	end
	table.insert(self.order, id)
	local evicted = {}
	while self:over() do
		local victim = nil
		-- the newest entry (last in order) is never a candidate; stale copies of a re-added id are skipped
		while self.head < #self.order do
			local candidate = self.order[self.head]
			self.head += 1
			if candidate ~= id and self.costs[candidate] then
				victim = candidate
				break
			end
		end
		if victim == nil then
			break
		end
		self:remove(victim)
		table.insert(evicted, victim)
	end
	if self.head > 32 and self.head > #self.order // 2 then
		local keep = {}
		for i = self.head, #self.order do
			local x = self.order[i]
			if self.costs[x] then
				table.insert(keep, x)
			end
		end
		self.order = keep
		self.head = 1
	end
	return evicted
end

function Budget.total(self: any, resource: string): number
	return self.totals[resource] or 0
end

------------------------------------------------------------------------------------------------ did-you-mean
-- Optimal-string-alignment distance (edits, with a swap of neighbours counting as one).
function FxMath.levenshtein(a: string, b: string): number
	local la, lb = #a, #b
	if la == 0 then
		return lb
	elseif lb == 0 then
		return la
	end
	local prev2 = table.create(lb + 1, 0)
	local prev = table.create(lb + 1, 0)
	local cur = table.create(lb + 1, 0)
	for j = 0, lb do
		prev[j + 1] = j
	end
	for i = 1, la do
		cur[1] = i
		local ca = string.byte(a, i)
		for j = 1, lb do
			local cb = string.byte(b, j)
			local cost = if ca == cb then 0 else 1
			local best = math.min(prev[j + 1] + 1, cur[j] + 1, prev[j] + cost)
			if i > 1 and j > 1 and ca == string.byte(b, j - 1) and string.byte(a, i - 1) == cb then
				best = math.min(best, prev2[j - 1] + 1)
			end
			cur[j + 1] = best
		end
		prev2, prev, cur = prev, cur, prev2
	end
	return prev[lb + 1]
end

-- The candidate closest to word (case-insensitive), or nil if nothing is close.
function FxMath.closest(word: string, candidates: { string }, maxDistance: number?): string?
	local lw = string.lower(word)
	local best: string?, bestD = nil, HUGE
	for _, c in candidates do
		local d = FxMath.levenshtein(lw, string.lower(c))
		if d < bestD then
			best, bestD = c, d
		end
	end
	local limit = maxDistance or math.max(1, #word // 3)
	if best and bestD <= limit then
		return best
	end
	if #lw >= 4 then
		for _, c in candidates do
			local lc = string.lower(c)
			if #lc >= 4 and (string.find(lw, lc, 1, true) or string.find(lc, lw, 1, true)) then
				return c
			end
		end
	end
	return nil
end

------------------------------------------------------------------------------------------------ spec schema
-- The VFX effect-spec schema. harness/tools/fxspec.py holds the same tables (a test keeps them identical).
FxMath.KINDS = { "particles", "beam", "light", "flash", "ring", "decal" }
FxMath.EFFECT_KEYS = { "layers", "family", "budget" }
FxMath.COMMON_KEYS = { "kind", "delay", "offset" }
FxMath.LAYER_KEYS = ({
	particles = { "count", "rate", "duration", "lifetime", "speed", "spread", "size", "transparency", "color",
		"lightEmission", "lightInfluence", "brightness", "drag", "acceleration", "rotation", "rotSpeed",
		"orientation", "squash", "zoffset", "flipbook", "texture", "direction", "shape", "lockedToPart", "timeScale" },
	beam = { "to", "from", "width", "color", "transparency", "texture", "textureSpeed", "textureLength", "textureMode",
		"lightEmission", "lightInfluence", "brightness", "curve", "segments", "faceCamera", "zoffset", "duration",
		"fadeOut" },
	light = { "color", "brightness", "range", "duration", "attack", "shadows", "spot" },
	flash = { "shape", "mesh", "meshTexture", "material", "color", "size", "transparency", "duration", "ease", "spin" },
	ring = { "size", "thickness", "color", "transparency", "duration", "texture", "lightEmission", "brightness", "flat",
		"ease", "material" },
	decal = { "texture", "size", "color", "transparency", "duration", "fade", "grow", "rotation" },
} :: any) :: { [string]: { string } }
FxMath.NESTED_KEYS = ({
	flipbook = { "layout", "mode", "fps", "random" },
	shape = { "kind", "size", "style", "inOut", "partial" },
	spot = { "angle", "face" },
	budget = { "particles", "lights", "effects" },
	trail = { "width", "offset", "axis", "lifetime", "color", "transparency", "widthScale", "texture", "textureMode",
		"textureLength", "lightEmission", "lightInfluence", "brightness", "minLength", "maxLength", "faceCamera",
		"enabled" },
} :: any) :: { [string]: { string } }
-- Other spellings a builder is likely to write (Roblox property names, synonyms) -> the canonical key.
FxMath.ALIASES = ({
	colour = "color", spreadangle = "spread", emissiondirection = "direction", emit = "count", amount = "count",
	burst = "count", lifespan = "lifetime", velocity = "speed", spin = "rotSpeed", rotationspeed = "rotSpeed",
	radius = "range", locked = "lockedToPart",
} :: any) :: { [string]: string }
local DIRS = { "up", "down", "forward", "back", "left", "right" }
local MATERIALS = { "neon", "forcefield", "glass", "smoothplastic", "plastic" }
local TEXTURE_MODES = { "stretch", "wrap", "static" }
-- Enum values also accepted under their Roblox names.
FxMath.ENUM_ALIASES = ({
	facingcamera = "facing", facingcameraworldup = "facingUp", velocityparallel = "parallel",
	velocityperpendicular = "perpendicular", top = "up", bottom = "down", front = "forward", grid2x2 = "2x2",
	grid4x4 = "4x4", grid8x8 = "8x8", ["2"] = "2x2", ["4"] = "4x4", ["8"] = "8x8", inandout = "both", ball = "sphere",
	brick = "block", cube = "block",
} :: any) :: { [string]: string }
-- {type, lo, hi} or {type, choices} or {"table", nestedName}. Types: num, int, bool, enum, range (number or
-- {min, max}), pair (number or {a, b}), vec3, numvec (number or Vector3), sizepair (numvec or {from, to}), target
-- (Vector3 or an Instance), numseq, colseq, color, texture, asset, ease, table.
FxMath.TYPES = ({
	common = { kind = { "enum", FxMath.KINDS }, delay = { "num", 0, 30 }, offset = { "vec3" } },
	particles = {
		count = { "int", 0, 1000 }, rate = { "num", 0, 1000 }, duration = { "num", 0, 600 },
		lifetime = { "range", 0, 20 }, speed = { "range", -1000, 1000 }, spread = { "pair", 0, 360 },
		size = { "numseq", 0, 1000 }, transparency = { "numseq", 0, 1 }, color = { "colseq" },
		lightEmission = { "num", 0, 1 }, lightInfluence = { "num", 0, 1 }, brightness = { "num", 0, 1000 },
		drag = { "num", -100, 100 }, acceleration = { "vec3" }, rotation = { "range", -3600, 3600 },
		rotSpeed = { "range", -36000, 36000 },
		orientation = { "enum", { "facing", "facingUp", "parallel", "perpendicular" } },
		squash = { "numseq", -3, 3 }, zoffset = { "num", -1000, 1000 }, flipbook = { "table", "flipbook" },
		texture = { "texture" }, direction = { "enum", DIRS }, shape = { "table", "shape" }, lockedToPart = { "bool" },
		timeScale = { "num", 0, 1 },
	},
	beam = {
		to = { "target" }, from = { "target" }, width = { "pair", 0, 1000 }, color = { "colseq" },
		transparency = { "numseq", 0, 1 }, texture = { "texture" }, textureSpeed = { "num", -1000, 1000 },
		textureLength = { "num", 0.001, 1000 }, textureMode = { "enum", TEXTURE_MODES },
		lightEmission = { "num", 0, 1 }, lightInfluence = { "num", 0, 1 }, brightness = { "num", 0, 1000 },
		curve = { "pair", -1000, 1000 }, segments = { "int", 1, 1000 }, faceCamera = { "bool" },
		zoffset = { "num", -1000, 1000 }, duration = { "num", 0, 600 }, fadeOut = { "num", 0, 10 },
	},
	light = {
		color = { "color" }, brightness = { "num", 0, 1000 }, range = { "num", 0, 60 }, duration = { "num", 0, 600 },
		attack = { "num", 0, 10 }, shadows = { "bool" }, spot = { "table", "spot" },
	},
	flash = {
		shape = { "enum", { "sphere", "block", "mesh" } }, mesh = { "asset" }, meshTexture = { "texture" },
		material = { "enum", MATERIALS }, color = { "color" }, size = { "sizepair", 0, 1000 },
		transparency = { "pair", 0, 1 }, duration = { "num", 0, 10 }, ease = { "ease" },
		spin = { "num", -36000, 36000 },
	},
	ring = {
		size = { "pair", 0, 1000 }, thickness = { "num", 0, 100 }, color = { "colseq" },
		transparency = { "numseq", 0, 1 }, duration = { "num", 0, 10 }, texture = { "texture" },
		lightEmission = { "num", 0, 1 }, brightness = { "num", 0, 1000 }, flat = { "bool" }, ease = { "ease" },
		material = { "enum", MATERIALS },
	},
	decal = {
		texture = { "texture" }, size = { "pair", 0, 1000 }, color = { "color" }, transparency = { "pair", 0, 1 },
		duration = { "num", 0, 600 }, fade = { "num", 0, 60 }, grow = { "num", 0, 10 },
		rotation = { "range", -3600, 3600 },
	},
	flipbook = {
		layout = { "enum", { "2x2", "4x4", "8x8" } }, mode = { "enum", { "loop", "oneshot", "pingpong", "random" } },
		fps = { "range", 0, 240 }, random = { "bool" },
	},
	shape = {
		kind = { "enum", { "sphere", "box", "disc", "cylinder" } }, size = { "numvec", 0, 1000 },
		style = { "enum", { "volume", "surface" } }, inOut = { "enum", { "outward", "inward", "both" } },
		partial = { "num", 0, 1 },
	},
	spot = { angle = { "num", 0, 180 }, face = { "enum", DIRS } },
	budget = { particles = { "int", 0, 100000 }, lights = { "int", 0, 64 }, effects = { "int", 1, 1000 } },
	trail = {
		width = { "num", 0, 1000 }, offset = { "vec3" }, axis = { "enum", { "up", "right", "forward" } },
		lifetime = { "num", 0, 20 }, color = { "colseq" }, transparency = { "numseq", 0, 1 },
		widthScale = { "numseq", 0, 1000 }, texture = { "texture" }, textureMode = { "enum", TEXTURE_MODES },
		textureLength = { "num", 0.001, 1000 }, lightEmission = { "num", 0, 1 }, lightInfluence = { "num", 0, 1 },
		brightness = { "num", 0, 1000 }, minLength = { "num", 0, 1000 }, maxLength = { "num", 0, 100000 },
		faceCamera = { "bool" }, enabled = { "bool" },
	},
} :: any) :: { [string]: { [string]: { any } } }

-- Camera option names (CameraRig warns about unknown ones with a suggestion).
FxMath.FOLLOW_KEYS = { "preset", "subject", "distance", "height", "offset", "fov", "yaw", "pitch", "pitchMin",
	"pitchMax", "orbit", "sensitivity", "invertY", "speed", "damping", "verticalSpeed", "rotSpeed", "zoomSpeed",
	"lookAhead", "lookAheadSpeed", "lookAheadRate", "collision", "collisionRadius", "minDistance", "returnSpeed",
	"speedFov", "autoAlign", "shoulder", "shoulderKey", "zoom", "ignore", "fadeSubject", "blend", "input" }
FxMath.SHOT_KEYS = { "from", "to", "path", "lookAt", "lookOffset", "orbit", "relativeTo", "track", "duration", "hold",
	"ease", "fov", "roll", "handheld", "blendIn", "blendOut", "letterbox", "slowmo", "timeScaled", "onStart", "onDone",
	"skipInput", "lockControls", "name" }
FxMath.SEQUENCE_KEYS = { "letterbox", "skipInput", "lockControls", "onDone", "blendOut", "name" }
-- Options of VFX.effect / VFX.play, VFX.hitstop and VFX.vignette.
FxMath.EFFECT_OPTS = { "scale", "intensity", "normal", "direction", "follow", "timeScaled", "onDone" }
FxMath.HITSTOP_KEYS = { "character", "animators", "tracks", "emitters", "camera", "timeScale", "speed" }
FxMath.VIGNETTE_KEYS = { "strength", "thickness", "fadeIn", "fadeOut", "texture" }
FxMath.CAMERA_NESTED_KEYS = {
	orbit = { "target", "radius", "height", "from", "to" },
	handheld = { "amount", "rotation", "frequency" },
	letterbox = { "ratio", "color", "seconds", "displayOrder", "maxFraction" },
	speedFov = { "from", "to", "fov", "pull" },
	zoom = { "min", "max", "step" },
	sensitivity = { "mouse", "touch", "gamepad" },
	autoAlign = { "delay", "speed" },
	slowmo = { "scale", "seconds", "rampIn", "rampOut" },
}

------------------------------------------------------------------------------------------------ validation
local lookupCache: { [any]: { [string]: string } } = setmetatable({}, { __mode = "k" }) :: any

local function lookupFor(keys: { string }): { [string]: string }
	local m = lookupCache[keys]
	if not m then
		m = {}
		for _, k in keys do
			m[string.lower(k)] = k
		end
		lookupCache[keys] = m
	end
	return m
end

export type Unknown = { key: string, suggestion: string? }

-- A copy of tbl with canonical keys (case-insensitive, FxMath.ALIASES), plus the keys it does not know, each with
-- a suggestion. An exact canonical key wins over an alias of it.
function FxMath.normalizeKeys(tbl: { [any]: any }, keys: { string }): ({ [string]: any }, { Unknown })
	local lookup = lookupFor(keys)
	local out: { [string]: any } = {}
	local unknown: { Unknown } = {}
	for k, v in tbl do
		if type(k) == "string" then
			local lower = string.lower(k)
			local canon = lookup[lower]
			if not canon then
				local alias = FxMath.ALIASES[lower]
				if alias and lookup[string.lower(alias)] then
					canon = alias
				end
			end
			if canon then
				if k == canon or out[canon] == nil then
					out[canon] = v
				end
			else
				table.insert(unknown, { key = k, suggestion = FxMath.closest(k, keys) })
			end
		else
			table.insert(unknown, { key = "[" .. tostring(k) .. "]", suggestion = nil })
		end
	end
	table.sort(unknown, function(a: Unknown, b: Unknown): boolean
		return a.key < b.key
	end)
	return out, unknown
end

-- The canonical choice for an enum value (string, number or EnumItem), or nil.
function FxMath.enumValue(v: any, choices: { string }): string?
	local name: string? = nil
	local ty: string = typeof(v)
	if ty == "string" then
		name = v
	elseif ty == "EnumItem" then
		name = (v :: any).Name
	elseif isNum(v) then
		name = tostring(v)
	end
	if not name then
		return nil
	end
	local lower = string.lower(name)
	lower = string.lower(FxMath.ENUM_ALIASES[lower] or lower)
	for _, c in choices do
		if string.lower(c) == lower then
			return c
		end
	end
	return nil
end

local function describe(v: any): string
	local t = typeof(v)
	if t == "string" then
		return "\"" .. string.sub(v, 1, 40) .. "\""
	elseif t == "number" or t == "boolean" or t == "nil" then
		return tostring(v)
	end
	return "a " .. t
end

local function fmtNum(x: number): string
	if x == math.floor(x) and math.abs(x) < 1e15 then
		return string.format("%d", x)
	end
	return tostring(x)
end

local function push(out: { string }, path: string, msg: string)
	table.insert(out, path .. ": " .. msg)
end

local function inRange(x: number, spec: { any }): boolean
	return x >= spec[2] and x <= spec[3]
end

local function rangeText(spec: { any }): string
	return fmtNum(spec[2]) .. ".." .. fmtNum(spec[3])
end

local checkValue: (spec: { any }, v: any, path: string, out: { string }) -> ()

local function checkTable(v: any, schemaName: string, path: string, out: { string })
	if type(v) ~= "table" then
		push(out, path, "expected a table, got " .. describe(v))
		return
	end
	local keys = FxMath.NESTED_KEYS[schemaName]
	local types = FxMath.TYPES[schemaName]
	local norm, unknown = FxMath.normalizeKeys(v, keys)
	for _, u in unknown do
		push(out, path .. "." .. u.key, "unknown key" .. (if u.suggestion then " (did you mean " .. u.suggestion .. "?)" else ""))
	end
	local names = {}
	for k in norm do
		table.insert(names, k)
	end
	table.sort(names)
	for _, k in names do
		checkValue(types[k], norm[k], path .. "." .. k, out)
	end
end

local function numOrVec(v: any, spec: { any }): boolean
	if isNum(v) then
		return inRange(v, spec)
	elseif isVec(v) then
		return inRange(v.X, spec) and inRange(v.Y, spec) and inRange(v.Z, spec)
	end
	return false
end

checkValue = function(spec: { any }, v: any, path: string, out: { string })
	local kind = spec[1]
	if kind == "num" then
		if not isNum(v) then
			push(out, path, "expected a number, got " .. describe(v))
		elseif not inRange(v, spec) then
			push(out, path, "expected " .. rangeText(spec) .. ", got " .. fmtNum(v))
		end
	elseif kind == "int" then
		if not isNum(v) or v % 1 ~= 0 then
			push(out, path, "expected a whole number, got " .. describe(v))
		elseif not inRange(v, spec) then
			push(out, path, "expected " .. rangeText(spec) .. ", got " .. fmtNum(v))
		end
	elseif kind == "bool" then
		if type(v) ~= "boolean" then
			push(out, path, "expected true or false, got " .. describe(v))
		end
	elseif kind == "enum" then
		if FxMath.enumValue(v, spec[2]) == nil then
			local name = if type(v) == "string" then v else nil
			local guess = name and FxMath.closest(name, spec[2])
			push(out, path, "expected one of " .. table.concat(spec[2], ", ") .. ", got " .. describe(v)
				.. (if guess then " (did you mean " .. guess .. "?)" else ""))
		end
	elseif kind == "range" or kind == "pair" then
		local a, b = nil, nil
		local ty: string = typeof(v)
		if ty == "NumberRange" then
			a, b = (v :: any).Min, (v :: any).Max
		elseif isNum(v) then
			a, b = v, v
		elseif type(v) == "table" and #v == 2 and isNum(v[1]) and isNum(v[2]) then
			a, b = v[1], v[2]
		end
		if a == nil or b == nil then
			push(out, path, "expected a number or {" .. (if kind == "range" then "min, max" else "a, b") .. "}, got " .. describe(v))
		elseif not inRange(a, spec) or not inRange(b, spec) then
			push(out, path, "expected values in " .. rangeText(spec))
		elseif kind == "range" and a > b then
			push(out, path, "min is greater than max")
		end
	elseif kind == "vec3" then
		if not isVec(v) then
			push(out, path, "expected a Vector3, got " .. describe(v))
		end
	elseif kind == "numvec" then
		if not numOrVec(v, spec) then
			push(out, path, "expected a number or a Vector3 in " .. rangeText(spec) .. ", got " .. describe(v))
		end
	elseif kind == "sizepair" then
		local ok = numOrVec(v, spec)
		if not ok and type(v) == "table" and #v == 2 then
			ok = numOrVec(v[1], spec) and numOrVec(v[2], spec)
		end
		if not ok then
			push(out, path, "expected a size (number or Vector3) or {from, to} in " .. rangeText(spec) .. ", got " .. describe(v))
		end
	elseif kind == "target" then
		local ty: string = typeof(v)
		if not isVec(v) and ty ~= "Instance" then
			push(out, path, "expected a Vector3 (offset in the effect's frame) or a part / attachment, got " .. describe(v))
		end
	elseif kind == "numseq" then
		local ty: string = typeof(v)
		if ty == "NumberSequence" then
			return
		end
		local list, problems = FxMath.keypoints(v, isNum)
		for _, p in problems do
			push(out, path, p)
		end
		if list then
			for _, k in list do
				if not inRange(k.v, spec) then
					push(out, path, "values must be in " .. rangeText(spec) .. ", got " .. fmtNum(k.v))
					break
				end
			end
		end
	elseif kind == "colseq" then
		local ty: string = typeof(v)
		if ty == "ColorSequence" then
			return
		end
		local _, problems = FxMath.keypoints(v, FxMath.isColor)
		for _, p in problems do
			push(out, path, p .. " (colours: Color3, \"#RRGGBB\" or \"Tokens.color.<name>\")")
		end
	elseif kind == "color" then
		if not FxMath.isColor(v) then
			push(out, path, "expected a Color3, \"#RRGGBB\" or \"Tokens.color.<name>\", got " .. describe(v))
		end
	elseif kind == "texture" then
		if not FxMath.isTexture(v) then
			push(out, path, "expected a content id (\"rbxassetid://123\") or a texture name, got " .. describe(v))
		end
	elseif kind == "asset" then
		if not (FxMath.isContentId(v) or (isNum(v) and v > 0 and v % 1 == 0)) then
			push(out, path, "expected a content id (\"rbxassetid://123\") or an asset id, got " .. describe(v))
		end
	elseif kind == "ease" then
		local _, problem = FxMath.easeFn(v)
		if problem then
			push(out, path, problem)
		end
	elseif kind == "table" then
		checkTable(v, spec[2], path, out)
	end
end

local ALL_LAYER_KEYS: { [string]: { string } } = {}
for kind, keys in FxMath.LAYER_KEYS do
	local all = table.clone(FxMath.COMMON_KEYS)
	for _, k in keys do
		table.insert(all, k)
	end
	ALL_LAYER_KEYS[kind] = all
end

-- Every key a layer of this kind may have (the common keys first).
function FxMath.layerKeys(kind: string): { string }?
	return ALL_LAYER_KEYS[kind]
end

local function findKey(tbl: { [any]: any }, name: string): any
	local v = tbl[name]
	if v ~= nil then
		return v
	end
	for k, x in tbl do
		if type(k) == "string" and string.lower(k) == name then
			return x
		end
	end
	return nil
end

FxMath.findKey = findKey

function FxMath.validateLayer(layer: any, path: string, out: { string })
	if type(layer) ~= "table" then
		push(out, path, "expected a layer table, got " .. describe(layer))
		return
	end
	local rawKind = findKey(layer, "kind")
	if rawKind == nil then
		push(out, path .. ".kind", "missing (one of " .. table.concat(FxMath.KINDS, ", ") .. ")")
		return
	end
	local kind = FxMath.enumValue(rawKind, FxMath.KINDS)
	if not kind then
		local guess = if type(rawKind) == "string" then FxMath.closest(rawKind, FxMath.KINDS) else nil
		push(out, path .. ".kind", "unknown kind " .. describe(rawKind) .. " (one of " .. table.concat(FxMath.KINDS, ", ")
			.. ")" .. (if guess then " (did you mean " .. guess .. "?)" else ""))
		return
	end
	local norm, unknown = FxMath.normalizeKeys(layer, ALL_LAYER_KEYS[kind])
	for _, u in unknown do
		push(out, path .. "." .. u.key, "unknown key for a " .. kind .. " layer"
			.. (if u.suggestion then " (did you mean " .. u.suggestion .. "?)" else ""))
	end
	local names = {}
	for k in norm do
		table.insert(names, k)
	end
	table.sort(names)
	local types = FxMath.TYPES[kind]
	for _, k in names do
		if k ~= "kind" then
			checkValue(types[k] or FxMath.TYPES.common[k], norm[k], path .. "." .. k, out)
		end
	end
	if kind == "particles" then
		if norm.count == nil and norm.rate == nil then
			push(out, path .. ".count", "set count (a burst) or rate (continuous emission)")
		elseif norm.count ~= nil and norm.rate ~= nil then
			push(out, path .. ".rate", "use count (a burst) or rate (continuous), not both")
		end
	elseif kind == "beam" then
		if norm.to == nil then
			push(out, path .. ".to", "a beam needs to (its end point)")
		end
	elseif kind == "decal" then
		if norm.texture == nil then
			push(out, path .. ".texture", "a decal needs a texture")
		end
	elseif kind == "flash" then
		if FxMath.enumValue(norm.shape, { "mesh" }) and norm.mesh == nil then
			push(out, path .. ".mesh", "shape \"mesh\" needs mesh (a mesh content id)")
		end
	end
end

-- Every problem in an effect spec, as "path: message" strings (paths like "layers[2].lifetime").
-- A bare list of layers is accepted as {layers = list}.
function FxMath.validateEffect(spec: any): { string }
	local out: { string } = {}
	if type(spec) ~= "table" then
		push(out, "effect", "expected a table with layers, got " .. describe(spec))
		return out
	end
	if findKey(spec, "layers") == nil and #spec > 0 then
		spec = { layers = spec }
	end
	local norm, unknown = FxMath.normalizeKeys(spec, FxMath.EFFECT_KEYS)
	for _, u in unknown do
		push(out, u.key, "unknown key for an effect" .. (if u.suggestion then " (did you mean " .. u.suggestion .. "?)" else ""))
	end
	local layers = norm.layers
	if type(layers) ~= "table" or #layers == 0 then
		push(out, "layers", "expected a non-empty list of layers")
	else
		for i, layer in ipairs(layers) do
			FxMath.validateLayer(layer, "layers[" .. i .. "]", out)
		end
	end
	if norm.family ~= nil and type(norm.family) ~= "string" then
		push(out, "family", "expected a string, got " .. describe(norm.family))
	end
	if norm.budget ~= nil then
		checkTable(norm.budget, "budget", "budget", out)
	end
	return out
end

-- Every problem in a VFX.trail spec.
function FxMath.validateTrail(spec: any): { string }
	local out: { string } = {}
	if type(spec) ~= "table" then
		push(out, "trail", "expected a table, got " .. describe(spec))
		return out
	end
	checkTable(spec, "trail", "trail", out)
	return out
end

return FxMath
