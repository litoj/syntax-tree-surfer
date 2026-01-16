---@diagnostic disable: undefined-field, redefined-local
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

	---@generic I,O
	---@param oop I the class we want to add some extra fn to without being visible in the class
	---@param base O|table object with static methods that should not be visible from {oop}
	---@return O|I|{class:I} static delegating all {oop} functionality back to {oop}
	function M.get_static(oop, base)
		base.class = oop
		base.__index = base.__index or oop
		return setmetatable(base, base)
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

--- Extend {t1} directly without creating a copy.
--- NOTE: Number-indexed values get set if nil, otherwise **appended**!
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
		local v1 = t1[k]
		if depth > 0 and type(v1) == 'table' and type(v2) == 'table' then
			t1[k] = M.tbl_inner_extend(mode, v1, v2, depth - 1, deep_copy)
		elseif v1 == nil or mode == 'force' then
			t1[k] = type(v2) == 'table' and deep_copy and vim.deepcopy(v2, deep_copy == 'noref') or v2
		elseif type(k) == 'number' then
			table.insert(t1, v2)
		end
	end
	return t1
end

---@generic T
---@param tbl `T`
---@param parts string[]
---@return T
function M.tbl_partcopy(tbl, parts)
	local ret = {}
	for _, p in ipairs(parts) do
		if type(tbl[p]) == 'table' then
			ret[p] = vim.deepcopy(tbl[p], true)
		else
			ret[p] = tbl[p]
		end
	end
	return ret
end

---@alias manipulator.VisualMode 'v'|'V'|'\022'|'s'|'S'|'\019'
---@alias manipulator.VisualModeEnabler table<manipulator.VisualMode, true>

---@param modes manipulator.VisualModeEnabler|'visual'
function M.validate_mode(modes)
	if modes == 'visual' then modes = { v = true, V = true, ['\022'] = true, s = true, S = true } end
	return modes[vim.fn.mode()]
