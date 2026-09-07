local M           = {}

local pickertools = require("locator.base.pickertools")
local throttle    = require("locator.util.throttle")

-- Stepping through the list fires `on_cursor` for every row, and each scheme
-- load repaints the whole UI, so an unthrottled browse strobes. Long enough
-- to swallow a run of steps, short enough that a deliberate move still previews.
local DEBOUNCE_MS = 500

---Switch to `name`, then put locator's own highlight groups back: `:colorscheme`
---runs `:highlight clear`, which drops every group defined outside the scheme.
---A scheme may error halfway through, so the `pcall` reports instead of throwing.
---@param name string
local function apply_scheme(name)
    vim.schedule(function() -- schedule to avoid issues with vim.cmd.colorscheme
        local ok, err = pcall(vim.cmd.colorscheme, name)
        require("locator").apply_highlights()
        if not ok then
            vim.notify(("Failed to load colorscheme %s: %s"):format(name, tostring(err)),
                vim.log.levels.WARN)
        end
    end)
end

---@return locator.PickerSpec?
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

    -- Debounce rather than throttle: any leading repaint is a flash while the
    -- user is still scrolling, so wait for the cursor to settle and apply only
    -- the row it settled on. The callback carries no argument, hence `pending`.
    local pending
    local apply_debounced, cancel_pending = throttle.debounce_wrap(DEBOUNCE_MS, function()
        local name = pending
        pending = nil
        if name then apply_scheme(name) end
    end)

    local function browse(name)
        pending = name
        apply_debounced()
    end

    return {
        prompt         = "Colorschemes",
        -- No previewer: the scheme is its own preview
        on_cursor      = function(data)
            browse(data.name)
        end,
        finder         = function(query, _, _, callback)
            local items = {}
            local current_row
            for _, name in ipairs(schemes) do
                local match = pickertools.match_label(name, query)
                if match then
                    ---@type locator.Picker.Item
                    table.insert(items, {
                        label_chunks = match.chunks,
                        score        = match.score,
                        data         = { name = name },
                    })
                    -- Open on the scheme in use, so moving away is what changes anything.
                    if name == original then current_row = #items end
                end
            end
            callback(items, current_row)
        end,
        on_confirm     = function(data)
            -- A confirm can land inside the debounce window, so flush what is
            -- queued rather than leaving it to fire after the picker is gone.
            -- A cancel drops it instead and puts the opening scheme back;
            -- otherwise the queued browse would repaint over the restore.
            local name = pending
            pending = nil
            cancel_pending()
            if data then
                -- Nothing queued means the debounce already applied it.
                if name then apply_scheme(name) end
                return
            end
            apply_scheme(original)
        end,
    }
end

return M
