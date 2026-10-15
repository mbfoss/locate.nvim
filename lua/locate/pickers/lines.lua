local M           = {}

local bufloader   = require("locate.util.bufloader")
local pickertools = require("locate.base.pickertools")
local rgutil      = require("locate.base.rgutil")
local spawn       = require("locate.util.spawn")
local strutil     = require("locate.util.strutil")
local ui          = require("locate.util.ui")

---The most rows the picker builds, the cap `files` and `live_grep` put on their
---own walks. A list past this is no better to read, and every row is memory.
local DEFAULT_MAX_RESULTS = 10000

---What every row of the picker says about the buffer it came from, as against
---the line it names: enough to search it, and to open a row where it points.
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

---Search the buffer with ripgrep, the buffer's lines written to its stdin: what
---is searched is the text as it stands, unsaved edits included, and the line
---numbers that come back are the buffer's own, the stream being the lines joined
---back with nothing else added. The lines are read and written a chunk at a
---time, so a very large buffer never holds the UI.
---@param prompt_details locate.Picker.PromptDetails
---@param ctx            locate.lines.Ctx
---@param max_results    integer  the most rows to build
---@param callback       fun(items:locate.Picker.Item[]?)
---@return fun()? cancel
local function search(prompt_details, ctx, max_results, callback)
    local items     = {}
    local stderr    = {} ---@type string[]
    local cancelled = false
    local stopped   = false  -- enough rows: rg was ended on purpose
    local read_err  ---@type string?  set when the read failed partway through
    local handle    ---@type locate.util.SpawnHandle?
    local loader    ---@type locate.util.bufloader.Read?

    -- Whatever is in flight is of no more use: the buffer stops being streamed
    -- and rg is asked to end, its exit being what settles the picker.
    local function stop()
        stopped = true
        if loader then loader.cancel() end
        if handle then handle.kill() end
    end

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
                -- Past this the list is one nobody reads, so the search ends
                -- here rather than building every match of a huge buffer.
                if #items >= max_results then
                    stop()
                    return
                end
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

    local spawn_err
    handle, spawn_err = spawn(rgutil.build_cmd(prompt_details, true), {
        stdin  = true,
        stdout = function(data)
            if not cancelled and not stopped and not read_err then feed(data) end
        end,
        stderr = function(data) stderr[#stderr + 1] = data end,
    }, finish)

    -- A failed spawn reports itself here and still fires the exit callback, so
    -- the error is left to `finish` rather than said here as well.
    if not handle then
        stderr[#stderr + 1] = ("ripgrep (%s): %s"):format(rgutil.exe(), spawn_err or "failed to start")
        return function() cancelled = true end
    end

    -- The buffer is pumped into rg's stdin a chunk at a time, on the main loop
    -- and with a turn given back to it between chunks.
    loader = bufloader.load(ctx.bufnr, {}, {
        on_chunk = function(lines)
            handle.write(table.concat(lines, "\n") .. "\n")
        end,
        on_done  = function() handle.write(nil) end,
        on_error = function(err)
            -- Half a buffer is not the text that was asked to be searched, so
            -- what rg has reported is dropped (`feed` shares `items`) and the
            -- reason is left to `finish`; EOF lets rg end on its own.
            read_err            = err
            items               = {}
            stderr[#stderr + 1] = err
            handle.write(nil)
        end,
    })

    return function()
        cancelled = true
        stop()
    end
end

---@class locate.lines.opts
---@field bufnr       integer?
---@field max_results integer?  the most rows to build (default 10000)

---@param opts locate.lines.opts?
---@return locate.PickerSpec?
function M.spec(opts)
    opts = opts or {}

    local max_results = opts.max_results or DEFAULT_MAX_RESULTS

    -- Resolve 0 the way the rest of the API does: the buffer it names is the
    -- current one.
    local bufnr       = opts.bufnr or vim.api.nvim_get_current_buf()
    if bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
    if not vim.api.nvim_buf_is_loaded(bufnr) then
        vim.notify("Buffer is not loaded", vim.log.levels.WARN)
        return nil
    end

    local name = vim.api.nvim_buf_get_name(bufnr)

    ---@type locate.lines.Ctx
    local ctx = {
        bufnr      = bufnr,
        filepath   = name ~= "" and name or nil,
        -- Rows are numbered as the buffer numbers its lines, so the width comes
        -- from the buffer's own line count rather than from any one result set.
        lnum_width = #tostring(vim.api.nvim_buf_line_count(bufnr)),
    }

    return {
        prompt         = "Buffer Lines",
        -- There is no tree here to search, so the flags that say what to match
        -- are the whole schema: live_grep's own, shared through rgutil.
        flags          = rgutil.MATCH_FLAGS,
        enable_preview = true,
        previewer      = pickertools.buffer_preview,
        finder         = function(query, flags, fetch_opts, callback)
            -- A query is what is searched for: with none there is nothing to
            -- match on, so the list stays empty rather than listing the buffer.
            if not query or query == "" then
                callback()
                return
            end
            -- `prompt_details` is what the prompt was read as; without it (a
            -- caller driving the finder directly) the arguments are all there is.
            local prompt_details = fetch_opts.prompt_details
                or { query = query, flags = flags, errors = {} }
            return search(prompt_details, ctx, max_results, callback)
        end,
        on_confirm     = function(data)
            if data then ui.smart_open_buffer(data.bufnr, data.lnum, data.col) end
        end,
    }
end

return M
