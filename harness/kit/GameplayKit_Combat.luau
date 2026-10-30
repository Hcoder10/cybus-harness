--!nonstrict
-- GameplayKit_Combat: health & damage, teams, checkpoints / respawn / fall death, knockback, weapons with server
-- hit validation (hitscan, projectile, melee hitboxes). Server-authoritative; use through GameplayKit.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local TeamsService = game:GetService("Teams")
local Debris = game:GetService("Debris")

local Core = require((script.Parent :: Instance):WaitForChild("GameplayKit_Core"))
local Maid = require((script.Parent :: Instance):WaitForChild("Maid"))
local Signal = Core.Signal

local Combat = {}

----------------------------------------------------------------------------------------------------------------
-- Teams. Players use the Teams service; NPC models carry a "Team" attribute.
----------------------------------------------------------------------------------------------------------------
local function teamOf(x)
	if typeof(x) ~= "Instance" then
		return nil
	end
	if x:IsA("Player") then
		return x:GetAttribute("Team") or (x.Team and x.Team.Name)
	end
	local p = Core.playerOf(x)
	if p then
		return p:GetAttribute("Team") or (p.Team and p.Team.Name)
	end
	local m = Core.modelOf(x) or x
	return m:GetAttribute("Team")
end
Combat.teamOf = teamOf

local function sameTeam(a, b)
	local ta, tb = teamOf(a), teamOf(b)
	return ta ~= nil and ta == tb
end
Combat.sameTeam = sameTeam

local Teams = {}
Teams.__index = Teams
-- Teams.new({teams={{name="Red", color=BrickColor.new("Bright red")}, ...}, autoAssign=true, balance=true,
--            friendlyFire=false})
function Teams.new(opts)
	opts = opts or {}
	local self = setmetatable({ maid = Maid.new(), byName = {}, Changed = Signal.new() }, Teams)
	self.friendlyFire = Core.opt(opts, "friendlyFire", false)
	Combat.friendlyFire = self.friendlyFire
	local defs = opts.teams or { { name = "Red", color = BrickColor.new("Bright red") }, { name = "Blue", color = BrickColor.new("Bright blue") } }
	for _, d in ipairs(defs) do
		local t = TeamsService:FindFirstChild(d.name)
		if not t then
			t = Instance.new("Team")
			t.Name = d.name
			t.TeamColor = typeof(d.color) == "BrickColor" and d.color or BrickColor.random()
			t.AutoAssignable = false
			t.Parent = TeamsService
			self.maid:Give(t)
		end
		self.byName[d.name] = t
		table.insert(self, t)
	end
	if Core.opt(opts, "autoAssign", true) then
		local function assign(p)
			if not p:GetAttribute("Team") then
				self:assign(p, nil)
			end
		end
		for _, p in ipairs(Players:GetPlayers()) do
			assign(p)
		end
		self.maid:Give(Players.PlayerAdded:Connect(assign))
	end
	return self
end
-- t:assign(player, name?) (nil = smallest team)
function Teams:assign(player, name)
	local team = name and self.byName[name]
	if not team then
		local best, n = nil, math.huge
		for _, t in ipairs(self) do
			local c = #t:GetPlayers()
			if c < n then
				best, n = t, c
			end
		end
		team = best
	end
	if team then
		player.Team = team
		player.Neutral = false
		player:SetAttribute("Team", team.Name)
		self.Changed:Fire(player, team.Name)
	end
	return team and team.Name
end
function Teams:of(x)
	return teamOf(x)
end
function Teams:sameTeam(a, b)
	return sameTeam(a, b)
end
function Teams:members(name)
	local t = self.byName[name]
	return t and t:GetPlayers() or {}
end
function Teams:destroy()
	self.maid:Clean()
end
Combat.Teams = Teams

----------------------------------------------------------------------------------------------------------------
-- Health. Wraps a Humanoid (Humanoid.Health) or gives any Model/Part custom HP (attributes HP / MaxHP).
-- The target always carries attributes HP, MaxHP (and Invulnerable while i-framed) so any UI can read them.
----------------------------------------------------------------------------------------------------------------
local registry = setmetatable({}, { __mode = "k" })

local Health = {}
Health.__index = Health