end

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
	---@class manipulator.Inheritable
	---@field inherit? boolean|string should inherit from persistent opts, or a preset (default: true for opts, false for table keys)

	--- Which preset, if any, should the given option inherit from
	--- - false for keys, true|string for action options (string to inherit from another key)
	---@class manipulator.KeyInheritanceMap: {[string]: boolean|string}

	---@generic P: manipulator.Inheritable
	---@param presets {[string|true]:P}
	---@param key string|true? index to the presets - can have a `.` for indexing inner value (action)
	--- - `true|nil` translates to `'super'`
	---@param default_key string? what to do on `key==true|key==nil` - default preset or return?
	---@param opt_name string? name of the option to retrieve, NOTE: only used for error messages
	---@param allow_nil? boolean|string when on a nil preset, return, or error?
	--- - `string` for a lua pattern to determine if given preset name can be nil
	--- - default keys, action paths, or caller determined preset paths can be nil and will return
	---@return P?
	---@return string? p_name
	function M.get_preset(presets, key, default_key, opt_name, allow_nil)
		if type(allow_nil) ~= 'string' then allow_nil = allow_nil and '^' or '$^' end
		if type(key) ~= 'string' then
			if not default_key then return end
			key = default_key
		end
		local k, field = key, nil
		while #k > 0 do
			field = k:match '^[^.]+'
			presets = presets[field]
			if not presets then
				-- default keys, action paths, or caller determined preset paths can be nil
				if key == default_key or key:match '%.' or key:match(allow_nil) then return end
				error(
					'Invalid preset field: "'
						.. field
						.. '" in preset path: "'
						.. key
						.. (opt_name and '", while getting: ' .. opt_name or '"')
				)
			end
			k = k:sub(#field + 2)
		end
		return presets, key
	end

	--- Resolve the inheritance chain of a single option key (not action).
	---@return boolean # `true` if the full expansion was successful, `false` if nil preset was found
	local function expand_opt(presets, val, default_p_name, opt_name, allow_nil)
		if type(val) ~= 'table' then return true end

		while rawget(val, 'inherit') do
			local preset, key = M.get_preset(presets, rawget(val, 'inherit'), default_p_name, opt_name, allow_nil)
			if not preset then return false end
			if preset[opt_name] then
				val.inherit = nil
				M.tbl_inner_extend('keep', val, preset[opt_name], true, 'noref')
			elseif rawget(val, 'inherit') ~= true then -- if it was a specific preset - could warn the user
				print { val = val, def_p = default_p_name, opt = opt_name }
				val.inherit = nil
			end
			if key == default_p_name then return true end
		end
		return true
	end

	---@class manipulator.Action: {inherit: boolean?, [string]: manipulator.Inheritable|any}
	---@generic O: manipulator.Action
	---@class manipulator.Preset: manipulator.Inheritable, {[string]: O}

	--- Expand opts to include all inherited features from presets etc.
	--- Inheritance is controlled by `.inherit` in {opts} or opt keys from {}.
	--- Using `true` in opts and opt keys translates to the field in super at the same level, i.e.:
	--- - `true` in a field in an action `a` is retrieved from the preset `super.a`
	--- FIXME: expands configs without copying -> inheriting options will get expanded also in the
	--- original preset -> base inherited config will get permanently imprinted
	---@generic O: manipulator.Preset
	---@param super O base options, or nil to not resolve the base yet
	---@param presets { [string]: O } should contain ['super'] as the parent Opts
	---@param config? O|string
	---@param action_map manipulator.KeyInheritanceMap which keys inherit by default and what
	---@return O|{ presets: { [string]: O } } config
	function M.expand_config(presets, super, config, action_map)
		presets['super'] = super
		config = type(config) ~= 'table' and { inherit = config } or config ---@type table

		local default_p_name = 'super' ---@type string?
		while config.inherit ~= false do
			local preset, p_name = M.get_preset(presets, config.inherit, default_p_name, nil, false)
			if p_name == default_p_name then default_p_name = nil end
			if not preset or not p_name then
				---@diagnostic disable-next-line: inject-field
				super.presets = nil
				error('Parent config inheritance chain unterminated: ' .. vim.inspect(super))
			end

			for key, val in pairs(config) do
				if not action_map[key] then -- any option, possibly capable of inheriting -> check
					expand_opt(presets, val, p_name, key, false)
				elseif not p_name:match '%.' then -- action opts
					local p_name = p_name .. '.' .. key
					for key, val in pairs(val) do -- inherit the keys in the action
						-- expand, but postpone `self` presets for expand_action (where they come from)
						if not action_map[key] then expand_opt(presets, val, p_name, key, '^self') end
					end

					-- try to inherit the config of the same action in the resolved preset
					if val.inherit ~= false then
						if type(val.inherit) == 'string' then
							error(
								'Config cannot set action inheritance to specific presets (got: '
									.. val.inherit
									.. '), correct your config for action: '
									.. key
							)
						end
						-- we don't have to loop since actions cannot inherit presets freely
						local preset = M.get_preset(presets, p_name, nil, key, true)
						if preset then
							val.inherit = nil
							M.tbl_inner_extend('keep', val, preset)
						end
					end
				end
			end
			config.inherit = nil -- allow preset to set the next config to inherit
			M.tbl_inner_extend('keep', config, preset)
		end

		-- since config is always expanded last, there might be new actions with new opt preset inherits
		-- also ensures the expansion happens even if we started with `config.inherit==false`
		for key, val in pairs(config) do
			if not action_map[key] then -- any option, possibly capable of inheriting -> check
				expand_opt(presets, val, default_p_name, key, false)
			else
				local p_name = default_p_name and default_p_name .. '.' .. key or nil
				for key, val in pairs(val) do -- inherit the keys in the action
					if not action_map[key] then expand_opt(presets, val, p_name, key, '^self') end
				end
			end
		end

		presets['super'] = nil -- avoid recursive references
		config.presets = super and presets or nil
		return config
	end

	--- Expands `self` and `self[action]` into `act_opts` following the `action_map`.
	--- Action defaults inheritance from other presets must be resolved with `M.expand_config`.
	--- - such as: `cfg={ presets={['P1']={ act = {def_val=1} }}, act = { inherit='P1.act' } }`
	--- Actions should be mapped to their defaults in `action_map`.
	--- - actions can inherit only from other actions, or its parent.
	--- If `self` has a preset dependency, it will be expanded before chain resolution.
	---@generic O: manipulator.Preset
	---@param self O|{ presets: {[string]: O} }
	---@param act_opts? manipulator.Action|{inherit:string}|string user options specifically for the action - modifiable
	---@param action? string name of what we're resolving - none to get a normal config expansion
	---@param action_map {[string]: boolean|string} keys with inheritance defaults
	---@return manipulator.Action config
	function M.expand_action(self, act_opts, action, action_map)
		if act_opts and act_opts.inherit == false then return act_opts end
		if not action then return M.expand_config(self.presets, self, act_opts, action_map) end

		act_opts = type(act_opts) ~= 'table' and { inherit = act_opts } or act_opts ---@type table

		-- new table with inheritance to distinguish inherited keys from explicit user options
		-- also resolves the config if just a template (ts.get_ft_config)
		self = (act_opts.inherit or self.inherit)
				and M.expand_config(self.presets, self, { inherit = act_opts.inherit }, action_map)
			or self
		if act_opts.inherit then act_opts.inherit = true end -- preset was resolved, now process normally

		local presets = self.presets
		presets['self'] = self
		local preset, default_p_name, p_name = nil, action, nil

		-- NOTE: this means an action with inherit=false will prevent types from inheriting self
		while act_opts.inherit ~= false and default_p_name do
			p_name = default_p_name == true and 'self' or ('self.' .. default_p_name)
			preset = M.get_preset(presets, p_name, nil, action, false)

			if preset then
				act_opts.inherit = nil -- allow preset to set the next config to inherit
				for key, val in pairs(preset) do
					if not action_map[key] then
						if act_opts[key] == nil then
							act_opts[key] = val
						else
							expand_opt(presets, act_opts[key], p_name, key, false)
						end
					end
				end
			end

			default_p_name = action_map[default_p_name] -- advance to the next action to inherit from
		end

		presets['self'] = nil
		act_opts.presets = nil
		return act_opts
	end

	--- For user preset to inherit from the previous version he should use that name for `inherit`
	---@generic O
	---@param presets table<string,O>
	---@param super O
	---@param config O?
	---@return O new
	function M.module_setup(presets, super, config, action_map)
		if not config then return super end
		local new_presets = config.presets or {}
		new_presets.active = config
		if config.inherit ~= false then -- only the main config can inherit from any preset
			presets['active'] = config.inherit == 'default' and super or presets[config.inherit or 'active']
			config.inherit = 'active'
		end

		for name, new in pairs(new_presets) do
			if presets[name] then
				local old = presets[name]
				local preset_inherits = M.get_or(new.inherit, name) == name
				local p_stub = { [name] = old } -- to ensure we expand only the old version
				for key, val in pairs(new) do
					if not action_map[key] then
						expand_opt(p_stub, val, nil, key, true)
					else
						local old_act = old[key] or {}
						key = name .. '.' .. key

						for opt, val in pairs(val) do
							expand_opt(p_stub, val, nil, opt, true)
						end

						-- actions cannot inherit freely, but do inherit if the preset does
						if val.inherit ~= false and preset_inherits then
							val.inherit = nil
							M.tbl_inner_extend('keep', val, old_act)
						end
					end
				end

				if preset_inherits then
					new.inherit = nil
					M.tbl_inner_extend('keep', new, old)
					new.presets = nil
				end
			end
		end

		for n, p in pairs(presets) do
			if not new_presets[n] then new_presets[n] = p end
			p.presets = nil -- to avoid recursive references (GC)
		end

		config.presets = new_presets
		return config
	end
end

return M
