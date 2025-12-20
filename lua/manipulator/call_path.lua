local UTILS = require 'manipulator.utils'
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

---@alias manipulator.MotionOpt 'fallback'|'print_last'|'error'

---@private
---@class manipulator.CallPath.CallInfo
---@field field? string what method to call on the object (else call the object directly)
---@field as_motion? manipulator.MotionOpt when applying `vim.v.count`-times what to do on nil
---@field args? unknown[] what arguments to run the method with
---@field anchor? string if the object is an anchor and not part an actual call

---@class manipulator.CallPath.Config
---@field immutable boolean if path additions produce new objects instead of updates
---@field exec_on_call boolean|integer if calls should be executed (at all) or executed with delay. Makes return value useless when running async and `.immutable=false`.
---@field strict boolean should any unfinished or anchored path be considered an error or skipped (default: false=skip)

---@class manipulator.CallPath: manipulator.CallPath.Config
---@field private item any
---@field private path manipulator.CallPath.CallInfo[]
---@field private idx integer at which index do we write the path
---@field private next_as_motion? manipulator.MotionOpt if the next index/call should be made a motion
---@field fn function ready-for-mapping function executing the constructed path
local CallPath = {}

---@overload fun(...):manipulator.TSRegion
---@class manipulator.CallPath.TSRegion: manipulator.CallPath,manipulator.TSRegion,{[string]:manipulator.CallPath.TSRegion|fun(...):manipulator.CallPath.TSRegion}
---@overload fun(...):manipulator.Region
---@class manipulator.CallPath.Region: manipulator.CallPath,manipulator.Region,{[string]:manipulator.CallPath.Region|fun(...):manipulator.CallPath.Region}

---Field `.exec_on_call`:
--- - `number` in ms until actual execution - updates itself,
--- - `false` to not execute until manual call of `:exec()` (the default),
--- - `true` to `:exec()` calls immediately - returns a new wrapper.
---Building syntax:
--- - `mcp.<key>:xyz(opts):exec()` -> `require'manipulator.<key>'.current():xyz(opts)`
--- - `mcp.tsregion({v_partial=0}).select.fn()` -> `require'manipulator.tsregion'.current({v_partial=0}):select()`
--- - segments are immutable - every path is reusable and each added field/args produce a new copy
---Calling the build path:
--- - for keymappings pass in the `.fn` field,
--- - for direct evaluation call `:exec()`/`.fn()` manually
---@overload fun(o?:manipulator.CallPath.Config):manipulator.CallPath for generic executor builds
---@class manipulator.CallPath.module: manipulator.CallPath
---@field tsregion manipulator.CallPath.TSRegion|fun(opts:manipulator.TSRegion.module.current.Opts):manipulator.CallPath.TSRegion
---@field region manipulator.CallPath.Region|fun(opts:manipulator.Region.module.current.Opts):manipulator.CallPath.Region
---@field class manipulator.CallPath
local M = UTILS.static_wrap_for_oop(CallPath, {
	__index = function(_, key) return CallPath:new({ item = mod_wrap })[key] end,
	__call = function(self, args) return self:new(args) end,
})

---@type manipulator.CallPath.Config
M.default_config = {
	immutable = true,
	exec_on_call = false,
	strict = false,

	-- Default object values that get copied when creating a new node
	idx = 0, ---@private
}

---@type manipulator.CallPath.Config
M.config = M.default_config

---@param config manipulator.CallPath.Config
function M.setup(config)
	M.config = UTILS.expand_config({ active = M.config }, M.default_config, config, {})
	return M
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
	o = UTILS.tbl_inner_extend('keep', o, self.path and self or M.config, 1)

	return setmetatable(o, CallPath)
end

---@private
function CallPath:__tostring() return vim.inspect(self.path) end

---@private
---@param elem manipulator.CallPath.CallInfo
function CallPath:_add_to_path(elem)
	self.idx = self.idx + 1
	table.insert(self.path, self.idx, elem)
end

local PathAnchor = { __index = function() return 1 end }

