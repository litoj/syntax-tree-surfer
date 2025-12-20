---@class manipulator.range_utils
---@field false_end_in_insert string luapat to determine if the char is a valid part of a region or if the region should end 1 char earlier
local M = {
	false_end_in_insert = '[, ]',
}

---@class manipulator.BufRange
---@field range Range4 0-indexed range with the buf number
---@field buf integer? (default: 0)

---@alias manipulator.RangeType manipulator.Region|manipulator.BufRange|Range4 0-inexed range

do -- ### Range converions
	---@param range manipulator.RangeType any 0-indexed range
	---@param explicit_buf? boolean if true replace buf=0 with actual bufnr
	---@return integer
	---@return Range4|{} 0-indexed buffer number and range or an empty table
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
	---@param a Range
	---@param b Range
	---@return integer # <0 if a<b, 0 if a==b, >0 if a>b
	function M.cmpPoint(a, b) return a[1] == b[1] and a[2] - b[2] or a[1] - b[1] end

	---@param a Range
	---@param b Range
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

	---@param a Range
	---@param b Range
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

	--- Shift the end by -1 if EOL is selected or the char falls under `pattern`
	---@param point Range2 0-indexed
	---@param pattern? string|boolean luapat testing if the char is extra (default: `M.false_end_in_insert`)
	---   - trims only EOL if set to `false`
	---@return Range2 point
	function M.fix_end(buf, point, pattern)
		if point[2] == 0 then return point end
		local char = vim.api.nvim_buf_get_lines(buf, point[1], point[1] + 1, true)[1]:sub(point[2] + 1, point[2] + 1)
		if
			char == ''
			or (pattern ~= false and char:match(type(pattern) == 'string' and pattern or M.false_end_in_insert))
		then
			point[2] = point[2] - 1
		end
		return point
	end

	---@param point manipulator.RangeType 0-indexed point
	---@param insert_after? boolean should the cursor come after the point in 's'/'i' mode
	---@param start_insert? boolean should we enter insert mode
	function M.jump(point, insert_after, start_insert)
		local buf, range = M.decompose(point)
		local mode = vim.fn.mode()
		if mode == 'i' or mode == 's' or start_insert then
			M.fix_end(buf, range) -- shifts back by one if at EOL
			if insert_after then range[2] = range[2] + 1 end -- to be after the selection
			if start_insert and mode ~= 'i' then vim.cmd.startinsert() end
		end

		vim.api.nvim_win_set_buf(0, buf)
		vim.api.nvim_win_set_cursor(0, { range[1] + 1, range[2] })
	end

	---@param region manipulator.RangeType
	---@return Range4 # 0-indexed range of the region trimmed to the
	function M.get_trimmed_range(region)
		local _, range = M.decompose(region)
		local lines = M.get_lines(region)

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

	---@alias manipulator.VisualMode 'v'|'V'|'\022'|'s'|'S'|'\019'
	---@alias manipulator.VisualModeEnabler table<manipulator.VisualMode, true>

	---@param v_modes? manipulator.VisualModeEnabler map of modes allowed to get visual range for ({} to disable)
	---@param insert_fixer? string|boolean pattern to check for -1 offset necessity (default: true = fixes spaces)
	---@return Range4? 0-indexed
	---@return boolean? leading if cursor was at the beginning of the current selection
	function M.current_visual(v_modes, insert_fixer)
		v_modes = type(v_modes) == 'table' or { v = true, V = true, ['\022'] = true, s = true }
		local mode = vim.fn.mode()
		if not v_modes[mode] then return end

		local from, to = vim.fn.getpos 'v', vim.fn.getpos '.'
		local leading = false
		if from[2] > to[2] or (from[2] == to[2] and from[3] > to[3]) then -- [1]=bufnr
			local tmp = to
			to = from
			from = tmp
			leading = true
		end
		local range = {
			from[2] - 1,
			from[3] - 1,
			to[2] - 1,
			to[3] - 1,
		}

		if insert_fixer ~= false then -- all visual modes can select the EOL
			local tmp = M.fix_end(0, { range[3], range[4] }, mode == 's' and (insert_fixer or true) or false)
			range[4] = tmp[2]
		end

		return range, leading
	end

	---@param mouse? boolean if mouse or cursor position should be retrieved
	---@param insert_fixer? string|boolean pattern to check for -1 offset necessity (default: true = fixes spaces)
	---@return manipulator.BufRange
	function M.current_point(mouse, insert_fixer)
		local ret
		if mouse then
			local m = vim.fn.getmousepos()
			ret = {
				buf = vim.api.nvim_win_get_buf(m.winid),
				range = { m.line - 1, m.column - 1 },
				mouse = true,
			}
		else
			ret = { buf = 0, range = vim.api.nvim_win_get_cursor(0) }
			ret.range[1] = ret.range[1] - 1
			local mode = vim.fn.mode()

			if mode ~= 'n' and insert_fixer ~= false then -- ensure we're not selecting eol
				M.fix_end(ret.buf, ret.range, (mode == 'i' or mode == 's') and (insert_fixer or true) or false)
			end

			if mode == 'i' then
				ret.range[3] = ret.range[1]
				ret.range[4] = ret.range[2] - 1
				return ret
			end
		end

		ret.range[3] = ret.range[1]
		ret.range[4] = ret.range[2]
		return ret
	end
end

return M
