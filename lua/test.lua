require 'bench'
local m = require 'manipulator'
local mts, mcp = m.ts, m.call_path

map('', ' ll', mcp.ts:collect(mcp:new():parent { types = { ['*'] = true } }):pick().fn)

local getters = {
	ltree = function(range) return vim.treesitter.get_parser(0):language_for_range(range):named_node_for_range(range) end,
	mts = function(range) return mts.get({ range = range }).node end,
	mts_current = function() return mts.current({ on_partial = 'larger' }).node end, -- measures overhead of getting cursor
	mts_current_partial = function() return mts.current({ on_partial = 'cursor' }).node end,
	mts_no_inj = function(range) return mts.get({ range = range, langs = false, types = { ['*'] = true } }).node end,
}

local lines

-- Generate random ranges, end exclusive
local function gen_rnd_point(range)
	local line = math.random(range[1], range[3])
	local col = math.random(range[2], range[4] or #lines[line])
	return { line, col }
end

local function gen_rnd_range0(range)
	local from = gen_rnd_point(range)
	local to = gen_rnd_point(range)
	-- make single-point
	if from[1] > to[1] or (from[1] == to[1] and from[2] > to[2]) then from = to end
	return { from[1] - 1, from[2] - 1, to[1] - 1, to[2] - 1 }
end

local function gen_real_ranges(size)
	lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

	local ranges = { [size] = { 1, 1, #lines } }
	for i = 1, size do
		ranges[i] = gen_rnd_range0(ranges[size])
	end
	return ranges
end

local function bench_filters()
	local args = {
		{ 'function_call', 'call_expression', 'return_statement' },

		{
			'function',
			'arrow_function',
			'function_definition',
			'function_declaration',
			'method_declaration',
			'function_call',
			'call_expression',
			'return_statement',
			'variable_declaration',
			'parameter_declaration',
			'field',
		},
	}

	local sts = require 'syntax-tree-surfer'
	local cp = mcp.ts.next['&1']:jump()['&$']['*1']

	local filters = {
		sts = function(_, types) sts.filtered_jump(types, true, {}) end,
		mts = function(_, types) mts.current():next({ types = types, allow_child = true }):jump() end,
		cp = function(_, types) cp({ types = types, allow_child = true }):exec() end,
	}

	local pos = m.region.current()
	local size = 10000
	local ranges = gen_real_ranges(size)
	ranges = { { #lines - 1, 1, #lines - 1, vim.v.maxcol } }
	_G.bench {
		duration = 2, -- iterations = size,
		methods = getters,
		args = function(i)
			local range = ranges[i % #ranges + 1]
			pos:new(range):select()
			return { range, vim.tbl_extend('keep', {}, args[i % #args + 1]) }
		end,
	}
	vim.api.nvim_input '<Esc>'
	pos:jump()
end
map('n', '<leader>bf', bench_filters)
