local M = {}

local cfgmod = require("locate.config")

-- ---------------------------------------------------------------------------
-- locate
--
-- A dependency-free fuzzy picker. `plugin/locate.lua` registers the `:Locate`
-- command and the highlight groups, so `setup()` is optional and only changes
-- the defaults. Nothing else in the editor is touched; routing `vim.ui.select`
-- through the picker is left to the user:
--
--   vim.ui.select = require("locate.select")
--
-- Built-in sources live in `locate.pickers` and are wired up lazily by
-- `locate.registry`. Other plugins add their own with `M.register(name, spec)`.
-- ---------------------------------------------------------------------------

---@class locate.PickerSpec
---@field prompt string
---@field flags locate.queryflags.FlagDef[]?
---@field enable_preview boolean?
---@field layout locate.Picker.LayoutKind? Overrides the configured layout for this source.
---@field height_ratio number? Overrides the configured height for this source, previewing or not.
---@field width_ratio number? Overrides the configured width for this source, previewing or not.
---@field list_wrap boolean?
---@field history_provider locate.Picker.QueryHistoryProvider?
---@field quickfix_formatter (fun(data:any):vim.quickfix.entry?)?
---@field setup (fun(callback:fun(data:table?)))?
---@field finder fun(query:string, flags:table, fetch_opts:locate.Picker.FetcherOpts, callback:fun(items:locate.Picker.Item[]?)):fun()?
---@field previewer locate.Picker.AsyncPreviewLoader?
---@field initial_cursor (integer|fun(items:locate.Picker.Item[]):integer?)? Row to highlight when the picker opens: a 1-based index into the ranked list, or a function that finds one in it. Resuming a picker overrides it with the row left behind.
---@field on_cursor fun(data:locate.picker.ItemData)? Called with an item's data when the highlight moves onto it, as the user steps through the list or a narrower query leaves a new item on top. Not called for the row the picker opens on.
---@field on_confirm fun(data:locate.picker.ItemData?)

---What a picker opens with. The two prompt sections are held apart: the flags
---are read against the source's schema, the query is text.
---@class locate.PickPrompt
---@field query string?
---@field flags string?

---The live options, held by `locate.config`; the same table, so reading an
---option off `require("locate").config` stays supported.
---@type locate.Config
M.config = cfgmod.current

---Sizing for one source: the configured geometry for the preview state it opens
---in, with whatever the source states itself folded over it.
---@param spec locate.PickerSpec
---@return locate.Picker.Geometry
local function _resolve_geometry(spec)
    local base = spec.enable_preview and M.config.with_preview or M.config.without_preview
    -- Absent keys are absent from the table, so this only overrides what the
    -- spec actually set.
    return vim.tbl_extend("force", base or {}, {
        layout       = spec.layout,
        width_ratio  = spec.width_ratio,
        height_ratio = spec.height_ratio,
    })
end

---The most recent picker invocation, replayed by M.resume(). Holds the
---resolved spec and its setup data so repeat reopens without re-running setup,
---plus the final prompt text so the same query is restored.
---@type {spec:locate.PickerSpec, data:table?, query:string, index:integer?, items:locate.Picker.Item[]?}?
local _last_pick = nil

