local M = {}

---@type table<string, locator.PickerSpec | fun(): locator.PickerSpec?>
local _pickers = {
    _parser_test          = function() return require("locator.pickers.parsertest").spec() end,
    files                 = function() return require("locator.pickers.files").spec() end,
    live_grep             = function() return require("locator.pickers.livegrep").spec() end,
    recent_files          = function() return require("locator.pickers.recentfiles").spec() end,
    config_files          = function()
        return require("locator.pickers.files").spec({
            cwd    = vim.fn.stdpath("config"),
            prompt = "Config files",
        })
    end,
    quickfix              = function() return require("locator.pickers.qflist").spec() end,
    loclist               = function(opts)
        return require("locator.pickers.qflist").spec({
            list_type = "loclist",
            winid     = opts and opts.winid,
        })
    end,
    jumplist              = function() return require("locator.pickers.jumplist").spec() end,
    marks                 = function() return require("locator.pickers.marks").spec() end,
    buffer_lines          = function() return require("locator.pickers.lines").spec() end,
    lsp_references        = function() return require("locator.pickers.lsp").references_spec() end,
    lsp_definitions       = function() return require("locator.pickers.lsp").definitions_spec() end,
    lsp_declarations      = function() return require("locator.pickers.lsp").declarations_spec() end,
    lsp_implementations   = function() return require("locator.pickers.lsp").implementations_spec() end,
    lsp_type_definitions  = function() return require("locator.pickers.lsp").type_definitions_spec() end,
    lsp_incoming_calls    = function() return require("locator.pickers.lsp").incoming_calls_spec() end,
    lsp_outgoing_calls    = function() return require("locator.pickers.lsp").outgoing_calls_spec() end,
    lsp_document_symbols  = function() return require("locator.pickers.lsp").document_symbols_spec() end,
    lsp_workspace_symbols = function() return require("locator.pickers.lsp").workspace_symbols_spec() end,
    document_diagnostics  = function() return require("locator.pickers.diagnostics").spec({ bufnr = 0 }) end,
    workspace_diagnostics = function() return require("locator.pickers.diagnostics").spec() end,
    buffers               = function() return require("locator.pickers.buffers").spec() end,
    windows               = function() return require("locator.pickers.windows").spec() end,
    registers             = function() return require("locator.pickers.registers").spec() end,
    spell_suggest         = function() return require("locator.pickers.spell").spec() end,
    highlights            = function() return require("locator.pickers.highlights").spec() end,
    colorschemes          = function() return require("locator.pickers.colorschemes").spec() end,
    autocommands          = function() return require("locator.pickers.autocommands").spec() end,
    keymaps               = function() return require("locator.pickers.keymaps").spec() end,
    commands              = function() return require("locator.pickers.commands").spec() end,
    command_history       = function() return require("locator.pickers.history").spec({ kind = "cmd" }) end,
    search_history        = function() return require("locator.pickers.history").spec({ kind = "search" }) end,
    help_tags             = function() return require("locator.pickers.helptags").spec() end,
}

---`M.pick` intercepts these before the registry is consulted, so a source
---taking one of these names could never be opened.
local _reserved = {
    resume = true,
}

---Add a source under `name`. A name already in use is suffixed with a counter
---(`files_2`) instead of replacing what is there, so neither source is lost to
---load order.
---@param name string
---@param spec locator.PickerSpec | fun(): locator.PickerSpec?
---@return string name The name the source was registered under.
function M.register(name, spec)
    if type(name) ~= "string" or name == "" then
        error("locator.register: name must be a non-empty string", 2)
    end
    -- `:Pick <name> <query>` splits on whitespace and the picker list shows the
    -- name verbatim, so a name with spaces in it is unreachable.
    if name:find("%s") then
        error("locator.register: name must not contain whitespace: " .. name, 2)
    end
    if _reserved[name] then
        error("locator.register: '" .. name .. "' is reserved by locator", 2)
    end
    local spec_type = type(spec)
    if spec_type ~= "table" and spec_type ~= "function" then
        error("locator.register: spec must be a table or a function returning one, got " .. spec_type, 2)
    end

    if _pickers[name] ~= nil then
        local taken = name
        local n = 1
        repeat
            n = n + 1
            name = taken .. "_" .. n
        until _pickers[name] == nil
        vim.notify(
            string.format("locator: source '%s' is already registered; using '%s' instead", taken, name),
            vim.log.levels.WARN
        )
    end

    _pickers[name] = spec
    return name
end

---@param name string
---@return boolean
function M.has(name)
    return _pickers[name] ~= nil
end

---@return string[]
function M.keys()
    return vim.tbl_keys(_pickers)
end

---@return string[]
function M.visible_keys()
    return vim.tbl_filter(function(name) return name:sub(1, 1) ~= "_" end, vim.tbl_keys(_pickers))
end

---The names a user may ask for by name: every visible source, plus the reserved
---ones `M.pick` answers itself, sorted so a menu and a completion list come out
---in the same order.
---@return string[]
function M.pickable_keys()
    local keys = M.visible_keys()
    vim.list_extend(keys, vim.tbl_keys(_reserved))
    table.sort(keys)
    return keys
end

---@param name string
---@param opts table? Passed to a source registered as a factory, so a caller
---can aim it at a particular window or list.
---@return locator.PickerSpec?
function M.get(name, opts)
    local entry = _pickers[name]
    if entry == nil then return nil end
    if type(entry) == "function" then return entry(opts) end
    return entry
end

---@param name string
---@return locator.queryflags.FlagDef[]?
function M.get_flags(name)
    local spec = M.get(name)
    return spec and spec.flags or nil
end

return M
