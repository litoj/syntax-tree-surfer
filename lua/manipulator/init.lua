---@diagnostic disable: redefined-local

---@class manipulator
---@field batch manipulator.Batch
---@field call_path manipulator.CallPath
---@field region manipulator.Region
---@field tsregion manipulator.TSRegion
local M = {}

---@class manipulator.Config
---@field batch? manipulator.Batch.module.Config
---@field call_path? manipulator.CallPath.Config
---@field region? manipulator.Region.module.Config
---@field tsregion? manipulator.TSRegion.module.Config

---@param config? manipulator.Config
---@return manipulator
function M.setup(config)
	config = config or {}

	for _, mod in ipairs { 'batch', 'call_path', 'region', 'tsregion' } do
		M[mod] = require('manipulator.' .. mod).setup(config[mod])
	end

	return M
end

return M