-- Health.new(target, {max=100, regen=0 (hp/s), regenDelay=3, invuln=0.4 (s of i-frames after a hit),
--   destroyOnDeath=false (custom-HP targets) | seconds, team=nil, onDeath=fn(source), onDamage=fn(amount, source)})
function Health.new(target, opts)
	opts = opts or {}
	if registry[target] then
		return registry[target]
	end
	local self = setmetatable({
		target = target,
		humanoid = target:IsA("Model") and target:FindFirstChildOfClass("Humanoid") or nil,
		Max = opts.max or 100,
		invuln = Core.opt(opts, "invuln", 0.4),
		regen = opts.regen or 0,
		regenDelay = opts.regenDelay or 3,
		destroyOnDeath = opts.destroyOnDeath,
		lastHit = 0,
		iUntil = 0,
		dead = false,
		Changed = Signal.new(), -- (hp, max)
		Damaged = Signal.new(), -- (amount, source, hitPosition?)
		Died = Signal.new(), -- (source)
		maid = Maid.new(),
	}, Health)
	registry[target] = self
	if opts.team then
		target:SetAttribute("Team", opts.team)
	end
	if self.humanoid then
		local h = self.humanoid
		if opts.max then -- explicit max resets the humanoid; wrapping an existing one keeps its current health
			h.MaxHealth = opts.max
			h.Health = opts.max
		end
		self.Max = h.MaxHealth
		self.maid:Give(h.HealthChanged:Connect(function(hp)
			target:SetAttribute("HP", hp)
			self.Changed:Fire(hp, self.Max)
			if hp <= 0 and not self.dead then
				self:_die(self.lastSource)
			end
		end))
	end
	target:SetAttribute("MaxHP", self.Max)
	target:SetAttribute("HP", self.humanoid and self.humanoid.Health or self.Max)
	if opts.onDeath then
		self.Died:Connect(opts.onDeath)
	end
	if opts.onDamage then
		self.Damaged:Connect(opts.onDamage)
	end
	if self.regen > 0 then
		self.maid:Give(Core.every(0.5, function(dt)
			if not self.dead and os.clock() - self.lastHit > self.regenDelay and self:get() < self.Max then
				self:heal(self.regen * dt)
			end
			return target.Parent ~= nil
		end))
	end
	self.maid:Give(target.AncestryChanged:Connect(function(_, parent)
		if not parent then
			self:destroy()
		end
	end))
	return self
end

function Health:get()
	if self.humanoid then
		return self.humanoid.Health
	end
	return self.target:GetAttribute("HP") or 0
end

function Health:_set(hp)
	hp = math.clamp(hp, 0, self.Max)
	if self.humanoid then
		self.humanoid.Health = hp -- HealthChanged mirrors the attribute + fires Changed
	else
		self.target:SetAttribute("HP", hp)
		self.Changed:Fire(hp, self.Max)
		if hp <= 0 and not self.dead then
			self:_die(self.lastSource)
		end
	end
end

function Health:isInvulnerable()
	if os.clock() < self.iUntil then
		return true
	end
	return self.target:FindFirstChildOfClass("ForceField") ~= nil or self.target:GetAttribute("God") == true
end

-- h:damage(amount, source?, {ignoreInvuln, knockback=Vector3, hitPosition}) -> applied amount
local function applyDamage(self, amount, source, o)
	o = o or {}
	if self.dead or amount <= 0 then
		return 0
	end
	if not o.ignoreInvuln and self:isInvulnerable() then
		return 0
	end
	if source and not Combat.friendlyFire and source ~= self.target and sameTeam(source, self.target) then
		return 0
	end
	local before = self:get()
	self.lastSource = source
	self.lastHit = os.clock()
	if self.invuln > 0 then
		self.iUntil = os.clock() + self.invuln
		self.target:SetAttribute("Invulnerable", true)
		task.delay(self.invuln, function()
			if os.clock() >= self.iUntil and self.target.Parent then
				self.target:SetAttribute("Invulnerable", nil)
			end
		end)
	end
	self:_set(before - amount)
	local applied = before - self:get()
	self.Damaged:Fire(applied, source, o.hitPosition)
	if o.knockback then
		Combat.knockback(self.target, o.knockback)
	end
	return applied
end

function Health:heal(amount)
	if not self.dead then
		self:_set(self:get() + amount)
	end
end

function Health:revive(hp)
	self.dead = false
	self:_set(hp or self.Max)
end

function Health:kill(source)
	self.lastSource = source
	self:_set(0)
end

