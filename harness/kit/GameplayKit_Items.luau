--!nonstrict
-- GameplayKit_Items: collectibles, ProximityPrompt interactables, pick-up/carry/drop/throw, stations with timed
-- processes (cook: raw -> cooking -> done -> burnt), recipes, and a slot inventory. Server-authoritative.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local CollectionService = game:GetService("CollectionService")

local Core = require((script.Parent :: Instance):WaitForChild("GameplayKit_Core"))
local Maid = require((script.Parent :: Instance):WaitForChild("Maid"))
local Signal = Core.Signal

local Items = {}

----------------------------------------------------------------------------------------------------------------
-- Collectibles
----------------------------------------------------------------------------------------------------------------
local function defaultCoin(color)
	local p = Core.part({
		Name = "Coin", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.35, 2.2, 2.2), Color = color,
		Material = Enum.Material.Neon, CanCollide = false, CanQuery = false, CastShadow = false,
	})
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = 8
	light.Brightness = 1.2
	light.Parent = p
	return p
end

local function placeItem(item, cf)
	if item:IsA("Model") then
		item:PivotTo(cf)
	else
		item.CFrame = cf
	end
end

local Collectibles = {}
Collectibles.__index = Collectibles
-- Collectibles.new({points={CFrame|Vector3|BasePart...} | region={center=Vector3, size=Vector3, count=10, seed},
--   template=BasePart|Model? (default: glowing coin), color="#FFD24A", value=1, stat="Coins" (player attribute +
--   leaderstat if score given), score=GameplayKit.Score obj?, radius=4 (pickup), magnet=0 (studs; >0 pulls items in),
--   respawn=nil|seconds, bob=true, spin=true, parent=Folder, onCollect=fn(player, value, total, item)})
-- Bob/spin run on clients (GameplayKit.startClient); collection is decided by the server only.
function Collectibles.new(opts)
	opts = opts or {}
	local self = setmetatable({
		value = opts.value or 1,
		stat = opts.stat or "Coins",
		score = opts.score,
		radius = opts.radius or 4,
		magnet = opts.magnet or 0,
		respawn = opts.respawn,
		color = Core.color(opts.color, Color3.fromRGB(255, 210, 74)),
		template = opts.template,
		bob = Core.opt(opts, "bob", true),
		spin = Core.opt(opts, "spin", true),
		parent = opts.parent or Core.folder("Collectibles"),
		items = {},
		counts = setmetatable({}, { __mode = "k" }),
		Collected = Signal.new(), -- (player, value, total, item)
		maid = Maid.new(),
	}, Collectibles)
	if opts.onCollect then
		self.Collected:Connect(opts.onCollect)
	end
	local points = opts.points or {}
	if opts.region then
		local r = Random.new(opts.region.seed or 7)
		local c, s = opts.region.center or Vector3.new(0, 3, 0), opts.region.size or Vector3.new(60, 0, 60)
		for _ = 1, opts.region.count or 10 do
			table.insert(points, c + Vector3.new(r:NextNumber(-0.5, 0.5) * s.X, r:NextNumber(-0.5, 0.5) * s.Y, r:NextNumber(-0.5, 0.5) * s.Z))
		end
	end
	for _, pt in ipairs(points) do
		local cf = Core.cframe(pt)
		if cf then
			self:spawnAt(cf)
		end
	end
	self.maid:Give(Core.every(0.1, function()
		self:_scan()
	end))
	return self
end

-- c:spawnAt(cframe) -> item
function Collectibles:spawnAt(cf)
	local item = self.template and self.template:Clone() or defaultCoin(self.color)
	for _, d in ipairs(item:IsA("Model") and item:GetDescendants() or { item }) do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
		end
	end
	placeItem(item, cf)
	item:SetAttribute("GKBase", cf)
	item:SetAttribute("GKBob", self.bob)
	item:SetAttribute("GKSpin", self.spin)
	item:SetAttribute("Value", self.value)
	CollectionService:AddTag(item, "GK_Collectible")
	item.Parent = self.parent
	self.items[item] = { cf = cf, active = true }
	self.maid:Give(item)
	return item
