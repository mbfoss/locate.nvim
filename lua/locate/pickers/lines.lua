local M           = {}

local pickertools = require("locate.base.pickertools")
local ui          = require("locate.util.ui")

---One matchable line of the buffer: its 1-based number and its text with the
---surrounding whitespace removed, so the query never has to account for indent.
---@class locate.lines.Entry
---@field lnum integer
---@field text string

---@param bufnr integer
---@return locate.lines.Entry[]
local function collect_lines(bufnr)
    local entries = {}
    for lnum, text in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
        -- Blank lines carry nothing to match on and would only pad the list
        -- shown for an empty query.
        if text:match("%S") then
            entries[#entries + 1] = { lnum = lnum, text = vim.trim(text) }
        end
    end
    return entries
end

---The entry the cursor sits on, or the first one below it when the cursor is on
---a blank line, so the picker opens where the user already is.
---@param entries locate.lines.Entry[]
---@param cursor_lnum integer?
---@return integer? lnum
local function initial_lnum(entries, cursor_lnum)
    if not cursor_lnum then return nil end
    local best
    for _, entry in ipairs(entries) do
        best = entry.lnum
        if entry.lnum >= cursor_lnum then break end
    end
    return best
end

---@param opts {bufnr:integer?}?
---@return locate.PickerSpec?
function M.spec(opts)
    opts               = opts or {}

    local bufnr        = opts.bufnr or vim.api.nvim_get_current_buf()
    if not vim.api.nvim_buf_is_loaded(bufnr) then
        vim.notify("Buffer is not loaded", vim.log.levels.WARN)
        return nil
    end

    local entries      = collect_lines(bufnr)
    if #entries == 0 then
        vim.notify("Buffer has no non-blank lines", vim.log.levels.WARN)
        return nil
    end

    local filepath     = vim.api.nvim_buf_get_name(bufnr)
    local cursor_lnum  = bufnr == vim.api.nvim_get_current_buf()
        and vim.api.nvim_win_get_cursor(0)[1]
        or nil
    local start_lnum   = initial_lnum(entries, cursor_lnum)

    -- Width of the widest line number, so the text of every row starts at the
    -- same column.
    local lnum_width   = #tostring(entries[#entries].lnum)

    return {
        prompt         = "Buffer Lines",
        enable_preview = true,
        previewer      = pickertools.buffer_preview,
        -- Open on the line the cursor is sitting on, so the picker starts where
        -- the reader already is.
        initial_cursor = function(items)
            for row, item in ipairs(items) do
                if item.data.lnum == start_lnum then return row end
            end
        end,
        finder         = function(query, _, _, callback)
            local items = {}
            for _, entry in ipairs(entries) do
                local match = pickertools.match_label(entry.text, query)
                if match then
                    local chunks = { { ("%" .. lnum_width .. "d "):format(entry.lnum), "LineNr" } }
                    vim.list_extend(chunks, match.chunks)
                    ---@type locate.Picker.Item
                    -- Deliberately unscored: a filtered buffer is still read top
                    -- to bottom, so rows keep document order and the line-number
                    -- column stays monotonic.
                    table.insert(items, {
                        label_chunks = chunks,
                        data         = {
                            bufnr    = bufnr,
                            filepath = filepath ~= "" and filepath or nil,
                            lnum     = entry.lnum,
                            col      = 0,
                        },
                    })
                end
            end
            callback(items)
        end,
        on_confirm     = function(data)
            if data then ui.smart_open_buffer(data.bufnr, data.lnum, data.col) end
        end,
    }
end

return M
