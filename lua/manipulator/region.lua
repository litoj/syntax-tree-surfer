local U = require 'manipulator.utils'
local RANGE_U = require 'manipulator.range_utils'
local MODS = require 'manipulator.range_mods'
local Batch = require 'manipulator.batch'

---@class manipulator.Region
---@field buf integer buffer number
---@field protected range Range4? injected field in case of manipulator.BufRange extending
---@field protected text string? injected field to source the text from
---@field protected lines string[]? injected field to source the text from
---@field protected config manipulator.Region.Config
local Region = {}
Region.__index = Region

---@class manipulator.Region.Config: manipulator.Inheritable
---@field jump? manipulator.Region.jump.Opts
---@field select? manipulator.Region.select.Opts
---@field paste? manipulator.Region.paste.Opts
---@field swap? manipulator.Region.swap.Opts
---@field queue_or_run? manipulator.Region.queue_or_swap.Opts
---@field presets? {[string]:manipulator.Region.Config}

Region.opt_inheritance = {
	mod = true,
	jump = true,
	select = 'jump',
	paste = true,
	swap = true,
	queue_or_run = 'swap',
}

---@class manipulator.Region.module: manipulator.Region
---@field class manipulator.Region
local M = U.static_wrap_for_oop(Region, {})

---@class manipulator.Region.module.Config: manipulator.Region.Config
---@field current? manipulator.Region.module.current.Opts

---@type manipulator.Region.module.Config
M.default_config = {
	jump = { rangemod = MODS.trimmed },
	select = { linewise = 'auto' },

	inherit = false,
	presets = {},
}
---@type manipulator.Region.module.Config
M.config = M.default_config
---@param config manipulator.Region.module.Config
function M.setup(config) -- TODO: put config into Region -||-TSRegion to simplify new() inheritance
	M.config = U.module_setup(M.config.presets, M.default_config, config, Region.opt_inheritance)
	return M
end

---@protected
---@generic O: table
---@param opts? O|string user options to get expanded - updated **inplace**
---@param action? string
---@return O # opts expanded for the given method
function Region:action_opts(opts, action)
	return U.get_opts_for_action(self.config or M.config, opts, action, self.opt_inheritance)
end

---@param base manipulator.RangeType|{lines?:string[],text?:string}
---@return self
function Region:new(base)
	self = setmetatable(base or {}, self.buf and getmetatable(self) or self)
	if (self.buf or 0) == 0 then self.buf = vim.api.nvim_get_current_buf() end
	return self
end

---@return integer|false # comparison of inclusion of range
---   - `false` if from different buffers
---   - `>0` if {b} is fully enclosed by {a}, `0` when equal, `<0` otherwise
function Region:contains(new)
	local b1, r1 = RANGE_U.decompose(self, true)
	local b2, r2 = RANGE_U.decompose(new, true)
	return b1 == b2 and RANGE_U.rangeContains(r1, r2) or false
end

function Region:eq(new) return self:contains(new) == 0 end

---@generic S: manipulator.Region
---@generic O
---@param self `S`
---@param fun fun(self:S):`O`?
---@return O
function Region:map(fun) return fun(self) end

---@protected
function Region:__tostring() return self:get_lines(true)[1] or 'NilRegion' end

function Region:print() print(tostring(self)) end

---@return Range4 0-indexed range
function Region:range0()
	local range = self[1] and self or self.range
	return range and { range[1], range[2], range[3], range[4] } or RANGE_U.offset(self:range1(), -1)
end

---@return Range4 1-indexed range
function Region:range1() return RANGE_U.offset(self:range0(), 1) end

--- Get beginning of this range
---@return Range4 0-indexed point prepared as a range
function Region:start()
	local _, r = RANGE_U.decompose(self)
	r[3] = r[1]
	r[4] = r[2]
	return r
end

