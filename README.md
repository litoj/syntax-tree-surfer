# manipulator.nvim

## Features

- `Region`:
  - text ops: jump, select, move/paste, …, quickfix, mark, highlight
  - position sources: cursor, visual, mouse (move via `vim.g.mousemoveevent`), operator
- `TSRegion`: treesitter full traversal including injected languages
  - filtering by node type & lang
  - selection possible with dynamic modifiers -> select fn with docs etc.
  - matching structures using query syntax and catching into groups
    - this is meant for more complex, or language-agnostic matching, that would be very difficult to
      replicate with just single-node matching
    - example: select all docs and annotations of current C# method
      ```lua
      ts.current({ langs = false, query = [[(method_declaration (block) @body)]] })
      	:prev({
      		query = [[((comment)+ . (method_declaration (attribute_list)* @docs)) @docs]],
      		types = { '@docs' },
      	}):select()
      ```
    - to see which captures the query provides just create an exception by using an invalid capture
      - `ts.current{query='textobjects', types={''}}`
- `CallPath`: flexible & reusable keymapping function builder
- vim motion support (`5j`…) (via `CallPath:repeatable`)
- dot repeat + operator mode (via `CallPath:as_op`)
- `Batch`: collecting and selecting (native or `fzf`) found matches
- extensive behaviour configuration with clever preset inheriting
  - In setup, all configs inherit from their previous version by default. However, to inherit also
    the previous values of overriden fields, you must set `inherit=<preset name>` in those fields
    explicitly. The preset name of the base configs is `'active'`.
    - Example (for the `ts` section):
      ```lua
      types = { inherit = 'active', 'list$' }, -- '*' is `true` -> matched nodes will be excluded
      -- you can set a generic luapat and override it by setting the specific node to override
      -- because order is: 1. direct index, 2. luapat match, 3. default value
      types = { throw_statement = false, 'statement$'}
      presets = {
        -- Filetypes get mapped to TS lang names -> langpresets use the TS parser name
        latex = {
          types = { inherit = 'latex', text = true } -- override the default of text being skipped
        }
      }
      ```
  - In action options, you can change the action inheritance chain by inheriting from an action
    instead of a preset. Alternatively, you can `inherit='self'` to skip inheriting from configs of
    parent actions and inherit only from the current node's config.
    - Example (from the `ts` section):
      ```lua
      presets = {
        with_docs = {
          next_sibling = { types = { inherit = 'self' } }, -- skip inheriting sibling.types
        }
      }
      ```
    - To view the inheritance chain of an action, inpect the `action_map` of your module of
      interest.
  - During runtime (when passing opts to the actions) fields with `inherit=true` inherit their
    values from the same preset as the parent table (=the opts).
    - Example:
      ```lua
      opts = { inherit = 'p1', types = { inherit = true --[[will inherit p1.types]] } }
      ```
- extensive docs right in the code for all settings and methods

## TODOS

- update docs & license, separate repo from the original but include references
  - make features into ### headings
  - add example under each feature, provide settings, videos, inspire from sts
  - TOC up top
  - chapter about how to actually create mappings / module layout and meaning / design
- add info/gtdefinition for types in info windows - _belongs to reform.nvim_
- provide a way to get the query capture group of any given node (DEBUG)
- refactor swap to allow swapping parent and child (i.e. conditionals)

### Syntax Tree Surfer is a plugin for Neovim that helps you surf through your document and move elements around using the nvim-treesitter API.

