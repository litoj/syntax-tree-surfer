local U = require 'manipulator.utils'
local Range = require 'manipulator.range'

---@class manipulator.range_mods
local M = {}

---@alias linewise_opt boolean|'auto'|fun(self:anypos, opts:unknown):boolean?

---@class manipulator.range_mods.linewise.Opts
---@field linewise? linewise_opt
---@field linewise_start? string luapat to match the unselected start of the line to be added by linewise
---@field linewise_end? string luapat to match the unselected start of the line to be added by linewise

--- Should whole lines be selected - not just the range
---@param opts manipulator.range_mods.linewise.Opts|table
---@param lw? linewise_opt behaviour override
--- - `'auto'`: decide by matching lua patterns on start and/or end
---@return boolean
function M.evaluate_linewise(self, opts, lw)
	local r = Range.get_or_make(self)
	lw = U.get_or(lw, opts.linewise)

	return lw == true
		or (type(lw) == 'function' and lw(self, opts))
		or (
			lw == 'auto'
			and r:start():get_line():sub(1, r[2]):match(opts.linewise_start or '^%s*$') --
			and r:end_():get_line():sub(r[4] + 2):match(opts.linewise_end or '^%s*$')
		)
		or false
end

---@see manipulator.range_mods.validate_linewise
---@param opts manipulator.range_mods.linewise.Opts|table
---@return manipulator.Range
function M.linewise(self, opts, lw)
	local r = Range.get_or_make(self)
	if M.evaluate_linewise(self, opts, lw) then
		r[2] = 0
		r[4] = vim.v.maxcol
	end

	return r
end

---@class manipulator.range_mods.trimmed.Opts
---@field trimm_start string lua pattern to determine what should be trimmed from the start
---@field trimm_end string lua pattern to determine what should be trimmed from the end

