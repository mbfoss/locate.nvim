---@diagnostic disable: undefined-global
-- Tests for `replace_copen`: `:copen` opens the quickfix picker instead of the
-- native window, whether it was typed or run by another command.

local locator = require("locator")
local picker = require("locator.base.picker")

---@return integer
local function redirect_autocmds()
    local ok, autocmds = pcall(vim.api.nvim_get_autocmds, { group = "LocatorCopen" })
    return ok and #autocmds or 0
end

---A quickfix list with one entry, in the current buffer.
local function fill_qf()
    local bufnr = vim.api.nvim_get_current_buf()
    vim.fn.setqflist({ { bufnr = bufnr, lnum = 1, text = "one" } }, "r")
end

describe("replace_copen", function()
    after_each(function()
        locator.setup({ replace_copen = false })
        vim.cmd("silent! close!")
        vim.cmd("silent! only!")
        vim.fn.setqflist({}, "r")
    end)

    it("is off by default", function()
        assert.is_false(require("locator.config").defaults().replace_copen)
    end)

    it("installs the redirect when enabled and removes it when disabled", function()
        locator.setup({ replace_copen = true })
        assert.are.equal(1, redirect_autocmds())

        locator.setup({ replace_copen = false })
        assert.are.equal(0, redirect_autocmds())
    end)

    it("stays installed when setup runs twice with it on", function()
        locator.setup({ replace_copen = true })
        locator.setup({ replace_copen = true })
        assert.are.equal(1, redirect_autocmds())
    end)

    it("opens the quickfix picker in place of a new quickfix window", function()
        locator.setup({ replace_copen = true })
        fill_qf()

        assert.is_nil(picker._active())
        vim.cmd("copen")
        vim.wait(500, function() return picker._active() ~= nil end)

        local p = assert(picker._active())
        assert.are.equal("Quickfix Items", p.opts.prompt)
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            local bufnr = vim.api.nvim_win_get_buf(win)
            assert.are_not.equal("quickfix", vim.bo[bufnr].buftype)
        end
    end)

    it("leaves an empty quickfix window alone", function()
        locator.setup({ replace_copen = true })
        vim.fn.setqflist({}, "r")

        vim.cmd("copen")
        vim.wait(100)
        assert.is_nil(picker._active())

        local found
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            if vim.bo[vim.api.nvim_win_get_buf(win)].buftype == "quickfix" then found = win end
        end
        assert.is_not_nil(found)
    end)
end)