function Health:_die(source)
	self.dead = true
	self.target:SetAttribute("Dead", true)
	self.Died:Fire(source)
	local d = self.destroyOnDeath
	if d and not self.humanoid then
		task.delay(type(d) == "number" and d or 0, function()
			if self.target.Parent then
				self.target:Destroy()
			end
		end)
	end
end

function Health:destroy()
	registry[self.target] = nil
	self.maid:Clean()
end

-- Health.of(partOrModel) -> health component (auto-wraps any Humanoid it finds), or nil
function Health.of(inst)
	if not inst then
		return nil
	end
	local m = Core.modelOf(inst)
	if not m then
		return nil
	end
	local h = registry[m]
	if h then
		return h
	end
	local hum = m:IsA("Model") and m:FindFirstChildOfClass("Humanoid")
	if hum then
		return Health.new(m, {})
	end
	return nil
end

-- Health.damage(partOrModel, amount, source?, opts?) -> applied amount (0 if not damageable). Also h:damage(...).
function Health.damage(inst, amount, source, o)
	if getmetatable(inst) == Health then
		return applyDamage(inst, amount, source, o)
	end
	local h = Health.of(inst)
	return h and applyDamage(h, amount, source, o) or 0
end

-- Health.players({max=100, regen=0, invuln=1, ...}) -> wraps every player's character on spawn
function Health.players(opts)
	local maid = Maid.new()
	local function wrap(ch)
		ch:WaitForChild("Humanoid", 10)
		if ch.Parent then
			local o = table.clone(opts or {})
			o.invuln = Core.opt(opts, "invuln", 1)
			Health.new(ch, o)
		end
	end
	local function hook(p)
		if p.Character then
			task.spawn(wrap, p.Character)
		end
		maid:Give(p.CharacterAdded:Connect(wrap))
	end
	for _, p in ipairs(Players:GetPlayers()) do
		hook(p)
	end
	maid:Give(Players.PlayerAdded:Connect(hook))
	return maid
end
Combat.Health = Health

----------------------------------------------------------------------------------------------------------------
-- Knockback. NPCs (server-owned) get velocity directly; player characters are client-owned, so the push is sent
-- to that client (GameplayKit.startClient applies it).
----------------------------------------------------------------------------------------------------------------
local knockRemote = Core.isServer and Core.remote("Knockback") or nil
-- Combat.knockback(target, velocity: Vector3, upward=0.35)  velocity in studs/s; upward adds a hop
function Combat.knockback(target, velocity, upward)
	local m = Core.modelOf(target) or target
	local root = Core.root(m)
	if not root or typeof(velocity) ~= "Vector3" then
		return
	end
	local v = velocity + Vector3.new(0, velocity.Magnitude * (upward or 0.35), 0)
	local player = m:IsA("Model") and Players:GetPlayerFromCharacter(m)
	if player and knockRemote then
		knockRemote:FireClient(player, v)
	elseif not root.Anchored then
		root.AssemblyLinearVelocity += v
		local hum = Core.humanoid(m)
		if hum then
			hum:ChangeState(Enum.HumanoidStateType.Freefall)
		end
	end
end

----------------------------------------------------------------------------------------------------------------
-- Spatial hit queries
----------------------------------------------------------------------------------------------------------------
-- Combat.hitscan(origin, direction (unit or scaled), range=300, ignore={instances}) -> RaycastResult?
function Combat.hitscan(origin, direction, range, ignore)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore or {}
	params.IgnoreWater = true
	return Workspace:Raycast(origin, direction.Unit * (range or 300), params)
end

-- Combat.hitbox(cframe, size, ignore) -> { model } : damageable models whose parts overlap the box (each once)
function Combat.hitbox(cframe, size, ignore)
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore or {}
	local seen, out = {}, {}
	for _, part in ipairs(Workspace:GetPartBoundsInBox(cframe, size, params)) do
		local m = Core.modelOf(part)
		if m and not seen[m] then
			seen[m] = true
			table.insert(out, m)
		end
	end
	return out
end

-- Combat.sphere(position, radius, ignore) -> { model }
function Combat.sphere(position, radius, ignore)
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore or {}
	local seen, out = {}, {}
	for _, part in ipairs(Workspace:GetPartBoundsInRadius(position, radius, params)) do
		local m = Core.modelOf(part)
		if m and not seen[m] then
			seen[m] = true
			table.insert(out, m)
		end
	end
	return out
end

