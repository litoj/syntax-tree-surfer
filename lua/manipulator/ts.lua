---@diagnostic disable: invisible

local Region = require 'manipulator.region'
local U = require 'manipulator.utils'
local RANGE_U = require 'manipulator.range_utils'
local TS_U = require 'manipulator.ts_utils'
local NVIM_TS_U = require 'nvim-treesitter.ts_utils'
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
---@field parent? manipulator.TS.Opts
---@field child? manipulator.TS.Opts
---@field sibling? manipulator.TS.Opts
---@field next_sibling? manipulator.TS.Opts
---@field prev_sibling? manipulator.TS.Opts
---@field in_graph? manipulator.TS.GraphOpts
---@field next? manipulator.TS.GraphOpts
---@field prev? manipulator.TS.GraphOpts
---@field presets? {[string]:manipulator.TS.Config}

TS.opt_inheritance = U.tbl_inner_extend('keep', Region.opt_inheritance, {
	types = false,
	langs = false,

	parent = true,
	child = true,
	sibling = true,
	next_sibling = 'sibling',
	prev_sibling = 'sibling',
	in_graph = 'sibling',
	next = 'in_graph',
	prev = 'in_graph',
})

---@class manipulator.TS.module: manipulator.TS
---@field class manipulator.TS
local M = U.static_wrap_for_oop(TS, {})

function M.activate_enablers(opts)
	if opts.types then U.activate_enabler(opts.types, '[^a-z_]') end
	if type(opts.langs) == 'table' then U.activate_enabler(opts.langs) end
	return opts
end

---@class manipulator.TS.module.Config: manipulator.TS.Config
--- Should the base config be derived from the filetype of the given source.
--- - `'ltree'`: use only `vim.treesitter.LanguageTree:lang()` to choose the filetype
---   - each injected language can be treated differently
---   - getting the node (`.current()`, `.get_all()`, `.get()`) will be done with default config
--- - `'ltree_or_buf`: best of both worlds - prefer ltree, use buf when ltree is not known yet
---@field ft_preset_source? false|'buf'|'ltree'|'ltree_or_buf'
---@field get? manipulator.TS.module.get.Opts
---@field get_all? manipulator.TS.module.get.Opts
---@field current? manipulator.TS.module.current.Opts

---@type manipulator.TS.module.Config
M.default_config = {
	langs = { ['*'] = true, 'luap', 'printf', 'regex' },
	types = {
		['*'] = true,
		-- common pg node types directly in the defaults
		'string_content',
		'comment_content',

		-- Lua
		'block',
		-- 'dot_index_expression', -- = field paths
		'method_index_expression',
		'arguments',
		'parameters',
	},

	sibling = { types = { inherit = true, comment = false } },
	next = { allow_child = true, start_point = 'cursor' },
	prev = {},

	current = { linewise = false, on_partial = 'larger' },

	nil_wrap = true,
	inherit = false,
	ft_preset_source = 'ltree_or_buf',

	presets = {
		-- ### General use presets
		path = { -- configured for selecting individual fields in a path to an attribute (A.b.c.d=2)
			in_graph = { max_link_dst = 4, max_ascend = 3, max_descend = 1, langs = { inherit = true, luadoc = false } },
			next = { allow_child = false },
			prev = { compare_end = true },
		},

		with_docs = {
			select = { -- what can we apply the mod to
				rangemod = require('manipulator.range_mods').with_docs,
				langs = { inherit = true, '.*doc.*' },
				types = { '.*definition', '.*declaration', '.*comment.*', '.*asignment.*' },
			},
			sibling = {
				langs = false,
				types = { '.*comment.*' },
			},
			-- field is required for with_docs rangemod to decide (caches the user opts)
			prev_sibling = { -- what preceeding nodes can join the selection (docs/comments)
			},
			next_sibling = { -- when selecting docs/comments, what can follow and join
			},
		},

		-- ### FileType presets
		-- **always inherit from 'ft_base'** (dynamic preset set to current node config or default)
		markdown = {
			inherit = 'ft_base',
			types = {
				inherit = 'ft_base',
				'list_marker_minus',
				'inline',
				'block_continuation',
				'delimiter$',
				'marker$',
			},
		},
		tex = {
			inherit = 'ft_base',
			types = {
				inherit = 'ft_base',
				'word',
				'text',
			},
		},

		lua = {
			inherit = 'ft_base',
			types = {
				inherit = 'ft_base',
				'documentation',
				'diagnostic_annotation',
				'chunk',
				'variable_list',
				'expression_list',
			},
		},
	},
}

