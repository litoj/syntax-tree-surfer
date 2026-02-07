---@diagnostic disable: invisible
---@diagnostic disable: missing-fields
local Range = require 'manipulator.range'

---@class manipulator.ts_query
local M = {}

-- TODO: remake this into producing it's own Region entity

---@class manipulator.NodeBatch: TSNode
---@field nodes TSNode[] ordered list of nodes under this capture
---@field capture string begins with '@'
local NodeBatch = {}
function NodeBatch.__index(tbl, idx)
	local ret = NodeBatch[idx]
	if not ret then
		ret = function(tbl, ...) return tbl.nodes[1][idx](tbl.nodes[1], ...) end
		NodeBatch[idx] = ret
	end
	tbl[idx] = ret

	return ret
end
function NodeBatch:start() return unpack(self.s) end
function NodeBatch:end_() return unpack(self.e) end
function NodeBatch:range() return self.s[1], self.s[2], self.e[1], self.e[2] end
---@param capture string should start with '@'
---@return manipulator.NodeBatch
function NodeBatch:new(nodes, capture)
	self = setmetatable({ nodes = nodes, capture = capture }, self)
	self.s = { nodes[1]:start() }
	self.e = { nodes[#nodes]:end_() }
	return self
end

---@class manipulator.TS.QueryOpts: manipulator.TS.Opts
--- Query which we use to filter the types (default: false - filters by raw node types).
--- Either the category to load, or custom query to filter by
---@field query? false|string|'highlights'|'textobjects'|'locals'|'folds'|'injections'

--- Get nodes of a custom query.
--- If the query nodetype is not available, then you're in the wrong ltree.
---@param filter fun(node:manipulator.NodeBatch):boolean
---@param ltree vim.treesitter.LanguageTree
---@param opts manipulator.TS.QueryOpts set .langs to false to enforce using toplevel tree
---@return manipulator.NodeBatch[]
---@return vim.treesitter.LanguageTree?
function M.get_all(filter, ltree, opts)
	if opts.langs == false then -- user disabled all subtrees -> go back to main tree
		---@diagnostic disable-next-line: need-check-nil
		while ltree:parent() do
			ltree = ltree:parent()
		end
	elseif type(opts.langs) == 'table' then
		while ltree and not opts.langs[ltree:lang()] do
			ltree = ltree:parent()
		end
	end
	if not ltree then return {}, nil end

	local query_src = opts.query
	---@diagnostic disable-next-line: need-check-nil
	local query = query_src:match '[^a-z0-9]' and vim.treesitter.query.parse(ltree:lang(), query_src)
		or vim.treesitter.query.get(ltree:lang(), query_src)
	if not query then error('Invalid query group: ' .. query_src) end

	local accepts = {}
	do
		local captures = opts.types
		for i, c in ipairs(query.captures) do
			---@diagnostic disable-next-line: need-check-nil
			if captures['@' .. c] then accepts[i] = true end
		end
		if vim.tbl_isempty(accepts) then
			error(
				'Selected types do not match any defined capture group: '
					.. vim.inspect { available = query.captures, requested = captures }
			)
		end
	end

	local nodes = {}
	for _, match, metadata in query:iter_matches(ltree:trees()[1]:root(), ltree._source, 0, -1) do
		if not vim.tbl_isempty(metadata) then
			error(
				'TODO: finally sth with metadata, see what it is: ' .. vim.inspect { m = metadata, c = query.captures }
			)
		end

		for id, found in pairs(match) do
			if accepts[id] then
				local node = NodeBatch:new(found, '@' .. query.captures[id])
				if filter(node) then nodes[#nodes + 1] = node end
			end
		end
	end

	return nodes, ltree
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
---@type fun(br:Range4,t:vim.treesitter.LanguageTree,o:manipulator.TS.QueryOpts,f:boolean,s:boolean):(TSNode|TSNode[],vim.treesitter.LanguageTree)
function M.get_ancestor(base_range, ltree, opts, get_first, allow_self)
	local containedness = allow_self and 0 or 1
	local filter = function(node) return Range.cmp_containment({ node:range() }, base_range) >= containedness end
	local nodes, ltree = M.get_all(filter, ltree, opts)
	return M.sorted(nodes, M.comparators.bottom, get_first), ltree
end

return M
