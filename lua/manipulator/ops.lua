---@class manipulator.ops
local M = {}

local RANGE_UTILS = require 'manipulator.range_utils'

---@param point manipulator.RangeType 0-indexed point
function M.jump(point)
	local buf, range = RANGE_UTILS.decompose(point)
	local mode = vim.fn.mode():sub(1, 1)
	local pos = vim.api.nvim_win_get_cursor(0)
	pos[1] = pos[1] - 1

	vim.api.nvim_win_set_buf(0, buf)
	vim.api.nvim_win_set_cursor(0, {
		range[1] + 1,
		range[2] + (RANGE_UTILS.cmpPoint(range, pos) > 0 and (mode == 'i' or mode == 's') and 1 or 0),
	})
end

---@param point manipulator.RangeType
---@param char string character for the mark
function M.mark(point, char)
	local buf, range = RANGE_UTILS.decompose(point)
	vim.api.nvim_buf_set_mark(buf, char, range[1] + 1, range[2], {})
end

--- Select given range in visual mode; overwrites the current one
---@param range Range4
---@param mode? 'v'|'V' which mode to enter for selection
function M.set_visual(range, mode)
	if not mode then mode = 'v' end

	local _, leading = RANGE_UTILS.get_visual()
	local current = vim.fn.mode():sub(1, 1)

	if current == 'i' then
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

---@alias manipulator.ops.Mode 'swap'|'before'|'after'|'before_line'|'after_line'|'over' NOTE: prefer using vim motions for modes other than 'swap'

--- Paste like with visual mode motions - prefer using vim motions
---@param text string text to paste
---@param dst manipulator.RangeType where to
---@param mode manipulator.ops.Mode method of modifying the dst range text content, doesn't support 'swap' mode
function M.paste(dst, text, mode)
	local buf, range = RANGE_UTILS.decompose(dst, true)
	if mode:sub(-5) == '_line' then
		if mode == 'after_line' then range[1] = range[3] + 1 end
		range[3] = range[1]
		range[2] = 0
		range[4] = 0
		text = text .. '\n'
	elseif mode == 'before' then
		range[3] = range[1]
		range[4] = range[2]
	elseif mode == 'after' then
		range[1] = range[3]
		range[2] = range[4]
	end -- else mode = 'over'

	vim.lsp.util.apply_text_edits(
		{ { range = RANGE_UTILS.lsp_range(range), newText = text } },
		buf,
		'utf-8'
	)
end

---@class manipulator.ops.move.Opts
---@field dst manipulator.RangeType optional direct destination to move to
---@field mode? manipulator.ops.Mode (default: 'swap')
---@field cursor_to? 'old'|'new'|false if cursor should be moved to original position (`'old'`) or new destination (`'new'`) (default: 'new')

--- Move or swap two regions. The buffer can differ.
---@param src manipulator.RangeType where from
---@param opts manipulator.ops.move.Opts
function M.move(src, opts)
	local sbuf, srange = RANGE_UTILS.decompose(src, true)
	local dbuf, drange = RANGE_UTILS.decompose(opts.dst, true)
	if not srange[1] or not drange[1] then return end

	-- Move the cursor before all positions get mangled by text edits
	if opts.cursor_to == nil then opts.cursor_to = 'new' end
	if opts.cursor_to then
		-- TODO: this needs adjusting to fix visual selection, ideally standalone
		-- lsp text edits move the cursor with the text -> for moving to the new pos we go to the start
		local dst = opts.cursor_to == 'new' and srange or drange
		M.jump { buf = sbuf, dst[1], dst[2] }
	end

	local text1 = table.concat(RANGE_UTILS.get_lines(src), '\n')
	if opts.mode ~= 'swap' then
		M.paste(opts.dst, text1, opts.mode)
		return
	end

	local text2 = table.concat(RANGE_UTILS.get_lines(opts.dst), '\n')

	local edit1 = { range = RANGE_UTILS.lsp_range(srange), newText = text2 }
	local edit2 = { range = RANGE_UTILS.lsp_range(drange), newText = text1 }

	if sbuf ~= dbuf then
		vim.lsp.util.apply_text_edits({ edit1 }, sbuf, 'utf-8')
		vim.lsp.util.apply_text_edits({ edit2 }, dbuf, 'utf-8')
	else
		vim.lsp.util.apply_text_edits({ edit1, edit2 }, sbuf, 'utf-8')
	end
end

return M
