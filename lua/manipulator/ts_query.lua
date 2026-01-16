---@diagnostic disable: invisible
---@diagnostic disable: missing-fields
local Range = require 'manipulator.range'

---@class manipulator.ts_query
local M = {}

--- Get nodes of a custom query
--- NOTE: When passing in the raw query string, you probably don't want to filter by node types.
---@param filter fun(node:TSNode):boolean
---@param ltree vim.treesitter.LanguageTree NOTE: presumes the tree is the root tree -> 1 TSTree
---@param query_src string string of the actual query or a predefined group ('textobjects' etc.)
---@param captures manipulator.Enabler which capture groups should we collect
---@return TSNode[]
function M.get_all(filter, ltree, query_src, captures)
	-- TODO: to make it usable as a general alternate traversal
	-- 1. detect changes in buffer and invalidate cache after change
	-- 2. get and cache all nodes matching query with the metadata in some processable format

	local query = query_src:match '[^a-z0-9]' and vim.treesitter.query.parse(ltree:lang(), query_src)
		or vim.treesitter.query.get(ltree:lang(), query_src)
	if not query then error('Invalid query group: ' .. query_src) end

	local accepts = {}
	for i, c in ipairs(query.captures) do
		if captures[c] then accepts[i] = true end
	end
	if vim.tbl_isempty(accepts) then
		error(
			'Selected types do not match any defined capture group: '
				.. vim.inspect { available = query.captures, requested = captures }
		)
	end

	local nodes = {}
	for _, match, metadata in query:iter_matches(ltree:trees()[1]:root(), ltree._source, 0, -1) do
		for id, found in pairs(match) do
			if accepts[id] then
				for _, node in ipairs(found) do
					if metadata[id] then
						error(
							'TODO: finally sth with metadata, see what it is: '
								.. vim.inspect { name = query.captures[id], metadata[id] }
						)
					end
					if filter(node) then nodes[#nodes + 1] = node end
				end
			end
		end
	end

	return nodes
end

---@alias manipulator.Comparator fun(a:Range4,b:Range4):boolean

---@type table<string,manipulator.Comparator>
M.comparators = {
	top_left = function(a, b) return Range.cmp_end(a, b) < 0 or Range.contains(a, b) end,
	top_right = function(a, b) return Range.cmp_end(b, a) < 0 or Range.contains(a, b) end,
	top = Range.contains_not_eq,
	bottom = function(a, b) return Range.cmp_containment(b, a) > 0 end,
	bottom_left = function(a, b) return Range.cmp_end(a, b) < 0 or Range.contains(b, a) end,
	bottom_right = function(a, b) return Range.cmp_end(b, a) < 0 or Range.contains(b, a) end,
	left = function(a, b) return Range.cmp_end(a, b) < 0 end,
	right = function(a, b) return Range.cmp_end(b, a) < 0 end,
}

---@param nodes TSNode[]
---@param cmp fun(a:Range4, b:Range4):boolean should we swap b and a
---@param first boolean should we get just the first node
---@param no_cmp_wrap? boolean should the comparator be used as is (provide full node acces, not just range)
---@return TSNode[]|TSNode
function M.sorted(nodes, cmp, first, no_cmp_wrap)
	local cmp = no_cmp_wrap and cmp or function(a, b) return cmp({ a:range() }, { b:range() }) end
	if not first then
		table.sort(nodes, cmp)
		return nodes
	end

	local min = nodes[1]
	local swapped = 0

	for _, item in ipairs(nodes) do
		if cmp(item, min) then
			swapped = swapped + 1
			min = item
		end
	end

	return min
end

---@see manipulator.ts_query.get_all
---@type fun(br:Range4,t:vim.treesitter.LanguageTree,q:string,c:manipulator.Enabler,f:boolean,s:boolean):(TSNode|TSNode[])
function M.get_ancestor(base_range, ltree, query, captures, get_first, allow_self)
	local containedness = allow_self and 0 or 1
	local filter = function(node) return Range.cmp_containment({ node:range() }, base_range) >= containedness end
	local nodes = M.get_all(filter, ltree, query, captures)
	return M.sorted(nodes, M.comparators.bottom, get_first)
end

return M
