local M = {}

local timer = require("locate.util.timer")

--- Lines read per slice when the caller names none: small enough that one slice
--- of even a buffer of very long lines stays well inside a frame.
local DEFAULT_CHUNK_LINES = 1000

--- Idle gap between slices, in ms.
local DEFAULT_YIELD_MS = 1

---@class locate.util.bufloader.Opts
---@field chunk_lines integer?  lines read per slice (default 1000)
---@field yield_ms    integer?  idle gap between slices, in ms (default 1)
---@field tick        integer?  the changedtick the read must match, for a caller
---  that measured the buffer (its line count, its offsets) before the read began

---@class locate.util.bufloader.Callbacks
---@field on_chunk fun(lines:string[], first_lnum:integer):boolean? a slice, in
---  document order; return `false` to park the read until `resume()`
---@field on_done  fun()            the whole buffer was read, unchanged throughout
---@field on_error fun(err:string)  the buffer changed under the read, or went away

---@class locate.util.bufloader.Read
---@field resume fun()  continue a read that parked itself
---@field cancel fun()  stop the read; nothing else is called

--- Read `bufnr` a chunk of lines at a time, in order.
---
--- Between chunks the read parks on a timer so libuv returns to the main loop
--- and Neovim can process keys and redraw: a buffer of any size costs the UI a
--- run of short turns rather than one long freeze. The read is pinned to the
--- text it started on, so an edit or a reload partway through reports
--- `on_error` instead of handing back line numbers that describe text which is
--- no longer there.
---@param bufnr integer
---@param opts  locate.util.bufloader.Opts?
---@param cb    locate.util.bufloader.Callbacks
---@return locate.util.bufloader.Read
function M.load(bufnr, opts, cb)
    opts = opts or {}

    -- A slice of no lines would leave the read standing still on the same one.
    local chunk_lines = math.max(1, opts.chunk_lines or DEFAULT_CHUNK_LINES)
    local yield_ms    = opts.yield_ms or DEFAULT_YIELD_MS
    local tick        = opts.tick or vim.api.nvim_buf_get_changedtick(bufnr)

    local next_lnum   = 1
    local settled     = false
    local parked      = false
    local stop_yield  ---@type fun()?

    local read        = {}

    ---@param err string
    local function fail(err)
        if settled then return end
        settled = true
        cb.on_error(err)
    end

    local function finish()
        if settled then return end
        settled = true
        cb.on_done()
    end

    local function clear_yield()
        if stop_yield then
            stop_yield()
            stop_yield = nil
        end
    end

    local function step()
        if settled then return end
        -- The one-shot timer that woke us is still an open handle; close it.
        clear_yield()

        -- A wiped or unloaded buffer has no lines left to read, and one that
        -- has been changed no longer holds the text the earlier slices came
        -- from.
        if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
            return fail("Buffer is no longer loaded")
        end
        if vim.api.nvim_buf_get_changedtick(bufnr) ~= tick then
            return fail("Buffer changed while it was being read")
        end

        local last_lnum = vim.api.nvim_buf_line_count(bufnr)
        if next_lnum > last_lnum then return finish() end

        -- `nvim_buf_get_lines` takes a 0-based, end-exclusive range; the line
        -- numbers reported to the caller are the buffer's own, 1-based ones.
        local end_lnum   = math.min(next_lnum + chunk_lines - 1, last_lnum)
        local lines      = vim.api.nvim_buf_get_lines(bufnr, next_lnum - 1, end_lnum, false)
        local first_lnum = next_lnum
        next_lnum        = end_lnum + 1

        if cb.on_chunk(lines, first_lnum) == false then
            -- Parked at the caller's request: the read waits for `resume`, and
            -- holds no timer open while it does.
            parked = true
            return
        end

        -- A callback may have cancelled the read from inside itself, having all
        -- it wants; there is nothing left to schedule and no timer to arm.
        if settled then return end

        if next_lnum > last_lnum then return finish() end
        stop_yield = timer.defer(yield_ms, step)
    end

    ---Continue a read that parked itself in `on_chunk`. Safe to call from a
    ---libuv callback: the next slice is scheduled onto the main loop.
    function read.resume()
        if settled or not parked then return end
        parked = false
        vim.schedule(step)
    end

    function read.cancel()
        if settled then return end
        settled = true
        clear_yield()
    end

    -- The first slice is deferred too, so the caller always holds the read
    -- before any callback fires and can cancel from inside one.
    stop_yield = timer.defer(yield_ms, step)

    return read
end

return M
