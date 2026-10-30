--!nonstrict
-- GameplayKit_AI: enemies / NPCs with a state machine (idle, patrol, chase, attack, flee, return), perception
-- (range + sight cone + line-of-sight raycast, plus a short hearing radius), PathfindingService with a
-- straight-line fallback, melee/ranged attacks, a default blocky rig, and a wave spawner. Server only.

local Workspace = game:GetService("Workspace")
local PathfindingService = game:GetService("PathfindingService")

local Core = require((script.Parent :: Instance):WaitForChild("GameplayKit_Core"))
local Combat = require((script.Parent :: Instance):WaitForChild("GameplayKit_Combat"))
local Maid = require((script.Parent :: Instance):WaitForChild("Maid"))
local Signal = Core.Signal
local Health = Combat.Health

local AI = {}

----------------------------------------------------------------------------------------------------------------
-- Default rig: a blocky humanoid (style="humanoid") or a squat monster (style="monster"). Limbs are welded
-- (no animation needed), Humanoid HipHeight keeps it standing; it walks with Humanoid:MoveTo.
----------------------------------------------------------------------------------------------------------------
-- AI.rig({style="humanoid"|"monster", color="#7A3BD1", accent="#FFE14D", scale=1, name="Enemy"}) -> Model
function AI.rig(o)
	o = o or {}
	local s = o.scale or 1
	local color = Core.color(o.color, Color3.fromRGB(122, 59, 209))
	local accent = Core.color(o.accent, Color3.fromRGB(255, 225, 77))
	local model = Instance.new("Model")
	model.Name = o.name or "Enemy"
	local monster = o.style == "monster"
	local legH = (monster and 1.2 or 2) * s
	local torso = monster and Vector3.new(3.4, 2.6, 2.6) * s or Vector3.new(2, 2, 1) * s
	local root = Core.part({
		Name = "HumanoidRootPart", Size = Vector3.new(2 * s, torso.Y, 1 * s), Transparency = 1, Anchored = false, CanCollide = true,
		CFrame = CFrame.new(0, legH + torso.Y / 2, 0), Parent = model,
	})
	model.PrimaryPart = root
	local function limb(name, size, offset, col, shape)
		local p = Core.part({
			Name = name, Size = size, Color = col, Material = Enum.Material.SmoothPlastic, Anchored = false,
			CanCollide = false, Massless = true, Shape = shape, CFrame = root.CFrame * offset, Parent = model,
		})
		local w = Instance.new("WeldConstraint")
		w.Part0 = root
		w.Part1 = p
		w.Parent = p
		return p
	end
	limb("Torso", torso, CFrame.new(), color)
	local headSize = (monster and 1.6 or 1.2) * s
	local headOffset = CFrame.new(0, torso.Y / 2 + headSize / 2, monster and -0.4 * s or 0)
	limb("Head", Vector3.one * headSize, headOffset, color)
	for _, x in ipairs({ -0.3, 0.3 }) do
		local eye = limb("Eye", Vector3.new(0.25, 0.25, 0.1) * s, headOffset * CFrame.new(x * headSize, 0.1 * headSize, -headSize / 2 - 0.02), accent)
		eye.Material = Enum.Material.Neon
	end
	local legX = torso.X / 2 - 0.5 * s
	for i, x in ipairs({ -legX, legX }) do
		limb(i == 1 and "LeftLeg" or "RightLeg", Vector3.new(0.9 * s, legH, 0.9 * s), CFrame.new(x, -torso.Y / 2 - legH / 2, 0), color:Lerp(Color3.new(), 0.3))
	end
	if not monster then
		for i, x in ipairs({ -1.5 * s, 1.5 * s }) do
			limb(i == 1 and "LeftArm" or "RightArm", Vector3.new(1 * s, 2 * s, 1 * s), CFrame.new(x, 0, 0), color:Lerp(Color3.new(1, 1, 1), 0.15))
		end
	end
	local hum = Instance.new("Humanoid")
	hum.RigType = Enum.HumanoidRigType.R15 -- R15 + HipHeight: the root floats at HipHeight, no Motor6D rig required
	hum.HipHeight = legH
	hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	hum.Parent = model
	return model
end

