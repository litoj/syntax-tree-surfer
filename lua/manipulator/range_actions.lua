---@class manipulator.range_actions
local M = {}

local RANGE_UTILS = require 'manipulator.range_utils'

---@param point manipulator.RangeType 0-indexed point
---@param offset_insert? boolean if end in 's'/'i' mode should get extra +1 offset (default: true)
function M.jump(point, offset_insert)
	local buf, range = RANGE_UTILS.decompose(point)
	range = { range[1] + 1, range[2] }
	local mode = vim.fn.mode()
	if mode == 'i' or mode == 's' then
		RANGE_UTILS.fix_end(buf, range) -- shifts back by one if at EOL
		if offset_insert ~= false then
			range[2] = range[2] + 1 -- we want insert to be after the selection -> add 1 to all cases
		end
	end

	vim.api.nvim_win_set_buf(0, buf)
	vim.api.nvim_win_set_cursor(0, range)
end

---@param point manipulator.RangeType
---@param char string character for the mark
function M.mark(point, char)
	local buf, range = RANGE_UTILS.decompose(point)
	vim.api.nvim_buf_set_mark(buf, char, range[1] + 1, range[2], {})
end

--- Select given range in visual mode; overwrites the current one
---@param range Range4
---@param mode? 'v'|'V'|'a'|'A' which mode to enter for selection, use 'a'/'A' for automatic switch
---   to 's'|'S' mode when coming from insert mode (default: 'a')
function M.set_visual(range, mode)
	if not mode then mode = 'v' end

	local _, leading = RANGE_UTILS.current_visual()
	local current = vim.fn.mode()

	if current == 'i' then -- TODO: resolve 'a'|'A' modes
		vim.cmd.stopinsert() -- updates in the next tick
		range[4] = range[4] + 1 -- fix insert shortening moved cursor in this tick
		vim.cmd.normal(mode)
	elseif current ~= mode then
		vim.cmd { cmd = 'normal', bang = true, args = { '\027' } }
		vim.cmd { cmd = 'normal', bang = true, args = { mode } }
	end

	vim.api.nvim_win_set_cursor(0, { range[1] + 1, range[2] })
	vim.cmd.normal 'o'
	vim.api.nvim_win_set_cursor(0, { range[3] + 1, range[4] })
	if leading then vim.cmd.normal 'o' end -- keep cursor on the same side
end

do
	local hl_ns = vim.api.nvim_create_namespace 'manipulator_marks'

	--- Highlight or remove highlighting from given range
	---@param buf_range manipulator.RangeType use {range={}} to clear the whole buffer
	---@param group? string|false highlight group name or false to clear (default: 'IncSearch')
	function M.highlight(buf_range, group)
		local buf, range = RANGE_UTILS.decompose(buf_range)
		if group == false then
			vim.api.nvim_buf_clear_namespace(buf, hl_ns, range[1] or 0, range[3] + 1 or -1)
			return
		end

		group = group or 'IncSearch'
		vim.hl.range(buf, hl_ns, group, { range[1], range[2] }, { range[3], range[4] + 1 })
	end
end

return M
