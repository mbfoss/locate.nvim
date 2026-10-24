---@brief Route `:copen` and `:lopen` through the `quickfix` and `loclist`
---sources. Enabled by `replace_copen` and `replace_lopen`; see
---`locator.Config`.

local M = {}

local config = require("locator.config").current

local _AUGROUP = "LocatorCopen"

---Close the native window again and open the picker in its place.
---@param args table nvim_create_autocmd callback args
local function _redirect(args)
    if vim.bo[args.buf].buftype ~= "quickfix" then return end
    local winid = vim.api.nvim_get_current_win()
    local info = vim.fn.getwininfo(winid)[1]
    if not info then return end

    local is_loclist = info.loclist == 1
    if is_loclist and not config.replace_lopen then return end
    if not is_loclist and not config.replace_copen then return end

    if #vim.api.nvim_tabpage_list_wins(0) <= 1 then return end

    -- A location list belongs to the window `:lopen` ran in, not to the scratch
    -- window it opened, so remember the former before the latter is closed.
    local owner = nil
    if is_loclist then
        owner = vim.fn.getloclist(winid, { filewinid = 1 }).filewinid
        if owner == 0 then owner = nil end
    end

    if not pcall(vim.api.nvim_win_close, winid, true) then return end
    if is_loclist then
        require("locator").pick("loclist", nil, { winid = owner })
    else
        require("locator").pick("quickfix")
    end
end

---Turn the redirects on or off. Idempotent: calling it again with the values
---already in force changes nothing.
---@param config locator.Config
function M.apply(config)
    vim.api.nvim_create_augroup(_AUGROUP, { clear = true })
    if not config.replace_copen and not config.replace_lopen then return end

    vim.api.nvim_create_autocmd("BufWinEnter", {
        group    = _AUGROUP,
        callback = _redirect,
        desc     = "Open the list picker in place of the native quickfix or location-list window",
    })
end

return M
