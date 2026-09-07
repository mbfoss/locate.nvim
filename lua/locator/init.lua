local M = {}

local cfgmod = require("locator.config")

-- ---------------------------------------------------------------------------
-- locator
--
-- A dependency-free fuzzy picker. `plugin/locator.lua` registers the `:Locate`
-- command and the highlight groups, so `setup()` is optional and only changes
-- the defaults. Nothing else in the editor is touched; routing `vim.ui.select`
-- through the picker is left to the user:
--
--   vim.ui.select = require("locator.select")
--
-- Built-in sources are defined in `locator.pickers` and are wired up lazily by
-- `locator.registry`. Other plugins add their own with `M.register(name, spec)`.
-- ---------------------------------------------------------------------------

---@class locator.PickerSpec
---@field prompt string
---@field flags locator.queryflags.FlagDef[]?
---@field enable_preview boolean?
---@field list_wrap boolean?
---@field history_provider locator.Picker.QueryHistoryProvider?
---@field quickfix_formatter (fun(data:any):vim.quickfix.entry?)?
---@field setup (fun(callback:fun(data:table?)))?
---@field finder fun(query:string, flags:table, fetch_opts:locator.Picker.FetcherOpts, callback:fun(items:locator.Picker.Item[]?, initial_cursor:integer?)):fun()? The callback's second argument is the row to open on, 1-based in the items passed.
---@field previewer locator.Picker.AsyncPreviewLoader?
---@field on_cursor fun(data:locator.picker.ItemData)? Called with an item's data when the highlight moves onto it, as the user steps through the list or a narrower query leaves a new item on top. Not called for the row the picker opens on.
---@field on_confirm fun(data:locator.picker.ItemData?)

---What a picker opens with. The two prompt sections are held apart: the flags
---are read against the source's schema, the query is text.
---@class locator.PickPrompt
---@field query string?
---@field flags string?

---The live options, held by `locator.config`; the same table, so reading an
---option off `require("locator").config` stays supported.
---@type locator.Config
M.config = cfgmod.current

---The most recent picker invocation, replayed by M.resume(). Holds the
---resolved spec and its setup data so repeat reopens without re-running setup,
---plus the final prompt text so the same query is restored.
---@type {spec:locator.PickerSpec, data:table?, query:string, index:integer?, items:locator.Picker.Item[]?}?
local _last_pick = nil

---@param spec locator.PickerSpec
---@param data table?
---@param prompt locator.PickPrompt?
---@param initial_index integer?
---@param replay_items locator.Picker.Item[]? Cached results to seed the first fetch instead of re-running the finder.
local function _do_open(spec, data, prompt, initial_index, replay_items)
    local picker = require("locator.base.picker")
    prompt     = prompt or {}
    _last_pick = {
        spec  = spec,
        data  = data,
        prompt = { query = prompt.query or "", flags = prompt.flags or "" },
        index = initial_index,
        items = replay_items,
    }
    local replayed = false
    picker.open({
        prompt              = spec.prompt,
        flags               = spec.flags,
        enable_preview      = spec.enable_preview,
        height_ratio        = M.config.height_ratio,
        preview_ratio       = M.config.preview_ratio,
        list_wrap           = spec.list_wrap,
        history_provider    = spec.history_provider,
        quickfix_formatter  = spec.quickfix_formatter,
        previewer           = spec.previewer,
        on_cursor           = spec.on_cursor,
        initial_query       = prompt.query,
        initial_flags       = prompt.flags,
        auto_complete_flags = M.config.auto_complete_flags,
        finder              = function(query, flags, fetch_opts, callback)
            -- Serve the cached snapshot for the first (unchanged) query so a
            -- repeated picker opens instantly; any edit falls through to a fresh
            -- finder run.
            if replay_items and not replayed then
                replayed = true
                callback(replay_items, initial_index)
                return nil
            end
            -- Keep a reference to each fresh result set as it flows to the picker,
            -- capped, so resume can replay it without re-running the finder.
            fetch_opts.data = data
            return spec.finder(query, flags, fetch_opts, function(items, cursor)
                if _last_pick and _last_pick.spec == spec then
                    _last_pick.items = items
                end
                callback(items, cursor)
            end)
        end,
        on_close            = function(query, flag_text, index)
            -- Remember the final prompt and highlighted row so resume restores
            -- both.
            if _last_pick and _last_pick.spec == spec then
                _last_pick.prompt = { query = query, flags = flag_text }
                _last_pick.index  = index
            end
        end,
    }, spec.on_confirm or function() end)
