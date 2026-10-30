--!nonstrict
-- GameplayKit_Race: race manager for any vehicle (or on foot). Ordered checkpoint gates, laps, positions, split
-- and lap times, wrong-way, finish, and AI followers along a spline with rubber-banding. Server only.
--
-- Progress is a monotonic odometer along a closed Catmull-Rom spline through the gates (the wave-racer model):
-- each sample's change in arc length is unwrapped across the start line and accumulated. Gates are arc-length
-- milestones on that odometer, so they cannot be missed or double-fired, and a jump larger than a racer could
-- physically drive in one tick (a shortcut or teleport) is simply not counted.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Core = require((script.Parent :: Instance):WaitForChild("GameplayKit_Core"))
local Maid = require((script.Parent :: Instance):WaitForChild("Maid"))
local Signal = Core.Signal

local Race = {}

----------------------------------------------------------------------------------------------------------------
-- Spline: closed (or open) Catmull-Rom through points, arc-length sampled
----------------------------------------------------------------------------------------------------------------
local Spline = {}
Spline.__index = Spline
Race.Spline = Spline

local function catmull(p0, p1, p2, p3, t)
	local t2, t3 = t * t, t * t * t
	return 0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (-p0 + 3 * p1 - 3 * p2 + p3) * t3)
end

-- Spline.new({Vector3|BasePart|CFrame...}, closed=true, samplesPerSegment=12) -> sp (sp.length; sp:at(s); sp:project(pos))
function Spline.new(points, closed, per)
	local pts = {}
	for _, p in ipairs(points) do
		table.insert(pts, Core.position(p))
	end
	closed = closed ~= false
	per = per or 12
	local self = setmetatable({ closed = closed, pos = {}, s = {}, length = 0 }, Spline)
	local n = #pts
	if n < 2 then
		pts = { Vector3.zero, Vector3.new(0, 0, -10) }
		n = 2
	end
	local function P(i)
		if closed then
			return pts[(i - 1) % n + 1]
		end
		return pts[math.clamp(i, 1, n)]
	end
	local segs = closed and n or n - 1
	local acc, prev = 0, nil
	for i = 1, segs do
		for k = 0, per - 1 do
			local q = catmull(P(i - 1), P(i), P(i + 1), P(i + 2), k / per)
			if prev then
				acc += (q - prev).Magnitude
			end
			table.insert(self.pos, q)
			table.insert(self.s, acc)
			prev = q
		end
	end
	local last = closed and P(1) or P(n)
	acc += (last - prev).Magnitude
	if not closed then
		table.insert(self.pos, last)
		table.insert(self.s, acc)
	end
	self.length = acc
	return self
end

-- sp:at(s) -> position, tangent (unit)
function Spline:at(s)
	local L = self.length
	if self.closed then
		s = s % L
	else
		s = math.clamp(s, 0, L)
	end
	local pos, arr = self.pos, self.s
	local lo, hi = 1, #arr
	while hi - lo > 1 do
		local mid = (lo + hi) // 2
		if arr[mid] <= s then
			lo = mid
		else
			hi = mid
		end
	end
	if arr[hi] <= s then
		lo = hi
	end
	local n = #arr
	local a, b, sb = pos[lo], nil, nil
	if lo < n then
		b, sb = pos[lo + 1], arr[lo + 1]
	elseif self.closed then
		b, sb = pos[1], L
	else
		b, sb = a, arr[lo]
	end
	local sa = arr[lo]
	local seg = b - a
	local t = (sb > sa) and (s - sa) / (sb - sa) or 0
	local tangent = seg.Magnitude > 1e-4 and seg.Unit or Vector3.new(0, 0, -1)
	return a + seg * math.clamp(t, 0, 1), tangent
end

-- sp:cframe(s, lateral=0, up=0) -> CFrame facing along the spline
function Spline:cframe(s, lateral, up)
	local p, t = self:at(s)
	local right = t:Cross(Vector3.yAxis)
	right = right.Magnitude > 1e-4 and right.Unit or Vector3.xAxis
	p += right * (lateral or 0) + Vector3.yAxis * (up or 0)
	return CFrame.lookAt(p, p + t)
