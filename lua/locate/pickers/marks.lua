local M           = {}

local pickertools = require("locate.base.pickertools")
local ui          = require("locate.util.ui")
local fsutil      = require("locate.util.fsutil")
local strutil     = require("locate.util.strutil")

---@type locate.queryflags.FlagDef[]
local FLAGS       = {
    { name = "global", type = "boolean", desc = "only global (A-Z, 0-9) marks" },
    { name = "buffer", type = "boolean", desc = "only marks local to this buffer" },
}

---@class locate.marks.Entry
---@field mark string      mark name without its leading quote, e.g. "a", "A", "^"
---@field is_global boolean
---@field bufnr integer?   the buffer holding the mark, when one is loaded
---@field filepath string?
---@field lnum integer
---@field col integer      0-based
---@field text string?     the marked line, when its buffer is loaded

---@param bufnr integer?
---@param lnum integer
---@return string?
local function line_text(bufnr, lnum)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return nil end
    if not vim.api.nvim_buf_is_loaded(bufnr) then return nil end
    local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
    if not line or not line:match("%S") then return nil end
    return vim.trim(line)
end

---Both mark lists report `[bufnr, lnum, col, off]` positions with a 1-based
---column; global entries name their file while buffer-local ones only carry the
---buffer they were read from.
---@param current_buf integer
---@return locate.marks.Entry[]
local function collect_marks(current_buf)
    local entries = {}

    ---@param list table[]
    ---@param is_global boolean
    local function add_all(list, is_global)
        for _, mark in ipairs(list) do
            local lnum = mark.pos[2]
            if lnum and lnum > 0 then
                local bufnr = is_global and (mark.pos[1] ~= 0 and mark.pos[1] or nil) or current_buf
                local filepath
                if mark.file and mark.file ~= "" then
                    filepath = vim.fn.fnamemodify(mark.file, ":p")
                elseif bufnr then
                    local name = vim.api.nvim_buf_get_name(bufnr)
                    filepath   = name ~= "" and name or nil
                end
                ---@type locate.marks.Entry
                entries[#entries + 1] = {
                    mark      = mark.mark:sub(2),
                    is_global = is_global,
                    bufnr     = bufnr,
                    filepath  = filepath,
                    lnum      = lnum,
                    col       = math.max(0, (mark.pos[3] or 1) - 1),
                    text      = line_text(bufnr, lnum),
                }
            end
        end
    end

    add_all(vim.fn.getmarklist(current_buf), false)
    add_all(vim.fn.getmarklist(), true)

    table.sort(entries, function(a, b)
        if a.is_global ~= b.is_global then return not a.is_global end
        return a.mark < b.mark
    end)
    return entries
end

---@return locate.PickerSpec?
function M.spec()
    local current_buf = vim.api.nvim_get_current_buf()
    local entries     = collect_marks(current_buf)

    if #entries == 0 then
        vim.notify("No marks set", vim.log.levels.WARN)
        return nil
    end

    ---@type locate.PickerSpec?
    return {
        prompt         = "Marks",
        flags          = FLAGS,
        enable_preview = true,
        previewer      = pickertools.buffer_preview,
        finder         = function(query, flags, fetch_opts, callback)
            local items = {}
            for _, entry in ipairs(entries) do
                if flags.global and not entry.is_global then goto continue end
                if flags.buffer and entry.is_global then goto continue end

                local relpath = entry.filepath
                    and (fsutil.get_relative_path(entry.filepath) or entry.filepath)
                    or nil
                -- The marked line is what identifies a mark; without a loaded
                -- buffer to read it from, its file has to stand in.
                local label   = entry.text or relpath or "[No Name]"
                local match   = pickertools.match_label(label, query)
                if match then
                    local chunks = { { ("'%s "):format(entry.mark), "Special" } }
                    vim.list_extend(chunks, match.chunks)

                    local loc = ("%s:%d:%d"):format(relpath or "[No Name]", entry.lnum, entry.col)
                    ---@type locate.Picker.Item
                    -- Deliberately unscored: marks are found by their letter, and
                    -- the sort above groups them the way that letter is read.
                    table.insert(items, {
                        label_chunks = chunks,
                        virt_line    = { { strutil.crop_for_ui(loc, fetch_opts.virt_line_width, true), "LocatePath" } },
                        data         = {
                            bufnr    = entry.bufnr,
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
            if not data then return end
            if data.bufnr and vim.api.nvim_buf_is_valid(data.bufnr) then
                ui.smart_open_buffer(data.bufnr, data.lnum, data.col)
            else
                ui.smart_open_file(data.filepath, data.lnum, data.col)
            end
        end,
    }
end

return M
