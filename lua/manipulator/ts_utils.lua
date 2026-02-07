---@diagnostic disable: missing-fields

local Range = require 'manipulator.range'
local TQ = require 'manipulator.ts_query'

---@class manipulator.ts_utils
local M = {}

---@param opts manipulator.TS.Opts
---@param node TSNode
---@param return_node TSNode? is the result when at a new range but {node} has bad type
---@param new TSNode?
---@param prefer_new boolean if the loop output would be the new node
---@return boolean # if the loop can end and return {return_node}
---@return TSNode? return_node updated to {node} or {new} if its type is accepted
function M.validate_parented_node(opts, node, return_node, new, prefer_new)
	-- ensure we hold the highest acceptable node
	if not prefer_new and opts.types[node:type()] then return_node = node end

	-- have we found a node of a different size?
	if new and not Range.__eq({ node:range() }, { new:range() }) then
		if prefer_new then
			if opts.types[new:type()] then return true, new end
		else
			-- accepts a node that may not be the top one in the range, but has acceptable type
			if return_node then return true, return_node end
		end
	end

	return false, return_node
end

---@type fun(opts:manipulator.TS.Opts, node:TSNode, ltree:vim.treesitter.LanguageTree):
--- (TSNode?,vim.treesitter.LanguageTree?)
function M.get_parent(opts, node, ltree)
	local parent = node:parent()

	if not parent and opts.langs then
		ltree = ltree:parent()
		if ltree then parent = ltree:node_for_range { node:range() } end
	end

	return parent, ltree
end

--- Get the furthest ancestor with the same range as current node,
--- or lowest parent with larger range if {return_parent}.
---@type fun(opts:manipulator.TS.Opts, node:TSNode?, ltree:vim.treesitter.LanguageTree,
---return_parent:boolean?): (TSNode?,vim.treesitter.LanguageTree?)
function M.get_identical_ancestor(opts, node, ltree, return_parent)
	if not node then return end

	local parent, otree = node, ltree

	-- if enabled skip to lowest accepted language tree (from current ltree upwards)
	local langs = opts.langs
	if langs then
		while not langs[ltree:lang()] do
			ltree = ltree:parent()
			if not ltree then return end
		end

		if ltree ~= otree then parent = ltree:node_for_range { node:range() } end
	end

	---@diagnostic disable-next-line: undefined-field
	if opts.query then
		---@diagnostic disable-next-line: inject-field
		opts._t_def = rawget(opts.types, '*')
		opts.types['*'] = true
	end

	-- update the range to the found acceptable node to find its top identity
	local ok, return_node = false, nil
	while parent and not ok do
		node = parent
		parent = parent:parent()

		if not parent and langs then
			otree = ltree
			ltree = ltree:parent() -- we expect only the bottom langs to be disabled -> no check here
			if ltree then parent = ltree:node_for_range { node:range() } end
		end

		ok, return_node = M.validate_parented_node(opts, node, return_node, parent, return_parent)
	end

	---@diagnostic disable-next-line: undefined-field
	if opts.query then
		opts.types['*'] = opts._t_def
		---@diagnostic disable-next-line: inject-field
		opts._t_def = nil
	end

	return return_node, return_parent and ltree or otree
end

---@type fun(opts:manipulator.TS.Opts, node:TSNode, ltree:vim.treesitter.LanguageTree,
---idx:0|-1): (TSNode?,vim.treesitter.LanguageTree?)
function M.get_child(opts, node, ltree, idx)
	local cnt = node:named_child_count()

	if cnt == 0 then -- search in the subtrees
		local r = { node:range() } -- shrink the range to fit the subtree root
		r[2] = r[2] + 1 -- luadoc doesn't include the third `-`, but the referring doc node does
		-- NOTE: an inner parser ending one char earlier has not been found yet
		-- if r[4] > 0 then r[4] = r[4] - 1 end

		local otree = ltree
		ltree = ltree:language_for_range(r)
		if ltree and ltree ~= otree and opts.langs and opts.langs[ltree:lang()] then
			node = ltree:named_node_for_range(r) ---@type TSNode get the root of the tree

			-- ensure type gets filtered (max 1 root with the same size exists)
			if node:parent() then node = node:parent() end
		else
			return
		end
		return node, ltree
	else
		return node:named_child(idx >= 0 and 0 or (cnt + idx)), ltree
	end
end

--- Depth-first search for a sub-node to the given side (first or last).
local function find_valid_descendant(opts, node, ltree, idx, orig_parent)
	if node:type() == 'inline' then -- XXX: partial fix for md inline
		-- manages to match the inner inline node only if there is no `block_continuation`
		node = ltree:named_node_for_range { node:range() }
		if node:parent() then return end
	end

	node, ltree = M.get_child(opts, node, ltree, idx)

	while node do
		if M.validate_parented_node(opts, orig_parent, nil, node, true) then return node, ltree end
		local gchild, gtree = find_valid_descendant(opts, node, ltree, idx, orig_parent)
		if M.validate_parented_node(opts, orig_parent, nil, gchild, true) then return gchild, gtree end

		node = node[idx >= 0 and 'next_named_sibling' or 'prev_named_sibling'](node)
	end
end

