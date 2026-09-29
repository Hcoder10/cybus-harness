--!native
-- AnimCore: the pure-Luau core of Kit.Anim. It uses no Roblox APIs, so the harness tests it under the standalone
-- Luau runtime. It validates and compiles clip data, samples clips (key search, easing, quaternion slerp), blends
-- weighted, prioritized tracks per joint, and runs track time (loops, fades, markers). Kit.Anim binds it to Motor6Ds.
--   local clip, problems = AnimCore.compile(data)     -- nil plus a list of problems for bad data; never errors
--   local qx, qy, qz, qw, px, py, pz = AnimCore.sampleChannel(clip.channels[i], t, clip.looped, clip.length)
--   local mixer = AnimCore.newMixer(jointCount); mixer:mix(tracks, trackCount)   -- results per joint slot
--   local track = AnimCore.newTrack(clip, { fade = 0.15 }); AnimCore.advance(track, dt, onEvent)
--
-- Conventions (shared with harness/tools/anim.py and harness/playbooks/animation_spec.md):
--   A pose value is { rx, ry, rz } or { rx, ry, rz, px, py, pz } (or { rx = .., py = .. }): degrees and studs,
--   relative to the joint's rest frame, about the CHARACTER's axes at rest (X right, Y up, Z back; the character
--   faces -Z). The rotation is CFrame.Angles(rx, ry, rz) = Rx * Ry * Rz, held as a quaternion.
--   Each joint's curve runs through the keys that pose it: quaternion slerp (always the short way round), eased by
--   the ease of the key it moves INTO. Looped clips wrap every curve around the loop, so joints keyed at offset
--   times (overlap) still loop seamlessly. In a one-shot, a joint not posed at t = 0 starts from rest at t = 0, and
--   every joint holds its last key to the end.
--   Blending: tracks of the same priority mix by weight; each priority is laid over the ones below it with its
--   total weight (capped at 1), so a full-weight action overrides idle on the joints it poses.
local AnimCore = {}

local sin, cos, sqrt, acos, floor = math.sin, math.cos, math.sqrt, math.acos, math.floor
local HUGE = math.huge
local HALF_RAD = math.pi / 360 -- degrees -> half-angle radians

AnimCore.PRIORITY = { core = 1, idle = 2, movement = 3, action = 4 }
AnimCore.PRIORITY_NAMES = { "core", "idle", "movement", "action" }
AnimCore.EASES = {
	"linear",
	"sine", "sineIn", "sineOut",
	"quad", "quadIn", "quadOut",
	"cubic", "cubicIn", "cubicOut",
	"back", "backIn", "backOut",
	"expo", "expoIn", "expoOut",
}
AnimCore.DEFAULT_EASE = "sine"
AnimCore.MIN_LENGTH = 0.05
AnimCore.MAX_LENGTH = 60

local EASE_ID = {}
for i, name in AnimCore.EASES do
	EASE_ID[name] = i
end
AnimCore.EASE_ID = EASE_ID

-- Easing curves (Penner). "<style>" eases both ends, "<style>In" accelerates into the key, "<style>Out"
-- decelerates into it (the same meaning as Enum.EasingDirection). back overshoots; the slerp extrapolates.
local B1 = 1.70158
local B2 = B1 * 1.525
local B3 = B1 + 1
local PI, HALF_PI = math.pi, math.pi / 2