--- Get beginning of this range
---@return Range4 0-indexed point prepared as a range
function Region:end_()
	local _, r = RANGE_U.decompose(self)
	r[1] = r[3]
	r[2] = r[4]
	return r
end

---@param override? {config?:table} modifications to apply to the cloned object
---@return self
function Region:clone(override)
	return setmetatable(U.tbl_inner_extend('keep', override or {}, self, 4), getmetatable(self))
end

--- Create a copy of this node with different defaults. (always persistent)
--- Compared to `:clone()` the contents get reprocessed as if creating a new node.
---@generic O: manipulator.Region.Config
---@param config O|string
---@return self
function Region:with(config)
	return self:new {
		range = self.range and {} or nil,
		config = self:action_opts(config),
	}
end

---@alias RangeMod (fun(self:manipulator.Region,opts):Range4)|'start'|'end'
---@class manipulator.Region.rangemod.Opts
--- What to base the calculations off of (default: self) - pre-processor
--- - usually used for `'start'|'end'` or to set a new absolute `Range4` (`false` for `self`)
---@field base? false|'start'|'end'|Range4
--- Transform the range of the region before manipulation (i.e. include comma after the text etc.)
--- Signle or multiple RangeMod functions taking `(self,opts)` into `Range4`
---@field rangemod? false|RangeMod|RangeMod[]

---@protected
--- Apply various modifications to the range, directly modifying the range of self
---@param opts manipulator.Region.mod.Opts|table
---@param postprocess? manipulator.Region.mod.Opts|table|RangeMod[] final modifications specific to the caller action
--- - usually used for `'start'|'end'` or a last rangemod (linewise, trim, etc.)
---@return Range4
function Region:rangemod(opts, postprocess)
	local r = postprocess and postprocess.base or opts.base or select(2, RANGE_U.decompose(self))
	if type(r) == 'string' then r = Region[r ~= 'start' and 'end_' or r](r) end

	for stage, batch in ipairs { opts.rangemod, postprocess } do
		-- merging to pass postprocess options to the user
		if stage == 3 then opts = U.tbl_inner_extend('keep', postprocess or {}, opts) end
		for _, v in ipairs(type(batch) == 'table' and batch or { batch or nil }) do
			self.range = r
			if type(v) == 'string' then
				r = Region[v ~= 'start' and 'end_' or v](r)
			else
				r = v(self, opts)
			end
		end
	end

	return r
end

---@class manipulator.Region.mod.Opts: manipulator.Region.rangemod.Opts
---@field text? string
---@field text_relative? false|'start'|'end' should the range be adjusted to text size and to which end
---@field ignore_last_nl? boolean should the last newline not count (default: true)
--- How to decide if the region should be made linewise from end to end.
--- - 'auto': if all excluded chars are whitespace on the active lines
--- - 'last_nl': if the text ends with '\n'
---@field linewise? boolean|'auto'|'last_nl'

