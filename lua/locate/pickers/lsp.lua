local M                  = {}

local ui                 = require("locate.util.ui")
local pickertools        = require("locate.base.pickertools")
local fsutil             = require("locate.util.fsutil")
local strutil            = require("locate.util.strutil")

local _kind_to_str_cache = {}
---@param kind number LSP SymbolKind (integer)
---@return string
local function kind_to_string(kind)
    if vim.tbl_isempty(_kind_to_str_cache) then
        local symbol_kinds = vim.lsp.protocol.SymbolKind
        for name, id in pairs(symbol_kinds) do
            if type(id) == "number" then
                _kind_to_str_cache[id] = name
            end
        end
    end
    return _kind_to_str_cache[kind] or ""
end

---@type locate.queryflags.FlagDef[]
local REF_FLAGS = {
    { name = "filter", type = "value", multi = true, slot = "glob", desc = "glob filter: *.txt, **/dir/**" },
}

---Every LSP SymbolKind name, in protocol order (SymbolKind 1..26).
---@type string[]
local SYMBOL_KINDS = {
    "File",
    "Module",
    "Namespace",
    "Package",
    "Class",
    "Method",
    "Property",
    "Field",
    "Constructor",
    "Enum",
    "Interface",
    "Function",
    "Variable",
    "Constant",
    "String",
    "Number",
    "Boolean",
    "Array",
    "Object",
    "Key",
    "Null",
    "EnumMember",
    "Struct",
    "Event",
    "Operator",
    "TypeParameter",
}

-- One boolean flag per symbol kind, so kinds are selected as "--Function
-- --Class" rather than a single "--kind" value list. Several at once are OR'd.
---@type locate.queryflags.FlagDef[]
local SYMBOL_FLAGS = {}
for _, name in ipairs(SYMBOL_KINDS) do
    table.insert(SYMBOL_FLAGS, {
        name = name,
        type = "boolean",
        desc = ("%s symbols"):format(name),
    })
end

---@class locate.lsp.LocationsOpts
---@field method string LSP request method, e.g. "textDocument/definition"
---@field prompt string
---@field include_declaration boolean? Send `context.includeDeclaration` (references only).
---@field jump_single boolean? Jump straight to the location when the request yields exactly one.

---A picker over any request that answers with locations: references,
---definitions, declarations, implementations and type definitions all return
---`Location`, `Location[]` or `LocationLink[]`, so they differ only in the
---method sent and how a single result is treated.
---@param opts locate.lsp.LocationsOpts
---@return locate.PickerSpec
local function locations_spec(opts)
    local params = vim.lsp.util.make_position_params(0, "utf-8")
    if opts.include_declaration then
        ---@diagnostic disable-next-line: inject-field
        params.context = { includeDeclaration = true }
    end

    ---@type locate.PickerSpec
    return {
        prompt          = opts.prompt,
        flags           = REF_FLAGS,
        enable_preview  = true,
        setup           = function(callback)
            local action = opts.method
            vim.lsp.buf_request_all(0, action, params, function(results_per_client)
                local lsp_items = {}
                local errors    = {}
                for client_id, result_or_error in pairs(results_per_client) do
                    local err, result = result_or_error.err, result_or_error.result
                    if err then
                        errors[client_id] = err
                    elseif result ~= nil then
                        local locations = vim.islist(result) and result or { result }
                        local enc       = vim.lsp.get_client_by_id(client_id).offset_encoding
                        vim.list_extend(lsp_items, vim.lsp.util.locations_to_items(locations, enc))
                    end
                end
                for _, err in pairs(errors) do
                    vim.notify(action .. " : " .. err.message, vim.log.levels.ERROR)
                end
                if vim.tbl_isempty(lsp_items) then
                    vim.notify("No " .. opts.prompt .. " found")
                    callback(nil)
                    return
                end
                -- A lone definition is what the user asked for; showing a
                -- one-entry picker for it would just add a keystroke.
                if opts.jump_single and #lsp_items == 1 then
                    local target = lsp_items[1]
                    vim.schedule(function()
                        ui.smart_open_file(target.filename, target.lnum, target.col - 1)
                    end)
                    callback(nil)
                    return
                end
                callback({ lsp_items = lsp_items })
            end)
        end,
        finder          = function(query, flags, fetch_opts, callback)
            local data         = fetch_opts.data
            local picker_items = {}
            for _, ref in ipairs(data.lsp_items) do
                local display_path = fsutil.get_relative_path(ref.filename) or ref.filename or ""
                local in_globs     = flags["filter"] or {}
                if not pickertools.match_globs(in_globs, display_path, true) then goto continue end

                local text  = ref.text and vim.fn.trim(ref.text) or ""
                local match = pickertools.match_label(text, query)
                if match then
                    local loc = ref.lnum and string.format("%s:%d", display_path, ref.lnum) or display_path
                    loc = strutil.crop_for_ui(loc, fetch_opts.virt_line_width, true)
                    ---@type locate.Picker.Item
                    table.insert(picker_items, {
                        label_chunks = match.chunks,
                        score        = match.score,
                        virt_line    = { { loc, "LocatePath" } },
                        data         = {
                            filepath = ref.filename,
                            lnum     = ref.lnum,
                            col      = ref.col - 1,
                        }
                    })
                end
                ::continue::
            end
            if query == "" then
                table.sort(picker_items, function(a, b)
                    if a.data.filepath ~= b.data.filepath then
                        return a.data.filepath < b.data.filepath
                    end
                    if a.data.lnum ~= b.data.lnum then
                        return a.data.lnum < b.data.lnum
                    end
                    return a.data.col < b.data.col
                end)
            end
            callback(picker_items)
        end,
        on_confirm      = function(data)
            if data then ui.smart_open_file(data.filepath, data.lnum, data.col) end
        end,
    }
