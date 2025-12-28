---@class manipulator.range_utils
local M = {}

---@class manipulator.BufRange
---@field range Range4 0-indexed range with the buf number
---@field buf integer? (default: 0)

---@alias manipulator.RangeType manipulator.Region|manipulator.BufRange|Range4 0-inexed range

do -- ### Range converions
	---@param range manipulator.RangeType any 0-indexed range
	---@param explicit_buf? boolean if true replace buf=0 with actual bufnr
	---@return integer buf
	---@return Range4|{} # 0-indexed buffer number and range or an empty table
	function M.decompose(range, explicit_buf)
		local buf = range.buf or 0
		if explicit_buf and buf == 0 then buf = vim.api.nvim_get_current_buf() end
		---@diagnostic disable-next-line: invisible
		return buf, range.range or (range.range0 and range:range0()) or range
	end

	---@param range Range4 0-indexed range, end inclusive
	function M.lsp_range(range)
		return {
			start = { line = range[1], character = range[2] },
			['end'] = { line = range[3], character = range[4] + 1 },
		}
	end

	---@param range Range
	function M.offset(range, offset)
		for i = 1, #range do
			range[i] = range[i] + offset
		end
		return range
	end
end

do -- ### Comparators
	---@return integer # <0 if a<b, 0 if a==b, >0 if a>b
	function M.cmpPoint(a, b) return a[1] == b[1] and a[2] - b[2] or a[1] - b[1] end

	---@return Range a with added values from b
	function M.addRange(a, b)
		for i, v in ipairs(a) do
			if b[i] then
				a[i] = v + b[i]
			else
				a[i] = nil
			end
		end
		return a
	end

	---@return Range a with subtracted values from b
	function M.subRange(a, b)
		for i, v in ipairs(a) do
			if b[i] then
				a[i] = v - b[i]
			else
				a[i] = nil
			end
		end
		return a
	end

	---@param a Range4
	---@param b Range2|Range4
	---@return integer # comparison of the starts
	---@return integer # comparison of the ends
	function M.cmpRange(a, b)
		return a[1] == b[1] and a[2] - b[2] or a[1] - b[1],
			b[3] and (a[3] == b[3] and a[4] - b[4] or a[3] - b[3]) or (a[3] == b[1] and a[4] - b[2] or a[3] - b[1])
	end

	---@param a Range4
	---@param b Range4
	---@return integer # >0 if {b} is a subset of {a}, 0 when equal, <0 otherwise
	function M.rangeContains(a, b)
		local r1, r2 = M.cmpRange(a, b)
		return r1 <= 0 and r2 >= 0 and (r1 == 0 and r2 == 0 and 0 or 1) or -1
	end

	---@return boolean
	function M.equal(a, b)
		local i = 1
		while true do
			if b[i] ~= a[i] then return false end
			if a[i] == nil then return true end
			i = i + 1
		end
	end

	---@param r Range4
	---@param p Range2
	---@param tolerate_end_by_1 boolean if point can be directly after the end of the range
	---@return Range2? position to the closer edge, or `nil` if point is more than 1 col outside range
	---@return boolean? end if the closer edge is the end of the range
	function M.posInRange(r, p, tolerate_end_by_1)
		if M.cmpPoint(p, r) < 0 or M.cmpPoint(p, { r[3], r[4] + (tolerate_end_by_1 and 1 or 0) }) > 0 then return end

		if p[1] ~= r[3] or p[2] - r[4] < 0 then -- if not very near the end default to start
			return {
				p[1] - r[1],
				p[2] - r[2],
			}, false
		else
			return {
				p[1] - r[3],
				p[2] - r[4],
			}, true
		end
	end
end

