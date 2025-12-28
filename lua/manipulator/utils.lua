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
		local path = type(file_or_buf) == 'string' and file_or_buf or vim.api.nvim_buf_get_name(file_or_buf)

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
		return function(arg_self, ...) return real_self[key](arg_self == fake_self and real_self or arg_self, ...) end
	end

	---@generic I,O
	---@param oop I the class we want to add some extra fn to without being visible in the class
	---@param static O|table object with static methods that should not be visible from {oop}
	---@return O|I|{class:I} static delegating all {oop} functionality back to {oop}
	function M.static_wrap_for_oop(oop, static)
		rawset(static, 'class', oop)
		local idx = static.__index
		static.__index = function(_, k)
			local val = oop[k]
			if type(val) == 'function' then return M.fn_self_wrap(static, oop, k) end
			if val ~= nil or not idx then return val end
			return idx(static, k)
		end
		if not static.__new_index then
			static.__new_index = function(_, k, v) error('Tried to set value "' .. k .. '" to "' .. v .. '"') end
		end
		return setmetatable(static, static)
	end
end

--- Helper to distinguish `nil` from `false`
---@generic V,D
---@param val V
---@param default D
---@return V|D
function M.get_or(val, default)
	if val == nil then return default end
	return val
end

--- Extend {t1} directly without creating a copy. Number-indexed values get appended!
---@param mode 'keep'|'force' if t1 attributes can get overriden by t2
---@param t1 table
---@param t2 table
---@param depth? integer|boolean number of levels to extend, true for infinite (default: 0)
---@param deep_copy? boolean|'noref' if t2 values should be cloned or can be used directly
---   - 'noref' sets the `noref` param of `vim.deepcopy()` to `true`
---@return table t1
function M.tbl_inner_extend(mode, t1, t2, depth, deep_copy)
	if t1 == t2 then return t1 end
	if not depth then
		depth = 0
	elseif depth == true then
		depth = math.huge
	end

	for k, v2 in pairs(t2) do
		if type(k) == 'number' and type(v2) ~= 'table' then
			table.insert(t1, v2)
		else
			local v1 = t1[k]
			if depth > 0 and type(v1) == 'table' and type(v2) == 'table' then
				t1[k] = M.tbl_inner_extend(mode, v1, v2, depth - 1, deep_copy)
			elseif v1 == nil or mode == 'force' then
				t1[k] = type(v2) == 'table' and deep_copy and vim.deepcopy(v2, deep_copy == 'noref') or v2
			end
		end
	end
	return t1
end

---@class manipulator.Inheritable
---@field inherit? boolean|string should inherit from persistent opts, or a preset (default: true for opts, false for table keys)

do -- enabler maker
	---@class manipulator.Enabler map or list of enabled/disabled values (state in a list is the opposite of ['*'])
	---@field [string] boolean
	---@field [integer] string
	---@field ['*']? boolean
	---@field inherit? boolean should we inherit from the parent config (default: false)
	---@field matchers? {[string]:boolean} list of lua patterns for more complex filtering

	local enabler_meta = {
		__index = function(self, key)
			if type(key) ~= 'string' then return nil end
			if rawget(self, 'matchers') then
				for m, v in pairs(self.matchers) do
					if key:match(m) then return v end
				end
			end
			return rawget(self, '*')
		end,
	}

	--- Setup automatic fallback evaluation + transform list into a map of enabled values
	---@generic K: string
	---@param enabler manipulator.Enabler
	---@param luapat_detect? string lua pattern to detect list items that are luapats, not str
	---@return manipulator.Enabler<K> enabler with added metatable for resolving default values to '*'
	function M.activate_enabler(enabler, luapat_detect)
		if enabler[1] then
			local val = not enabler['*']
			for i, key in ipairs(enabler) do
				enabler[i] = nil
				if luapat_detect and key:match(luapat_detect) then -- luapat expression
					if not enabler.matchers then enabler.matchers = {} end
					enabler.matchers[key] = val
				elseif not enabler[key] then
					enabler[key] = val
				end
			end
		elseif getmetatable(enabler) then
			return enabler
		end

		return setmetatable(enabler, enabler_meta)
	end
end

