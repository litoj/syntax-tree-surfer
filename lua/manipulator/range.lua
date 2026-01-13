local Pos = require 'manipulator.pos'

---@class manipulator.Range: manipulator.Pos,Range4
local Range = setmetatable({ super = Pos }, Pos)
Range.__index = Range

do -- ### Producers
	--- Get the table with the positions
	---@param r anypos
	---@return Range4
	function Range.raw(r)
		r = r.range or r
		return r[3] and r or { r[1], r[2], r[1], r[2] }
	end

	--- Create a new Range object, guarantees a copy of the original
	---@param r anypos
	---@param buf? integer
	function Range.new(r, buf)
		buf = buf or r.buf
		r = Pos.raw(r) ---@cast r manipulator.Range
		if not r[1] then error('Invalid Range: ' .. vim.inspect(r)) end
		return setmetatable({ buf = buf, r[1], r[2], r[3] or r[1], r[4] or r[2] }, Range)
	end

	--- Get a Range object, creating it if not already existing
	---@param r anypos
	function Range.get_or_make(r)
		if getmetatable(r.range or r) then return r.range or r end -- optimisation for Region.range
		return Range.new(r)
	end

	--- Get a Range from the given marks or positions. Returned range guarantees start<end.
	---@see manipulator.range_utils.get_pos
	---@param s_expr pos_src whether a pos or a range only the start will be used
	---@param e_expr? pos_src same as `s_expr` if not provided
	---@return manipulator.Range
	---@return boolean? swapped if the order of expressions was changed to make a positive range
	--- - `swapped=nil` if there was no `e_expr`
	function Range.from(s_expr, e_expr)
		local from = Pos.from(s_expr)
		local to = e_expr and Pos.from(e_expr) or from
		assert(Pos.buf_eq(from, to, 0), 'Cannot create a range from positions from different buffers')

		local swapped
		if e_expr then swapped = from > to end
		if swapped then
			local tmp = to
			to = from
			from = tmp
		end

		from[3] = to[1]
		from[4] = to[2]
		return Range.new(from), swapped
	end
end

do -- ### Getters / Actions
	---@return manipulator.Range
	---@return manipulator.Range
	function Range.check(a, b, require_buf_eq)
		a, b = Pos.check(a, b, require_buf_eq)
		if not a[3] then
			a[3] = a[1]
			a[4] = a[2]
		end
		setmetatable(a, Range)
		if not b[3] then
			b[3] = b[1]
			b[4] = b[2]
		end
		setmetatable(b, Range)
		return a, b
	end

	--- Get the lines of text of the given range
	--- NOTE: to include the EOL don't use `math.huge` but `vim.v.maxcol`!!!
	---@param r anyrange
	---@param cut_to_range? boolean unless false, truncate lines to match size precisely (default: true)
	---@return string[]
	function Range.get_lines(r, cut_to_range)
		---@diagnostic disable-next-line: invisible, undefined-field
		if (r.lines or r.text) and cut_to_range ~= false then return r.lines or vim.split(r.text, '\n') end
		local buf = r.buf or 0
		r = Range.raw(r)

		if cut_to_range == false then
			return vim.api.nvim_buf_get_lines(buf, r[1], r[3] + 1, true)
		else
			return vim.api.nvim_buf_get_text(buf, r[1], r[2], r[3], r[4] + 1, {})
		end
	end

	function Range.get_text(r) return r.text or table.concat(Range.get_lines(r, true), '\n') end

	---@param r anypos 0-indexed range, end inclusive
	function Range.to_lsp(r)
		r = Range.raw(r)
		return {
			start = { line = r[1], character = r[2] },
			['end'] = { line = r[3], character = r[4] + 1 },
		}
	end

	---@param r anypos
	---@param as_pos? boolean return an actual manipulator.Pos, or a new Range object
	---@return manipulator.Range|manipulator.Pos
	function Range.end_(r, as_pos)
		local a = Range.raw(r)
		return as_pos and Pos.new({ a[3], a[4] }, r.buf) or Range.new({ a[3], a[4] }, r.buf)
	end

	---@param r anypos
	---@param as_pos? boolean return an actual manipulator.Pos, or a new Range object
	---@return manipulator.Range|manipulator.Pos
	function Range.start(r, as_pos)
		r = Pos.new(r, r.buf)
		return as_pos and r or Range.new(r)
	end

	---@param r anypos
	---@param end_ boolean
	function Range.jump(r, end_) Pos.jump(Range[end_ and 'end_' or 'start'](r)) end
