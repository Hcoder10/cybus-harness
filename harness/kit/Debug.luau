-- Debug: named commands the test harness runs in a live play session (Studio only), plus event and log capture.
--   Debug.register("show_shop", function() Shop.open() end, "opens the shop screen")   (client or server)
--   Debug.event("round_started", { round = 3 })       timestamped gameplay event for playtest checks
-- In Studio, the game server long-polls the harness on localhost (HttpService) for commands, runs server commands
-- itself and relays client commands to every client. None of this exists outside Studio: the relay remote and the
-- poll loop are only created when RunService:IsStudio() and the harness has set its port on ServerStorage.
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local LogService = game:GetService("LogService")

local Debug = {}
local commands = {}
local events = {}
local logs = {}
local MAX_EVENTS, MAX_LOGS = 600, 800
local REMOTE = "KitDebugRelay"
local pending = {}

local function push(list, item, max)
	table.insert(list, item)
	if #list > max then
		table.remove(list, 1)
	end
end

local function side()
	return RunService:IsServer() and "server" or "client"
end

function Debug.register(name, fn, description)
	commands[name] = { fn = fn, description = description or "" }
end

function Debug.event(name, data)
	push(events, { t = os.clock(), name = name, side = side(), data = data }, MAX_EVENTS)
	if RunService:IsClient() and RunService:IsStudio() then
		local remote = ReplicatedStorage:FindFirstChild(REMOTE)
		if remote then
			remote:FireServer("event", name, data)
		end
	end
end

function Debug.events()
	return events
end

function Debug.list()
	local out = {}
	for name, c in commands do
		out[name] = c.description
	end
	return out
end

function Debug.run(name, ...)
	local c = commands[name]
	if not c then
		return false, "unknown command " .. tostring(name)
	end
	return pcall(c.fn, ...)
end

local function encode(v)
	if type(v) == "table" then
		local ok, s = pcall(HttpService.JSONEncode, HttpService, v)
		return ok and s or tostring(v)
	end
	return tostring(v)
end

-- Run a server command, or relay it to every client and wait for their replies.
function Debug.call(name, ...)
	if commands[name] then
		local ok, result = Debug.run(name, ...)
		return { side = "server", ok = ok, result = encode(result) }
	end
	local remote = ReplicatedStorage:FindFirstChild(REMOTE)
	if not remote then
		return { ok = false, result = "no relay (not in a Studio play session)" }
	end
	local id = HttpService:GenerateGUID(false)
	pending[id] = {}
	remote:FireAllClients("run", id, name, ...)
	local deadline = os.clock() + 5
	while os.clock() < deadline and #pending[id] < math.max(1, #Players:GetPlayers()) do
		task.wait(0.05)
	end
	local replies = pending[id]
	pending[id] = nil
	local ok = #replies > 0
	for _, r in replies do
		ok = ok and r.ok
	end
	return { side = "client", ok = ok, replies = replies }
end

local function captureLogs(tag)
	local KINDS = { [Enum.MessageType.MessageError] = "error", [Enum.MessageType.MessageWarning] = "warning",
		[Enum.MessageType.MessageOutput] = "output", [Enum.MessageType.MessageInfo] = "info" }
	LogService.MessageOut:Connect(function(message, kind)
		if KINDS[kind] then
			local entry = { t = os.clock(), kind = KINDS[kind], text = string.sub(message, 1, 800), side = tag }
			push(logs, entry, MAX_LOGS)
			if RunService:IsClient() then
				local remote = ReplicatedStorage:FindFirstChild(REMOTE)
				if remote then
					remote:FireServer("log", entry)
				end
			end
		end
	end)
end

local function builtinsServer()
	Debug.register("__list", function()
		return Debug.list()
	end, "server commands")
	Debug.register("__events", function()
		return events
	end, "gameplay events from server and clients")
	Debug.register("__log", function()
		return logs
	end, "errors and warnings from server and clients")
	Debug.register("__players", function()
		local out = {}
		for _, p in Players:GetPlayers() do
			local root = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
			table.insert(out, { name = p.Name, position = root and tostring(root.Position) or "none" })
		end
		return out
	end, "players and their positions")
end