----------------------------------------------------------------------------------------------------------------
-- Targets & perception
----------------------------------------------------------------------------------------------------------------
local function defaultTargets(self)
	local out = {}
	for _, e in ipairs(Core.alivePlayers()) do
		if not Combat.sameTeam(e.character, self.model) then
			table.insert(out, e.character)
		end
	end
	return out
end

local Enemy = {}
Enemy.__index = Enemy
AI.Enemy = Enemy
local enemyWeapons = {} -- shared server-only weapons for ranged enemies, keyed by damage/range

-- Enemy.new({model=Model? (default AI.rig(rig)), rig={style, color, scale}, position=Vector3|CFrame, parent=Folder,
--   kind="melee"|"ranged", hp=100, speed=14, sight=70 (range), fov=110 (degrees), hearing=12, lose=110,
--   memory=3 (s chasing last seen position), attackRange=5 (ranged: 45), damage=10, cooldown=1.1, windup=0.25,
--   knockback=35, patrol={Vector3...} | nil (wander patrolRadius=20 around home), idleTime={1,3}, flee=0
--   (hp fraction to flee at), leash=140 (return home when this far), team="Enemies", think=0.15 (s),
--   targets=fn(enemy) -> {Model}, onAttack=fn(enemy, targetModel) (return false to skip default damage),
--   onDeath=fn(enemy, killer), onState=fn(enemy, state, prev), weapon=GameplayKit.Weapon (ranged; default hitscan)})
function Enemy.new(opts)
	opts = opts or {}
	local model = opts.model or AI.rig(opts.rig)
	local ranged = opts.kind == "ranged"
	local self = setmetatable({
		model = model,
		opts = opts,
		kind = ranged and "ranged" or "melee",
		speed = opts.speed or 14,
		sight = opts.sight or 70,
		cosHalfFov = math.cos(math.rad((opts.fov or 110) / 2)),
		hearing = opts.hearing or 12,
		lose = opts.lose or 110,
		memory = opts.memory or 3,
		attackRange = opts.attackRange or (ranged and 45 or 5),
		damage = opts.damage or 10,
		cooldown = opts.cooldown or 1.1,
		windup = opts.windup or 0.25,
		knockback = Core.opt(opts, "knockback", 35),
		patrol = opts.patrol,
		patrolRadius = opts.patrolRadius or 20,
		idleTime = opts.idleTime or { 1, 3 },
		flee = opts.flee or 0,
		leash = opts.leash or 140,
		think = opts.think or 0.15,
		targets = opts.targets or defaultTargets,
		State = "idle",
		StateChanged = Signal.new(), -- (state, prev)
		Attacked = Signal.new(), -- (targetModel)
		Died = Signal.new(), -- (killer)
		maid = Maid.new(),
		rng = Random.new(),
		lastAttack = 0,
		patrolIndex = 1,
	}, Enemy)
	model:SetAttribute("Team", opts.team or "Enemies")
	model:SetAttribute("AIState", "idle")
	local at = Core.cframe(opts.position) or CFrame.new(0, 5, 0)
	model:PivotTo(at)
	model.Parent = opts.parent or Core.folder("Enemies")
	self.home = at.Position
	self.humanoid = model:FindFirstChildOfClass("Humanoid")
	self.root = Core.root(model)
	if not self.humanoid or not self.root then
		warn("[GameplayKit] Enemy model needs a Humanoid and a root part; got " .. model:GetFullName())
	end
	if self.humanoid then
		self.humanoid.WalkSpeed = self.speed
	end
	pcall(function()
		self.root:SetNetworkOwner(nil) -- server-authoritative movement, no client can drag enemies
	end)
	self.health = Health.new(model, { max = opts.hp or 100, invuln = 0.1, destroyOnDeath = 3 })
	self.maid:Give(self.health.Died:Connect(function(killer)
		self:_setState("dead")
		self.Died:Fire(killer)
		if opts.onDeath then
			task.spawn(opts.onDeath, self, killer)
		end
		task.delay(3, function()
			self:destroy()
		end)
	end))
	if opts.onState then
		self.StateChanged:Connect(function(s, prev)
			opts.onState(self, s, prev)
		end)
	end
	if ranged then
		local key = self.damage .. "_" .. self.attackRange
		enemyWeapons[key] = enemyWeapons[key] or Combat.Weapon.new("EnemyBolt_" .. key, {
			kind = "hitscan", damage = self.damage, cooldown = 0, range = self.attackRange + 10, color = "#FF5A5A", serverOnly = true,
		})
		self.weapon = opts.weapon or enemyWeapons[key]
	end
	self.idleUntil = os.clock() + self.rng:NextNumber(self.idleTime[1], self.idleTime[2])
	self.maid:Give(task.spawn(function()
		task.wait(self.rng:NextNumber(0, self.think)) -- de-sync brains
		while self.State ~= "dead" and model.Parent do
			local ok, err = pcall(self._step, self)
			if not ok then
				warn("[GameplayKit] enemy brain: " .. tostring(err))
			end
			task.wait(self.think)
		end
	end))
	return self
