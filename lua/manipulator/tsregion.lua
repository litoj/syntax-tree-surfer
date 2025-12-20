---@diagnostic disable: invisible

local Region = require 'manipulator.region'
local UTILS = require 'manipulator.utils'
local RANGE_UTILS = require 'manipulator.range_utils'
local TS_UTILS = require 'manipulator.ts_utils'
local NVIM_TS_UTILS = require 'nvim-treesitter.ts_utils'
local Batch = require 'manipulator.batch'

---@class manipulator.TSRegion: manipulator.Region
---@field public node TSNode
---@field public ltree vim.treesitter.LanguageTree
---@field protected config manipulator.TSRegion.Config
local TSRegion = setmetatable({ super = Region.class }, Region.class) -- allowing for user extensions
TSRegion.__index = TSRegion

---@class manipulator.TSRegion.Opts: manipulator.Inheritable base set of options for configuring the behaviour of methods
---@field types? manipulator.Enabler|{inherit:boolean|string} which types of nodes to accept, which to ignore (if previous node of identical range not accepted) + if it should inherit previous/preset values
---@field langs? false|manipulator.Enabler|{inherit:boolean|string} which languages to accept (false to disable LanguageTree switching) (seeking further in the direction if not accepted (parent or child))
---@field nil_wrap? boolean if nodes should return a nil node wrapper instead of nil (for method chaining)

---@class manipulator.TSRegion.Config: manipulator.TSRegion.Opts, manipulator.Region.Config
---@field parent? manipulator.TSRegion.Opts
---@field child? manipulator.TSRegion.Opts
---@field sibling? manipulator.TSRegion.SiblingOpts
---@field next? manipulator.TSRegion.SiblingOpts
---@field prev? manipulator.TSRegion.SiblingOpts
---@field in_graph? manipulator.TSRegion.GraphOpts
---@field next_in_graph? manipulator.TSRegion.GraphOpts
---@field prev_in_graph? manipulator.TSRegion.GraphOpts
---@field presets? {[string]:manipulator.TSRegion.Config}

TSRegion.opt_inheritance = UTILS.tbl_inner_extend('keep', Region.opt_inheritance, {
	types = false,
	langs = false,

	parent = true,
	child = true,
	sibling = true,
	next = 'sibling',
	prev = 'sibling',
	in_graph = true,
	next_in_graph = 'in_graph',
	prev_in_graph = 'in_graph',
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

		-- lua
		'documentation',
		'block',
		'chunk',
		'variable_list',
		'expression_list',
		-- 'dot_index_expression', -- = field paths
		'method_index_expression',
		'arguments',
		'parameters',
	},
	nil_wrap = true,
	inherit = false,

	sibling = { types = { inherit = true, comment = false } },
	next_in_graph = { start_point = 'cursor', allow_child = true },
	prev_in_graph = { start_point = 'cursor' },

	prefer_ft_preset = true,

	presets = {
		path = {
			sibling = { lvl_diff = 0, ancestor_diff = 2, fallback = true, types = { inherit = true } },
			next = { max_ancestor = 4, inherit = 'sibling' },
			prev = {
				max_ancestor = 5,
				prioritize = 'ancestor_diff',
				inherit = 'sibling',
			},
		},

		markdown = {
			inherit = 'active',
			types = {
				inherit = true,
				['*'] = true,
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
				['*'] = true,
				'word',
				'text',
			},
		},
	},
}

---@type manipulator.TSRegion.module.Config
M.config = UTILS.tbl_inner_extend('force', {}, M.default_config, true, 'noref')
M.config.presets.active = M.config
for _, v in pairs(M.config.presets) do
	activate_enablers(v)
end

local function get_ft_config(expanded, buf)
	local bp = M.config.presets[vim.bo[buf or 0].ft]
	-- base config is always fully expanded, because it doesn't inherit
	if not M.config.prefer_ft_preset or not bp then return M.config end
	return expanded and UTILS.expand_config(M.config.presets, M.config, bp, TSRegion.opt_inheritance) or bp
end

---@override
function TSRegion:expand_config(config)
	local orig = self.config or get_ft_config(false)
	return activate_enablers(UTILS.expand_config(orig.presets, orig, config, self.opt_inheritance))
end

---@override
function TSRegion:action_opts(opts, action)
	return activate_enablers(
		UTILS.get_opts_for_action(self.config or get_ft_config(true, self.buf), opts, action, self.opt_inheritance)
	)
end

---@param config manipulator.TSRegion.module.Config
function M.setup(config)
	M.config = UTILS.expand_config(M.config.presets, M.default_config, config, TSRegion.opt_inheritance)
	M.config.presets.active = M.config
	activate_enablers(M.config) -- minimize repeated work of converting types list to a map
	-- region actions on TSRegions will look for its defaults here -> copy the defaults
	UTILS.tbl_inner_extend('keep', M.config, Region.config, 2)
	return M
