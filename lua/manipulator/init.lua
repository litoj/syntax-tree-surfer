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
---@field debug? false|vim.log.levels log level of debug messages of expanded options etc.

---@param config? manipulator.Config
---@return manipulator
function M.setup(config)
	config = config or {}

	for _, mod in ipairs { 'batch', 'call_path', 'region', 'tsregion' } do
		M[mod] = require('manipulator.' .. mod).setup(config[mod])

		if config.debug ~= nil then M[mod].debug = config.debug end
	end

	return M
end

return M