---@private
function CallPath:__index(key)
	if CallPath[key] then return CallPath[key] end
	if key == 'fn' then -- allow delayed method call via static reference (inject self)
		return function() return self:exec() end
	end

	if self.immutable then self = self:new() end

	local k1 = #key > 1 and key:sub(1, 1) or ''
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
		self:_add_to_path { field = key, as_motion = rawget(self, 'next_as_motion') }
		self.next_as_motion = nil

		if key == 'pick' then self.needs_coroutine = true end -- `Batch.pick` direct integration
	end
	return self
end

-- TODO: dot repeat
--- Allow the next index (call) to be repeated `vim.v.count1`-times.
--- NOTE: anchores are ignored -> if it is followed by an anchor and
--- then an index that index will get marked as a motion.
---
--- Type annotation commented, until lsp_lua figures out inheritance
--- - `on_nil?` (`manipulator.MotionOpt`): (default: error message)
function CallPath:next_with_count(on_nil)
	if self.immutable then self = self:new() end

	self.next_as_motion = on_nil or 'error'
	return self
end

---@private
function CallPath:__call(a1, ...)
	local args = a1 and (getmetatable(a1) == CallPath) and { ... } or { a1, ... }

	if self.immutable then self = self:new() end

	local call = self.path[self.idx]

	if call and not call.args then -- count-enabled call
		self.path[self.idx] = UTILS.tbl_inner_extend('keep', { args = args }, call)
		-- `manipulator.Batch.pick` direct integration to detect necessity for coroutine wrap
		if call.field == 'pick' and args[1] and args[1].callback then self.needs_coroutine = nil end
	else -- call of the wrapped object directly
		self:_add_to_path { args = args }
	end

	if self.exec_on_call then -- check autoexec settings
		if self.exec_on_call == true then
			self:exec(true)
		else
			vim.defer_fn(function() self:exec(true) end, self.exec_on_call)
		end
	end

	return self
end

---@private
function CallPath:_exec(inplace)
	if inplace then
		if self.running then return end -- basic attempt for async locking
		self.running = true
	end

	local item = self.item
	for _, call in ipairs(self.path) do
		if not rawget(call, 'field') then -- raw to skip anchor metatables
			if rawget(call, 'args') then -- call the object directly
				item = item(unpack(call.args))
			elseif self.strict then
				error('Invalid CallInfo: ' .. vim.inspect(call) .. '\nin CallPath: ' .. vim.inspect(self.path))
			end
		else
			if call.args or call.as_motion then -- method call
				if not call.as_motion or vim.v.count1 == 1 then
					item = item[call.field](item, unpack(call.args or {}))
				else -- vim motion - run for multiple iterations
					local args = call.args or {}
					local fn = call.field
					local batch = Batch.from_recursive(
						item,
						vim.v.count1,
						function(item) return item[fn](item, unpack(args)) end
					)

					local len = batch:length()
					if len == vim.v.count1 then
						item = batch:at(-1)
					else
						vim.notify('Got to count: ' .. len, vim.log.levels.INFO)

						if call.as_motion == 'fallback' then
							item = batch:at(-1)
						elseif call.as_motion == 'print_last' then
							return
						else
							error('CallPath iteration count not satisfied: ' .. len)
						end
					end
				end
			else
				local field = item[call.field]
				if type(field) == 'function' or getmetatable(field).__call then
					item = field(item) -- method without args
				else -- field access or method call
					item = field -- simple field access
				end
			end
		end
	end

	if inplace then
		self.item = item
		self.path = {}
		self.needs_coroutine = nil -- all steps processed -> async was also processed
		self.running = false
	end
	return item
end

---@param inplace? boolean if the result should replace the object, reseting the path to {}
function CallPath:exec(inplace)
	if rawget(self, 'needs_coroutine') then
		local co = coroutine.running()
		if not co then
			return coroutine.wrap(function() return self:_exec(inplace) end)()
		end
	end
	return self:_exec(inplace)
end

return M
