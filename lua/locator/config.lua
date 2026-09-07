---@brief The picker's options. A leaf module, so `locator.select` and any other
---submodule can read the live config without requiring `locator` itself.

local M = {}

---A picker opens compact, a bar across the bottom. `<C-t>` adds the preview
---on its right, and `<C-e>` expands the prompt and list to fill the editor.
---@class locator.Config
---@field height_ratio number? Fraction of the usable rows the bar spans (default 0.25).
---@field preview_ratio number? Fraction of the frame's width the preview takes, clamped to 0.1-0.9 (default 0.5).
---@field auto_complete_flags boolean? Auto-open flag completion on an empty flags line and while typing (default true).
---@field rg_path string? Path to the ripgrep executable the `live_grep` picker runs (default "rg", resolved on `PATH`).
---@field replace_copen boolean? Open the `quickfix` picker in place of the native quickfix window when `:copen` runs (default false).

---@return locator.Config
local function _defaults()
    ---@type locator.Config
    return {
        height_ratio        = 0.25,
        preview_ratio       = 0.5,
        auto_complete_flags = true,
        replace_copen       = false,
    }
end

---The live options, at the defaults until `setup()` applies the user's. Always
---this same table: `apply()` refills it in place, so a module may capture it
---once at its top (`local config = require("locator.config").current`) and never
---see a stale value.
---@type locator.Config
M.current = _defaults()

---The options as they shipped. A fresh table every call, so the caller may keep
---or mutate it.
---@return locator.Config
function M.defaults()
    return _defaults()
end

---Overwrite `dst` from `src` key by key: a key `src` lacks is dropped, and a
---table on both sides recurses instead of being swapped in. Nothing reachable
---from `current` is ever replaced, and nothing stale is left behind.
local function _refill(dst, src)
    for k in pairs(dst) do
        if src[k] == nil then dst[k] = nil end
    end
    for k, v in pairs(src) do
        if type(v) == "table" and type(dst[k]) == "table" then
            _refill(dst[k], v)
        else
            dst[k] = v
        end
    end
end

---Merge `opts` over the defaults. Starting from a fresh copy of the defaults
---rather than from `current` means no key of an earlier call survives into a
---later one.
---@param opts locator.Config?
function M.apply(opts)
    _refill(M.current, vim.tbl_deep_extend("force", _defaults(), opts or {}))
end

return M
