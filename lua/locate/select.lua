local M           = {}

local picker      = require("locate.base.picker")
local pickertools = require("locate.base.pickertools")
local layouts     = require("locate.base.layouts")
local config      = require("locate.config").current

---@return number,number
local function _compute_dimentions(items)
    local maxw, height = 0, 0
    for _, item in ipairs(items) do
        if item.label then
            maxw = math.max(maxw, vim.fn.strdisplaywidth(item.label))
            height = height + 1
        end
    end
    return maxw, height
end

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

    local geometry = (preview_item and config.with_preview or config.without_preview) or {}

    -- A select with nothing to preview shrinks to its own contents rather than
    -- taking the configured share of the editor.
    if not preview_item then
        local list_width, list_height = _compute_dimentions(_cached)
        geometry = vim.tbl_extend("force", geometry, {
            width_ratio  = (list_width + 2) / vim.o.columns,
            -- Two rows on top of the items: the prompt line and the rule under
            -- it, the shared frame's other edges being the border ring.
            height_ratio = (list_height + 2) / layouts.usable_lines(),
        })
    end

    picker.open({
        prompt         = opts.prompt and opts.prompt:gsub("%s*:%s*$", "") or "Select",
        layout         = geometry.layout,
        width_ratio    = geometry.width_ratio,
        height_ratio   = geometry.height_ratio,
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