end

--- Create a new language-tree node wrapper.
---@type fun(self:manipulator.TSRegion, opts:manipulator.TSRegion.Opts, node?:TSNode,
--- ltree?:vim.treesitter.LanguageTree): manipulator.TSRegion
function TSRegion:new(opts, node, ltree)
	-- method opts also apply to the resul node
	-- always select the top node of the same range and valid type
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

---@protected
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

---@class manipulator.TSRegion.SiblingOpts: manipulator.TSRegion.Opts not necessarily a sibling, rather a related member in a direction
---@field max_ancestor? integer how far up can the shared ancestor be from self - positive int (nil=infinite)
---@field max_skip? integer how many found children can we skip before giving up (nil=infinite)
---@field lvl_diff? integer height diff from the original
---@field ancestor_diff? integer max height diff from the shared ancestor (accepts node if equal)
---@field prioritize? 'lvl_diff'|'ancestor_diff' which match to prefer returning (returns the other as fallback) (defalt: 'lvl_diff')
---@field fallback? boolean failing to satisfy these settings should we return the last found sibling

--- Get a node in said direction.
---@private
---@param direction 'prev'|'next'
---@param opts? manipulator.TSRegion.SiblingOpts|string
---@return manipulator.TSRegion? node from the given direction, TODO: currently only within the current ltree
function TSRegion:sibling(direction, opts)
	opts = self:action_opts(opts, direction)

	opts.max_skip = (opts.max_skip or math.huge) + 1 -- +1 to first allow a visit
	if not opts.lvl_diff and not opts.ancestor_diff then -- set defaults if no return policy exists
		opts.lvl_diff = 0
		opts.max_ancestor = 1 -- allow only direct siblings
	end
	opts.max_ancestor = (opts.max_ancestor or math.huge) - 1

	local node = self.node
	local get_child = direction == 'next' and node.named_child
		or function(n) return n:named_child(n:named_child_count() - 1) end
	local get_in_dir = node[direction .. '_named_sibling']
	-- if opts.max_ancestor == 0 then return self:new(cfg, opts, get_in_dir(self.node)) end

	local fallback, secondary = nil, nil ---@type TSNode?
	local ancestor_lvl, lvl, visited = 1, 0, 0

	---@type fun(ret_node:TSNode):manipulator.TSRegion
	local ret = function(ret_node)
		if ret_node then
			if ret_node == node then
				while ret_node and not opts.types[ret_node:type()] do -- find a smaller acceptable node
					ret_node = get_child(ret_node)
				end
			end
			-- use fallback nodes if primary failed
			if not ret_node or ret_node == (secondary or (opts.fallback and fallback)) then
				ret_node = secondary
				while ret_node and not opts.types[ret_node:type()] do
					ret_node = get_child(ret_node)
				end
				if not ret_node then return self:new(opts, opts.fallback and fallback) end
			end

			local par
			while true do
				par = ret_node
				ret_node = get_child(ret_node)
				if ---@diagnostic disable-next-line: missing-fields
					not ret_node or RANGE_UTILS.rangeContains({ par:range() }, { ret_node:range() }) ~= 0
				then
					break
				end
			end
			ret_node = par
		end
		return self:new(opts, ret_node)
	end

	local tmp
	while visited < opts.max_skip do
		while not get_in_dir(node) do
			node = node:parent()
			lvl = lvl + 1
			if lvl > opts.max_ancestor or not node then -- reached distance limit from self
				return ret(secondary or (opts.fallback and fallback))
			end

			if lvl == ancestor_lvl then ancestor_lvl = lvl + 1 end -- shared is one above
		end

		node = get_in_dir(node)
		fallback = node
		visited = visited + 1

		while true do
			if opts.types[node:type()] then
				if opts.lvl_diff then -- XXX: fully successful find
					if lvl <= opts.lvl_diff and opts.prioritize ~= 'ancestor_diff' then return ret(node) end
					if
						opts.ancestor_diff
						and ancestor_lvl - lvl >= opts.ancestor_diff
						and opts.prioritize == 'ancestor_diff'
					then
						return ret(node)
					end

					if secondary == nil then secondary = node end
				elseif opts.ancestor_diff and ancestor_lvl - lvl >= opts.ancestor_diff then
					return ret(node)
				end
			end

			tmp = get_child(node)
			if not tmp then break end
			node = tmp
			lvl = lvl - 1
		end
	end

	return ret(secondary or (opts.fallback and fallback))
end

