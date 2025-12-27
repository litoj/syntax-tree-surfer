local U = require 'manipulator.utils'
local Batch = require 'manipulator.batch'

local mod_wrap = {}
do
	local fb_call_wrap = {} -- wrap for a fallback call if the next key doesn't exist on the current item
	function fb_call_wrap:__tostring() return 'fb_call_wrap' end
	function fb_call_wrap:__call(_, ...) -- catch args without provided self
		self.args = { ... }
		return self
	end
	function fb_call_wrap:__index(key)
		local wrappee = rawget(self.item, key)
		if wrappee then -- is in static module -> no `self` needed
			self[key] = function(_, ...) return wrappee(...) end
			return self[key]
		elseif type(self.item[key] or type) ~= 'function' then -- field access by some intermediate checker
			return self.item[key]
		else -- call fallback function to get the object version and seek the key there
			wrappee = self.item.current(unpack(self.args))
			if not wrappee[key] then error('No such method ' .. key .. '() on ' .. tostring(wrappee)) end
			return function(_, ...) return wrappee[key](wrappee, ...) end
		end
	end
	setmetatable(fb_call_wrap, fb_call_wrap)

	function mod_wrap:__tostring() return 'mod_wrap' end
	function mod_wrap:__index(key)
		-- will be called only if the index isn't found, therefore is new and needs initializing
		self[key] = setmetatable({ item = require('manipulator.' .. key), args = {} }, fb_call_wrap)
		return self[key]
	end
	setmetatable(mod_wrap, mod_wrap)
end

---@class manipulator.CallPath.Config
---@field immutable? boolean if path additions produce new objects instead of updates
---@field exec_on_call? # NOTE: makes return value useless when running async and `immutable=false`
---| number # in ms until actual execution - updates itself,
---| false # to not execute until manual call of `:exec()` (the default),
---| true # to `:exec()` calls immediately - returns a new wrapper.
---@field exec? manipulator.CallPath.exec.Opts
---@field as_op? manipulator.CallPath.as_op.Opts

---@class manipulator.CallPath<O>: {item: O, [any]:manipulator.CallPath<O>|O}
---@operator call(...):manipulator.CallPath
---@field protected config manipulator.CallPath.Config
---@field protected path manipulator.CallPath.CallInfo[]
---@field protected idx integer at which index do we write the path
---@field private next_as_motion? manipulator.MotionOpt if the next index/call should be made a motion
---@field fn function ready-for-mapping function executing the constructed path
---@field op_fn function shortcut for `self:as_op()`
---@field dot_fn function shortcut for `self:as_op({dot_repeat_only=true})`
local CallPath = {}

---@overload fun(...):manipulator.TS
---@class manipulator.CallPath.TS: manipulator.CallPath,manipulator.TS,{[string]:manipulator.CallPath.TS|fun(...):manipulator.CallPath.TS}
---@overload fun(...):manipulator.Region
---@class manipulator.CallPath.Region: manipulator.CallPath,manipulator.Region,{[string]:manipulator.CallPath.Region|fun(...):manipulator.CallPath.Region}

---Building syntax:
--- - `mcp.<key>:xyz(opts):exec()` -> `require'manipulator.<key>'.current():xyz(opts)`
--- - `mcp.ts({v_partial=0}).select.fn()` -> `require'manipulator.ts'.current({v_partial=0}):select()`
--- - segments are immutable - every path is reusable and each added field/args produce a new copy
---Calling the build path:
--- - for keymappings pass in the `.fn` field,
--- - for direct evaluation call `:exec()`/`.fn()` manually
---@overload fun(o?:manipulator.CallPath.Config):manipulator.CallPath for generic executor builds
---@class manipulator.CallPath.module: manipulator.CallPath
---@field ts manipulator.CallPath.TS|fun(opts:manipulator.TS.module.current.Opts):manipulator.CallPath.TS
---@field region manipulator.CallPath.Region|fun(opts:manipulator.Region.module.current.Opts):manipulator.CallPath.Region
---@field class manipulator.CallPath
local M = U.static_wrap_for_oop(CallPath, {
	__index = function(_, key) return CallPath:new({ item = mod_wrap })[key] end,
	__call = function(self, args) return self:new(args) end,
})

---@type manipulator.CallPath.Config
M.default_config = {
	immutable = true,
	exec_on_call = false,

	exec = {
		allow_shorter_motion = true,
		allow_direct_calls = false,
		allow_field_access = false,
		skip_anchors = true,
	},
	as_op = { keep_visual = false, return_expr = false },
}