end

function Collectibles:_scan()
	local players = Core.alivePlayers()
	if #players == 0 then
		return
	end
	local reach = math.max(self.radius, self.magnet)
	for item, st in pairs(self.items) do
		if st.active then
			local pos = st.cf.Position
			for _, e in ipairs(players) do
				local d = (e.root.Position - pos).Magnitude
				if d <= reach then
					self:_collect(e.player, item, st, e.root, d > self.radius)
					break
				end
			end
		end
	end
end

function Collectibles:_collect(player, item, st, root, fly)
	st.active = false
	local total = (self.counts[player] or 0) + self.value
	self.counts[player] = total
	player:SetAttribute(self.stat, total)
	if self.score then
		self.score:add(player, self.value, self.stat)
	end
	self.Collected:Fire(player, self.value, total, item)
	local function hide()
		if not item.Parent then
			return
		end
		if self.respawn then
			item.Parent = nil
			task.delay(self.respawn, function()
				if self.items[item] then
					placeItem(item, st.cf)
					item.Parent = self.parent
					st.active = true
				end
			end)
		else
			self.items[item] = nil
			item:Destroy()
		end
	end
	if fly and item:IsA("BasePart") then
		local t = TweenService:Create(item, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { CFrame = root.CFrame })
		t.Completed:Once(hide)
		t:Play()
	else
		hide()
	end
end

function Collectibles:count(player)
	return self.counts[player] or 0
end

function Collectibles:remaining()
	local n = 0
	for _, st in pairs(self.items) do
		if st.active then
			n += 1
		end
	end
	return n
end

function Collectibles:clear()
	self.maid:Clean()
	table.clear(self.items)
	self.maid:Give(Core.every(0.1, function()
		self:_scan()
	end))
end

function Collectibles:destroy()
	self.maid:Clean()
	table.clear(self.items)
end
Items.Collectibles = Collectibles

----------------------------------------------------------------------------------------------------------------
-- Interactables: ProximityPrompt wrapper with a server-side distance + rate check
----------------------------------------------------------------------------------------------------------------
-- Items.prompt(part, {action="Use", object=part.Name, hold=0, distance=10, key=Enum.KeyCode.E, cooldown=0.3,
--   lineOfSight=false, onUse=fn(player, part)}) -> h {prompt, Used: Signal(player, part), destroy()}
function Items.prompt(part, opts)
	opts = opts or {}
	local pp = Instance.new("ProximityPrompt")
	pp.ActionText = opts.action or "Use"
	pp.ObjectText = opts.object or part.Name
	pp.HoldDuration = opts.hold or 0
	pp.MaxActivationDistance = opts.distance or 10
	pp.KeyboardKeyCode = opts.key or Enum.KeyCode.E
	pp.RequiresLineOfSight = Core.opt(opts, "lineOfSight", false)
	pp.Parent = part
	local h = { prompt = pp, Used = Signal.new(), maid = Maid.new() }
	h.maid:Give(pp)
	local cooldown = opts.cooldown or 0.3
	local last = setmetatable({}, { __mode = "k" })
	h.maid:Give(pp.Triggered:Connect(function(player)
		local _, root = Core.character(player)
		local pos = Core.position(part)
		if not root or not pos or (root.Position - pos).Magnitude > pp.MaxActivationDistance + 6 then
			return
		end
		local now = os.clock()
		if now - (last[player] or 0) < cooldown then
			return
		end
		last[player] = now
		h.Used:Fire(player, part)
		if opts.onUse then
			task.spawn(opts.onUse, player, part)
		end
	end))
	function h.destroy()
		h.maid:Clean()
	end
	h.Destroy = h.destroy
	return h
end