local function builtinsClient()
	Debug.register("__client_list", function()
		return Debug.list()
	end, "client commands")
	local marker
	Debug.register("__marker", function(on)
		if on then
			local pg = Players.LocalPlayer:WaitForChild("PlayerGui")
			marker = Instance.new("ScreenGui")
			marker.Name = "KitViewportMarker"
			marker.IgnoreGuiInset = true
			marker.DisplayOrder = 2147483647
			pcall(function()
				marker.ScreenInsets = Enum.ScreenInsets.None
			end)
			local f = Instance.new("Frame")
			f.BorderSizePixel = 0
			f.BackgroundColor3 = Color3.fromRGB(255, 0, 255)
			f.Size = UDim2.fromScale(1, 1)
			f.Parent = marker
			marker.Parent = pg
		elseif marker then
			marker:Destroy()
			marker = nil
		end
		local cam = workspace.CurrentCamera
		return { viewport = { cam.ViewportSize.X, cam.ViewportSize.Y } }
	end, "full-screen magenta frame for locating the viewport in screenshots")
	Debug.register("__camera", function(x, y, z, lx, ly, lz, fov)
		local cam = workspace.CurrentCamera
		if x == nil then
			cam.CameraType = Enum.CameraType.Custom
			return "camera reset"
		end
		cam.CameraType = Enum.CameraType.Scriptable
		cam.CFrame = CFrame.lookAt(Vector3.new(x, y, z), Vector3.new(lx, ly, lz))
		if fov then
			cam.FieldOfView = fov
		end
		return "camera set"
	end, "place the camera: x,y,z, lookX,lookY,lookZ, fov; no args resets")
	Debug.register("__sound_manifest", function()
		local ok, Sound = pcall(function()
			return require(ReplicatedStorage:WaitForChild("Kit"):WaitForChild("Sound"))
		end)
		return ok and Sound.manifest() or "no Sound module"
	end, "every registered sound with its load state")
	Debug.register("__stats", function()
		local frames, t0 = 0, os.clock()
		local conn = RunService.RenderStepped:Connect(function()
			frames += 1
		end)
		task.wait(1)
		conn:Disconnect()
		local Stats = game:GetService("Stats")
		return { fps = frames / (os.clock() - t0), memory_mb = Stats:GetTotalMemoryUsageMb(),
			instances = #game:GetDescendants(), viewport = tostring(workspace.CurrentCamera.ViewportSize) }
	end, "frame rate, memory and instance count on this client")
	Debug.register("__ui", function()
		local out = {}
		for _, g in Players.LocalPlayer:WaitForChild("PlayerGui"):GetChildren() do
			if g:IsA("ScreenGui") then
				table.insert(out, { name = g.Name, enabled = g.Enabled, order = g.DisplayOrder })
			end
		end
		return out
	end, "ScreenGuis on this client")
end

local function pollHarness(port, token)
	local base = "http://127.0.0.1:" .. tostring(port) .. "/cybus/"
	local function post(route, body)
		body.token = token
		return pcall(HttpService.PostAsync, HttpService, base .. route, HttpService:JSONEncode(body),
			Enum.HttpContentType.ApplicationJson)
	end
	post("hello", { place = game.PlaceId, t = os.clock() })
	local failures = 0
	while true do
		local ok, body = pcall(HttpService.GetAsync, HttpService, base .. "next?token=" .. token, true)
		if not ok then
			failures += 1
			task.wait(math.min(5, failures))
			if failures % 5 == 0 then
				post("hello", { place = game.PlaceId, t = os.clock() })
			end
			continue
		end
		failures = 0
		local decoded, cmd = pcall(HttpService.JSONDecode, HttpService, body)
		if decoded and type(cmd) == "table" and cmd.id then
			task.spawn(function()
				local result = Debug.call(cmd.name, table.unpack(cmd.args or {}))
				post("result", { id = cmd.id, result = result })
			end)
		end
	end
end

function Debug.initServer()
	if not RunService:IsStudio() or ReplicatedStorage:FindFirstChild(REMOTE) then
		return
	end
	local remote = Instance.new("RemoteEvent")
	remote.Name = REMOTE
	remote.Parent = ReplicatedStorage
	remote.OnServerEvent:Connect(function(player, kind, a, b, c)
		if kind == "reply" and pending[a] then
			table.insert(pending[a], { player = player.Name, ok = b, result = c })
		elseif kind == "event" then
			push(events, { t = os.clock(), name = tostring(a), side = "client:" .. player.Name, data = b }, MAX_EVENTS)
		elseif kind == "log" and type(a) == "table" then
			a.side = "client:" .. player.Name
			push(logs, a, MAX_LOGS)
		end
	end)
	captureLogs("server")
	builtinsServer()
	local storage = game:GetService("ServerStorage")
	local port, token = storage:GetAttribute("CybusHarnessPort"), storage:GetAttribute("CybusHarnessToken")
	if port and token then
		task.spawn(pollHarness, port, token)
	end
end

function Debug.initClient()
	if not RunService:IsStudio() then
		return
	end
	captureLogs("client")
	builtinsClient()
	local remote = ReplicatedStorage:WaitForChild(REMOTE, 15)
	if not remote then
		return
	end
	remote.OnClientEvent:Connect(function(kind, id, name, ...)
		if kind == "run" then
			local ok, result = Debug.run(name, ...)
			remote:FireServer("reply", id, ok, encode(result))
		end
	end)
end

return Debug
