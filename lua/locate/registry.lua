local M = {}

---@type table<string, locate.PickerSpec | fun(): locate.PickerSpec?>
local _pickers = {
    parser_test           = function() return require("locate.pickers.parsertest").spec() end,
    files                 = function() return require("locate.pickers.files").spec() end,
    live_grep             = function() return require("locate.pickers.livegrep").spec() end,
    recent_files          = function() return require("locate.pickers.recentfiles").spec() end,
    config_files          = function()
        return require("locate.pickers.files").spec({
            cwd    = vim.fn.stdpath("config"),
            prompt = "Config files",
        })
    end,
    quickfix              = function() return require("locate.pickers.qflist").spec() end,
    loclist               = function() return require("locate.pickers.qflist").spec({ list_type = "loclist" }) end,
    jumplist              = function() return require("locate.pickers.jumplist").spec() end,
    marks                 = function() return require("locate.pickers.marks").spec() end,
    buffer_lines          = function() return require("locate.pickers.lines").spec() end,
    lsp_references        = function() return require("locate.pickers.lsp").references_spec() end,
    lsp_definitions       = function() return require("locate.pickers.lsp").definitions_spec() end,
    lsp_declarations      = function() return require("locate.pickers.lsp").declarations_spec() end,
    lsp_implementations   = function() return require("locate.pickers.lsp").implementations_spec() end,
    lsp_type_definitions  = function() return require("locate.pickers.lsp").type_definitions_spec() end,
    lsp_incoming_calls    = function() return require("locate.pickers.lsp").incoming_calls_spec() end,
    lsp_outgoing_calls    = function() return require("locate.pickers.lsp").outgoing_calls_spec() end,
    lsp_document_symbols  = function() return require("locate.pickers.lsp").document_symbols_spec() end,
    lsp_workspace_symbols = function() return require("locate.pickers.lsp").workspace_symbols_spec() end,
    document_diagnostics  = function() return require("locate.pickers.diagnosics").spec({ bufnr = 0 }) end,
    workspace_diagnostics = function() return require("locate.pickers.diagnosics").spec() end,
    buffers               = function() return require("locate.pickers.buffers").spec() end,
    windows               = function() return require("locate.pickers.windows").spec() end,
    registers             = function() return require("locate.pickers.registers").spec() end,
    spell_suggest         = function() return require("locate.pickers.spell").spec() end,
    highlights            = function() return require("locate.pickers.highlights").spec() end,
    colorschemes          = function() return require("locate.pickers.colorschemes").spec() end,
    autocommands          = function() return require("locate.pickers.autocommands").spec() end,
    keymaps               = function() return require("locate.pickers.keymaps").spec() end,
    commands              = function() return require("locate.pickers.commands").spec() end,
    command_history       = function() return require("locate.pickers.history").spec({ kind = "cmd" }) end,
    search_history        = function() return require("locate.pickers.history").spec({ kind = "search" }) end,
    help_tags             = function() return require("locate.pickers.helptags").spec() end,
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
---@param spec locate.PickerSpec | fun(): locate.PickerSpec?
---@return string name The name the source was registered under.
function M.register(name, spec)
    if type(name) ~= "string" or name == "" then
        error("locate.register: name must be a non-empty string", 2)
    end
    -- `:Pick <name> <query>` splits on whitespace and the picker list shows the
    -- name verbatim, so a name with spaces in it is unreachable.
    if name:find("%s") then
        error("locate.register: name must not contain whitespace: " .. name, 2)
    end
    if _reserved[name] then
        error("locate.register: '" .. name .. "' is reserved by locate", 2)
    end
    local spec_type = type(spec)
    if spec_type ~= "table" and spec_type ~= "function" then
        error("locate.register: spec must be a table or a function returning one, got " .. spec_type, 2)
    end

    if _pickers[name] ~= nil then
        local taken = name
        local n = 1
        repeat
            n = n + 1
            name = taken .. "_" .. n
        until _pickers[name] == nil
        vim.notify(
            string.format("locate: source '%s' is already registered; using '%s' instead", taken, name),
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

---@param name string
---@return locate.PickerSpec?
function M.get(name)
    local entry = _pickers[name]
    if entry == nil then return nil end
    if type(entry) == "function" then return entry() end
    return entry
end

---@param name string
---@return locate.queryflags.FlagDef[]?
function M.get_flags(name)
    local spec = M.get(name)
    return spec and spec.flags or nil
end

return M
