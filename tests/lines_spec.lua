local lines = require("locate.pickers.lines")

local FETCH_OPTS = { line_width = 60, virt_line_width = 57, list_height = 20 }

---The buffer the test is working on, so the one it left behind can be wiped.
local bufnr

---A buffer holding `text`, current, with the cursor at the top.
---@param text string[]
local function buffer(text)
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, text)
    vim.api.nvim_win_set_buf(0, bufnr)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
end

---Run the spec's finder to completion. A query goes to ripgrep, so the rows
---arrive from a subprocess and not before the finder returns.
---@param spec  locate.PickerSpec
---@param query string
---@param flags table?
---@return locate.Picker.Item[]
local function fetch(spec, query, flags)
    local items, done
    spec.finder(query, flags or {}, FETCH_OPTS, function(new_items)
        items, done = new_items, true
    end)
    assert(vim.wait(5000, function() return done end, 10), "the search never finished")
    return items
end

---The text of one row, as the list would show it.
---@param item locate.Picker.Item
---@return string
local function row(item)
    local parts = {}
    for _, chunk in ipairs(item.label_chunks) do parts[#parts + 1] = chunk[1] end
    return table.concat(parts)
end

describe("buffer_lines", function()
    after_each(function()
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
        bufnr = nil
    end)

    it("lists the non-blank lines of the current buffer, numbered", function()
        buffer({ "alpha", "", "   ", "beta" })
        local items = fetch(lines.spec({ bufnr = bufnr }), "")

        assert.same({ "1 alpha", "4 beta" }, vim.tbl_map(row, items))
        assert.equals(1, items[1].data.lnum)
        assert.equals(4, items[2].data.lnum)
        assert.equals(bufnr, items[1].data.bufnr)
    end)

    it("matches a query literally, leaving regex characters alone", function()
        buffer({ "abc def", "a.c def" })
        local items = fetch(lines.spec({ bufnr = bufnr }), "a.c")

        assert.same({ "2 a.c def" }, vim.tbl_map(row, items))
    end)

    it("reads the query as a regex when regex is on", function()
        buffer({ "abc def", "a.c def" })
        local items = fetch(lines.spec({ bufnr = bufnr }), "a.c", { regex = true })

        assert.same({ "1 abc def", "2 a.c def" }, vim.tbl_map(row, items))
    end)

    it("word matches whole words alone", function()
        buffer({ "concatenate", "cat and dog" })
        local items = fetch(lines.spec({ bufnr = bufnr }), "cat", { word = true })

        assert.same({ "2 cat and dog" }, vim.tbl_map(row, items))
    end)

    it("line matches whole lines alone", function()
        buffer({ "cat and dog", "cat" })
        local items = fetch(lines.spec({ bufnr = bufnr }), "cat", { line = true })

        assert.same({ "2 cat" }, vim.tbl_map(row, items))
    end)

    it("invert shows the lines that do not match", function()
        buffer({ "alpha", "beta" })
        local items = fetch(lines.spec({ bufnr = bufnr }), "alpha", { invert = true })

        assert.same({ "2 beta" }, vim.tbl_map(row, items))
    end)

    it("is smart-case by default and takes case or nocase when told", function()
        buffer({ "Alpha", "alpha" })
        local spec = lines.spec({ bufnr = bufnr })

        assert.same({ "1 Alpha", "2 alpha" }, vim.tbl_map(row, fetch(spec, "alpha")))
        assert.same({ "1 Alpha" },
            vim.tbl_map(row, fetch(spec, "Alpha", { case = true })))
        assert.same({ "1 Alpha", "2 alpha" },
            vim.tbl_map(row, fetch(spec, "ALPHA", { nocase = true })))
    end)

    it("trims the line for display and marks the match on it", function()
        buffer({ "  foo bar" })
        local items = fetch(lines.spec({ bufnr = bufnr }), "bar")

        assert.same({
            { "1 ", "LineNr" },
            { "foo " },
            { "bar", "LocatePickerMatch" },
        }, items[1].label_chunks)
        -- The column to open on is the match's own, in the line as stored.
        assert.equals(6, items[1].data.col)
    end)

    it("answers an empty list when nothing matches", function()
        buffer({ "alpha" })
        assert.same({}, fetch(lines.spec({ bufnr = bufnr }), "zzz"))
    end)

    it("reports a search that could not be run", function()
        buffer({ "alpha" })
        local items = fetch(lines.spec({ bufnr = bufnr }), "(", { regex = true })

        assert.equals(1, #items)
        assert.is_truthy(row(items[1]):find("ERROR:", 1, true))
    end)

    it("hands back a cancel function for a search in flight", function()
        buffer({ "alpha" })
        local cancel = lines.spec({ bufnr = bufnr }).finder("a", {}, FETCH_OPTS, function() end)

        assert.is_function(cancel)
        cancel()
    end)
end)
