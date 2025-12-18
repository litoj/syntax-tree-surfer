local UTILS = require 'manipulator.utils'
local RANGE_UTILS = require 'manipulator.range_utils'
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
---@field queue_or_run? manipulator.Region.queue_or_run.Opts
---@field presets? {[string]:manipulator.Region.Config}

Region.opt_inheritance = {
	jump = true,
	select = true,
	paste = true,
	swap = true,
	queue_or_run = true,
}

---@class manipulator.Region.module: manipulator.Region
---@field class manipulator.Region
local M = UTILS.static_wrap_for_oop(Region, {})

---@class manipulator.Region.module.Config: manipulator.Region.Config
---@field current? manipulator.Region.module.current.Opts

---@type manipulator.Region.module.Config
M.default_config = { inherit = false, presets = {} }
---@type manipulator.Region.module.Config
M.config = UTILS.tbl_inner_extend('force', {}, M.default_config, true, 'noref')
M.config.presets.active = M.config

--- Resolve option inheritance etc. and set automatic enabler tables index fallbacks.
---@generic O: manipulator.Region.Config
---@param config `O`|string user config to get expanded - updated inside
---@return O cfg expanded with all default config
function Region:expand_config(config)
	local orig = self.config or M.config
	return UTILS.expand_config(orig.presets, orig, config, self.opt_inheritance)
end

---@protected
---@generic O: manipulator.Region.Config
---@param opts? `O`|string user options to get expanded - updated into a copy
---@param action string
---@return O # opts expanded for the given method
function Region:action_opts(opts, action)
	return UTILS.get_opts_for_action(self.config or M.config, opts, action, self.opt_inheritance)
end

---@param config manipulator.Region.module.Config
function M.setup(config)
	M.config = UTILS.expand_config(M.config.presets, M.default_config, config, Region.opt_inheritance)
	M.config.presets.active = M.config
	return M
end

---@generic O: manipulator.Region
---@param self `O`
---@param base manipulator.RangeType|{lines?:string[],text?:string}
---@return O
function Region:new(base)
	self = setmetatable(base or {}, self.buf and getmetatable(self) or self)
	if (self.buf or 0) == 0 then self.buf = vim.api.nvim_get_current_buf() end
	return self
end

---@param override table modifications to apply to the cloned object
function Region:clone(override)
	return setmetatable(vim.tbl_deep_extend('keep', override or {}, self), getmetatable(self))
end

--- Create a copy of this node with different defaults. (always persistent)
---@generic O: manipulator.Region.Config
---@generic S: manipulator.Region
---@param self `S`
---@param config `O`|string
---@param inplace boolean should we replace current config or clone the region first (default: false)
---@return S self
function Region:with(config, inplace)
	---@diagnostic disable-next-line: undefined-field
	local ret = inplace and self or self:clone()
	---@diagnostic disable-next-line: undefined-field
	ret.config = self:expand_config(config)
	return ret
end

---@return integer|false # comparison of inclusion of range
---   - `false` if from different buffers
---   - `>0` if {b} is fully enclosed by {a}, `0` when equal, `<0` otherwise
function Region:contains(new)
	local b1, r1 = RANGE_UTILS.decompose(self, true)
	local b2, r2 = RANGE_UTILS.decompose(new, true)
	return b1 == b2 and RANGE_UTILS.rangeContains(r1, r2) or false
end

function Region:eq(new) return self:contains(new) == 0 end

---@generic S: manipulator.Region
---@generic O
---@param self `S`
---@param fun fun(self:S):`O`
---@return O
function Region:apply(fun) return fun(self) end

---@protected
function Region:__tostring() return self:get_lines(true)[1] or 'NilRegion' end

---@return Range4 0-indexed range
function Region:range0()
	local range = self[1] and self or self.range
	return range and { range[1], range[2], range[3], range[4] } or RANGE_UTILS.offset(self:range1(), -1)
end

---@return Range4 1-indexed range
function Region:range1() return RANGE_UTILS.offset(self:range0(), 1) end

