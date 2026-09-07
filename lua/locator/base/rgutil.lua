local M      = {}

local config = require("locator.config")

---The ripgrep executable: `rg_path` when set, otherwise `rg` off the `PATH`.
---Read per call so a `setup()` after this module loaded is honoured.
---@return string
function M.exe()
    local path = config.current.rg_path
    if path and path ~= "" then return path end
    return "rg"
end

---@class locator.rgutil.Submatch
---@field s    integer  -- 0-indexed byte start in the line
---@field e    integer  -- 0-indexed byte end (exclusive) in the line

---@class locator.rgutil.Match
---@field path string
---@field lnum integer
---@field col  integer  -- 1-indexed byte column of the first submatch
---@field text string
---@field subs locator.rgutil.Submatch[]

---One `--json` line from rg, decoded. Nil for the records that are not matches
---(`begin`, `end`, `summary`) and for a line that is not JSON at all.
---@param line string
---@return locator.rgutil.Match?
function M.parse_match(line)
    local ok, decoded = pcall(vim.json.decode, line)
    if not ok or not decoded or decoded.type ~= "match" then return end

    local data = decoded.data
    local path = data.path and data.path.text
    if not path then return end

    local text = data.lines.text or data.lines.bytes or ""
    text       = text:gsub("\r?\n$", "")

    local subs = {}
    for _, m in ipairs(data.submatches or {}) do
        subs[#subs + 1] = { s = m.start, e = m["end"] }
    end

    local col = (subs[1] and subs[1].s + 1) or 1
    return { path = path, lnum = data.line_number, col = col, text = text, subs = subs }
end

---The line's text in chunks, the spans rg matched carrying `LocatorMatch`
---so the picker draws them as the match they are.
---@param text string
---@param subs locator.rgutil.Submatch[]
---@return {[1]:string,[2]:string?}[]
function M.build_chunks(text, subs)
    local chunks = {}
    local last   = 1
    for _, sm in ipairs(subs) do
        local s = sm.s + 1
        local e = sm.e
        if s > last then
            chunks[#chunks + 1] = { text:sub(last, s - 1) }
        end
        chunks[#chunks + 1] = { text:sub(s, e), "LocatorMatch" }
        last = e + 1
    end
    if last <= #text then
        chunks[#chunks + 1] = { text:sub(last) }
    end
    return chunks
end

--- Strip surrounding whitespace for display, shifting the submatch offsets to
--- match. Trimming never eats into a submatch (a query can match whitespace),
--- so whitespace that is part of the result is kept. Display only; `data.subs`
--- keeps the original offsets into the untrimmed line.
---@param text string
---@param subs locator.rgutil.Submatch[]
---@return string text, locator.rgutil.Submatch[] subs
function M.trim_for_display(text, subs)
    local lead = #text:match("^%s*")
    local tail = #text - #text:match("%s*$")
    for _, sm in ipairs(subs) do
        if sm.s < lead then lead = sm.s end
        if sm.e > tail then tail = sm.e end
    end
    if lead == 0 and tail == #text then return text, subs end

    local shifted = {}
    for i, sm in ipairs(subs) do
        shifted[i] = { s = sm.s - lead, e = sm.e - lead }
    end
    return text:sub(lead + 1, tail), shifted
end

--- rg's file types (`rg --type-list`), parsed once per session: `{ lua = { "*.lua" }, … }`.
---@type table<string, string[]>?
local _rg_types

---@return table<string, string[]>
function M.types()
    if _rg_types then return _rg_types end

    local types = {}
    local exe   = M.exe()
    if vim.fn.executable(exe) == 1 then
        local res = vim.system({ exe, "--no-config", "--type-list" }, { text = true }):wait()
        if res.code == 0 then
            for line in vim.gsplit(res.stdout or "", "\n", { trimempty = true }) do
                local name, globs = line:match("^([^:]+):%s*(.+)$")
                if name then
                    local list = {}
                    for g in vim.gsplit(globs, ",", { trimempty = true }) do
                        list[#list + 1] = vim.trim(g)
                    end
                    types[name] = list
                end
            end
        end
    end

    _rg_types = types
    return types
end

---@param partial string
---@return string[]
function M.complete_type(partial)
    local names = vim.tbl_keys(M.types())
    table.sort(names)
    return vim.tbl_filter(function(n) return vim.startswith(n, partial) end, names)
end

---The flags that say *what* to match, as against where to look for it: the
---part of rg's vocabulary a single buffer can be searched with too.
---@type locator.queryflags.FlagDef[]
M.MATCH_FLAGS = {
    { name = "regex",  type = "boolean", desc = "enable regex mode" },
    { name = "case",   type = "boolean", desc = "case-sensitive (default: smart case)" },
    { name = "nocase", type = "boolean", desc = "case-insensitive (default: smart case)" },
    { name = "word",   type = "boolean", desc = "match whole words only" },
    { name = "line",   type = "boolean", desc = "match whole lines only" },
    { name = "invert", type = "boolean", desc = "show lines that do NOT match" },
}

--- The rg command for a search: the flags they all share, then, when `stdin` is
--- set, the query and the `-` target of a search over text written in. Without
--- it the caller appends its own globs, query and search target.
---@param prompt_details locator.Picker.PromptDetails
---@param stdin boolean?
---@return string[] cmd
function M.build_cmd(prompt_details, stdin)
    local flags = prompt_details.flags
    -- --no-config: the user's RIPGREP_CONFIG_PATH must not change the flags
    -- this picker depends on (--json output, match semantics).
    local args  = { "--no-config", "--json", "--no-heading", "--glob-case-insensitive" }

    if flags.case then
        table.insert(args, "--case-sensitive")
    elseif flags.nocase then
        table.insert(args, "--ignore-case")
    else
        table.insert(args, "--smart-case")
    end

    if not flags.regex then
        table.insert(args, "--fixed-strings")
    end

    if flags.word then
        table.insert(args, "--word-regexp")
    end

    if flags.line then
        table.insert(args, "--line-regexp")
    end

    if flags.invert then
        table.insert(args, "--invert-match")
    end

    if stdin then
        table.insert(args, "--line-buffered")
        table.insert(args, "--")
        table.insert(args, prompt_details.query)
        table.insert(args, "-")
    end

    return vim.list_extend({ M.exe() }, args)
end

return M