----------------------------------------------------------------------------------------------------------------
-- Weapons. Server: Weapon.new(name, opts). Client: GameplayKit.Weapon.client(name) -> w:fire(direction?) / w:fire()
-- The client only sends an aim direction; the server re-derives the origin from the character, enforces the
-- cooldown, range and line of sight, and applies damage. NPCs fire with w:fireFrom(model, direction).
----------------------------------------------------------------------------------------------------------------
local projectiles = {}
local projectileConn

local function stepProjectiles(dt)
	for i = #projectiles, 1, -1 do
		local pr = projectiles[i]
		pr.age += dt
		local step = pr.velocity * dt
		local hit = Combat.hitscan(pr.position, step, step.Magnitude + pr.radius, pr.ignore)
		local done = pr.age > pr.lifetime
		if hit then
			pr.weapon:_impact(pr.owner, hit.Instance, hit.Position, pr.velocity.Unit)
			done = true
		else
			pr.position += step
			pr.velocity += Vector3.new(0, -Workspace.Gravity * pr.gravity * dt, 0)
			if pr.visual then
				pr.visual.CFrame = CFrame.lookAt(pr.position, pr.position + pr.velocity)
			end
		end
		if done then
			if pr.visual then
				pr.visual:Destroy()
			end
			table.remove(projectiles, i)
		end
	end
	if #projectiles == 0 and projectileConn then
		projectileConn:Disconnect()
		projectileConn = nil
	end
end

local Weapon = {}
Weapon.__index = Weapon
-- Weapon.new(name, {kind="hitscan"|"projectile"|"melee", damage=20, cooldown=0.25, range=300 (melee: 7),
--   speed=150 (projectile studs/s), gravity=0 (fraction of Workspace.Gravity), radius=0.5, lifetime=3,
--   arc=Vector3.new(6,6,7) (melee box size), headshot=1.5, knockback=0 (studs/s), friendlyFire=false,
--   color="#FFD45A", tracer=true, serverOnly=false (true: NPC-only, no client remote), onHit=fn(attacker, targetModel, damage, position), onFire=fn(attacker, origin, dir)})
function Weapon.new(name, opts)
	opts = opts or {}
	local kind = opts.kind or "hitscan"
	local self = setmetatable({
		name = name or "Weapon",
		kind = kind,
		damage = opts.damage or 20,
		cooldown = opts.cooldown or (kind == "melee" and 0.5 or 0.25),
		range = opts.range or (kind == "melee" and 7 or 300),
		speed = opts.speed or 150,
		gravity = opts.gravity or 0,
		radius = opts.radius or 0.5,
		lifetime = opts.lifetime or 3,
		arc = opts.arc or Vector3.new(6, 6, 7),
		headshot = opts.headshot or 1.5,
		knockback = opts.knockback or 0,
		friendlyFire = Core.opt(opts, "friendlyFire", false),
		color = Core.color(opts.color, Color3.fromRGB(255, 212, 90)),
		tracer = Core.opt(opts, "tracer", true),
		onHit = opts.onHit,
		onFire = opts.onFire,
		last = setmetatable({}, { __mode = "k" }),
		Hit = Signal.new(), -- (attacker, targetModel, damage, position)
		Fired = Signal.new(), -- (attacker, origin, direction)
		maid = Maid.new(),
	}, Weapon)
	if Core.isServer and not opts.serverOnly then -- serverOnly: NPC weapons that no client may trigger
		local remote = Core.remote("Weapon_" .. self.name)
		self.maid:Give(remote.OnServerEvent:Connect(function(player, direction)
			local ch = Core.character(player)
			if not ch then
				return
			end
			if typeof(direction) ~= "Vector3" or direction.Magnitude < 1e-3 or direction.Magnitude ~= direction.Magnitude then
				direction = nil
			end
			self:fireFrom(ch, direction)
		end))
	end
	return self
end

-- origin for a shooter model: its head (or root) position
local function muzzle(model)
	local head = model:FindFirstChild("Head")
	local root = Core.root(model)
	local src = (head and head:IsA("BasePart") and head) or root
	return src and src.Position
end

