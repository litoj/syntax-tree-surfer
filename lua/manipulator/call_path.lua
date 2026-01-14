local U = require 'manipulator.utils'

---@class manipulator.CallPath.Config
---@field immutable? boolean if path additions produce new objects instead of updates
---@field call? manipulator.CallPath.call.Opts
---@field exec? manipulator.CallPath.exec.Opts
---@field as_op? manipulator.CallPath.as_op.Opts
---@field on_short_motion? manipulator.CallPath.ShortMotionOpt

---@class manipulator.CallPath
---@field [any] self|fun(...):self
---@field protected item any
---@field protected config manipulator.CallPath.Config
---@field protected path manipulator.CallPath.CallConfig[]
---@field protected idx integer at which index do we write the path
---@field private needs_coroutine boolean should it be executed in a coroutine
---@field fn function ready-for-mapping function executing the constructed path
---@field op_fn function shortcut for `self:as_op()`
---@field dot_fn function shortcut for `self:as_op({dot_repeat_only=true})`
local CallPath = {}

--- Necessary reduntant annotations, because lua_ls doesn't work with generics properly

---@class manipulator.CallPath.TS: manipulator.CallPath,manipulator.TS
---@field [any] self|fun(...):self
---@class manipulator.CallPath.Region: manipulator.CallPath,manipulator.Region
---@field [any] self|fun(...):self

local method_to_fn_call = {} -- wrap to ensure the first callpath call on a module is static (no self)
function method_to_fn_call:__index(key)
	local wrappee = rawget(self.item, key)
	if type(wrappee) == 'function' then -- is in static module -> no `self` needed
		self[key] = function(_, ...) return wrappee(...) end
		return self[key]
	end

	return self.item[key]
end

local function wrap_mod(mod)
	if not rawget(method_to_fn_call, mod) then
		method_to_fn_call[mod] = setmetatable({ item = require('manipulator.' .. mod) }, method_to_fn_call)
	end

	return CallPath:new(method_to_fn_call[mod])
end

--- Building syntax:
--- - `mcp.<key>:xyz(opts):exec()` -> `require'manipulator.<key>'.current():xyz(opts)`
--- - `mcp.ts({v_partial=0}).select.fn()` -> `require'manipulator.ts'.current({v_partial=0}):select()`
--- - segments are immutable - every path is reusable and each added field/args produce a new copy
--- Calling the build path:
--- - for keymappings pass in the `.fn` field,
--- - for direct evaluation call `:exec()`/`.fn()` manually
---@overload fun(item?:any,o?:manipulator.CallPath.Config):manipulator.CallPath for generic executor builds
---@class manipulator.CallPath.module: manipulator.CallPath
---@field ts manipulator.CallPath.TS|manipulator.TS.module
---@field region manipulator.CallPath.Region|manipulator.Region.module
---@field class manipulator.CallPath
---@field config manipulator.CallPath.Config
local M = U.get_static(CallPath, {
	__index = function(_, key) return wrap_mod(key) end,
	__call = function(_, ...) return CallPath:new(...) end,
})
function M:new(...) return CallPath:new(...) end

--- Get **immutable** options for the given actions from current config
---@generic O
---@param opts? `O` user options to get expanded - updated **inplace**
---@param action string
---@return O # opts expanded for the given method
function CallPath:action_opts(opts, action)
	return self.config[action]
			and (opts and U.tbl_inner_extend('keep', opts, self.config[action]) or self.config[action])
		or opts
		or {}
end

---@generic I
---@param item? I clones itself if {item} is not provided
---@param config? manipulator.CallPath.Config
---@return manipulator.CallPath<I>
function CallPath:new(item, config)
	-- copies the path contents, not the path obj itself -> modification-independent
	-- relies on the CallInfo to be immutable
	self = U.tbl_inner_extend(
		'keep',
		{ config = config, path = {}, running = false },
		self.path and self or { config = M.config, idx = 0, needs_coroutine = false },
		2 -- level 1: extend path, level 2: extend config also for methods
	)
	self.item = item or self.item or false -- don't ever allow it to be nil (will break normal access)

	return setmetatable(self, CallPath)
