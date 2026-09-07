---@diagnostic disable: undefined-global
-- The quickfix picker's type flags: every entry is reachable. The four named
-- codes have a flag each, and `untyped` is the catch-all for a `type` that is
-- empty (what `:vimgrep` leaves behind) or carries a code none of them names.

local pickertools = require("locator.base.pickertools")
local queryflags  = require("locator.base.queryflags")
local qflist      = require("locator.pickers.qflist")

local FETCH_OPTS = { line_width = 60, list_height = 20 }

---Run the picker's finder with `flags` over the current quickfix list.
---@param flags table
---@return table[] items
local function fetch(flags)
    local items
    qflist.spec({}).finder("", flags, FETCH_OPTS, function(new_items)
        items = new_items
    end)
    return items
end

---@param items table[]
---@return string[]
local function texts(items)
    local out = {}
    for _, item in ipairs(items) do out[#out + 1] = item.data.text end
    return out
end

describe("qflist type flags", function()
    before_each(function()
        local bufnr = vim.api.nvim_get_current_buf()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "line" })
        vim.fn.setqflist({
            { bufnr = bufnr, lnum = 1, col = 1, text = "err",   type = "E" },
            { bufnr = bufnr, lnum = 1, col = 1, text = "warn",  type = "W" },
            { bufnr = bufnr, lnum = 1, col = 1, text = "info",  type = "I" },
            { bufnr = bufnr, lnum = 1, col = 1, text = "hint",  type = "N" },
            { bufnr = bufnr, lnum = 1, col = 1, text = "plain"              },
            { bufnr = bufnr, lnum = 1, col = 1, text = "odd",   type = "A" },
        }, "r")
    end)

    after_each(function()
        vim.fn.setqflist({}, "r")
    end)

    it("shows every type when no type flag is set", function()
        assert.are.same({ "err", "warn", "info", "hint", "plain", "odd" }, texts(fetch({})))
    end)

    it("selects entries with no recognised type", function()
        assert.are.same({ "plain", "odd" }, texts(fetch({ untyped = true })))
    end)

    it("unions the named flags and the untyped catch-all", function()
        assert.are.same({ "warn", "plain", "odd" }, texts(fetch({ warnings = true, untyped = true })))
    end)

    it("selects only entries whose location resolves", function()
        local bufnr = vim.api.nvim_get_current_buf()
        vim.fn.setqflist({
            { bufnr = bufnr, lnum = 1, col = 1, text = "here"    },
            { bufnr = bufnr, lnum = 0,          text = "nowhere" },
        }, "r")

        assert.are.same({ "here" }, texts(fetch({ resolved = true })))
    end)

    it("still reads `valid` for the resolved flag", function()
        local flags = queryflags.parse(qflist.spec({}).flags, "valid").flags
        assert.is_true(flags.resolved)
    end)

    it("marks an untyped entry with the unknown glyph, not the hint one", function()
        local items = fetch({ untyped = true })
        assert.are.equal(pickertools.UNKNOWN_ICON[1] .. " ", items[1].label_chunks[1][1])
    end)
end)
