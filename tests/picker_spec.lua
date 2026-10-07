local locate = require("locate")
local picker = require("locate.base.picker")

---What the source under test has seen, in order.
local browsed = {}

---Rows the source hands back by query: the empty query is the opening list, and
---a query stands for a narrower one that leaves different items on top.
local RESULTS = {
    [""]  = { "one", "two", "three" },
    ["f"] = { "four", "five" },
}

local source = locate.register("picker_spec", {
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

describe("on_cursor", function()
    after_each(function() vim.cmd("silent! close!") end)

    ---Open the picker and let the first fetch land.
    ---@return locate.util.Picker
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
