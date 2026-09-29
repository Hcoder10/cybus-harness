-- Textures: art painted from texture specs by the harness (paint_texture), rebuilt at runtime as EditableImages.
--   Textures.apply(panel, "panel_skin")    ImageLabel / ImageButton (ImageContent, plus SliceCenter when the texture
--                                          has a 9-slice and the label's ScaleType is Slice); ParticleEmitter, Beam,
--                                          Trail, Decal, Texture, MeshPart (TextureContent). -> true when applied
--   local content = Textures.get("spark")   Content, decoded on first use and cached; nil if unavailable
--   Textures.preload({"panel_skin", "spark"})   decode ahead of time, spread over frames when the caller can yield
--   Textures.has(name); Textures.info(name) -> {w, h, size, fmt, slice: Rect?, loaded}; Textures.names()
--   Textures.release(name)                  destroy a texture's EditableImage once nothing shows it
-- LA textures are white/grey + alpha: colour them with ImageColor3, or the emitter's / beam's / trail's Color.
-- EditableImage memory is limited (about 70 MB on desktop, less on phones; a 256x256 texture uses 256 KB). When it
-- is spent, get/apply return nil/false, warn once, and creation is retried at most every few seconds. Nothing here
-- throws. Client-side: EditableImages made on the server are not replicated.
local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TexCodec = require(script.Parent:WaitForChild("TexCodec"))

local Textures = {}

local RETRY_SECONDS = 3
local FRAME_BUDGET = 0.004 -- seconds of decoding per frame while preloading

type Entry = { pack: number | { number }, w: number, h: number, fmt: string, slice: { number }?, checksum: number? }
type Record = { image: any, content: any }

local index: { [string]: Entry }? = nil
local indexRetryAt = 0
local waitedForIndex = false
local folder: Instance? = nil
local packs: { [number]: { [string]: string } | false } = {}
local cache: { [string]: Record } = {}
local broken: { [string]: boolean } = {}
local createRetryAt = 0
local warned: { [string]: boolean } = {}

local function warnOnce(key: string, message: string)
	if not warned[key] then
		warned[key] = true
		warn("[Textures] " .. message)
	end
end

local function findIndex(): { [string]: Entry }?
	local now = os.clock()
	if now < indexRetryAt then
		return nil
	end
	indexRetryAt = now + RETRY_SECONDS
	local shared = ReplicatedStorage:FindFirstChild("Shared")
	local found = shared and shared:FindFirstChild("TexPacks")
	if not found and not waitedForIndex and coroutine.isyieldable() then
		waitedForIndex = true -- right after joining, give replication a moment (once)
		shared = shared or ReplicatedStorage:WaitForChild("Shared", 5)
		found = shared and shared:WaitForChild("TexPacks", 5)
	end
	local module = found and found:FindFirstChild("Index")
	if not module or not module:IsA("ModuleScript") then
		warnOnce("index", "no texture index at ReplicatedStorage.Shared.TexPacks.Index (no textures painted yet?)")
		return nil
	end
	local ok, result = pcall(require, module)
	if not ok or type(result) ~= "table" then
		warnOnce("index", "could not load the texture index: " .. tostring(result))
		return nil
	end
	folder = found
	index = result
	return result
end

local function loadIndex(): { [string]: Entry }?
	if index then
		return index
	end
	local ok, result = pcall(findIndex)
	if not ok then
		warnOnce("index", "could not load the texture index: " .. tostring(result))
		return nil
	end
	return result
end

local function packData(n: number): { [string]: string }?
	local p = packs[n]
	if p == nil then
		local module = folder and folder:FindFirstChild("Pack" .. tostring(n))
		local ok, result = false, nil
		if module and module:IsA("ModuleScript") then
			ok, result = pcall(require, module)
		end
		p = if ok and type(result) == "table" then result else false
		packs[n] = p
		if not p then
			warnOnce("pack" .. tostring(n), "texture pack Pack" .. tostring(n) .. " is missing or broken")
		end
	end
	return if p then p else nil
end

local function dataOf(name: string, entry: Entry): string?
	local pack = entry.pack
	if type(pack) == "number" then
		local p = packData(pack)
		local data = p and p[name]
		return if type(data) == "string" then data else nil
	elseif type(pack) == "table" then
		local parts = table.create(#pack)
		for i, n in pack do
			local p = packData(n)
			local part = p and p[name]
			if type(part) ~= "string" then
				return nil
			end
			parts[i] = part
		end
		return table.concat(parts)
	end
	return nil
end

local function build(name: string): Record?
	local idx = loadIndex()
	if cache[name] then -- another thread built it while the index loaded
		return cache[name]
	end
	local entry = idx and idx[name]
	if type(entry) ~= "table" then
		if idx then
			warnOnce("missing:" .. name, "no texture named " .. name)
		end
		return nil
	end
	if broken[name] or os.clock() < createRetryAt then
		return nil
	end
	local data = dataOf(name, entry)
	if not data then
		broken[name] = true
		warnOnce("data:" .. name, "no data for texture " .. name .. " in its pack")
		return nil
	end
	local ok, pixels = pcall(TexCodec.decode, data, entry.w, entry.h, entry.fmt)
	if not ok then
		broken[name] = true
		warnOnce("decode:" .. name, "could not decode texture " .. name .. ": " .. tostring(pixels))
		return nil
	end
	if entry.checksum and TexCodec.checksum(pixels) ~= entry.checksum then
		broken[name] = true
		warnOnce("checksum:" .. name, "texture " .. name .. " is corrupted (checksum mismatch)")
		return nil
	end
	local size = Vector2.new(entry.w, entry.h)
	local okImage, image = pcall(function()
		return AssetService:CreateEditableImage({ Size = size })
	end)
	if not okImage or image == nil then
		createRetryAt = os.clock() + RETRY_SECONDS
		warnOnce("memory", "could not create an EditableImage for " .. name .. " (" .. tostring(image)
			.. "): the image memory budget may be spent; Textures.release what is no longer shown")
		return nil
	end
	local okWrite, err = pcall(function()
		image:WritePixelsBuffer(Vector2.zero, size, pixels)
	end)
	local okContent, content = false, nil
	if okWrite then
		okContent, content = pcall(Content.fromObject, image)
	end
	if not okWrite or not okContent then
		pcall(image.Destroy, image)
		createRetryAt = os.clock() + RETRY_SECONDS
		warnOnce("write:" .. name, "could not fill the EditableImage for " .. name .. ": "
			.. tostring(if okWrite then content else err))
		return nil
	end
	local record = { image = image, content = content }
	cache[name] = record
	return record
end

function Textures.get(name: string): Content?
	local record = cache[name]
	if record then
		return record.content
	end
	local ok, result = pcall(build, name)
	if not ok then
		warnOnce("error:" .. tostring(name), "failed to build texture " .. tostring(name) .. ": " .. tostring(result))
		return nil
	end
	return if result then result.content else nil
end

function Textures.apply(inst: Instance, name: string): boolean
	if typeof(inst) ~= "Instance" then
		warnOnce("apply:notinstance", "Textures.apply needs an Instance, got " .. typeof(inst))
		return false
	end
	local content = Textures.get(name)
	if content == nil then
		return false
	end
	local ok, err = pcall(function()
		if inst:IsA("ImageLabel") or inst:IsA("ImageButton") then
			local label = inst :: any
			label.ImageContent = content
			local entry = index and index[name]
			local s = entry and entry.slice
			if s and label.ScaleType == Enum.ScaleType.Slice then
				label.SliceCenter = Rect.new(s[1], s[2], s[3], s[4])
			end
		elseif inst:IsA("ParticleEmitter") or inst:IsA("Beam") or inst:IsA("Trail") or inst:IsA("Decal")
			or inst:IsA("MeshPart") then
			(inst :: any).TextureContent = content
		else
			error("a " .. inst.ClassName .. " does not show textures", 0)
		end
	end)
	if not ok then
		warnOnce("apply:" .. inst.ClassName .. ":" .. name, "could not apply " .. name .. " to "
			.. inst:GetFullName() .. ": " .. tostring(err))
		return false
	end
	return true
end

-- Decodes textures ahead of time (all of them when names is nil). Returns how many are ready.
function Textures.preload(names: { string }?): number
	local list = names or Textures.names()
	local ready = 0
	local frameStart = os.clock()
	for _, name in list do
		if not cache[name] then
			Textures.get(name)
			if os.clock() - frameStart > FRAME_BUDGET and coroutine.isyieldable() then
				task.wait()
				frameStart = os.clock()
			end
		end
		if cache[name] then
			ready += 1
		end
	end
	return ready
end

function Textures.has(name: string): boolean
	local idx = loadIndex()
	return idx ~= nil and type(idx[name]) == "table"
end

function Textures.info(name: string): { [string]: any }?
	local idx = loadIndex()
	local e = idx and idx[name]
	if type(e) ~= "table" then
		return nil
	end
	local ok, info = pcall(function()
		local s = e.slice
		return {
			w = e.w,
			h = e.h,
			size = Vector2.new(e.w, e.h),
			fmt = e.fmt,
			slice = if s then Rect.new(s[1], s[2], s[3], s[4]) else nil,
			loaded = cache[name] ~= nil,
		}
	end)
	return if ok then info else nil
end

function Textures.names(): { string }
	local idx = loadIndex()
	local out = {}
	if idx then
		for name in idx do
			table.insert(out, name)
		end
		table.sort(out)
	end
	return out
end

-- Frees a texture's EditableImage (anything still showing it goes blank); the next get() rebuilds it.
function Textures.release(name: string)
	local record = cache[name]
	if record then
		cache[name] = nil
		pcall(record.image.Destroy, record.image)
		createRetryAt = 0
	end
end

return Textures
