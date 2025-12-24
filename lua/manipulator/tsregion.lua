---@diagnostic disable: invisible

local Region = require 'manipulator.region'
local UTILS = require 'manipulator.utils'
local RANGE_UTILS = require 'manipulator.range_utils'
local TS_UTILS = require 'manipulator.ts_utils'
local NVIM_TS_UTILS = require 'nvim-treesitter.ts_utils'
local Batch = require 'manipulator.batch'

---@class manipulator.TSRegion: manipulator.Region
---@field node TSNode
---@field ltree vim.treesitter.LanguageTree
---@field protected config manipulator.TSRegion.Config
local TSRegion = setmetatable({ super = Region.class }, Region.class) -- allowing for user extensions
TSRegion.__index = TSRegion

---@class manipulator.TSRegion.Opts: manipulator.Inheritable base set of options for configuring the behaviour of methods
---@field types? manipulator.Enabler|{inherit:boolean|string} which types of nodes to accept, which to ignore (if previous node of identical range not accepted) + if it should inherit previous/preset values
---@field langs? false|manipulator.Enabler|{inherit:boolean|string} which languages to accept (false to disable LanguageTree switching) (seeking further in the direction if not accepted (parent or child))
---@field nil_wrap? boolean if nodes should return a nil node wrapper instead of nil (for method chaining)
---@field save_as? false|string a non-inheritable setting to save the expanded opts into a preset

---@class manipulator.TSRegion.Config: manipulator.TSRegion.Opts, manipulator.Region.Config
---@field parent? manipulator.TSRegion.Opts
---@field child? manipulator.TSRegion.Opts
---@field sibling? manipulator.TSRegion.Opts
---@field next_sibling? manipulator.TSRegion.Opts
---@field prev_sibling? manipulator.TSRegion.Opts
---@field in_graph? manipulator.TSRegion.GraphOpts
---@field next? manipulator.TSRegion.GraphOpts
---@field prev? manipulator.TSRegion.GraphOpts
---@field presets? {[string]:manipulator.TSRegion.Config}