--- Get beginning of this range
---@return Range4 0-indexed point prepared as a range
function Region:start()
	local r = self:range0()
	r[3] = r[1]
	r[4] = r[2]
	return r
end

--- Get beginning of this range
---@return Range4 0-indexed point prepared as a range
function Region:end_()
	local r = self:range0()
	r[1] = r[3]
	r[2] = r[4]
	return r
end

---@param ... manipulator.Batch.Action item method sequences to apply recursively and collect node of each iteration
---@return manipulator.Batch
function Region:collect(...) return Batch.from_recursive(self, ...) end

---@param ... manipulator.Batch.Action item method sequences to apply and collect the result of
---@return manipulator.Batch
function Region:to_batch(x, ...)
	if not x then
		return Batch.from(self, function() return self end)
	end
	return Batch.from(self, x, ...)
end

---@param cut_to_range? boolean if true, disable truncating lines to match size precisely (default: true)
---@return string[]
function Region:get_lines(cut_to_range)
	local lines = self.text and cut_to_range ~= false and vim.split(self.text, '\n') or self.lines
	return lines or RANGE_UTILS.get_lines(self, cut_to_range)
end

---@return string # Concatenated lines of the region
function Region:get_text() return self.text or table.concat(self:get_lines(true), '\n') end

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

do
	local hl_ns = vim.api.nvim_create_namespace 'manipulator_hl'

	--- Highlight or remove highlighting from given range (run on NilRegion to clear the whole buffer)
	---@param group? string|false highlight group name or false to clear (default: 'IncSearch')
	function Region:highlight(group)
		local buf, range = RANGE_UTILS.decompose(self)
		if group == false then
			vim.api.nvim_buf_clear_namespace(buf, hl_ns, range[1] or 0, range[3] and range[3] + 1 or -1)
			return
		elseif not range[1] then
			vim.notify('Cannot highlight Nil', vim.log.levels.INFO)
			return
		end

		group = group or 'IncSearch'
		vim.hl.range(buf, hl_ns, group, { range[1], range[2] }, { range[3], range[4] + 1 })
	end
end

---@param char string character for the mark
function Region:mark(char)
	local buf, range = RANGE_UTILS.decompose(self)
	vim.api.nvim_buf_set_mark(buf, char, range[1] + 1, range[2], {})
end

---@class manipulator.Region.jump.Opts
---@field end_? boolean if the cursor should jump to the end of the selection (applied only when not in visual mode already) (default: true)
---@field rangemod? false|fun(self:manipulator.Region):Range4 transform the range of the region before manipulation (default: trims whitespace)
---@field insert? boolean should we enter insert mode (default: false)

--- Jump to the start (or end, if `opts.end_`) of the region.
---@param opts? manipulator.Region.jump.Opts
function Region:jump(opts)
	opts = self:action_opts(opts, 'jump')
	local r = opts.rangemod == false and self:range0() or (opts.rangemod or RANGE_UTILS.get_trimmed_range)(self)

	RANGE_UTILS.jump(
		{ buf = self.buf, range = not opts.end_ and { r[1], r[2] } or { r[3], r[4] } },
		opts.end_,
		opts.insert
	)
end

---@class manipulator.Region.select.Opts: manipulator.Region.jump.Opts
---@field allow_grow? boolean if true, add to current visual selection (default: false)
---@field linewise? boolean|'auto' 'auto' uses linewise mode if the range covers all line text (default: 'auto')
---@field insert? boolean if coming from insert mode should we return to it after ending the selection (like `<C-o>v`) (default: false)
---@field allow_select_mode? boolean if coming from insert mode should we enter select or visual mode. Cannot be combined with `return_to_insert` (default: false=visual mode only)

