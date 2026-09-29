-- Sound: named sounds in SoundGroups, with variation, 3D placement, music crossfades and ducking.
--   Sound.register("ui_click", { ids = {"rbxassetid://..."}, group = "UI", volume = 0.5, pitch = 0.06 })
--   Sound.play("ui_click")                         2D
--   Sound.play("impact", { parent = part })        3D, positioned on a part or attachment
--   Sound.music("explore", 1.5)                    crossfade to a looping track
--   Sound.duck(0.35, 1.2)                          dip music for a payoff moment
--   Sound.manifest()                               every registered sound with its load state (for the audio review)
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local ContentProvider = game:GetService("ContentProvider")

local Sound = {}
local GROUP_VOLUME = { Music = 0.45, SFX = 0.8, UI = 0.6, Ambience = 0.5 }
local registry = {}
local rng = Random.new()
local currentMusic, currentMusicName = nil, nil

function Sound.group(name)
	local g = SoundService:FindFirstChild(name)
	if not g then
		g = Instance.new("SoundGroup")
		g.Name = name
		g.Volume = GROUP_VOLUME[name] or 0.7
		g.Parent = SoundService
	end
	return g
end

function Sound.register(name, def)
	assert(type(def) == "table" and type(def.ids) == "table" and #def.ids > 0, "Sound.register needs ids")
	registry[name] = {
		ids = def.ids,
		group = def.group or "SFX",
		volume = def.volume or 0.7,
		pitch = def.pitch or 0,
		looped = def.looped or false,
		rollOff = def.rollOff or { 8, 120 },
	}
end

local function make(name, def, opts)
	local s = Instance.new("Sound")
	s.Name = name
	s.SoundId = def.ids[rng:NextInteger(1, #def.ids)]
	s.Volume = (opts and opts.volume) or def.volume
	s.Looped = def.looped
	s.SoundGroup = Sound.group(def.group)
	local var = (opts and opts.pitch) or def.pitch
	s.PlaybackSpeed = 1 + (var > 0 and rng:NextNumber(-var, var) or 0)
	local parent = opts and opts.parent
	if parent then
		s.RollOffMode = Enum.RollOffMode.InverseTapered
		s.RollOffMinDistance = def.rollOff[1]
		s.RollOffMaxDistance = def.rollOff[2]
		s.Parent = parent
	else
		s.Parent = SoundService
	end
	return s
end

function Sound.play(name, opts)
	local def = registry[name]
	if not def then
		warn("[Sound] not registered: " .. tostring(name))
		return nil
	end
	local s = make(name, def, opts)
	s:Play()
	if not def.looped then
		s.Ended:Once(function()
			s:Destroy()
		end)
		task.delay(30, function()
			if s.Parent then
				s:Destroy()
			end
		end)
	end
	return s
end

function Sound.music(name, fade)
	if name == currentMusicName then
		return currentMusic
	end
	fade = fade or 1.5
	local old = currentMusic
	if old then
		local t = TweenService:Create(old, TweenInfo.new(fade), { Volume = 0 })
		t:Play()
		t.Completed:Once(function()
			old:Destroy()
		end)
	end
	currentMusicName = name
	currentMusic = nil
	if not name then
		return nil
	end
	local def = registry[name]
	if not def then
		warn("[Sound] music not registered: " .. tostring(name))
		return nil
	end
	local s = make(name, { ids = def.ids, group = "Music", volume = def.volume, pitch = 0, looped = true, rollOff = def.rollOff })
	local target = s.Volume
	s.Volume = 0
	s:Play()
	TweenService:Create(s, TweenInfo.new(fade), { Volume = target }):Play()
	currentMusic = s
	return s
end

function Sound.duck(amount, seconds)
	local g = Sound.group("Music")
	local base = GROUP_VOLUME.Music
	g.Volume = base * (1 - (amount or 0.35))
	task.delay(seconds or 1, function()
		TweenService:Create(g, TweenInfo.new(0.6), { Volume = base }):Play()
	end)
end

function Sound.preload()
	local list = {}
	for name, def in registry do
		for _, id in def.ids do
			local s = Instance.new("Sound")
			s.Name = name
			s.SoundId = id
			table.insert(list, s)
		end
	end
	pcall(function()
		ContentProvider:PreloadAsync(list)
	end)
	return list
end

-- For the audio review: every registered sound, whether its assets load, and their lengths.
function Sound.manifest()
	local out = {}
	local probes = Sound.preload()
	for _, s in probes do
		local entry = out[s.Name] or { group = registry[s.Name].group, volume = registry[s.Name].volume,
			pitch = registry[s.Name].pitch, looped = registry[s.Name].looped, ids = {} }
		table.insert(entry.ids, { id = s.SoundId, loaded = s.IsLoaded, length = s.TimeLength })
		out[s.Name] = entry
		s:Destroy()
	end
	return out
end

return Sound
