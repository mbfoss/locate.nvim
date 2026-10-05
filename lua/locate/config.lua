---@brief The picker's options. A leaf module, so `locate.select` and any other
---submodule can read the live config without requiring `locate` itself.

local M = {}

---A picker is sized by which of these two applies, so a source with nothing to
---preview can be narrower than one showing a file beside the list. `layout` only
---arranges a list against a preview, so it is meaningful in `with_preview`.
---@class locate.Config
---@field with_preview locate.Picker.Geometry? Sizing while the preview is showing.
---@field without_preview locate.Picker.Geometry? Sizing while it is not.
---@field auto_complete_flags boolean? Auto-open flag completion on an empty flags line and while typing (default true).
---@field rg_path string? Path to the ripgrep executable the `live_grep` picker runs (default "rg", resolved on `PATH`).

---@return locate.Config
local function _defaults()
    ---@type locate.Config
    return {
        with_preview        = {
            layout       = "horizontal",
            width_ratio  = 0.8,
            height_ratio = 0.7,
        },
        without_preview     = {
            width_ratio  = 0.6,
            height_ratio = 0.7,
        },
        auto_complete_flags = true,
    }
end

---The live options, at the defaults until `setup()` applies the user's. Always
---this same table: `apply()` refills it in place, so a module may capture it
---once at its top (`local config = require("locate.config").current`) and never
---see a stale value.
---@type locate.Config
M.current = _defaults()

---The options as they shipped. A fresh table every call, so the caller may keep
---or mutate it.
---@return locate.Config
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
---@param opts locate.Config?
function M.apply(opts)
    _refill(M.current, vim.tbl_deep_extend("force", _defaults(), opts or {}))
end

return M