--- Select node in visual/select mode.
---@param opts? manipulator.Region.select.Opts
function Region:select(opts)
	opts = self:action_opts(opts, 'select')
	local r = opts.rangemod == false and self:range0() or (opts.rangemod or RANGE_UTILS.get_trimmed_range)(self)
	local buf = self.buf
	if buf == 0 then
		buf = vim.api.current_buf()
	else
		vim.api.nvim_win_set_buf(0, buf)
	end
	local t_mode = opts.linewise == nil and 'auto' or opts.linewise
	if
		t_mode == 'auto'
		and not vim.api.nvim_buf_get_lines(buf, r[1], r[1] + 1, true)[1]:sub(1, r[2]):match '%S'
		and not vim.api.nvim_buf_get_lines(buf, r[3], r[3] + 1, true)[1]:sub(r[4] + 2):match '%S'
	then
		t_mode = 'V'
	else
		t_mode = 'v'
	end

	local visual, leading = RANGE_UTILS.current_visual()
	if visual and opts.allow_grow then
		r[1] = math.min(r[1], visual[1])
		r[2] = math.min(r[2], visual[2])
		r[3] = math.max(r[3], visual[3])
		r[4] = math.max(r[4], visual[4])
	end

	local c_mode = vim.fn.mode()
	if c_mode ~= t_mode then
		if c_mode == 'i' then
			if not opts.allow_select_mode then vim.cmd.stopinsert() end -- updates in the next tick
			r[4] = r[4] + 1 -- fix insert shortening moved cursor in this tick
			if opts.insert then vim.cmd { cmd = 'normal', bang = true, args = { '\015' } } end
		else
			vim.cmd { cmd = 'normal', bang = true, args = { '\027' } }
		end
		vim.cmd { cmd = 'normal', bang = true, args = { t_mode } }
	end

	-- vim line is 1-indexed, col is 0-indexed
	vim.api.nvim_win_set_cursor(0, { r[1] + 1, r[2] })
	vim.cmd.normal 'o'
	vim.api.nvim_win_set_cursor(0, { r[3] + 1, r[4] })
	if leading or (not visual and opts.end_ == false) then vim.cmd.normal 'o' end
end

---@class manipulator.Region.paste.Opts
---@field dst? manipulator.RangeType where to put the text relative to (default: self)
---@field text? string text to paste or '"x' to paste from register `x` (default: `self:get_text()`)
---@field mode? 'before'|'after'|'over' method of modifying the dst range text content, doesn't support 'swap' mode
---@field linewise? boolean

--- Paste like with visual mode motions - prefer using vim motions
---@param opts manipulator.Region.paste.Opts
function Region:paste(opts)
	opts = self:action_opts(opts, 'paste')
	local buf, range = RANGE_UTILS.decompose(opts.dst or self, true)
	local text = opts.text
	if not text then
		text = self:get_text()
	elseif #text == 2 and text:sub(1, 1) == '"' then
		text = vim.fn.getreg(text:sub(2, 2))
		if not text then
			vim.notify('Register ' .. opts.text:sub(2, 2) .. ' is empty', vim.log.levels.INFO)
			return
		end
	end
	if not buf or not range[1] then
		vim.notify('Invalid dst to paste to', vim.log.levels.INFO)
		return
	end

	if opts.linewise then -- mode='over' doesn't make sense here, so we ignore it
		if opts.mode == 'after' then range[1] = range[3] + 1 end
		range[3] = range[1]
		range[2] = 0
		range[4] = 0
		text = text .. '\n'
	elseif opts.mode == 'before' then
		range[3] = range[1]
		range[4] = range[2]
	elseif opts.mode == 'after' then
		range[1] = range[3]
		range[2] = range[4]
	end -- else mode = 'over'

	vim.lsp.util.apply_text_edits({ { range = RANGE_UTILS.lsp_range(range), newText = text } }, buf, 'utf-8')
end

---@class manipulator.Region.swap.Opts
---@field dst manipulator.RangeType direct destination to move to
---@field cursor_with? 'dst'|'src'|false at which object should the cursor end up (default: 'src')
---@field visual? boolean|manipulator.VisualModeEnabler which visual modes can be updated (use `{}` to disable) (default: true=all)

