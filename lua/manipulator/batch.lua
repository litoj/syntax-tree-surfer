---@diagnostic disable: invisible
local U = require 'manipulator.utils'

---@class manipulator.Batch
---@field items manipulator.Region[]
---@field private Nil manipulator.Region|false what to return, if no items are valid/chosen
---@field private config manipulator.Batch.Config
local Batch = {}
Batch.__index = Batch

---@class manipulator.Batch.Opts: manipulator.Inheritable
---@field on_nil_item? 'drop'|'drop_all'|'include' what to do when an item is `nil` (remove it/all?)

---@class manipulator.Batch.Config: manipulator.Batch.Opts
---@field pick? manipulator.Batch.pick.Opts
---@field presets? { [string]: manipulator.Batch.Config }

Batch.opt_inheritance = { pick = 'super' }

---@class manipulator.Batch.module: manipulator.Batch
---@field class manipulator.Batch
local M = U.static_wrap_for_oop(Batch, {})

---@class manipulator.Batch.module.Config: manipulator.Batch.Config
---@field recursive_limit? integer how many iterations is from_recursive() allowed by default

---@type manipulator.Batch.module.Config
M.default_config = {
	on_nil_item = 'drop_all',
	inherit = false,

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
}

---@type manipulator.Batch.module.Config
M.config = M.default_config
---@param config manipulator.Batch.module.Config
function M.setup(config)
	M.config = U.module_setup({ active = M.config }, M.default_config, config, Batch.opt_inheritance)
	return M
end

---@private
---@param opts manipulator.Batch.Opts
function Batch:fix_items(opts)
	opts = opts or self.config
	if opts.on_nil_item == 'include' then return end
	local Nil = self.Nil
	if opts.on_nil_item == 'drop_all' then
		for _, item in ipairs(self.items) do
			if item == nil or item == self.Nil then
				self.items = {}
				return
			end
		end
	else
		local items = self.items
		local i = #items -- going in reverse order to make table.remove more efficient
		while i > 0 do
			if items[i] == nil or items[i] == Nil then table.remove(items, i) end
			i = i - 1
		end
	end
end

---@param items manipulator.Region[] contents
---@param Nil? manipulator.Region|false what to return, if no items are valid/chosen
---@param config? manipulator.Batch.Opts
---@return manipulator.Batch
function Batch:new(items, Nil, config)
	self = setmetatable({ items = items, Nil = U.get_or(Nil, self.Nil), config = self.config or M.config }, Batch)
	self:fix_items(config)
	return self
end

function Batch:__tostring() return '[' .. table.concat(self.items, ', ') .. ']' end

---@param config manipulator.Batch.Config|string
---@param inplace boolean should we replace current config or make new copy (default: false)
function Batch:with(config, inplace)
	---@diagnostic disable-next-line: inject-field
	config = U.expand_config(self.config.presets, self.config, config, Batch.opt_inheritance)

	local ret = inplace and self or self:new(self.items, self.Nil, config)
	ret.config = config
	return ret
end