----------------------------------------------------------------------------------------------------------------
-- Carry: pick up (E), drop (G), throw (R). Any part with an "Item" attribute that you pass to c:make(), or that
-- c:spawn() creates. Held items are welded to the character; stations take items out of hands.
----------------------------------------------------------------------------------------------------------------
local Carry = {}
Carry.__index = Carry
-- Carry.new({holdOffset=CFrame.new(0, 0.6, -2.4), throwSpeed=55, distance=9, parent=Folder,
--   colors={[itemType]=Color3|"#hex"} (spawn colours), onPickup=fn(player, part), onDrop=fn(player, part, thrown)})
function Carry.new(opts)
	opts = opts or {}
	local self = setmetatable({
		holdOffset = opts.holdOffset or CFrame.new(0, 0.6, -2.4),
		throwSpeed = opts.throwSpeed or 55,
		distance = opts.distance or 9,
		parent = opts.parent or Core.folder("Items"),
		colors = opts.colors or {},
		holding = setmetatable({}, { __mode = "k" }), -- player -> part
		parts = {}, -- part -> {holder, prompts...}
		PickedUp = Signal.new(), -- (player, part)
		Dropped = Signal.new(), -- (player, part, thrown)
		maid = Maid.new(),
	}, Carry)
	if opts.onPickup then
		self.PickedUp:Connect(opts.onPickup)
	end
	if opts.onDrop then
		self.Dropped:Connect(opts.onDrop)
	end
	local function hookChar(p)
		self.maid:Give(p.CharacterRemoving:Connect(function()
			self:drop(p)
		end))
	end
	for _, p in ipairs(Players:GetPlayers()) do
		hookChar(p)
	end
	self.maid:Give(Players.PlayerAdded:Connect(hookChar))
	self.maid:Give(Players.PlayerRemoving:Connect(function(p)
		self:drop(p)
	end))
	-- key fallback (G drop / R throw) sent by GameplayKit.startClient while the player attribute "Holding" is set
	local remote = Core.remote("Carry")
	local allow = Core.limiter(4, 4)
	self.maid:Give(remote.OnServerEvent:Connect(function(player, action)
		if self.holding[player] and allow(player) then
			self:drop(player, action == "throw")
		end
	end))
	return self
end

-- c:spawn(itemType, position|CFrame, {size=Vector3.new(1.6,1.6,1.6), color, shape, material}) -> part
function Carry:spawn(itemType, at, o)
	o = o or {}
	local cf = Core.cframe(at) or CFrame.new(0, 5, 0)
	local part = Core.part({
		Name = itemType, Size = o.size or Vector3.new(1.6, 1.6, 1.6), Shape = o.shape,
		Color = Core.color(o.color or self.colors[itemType], Color3.fromRGB(230, 170, 110)),
		Material = o.material or Enum.Material.SmoothPlastic, Anchored = false, CFrame = cf, Parent = self.parent,
	})
	self:make(part, itemType)
	return part
end

-- c:make(part, itemType?) makes an existing part carryable
function Carry:make(part, itemType)
	if self.parts[part] then
		return part
	end
	part:SetAttribute("Item", itemType or part:GetAttribute("Item") or part.Name)
	local pick = Items.prompt(part, { action = "Pick up", object = part:GetAttribute("Item"), distance = self.distance, key = Enum.KeyCode.E })
	local throw = Items.prompt(part, { action = "Throw", object = "", distance = self.distance, key = Enum.KeyCode.R })
	throw.prompt.Enabled = false
	local st: any = { pick = pick, throw = throw, holder = nil, weld = nil }
	self.parts[part] = st
	pick.Used:Connect(function(player)
		if st.holder == player then
			self:drop(player)
		elseif not st.holder then
			self:pickup(player, part)
		end
	end)
	throw.Used:Connect(function(player)
		if st.holder == player then
			self:drop(player, true)
		end
	end)
	self.maid:Give(part.AncestryChanged:Connect(function(_, parent)
		if not parent and self.parts[part] then
			if st.holder then
				self.holding[st.holder] = nil
				st.holder:SetAttribute("Holding", nil)
			end
			pick.destroy()
			throw.destroy()
			self.parts[part] = nil
		end
	end))
	return part
