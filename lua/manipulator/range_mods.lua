local U = require 'manipulator.utils'
local RANGE_U = require 'manipulator.range_utils'

---@class manipulator.range_mods
---@field [string] fun(self:manipulator.RangeType,opts:unknown):Range4
local M = {}

---@param opts {linewise: boolean|'auto'|'force'}
function M.linewise(self, opts)
	local buf, r = RANGE_U.decompose(self, false)
	if
		opts.linewise == 'auto'
			and not vim.api.nvim_buf_get_lines(buf, r[1], r[1] + 1, true)[1]:sub(1, r[2]):match '%S'
			and not vim.api.nvim_buf_get_lines(buf, r[3], r[3] + 1, true)[1]:sub(r[4] + 2):match '%S'
		or opts.linewise == true
		or opts.linewise == 'force'
	then
		return { r[1], 0, r[3], vim.v.maxcol }
	else
		return r
	end
end

---@param self manipulator.RangeType
function M.trimmed(self)
	local _, range = RANGE_U.decompose(self)
	local lines = RANGE_U.get_lines(self)

	-- Trim leading whitespace
	local s_l = 1
	local s_c = range[2]
	while s_l <= #lines do
		local line = lines[s_l]
		local len = #(line:match '^%s*')

		if len >= #line then
			s_l = s_l + 1
			s_c = 0
		else
			s_c = s_c + len
			break
		end
	end

	-- Trim trailing whitespace
	local e_l = #lines
	local e_c = range[4]
	while e_l >= s_l do
		local line = lines[e_l]
		local len = #(line:match '%s*$')

		if len >= #line then
			e_l = e_l - 1
			e_c = #lines[e_l] - 1
		else
			e_c = e_c - len
			break
		end
	end

	if s_l <= e_l then -- update only if there is text left
		range[1] = range[1] + s_l - 1
		if s_l == e_l and (range[4] ~= e_c or range[3] ~= range[1] + e_l - 1) then
			e_c = e_c + range[2] -- shift the col by the truncated amount
		end
		range[2] = s_c
		range[3] = range[1] + e_l - 1
		range[4] = e_c
	end

	return range
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
	if opts.prev_sibling.types[self.node:type()] then
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