local EASE_FN = {
	function(a) -- linear
		return a
	end,
	function(a) -- sine
		return -(cos(PI * a) - 1) / 2
	end,
	function(a) -- sineIn
		return 1 - cos(a * HALF_PI)
	end,
	function(a) -- sineOut
		return sin(a * HALF_PI)
	end,
	function(a) -- quad
		if a < 0.5 then
			return 2 * a * a
		end
		local b = -2 * a + 2
		return 1 - b * b / 2
	end,
	function(a) -- quadIn
		return a * a
	end,
	function(a) -- quadOut
		local b = 1 - a
		return 1 - b * b
	end,
	function(a) -- cubic
		if a < 0.5 then
			return 4 * a * a * a
		end
		local b = -2 * a + 2
		return 1 - b * b * b / 2
	end,
	function(a) -- cubicIn
		return a * a * a
	end,
	function(a) -- cubicOut
		local b = 1 - a
		return 1 - b * b * b
	end,
	function(a) -- back
		if a < 0.5 then
			local b = 2 * a
			return b * b * ((B2 + 1) * b - B2) / 2
		end
		local b = 2 * a - 2
		return (b * b * ((B2 + 1) * b + B2) + 2) / 2
	end,
	function(a) -- backIn
		return B3 * a * a * a - B1 * a * a
	end,
	function(a) -- backOut
		local b = a - 1
		return 1 + B3 * b * b * b + B1 * b * b
	end,
	function(a) -- expo
		if a <= 0 then
			return 0
		elseif a >= 1 then
			return 1
		elseif a < 0.5 then
			return 2 ^ (20 * a - 10) / 2
		end
		return (2 - 2 ^ (-20 * a + 10)) / 2
	end,
	function(a) -- expoIn
		if a <= 0 then
			return 0
		end
		return 2 ^ (10 * a - 10)
	end,
	function(a) -- expoOut
		if a >= 1 then
			return 1
		end
		return 1 - 2 ^ (-10 * a)
	end,
}

function AnimCore.ease(name, a)
	local id = if type(name) == "number" then name else EASE_ID[name]
	return EASE_FN[id or EASE_ID[AnimCore.DEFAULT_EASE]](a)
end

-- Quaternions (x, y, z, w) -------------------------------------------------------------------------------

-- CFrame.Angles(rx, ry, rz) in degrees (= Rx * Ry * Rz) as a quaternion.
function AnimCore.euler(rx, ry, rz)
	local hx, hy, hz = rx * HALF_RAD, ry * HALF_RAD, rz * HALF_RAD
	local sx, cx = sin(hx), cos(hx)
	local sy, cy = sin(hy), cos(hy)
	local sz, cz = sin(hz), cos(hz)
	return sx * cy * cz + cx * sy * sz, cx * sy * cz - sx * cy * sz, cx * cy * sz + sx * sy * cz, cx * cy * cz - sx * sy * sz
end

-- a * b (apply b first, then a).
local function mul(ax, ay, az, aw, bx, by, bz, bw)
	return aw * bx + ax * bw + ay * bz - az * by,
		aw * by - ax * bz + ay * bw + az * bx,
		aw * bz + ax * by - ay * bx + az * bw,
		aw * bw - ax * bx - ay * by - az * bz
end
AnimCore.mul = mul

-- Rotates the vector (vx, vy, vz) by the unit quaternion q.
function AnimCore.rotate(qx, qy, qz, qw, vx, vy, vz)
	local tx = 2 * (qy * vz - qz * vy)
	local ty = 2 * (qz * vx - qx * vz)
	local tz = 2 * (qx * vy - qy * vx)
	return vx + qw * tx + (qy * tz - qz * ty), vy + qw * ty + (qz * tx - qx * tz), vz + qw * tz + (qx * ty - qy * tx)
end