end

function Carry:held(player)
	return self.holding[player]
end

-- c:pickup(player, part) -> bool
function Carry:pickup(player, part)
	local st = self.parts[part]
	local _, root = Core.character(player)
	if not st or st.holder or not root or self.holding[player] then
		return false
	end
	if part:GetAttribute("OnStation") then
		return false -- stations hand items out themselves
	end
	st.holder = player
	self.holding[player] = part
	player:SetAttribute("Holding", part:GetAttribute("Item"))
	part.Anchored = false
	part.CanCollide = false
	part.Massless = true
	part.CFrame = root.CFrame * self.holdOffset
	local weld = Instance.new("WeldConstraint")
	weld.Name = "CarryWeld"
	weld.Part0 = root
	weld.Part1 = part
	weld.Parent = part
	st.weld = weld
	st.pick.prompt.ActionText = "Drop"
	st.pick.prompt.KeyboardKeyCode = Enum.KeyCode.G
	st.throw.prompt.Enabled = true
	self.PickedUp:Fire(player, part)
	return true
end

-- c:take(player) -> part?  removes the held item from the player's hands (no physics), for stations
function Carry:take(player)
	local part = self.holding[player]
	if not part then
		return nil
	end
	local st = self.parts[part]
	if st.weld then
		st.weld:Destroy()
		st.weld = nil
	end
	st.holder = nil
	self.holding[player] = nil
	player:SetAttribute("Holding", nil)
	part.Anchored = true
	part.Massless = false
	st.pick.prompt.ActionText = "Pick up"
	st.pick.prompt.KeyboardKeyCode = Enum.KeyCode.E
	st.throw.prompt.Enabled = false
	return part
end

-- c:give(player, part) -> bool  (puts a part straight into empty hands)
function Carry:give(player, part)
	self:make(part)
	part:SetAttribute("OnStation", nil)
	return self:pickup(player, part)
end

-- c:drop(player, throw?)
function Carry:drop(player, thrown)
	local part = self:take(player)
	if not part then
		return
	end
	local _, root = Core.character(player)
	part.Anchored = false
	part.CanCollide = true
	if root then
		part.CFrame = root.CFrame * CFrame.new(0, 0.5, -3)
		local v = thrown and (root.CFrame.LookVector * self.throwSpeed + Vector3.new(0, self.throwSpeed * 0.35, 0)) or root.AssemblyLinearVelocity
		part.AssemblyLinearVelocity = v
	end
	self.Dropped:Fire(player, part, thrown == true)
end

function Carry:destroy()
	self.maid:Clean()
end
Items.Carry = Carry

----------------------------------------------------------------------------------------------------------------
-- Recipes: inputs (multiset of item types) -> output
----------------------------------------------------------------------------------------------------------------
local Recipes = {}
Recipes.__index = Recipes
local function multiset(inputs)
	local m = {}
	for k, v in pairs(inputs) do
		if type(k) == "number" then
			m[v] = (m[v] or 0) + 1
		else
			m[k] = (m[k] or 0) + v
		end
	end
	return m
end
-- Recipes.new({ {inputs={"Bun","Cooked Patty"} | {Bun=1, ["Cooked Patty"]=1}, output="Burger", count=1, time=0}, ... })
function Recipes.new(list)
	local self = setmetatable({ list = {} }, Recipes)
	for _, r in ipairs(list or {}) do
		table.insert(self.list, { inputs = multiset(r.inputs or {}), output = r.output, count = r.count or 1, time = r.time or 0 })
	end
	return self
end
-- r:match({itemType...}) -> recipe? (exact multiset match)
function Recipes:match(types)
	local have = multiset(types)
	for _, r in ipairs(self.list) do
		local ok = true
		for k, n in pairs(r.inputs) do
			if have[k] ~= n then
				ok = false
				break
			end
		end
		for k in pairs(have) do
			if not r.inputs[k] then
				ok = false
				break
			end
		end
		if ok then
			return r
		end
	end
	return nil
