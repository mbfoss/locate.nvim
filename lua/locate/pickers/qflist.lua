local M            = {}

local pickertools  = require("locate.base.pickertools")
local fsutil       = require("locate.util.fsutil")
local ui           = require("locate.util.ui")

---@type locate.queryflags.FlagDef[]
local FLAGS        = {
    { name = "errors",   type = "boolean", desc = "show error items" },
    { name = "warnings", type = "boolean", desc = "show warning items" },
    { name = "info",     type = "boolean", desc = "show info items" },
    { name = "hints",    type = "boolean", desc = "show hint items" },
    { name = "filter",   type = "value",   multi = true, slot = "glob",                  desc = "glob filter: *.txt, **/dir/**" },
    { name = "valid",    type = "boolean", desc = "only items with a resolved location" },
}

-- Boolean type flags onto the qf `type` code they select. Several may be
-- combined; together they act as a union.
local _type_flags  = {
    errors   = "E",
    warnings = "W",
    info     = "I",
    hints    = "N",
}

---@alias locate.qflist_filter 'all'|"errors"|"warnings"|"info"
---@alias locate.qflist_type 'quickfix'|"loclist"

local _type_prefix = {
    E = { "󰅚 ", "DiagnosticError" },
    W = { "󰀪 ", "DiagnosticWarn" },
    I = { "󰋽 ", "DiagnosticInfo" },
    N = { "󰌶 ", "DiagnosticHint" },
}

---@param qf any
---@param filter locate.qflist_filter
---@return boolean
local function matches_filter(qf, filter)
    if filter == "all" or not filter then return true end
    local t = (qf.type or ""):upper()
    if filter == "errors" then return t == "E" or t == "" end
    if filter == "warnings" then return t == "W" end
    if filter == "info" then return t == "I" end
    return true
end

---@param item table
---@param rendered_text string?
---@return {filepath:string,relpath:string,filename:string,dir:string,lnum:number,col:number,bufnr:number,type:string,text:string,valid:boolean,qfidx:number}?
local function read_qf_item(item, rendered_text)
    local bufnr = item.bufnr
    if not bufnr or bufnr == 0 or not vim.api.nvim_buf_is_valid(bufnr) then return nil end
    local filepath = vim.api.nvim_buf_get_name(bufnr)
    local relpath  = fsutil.get_relative_path(filepath) or filepath
    return {
        bufnr    = bufnr,
        filepath = filepath,
        relpath  = relpath,
        filename = vim.fn.fnamemodify(relpath, ":t"):lower(),
        dir      = vim.fn.fnamemodify(relpath, ":h"):lower(),
        lnum     = item.lnum,
        col      = item.col > 0 and item.col - 1 or 0,
        type     = (item.type or ""):upper(),
        text     = rendered_text or item.text or "",
        valid    = item.valid == 1 and item.lnum and item.lnum > 0,
    }
end

-- Lists can customize their displayed label via the 'quickfixtextfunc' list-property
-- (:h quickfix-window-function); the native window renders through it, but `item.text`
-- from get{qf,loc}list() is raw. Render through it here too so pickers match the native label.
---@param list_type locate.qflist_type
---@param winid integer
---@param list table[]
---@return string[]? rendered_lines indexed 1..#list
local function render_qftf(list_type, winid, list)
    local is_loclist = list_type == "loclist"
    local get        = is_loclist
        and function(what) return vim.fn.getloclist(winid, what) end
        or function(what) return vim.fn.getqflist(what) end
    local qftf       = get({ quickfixtextfunc = 1 }).quickfixtextfunc
    if not qftf or qftf == "" then return nil end
    local id = get({ id = 0 }).id
    local ok, lines = pcall(vim.fn.call, qftf, { {
        quickfix  = is_loclist and 0 or 1,
        winid     = winid,
        id        = id,
        start_idx = 1,
        end_idx   = #list,
    } })
    if ok and type(lines) == "table" then return lines end
    return nil
end