end

---@return locate.PickerSpec
function M.references_spec()
    return locations_spec({
        method              = "textDocument/references",
        prompt              = "LSP References",
        include_declaration = true,
    })
end

---@return locate.PickerSpec
function M.definitions_spec()
    return locations_spec({
        method      = "textDocument/definition",
        prompt      = "LSP Definitions",
        jump_single = true,
    })
end

---@return locate.PickerSpec
function M.declarations_spec()
    return locations_spec({
        method      = "textDocument/declaration",
        prompt      = "LSP Declarations",
        jump_single = true,
    })
end

---@return locate.PickerSpec
function M.implementations_spec()
    return locations_spec({
        method      = "textDocument/implementation",
        prompt      = "LSP Implementations",
        jump_single = true,
    })
end

---@return locate.PickerSpec
function M.type_definitions_spec()
    return locations_spec({
        method      = "textDocument/typeDefinition",
        prompt      = "LSP Type Definitions",
        jump_single = true,
    })
end

---One end of a call relationship, flattened out of the protocol's nested
---`CallHierarchyItem` / `fromRanges` shape.
---@class locate.lsp.CallEntry
---@field name string
---@field kind string
---@field filepath string
---@field lnum integer
---@field col integer

---Incoming calls: `call.from` is the caller, and `fromRanges` are the call sites
---*inside* that caller: one entry each, since landing on the call itself is
---the point of asking who calls this.
---@param call table CallHierarchyIncomingCall
---@return locate.lsp.CallEntry[]
local function incoming_entries(call)
    local from = call.from
    if not from or not from.uri then return {} end

    local filepath = vim.uri_to_fname(from.uri)
    local ranges   = call.fromRanges
    if not ranges or #ranges == 0 then
        ranges = { from.selectionRange or from.range }
    end

    local entries = {}
    for _, range in ipairs(ranges) do
        if range then
            entries[#entries + 1] = {
                name     = from.name,
                kind     = kind_to_string(from.kind),
                filepath = filepath,
                lnum     = range.start.line + 1,
                col      = range.start.character,
            }
        end
    end
    return entries
end

---Outgoing calls: `call.to` is the callee. Its `fromRanges` point back into the
---buffer the cursor is already in, so they are dropped in favour of the callee's
---own position: one entry per callee, landing on what it is you are calling.
---@param call table CallHierarchyOutgoingCall
---@return locate.lsp.CallEntry[]
local function outgoing_entries(call)
    local to = call.to
    if not to or not to.uri then return {} end

    local range = to.selectionRange or to.range
    return { {
        name     = to.name,
        kind     = kind_to_string(to.kind),
        filepath = vim.uri_to_fname(to.uri),
        lnum     = range and range.start.line + 1 or 1,
        col      = range and range.start.character or 0,
    } }
