local M           = {}

local picker      = require("locator.base.picker")
local pickertools = require("locator.base.pickertools")
local config      = require("locator.config").current

---@generic T
---@param items T[] Arbitrary items
---@param opts vim.ui.select.Opts Additional options
---@param on_choice fun(item: T|nil, idx: integer|nil)
---               Called once the user made a choice.
---               `idx` is the 1-based index of `item` within `items`.
---               `nil` if the user aborted the dialog.
return function(items, opts, on_choice)
    vim.validate("on_choice", on_choice, "function")
    opts               = opts or {}

    local format_item  = opts.format_item or tostring

    ---@type (fun(item:any):{buf:integer?,pos:{[1]:integer,[2]:integer}?,pos_end:{[1]:integer,[2]:integer}?})?
    ---@diagnostic disable-next-line: undefined-field
    local preview_item = opts.preview_item

    local _cached      = {}
    for i, item in ipairs(items) do
        local ok, label = pcall(format_item, item)
        _cached[i] = {
            label = ok and tostring(label) or tostring(item),
            data  = item,
        }
    end

    picker.open({
        prompt         = opts.prompt and opts.prompt:gsub("%s*:%s*$", "") or "Select",
        height_ratio   = config.height_ratio,
        preview_ratio  = config.preview_ratio,
        enable_preview = preview_item ~= nil,
        finder         = function(query, _, _, callback)
            local results = {}
            for _, entry in ipairs(_cached) do
                local match = pickertools.match_label(entry.label, query)
                if match then
                    table.insert(results, {
                        label_chunks = match.chunks,
                        data         = entry.data,
                    })
                end
            end
            callback(results)
        end,

        previewer      = preview_item and function(data, _, callback)
            vim.schedule(function()
                local result = preview_item(data)
                if not result or not result.buf then
                    callback(nil)
                    return
                end
                callback({
                    bufnr   = result.buf,
                    pos     = result.pos,
                    pos_end = result.pos_end,
                })
            end)
        end or nil,
    }, function(choice)
        if not choice then
            on_choice(nil, nil)
            return
        end
        for i, item in ipairs(items) do
            if item == choice then
                on_choice(choice, i)
                return
            end
        end
        on_choice(choice, nil)
    end)
end
