---@diagnostic disable: undefined-field
---@class manipulator.utils
local M = {}

do -- ### file helpers
	function M.exists(file)
		local f = io.open(file)
		if not f then return false end
		f:close()
		return true
	end

	function M.real_file(file, bufnr)
		file = file:gsub('^~', os.getenv 'HOME', 1)
		if M.exists(file) then return file end
		if file:sub(1, 1) == '/' then return end -- absolute path not found

		if not bufnr then bufnr = 0 end
		local bufDir = vim.api.nvim_buf_get_name(bufnr)
		if bufDir:sub(1, 4) == 'term' then bufDir = bufDir:gsub('^term://(.+/)/%d+:.*$', '%1', 1) end
		bufDir = bufDir:gsub('^~', os.getenv 'HOME', 1):sub(#vim.uv.cwd() + 2) -- keep the last /
		local bufRelFile = bufDir:gsub('[^/]+$', file)
		if M.exists(bufRelFile) then return bufRelFile end
		-- src/ is often in both cwd and path -> path relative to 1 level above cwd
		local cwd_1Rel = vim.uv.cwd():gsub('[^/]+$', file)
		if M.exists(cwd_1Rel) then return cwd_1Rel end
	end

	function M.rel_path(file_or_buf)
		local path = type(file_or_buf) == 'string' and file_or_buf
			or vim.api.nvim_buf_get_name(file_or_buf)

		local cwd = vim.uv.cwd()
		if vim.startswith(path, cwd) then path = '.' .. path:sub(#cwd + 1) end
		return path:gsub('^' .. os.getenv 'HOME', '~')
	end
end

do -- ### module helpers
	function M.with_mod(mod, cb)
		if package.loaded[mod] then return cb(package.loaded[mod]) end
		local old = package.preload[mod]
		package.preload[mod] = function()
			package.preload[mod] = nil
			if old then
				old()
			else
				package.loaded[mod] = nil
				for i = 2, #package.loaders do
					local ret = package.loaders[i](mod)
					if type(ret) == 'function' then
						package.loaded[mod] = ret()
						break
					end
				end
			end
			cb(package.loaded[mod])
		end
	end

	--- Ensure that the function at {key} gets the appropriate `self` object
	function M.fn_self_wrap(fake_self, real_self, key)
		-- pass on `self` only if it seems it's a method call on fake_self
		local wrap = function(arg_self, ...)
			return real_self[key](arg_self == fake_self and real_self or arg_self, ...)
		end
		rawset(fake_self, key, wrap)
		return wrap
	end

	---@generic I
	---@generic O
	---@param oop `I` the class we want to add some extra fn to without being visible in the class
	---@param static `O` object with static methods that should not be visible from {oop}
	---@return O|I|{class:I} static delegating all {oop} functionality back to {oop}
	function M.static_wrap_for_oop(oop, static)
		rawset(static, 'class', oop)
		local idx = static.__index
		return setmetatable(static, {
			__new_index = static.__new_index or function(_, k, v) oop[k] = v end,
			__index = function(_, k)
				local val = oop[k]
				if type(val) == 'function' then val = M.fn_self_wrap(static, oop, k) end
				if val ~= nil or not idx then return val end
				return idx(static, k)
			end,
		})
	end
end

do -- ### opts helpers
	--- Extend {t1} directly without creating a copy. Number-indexed values get appended!
	---@param mode 'keep'|'force' if t1 attributes can get overriden by t2
	---@param t1 table
	---@param t2 table
	---@param depth? integer|boolean number of levels to extend, true for infinite (default: 0)
	---@param deep_copy? boolean if t2 values should be cloned or can be used directly
	---@return table t1
	function M.tbl_inner_extend(mode, t1, t2, depth, deep_copy)
		if t1 == t2 then return t1 end
		if not depth then
			depth = 0
		elseif depth == true then
			depth = math.huge()
		end

		for k, v2 in pairs(t2) do
			if type(k) == 'number' and type(v2) ~= 'table' then
				table.insert(t1, v2)
			else
				local v1 = t1[k]
				if depth > 0 and type(v1) == 'table' and type(v2) == 'table' then
					t1[k] = M.tbl_inner_extend(mode, v1, v2, depth - 1, deep_copy)
				elseif v1 == nil or mode == 'force' then
					t1[k] = type(v2) == 'table' and deep_copy and vim.deepcopy(v2) or v2
				end
			end
		end
		return t1
	end

	---@class manipulator.Enabler: {[string]: boolean}, {[integer]: string} map or list of enabled/disabled values (state in a list is the opposite of ['*'])
	---@field ['*']? boolean
	---@field inherit? boolean should we inherit from the parent config (default: false)

	local enabler_meta = {
		__index = function(self) return rawget(self, '*') end,
	}

	--- Setup automatic fallback evaluation + transform list into a map of enabled values
	---
	---@generic K: string
	---@param enabler {[K]:boolean}
	---@return manipulator.Enabler<K> enabler with added metatable for resolving default values to '*'
	function M.makeEnabler(enabler)
		if enabler[1] then
			local val = not enabler['*']
			for i, v in ipairs(enabler) do
				enabler[i] = nil
				enabler[v] = val
			end
		elseif getmetatable(enabler) then
			return enabler
		end

		return setmetatable(enabler, enabler_meta)
	end

	---@class manipulator.Inheritable
	---@field inherit? boolean|string should inherit from persistent opts, or a preset (default: true for opts, false for table keys)

	--- Expand opts to include all inherited features from presets etc.
	--- Inheritance is controlled by `.inherit` in {opts} or opt keys from {inheritable_keys}.
	--- - By default opts do inherit and opt keys as defined by {inheritable_keys}.
	--- - Using `true` in opts and opt keys translates to 'super'.
	---@generic O: manipulator.Inheritable
	---@param super O|{ [string]: O }|false base options, or false to not resolve the base yet
	---@param presets { [string]: O|{[string]: O} } should contain ['super'] as the parent Opts
	---@param config `O`|string
	---@param inheritable_keys {[string]: boolean|string} keys with inheritance defaults
	--- - false for keys, true|string for actions (string to inherit from another action)
	---@return O|{ presets: { [string]: O|{[string]: O} } } opts
	function M.expand_config(presets, super, config, inheritable_keys)
		presets[true] = super
		config = type(config) ~= 'table' and { inherit = config } or config

		while config.inherit ~= false do
			local preset = presets[config.inherit or true]
			if not preset then
				if preset == false then break end -- to resolve presets, but set the base options later
				error('Invalid preset "' .. (config.inherit or true) .. '"')
			end

			config.inherit = nil -- allow preset to set its own inheritance object
			M.tbl_inner_extend('keep', config, preset)
		end

		for key, is_action in pairs(inheritable_keys) do
			if not is_action then -- actions are resolved separately -> ignore them here
				local val = config[key]
				if type(val) == 'table' and rawget(val, 'inherit') then
					while rawget(val, 'inherit') do
						local preset = presets[val.inherit]
						if preset == false then break end -- preset is a resolving breakpoint

						val.inherit = nil
						if preset[key] then M.tbl_inner_extend('keep', val, preset[key]) end
					end
				end
			end
		end

		config.presets = super and presets or nil
		return config
	end

	--- Actions should be mapped to their defaults in {inheritable_keys}.
	function M.expand_action(config, action, inheritable_keys)
		action = action or ''
		local act_opts = config[action] or {}
		local p_name = inheritable_keys[action]
		while act_opts.inherit ~= false do -- resolve presets for the action
			if act_opts.inherit == nil then act_opts.inherit = p_name or true end

			if act_opts.inherit == true then
				act_opts.inherit = nil
				M.tbl_inner_extend('keep', act_opts, config)
			else
				p_name = inheritable_keys[act_opts.inherit] -- default parent of the inherited action
				local preset = config[act_opts.inherit] or { inherit = true }
				act_opts.inherit = nil
				M.tbl_inner_extend('keep', act_opts, preset)
			end
		end

		for key, is_action in pairs(inheritable_keys) do
			local val = act_opts[key]
			if not is_action and type(val) == 'table' and val.inherit then
				if val.inherit ~= true then error 'Preset referencing not allowed in action defaults.' end

				val.inherit = nil
				if config[key] then M.tbl_inner_extend('keep', val, config[key]) end
			end
		end
		return act_opts
	end

	function M.prepare_presets(config, inheritable_keys)
		local presets = config.presets
		for _, preset in pairs(presets) do
			M.expand_config(presets, false, preset, inheritable_keys)
		end
		config.presets = presets
	end

	--- Expands `opts.actions[action]` with defaults from {opts} and returns the expanded action.
	---@generic O: manipulator.Inheritable
	---@param config { [string]: O, presets: {[string]: O|{[string]: O}} }
	---@param opts? `O`|string user options specifically for the action
	---@param action? string
	---@param inheritable_keys {[string]: boolean|string} keys with inheritance defaults
	---@return O
	function M.get_opts_for_action(config, opts, action, inheritable_keys)
		---@diagnostic disable-next-line: param-type-mismatch
		opts = type(opts) ~= 'table' and { inherit = opts } or M.tbl_inner_extend('force', {}, opts, 2)
		if opts.inherit == false then return opts end
		local act_opts = M.expand_action(
			-- new table with inheritance to distinguish inherited keys from explicit user options
			opts.inherit == nil and config
				or M.expand_config(config.presets, config, { inherit = opts.inherit }, inheritable_keys),
			action,
			inheritable_keys
		)
		act_opts.presets = nil
		opts.inherit = true -- now copy the action defaults into the user opts
		M.expand_config(config.presets, act_opts, opts, inheritable_keys)

		return opts
	end
end

return M
