--!nonstrict
-- GameplayKit_Core: shared plumbing for every GameplayKit system (signals, internal remotes, replicated state
-- folders, rate limits, character lookups, part building). Games use it through GameplayKit; you rarely need it.
--
-- Replication model (the same for every system):
--   * Server systems write ATTRIBUTES on ReplicatedStorage.GameplayKitState.<System> (whole-game state) or on the
--     Player / the model (per-player / per-object state). Clients read them with GameplayKit.watch / :GetAttribute.
--   * Client -> server requests go through RemoteEvents the kit creates itself in ReplicatedStorage.GameplayKitRemotes.
--     The game never creates or wires a remote for a kit system.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")

local Core = {}
Core.isServer = RunService:IsServer()
Core.isClient = RunService:IsClient()

----------------------------------------------------------------------------------------------------------------
-- Signal: s:Connect(fn) -> conn (conn:Disconnect(); Maid-friendly), s:Once(fn), s:Wait(), s:Fire(...)
-- Handlers run in their own thread (task.spawn), so one erroring handler never breaks the others or the caller.
----------------------------------------------------------------------------------------------------------------
local Connection = {}
Connection.__index = Connection
function Connection:Disconnect()
	if self.Connected then
		self.Connected = false
		self._signal._handlers[self] = nil
	end
end
Connection.Destroy = Connection.Disconnect

local Signal = {}
Signal.__index = Signal
function Signal.new()
	return setmetatable({ _handlers = {} }, Signal)
end
function Signal:Connect(fn)
	local c = setmetatable({ Connected = true, _signal = self, _fn = fn }, Connection)
	self._handlers[c] = true
	return c
end
function Signal:Once(fn)
	local c
	c = self:Connect(function(...)
		c:Disconnect()
		fn(...)
	end)
	return c
