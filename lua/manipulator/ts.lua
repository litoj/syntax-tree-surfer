---@diagnostic disable: invisible, missing-fields

local Region = require 'manipulator.region'
local U = require 'manipulator.utils'
local Range = require 'manipulator.range'
local TU = require 'manipulator.ts_utils'
local TQ = require 'manipulator.ts_query'
local Batch = require 'manipulator.batch'

---@class manipulator.TS: manipulator.Region
---@field node TSNode
---@field ltree vim.treesitter.LanguageTree
---@field protected config manipulator.TS.Config
local TS = setmetatable({ super = Region.class }, Region.class) -- allowing for user extensions
TS.__index = TS

---@class manipulator.TS.Opts: manipulator.Inheritable base set of options for configuring the behaviour of methods
---@field types? manipulator.Enabler|{inherit:boolean|string} which types of nodes to accept, which to ignore (if previous node of identical range not accepted) + if it should inherit previous/preset values
---@field langs? false|manipulator.Enabler|{inherit:boolean|string} which languages to accept (false to disable LanguageTree switching) (seeking further in the direction if not accepted (parent or child))
---@field nil_wrap? boolean if nodes should return a nil node wrapper instead of nil (for method chaining)
---@field save_as? false|string a non-inheritable setting to save the expanded opts into a preset

---@class manipulator.TS.Config: manipulator.TS.Opts, manipulator.Region.Config
---@field parent? manipulator.TS.QueryOpts
---@field child? manipulator.TS.QueryOpts
---@field sibling? manipulator.TS.Opts
---@field next_sibling? manipulator.TS.Opts
---@field prev_sibling? manipulator.TS.Opts
---@field in_graph? manipulator.TS.GraphOpts
---@field next? manipulator.TS.GraphOpts
---@field prev? manipulator.TS.GraphOpts
---@field presets? {[string]:manipulator.TS.Config}

---@class manipulator.TS.module.Config: manipulator.TS.Config
--- Should the base config be derived from the filetype of the given source.
--- - `'ltree'`: use only `vim.treesitter.LanguageTree:lang()` to choose the filetype
---   - each injected language can be treated differently
---   - getting the node (`.current()`, `.get_all()`, `.get()`) will be done with default config
--- - `'buf'`: use current buffer filetype and map it to the its lang with `.ft_to_lang`
--- - `'ltree_or_buf`: best of both worlds - prefer ltree, use buf when ltree is not known yet
---@field use_lang_presets? false|'buf'|'ltree'|'ltree_or_buf'
---@field ft_to_lang? table<string,string> map filetype to TS language
---@field get? manipulator.TS.QueryOpts
---@field get_all? manipulator.TS.QueryOpts
---@field current? manipulator.TS.module.current.Opts
---@field debug? false|vim.log.levels

TS.action_map = U.tbl_inner_extend('keep', Region.action_map, {
	parent = true,
	child = true,
	sibling = true,
	next_sibling = 'sibling',
	prev_sibling = 'sibling',
	in_graph = 'sibling',
	next = 'in_graph',
	prev = 'in_graph',

	get = true,
	get_all = 'get',
	current = 'get',
})

---@class manipulator.TS.module: manipulator.TS
---@field class manipulator.TS
---@field config manipulator.TS.module.Config
local M = U.get_static(TS, {})

function M.activate_enablers(opts)
	if opts.types then U.activate_enabler(opts.types, '[^@a-z0-9_.]') end
	if type(opts.langs) == 'table' then U.activate_enabler(opts.langs) end
	return opts
end

--- This gets called by main module after resolving config setup
---@private
function M._post_setup()
	-- NOTE: cannot activate enablers right away because they might not have the '*' set due to inheritance
	-- region actions on TSs will look for its defaults here -> copy the defaults
	U.tbl_inner_extend('keep', M.config, Region.config, 2, 'noref')
end

--- Get a config specific for the current filetype (ltree-/buffer-based)
--- Returned config may need expanding before standalone use.
---@param buf? integer
---@param ltree? vim.treesitter.LanguageTree
---@return manipulator.TS.Config?
local function get_lang_preset(buf, ltree)
	-- ltree_or_buffer? Y-> is there a preset for ltree? N-> return buffer
	local bp = M.config.use_lang_presets ---@type string|manipulator.TS.Config
	if bp then
		if bp ~= 'buf' and ltree then bp = M.config.presets[ltree:lang()] or bp end
		if type(bp) == 'string' and bp ~= 'ltree' then
			local ft = vim.bo[buf or 0].ft
			bp = M.config.presets[M.config.ft_to_lang[ft] or ft]
		end

		if type(bp) == 'table' then
			bp.presets = M.config.presets
			if bp.inherit == nil then bp.inherit = 'active' end -- set the correct base preset
			return bp
		end
	end
end

