local M           = {}

local pickertools = require("locate.base.pickertools")

---@type locate.queryflags.FlagDef[]
local FLAGS       = {
    { name = "empty", type = "boolean", desc = "include empty registers" },
}

---Every register a user can paste from, in the order `:registers` shows them:
---the unnamed one first, then the numbered, named and read-only ones.
---@return string[]
local function register_names()
    local names = { '"' }
    for char in ("0123456789abcdefghijklmnopqrstuvwxyz"):gmatch(".") do
        names[#names + 1] = char
    end
    vim.list_extend(names, { "-", "*", "+", ".", ":", "%", "#", "/", "=" })
    return names
end

---@class locate.registers.Entry
---@field name string
---@field lines string[]
---@field regtype string  `getregtype()` result, passed straight back to `nvim_put`
---@field display string  single-line rendering of the contents

---Render register contents as one line: the control characters that make it
---multi-line are shown as glyphs so a row can never break the list layout.
---@param lines string[]
---@return string
local function to_display(lines)
    return (table.concat(lines, "⏎"):gsub("\t", "→"):gsub("%c", " "))
end

---@return locate.registers.Entry[]
local function collect_registers()
    local entries = {}
    for _, name in ipairs(register_names()) do
        -- The expression register evaluates on read, so ask for its definition
        -- instead of its (possibly erroring) value.
        local lines = name == "=" and { vim.fn.getreg("=", 1) } or vim.fn.getreg(name, 1, true)
        ---@cast lines string[]
        entries[#entries + 1] = {
            name    = name,
            lines   = lines,
            regtype = vim.fn.getregtype(name),
            display = to_display(lines),
        }
    end
    return entries
end

---@return locate.PickerSpec
function M.spec()
    local entries = collect_registers()

    return {
        prompt         = "Registers",
        flags          = FLAGS,
        enable_preview = true,
        previewer      = function(data, _, callback)
            callback({ content = data.lines })
        end,
        finder         = function(query, flags, _, callback)
            local items = {}
            for _, entry in ipairs(entries) do
                if entry.display == "" and not flags.empty then goto continue end

                local match = pickertools.match_label(entry.display, query)
                if match then
                    local chunks = { { ('"%s '):format(entry.name), "Special" } }
                    vim.list_extend(chunks, match.chunks)
                    if entry.regtype:sub(1, 1) == "V" then
                        table.insert(chunks, { " [line]", "Comment" })
                    elseif entry.regtype:sub(1, 1) == "\22" then -- CTRL-V
                        table.insert(chunks, { " [block]", "Comment" })
                    end
                    ---@type locate.Picker.Item
                    -- Deliberately unscored: registers are located by name, and
                    -- the collection order is the one `:registers` shows.
                    table.insert(items, {
                        label_chunks = chunks,
                        data         = {
                            name    = entry.name,
                            lines   = entry.lines,
                            regtype = entry.regtype,
                        },
                    })
                end
                ::continue::
            end
            callback(items)
        end,
        on_confirm     = function(data)
            if data then vim.api.nvim_put(data.lines, data.regtype, true, true) end
        end,
    }
end

return M
