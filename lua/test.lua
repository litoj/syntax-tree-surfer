local mts = require 'manipulator.tsregion'
local mcp = require 'manipulator.call_path'
local get_node = mcp.tsregion.current.fn

local methods = {
	top = function() return vim.treesitter.get_node { bufnr = 0 } end,
	inj_node = function() return vim.treesitter.get_node { bufnr = 0, ignore_injections = false } end,
	--[[ inj_range = function() -- faster, but we have no awareness of the language tree
		return vim.treesitter.get_parser(0):named_node_for_range(range, { ignore_injections = false })
	end,
	ltree = function()
		return vim.treesitter.get_parser(0):language_for_range(range):named_node_for_range(range)
	end, ]]
	mts = function() return mts.current().node end,
	mts_ni = function() return mts.current({ inherit = false, types = {}, nil_wrap = true }).node end,

	cp = get_node,
}
-- TODO: add info/gtdefinition for types in info windows
-- TODO: matching by query syntax and catching into groups
-- TODO: make next/prev use the general next/prev traversal/type finder
-- TODO: finally solve the visual paste before/after offset by 1 for non-line copies
-- TODO: fix prev():jump()
-- TODO: ensure move() correctly shifts visual mode
-- TODO: ensure move() moves the cursor to stay at the same relative position to the original node
-- TODO: add selection modification/filter (include trailing comma etc.)
-- TODO: add wrapper for dot repeat
-- TODO: add wrapper for <num>gc<X> style mappings (snf = select next function, gnn = jump next node)...
-- TODO: consider adding optional highlight of further jumps (like filtered_jump)
-- TODO: siblings should just set defaults to locals not modify the opts

-- Test function that uses visual selection or cursor position
local function show_node_path()
	-- test difference between sts parents
	local ret = mts.current { deep = true }
	if not ret or not ret.node then return end
	local node = ret.node

	-- collect all node and parent data
	local path = {}
	local i = 1
	while node do
		path[string.format('_%02d', i)] = {
			{ node:range() },
			node:type(),
			node:sexpr(),
		}
		i = i + 1
		node = node:named_child(0)
	end
	node = ret.node
	while node do
		path[string.format('_%02d', i)] = {
			{ node:range() },
			node:type(),
		}
		i = i + 1
		node = node:parent()
	end
	print(path, 5)
end
map('', ' ll', show_node_path)

local lines
local function update_lines(bufnr) lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false) end

