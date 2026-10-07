local M           = {}

local pickertools = require("locate.base.pickertools")

---Switch to `name`, then put locate's own highlight groups back: `:colorscheme`
---runs `:highlight clear`, which drops every group defined outside the scheme.
---A scheme may error halfway through, so the `pcall` reports instead of throwing.
---@param name string
local function apply_scheme(name)
    local ok, err = pcall(vim.cmd.colorscheme, name)
    require("locate").apply_highlights()
    if not ok then
        vim.notify(("Failed to load colorscheme %s: %s"):format(name, tostring(err)),
            vim.log.levels.WARN)
    end
end

---@return locate.PickerSpec?
function M.spec()
    local schemes = vim.fn.getcompletion("", "color")
    if vim.tbl_isempty(schemes) then
        vim.notify("No colorschemes found", vim.log.levels.WARN)
        return nil
    end

    -- Restored when the picker is closed without a choice: browsing applies
    -- schemes on the way, so a cancel has to put this one back. `colors_name` is
    -- unset until a scheme is loaded, when Neovim's built-in default applies.
    local original = vim.g.colors_name or "default"

    return {
        prompt         = "Colorschemes",
        -- Open on the scheme in use, so moving away is what changes anything.
        initial_cursor = function(items)
            for row, item in ipairs(items) do
                if item.data.name == original then return row end
            end
        end,
        -- No previewer: the scheme is its own preview
        on_cursor      = function(data)
            apply_scheme(data.name)
        end,
        finder         = function(query, _, _, callback)
            local items = {}
            for _, name in ipairs(schemes) do
                local match = pickertools.match_label(name, query)
                if match then
                    ---@type locate.Picker.Item
                    table.insert(items, {
                        label_chunks = match.chunks,
                        score        = match.score,
                        data         = { name = name },
                    })
                end
            end
            callback(items)
        end,
        on_confirm     = function(data)
            -- The browsed scheme is already applied, so a confirm has nothing
            -- left to do and a cancel has to undo it.
            if data then return end
            apply_scheme(original)
        end,
    }
end

return M
