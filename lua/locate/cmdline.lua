local M = {}

-- ---------------------------------------------------------------------------
-- The `:Locate` command line: cutting its arguments into the picker's two
-- prompt sections, and completing the word under the cursor.
-- `plugin/locate.lua` registers the command and requires this only when one is
-- run.
-- ---------------------------------------------------------------------------

---Read one whitespace-delimited token from `str`, starting at `i`. A '\'
---takes the character after it along, so an escaped space stays inside the
---token. Escapes are left as written; queryflags resolves them.
---@param str string
---@param i   integer
---@return string? token, integer next_i
local function _read_token(str, i)
    local n = #str
    while i <= n and str:sub(i, i):match("%s") do i = i + 1 end
    if i > n then return nil, i end

    local start = i
    while i <= n do
        local c = str:sub(i, i)
        if c == "\\" and i < n then
            i = i + 2
        elseif c:match("%s") then
            break
        else
            i = i + 1
        end
    end
    return str:sub(start, i - 1), i
end

---Cut the `:Locate` arguments past the source name into the two prompt sections.
---A line opening on `--flags` reads everything up to the `--` that closes it as
---the flags, and the rest as the query; a line opening on anything else is the
---query alone, so a query needs no quoting and nothing in it is read as a flag.
---@param rest string
---@return string flags, string query
local function _parse_cmdline(rest)
    local tok, i = _read_token(rest, 1)
    if tok ~= "--flags" then
        return "", rest
    end

    local flags = {}
    while true do
        local t
        t, i = _read_token(rest, i)
        if not t or t == "--" then break end
        flags[#flags + 1] = t
    end
    return table.concat(flags, " "), (rest:sub(i):gsub("^%s+", ""))
end

---Candidates for the word under the cursor on the `:Locate` line, past the source
---name. `--flags` opens the flags section and is itself completed while the word
---being typed is still a prefix of it; the section is then completed from the
---source's schema until its `--` opens the query, which is free text. A line
---opening on anything else is already the query.
---@param registry table
---@param source string
---@param before string    -- the command line up to the cursor
---@param arg_lead string
---@return string[]
local function _complete_cmdline(registry, source, before, arg_lead)
    -- The completed tokens behind the cursor: everything up to the word being
    -- typed, which `arg_lead` holds back.
    local head = before:sub(1, #before - #arg_lead)
    local i    = 1
    i = select(2, _read_token(head, i)) -- command name
    i = select(2, _read_token(head, i)) -- source name

    local first
    first, i = _read_token(head, i)
    if first == nil then
        -- The word being typed is the first one past the source: it is, or is
        -- still becoming, `--flags`.
        return vim.tbl_filter(function(k) return vim.startswith(k, arg_lead) end, { "--flags" })
    end
    if first ~= "--flags" then
        return {}
    end

    -- The flags section runs from just past `--flags` to its closing `--`; past
    -- one, the cursor is in the query, which is free text.
    local flags_line = head:sub(i) .. arg_lead
    local j = 1
    while true do
        local t
        t, j = _read_token(flags_line, j)
        if not t then break end
        if t == "--" then return {} end
    end

    local flags = registry.get_flags(source)
    if not flags then return {} end

    local queryflags = require("locate.base.queryflags")
    local comps      = queryflags.get_completions(flags, flags_line, #flags_line)
    if not comps then return {} end

    -- `get_completions` answers in columns of the whole flags line, but the
    -- cmdline replaces only the word under the cursor, so the column is put back
    -- onto that word. Whatever the completion does not claim ("dir=" before a
    -- path) stays in front of it.
    local kept = arg_lead:sub(1, comps.startcol - (#flags_line - #arg_lead) - 1)
    local out  = {}
    for _, item in ipairs(comps.items) do
        table.insert(out, kept .. item.word)
    end
    return out
end

---Open the picker named on the `:Locate` line, seeded with the rest of it.
---@param cmd_opts vim.api.keyset.create_user_command.command_args
function M.run(cmd_opts)
    local source = cmd_opts.fargs[1]
    -- `args` rather than `fargs`: Vim resolves the backslashes in `fargs`,
    -- and a flag value keeps its own (`--flags dir=my\ src`).
    local rest = cmd_opts.args:match("^%S+%s+(.*)$") or ""
    local flags, query = _parse_cmdline(rest)
    require("locate").pick(source, { flags = flags, query = query })
end

---Completion for the `:Locate` line: source names in the first argument, the
---source's flags past it.
---@param arg_lead string
---@param cmd_line string
---@param cursor_pos integer
---@return string[]
function M.complete(arg_lead, cmd_line, cursor_pos)
    local registry = require("locate.registry")
    local before   = cmd_line:sub(1, cursor_pos)
    local parts    = vim.split(before, "%s+", { trimempty = true })
    if #parts <= 1 or (#parts == 2 and not before:match("%s$")) then
        local keys = registry.keys()
        table.insert(keys, "resume")
        table.sort(keys)
        return vim.tbl_filter(function(k) return vim.startswith(k, arg_lead) end, keys)
    end

    return _complete_cmdline(registry, parts[2], before, arg_lead)
end

return M