do -- ### Current state helpers
	--- Get the text of the given range
	--- NOTE: to include the EOL don't use `math.huge` but `vim.v.maxcol`!!!
	---@param region manipulator.RangeType
	---@param cut_to_range? boolean if true, disable truncating lines to match size precisely (default: true)
	---@return string[]
	function M.get_lines(region, cut_to_range)
		local buf, range = M.decompose(region)

		local lines = vim.api.nvim_buf_get_lines(buf, range[1], range[3] + 1, true)

		if cut_to_range ~= false then
			if #lines == 1 then
				lines[1] = lines[1]:sub(range[2] + 1, range[4] + 1)
			else
				lines[1] = lines[1]:sub(range[2] + 1)
				lines[#lines] = lines[#lines]:sub(1, range[4] + 1)
			end
		end

		return lines
	end

	---@param point manipulator.RangeType|Range2 0-indexed point
	function M.jump(point)
		local buf, range = M.decompose(point)
		vim.api.nvim_set_current_buf(buf)
		vim.api.nvim_win_set_cursor(0, { range[1] + 1, range[2] })
	end

	---@alias pos_expr 'mouse'|"'x"|'.'|'v'|"'["|"']"|"'<"|"'>"|string

	---@see vim.fn.getpos
	---@param expr? pos_expr expr for vim.fn.getpos or 'mouse' for mouse pos
	---@return Range2 point or an error, if the mark doesn't exist
	---@return integer? buf
	function M.get_point(expr)
		if not expr then expr = '.' end
		-- vim.fn.getpos can parse all inputs, but is half as fast
		if #expr == 2 or expr == '.' then
			local r = expr == '.' and vim.api.nvim_win_get_cursor(0) or vim.api.nvim_buf_get_mark(0, expr:sub(2))
			if r[1] == 0 then error('No position for: ' .. expr) end
			r[1] = r[1] - 1
			return r, 0
		elseif expr == 'mouse' then
			local m = vim.fn.getmousepos()
			return { m.line - 1, m.column - 1 }, vim.api.nvim_win_get_buf(m.winid)
		else
			local r = vim.fn.getpos(expr)
			local buf = r[1]
			r[1] = r[2] - 1
			r[2] = r[3] - 1
			r[3] = nil
			return r, buf
		end
	end

	---@param point Range2|Range4|pos_expr
	---@param fallback? integer should be provided if pos_expr points to a mark
	---@return integer
	function M.point_to_byte(point, fallback)
		if type(point) ~= 'table' then point = M.get_point(point) end
		if not point then return fallback end
		return vim.fn.line2byte(point[1] + 1) - 1 + point[2]
	end

	---@alias manipulator.VisualMode 'v'|'V'|'\022'|'s'|'S'|'\019'
	---@alias manipulator.VisualModeEnabler table<manipulator.VisualMode, true>

	--- Get a range from the current buffer
	---@see manipulator.range_utils.get_point
	---@param s_expr pos_expr|manipulator.VisualModeEnabler|'visual'
	---@param e_expr? pos_expr same as `s_expr` if not provided, or `'.'` for visual mode enabler
	---@param order? boolean should we reorder the expressions to ensure s<e
	---@return Range4? range
	---@return integer? buf buffer of the s_expr
	---@return boolean? swapped if the order of expressions was changed to make a positive range
	function M.get_range(s_expr, e_expr, order)
		if type(s_expr) == 'table' or s_expr == 'visual' then
			local modes = type(s_expr) == 'table' and s_expr
				or { v = true, V = true, ['\022'] = true, s = true, S = true }
			if modes[vim.fn.mode()] then
				s_expr = 'v'
				e_expr = '.'
			else
				return nil, nil
			end
		end

		local from, buf = M.get_point(s_expr)
		local to = e_expr and M.get_point(e_expr) or from

		local swapped = false
		if e_expr and order and M.cmpPoint(from, to) > 1 then
			local tmp = to
			to = from
			from = tmp
			swapped = true
		end

		---@cast from Range2|Range4
		from[3] = to[1]
		from[4] = to[2]
		return from, buf, swapped
	end
end

return M
