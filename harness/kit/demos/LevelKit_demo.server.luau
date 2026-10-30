--!nonstrict
-- LevelKit demo (server Script). Builds a level for each look in turn and frames it with the DemoCam attribute:
-- the player's view from behind the spawn, the studio_build survey overview, a hero shot from behind the hub, and the
-- survey side view. Workspace attributes (set before Play): LevelDemoRuns (comma list of kind:look, default RUNS below),
-- LevelDemoHold (seconds per shot, default 6), LevelDemoSeed.
-- The current shot name is in the Workspace attribute LevelDemoShot.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Kit = ReplicatedStorage:WaitForChild("Kit")
local LevelKit = require(Kit:WaitForChild("LevelKit"))

local base = Workspace:FindFirstChild("Baseplate")
if base then base:Destroy() end

local RUNS = "sky_islands:toon_bright,sky_islands:cozy,meadow_course:candy"
local runs = string.split(Workspace:GetAttribute("LevelDemoRuns") or RUNS, ",")
local hold = Workspace:GetAttribute("LevelDemoHold") or 6

local function cam(name, pos, at)
	Workspace:SetAttribute("LevelDemoShot", name)
	Workspace:SetAttribute("DemoCam", string.format("%.1f,%.1f,%.1f,%.1f,%.1f,%.1f", pos.X, pos.Y, pos.Z, at.X, at.Y, at.Z))
	print("[LevelDemo] shot", name)
	task.wait(hold)
end

for _, run in ipairs(runs) do
	local kind, look = table.unpack(string.split(run, ":"))
	local t0 = os.clock()
	local info = LevelKit.build(kind, { look = look, seed = Workspace:GetAttribute("LevelDemoSeed") or 7,
		parent = Workspace })
	print(string.format("[LevelDemo] %s/%s built in %.1fs: %d islands, %d courses, %d checkpoints, %d coins, %d goals, %d hazards",
		kind, look, os.clock() - t0, #info.islands, #info.courses, #info.checkpoints, #info.collectibles, #info.goals,
		#info.hazards))
	local sp = info.spawn
	local first = info.courses[1] and info.courses[1].platforms[1] or (sp + Vector3.new(0, 0, -40))
	local dir = ((first - sp) * Vector3.new(1, 0, 1)).Unit
	local lo, hi = info.bounds.min, info.bounds.max
	local c = (lo + hi) / 2
	local r = math.max(hi.X - lo.X, hi.Z - lo.Z, 80) * 0.75
	look = kind .. "_" .. look
	cam(look .. "_player", sp - dir * 16 + Vector3.new(0, 7, 0), sp + dir * 40 + Vector3.new(0, 4, 0))
	cam(look .. "_overview", c + Vector3.new(0.75 * r, 0.6 * r, 0.75 * r), c)
	local hub = info.islands[1].center
	local m = Vector3.zero
	for i = 2, #info.islands do m += (info.islands[i].center - hub) * Vector3.new(1, 0, 1) end
	m = m.Magnitude > 0 and m.Unit or Vector3.new(0, 0, -1)
	cam(look .. "_hero", hub - m * 0.75 * r + Vector3.new(0, 0.45 * r, 0), c)
	cam(look .. "_side", c + Vector3.new(1.25 * r, math.max(0.12 * r, 40), 0), c)
end
Workspace:SetAttribute("LevelDemoShot", "done")
print("[LevelDemo] done")