![tree surfing cover](https://user-images.githubusercontent.com/102876811/163170119-89369c35-a061-4058-aaeb-1706ea6fa4cf.jpg)

## Table of Contents

1. [Version 1.0 Functionalities](#version-10-functionalities)
1. [How do I install?](#how-do-i-install)
1. [Version 1.1 Update](#version-11-update)
1. [Version 2.0 Beta Update](#version-20-beta-update)
1. [Version 2.2 Update](#version-22-update)

#### Use your favorite Plugin Manager with the link [ziontee113/syntax-tree-surfer](ziontee113/syntax-tree-surfer)

For Packer:

```lua
use "ziontee113/syntax-tree-surfer"
```

# How do I set things up?

### Here's my suggestion:

```lua
-- Syntax Tree Surfer
local opts = {noremap = true, silent = true}

-- Normal Mode Swapping:
-- Swap The Master Node relative to the cursor with it's siblings, Dot Repeatable
vim.keymap.set("n", "vU", function()
	vim.opt.opfunc = "v:lua.require'syntax-tree-surfer'.STSSwapUpNormal_Dot"
	return "g@l"
end, { silent = true, expr = true })
vim.keymap.set("n", "vD", function()
	vim.opt.opfunc = "v:lua.require'syntax-tree-surfer'.STSSwapDownNormal_Dot"
	return "g@l"
end, { silent = true, expr = true })

-- Swap Current Node at the Cursor with it's siblings, Dot Repeatable
vim.keymap.set("n", "vd", function()
	vim.opt.opfunc = "v:lua.require'syntax-tree-surfer'.STSSwapCurrentNodeNextNormal_Dot"
	return "g@l"
end, { silent = true, expr = true })
vim.keymap.set("n", "vu", function()
	vim.opt.opfunc = "v:lua.require'syntax-tree-surfer'.STSSwapCurrentNodePrevNormal_Dot"
	return "g@l"
end, { silent = true, expr = true })

--> If the mappings above don't work, use these instead (no dot repeatable)
-- vim.keymap.set("n", "vd", '<cmd>STSSwapCurrentNodeNextNormal<cr>', opts)
-- vim.keymap.set("n", "vu", '<cmd>STSSwapCurrentNodePrevNormal<cr>', opts)
-- vim.keymap.set("n", "vD", '<cmd>STSSwapDownNormal<cr>', opts)
-- vim.keymap.set("n", "vU", '<cmd>STSSwapUpNormal<cr>', opts)

-- Visual Selection from Normal Mode
vim.keymap.set("n", "vx", '<cmd>STSSelectMasterNode<cr>', opts)
vim.keymap.set("n", "vn", '<cmd>STSSelectCurrentNode<cr>', opts)

-- Select Nodes in Visual Mode
vim.keymap.set("x", "J", '<cmd>STSSelectNextSiblingNode<cr>', opts)
vim.keymap.set("x", "K", '<cmd>STSSelectPrevSiblingNode<cr>', opts)
vim.keymap.set("x", "H", '<cmd>STSSelectParentNode<cr>', opts)
vim.keymap.set("x", "L", '<cmd>STSSelectChildNode<cr>', opts)

-- Swapping Nodes in Visual Mode
vim.keymap.set("x", "<A-j>", '<cmd>STSSwapNextVisual<cr>', opts)
vim.keymap.set("x", "<A-k>", '<cmd>STSSwapPrevVisual<cr>', opts)
```

# Version 2.0 Beta Update

### Targeted Jump with Virtual Text

https://user-images.githubusercontent.com/102876811/169820839-5ec66bd9-bf14-49f6-8e5a-3078b8ec43c4.mp4

### Filtered Jump through user-defined node types

https://user-images.githubusercontent.com/102876811/169820922-b1eefa5e-6ed9-4ebd-95d1-f3f35e0388da.mp4

### These are experimental features and I wish to expand them even further. If you have any suggestions, please feel free to let me know 😊

Example mappings for Version 2.0 Beta functionalities:

```lua
-- Syntax Tree Surfer V2 Mappings
-- Targeted Jump with virtual_text
local sts = require("syntax-tree-surfer")
vim.keymap.set("n", "gv", function() -- only jump to variable_declarations
	sts.targeted_jump({ "variable_declaration" })
end, opts)
vim.keymap.set("n", "gfu", function() -- only jump to functions
	sts.targeted_jump({ "function", "arrrow_function", "function_definition" })
  --> In this example, the Lua language schema uses "function",
  --  when the Python language uses "function_definition"
  --  we include both, so this keymap will work on both languages
end, opts)
vim.keymap.set("n", "gif", function() -- only jump to if_statements
	sts.targeted_jump({ "if_statement" })
end, opts)
vim.keymap.set("n", "gfo", function() -- only jump to for_statements
	sts.targeted_jump({ "for_statement" })
end, opts)
vim.keymap.set("n", "gj", function() -- jump to all that you specify
	sts.targeted_jump({
		"function",
	  "if_statement",
		"else_clause",
		"else_statement",
		"elseif_statement",
		"for_statement",
		"while_statement",
		"switch_statement",
	})
end, opts)

-------------------------------
-- filtered_jump --
-- "default" means that you jump to the default_desired_types or your lastest jump types
vim.keymap.set("n", "<A-n>", function()
	sts.filtered_jump("default", true) --> true means jump forward
end, opts)
vim.keymap.set("n", "<A-p>", function()
	sts.filtered_jump("default", false) --> false means jump backwards
end, opts)

-- non-default jump --> custom desired_types
vim.keymap.set("n", "your_keymap", function()
	sts.filtered_jump({
		"if_statement",
		"else_clause",
		"else_statement",
	}, true) --> true means jump forward
end, opts)
vim.keymap.set("n", "your_keymap", function()
	sts.filtered_jump({
		"if_statement",
		"else_clause",
		"else_statement",
	}, false) --> false means jump backwards
end, opts)

-------------------------------
-- jump with limited targets --
-- jump to sibling nodes only
vim.keymap.set("n", "-", function()
	sts.filtered_jump({
		"if_statement",
		"else_clause",
		"else_statement",
	}, false, { destination = "siblings" })
end, opts)
vim.keymap.set("n", "=", function()
	sts.filtered_jump({ "if_statement", "else_clause", "else_statement" }, true, { destination = "siblings" })
end, opts)

-- jump to parent or child nodes only
vim.keymap.set("n", "_", function()
	sts.filtered_jump({
		"if_statement",
		"else_clause",
		"else_statement",
	}, false, { destination = "parent" })
end, opts)
vim.keymap.set("n", "+", function()
	sts.filtered_jump({
		"if_statement",
		"else_clause",
		"else_statement",
	}, true, { destination = "children" })
end, opts)

-- Setup Function example:
-- These are the default options:
require("syntax-tree-surfer").setup({
	highlight_group = "STS_highlight",
	disable_no_instance_found_report = false,
	default_desired_types = {
		"function",
		"arrow_function",
		"function_definition",
		"if_statement",
		"else_clause",
		"else_statement",
		"elseif_statement",
		"for_statement",
		"while_statement",
		"switch_statement",
	},
	left_hand_side = "fdsawervcxqtzb",
	right_hand_side = "jkl;oiu.,mpy/n",
	icon_dictionary = {
		["if_statement"] = "",
		["else_clause"] = "",
		["else_statement"] = "",
		["elseif_statement"] = "",
		["for_statement"] = "ﭜ",
		["while_statement"] = "ﯩ",
		["switch_statement"] = "ﳟ",
		["function"] = "",
		["function_definition"] = "",
		["variable_declaration"] = "",
	},
})
```

### Because every languages have different schemas and node-types, you can check the node-types that you're interested in with https://github.com/nvim-treesitter/playground

#### You can also do a quick check using the command :STSPrintNodesAtCursor

# Version 2.2 Update

### Hold and swap nodes

https://user-images.githubusercontent.com/8104435/225992362-4e82d677-2ff5-463a-a910-6a6bdbf4fc9c.mp4

This feature allows marking a node and then swapping it with another node.

Example mapping:

```lua
-- Holds a node, or swaps the held node
vim.keymap.set("n", "gnh", "<cmd>STSSwapOrHold<cr>", opts)
-- Same for visual
vim.keymap.set("x", "gnh", "<cmd>STSSwapOrHoldVisual<cr>", opts)
```

The lower-level functionality can be accessed via:

```lua
require("syntax-tree-surfer").hold_or_swap(true) -- param is_visual boolean
require("syntax-tree-surfer").clear_held_node()
```

note that `STSSwapOrHoldVisual` will clear the visual selection, but `hold_or_swap(true)` will not.

# Special Thanks To:

### Dr. David A. Kunz for creating [Let's create a Neovim plugin using Treesitter and Lua](https://www.youtube.com/watch?v=dPQfsASHNkg)

### NVIM Treesitter Team - https://github.com/nvim-treesitter/nvim-treesitter

### @lmburns for [#9](https://github.com/ziontee113/syntax-tree-surfer/pull/9)

### @spiderforrest for [#14](https://github.com/ziontee113/syntax-tree-surfer/pull/14)
