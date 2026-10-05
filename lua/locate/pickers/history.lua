local M           = {}

local pickertools = require("locate.base.pickertools")

---@class locate.history.Kind
---@field name string   `histget()` history name
---@field prompt string
---@field prefix string  what starts the command line the entry is put back on

---@type table<string, locate.history.Kind>
local _KINDS      = {
    cmd    = { name = "cmd", prompt = "Command History", prefix = ":" },
    search = { name = "search", prompt = "Search History", prefix = "/" },
}

---Most recent first, which is the order these lists are read in.
---@param name string
---@return string[]
local function collect_entries(name)
    local entries = {}
    for i = vim.fn.histnr(name), 1, -1 do
        local entry = vim.fn.histget(name, i)
        if entry ~= "" then entries[#entries + 1] = entry end
    end
    return entries
end

---@param opts {kind:"cmd"|"search"}
---@return locate.PickerSpec?
function M.spec(opts)
    local kind = _KINDS[opts and opts.kind or "cmd"]
    assert(kind, "unknown history kind")

    local entries = collect_entries(kind.name)
    if #entries == 0 then
        vim.notify(kind.prompt .. " is empty", vim.log.levels.WARN)
        return nil
    end

    return {
        prompt         = kind.prompt,
        enable_preview = false,
        finder         = function(query, _, _, callback)
            local items = {}
            for i, entry in ipairs(entries) do
                local match = pickertools.match_label(entry, query)
                if match then
                    local chunks = { { ("%3d "):format(i), "Comment" }, { kind.prefix, "NonText" } }
                    vim.list_extend(chunks, match.chunks)
                    ---@type locate.Picker.Item
                    -- Deliberately unscored: recency is what a history list is
                    -- for, and the index column printed above only reads right
                    -- if the rows keep that order while the query narrows them.
                    table.insert(items, {
                        label_chunks = chunks,
                        data         = { entry = entry },
                    })
                end
            end
            callback(items)
        end,
        on_confirm     = function(data)
            -- Put the entry back on the command line unexecuted: a recalled
            -- command is as often a starting point as it is a rerun, and a
            -- destructive one should not fire on a stray <CR>.
            if data then vim.api.nvim_feedkeys(kind.prefix .. data.entry, "n", false) end
        end,
    }
end

return M