TSRegion.opt_inheritance = UTILS.tbl_inner_extend('keep', Region.opt_inheritance, {
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

local function activate_enablers(opts)
	if opts.types then UTILS.activate_enabler(opts.types, '[^a-z_]') end
	if type(opts.langs) == 'table' then UTILS.activate_enabler(opts.langs) end
	return opts
end

---@class manipulator.TSRegion.module: manipulator.TSRegion
---@field class manipulator.TSRegion
local M = UTILS.static_wrap_for_oop(TSRegion, {})

---@class manipulator.TSRegion.module.Config: manipulator.TSRegion.Config
---@field prefer_ft_preset? boolean should the base preset for all nodes be based on filetype-named presets (extending the config) or just use the config alone
---@field get? manipulator.TSRegion.module.get.Opts
---@field get_all? manipulator.TSRegion.module.get.Opts
---@field current? manipulator.TSRegion.module.current.Opts

---@type manipulator.TSRegion.module.Config
M.default_config = {
	langs = { ['*'] = true, 'luap', 'printf', 'regex' },
	types = {
		['*'] = true,
		-- pg langs can be in markdown blocks -> common pg langs directly in the defaults
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

	current = { linewise = 'ignore', on_partial = 'larger' },

	nil_wrap = true,
	inherit = false,
	prefer_ft_preset = true,

	presets = {
		-- ### General use presets
		path = { -- configured for selecting individual fields in a path to an attribute (A.b.c.d=2)
			in_graph = { max_link_dst = 4, max_ascend = 3, max_descend = 1, langs = { inherit = true, luadoc = false } },
			next = { allow_child = false },
			prev = { compare_end = true },
		},

		-- ### FileType presets
		markdown = {
			inherit = 'active',
			types = {
				inherit = true,
				'list_marker_minus',
				'inline',
				'block_continuation',
				'delimiter$',
				'marker$',
			},
		},
		tex = {
			inherit = 'active',
			types = {
				inherit = true,
				'word',
				'text',
			},
		},

		lua = {
			inherit = 'active',
			types = {
				inherit = true,
				'documentation',
				'diagnostic_annotation',
				'chunk',
				'variable_list',
				'expression_list',
			},
		},
	},
}

---@type manipulator.TSRegion.module.Config
M.config = M.default_config
M.config.presets.active = M.config

---@param config manipulator.TSRegion.module.Config
function M.setup(config)
	M.config = UTILS.module_setup(M.config.presets, M.default_config, config, TSRegion.opt_inheritance)
	-- region actions on TSRegions will look for its defaults here -> copy the defaults
	UTILS.tbl_inner_extend('keep', M.config, Region.config, 2)
	return M
end

local function get_ft_config(expanded, buf)
	local bp = M.config.presets[vim.bo[buf or 0].ft]
	-- base config is always fully expanded, because it doesn't inherit
	if not bp or not M.config.prefer_ft_preset then return M.config end
	return expanded and UTILS.expand_config(M.config.presets, M.config, bp, TSRegion.opt_inheritance) or bp
end

M.debug = false ---@type false|vim.log.levels

---@override
function TSRegion:action_opts(opts, action)
	if type(opts) == 'table' and opts.save_as then
		M.config.presets[opts.save_as] = opts
		opts.save_as = nil
	end

	opts = activate_enablers(
		UTILS.get_opts_for_action(self.config or get_ft_config(true, self.buf), opts, action, self.opt_inheritance)
	)

	if M.debug then
		local presets = opts.presets
		opts.presets = nil
		vim.notify(vim.inspect { action = action, opts = opts }, M.debug)
		opts.presets = presets
	end

	return opts
end

--- Create a new language-tree node wrapper.
---@type fun(self:manipulator.TSRegion, opts:manipulator.TSRegion.Opts, node?:TSNode,
--- ltree?:vim.treesitter.LanguageTree): manipulator.TSRegion
function TSRegion:new(opts, node, ltree)
	-- method opts also apply to the result node
	-- always select the top node of valid type and the same range (not the top if top has bad type)
	node, ltree = TS_UTILS.top_identity(opts, node, ltree or self.ltree)
	if not node or not ltree then return opts.nil_wrap and self.Nil end

	return TSRegion.super.new(self, {
		buf = ltree._source,
		node = node,
		ltree = ltree,
		config = self.config or get_ft_config(true, ltree._source),
	})
end

function TSRegion:range1() return { NVIM_TS_UTILS.get_vim_range({ self.node:range() }, self.buf) } end

function TSRegion:start() return { self.node:start() } end

---@override
function TSRegion:__tostring()
	return string.format('%s: %s', self.node and self.node:type() or 'invalid', TSRegion.super.__tostring(self))
end

--- Get a parent node.
---@param opts? manipulator.TSRegion.Opts|string
---@return manipulator.TSRegion? node from the given direction
---@return boolean? changed_lang true if {node} is from a different language tree
function TSRegion:parent(opts)
	opts = self:action_opts(opts, 'parent')

	local node, ltree = TS_UTILS.top_identity(opts, self.node, self.ltree, true)
	return self:new(opts, node, ltree), ltree ~= self.ltree
end

--- Get a child node.
---@param idx? integer|Range4 child index, <0 for reverse indexing, or a range it should contain (default: 0)
---@param opts? manipulator.TSRegion.Opts|string
---@return manipulator.TSRegion? node from the given direction
---@return boolean? changed_lang true if {node} is from a different language tree
function TSRegion:child(idx, opts)
	opts = self:action_opts(opts, 'child')

	local node, ltree = TS_UTILS.get_child(opts, self.node, self.ltree, idx)
	return self:new(opts, node, ltree), ltree ~= self.ltree
end

---@param opts? manipulator.TSRegion.Opts|string
---@return manipulator.TSRegion? node from the given direction
---@return boolean? changed_lang true if {node} is from a different language tree
function TSRegion:closer_edge_child(opts)
	local pos = vim.api.nvim_win_get_cursor(0)
	local pos_byte = vim.fn.line2byte(pos[1]) - 1 + pos[2]
	local mid_byte = (select(3, self.node:start()) + select(3, self.node:end_())) / 2
	return self:child(pos_byte > mid_byte and -1 or 0, opts)
end

--- Find the closest child to active position
---@param opts? manipulator.TSRegion.Opts|string|{mouse:true} allow using mouse position instead of cursor (default: false)
---@return manipulator.TSRegion? node from the given direction
---@return boolean? changed_lang true if {node} is from a different language tree
function TSRegion:closest_child(opts)
	local node = self:child(RANGE_UTILS.current_point(opts and opts.mouse).range, opts)
	return node and node.node and node or self:closer_edge_child(opts)
end

--- Get a node in said direction. only
---@param opts? manipulator.TSRegion.Opts|string
---@return manipulator.TSRegion? node from the given direction
function TSRegion:next_sibling(opts)
	opts = self:action_opts(opts, 'next_sibling')

	local node = self.node:next_named_sibling()
	while node and not opts.types[node:type()] do
		node = node:next_named_sibling()
	end

	return self:new(opts, node)
end

--- Get a node in said direction. only
---@param opts? manipulator.TSRegion.Opts|string
---@return manipulator.TSRegion? node from the given direction
function TSRegion:prev_sibling(opts)
	opts = self:action_opts(opts, 'prev_sibling')

	local node = self.node:prev_named_sibling()
	while node and not opts.types[node:type()] do
		node = node:prev_named_sibling()
	end

	return self:new(opts, node)
end

--- Get the next node in tree order (child, sibling, parent sibling)
---@param opts? manipulator.TSRegion.GraphOpts|string
---@return manipulator.TSRegion? node from the given direction
---@return boolean? changed_lang true if {node} is from a different language tree
function TSRegion:next(opts)
	opts = self:action_opts(opts, 'next')
	local node, ltree = TS_UTILS.search_in_graph('next', opts, self.node, self.ltree)
	return self:new(opts, node, ltree), ltree == self.ltree
end

--- Get the prev node in tree order (child, sibling, parent sibling)
---@param opts? manipulator.TSRegion.GraphOpts|string
---@return manipulator.TSRegion? node from the given direction
---@return boolean? changed_lang true if {node} is from a different language tree
function TSRegion:prev(opts)
	opts = self:action_opts(opts, 'prev')
	local node, ltree = TS_UTILS.search_in_graph('prev', opts, self.node, self.ltree)
	return self:new(opts, node, ltree), ltree == self.ltree
end

do -- ### Wrapper for nil TSNode matches
	local nil_fn = function(self) return self end
	local nr_index = Region.class.Nil.__index

	local pass_through = { Nil = true, opt_inheritance = true, action_opts = true }
	function Region.class.Nil:__index(key)
		if rawget(TSRegion, key) then
			if pass_through[key] then return TSRegion[key] end
			return nil_fn
		end
		return nr_index(self, key)
	end

	---@class manipulator.TSRegion.Nil: manipulator.TSRegion, manipulator.Region.Nil
	---@protected
	TSRegion.Nil = Region.class.Nil
end

---@class manipulator.TSRegion.module.get.Opts: manipulator.TSRegion.Config
---@field buf? integer Buffer number (default: 0)
---@field range Range4 0-indexed range: {start_row, start_col, end_row, end_col}
---@field persistent? boolean should opts be saved as the default for the node (default: false)

--- Get all matching nodes spanning the entire buffer.
---@param opts manipulator.TSRegion.module.get.Opts|{range?:nil} GetOpts, but range is ignored
---@return manipulator.Batch
function M.get_all(opts)
	opts = M:action_opts(opts, 'get_all')

	local ltree = vim.treesitter.get_parser(opts.buf or 0)
	opts.buf = nil
	if not ltree then return Batch:new({}, TSRegion.Nil, TSRegion.Nil) end

	local types = opts.types
	local nodes = {} ---@type manipulator.TSRegion[]
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
				local tsregion = TSRegion:new(opts, node, ltree)
				-- ensure different ranges from the previous node (in parent->child relations)
				if tsregion and tsregion.node and #nodes == 0 or tsregion.node ~= nodes[#nodes].node then
					nodes[#nodes + 1] = opts.persistent and tsregion:with(opts, true) or tsregion
				end
			end
		end
	end)

	return Batch:new(nil, nodes, opts.nil_wrap and TSRegion.Nil)
end

--- Get a node covering given range.
---@param opts manipulator.TSRegion.module.get.Opts
---@return manipulator.TSRegion?
function M.get(opts)
	opts = M:action_opts(opts, 'get')

	local ltree = vim.treesitter.get_parser(opts.buf or 0)
	opts.buf = nil
	if not ltree then return TSRegion:new(opts) end
	local range = opts.range
	range[4] = range[4] + 1
	opts.range = nil
	-- slow, but we have no other way to get the language info (and ltree) the node is in
	if opts.langs then ltree = ltree:language_for_range(range) end

	local ret = TSRegion:new(opts, ltree:named_node_for_range(range), ltree)
	return ret and opts.persistent and ret:with(opts, true) or ret
end

---@class manipulator.TSRegion.module.current.Opts: manipulator.TSRegion.module.get.Opts,manipulator.Region.module.current.Opts
---@field on_partial? 'larger'|'cursor'|'nil' when visual selection doesn't cover the node fully, what node should we return (default: 'larger')
---@field range? nil ignored

---@param opts? manipulator.TSRegion.module.current.Opts persistent by default
---@return manipulator.TSRegion?
function M.current(opts)
	opts = M:action_opts(opts, 'current')

	local region, visual = Region.current(opts)
	opts.range = region:range0()

	local ret = M.get(opts) -- get the primary chosen node
	if not ret or not ret.node then return ret end

	-- if selection is smaller than the chosen node decide what to do
	if visual and opts.on_partial ~= 'larger' and RANGE_UTILS.rangeContains(ret:range0(), region:range0()) > 0 then
		if opts.on_partial == 'cursor' then -- fall back to node under cursor
			---@diagnostic disable-next-line: cast-local-type
			region = RANGE_UTILS.current_point(false, opts.insert_fixer)
			opts.range = region.range
			opts.buf = region.buf
			ret = M.get(opts)
			opts.buf = nil
		else -- partial == 'nil' - no fallback allowed
			ret = TSRegion:new(opts)
		end
	end

	return ret
end

return M