---@type manipulator.CallPath.Config
M.config = M.default_config

---@param config manipulator.CallPath.Config
function M.setup(config)
	M.config = U.expand_config({ active = M.config }, M.default_config, config, {})
	return M
end

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

---@param o? manipulator.CallPath.Config|{item?: table} clones itself if {item} is not provided
---@return manipulator.CallPath
function CallPath:new(o)
	---@cast o manipulator.CallPath
	o = o or {}
	o.path = {} -- specifying before extending to ensure the path object is modifiable
	o.running = false

	-- copies the path contents, not the path obj itself -> modification-independent
	-- relies on the CallInfo to be immutable
	o = U.tbl_inner_extend('keep', o, self.path and self or { config = M.config, idx = 0 }, 1)

	return setmetatable(o, CallPath)
end

---@private
function CallPath:__tostring() return vim.inspect(self.path) end
U.with_mod('reform', function()
	local t = require 'reform.tbl_extras'
	function CallPath:__tostring() return vim.inspect(t.tbl_cut_depth(self.path, { depth = 3, cuts = '…' })) end
end)

---@private
---@class manipulator.CallPath.CallInfo
---@field fn? string|fun(x:any,...):any? what method to call/apply on the object (else call the object directly)
---@field as_motion? manipulator.MotionOpt when applying `vim.v.count`-times what to do on nil
---@field args? unknown[] what arguments to run the method with
---@field anchor? string if the object is an anchor and not part an actual call

---@private
---@param elem manipulator.CallPath.CallInfo
function CallPath:_add_to_path(elem)
	self.idx = self.idx + 1
	table.insert(self.path, self.idx, elem)
end

local PathAnchor = { __index = function() return 1 end }

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

	if self.config.immutable then self = self:new() end

	local k1 = type(key) == 'string' and #key > 1 and key:sub(1, 1) or ''
	if k1 == '&' then -- placeholder set (reference/ptr)
		--- Create an anchor object that looks like a fully setup object
		self:_add_to_path(setmetatable({ anchor = key:sub(2) }, PathAnchor))
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
		self:_add_to_path { fn = key, as_motion = rawget(self, 'next_as_motion') }
		self.next_as_motion = nil

		if key == 'pick' then self.needs_coroutine = true end -- `Batch.pick` direct integration
	end
	return self
end

---@private
function CallPath:__call(a1, ...)
	local args = a1 and (getmetatable(a1) == CallPath) and { ... } or { a1, ... }

	if self.config.immutable then self = self:new() end

	local call = self.path[self.idx]

	if call and not call.args then -- count-enabled call
		self.path[self.idx] = U.tbl_inner_extend('keep', { args = args }, call)
		-- `manipulator.Batch.pick` direct integration to detect necessity for coroutine wrap
		if call.fn == 'pick' and args[1] and args[1].callback then self.needs_coroutine = nil end
	else -- call of the wrapped object directly
		self:_add_to_path { args = args }
	end

	if self.config.exec_on_call then -- check autoexec settings
		if self.config.exec_on_call == true then
			self:exec { src = 'update' }
		else
			vim.defer_fn(function() self:exec { src = 'update' } end, self.config.exec_on_call)
		end
	end

	return self
end

---@alias manipulator.MotionOpt (nil|true|'print')|('ignore'|false) whether to inform the user when the motion falls short of the requested iteration count

--- Allow the {target} to be repeated `vim.v.count1`-times.
--- NOTE: anchores are ignored -> if it is followed by an anchor and
--- then an index that index will get marked as a motion.
---
--- NOTE: Type annotation commented, until lsp_lua fixes inheritance in generics
---
--[[ ---@generic P: manipulator.CallPath
---@param self `P`
---@param target manipulator.Batch.Action|'on_next' what to apply the count onto
---@param on_fail? manipulator.MotionOpt if we should inform the user about failing to do enough
---   interations, or carry on (accepting the last good value or giving an error) (default: 'print')
---@return `P` self copy ]]
function CallPath:with_count(target, on_fail)
	if self.config.immutable then self = self:new() end

	local as_motion = U.get_or(on_fail, 'print') or 'ignore'
	if target == 'on_next' then
		self.next_as_motion = as_motion
	elseif target then
		self:_add_to_path { fn = target, as_motion = as_motion }
	else
		error 'Param `target` is required'
	end
	return self
end