-- Rotation matrix (rows, as CFrame:GetComponents() gives them) -> unit quaternion.
function AnimCore.fromMatrix(r00, r01, r02, r10, r11, r12, r20, r21, r22)
	local x, y, z, w
	local trace = r00 + r11 + r22
	if trace > 0 then
		local s = sqrt(trace + 1) * 2
		x, y, z, w = (r21 - r12) / s, (r02 - r20) / s, (r10 - r01) / s, 0.25 * s
	elseif r00 > r11 and r00 > r22 then
		local s = sqrt(1 + r00 - r11 - r22) * 2
		x, y, z, w = 0.25 * s, (r01 + r10) / s, (r02 + r20) / s, (r21 - r12) / s
	elseif r11 > r22 then
		local s = sqrt(1 + r11 - r00 - r22) * 2
		x, y, z, w = (r01 + r10) / s, 0.25 * s, (r12 + r21) / s, (r02 - r20) / s
	else
		local s = sqrt(1 + r22 - r00 - r11) * 2
		x, y, z, w = (r02 + r20) / s, (r12 + r21) / s, 0.25 * s, (r10 - r01) / s
	end
	local n = sqrt(x * x + y * y + z * z + w * w)
	return x / n, y / n, z / n, w / n
end

-- Spherical interpolation from a to b, the short way round. t outside 0..1 extrapolates along the same arc
-- (back easing overshoots); nearly equal rotations fall back to a normalized lerp.
local function slerp(
	ax: number,
	ay: number,
	az: number,
	aw: number,
	bx: number,
	by: number,
	bz: number,
	bw: number,
	t: number
): (number, number, number, number)
	local d = ax * bx + ay * by + az * bz + aw * bw
	if d < 0 then
		d, bx, by, bz, bw = -d, -bx, -by, -bz, -bw
	end
	local k0, k1
	if d > 0.9995 then
		k0, k1 = 1 - t, t
	else
		local th = acos(d)
		local s = sin(th)
		k0, k1 = sin((1 - t) * th) / s, sin(t * th) / s
	end
	local x, y, z, w = ax * k0 + bx * k1, ay * k0 + by * k1, az * k0 + bz * k1, aw * k0 + bw * k1
	local n = sqrt(x * x + y * y + z * z + w * w)
	if n < 1e-12 then
		return 0, 0, 0, 1
	end
	return x / n, y / n, z / n, w / n
end
AnimCore.slerp = slerp

-- Validation ---------------------------------------------------------------------------------------------

local function finite(x)
	return type(x) == "number" and x == x and x ~= HUGE and x ~= -HUGE
end

local POSE_FIELDS = { rx = true, ry = true, rz = true, px = true, py = true, pz = true }

-- A pose value -> rx, ry, rz, px, py, pz; nil when it is not { rx, ry, rz [, px, py, pz] } or { rx = .., .. }.
local function poseValue(v)
	if type(v) ~= "table" then
		return nil
	end
	local n = #v
	if n > 0 then
		if n ~= 3 and n ~= 6 then
			return nil
		end
		for i = 1, n do
			if not finite(v[i]) then
				return nil
			end
		end
		return v[1], v[2], v[3], v[4] or 0, v[5] or 0, v[6] or 0
	end
	local any = false
	for k, x in v do
		if not POSE_FIELDS[k] or not finite(x) then
			return nil
		end
		any = true
	end
	if not any then
		return nil
	end
	return v.rx or 0, v.ry or 0, v.rz or 0, v.px or 0, v.py or 0, v.pz or 0
end
AnimCore.poseValue = poseValue

local function near(a, b)
	return math.abs(a - b) <= 1e-6
end

