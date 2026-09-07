local locator = require("locator")
local picker = require("locator.base.picker")

---What the source under test has seen, in order.
local browsed = {}

---Rows the source hands back by query: the empty query is the opening list, and
---a query stands for a narrower one that leaves different items on top.
local RESULTS = {
    [""]  = { "one", "two", "three" },
    ["f"] = { "four", "five" },
}

local source = locator.register("picker_spec", {
    prompt     = "Browsing",
    finder     = function(query, _, _, callback)
        local items = {}
        for row, name in ipairs(RESULTS[query] or {}) do
            items[row] = { label_chunks = { { name } }, data = { name = name } }
        end
        callback(items)
    end,
    on_cursor  = function(data) browsed[#browsed + 1] = data.name end,
    on_confirm = function() end,
})

---A source whose row is an index into the list it passes, which ranking then
---reorders: "low" scores last, so it lands on row 3.
local cursor_source = locator.register("picker_cursor_spec", {
    prompt     = "Cursor",
    finder     = function(_, _, _, callback)
        callback({
            { label_chunks = { { "low" } }, score = 1, data = { name = "low" } },
            { label_chunks = { { "high" } }, score = 100, data = { name = "high" } },
            { label_chunks = { { "middle" } }, score = 50, data = { name = "middle" } },
        }, 1)
    end,
    on_confirm = function() end,
})

---A source that can preview, so the mode switch has a preview float to put up
---and take down.
local preview_source = locator.register("picker_preview_spec", {
    prompt         = "Preview",
    enable_preview = true,
    previewer      = function(_, _, callback)
        callback({ content = "preview" })
        return function() end
    end,
    finder         = function(_, _, _, callback)
        callback({ { label_chunks = { { "item" } }, data = { name = "item" } } })
    end,
    on_confirm     = function() end,
})

describe("view modes", function()
    after_each(function() vim.cmd("silent! close!") end)

    it("opens compact, with no preview", function()
        vim.cmd("Locate " .. preview_source)
        vim.wait(100)
        local p = assert(picker._active())

        assert.is_false(p._expanded)
        assert.is_false(p._preview_open)
        assert.is_nil(p._vwin)
    end)

    it("toggle_preview splits the bar, the preview on the right", function()
        vim.cmd("Locate " .. preview_source)
        vim.wait(100)
        local p = assert(picker._active())
        local prompt = vim.api.nvim_win_get_config(p._pwin)
        local list = vim.api.nvim_win_get_config(p._lwin)

        p:toggle_preview()
        assert.is_true(p._preview_open)
        assert.is_truthy(p._vwin)
        assert.is_true(vim.api.nvim_win_is_valid(p._vwin))

        local prompt_preview = vim.api.nvim_win_get_config(p._pwin)
        local list_preview = vim.api.nvim_win_get_config(p._lwin)
        -- The bar keeps its rows and its left edge; the prompt and list give up
        -- width to the preview, and keep the same width as each other.
        assert.equals(prompt.row, prompt_preview.row)
        assert.equals(prompt.col, prompt_preview.col)
        assert.equals(list.row, list_preview.row)
        assert.equals(list.col, list_preview.col)
        assert.is_true(prompt_preview.width < prompt.width)
        assert.equals(prompt_preview.width, list_preview.width)

        -- Beside the list, borders touching, bottom borders level.
        local preview = vim.api.nvim_win_get_config(p._vwin)
        assert.equals(prompt_preview.row, preview.row)
        assert.equals(prompt_preview.col + prompt_preview.width + 2, preview.col)
        assert.equals(list_preview.row + list_preview.height, preview.row + preview.height + 1)

        p:toggle_preview()
        assert.is_false(p._preview_open)
        assert.is_nil(p._vwin)
        -- The bar takes its full width back.
        assert.equals(prompt.width, vim.api.nvim_win_get_config(p._pwin).width)
    end)

    it("toggle_expanded fills the screen and leaves the preview beside the list", function()
        vim.cmd("Locate " .. preview_source)
        vim.wait(100)
        local p = assert(picker._active())
        p:toggle_preview()
        assert.is_truthy(p._vwin)

        p:toggle_expanded()
        assert.is_true(p._expanded)
        assert.is_true(vim.api.nvim_win_is_valid(p._vwin))

        -- The frame starts at the first row, keeps a cell of margin either
        -- side, and the preview's right border ends at the other.
        local prompt = vim.api.nvim_win_get_config(p._pwin)
        local list = vim.api.nvim_win_get_config(p._lwin)
        local preview = vim.api.nvim_win_get_config(p._vwin)
        assert.equals(0, prompt.row)
        assert.equals(1, prompt.col)
        assert.equals(vim.o.columns - 2, preview.col + preview.width + 1)
        assert.equals(prompt.row, preview.row)
        assert.equals(list.row + list.height, preview.row + preview.height + 1)

        p:toggle_expanded()
        assert.is_false(p._expanded)
        assert.is_true(vim.api.nvim_win_is_valid(p._vwin))
    end)
end)

describe("initial cursor", function()
    after_each(function() vim.cmd("silent! close!") end)

    it("follows the finder's row through ranking", function()
        vim.cmd("Locate " .. cursor_source)
        vim.wait(100)
        local p = assert(picker._active())
        assert.equals(3, p._cursor_row)
        assert.equals("low", p._list_items[p._cursor_row].data.name)
    end)

    it("leaves the cursor at the top when the finder names no row", function()
        vim.cmd("Locate " .. source)
        vim.wait(100)
        local p = assert(picker._active())
        assert.equals(1, p._cursor_row)
    end)

    it("restores the row the last picker was left on", function()
        vim.cmd("Locate " .. cursor_source)
        vim.wait(100)
        local p = assert(picker._active())
        p:move_cursor(2)
        p:close()
        vim.wait(100)

        locator.resume()
        vim.wait(100)
        local resumed = assert(picker._active())
        assert.equals(2, resumed._cursor_row)
        assert.equals("middle", resumed._list_items[2].data.name)
    end)
end)

describe("list cursor", function()
    after_each(function() vim.cmd("silent! close!") end)

    ---The row the ❯ marker is drawn on, 1-based.
    ---@param p locator.util.Picker
    ---@return integer?
    local function marker_row(p)
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(p._lbuf, -1, 0, -1, { details = true })) do
            local virt = mark[4].virt_text
            if virt and virt[1] and virt[1][1] == "❯ " then return mark[2] + 1 end
        end
    end

    it("follows the cursor an ordinary motion moves in the list", function()
        browsed = {}
        vim.cmd("Locate " .. source)
        vim.wait(100)
        local p = assert(picker._active())
        assert.equals(1, marker_row(p))

        -- `<C-l>` leaves the focus on the list, where j, k and the mouse move
        -- the cursor directly rather than through `move_cursor`.
        vim.api.nvim_win_set_cursor(p._lwin, { 3, 0 })
        vim.api.nvim_exec_autocmds("CursorMoved", { buffer = p._lbuf })

        assert.equals(3, marker_row(p))
        assert.equals(3, p._cursor_row)
        assert.same({ "three" }, browsed)
    end)
end)

describe("on_cursor", function()
    after_each(function() vim.cmd("silent! close!") end)

    ---Open the picker and let the first fetch land.
    ---@return locator.util.Picker
    local function open()
        browsed = {}
        vim.cmd("Locate " .. source)
        vim.wait(100)
        return assert(picker._active())
    end

    it("stays quiet for the row the picker opens on", function()
        open()
        assert.same({}, browsed)
    end)

    it("reports each item the highlight moves onto", function()
        local p = open()
        p:move_cursor(2)
        assert.same({ "two" }, browsed)

        p:move_cursor(3)
        assert.same({ "two", "three" }, browsed)
    end)

    it("stays quiet when the picker re-selects the item already highlighted", function()
        local p = open()
        p:move_cursor(2)
        p:move_cursor(2, true, true)
        assert.same({ "two" }, browsed)
    end)

    it("reports a fresh item a narrower query leaves under the cursor", function()
        local p = open()
        -- Row 1 both times: the fetch alone is what puts a new item there.
        p:set_prompt("", "f")
        vim.wait(100)
        assert.same({ "four" }, browsed)
    end)
end)
