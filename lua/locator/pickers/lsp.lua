local M                  = {}

local ui                 = require("locator.util.ui")
local pickertools        = require("locator.base.pickertools")
local fsutil             = require("locator.util.fsutil")
local strutil            = require("locator.util.strutil")

local _partial_msg = "LSP busy, results may be incomplete"

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

---True while any of `clients` is still doing background work reported as LSP
---work-done progress. The tokens are chosen by each server (clangd's index,
---rust-analyzer's indexing, gopls' workspace setup, ...), so none of them can
---be matched generically: any unfinished sequence counts as busy. A server
---that reports no progress is indistinguishable from an idle one.
---@param clients (vim.lsp.Client|nil)[]
---@return boolean
local function any_busy(clients)
    for _, client in ipairs(clients) do
        if client and client.progress and next(client.progress.pending) ~= nil then
            return true
        end
    end
    return false
end

---The first row of a result that may be missing entries. Its score pins it
---above every match after ranking, and its data names no position, so
---confirming it does nothing.
---@return locator.Picker.Item
local function partial_item()
    return {
        label_chunks = { { _partial_msg, "WarningMsg" } },
        score        = math.huge,
        data         = {},
    }
end

---Select the first real result, stepping over `partial_item` when it leads, so
---the picker does not open with an inert row under the cursor.
---@param items locator.Picker.Item[]
---@return integer
local function first_match_row(items)
    if items[1] and next(items[1].data) == nil and #items > 1 then
        return 2
    end
    return 1
end

---@type locator.queryflags.FlagDef[]
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
---@type locator.queryflags.FlagDef[]
local SYMBOL_FLAGS = {}
for _, name in ipairs(SYMBOL_KINDS) do
    table.insert(SYMBOL_FLAGS, {
        name = name,
        type = "boolean",
        desc = ("%s symbols"):format(name),
    })
end

---The kinds the kind booleans in `flags` select, as a set, and whether any of
---them was set at all. They are a union: `--Function --Class` keeps both, and
---none set keeps every kind, so the caller has to tell those two apart.
---@param flags table<string, any>
---@return table<string, boolean> kinds
---@return boolean any
local function _selected_kinds(flags)
    local kinds = {}
    local any = false
    for _, name in ipairs(SYMBOL_KINDS) do
        if flags[name] then
            kinds[name] = true
            any = true
        end
    end
    return kinds, any
end

---@class locator.lsp.LocationsOpts
---@field method string LSP request method, e.g. "textDocument/definition"
---@field prompt string
---@field include_declaration boolean? Send `context.includeDeclaration` (references only).
---@field jump_single boolean? Jump straight to the location when the request yields exactly one.
---@field highlight_reference boolean? Highlight the word each location points at in its row.
---@field merge_same_line boolean? Show every location on one line as a single row.