end
-- r:partial({itemType...}) -> bool: these items are a subset of some recipe (a station can keep accepting)
function Recipes:partial(types)
	local have = multiset(types)
	for _, r in ipairs(self.list) do
		local ok = true
		for k, n in pairs(have) do
			if (r.inputs[k] or 0) < n then
				ok = false
				break
			end
		end
		if ok then
			return true
		end
	end
	return false
end
function Recipes:get(output)
	for _, r in ipairs(self.list) do
		if r.output == output then
			return r
		end
	end
	return nil
end
function Recipes:canCraft(inventory, player, output)
	local r = self:get(output)
	if not r then
		return false
	end
	for k, n in pairs(r.inputs) do
		if inventory:count(player, k) < n then
			return false
		end
	end
	return true
end
-- r:craft(inventory, player, output) -> bool (consumes inputs, adds output)
function Recipes:craft(inventory, player, output)
	if not self:canCraft(inventory, player, output) then
		return false
	end
	local r = self:get(output)
	for k, n in pairs(r.inputs) do
		inventory:remove(player, k, n)
	end
	inventory:add(player, r.output, r.count)
	return true
end
Items.Recipes = Recipes

----------------------------------------------------------------------------------------------------------------
-- Inventory: slots with stacks, replicated as JSON in player attribute "Inv_<name>"
----------------------------------------------------------------------------------------------------------------
local Inventory = {}
Inventory.__index = Inventory
-- Inventory.new({name="Main", slots=20, stack=99})
function Inventory.new(opts)
	opts = opts or {}
	return setmetatable({
		name = opts.name or "Main",
		slots = opts.slots or 20,
		stack = opts.stack or 99,
		data = setmetatable({}, { __mode = "k" }), -- player -> { {item, count} }
		Changed = Signal.new(), -- (player, item, newCount)
	}, Inventory)
end
function Inventory:_slots(player)
	local s = self.data[player]
	if not s then
		s = {}
		self.data[player] = s
	end
	return s
end
function Inventory:_sync(player, item)
	player:SetAttribute("Inv_" .. self.name, Core.encode(self:list(player)))
	self.Changed:Fire(player, item, self:count(player, item))
end
-- inv:add(player, item, n=1) -> added (may be < n when full)
function Inventory:add(player, item, n)
	n = n or 1
	local slots = self:_slots(player)
	local left = n
	for _, s in ipairs(slots) do
		if s.item == item and s.count < self.stack then
			local k = math.min(left, self.stack - s.count)
			s.count += k
			left -= k
			if left <= 0 then
				break
			end
		end
	end
	while left > 0 and #slots < self.slots do
		local k = math.min(left, self.stack)
		table.insert(slots, { item = item, count = k })
		left -= k
	end
	if left < n then
		self:_sync(player, item)
	end
	return n - left
end
-- inv:remove(player, item, n=1) -> bool (all or nothing)
function Inventory:remove(player, item, n)
	n = n or 1
	if self:count(player, item) < n then
		return false
	end
	local slots = self:_slots(player)
	for i = #slots, 1, -1 do
		local s = slots[i]
		if s.item == item then
			local k = math.min(n, s.count)
			s.count -= k
			n -= k
			if s.count <= 0 then
				table.remove(slots, i)
			end
			if n <= 0 then
				break
			end
		end
	end
	self:_sync(player, item)
	return true
end
function Inventory:count(player, item)
	local c = 0
	for _, s in ipairs(self.data[player] or {}) do
		if s.item == item then
			c += s.count
		end
	end
	return c
end
function Inventory:has(player, item, n)
	return self:count(player, item) >= (n or 1)
end
function Inventory:list(player)
	local out = {}
	for i, s in ipairs(self.data[player] or {}) do
		out[i] = { item = s.item, count = s.count }
	end
	return out