end

---@private
function CallPath:__tostring() return vim.inspect(self.path) end
U.with_mod('reform', function()
	local t = require 'reform.tbl_extras'
	function CallPath:__tostring() return vim.inspect(t.tbl_cut_depth(self.path, { depth = 3, cuts = '…' })) end
end)

---@private
---@class manipulator.CallPath.CallConfig
---@field anchor? string if the object is an anchor and not part an actual call
---@field fn? string|fun(x:any,...):any? what method to call/apply on the object (else call the object directly)
---@field args? table<integer,any> what arguments to run the method with
---@field motion_opt? manipulator.CallPath.ShortMotionOpt when applying `vim.v.count`-times and failing

---@private
---@param field 'anchor'|'fn'|'args'|'motion_opt'
---@return manipulator.CallPath.CallConfig
function CallPath:_set_call_field(idx, field, value)
	local call = self.path[idx]
	if self.config.immutable then -- to maintain immutability
		call = U.tbl_inner_extend('keep', { [field] = value }, call)
		self.path[idx] = call
	else
		call[field] = value
	end

	return call
end

---@private
---@param field 'anchor'|'fn'|'args'|'motion_opt'
---@return manipulator.CallPath.CallConfig
function CallPath:_add_call_field(field, value)
	self.idx = self.idx + 1
	local call = { [field] = value }
	table.insert(self.path, self.idx, call)
	return call
end

---@private
---@return self
function CallPath:_mutable()
	local old_self = self -- to be able to check if path was called as a method or fn
	if self.config.immutable then self = self:new() end
	self.old_self = old_self
	return self
end

---@private
---@param key string|fun(x:any,...):any?
function CallPath:__index(key)
	if CallPath[key] then return CallPath[key] end
	if key == 'fn' then -- allow delayed method call via static reference (inject self)
		return function() return self:exec() end
	elseif key == 'op_fn' then
		return self:as_op()
	elseif key == 'dot_fn' then
		return self:as_op { dot_repeat_only = true }
	end

	self = self:_mutable()

	local k1 = type(key) == 'string' and #key > 1 and key:sub(1, 1) or ''
	if k1 == '&' then -- placeholder set (reference/ptr)
		self:_add_call_field('anchor', key:sub(2))
	elseif k1 == '*' then -- placeholder get (dereference)
		k1 = key:sub(2)

		for i, call in ipairs(self.path) do
			if call.anchor == k1 then
				table.remove(self.path, i)
				self.idx = i - 1
				return self
			end
		end

		error('Unknown anchor ' .. k1)
	else -- path addition
		if key == 'pick' then self.needs_coroutine = true end -- `Batch.pick` direct integration

		if self.idx > 0 then -- if there is a motion placeholder, set the field to it
			local call = self.path[self.idx]
			if not call.fn and call.motion_opt then
				self:_set_call_field(self.idx, 'fn', key)
				return self
			end
		end

		self:_add_call_field('fn', key)
	end
	return self
end

---@class manipulator.CallPath.call.Opts
--- NOTE: makes return value useless when running async and `immutable=false`
--- - `number`: ms until actual execution - updates itself (inplace)
--- - `false`: do nothing (default)
--- - `true`: exec immediately and return the result
--- - `'wrapped'`: exec immediately and return a new wrapper
---@field auto_exec? number|false|'wrapped'|true
--- When calling the path and no function is set for the next call should we extend previous args
---@field on_no_fn? 'extend-prev'|'error'|'call-object'
---@field immutable_args? boolean if arguments should be the copy of passed arguments instead