end

-- sp:project(pos, hintIndex?, window=24) -> s, distance, index (local search around the hint, global otherwise)
function Spline:project(p, hint, window)
	local pos, arr, n = self.pos, self.s, #self.pos
	local function test(i)
		local j = i % n + 1
		local a, b = pos[i], pos[j]
		local sa = arr[i]
		local sb = (j == 1) and self.length or arr[j]
		if j == 1 and not self.closed then
			return math.huge, sa
		end
		local ab = b - a
		local len2 = ab:Dot(ab)
		local t = len2 > 0 and math.clamp((p - a):Dot(ab) / len2, 0, 1) or 0
		local q = a + ab * t
		return (p - q).Magnitude, sa + (sb - sa) * t
	end
	local bestD, bestS, bestI = math.huge, 0, 1
	if hint then
		window = window or 24
		for k = -window, window do
			local i = (hint - 1 + k) % n + 1
			local d, s = test(i)
			if d < bestD then
				bestD, bestS, bestI = d, s, i
			end
		end
	end
	if not hint or bestD > 40 then
		for i = 1, n do
			local d, s = test(i)
			if d < bestD then
				bestD, bestS, bestI = d, s, i
			end
		end
	end
	return bestS, bestD, bestI
end

----------------------------------------------------------------------------------------------------------------
-- Race manager
----------------------------------------------------------------------------------------------------------------
local RaceMgr = {}
RaceMgr.__index = RaceMgr

