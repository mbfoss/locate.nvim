local M = {}

local timer = require("locator.util.timer")
local strutil = require("locator.util.strutil")

---@param path string
function M.file_exists(path)
    local stat = vim.loop.fs_stat(path)
    return stat and stat.type == "file"
end

---@param path string
---@param base string?
function M.get_relative_path(path, base)
    base = base or vim.fn.getcwd()

    local full_path = vim.fn.fnamemodify(path, ":p")
    base = vim.fn.fnamemodify(base, ":p")

    -- ensure trailing slash for proper prefix match
    if base:sub(-1) ~= "/" then
        base = base .. "/"
    end

    if full_path:find(base, 1, true) == 1 then
        return full_path:sub(#base + 1)
    end

    return nil -- not relative to base
end

---@param filepath string
---@param data string
---@return boolean
---@return string | nil
function M.write_content(filepath, data)
    local fd = io.open(filepath, "w")
    if not fd then
        return false, "Cannot open file for write '" .. filepath or "" .. "'"
    end
    local ok, ret_or_err = pcall(function() fd:write(data) end)
    fd:close()
    return ok, ret_or_err
end

---@param filepath  string
---@return boolean success
---@return string content or error
function M.read_content(filepath)
    local fd = io.open(filepath, "r")
    if not fd then
        return false, "Cannot open file for read '" .. (filepath or "") .. "'"
    end
    local read_ok, content_or_err = pcall(function() return fd:read("*a") end)
    fd:close()
    if not content_or_err then
        return false, "failed to read from file '" .. (filepath or "") .. "'"
    end
    return read_ok, content_or_err
end

---@param path string
---@param opts { max_size: number?, timeout: number? }?
---@param callback fun(err:string|nil, data:string|nil,cropped:boolean?)
---@return fun() abort
function M.async_load_text_file(path, opts, callback)
    opts = opts or {}

    local max_size = opts.max_size
    local timeout_ms = opts.timeout
    local uv = vim.uv or vim.loop

    local t = uv.new_timer()
    local fd = nil
    local chunks = {}
    local total_read = 0
    local offset = 0

    local finished = false
    local aborted = false

    ---@param err string|nil
    ---@param cropped boolean?
    local function finish(err, cropped)
        if finished then return end
        finished = true
        if t then
            if not t:is_closing() then
                t:stop()
                t:close()
            end
            t = nil
        end
        if fd then
            uv.fs_close(fd)
            fd = nil
        end
        if err then chunks = {} end
        vim.schedule(function()
            if not aborted then
                local final_data = table.concat(chunks)
                callback(err, final_data)
                chunks = {}
            end
        end)
    end
    local timeout_timer
    if timeout_ms then
        timeout_timer = vim.defer_fn(function()
            finish("Timeout", nil)
        end, timeout_ms)
    end
    uv.fs_open(path, "r", 438, function(open_err, opened_fd)
        if open_err or finished or aborted then
            if opened_fd then uv.fs_close(opened_fd) end
            if open_err and not (finished or aborted) then
                return finish("Could not open file: " .. open_err)
            end
            return
        end

        fd = opened_fd
        local function read_next()
            if not fd or finished or aborted then return end

            uv.fs_read(fd, 8192, offset, function(read_err, data)
                if finished or aborted then return end

                if read_err then
                    return finish("Read error: " .. read_err)
                end
                if not data or #data == 0 then
                    return finish()
                end
                if data:find("\0", 1, true) then
                    return finish("Binary file")
                end

                total_read = total_read + #data
                if max_size and total_read > max_size then
                    table.insert(chunks, data:sub(1, #data - (total_read - max_size)))
                    return finish(nil, true)
                end

                table.insert(chunks, data)
                offset = offset + #data

                read_next()
            end)
        end

        read_next()
    end)
    return function()
        if finished or aborted then return end
        aborted = true
        timer.stop_and_close_timer(timeout_timer)
        finish("Aborted")
    end
end

local _uv = vim.uv or vim.loop


---@class locator.util.fsutil.walk_dir_opts
---@field include_regex_list vim.regex[]?
---@field exclude_regex_list vim.regex[]?
---@field on_dir_enter fun(path:string)?
---@field on_file fun(filepath:string,filename:string,relative_path:string)
---@field on_done fun()
---@field follow_symlinks boolean?
---@field slice_ms number? work budget per slice in ms before yielding (default 10)
---@field yield_ms number? idle gap between slices in ms (default 1)

--- Walk `dir` recursively without blocking the UI.
---
--- Directories are scanned in slices of `slice_ms`; between slices the walk
--- parks on a `yield_ms` timer so libuv returns to the main loop and Neovim can
--- process typed keys and redraw. A plain `vim.schedule` chain is not enough
--- here: its callbacks drain within the same loop iteration, so a deep tree
--- still holds the UI.
---@param dir string
---@param opts locator.util.fsutil.walk_dir_opts
---@return function # cancel function
function M.async_walk_dir(dir, opts)
    local pending_dirs = { dir }
    local is_cancelled = false
    local slice_ns     = (opts.slice_ms or 10) * 1e6
    local yield_ms     = opts.yield_ms or 1
    local stop_yield ---@type fun()?

    local on_done_called = false
    local call_on_done = function()
        if not on_done_called then
            vim.schedule(function()
                opts.on_done()
            end)
            on_done_called = true
        end
    end

    ---@param path string
    local function scan_dir(path)
        if opts.on_dir_enter then
            opts.on_dir_enter(path)
        end
        local fd = _uv.fs_scandir(path)
        if not fd then return end
        while true do
            -- `on_file` may cancel mid-directory; stop there rather than
            -- matching every remaining entry of a huge directory.
            if is_cancelled then return end
            local name, type_ = _uv.fs_scandir_next(fd)
            if not name then break end

            local full_path = vim.fs.joinpath(path, name)
            local rel_path = vim.fs.relpath(dir, full_path)
            if rel_path then
                local resolved_type = type_ ---@type string?
                if type_ == "link" and opts.follow_symlinks then
                    local stat = _uv.fs_stat(full_path)
                    resolved_type = stat and stat.type or nil
                end
                if resolved_type == "directory" then
                    if strutil.check_path_pattern(rel_path, true, nil, opts.exclude_regex_list) then
                        table.insert(pending_dirs, full_path)
                    end
                elseif resolved_type == "file" then
                    if strutil.check_path_pattern(rel_path, false, opts.include_regex_list, opts.exclude_regex_list) then
                        opts.on_file(full_path, name, rel_path)
                    end
                end
            end
        end
    end

    local function run_slice()
        -- The one-shot timer that woke us is still an open handle; close it.
        if stop_yield then
            stop_yield()
            stop_yield = nil
        end

        local deadline = _uv.hrtime() + slice_ns
        while true do
            if is_cancelled or #pending_dirs == 0 then
                call_on_done()
                return
            end
            scan_dir(table.remove(pending_dirs, 1))
            if _uv.hrtime() >= deadline then break end
        end

        stop_yield = timer.defer(yield_ms, run_slice)
    end

    -- The first slice is deferred too, so the caller always holds the cancel
    -- handle before any `on_file` fires: a cancel from inside a callback can
    -- never be dropped for want of a handle it hasn't been given yet.
    stop_yield = timer.defer(yield_ms, run_slice)

    return function()
        is_cancelled = true
        pending_dirs = {}
        if stop_yield then
            stop_yield()
            stop_yield = nil
        end
        -- Cancelling between slices leaves nobody to reach the loop head, so
        -- close the walk out here; `call_on_done` is idempotent.
        call_on_done()
    end
end

return M