---@private
function CallPath:__call(a1, ...)
	local opts = self.config.call or {}

	local args = rawget(self, 'old_self') == a1 and { ... } or { a1, ... }
	if opts.immutable_args then args = vim.deepcopy(args, true) end

	self = self:_mutable()

	local idx = self.idx
	local call = self.path[idx] ---@type manipulator.CallPath.CallConfig?
	if call and call.anchor then call = nil end
	-- motion marker can obstruct previous field that might not have args yet -> check first
	if call and not call.fn and not call.args and idx > 1 then
		local call_1 = self.path[idx - 1]
		if not call_1.anchor and (call_1.fn or call_1.args) then
			call, idx = call_1, idx - 1
		end
	end

	-- check last CallConfig if we have somewhere to put the args
	if not call or not call.fn or call.args then -- ## cannot update last item
		if opts.on_no_fn == 'call-object' then -- ### create a new call
			call = self:_add_call_field('args', args)
		elseif call and call.fn and opts.on_no_fn == 'extend-prev' then -- ### splice the args
			call = self:_set_call_field( --
				idx,
				'args',
				U.tbl_inner_extend('keep', args, call.args, true, 'noref')
			)
		else
			error('CallPath object call not enabled but attempted: ' .. vim.inspect {
				path = self.path,
				call_nr = idx,
				args = args,
			})
		end
	else -- ## the CallConfig already has a `.fn` that can accept args
		call = self:_set_call_field(idx, 'args', args)
	end

	if call.fn == 'pick' and call.args[1].callback then self.needs_coroutine = false end

	if opts.auto_exec then -- check autoexec settings
		if opts.auto_exec == true then
			return self:exec()
		elseif opts.auto_exec == 'wrapped' then
			self:exec { src = 'update' }
		else
			vim.defer_fn(function() self:exec { src = 'update' } end, opts.auto_exec)
		end
	end

	return self
end

---@alias manipulator.CallPath.ShortMotionOpt 'last-or-nil'|'last-or-self'|'supply-nil'|'abort'

--- Allow the {target} (or the call following that place) to be repeated `vim.v.count1`-times.
---@param target? manipulator.Batch.Action what to apply the count to - defaults to next path
---@param on_short_motion? manipulator.CallPath.ShortMotionOpt on fewer iterations: (at EOF, etc.)
--- - `'last-or-nil'|'last-or-self'`: continue with the last successful iteration or x if empty
--- - `'supply-nil'`: continue with a Nil object
--- - `'abort'`: print a message and end
--- - defaults to `'last-or-self'` to mimic vim motion behaviour at EOF
---@return self
function CallPath:repeatable(target, on_short_motion)
	---@diagnostic disable-next-line: undefined-field because lua_ls is dumb with generics
	self = self:_mutable()

	self:_add_call_field('motion_opt', on_short_motion or M.config.on_short_motion or 'last-or-self')
	if target then self:_add_call_field('fn', target) end
	return self
end

---@class manipulator.CallPath.as_op.Opts
--- Which modes should run normally and not as an operator (to keep visual selection)
--- - forced `'visual'` if `.dot_repeat_only` is enabled
---@field except? false|manipulator.VisualModeEnabler|'visual'
--- Should we return the 'g@' or will this be mapped without `{expr=true}` (both work in insert)
---@field return_expr? boolean
--- Is the purpose only for a dot-repeatable mapping (-> self-initiate) or an actual operator
--- _Note: will act as a normal mapping when in visual mode!_
---@field dot_repeat_only? boolean

--- Create a keybind-ready function that acts as an operator executing the constructed path.
--- Options improve the handling in visual modes and better UX during mapping. Works in insert mode.
---@param opts? manipulator.CallPath.as_op.Opts
---@return function
function CallPath:as_op(opts)
	opts = self:action_opts(opts, 'as_op')

	return function()
		if (opts.except or opts.dot_repeat_only) and U.validate_mode(opts.except or 'visual') then
			return self:exec()
		end

		-- if self-actuating, then <C-o> mode will be finished -> check for temporary normal mode
		local keys = vim.fn.mode(not opts.return_expr):match 'i' and '\015g@' or 'g@'
		if opts.dot_repeat_only then -- special handling to retain `vim.v.count1` value
			M.opfunc = function() self:exec() end
			keys = keys .. tostring(vim.v.count1) .. 'l'
		else
			M.opfunc = function(opmode)
				vim.g.manip_opmode = opmode
				self:exec()
				vim.g.manip_opmode = nil
			end
		end
		vim.go.opfunc = [[v:lua.require'manipulator.call_path'.opfunc]]

		if opts.return_expr then return keys end
		vim.api.nvim_feedkeys(keys, 'n', false)
	end
