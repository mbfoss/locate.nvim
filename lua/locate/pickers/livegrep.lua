local M                = {}

local ui               = require("locate.util.ui")
local strutil          = require("locate.util.strutil")
local fsutil           = require("locate.util.fsutil")
local bufloader        = require("locate.util.bufloader")
local spawn            = require("locate.util.spawn")
local pickertools      = require("locate.base.pickertools")
local rgutil           = require("locate.base.rgutil")

--- High-water mark (bytes) for stdin backpressure: buffers are fed to rg ahead
--- of itself for throughput, but once its stdin write queue is backed up past
--- this we wait for it to drain before pushing more, so buffered memory stays
--- bounded even with very large or very many open buffers.
local _MAX_WRITE_QUEUE = 1024 * 1024

---@class locate.livegrep.opts
---@field max_results number?

---@class locate.livegrep.grep_opts
---@field cwd         string
---@field max_results number?

---What to search: the flags only a tree has any use for. Kept apart from
---rgutil's, so a search with no tree to walk takes those alone.
---@type locate.queryflags.FlagDef[]
local TARGET_FLAGS = {
    { name = "buffers",   type = "boolean", desc = "search only the loaded buffers" },
    { name = "dir",       type = "value",   complete = "dir", slot = "path", desc = "search root directory" },
    { name = "filter",    type = "value",   multi = true,     slot = "glob", desc = "glob filter: *.txt, !*.lua, **/dir/**" },
    { name = "type",      type = "value",   multi = true,     slot = "name", complete = rgutil.complete_type, desc = "rg file type: lua, rust, !md (see rg --type-list)" },
}

---How to walk it: the flags rg's own traversal reads.
---@type locate.queryflags.FlagDef[]
local WALK_FLAGS = {
    { name = "follow",    type = "boolean", desc = "follow symlinks" },
    { name = "hidden",    type = "boolean", desc = "include hidden (dotfiles)" },
    { name = "no-ignore", type = "boolean", desc = "disable .gitignore / .ignore rules" },
    { name = "max-depth", type = "value",   slot = "n", desc = "max directory depth to descend" },
}

--- The schema the picker offers, in the order the flags read: where to search,
--- then what to match there, then how to walk it.
---@type locate.queryflags.FlagDef[]
local FLAGS = {}
vim.list_extend(FLAGS, TARGET_FLAGS)
vim.list_extend(FLAGS, rgutil.MATCH_FLAGS)
vim.list_extend(FLAGS, WALK_FLAGS)

--- Directory search. Disk matches for files that are open in a buffer are
--- dropped by the caller (post-filter) so their in-memory versions take
--- priority: cheaper and more robust than emitting a glob per open file.
---@param prompt_details locate.Picker.PromptDetails
---@return string[] cmd
local function build_rg_dir_cmd(prompt_details)
    local flags = prompt_details.flags
    local args  = rgutil.build_cmd(prompt_details)

    -- A walk is the only thing here with anything to follow, hide or ignore.
    if flags.follow then
        table.insert(args, "--follow")
    end

    if flags.hidden then
        table.insert(args, "--hidden")
    end

    if flags["no-ignore"] then
        table.insert(args, "--no-ignore")
    end

    table.insert(args, "--sort")
    table.insert(args, "path")
    for _, g in ipairs(flags["filter"] or {}) do
        table.insert(args, "-g")
        table.insert(args, g)
    end
    for _, t in ipairs(flags["type"] or {}) do
        if t:sub(1, 1) == "!" then
            table.insert(args, "--type-not")
            table.insert(args, t:sub(2))
        else
            table.insert(args, "--type")
            table.insert(args, t)
        end
    end
    local depth = tonumber(flags["max-depth"])
    if depth then
        table.insert(args, "--max-depth")
        table.insert(args, tostring(math.floor(depth)))
    end
    table.insert(args, "--")
    table.insert(args, prompt_details.query)
    table.insert(args, ".")
    return args
end