--- Swap two regions. (buffers can differ)
--- Maintains cursor (and visual selection) on the region specified via `opts.cursor_with`.
---@param opts manipulator.Region.swap.Opts
function Region:swap(opts)
	opts = self:action_opts(opts, 'swap')
	local sbuf, srange = RANGE_UTILS.decompose(self, true)
	local dbuf, drange = RANGE_UTILS.decompose(opts.dst, true)
	if not srange[1] or not drange[1] then
		vim.notify('Invalid range', vim.log.levels.INFO)
		return
	end

	-- Calculate relative cursor positions to the colser of the regions or fallback start-to-end
	if opts.cursor_with == nil then opts.cursor_with = 'src' end
	local c_at_src = opts.cursor_with == 'src'
	local c_pos, c_end, v_pos, v_end -- relative pos to the start or end of the region
	if opts.cursor_with then
		local range, leading = RANGE_UTILS.current_visual(opts.visual == false and {} or opts.visual, false)
		if not range or opts.visual == false then
			c_pos = RANGE_UTILS.current_point(nil, false).range
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
			local rel_pos, is_end = RANGE_UTILS.posInRange(rel_range, c_pos, true)
			if not rel_pos then
				rel_range = drange
				c_pos, c_end = RANGE_UTILS.posInRange(rel_range, c_pos, true)
			else
				c_pos, c_end = rel_pos, is_end
			end
		end

		local size = c_at_src and srange or drange
		size = RANGE_UTILS.subRange({ size[3], size[4] }, size)

		if
			v_pos -- if visual is allowed then always select to the whole region
			or not c_pos
			or RANGE_UTILS.cmpPoint(c_end and RANGE_UTILS.subRange({ 0, 0 }, c_pos) or c_pos, size) > 0
			or (v_pos and RANGE_UTILS.cmpPoint(v_end and RANGE_UTILS.subRange({ 0, 0 }, v_pos) or v_pos, size) > 0)
		then -- cursor outside manipulated ranges -> select start-to-end
			c_pos, c_end = { 0, 0 }, c_end
			if v_pos then
				v_pos, v_end = { 0, 0 }, not c_end
			end
		end
	end

	local s_edit = { range = RANGE_UTILS.lsp_range(srange), newText = opts.dst:get_text() }
	local d_edit = { range = RANGE_UTILS.lsp_range(drange), newText = self:get_text() }

	local t_range = c_at_src and srange or drange
	if sbuf ~= dbuf then
		vim.lsp.util.apply_text_edits({ s_edit }, sbuf, 'utf-8')
		vim.lsp.util.apply_text_edits({ d_edit }, dbuf, 'utf-8')

		if opts.cursor_with then
			local n_start = c_at_src and drange or srange
			local n_buf = c_at_src and dbuf or sbuf
			if v_pos then
				RANGE_UTILS.jump(
					RANGE_UTILS.addRange(RANGE_UTILS.subRange({ t_range[3], t_range[4] }, t_range), n_start)
				)
				vim.cmd.normal 'o'
			end
			RANGE_UTILS.jump { buf = n_buf, range = n_start }
		end
	else
		-- always jump to the tracked region to calculate the shift afterwards
		if opts.cursor_with then RANGE_UTILS.jump { buf = sbuf, range = c_at_src and drange or srange } end
		vim.lsp.util.apply_text_edits({ s_edit, d_edit }, sbuf, 'utf-8')

		-- TODO: make Region inherit from Range
		if
			opts.cursor_with
			and (v_pos or c_end or c_pos[1] ~= 0 or c_pos[2] ~= 0) -- update position if jump wasn't enough
		then
			local n_start = RANGE_UTILS.current_point(nil, false).range
			local n_end = RANGE_UTILS.addRange(
				RANGE_UTILS.subRange({ t_range[3], t_range[4] }, t_range),
				{ n_start[1], n_start[2] }
			)

			if v_pos then
				RANGE_UTILS.jump(RANGE_UTILS.addRange(v_pos, v_end and n_end or n_start))
				vim.cmd.normal 'o'
			end
			RANGE_UTILS.jump(RANGE_UTILS.addRange(c_pos, c_end and n_end or n_start))
		end
	end
