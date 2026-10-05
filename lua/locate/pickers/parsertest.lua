local M = {}

-- A scratch picker whose list is the parse of its own prompt: the query is not
-- searched for, it is the input under test. The schema below exercises every
-- FlagDef feature, so the flag section is worth typing into. Not documented,
-- and meant to be deleted once the parser stops changing.
--
-- The picker refetches on a changed query or flags, so an edit that alters only
-- an error's span leaves the error rows a keystroke behind.

---@type locate.queryflags.FlagDef[]
local FLAGS = {
    { name = "switch", type = "boolean", alias = { "sw" }, desc = "a switch: set by being written" },
    { name = "value",  type = "value",   slot = "text", desc = "one value, written after the =" },
    { name = "list",   type = "value",   multi = true, slot = "item", desc = "comma-separated values" },
    { name = "kind",   type = "value",   multi = true, values = { "alpha", "beta", "gamma" }, slot = "name", desc = "comma-separated, with candidates" },
    { name = "choice", type = "value",   strict = true, values = { "on", "off", "auto" }, slot = "one", desc = "strict: only its own values" },
    { name = "file",   type = "value",   complete = "file", slot = "path", desc = "completed from the filesystem" },
}

---Every value is quoted, a list one element at a time: a comma inside a value
---and a comma that split one apart have to be told apart on sight.
---@param value boolean|string|string[]
---@return string
local function show(value)
    if type(value) == "boolean" then return tostring(value) end
    if type(value) == "string"  then return ("%q"):format(value) end

    local quoted = {}
    for k, v in ipairs(value) do quoted[k] = ("%q"):format(v) end
    return "{ " .. table.concat(quoted, ", ") .. " }"
end

---One row per fact of the parse, in reading order: the query, then the flags in
---schema order, then the errors as `parse` sorted them.
---@param parsed locate.Picker.ParsedPrompt
---@return locate.Picker.Item[]
local function rows(parsed)
    local items = {}

    ---The kind names the column, so it is the only thing styled; the fact
    ---itself is read, not scanned.
    ---@param kind string
    ---@param text string
    ---@param virt string?
    local function add(kind, text, virt)
        table.insert(items, {
            label_chunks = { { ("%-6s "):format(kind), "NonText" }, { text } },
            virt_line    = virt and { { virt, "Comment" } } or nil,
            data         = { line = ("%s %s"):format(kind, text) },
        })
    end

    add("query", ("%q"):format(parsed.query))

    for _, def in ipairs(FLAGS) do
        local value = parsed.flags[def.name]
        if value ~= nil then
            add("flag", ("%s = %s"):format(def.name, show(value)))
        end
    end

    for _, err in ipairs(parsed.errors) do
        add("error", ("[%d,%d)%s"):format(
            err.start, err.finish, err.settled and " settled" or ""), err.msg)
    end

    return items
end

---@return locate.PickerSpec
function M.spec()
    return {
        prompt         = "Parser test",
        flags          = FLAGS,
        enable_preview = true,
        finder         = function(query, flags, opts, callback)
            -- `parsed` is what the prompt was read as; without it (a caller
            -- driving the finder directly) the arguments are all there is.
            local parsed = opts.parsed
                or { query = query, flags = flags, errors = {} }
            local dump   = vim.inspect(parsed)

            local items = rows(parsed)
            for _, item in ipairs(items) do item.data.dump = dump end
            callback(items)
        end,
        previewer      = function(data, _, callback)
            callback({ content = data.dump, filetype = "lua" })
            return function() end
        end,
        on_confirm     = function(data)
            if not data then return end
            vim.fn.setreg('"', data.line)
            vim.notify(data.line)
        end,
    }
end

return M
