local livegrep = require("locator.pickers.livegrep")

local FETCH_OPTS = { line_width = 60, list_height = 20 }

---Run the spec's finder to completion. Both halves of the search are
---subprocesses, so the rows arrive from rg and not before the finder returns.
---@param spec  locator.PickerSpec
---@param query string
---@param flags table
---@return locator.Picker.Item[]
local function fetch(spec, query, flags)
    local items, done
    spec.finder(query, flags, FETCH_OPTS, function(new_items)
        items, done = new_items, true
    end)
    assert(vim.wait(5000, function() return done end, 10), "the search never finished")
    return items
end

---The text of one row, as the list would show it.
---@param item locator.Picker.Item
---@return string
local function row(item)
    local parts = {}
    for _, chunk in ipairs(item.label_chunks) do parts[#parts + 1] = chunk[1] end
    return table.concat(parts)
end

describe("live_grep", function()
    -- A directory of its own, holding one file that is open with an unsaved
    -- match and one that is only on disk, so which text each row came from is
    -- told apart by the text itself.
    local dir, open_path, bufnr

    before_each(function()
        dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        -- tempname() hands back the /var path on macOS while a buffer's name
        -- comes back as /private/var, one of which is not under the other, so
        -- the search root is put in the same terms as the buffer names first.
        dir = vim.fn.resolve(dir)
        open_path = dir .. "/open.txt"
        vim.fn.writefile({ "nothing here" }, open_path)
        vim.fn.writefile({ "needle on disk" }, dir .. "/disk.txt")

        bufnr = vim.api.nvim_create_buf(false, false)
        vim.api.nvim_buf_set_name(bufnr, open_path)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "needle unsaved" })
    end)

    after_each(function()
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
        vim.fn.delete(dir, "rf")
    end)

    it("takes buffers as a switch of its own", function()
        -- The flag is only reachable if its own schema reads it: a name nothing
        -- declares comes back as an error, and the search would never run.
        local parsed = require("locator.base.queryflags").parse(livegrep.spec().flags, "buffers")

        assert.same({}, parsed.errors)
        assert.is_true(parsed.flags.buffers)
    end)

    it("searches the open buffers and the directory both", function()
        local items = fetch(livegrep.spec(), "needle", { dir = dir })

        assert.equals(2, #items)
        -- The buffer's text leads and its location prefix is marked as such; the
        -- file with no open buffer is read from disk and follows, unmarked.
        assert.is_truthy(row(items[1]):find("unsaved", 1, true))
        assert.is_truthy(row(items[1]):find("≡", 1, true))
        assert.is_truthy(row(items[2]):find("on disk", 1, true))
        assert.is_falsy(row(items[2]):find("≡", 1, true))
    end)

    it("searches the open buffers alone when buffers is set", function()
        local items = fetch(livegrep.spec(), "needle", { dir = dir, buffers = true })

        -- No directory walk: the file that is only on disk is not searched, and
        -- the one that is open is still searched in memory.
        assert.equals(1, #items)
        assert.is_truthy(row(items[1]):find("unsaved", 1, true))
        assert.is_truthy(row(items[1]):find("≡", 1, true))
    end)
end)
