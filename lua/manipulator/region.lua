local UTILS = require 'manipulator.utils'
local RANGE_UTILS = require 'manipulator.range_utils'
local OPS = require 'manipulator.ops'
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

Region.highlight = OPS.highlight
Region.mark = OPS.mark
Region.paste = OPS.paste

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

--- Jump to the start (or end, if {_end}) of the region.
---@param end_? boolean
function Region:jump(end_) OPS.jump { buf = self.buf, range = end_ and self:end_() or self:start() } end

---@class manipulator.Region.select.Opts
---@field allow_grow? boolean if true, add to current visual selection (default: false)
---@field mode? 'v'|'V' which mode to enter for selection (default: 'v')

--- Select node in visual mode
---@param opts? manipulator.Region.select.Opts
function Region:select(opts)
	opts = opts or {}
	local range = self:range0()

	local visual = RANGE_UTILS.get_visual()
	if opts.allow_grow then
		if visual then
			range[1] = math.min(range[1], visual[1])
			range[2] = math.min(range[2], visual[2])
			range[3] = math.max(range[3], visual[3])
			range[4] = math.max(range[4], visual[4])
		end
	end

	-- in nvim line is 1-indexed, col is 0-indexed
	OPS.set_visual(range, opts.mode)
end

do
	---@type table<string,manipulator.Region?>
	local active_moves_map = {}

	---@class manipulator.Region.move.Opts: manipulator.ops.move.Opts
	---@field dst? manipulator.RangeType optional direct destination to move to
	---@field group? string used as a key to allow multiple pending moves
	---@field highlight? string|false highlight group to use, suggested to specify with custom {group} (default: 'IncSearch')
	---@field allow_grow? boolean if selected region can be updated to the current when its fully contained (default: true)

	---@generic S
	--- Move the node to a given position
	---@param self `S`
	---@param opts? manipulator.Region.move.Opts
	---@return S? self returns itself if it was the first to be selected; nil, if selection was removed
	function Region:move(opts) -- TODO: add linewise region info
		opts = opts or {} -- TODO: make this into inheritable settings
		opts.group = opts.group or 'default'
		if opts.highlight == nil then opts.highlight = 'IncSearch' end
		opts.mode = opts.mode or 'swap'

		if opts.dst then -- directly swap with a range
			OPS.move(self, opts) -- also ensures NilNode doesn't get swapped (checks if range is valid)
			return
		end

		local active = active_moves_map[opts.group]
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
			active_moves_map[opts.group] = nil
			if vim.api.nvim_buf_is_valid(active.buf) then
				active:highlight(false)
				vim.notify(self.buf and 'Unselected' or 'Invalid region to move to', vim.log.levels.WARN)
				return
			end
			active = nil
		end

		if
			not active
			or (
				opts.allow_grow ~= false
				and active.buf == self.buf -- test if we contain the active range
				and RANGE_UTILS.rangeContains(self:range0(), active:range0()) >= 0
			)
		then
			if active then active:highlight(false) end
			active_moves_map[opts.group] = self
			if opts.highlight then self:highlight(opts.highlight) end
			return self
		else
			opts.dst = active
			OPS.move(self, opts)
			active:highlight(false)
			active_moves_map[opts.group] = nil
		end
	end
end

do -- ### Wrapper for nil matches
	---@class manipulator.NilRegion: manipulator.Region
	local NilRegion = {}
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
	local range = opts.visual ~= false and RANGE_UTILS.get_visual(opts.visual)
	if range then return Region:new { range = range }, true end
	return Region:new(RANGE_UTILS.current_point(opts.mouse)), false
end

return M
