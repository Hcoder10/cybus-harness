--!nonstrict
-- GameplayKit: self-wiring, server-authoritative game systems for any genre. Configure a system with one call;
-- remotes and replication are internal (the game never creates a RemoteEvent for a kit system).
--   local GK = require(ReplicatedStorage.Kit.GameplayKit)
--   Server: GK.Rounds.new{...}, GK.Score.new{...}, GK.Collectibles.new{...}, GK.Enemy.new{...}, GK.Race.new{...} ...
--   Client: requiring the module starts the client side (collectible bob/spin, knockback); read state with
--           GK.watch("Rounds", "State", fn), player:GetAttribute("Checkpoint"), part:GetAttribute("Progress") ...
-- Every signal is s:Connect(fn) -> conn (conn:Disconnect(), Maid-friendly); handlers run isolated (task.spawn).
-- Siblings: GameplayKit_Core, _Combat, _Items, _AI, _Race, _World (all in ReplicatedStorage.Kit).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local Kit = script.Parent :: Instance
local Core = require(Kit:WaitForChild("GameplayKit_Core"))
local Combat = require(Kit:WaitForChild("GameplayKit_Combat"))
local Items = require(Kit:WaitForChild("GameplayKit_Items"))
local AI = require(Kit:WaitForChild("GameplayKit_AI"))
local Race = require(Kit:WaitForChild("GameplayKit_Race"))
local World = require(Kit:WaitForChild("GameplayKit_World"))
local Maid = require(Kit:WaitForChild("Maid"))
local Signal = Core.Signal

local GK = {}
GK.Signal = Signal
GK.Core = Core
GK.watch = Core.watch -- GK.watch(system, attr, fn) -> conn (server or client)
GK.get = Core.get -- GK.get(system, attr) -> value
GK.limiter = Core.limiter

----------------------------------------------------------------------------------------------------------------
-- Timer / stopwatch (server or client). Timer.new({duration=60 | nil (stopwatch), tick=1, name=nil (server:
-- replicate as state "Timer_<name>" attrs Remaining/Elapsed/Running)}) -> t:start(); t:pause(); t:resume();
-- t:reset(); t:elapsed(); t:remaining(); t.Tick: Signal(value); t.Finished: Signal()
----------------------------------------------------------------------------------------------------------------
local Timer = {}
Timer.__index = Timer
function Timer.new(opts)
	opts = opts or {}
	return setmetatable({
		duration = opts.duration, tickEvery = opts.tick or 1, acc = 0, running = false,
		state = (opts.name and Core.isServer) and Core.state("Timer_" .. opts.name) or nil,
		Tick = Signal.new(), Finished = Signal.new(),
	}, Timer)
end
function Timer:elapsed()
	return self.acc + (self.running and (os.clock() - self.t0) or 0)
end
function Timer:remaining()
	return self.duration and math.max(0, self.duration - self:elapsed()) or nil
end
function Timer:_sync()
	if self.state then
		self.state:SetAttribute("Elapsed", self:elapsed())
		self.state:SetAttribute("Remaining", self:remaining())
		self.state:SetAttribute("Running", self.running)
	end
end
function Timer:resume()
	if self.running then
		return
	end
	self.running = true
	self.t0 = os.clock()
	self:_sync()
	self.thread = task.spawn(function()
		while self.running do
			task.wait(self.tickEvery)
			if not self.running then
				break
			end
			local rem = self:remaining()
			self:_sync()
			self.Tick:Fire(rem or self:elapsed())
			if rem and rem <= 0 then
				self.acc, self.running = self.duration, false
				self:_sync()
				self.Finished:Fire()
			end
		end
	end)
end
Timer.start = Timer.resume
function Timer:pause()
	if self.running then
		self.acc = self:elapsed()
		self.running = false
		if self.thread and coroutine.running() ~= self.thread then
			pcall(task.cancel, self.thread)
		end
		self:_sync()
	end
end
function Timer:reset()
	self:pause()
	self.acc = 0
	self:_sync()