---@param spec locate.PickerSpec
---@param data table?
---@param prompt locate.PickPrompt?
---@param initial_index integer?
---@param replay_items locate.Picker.Item[]? Cached results to seed the first fetch instead of re-running the finder.
local function _do_open(spec, data, prompt, initial_index, replay_items)
    local picker = require("locate.base.picker")
    prompt     = prompt or {}
    _last_pick = {
        spec  = spec,
        data  = data,
        prompt = { query = prompt.query or "", flags = prompt.flags or "" },
        index = initial_index,
        items = replay_items,
    }
    local replayed = false
    local geometry = _resolve_geometry(spec)
    picker.open({
        prompt              = spec.prompt,
        flags               = spec.flags,
        enable_preview      = spec.enable_preview,
        layout              = geometry.layout,
        width_ratio         = geometry.width_ratio,
        height_ratio        = geometry.height_ratio,
        list_wrap           = spec.list_wrap,
        history_provider    = spec.history_provider,
        quickfix_formatter  = spec.quickfix_formatter,
        previewer           = spec.previewer,
        on_cursor           = spec.on_cursor,
        initial_query       = prompt.query,
        initial_flags       = prompt.flags,
        -- Resuming restores the row the picker was left on, which is a more
        -- specific intent than whatever the source would open on from scratch.
        initial_cursor      = initial_index or spec.initial_cursor,
        auto_complete_flags = M.config.auto_complete_flags,
        finder              = function(query, flags, fetch_opts, callback)
            -- Serve the cached snapshot for the first (unchanged) query so a
            -- repeated picker opens instantly; any edit falls through to a fresh
            -- finder run.
            if replay_items and not replayed then
                replayed = true
                callback(replay_items)
                return nil
            end
            -- Keep a reference to each fresh result set as it flows to the picker,
            -- capped, so resume can replay it without re-running the finder.
            fetch_opts.data = data
            return spec.finder(query, flags, fetch_opts, function(items)
                if _last_pick and _last_pick.spec == spec then
                    _last_pick.items = items
                end
                callback(items)
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

---@param spec locate.PickerSpec?
---@param prompt locate.PickPrompt?
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
---@param prompt locate.PickPrompt?
function M.pick(picker_type, prompt)
    local registry    = require("locate.registry")
    local pickertools = require("locate.base.pickertools")
    if not picker_type or picker_type == "" then
        local keys = registry.keys()
        table.insert(keys, "resume")
        table.sort(keys)
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
---@param spec locate.PickerSpec | fun(): locate.PickerSpec?
---@return string name
function M.register(name, spec)
    return require("locate.registry").register(name, spec)
end

--- Define locate's own highlight groups, as defaults so a colorscheme can
--- override them. Links survive `:colorscheme` and re-resolve against the new
--- scheme, but lose the `default` that lets it have them, which is why anything
--- switching schemes while a picker is open (the `colorschemes` source) calls
--- this again afterwards.
function M.apply_highlights()
    vim.api.nvim_set_hl(0, "LocateMatch", { default = true, link = "Visual" })
    vim.api.nvim_set_hl(0, "LocatePath", { default = true, link = "@namespace" })
    vim.api.nvim_set_hl(0, "LocateBufferIndicator", { default = true, link = "Special" })
    vim.api.nvim_set_hl(0, "LocateFlagPill", { default = true, link = "Visual" })
end

---Optional: `:Locate` and the highlight groups are set up by
---`plugin/locate.lua`, so this is only needed to change the defaults.
---@param opts locate.Config?
function M.setup(opts)
    cfgmod.apply(opts)
end

---Register a user command `name` that forwards its arguments and completion to
---`:Locate`, so the picker can be reached as e.g. `:Pick`. No range, because
---`:Locate` takes none. A name already taken is left alone with a warning.
---
---The registration repeats the one in `plugin/locate.lua` rather than sharing
---it: nothing under `lua/locate/` may be required at startup, and a helper both
---could call would have to be. Both callbacks require `locate.cmdline` lazily,
---so an alias costs nothing until it is used.
---@param name string  a user command name: an uppercase letter, then word characters
---@return boolean created  false when `name` was already taken
function M.create_cmd_alias(name)
    if type(name) ~= "string" or not name:match("^%u") then
        error("[locate] create_cmd_alias() needs a user command name: "
            .. "an uppercase letter, then word characters", 2)
    end
    if vim.api.nvim_get_commands({})[name] then
        vim.notify(("[locate] :%s is already taken, so no alias was created"):format(name),
            vim.log.levels.WARN)
        return false
    end
    vim.api.nvim_create_user_command(name, function(cmd_opts)
        require("locate.cmdline").run(cmd_opts)
    end, {
        nargs    = "*",
        desc     = "Picker for files, grep etc... (alias for :Locate)",
        complete = function(arg_lead, cmd_line, cursor_pos)
            return require("locate.cmdline").complete(arg_lead, cmd_line, cursor_pos)
        end,
    })
    return true
end

return M