---@param opts manipulator.range_mods.trimmed.Opts
---@return manipulator.Range
function M.trimmed(self, opts)
	local r = Range.get_or_make(self)
	local lines = r:get_lines(true)
	local s_ptn, e_ptn = opts.trimm_start or '^%s*', opts.trimm_end or '%s*$'

	-- Trim leading whitespace
	local s_l = 1
	local s_c = r[2]
	while s_l <= #lines do
		local line = lines[s_l]
		local space = #(line:match(s_ptn) or '')

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
	-- NOTE: trims linewise mode back into a normal range!
	local e_c = math.min(r[4], #r:end_():get_line() - 1) - (#lines == 1 and r[2] or 0)
	while e_l >= s_l do
		local line = lines[e_l]
		local space = #(line:match(e_ptn) or '')

		if space >= #line then
			if s_l == e_l then
				e_c = s_c - 1
				break
			end
			e_l = e_l - 1
			e_c = #lines[e_l] - 1
		else
			e_c = e_c - space
			break
		end
	end

	if s_l <= e_l then -- update only if there is text left
		r[3] = r[1] + e_l - 1 -- update the end before the start gets overriden
		r[4] = e_l == 1 and (r[2] + e_c) or e_c -- shift by the truncated start

		r[1] = r[1] + s_l - 1
		r[2] = s_c
	end

	return r
end

do -- end_shift with adjustment for insert mode
	---@class manipulator.range_mods.end_shift.Opts
	---@field end_shift_ptn? string luapat to determine if a by-one shift in position should be done
	---@field shift_point_range? boolean shift also the start of a single-char-wide range
	--- How to manipulate the matching end
	--- - 1 to add the matching end, -1 to exclude it from the range (default)
	--- - `'insert'`: -1 if matching, and on top always add 1 if we're in insert/select mode
	---@field shift_mode? 'insert'|1|-1

	local insert_modes = { i = 1, s = 1, S = 1 }

	--- Shift the end by -1 if EOL is selected or the char falls under `opts.endfix`.
	--- Shifts the whole region if it was just 1 char wide.
	---@param self anyrange
	---@param opts? manipulator.range_mods.end_shift.Opts
	---@return manipulator.Range point returns `Range2` if `self` was `Range2`
	function M.end_shift(self, opts)
		opts = opts or {}
		local r = Range.new(self)

		local col = r[4] + (opts.shift_mode == 1 and 1 or 0) -- check the col to be added or removed
		local char = r:end_():get_line():sub(col + 1, col + 1)

		col = char:match(opts.end_shift_ptn or '^[, ]?$') and (opts.shift_mode == 1 and 1 or -1) or 0
		if opts.shift_mode == 'insert' and insert_modes[vim.fn.mode()] then col = col + 1 end

		if opts.shift_point_range and r[1] == r[3] and r[4] <= r[2] then r[2] = r[2] + col end
		r[4] = r[4] + col
		return r
	end
end

---@class manipulator.range_mods.pos_shift.Opts
---@field shift_backward? boolean go before or after the collective match
---@field shift_by_luapat string pattern to match the space to be ignored - move to the edge of it
---@field shift_modes manipulator.Enabler which modes to apply to (default: all modes)

--- Shift the range if it is at most 1-char wide.
---@param r anyrange
---@param opts manipulator.range_mods.pos_shift.Opts
---@return manipulator.Range point returns `Range2` if `self` was `Range2`
function M.pos_shift(r, opts)
	r = Range.get_or_make(r)
	local size = r:size()
	if size[1] ~= 0 or size[2] > 1 or not opts.shift_modes[vim.fn.mode()] then return r end

	local line = r:get_line()

	local from, to, s, e = 0, 0, 0, 0
	while true do
		from, to = line:find(opts.shift_by_luapat, (e or to) + 1)
		if not from then break end

		-- build a collective match (range of all matches touching one another)
		s, e = from, to
		while s and to + 1 >= s do -- end of last connects to start of current
			to = e
			s, e = line:find(opts.shift_by_luapat, e + 1)
		end

		if from - 1 <= r[2] and r[4] < to then -- if 0-indexed is contained in 1-indexed
			-- adjust to 0-indexed and move behind (or in front of) the match
			if opts.shift_backward then to = from <= 1 and 0 or from - 2 end

			r[4] = r[4] - r[2] + to
			r[2] = to
			break
		end
	end

	return r
end

---@param self manipulator.TS
---@param opts manipulator.TS.Config
function M.with_docs(self, opts)
	-- doesn't get launched on Nil, but we still must check the opts
	local lw_opts = { linewise = 'auto' }
	-- ensure we're the type that could carry docs and that we don't share the line with other nodes
	if not self:is_valid_in(opts) or not M.evaluate_linewise(self, lw_opts) then return self.range end

	local prev_opts = self:action_opts('with_docs', 'prev_sibling')
	prev_opts.inherit = false

	-- NOTE: not testing for a TS.Nil node, because we disabled `nil_wrap` in the preset config
	local old, new = self, self:prev_sibling 'with_docs'
	-- include all comments above
	while new and new.range[3] + 1 == old.range[1] and M.evaluate_linewise(new, lw_opts) do
		old = new
		new = new:prev_sibling 'with_docs'
	end

	local s, e = old.range, self.range
	if prev_opts.types[self.node:type()] then -- if we are the comment to which we'd expand
		old, new = self, self:next_sibling(prev_opts)
		-- include all comments bellow
		while new and new.range[1] - 1 == old.range[3] and M.evaluate_linewise(new, lw_opts) do
			old = new
			new = new:next_sibling(prev_opts) -- also allow only docs
		end

		new = old:next_sibling 'with_docs' -- uses with_docs.types (all the ones we can process)
		-- include the node that is being documented
		if new and new.range[1] - 1 == old.range[3] and M.evaluate_linewise(new, lw_opts) then
			e = new.range
		elseif s ~= self.range or old ~= self then -- or select just the block of comments
			e = old.range
		else -- or recognize we didn't actually want to select the whole block -> revert
			return self.range
		end
	end

	-- include previous line only if we found some other nodes, too
	if s[1] < e[1] and Range.get_line { s[1] - 1, 0, buf = self.buf } == '' then
		s[1] = s[1] - 1
		s[2] = 0
	end

	return { s[1], s[2], e[3], e[4] }
end

return M
