local M = {}

local pickertools = require("locate.base.pickertools")
local ui          = require("locate.util.ui")

---@type locate.queryflags.FlagDef[]
local FLAGS = {
    { name = "event", type = "value", multi = true, slot = "name",    desc = "filter by event name" },
    { name = "group", type = "value", multi = true, slot = "name",    desc = "filter by augroup"    },
    { name = "pat",   type = "value", multi = true, slot = "pattern", desc = "filter by pattern"    },
}

---Where an autocommand was declared. A Lua callback carries its own chunk name
---and line, so `debug.getinfo` answers directly; anything defined in Vimscript
---has to be asked of `:verbose autocmd`, which reports "Last set from <file>
---line <n>". Between them that is all the source information Neovim exposes,
---an autocommand with neither cannot be located at all.
---@param ac vim.api.keyset.get_autocmds.ret
---@return {filepath:string, lnum:integer}?
local function find_declaration(ac)
    if type(ac.callback) == "function" then
        local info = debug.getinfo(ac.callback, "S")
        -- A chunk read from a file names itself "@/path/to/file.lua"; one built
        -- from a string (`:lua`, `luaeval`) has no file to open.
        if info and info.source and info.source:sub(1, 1) == "@" then
            return { filepath = info.source:sub(2), lnum = math.max(info.linedefined, 1) }
        end
        return nil
    end

    local parts = { "verbose autocmd" }
    if ac.group_name and ac.group_name ~= "" then table.insert(parts, ac.group_name) end
    table.insert(parts, ac.event)
    table.insert(parts, (ac.pattern and ac.pattern ~= "") and ac.pattern or "*")

    -- Patterns come from the user's config and may hold anything, so the
    -- assembled Ex command is not guaranteed to parse.
    local ok, out = pcall(vim.fn.execute, table.concat(parts, " "), "silent")
    if not ok or type(out) ~= "string" then return nil end

    -- Line by line: the query can still match several autocommands, and a
    -- pattern spanning the whole output would report the last one's source.
    for line in out:gmatch("[^\n]+") do
        local file, lnum = line:match("Last set from (.*) line (%d+)")
        if file then
            return { filepath = vim.fs.normalize(file), lnum = tonumber(lnum) }
        end
    end
    return nil
end

---@param ac vim.api.keyset.get_autocmds.ret
---@param decl {filepath:string, lnum:integer}?
local function format_preview(ac, decl)
    local function fmt(val)
        if val == nil then return nil end
        if type(val) == "table"   then return table.concat(val, ", ") end
        if type(val) == "boolean" then return val and "true" or "false" end
        return tostring(val)
    end

    local function add(lines, label, value)
        local v = fmt(value)
        if v and v ~= "" then
            table.insert(lines, string.format("- %s: %s", label, v))
        end
    end

    local lines = {}
    add(lines, "ID",          ac.id)
    add(lines, "Group",       ac.group_name or ac.group)
    add(lines, "Event",       ac.event)
    add(lines, "Pattern",     ac.pattern or "*")
    add(lines, "Description", ac.desc)
    add(lines, "Once",        ac.once)
    add(lines, "Buflocal",    ac.buflocal)
    ---@diagnostic disable-next-line: undefined-field
    add(lines, "Buffer",      ac.buffer)

    table.insert(lines, "")
    table.insert(lines, "Action:")

    if ac.command and ac.command ~= "" then
        vim.list_extend(lines, vim.split(ac.command, "\n"))
    elseif ac.callback then
        table.insert(lines, "- Type: Lua callback")
    else
        table.insert(lines, "_No action defined_")
    end

    table.insert(lines, "")
    if decl then
        table.insert(lines, string.format("Declared in `%s` line %d", decl.filepath, decl.lnum))
    else
        table.insert(lines, "_Declaration site unknown_")
    end

    return table.concat(lines, "\n")
end

---@return locate.PickerSpec?
function M.spec()
    local entries = vim.api.nvim_get_autocmds({})

    if vim.tbl_isempty(entries) then
        vim.notify("No autocommands found", vim.log.levels.WARN)
        return nil
    end

    -- Resolving a declaration shells out to `:verbose autocmd`, and the preview
    -- asks for one on every cursor move, so each answer is kept next to the
    -- entry that produced it. The cache lives and dies with this picker session.
    ---@type table<table, {filepath:string, lnum:integer}|false>
    local declarations = {}

    ---@param ac vim.api.keyset.get_autocmds.ret
    ---@return {filepath:string, lnum:integer}?
    local function declaration(ac)
        local cached = declarations[ac]
        if cached == nil then
            cached           = find_declaration(ac) or false
            declarations[ac] = cached
        end
        return cached or nil
    end

    return {
        prompt          = "Autocommands",
        flags           = FLAGS,
        enable_preview  = true,
        finder          = function(query, flags, _, callback)
            local items = {}

            for _, ac in ipairs(entries) do
                local group   = (ac.group_name or ac.group or ""):lower()
                local event   = (ac.event or ""):lower()
                local pattern = (ac.pattern and ac.pattern ~= "" and ac.pattern or "*"):lower()

                local skip = false
                for _, v in ipairs(flags.event or {}) do
                    if not event:find(v:lower(), 1, true) then skip = true; break end
                end
                if not skip then
                    for _, v in ipairs(flags.group or {}) do
                        if not group:find(v:lower(), 1, true) then skip = true; break end
                    end
                end
                if not skip then
                    for _, v in ipairs(flags.pat or {}) do
                        if not pattern:find(v:lower(), 1, true) then skip = true; break end
                    end
                end
                if skip then goto continue end

                local label = string.format(
                    "%s │ %s │ %s",
                    ac.group_name or ac.group or "",
                    ac.event or "",
                    (ac.pattern and ac.pattern ~= "") and ac.pattern or "*"
                )

                local match      = query ~= "" and pickertools.match_label(label, query)
                    or { chunks = { { label } } }
                local virt_line  = (ac.desc and ac.desc ~= "") and { { ac.desc, "Comment" } } or nil

                if match then
                    table.insert(items, {
                        label_chunks = match.chunks,
                        score        = match.score,
                        virt_line    = virt_line,
                        data         = { ac = ac },
                    })
                end

                ::continue::
            end
            callback(items)
        end,
        previewer = function(data, _, callback)
            callback({ content = format_preview(data.ac, declaration(data.ac)) })
            return function() end
        end,
        on_confirm = function(data)
            if not data then return end
            local decl = declaration(data.ac)
            if not decl then
                vim.notify(
                    string.format("No declaration site recorded for %s %s",
                        data.ac.event,
                        (data.ac.pattern and data.ac.pattern ~= "") and data.ac.pattern or "*"),
                    vim.log.levels.WARN
                )
                return
            end
            ui.smart_open_file(decl.filepath, decl.lnum, 0)
        end,
    }
end

return M