end

do
	---@type table<string,manipulator.Region?>
	local queued_map = {}

	---@class manipulator.Region.queue_or_run.Opts: manipulator.Region.paste.Opts,manipulator.Region.swap.Opts
	---@field group? string used as a key to allow multiple pending moves
	---@field highlight? string|false highlight group to use, suggested to specify with custom {group} (default: 'IncSearch')
	---@field allow_grow? boolean if selected region can be updated to the current when its fully contained or should be deselected (default: false)
	---@field run_on_queued? boolean should the action be run on the queued node or on the pairing one (default: false)
	---@field action? 'swap'|'paste' which action to run on the pairing node

	--- Move the node to a given position
	---@param opts? manipulator.Region.queue_or_run.Opts included action options used only on run call
	---@return manipulator.Region? self returns itself if it was the first to be selected; nil, if selection was removed
	function Region:queue_or_run(opts)
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
					and RANGE_UTILS.rangeContains(active:range0(), self:range0()) >= 0
				)
			)
		then
			if vim.api.nvim_buf_is_valid(active.buf) then
				queued_map[opts.group] = nil
				active:highlight(false)
				vim.notify(self.buf and 'Unselected' or 'Cannot run queued action on Nil', vim.log.levels.WARN)
				return
			end
			active = nil
		end

		if
			not active
			or (
				opts.allow_grow
				and active.buf == self.buf -- test if we contain the active range
				and RANGE_UTILS.rangeContains(self:range0(), active:range0()) >= 0
			)
		then
			if active then active:highlight(false) end
			queued_map[opts.group] = self
			if opts.highlight then self:highlight(opts.highlight) end
			return self
		else
			opts.dst = active
			self[opts.action or 'swap'](self, opts)
			active:highlight(false)
			queued_map[opts.group] = nil
		end
	end
end

do -- ### Wrapper for nil matches
	---@class manipulator.NilRegion: manipulator.Region
	local NilRegion = { range = {} }
	function NilRegion:clone() return self end -- nil is only one
	NilRegion.with = NilRegion.clone
	function NilRegion:__tostring() return 'Nil' end
	-- allow queue_or_run() to deselect the group and collect() to return an empty Batch
	local passthrough = {
		Nil = true,
		action_opts = true,
		highlight = true,
		collect = true,
		queue_or_run = true,
	}
	function NilRegion:__index(key)
		if passthrough[key] then return Region[key] end
		return function() vim.notify('Cannot ' .. key .. ' Nil') end
	end

	---@protected
	Region.Nil = setmetatable(NilRegion, NilRegion)
end

---@param range manipulator.RangeType|{lines?:string[],text?:string}
---@return manipulator.Region
function M.from(range) return Region:new(range) end

---@class manipulator.Region.module.current.Opts options for retrieving various kinds of user position
---@field mouse? boolean if the event is a mouse click
---@field visual? boolean|manipulator.VisualModeEnabler map of modes for which to return visual range, false to get a cursor/mouse only
---@field insert_fixer? string luapat to match the char under cursor to determine if c-1 column should be used when in 'i'/'s' mode

--- Get mouse click position or currently selected region and cursor position
---@param opts? manipulator.Region.module.current.Opts use {} for disabling visual mode
---@return manipulator.Region # object of the selected region (point or range)
---@return boolean is_visual true if the range is from visual mode
function M.current(opts)
	opts = M:action_opts(opts, 'current')

	local range = opts.visual ~= false and RANGE_UTILS.current_visual(opts.visual, opts.insert_fixer)
	return M.from(range or RANGE_UTILS.current_point(opts.mouse, opts.insert_fixer)), not not range
end

return M