-- Generate random ranges, end exclusive
local function gen_rnd_point(range)
	local line = math.random(range[1], range[3])
	local col = math.random(range[2], range[4] or #lines[line])
	return { line, col }
end

local function gen_rnd_range(range)
	local from = gen_rnd_point(range)
	local to = gen_rnd_point(range)
	if from[1] > to[1] or (from[1] == to[1] and from[2] > to[2]) then
		local tmp = from
		from = to
		to = tmp
	end
	return { from[1], from[2], to[1], to[2] }
end

local function gen_rnd_range0(bound1)
	local range = gen_rnd_range(bound1)
	return { range[1] - 1, range[2] - 1, range[3] - 1, range[4] - 1 }
end

local function gen_real_ranges(iterations)
	local ranges = { [iterations] = { 1, 1, 1, 1 } }
	update_lines(0)
	for i = 1, iterations do
		ranges[i] = gen_rnd_range0 {
			1,
			1,
			#lines, --[[ iterations ]]
		}
	end
	return ranges
end

-- Performance benchmarking for node retrieval methods
local function benchmark_node_retrieval()
	local bufnr = 0
	local iterations = 100000

	local parser = vim.treesitter.get_parser(bufnr)
	if not parser then
		print 'No parser available'
		return
	end

	-- Collect injected language regions
	local injected_regions = {}
	local seen_ltrees = {}
	-- local seen_tstrees = {}
	parser:for_each_tree(function(tstree, ltree)
		-- Deduplicate: for_each_tree may iterate over the same ltree multiple times
		local r = ltree:included_regions()
		seen_ltrees[r] = { (seen_ltrees[r] or { 0 })[1] + 1, ltree:lang() }
		-- seen_tstrees[tstree] = { (seen_tstrees[r] or { 0 })[1] + 1, ltree:lang() }
		if seen_ltrees[r][1] > 1 then return end

		local lang = ltree:lang()
		local regions = ltree:included_regions()

		-- Skip if it's the main language or already processed
		if #regions[1] > 0 then
			for _, region in ipairs(regions) do
				-- region is {start_row, start_col, end_row, end_col}
				injected_regions[#injected_regions + 1] = {
					lang = lang,
					region = { region[1][1] + 1, region[1][2] + 1, region[1][4] + 1, region[1][5] + 1 },
					ltree = ltree,
				}
			end
		end
	end)

	print(string.format('Found %d injected regions', #injected_regions))

	-- ### Range generation
	-- Get buffer dimensions
	update_lines(bufnr)

	-- Generate ranges within injected regions
	local function gen_inj_range()
		local inj = injected_regions[math.random(1, #injected_regions)]
		if not inj then return end
		local region = inj.region
		return gen_rnd_range(region)
	end

	-- Generate test ranges
	local ranges = { [iterations] = { 1, 1, 1, 1 } }
	for i = 1, iterations do
		ranges[i] = i % 2 == 1 and gen_inj_range() or gen_rnd_range { 1, 1, #lines }
	end

	-- Run benchmarks
	_G.bench {
		methods = methods,
		-- iterations = iterations,
		duration = 1,
		args = function(i)
			local range = ranges[i % #ranges + 1]
			vim.api.nvim_win_set_cursor(0, { range[1], range[2] - 1 })
			return {}
		end,
	}
end

map('n', '<leader>bp', benchmark_node_retrieval)

-- Generalized function to collect all nodes in the tree that satisfy a given filter
-- @param filter: function(node) -> boolean - determines which nodes to collect
-- @return: array of nodes that satisfy the filter
local function collect_filtered_nodes(filter)
	local parser = vim.treesitter.get_parser(0)
	if not parser then return {} end

	local collected = {}
	parser:for_each_tree(function(tstree, ltree)
		local root = tstree:root()

		-- Traverse tree and collect nodes matching the filter
		local function traverse(node)
			if not node then return end

			if filter(node) then collected[#collected + 1] = node end

			-- Recursively traverse all named children
			local child_count = node:named_child_count()
			for i = 0, child_count - 1 do
				traverse(node:named_child(i))
			end
		end

		traverse(root)
	end)

	return collected
end

local function bench_table_update()
	local iterations = 1000
	local ranges = gen_real_ranges(iterations)
	local function sub(range1, range2)
		for i, v in ipairs(range1) do
			range1[i] = math.min(v, range2[i])
		end
		return range1
	end

	_G.bench {
		methods = {
			--[[ newtbl = function(add, range1, range2)
				if add then
					range1 = {
						math.min(range1[1], range2[1]),
						math.min(range1[2], range2[2]),
						math.max(range1[3], range2[3]),
						math.max(range1[4], range2[4]),
					}
				end
				return range1
			end,
			replace = function(add, range1, range2)
				if add then
					range1[1] = math.min(range1[1], range2[1])
					range1[2] = math.min(range1[2], range2[2])
					range1[3] = math.max(range1[3], range2[3])
					range1[4] = math.max(range1[4], range2[4])
				end
				return range1
			end, ]]
			cycle_for = function(add, range1, range2)
				if add then
					for i = 1, #range1 do
						range1[i] = math.min(range1[i], range2[i])
					end
				end
				return range1
			end,
			cycle_pairs = function(add, range1, range2)
				if add then
					for i, v in ipairs(range1) do
						range1[i] = math.min(v, range2[i])
					end
				end
				return range1
			end,
			cycle_while = function(add, range1, range2)
				if add then
					local i = 1
					while range1[i] do
						range1[i] = math.min(range1[i], range2[i])
						i = i + 1
					end
				end
				return range1
			end,
			cycle_deffered = function(add, range1, range2)
				if add then range1 = sub(range1, range2) end
				return range1
			end,
		},
		duration = 5,
		args = function(i)
			return { true, ranges[i % iterations + 1], ranges[(i + iterations / 2) % iterations + 1] }
		end,
	}
end
map('n', '<leader>br', bench_table_update)

local function bench_filters()
	local iterations = 10000
	local ranges = gen_real_ranges(iterations)
	local args = {
		{ 'function_call', 'call_expression', 'return_statement' },

		--[[ {
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
		}, ]]
	}

	local sts = require 'syntax-tree-surfer'
	local mts = require 'manipulator.tsregion'

	_G.bench {
		duration = 1,
		methods = {
			sts = function(types) sts.filtered_jump(types, true, {}) end,
			mts = function(types)
				mts.current():next_in_graph({ types = types, allow_child = true }):jump()
			end,
		},
		args = function(i)
			local range = ranges[i % #ranges + 1]
			vim.api.nvim_win_set_cursor(0, { range[1] + 1, range[2] })
			return { vim.tbl_extend('keep', {}, args[i % #args + 1]) }
		end,
	}
end
map('n', '<leader>bf', bench_filters)

local tsu = require'manipulator.ts_utils'
local node = mts.current():collect({'next_in_graph'}):pick({ picker = 'fzf-lua',callback=true})
