---@diagnostic disable: cast-local-type
---@class manipulator.Pos: Range2 position in the buffer
---@field buf integer
---@operator concat(anypos):manipulator.Range
local Pos = {}
Pos.__index = Pos

---@class manipulator.BufRange
---@field range Range4 0-indexed range with the buf number
---@field buf? integer

---@alias anyrange manipulator.BufRange|Range4 0-inexed range
---@alias anypos anyrange|Range2

do -- ### Producers
	--- Get the table with the positions - may or may not contain [3], [4]
	---@param p anypos
	---@return Range4|Range2 # 0-indexed buffer number and range or an empty table
	function Pos.raw(p) return p.range or p end

	--- Create a new Pos object, guarantees a copy of the original
	---@param self anypos
	---@param buf? integer
	function Pos.new(self, buf)
		buf = buf or self.buf
		self = Pos.raw(self)
		if not self[1] then error('Invalid Pos: ' .. vim.inspect(self)) end
		return setmetatable({ buf = buf, self[1], self[2] }, Pos)
	end

	--- Get a Pos object, creating it if not already existing
	---@param p anypos
	---@return manipulator.Pos
	function Pos.get_or_make(p) return getmetatable(p) == Pos and p or Pos.new(p) end

	---@alias pos_expr 'mouse'|'.'|'v'|"'["|"']"|"'<"|"'>"|"'j"|"'d"
	---@alias pos_src pos_expr|anypos

	--- Get a Pos object created from the position of the given mark or just a wrap of the range.
	--- _Note: Doesn't create a new object if `src` is already a Pos_
	---@see vim.fn.getpos
	---@param src? pos_src expr for vim.fn.getpos or 'mouse' for mouse pos
	---@return manipulator.Pos pos or an error, if the mark doesn't exist
	function Pos.from(src)
		if type(src) == 'table' then return Pos.get_or_make(src) end

		if not src then src = '.' end
		-- vim.fn.getpos can parse all inputs, but is half as fast
		if #src == 2 or src == '.' then
			local r = src == '.' and vim.api.nvim_win_get_cursor(0) or vim.api.nvim_buf_get_mark(0, src:sub(2))
			if r[1] == 0 then error('Invalid mark: ' .. src) end
			r[1] = r[1] - 1
			return Pos.new(r, 0)
		elseif src == 'mouse' then
			local m = vim.fn.getmousepos()
			return Pos.new({ m.line - 1, m.column - 1 }, vim.api.nvim_win_get_buf(m.winid))
		else
			local r = vim.fn.getpos(src)
			if r[2] == 0 then error('Invalid pos_expr, did you want a mark?: ' .. src) end
			local buf = r[1]
			r[1] = r[2] - 1
			r[2] = r[3] - 1
			return Pos.new(r, buf)
		end
	end
end