do -- ### config inheritance/extension helpers
	---@alias manipulator.KeyInheritanceMap {[string]: boolean|string} which preset, if any, should the given option inherit from
	--- - false for keys, true|string for action options (string to inherit from another key)

	--- Expand opts to include all inherited features from presets etc.
	--- Inheritance is controlled by `.inherit` in {opts} or opt keys from {inheritable_keys}.
	--- - By default opts do inherit and opt keys as defined by {inheritable_keys}.
	--- - Using `true` in opts and opt keys translates to 'super'.
	---@generic O: manipulator.Inheritable
	---@param super O|{ [string]: O }|false base options, or false to not resolve the base yet
	---@param presets { [string]: O|{[string]: O} } should contain ['super'] as the parent Opts
	---@param config? `O`|string
	---@param opt_inheritance manipulator.KeyInheritanceMap defaults of key inheritance
	---@return O|{ presets: { [string]: O|{[string]: O} } } opts
	function M.expand_config(presets, super, config, opt_inheritance)
		presets[true] = super
		config = type(config) ~= 'table' and { inherit = config } or config ---@type table

		local last, preset = config, nil ---@type table?
		while config.inherit ~= false do
			preset = presets[config.inherit or true]
			if not preset or preset == last then -- prevent recursion
				if preset ~= nil then break end -- preset merging without finalization
				error('Invalid preset: ' .. config.inherit)
			end
			last = preset

			config.inherit = nil -- allow preset to set its own inheritance object
			M.tbl_inner_extend('keep', config, preset, 1) -- 1 to get into action opts
		end

		for key, is_action in pairs(opt_inheritance) do
			local val = config[key]
			preset = type(val) == 'table' and M.get_or(rawget(val, 'inherit'), is_action) ---@type string|table?
			if preset then
				last = nil
				while preset do -- rawget to not trigger enablers
					preset = presets[preset]
					if not preset or preset == last then -- prevent recursion
						if is_action or preset ~= nil then break end -- action/preset merging without finalization
						error('Invalid preset: ' .. val.inherit .. ' in key: ' .. key)
					end
					last = preset

					val.inherit = nil
					if preset[key] then M.tbl_inner_extend('keep', val, preset[key]) end
					preset = M.get_or(rawget(val, 'inherit'), is_action)
				end
			end
		end

		presets[true] = nil -- avoid recursion and hence memory leaking
		config.presets = super and presets or nil
		return config
	end

	--- Transitively expand action inheritance chain.
	--- Action defaults inheritance from other presets must be resolved with `M.expand_config`.
	--- - such as: `cfg={ presets={['P1']={ [action] = {def_val=1} }}, [action] = { inherit='P1' } }`
	--- Can inherit only from other actions, or its parent.
	--- Actions should be mapped to their defaults in {opt_inheritance}.
	function M.expand_action(presets, action, opt_inheritance)
		presets[true] = presets
		action = action or ''
		-- start with the action defaults so that the defaults get saved
		local config = presets[action] or {}
		local p_name = opt_inheritance[action]

		local last, preset = config, nil
		while config.inherit ~= false do -- resolve presets for the action
			if config.inherit == nil then config.inherit = p_name or true end

			p_name = opt_inheritance[config.inherit] -- default parent of the inherited action
			preset = presets[config.inherit]
			if preset then
				if preset == last then
					error('Invalid action: ' .. config.inherit .. ' while resolving action: ' .. action)
				end
				last = preset

				config.inherit = nil
				M.tbl_inner_extend('keep', config, preset)
			else
				config.inherit = nil
			end
		end

		-- local not_cfg = opt_inheritance[action] -- static fns don't inherit
		config[action] = nil -- avoid inheriting itself from the base cfg

		for key, is_action in pairs(opt_inheritance) do -- action keys can inherit only from parent
			local val = config[key]
			if is_action then -- action cfg doesn't get saved and reused -> other act opts useless
				-- NOTE: disabled action ref cleanup until a better solution for rangemod full user opts access
				-- even when enabled there will be ptr recursion
				-- - current() defaults inherit cfg, actions keys with opt_inh.=false -> set inh to ''?
				-- if not_cfg then act_opts[key] = nil end
			elseif type(val) == 'table' and rawget(val, 'inherit') then -- avoid enablers
				if val.inherit == true then -- NOTE: presets in keys get resolved by expand_config later
					val.inherit = nil
					if presets[key] then M.tbl_inner_extend('keep', val, presets[key]) end
				end
			end
		end

		presets[true] = nil
		config[true] = nil
		return config
	end

	--- Expands `config` and `config.actions[action]` into {opts}.
	--- If `config` has not been expanded yet, it will be first.
	---@generic O: manipulator.Inheritable
	---@param config { [string]: O, presets: {[string]: O|{[string]: O}} }
	---@param opts? `O`|string user options specifically for the action, will get modified
	---@param action? string no action is considered a request for just expanded config into `{opts}`
	---@param opt_inheritance {[string]: boolean|string} keys with inheritance defaults
	---@return O
	function M.get_opts_for_action(config, opts, action, opt_inheritance)
		if not action then return M.expand_config(config.presets, config, opts, opt_inheritance) end

		opts = type(opts) ~= 'table' and { inherit = opts } or opts ---@type table
		if opts.inherit == false then return opts end

		local act_opts = M.expand_action(
			-- new table with inheritance to distinguish inherited keys from explicit user options
			-- also resolve, if config is just a template
			(opts.inherit or config.inherit)
					and M.expand_config(config.presets, config, { inherit = opts.inherit }, opt_inheritance)
				or config,
			action,
			opt_inheritance
		)
		act_opts.presets = nil
		opts.inherit = true -- merge action defaults into user opts
		M.expand_config(config.presets, act_opts, opts, opt_inheritance)

		return opts
	end

	---@return table new
	function M.module_setup(presets, super, new, opt_inheritance)
		if presets and new and new.presets then -- imperfect but the best possible preset merging and extending
			for k, v in pairs(presets) do
				if not new.presets[k] then new.presets[k] = v end
				v.presets = nil
			end

			for k, v in pairs(new.presets) do
				if (presets[k] or 1) ~= v then
					new.presets.parent = presets[k] -- allow inheriting from previous version of the preset
					M.expand_config(new.presets, false, v, opt_inheritance)
					v.presets = nil
				end
			end

			new.presets.parent = nil
			presets = new.presets
		end

		local config = M.expand_config(presets, super, new, opt_inheritance)
		presets.active = config
		return config
	end
end

return M