end

do -- ### Comparisons
	--- Compare end of `a` with start of `b`
	function Range.cmp(a, b)
		-- assert(Pos.buf_eq(a, b, 0), 'Cannot compare ranges from different buffers')
		a = Pos.raw(a)
		b = Pos.raw(b)
		return (a[3] or a[1]) == b[1] and (a[4] or a[2]) - b[2] or (a[3] or a[1]) - b[1]
	end

	-- NOTE: had to be adapted from Pos, because operators don't work via metatable search

	--- Negations work differently because of being a range -> >= compares E>S, not S>E
	--- - actual point comparison:
	---   (a >= b) == (a:end_() >= b:start())
	---   (a:end_() < b) == (a:end_() < b:end_())
	function Range.__lt(a, b) return Range.cmp(a, b) < 0 end
	function Range.__le(a, b) return Range.cmp(a, b) <= 0 end
	function Range.__eq(a, b)
		if not Pos.buf_eq(a, b, 0) then return false end
		a = Range.raw(a)
		b = Range.raw(b)
		return a[1] == b[1] and a[2] == b[2] and a[3] == b[3] and a[4] == b[4]
	end
end

do -- ### Set operations
	---@param a anyrange
	---@param b anypos
	function Range.contains(a, b)
		if not Pos.buf_eq(a, b, 0) then return false end
		a = Range.raw(a)
		b = Range.raw(b)

		return Pos.cmp(a, b) <= 0 and Range.cmp(a, { b[3], b[4] }) >= 0
	end

	--- Intersection result (nil if not intersecting)
	---@param a anypos
	---@param b anypos
	function Range.intersection(a, b)
		a = Range.get_or_make(a)
		b = Range.get_or_make(b)
		if not a:buf_eq(b, 0) or a < b or b < a then return nil end

		if a:start() <= b then
			if b <= a:end_() then return b end
			return Range.new({ b[1], b[2], a[3], a[4] }, a.buf)
		else
			if a <= b:end_() then return a end
			return Range.new({ a[1], a[2], b[3], b[4] }, a.buf)
		end
	end

	--- Extend the range to encompass both `a` and `b`
	---@param a anypos
	---@param b anypos
	function Range.union(a, b)
		if not Pos.buf_eq(a, b, 0) then return nil end
		a = Range.get_or_make(a)
		b = Range.get_or_make(b)

		if a:start() >= b then
			if a:end_() >= b then return a end
			return Range.new({ a[1], a[2], b[3], b[4] }, a.buf)
		else
			if b:end_() >= a then return b end
			return Range.new({ b[1], b[2], a[3], a[4] }, a.buf)
		end
	end

	--- Get the parts of `a` that are not in `b`
	---@param a anypos
	---@param b anypos
	function Range.set_minus(a, b)
		a = Range.get_or_make(a)
		b = Range.get_or_make(b)
		if not Pos.buf_eq(a, b, 0) or a < b or b < a then return a end
		if b:contains(a) then return nil end

		local res = {}
		if b[2] == 0 then
			res[1] = { a[1], a[2], b[1] - 1, vim.v.maxcol }
		else
			res[1] = { a[1], a[2], b[1], b[2] - 1 }
		end

		if a:end_() > b then -- if `a` ends after `b`, then we know there is text behind B
			if b[4] + 1 >= #b:end_():get_line() then
				res[2] = { b[3] + 1, 0, a[3], a[4] }
			else
				res[2] = { b[3], b[4] + 1, a[3], a[4] }
			end
		end

		return Range.new(res[1], a.buf), res[2] and Range.new(res[2], a.buf) or nil
	end

	---@class manipulator.Range.rel_pos.Opts
	---@field accept_one_col_after? boolean still compute if the pos is directly after the range
	--- Minimum col value of the relative pos to return end-relative pos.
	--- Use a positive number > `accept_one_col_after` to guarantee a start-relative position.
	---@field relative_end_min? integer

	---@param r anyrange
	---@param p pos_src
	---@param opts? manipulator.Range.rel_pos.Opts
	---@return manipulator.Pos? # position to the closer edge, or `nil` if outside range by >1 col
	---@return boolean? relative_to_end if the closer edge is the end of the range
	function Range.rel_pos(r, p, opts)
		if not Pos.buf_eq(r, p, 0) then return nil end
		r = Range.raw(r)
		p = Pos.raw(p)

		opts = opts or {}
		if Pos.cmp(p, r) < 0 or Pos.cmp(p, { r[3], r[4] + (opts.accept_one_col_after and 1 or 0) }) > 0 then
			return nil
		end

		local rel_s = p - r
		local rel_e = p - { r[3], r[4] }
		if rel_e[1] == 0 and rel_e[2] >= (opts.relative_end_min or 0) then return rel_e, true end
		return rel_s, false
	end
