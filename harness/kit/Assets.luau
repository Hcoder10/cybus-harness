-- Assets: generated art by name. The harness writes ReplicatedStorage.Shared.AssetMap (name -> content id)
-- whenever generate_image produces an image, so code refers to art by name, never by raw id.
--   icon.Image = Assets.image("coin_icon")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Assets = {}
local map = {}
do
	local ok, result = pcall(function()
		return require(ReplicatedStorage:WaitForChild("Shared", 5):WaitForChild("AssetMap", 5))
	end)
	if ok and type(result) == "table" then
		map = result
	end
end

function Assets.image(name, fallback)
	local entry = map[name]
	if type(entry) == "table" then
		return entry.id or fallback or ""
	end
	return entry or fallback or ""
end

-- Slice metadata for 9-slice textures generated with a known border, if the generator recorded one.
function Assets.slice(name)
	local entry = map[name]
	if type(entry) == "table" and entry.slice then
		local s = entry.slice
		return Rect.new(s[1], s[2], s[3], s[4])
	end
	return nil
end

function Assets.has(name)
	return map[name] ~= nil
end

return Assets
