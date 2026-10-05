local M = {}

local pickertools = require("locate.base.pickertools")
local helptags    = require("locate.pickers.helptags")

--- A command entry: the raw info from `nvim_get_commands` (under `info`) tagged
--- with the source flags this picker tracks.  `nvim_get_commands` never returns
--- a `desc` field; for Lua-callback commands the description is reported in
--- `info.definition`, while for `:command`-defined commands `info.definition` is
--- the command body.  Built-ins have no info of their own, so we synthesize one
--- and borrow a one-liner from Neovim's help index as the `definition`.
---@class locate.CommandEntry
---@field is_builtin boolean?
---@field is_buf boolean?
---@field info vim.api.keyset.command_info

---@type locate.queryflags.FlagDef[]
local FLAGS = {
    { name = "buflocal", type = "boolean", desc = "only buffer-local commands" },
    { name = "builtin",  type = "boolean", desc = "only built-in commands" },
    { name = "user",     type = "boolean", desc = "only user-defined commands" },
}

---@type table<string, string>?
local _builtin_desc

--- Short one-line descriptions for built-in Ex commands, parsed on demand from
--- Neovim's bundled `doc/index.txt` (the `ex-cmd-index` table) so they stay in
--- sync with the running version.  Built-ins expose no description of their own.
--- Each entry there reads `|:tag|<tab>:ab[brev]<tab>description`; the full
--- command name is the abbreviation with its `[...]` optional part flattened
--- (`:a[ppend]` -> `append`).  Memoised after the first call.
---@return table<string, string> name -> description
local function builtin_descriptions()
    if _builtin_desc then return _builtin_desc end
    _builtin_desc = {}

    local file = vim.api.nvim_get_runtime_file("doc/index.txt", false)[1]
    if not file then return _builtin_desc end

    local ok, lines = pcall(vim.fn.readfile, file)
    if not ok then return _builtin_desc end

    local in_section = false
    for _, line in ipairs(lines) do
        if not in_section then
            in_section = line:find("*ex-cmd-index*", 1, true) ~= nil
        else
            local abbrev, desc = line:match("^|:[^|]*|%s+:(%S+)%s+(.+)$")
            if abbrev then
                _builtin_desc[(abbrev:gsub("[%[%]]", ""))] = vim.trim(desc)
            end
        end
    end
    return _builtin_desc
end

