local M           = {}

local pickertools = require("locate.base.pickertools")

---A snippet to preview against when the current buffer has nothing worth
---showing (an empty or unnamed scratch buffer), so a scheme can still be judged
---on comments, keywords, strings and numbers.
local _SAMPLE = [[
---@diagnostic disable
---@class ClassName
---@field field_name string
local data = {
    key_one = "string_value",
    key_two = 42,
    flag = true,
}

---@param parameter_name string|integer
---@return boolean
function function_name(parameter_name)
    -- TODO: inline comment
    if type(parameter_name) == "integer" and data.flag ~= nil then
        for index = 1, 2 do
            if index == parameter_name then
                return true
            end
        end
    end

    return false
end

return {
    data = data,
    function_name = function_name,
}
]]

---Switch to `name`, then restore locate's own highlight groups: `:colorscheme`
---runs `:highlight clear`, which drops every group defined outside the scheme.
---A scheme is arbitrary user code and may error halfway through, hence the
---`pcall`: the message is shown in the preview rather than thrown at the user.
---@param name string
---@return string? error
local function apply_scheme(name)
    local ok, err = pcall(vim.cmd.colorscheme, name)
    require("locate").apply_highlights()
    if not ok then return tostring(err) end
    return nil
end

---@return locate.PickerSpec?
function M.spec()
    local schemes = vim.fn.getcompletion("", "color")
    if vim.tbl_isempty(schemes) then
        vim.notify("No colorschemes found", vim.log.levels.WARN)
        return nil
    end

    -- Restored when the picker is closed without a choice. `colors_name` is unset
    -- until a scheme is loaded, in which case Neovim's built-in default applies.
    local original    = vim.g.colors_name or "default"

    -- Previewing the buffer the picker was opened from shows the scheme against
    -- real code; a scratch or empty buffer has nothing to show, so use a sample.
    local origin_buf  = vim.api.nvim_get_current_buf()
    local use_origin  = vim.api.nvim_buf_is_loaded(origin_buf)
        and vim.bo[origin_buf].filetype ~= ""
        and vim.api.nvim_buf_line_count(origin_buf) > 1

    return {
        prompt         = "Colorschemes",
        enable_preview = true,
        -- Open on the scheme in use, so moving away is what changes anything.
        initial_cursor = function(items)
            for row, item in ipairs(items) do
                if item.data.name == original then return row end
            end
        end,
        previewer      = function(data, _, callback)
            local err = apply_scheme(data.name)
            if err then
                callback({ error_msg = err })
                return
            end
            if use_origin then
                callback({ bufnr = origin_buf })
            else
                callback({ content = _SAMPLE, filetype = "lua" })
            end
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
            -- The highlighted scheme is already applied by the previewer, so a
            -- confirm has nothing left to do and a cancel has to undo it.
            if data then return end
            apply_scheme(original)
        end,
    }
end

return M
