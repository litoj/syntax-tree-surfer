---@diagnostic disable: redefined-local

local U = require 'manipulator.utils'
local RM = require 'manipulator.range_mods'

---@class manipulator
---@field batch manipulator.Batch.module
---@field call_path manipulator.CallPath.module
---@field region manipulator.Region.module
---@field ts manipulator.TS.module
local M = {}

--- Configs for all submodules, that can have the following sections:
--- 1. class options - default opts inherited by everyone in the module
--- 2. action defaults - default options for individual class methods
--- 3. module config - options specific for overall module behaviour
--- 4. module function defaults - default options for top-level static actions
--- 5. presets - ready-to-use+template class configs (opts+actions)
---@class manipulator.Config
---@field batch? manipulator.Batch.module.Config
---@field region? manipulator.Region.module.Config
---@field ts? manipulator.TS.module.Config
---@field call_path? manipulator.CallPath.Config

---@type manipulator.Config
M.default_config = {
	batch = {
		inherit = false,
		on_nil_item = 'drop_all',

		pick = {
			format_item = tostring,
			picker = 'native',
			prompt = 'Choose item',
			prompt_postfix = ': ',
			multi = false,
			fzf_resolve_timeout = 100,
			callback = false,
		},

		recursive_limit = 500,
	},

	call_path = {
		inherit = false,
		immutable = true,
		immutable_args = false,
		exec_on_call = false,

		exec = {
			allow_direct_calls = false,
			allow_field_access = false,
			skip_anchors = true,
		},
		as_op = { except = false, return_expr = false },
		on_short_motion = 'last-or-self',
	},

	region = {
		inherit = false,

		jump = { rangemod = { RM.trimmed } },
		select = { linewise = 'auto' },
		swap = { visual = true, cursor_with = 'current' },

		current = { fallback = '.', end_shift_ptn = '^$' },
	},

	ts = {
		inherit = false,
		langs = { ['*'] = true, 'luap', 'printf', 'regex' },
		types = {
			['*'] = true,
			-- most common node types directly in the defaults
			'string_content',
			'comment_content',

			-- C/C++
			'compound_statement',
			-- Lua
			'block',
			-- 'dot_index_expression', -- = field paths
			'method_index_expression',
			'arguments',
			'parameters',
		},
		nil_wrap = true, -- TODO: move this option to Region

		sibling = { types = { inherit = true, comment = false } },
		next = { allow_child = true, start_point = '.' },
		prev = {},

		use_lang_presets = 'ltree_or_buf',
		ft_to_lang = {
			tex = 'latex',
			sh = 'bash',
			cs = 'c_sharp',
		},

		current = { linewise = false, on_partial = 'larger' },

		presets = {
			-- ### General-use presets
			path = { -- configured for selecting individual fields in a path to an attribute (A.b.c.d=2)
				in_graph = {
					max_link_dst = 4,
					max_ascend = 3,
					max_descend = 1,
					langs = { inherit = true, luadoc = false },
				},
				next = { allow_child = false },
				prev = { compare_end = true },
			},

			with_docs = { -- select the node under cursor and all documentation associated with it
				nil_wrap = false,

				types = { 'definition$', 'declaration$', '.*comment.*', '.*asignment.*' },
				select = { -- what can we apply the mod to
					rangemod = { inherit = true, RM.with_docs },
					langs = { inherit = true, matchers = { ['.*doc.*'] = false } },
				},
				-- which preceeding nodes can join the selection (docs/comments)
				prev_sibling = { langs = false, types = { '.*comment.*' } },
				next_sibling = { types = { inherit = 'self' } }, -- do not inherit default (=sibling.types)
			},

			-- ### Lang presets (used if .use_lang_presets)
			markdown = {
				types = {
					-- `true` always means _inherit from what parent table inherits (→'active' = base cfg)_
					inherit = true,
					'list_marker_minus',
					'inline',
					'block_continuation',
					'delimiter$',
					'marker$',
				},
			},
			latex = {
				types = {
					inherit = true,
					'word',
					'text',
				},
			},
			lua = {
				types = {
					inherit = true,
					'documentation',
					'_annotation$',
					'chunk',
					'variable_list',
					'expression_list',
				},
			},
		},
	},
}

M.setup_order = { 'batch', 'call_path', 'region', 'ts' }
for _, name in ipairs(M.setup_order) do
	local m = require('manipulator.' .. name)
	M[name] = m
	m.default_config = M.default_config[name]
	m.config = m.default_config
	-- create self-reference
	if not m.config.presets then m.config.presets = {} end
	m.config.presets.default = m.config
	m.config.presets.active = m.config
end

---@param config? manipulator.Config
---@return manipulator
function M.setup(config)
	config = config or {}

	for _, name in ipairs(M.setup_order) do
		local m = require('manipulator.' .. name)
		m.config = U.module_setup( --
			m.config.presets,
			m.config.presets.default,
			config[name],
			m.class.action_map or {}
		)
		if rawget(m, '_post_setup') then m._post_setup() end
	end

	return M
end

return M