end
function Inventory:clear(player)
	self.data[player] = {}
	self:_sync(player, nil)
end
-- Client: Inventory.client(name="Main") -> {list() -> {{item,count}}, Changed: Signal(list)}
function Inventory.client(name)
	local attr = "Inv_" .. (name or "Main")
	local player = Players.LocalPlayer
	local h = { Changed = Signal.new() }
	function h.list()
		return Core.decode(player and player:GetAttribute(attr)) or {}
	end
	if player then
		player:GetAttributeChangedSignal(attr):Connect(function()
			h.Changed:Fire(h.list())
		end)
	end
	return h
end
Items.Inventory = Inventory

----------------------------------------------------------------------------------------------------------------
-- Stations: place items, run timed processes, combine by recipe, take results.
-- Part attributes for UI: State ("Empty" | process label | "Ready"), Item (top item type), Progress (0..1),
-- Contents (JSON list of item types). E.g. a stove: Raw Patty -[Cooking 5s]-> Cooked Patty -[Burning 6s]-> Burnt Patty
----------------------------------------------------------------------------------------------------------------
local Station = {}
Station.__index = Station
-- Station.new(part, {name=part.Name, carry=Carry obj | inventory=Inventory obj, accepts=nil (any) | {types},
--   process={ {from="Raw Patty", to="Cooked Patty", time=5, label="Cooking"}, ... }, recipes=Recipes obj (combine),
--   capacity=1 (4 with recipes), colors={[type]=Color3|"#hex"}, distance=9,
--   onChange=fn(state, itemType), onDone=fn(fromType, toType)})
function Station.new(part, opts)
	opts = opts or {}
	local self = setmetatable({
		part = part,
		name = opts.name or part.Name,
		carry = opts.carry,
		inventory = opts.inventory,
		accepts = opts.accepts,
		process = opts.process or {},
		recipes = opts.recipes,
		capacity = opts.capacity or (opts.recipes and 4 or 1),
		colors = opts.colors or {},
		contents = {}, -- array of item types (top = last)
		visuals = {},
		Changed = Signal.new(), -- (state, itemType, progress)
		Done = Signal.new(), -- (fromType, toType)
		maid = Maid.new(),
	}, Station)
	if opts.onChange then
		self.Changed:Connect(opts.onChange)
	end
	if opts.onDone then
		self.Done:Connect(opts.onDone)
	end
	local pr = Items.prompt(part, { action = "Place", object = self.name, distance = opts.distance or 9, key = Enum.KeyCode.E })
	self.prompt = pr.prompt
	self.maid:Give(pr)
	pr.Used:Connect(function(player)
		self:_use(player)
	end)
	self:_set("Empty", 0)
	return self
end

function Station:_accepts(itemType)
	if #self.contents >= self.capacity then
		return false
	end
	if self.accepts then
		local ok = false
		for _, t in ipairs(self.accepts) do
			if t == itemType then
				ok = true
				break
			end
		end
		if not ok then
			return false
		end
	end
	if self.recipes and #self.contents > 0 then
		local next = table.clone(self.contents)
		table.insert(next, itemType)
		return self.recipes:partial(next)
	end
	return true
end

