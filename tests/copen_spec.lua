---@diagnostic disable: undefined-global
-- Tests for `replace_copen` and `replace_lopen`: the native quickfix or
-- location-list window is closed and the matching picker opens in its place,
-- whether the command was typed or run by another command.

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

---Close whatever a test left open -- picker floats, native list windows -- so
---none of it leaks into the next test.
local function reset()
    locator.setup({ replace_copen = false, replace_lopen = false })
    local p = picker._active()
    if p then p:close() end
    vim.wait(50)
    -- A native list window may be the current one, so close those by buftype
    -- rather than relying on `:close` hitting the right window.
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_is_valid(win)
            and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == "quickfix" then
            pcall(vim.api.nvim_win_close, win, true)
        end
    end
    vim.cmd("silent! only!")
    vim.fn.setqflist({}, "r")
    vim.fn.setloclist(0, {}, "r", { items = {} })
end

describe("replace_copen", function()
    after_each(reset)

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

describe("replace_lopen", function()
    after_each(reset)

    ---A location list for `winid` with one entry.
    local function fill_ll(winid)
        local bufnr = vim.api.nvim_get_current_buf()
        vim.fn.setloclist(winid, {}, "r", {
            items = { { bufnr = bufnr, lnum = 1, text = "one" } },
        })
    end

    it("is off by default", function()
        assert.is_false(require("locator.config").defaults().replace_lopen)
    end)

    it("installs the redirect when enabled and removes it when disabled", function()
        locator.setup({ replace_lopen = true })
        assert.are.equal(1, redirect_autocmds())

        locator.setup({ replace_lopen = false })
        assert.are.equal(0, redirect_autocmds())
    end)

    it("stays installed when setup runs twice with it on", function()
        locator.setup({ replace_lopen = true })
        locator.setup({ replace_lopen = true })
        assert.are.equal(1, redirect_autocmds())
    end)

    it("opens the loclist picker in place of a new location-list window", function()
        locator.setup({ replace_lopen = true })
        local winid = vim.api.nvim_get_current_win()
        fill_ll(winid)

        assert.is_nil(picker._active())
        vim.cmd("lopen")
        vim.wait(500, function() return picker._active() ~= nil end)

        local p = assert(picker._active())
        assert.are.equal("Location List Items", p.opts.prompt)
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            local bufnr = vim.api.nvim_win_get_buf(win)
            assert.are_not.equal("quickfix", vim.bo[bufnr].buftype)
        end
    end)

    it("leaves an empty location list alone", function()
        locator.setup({ replace_lopen = true })

        vim.cmd("lopen")
        vim.wait(100)
        assert.is_nil(picker._active())

        local found
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            if vim.bo[vim.api.nvim_win_get_buf(win)].buftype == "quickfix" then found = win end
        end
        assert.is_not_nil(found)
    end)

    it("leaves the quickfix window alone when only loclist is replaced", function()
        locator.setup({ replace_lopen = true })
        fill_qf()

        vim.cmd("copen")
        vim.wait(100)
        assert.is_nil(picker._active())
    end)
end)