end

---@class manipulator.CallPath.exec.Opts
--- Should paths that don't lead to a function be considered a simple field access
---@field allow_field_access? boolean
--- Should prepared, but unconfigured motion markers be skipped or produce an error
---@field skip_empty_motion? boolean
---@field skip_anchors? boolean Should any anchored path be skipped or produce an error
--- Object to run the path on (default: self.item), use `'update'` to update the path item
---@field src? 'update'|table

---@param opts? manipulator.CallPath.exec.Opts
---@return any
function CallPath:exec(opts)
	if self.needs_coroutine then
		local co = coroutine.running()
		if not co then
			return coroutine.wrap(function() return self:_exec(opts) end)()
		end
	end
	return self:_exec(opts)
end

---@private
---@param opts? manipulator.CallPath.exec.Opts
function CallPath:_exec(opts)
	opts = self:action_opts(opts, 'exec')

	if opts.src == 'update' then
		if self.running then return end -- basic attempt for async locking
		self.running = true
	elseif opts.src then
		self.backup = self.item
		self.item = opts.src
	end

	local item = self.item
	for i, call in ipairs(self.path) do
		if item == nil and not call.anchor then
			error('CallPath step ' .. i - 1 .. ' returned nil: ' .. tostring(self))
		elseif type(call.fn) ~= 'string' and type(call.fn) ~= 'function' then -- ## no object access
			if call.anchor then
				if not opts.skip_anchors then error('CallPath anchor skipping not allowed: ' .. tostring(self)) end
			elseif call.args then -- ### directly call the object
				item = item(unpack(call.args))
			elseif call.motion_opt then
				if not opts.skip_empty_motion then
					error('CallPath empty-motion skipping not allowed: ' .. tostring(self))
				end
			end
		else -- ## field or function
			local fn = type(call.fn) == 'function' and call.fn or item[call.fn]

			if not fn then
				error("CallPath found no field '" .. call.fn .. "': " .. tostring(self))
			elseif type(fn) ~= 'function' and not rawget(getmetatable(fn) or {}, '__call') then -- ### simple field access
				if call.args or call.motion_opt or not opts.allow_field_access then
					error('CallPath item field ' .. call.fn .. ' is not callable: ' .. tostring(self))
				else
					item = fn -- not a fn - just a field of `item`
				end
			elseif not call.motion_opt or vim.v.count1 == 1 then -- ### single method call - most common
				item = fn(item, unpack(call.args or {}))
			else -- ### vim motion - run for multiple iterations
				local Batch = require 'manipulator.batch'
				local batch =
					Batch.from_recursive(item, vim.v.count1, Batch.action_to_fn(call.fn, unpack(call.args or {})))

				local len = batch:length()
				if len == vim.v.count1 then
					item = batch:at(len)
				else
					vim.notify('Got to count: ' .. len, vim.log.levels.INFO)

					if call.motion_opt == 'abort' then
						break
					elseif call.motion_opt == 'supply-nil' then
						item = item.Nil
					else
						item = len > 0 and batch:at(-1) or (call.motion_opt == 'last-or-self' and item or item.Nil)
					end
				end
			end
		end
	end

	if opts.src == 'update' then
		self.item = item
		self.path = {}
		self.needs_coroutine = false -- all steps processed -> async was also processed
		self.running = false
	elseif opts.src then
		self.item = self.backup
		self.backup = nil
	end
	return item
end

return M
