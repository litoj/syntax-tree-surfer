local U = require 'manipulator.utils'
local RANGE_U = require 'manipulator.range_utils'

---@class manipulator.range_mods
local M = {}

---@class manipulator.range_mods.linewise.Opts
--- Should whole lines be selected - not just the range ('if_trimmable' = only over whitespace)
---@field linewise? boolean|'if_trimmable'|fun(self:manipulator.RangeType, opts:unknown):boolean?

---@param opts manipulator.range_mods.linewise.Opts
function M.linewise(self, opts)
	local buf, r = RANGE_U.decompose(self, false)

	local lw = opts.linewise
	if
		lw == true
		or (type(lw) == 'function' and lw(self, opts))
		or (
			lw == 'if_trimmable'
			and not vim.api.nvim_buf_get_lines(buf, r[1], r[1] + 1, true)[1]:sub(1, r[2]):match '%S'
			and not vim.api.nvim_buf_get_lines(buf, r[3], r[3] + 1, true)[1]:sub(r[4] + 2):match '%S'
		)
	then
		r[2] = 0
		r[4] = vim.v.maxcol
	end

	return r
end

function M.trimmed(self)
	local _, range = RANGE_U.decompose(self)
	local lines = RANGE_U.get_lines(self, true)

	-- Trim leading whitespace
	local s_l = 1
	local s_c = range[2]
	while s_l <= #lines do
		local line = lines[s_l]
		local space = #(line:match '^%s*')

		if space >= #line then
			s_l = s_l + 1
			s_c = 0
		else
			s_c = s_c + space
			break
		end
	end

	-- Trim trailing whitespace
	local e_l = #lines
	local e_c = range[4] - (#lines == 1 and range[2] or 0)
	while e_l >= s_l do
		local line = lines[e_l]
		local space = #(line:match '%s*$')

		if space >= #line then
			e_l = e_l - 1
			e_c = #lines[e_l] - 1
		else
			e_c = e_c - space
			break
		end
	end

	if s_l <= e_l then -- update only if there is text left
		range[3] = range[1] + e_l - 1 -- update the end before the start gets overriden
		range[4] = e_l == 1 and (range[2] + e_c) or e_c -- shift by the truncated start

		range[1] = range[1] + s_l - 1
		range[2] = s_c
	end

	return range
end

---@class manipulator.range_mods.end_shift.Opts
---@field end_shift_ptn? string luapat to determine if a by-one shift in position should be done
--- How to manipulate the matching end
--- - 1 to add the matching end, -1 to exclude it from the range (default)
--- - `'insert'`: -1 if matching, and on top always add 1 if we're in insert/select mode
---@field shift_mode? 'insert'|1|-1

do -- end_shift with adjustment for insert mode
	local insert_modes = { i = 1, s = 1, S = 1 }

	--- Shift the end by -1 if EOL is selected or the char falls under `opts.endfix`.
	--- Shifts the whole region if it was just 1 char wide.
	---@param opts? manipulator.range_mods.end_shift.Opts
	---@return Range4 point returns `Range2` if `self` was `Range2`
	function M.end_shift(self, opts)
		opts = opts or {}
		local buf, r = RANGE_U.decompose(self)

		local line, col = r[3] or r[1], (r[4] or r[2]) + (opts.shift_mode == 1 and 1 or -1)
		local char = vim.api.nvim_buf_get_lines(buf, line, line + 1, true)[1]:sub(col + 1, col + 1)

		col = char:match(opts.end_shift_ptn or '^[, ]?$') and (opts.shift_mode == 1 and 1 or -1) or 0
		if opts.shift_mode == 'insert' and insert_modes[vim.fn.mode()] then col = col + 1 end

		r[4] = r[4] + col
		return r
	end
end

---@param self manipulator.TS
---@param opts manipulator.TS.Config
function M.with_docs(self, opts)
	-- doesn't get launched on Nil, but we still must check the opts
	if self:is_valid_in(opts) ~= true then return self:range0() end
	---@diagnostic disable-next-line: invisible
	self.config = opts

	local function extend_dir(dir)
		local met = dir == 'prev' and self.prev_sibling or self.next_sibling
		local i = dir == 'prev' and 1 or -1
		local old, new = self, met(self)
		while new and new.node and new:range0()[2 + i] + i == old:range0()[2 - i] do
			old = new
			new = met(new)
		end

		return old:range0()
	end

	local s = extend_dir 'prev'
	local e
	local prev_opts = self:action_opts(nil, 'prev_sibling')
	if prev_opts.types[self.node:type()] then
		e = extend_dir 'next' -- if we could get up to this type of node, try also down to the other
	else
		e = self:range0()
		-- include previous line only if we found some other nodes, too
		if s[1] < e[1] and self.get_lines({ s[1] - 1, 0, s[1] - 1, vim.v.maxcol }, false)[1] == '' then
			s[1] = s[1] - 1
			s[2] = 0
		end
	end

	return { s[1], s[2], e[3], e[4] }
end

return M
