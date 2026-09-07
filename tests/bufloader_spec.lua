local bufloader = require("locator.util.bufloader")

---The buffer the test is working on, so the one it left behind can be wiped.
local bufnr

---A buffer holding `text`.
---@param text string[]
local function buffer(text)
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, text)
end

---Read the buffer whole, collecting what the read reports.
---@param buf      integer
---@param opts     locator.util.bufloader.Opts?
---@param on_chunk? fun(lines:string[], first_lnum:integer):boolean?
---@return {chunks:{[1]:string[],[2]:integer}[], done:boolean, err:string?} out
---@return locator.util.bufloader.Read read
local function read(buf, opts, on_chunk)
    local out = { chunks = {}, done = false }
    local r   = bufloader.load(buf, opts, {
        on_chunk = function(lines, first_lnum)
            out.chunks[#out.chunks + 1] = { lines, first_lnum }
            if on_chunk then return on_chunk(lines, first_lnum) end
        end,
        on_done  = function() out.done = true end,
        on_error = function(err) out.err = err end,
    })
    return out, r
end

---Wait for what the read reports through its own timers.
---@param cond fun():boolean
local function settle(cond)
    assert(vim.wait(1000, cond, 1), "the read never settled")
end

---Let the loop run for `ms`, so a callback that should not fire has its chance.
---@param ms integer
local function idle(ms)
    vim.wait(ms, function() return false end, 5)
end

describe("bufloader", function()
    after_each(function()
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
        bufnr = nil
    end)

    it("reads the buffer in order, a chunk at a time", function()
        buffer({ "one", "two", "three", "four", "five" })
        local out = read(bufnr, { chunk_lines = 2 })

        settle(function() return out.done end)
        assert.same({
            { { "one", "two" }, 1 },
            { { "three", "four" }, 3 },
            { { "five" }, 5 },
        }, out.chunks)
        assert.is_nil(out.err)
    end)

    it("reads a lone blank line as the whole buffer", function()
        buffer({ "" })
        local out = read(bufnr)

        settle(function() return out.done end)
        assert.same({ { { "" }, 1 } }, out.chunks)
    end)

    it("reports a buffer that changed between chunks", function()
        buffer({ "one", "two", "three" })
        local out, r = read(bufnr, { chunk_lines = 1 }, function()
            -- The edit lands between slices: parked first, so no slice is
            -- read past it.
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "changed" })
            return false
        end)

        settle(function() return #out.chunks == 1 end)
        r.resume()
        settle(function() return out.err ~= nil end)
        assert.equals("Buffer changed while it was being read", out.err)
        assert.is_false(out.done)
    end)

    it("reports a buffer that was unloaded mid-read", function()
        buffer({ "one", "two" })
        local out, r = read(bufnr, { chunk_lines = 1 }, function()
            vim.api.nvim_buf_delete(bufnr, { force = true })
            return false
        end)

        settle(function() return #out.chunks == 1 end)
        r.resume()
        settle(function() return out.err ~= nil end)
        assert.equals("Buffer is no longer loaded", out.err)
        assert.is_false(out.done)
    end)

    it("reads on from a parked chunk when resumed", function()
        buffer({ "one", "two", "three" })
        local parked = false
        local out, r = read(bufnr, { chunk_lines = 1 }, function()
            if parked then return end
            parked = true
            return false
        end)

        settle(function() return parked end)
        assert.same({ { { "one" }, 1 } }, out.chunks)

        r.resume()
        settle(function() return out.done end)
        assert.same({
            { { "one" }, 1 },
            { { "two" }, 2 },
            { { "three" }, 3 },
        }, out.chunks)
    end)

    it("goes quiet when cancelled before the first chunk", function()
        buffer({ "one", "two", "three" })
        local out, r = read(bufnr, { chunk_lines = 1, yield_ms = 50 })

        r.cancel()
        idle(80)
        assert.same({}, out.chunks)
        assert.is_false(out.done)
        assert.is_nil(out.err)
    end)

    it("goes quiet when a parked read is cancelled", function()
        buffer({ "one", "two", "three" })
        local out, r = read(bufnr, { chunk_lines = 1 }, function() return false end)

        settle(function() return #out.chunks == 1 end)
        r.cancel()
        r.resume()
        idle(30)
        assert.equals(1, #out.chunks)
        assert.is_nil(out.err)
    end)
end)