end
function Signal:Wait()
	local thread = coroutine.running()
	self:Once(function(...)
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end
function Signal:Fire(...)
	for c in pairs(table.clone(self._handlers)) do
		if c.Connected then
			task.spawn(c._fn, ...)
		end
	end
end
function Signal:DisconnectAll()
	for c in pairs(self._handlers) do
		c.Connected = false
	end
	table.clear(self._handlers)
end
Signal.Destroy = Signal.DisconnectAll
Core.Signal = Signal

----------------------------------------------------------------------------------------------------------------
-- Remotes and replicated state folders (created by the server, waited for by clients; nil-safe on timeout)
----------------------------------------------------------------------------------------------------------------
local function rootFolder(name)
	local f = ReplicatedStorage:FindFirstChild(name)
	if f then
		return f
	end
	if Core.isServer then
		f = Instance.new("Folder")
		f.Name = name
		f.Parent = ReplicatedStorage
		return f
	end
	return ReplicatedStorage:WaitForChild(name, 15)
end

-- Core.remote(name) -> RemoteEvent? (server creates; client waits up to 15 s)
function Core.remote(name)
	local folder = rootFolder("GameplayKitRemotes")
	if not folder then
		return nil
	end
	local r = folder:FindFirstChild(name)
	if r then
		return r
	end
	if Core.isServer then
		r = Instance.new("RemoteEvent")
		r.Name = name
		r.Parent = folder
		return r
	end
	return folder:WaitForChild(name, 15)
end

-- Core.state(name) -> Folder? whose attributes hold a system's replicated state
function Core.state(name)
	local folder = rootFolder("GameplayKitState")
	if not folder then
		return nil
	end
	local s = folder:FindFirstChild(name)
	if s then
		return s
	end
	if Core.isServer then
		s = Instance.new("Folder")
		s.Name = name
		s.Parent = folder
		return s
	end
	return folder:WaitForChild(name, 15)
end

-- Core.watch(system, attr, fn) -> conn: fn(value) now (if set) and on every change. Server or client.
function Core.watch(system, attr, fn)
	local handle = { Connected = true }
	local inner
	function handle:Disconnect()
		self.Connected = false
		if inner then
			inner:Disconnect()
		end
	end
	handle.Destroy = handle.Disconnect
	task.spawn(function()
		local folder = Core.state(system)
		if not folder or not handle.Connected then
			return
		end
		inner = folder:GetAttributeChangedSignal(attr):Connect(function()
			fn(folder:GetAttribute(attr))
		end)
		local v = folder:GetAttribute(attr)
		if v ~= nil then
			fn(v)
		end
	end)
	return handle
end

function Core.get(system, attr)
	local folder = ReplicatedStorage:FindFirstChild("GameplayKitState")
	folder = folder and folder:FindFirstChild(system)
	return folder and folder:GetAttribute(attr)
end

function Core.encode(t)
	local ok, s = pcall(HttpService.JSONEncode, HttpService, t)
	return ok and s or "[]"
end
function Core.decode(s)
	if type(s) ~= "string" or s == "" then
		return nil
	end
	local ok, t = pcall(HttpService.JSONDecode, HttpService, s)
	return ok and t or nil
end

----------------------------------------------------------------------------------------------------------------
-- Anti-exploit: token-bucket rate limiter. Core.limiter(perSecond=10, burst=perSecond) -> allow(player, key?) -> bool
----------------------------------------------------------------------------------------------------------------
function Core.limiter(perSecond, burst)
	perSecond = perSecond or 10
	burst = burst or perSecond
	local buckets = setmetatable({}, { __mode = "k" })
	return function(player, key)
		local per = buckets[player]
		if not per then
			per = {}
			buckets[player] = per
		end
		key = key or "_"
		local now = os.clock()
		local b = per[key]
		if not b then
			b = { tokens = burst, t = now }
			per[key] = b
		end
		b.tokens = math.min(burst, b.tokens + (now - b.t) * perSecond)
		b.t = now
		if b.tokens >= 1 then
			b.tokens -= 1
			return true
		end
		return false
	end
end

----------------------------------------------------------------------------------------------------------------
-- Characters and models
----------------------------------------------------------------------------------------------------------------
function Core.root(model)
	if not model then
		return nil
	end
	if model:IsA("BasePart") then
		return model
	end
	if not model:IsA("Model") then
		return nil
	end
	return model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
end

function Core.humanoid(model)
	return model and model:FindFirstChildOfClass("Humanoid")
end

-- Core.character(player) -> (character, root, humanoid) only while alive, else nil
function Core.character(player)
	local ch = player and player.Character
	if not ch or not ch.Parent then
		return nil
	end
	local hum = ch:FindFirstChildOfClass("Humanoid")
	local root = ch:FindFirstChild("HumanoidRootPart")
	if not hum or not root or hum.Health <= 0 then
		return nil
	end
	return ch, root, hum
end

-- Core.alivePlayers() -> { {player, character, root, humanoid} }
function Core.alivePlayers()
	local out = {}
	for _, p in ipairs(Players:GetPlayers()) do
		local ch, root, hum = Core.character(p)
		if ch then
			table.insert(out, { player = p, character = ch, root = root, humanoid = hum })
		end
	end
	return out
end

-- Core.modelOf(part) -> the Model that owns health for this part (has a Humanoid or an "MaxHP" attribute), or nil
function Core.modelOf(inst)
	local cur = inst
	while cur and cur ~= Workspace and cur ~= game do
		if cur:IsA("Model") and (cur:FindFirstChildOfClass("Humanoid") or cur:GetAttribute("MaxHP") ~= nil) then
			return cur
		end
		if cur:IsA("BasePart") and cur:GetAttribute("MaxHP") ~= nil then
			return cur
		end
		cur = cur.Parent
	end
	return nil
end

function Core.playerOf(inst)
	local m = inst and (Core.modelOf(inst) or inst)
	if m and m:IsA("Model") then
		return Players:GetPlayerFromCharacter(m)
	end
	return nil
end

function Core.position(x)
	local t = typeof(x)
	if t == "Vector3" then
		return x
	elseif t == "CFrame" then
		return x.Position
	elseif t == "Instance" then
		if x:IsA("BasePart") then
			return x.Position
		elseif x:IsA("Model") then
			return x:GetPivot().Position
		elseif x:IsA("Attachment") then
			return x.WorldPosition
		end
	end
	return nil
end

function Core.cframe(x)
	local t = typeof(x)
	if t == "CFrame" then
		return x
	elseif t == "Vector3" then
		return CFrame.new(x)
	elseif t == "Instance" then
		if x:IsA("BasePart") then
			return x.CFrame
		elseif x:IsA("Model") then
			return x:GetPivot()
		end
	end
	return nil
end

-- Core.list(x) -> array of Instances/values: accepts an array, a Folder/Model (children sorted by name, numeric aware)
function Core.list(x, className)
	if type(x) == "table" then
		return x
	end
	if typeof(x) == "Instance" then
		local out = {}
		for _, c in ipairs(x:GetChildren()) do
			if not className or c:IsA(className) then
				table.insert(out, c)
			end
		end
		table.sort(out, function(a, b)
			local na, nb = tonumber(a.Name:match("%d+")), tonumber(b.Name:match("%d+"))
			if na and nb and na ~= nb then
				return na < nb
			end
			return a.Name < b.Name
		end)
		return out
	end
	return {}
end

function Core.color(v, fallback)
	if typeof(v) == "Color3" then
		return v
	end
	if typeof(v) == "BrickColor" then
		return v.Color
	end
	if type(v) == "string" then
		local ok, c = pcall(Color3.fromHex, v)
		if ok then
			return c
		end
	end
	return fallback
end

-- Core.part({...props}) -> anchored smooth Part (Shape is applied before Size, CFrame last)
function Core.part(props)
	local p = Instance.new(props.ClassName or "Part")
	p.Anchored = props.Anchored ~= false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if props.Shape then
		p.Shape = props.Shape
	end
	for k, v in pairs(props) do
		if k ~= "ClassName" and k ~= "Parent" and k ~= "Shape" and k ~= "CFrame" and k ~= "Anchored" then
			if k == "Color" then
				v = Core.color(v, p.Color)
			end
			p[k] = v
		end
	end
	if props.CFrame then
		p.CFrame = props.CFrame
	end
	p.Parent = props.Parent
	return p
end

function Core.folder(name, parent)
	parent = parent or Workspace
	local f = parent:FindFirstChild(name)
	if not f then
		f = Instance.new("Folder")
		f.Name = name
		f.Parent = parent
	end
	return f
end

-- Core.every(seconds, fn) -> thread: runs fn(dt) every `seconds` until fn returns false or the thread is cancelled
function Core.every(seconds, fn)
	return task.spawn(function()
		local last = os.clock()
		while true do
			task.wait(seconds)
			local now = os.clock()
			local ok, res = pcall(fn, now - last)
			last = now
			if not ok then
				warn("[GameplayKit] " .. tostring(res))
			elseif res == false then
				break
			end
		end
	end)
end

function Core.opt(opts, key, default)
	local v = opts and opts[key]
	if v == nil then
		return default
	end
	return v
end

return Core