--- Compile a glob list, dropping any that fail (the prompt is compiled on every
--- keystroke, so half-typed globs are expected). nil when nothing compiled, so
--- a transient bad glob does not filter everything out.
---@param globs string[]
---@return vim.regex[]?
local function compile_globs(globs)
    local out = {}
    for _, g in ipairs(globs) do
        local re = strutil.compile_glob(g)
        if re then out[#out + 1] = re end
    end
    return #out > 0 and out or nil
end

--- Split a flag-glob list ("*.lua", "!*_spec.lua") into compiled include/exclude
--- regexes. rg's own `-g` only filters disk traversal, not stdin input, so open
--- buffers are filtered in-process instead.
---@param filters string[]?
---@return vim.regex[]? include, vim.regex[]? exclude
local function compile_filter_globs(filters)
    local include, exclude = {}, {}
    for _, g in ipairs(filters or {}) do
        if g:sub(1, 1) == "!" then
            exclude[#exclude + 1] = g:sub(2)
        else
            include[#include + 1] = g
        end
    end
    return compile_globs(include), compile_globs(exclude)
end

--- Same idea for `--type`: rg's own `-t` filters files it walks, not stdin, so
--- the type globs are expanded here and matched against each buffer's basename
--- (rg matches a slashless type glob the same way).
---@param types string[]?
---@return vim.regex[]? include, vim.regex[]? exclude
local function compile_type_globs(types)
    if not types or #types == 0 then return nil, nil end

    local known = rgutil.types()
    local include, exclude = {}, {}
    for _, t in ipairs(types) do
        local negated = t:sub(1, 1) == "!"
        local name    = negated and t:sub(2) or t
        local target  = negated and exclude or include
        for _, g in ipairs(known[name] or {}) do
            target[#target + 1] = g
        end
    end
    return compile_globs(include), compile_globs(exclude)
end

---@class locate.livegrep.OpenBuf
---@field bufnr   integer
---@field path    string  absolute file path
---@field relpath string  path relative to the search cwd

--- Loaded, file-backed buffers under `cwd` that pass the filter globs. These are
--- searched from their in-memory text so unsaved (and stale-on-disk) edits win.
---@param cwd       string
---@param filters   string[]?
---@param types     string[]?
---@param max_depth number?  -- directory depth limit, mirroring rg's --max-depth
---@return locate.livegrep.OpenBuf[]
local function collect_open_buffers(cwd, filters, types, max_depth)
    local include_re, exclude_re = compile_filter_globs(filters)
    local type_include, type_exclude = compile_type_globs(types)
    local out = {}
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buftype == "" then
            local name = vim.api.nvim_buf_get_name(bufnr)
            if name ~= "" then
                local path = vim.fn.fnamemodify(name, ":p")
                local rel  = fsutil.get_relative_path(path, cwd)
                local base = rel and vim.fs.basename(rel) or ""
                if rel
                    and strutil.check_path_pattern(rel, false, include_re, exclude_re)
                    and strutil.check_path_pattern(base, false, type_include, type_exclude)
                    and (not max_depth or select(2, rel:gsub("/", "")) < max_depth)
                then
                    out[#out + 1] = { bufnr = bufnr, path = path, relpath = rel }
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.relpath < b.relpath end)
    return out
end

--- Marker prefixed to the location line for matches sourced from an open
--- buffer's in-memory text rather than the on-disk file.
local _BUFFER_INDICATOR = "≡ "
local _BUFFER_INDICATOR_WIDTH = vim.fn.strdisplaywidth(_BUFFER_INDICATOR)

--- Build a picker item from a parsed rg match at an absolute path.
---@param m           locate.rgutil.Match
---@param abs_path    string
---@param cwd         string
---@param path_width  integer
---@param rel_path    string?  precomputed cwd-relative path (avoids recomputation)
---@param from_buffer boolean?  match came from an open buffer, not disk
---@return locate.Picker.Item
local function make_item(m, abs_path, cwd, path_width, rel_path, from_buffer)
    rel_path = rel_path or fsutil.get_relative_path(abs_path, cwd) or abs_path
    local indicator_width = from_buffer and _BUFFER_INDICATOR_WIDTH or 0
    local location = strutil.crop_for_ui(
        string.format("%s:%s", rel_path, m.lnum),
        path_width - indicator_width, true
    )
    local virt_line = {}
    if from_buffer then
        virt_line[#virt_line + 1] = { _BUFFER_INDICATOR, "LocatePickerBufferIndicator" }
    end
    virt_line[#virt_line + 1] = { location, "LocatePickerPath" }
    local shown_text, shown_subs = rgutil.trim_for_display(m.text, m.subs)
    return {
        label_chunks = rgutil.build_chunks(shown_text, shown_subs),
        virt_line    = virt_line,
        data         = { filepath = abs_path, lnum = m.lnum, col = m.col, subs = m.subs },
    }
end

--- A parsed match held until it can be turned into an item on the main loop.
---@class locate.livegrep.Record
---@field m           locate.rgutil.Match
---@field abs_path    string
---@field rel_path    string?
---@field from_buffer boolean?

---@param filepath string  absolute path
---@return integer? bufnr  a loaded buffer holding this exact file, if any
local function loaded_buf_for(filepath)
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr)
            and vim.api.nvim_buf_get_name(bufnr) == filepath then
            return bufnr
        end
    end
end

--- Preview the live buffer when the file is open, so the preview matches the
--- (possibly modified or stale-on-disk) text the result list was built from.
--- Falls back to the on-disk previewer for files with no open buffer.
---@type locate.Picker.AsyncPreviewLoader
local function buffer_preview(data, opts, callback)
    local filepath = data.filepath
    if filepath and filepath ~= "" then
        local bufnr = loaded_buf_for(filepath)
        if bufnr then
            callback({
                bufnr = bufnr,
                pos   = data.lnum and { data.lnum, data.col or 0 } or nil,
            })
            return
        end
    end
    return pickertools.file_preview(data, opts, callback)
end

--------------------------------------------------------------------------------
-- In-buffer search (single rg over stdin): every open buffer's in-memory text is
-- concatenated into one stdin doc streamed to `rg -` (unsaved edits win; N buffers
-- cost one subprocess), and the continuous line counter is mapped back per buffer.
--------------------------------------------------------------------------------

--- Precompute where each buffer begins in the concatenated stdin stream:
--- `starts[i]` is the 1-based line number of `bufs[i]`'s first line, `ticks[i]`
--- the buffer revision it was measured from. Buffers are newline-joined and
--- newline-separated, and Neovim buffer lines never contain a newline, so the
--- stream's line counter is exact and matches never straddle a buffer boundary
--- (the search is line-oriented).
---@param bufs locate.livegrep.OpenBuf[]
---@return integer[] starts, integer[] ticks
local function buffer_line_offsets(bufs)
    local starts    = {}
    local ticks     = {}
    local next_line = 1
    for i, b in ipairs(bufs) do
        starts[i] = next_line
        -- The offsets describe the text as it is right now, so each read is
        -- pinned to the revision they were measured from.
        ticks[i]  = vim.api.nvim_buf_get_changedtick(b.bufnr)
        next_line = next_line + vim.api.nvim_buf_line_count(b.bufnr)
    end
    return starts, ticks
end

--- Map a 1-based stream line back to its buffer: the largest `starts[i] <= gline`.
---@param starts integer[]  ascending buffer start lines
---@param gline  integer    1-based line in the concatenated stream
---@return integer buf_index, integer local_lnum
local function locate_line(starts, gline)
    local lo, hi = 1, #starts
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if starts[mid] <= gline then lo = mid else hi = mid - 1 end
    end
    return lo, gline - starts[lo] + 1
end

---@param prompt_details locate.Picker.PromptDetails
---@param grep_opts      locate.livegrep.grep_opts
---@param fetch_opts     locate.Picker.FetcherOpts
---@param callback       fun(items:table[]?)
---@return fun()? cancel
local function async_grep(prompt_details, grep_opts, fetch_opts, callback)
    if prompt_details.query == "" then
        callback()
        return
    end

    local max_results   = grep_opts.max_results or 10000
    local cwd           = grep_opts.cwd
    local path_width    = fetch_opts.virt_line_width
    -- `buffers` leaves the directory half unrun: what is open is the whole
    -- search, and the flags that narrow the open buffers still apply to it.
    local only_buffers  = prompt_details.flags["buffers"] == true

    -- Open buffers take priority: search their in-memory text, then drop the
    -- on-disk matches for those same files so stale disk content never wins.
    local bufs          = collect_open_buffers(
        cwd,
        prompt_details.flags["filter"],
        prompt_details.flags["type"],
        tonumber(prompt_details.flags["max-depth"])
    )
    local open_relpaths = {} ---@type table<string, true>
    for _, b in ipairs(bufs) do
        open_relpaths[b.relpath] = true
    end

    local cancelled = false
    local buf_recs  = {} ---@type locate.livegrep.Record[]
    local dir_recs  = {} ---@type locate.livegrep.Record[]
    local errors    = {} ---@type string[]
    local buf_handle ---@type locate.util.SpawnHandle?
    local dir_handle ---@type locate.util.SpawnHandle?
    local buf_loader ---@type locate.util.bufloader.Read?  the buffer being streamed to stdin
    local buf_err    ---@type string?  why the in-buffer ripgrep did not start

    ---Whatever the picker started, stopped: called once when the query changes
    ---or the picker closes, with either half possibly never having been run.
    local function cancel()
        cancelled = true
        if buf_loader then buf_loader.cancel() end
        if buf_handle then buf_handle.kill() end
        if dir_handle then dir_handle.kill() end
    end

    -- Both searches run as async rg jobs; finish() fires once both have settled,
    -- with buffer matches leading the merged list.
    --
    -- rg's output is parsed inside libuv's read callbacks, which may not measure
    -- display width (nvim_strwidth is not fast-context safe), so those only
    -- record parsed matches. Items are built here instead: finish() runs on the
    -- main loop (spawn schedules its exit callback), and costs one pass over the
    -- kept records rather than a schedule per chunk.
    local pending   = only_buffers and 1 or 2
    local function finish()
        if cancelled then return end
        local recs = {}
        vim.list_extend(recs, buf_recs)
        vim.list_extend(recs, dir_recs)
        for i = #recs, max_results + 1, -1 do
            recs[i] = nil
        end

        local merged = {}
        for _, msg in ipairs(errors) do
            ---@type locate.Picker.Item
            merged[#merged + 1] = {
                label_chunks = { { "ERROR: ", "Error" }, { msg } },
                data         = {},
            }
        end
        for _, r in ipairs(recs) do
            merged[#merged + 1] =
                make_item(r.m, r.abs_path, cwd, path_width, r.rel_path, r.from_buffer)
        end
        callback(merged)
    end
    local function settle()
        if cancelled then return end
        pending = pending - 1
        if pending == 0 then finish() end
    end

    ----------------------------------------------------------------------------
    -- In-buffer search: one rg reading every open buffer's in-memory text from stdin.
    -- Buffers are pumped one at a time, a chunk of lines at a time and with backpressure
    -- (peak extra memory ~one chunk), and each match's stream line is mapped back to the
    -- buffer it came from.
    ----------------------------------------------------------------------------
    if #bufs == 0 then
        settle()
    else
        local starts, ticks = buffer_line_offsets(bufs)
        local stop_buf      = false
        local buf_done      = false
        local buf_count     = 0

        local buf_feed      = strutil.create_line_buffered_feed(function(lines)
            for _, line in ipairs(lines) do
                if stop_buf then return end
                local m = rgutil.parse_match(line)
                if m and m.lnum then
                    local idx, lnum = locate_line(starts, m.lnum)
                    local b = bufs[idx]
                    if b then
                        m.lnum = lnum
                        m.path = b.path
                        buf_recs[#buf_recs + 1] = {
                            m           = m,
                            abs_path    = b.path,
                            rel_path    = b.relpath,
                            from_buffer = true,
                        }
                        buf_count = buf_count + 1
                        if buf_count >= max_results then
                            stop_buf = true
                            if buf_loader then buf_loader.cancel() end
                            if buf_handle then buf_handle.kill() end
                            return
                        end
                    end
                end
            end
        end)

        -- Hand one buffer to rg's stdin a chunk at a time. The lines are read on
        -- the main loop and the read gives the loop a turn between chunks, so no
        -- single buffer holds the UI; once rg's stdin backs up past the high-water
        -- mark the read parks until that write drains.
        local function pump(i)
            if cancelled or stop_buf or buf_done then return end
            if i > #bufs then
                if buf_handle then buf_handle.write(nil) end
                return
            end
            if not buf_handle then return end

            -- `read` is declared before the call so `on_chunk` can resume the
            -- read it belongs to; `buf_loader` is how a cancel reaches it.
            local read ---@type locate.util.bufloader.Read
            read       = bufloader.load(bufs[i].bufnr, { tick = ticks[i] }, {
                on_chunk = function(lines)
                    if cancelled or stop_buf then return false end
                    local chunk = table.concat(lines, "\n") .. "\n"
                    if buf_handle.get_write_queue_size() >= _MAX_WRITE_QUEUE then
                        -- Park rather than queue a whole buffer ahead of rg; the
                        -- write callback resumes on the main loop.
                        buf_handle.write(chunk, function()
                            read.resume()
                        end)
                        return false
                    end
                    buf_handle.write(chunk)
                end,
                on_done  = function()
                    if not (cancelled or stop_buf or buf_done) then pump(i + 1) end
                end,
                on_error = function(err)
                    -- The rest of the stream would be built from lines that have
                    -- moved under the read: the in-buffer half stops here and
                    -- says why, and whatever rg has already matched stands.
                    errors[#errors + 1] = ("%s: %s"):format(bufs[i].relpath, err)
                    stop_buf            = true
                    if buf_handle then buf_handle.kill() end
                end,
            })
            buf_loader = read
        end

        buf_handle, buf_err = spawn(
            rgutil.build_cmd(prompt_details, true),
            {
                cwd    = cwd,
                stdin  = true,
                stdout = function(data)
                    if not stop_buf then buf_feed(data) end
                end,
            },
            function()
                buf_done = true
                settle()
            end
        )

        -- A failed spawn still fires its exit callback, so settle() is not
        -- called here; the directory search reports the error (same exe).
        if buf_handle then
            pump(1)
        else
            buf_done = true
            -- The directory half reports a ripgrep that never started, running
            -- the same exe; with no directory half there is no one else to say
            -- it, so an empty list would be all the user got.
            if only_buffers then
                errors[#errors + 1] =
                    ("ripgrep (%s): %s"):format(rgutil.exe(), buf_err or "failed to start")
            end
        end
    end

    -- With `buffers` the in-buffer half was the whole search, and it settles on
    -- its own: there is no second half left to wait for.
    if only_buffers then return cancel end

    ----------------------------------------------------------------------------
    -- Directory search (rg over the filesystem, open buffers excluded).
    ----------------------------------------------------------------------------
    local stop_read = false
    local count     = 0

    local function on_error(msg)
        errors[#errors + 1] = msg
    end

    local buffered_feed = strutil.create_line_buffered_feed(function(lines)
        for _, line in ipairs(lines) do
            if stop_read then return end
            local m = rgutil.parse_match(line)
            if m then
                local abs_path = vim.fs.joinpath(cwd, m.path)
                local rel_path = fsutil.get_relative_path(abs_path, cwd)
                -- Skip files already covered by the in-buffer search.
                if not (rel_path and open_relpaths[rel_path]) then
                    dir_recs[#dir_recs + 1] = {
                        m        = m,
                        abs_path = abs_path,
                        rel_path = rel_path,
                    }
                    count = count + 1
                    if count >= max_results then
                        stop_read = true
                        if dir_handle then dir_handle.kill() end
                        break
                    end
                end
            end
        end
    end)

    local spawn_err
    dir_handle, spawn_err = spawn(
        build_rg_dir_cmd(prompt_details),
        {
            cwd    = cwd,
            stdout = function(data)
                if not stop_read then buffered_feed(data) end
            end,
            stderr = function(data)
                on_error(data)
            end,
        },
        function() settle() end
    )

    -- An unusable `rg_path` fails here, not on stderr: report it in the result
    -- list rather than showing an empty picker. settle() comes from spawn's
    -- exit callback, which fires even when the process never started.
    if not dir_handle then
        on_error(string.format("ripgrep (%s): %s", rgutil.exe(), spawn_err or "failed to start"))
    end

    return cancel
end

---@param opts locate.livegrep.opts?
---@return locate.PickerSpec
function M.spec(opts)
    opts = opts or {}

    ---@type locate.PickerSpec
    return {
        prompt         = "Live Grep",
        flags          = FLAGS,
        enable_preview = true,
        previewer      = buffer_preview,
        finder         = function(query, flags, fetch_opts, callback)
            local prompt_details = { query = query, flags = flags }
            local target_cwd     = flags.dir and vim.fn.expand(flags.dir) or vim.fn.getcwd()
            return async_grep(prompt_details, {
                cwd         = target_cwd,
                max_results = opts.max_results or 10000,
            }, fetch_opts, callback)
        end,
        on_confirm     = function(data)
            if not data then return end
            if data.filepath and data.lnum and data.col then
                ui.smart_open_file(data.filepath, data.lnum, data.col - 1)
            end
        end,
    }
end

return M
