---@diagnostic disable: redefined-local

local UTILS = require 'manipulator.utils'

---@class manipulator
local M = {}
M.config = {}

function M.setup(config)
	if config then
		M.config = config.inherit ~= false and UTILS.tbl_inner_extend('keep', config, M.config, true) or config
	end

	for k, config in pairs(M.config) do
		require('manipulator.' .. k).setup(config)
	end
end

return M