---@class manipulator.CallPath.as_op.Opts
---@field keep_visual? boolean should visual mode be run normally, or as an operator (which would cause an exit from visual mode)
---@field return_expr? boolean if we should return the 'g@' or will this be mapped without `{expr=true}` (adapted for insert mode either way)
---@field dot_repeat_only? boolean if the purpose is only for a dot-repeatable mapping (-> self-initiate) or an actual operator
--- - invokes itself to

--- Create a keybind-ready function that acts as an operator executing the constructed path.
--- Options improve the handling in visual modes and better UX during mapping. Works in insert mode.
---@param opts? manipulator.CallPath.as_op.Opts
---@return function
function CallPath:as_op(opts)
	opts = self:action_opts(opts, 'as_op')

	return function()
		local mode = vim.fn.mode()
		local keys
		if mode == 'v' or mode == 'V' or mode == '\022' then
			if opts.keep_visual then return self:exec() end

			keys = 'g@'
		else
			keys = opts.dot_repeat_only and 'g@l' or 'g@'
		end

		M.opfunc = function(opmode)
			if keys == 'g@' then vim.g.manip_opmode = opmode end
			self:exec()
			vim.g.manip_opmode = nil
		end
		vim.go.operatorfunc = [[v:lua.require'manipulator.call_path'.opfunc]]

		if mode == 'i' then keys = '\015' .. keys end -- <C-o>
		if opts.return_expr then return keys end
		vim.api.nvim_feedkeys(keys, 'n', false)
	end
end

---@class manipulator.CallPath.exec.Opts
---@field allow_shorter_motion? boolean should we use the last valid motion iteration or produce an error when the motion cannot be repeated anymore (reached end of document)
---@field allow_direct_calls? boolean should arguments for direct calls on the wrapped object be executed or produce an error
---@field allow_field_access? boolean should paths that don't lead to a function be considered a simple field access
---@field skip_anchors? boolean should any anchored path be skipped or produce an error
---@field src? # modifications to the object to run the path on (default: self.item)
---| 'update' # the result should replace the object, reseting the path to {}
---| table # run the path on the given object

---@param opts? manipulator.CallPath.exec.Opts
---@return any
function CallPath:exec(opts)
	if rawget(self, 'needs_coroutine') then
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
		if item == nil and type(call.anchor) ~= 'string' then -- no item and not at an anchor
			error('CallPath step ' .. i - 1 .. ' returned nil: ' .. tostring(self))
		elseif type(call.fn) ~= 'string' and type(call.fn) ~= 'function' then -- ## no object access
			if rawget(call, 'args') then -- directly call the object
				if not opts.allow_direct_calls then
					error('CallPath direct calls are not allowed: ' .. tostring(self))
				end
				item = item(unpack(call.args))
			elseif not opts.skip_anchors then
				error('CallPath anchor skipping not allowed: ' .. tostring(self))
			end
		else -- ## field or function
			local fn = type(call.fn) == 'function' and call.fn or item[call.fn]

			if not fn then
				error("CallPath found no field '" .. call.fn .. "': " .. tostring(self))
			elseif type(fn) ~= 'function' and not getmetatable(fn).__call then -- simple field access
				if call.args or call.as_motion or not opts.allow_field_access then
					error('CallPath item field ' .. call.fn .. ' is not callable: ' .. tostring(self))
				else
					item = fn
				end
			elseif not call.args and not call.as_motion then -- ### method without args
				item = fn(item)
			elseif not call.as_motion or vim.v.count1 == 1 then -- ### single method call
				item = fn(item, unpack(call.args or {}))
			else -- ### vim motion - run for multiple iterations
				local batch = Batch.from_recursive(
					item,
					vim.v.count1,
					function(item)
						return (type(call.fn) == 'function' and call.fn or item[call.fn])(item, unpack(call.args or {}))
					end
				)

				local len = batch:length()
				if len == vim.v.count1 then
					item = batch:at(len)
				else
					if call.as_motion == 'print' then vim.notify('Got to count: ' .. len, vim.log.levels.INFO) end

					if opts.allow_shorter_motion and len > 0 then
						item = batch:at(-1)
					else
						if call.as_motion == 'print' then break end
						error('CallPath iteration count not satisfied: ' .. len)
					end
				end
			end
		end
	end

	if opts.src == 'update' then
		self.item = item
		self.path = {}
		self.needs_coroutine = nil -- all steps processed -> async was also processed
		self.running = false
	elseif opts.src then
		self.item = self.backup
		self.backup = nil
	end
	return item
end

return M
