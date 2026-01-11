local U = require 'manipulator.utils'
local Range = require 'manipulator.range'
local MODS = require 'manipulator.range_mods'
local Batch = require 'manipulator.batch'

---@class manipulator.Region: manipulator.BufRange
---@field buf integer buffer number
---@field range manipulator.Range can be just Range4 if injected - will get converted on creation
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

Region.action_map = {
	mod = true,
	jump = true,
	select = 'jump',
	paste = true,
	swap = true,
	queue_or_run = 'swap',

	current = true,
}

---@class manipulator.Region.module: manipulator.Region
---@field class manipulator.Region
local M = U.get_static(Region, {})

---@class manipulator.Region.module.Config: manipulator.Region.Config
---@field current? manipulator.Region.module.current.Opts

---@type manipulator.Region.module.Config
M.default_config = {
	inherit = false,
	jump = { rangemod = { MODS.trimmed } },
	select = { linewise = 'auto', end_ = true },
	swap = { visual = true, cursor_with = 'current' },

	current = { fallback = '.', end_shift_ptn = '^$' },

	presets = {},
}
---@type manipulator.Region.module.Config
M.config = M.default_config
M.config.presets.active = M.config
---@param config manipulator.Region.module.Config
function M.setup(config)
	M.config = U.module_setup(M.config.presets, M.default_config, config, Region.action_map)
	return M
end

---@protected
---@generic O: table
---@param opts? O|string user options to get expanded - updated **inplace**
---@param action? string
---@return O # opts expanded for the given method
function Region:action_opts(opts, action) return U.expand_action(self.config or M.config, opts, action, self.action_map) end

---@param base anypos|{lines?:string[],text?:string}
---@return self
function Region:new(base)
	---@type	manipulator.Region
	self = setmetatable(base[1] and { range = base } or base, self.buf and getmetatable(self) or self)
	self.range = Range.get_or_make(self)
	self.buf = Range.get_real_buf(self.range)
	self.range.buf = self.buf
	return self
end

---@generic O,S: manipulator.Region
---@param self S
---@param fun fun(self:S, ...):O?
---@return O
function Region:map(fun, ...) return fun(self, ...) end

---@protected
function Region:__tostring() return self:get_lines(true)[1] or 'NilRegion' end

function Region:print() print(tostring(self)) end

Region.start = Range.start
Region.end_ = Range.end_

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

---@alias RangeMod (fun(self:manipulator.Range,opts):manipulator.Range)|'start'|'end'
---@class manipulator.Region.rangemod.Opts
--- What to base the calculations off of (default: self) - pre-processor
--- - usually used for `'start'|'end'` or to set a new absolute `Range4` (`false` for `self`)
---@field base? false|'start'|'end'|anypos
--- Transform the range of the region before manipulation (i.e. include comma after the text etc.)
--- Signle or multiple RangeMod functions taking `(self,opts)` into `Range4`
---@field rangemod? false|RangeMod|RangeMod[]

--- Apply various modifications to the range, directly modifying the range of self
---@param opts manipulator.Region.rangemod.Opts|table
---@param postprocess? manipulator.Region.rangemod.Opts|table|RangeMod|RangeMod[] final modifications specific to the caller action
--- - usually used for `'start'|'end'` or a last rangemod (linewise, trim, endshift, etc.)
---@return manipulator.Range
function Region:rangemod(opts, postprocess)
	local o_r = self.range
	local r = opts.base or (type(postprocess) == 'table' and postprocess.base) or Range.get_or_make(self)
	if type(r) == 'string' then
		r = self.range[r ~= 'start' and 'end_' or r](self)
	else
		r = Range.get_or_make(r)
	end

	for _, batch in ipairs { opts.rangemod, postprocess } do
		-- merging to pass postprocess options to the user
		if batch == postprocess and type(postprocess) == 'table' then
			opts = U.tbl_inner_extend('keep', postprocess, opts)
		end

		for _, v in ipairs(type(batch) == 'table' and batch or { batch or nil }) do
			self.range = r
			if type(v) == 'string' then
				r = Region[v ~= 'start' and 'end_' or v](r)
			else
				r = v(self, opts)
			end
		end
	end

	self.range = o_r
	return r
end

---@class manipulator.Region.mod.Opts: manipulator.Region.rangemod.Opts
--- Use the given text for processing further (not rangemod) options
--- - `true` to use the text of the region
--- - `false` to use the text of the range after `rangemod` processing (default)
---@field text? boolean|string
---@field text_relative? false|'start'|'end' should the range be adjusted to text size and to which end
---@field keep_last_nl? boolean should the last newline be counted as a new line, or trimmable end
--- How to decide if the region should be made linewise from end to end.
--- - 'auto': if all excluded chars are whitespace on the active lines
--- - 'last_nl': if the text ends with '\n'
---@field linewise? 'last_nl'|linewise_opt