--- Create a new region with modifications (range dimensions / text content...)
--- Compared to `:with()` this creates just a region - doesn't try to inherit anything.
---@see manipulator.Region.rangemod
---@param opts manipulator.Region.mod.Opts|table changes to be made + config for `.rangemod`. Order of changes:
--- - 1. `rangemod` on the current region
--- - 2. `text` is set and range adjusted based on `text_relative`
--- - 3. `linewise` gets applied (use together with `text` is discouraged)
---@return manipulator.Region
function Region:mod(opts)
	opts = opts or {}
	local r = Region.rangemod(self, opts)

	local text = opts.text or Region.get_text(self)
	local lw = opts.linewise ~= 'last_nl' and opts.linewise or text:sub(#text) == '\n'

	if opts.ignore_last_nl ~= false and text:sub(#text) == '\n' then text = text:sub(1, #text - 1) end
	local lines = vim.split(text, '\n')
	if opts.text_relative == 'start' then
		r[3] = r[1] + (#lines - 1)
		r[4] = (#lines == 1 and r[2] or 0) + (#lines[#lines] - 1)
	elseif opts.text_relative == 'end' then
		r[1] = r[3] - (#lines - 1)
		r[2] = (#lines == 1 and (r[4] - (#lines[#lines] - 1)) or 0)
	end

	if lw then r = MODS.linewise(r, { linewise = lw }) end

	return Region:new { range = r, buf = self.buf, text = text, lines = lines }
end

---@param limit_or_fn? integer|manipulator.Batch.Action max iterations per action (-1= `M.config.recursive_limit`)
---@param ... manipulator.Batch.Action item method sequences to apply recursively and collect node of each iteration
---@return manipulator.Batch
function Region:collect(limit_or_fn, ...)
	local limit = type(limit_or_fn) == 'number' and limit_or_fn or (not limit_or_fn and -1)
	if limit then
		return Batch.from_recursive(self, limit_or_fn, ...)
	else
		return Batch.from_recursive(self, -1, limit_or_fn, ...)
	end
end

---@param ... manipulator.Batch.Action item method sequences to apply and collect the result of
---@return manipulator.Batch
function Region:to_batch(...)
	if not select(1, ...) then
		return Batch.from(self, function() return self end)
	end
	return Batch.from(self, ...)
end

---@param self manipulator.RangeType
---@param cut_to_range? boolean if false, returns entire lines the region is in (default: true)
---@return string[]
function Region:get_lines(cut_to_range)
	return self.text and cut_to_range ~= false and vim.split(self.text, '\n')
		or self.lines
		or RANGE_U.get_lines(self, cut_to_range)
end

---@param self manipulator.RangeType
---@return string # Concatenated lines of the region
function Region:get_text() return self.text or table.concat(Region.get_lines(self, true), '\n') end

function Region:as_qf_item()
	local r1 = self:range1()
	return {
		bufnr = self.buf,
		lnum = r1[1],
		col = r1[2],
		end_lnum = r1[3],
		end_col = r1[2],
		text = self:__tostring(),
	}
end

---@param action? 'a'|'r' `vim.fn.setqflist` action to perform - append or replace (default: 'a')
function Region:add_to_qf(action) vim.fn.setqflist({ self:as_qf_item() }, action or 'a') end

---@class manipulator.Region.set_reg.Opts: manipulator.Region.rangemod.Opts
---@field register? string defaults to `vim.v.register`
---@field type? 'v'|'V' by default determines by text being from start to end

---@param opts manipulator.Region.set_reg.Opts
function Region:set_reg(opts)
	local r = Region.rangemod(self, opts)
	local type = opts.type or (r[2] == 0 and r[4] == vim.v.maxcol and 'V' or 'v')
	vim.fn.setreg(opts.register or vim.v.register, self.get_text(r), type)
end

do
	local hl_ns = vim.api.nvim_create_namespace 'manipulator_hl'

	--- Highlight or remove highlighting from given range (run on NilRegion to clear the whole buffer)
	---@param group? string|integer|false highlight group to highlight with or ID of the mark to clear (default: toggles clear and add)
	---@return integer? # id of the created extmark
	function Region:highlight(group)
		local buf, range = RANGE_U.decompose(self)
		if not group or type(group) == 'number' then
			local id = group or self.hl_id
			if not id then
				local r = self:range0() ---@type table
				r = vim.api.nvim_buf_get_extmarks(buf, hl_ns, { r[1], r[2] }, { r[3], r[4] }, {})[1]
				if r then id = r[1] end
			end

			if id then
				vim.api.nvim_buf_del_extmark(buf, hl_ns, id)
				return
			end
		elseif not range[1] then
			vim.notify('Cannot highlight Nil', vim.log.levels.INFO)
			return
		end

		self.hl_id = vim.api.nvim_buf_set_extmark(buf, hl_ns, range[1], range[2], {
			end_row = range[3],
			end_col = range[4] + 1,
			hl_group = group or 'IncSearch',
		})
	end
end

---@param char string character for the mark
---@return self
function Region:mark(char)
	local buf, range = RANGE_U.decompose(self)
	vim.api.nvim_buf_set_mark(buf, char, range[1] + 1, range[2], {})

	return self
end

---@class manipulator.Region.jump.Opts: manipulator.Region.rangemod.Opts
---@field insert? boolean should we enter insert mode (default: false)

--- Jump to the start (or end, if `opts.end_`) of the region.
---@param opts? manipulator.Region.jump.Opts range defaults to 'end'
--- - range options (which end to jump to) apply only outside visual modes
function Region:jump(opts)
	opts = self:action_opts(opts, 'jump')
	local r = self:rangemod(opts)
	RANGE_U.jump({ buf = self.buf, range = opts.end_ and { r[3], r[4] } or { r[1], r[2] } }, opts.end_, opts.insert)
end

---@class manipulator.Region.select.Opts: manipulator.Region.jump.Opts
---@field allow_grow? boolean if true, add to current visual selection (default: false)
---@field insert? boolean if coming from insert mode should we return to it after ending the selection (like `<C-o>v`) (default: false)
---@field allow_select_mode? boolean if coming from insert mode should we enter select or visual mode. Cannot be combined with `return_to_insert` (default: false=visual mode only)

--- Select node in visual/select mode.
---@param opts? manipulator.Region.select.Opts
function Region:select(opts)
	opts = self:action_opts(opts, 'select')
	if (self.buf or 0) ~= 0 then vim.api.nvim_win_set_buf(0, self.buf) end

	local r = self:rangemod(opts)

	local visual, leading, c_mode = RANGE_U.current_visual()
	if visual and opts.allow_grow then
		r[1] = math.min(r[1], visual[1])
		r[2] = math.min(r[2], visual[2])
		r[3] = math.max(r[3], visual[3])
		r[4] = math.max(r[4], visual[4])
	end

	local text_mode = MODS.linewise(r, { linewise = opts.linewise })[4] == vim.v.maxcol and 'V' or 'v'
	if c_mode ~= text_mode then
		if c_mode == 'i' then
			if not opts.allow_select_mode then vim.cmd.stopinsert() end -- updates in the next tick
			r[4] = r[4] + 1 -- fix insert shortening moved cursor in this tick
			if opts.insert then vim.cmd { cmd = 'normal', bang = true, args = { '\015' } } end
		else
			vim.cmd { cmd = 'normal', bang = true, args = { '\027' } }
		end
		vim.cmd { cmd = 'normal', bang = true, args = { text_mode } }
	end

	-- vim line is 1-indexed, col is 0-indexed
	vim.api.nvim_win_set_cursor(0, { r[1] + 1, r[2] })
	vim.cmd.normal 'o'
	vim.api.nvim_win_set_cursor(0, { r[3] + 1, r[4] })
	if opts.end_ == false or leading then vim.cmd.normal 'o' end
end

---@class manipulator.Region.paste.Opts
---@field dst? manipulator.RangeType where to put the text relative to (default: self)
---@field text? string text to paste or '"x' to paste from register `x` (default: `self:get_text()`)
---@field mode? 'before'|'after'|'over' method of modifying the dst range text content, doesn't support 'swap' mode
---@field linewise? boolean

--- Paste like with visual mode motions - prefer using vim motions
---@param opts manipulator.Region.paste.Opts
---@return manipulator.Region # region of the pasted text
function Region:paste(opts)
	opts = self:action_opts(opts, 'paste')
	local buf, range = RANGE_U.decompose(opts.dst or self, true)
	if not buf or not range[1] then
		vim.notify('Invalid dst to paste to', vim.log.levels.INFO)
		return self.Nil
	end
	local text = opts.text
	if not text and opts.dst then
		text = self:get_text()
	elseif not text or text:match '^".$' then
		local reg = text and text:sub(2) or vim.v.register
		text = vim.fn.getreg(reg)

		if not text then
			vim.notify('Register ' .. reg .. ' is empty', vim.log.levels.INFO)
			return self.Nil
		end
	end

	if opts.linewise then
		if (opts.mode or 'over') == 'over' then
			-- if we're not replacing the line fully, make sure to insert on a fully separate line
			if range[2] > 0 then text = '\n' .. text end
			if range[4] < #vim.api.nvim_buf_get_lines(buf, range[3], range[3] + 1, true)[1] - 1 then
				text = text .. '\n'
			end
		else
			if opts.mode == 'after' then range[1] = range[3] + 1 end
			range[3] = range[1]
			range[2] = 0
			range[4] = -1
			text = text .. '\n'
		end
	else
		if opts.mode == 'before' then
			range[3] = range[1]
			range[4] = range[2] - 1
		elseif opts.mode == 'after' then
			range[1] = range[3]
			range[2] = range[4] + 1
		end -- else mode = 'over'
	end

	vim.lsp.util.apply_text_edits({
		{ range = RANGE_U.lsp_range(range), newText = text },
	}, buf, 'utf-8')

	return self:mod { base = range, text = text, text_relative = 'start', ignore_last_nl = true }
end

---@class manipulator.Region.swap.Opts
---@field dst manipulator.RangeType direct destination to move to
---@field cursor_with? # which object should the cursor end up at
---| 'current' track object under cursor (default)
---| 'dst'
---| 'src' move with the said object
---| false let the weird mangling begin
---@field visual? boolean|manipulator.VisualModeEnabler which visual modes can be updated (use `{}` to disable) (default: true=all)

-- TODO: try to shrink code with M.from_text math
--- Swap two regions. (buffers can differ)
--- Maintains cursor (and visual selection) on the region specified via `opts.cursor_with`.
---@param opts manipulator.Region.swap.Opts
function Region:swap(opts)
	opts = self:action_opts(opts, 'swap')
	local sbuf, srange = RANGE_U.decompose(self, true)
	local dbuf, drange = RANGE_U.decompose(opts.dst, true)
	if not srange[1] or not drange[1] then
		vim.notify('Invalid range', vim.log.levels.INFO)
		return
	end

	-- Calculate relative cursor positions to the colser of the regions or fallback start-to-end
	local c_with = opts.cursor_with or 'current'
	if c_with == 'current' then
		local c = vim.api.nvim_win_get_cursor(0)
		c[1] = c[1] - 1
		c_with = RANGE_U.posInRange(srange, c, true) and 'src'
			or (RANGE_U.posInRange(drange, c, true) and 'dst')
			or false
	end
	--[[
	cases:
	- pos in the object:
	- or in the other object:
	- or jump to start
	]]
	local c_at_src = c_with == 'src'
	local c_pos, c_end, v_pos, v_end -- relative pos to the start or end of the region
	if c_with then
		local range, leading = RANGE_U.current_visual(opts.visual == false and {} or opts.visual, false)
		if not range or opts.visual == false then
			c_pos = vim.api.nvim_win_get_cursor(0)
			c_pos[1] = c_pos[1] - 1
			if range then vim.cmd { cmd = 'normal', bang = true, args = { '\027' } } end
		else
			if leading then
				c_pos, v_pos = range, { range[3], range[4] }
			else
				v_pos, c_pos = range, { range[3], range[4] }
			end
		end

		-- calculate the relative position to the closer of the regions
		do
			local rel_range = srange
			local rel_pos, is_end = RANGE_U.posInRange(rel_range, c_pos, true)
			if not rel_pos then
				rel_range = drange
				c_pos, c_end = RANGE_U.posInRange(rel_range, c_pos, true)
			else
				c_pos, c_end = rel_pos, is_end
			end
		end

		local size = c_at_src and srange or drange
		size = RANGE_U.subRange({ size[3], size[4] }, size)

		if
			v_pos -- if visual is allowed then always select to the whole region
			or not c_pos
			or RANGE_U.cmpPoint(c_end and RANGE_U.subRange({ 0, 0 }, c_pos) or c_pos, size) > 0
			or (v_pos and RANGE_U.cmpPoint(v_end and RANGE_U.subRange({ 0, 0 }, v_pos) or v_pos, size) > 0)
		then -- cursor outside manipulated ranges -> select start-to-end
			c_pos, c_end = { 0, 0 }, c_end
			if v_pos then
				v_pos, v_end = { 0, 0 }, not c_end
			end
		end
	end

	local s_edit = { range = RANGE_U.lsp_range(srange), newText = self.get_text(opts.dst) }
	local d_edit = { range = RANGE_U.lsp_range(drange), newText = self:get_text() }

	local t_range = c_at_src and srange or drange
	if sbuf ~= dbuf then
		vim.lsp.util.apply_text_edits({ s_edit }, sbuf, 'utf-8')
		vim.lsp.util.apply_text_edits({ d_edit }, dbuf, 'utf-8')

		if c_with then
			local n_start = c_at_src and drange or srange
			local n_buf = c_at_src and dbuf or sbuf
			if v_pos then
				RANGE_U.jump(RANGE_U.addRange(RANGE_U.subRange({ t_range[3], t_range[4] }, t_range), n_start))
				vim.cmd.normal 'o'
			end
			RANGE_U.jump { buf = n_buf, range = n_start }
		end
	else
		-- always jump to the tracked region to calculate the shift afterwards
		if c_with then RANGE_U.jump { buf = sbuf, range = c_at_src and drange or srange } end
		vim.lsp.util.apply_text_edits({ s_edit, d_edit }, sbuf, 'utf-8')

		-- TODO: make Region inherit from Range
		if
			c_with and (v_pos or c_end or c_pos[1] ~= 0 or c_pos[2] ~= 0) -- update position if jump wasn't enough
		then
			local n_start = RANGE_U.get_point_bufrange(nil, false).range
			local n_end =
				RANGE_U.addRange(RANGE_U.subRange({ t_range[3], t_range[4] }, t_range), { n_start[1], n_start[2] })

			if v_pos then
				RANGE_U.jump(RANGE_U.addRange(v_pos, v_end and n_end or n_start))
				vim.cmd.normal 'o'
			end
			RANGE_U.jump(RANGE_U.addRange(c_pos, c_end and n_end or n_start))
		end
	end

	return -- TODO: should return updated region, maybe option for which of the two
end

do
	---@type table<string,manipulator.Region?>
	local queued_map = {}

	---@class manipulator.Region.queue_or_swap.Opts: manipulator.Region.swap.Opts
	---@field group? string used as a key to allow multiple pending moves
	---@field highlight? string|false highlight group to use, suggested to specify with custom {group} (default: 'IncSearch')
	---@field allow_grow? boolean if selected region can be updated to the current when its fully contained or should be deselected
	---@field run_on_queued? boolean should the action be run on the queued node or on the pairing one
	---@field dst? manipulator.RangeType ignored

	--- Move the node to a given position
	---@param opts? manipulator.Region.queue_or_swap.Opts included action options used only on run call
	---@return manipulator.Region? self returns itself if it was the first to be selected; nil, if selection was removed
	function Region:queue_or_swap(opts)
		opts = self:action_opts(opts, 'queue_or_run')
		if opts.highlight == nil then opts.highlight = 'IncSearch' end
		opts.group = opts.group or opts.highlight

		local active = queued_map[opts.group]
		if
			active
			and (
				not self.buf
				or not vim.api.nvim_buf_is_valid(active.buf)
				or (
					active.buf == self.buf -- cancel sellection if we sellect smaller node
					and RANGE_U.rangeContains(active:range0(), self:range0()) >= 0
				)
			)
		then
			if vim.api.nvim_buf_is_valid(active.buf) then
				queued_map[opts.group] = nil
				active:highlight(false)
				vim.notify('Unselected' .. (self.buf and ' - queued Nil' or ''), vim.log.levels.WARN)
				return
			end
			active = nil
		end

		if
			not active
			or (
				opts.allow_grow
				and active.buf == self.buf -- test if we contain the active range
				and RANGE_U.rangeContains(self:range0(), active:range0()) >= 0
			)
		then
			if active then active:highlight(false) end
			queued_map[opts.group] = self
			if opts.highlight then self:highlight(opts.highlight) end
			return self
		else
			opts.dst = active
			self:swap(opts)
			active:highlight(false)
			queued_map[opts.group] = nil
		end
	end
end

do -- ### Wrapper for nil matches
	---@class manipulator.Region.Nil: manipulator.Region
	local NilRegion = { config = { inherit = false, presets = {} } }
	function NilRegion:__tostring() return 'Nil' end
	-- allow queue_or_run() to deselect the group and collect() to return an empty Batch
	local passthrough = {
		print = true,
		opt_inheritance = true,
		action_opts = true,
		highlight = true,
		collect = true,
		queue_or_swap = true,
	}
	function NilRegion:__index(key)
		if passthrough[key] or type(Region[key]) ~= 'function' then return Region[key] end
		return function()
			vim.notify('Cannot ' .. key .. ' Nil')
			return self
		end
	end

	---@protected
	Region.Nil = setmetatable(NilRegion, NilRegion)
end

---@class manipulator.Region.module.current.Opts options for retrieving various kinds of user position
---@field src? # where to source the position / range from
---| 'prefer-visual'|manipulator.VisualModeEnabler # map of modes for which to return visual range, fallback to cursor (default)
---| 'operator' # behave like an operator - get the result of the last motion; provide mode info with `vim.g.manip_opmode`
---| pos_expr # cursor/mouse # use mouse click, or hover / current pos (for a kbd bind) when 'mousemoveevent' is enabled
---| string|"'x" # to use the position of the mark `x`
---@field linewise?
---| 'extend' # when in 'V' mode extend the cursor range to full lines (default)
---| 'ignore' # when in 'V' mode behave like in 'v' mode - cut the range to the cursor bounds
---| 'always' # make the selection always linewise, even if the current mode isn't visual
---@field insert_fixer? string|false luapat to match the char under cursor to determine if c-1 column should be used when in 'i'/'s' mode

--- Get mouse click position or currently selected region and cursor position
---@param opts? manipulator.Region.module.current.Opts use {} for disabling visual mode
---@return manipulator.Region # object of the selected region (point or range)
---@return boolean is_visual true if the range is from visual mode or `mode='operator'`
--- - can return false while user is in visual mode
function M.current(opts)
	opts = M:action_opts(opts, 'current')

	-- TODO: this should all be just one and only method in range utils
	local buf, r, mode
	if opts.src == 'operator' or (not opts.mode and vim.g.manip_opmode) then
		r, buf = RANGE_U.get_range("'[", "']", false)

		mode = vim.g.manip_opmode == 'linewise' and 'V' or 'v'
	elseif (opts.mode or 'prefer-visual') == 'prefer-visual' or type(opts.mode) == 'table' then
		r, buf, mode = RANGE_U.current_visual(opts.mode, opts.insert_fixer)
	end

	if not r then
		r = RANGE_U.get_point_bufrange(opts.src, opts.insert_fixer)
		buf, r, mode = r.buf, r.range, nil
	end

	local lw = opts.linewise or 'extend'
	if lw ~= 'ignore' and (mode == 'V' or lw == 'always') then
		r[2] = 0
		r[4] = #vim.api.nvim_buf_get_lines(0, r[3], r[3] + 1, true)[1] - 1
	end

	return Region:new { buf = buf, range = r }, not not mode
end

return M
