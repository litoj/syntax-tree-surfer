local UTILS = require 'manipulator.utils'
local RANGE_UTILS = require 'manipulator.range_utils'
local RANGE_ACTIONS = require 'manipulator.range_actions'
local Batch = require 'manipulator.batch'

---@class manipulator.Region
---@field buf integer buffer number
---@field protected range Range4? injected field in case of manipulator.BufRange extending
---@field protected text string? injected field to source the text from
---@field protected lines string[]? injected field to source the text from
local Region = {}
Region.__index = Region

---@class manipulator.Region.module: manipulator.Region
---@field class manipulator.Region
local M = UTILS.static_wrap_for_oop(Region, {})

---@generic O: manipulator.Region
---@param o manipulator.RangeType|{lines?:string[],text?:string}|`O`
---@return O
function Region:new(o)
	self = setmetatable(o or {}, self)
	if (self.buf or 0) == 0 then self.buf = vim.api.nvim_get_current_buf() end
	return self
end

---@param override table modifications to apply to the cloned result
function Region:clone(override)
	return setmetatable(vim.tbl_deep_extend('keep', override or {}, self), getmetatable(self))
end

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
	return self.range and UTILS.tbl_inner_extend('keep', {}, self.range)
		or (self[1] and { self[1], self[2], self[3], self[4] })
		or RANGE_UTILS.offset(self:range1(), -1)
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

---@param cut_to_range? boolean if true, disable truncating lines to match size precisely (default: false)
function Region:get_lines(cut_to_range)
	return self.text and vim.split(self.text, '\n')
		or self.lines
		or RANGE_UTILS.get_lines(self, cut_to_range)
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

Region.highlight = RANGE_ACTIONS.highlight
Region.mark = RANGE_ACTIONS.mark

--- Jump to the start (or end, if {_end}) of the region.
---@param end_? boolean
function Region:jump(end_)
	RANGE_ACTIONS.jump { buf = self.buf, range = end_ and self:end_() or self:start() }
end

---@class manipulator.Region.select.Opts
---@field allow_grow? boolean if true, add to current visual selection (default: false)
---@field mode? 'v'|'V' which mode to enter for selection (default: 'v')

--- Select node in visual mode
---@param opts? manipulator.Region.select.Opts
function Region:select(opts)
	opts = opts or {}
	local range = self:range0()

	local visual = RANGE_UTILS.current_visual()
	if opts.allow_grow then
		if visual then
			range[1] = math.min(range[1], visual[1])
			range[2] = math.min(range[2], visual[2])
			range[3] = math.max(range[3], visual[3])
			range[4] = math.max(range[4], visual[4])
		end
	end

	-- in nvim line is 1-indexed, col is 0-indexed
	RANGE_ACTIONS.set_visual(range, opts.mode)
end

---@class manipulator.Region.paste.Opts
---@field dst? manipulator.RangeType where to put the text relative to (default: self)
---@field text? string text to paste (default: self:get_text())
---@field mode 'before'|'after'|'over' method of modifying the dst range text content, doesn't support 'swap' mode
---@field linewise? boolean

--- Paste like with visual mode motions - prefer using vim motions
---@param opts manipulator.Region.paste.Opts
function Region:paste(opts)
	local buf, range = RANGE_UTILS.decompose(opts.dst or self, true)
	local text = opts.text or self:get_text()
	if not buf or not range[1] then
		vim.notify('Invalid dst to paste to', vim.log.levels.INFO)
		return
	end

	local text = opts.text
	if opts.linewise then
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

	vim.lsp.util.apply_text_edits(
		{ { range = RANGE_UTILS.lsp_range(range), newText = text } },
		buf,
		'utf-8'
	)
end

---@class manipulator.Region.swap.Opts
---@field dst manipulator.RangeType direct destination to move to
---@field cursor_with? 'dst'|'src'|false at which object should the cursor end up (default: 'src')
---@field visual? boolean|manipulator.VisualModeEnabler which visual modes can be updated (use `{}` to disable) (default: true=all)

--- Swap two regions. (buffers can differ)
--- Maintains cursor (and visual selection) on the region specified via `opts.cursor_with`.
---@param opts manipulator.Region.swap.Opts
function Region:swap(opts)
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
		local range, leading =
			RANGE_UTILS.current_visual(opts.visual == false and {} or opts.visual, false)
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
			or (
				v_pos
				and RANGE_UTILS.cmpPoint(v_end and RANGE_UTILS.subRange({ 0, 0 }, v_pos) or v_pos, size)
					> 0
			)
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
				RANGE_ACTIONS.jump(
					RANGE_UTILS.addRange(RANGE_UTILS.subRange({ t_range[3], t_range[4] }, t_range), n_start)
				)
				vim.cmd.normal 'o'
			end
			RANGE_ACTIONS.jump({ buf = n_buf, range = n_start }, false)
		end
	else
		-- always jump to the tracked region to calculate the shift afterwards
		if opts.cursor_with then
			RANGE_ACTIONS.jump({ buf = sbuf, range = c_at_src and drange or srange }, false)
		end
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
				RANGE_ACTIONS.jump(RANGE_UTILS.addRange(v_pos, v_end and n_end or n_start), false)
				vim.cmd.normal 'o'
			end
			RANGE_ACTIONS.jump(RANGE_UTILS.addRange(c_pos, c_end and n_end or n_start), false)
		end
	end
end

do
	---@type table<string,manipulator.Region?>
	local queued_map = {}

	---@class manipulator.Region.queue_or_run.Opts: {[string]:any}
	---@field group? string used as a key to allow multiple pending moves
	---@field highlight? string|false highlight group to use, suggested to specify with custom {group} (default: 'IncSearch')
	---@field allow_grow? boolean if selected region can be updated to the current when its fully contained or should be deselected (default: false)
	---@field run_on_queued? boolean should the action be run on the queued node or on the pairing one (default: false)
	---@field action? 'swap'|'paste' which action to run on the pairing node

	--- Move the node to a given position
	---@param opts? manipulator.Region.queue_or_run.Opts included action options used only on run call
	---@return manipulator.Region? self returns itself if it was the first to be selected; nil, if selection was removed
	function Region:queue_or_run(opts) -- TODO: add linewise region info
		opts = opts or {} -- TODO: make this into inheritable settings
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
				vim.notify(
					self.buf and 'Unselected' or 'Cannot run queued action on nil',
					vim.log.levels.WARN
				)
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
	function NilRegion:__tostring() return 'Nil' end
	-- allow move() to deselect the group and collect() to return an empty Batch
	local pass_through = { Nil = true, move = true, highlight = true, collect = true }
	function NilRegion:__index(key)
		if pass_through[key] then return Region[key] end
		return function() vim.notify('Cannot ' .. key .. ' Nil') end
	end

	---@protected
	Region.Nil = setmetatable(NilRegion, NilRegion)
end

---@class manipulator.Region.module.current.Opts options for retrieving various kinds of user position
---@field mouse? boolean if the event is a mouse click
---@field visual? boolean|manipulator.VisualModeEnabler map of modes for which to return visual range, false to get a cursor/mouse only

--- Get mouse click position or currently selected region and cursor position
---@param opts? manipulator.Region.module.current.Opts use {} for disabling visual mode
---@return manipulator.Region # object of the selected region (point or range)
---@return boolean is_visual true if the range is from visual mode
function M.current(opts)
	opts = opts or {}
	local range = opts.visual ~= false and RANGE_UTILS.current_visual(opts.visual)
	if range then return Region:new { range = range }, true end
	return Region:new(RANGE_UTILS.current_point(opts.mouse)), false
end

return M