---The byte range of a row's text that a location points at. `ref.text` is the
---untrimmed source line and the label shows it trimmed, so both ends are
---shifted by the leading whitespace that was cut. A range that is empty, that
---points into that whitespace, or that runs onto another line has no word to
---show, and yields nil.
---@param ref vim.quickfix.entry
---@param text string The trimmed line, as the row shows it
---@return integer? start 1-based byte offset
---@return integer? stop 1-based byte offset, inclusive
local function _reference_span(ref, text)
    if not ref.col or not ref.end_col or not ref.text then return nil end
    if ref.end_lnum and ref.lnum and ref.end_lnum ~= ref.lnum then return nil end

    local first = ref.text:find("%S")
    if not first then return nil end
    local start = ref.col - first + 1 -- into the trimmed text
    local stop  = ref.end_col - first -- end_col is one past the last byte
    if stop < start or start < 1 or start > #text then return nil end
    return start, math.min(stop, #text)
end

---Recolour one byte range of a chunk list, splitting the chunks that straddle
---it and leaving everything else as `match_label` styled it.
---@param chunks string[][]
---@param start integer 1-based byte offset of the first byte
---@param stop integer 1-based byte offset of the last byte, inclusive
---@param hl string
---@return string[][]
local function _recolour_range(chunks, start, stop, hl)
    local out, pos = {}, 1
    for _, chunk in ipairs(chunks) do
        local text, chunk_hl = chunk[1], chunk[2]
        local last = pos + #text - 1
        if last < start or pos > stop then
            out[#out + 1] = chunk
        else
            local before_stop = start - pos
            if before_stop > 0 then
                out[#out + 1] = chunk_hl and { text:sub(1, before_stop), chunk_hl } or { text:sub(1, before_stop) }
            end
            local mid_start = math.max(start, pos) - pos + 1
            local mid_stop  = math.min(stop, last) - pos + 1
            out[#out + 1] = { text:sub(mid_start, mid_stop), hl }
            local after_start = math.min(stop, last) - pos + 2
            if after_start <= #text then
                local after = text:sub(after_start)
                out[#out + 1] = chunk_hl and { after, chunk_hl } or { after }
            end
        end
        pos = last + 1
    end
    return out
end

---Collect the locations that point into the same line, so a line holding the
---symbol twice is one row rather than two rows that read alike. Without
---`merge` every location is a group of its own. A location with no line to
---group by never joins another.
---@param refs vim.quickfix.entry[]
---@param merge boolean?
---@return vim.quickfix.entry[][]
local function _group_lines(refs, merge)
    local groups, index = {}, {}
    for _, ref in ipairs(refs) do
        local key
        if merge and ref.filename and ref.lnum then
            key = ref.filename .. "\0" .. ref.lnum
        end
        local group = key and index[key]
        if not group then
            group               = {}
            groups[#groups + 1] = group
            if key then index[key] = group end
        end
        group[#group + 1] = ref
    end
    -- The row confirms at its leftmost location, whatever order the clients
    -- answered in.
    for _, group in ipairs(groups) do
        if #group > 1 then
            table.sort(group, function(a, b) return (a.col or 0) < (b.col or 0) end)
        end
    end
    return groups
end

---definitions, declarations, implementations and type definitions all return
---`Location`, `Location[]` or `LocationLink[]`, so they differ only in the
---method sent and how a single result is treated.
---@param opts locator.lsp.LocationsOpts
---@return locator.PickerSpec
local function locations_spec(opts)
    local params = vim.lsp.util.make_position_params(0, "utf-8")
    if opts.include_declaration then
        ---@diagnostic disable-next-line: inject-field
        params.context = { includeDeclaration = true }
    end

    ---@type locator.PickerSpec
    return {
        prompt         = opts.prompt,
        flags          = REF_FLAGS,
        enable_preview = true,
        setup          = function(callback)
            local action  = opts.method
            local bufnr   = vim.api.nvim_get_current_buf()
            -- Checked at both ends of the round trip: a server that was busy
            -- when asked may still answer from the work it has done so far,
            -- and one that started after the request can answer from a state
            -- still being built.
            local partial = any_busy(vim.lsp.get_clients({ bufnr = bufnr, method = action }))
            vim.lsp.buf_request_all(bufnr, action, params, function(results_per_client)
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
                partial = partial or any_busy(vim.lsp.get_clients({ bufnr = bufnr, method = action }))
                if vim.tbl_isempty(lsp_items) then
                    vim.notify("No " .. opts.prompt .. " found" .. (partial and ". " .. _partial_msg or ""))
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
                callback({ lsp_items = lsp_items, partial = partial })
            end)
        end,
        finder          = function(query, flags, fetch_opts, callback)
            local data         = fetch_opts.data
            local picker_items = {}
            local in_globs     = flags["filter"] or {}
            for _, group in ipairs(_group_lines(data.lsp_items, opts.merge_same_line)) do
                local ref          = group[1]
                local display_path = fsutil.get_relative_path(ref.filename) or ref.filename or ""
                if not pickertools.match_globs(in_globs, display_path, true) then goto continue end

                local text  = ref.text and vim.fn.trim(ref.text) or ""
                local match = pickertools.match_label(text, query)
                if match then
                    local loc = ref.lnum and string.format("%s:%d", display_path, ref.lnum) or display_path
                    loc = strutil.crop_for_ui(loc, fetch_opts.line_width, true)
                    local chunks      = { { loc, "LocatorPath" }, { ": ", "NonText" } }
                    local text_chunks = match.chunks
                    if opts.highlight_reference then
                        for _, occurrence in ipairs(group) do
                            local start, stop = _reference_span(occurrence, text)
                            if start and stop then
                                text_chunks = _recolour_range(text_chunks, start, stop, "LocatorLspReference")
                            end
                        end
                    end
                    vim.list_extend(chunks, text_chunks)
                    ---@type locator.Picker.Item
                    table.insert(picker_items, {
                        label_chunks = chunks,
                        score        = match.score,
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
            -- Inserted after the sort, which compares filepaths the notice
            -- does not have. Its score keeps it above the matches.
            if data.partial then
                table.insert(picker_items, 1, partial_item())
            end
            callback(picker_items, first_match_row(picker_items))
        end,
        on_confirm      = function(data)
            if data and data.filepath then
                ui.smart_open_file(data.filepath, data.lnum, data.col)
            end
        end,
    }
end

---@return locator.PickerSpec
function M.references_spec()
    return locations_spec({
        method              = "textDocument/references",
        prompt              = "LSP References",
        include_declaration = true,
        highlight_reference = true,
        merge_same_line     = true,
    })
end

---@return locator.PickerSpec
function M.definitions_spec()
    return locations_spec({
        method      = "textDocument/definition",
        prompt      = "LSP Definitions",
        jump_single = true,
    })
end

---@return locator.PickerSpec
function M.declarations_spec()
    return locations_spec({
        method      = "textDocument/declaration",
        prompt      = "LSP Declarations",
        jump_single = true,
    })
end

---@return locator.PickerSpec
function M.implementations_spec()
    return locations_spec({
        method      = "textDocument/implementation",
        prompt      = "LSP Implementations",
        jump_single = true,
    })
end

---@return locator.PickerSpec
function M.type_definitions_spec()
    return locations_spec({
        method      = "textDocument/typeDefinition",
        prompt      = "LSP Type Definitions",
        jump_single = true,
    })
end

---One end of a call relationship, flattened out of the protocol's nested
---`CallHierarchyItem` / `fromRanges` shape.
---@class locator.lsp.CallEntry
---@field name string
---@field kind string
---@field filepath string
---@field lnum integer
---@field col integer

---Incoming calls: `call.from` is the caller, and `fromRanges` are the call sites
---*inside* that caller: one entry each, since landing on the call itself is
---the point of asking who calls this.
---@param call table CallHierarchyIncomingCall
---@return locator.lsp.CallEntry[]
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
---@return locator.lsp.CallEntry[]
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

---@class locator.lsp.CallsOpts
---@field method string `callHierarchy/incomingCalls` or `callHierarchy/outgoingCalls`
---@field prompt string
---@field to_entries fun(call:table):locator.lsp.CallEntry[]

---Call hierarchy takes two rounds: `textDocument/prepareCallHierarchy` turns the
---cursor position into an item, and only then can the calls be asked for. The
---item belongs to the client that produced it, so the second request goes back
---to that same client rather than to the buffer at large.
---@param opts locator.lsp.CallsOpts
---@return locator.PickerSpec?
local function calls_spec(opts)
    local bufnr = vim.api.nvim_get_current_buf()

    if vim.tbl_isempty(vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/prepareCallHierarchy" })) then
        vim.notify("No LSP client supports call hierarchy", vim.log.levels.WARN)
        return nil
    end

    local params = vim.lsp.util.make_position_params(0, "utf-8")

    ---@type locator.PickerSpec?
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

                ---@type locator.lsp.CallEntry[]
                local entries   = {}
                local remaining = #targets
                local partial   = false

                -- The clients that answered the prepare step are the ones the
                -- calls are asked of, so they are the ones worth watching.
                for _, target in ipairs(targets) do
                    if any_busy({ target.client }) then partial = true end
                end

                local function finish()
                    if #entries == 0 then
                        vim.notify("No " .. opts.prompt .. " found" .. (partial and ". " .. _partial_msg or ""))
                        callback(nil)
                        return
                    end
                    table.sort(entries, function(a, b)
                        if a.filepath ~= b.filepath then return a.filepath < b.filepath end
                        if a.lnum ~= b.lnum then return a.lnum < b.lnum end
                        return a.col < b.col
                    end)
                    callback({ entries = entries, partial = partial })
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
                            -- A server that only became busy after the prepare
                            -- step still answers from a state being built.
                            if any_busy({ target.client }) then partial = true end
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
                    local loc = strutil.crop_for_ui(
                        ("%s:%d"):format(display_path, entry.lnum), fetch_opts.line_width, true)
                    local chunks = { { loc, "LocatorPath" }, { ": ", "NonText" } }
                    vim.list_extend(chunks, match.chunks)
                    table.insert(chunks, { (" (%s)"):format(entry.kind), "Comment" })

                    ---@type locator.Picker.Item
                    table.insert(items, {
                        label_chunks = chunks,
                        score        = match.score,
                        data         = {
                            filepath = entry.filepath,
                            lnum     = entry.lnum,
                            col      = entry.col,
                        },
                    })
                end
                ::continue::
            end
            if fetch_opts.data.partial then
                table.insert(items, 1, partial_item())
            end
            callback(items, first_match_row(items))
        end,
        on_confirm     = function(data)
            if data and data.filepath then
                ui.smart_open_file(data.filepath, data.lnum, data.col)
            end
        end,
    }
end

---@return locator.PickerSpec?
function M.incoming_calls_spec()
    return calls_spec({
        method     = "callHierarchy/incomingCalls",
        prompt     = "LSP Incoming Calls",
        to_entries = incoming_entries,
    })
end

---@return locator.PickerSpec?
function M.outgoing_calls_spec()
    return calls_spec({
        method     = "callHierarchy/outgoingCalls",
        prompt     = "LSP Outgoing Calls",
        to_entries = outgoing_entries,
    })
end

---@param opts {kinds:string[]?,prompt:string?}?
---@return locator.PickerSpec
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
        setup          = function(callback)
            local partial = any_busy(vim.lsp.get_clients({
                bufnr = 0, method = "textDocument/documentSymbol" }))
            vim.lsp.buf_request(0, "textDocument/documentSymbol", params, function(err, result, ctx)
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

                -- `ctx` names the client whose reply this is.
                local client = ctx and vim.lsp.get_client_by_id(ctx.client_id) or nil
                partial = partial or any_busy({ client })

                if #items == 0 then
                    vim.notify("No symbols found" .. (partial and ". " .. _partial_msg or ""))
                    callback(nil)
                    return
                end
                callback({ items = items, partial = partial })
            end)
        end,
        finder         = function(query, flags, fetch_opts, callback)
            local data = fetch_opts.data
            local flag_kinds, any_kind = _selected_kinds(flags)

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
            if data.partial then
                table.insert(filtered, 1, partial_item())
            end
            local cursor_row = first_match_row(filtered)
            for row, item in ipairs(filtered) do
                if item.data == initial_data then
                    cursor_row = row
                    break
                end
            end
            callback(filtered, cursor_row)
        end,
        on_confirm     = function(data)
            if data and data.lnum then
                vim.api.nvim_win_set_cursor(0, { data.lnum, data.col })
            end
        end,
    }
end

---A workspace symbol as this picker keeps it: flattened out of the LSP reply so
---the finder never has to reach back into the protocol shapes.
---@class locator.lsp.WorkspaceSymbol
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
---@return locator.PickerSpec?
function M.workspace_symbols_spec(opts)
    opts = opts or {}

    if vim.tbl_isempty(vim.lsp.get_clients({ bufnr = 0, method = "workspace/symbol" })) then
        vim.notify("No LSP client supports workspace/symbol", vim.log.levels.WARN)
        return nil
    end

    ---@type locator.PickerSpec?
    return {
        prompt         = "Workspace Symbols",
        flags          = SYMBOL_FLAGS,
        enable_preview = true,
        setup          = function(callback)
            local bufnr   = vim.api.nvim_get_current_buf()
            local params  = { query = opts.query or "" }
            -- Checked at both ends of the round trip; see `locations_spec`.
            local partial = any_busy(vim.lsp.get_clients({ bufnr = bufnr, method = "workspace/symbol" }))
            vim.lsp.buf_request_all(bufnr, "workspace/symbol", params, function(results_per_client)
                ---@type locator.lsp.WorkspaceSymbol[]
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
                partial = partial or any_busy(vim.lsp.get_clients({ bufnr = bufnr, method = "workspace/symbol" }))

                if #symbols == 0 then
                    vim.notify("No workspace symbols found" .. (partial and ". " .. _partial_msg or ""))
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
                callback({ symbols = symbols, partial = partial })
            end)
        end,
        finder         = function(query, flags, fetch_opts, callback)
            local flag_kinds, any_kind = _selected_kinds(flags)

            local items = {}
            for _, sym in ipairs(fetch_opts.data.symbols) do
                if any_kind and not flag_kinds[sym.kind] then goto continue end

                local match = pickertools.match_label(sym.name, query)
                if match then
                    local loc = strutil.crop_for_ui(
                        ("%s:%d"):format(fsutil.get_relative_path(sym.filepath) or sym.filepath, sym.lnum),
                        fetch_opts.line_width, true)
                    local chunks = { { loc, "LocatorPath" }, { ": ", "NonText" } }
                    vim.list_extend(chunks, match.chunks)
                    table.insert(chunks, { (" (%s)"):format(sym.kind), "Comment" })
                    if sym.container and sym.container ~= "" then
                        table.insert(chunks, { "  " .. sym.container, "Comment" })
                    end

                    ---@type locator.Picker.Item
                    table.insert(items, {
                        label_chunks = chunks,
                        score        = match.score,
                        data         = {
                            filepath = sym.filepath,
                            lnum     = sym.lnum,
                            col      = sym.col,
                        },
                    })
                end
                ::continue::
            end
            if fetch_opts.data.partial then
                table.insert(items, 1, partial_item())
            end
            callback(items, first_match_row(items))
        end,
        on_confirm     = function(data)
            if data and data.filepath then
                ui.smart_open_file(data.filepath, data.lnum, data.col)
            end
        end,
    }
end

return M
