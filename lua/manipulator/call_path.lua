local UTILS = require 'manipulator.utils'

---@overload fun(...):manipulator.TSRegion
---@class manipulator.CallPath.TSRegion: manipulator.CallPath,manipulator.TSRegion,{[string]:manipulator.CallPath.TSRegion|fun(...):manipulator.CallPath.TSRegion}
---@overload fun(...):manipulator.Region
---@class manipulator.CallPath.Region: manipulator.CallPath,manipulator.Region,{[string]:manipulator.CallPath.Region|fun(...):manipulator.CallPath.Region}

local fb_call_wrap = {} -- wrap for a fallback call if the next key doesn't exist on the current item
function fb_call_wrap.of(cfg) return setmetatable(cfg, fb_call_wrap) end
function fb_call_wrap:__call(_, ...) -- catch args, without provided self, decide the action on next index
	self.args = { ... }
	return self
end
function fb_call_wrap:__index(key)
	local wrappee = rawget(self.item, key)
	if wrappee then -- is in static module -> no `self` needed
		self[key] = function(_, ...) return wrappee(...) end
	elseif rawget(self.item, key) then -- check the static methods
		-- cannot use UTILS.self_wrap because CallPath always calls in method style
		self[key] = function(_, ...) return wrappee[key](wrappee, ...) end
	else -- call fb_fn to get the object version otherwise
		wrappee = self.item[self.fb_fn](unpack(self.args))
		-- NO saving because we already called a method
		return function(_, ...) return wrappee[key](wrappee, ...) end
	end
	return self[key]
end
setmetatable(fb_call_wrap, fb_call_wrap)

local mod_wrap = {}
function mod_wrap:__index(key)
	-- will be called only if the index isn't found, therefore is new and needs initializing
	self[key] = fb_call_wrap.of { item = require('manipulator.' .. key), fb_fn = 'current' }
	return self[key]
end
setmetatable(mod_wrap, mod_wrap)

---@class manipulator.CallPath: manipulator.CallPath.Opts
---@field private item any
---@field private path (string|{fn:string,args:unknown[]})[]
---@field private ptrs table<string,integer> map of pointers to positions in the path (`&x`->`*x`)
---@field private idx integer at which index do we write the path
---@field fn function ready-for-mapping function executing the constructed path
local CallPath = {}

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
---@class manipulator.CallPath.module: manipulator.CallPath
---@field tsregion manipulator.CallPath.TSRegion|fun(opts:manipulator.TSRegion.module.current.Opts):manipulator.CallPath.TSRegion
---@field region manipulator.CallPath.Region|fun(opts:manipulator.Region.module.current.Opts):manipulator.CallPath.Region
---@field class manipulator.CallPath
local M = UTILS.static_wrap_for_oop(CallPath, {
	__index = function(_, key) return CallPath:new({ item = mod_wrap })[key] end,
})

---@class manipulator.CallPath.Opts
---@field immutable boolean if path additions produce new objects instead of updates
---@field exec_on_call boolean|integer if calls should be executed (at all) or executed with delay. Makes return value useless when running async and `.immutable=false`.
M.default_config = {
	immutable = true,
	exec_on_call = false,

	-- Default object values that get copied when creating a new node
	needs_coroutine = false, ---@private
	running = false,
	idx = 0, ---@private
}
M.config = M.default_config

---@param o? manipulator.CallPath.Opts|{item?: table} clones itself if {item} is not provided
---@return manipulator.CallPath
function CallPath:new(o)
	---@cast o manipulator.CallPath
	o = o or {}
	o.path = {} -- specifying before extending to ensure the path object is modifiable
	o.ptrs = {}

	-- copies the path contents, not the path obj itself -> modification-independent
	o = UTILS.tbl_inner_extend('keep', o, self.path and self or M.config, 1)

	return setmetatable(o, CallPath)
end

---@private
function CallPath:_add_to_path(elem)
	local idx = self.idx + 1
	table.insert(self.path, idx, elem)
	self.idx = idx

	for k, i in pairs(self.ptrs) do -- update all placeholders ahead
		if i >= idx then self.ptrs[k] = i + 1 end
	end
end

---@private
function CallPath:__index(key)
	if CallPath[key] then return CallPath[key] end
	if key == 'fn' then
		return function() return self:exec() end
	end

	if self.immutable then self = self:new() end

	local k1 = #key > 1 and key:sub(1, 1) or ''
	if k1 == '&' then -- placeholder set (reference/ptr)
		self.ptrs[key:sub(2)] = self.idx
	elseif k1 == '*' then -- placeholder get (dereference)
		k1 = key:sub(2)
		self.idx = self.ptrs[k1] or error('Unknown anchor ' .. k1)
		self.ptrs[k1] = nil
	else -- path addition
		self:_add_to_path(key)
		if key == 'pick' then self.needs_coroutine = true end -- `Batch.pick` direct integration
	end
	return self
end

---@private
function CallPath:__call(a1, ...)
	local args = a1 and (getmetatable(a1) == CallPath) and { ... } or { a1, ... }

	if self.immutable then self = self:new() end

	local callee = self.path[self.idx]
	-- `manipulator.Batch.pick` direct integration to detect necessity for coroutine wrap
	if callee == 'pick' then
		if args[1] and args[1].callback then self.needs_coroutine = false end
	end

	if type(callee) == 'string' then
		self.path[self.idx] = { fn = callee, args = args }
	else -- call of the returned value directly
		self:_add_to_path { args = args }
	end

	if #self.ptrs == 0 and self.exec_on_call then -- if the path is complete check autoexec settings
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
	for _, v in ipairs(self.path) do
		if v.fn then -- method with args
			item = item[v.fn](item, unpack(v.args))
		elseif v.args then -- call the object directly
			item = item(unpack(v.args))
		else
			local field = item[v]
			if type(field) == 'function' or getmetatable(field).__call then
				item = field(item) -- method without args
			else
				item = field -- simple field access
			end
		end
	end

	if inplace then
		self.item = item
		self.path = {}
		self.needs_coroutine = false -- all steps processed -> async was also processed
		self.running = false
	end
	return item
end

---@param inplace? boolean if the result should replace the object, reseting the path to {}
function CallPath:exec(inplace)
	if self.needs_coroutine then
		local co = coroutine.running()
		if not co then
			return coroutine.wrap(function() return self:_exec(inplace) end)()
		end
	end
	return self:_exec(inplace)
end

return M