---@type manipulator.TS.module.Config
M.config = M.default_config
M.config.presets.active = M.config

---@param config manipulator.TS.module.Config
function M.setup(config)
	M.config = U.module_setup(M.config.presets, M.default_config, config, TS.opt_inheritance)
	-- NOTE: cannot activate enablers right away because they might not have the '*' set due to inheritance
	-- region actions on TSs will look for its defaults here -> copy the defaults
	U.tbl_inner_extend('keep', M.config, Region.config, 2)
	return M
end

-- returned config may need expanding before standalone use
---@param buf? integer
---@param ltree? vim.treesitter.LanguageTree
local function get_ft_config(buf, ltree)
	-- could it be from buffer? Y-> are we missing ltree or is it just from buffer? Y-> return buffer
	local bp = M.config.ft_preset_source
		and M.config.presets[M.config.ft_preset_source ~= 'ltree' and ((not ltree or M.config.ft_preset_source == 'buf') and vim.bo[buf or 0].ft) or (ltree and ltree:lang())]
	if bp then bp.presets = M.config.presets end
	return bp
end

M.debug = false ---@type false|vim.log.levels

---@override
---@generic O: manipulator.TS.Opts
---@param opts? O|string user options to get expanded - updated **inplace**
---@param action? string
---@return O # opts expanded for the given method
function TS:action_opts(opts, action)
	local save_as = opts and opts.save_as
	if save_as then
		---@diagnostic disable-next-line: assign-type-mismatch
		M.config.presets[save_as] = opts
	end

	M.config.presets.ft_base = self.config or M.config
	opts = M.activate_enablers(U.get_opts_for_action(
		---@diagnostic disable-next-line: undefined-field
		get_ft_config(opts and opts.buf or self.buf, self.ltree) or M.config.presets.ft_base,
		opts,
		action,
		self.opt_inheritance
	))

	-- ensure it doesn't get inherited, but stays in the user opts in case he reuses them
	if not save_as then opts.save_as = nil end

	if M.debug then
		local presets = opts.presets
		opts.presets = nil
		vim.notify(vim.inspect { action = action, opts = opts }, M.debug)
		opts.presets = presets
	end

	return opts
end