end
Timer.destroy = Timer.pause
-- Timer.format(seconds, centis=false) -> "m:ss" or "m:ss.cc"
function Timer.format(s, centis)
	s = math.max(0, s or 0)
	local m = math.floor(s / 60)
	local r = s - m * 60
	if centis then
		return string.format("%d:%05.2f", m, r)
	end
	return string.format("%d:%02d", m, math.floor(r))
end
GK.Timer = Timer

----------------------------------------------------------------------------------------------------------------
-- Rounds: Lobby -> Countdown -> Playing -> Results -> (Lobby). State "Rounds": State, TimeLeft, Round, Reason, Players
----------------------------------------------------------------------------------------------------------------
local Rounds = {}
Rounds.__index = Rounds
-- Rounds.new({minPlayers=1, lobby=8, countdown=3, duration=120, results=6, autoStart=true, autoRestart=true,
--   lobbySpawn=CFrame|part?, arenaSpawns={CFrame|part...}? (players are teleported on start / end),
--   endWhen=fn(rounds) -> reason? (checked every second while Playing), onState=fn(state, prev),
--   onStart=fn(players), onEnd=fn(reason, players)}) -> r (r.State; r:finish(reason); r:stop(); r.participants)
function Rounds.new(opts)
	opts = opts or {}
	local self = setmetatable({
		opts = opts, State = "Idle", Round = 0, participants = {},
		state = Core.state("Rounds"),
		StateChanged = Signal.new(), -- (state, prev)
		Tick = Signal.new(), -- (timeLeft)
		Started = Signal.new(), -- (players)
		Ended = Signal.new(), -- (reason, players)
	}, Rounds)
	if opts.onState then
		self.StateChanged:Connect(opts.onState)
	end
	if opts.onStart then
		self.Started:Connect(opts.onStart)
	end
	if opts.onEnd then
		self.Ended:Connect(opts.onEnd)
	end
	if opts.autoStart ~= false then
		self:start()
	end
	return self
end
function Rounds:_set(state, timeLeft)
	local prev = self.State
	self.State = state
	if self.state then
		self.state:SetAttribute("State", state)
		self.state:SetAttribute("TimeLeft", timeLeft or 0)
		self.state:SetAttribute("Round", self.Round)
	end
	if prev ~= state then
		self.StateChanged:Fire(state, prev)
	end
