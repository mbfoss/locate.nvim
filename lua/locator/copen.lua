---@brief Route `:copen` through the `quickfix` source. Enabled by
---`replace_copen`; see `locator.Config`.

local M = {}

local _AUGROUP = "LocatorCopen"



---Close the native window again and open the picker in its place. Deferred,
---so the window exists before it is closed, and re-checked there because the
---editor may have moved on in between.
---@param args table nvim_create_autocmd callback args
local function _redirect(args)
    if vim.bo[args.buf].buftype ~= "quickfix" then return end
    local winid = vim.api.nvim_get_current_win()
    local info = vim.fn.getwininfo(winid)[1]
    if not info or info.loclist ~= 0 then return end
    if #vim.api.nvim_tabpage_list_wins(0) <= 1 then return end
    if not pcall(vim.api.nvim_win_close, winid, true) then return end
    require("locator").pick("quickfix")
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