--- Create a new language-tree node wrapper.
---@type fun(self:manipulator.TS, node?: TSNode,
---ltree?:vim.treesitter.LanguageTree, opts:manipulator.TS.Opts): manipulator.TS
function TS:new(node, ltree, opts)
	-- method opts also apply to the result node
	-- always select the top node of valid type and the same range (not the top if top has bad type)
	node, ltree = TS_U.top_identity(opts, node, ltree)
	if not node or not ltree then return opts.nil_wrap and self.Nil end

	return TS.super.new(self, {
		buf = ltree._source,
		node = node,
		ltree = ltree,
		config = self.config or M.config,
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

function TS:range1() return { NVIM_TS_U.get_vim_range({ self.node:range() }, self.buf) } end

function TS:start() return { self.node:start() } end

---@override
function TS:__tostring()
	return string.format('%s: %s', self.node and self.node:type() or 'invalid', TS.super.__tostring(self))
end

--- Get a parent node.
---@param opts? manipulator.TS.Opts|string
---@return manipulator.TS? node from the given direction
---@return boolean? changed_lang true if {node} is from a different language tree
function TS:parent(opts)
	opts = self:action_opts(opts, 'parent')

	local node, ltree = TS_U.top_identity(opts, self.node, self.ltree, true)
	return self:new(node, ltree, opts), ltree ~= self.ltree
end

--- Get a child node.
---@param opts? manipulator.TS.Opts|string
---@param idx? integer|Range4|'closer_edge' child index
--- - `<0` for reverse indexing, or a range it should contain
--- - `'closer_edge'` to choose from the end closer to the cursor (default)
---@return manipulator.TS? node from the given direction
---@return boolean? changed_lang true if {node} is from a different language tree
function TS:child(opts, idx)
	opts = self:action_opts(opts, 'child')
	if not idx or idx == 'closer_edge' then
		idx = RANGE_U.point_to_byte '.' > (select(3, self.node:start()) + select(3, self.node:end_())) / 2 and -1 or 0
	end

	local node, ltree = TS_U.get_child(opts, self.node, self.ltree, idx)
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
	local node, ltree = TS_U.search_in_graph('next', opts, self.node, self.ltree)
	return self:new(node, ltree, opts), ltree == self.ltree
end

--- Get the prev node in tree order (child, sibling, parent sibling)
---@param opts? manipulator.TS.GraphOpts|string
---@return manipulator.TS? node from the given direction
---@return boolean? changed_lang true if {node} is from a different language tree
function TS:prev(opts)
	opts = self:action_opts(opts, 'prev')
	local node, ltree = TS_U.search_in_graph('prev', opts, self.node, self.ltree)
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

---@class manipulator.TS.module.get.Opts: manipulator.TS.Opts irl inherits the whole config
---@field buf? integer Buffer number (default: 0)
---@field range Range4 0-indexed range: {start_row, start_col, end_row, end_col}
---@field persistent? boolean should opts be saved as the default for the node (default: false)

--- Get all matching nodes spanning the entire buffer.
---@param opts manipulator.TS.module.get.Opts|{range?:nil} GetOpts, but range is ignored
---@return manipulator.Batch
function M.get_all(opts)
	opts = M:action_opts(opts, 'get_all')

	local ltree = vim.treesitter.get_parser(opts.buf or 0)
	opts.buf = nil
	if not ltree then return Batch:new({}, TS.Nil, TS.Nil) end

	local types = opts.types
	assert(types)
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
				if ts and ts.node and #nodes == 0 or ts.node ~= nodes[#nodes].node then
					nodes[#nodes + 1] = opts.persistent and ts:with(opts) or ts
				end
			end
		end
	end)

	return Batch:new(nodes, opts.nil_wrap and TS.Nil)
end

--- Get a node covering given range.
---@param opts manipulator.TS.module.get.Opts
---@return manipulator.TS?
function M.get(opts)
	opts = M:action_opts(opts, 'get')

	local ltree = vim.treesitter.get_parser(opts.buf or 0)
	if not ltree then return TS:new(nil, nil, opts) end

	opts.range[4] = opts.range[4] + 1
	if opts.langs then ltree = ltree:language_for_range(opts.range) end

	local ret = TS:new(ltree:named_node_for_range(opts.range), ltree, opts)
	opts.range[4] = opts.range[4] - 1
	return ret and opts.persistent and ret:with(opts) or ret
end

---@class manipulator.TS.module.current.Opts: manipulator.TS.module.get.Opts,manipulator.Region.module.current.Opts
--- When node is larger than visual selection, what node should we return (default: '.')
---@field on_partial? 'larger'|pos_expr|false
---@field range? Range4 this is for get() call, prefer using `fallback` for a specific range

---@param opts? manipulator.TS.module.current.Opts persistent by default
---@return manipulator.TS?
function M.current(opts)
	opts = M:action_opts(opts, 'current')

	local r, visual = Region.current(opts)
	opts.range = r:range0()
	local ts = M.get(opts) -- get the primary chosen node

	-- if selection is smaller than the chosen node decide what to do
	if
		(ts and ts.node and visual and opts.on_partial ~= 'larger')
		and RANGE_U.rangeContains(ts:range0(), opts.range) > 0
	then
		if opts.on_partial == false then return TS:new(nil, nil, opts) end

		local bufrange =
			Region.current(U.tbl_inner_extend('keep', { src = opts.on_partial or '.', fallback = false }, opts))
		opts.range = bufrange.range
		opts.buf = bufrange.buf
		ts = M.get(opts)
	end

	opts.buf = nil
	opts.range = nil

	return ts
end

return M
