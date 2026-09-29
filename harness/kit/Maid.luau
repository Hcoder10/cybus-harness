-- Maid: collects connections, instances, cleanup functions, threads and objects with :Destroy(),
-- and cleans them all at once when a screen, round or effect ends.
local Maid = {}
Maid.__index = Maid

function Maid.new()
	return setmetatable({ _jobs = {} }, Maid)
end

-- Give(job) -> job. Accepts RBXScriptConnection, Instance, function, thread, or a table with :Destroy().
function Maid:Give(job)
	table.insert(self._jobs, job)
	return job
end

local function clean(job)
	local kind = typeof(job)
	if kind == "RBXScriptConnection" then
		job:Disconnect()
	elseif kind == "Instance" then
		job:Destroy()
	elseif kind == "function" then
		job()
	elseif kind == "thread" then
		pcall(task.cancel, job)
	elseif kind == "table" and type(job.Destroy) == "function" then
		job:Destroy()
	end
end

function Maid:Clean()
	local jobs = self._jobs
	self._jobs = {}
	for i = #jobs, 1, -1 do
		local ok, err = pcall(clean, jobs[i])
		if not ok then
			warn("[Maid] cleanup failed: " .. tostring(err))
		end
	end
end

Maid.Destroy = Maid.Clean

return Maid