end

function Enemy:_setState(s)
	if s == self.State then
		return
	end
	local prev = self.State
	self.State = s
	self.model:SetAttribute("AIState", s)
	self.path = nil
	self.StateChanged:Fire(s, prev)
end

-- returns the best visible target (closest), or nil
function Enemy:_perceive()
	local root = self.root
	local look = root.CFrame.LookVector
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local best, bestD = nil, math.huge
	for _, t in ipairs(self.targets(self)) do
		local tr = Core.root(t)
		if tr then
			local to = tr.Position - root.Position
			local d = to.Magnitude
			local range = (self.target == t) and self.lose or self.sight
			if d < bestD and d <= range then
				local inCone = d <= self.hearing or (d > 0 and look:Dot(to.Unit) >= self.cosHalfFov) or self.target == t
				if inCone then
					params.FilterDescendantsInstances = { self.model, t, Core.folder("GameplayKitFX") }
					local head = self.model:FindFirstChild("Head")
					local eye = head and head.Position or root.Position
					local hit = Workspace:Raycast(eye, tr.Position - eye, params)
					if not hit then
						best, bestD = t, d
					end
				end
			end
		end
	end
	return best, bestD
end

-- move toward a world point: pathfinding when far / blocked, straight-line steering otherwise
function Enemy:_moveTo(goal, run)
	local hum = self.humanoid
	if not hum then
		return
	end
	hum.WalkSpeed = run and self.speed or self.speed * 0.5
	local pos = self.root.Position
	local flat = Vector3.new(goal.X - pos.X, 0, goal.Z - pos.Z)
	if flat.Magnitude < 2 then
		hum:Move(Vector3.zero)
		return true
	end
	local now = os.clock()
	local direct = flat.Magnitude < 14
	if not direct then
		local p = self.path
		if not p or (p.goal - goal).Magnitude > 6 or now - p.t > 1.5 then
			p = { goal = goal, t = now, i = 2, points = nil }
			local path = PathfindingService:CreatePath({ AgentRadius = 2, AgentHeight = 5, AgentCanJump = true })
			local ok = pcall(function()
				path:ComputeAsync(pos, goal)
			end)
			if ok and path.Status == Enum.PathStatus.Success then
				p.points = path:GetWaypoints()
			end
			self.path = p
		end
		if p.points and p.points[p.i] then
			local wp = p.points[p.i]
			if (Vector3.new(wp.Position.X - pos.X, 0, wp.Position.Z - pos.Z)).Magnitude < 3 then
				p.i += 1
				wp = p.points[p.i] or wp
			end
			if wp.Action == Enum.PathWaypointAction.Jump then
				hum.Jump = true
			end
			hum:MoveTo(wp.Position)
			return false
		end
	end
	hum:MoveTo(goal) -- straight-line fallback
	return false
end

function Enemy:_face(pos)
	local r = self.root
	local flat = Vector3.new(pos.X, r.Position.Y, pos.Z)
	if (flat - r.Position).Magnitude > 0.1 then
		self.humanoid:Move(Vector3.zero)
		r.CFrame = CFrame.lookAt(r.Position, flat)
	end
end