-- Race.new({gates={BasePart...} | Folder (gate 1 = start/finish), path={points}? (smoother line than gate centres),
--   laps=3, countdown=3, freeze=true (anchor players during countdown), grid=true (line racers up behind gate 1),
--   width=80 (off-track distance that stops progress), maxSpeed=250 (studs/s; faster jumps don't count),
--   finishGrace=30 (s after the winner before the rest are DNF), autoJoin=true (all players join on start),
--   onGate=fn(racer, gate, split), onLap=fn(racer, lap, lapTime), onFinish=fn(racer, place, time), onOver=fn(standings)})
-- Racer records: {name, player?, model?, lap, place, finished, time, splits, lapTimes, bestLap, wrongWay, progress}
function Race.new(opts)
	opts = opts or {}
	local gates = Core.list(opts.gates or workspace:FindFirstChild("Gates"), "BasePart")
	if #gates < 2 then
		warn("[GameplayKit] Race needs at least 2 gates (opts.gates = {BasePart...} or a Folder); race:start() will do nothing")
	end
	local self = setmetatable({
		opts = opts,
		gates = gates,
		laps = opts.laps or 3,
		width = opts.width or 80,
		maxSpeed = opts.maxSpeed or 250,
		racers = {},
		Status = "Idle",
		state = Core.state("Race"),
		maid = Maid.new(),
		GatePassed = Signal.new(), -- (racer, gateIndex, splitTime)
		LapCompleted = Signal.new(), -- (racer, lap, lapTime)
		Finished = Signal.new(), -- (racer, place, time)
		WrongWay = Signal.new(), -- (racer, bool)
		StatusChanged = Signal.new(), -- (status) "Idle"|"Countdown"|"Racing"|"Finished"
		Over = Signal.new(), -- (standings)
	}, RaceMgr)
	self.spline = Spline.new(opts.path or gates, true)
	local L = self.spline.length
	local s0 = self.spline:project(Core.position(gates[1]) or Vector3.zero)
	self.s0 = s0
	self.rel = {}
	for i, g in ipairs(gates) do
		local s = self.spline:project(g.Position)
		self.rel[i] = (s - s0) % L
		g:SetAttribute("GateIndex", i)
	end
	self.rel[1] = 0
	if opts.onGate then
		self.GatePassed:Connect(opts.onGate)
	end
	if opts.onLap then
		self.LapCompleted:Connect(opts.onLap)
	end
	if opts.onFinish then
		self.Finished:Connect(opts.onFinish)
	end
	if opts.onOver then
		self.Over:Connect(opts.onOver)
	end
	self.maid:Give(Players.PlayerRemoving:Connect(function(p)
		self:removeRacer(p)
	end))
	self:_status("Idle")
	return self
end

function RaceMgr:_status(s)
	self.Status = s
	if self.state then
		self.state:SetAttribute("Status", s)
		self.state:SetAttribute("Laps", self.laps)
		self.state:SetAttribute("Gates", #self.gates)
	end
	self.StatusChanged:Fire(s)
end

local function racerRoot(r)
	if r.player then
		local _, root, hum = Core.character(r.player)
		if hum and hum.SeatPart then
			return hum.SeatPart
		end
		return root
	end
	return r.model and r.model.Parent and Core.root(r.model)
end

-- race:addRacer(player | model, name?) -> racer
function RaceMgr:addRacer(x, name)
	for _, r in ipairs(self.racers) do
		if r.key == x then
			return r
		end
	end
	local isPlayer = typeof(x) == "Instance" and x:IsA("Player")
	local r = {
		key = x, player = isPlayer and x or nil, model = (not isPlayer) and x or nil,
		name = name or (typeof(x) == "Instance" and (isPlayer and (x :: any).DisplayName or x.Name)) or "Racer",
		lap = 0, passed = 0, odo = 0, place = #self.racers + 1, finished = false, time = 0,
		splits = {}, lapTimes = {}, bestLap = nil, wrongWay = false, back = 0, progress = 0,
	}
	table.insert(self.racers, r)
	return r
end

function RaceMgr:removeRacer(x)
	for i, r in ipairs(self.racers) do
		if r.key == x then
			table.remove(self.racers, i)
			return
		end
	end
end

-- race:grid(i) -> CFrame of grid slot i (two columns, behind the start line)
function RaceMgr:grid(i)
	local row, col = (i - 1) // 2, (i - 1) % 2
	return self.spline:cframe(self.s0 - 14 - row * 12, col == 0 and -6 or 6, 3)
end

local function milestone(self, k)
	local n = #self.gates
	return (k // n) * self.spline.length + self.rel[(k % n) + 1]
end

-- race:start() -> countdown, then racing
function RaceMgr:start()
	if self.Status == "Countdown" or self.Status == "Racing" or #self.gates < 2 then
		return
	end
	if Core.opt(self.opts, "autoJoin", true) then
		for _, p in ipairs(Players:GetPlayers()) do
			self:addRacer(p)
		end
	end
	local L = self.spline.length
	for i, r in ipairs(self.racers) do
		r.lap, r.passed, r.finished, r.time, r.wrongWay, r.back = 0, 0, false, 0, false, 0
		r.splits, r.lapTimes, r.bestLap = {}, {}, nil
		if Core.opt(self.opts, "grid", true) then
			local cf = self:grid(i)
			if r.player then
				local ch = Core.character(r.player)
				if ch then
					ch:PivotTo(cf)
				end
			elseif r.model then
				r.model:PivotTo(cf)
			end
			if r.follower then
				r.follower.s = self.s0 - 14 - ((i - 1) // 2) * 12
			end
		end
		local root = racerRoot(r)
		local s, _, idx = self.spline:project(root and root.Position or Vector3.zero)
		local rel = (s - self.s0) % L
		if rel > L / 2 then
			rel -= L
		end
		r.odo, r.lastS, r.hint = rel, s, idx
	end
	self:_publish()
	self.thread = task.spawn(function()
		self:_status("Countdown")
		local freeze = Core.opt(self.opts, "freeze", true)
		local frozen = {}
		if freeze then
			for _, r in ipairs(self.racers) do
				local root = r.player and racerRoot(r)
				if root and not root.Anchored then
					root.Anchored = true
					table.insert(frozen, root)
				end
			end
		end
		for c = self.opts.countdown or 3, 1, -1 do
			if self.state then
				self.state:SetAttribute("Count", c)
			end
			task.wait(1)
		end
		if self.state then
			self.state:SetAttribute("Count", 0)
		end
		for _, root in ipairs(frozen) do
			if root.Parent then
				root.Anchored = false
			end
		end
		self.t0 = os.clock()
		self:_status("Racing")
		self.loop = Core.every(0.05, function(dt)
			self:_tick(dt)
			return self.Status == "Racing"
		end)
		self.hb = RunService.Heartbeat:Connect(function(dt)
			self:_driveFollowers(dt)
		end)
		self.maid:Give(self.hb)
	end)
end

function RaceMgr:_tick(dt)
	local L = self.spline.length
	local now = os.clock() - self.t0
	if self.state then
		self.state:SetAttribute("Time", now)
	end
	for _, r in ipairs(self.racers) do
		local root = not r.finished and racerRoot(r)
		if root then
			local s, dist, idx = self.spline:project(root.Position, r.hint)
			r.hint = idx
			local ds = s - (r.lastS or s)
			if ds > L / 2 then
				ds -= L
			elseif ds < -L / 2 then
				ds += L
			end
			r.lastS = s
			if dist <= self.width and math.abs(ds) <= self.maxSpeed * dt * 1.5 + 8 then
				r.odo += ds
			end
			-- wrong way: going backwards along the line for > 1 s
			if ds < -0.5 * dt * 4 then
				r.back += dt
			elseif ds > 0 then
				r.back = 0
			end
			local wrong = r.back > 1
			if wrong ~= r.wrongWay then
				r.wrongWay = wrong
				self.WrongWay:Fire(r, wrong)
			end
			-- milestones
			while not r.finished and r.odo >= milestone(self, r.passed + 1) do
				r.passed += 1
				local g = (r.passed % #self.gates) + 1
				table.insert(r.splits, now)
				self.GatePassed:Fire(r, g, now)
				if g == 1 then
					r.lap += 1
					local prev = 0
					for _, t in ipairs(r.lapTimes) do
						prev += t
					end
					local lapTime = now - prev
					table.insert(r.lapTimes, lapTime)
					r.bestLap = math.min(r.bestLap or math.huge, lapTime)
					self.LapCompleted:Fire(r, r.lap, lapTime)
					if r.lap >= self.laps then
						self:_finish(r, now)
					end
				end
			end
			r.progress = r.odo / L
		end
	end
	self:_rank()
	self:_publish()
	if self.firstFinish and now - self.firstFinish > (self.opts.finishGrace or 30) then
		self:stop()
	end
end

function RaceMgr:_finish(r, now)
	r.finished = true
	r.time = now
	self.finishedCount = (self.finishedCount or 0) + 1
	r.place = self.finishedCount
	self.firstFinish = self.firstFinish or now
	self.Finished:Fire(r, r.place, now)
	local all = true
	for _, o in ipairs(self.racers) do
		if not o.finished then
			all = false
			break
		end
	end
	if all then
		task.defer(function()
			self:stop()
		end)
	end
end

function RaceMgr:_rank()
	local order = table.clone(self.racers)
	table.sort(order, function(a, b)
		if a.finished ~= b.finished then
			return a.finished
		end
		if a.finished then
			return a.place < b.place
		end
		return a.odo > b.odo
	end)
	for i, r in ipairs(order) do
		r.place = i
	end
	self.order = order
end

function RaceMgr:_publish()
	local rows = {}
	for i, r in ipairs(self.order or self.racers) do
		rows[i] = { name = r.name, place = r.place, lap = math.min(r.lap + 1, self.laps), finished = r.finished, time = r.time, progress = r.progress }
		if r.player then
			local p = r.player
			p:SetAttribute("RacePlace", r.place)
			p:SetAttribute("RaceLap", math.min(r.lap + 1, self.laps))
			p:SetAttribute("RaceGate", (r.passed % #self.gates) + 1)
			p:SetAttribute("RaceWrongWay", r.wrongWay)
			p:SetAttribute("RaceFinished", r.finished)
			p:SetAttribute("RaceTime", r.time)
		end
	end
	if self.state then
		self.state:SetAttribute("Standings", Core.encode(rows))
	end
end

-- race:standings() -> racers sorted by place
function RaceMgr:standings()
	self:_rank()
	return self.order
end

function RaceMgr:stop()
	if self.Status ~= "Racing" and self.Status ~= "Countdown" then
		return
	end
	if self.hb then
		self.hb:Disconnect()
		self.hb = nil
	end
	for _, r in ipairs(self.racers) do
		if not r.finished then
			r.dnf = true
		end
	end
	self:_rank()
	self:_publish()
	self:_status("Finished")
	self.firstFinish, self.finishedCount = nil, 0
	self.Over:Fire(self:standings())
end

----------------------------------------------------------------------------------------------------------------
-- AI followers: race:addFollower(model, {drive=fn(model, target: Vector3, speedScale, dt)?, speed=60 (studs/s),
--   lookahead=18, lane=0 (lateral offset), wander=2, height=2, rubber={min=0.85, max=1.2, range=120 (studs)},
--   name}) -> racer. Without `drive`: Humanoid models walk with MoveTo; anything else is moved kinematically
--   along the spline (PivotTo each frame). With `drive`, the callback steers your vehicle toward `target`.
----------------------------------------------------------------------------------------------------------------
function RaceMgr:addFollower(model, o)
	o = o or {}
	local r = self:addRacer(model, o.name)
	local rubber = o.rubber or {}
	r.follower = {
		drive = o.drive, speed = o.speed or 60, lookahead = o.lookahead or 18, lane = o.lane or 0,
		wander = o.wander or 2, height = o.height or 2, min = rubber.min or 0.85, max = rubber.max or 1.2,
		range = rubber.range or 120, scale = 1, s = nil, seed = math.random() * 100,
	}
	return r
end

function RaceMgr:_driveFollowers(dt)
	if self.Status ~= "Racing" then
		return
	end
	local L = self.spline.length
	local humanBest
	for _, r in ipairs(self.racers) do
		if r.player and not r.finished then
			humanBest = math.max(humanBest or -math.huge, r.odo)
		end
	end
	local t = os.clock()
	for _, r in ipairs(self.racers) do
		local f = r.follower
		if f and r.model and r.model.Parent and not r.finished then
			-- rubber band toward the best human
			local target = 1
			if humanBest then
				local gap = humanBest - r.odo
				local k = math.clamp(gap / f.range, -1, 1)
				target = k > 0 and 1 + k * (f.max - 1) or 1 + k * (1 - f.min)
			end
			f.scale += (target - f.scale) * math.min(1, dt * 2)
			local lane = f.lane + math.sin(t * 0.4 + f.seed) * f.wander
			if f.drive or Core.humanoid(r.model) then
				local root = Core.root(r.model)
				local s = root and self.spline:project(root.Position, r.hint) or 0
				local aim = self.spline:cframe(s + f.lookahead, lane, 0).Position
				if f.drive then
					local ok, err = pcall(f.drive, r.model, aim, f.scale, dt)
					if not ok then
						warn("[GameplayKit] follower drive: " .. tostring(err))
					end
				else
					local hum = Core.humanoid(r.model)
					hum.WalkSpeed = f.speed * f.scale
					hum:MoveTo(aim)
				end
			else
				f.s = (f.s or (self.s0 + r.odo)) + f.speed * f.scale * dt
				r.model:PivotTo(self.spline:cframe(f.s % L, lane, f.height))
			end
		end
	end
end

function RaceMgr:destroy()
	self:stop()
	if self.loop then
		pcall(task.cancel, self.loop)
	end
	if self.thread then
		pcall(task.cancel, self.thread)
	end
	self.maid:Clean()
end

-- Maid-friendly aliases (maid:Give(obj) calls obj:Destroy())
RaceMgr.Destroy = RaceMgr.destroy

Race.RaceMgr = RaceMgr
return Race