-- w:fireFrom(model, direction?) -> bool  (server; direction defaults to the model's look vector)
function Weapon:fireFrom(model, direction)
	local root = Core.root(model)
	if not root then
		return false
	end
	local now = os.clock()
	local last = self.last[model] or 0
	if now - last < self.cooldown * 0.85 then -- small tolerance for network jitter
		return false
	end
	self.last[model] = now
	direction = (direction or root.CFrame.LookVector).Unit
	local origin = muzzle(model)
	self.Fired:Fire(model, origin, direction)
	if self.onFire then
		task.spawn(self.onFire, model, origin, direction)
	end
	if self.kind == "melee" then
		local flat = Vector3.new(direction.X, 0, direction.Z)
		flat = flat.Magnitude > 1e-3 and flat.Unit or root.CFrame.LookVector
		local cf = CFrame.lookAt(root.Position, root.Position + flat) * CFrame.new(0, 0, -self.arc.Z / 2)
		for _, m in ipairs(Combat.hitbox(cf, self.arc, { model })) do
			local r = Core.root(m)
			self:_apply(model, m, self.damage, r and r.Position or cf.Position, flat)
		end
	elseif self.kind == "projectile" then
		local visual = Core.part({
			Name = self.name .. "Projectile",
			Shape = Enum.PartType.Ball,
			Size = Vector3.one * math.max(0.4, self.radius * 2),
			Color = self.color,
			Material = Enum.Material.Neon,
			CanCollide = false,
			CanQuery = false,
			CanTouch = false,
			CFrame = CFrame.new(origin),
			Parent = Core.folder("GameplayKitFX"),
		})
		table.insert(projectiles, {
			weapon = self, owner = model, position = origin, velocity = direction * self.speed, gravity = self.gravity,
			radius = self.radius, lifetime = self.lifetime, age = 0, ignore = { model, Core.folder("GameplayKitFX") }, visual = visual,
		})
		if not projectileConn then
			projectileConn = RunService.Heartbeat:Connect(stepProjectiles)
		end
	else
		local hit = Combat.hitscan(origin, direction, self.range, { model, Core.folder("GameplayKitFX") })
		local finish = hit and hit.Position or origin + direction * self.range
		if self.tracer then
			local len = (finish - origin).Magnitude
			local t = Core.part({
				Name = "Tracer", Size = Vector3.new(0.12, 0.12, len), Color = self.color, Material = Enum.Material.Neon,
				CanCollide = false, CanQuery = false, CanTouch = false, Transparency = 0.2,
				CFrame = CFrame.lookAt(origin, finish) * CFrame.new(0, 0, -len / 2), Parent = Core.folder("GameplayKitFX"),
			})
			Debris:AddItem(t, 0.06)
		end
		if hit then
			self:_impact(model, hit.Instance, hit.Position, direction)
		end
	end
	return true
end

function Weapon:_impact(attacker, part, position, direction)
	local m = Core.modelOf(part)
	if not m then
		return
	end
	local dmg = self.damage
	if part.Name == "Head" then
		dmg *= self.headshot
	end
	self:_apply(attacker, m, dmg, position, direction)
end

function Weapon:_apply(attacker, target, dmg, position, direction)
	if target == attacker then
		return
	end
	if not self.friendlyFire and sameTeam(attacker, target) then
		return
	end
	local kb = self.knockback > 0 and direction and Vector3.new(direction.X, 0, direction.Z).Unit * self.knockback or nil
	local applied = Health.damage(target, dmg, attacker, { knockback = kb, hitPosition = position })
	if applied > 0 then
		self.Hit:Fire(attacker, target, applied, position)
		if self.onHit then
			task.spawn(self.onHit, attacker, target, applied, position)
		end
	end
end

function Weapon:destroy()
	self.maid:Clean()
end

-- Client counterpart: Weapon.client(name) -> {fire = fn(direction?)}; direction defaults to the camera aim.
function Weapon.client(name)
	local remote = Core.remote("Weapon_" .. (name or "Weapon"))
	local w = {}
	function w.fire(a, b) -- w.fire(dir) or w:fire(dir)
		local direction = if a == w then b else a
		if not remote then
			return
		end
		if typeof(direction) ~= "Vector3" then
			local cam = Workspace.CurrentCamera
			direction = cam and cam.CFrame.LookVector or nil
		end
		remote:FireServer(direction)
	end
	return w
end
Combat.Weapon = Weapon

----------------------------------------------------------------------------------------------------------------
-- Checkpoints / respawn / fall death (obby, platformer). Touch a checkpoint part to set it; falling below
-- fallY (or dying) respawns at the last one. Player attribute "Checkpoint" = index (0 = start).
----------------------------------------------------------------------------------------------------------------
local Checkpoints = {}
Checkpoints.__index = Checkpoints
-- Checkpoints.new({parts = {BasePart} | Folder (sorted by name number), start = CFrame|part? (defaults to spawn),
--   fallY = -30 (kill plane Y; nil disables), forwardOnly = true, respawnDelay = nil (Players.RespawnTime),
--   color = "#5AE38C" (reached colour), onReached = fn(player, index)})
function Checkpoints.new(opts)
	opts = opts or {}
	local self = setmetatable({
		parts = Core.list(opts.parts or Workspace:FindFirstChild("Checkpoints"), "BasePart"),
		start = opts.start,
		fallY = Core.opt(opts, "fallY", -30),
		forwardOnly = Core.opt(opts, "forwardOnly", true),
		reachedColor = Core.color(opts.color, Color3.fromRGB(90, 227, 140)),
		index = setmetatable({}, { __mode = "k" }),
		Reached = Signal.new(), -- (player, index)
		maid = Maid.new(),
	}, Checkpoints)
	if opts.onReached then
		self.Reached:Connect(opts.onReached)
	end
	if opts.respawnDelay then
		Players.RespawnTime = opts.respawnDelay
	end
	for i, part in ipairs(self.parts) do
		part:SetAttribute("CheckpointIndex", i)
		self.maid:Give(part.Touched:Connect(function(hit)
			local p = Core.playerOf(hit)
			if p and Core.character(p) then
				self:set(p, i)
			end
		end))
	end
	local function onChar(p, ch)
		local i = self.index[p] or 0
		if i <= 0 and not self.start then
			return
		end
		local root = ch:WaitForChild("HumanoidRootPart", 10)
		if not root then
			return
		end
		task.delay(0.05, function() -- after the engine's own spawn placement
			if ch.Parent then
				ch:PivotTo(self:spawnCFrame(p))
			end
		end)
	end
	local function hook(p)
		p:SetAttribute("Checkpoint", self.index[p] or 0)
		self.maid:Give(p.CharacterAdded:Connect(function(ch)
			onChar(p, ch)
		end))
	end
	for _, p in ipairs(Players:GetPlayers()) do
		hook(p)
	end
	self.maid:Give(Players.PlayerAdded:Connect(hook))
	if self.fallY then
		self.maid:Give(Core.every(0.2, function()
			for _, e in ipairs(Core.alivePlayers()) do
				if e.root.Position.Y < self.fallY then
					self:respawn(e.player)
				end
			end
		end))
	end
	return self
end

function Checkpoints:get(player)
	return self.index[player] or 0
end

-- c:set(player, index) (forwardOnly ignores going back)
function Checkpoints:set(player, i)
	local cur = self.index[player] or 0
	if i == cur or (self.forwardOnly and i < cur) then
		return
	end
	self.index[player] = i
	player:SetAttribute("Checkpoint", i)
	local part = self.parts[i]
	if part then
		part.Color = self.reachedColor
	end
	self.Reached:Fire(player, i)
end

function Checkpoints:spawnCFrame(player)
	local i = self.index[player] or 0
	local part = self.parts[i]
	local base = part and part.CFrame or Core.cframe(self.start)
	if not base then
		local sp = Workspace:FindFirstChildWhichIsA("SpawnLocation", true)
		base = sp and sp.CFrame or CFrame.new(0, 5, 0)
	end
	local up = part and part.Size.Y / 2 or 0
	return CFrame.new(base.Position + Vector3.new(0, up + 3.5, 0)) * (base - base.Position)
end

-- c:respawn(player): instant teleport to the last checkpoint (no death), with i-frames if Health is used
function Checkpoints:respawn(player)
	local ch, root = Core.character(player)
	if not ch then
		return
	end
	root.AssemblyLinearVelocity = Vector3.zero
	ch:PivotTo(self:spawnCFrame(player))
	local h = Health.of(ch)
	if h then
		h.iUntil = os.clock() + 1
	end
end

function Checkpoints:reset(player)
	self.index[player] = 0
	player:SetAttribute("Checkpoint", 0)
end

function Checkpoints:destroy()
	self.maid:Clean()
end
Combat.Checkpoints = Checkpoints

-- Maid-friendly aliases (maid:Give(obj) calls obj:Destroy())
Teams.Destroy = Teams.destroy
Health.Destroy = Health.destroy
Weapon.Destroy = Weapon.destroy
Checkpoints.Destroy = Checkpoints.destroy

return Combat