---@type fun(opts:manipulator.TS.QueryOpts, node:TSNode, ltree:vim.treesitter.LanguageTree,
---idx?:integer|Range4): (TSNode?,vim.treesitter.LanguageTree?)
function M.get_descendant(opts, node, ltree, idx)
	if not idx then idx = 0 end
	local child = node

	-- specified a particular index -> no readjustment to find the top-level result
	if type(idx) == 'table' or idx > 0 or idx < -1 then
		local cnt = node:named_child_count()

		-- sift through identically-sized nodes until a new range
		while cnt <= 1 do
			node = child
			child, ltree = M.get_child(opts, child, ltree, idx)
			if child then
				if not Range.__eq({ node:range() }, { child:range() }) then break end
				cnt = child:named_child_count()
			else
				break
			end
		end

		-- pick the node at the particular idx/position
		if type(idx) == 'table' then
			child = node:child_with_descendant(node:named_descendant_for_range(idx[1], idx[2], idx[3], idx[4]))
		else
			child = (cnt + idx) >= 0 and node:named_child(idx >= 0 and 0 or (cnt + idx)) ---@type TSNode?
		end

		-- if the picked node is valid, or non-existent, then we're done
		if not child or M.validate_parented_node(opts, node, nil, child, true) then return child, ltree end
	end

	if opts.query then -- TODO: implement a version working for a specific index
		local base_range = { node:range() }
		local filter = function(node) return Range.cmp_containment(base_range, { node:range() }) > 0 end
		node, ltree = TQ.get_all(filter, ltree, opts)
		return TQ.sorted(node, idx == 0 and TQ.comparators.top_left or TQ.comparators.top_right, true), ltree
	end

	return find_valid_descendant(opts, child, ltree, idx, node)
end

--- Traverse the graph left or right of the current node with the given restraints.
--- NOTE: when using `.query` only comparison options work, not restrictions (`max_...`)
---@class manipulator.TS.GraphOpts: manipulator.TS.QueryOpts
---@field max_descend? integer|false how many lower levels to scan for a result (not necessarily direct child)
---@field max_ascend? integer|false the furthest parent to consider returning
---@field max_link_dst? integer|false how far from the original can the common ancestor be (<= `max_ascend`)
---@field allow_child? boolean if children of the current node can be returned (NOTE: forced `false` for prev)
---@field start_point? pos_expr|Range2 0-indexed, from where to start looking for nodes
--- Should we look in direction by end of node or start.
--- In 'prev' search can enforce no parent can be selected (end_() will always be after self:start())
---@field compare_end? boolean

---@type fun(direction:'prev'|'next',opts:manipulator.TS.GraphOpts, node:TSNode,
---ltree:vim.treesitter.LanguageTree): (TSNode?,vim.treesitter.LanguageTree?)
function M.search_in_graph(direction, opts, node, ltree)
	local types = opts.types ---@type manipulator.Enabler
	local max_depth = opts.max_descend or vim.v.maxcol
	local min_shared = -(opts.max_link_dst or vim.v.maxcol)
	local min_depth = -(opts.max_ascend or vim.v.maxcol)
	local cmp_fn = opts.compare_end and function(n) return n:end_() end or function(n) return n:start() end

	local o_range = { node:range() }
	local depth = 0
	local tmp, tmp_tree = nil, ltree
	local ok_range
	local continue = function()
		return node and not (types[node:type()] and ok_range(node) and not Range.__eq({ node:range() }, o_range))
	end

	if direction == 'prev' then
		local base_point = math.min(select(3, node:start()), Range.to_byte(opts.start_point, vim.v.maxcol))
		ok_range = function(node) return select(3, cmp_fn(node)) < base_point end

		if opts.query then
			node, ltree = TQ.get_all(ok_range, ltree, opts)
			return TQ.sorted(node, TQ.comparators.right, true), ltree
		end

		while continue() do
			-- must begin with sibling to prevent looping parent-child in repeated uses
			tmp = node:prev_named_sibling()

			if tmp then
				tmp_tree = ltree
				while tmp do
					node, ltree = tmp, tmp_tree
					if depth == max_depth then break end
					depth = depth + 1
					tmp, tmp_tree = M.get_child(opts, node, ltree, -1)
				end
			elseif depth > min_shared then
				depth = depth - 1
				node, ltree = M.get_parent(opts, node, ltree)
			else
				node = nil
			end
		end
	else -- direction == 'next'
		local base_point = math.max(
			opts.allow_child and select(3, node:start()) or select(3, node:end_()),
			Range.to_byte(opts.start_point, -1)
		)
		ok_range = function(node) return select(3, cmp_fn(node)) > base_point end

		if opts.query then
			node, ltree = TQ.get_all(ok_range, ltree, opts)
			return TQ.sorted(node, TQ.comparators.left, true), ltree
		end

		while continue() do
			if depth < max_depth then
				depth = depth + 1
				tmp, tmp_tree = M.get_child(opts, node, ltree, 0)
			else
				tmp = nil
			end

			if tmp then
				ltree = tmp_tree
			else
				while node and not tmp and depth >= min_shared do
					tmp = node:next_named_sibling()
					if not tmp then
						depth = depth - 1
						node, ltree = M.get_parent(opts, node, ltree)
					end
				end
			end

			node = tmp
		end
	end

	if depth < min_depth then return nil end
	return node, ltree
end

return M