---@override
---@generic O: manipulator.TS.Opts
---@param opts? O|string user options to get expanded - updated **inplace**
---@param action? string
---@return O # opts expanded for the given method
function TS:action_opts(opts, action)
	local save_as = opts and opts.save_as
	if save_as then
		---@diagnostic disable-next-line: assign-type-mismatch
		M.config.presets[save_as] = action and U.tbl_partcopy(opts, { 'types', 'langs', 'query', action }) or opts
	end

	opts = M.activate_enablers(U.expand_action(self.config or get_lang_preset(
		---@diagnostic disable-next-line: undefined-field
		opts and opts.buf or self.buf,
		self.ltree
	) or M.config, opts, action, self.action_map))

	-- ensure it doesn't get inherited, but stays in the user opts for reuse
	if not save_as then opts.save_as = nil end

	if action and M.config.debug then
		local presets = opts.presets
		opts.presets = nil
		if package.loaded['reform'] then
			print({ [action or 'config'] = opts }, 3, M.config.debug)
		else
			vim.notify(vim.inspect { [action or 'config'] = opts }, M.config.debug)
		end
		opts.presets = presets
	end

	return opts
end

local function range_fix(node, buf)
	local r = { node:range() }
	if r[4] == 0 then
		r[3] = r[3] - 1
		r[4] = #vim.api.nvim_buf_get_lines(buf, r[3], r[3] + 1, true)[1] - 1
	else
		r[4] = r[4] - 1
	end
	return r
end

--- Create a new language-tree node wrapper.
---@type fun(self:manipulator.TS, node?: TSNode,
---ltree?:vim.treesitter.LanguageTree, opts:manipulator.TS.Opts): manipulator.TS
function TS:new(node, ltree, opts)
	-- method opts also apply to the result node
	-- always select the top node of valid type and the same range (not the top if top has bad type)
	node, ltree = TU.get_identical_ancestor(opts, node, ltree)
	if not node or not ltree then return opts.nil_wrap and self.Nil end

	return TS.super.new(self, {
		buf = ltree._source,
		range = range_fix(node, ltree._source),
		node = node,
		ltree = ltree,
		-- expand lang preset into new tbl to ensure base config updates will also update preset
		config = self.config or self:action_opts(),
	})
end

---@override
---@generic O: manipulator.TS.Opts
---@param config O|string
---@return self
function TS:with(config) return self:new(self.node, self.ltree, self:action_opts(config)) end

---@param opts manipulator.TS.Opts
---@return boolean
function TS:is_valid_in(opts)
	return opts.types[self.node:type()] and (type(opts.langs) ~= 'table' or opts.langs[self.ltree:lang()])
end

---@override
function TS:__tostring()
	return string.format('%s: %s', self.node and self.node:type() or 'invalid', TS.super.__tostring(self))
end

--- Get a parent node.
---@param opts? manipulator.TS.QueryOpts|string
---@return manipulator.TS? node from the given direction
---@return boolean? changed_lang true if {node} is from a different language tree
function TS:parent(opts)
	opts = self:action_opts(opts, 'parent')

	if opts.query then
		local node, ltree = TQ.get_ancestor({ self.node:range() }, self.ltree, opts, true, false)
		return self:new(node, ltree, opts)
	end

	local node, ltree = TU.get_identical_ancestor(opts, self.node, self.ltree, true)
	return self:new(node, ltree, opts), ltree ~= self.ltree
end

--- Get a child node.
---@param idx? integer|Range4|'closer_edge' child index
--- - `<0` for reverse indexing, or a range it should contain
--- - `'closer_edge'` to choose from the end closer to the cursor (default)
---@param opts? manipulator.TS.QueryOpts|string
---@return manipulator.TS? node from the given direction
---@return boolean? changed_lang true if {node} is from a different language tree
function TS:child(idx, opts)
	if type(idx) == 'table' and not idx[1] then
		---@diagnostic disable-next-line: cast-local-type
		opts = idx
		idx = nil
	end

	opts = self:action_opts(opts, 'child')
	if not idx or idx == 'closer_edge' then
		idx = Range.to_byte '.' > (select(3, self.node:start()) + select(3, self.node:end_())) / 2 and -1 or 0
	end

	local node, ltree = TU.get_descendant(opts, self.node, self.ltree, idx)
	return self:new(node, ltree, opts), ltree ~= self.ltree
end

--- Get a node in said direction. only
---@param opts? manipulator.TS.Opts|string
---@return manipulator.TS? node from the given direction
function TS:next_sibling(opts)
	opts = self:action_opts(opts, 'next_sibling')

	local node = self.node:next_named_sibling()
	while node and not opts.types[node:type()] do
		node = node:next_named_sibling()
	end

	return self:new(node, self.ltree, opts)
end

--- Get a node in said direction. only
---@param opts? manipulator.TS.Opts|string
---@return manipulator.TS? node from the given direction
function TS:prev_sibling(opts)
	opts = self:action_opts(opts, 'prev_sibling')

	local node = self.node:prev_named_sibling()
	while node and not opts.types[node:type()] do
		node = node:prev_named_sibling()
	end

	return self:new(node, self.ltree, opts)