function Enemy:_attack(target)
	local now = os.clock()
	if now - self.lastAttack < self.cooldown then
		return
	end
	self.lastAttack = now
	local tr = Core.root(target)
	if not tr then
		return
	end
	self:_face(tr.Position)
	task.delay(self.windup, function()
		if self.State == "dead" or not self.model.Parent then
			return
		end
		self.Attacked:Fire(target)
		if self.opts.onAttack and self.opts.onAttack(self, target) == false then
			return
		end
		local r2 = Core.root(target)
		if not r2 then
			return
		end
		if self.kind == "ranged" then
			self.weapon:fireFrom(self.model, (r2.Position - (self.model:FindFirstChild("Head") or self.root).Position))
		elseif (r2.Position - self.root.Position).Magnitude <= self.attackRange + 2 then -- re-check at hit time
			local dir = (r2.Position - self.root.Position) * Vector3.new(1, 0, 1)
			Health.damage(target, self.damage, self.model, { knockback = dir.Magnitude > 0 and dir.Unit * self.knockback or nil })
		end
	end)
end

function Enemy:_step()
	if not self.root or not self.humanoid or self.health.dead then
		return
	end
	local now = os.clock()
	local pos = self.root.Position
	local fromHome = (pos - self.home).Magnitude
	local hpFrac = self.health:get() / self.health.Max

	local target, dist = self:_perceive()
	if target then
		self.target = target
		self.lastSeen = now
		self.lastSeenPos = Core.root(target).Position
	elseif self.target and now - (self.lastSeen or 0) > self.memory then
		self.target = nil
	end

	if self.State == "return" then
		if fromHome < 4 then
			self.health:heal(self.health.Max)
			self:_setState("idle")
		else
			self:_moveTo(self.home, true)
		end
		return
	end
	if fromHome > self.leash then
		self.target = nil
		self:_setState("return")
		return
	end
	if self.target and self.flee > 0 and hpFrac <= self.flee then
		self:_setState("flee")
		local away = pos - (self.lastSeenPos or pos)
		away = away.Magnitude > 0.1 and away.Unit or self.root.CFrame.LookVector * -1
		self:_moveTo(pos + away * 20, true)
		return
	end
	if self.target then
		local tr = Core.root(self.target)
		if target and dist <= self.attackRange then
			self:_setState("attack")
			if self.kind == "melee" then
				self.humanoid:MoveTo(tr.Position)
			end
			self:_attack(self.target)
		else
			self:_setState("chase")
			self:_moveTo(target and tr.Position or self.lastSeenPos, true)
		end
		return
	end
	-- calm: idle <-> patrol
	if self.State ~= "idle" and self.State ~= "patrol" then
		self:_setState("idle")
		self.idleUntil = now + self.rng:NextNumber(self.idleTime[1], self.idleTime[2])
	end
	if self.State == "idle" then
		self.humanoid:Move(Vector3.zero)
		if now >= self.idleUntil then
			if self.patrol and #self.patrol > 0 then
				self.goal = Core.position(self.patrol[self.patrolIndex])
				self.patrolIndex = self.patrolIndex % #self.patrol + 1
			else
				local a = self.rng:NextNumber(0, math.pi * 2)
				local r = self.rng:NextNumber(0.3, 1) * self.patrolRadius
				self.goal = self.home + Vector3.new(math.cos(a) * r, 0, math.sin(a) * r)
			end
			self.patrolStart = now
			self:_setState("patrol")
		end
	elseif self.State == "patrol" then
		if not self.goal or self:_moveTo(self.goal, false) or now - (self.patrolStart or now) > 12 then
			self:_setState("idle")
			self.idleUntil = now + self.rng:NextNumber(self.idleTime[1], self.idleTime[2])
		end
	end
end

function Enemy:destroy()
	if self.State ~= "dead" then
		self.State = "dead"
	end
	self.maid:Clean()
	if self.model.Parent then
		self.model:Destroy()
	end
end
Enemy.Destroy = Enemy.destroy