---@param index integer for <0 returns values from the end
---@return unknown
function Batch:at(index) return self.items[index > 0 and index or #self.items + 1 + index] or self.Nil end
---@return integer
function Batch:length() return #self.items end

---@alias manipulator.Batch.Action (fun(item:manipulator.Region):manipulator.Region?)|manipulator.CallPath|string|string[]

---@param action manipulator.Batch.Action
---@return fun(item):unknown
function M.action_to_fn(action)
	return type(action) == 'function' and action
		or action.path and function(x) return action:exec { src = x } end -- manipulator.CallPath
		or (not action[1] and function(x) return x[action](x) end) -- string
		or function(x) -- string[]
			for _, a in ipairs(action) do
				x = x[a](x)
			end

			return x
		end
end

---@param action manipulator.Batch.Action
---@return manipulator.Batch self
function Batch:for_each(action)
	action = M.action_to_fn(action)
	for _, item in ipairs(self.items) do
		action(item)
	end

	return self
end
---Reduce a list to a single value.
---@generic T,U
---@param init U
---@param fn fun(acc:U,value:T):U
---@return U
function Batch:reduce(init, fn)
	for _, v in ipairs(self.items) do
		init = fn(init, v)
	end

	return init
end

--- Reverse items inplace
---@return manipulator.Batch self
function Batch:reverse()
	local max = #self.items + 1

	local items = {}
	for i, v in ipairs(self.items) do
		items[max - i] = v
	end

	return self:new(items)
end

---@param ... manipulator.Batch.Action item method sequences to apply
--- - each sequence applied to the original
--- - multi-return actions spliced
---@return manipulator.Batch
function Batch:map(...)
	local items = {}
	for _, action in ipairs { ... } do
		action = M.action_to_fn(action)
		for _, item in ipairs(self.items) do
			for _, res in ipairs { action(item) } do
				items[#items + 1] = res
			end
		end
	end

	return self:new(items, #items > 0 and items[1].Nil or self.Nil)
end

---@param filter fun(item):boolean say which nodes should be carried over
---@return manipulator.Batch
function Batch:filter(filter)
	local items = {}
	for _, item in ipairs(self.items) do
		if filter(item) then items[#items + 1] = item end
	end

	return self:new(items)
end

---@return IterMod
function Batch:to_iter() return vim.iter(self.items) end

--- Presumes the items are Region items that can be added to the quickfix window
---@param mode? 'a'|'w' `vim.fn.setqflist` action to perform - append or overwrite (default: 'w')
function Batch:to_qf(mode)
	local list = {}
	for _, item in ipairs(self.items) do
		list[#list + 1] = item:as_qf_item()
	end
	vim.fn.setqflist(list, mode or 'w')

	return self
end

---@class manipulator.Batch.pick.Opts
---@field callback? fun(result:manipulator.Region|manipulator.Batch?)|boolean what to do after the value has been picked, `true` to convert the return value callers to an execution plan, `false` to return value via currently active coroutine
---@field format_item? fun(item:any):string how to display the item (default: tostring(V))
---@field picker? 'native'|'fzf-lua' (default: 'native')
---@field prompt? string
---@field multi? boolean if multiple items can be selected (will return a new Batch instead of item)
---@field autoselect_single? boolean should we automatically return the first item if it is the ony one in the list
---@field fzf_resolve_timeout? integer how long (in ms) to wait for fzf to pass the result to the callback after the fzf window closes (default: 100)

-- TODO: add picker based on pressing a character in the buffer (like sts/autopairs/flash)

--- Pick from the items. Must be in a coroutine or use a callback.
---@param self manipulator.Batch
---@param opts? manipulator.Batch.pick.Opts can include all `fzf-lua.config.Base` opts
---@return manipulator.Region|manipulator.Batch?
function Batch:pick(opts)
	opts = U.expand_action(self.config, opts, 'pick', Batch.opt_inheritance)

	local co
	local callback = opts.callback
	local pick
	local function resolve(result) callback(opts.multi and self:new(result, self.Nil, opts) or result[1] or self.Nil) end
	if #self.items <= 1 and (opts.autoselect_single or #self.items == 0) then
		if type(callback) ~= 'function' then callback = function(x) pick = x end end
		resolve { self.Nil }
		return pick
	end

	if callback == true then
		pick = require('manipulator.call_path'):new(nil, { immutable = false, exec_on_call = false })
		callback = function(result)
			pick.item = result
			pick:exec { src = 'update' } -- run the planned execution
			pick.config.exec_on_call = 10 -- in case the full path hasn't been constructed yet (unlikely)
		end
	elseif not callback then
		co = coroutine.running()
		if not co then error 'Must be inside a coroutine when no callback is present' end
		callback = function(result)
			pick = result
			coroutine.resume(co)
		end
	end

	if opts.prompt:match '%w$' then opts.prompt = opts.prompt .. opts.prompt_postfix end

	if opts.picker == 'native' then
		vim.ui.select(self.items, opts, function(item) resolve { item } end)
	elseif opts.picker == 'fzf-lua' then
		---@cast opts manipulator.Batch.pick.Opts|fzf-lua.config.Base
		local core = require 'fzf-lua.core'

		opts.actions = opts.actions or {}
		opts.actions.default = function(res) -- parses entry back to item
			opts.actions.default = nil
			res = res or {}
			local mapped = { [#res] = false } ---@cast mapped {}
			for i, v in ipairs(res) do
				mapped[i] = self.items[tonumber(v:match '^([0-9]+):')]
			end
			resolve(mapped)
		end

		local Pos = require 'manipulator.pos'

		-- Build entries with location information for preview.
		-- Use make_entry.lcol directly so fzf-lua's builtin previewer can jump to file:line:col.
		local entries = { [#self.items] = '' }
		local make_entry = require 'fzf-lua.make_entry'
		local bufs = { [#self.items] = 1 } ---@cast bufs (integer|{})[]
		for i, item in ipairs(self.items) do
			local display = opts.format_item(item)
			local buf = item.buf or 0
			if not bufs[-buf] then bufs[-buf] = { bufnr = buf, path = vim.api.nvim_buf_get_name(buf) } end
			bufs[i] = buf
			local range = Pos.raw(item)
			if range and range[2] then
				display = make_entry.lcol({ ---@type string
					filename = tostring(buf), -- pretend to be a filename to save on search space
					lnum = range[1] + 1,
					col = range[2] + 1,
					text = display,
				}, opts)
			end
			display = string.format('%d:%s', i, display)
			entries[i] = display
		end

		local previewer = require('fzf-lua.previewer.builtin').buffer_or_file:extend()
		function previewer:new(o, opts, fzf_win)
			previewer.super.new(self, o, opts, fzf_win)
			return setmetatable(self, previewer)
		end
		function previewer:parse_entry(str)
			local info = {}
			for m in str:gmatch '([0-9]+):' do
				info[#info + 1] = tonumber(m)
			end
			local buf = info[2]
			local entry = bufs[-buf]
			entry.line = info[3]
			entry.col = info[4]
			return entry
		end
		opts.previewer = previewer

		opts.fzf_opts = opts.fzf_opts or {}
		if opts.multi then opts.fzf_opts['--multi'] = true end
		opts.fzf_opts['--delimiter'] = ':' -- how to detect separate fields
		opts.fzf_opts['--nth'] = '5..' -- which fields to consider for matching

		opts.no_resume = true -- to fire the window closing events (would break the coroutine anyway)

		core.fzf_exec(entries, opts) -- async

		vim.api.nvim_create_autocmd('WinClosed', {
			callback = function(s)
				if vim.bo[s.buf].ft == 'fzf' then
					vim.defer_fn(function()
						if opts.actions.default then resolve() end
					end, opts.fzf_resolve_timeout)
					return true
				end
			end,
		})
	else
		vim.notify('Invalid picker ' .. opts.picker, vim.log.levels.WARN)
	end

	if co then coroutine.yield() end
	return pick
end

---@param src manipulator.Region|{Nil:table|false}
---@param ... manipulator.Batch.Action item method sequences to apply and collect the result of
---@return manipulator.Batch
function M.from(src, ...)
	if not src or src == src.Nil then return Batch:new({}, src and src.Nil or false) end
	local actions = { ... }
	if type(actions[1]) == 'table' and rawget(actions[1], 1) then actions = actions[1] end
	local acc = {}
	local Nil = src.Nil

	for _, action in ipairs(actions) do -- for each action
		action = M.action_to_fn(action)
		acc[#acc + 1] = action(src)
	end

	return Batch:new(acc, Nil)
end

---@param src manipulator.Region|{Nil:table|false}
---@param limit integer|'vimcount' max iterations total (-1= `M.config.recursive_limit`)
---@param ... manipulator.Batch.Action item method sequences to apply recursively and collect node of each iteration
---@return manipulator.Batch
function M.from_recursive(src, limit, ...)
	if not src or src == src.Nil then return Batch:new({}, src and src.Nil or false) end
	limit = limit == -1 and M.config.recursive_limit or (limit == 'vimcount' and vim.v.count1 or limit)
	local actions = { ... }

	-- rawget to bypass CallPath modifications
	if type(actions[1]) == 'table' and rawget(actions[1], 1) then actions = actions[1] end
	local acc = {}
	local Nil = src.Nil

	for _, action in ipairs(actions) do -- for each action
		action = M.action_to_fn(action)
		local item = action(src)
		while item and item ~= Nil and limit > 0 do -- collect nodes while we can apply the action on the consecutive result
			acc[#acc + 1] = item
			item = action(item)
			limit = limit - 1
		end
	end

	return Batch:new(acc, Nil)
end

return M