end

--- Get the next node in tree order (child, sibling, parent sibling)
---@param opts? manipulator.TS.GraphOpts|string
---@return manipulator.TS? node from the given direction
---@return boolean? changed_lang true if {node} is from a different language tree
function TS:next(opts)
	opts = self:action_opts(opts, 'next')

	local node, ltree = TU.search_in_graph('next', opts, self.node, self.ltree)
	return self:new(node, ltree, opts), ltree == self.ltree
end

--- Get the prev node in tree order (child, sibling, parent sibling)
---@param opts? manipulator.TS.GraphOpts|string
---@return manipulator.TS? node from the given direction
---@return boolean? changed_lang true if {node} is from a different language tree
function TS:prev(opts)
	opts = self:action_opts(opts, 'prev')

	local node, ltree = TU.search_in_graph('prev', opts, self.node, self.ltree)
	return self:new(node, ltree, opts), ltree == self.ltree
end

do -- ### Wrapper for nil TSNode matches
	local nil_fn = function(self) return self end
	local nr_index = Region.class.Nil.__index
	---@class manipulator.TS.Nil: manipulator.TS, manipulator.Region.Nil
	---@protected
	TS.Nil = Region.class.Nil

	local passthrough = { opt_inheritance = true, action_opts = true }
	function TS.Nil:__index(key)
		if rawget(TS, key) then
			if passthrough[key] or type(rawget(TS, key)) ~= 'function' then return TS[key] end
			return nil_fn
		end
		return nr_index(self, key)
	end

	---@diagnostic disable-next-line: inject-field
	function TS.Nil:is_valid_in() return false end
end

--- Get all matching nodes spanning the entire buffer.
---@param opts manipulator.TS.QueryOpts
---@param from_range? anyrange where should the nodes come from (whole buffer by default)
---@return manipulator.Batch
function M.get_all(opts, from_range)
	opts = M:action_opts(opts, 'get_all')

	local r = from_range and Range.get_or_make(from_range)
	if r then r[4] = r[4] + 1 end
	local ltree = vim.treesitter.get_parser(r and r.buf or 0)
	if not ltree then return Batch:new({}, TS.Nil, TS.Nil) end

	local types = opts.types
	assert(types, 'TS.config.types must be always set')
	local nodes = {} ---@type manipulator.TS[]
	ltree:for_each_tree(function(tree, lt)
		if lt ~= ltree or not opts.langs or not opts.langs[ltree:lang()] then return end
		local node = tree:root()
		while node do
			local tmp = node:named_child(0)
			if not tmp then
				while node and not tmp do
					tmp = node:next_named_sibling()
					if not tmp then node = node:parent() end
				end
			end
			node = tmp

			if node and types[node:type()] then
				local ts = TS:new(node, ltree, opts)
				-- ensure different ranges from the previous node (in parent->child relations)
				if ts and ts.node and (#nodes == 0 or ts.node ~= nodes[#nodes].node) and (not r or r:contains(ts)) then
					nodes[#nodes + 1] = ts
				end
			end
		end
	end)

	return Batch:new(nodes, opts.nil_wrap and TS.Nil)
end

--- Get a node covering given range.
---@param range anypos range that the result node must include
---@param opts manipulator.TS.QueryOpts
---@return manipulator.TS?
function M.get(range, opts)
	opts = M:action_opts(opts, 'get')
	local r = Range.get_or_make(range)

	local ltree = vim.treesitter.get_parser(r.buf)
	if not ltree then return TS:new(nil, nil, opts) end

	r[4] = r[4] + 1 -- NOTE: TSNode:range() is end exclusive
	local ret
	if opts.query then
		local nodes, ltree = TQ.get_ancestor(r, ltree, opts, true, true)
		ret = TS:new(nodes, ltree, opts)
	else
		if opts.langs then ltree = ltree:language_for_range(r) end
		ret = TS:new(ltree:named_node_for_range(r), ltree, opts)
	end

	r[4] = r[4] - 1
	return ret
end

---@class manipulator.TS.module.current.Opts: manipulator.TS.QueryOpts,manipulator.Region.module.current.Opts
--- When node is larger than visual selection, what node should we return (default: '.')
---@field on_partial? 'larger'|pos_expr|false

---@param opts? manipulator.TS.module.current.Opts persistent by default
---@return manipulator.TS?
function M.current(opts)
	opts = M:action_opts(opts, 'current')

	local reg, visual = Region.current(opts)
	local ts = M.get(reg, opts) -- get the primary chosen node

	-- if selection is smaller than the chosen node decide what to do
	if (ts and ts.node and visual and opts.on_partial ~= 'larger') and ts.range ~= reg.range then
		if opts.on_partial == false then return TS:new(nil, nil, opts) end

		ts = M.get(
			Region.current(U.tbl_inner_extend('keep', {
				src = opts.on_partial or '.',
				fallback = false,
			}, opts)),
			opts
		)
	end
	return ts
end

return M