----------------------------------------------------------------------------------------------------------------
-- Spawner with waves. State folder "Waves": Wave, Waves, Alive, Remaining, Status ("Idle"|"Spawning"|"Fighting"|
-- "Break"|"Cleared")
----------------------------------------------------------------------------------------------------------------
local Spawner = {}
Spawner.__index = Spawner
AI.Spawner = Spawner
-- Spawner.new({points={Vector3|CFrame|BasePart...} | region={center, size}, waves={ {count=4, interval=0.6,
--   enemy={...Enemy opts}}, ... } | nil (generated: waveCount=3, baseCount=3, growth=2), enemy={...} (defaults for
--   every wave), between=5 (s break between waves), maxAlive=20, autoStart=false, loop=false,
--   onWave=fn(i), onCleared=fn(i), onAllCleared=fn()})
function Spawner.new(opts)
	opts = opts or {}
	local self = setmetatable({
		opts = opts,
		points = opts.points,
		alive = {},
		Wave = 0,
		WaveStarted = Signal.new(), -- (i)
		WaveCleared = Signal.new(), -- (i)
		AllCleared = Signal.new(),
		Spawned = Signal.new(), -- (enemy)
		maid = Maid.new(),
		state = Core.state("Waves"),
	}, Spawner)
	local waves = opts.waves
	if not waves then
		waves = {}
		for i = 1, opts.waveCount or 3 do
			table.insert(waves, { count = (opts.baseCount or 3) + (i - 1) * (opts.growth or 2) })
		end
	end
	self.waves = waves
	if opts.onWave then
		self.WaveStarted:Connect(opts.onWave)
	end
	if opts.onCleared then
		self.WaveCleared:Connect(opts.onCleared)
	end
	if opts.onAllCleared then
		self.AllCleared:Connect(opts.onAllCleared)
	end
	self:_sync("Idle")
	if opts.autoStart then
		self:start()
	end
	return self
end

function Spawner:_sync(status)
	if status then
		self.status = status
	end
	local n = 0
	for _ in pairs(self.alive) do
		n += 1
	end
	self.aliveCount = n
	if self.state then
		self.state:SetAttribute("Wave", self.Wave)
		self.state:SetAttribute("Waves", #self.waves)
		self.state:SetAttribute("Alive", n)
		self.state:SetAttribute("Status", self.status)
	end
end

function Spawner:_point(i)
	local pts = self.points
	if pts and #pts > 0 then
		local p = Core.position(pts[(i - 1) % #pts + 1])
		return p + Vector3.new(math.random() * 4 - 2, 0, math.random() * 4 - 2)
	end
	local r = self.opts.region or {}
	local c, s = r.center or Vector3.new(0, 4, 0), r.size or Vector3.new(40, 0, 40)
	return c + Vector3.new((math.random() - 0.5) * s.X, 0, (math.random() - 0.5) * s.Z)
end

-- sp:spawn(enemyOpts?, position?) -> enemy
function Spawner:spawn(eopts, position)
	local o = table.clone(self.opts.enemy or {})
	for k, v in pairs(eopts or {}) do
		o[k] = v
	end
	o.position = position or o.position or self:_point(math.random(1, 64))
	local e = Enemy.new(o)
	self.alive[e] = true
	e.Died:Connect(function()
		self.alive[e] = nil
		self:_sync()
		if self.status == "Fighting" and self.aliveCount == 0 and self._clear then
			self._clear()
		end
	end)
	self.maid:Give(e)
	self:_sync()
	self.Spawned:Fire(e)
	return e
end

function Spawner:start()
	if self.thread then
		return
	end
	self.thread = task.spawn(function()
		repeat
			for i, w in ipairs(self.waves) do
				self.Wave = i
				self:_sync("Spawning")
				self.WaveStarted:Fire(i)
				for k = 1, w.count or 3 do
					while self.aliveCount >= (self.opts.maxAlive or 20) do
						task.wait(0.5)
					end
					self:spawn(w.enemy, self:_point(k))
					task.wait(w.interval or 0.6)
				end
				self:_sync("Fighting")
				if self.aliveCount > 0 then
					local th = coroutine.running()
					self._clear = function()
						self._clear = nil
						task.spawn(th)
					end
					coroutine.yield()
				end
				self.WaveCleared:Fire(i)
				if i < #self.waves then
					self:_sync("Break")
					task.wait(self.opts.between or 5)
				end
			end
			self:_sync("Cleared")
			self.AllCleared:Fire()
		until not self.opts.loop
		self.thread = nil
	end)
end

function Spawner:stop()
	if self.thread then
		pcall(task.cancel, self.thread)
		self.thread = nil
	end
	self._clear = nil
	self.maid:Clean()
	table.clear(self.alive)
	self:_sync("Idle")
end
Spawner.destroy = Spawner.stop
Spawner.Destroy = Spawner.stop

return AI
