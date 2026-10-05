--- Filetype icons, sourced from an installed icon provider.
--- locate has no icon data of its own and does not require any particular
--- icon plugin. Providers are detected lazily and cached.
---@class locate.icon.Module
local M = {}

---@type boolean
local _resolved = false

---@class locate.icon.Provider
---@field get_icon fun(filename?: string, extension?: string, opts?: table): string?, string?

---@type locate.icon.Provider|nil
local _provider

---@return locate.icon.Provider|nil
local function _resolve()
    if _resolved then
        return _provider
    end
    _resolved = true
    local ok, mod
    -- nvim-web-icon
    ok, mod = pcall(require, "nvim-web-icon")
    if ok then
        _provider = {
            get_icon = function(filename, extension, opts)
                return mod.get_icon(filename, extension, opts)
            end,
        }
        return _provider
    end
    -- keystone.nvim
    ok, mod = pcall(require, "keystone.icons")
    if ok then
        _provider = {
            get_icon = function(filename, extension, opts)
                return mod.get_icon(filename, extension, opts)
            end,
        }
        return _provider
    end
    -- mini.icons
    ok, mod = pcall(require, "mini.icons")
    if ok then
        _provider = {
            get_icon = function(filename)
                local icon, hl = mod.get("file", filename)
                return icon, hl
            end,
        }
        return _provider
    end
    return nil
end

--- Get the icon and highlight group for a file, or `nil, nil` when no icon
--- provider is available.
---@param filename? string
---@param extension? string
---@param opts? table
---@return string?, string?
function M.get_icon(filename, extension, opts)
    local provider = _resolve()
    if not provider then
        return nil, nil
    end

    return provider.get_icon(filename, extension, opts)
end

return M