do -- ### Getters / Actions
	---@param a anypos
	---@param b? anypos
	---@param default? integer what should we return if both buffers are undefined
	---@return false|integer? # returns the buffer if they are the same (or one is unspecified)
	function Pos.buf_eq(a, b, default)
		a = a.buf
		b = b and b.buf
		if not a or not b then return a or b or default end

		if a == b then return a end
		if a == 0 then return b == vim.api.nvim_get_current_buf() and a end
		if b == 0 then return a == vim.api.nvim_get_current_buf() and b end
		return false
	end

	---@protected
	--- Ensure both `a` and `b` are objects with methods. Optionally check they share the same buf.
	---@param require_buf_eq? boolean
	function Pos.check(a, b, require_buf_eq)
		if require_buf_eq then assert(Pos.buf_eq(a, b, 0), 'Cannot use positions from different buffers') end

		-- check valid type by looking for an uncommon method we implement - allows child types
		if a.to_byte == Pos.to_byte then -- NOTE: order matters -> addition with range first makes new R
			if getmetatable(a) == getmetatable(b) then return a, b end
			return a, a.new(b)
		elseif b.to_byte == Pos.to_byte then
			return b.new(a), b
		else
			return Pos.new(a), Pos.new(b)
		end
	end

	function Pos.get_real_buf(a) return (a.buf or 0) > 0 and a.buf or vim.api.nvim_get_current_buf() end

	---@param p pos_src
	---@return string
	function Pos.get_line(p)
		p = Pos.from(p)
		return vim.api.nvim_buf_get_lines(p.buf or 0, p[1], p[1] + 1, true)[1]
	end

	---@param p anypos
	function Pos.jump(p)
		vim.api.nvim_set_current_buf(p.buf or 0)
		p = Pos.raw(p)
		vim.api.nvim_win_set_cursor(0, { p[1] + 1, p[2] })
	end

	---@param p pos_src
	---@param fallback? integer should be provided if pos_expr points to a mark
	---@return integer
	function Pos.to_byte(p, fallback)
		p = Pos.from(p)
		if not p then return fallback end
		return vim.fn.line2byte(p[1] + 1) - 1 + p[2]
	end

	function Pos.to_list(p)
		p = Pos.from(p)
		return { p[1], p[2], p[3], p[4] }
	end
end

do -- ### Comparisons
	---@param a anypos
	---@param b anypos
	---@return integer # comparison of the positions (only first and second fields)
	function Pos.cmp(a, b)
		assert(Pos.buf_eq(a, b, 0), 'Cannot compare positions from different buffers')
		a = Pos.raw(a)
		b = Pos.raw(b)
		return a[1] == b[1] and a[2] - b[2] or a[1] - b[1]
	end

	---@param a anypos
	---@param b anypos
	function Pos.__eq(a, b)
		if not Pos.buf_eq(a, b, 0) then return false end
		a = Pos.raw(a)
		b = Pos.raw(b)
		for i = 1, #a do
			if a[i] ~= b[i] then return false end
		end
		return true
	end
	function Pos.__lt(a, b) return Pos.cmp(a, b) < 0 end
	function Pos.__le(a, b) return Pos.cmp(a, b) <= 0 end

	--- Get the change it takes to get from A to B - line diff and cols from start or just col diff.
	---@return manipulator.Pos # positive if B is after A
	function Pos.distance_to(a, b)
		b, a = Pos.check(b, a, true)
		if b[1] == a[1] then
			return Pos.new({ 0, b[2] - a[2] }, b.buf or a.buf)
		else
			return Pos.new({ b[1] - a[1], b[2] }, b.buf or a.buf)
		end
	end
end

do -- ### Math set operations - array processing, no text awereness
	---@param b? self
	---@param fun fun(ai:integer,bi?:integer):integer
	---@return self
	function Pos:for_each(b, fun)
		local n = {}
		b = b or { 0, 0, 0, 0 }
		for i = 1, #self do
			if not b[i] then break end
			n[i] = fun(self[i], b[i])
			-- ensure inclusion of EOL cannot be changed
			if i % 2 == 0 and n[i] > vim.v.maxcol / 2 then n[i] = vim.v.maxcol end
		end
		return self.new(n, b and b.buf or self.buf)
	end

	--- Adds the fields of `b` to the respective fields of `a`.
	--- **processing as an array, not a text oject**
	---@param a anypos
	---@param b anypos
	function Pos.__add(a, b)
		a, b = Pos.check(a, b, true)
		return a:for_each(b, function(a, b) return a + b end)
	end

	--- Subtracts the fields of `b` to the respective fields of `a`.
	--- **processing as an array, not a text oject**
	---@param a anypos
	---@param b anypos
	function Pos.__sub(a, b)
		a, b = Pos.check(a, b, true)
		return a:for_each(b, function(a, b) return a - b end)
	end

	--- Get all fields in absolute values.
	---@param a anypos
	function Pos.abs(a)
		a = Pos.get_or_make(a)
		return a:for_each(nil, function(a) return math.abs(-a) end)
	end
end

return Pos
