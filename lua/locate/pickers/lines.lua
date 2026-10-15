local M           = {}

local pickertools = require("locate.base.pickertools")
local rgutil      = require("locate.base.rgutil")
local spawn       = require("locate.util.spawn")
local strutil     = require("locate.util.strutil")
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

---What every row of the picker says about the buffer it came from, as against
---the line it names.
---@class locate.lines.Ctx
---@field bufnr      integer
---@field filepath   string?  the buffer's file, nil for a scratch buffer
---@field lnum_width integer  width of the widest line number, so rows line up

---The prefix every row starts with: the line number, padded to the width of the
---widest one, so the text of every row begins at the same column.
---@param lnum  integer
---@param width integer
---@return {[1]:string,[2]:string}
local function lnum_chunk(lnum, width)
    return { ("%" .. width .. "d "):format(lnum), "LineNr" }
end

---@param ctx    locate.lines.Ctx
---@param lnum   integer
---@param col    integer  0-based byte column to open on, 0 when there is none
---@param chunks {[1]:string,[2]:string?}[]  the line, its matches marked
---@return locate.Picker.Item
local function make_item(ctx, lnum, col, chunks)
    return {
        label_chunks = vim.list_extend({ lnum_chunk(lnum, ctx.lnum_width) }, chunks),
        data         = {
            bufnr    = ctx.bufnr,
            filepath = ctx.filepath,
            lnum     = lnum,
            col      = col,
        },
    }
end

---The buffer as a plain list, for the query that is not one yet: an empty query
---has nothing to match on, so the lines a search could return are listed as they
---stand rather than handed to a ripgrep whose every match would be zero-width.
---@param ctx     locate.lines.Ctx
---@param entries locate.lines.Entry[]
---@return locate.Picker.Item[]
local function browse_items(ctx, entries)
    local items = {}
    for i, entry in ipairs(entries) do
        items[i] = make_item(ctx, entry.lnum, 0, { { entry.text } })
    end
    return items
end

---Search the buffer with ripgrep, the buffer's lines written to its stdin: what
---is searched is the text as it stands, unsaved edits included, and the line
---numbers that come back are the buffer's own, the stream being the lines joined
---back with nothing else added.
---@param prompt_details locate.Picker.PromptDetails
---@param ctx            locate.lines.Ctx
---@param callback       fun(items:locate.Picker.Item[]?)
---@return fun()? cancel
local function search(prompt_details, ctx, callback)
    local lines = vim.api.nvim_buf_get_lines(ctx.bufnr, 0, -1, false)
    local text  = table.concat(lines, "\n") .. "\n"

    local items     = {}
    local stderr    = {} ---@type string[]
    local cancelled = false

    -- rg's output arrives in libuv's read callbacks, which is no place to
    -- measure anything: the rows are built from bytes alone here, and the picker
    -- draws them on the main loop.
    local feed      = strutil.create_line_buffered_feed(function(chunk_lines)
        for _, line in ipairs(chunk_lines) do
            local m = rgutil.parse_match(line)
            if m and m.lnum then
                local shown, subs = rgutil.trim_for_display(m.text, m.subs)
                -- The column to open on is the match's own, in the line as it is
                -- stored: the row is trimmed for display, the buffer is not.
                local col         = m.col - 1
                -- Deliberately unscored, and rg hands its rows over in document
                -- order: a filtered buffer is still read top to bottom, so the
                -- line numbers stay monotonic.
                items[#items + 1] =
                    make_item(ctx, m.lnum, col, rgutil.build_chunks(shown, subs))
            end
        end
    end)

    local function finish()
        if cancelled then return end
        -- A search that failed has no rows of its own, so the list says why
        -- rather than coming up empty and silent. rg's message is folded onto
        -- one row, a list row being one line.
        local merged = {}
        if #stderr > 0 then
            local msg = table.concat(stderr):gsub("%s+", " ")
            ---@type locate.Picker.Item
            merged[1] = {
                label_chunks = { { "ERROR: ", "Error" }, { vim.trim(msg) } },
                data         = {},
            }
        end
        vim.list_extend(merged, items)
        callback(merged)
    end

    local handle, spawn_err = spawn(rgutil.build_cmd(prompt_details, true), {
        stdin  = true,
        stdout = function(data) if not cancelled then feed(data) end end,
        stderr = function(data) stderr[#stderr + 1] = data end,
    }, finish)

    -- A failed spawn reports itself here and still fires the exit callback, so
    -- the error is left to `finish` rather than said here as well.
    if not handle then
        stderr[#stderr + 1] = ("ripgrep (%s): %s"):format(rgutil.exe(), spawn_err or "failed to start")
        return function() cancelled = true end
    end

    handle.write(text)
    handle.write(nil)

    return function()
        cancelled = true
        handle.kill()
    end
end

---@class locate.lines.opts
---@field bufnr integer?

---@param opts locate.lines.opts?
---@return locate.PickerSpec?
function M.spec(opts)
    opts              = opts or {}

    local bufnr       = opts.bufnr or vim.api.nvim_get_current_buf()
    if not vim.api.nvim_buf_is_loaded(bufnr) then
        vim.notify("Buffer is not loaded", vim.log.levels.WARN)
        return nil
    end

    local entries     = collect_lines(bufnr)
    if #entries == 0 then
        vim.notify("Buffer has no non-blank lines", vim.log.levels.WARN)
        return nil
    end

    local name        = vim.api.nvim_buf_get_name(bufnr)
    local cursor_lnum = bufnr == vim.api.nvim_get_current_buf()
        and vim.api.nvim_win_get_cursor(0)[1]
        or nil
    local start_lnum  = initial_lnum(entries, cursor_lnum)

    ---@type locate.lines.Ctx
    local ctx         = {
        bufnr      = bufnr,
        filepath   = name ~= "" and name or nil,
        lnum_width = #tostring(entries[#entries].lnum),
    }

    return {
        prompt         = "Buffer Lines",
        -- There is no tree here to search, so the flags that say what to match
        -- are the whole schema: live_grep's own, shared through rgutil.
        flags          = rgutil.MATCH_FLAGS,
        enable_preview = true,
        previewer      = pickertools.buffer_preview,
        -- Open on the line the cursor is sitting on, so the picker starts where
        -- the reader already is.
        initial_cursor = function(items)
            for row, item in ipairs(items) do
                if item.data.lnum == start_lnum then return row end
            end
        end,
        finder         = function(query, flags, fetch_opts, callback)
            if query == "" then
                callback(browse_items(ctx, entries))
                return
            end
            -- `prompt_details` is what the prompt was read as; without it (a
            -- caller driving the finder directly) the arguments are all there is.
            local prompt_details = fetch_opts.prompt_details
                or { query = query, flags = flags, errors = {} }
            return search(prompt_details, ctx, callback)
        end,
        on_confirm     = function(data)
            if data then ui.smart_open_buffer(data.bufnr, data.lnum, data.col) end
        end,
    }
end

return M