function Station:_set(state, progress)
	local top = self.contents[#self.contents]
	self.state = state
	self.part:SetAttribute("State", state)
	self.part:SetAttribute("Item", top)
	self.part:SetAttribute("Progress", progress or 0)
	self.part:SetAttribute("Contents", Core.encode(self.contents))
	self.prompt.ObjectText = self.name .. (top and (" - " .. top) or "")
	self.prompt.ActionText = (#self.contents == 0) and "Place" or ((#self.contents < self.capacity) and "Place / Take" or "Take")
	self.Changed:Fire(state, top, progress or 0)
end

function Station:_redraw()
	for _, v in ipairs(self.visuals) do
		v:Destroy()
	end
	table.clear(self.visuals)
	local top = self.part.CFrame * CFrame.new(0, self.part.Size.Y / 2, 0)
	for i, t in ipairs(self.contents) do
		local v = Core.part({
			Name = t, Size = Vector3.new(1.6, 0.5, 1.6), Color = Core.color(self.colors[t], Color3.fromRGB(230, 170, 110)),
			Material = Enum.Material.SmoothPlastic, CanCollide = false, CFrame = top * CFrame.new(0, 0.25 + (i - 1) * 0.5, 0),
			Parent = self.part,
		})
		v:SetAttribute("Item", t)
		v:SetAttribute("OnStation", true)
		table.insert(self.visuals, v)
	end
end

-- st:put(itemType) -> bool  (server API: place an item without a player)
function Station:put(itemType)
	if not self:_accepts(itemType) then
		return false
	end
	table.insert(self.contents, itemType)
	self:_redraw()
	self:_advance()
	return true
end

-- st:takeTop() -> itemType?
function Station:takeTop()
	local t = table.remove(self.contents)
	if self.job then
		task.cancel(self.job)
		self.job = nil
	end
	self:_redraw()
	self:_advance()
	return t
end

function Station:_use(player)
	if self.carry then
		local held = self.carry:held(player)
		if held then
			local t = held:GetAttribute("Item")
			if self:_accepts(t) then
				self.carry:take(player):Destroy()
				self:put(t)
			end
		elseif #self.contents > 0 then
			local t = self:takeTop()
			local _, root = Core.character(player)
			local part = self.carry:spawn(t, root and root.CFrame or self.part.CFrame)
			self.carry:pickup(player, part)
		end
	elseif self.inventory then
		for _, t in ipairs(self.accepts or {}) do
			if self.inventory:has(player, t) and self:_accepts(t) then
				self.inventory:remove(player, t, 1)
				self:put(t)
				return
			end
		end
		if #self.contents > 0 then
			local t = self.contents[#self.contents]
			if self.inventory:add(player, t, 1) == 1 then
				self:takeTop()
			end
		end
	end
end

function Station:_advance()
	if self.job then
		task.cancel(self.job)
		self.job = nil
	end
	if #self.contents == 0 then
		self:_set("Empty", 0)
		return
	end
	if self.recipes then
		local r = self.recipes:match(self.contents)
		if r then
			self:_run("Combining", r.time, function()
				local from = table.concat(self.contents, "+")
				table.clear(self.contents)
				for _ = 1, r.count do
					table.insert(self.contents, r.output)
				end
				self.Done:Fire(from, r.output)
			end)
			return
		end
	end
	if #self.contents == 1 then
		local t = self.contents[1]
		for _, p in ipairs(self.process) do
			if p.from == t then
				self:_run(p.label or "Processing", p.time or 3, function()
					self.contents[1] = p.to
					self.Done:Fire(p.from, p.to)
				end)
				return
			end
		end
	end
	self:_set("Ready", 1)
end

function Station:_run(label, seconds, finish)
	if seconds <= 0 then
		finish()
		self:_redraw()
		self:_advance()
		return
	end
	self:_set(label, 0)
	self.job = task.spawn(function()
		local t0 = os.clock()
		while true do
			task.wait(0.1)
			local k = math.min(1, (os.clock() - t0) / seconds)
			self.part:SetAttribute("Progress", k)
			if k >= 1 then
				break
			end
		end
		self.job = nil
		finish()
		self:_redraw()
		self:_advance()
	end)
end

function Station:destroy()
	if self.job then
		task.cancel(self.job)
	end
	for _, v in ipairs(self.visuals) do
		v:Destroy()
	end
	self.maid:Clean()
end
Items.Station = Station

-- Maid-friendly aliases (maid:Give(obj) calls obj:Destroy())
Collectibles.Destroy = Collectibles.destroy
Carry.Destroy = Carry.destroy
Station.Destroy = Station.destroy

return Items