end

--- Reopen the most recent picker with its last query. Reuses the resolved spec
--- and setup data, so setup is not run again.
function M.resume()
    if not _last_pick then
        vim.notify("No previous picker session", vim.log.levels.INFO)
        return
    end
    _do_open(_last_pick.spec, _last_pick.data, _last_pick.prompt, _last_pick.index, _last_pick.items)
end

---@param spec locator.PickerSpec?
---@param prompt locator.PickPrompt?
local function _open_spec(spec, prompt)
    if not spec then return end
    if spec.setup then
        spec.setup(function(data)
            if data ~= nil then _do_open(spec, data, prompt) end
        end)
    else
        _do_open(spec, nil, prompt)
    end
end

---@param picker_type string?
---@param prompt locator.PickPrompt?
function M.pick(picker_type, prompt)
    local registry    = require("locator.registry")
    local pickertools = require("locator.base.pickertools")
    if not picker_type or picker_type == "" then
        local keys = registry.pickable_keys()
        vim.ui.select(keys, { prompt = "Pick" }, function(choice)
            if choice then M.pick(choice) end
        end)
        return
    end

    if picker_type == "resume" then
        M.resume()
        return
    end

    local spec = registry.get(picker_type)
    if spec then
        spec.history_provider = spec.history_provider or pickertools.make_history_provider(picker_type)
        _open_spec(spec, prompt)
    elseif not registry.has(picker_type) then
        vim.notify("Invalid picker type: " .. tostring(picker_type), vim.log.levels.WARN)
    end
end

---Add a source under `name`. A name already taken by a built-in or another
---plugin is suffixed with a counter; the name actually used is returned.
---@param name string
---@param spec locator.PickerSpec | fun(): locator.PickerSpec?
---@return string name
function M.register(name, spec)
    return require("locator.registry").register(name, spec)
end

--- Define locator's own highlight groups, as defaults so a colorscheme can
--- override them. Links survive `:colorscheme` and re-resolve against the new
--- scheme, but lose the `default` that lets it have them, which is why anything
--- switching schemes while a picker is open (the `colorschemes` source) calls
--- this again afterwards.
function M.apply_highlights()
    vim.api.nvim_set_hl(0, "LocatorMatch", { default = true, link = "Visual" })
    vim.api.nvim_set_hl(0, "LocatorPath", { default = true, link = "@module" })
    vim.api.nvim_set_hl(0, "LocatorLspReference", { default = true, link = "Label" })
    vim.api.nvim_set_hl(0, "LocatorBufferIndicator", { default = true, link = "Special" })
    vim.api.nvim_set_hl(0, "LocatorFlagPill", { default = true, link = "Visual" })
end

---Optional: `:Locate` and the highlight groups are set up by
---`plugin/locator.lua`, so this is only needed to change the defaults.
---@param opts locator.Config?
function M.setup(opts)
    cfgmod.apply(opts)
    require("locator.copen").apply(cfgmod.current.replace_copen)
end

---Register a user command `name` that forwards its arguments and completion to
---`:Locate`, so the picker can be reached as e.g. `:Pick`. No range, because
---`:Locate` takes none. A name already taken is left alone with a warning.
---
---The registration repeats the one in `plugin/locator.lua` rather than sharing
---it: nothing under `lua/locator/` may be required at startup, and a helper both
---could call would have to be. Both callbacks require `locator.cmdline` lazily,
---so an alias costs nothing until it is used.
---@param name string  a user command name: an uppercase letter, then word characters
---@return boolean created  false when `name` was already taken
function M.create_cmd_alias(name)
    if type(name) ~= "string" or not name:match("^%u") then
        error("[locator] create_cmd_alias() needs a user command name: "
            .. "an uppercase letter, then word characters", 2)
    end
    if vim.api.nvim_get_commands({})[name] then
        vim.notify(("[locator] :%s is already taken, so no alias was created"):format(name),
            vim.log.levels.WARN)
        return false
    end
    vim.api.nvim_create_user_command(name, function(cmd_opts)
        require("locator.cmdline").run(cmd_opts)
    end, {
        nargs    = "*",
        desc     = "Picker for files, grep etc... (alias for :Locate)",
        complete = function(arg_lead, cmd_line, cursor_pos)
            return require("locator.cmdline").complete(arg_lead, cmd_line, cursor_pos)
        end,
    })
    return true
end

return M