--- Collect every command available in the current buffer: user/buffer-local
--- commands (with full info) merged over the names reported by completion, so
--- built-ins that have no info entry still show up.
---@return locate.CommandEntry[]
local function collect_commands()
    ---@type table<string, locate.CommandEntry>
    local by_name = {}

    for name, cmd in pairs(vim.api.nvim_get_commands({})) do
        by_name[name] = { info = cmd }
    end
    for name, cmd in pairs(vim.api.nvim_buf_get_commands(0, {})) do
        by_name[name] = { info = cmd, is_buf = true }
    end

    local descs = builtin_descriptions()

    ---@type locate.CommandEntry[]
    local entries = {}
    for _, name in ipairs(vim.fn.getcompletion("", "command")) do
        -- built-ins have no info entry; synthesize one and borrow its blurb
        -- from the help index parsed above.
        ---@diagnostic disable-next-line: missing-fields
        entries[#entries + 1] = by_name[name]
            or { is_builtin = true, info = { name = name, definition = descs[name] } }
    end
    return entries
end

--- Extract just the block documenting `name` from a full help file: from the
--- command's tag anchor down to the line that begins a *different* known command,
--- or the next `====` section rule.  A line begins another command when it
--- defines a `*:tag*` anchor naming some other command; sub-anchors (`*:w_f*`)
--- and error tags (`*E502*`) are not commands, so the block flows through them.
---@param lines string[]                    full help file
---@param anchor string                     the command's anchor, e.g. "*:write*"
---@param name string                       command being previewed
---@param commands table<string, boolean>   set of all known command names
---@return string[]
local function extract_help_section(lines, anchor, name, commands)
    local start
    for i, line in ipairs(lines) do
        if line:find(anchor, 1, true) then
            start = i
            break
        end
    end
    if not start then return lines end

    local function starts_other_command(line)
        for tag in line:gmatch("%*([^%*%s]+)%*") do
            local other = tag:match("^:(.+)$")
            if other and other ~= name and commands[other] then return true end
        end
        return false
    end

    local stop = #lines + 1
    for i = start + 1, #lines do
        if lines[i]:match("^====") or starts_other_command(lines[i]) then
            stop = i
            break
        end
    end

    -- Trim back over trailing blank lines and the next command's leading
    -- anchor/alias lines (e.g. `CTRL-W n` headers, which carry their own `*tag*`
    -- anchors); this command's own trailing prose has none, so it is preserved.
    local last = stop - 1
    while last > start and (lines[last]:match("^%s*$") or lines[last]:find("%*[^%*%s]+%*")) do
        last = last - 1
    end

    local section = {}
    for i = start, last do
        section[#section + 1] = lines[i]
    end
    return section
end

--- Build the `:help :<command>` previewer.  It closes over the freshly-parsed
--- `help_tags` index and a per-session file cache (both discarded when the picker
--- closes); the cache only avoids re-reading the same help file while scrolling.
--- The preview is limited to the command's own help block (see
--- `extract_help_section`).  Commands with no help tag (most user commands) fall
--- back to their description.
---@param help_tags table<string, { file: string, anchor: string }>
---@param commands table<string, boolean>   set of all known command names
---@return locate.Picker.AsyncPreviewLoader
local function make_help_previewer(help_tags, commands)
    ---@type table<string, string[]>
    local file_cache = {}

    local function read_help_file(path)
        local cached = file_cache[path]
        if cached then return cached end
        local ok, lines = pcall(vim.fn.readfile, path)
        lines = (ok and lines) or {}
        file_cache[path] = lines
        return lines
    end

    return function(data, _, callback)
        ---@type locate.CommandEntry
        local cmd  = data.cmd
        local info = cmd.info
        local hit  = help_tags[":" .. info.name]
        local lines = hit and read_help_file(hit.file) or {}

        if not hit or #lines == 0 then
            local fallback = { "No help available for  :" .. info.name }
            if info.definition and info.definition ~= "" then
                fallback[#fallback + 1] = ""
                fallback[#fallback + 1] = info.definition
            end
            callback({ content = fallback })
            return function() end
        end

        local section = extract_help_section(lines, hit.anchor, info.name, commands)
        callback({ content = section, filepath = hit.file, filetype = "help" })
        return function() end
    end
end

--- Split a `match_label` chunk list at a character offset, so the matched
--- name and description portions of a single fuzzy match (run together as
--- one search string) can be styled independently.
---@param chunks string[][]
---@param split_at integer character offset to split at
---@return string[][] left, string[][] right
local function _split_chunks(chunks, split_at)
    local left, right = {}, {}
    local consumed = 0
    for _, chunk in ipairs(chunks) do
        local text, hl = chunk[1], chunk[2]
        local len = vim.fn.strchars(text)
        if consumed >= split_at then
            right[#right + 1] = chunk
        elseif consumed + len <= split_at then
            left[#left + 1] = chunk
        else
            local left_len = split_at - consumed
            left[#left + 1] = hl
                and { vim.fn.strcharpart(text, 0, left_len), hl }
                or { vim.fn.strcharpart(text, 0, left_len) }
            right[#right + 1] = hl
                and { vim.fn.strcharpart(text, left_len), hl }
                or { vim.fn.strcharpart(text, left_len) }
        end
        consumed = consumed + len
    end
    return left, right
end

---@return locate.PickerSpec?
function M.spec()
    local entries = collect_commands()

    if vim.tbl_isempty(entries) then
        vim.notify("No commands found", vim.log.levels.WARN)
        return nil
    end

    ---@type table<string, boolean>
    local command_names = {}
    for _, entry in ipairs(entries) do
        command_names[entry.info.name] = true
    end

    return {
        prompt         = "Commands",
        flags          = FLAGS,
        enable_preview = true,
        previewer      = make_help_previewer(helptags.tag_index(), command_names),
        finder         = function(query, flags, _, callback)
            local items = {}
            for _, cmd in ipairs(entries) do
                if flags.buflocal and not cmd.is_buf then goto continue end
                if flags.builtin and not cmd.is_builtin then goto continue end
                if flags.user and cmd.is_builtin then goto continue end

                local info = cmd.info
                -- `definition` is the description for Lua callbacks, the body for
                -- `:command`-defined commands, and the help one-liner for built-ins.
                -- Matched together with the name so the query can hit either.
                local has_desc = info.definition and info.definition ~= ""
                local search_text = has_desc and (info.name .. "  " .. info.definition) or info.name
                local match = pickertools.match_label(search_text, query)
                if match then
                    local chunks = match.chunks
                    if has_desc then
                        local name_chunks, desc_chunks = _split_chunks(chunks, vim.fn.strchars(info.name))
                        for _, c in ipairs(desc_chunks) do
                            c[2] = c[2] or "Comment"
                        end
                        chunks = name_chunks
                        vim.list_extend(chunks, desc_chunks)
                    end
                    if cmd.is_buf then
                        table.insert(chunks, { " [buf]", "Special" })
                    end
                    table.insert(items, {
                        label_chunks = chunks,
                        score        = match.score,
                        data         = { cmd = cmd },
                    })
                end
                ::continue::
            end
            callback(items)
        end,
        on_confirm     = function(data)
            if not data then return end
            ---@type locate.CommandEntry
            local cmd     = data.cmd
            local info    = cmd.info
            local cmdline = (not cmd.is_builtin and info.nargs ~= "0") and (info.name .. " ") or info.name
            vim.api.nvim_feedkeys(":" .. cmdline, "n", false)
        end,
    }
end

return M