--- Create a new region with modifications (range dimensions / text content...)
--- Compared to `:with()` this creates just a region - doesn't try to inherit settings or type.
--- If only rangemod options are set, then only rangemod is executed and no text changes are made.
---@see manipulator.Region.rangemod
---@param self anypos
---@param opts manipulator.Region.mod.Opts|table changes to be made + config for `.rangemod`. Order of changes:
--- - 1. `rangemod` on the current region
--- - 2. `text` is set and range adjusted based on `text_relative`
--- - 3. `linewise` gets applied (use together with `text` is discouraged)
---@return manipulator.Region
function Region:mod(opts)
	opts = opts or {}
	local text = opts.text == true and Region.get_text(self) or opts.text
	local r = Region.rangemod(self, opts)

	text = text or Region.get_text(r)

	local lw = opts.linewise
	if lw == 'last_nl' then lw = text:sub(#text) == '\n' end

	if not opts.keep_last_nl and text:sub(#text) == '\n' then text = text:sub(1, #text - 1) end
	local lines = vim.split(text, '\n')
	if opts.text_relative == 'start' then
		r[3] = r[1] + (#lines - 1)
		r[4] = (#lines == 1 and r[2] or 0) + (#lines[#lines] - 1)
	elseif opts.text_relative == 'end' then
		r[1] = r[3] - (#lines - 1)
		r[2] = (#lines == 1 and (r[4] - (#lines[#lines] - 1)) or 0)
	end

	if lw then r = MODS.linewise(r, opts, lw) end

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

Region.get_lines = Range.get_lines
Region.get_text = Range.get_text

function Region:as_vim_list_item()
	local r = self.range
	return {
		bufnr = self.buf,
		lnum = r[1] + 1,
		col = r[2] + 1,
		end_lnum = r[3] + 1,
		end_col = r[2] + 1,
		text = self:__tostring(),
	}
end

---@param action? 'a'|'r' `vim.fn.setqflist` action to perform - append or replace (default: 'a')
function Region:add_to_qf(action) vim.fn.setqflist({ self:as_vim_list_item() }, action or 'a') end

---@param action? 'a'|'r'|' ' `vim.fn.setloclist` action to perform - append or replace or push (default: 'a')
function Region:add_to_ll(action) vim.fn.setloclist(0, { self:as_vim_list_item() }, action or 'a') end

---@class manipulator.Region.set_reg.Opts: manipulator.Region.rangemod.Opts
---@field register? string defaults to `vim.v.register`
---@field type? 'v'|'V' by default determines by text being from start to end

---@param self anypos
---@param opts manipulator.Region.set_reg.Opts
function Region:set_reg(opts)
	local r = Region.rangemod(self, opts)
	local type = opts.type or (r[2] == 0 and r[4] == vim.v.maxcol and 'V' or 'v')
	vim.fn.setreg(opts.register or vim.v.register, Region.get_text(r), type)
end

do
	local hl_ns = vim.api.nvim_create_namespace 'manipulator_hl'

	--- Highlight or remove highlighting from given range (run on NilRegion to clear the whole buffer)
	---@param self anypos
	---@param group? string|integer|false highlight group to highlight with or ID of the mark to clear (default: toggles clear and add)
	---@return integer? # id of the created extmark
	function Region:highlight(group)
		local r = Range.raw(self)
		if not group or type(group) == 'number' then
			local id = group
				or self.hl_id
				or U.get_or(
					vim.api.nvim_buf_get_extmarks(self.buf or 0, hl_ns, { r[1], r[2] }, { r[3], r[4] }, {})[1],
					{}
				)[1]

			if id then
				vim.api.nvim_buf_del_extmark(self.buf or 0, hl_ns, id)
				return
			end
		elseif not r[1] then
			vim.notify('Cannot highlight Nil', vim.log.levels.INFO)
			return
		end

		self.hl_id = vim.api.nvim_buf_set_extmark(self.buf or 0, hl_ns, r[1], r[2], {
			end_row = r[3],
			end_col = r[4] + 1,
			hl_group = group or 'IncSearch',
		})
	end
end

---@param self anypos
---@param char string character for the mark (suggested to prefix it with `'` for consistency)
---@param opts? {end_: boolean} which end should we mark
---@return self
function Region:mark(char, opts)
	local range = Region[opts and opts.end_ and 'end_' or 'start'](self)
	vim.api.nvim_buf_set_mark(self.buf or 0, char:sub(#char), range[1] + 1, range[2], {})

	return self
end

---@class manipulator.Region.jump.Opts: manipulator.Region.rangemod.Opts,manipulator.range_mods.end_shift.Opts
---@field insert? boolean enter insert mode and adjust the range end for it (default: false)
---@field end_? boolean jump to the end? (or start of the range - default)

--- Jump to the start (or end, if `opts.end_`) of the region.
---@param opts? manipulator.Region.jump.Opts|string opts and modifications of the jump location
function Region:jump(opts)
	opts = self:action_opts(opts, 'jump')

	-- TODO: test how going insert before the correct location affects the undo position
	if opts.insert then vim.cmd.startinsert() end

	Range.jump({
		buf = self.buf,
		range = Region.rangemod(self, opts, { shift_mode = 'insert', MODS.end_shift }),
	}, opts.end_)
end

---@class manipulator.Region.select.Opts: manipulator.Region.jump.Opts,manipulator.range_mods.linewise.Opts
--- If coming from insert mode:
--- - `temporary-visual`: return to insert mode after the selection is finished
--- - `visual`: exit insert mode and start a normal visual selection (default)
--- - `select`: enter select mode
---@field from_insert? 'temporary-visual'|'visual'|'select'

--- Select node in visual/select mode.
---@param opts? manipulator.Region.select.Opts|string
function Region:select(opts)
	opts = self:action_opts(opts, 'select')

	local r = self:rangemod(opts)

	local end_ = opts.end_
	if U.validate_mode 'visual' then end_ = not select(2, Range.from('v', '.')) end

	local c_mode = vim.fn.mode()
	local text_mode = MODS.evaluate_linewise(r, opts) and 'V' or 'v'
	if c_mode ~= text_mode then
		if c_mode == 'i' then
			if opts.from_insert == 'temporary-visual' then
				local v = end_ and r or r:end_(true)
				local c = end_ and r:end_(true) or r
				vim.api.nvim_feedkeys(
					('\015%s%dgg0%d o%dgg0%d '):format(text_mode, v[1] + 1, v[2], c[1] + 1, c[2]),
					'n',
					false
				)
				return
			elseif opts.from_insert ~= 'select' then
				vim.cmd.stopinsert()
			end
			r[4] = r[4] + 1
		else
			vim.cmd.normal { bang = true, args = { '\027' } }
		end
		vim.cmd.normal { bang = true, args = { text_mode } }
	end

	Range.jump(r, not end_)
	vim.cmd.normal 'o'
	Range.jump(r, end_)
end

---@class manipulator.Region.paste.Opts
---@field dst? anypos where to put the text relative to (default: self)
---@field text? string text to paste or '"x' to paste from register `x` (default: `self:get_text()`)
---@field mode? 'before'|'after'|'over' method of modifying the dst range text content
---@field linewise? boolean

--- Paste like with visual mode motions - prefer using vim motions
---@param opts manipulator.Region.paste.Opts|string
---@return manipulator.Region # region of the pasted text
function Region:paste(opts)
	opts = self:action_opts(opts, 'paste')
	local r = Range.get_or_make(opts.dst or self)

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
			if r[2] > 0 then text = '\n' .. text end
			if r[4] < #r:end_():get_line() - 1 then text = text .. '\n' end
		else
			if opts.mode == 'after' then r[1] = r[3] + 1 end
			r[3] = r[1]
			r[2] = 0
			r[4] = -1 -- ensure we paste before any text on the line to avoid overriding
			text = text .. '\n'
		end
	else
		if opts.mode == 'before' then
			r[3] = r[1]
			r[4] = r[2] - 1
		elseif opts.mode == 'after' then
			r[1] = r[3]
			r[2] = r[4] + 1
		end -- else mode = 'over'
	end

	vim.lsp.util.apply_text_edits({
		{ range = r:to_lsp(), newText = text },
	}, r:get_real_buf(), 'utf-8')

	return self:mod {
		base = r,
		text = text,
		text_relative = 'start',
		linewise = not not opts.linewise,
		keep_last_nl = false,
	}
end

---@class manipulator.Region.swap.Opts
--- Which object should the cursor end up at
--- - `'dst'|'src'|false`: track the object or do nothing
--- - `'current'`: track the object under cursor - translates to one of the above
---@field cursor_with? 'current'|'dst'|'src'|false
---@field visual? boolean|manipulator.VisualModeEnabler which visual modes can be updated
---@field single_buf? boolean enforce swapping to be only within the same buffer

--- Swap two regions. (buffers can differ)
--- Maintains cursor (and visual selection) on the region specified via `opts.cursor_with`.
---@param dst anypos direct destination to move to
---@param opts manipulator.Region.swap.Opts
---@return manipulator.Region cursor_destination
function Region:swap(dst, opts)
	opts = self:action_opts(opts, 'swap')
	local sr, dr = Range.get_or_make(self), Range.get_or_make(dst)
	-- TODO: implement vertical swap - conditional switch to outer block (probably just in TS)
	if Range.intersection(sr, dr) then error 'vertical swap not implemented (overlap found)' end

	-- Store current cursor position to correct it later
	local v_pos = opts.visual
		and U.validate_mode(opts.visual == true and 'visual' or opts.visual)
		and Range.super.from 'v'
	local c_pos = Range.super.from '.'

	-- Execute the actual edit
	local s_edit = { range = sr:to_lsp(), newText = self.get_text(dst) }
	local d_edit = { range = dr:to_lsp(), newText = self:get_text() }

	local buf = Range.buf_eq(sr, dr, 0)
	if not buf then
		if opts.single_buf then error 'Cross-buffer swapping user-disabled' end

		vim.lsp.util.apply_text_edits({ s_edit }, sr:get_real_buf(), 'utf-8')
		vim.lsp.util.apply_text_edits({ d_edit }, dr:get_real_buf(), 'utf-8')
	else
		vim.lsp.util.apply_text_edits({ s_edit, d_edit }, Range.get_real_buf { buf = buf }, 'utf-8')
	end

	-- Determine which region to track (src or dst)
	---@type manipulator.Range.rel_pos.Opts
	local rpo = { accept_one_col_after = true, relative_end_min = 0 }
	local c_at = sr:rel_pos(c_pos, rpo) and 'src' or dr:rel_pos(c_pos, rpo) and 'dst' or false
	local c_wanted = opts.cursor_with
	if c_wanted == 'current' then c_wanted = c_at or 'src' end
	if not c_wanted then return Region.Nil end

	-- Calculate relative cursor positions to the closer of the regions or fallback start-to-end
	local c_end, v_end ---@type boolean? relative to which end of the range is c_pos/v_pos
	local c_from, c_to = c_wanted == 'src' and sr or dr, c_wanted == 'src' and dr or sr
	if c_at then
		c_pos, c_end = (c_at == 'src' and sr or dr):rel_pos(c_pos, rpo)
		v_pos, v_end = (c_at == 'src' and sr or dr):rel_pos(v_pos or { -1, -1 }, rpo)
	else
		c_pos, c_end = Range.super.new { 0, 0 }, true
		v_pos, v_end = v_pos and c_pos, false
	end

	-- Set the target region - where the tracked object currently is
	local tr = c_from:moved_to(c_to):with_change(c_to:aligned_to(c_from), 'insert')

	-- Update the cursor
	if v_pos then
		(Range[v_end and 'end_' or 'start'](tr, true) + v_pos):jump()
		vim.cmd.normal 'o'
	end
	(Range[c_end and 'end_' or 'start'](tr, true) + c_pos):jump()

	return Region:new(tr)
end

do
	---@type table<string,manipulator.Region?>
	local queued_map = {}

	---@class manipulator.Region.queue_or_swap.Opts: manipulator.Region.swap.Opts
	---@field group? string used as a key to allow multiple pending moves (default: 'default')
	---@field hl_group? string|false highlight group to use (default: 'IncSearch')
	---@field allow_grow? boolean if selected region can be updated to the current when its fully contained or should be deselected
	---@field run_on_queued? boolean should the action be run on the queued node or on the pairing one

	--- Move the node to a given position
	---@param opts? manipulator.Region.queue_or_swap.Opts|string included action options used only on run call
	---@return manipulator.Region self returns itself if it was the first to be selected; Region.Nil, if selection was removed
	function Region:queue_or_swap(opts)
		opts = self:action_opts(opts, 'queue_or_run')
		if opts.hl_group == nil then opts.hl_group = 'IncSearch' end
		opts.group = opts.group or 'default'

		local active = queued_map[opts.group]
		if active and (not self.range or not vim.api.nvim_buf_is_valid(active.buf) or active.range:contains(self)) then
			if vim.api.nvim_buf_is_valid(active.buf) then
				queued_map[opts.group] = nil
				active:highlight(false)
				vim.notify('Unselected' .. (self.buf and '' or ' (queuing Nil)'), vim.log.levels.WARN)
				return Region.Nil
			end
			active = nil
		end

		if not active or (opts.allow_grow and self.range:contains(active)) then
			if active then active:highlight(false) end
			queued_map[opts.group] = self
			if opts.hl_group then self:highlight(opts.hl_group) end
			return self
		else
			active:highlight(false)
			queued_map[opts.group] = nil
			return self:swap(active, opts)
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

--- Options for retrieving various kinds of user position.
---@class manipulator.Region.module.current.Opts: manipulator.range_mods.linewise.Opts,manipulator.Region.rangemod.Opts
--- When to apply end_shift fixing (default: true = allow all modes with appropriate ptn format)
--- - `'point'` to exclude selections
--- - `opts.end_shift_ptn` is applied only in insert or select modes
---@field shift_mode? boolean|'point'
---@field end_shift_ptn? string shift if the last range char matches
--- Where to source the position / range from.
---  - `'visual'|manipulator.VisualModeEnabler`: try to get visual range of allowed modes (default)
--- - `'operator'`: behave like an operator
---   - get the result of the last motion
---   - _is the default when `vim.g.manip_opmode`_ is set
--- - `pos_expr`: cursor/mouse/mark
---   - `'mouse'` for mouse click, or hover (for a kbd bind) when vim 'mousemoveevent' is enabled
---@see manipulator.range_utils.get_point
---@field src? 'visual'|manipulator.VisualModeEnabler|'operator'|pos_expr|"'xy"
--- if the primary src fails, what should we try next
---@field fallback? false|pos_expr|anypos
--- When should we extend the range to full lines
--- - `'auto'`: extends when sourcing 'V'-mode position (default)
--- - `false`: never - 'V'-mode behaves like 'v' (bound by the '.' and 'v' positions)
--- - `true`: make the selection always linewise, even if the current mode isn't visual
---@field linewise? boolean|'auto'

--- Get mouse click position or currently selected region and cursor position
---@param opts? manipulator.Region.module.current.Opts
---@return manipulator.Region # object of the selected region (point or range)
---@return manipulator.VisualMode|'operator'|'fallback_range'|nil visual_type
--- If the return value is not a point, sends what type of range it is
--- - can return a falsy value while user is in visual mode
function M.current(opts)
	opts = M:action_opts(opts, 'current')

	local expr = opts.src
	local r, mode
	if expr == 'operator' or (not expr and vim.g.manip_opmode) then
		expr = 'operator'
		r = Range.from("'[", "']")
		mode = vim.g.manip_opmode == 'linewise' and 'V' or 'v'
	elseif not expr or expr == 'visual' or type(expr) == 'table' then
		expr = expr or 'visual'
		if U.validate_mode(expr) then
			r, mode = Range.from('v', '.')
			if mode == true then -- cursor is at the beginning -> check select mode and prevent range fix
				mode = vim.fn.mode()
				mode = mode == 'S' and 'V' or (mode == 's' and 'v') or mode
			else
				mode = vim.fn.mode()
			end
		end
	else
		r = Range.from(expr)
	end

	if not r then
		expr = opts.fallback
		if not expr then error('No fallback for failed src: ' .. vim.inspect(opts.src)) end
		r = type(expr) == 'table' and Range.get_or_make(expr) or Range.from(expr)
		if type(expr) == 'table' then mode = 'fallback_range' end
	end

	---@diagnostic disable-next-line: missing-fields
	if opts.rangemod then r = Region.rangemod({ range = r }, opts) end

	-- Shift the end by 1 if in insert mode or at EOL in visual mode
	if opts.shift_mode ~= false then
		local es_ptn = opts.end_shift_ptn or true
		if opts.shift_mode == 'point' or not mode or #mode > 1 then
			-- visual forbidden, mouse EOL only, i+s modes fully shiftable
			es_ptn = ({ [true] = '^$', i = es_ptn, s = es_ptn })[mode or expr == 'mouse' or vim.fn.mode()]
		elseif mode then
			-- remove only EOL in visual mode, but behave like insert for select mode
			es_ptn = (mode == 'v' or mode == 'V') and '^$' or es_ptn
		end
		if es_ptn then
			r = Range.get_or_make(MODS.end_shift(r, {
				shift_point_range = not mode,
				end_shift_ptn = es_ptn ~= true and es_ptn or nil, -- ensure the default can be used
			}))
		end
	end

	-- Extend to full lines (linewise visual mode or user override)
	local lw = U.get_or(opts.linewise, 'auto')
	if lw == 'auto' then lw = mode == 'V' or mode == 'S' end
	if lw then r = MODS.linewise(r, opts, lw) end

	return Region:new { range = r, mouse = expr == 'mouse' }, mode
end

return M
