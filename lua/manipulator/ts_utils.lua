---@diagnostic disable: missing-fields
---@class manipulator.ts_utils
local M = {}

local RANGE_UTILS = require 'manipulator.range_utils'

---@param opts manipulator.TSRegion.Opts
---@param node TSNode
---@param return_node TSNode?
---@param new TSNode?
---@param prefer_new boolean if the loop output would be the new node
---@return boolean # if the loop can end and return {return_node}
---@return TSNode? return_node updated to {node} or {new} if its type is accepted
function M.valid_parented_node(opts, node, return_node, new, prefer_new)
	-- ensure we hold the highest acceptable node
	if not prefer_new and opts.types[node:type()] then return_node = node end

	-- test for a new range size
	if new and RANGE_UTILS.rangeContains({ node:range() }, { new:range() }) ~= 0 then
		if prefer_new then
			if opts.types[new:type()] then return true, new end
		else
			if return_node then return true, return_node end
		end
	end

	return false, return_node
end

---@type fun(opts:manipulator.TSRegion.Opts, node:TSNode, ltree:vim.treesitter.LanguageTree):
--- (TSNode?,vim.treesitter.LanguageTree?)
function M.get_direct_parent(opts, node, ltree)
	local parent = node:parent()

	if not parent and opts.langs then
		ltree = ltree:parent()
		if ltree then parent = ltree:node_for_range { node:range() } end
	end

	return parent, ltree
end

--- Get the furthest ancestor with the same range as current node,
--- or lowest parent with larger range if {return_parent}.
---@type fun(opts:manipulator.TSRegion.Opts, node:TSNode?, ltree:vim.treesitter.LanguageTree,
---return_parent:boolean?): (TSNode?,vim.treesitter.LanguageTree?)
function M.top_identity(opts, node, ltree, return_parent)
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

	-- update the range to the found acceptable node to find its top identity
	local ok, return_node = false, nil
	while parent and not ok do
		node = parent
		parent = parent:parent()

		if not parent and langs then
			otree = ltree
			ltree = ltree:parent()
			if ltree then parent = ltree:node_for_range { node:range() } end
		end

		ok, return_node = M.valid_parented_node(opts, node, return_node, parent, return_parent)
	end

	return return_node, return_parent and ltree or otree
end

---@type fun(opts:manipulator.TSRegion.Opts, node:TSNode, ltree:vim.treesitter.LanguageTree,
---idx:0|-1): (TSNode?,vim.treesitter.LanguageTree?)
function M.get_direct_child(opts, node, ltree, idx)
	local cnt = node:named_child_count()

	if cnt == 0 then -- search in the subtrees
		local r = { node:range() } -- shrink the range to fit the subtree root
		r[2] = r[2] + 1 -- TODO: what happens when we're at the last column (md: ```lang)
		if r[4] > 0 then r[4] = r[4] - 1 end

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
local function find_valid_child(opts, node, ltree, idx, orig_parent)
	local dir_fn = idx >= 0 and node.next_named_sibling or node.prev_named_sibling
	node, ltree = M.get_direct_child(opts, node, ltree, idx)

	while node do
		if M.valid_parented_node(opts, orig_parent, nil, node, true) then return node, ltree end
		local gchild, gtree = find_valid_child(opts, node, ltree, idx, orig_parent)
		if M.valid_parented_node(opts, orig_parent, nil, gchild, true) then return gchild, gtree end

		node = dir_fn(node)
	end
end

---@type fun(opts:manipulator.TSRegion.Opts, node:TSNode, ltree:vim.treesitter.LanguageTree,
---idx?:integer|Range4): (TSNode?,vim.treesitter.LanguageTree?)
function M.get_child(opts, node, ltree, idx)
	if not idx then idx = 0 end
	local child = node

	-- specified a particular index -> no readjustment to find the top-level result
	if type(idx) == 'table' or idx > 0 or idx < -1 then
		local cnt = node:named_child_count()

		-- sift through identically-sized nodes until a new range
		while cnt <= 1 do
			node = child
			child, ltree = M.get_direct_child(opts, child, ltree, idx)
			if child then
				if RANGE_UTILS.rangeContains({ node:range() }, { child:range() }) ~= 0 then break end
				cnt = child:named_child_count()
			else
				break
			end
		end

		-- pick the node at the particular idx/position
		if type(idx) == 'table' then
			child =
				node:child_with_descendant(node:named_descendant_for_range(idx[1], idx[2], idx[3], idx[4]))
		else
			child = (cnt + idx) >= 0 and node:named_child(idx >= 0 and 0 or (cnt + idx)) ---@type TSNode?
		end

		-- if the picked node is valid, or non-existent, then we're done
		if not child or M.valid_parented_node(opts, node, nil, child, true) then return child, ltree end
	end

	return find_valid_child(opts, child, ltree, idx, node)
end

---@class manipulator.TSRegion.GraphOpts: manipulator.TSRegion.Opts
---@field allow_child? boolean if children of the current node can be returned
---@field start_point? Range2 0-indexed, from where to start looking for nodes
---@field compare_end? boolean should we look in direction by end of node or start
-- ---@field match string scheme query to match

---@type fun(opts:manipulator.TSRegion.GraphOpts, node:TSNode,
---ltree:vim.treesitter.LanguageTree): (TSNode?,vim.treesitter.LanguageTree?)
function M.next_in_graph(opts, node, ltree)
	local types = opts.types ---@type manipulator.Enabler
	local cmp_method = opts.compare_end and node.end_ or node.start

	local base_point = opts.allow_child and select(3, node:start()) or select(3, node:end_())
	if opts.start_point and opts.start_point > base_point then base_point = opts.start_point end
	local ok_range = function(node) return select(3, cmp_method(node)) > base_point end

	local tmp, tmp_tree
	while node and not (ok_range(node) and types[node:type()]) do
		tmp, tmp_tree = M.get_direct_child(opts, node, ltree, 0)

		if tmp then
			ltree = tmp_tree
		else
			while node and not tmp do
				tmp = node:next_named_sibling()
				if not tmp then
					node, ltree = M.get_direct_parent(opts, node, ltree)
				end
			end
		end

		node = tmp
	end
	return node, ltree
end

---@type fun(opts:manipulator.TSRegion.GraphOpts, node:TSNode,
---ltree:vim.treesitter.LanguageTree): (TSNode?,vim.treesitter.LanguageTree?)
function M.prev_in_graph(opts, node, ltree)
	local types = opts.types ---@type manipulator.Enabler
	local cmp_method = opts.compare_end and node.end_ or node.start

	local base_point = opts.allow_child and select(3, node:end_()) or select(3, node:start())
	if opts.start_point and opts.start_point < base_point then base_point = opts.start_point end
	local ok_range = function(node) return select(3, cmp_method(node)) < base_point end

	local tmp, tmp_tree = nil, ltree
	while node and not (ok_range(node) and types[node:type()]) do
		tmp = node:prev_named_sibling()

		if tmp then
			tmp_tree = ltree
			while tmp do
				node, ltree = tmp, tmp_tree
				tmp, tmp_tree = M.get_direct_child(opts, node, ltree, -1)
			end
		else
			node, ltree = M.get_direct_parent(opts, node, ltree)
		end
	end
	return node, ltree
end

return M