-- Every structural problem in a clip table, as a list of strings (empty when the clip is usable).
-- harness/tools/anim.py validates authored clips more strictly (joint names, anatomical limits, loop seams);
-- this is the runtime's guard so bad data warns instead of erroring.
function AnimCore.check(clip)
	local problems = {}
	local function bad(message)
		if #problems < 24 then
			table.insert(problems, message)
		end
	end
	if type(clip) ~= "table" then
		return { "a clip must be a table" }
	end
	if type(clip.name) ~= "string" or clip.name == "" then
		bad("name must be a non-empty string")
	end
	local length = clip.length
	if not finite(length) or length < AnimCore.MIN_LENGTH or length > AnimCore.MAX_LENGTH then
		bad(`length must be seconds between {AnimCore.MIN_LENGTH} and {AnimCore.MAX_LENGTH}, got {tostring(length)}`)
		length = nil
	end
	if clip.looped ~= nil and type(clip.looped) ~= "boolean" then
		bad("looped must be true or false")
	end
	if clip.priority ~= nil and AnimCore.PRIORITY[clip.priority] == nil then
		bad(`priority must be core, idle, movement or action, got {tostring(clip.priority)}`)
	end
	local keys = clip.keys
	if type(keys) ~= "table" or #keys == 0 then
		bad("keys must be a non-empty list of { t = seconds, pose = { [joint] = { rx, ry, rz } } }")
		return problems
	end
	local last = -HUGE
	for i, key in ipairs(keys) do
		local where = `keys[{i}]`
		if type(key) ~= "table" then
			bad(where .. " must be a table")
			continue
		end
		local t = key.t
		if not finite(t) then
			bad(where .. ".t must be a number of seconds")
		else
			if t < 0 or (length ~= nil and t > length + 1e-6) then
				bad(`{where}.t = {t} is outside 0..length`)
			end
			if t <= last then
				bad(`{where}.t = {t} is not after the previous key (keys must be in time order)`)
			end
			last = t
		end
		if key.ease ~= nil and EASE_ID[key.ease] == nil then
			bad(`{where}.ease {tostring(key.ease)} is not one of {table.concat(AnimCore.EASES, ", ")}`)
		end
		local pose = key.pose
		if type(pose) ~= "table" then
			bad(where .. ".pose must be a table { [joint] = { rx, ry, rz } }")
			continue
		end
		for joint, v in pose do
			if type(joint) ~= "string" or joint == "" then
				bad(where .. ".pose has a joint name that is not a string")
			elseif poseValue(v) == nil then
				bad(`{where}.pose.{joint} must be \{ rx, ry, rz } or \{ rx, ry, rz, px, py, pz } (finite numbers)`)
			end
		end
	end
	local first = keys[1]
	local final = keys[#keys]
	if type(first) == "table" and finite(first.t) and not near(first.t, 0) then
		bad("the first key must be at t = 0")
	end
	if clip.looped == true and length ~= nil and type(final) == "table" and finite(final.t) and not near(final.t, length) then
		bad("a looped clip needs its last key at t = length (the same pose as t = 0)")
	end
	if clip.markers ~= nil then
		if type(clip.markers) ~= "table" then
			bad("markers must be a list of { t = seconds, name = string }")
		else
			for i, m in ipairs(clip.markers) do
				if type(m) ~= "table" or type(m.name) ~= "string" or m.name == "" then
					bad(`markers[{i}] needs a name`)
				elseif not finite(m.t) or m.t < 0 or (length ~= nil and m.t > length + 1e-6) then
					bad(`markers[{i}] ({m.name}).t must be within 0..length`)
				end
			end
		end
	end
	return problems
end

-- Compile ------------------------------------------------------------------------------------------------

-- Validates and precomputes a clip: one channel per joint (the keys that pose it) with quaternions.
-- Returns compiled, {} or nil, problems. An already compiled clip is returned as is.
function AnimCore.compile(clip)
	if type(clip) == "table" and clip._compiled == true then
		return clip, {}
	end
	local problems = AnimCore.check(clip)
	if #problems > 0 then
		return nil, problems
	end
	local byJoint, joints = {}, {}
	for _, key in ipairs(clip.keys) do
		local ease = EASE_ID[key.ease or AnimCore.DEFAULT_EASE]
		for joint, v in key.pose do
			local ch = byJoint[joint]
			if ch == nil then
				ch = { joint = joint, n = 0, t = {}, qx = {}, qy = {}, qz = {}, qw = {}, px = {}, py = {}, pz = {}, ease = {} }
				byJoint[joint] = ch
				table.insert(joints, joint)
			end
			local rx, ry, rz, px, py, pz = poseValue(v)
			local n = ch.n + 1
			ch.n = n
			ch.t[n] = key.t
			ch.qx[n], ch.qy[n], ch.qz[n], ch.qw[n] = AnimCore.euler(rx, ry, rz)
			ch.px[n], ch.py[n], ch.pz[n] = px, py, pz
			ch.ease[n] = ease
		end
	end
	table.sort(joints)
	local looped = clip.looped == true
	local channels, index = {}, {}
	for i, joint in joints do
		local ch = byJoint[joint]
		if not looped and ch.t[1] > 0 then
			-- a one-shot starts every joint it moves from rest unless the joint is posed at t = 0
			table.insert(ch.t, 1, 0)
			table.insert(ch.qx, 1, 0)
			table.insert(ch.qy, 1, 0)
			table.insert(ch.qz, 1, 0)
			table.insert(ch.qw, 1, 1)
			table.insert(ch.px, 1, 0)
			table.insert(ch.py, 1, 0)
			table.insert(ch.pz, 1, 0)
			table.insert(ch.ease, 1, EASE_ID[AnimCore.DEFAULT_EASE])
			ch.n += 1
		end
		channels[i] = ch
		index[joint] = i
	end
	local markers = {}
	if type(clip.markers) == "table" then
		for _, m in ipairs(clip.markers) do
			local t = m.t
			if looped and t >= clip.length - 1e-6 then
				t = 0 -- the end of a loop is its start
			end
			table.insert(markers, { t = t, name = m.name })
		end
		table.sort(markers, function(a, b)
			return a.t < b.t
		end)
	end
	local priorityName = clip.priority or (if looped then "idle" else "action")
	return {
		_compiled = true,
		name = clip.name,
		length = clip.length,
		looped = looped,
		priority = AnimCore.PRIORITY[priorityName],
		priorityName = priorityName,
		channels = channels,
		index = index,
		joints = joints,
		count = #channels,
		markers = markers,
		source = clip,
	}, {}
end

-- Sampling -----------------------------------------------------------------------------------------------

-- One joint at time t -> qx, qy, qz, qw, px, py, pz. Looped: t wraps, and so does the curve (from the joint's
-- last key round to its first). Not looped: holds the first / last key outside the keyed range.
local function sampleChannel(ch, t, looped, length)
	local n = ch.n
	local times = ch.t
	if n == 1 then
		return ch.qx[1], ch.qy[1], ch.qz[1], ch.qw[1], ch.px[1], ch.py[1], ch.pz[1]
	end
	local i, j, a = 0, 0, 0
	local wrapped = false
	if looped then
		t -= floor(t / length) * length
		if t >= length then
			t = 0
		end
		local tLast = times[n]
		if t < times[1] or t >= tLast then
			local span = times[1] + length - tLast
			local u = if t >= tLast then t - tLast else t + length - tLast
			i, j, a = n, 1, if span > 0 then u / span else 0
			wrapped = true
		end
	else
		if t <= times[1] then
			return ch.qx[1], ch.qy[1], ch.qz[1], ch.qw[1], ch.px[1], ch.py[1], ch.pz[1]
		elseif t >= times[n] then
			return ch.qx[n], ch.qy[n], ch.qz[n], ch.qw[n], ch.px[n], ch.py[n], ch.pz[n]
		end
	end
	if not wrapped then
		local lo, hi = 1, n -- times[lo] <= t < times[hi]
		while hi - lo > 1 do
			local mid = (lo + hi) // 2
			if times[mid] <= t then
				lo = mid
			else
				hi = mid
			end
		end
		i, j = lo, lo + 1
		a = (t - times[i]) / (times[j] - times[i])
	end
	local k = EASE_FN[ch.ease[j]](a)
	local qx, qy, qz, qw = slerp(ch.qx[i], ch.qy[i], ch.qz[i], ch.qw[i], ch.qx[j], ch.qy[j], ch.qz[j], ch.qw[j], k)
	local px, py, pz = ch.px[i], ch.py[i], ch.pz[i]
	return qx, qy, qz, qw, px + (ch.px[j] - px) * k, py + (ch.py[j] - py) * k, pz + (ch.pz[j] - pz) * k
end
AnimCore.sampleChannel = sampleChannel

-- Every joint of a compiled clip at time t -> { [joint] = { qx, qy, qz, qw, px, py, pz } } (allocates; for tools).
function AnimCore.samplePose(clip, t, looped)
	if looped == nil then
		looped = clip.looped
	end
	local out = {}
	for _, ch in clip.channels do
		out[ch.joint] = { sampleChannel(ch, t, looped, clip.length) }
	end
	return out
end

-- Mixer --------------------------------------------------------------------------------------------------
-- Blends tracks into per-joint results without allocating. A track (see newTrack) needs: clip (compiled), time,
-- looped, w (effective weight), prio, and map (clip channel index -> joint slot, 0 when the rig lacks the joint).
-- tracks[1..count] must be sorted by prio, lowest first. After mix(), for each slot s:
--   c[s]   coverage 0..1: how much of this joint the tracks own (0 = untouched)
--   qx/qy/qz/qw[s], px/py/pz[s]   the blended pose (unit quaternion; identity where c is 0)
-- The final joint pose is slerp(base, blended, c): base is the rest pose, or the Animator's pose under it.
local Mixer = {}
Mixer.__index = Mixer

local FIELDS = { "c", "qx", "qy", "qz", "qw", "px", "py", "pz", "lw", "lx", "ly", "lz", "lq", "lpx", "lpy", "lpz" }

function AnimCore.newMixer(slots)
	local m = setmetatable({ n = slots }, Mixer)
	for _, f in FIELDS do
		m[f] = table.create(slots, 0)
	end
	return m
end

function Mixer:mix(tracks, count)
	local n = self.n
	local c, qx, qy, qz, qw, px, py, pz = self.c, self.qx, self.qy, self.qz, self.qw, self.px, self.py, self.pz
	local lw, lx, ly, lz, lq, lpx, lpy, lpz = self.lw, self.lx, self.ly, self.lz, self.lq, self.lpx, self.lpy, self.lpz
	for s = 1, n do
		c[s], qx[s], qy[s], qz[s], qw[s], px[s], py[s], pz[s] = 0, 0, 0, 0, 0, 0, 0, 0
	end
	local i = 1
	while i <= count do
		local prio = tracks[i].prio
		for s = 1, n do
			lw[s], lx[s], ly[s], lz[s], lq[s], lpx[s], lpy[s], lpz[s] = 0, 0, 0, 0, 0, 0, 0, 0
		end
		local any = false
		-- one priority layer: weighted sum of its tracks per joint (quaternions kept in one hemisphere)
		while i <= count do
			local tr = tracks[i]
			if tr.prio ~= prio then
				break
			end
			i += 1
			local w = tr.w
			local map = tr.map
			if w > 0 and map ~= nil then
				local clip = tr.clip
				local channels = clip.channels
				local looped, length, time = tr.looped, clip.length, tr.time
				for ci = 1, clip.count do
					local s = map[ci]
					if s ~= nil and s > 0 then
						local x, y, z, ww, ox, oy, oz = sampleChannel(channels[ci], time, looped, length)
						local acc = lw[s]
						if acc > 0 and lx[s] * x + ly[s] * y + lz[s] * z + lq[s] * ww < 0 then
							x, y, z, ww = -x, -y, -z, -ww
						end
						lx[s] += w * x
						ly[s] += w * y
						lz[s] += w * z
						lq[s] += w * ww
						lpx[s] += w * ox
						lpy[s] += w * oy
						lpz[s] += w * oz
						lw[s] = acc + w
						any = true
					end
				end
			end
		end
		if any then
			-- lay the layer over what is below it with alpha = min(1, total weight)
			for s = 1, n do
				local wsum = lw[s]
				if wsum > 0 then
					local alpha = if wsum < 1 then wsum else 1
					local x, y, z, ww = lx[s], ly[s], lz[s], lq[s]
					local len = sqrt(x * x + y * y + z * z + ww * ww)
					if len > 1e-12 then
						x, y, z, ww = x / len, y / len, z / len, ww / len
					else
						x, y, z, ww = 0, 0, 0, 1
					end
					if c[s] > 0 and qx[s] * x + qy[s] * y + qz[s] * z + qw[s] * ww < 0 then
						x, y, z, ww = -x, -y, -z, -ww
					end
					local keep = 1 - alpha
					qx[s] = qx[s] * keep + x * alpha
					qy[s] = qy[s] * keep + y * alpha
					qz[s] = qz[s] * keep + z * alpha
					qw[s] = qw[s] * keep + ww * alpha
					px[s] = px[s] * keep + lpx[s] / wsum * alpha
					py[s] = py[s] * keep + lpy[s] / wsum * alpha
					pz[s] = pz[s] * keep + lpz[s] / wsum * alpha
					c[s] = c[s] * keep + alpha
				end
			end
		end
	end
	for s = 1, n do
		local cs = c[s]
		if cs > 0 then
			local x, y, z, w = qx[s], qy[s], qz[s], qw[s]
			local len = sqrt(x * x + y * y + z * z + w * w)
			if len > 1e-12 then
				qx[s], qy[s], qz[s], qw[s] = x / len, y / len, z / len, w / len
			else
				qx[s], qy[s], qz[s], qw[s] = 0, 0, 0, 1
			end
			px[s] /= cs
			py[s] /= cs
			pz[s] /= cs
		else
			qw[s] = 1
		end
	end
end

-- Tracks -------------------------------------------------------------------------------------------------

local function number(x, default)
	if finite(x) then
		return x
	end
	return default
end

local function clampNumber(x, default, lo, hi)
	return math.clamp(number(x, default), lo, hi)
end

-- A playing instance of a compiled clip. opts: fade (seconds in, default 0.15), speed (1; negative plays
-- backwards), weight (1), priority (name; default the clip's), looped (default the clip's), hold (a one-shot keeps
-- its last pose until stopped), fadeOut (seconds out when a one-shot ends; default fade).
function AnimCore.newTrack(clip, opts)
	opts = if type(opts) == "table" then opts else {}
	local speed = clampNumber(opts.speed, 1, -100, 100)
	local weight = clampNumber(opts.weight, 1, 0, 10)
	local fade = clampNumber(opts.fade, 0.15, 0, 10)
	local looped = if opts.looped == nil then clip.looped else opts.looped == true
	return {
		clip = clip,
		name = clip.name,
		length = clip.length,
		looped = looped,
		prio = AnimCore.PRIORITY[opts.priority] or clip.priority,
		time = if speed < 0 and not looped then clip.length else 0,
		speed = speed,
		weight = weight,
		w = if fade > 0 then 0 else weight,
		wFrom = 0,
		wTo = weight,
		fadeT = fade,
		fadeE = 0,
		fadeOut = clampNumber(opts.fadeOut, fade, 0, 10),
		hold = opts.hold == true,
		state = "playing", -- playing -> stopping (fading out) -> ended
		isPlaying = true,
	}
end

-- Calls onEvent(track, "marker", name) for markers with lo < t < hi (inclusive ends when asked).
local function fire(tr, lo, hi, loIn, hiIn, onEvent)
	local markers = tr.clip.markers
	for i = 1, #markers do
		local m = markers[i]
		local t = m.t
		if (t > lo or (loIn and t == lo)) and (t < hi or (hiIn and t == hi)) then
			onEvent(tr, "marker", m.name)
		end
	end
end

-- Advances time and fades by dt seconds. Events go to onEvent(track, kind, name): "marker" (only while playing),
-- "stopped" (a one-shot reached its end and starts fading out) and "ended" (faded out; drop the track).
-- Returns true once the track has ended.
function AnimCore.advance(tr, dt, onEvent)
	if tr.state == "ended" then
		return true
	end
	local length = tr.clip.length
	local d = dt * tr.speed
	local firing = onEvent ~= nil and tr.state == "playing" and #tr.clip.markers > 0
	if d ~= 0 then
		local t0 = tr.time
		local t1 = t0 + d
		if tr.looped then
			if d > 0 then
				if t1 >= length then
					if firing then
						fire(tr, t0, length, true, false, onEvent) -- [t0, length)
					end
					t1 -= floor(t1 / length) * length
					if firing then
						fire(tr, 0, t1, true, false, onEvent) -- [0, t1)
					end
				elseif firing then
					fire(tr, t0, t1, true, false, onEvent) -- [t0, t1)
				end
			elseif t1 < 0 then
				if firing then
					fire(tr, 0, t0, true, true, onEvent) -- [0, t0]
				end
				t1 -= floor(t1 / length) * length
				if firing then
					fire(tr, t1, length, false, false, onEvent) -- (t1, length)
				end
			elseif firing then
				fire(tr, t1, t0, false, true, onEvent) -- (t1, t0]
			end
			if t1 >= length then
				t1 = 0
			end
			tr.time = t1
		elseif (d > 0 and t0 < length) or (d < 0 and t0 > 0) then
			local done = false
			if d > 0 then
				if t1 >= length then
					t1, done = length, true
				end
				if firing then
					fire(tr, t0, t1, true, done, onEvent) -- [t0, t1), or [t0, length] at the end
				end
			else
				if t1 <= 0 then
					t1, done = 0, true
				end
				if firing then
					fire(tr, t1, t0, done, true, onEvent) -- (t1, t0], or [0, t0] at the start
				end
			end
			tr.time = t1
			if done and tr.state == "playing" and not tr.hold then
				tr.state = "stopping"
				tr.isPlaying = false
				tr.wFrom, tr.wTo, tr.fadeT, tr.fadeE = tr.w, 0, tr.fadeOut, 0
				if onEvent ~= nil then
					onEvent(tr, "stopped")
				end
			end
		end
	end
	if tr.fadeE < tr.fadeT then
		local e = tr.fadeE + dt
		if e >= tr.fadeT then
			tr.fadeE = tr.fadeT
			tr.w = tr.wTo
		else
			tr.fadeE = e
			local a = e / tr.fadeT
			tr.w = tr.wFrom + (tr.wTo - tr.wFrom) * (a * a * (3 - 2 * a))
		end
	else
		tr.w = tr.wTo
	end
	if tr.state == "stopping" and tr.w <= 0 then
		tr.state = "ended"
		tr.isPlaying = false
		tr.w = 0
		if onEvent ~= nil then
			onEvent(tr, "ended")
		end
		return true
	end
	return false
end

-- Starts fading a playing track out (fade seconds; default its fadeOut). Returns true if it was playing.
function AnimCore.stop(tr, fade)
	if tr.state ~= "playing" then
		return false
	end
	tr.state = "stopping"
	tr.isPlaying = false
	tr.wFrom, tr.wTo, tr.fadeT, tr.fadeE = tr.w, 0, clampNumber(fade, tr.fadeOut, 0, 10), 0
	return true
end

-- Fades a playing track's weight to `weight` over `fade` seconds (default 0.1, like AnimationTrack:AdjustWeight).
function AnimCore.setWeight(tr, weight, fade)
	if tr.state ~= "playing" then
		return false
	end
	tr.weight = clampNumber(weight, tr.weight, 0, 10)
	tr.wFrom, tr.wTo, tr.fadeT, tr.fadeE = tr.w, tr.weight, clampNumber(fade, 0.1, 0, 10), 0
	return true
end

return AnimCore
