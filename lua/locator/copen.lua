---@brief Route `:copen` through the `quickfix` source. Enabled by
---`replace_copen`; see `locator.Config`.

local M = {}

local _AUGROUP = "LocatorCopen"

---The windows a `:copen` just created. `:lopen` and `:copen` share the
---`quickfix` buftype, so `getwininfo()` has to say which one this is.
---@param winid integer
---@param bufnr integer
---@return boolean
local function _is_quickfix_window(winid, bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype ~= "quickfix" then
        return false
    end
    local info = vim.fn.getwininfo(winid)[1]
    return info ~= nil and info.loclist == 0
end

---Close the native window again and open the picker in its place. Deferred,
---so the window exists before it is closed, and re-checked there because the
---editor may have moved on in between.
---@param args table nvim_create_autocmd callback args
local function _redirect(args)
    local winid = vim.api.nvim_get_current_win()
    if not _is_quickfix_window(winid, args.buf) then return end
    -- An empty list would only report itself as empty and leave nothing behind,
    -- so the native window is the better answer for one.
    if vim.tbl_isempty(vim.fn.getqflist()) then return end
    if #vim.api.nvim_tabpage_list_wins(0) <= 1 then return end

    vim.schedule(function()
        if not vim.api.nvim_win_is_valid(winid) then return end
        if vim.api.nvim_win_get_buf(winid) ~= args.buf then return end
        if #vim.api.nvim_tabpage_list_wins(0) <= 1 then return end
        if not pcall(vim.api.nvim_win_close, winid, true) then return end
        require("locator").pick("quickfix")
    end)
end

---Turn the redirect on or off. Idempotent: calling it again with the value
---already in force changes nothing.
---@param enabled boolean
function M.apply(enabled)
    vim.api.nvim_create_augroup(_AUGROUP, { clear = true })
    if not enabled then return end

    vim.api.nvim_create_autocmd("BufWinEnter", {
        group    = _AUGROUP,
        callback = _redirect,
        desc     = "Open the quickfix picker in place of the native window",
    })
end

return M