end

do -- ### Text operations - always updates line, column is updated only if on the same line
	---@return manipulator.Pos
	function Range.size(a)
		a = Range.get_or_make(a)
		if a[4] == vim.v.maxcol then return Pos.new({ a[3] - a[1] + 1, 0 }, a.buf) end
		if a[1] == a[3] then
			return Pos.new({ 0, a[4] - a[2] + 1 }, a.buf)
		else
			return Pos.new({ a[3] - a[1], a[4] }, a.buf)
		end
	end

	---@protected
	--- Adjust to changes on the line of the start just before the start.
	--- It shouldn't be possible to achieve a negative column result, so we're not checking.
	---@param o integer size of the column offset to apply (also to the end if self is oneline)
	function Range:offset_col(o)
		if self[4] == vim.v.maxcol then return end -- linewise columns cannot be changed

		self[2] = self[2] + o
		if self[1] == self[3] then self[4] = self[4] + o end
	end

	--- Set range `src` in place of the beginning of `dst`.
	---@param r anyrange
	---@param p anypos point to align / set new position to
	---@return manipulator.Range
	function Range.aligned_to(r, p)
		---@diagnostic disable-next-line: undefined-field
		r, p = Range.new(r, p.buf), Pos.raw(p)

		r[3] = p[1] + (r[3] - r[1])
		r[1] = p[1]

		r:offset_col(p[2] - r[2])
		return r
	end

	---@param r anypos
	---@param at anyrange where is the change happening
	---@param change 'remove'|'insert'
	function Range.with_change(r, at, change)
		if not Pos.buf_eq(r, at, 0) then return r end
		r = Range.new(r) -- make a copy to ensure original stays immutable
		at = Range.get_or_make(at)
		if at.buf then r.buf = at.buf end -- ensure self.buf is set, different buffs already filtered

		local change_sign = ({ remove = -1, insert = 1 })[change] or error 'Invalid change type'

		-- TODO: implement extending the region by inserting into it and shrinking by removing
		if change_sign < 0 then assert(not r:intersection(at), 'Removing overlapping text not implemented') end

		if Pos.cmp(at, r) <= 0 then -- change before our text -> adjustment required
			if at[1] == r[1] then
				if at[3] == r[1] then -- all on the same line (but still has to check maxcol later)
					r:offset_col(change_sign * Range.size(at)[2])
				elseif change_sign > 0 then
					-- inserting multiline directly in front of r and shift by what was between (-r[2]+r[2])
					r:offset_col(at[4] - at[2] + 1)
				end
			end
			-- extend by 1 extra line if we're including EOL
			local line_diff = at[3] - at[1] + (at[4] == vim.v.maxcol and 1 or 0)
			r[1] = r[1] + change_sign * line_diff
			r[3] = r[3] + change_sign * line_diff
		end

		return r
	end

	--- Move range in place of the beginning of `dst`.
	--- Adjusts the result according to the placement of `self`
	--- - if self < dst then first calculates the decrease in dst position before moving
	---@param r anyrange
	---@param dst anypos
	---@return manipulator.Range self moved to `dst`
	function Range.moved_to(r, dst)
		r = Range.new(r)
		dst = Range.new(dst)
		local buf = Pos.buf_eq(r, dst)

		if buf ~= false and Pos.cmp(r, { dst[3], dst[4] }) < 0 then
			assert(r < dst, 'Moving to an overlapping position not implemented')
			dst = dst:with_change(r, 'remove')
		else -- dst is a different buffer or wasn't preceeded by the moved self -> no changes to dst
			r.buf = buf or dst.buf
		end

		return Range.aligned_to(r, dst)
	end
end

return Range