end

---@class locate.lsp.CallsOpts
---@field method string `callHierarchy/incomingCalls` or `callHierarchy/outgoingCalls`
---@field prompt string
---@field to_entries fun(call:table):locate.lsp.CallEntry[]

---Call hierarchy takes two rounds: `textDocument/prepareCallHierarchy` turns the
---cursor position into an item, and only then can the calls be asked for. The
---item belongs to the client that produced it, so the second request goes back
---to that same client rather than to the buffer at large.
---@param opts locate.lsp.CallsOpts
---@return locate.PickerSpec?
local function calls_spec(opts)
    local bufnr = vim.api.nvim_get_current_buf()

    if vim.tbl_isempty(vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/prepareCallHierarchy" })) then
        vim.notify("No LSP client supports call hierarchy", vim.log.levels.WARN)
        return nil
    end

    local params = vim.lsp.util.make_position_params(0, "utf-8")

    ---@type locate.PickerSpec?
    return {
        prompt         = opts.prompt,
        flags          = REF_FLAGS,
        enable_preview = true,
        setup          = function(callback)
            vim.lsp.buf_request_all(bufnr, "textDocument/prepareCallHierarchy", params, function(prepared)
                ---@type {client:vim.lsp.Client, item:table}[]
                local targets = {}
                for client_id, result_or_error in pairs(prepared) do
                    local item   = result_or_error.result and result_or_error.result[1]
                    local client = vim.lsp.get_client_by_id(client_id)
                    if item and client then
                        targets[#targets + 1] = { client = client, item = item }
                    end
                end

                if #targets == 0 then
                    vim.notify("No call hierarchy for the symbol under the cursor")
                    callback(nil)
                    return
                end

                ---@type locate.lsp.CallEntry[]
                local entries   = {}
                local remaining = #targets

                local function finish()
                    if #entries == 0 then
                        vim.notify("No " .. opts.prompt .. " found")
                        callback(nil)
                        return
                    end
                    table.sort(entries, function(a, b)
                        if a.filepath ~= b.filepath then return a.filepath < b.filepath end
                        if a.lnum ~= b.lnum then return a.lnum < b.lnum end
                        return a.col < b.col
                    end)
                    callback({ entries = entries })
                end

                for _, target in ipairs(targets) do
                    local sent = target.client:request(opts.method, { item = target.item },
                        function(err, result)
                            if err then
                                vim.notify(opts.method .. " : " .. err.message, vim.log.levels.ERROR)
                            end
                            for _, call in ipairs(result or {}) do
                                vim.list_extend(entries, opts.to_entries(call))
                            end
                            remaining = remaining - 1
                            if remaining == 0 then finish() end
                        end, bufnr)

                    -- A client that refuses the request never calls back, so it
                    -- has to be counted off here or the picker never opens.
                    if not sent then
                        remaining = remaining - 1
                        if remaining == 0 then finish() end
                    end
                end
            end)
        end,
        finder         = function(query, flags, fetch_opts, callback)
            local items = {}
            for _, entry in ipairs(fetch_opts.data.entries) do
                local display_path = fsutil.get_relative_path(entry.filepath) or entry.filepath
                if not pickertools.match_globs(flags["filter"] or {}, display_path, true) then goto continue end

                local match = pickertools.match_label(entry.name, query)
                if match then
                    local chunks = match.chunks
                    table.insert(chunks, { (" (%s)"):format(entry.kind), "Comment" })

                    local loc = strutil.crop_for_ui(
                        ("%s:%d"):format(display_path, entry.lnum), fetch_opts.virt_line_width, true)

                    ---@type locate.Picker.Item
                    table.insert(items, {
                        label_chunks = chunks,
                        score        = match.score,
                        virt_line    = { { loc, "LocatePath" } },
                        data         = {
                            filepath = entry.filepath,
                            lnum     = entry.lnum,
                            col      = entry.col,
                        },
                    })
                end
                ::continue::
            end
            callback(items)
        end,
        on_confirm     = function(data)
            if data then ui.smart_open_file(data.filepath, data.lnum, data.col) end
        end,
    }
end

---@return locate.PickerSpec?
function M.incoming_calls_spec()
    return calls_spec({
        method     = "callHierarchy/incomingCalls",
        prompt     = "LSP Incoming Calls",
        to_entries = incoming_entries,
    })
end

---@return locate.PickerSpec?
function M.outgoing_calls_spec()
    return calls_spec({
        method     = "callHierarchy/outgoingCalls",
        prompt     = "LSP Outgoing Calls",
        to_entries = outgoing_entries,
    })
end

---@param opts {kinds:string[]?,prompt:string?}?
---@return locate.PickerSpec
function M.document_symbols_spec(opts)
    opts                   = opts or {}

    local params           = { textDocument = vim.lsp.util.make_text_document_params() }
    local filepath         = vim.api.nvim_buf_get_name(0)
    local cursor_lnum      = vim.api.nvim_win_get_cursor(0)[1]

    local opts_kind_filter = {}
    for _, k in ipairs(opts.kinds or {}) do opts_kind_filter[k:lower()] = true end

    -- The symbol enclosing the cursor, picked out once the server answers. The
    -- finder hands each item this very table as its data, so identity is enough
    -- to find its row later.
    local initial_data     = nil

    return {
        prompt         = opts.prompt or "Document Symbols",
        flags          = SYMBOL_FLAGS,
        enable_preview = true,
        initial_cursor = function(items)
            if not initial_data then return nil end
            for row, item in ipairs(items) do
                if item.data == initial_data then return row end
            end
        end,
        setup          = function(callback)
            vim.lsp.buf_request(0, "textDocument/documentSymbol", params, function(err, result, _)
                if err or not result then
                    callback(nil)
                    return
                end

                local items = {}
                local function flatten(symbols)
                    for _, s in ipairs(symbols) do
                        -- DocumentSymbol uses selectionRange; SymbolInformation uses location.range
                        local range = s.selectionRange or (s.location and s.location.range)
                        if range then
                            table.insert(items, {
                                kind = kind_to_string(s.kind),
                                data = {
                                    name     = s.name,
                                    filepath = filepath,
                                    lnum     = range.start.line + 1,
                                    col      = range.start.character,
                                },
                            })
                        end
                        if s.children then flatten(s.children) end
                    end
                end
                flatten(result)

                local best, best_lnum = nil, 0
                for _, item in ipairs(items) do
                    local lnum = item.data.lnum
                    if lnum <= cursor_lnum and lnum > best_lnum then
                        best      = item
                        best_lnum = lnum
                    end
                end
                initial_data = best and best.data or nil

                if #items == 0 then
                    vim.notify("No symbols found")
                    callback(nil)
                    return
                end
                callback({ items = items })
            end)
        end,
        finder         = function(query, flags, fetch_opts, callback)
            local data       = fetch_opts.data
            -- Kind booleans select a union: "--Function --Class" keeps both,
            -- none set keeps every kind.
            local flag_kinds = {}
            local any_kind   = false
            for _, name in ipairs(SYMBOL_KINDS) do
                if flags[name] then
                    flag_kinds[name] = true
                    any_kind         = true
                end
            end

            local filtered = {}
            for _, item in ipairs(data.items) do
                if next(opts_kind_filter) ~= nil and not opts_kind_filter[item.kind:lower()] then
                    goto continue
                end
                if any_kind and not flag_kinds[item.kind] then goto continue end

                local match = pickertools.match_label(item.data.name, query)
                if match then
                    vim.list_extend(match.chunks, { { (" (%s)"):format(item.kind), "Comment" } })
                    table.insert(filtered, {
                        label_chunks = match.chunks,
                        score        = match.score,
                        data         = item.data,
                    })
                end
                ::continue::
            end
            callback(filtered)
        end,
        on_confirm     = function(data)
            if data then vim.api.nvim_win_set_cursor(0, { data.lnum, data.col }) end
        end,
    }
end

---A workspace symbol as this picker keeps it: flattened out of the LSP reply so
---the finder never has to reach back into the protocol shapes.
---@class locate.lsp.WorkspaceSymbol
---@field name string
---@field kind string
---@field container string?
---@field filepath string
---@field lnum integer
---@field col integer

---Symbols across the whole workspace, registered as `lsp_workspace_symbols`.
---The server is asked once, with `query` (empty by default, which most servers
---read as "everything you have"), and the answer is then filtered locally like
---every other source: the same split Telescope's picker of that name makes.
---Servers that refuse an empty query need one passed in through `opts.query`.
---@param opts {query:string?}?
---@return locate.PickerSpec?
function M.workspace_symbols_spec(opts)
    opts = opts or {}

    if vim.tbl_isempty(vim.lsp.get_clients({ bufnr = 0, method = "workspace/symbol" })) then
        vim.notify("No LSP client supports workspace/symbol", vim.log.levels.WARN)
        return nil
    end

    ---@type locate.PickerSpec?
    return {
        prompt         = "Workspace Symbols",
        flags          = SYMBOL_FLAGS,
        enable_preview = true,
        setup          = function(callback)
            local params = { query = opts.query or "" }
            vim.lsp.buf_request_all(0, "workspace/symbol", params, function(results_per_client)
                ---@type locate.lsp.WorkspaceSymbol[]
                local symbols = {}
                local errors  = {}
                for client_id, result_or_error in pairs(results_per_client) do
                    if result_or_error.err then
                        errors[client_id] = result_or_error.err
                    end
                    for _, sym in ipairs(result_or_error.result or {}) do
                        local location = sym.location
                        if location and location.uri then
                            -- A 3.17 server may answer with a location carrying no
                            -- range (to be filled in by workspaceSymbol/resolve);
                            -- point at the top of the file in that case.
                            local range = location.range
                            symbols[#symbols + 1] = {
                                name      = sym.name,
                                kind      = kind_to_string(sym.kind),
                                container = sym.containerName,
                                filepath  = vim.uri_to_fname(location.uri),
                                lnum      = range and range.start.line + 1 or 1,
                                col       = range and range.start.character or 0,
                            }
                        end
                    end
                end
                for _, err in pairs(errors) do
                    vim.notify("workspace/symbol : " .. err.message, vim.log.levels.ERROR)
                end

                if #symbols == 0 then
                    vim.notify("No workspace symbols found")
                    callback(nil)
                    return
                end

                -- Servers answer in no particular order, and the engine does not
                -- rank by match score, so settle on one predictable ordering.
                -- Case-insensitively, or every capitalised type name would be
                -- herded above the lowercase functions.
                table.sort(symbols, function(a, b)
                    local a_name, b_name = a.name:lower(), b.name:lower()
                    if a_name ~= b_name then return a_name < b_name end
                    if a.name ~= b.name then return a.name < b.name end
                    if a.filepath ~= b.filepath then return a.filepath < b.filepath end
                    return a.lnum < b.lnum
                end)
                callback({ symbols = symbols })
            end)
        end,
        finder         = function(query, flags, fetch_opts, callback)
            local flag_kinds = {}
            local any_kind   = false
            for _, name in ipairs(SYMBOL_KINDS) do
                if flags[name] then
                    flag_kinds[name] = true
                    any_kind         = true
                end
            end

            local items = {}
            for _, sym in ipairs(fetch_opts.data.symbols) do
                if any_kind and not flag_kinds[sym.kind] then goto continue end

                local match = pickertools.match_label(sym.name, query)
                if match then
                    local chunks = match.chunks
                    table.insert(chunks, { (" (%s)"):format(sym.kind), "Comment" })
                    if sym.container and sym.container ~= "" then
                        table.insert(chunks, { "  " .. sym.container, "Comment" })
                    end

                    local loc = strutil.crop_for_ui(
                        ("%s:%d"):format(fsutil.get_relative_path(sym.filepath) or sym.filepath, sym.lnum),
                        fetch_opts.virt_line_width, true)

                    ---@type locate.Picker.Item
                    table.insert(items, {
                        label_chunks = chunks,
                        score        = match.score,
                        virt_line    = { { loc, "LocatePath" } },
                        data         = {
                            filepath = sym.filepath,
                            lnum     = sym.lnum,
                            col      = sym.col,
                        },
                    })
                end
                ::continue::
            end
            callback(items)
        end,
        on_confirm     = function(data)
            if data then ui.smart_open_file(data.filepath, data.lnum, data.col) end
        end,
    }
end

return M
