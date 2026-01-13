---@diagnostic disable: invisible
---@diagnostic disable: missing-fields
local Range = require 'manipulator.range'

---@class manipulator.ts_query
local M = {}

--- Get nodes of a custom query
--- NOTE: When passing in the raw query string, you probably don't want to filter by node types.
---@param ltree vim.treesitter.LanguageTree NOTE: presumes the tree is the root tree -> 1 TSTree
---@param query string string of the actual query or a predefined group ('textobjects' etc.)
---@param filter fun(node:TSNode):boolean
---@param captures manipulator.Enabler which capture groups should we collect
---@return TSNode[]
function M.get_all(ltree, query, filter, captures)
	-- TODO: to make it usable as a general alternate traversal
	-- 1. detect changes in buffer and invalidate cache after change
	-- 2. get and cache all nodes matching query with the metadata in some processable format
	-- 3. implement the base methods used on nodes
	-- 4. result returns a normal node -> next use has to find it in the cache again

	local query = query:match '[^a-z0-9]' and vim.treesitter.query.parse(ltree:lang(), query)
		or vim.treesitter.query.get(ltree:lang(), query)

	local nodes = {}
	for _, match, metadata in query:iter_matches(ltree:trees()[1]:root(), ltree._source, 0, -1) do
		for id, found in pairs(match) do
			local name = query.captures[id]
			for _, node in ipairs(found) do
				if metadata[id] then
					error(
						'TODO: finally sth with metadata, see what it is: ' .. vim.inspect { name = name, metadata[id] }
					)
				end
				if captures[name] and filter(node) then nodes[#nodes + 1] = node end
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
}

---@param nodes TSNode[]
---@param first boolean should we get just the first node
---@param cmp fun(a:Range4, b:Range4):boolean should we swap b and a
---@return TSNode[]|TSNode
local function sorted(nodes, cmp, first)
	local cmp = function(a, b) return cmp({ a:range() }, { b:range() }) end
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

---@alias query_dir fun(br:Range4,lt:vim.treesitter.LanguageTree,q:string,c:manipulator.Enabler,f:boolean):(TSNode|TSNode[])

---@see manipulator.ts_query.get_all
---@type fun(br:Range4,lt:vim.treesitter.LanguageTree,q:string,c:manipulator.Enabler,f:boolean,s:boolean):(TSNode|TSNode[])
function M.get_ancestor(base_range, ltree, query, captures, get_first, allow_self)
	local containedness = allow_self and 0 or 1
	local filter = function(node) return Range.cmp_containment({ node:range() }, base_range) >= containedness end
	local nodes = M.get_all(ltree, query, filter, captures)
	return sorted(nodes, M.comparators.bottom, get_first)
end

---@see manipulator.ts_query.get_all
---@param idx 0|-1 which end to look for the child from (how to sort the descendants)
---@type fun(br:Range4,lt:vim.treesitter.LanguageTree,q:string,c:manipulator.Enabler,f:boolean,s:boolean,i:0|-1):(TSNode|TSNode[])
function M.get_descendant(base_range, ltree, query, captures, get_first, allow_self, idx)
	local containedness = allow_self and 0 or 1
	local filter = function(node) return Range.cmp_containment(base_range, { node:range() }) >= containedness end
	local nodes = M.get_all(ltree, query, filter, captures)
	return sorted(nodes, idx == 0 and M.comparators.top_left or M.comparators.top_right, get_first)
end

---@see manipulator.ts_query.get_all
---@type query_dir
function M.get_next(base_range, ltree, query, captures, get_first)
	local filter = function(node) return Range.cmp_end(base_range, { node:range() }) < 0 end
	local nodes = M.get_all(ltree, query, filter, captures)
	return sorted(nodes, M.comparators.top_left, get_first)
end

---@see manipulator.ts_query.get_all
---@type query_dir
function M.get_prev(base_range, ltree, query, captures, get_first)
	local filter = function(node) return Range.cmp_end({ node:range() }, base_range) < 0 end
	local nodes = M.get_all(ltree, query, filter, captures)
	return sorted(nodes, M.comparators.top_right, get_first)
end

return M