---@param list_type locate.qflist_type
---@param winid integer
---@return table[], integer, string[]?
local function get_list(list_type, winid)
    local list, idx
    if list_type == "loclist" then
        list, idx = vim.fn.getloclist(winid), vim.fn.getloclist(winid, { idx = 0 }).idx
    else
        list, idx = vim.fn.getqflist(), vim.fn.getqflist({ idx = 0 }).idx
    end
    return list, idx, render_qftf(list_type, winid, list)
end

---@param opts {filter:locate.qflist_filter?, list_type:locate.qflist_type?, winid:integer?}?
---@return locate.PickerSpec?
function M.spec(opts)
    opts                                = opts or {}
    local filter                        = opts.filter or "all"
    local list_type                     = opts.list_type or "quickfix"
    local winid                         = opts.winid or vim.fn.win_getid()
    local is_loclist                    = list_type == "loclist"
    local qflist, current_idx, rendered = get_list(list_type, winid)
    local list_label                    = is_loclist and "Location List" or "Quickfix"

    local entries                       = {}
    for idx, qf in ipairs(qflist) do
        if matches_filter(qf, filter) then
            local data = read_qf_item(qf, rendered and rendered[idx])
            if data then
                data.qfidx = idx
                table.insert(entries, data)
            end
        end
    end

    if vim.tbl_isempty(entries) then
        if filter == "all" then
            vim.notify(("%s is empty"):format(list_label), vim.log.levels.WARN)
        else
            vim.notify(("No %s in %s"):format(filter, list_label), vim.log.levels.WARN)
        end
        return nil
    end

    ---@type locate.PickerSpec
    return {
        prompt             = list_label .. " Items",
        flags              = FLAGS,
        enable_preview     = true,
        -- Open on the entry the list is parked at, the one :cc would jump to.
        initial_cursor     = function(items)
            for row, item in ipairs(items) do
                if item.data.qfidx == current_idx then return row end
            end
        end,
        finder             = function(query, flags, _, callback)
            local items = {}
            for _, data in ipairs(entries) do
                if flags.valid and not data.valid then goto continue end

                local skip     = false
                local any_type = false
                local matched  = false
                for flag, code in pairs(_type_flags) do
                    if flags[flag] then
                        any_type = true
                        if data.type == code then matched = true end
                    end
                end
                if any_type and not matched then skip = true end
                local in_globs = flags["filter"] or {}
                if not skip and not pickertools.match_globs(in_globs, data.relpath, true) then
                    skip = true
                end
                if skip then goto continue end

                local loc = nil
                if data.relpath and #data.relpath > 0 then
                    if data.lnum > 0 then
                        if data.col > 0 then
                            loc = string.format("%s:%d:%d", data.relpath, data.lnum, data.col)
                        else
                            loc = string.format("%s:%d", data.relpath, data.lnum)
                        end
                    else
                        loc = data.relpath
                    end
                end
                ---@type string?
                local text = (data.text and data.text ~= "") and vim.trim(data.text) or nil
                if not text or #text == "" then
                    text, loc = loc, nil
                end
                -- Deliberately unscored: the order of a quickfix list is the
                -- compiler's or the search's, and reordering it would lose the
                -- sequence the user is working through.
                local match = text and pickertools.match_label(text, query) or nil
                if match then
                    local chunks = { _type_prefix[data.type] or _type_prefix.N }
                    vim.list_extend(chunks, match.chunks)
                    ---@type locate.Picker.Item
                    table.insert(items, {
                        label_chunks = chunks,
                        virt_line    = loc and { { loc, "LocatePath" } } or nil,
                        data         = data,
                    })
                end
                ::continue::
            end
            callback(items)
        end,
        quickfix_formatter = function(data)
            return data
        end,
        on_confirm         = function(data)
            if not data then return end
            -- Keep the list's current index in sync (what :cc/:ll would do) so
            -- :cnext/:cprev continue from the picked item, then jump ourselves.
            if is_loclist then
                vim.fn.setloclist(winid, {}, "r", { idx = data.qfidx })
            else
                vim.fn.setqflist({}, "r", { idx = data.qfidx })
            end
            ui.smart_open_file(data.filepath, data.lnum, data.col)
        end,
    }
end

return M