--- Get a node in said direction. only
---@param opts? manipulator.TSRegion.SiblingOpts|string
---@return manipulator.TSRegion? node from the given direction
function TSRegion:next(opts) return self:sibling('next', opts) end

--- Get a node in said direction. only
---@param opts? manipulator.TSRegion.SiblingOpts|string
---@return manipulator.TSRegion? node from the given direction
function TSRegion:prev(opts) return self:sibling('prev', opts) end

--- Get the next node in tree order (child, sibling, parent sibling)
---@param opts? manipulator.TSRegion.GraphOpts|string
---@return manipulator.TSRegion? node from the given direction
---@return boolean? changed_lang true if {node} is from a different language tree
function TSRegion:next_in_graph(opts)
	opts = self:action_opts(opts, 'next_in_graph')
	local node, ltree = TS_UTILS.next_in_graph(opts, self.node, self.ltree)
	return self:new(opts, node, ltree), ltree == self.ltree
end

--- Get the prev node in tree order (child, sibling, parent sibling)
---@param opts? manipulator.TSRegion.GraphOpts|string
---@return manipulator.TSRegion? node from the given direction
---@return boolean? changed_lang true if {node} is from a different language tree
function TSRegion:prev_in_graph(opts)
	opts = self:action_opts(opts, 'prev_in_graph')
	local node, ltree = TS_UTILS.prev_in_graph(opts, self.node, self.ltree)
	return self:new(opts, node, ltree), ltree == self.ltree
end

do -- ### Wrapper for nil TSNode matches
	local nil_fn = function(self) return self end
	local nr_index = Region.class.Nil.__index

	local pass_through = { Nil = true, action_opts = true }
	function Region.class.Nil:__index(key)
		if rawget(TSRegion, key) then
			if pass_through[key] then return TSRegion[key] end
			return nil_fn
		end
		return nr_index(self, key)
	end

	---@class manipulator.NilTSRegion: manipulator.TSRegion, manipulator.NilRegion
	---@protected
	TSRegion.Nil = Region.class.Nil
end

---@class manipulator.TSRegion.module.get.Opts: manipulator.TSRegion.Config
---@field buf? integer Buffer number (default: 0)
---@field range Range4 0-indexed range: {start_row, start_col, end_row, end_col}
---@field persistent? boolean should opts be saved as the default for the node (default: false)

--- Get a node covering given range. (end-column-exclusive -> use +1)
---@param opts manipulator.TSRegion.module.get.Opts
---@return manipulator.TSRegion?
function M.get(opts)
	opts = M:action_opts(opts, 'get')

	local ltree = vim.treesitter.get_parser(opts.buf or 0)
	opts.buf = nil
	if not ltree then return TSRegion:new(opts) end
	local range = opts.range
	opts.range = nil
	-- slow, but we have no other way to get the language info (and ltree) the node is in
	if opts.langs then ltree = ltree:language_for_range(range) end

	local ret = TSRegion:new(opts, ltree:named_node_for_range(range), ltree)
	return ret and opts.persistent and ret:with(opts, true) or ret
end

--- Get all matching nodes spanning the entire buffer.
---@param opts manipulator.TSRegion.module.get.Opts|{range?:nil}
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

---@class manipulator.TSRegion.module.current.Opts: manipulator.TSRegion.module.get.Opts,manipulator.Region.module.current.Opts
---@field v_partial? integer >0 allows node larger than visual selection, 0 falls back to cursor, <0 nil (default: 1)
---@field range? nil

---@param opts? manipulator.TSRegion.module.current.Opts persistent by default
---   - `respect_linewise`: compared to `Region.current()` here defaults to `false`
---@return manipulator.TSRegion?
function M.current(opts)
	opts = M:action_opts(opts, 'current')

	if opts.respect_linewise == nil then opts.respect_linewise = false end
	local region, visual = Region.current(opts)
	opts.mouse = nil
	opts.visual = nil
	opts.range = region:range0()

	local ret = M.get(opts) -- get the primary chosen node
	if not ret or not ret.node then return ret end

	local v_partial = opts.v_partial or 1
	-- if selection is smaller than the chosen node decide what to do
	if v_partial <= 0 and visual and RANGE_UTILS.rangeContains(ret:range0(), region:range0()) > 0 then
		if v_partial == 0 then -- fall back to node under cursor
			---@diagnostic disable-next-line: cast-local-type
			region = RANGE_UTILS.current_point(opts.mouse, opts.insert_fixer)
			opts.range = region.range
			opts.buf = region.buf
			ret = M.get(opts)
		else -- no fallback allowed -> return nil node
			ret = TSRegion:new(opts)
		end
	end

	return ret
end

return M
