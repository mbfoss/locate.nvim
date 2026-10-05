local M = {}

local pickertools = require("locate.base.pickertools")

---@class locate.spell.Opts
---@field limit number?

---@param opts locate.spell.Opts?
---@return locate.PickerSpec?
function M.spec(opts)
    opts = opts or {}

    -- expand("<cword>") raises E348 when no word is under the cursor (empty or
    -- whitespace-only line), so the error must be caught rather than checked for.
    local ok, cursor_word = pcall(vim.fn.expand, "<cword>")
    if not ok or cursor_word == "" then
        vim.notify("No word under cursor", vim.log.levels.WARN)
        return nil
    end
    ---@cast cursor_word string

    local suggestions = vim.fn.spellsuggest(cursor_word, opts.limit or 25)

    if #suggestions == 0 then
        vim.notify("No spell suggestions found for: " .. cursor_word, vim.log.levels.INFO)
        return nil
    end

    return {
        prompt = "Spell Checker: " .. cursor_word,
        finder = function(query, _, _, callback)
            local items = {}
            for _, word in ipairs(suggestions) do
                -- Deliberately unscored: `spellsuggest()` already ranks these
                -- by how likely the correction is, and that ordering is the
                -- answer to the question the picker was opened to ask.
                local match = pickertools.match_label(word, query)
                if match then
                    table.insert(items, {
                        label_chunks = match.chunks,
                        data         = { word = word },
                    })
                end
            end
            callback(items)
        end,
        on_confirm = function(data)
            if data then vim.cmd("normal! ciw" .. data.word) end
        end,
    }
end

return M
