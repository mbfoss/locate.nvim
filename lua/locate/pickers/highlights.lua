local M = {}

local _attrs = {
    "bold", "italic", "underline", "undercurl", "underdouble",
    "underdotted", "underdashed", "strikethrough", "reverse",
    "standout", "nocombine",
}

---@type locate.queryflags.FlagDef[]
local FLAGS = {
    { name = "linksto", type = "value",   multi = true,                                   slot = "group",  desc = "filter by link target group" },
    { name = "linked",  type = "boolean", desc = "only groups that link to another group" },
    { name = "attr",    type = "value",   multi = true,                                   values = _attrs, slot = "name",                       desc = "has attribute: bold, italic, underline, ..." },
}

---@param name string
---@param hl table
---@param query string
---@param flags table
---@return boolean
local function highlight_matches(name, hl, query, flags)
    if query ~= "" then
        if not name:lower():find(query:lower(), 1, true) then return false end
    end

    if flags.linked and not hl.link then return false end

    local linksto = flags.linksto or {}
    if #linksto > 0 then
        local link = (hl.link or ""):lower()
        if link == "" then return false end
        for _, v in ipairs(linksto) do
            if not link:find(v:lower(), 1, true) then return false end
        end
    end

    for _, v in ipairs(flags.attr or {}) do
        if not hl[v] then return false end
    end

    return true
end

---@param name string
---@param hl table
---@return locate.Picker.Item
local function highlight_to_item(name, hl)
    local chunks = { { name, name } }

    local link = hl.link
    if link then
        table.insert(chunks, { " → ", "NonText" })
        table.insert(chunks, { link, link })
    end

    return {
        label_chunks = chunks,
        data         = { name = name, highlight = hl },
    }
end

---@return locate.PickerSpec
function M.spec()
    local highlights = vim.api.nvim_get_hl(0, {})

    return {
        prompt         = "Highlights",
        flags          = FLAGS,
        enable_preview = true,
        finder         = function(query, flags, _, callback)
            local items = {}
            for name, hl in pairs(highlights) do
                if highlight_matches(name, hl, query, flags) then
                    table.insert(items, highlight_to_item(name, hl))
                end
            end
            callback(items)
        end,
        previewer      = function(data, _, callback)
            local h = data.highlight

            local lines = {
                data.name or "Unknown",
                "",
                "# Colors",
                ("- **Foreground:** %s"):format(h.fg and ("#%06X"):format(h.fg) or "none"),
                ("- **Background:** %s"):format(h.bg and ("#%06X"):format(h.bg) or "none"),
                "",
                "# Styles",
            }
            local styles = {
                "bold",
                "italic",
                "underline",
                "undercurl",
                "strikethrough",
                "reverse",
                "standout",
                "nocombine",
            }
            local found_style = false
            for _, style in ipairs(styles) do
                if h[style] then
                    table.insert(lines, "- " .. style)
                    found_style = true
                end
            end
            if not found_style then
                table.insert(lines, "")
            end
            if h.link then
                vim.list_extend(lines, {
                    "# Link",
                    ("%s"):format(h.link),
                })
            end
            callback({
                content = lines,
                filetype = "markdown",
            })
            return function() end
        end,
        on_confirm     = function(data)
            if data then vim.api.nvim_put({ data.name }, "c", true, true) end
        end,
    }
end

return M