end
function Rounds:_count(seconds, check)
	for t = seconds, 1, -1 do
		if self.state then
			self.state:SetAttribute("TimeLeft", t)
			self.state:SetAttribute("Players", #Players:GetPlayers())
		end
		self.Tick:Fire(t)
		task.wait(1)
		local r = check and check()
		if r then
			return r
		end
	end
	if self.state then
		self.state:SetAttribute("TimeLeft", 0)
	end
	return nil
end
local function teleport(player, at)
	local cf = Core.cframe(at)
	local ch = Core.character(player)
	if cf and ch then
		ch:PivotTo(cf + Vector3.new(0, 4, 0))
	end
end
function Rounds:start()
	if self.thread then
		return
	end
	local o = self.opts
	self.thread = task.spawn(function()
		repeat
			-- Lobby: wait for enough players, then the lobby timer
			self:_set("Lobby", o.lobby or 8)
			while #Players:GetPlayers() < (o.minPlayers or 1) do
				if self.state then
					self.state:SetAttribute("Players", #Players:GetPlayers())
				end
				task.wait(1)
			end
			local short = self:_count(o.lobby or 8, function()
				return #Players:GetPlayers() < (o.minPlayers or 1) and "short" or nil
			end)
			if not short then
				self:_set("Countdown", o.countdown or 3)
				self:_count(o.countdown or 3)
				self.Round += 1
				self.participants = {}
				for i, p in ipairs(Players:GetPlayers()) do
					table.insert(self.participants, p)
					local spawns = o.arenaSpawns
					if spawns and #spawns > 0 then
						teleport(p, spawns[(i - 1) % #spawns + 1])
					end
				end
				self.reason = nil
				self:_set("Playing", o.duration or 120)
				self.Started:Fire(self.participants)
				local reason = self:_count(o.duration or 120, function()
					if self.reason then
						return self.reason
					end
					return o.endWhen and o.endWhen(self) or nil
				end) or "time"
				if self.state then
					self.state:SetAttribute("Reason", reason)
				end
				self:_set("Results", o.results or 6)
				self.Ended:Fire(reason, self.participants)
				self:_count(o.results or 6)
				if o.lobbySpawn then
					for _, p in ipairs(Players:GetPlayers()) do
						teleport(p, o.lobbySpawn)
					end
				end
			end
		until o.autoRestart == false and not short
		self:_set("Idle", 0)
		self.thread = nil
	end)
end
-- r:finish(reason="finished") ends the current Playing phase at the next second
function Rounds:finish(reason)
	if self.State == "Playing" then
		self.reason = reason or "finished"
	end
end
function Rounds:stop()
	if self.thread then
		pcall(task.cancel, self.thread)
		self.thread = nil
	end
	self:_set("Idle", 0)
end
Rounds.destroy = Rounds.stop
GK.Rounds = Rounds

----------------------------------------------------------------------------------------------------------------
-- Score / leaderboard: leaderstats IntValues + sorted ranking. State "Score": Top (JSON top 10 of the primary stat);
-- player attribute "Rank".
----------------------------------------------------------------------------------------------------------------
local Score = {}
Score.__index = Score
-- Score.new({stats={"Score"} (first = primary, shown first), start=0, descending=true, leaderstats=true})
function Score.new(opts)
	opts = opts or {}
	local self = setmetatable({
		stats = opts.stats or { "Score" }, start = opts.start or 0, descending = opts.descending ~= false,
		leaderstats = opts.leaderstats ~= false, values = setmetatable({}, { __mode = "k" }),
		state = Core.state("Score"), maid = Maid.new(),
		Changed = Signal.new(), -- (player, stat, value)
	}, Score)
	self.primary = self.stats[1]
	local function join(p)
		local v = {}
		self.values[p] = v
		local ls
		if self.leaderstats then
			ls = p:FindFirstChild("leaderstats") or Instance.new("Folder")
			ls.Name = "leaderstats"
			ls.Parent = p
		end
		for _, stat in ipairs(self.stats) do
			v[stat] = self.start
			if ls then
				local iv = ls:FindFirstChild(stat) or Instance.new("IntValue")
				iv.Name = stat
				iv.Value = self.start
				iv.Parent = ls
			end
		end
		self:_rank()
	end
	for _, p in ipairs(Players:GetPlayers()) do
		join(p)
	end
	self.maid:Give(Players.PlayerAdded:Connect(join))
	self.maid:Give(Players.PlayerRemoving:Connect(function(p)
		self.values[p] = nil
		self:_rank()
	end))
	return self
end
function Score:get(player, stat)
	local v = self.values[player]
	return v and v[stat or self.primary] or 0
end
function Score:set(player, value, stat)
	stat = stat or self.primary
	local v = self.values[player]
	if not v then
		return
	end
	v[stat] = value
	local ls = player:FindFirstChild("leaderstats")
	local iv = ls and ls:FindFirstChild(stat)
	if iv then
		iv.Value = math.floor(value)
	end
	self.Changed:Fire(player, stat, value)
	self:_rank()
end
-- s:add(player, n=1, stat=primary) -> new value
function Score:add(player, n, stat)
	local new = self:get(player, stat) + (n or 1)
	self:set(player, new, stat)
	return new
end
-- s:ranking(stat=primary) -> { {player, name, value, rank} } best first
function Score:ranking(stat)
	stat = stat or self.primary
	local rows = {}
	for p, v in pairs(self.values) do
		if p.Parent then
			table.insert(rows, { player = p, name = p.DisplayName, value = v[stat] or 0 })
		end
	end
	table.sort(rows, function(a, b)
		if a.value == b.value then
			return a.name < b.name
		end
		if self.descending then
			return a.value > b.value
		end
		return a.value < b.value
	end)
	for i, r in ipairs(rows) do
		r.rank = i
	end
	return rows
end
function Score:_rank()
	if self.pending then
		return
	end
	self.pending = true
	task.defer(function()
		self.pending = false
		local rows = self:ranking()
		local top = {}
		for i, r in ipairs(rows) do
			r.player:SetAttribute("Rank", i)
			if i <= 10 then
				top[i] = { name = r.name, value = r.value, rank = i, userId = r.player.UserId }
			end
		end
		if self.state then
			self.state:SetAttribute("Top", Core.encode(top))
		end
	end)
end
function Score:reset()
	for p in pairs(self.values) do
		for _, stat in ipairs(self.stats) do
			self:set(p, self.start, stat)
		end
	end
end
function Score:destroy()
	self.maid:Clean()
end
GK.Score = Score

----------------------------------------------------------------------------------------------------------------
-- Objectives / quests. State "Objectives": List (JSON {id,text,goal}); player attrs Obj_<id> (progress),
-- ObjDone (count), ObjCurrent (sequential mode)
----------------------------------------------------------------------------------------------------------------
local Objectives = {}
Objectives.__index = Objectives
-- Objectives.new({list={ {id="coins", text="Collect 10 coins", goal=10, reward=fn(player)?}, ... },
--   sequential=false (only the current one advances), onComplete=fn(player, id), onAll=fn(player)})
function Objectives.new(opts)
	opts = opts or {}
	local self = setmetatable({
		list = opts.list or {}, sequential = opts.sequential or false, byId = {},
		data = setmetatable({}, { __mode = "k" }), state = Core.state("Objectives"),
		Progress = Signal.new(), -- (player, id, value, goal)
		Completed = Signal.new(), -- (player, id)
		AllCompleted = Signal.new(), -- (player)
	}, Objectives)
	local rows = {}
	for i, q in ipairs(self.list) do
		q.goal = q.goal or 1
		self.byId[q.id] = q
		rows[i] = { id = q.id, text = q.text or q.id, goal = q.goal }
	end
	if self.state then
		self.state:SetAttribute("List", Core.encode(rows))
	end
	if opts.onComplete then
		self.Completed:Connect(opts.onComplete)
	end
	if opts.onAll then
		self.AllCompleted:Connect(opts.onAll)
	end
	return self
end
function Objectives:_d(player)
	local d = self.data[player]
	if not d then
		d = { done = 0, cur = 1 }
		self.data[player] = d
		if self.list[1] then
			player:SetAttribute("ObjCurrent", self.list[1].id)
		end
	end
	return d
end
function Objectives:get(player, id)
	return self:_d(player)[id] or 0
end
function Objectives:isComplete(player, id)
	local q = self.byId[id]
	return q ~= nil and self:get(player, id) >= q.goal
end
-- o:set(player, id, value)
function Objectives:set(player, id, value)
	local q = self.byId[id]
	if not q then
		return
	end
	local d = self:_d(player)
	if self.sequential and self.list[d.cur] ~= q then
		return
	end
	local was = (d[id] or 0) >= q.goal
	value = math.clamp(value, 0, q.goal)
	d[id] = value
	player:SetAttribute("Obj_" .. id, value)
	self.Progress:Fire(player, id, value, q.goal)
	if not was and value >= q.goal then
		d.done += 1
		player:SetAttribute("ObjDone", d.done)
		if q.reward then
			task.spawn(q.reward, player)
		end
		self.Completed:Fire(player, id)
		if self.sequential then
			d.cur += 1
			player:SetAttribute("ObjCurrent", self.list[d.cur] and self.list[d.cur].id or nil)
		end
		if d.done >= #self.list then
			self.AllCompleted:Fire(player)
		end
	end
end
-- o:progress(player, id, n=1)
function Objectives:progress(player, id, n)
	self:set(player, id, self:get(player, id) + (n or 1))
end
function Objectives:reset(player)
	self.data[player] = nil
	for _, q in ipairs(self.list) do
		player:SetAttribute("Obj_" .. q.id, 0)
	end
	player:SetAttribute("ObjDone", 0)
	self:_d(player)
end
-- Client: Objectives.client() -> {list() -> {{id,text,goal,progress,done}}, Changed: Signal()}
function Objectives.client()
	local player = Players.LocalPlayer
	local h = { Changed = Signal.new() }
	function h.list()
		local rows = Core.decode(Core.get("Objectives", "List")) or {}
		for _, r in ipairs(rows) do
			r.progress = player and player:GetAttribute("Obj_" .. r.id) or 0
			r.done = r.progress >= r.goal
		end
		return rows
	end
	if player then
		player.AttributeChanged:Connect(function(name)
			if name:sub(1, 4) == "Obj_" or name == "ObjCurrent" then
				h.Changed:Fire()
			end
		end)
	end
	return h
end
GK.Objectives = Objectives

----------------------------------------------------------------------------------------------------------------
-- Re-exports
----------------------------------------------------------------------------------------------------------------
GK.Health = Combat.Health -- Health.new(target, opts); Health.of(x); Health.damage(x, n, source, opts); Health.players(opts)
GK.Teams = Combat.Teams
GK.Checkpoints = Combat.Checkpoints
GK.Weapon = Combat.Weapon
GK.knockback = Combat.knockback
GK.hitscan = Combat.hitscan
GK.hitbox = Combat.hitbox
GK.sphere = Combat.sphere
GK.sameTeam = Combat.sameTeam
GK.Collectibles = Items.Collectibles
GK.prompt = Items.prompt
GK.Carry = Items.Carry
GK.Station = Items.Station
GK.Recipes = Items.Recipes
GK.Inventory = Items.Inventory
GK.Enemy = AI.Enemy
GK.Spawner = AI.Spawner
GK.rig = AI.rig
GK.Race = Race -- Race.new(opts) -> race; race:addFollower(model, opts); Race.Spline.new(points)
GK.Mover = World.Mover
GK.Door = World.Door
GK.Hazard = World.Hazard

----------------------------------------------------------------------------------------------------------------
-- Client side: collectible bob/spin + knockback receiver. Runs automatically when a client requires this module.
----------------------------------------------------------------------------------------------------------------
local clientStarted = false
function GK.startClient()
	if clientStarted or not Core.isClient then
		return
	end
	clientStarted = true
	task.spawn(function()
		local remote = Core.remote("Knockback")
		if remote then
			remote.OnClientEvent:Connect(function(v)
				local _, root, hum = Core.character(Players.LocalPlayer)
				if root and typeof(v) == "Vector3" and v.Magnitude < 500 then
					hum:ChangeState(Enum.HumanoidStateType.Freefall)
					root.AssemblyLinearVelocity += v
				end
			end)
		end
	end)
	task.spawn(function()
		local remote = Core.remote("Carry")
		local UserInputService = game:GetService("UserInputService")
		if not remote then
			return
		end
		UserInputService.InputBegan:Connect(function(input, processed)
			local player = Players.LocalPlayer
			if processed or not player or player:GetAttribute("Holding") == nil then
				return
			end
			if input.KeyCode == Enum.KeyCode.G then
				remote:FireServer("drop")
			elseif input.KeyCode == Enum.KeyCode.R then
				remote:FireServer("throw")
			end
		end)
	end)
	local items = {}
	local function add(inst)
		items[inst] = math.random() * 10
	end
	for _, inst in ipairs(CollectionService:GetTagged("GK_Collectible")) do
		add(inst)
	end
	CollectionService:GetInstanceAddedSignal("GK_Collectible"):Connect(add)
	CollectionService:GetInstanceRemovedSignal("GK_Collectible"):Connect(function(inst)
		items[inst] = nil
	end)
	RunService.RenderStepped:Connect(function()
		local t = os.clock()
		for inst, phase in pairs(items) do
			local base = inst:GetAttribute("GKBase")
			if typeof(base) == "CFrame" and inst.Parent then
				local y = inst:GetAttribute("GKBob") and math.sin(t * 2.2 + phase) * 0.35 or 0
				local spin = inst:GetAttribute("GKSpin") and (t * 2 + phase) or 0
				local cf = base * CFrame.new(0, y, 0) * CFrame.Angles(0, spin, 0)
				if inst:IsA("BasePart") then
					inst.CFrame = cf
				elseif inst:IsA("Model") then
					inst:PivotTo(cf)
				end
			end
		end
	end)
end

-- Maid-friendly aliases (maid:Give(obj) calls obj:Destroy())
Score.Destroy = Score.destroy
Rounds.Destroy = Rounds.destroy
Timer.Destroy = Timer.destroy

if Core.isClient then
	task.defer(GK.startClient)
end

return GK
