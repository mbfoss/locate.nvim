local M = {}

local fsutil = require("locate.util.fsutil")

---@param text string The final string to be shown
---@param positions integer[] Matched indices
---@return table[] chunks
local function _build_highlight_chunks(text, positions)
    if not positions or #positions == 0 then
        return { { text } }
    end

    local hl = "LocateMatch"
    local chunks = {}
    local pos_map = {}
    for _, p in ipairs(positions) do pos_map[p] = true end

    local current_chunk = ""
    local last_was_match = pos_map[1] or false
    local nchars = vim.fn.strchars(text)

    for i = 1, nchars do
        local char = vim.fn.strcharpart(text, i - 1, 1)
        local is_match = pos_map[i] or false
        if is_match ~= last_was_match then
            table.insert(chunks, last_was_match and { current_chunk, hl } or { current_chunk })
            current_chunk = char
            last_was_match = is_match
        else
            current_chunk = current_chunk .. char
        end
    end

    if current_chunk ~= "" then
        table.insert(chunks, last_was_match and { current_chunk, hl } or { current_chunk })
    end
    return chunks
end

---@param text string
---@param positions integer[]? 1-based matched char positions
---@return table[] chunks
function M.highlight_chunks(text, positions)
    return _build_highlight_chunks(text, positions or {})
end

-- match_label only knows how to *find* `query` in `text`; it never reasons about
-- case. Case sensitivity is layered on top separately by the gate below.

---@param text string What we match against
---@param query string User input
---@return {score:number?,chunks:string[][]}?
function M.match_label(text, query)
    if query == "" then
        return { score = nil, chunks = _build_highlight_chunks(text, {}) }
    end
    -- matchfuzzypos is smart-case (a lowercase query char matches either case), so
    -- a lowercased query yields plain case-insensitive fuzzy matching.
    local result = vim.fn.matchfuzzypos({ text }, query:lower())
    if #result[1] == 0 then return nil end
    local positions = {}
    for _, p in ipairs(result[2][1]) do
        positions[#positions + 1] = p + 1 -- matchfuzzypos is 0-based; chunks want 1-based
    end
    return { score = result[3][1], chunks = _build_highlight_chunks(text, positions) }
end

-- The case concept, standalone: given the same text/query as match_label, does a
-- *case-exact* subsequence exist, and where? Returns the 1-based char positions
-- of that match (for highlighting) or nil.

---@param text string
---@param query string
---@return integer[]?
function M.case_subseq(text, query)
    -- Greedy earliest matching is complete: if any case-exact subsequence exists
    -- it finds one, so there are no false negatives.
    local positions = {}
    local tn        = vim.fn.strchars(text)
    local qn        = vim.fn.strchars(query)
    local qi        = 0
    for ti = 0, tn - 1 do
        if qi >= qn then break end
        if vim.fn.strcharpart(text, ti, 1) == vim.fn.strcharpart(query, qi, 1) then
            positions[#positions + 1] = ti + 1
            qi = qi + 1
        end
    end
    if qi < qn then return nil end
    return positions
end

-- Match a glob `[...]` class against one char. `j` is the 1-indexed position
-- just inside the `[`. Supports `!`/`^` negation, `a-z` ranges, `\` escapes, a
-- literal leading `]`. Returns `matched, next_index` (past `]`), `nil` if unterminated.
---@param pat string
---@param j integer
---@param ch string
---@return boolean? matched, integer? next_index
local function _class_match(pat, j, ch)
    local plen   = #pat
    local negate = false
    local c0     = pat:sub(j, j)
    if c0 == "!" or c0 == "^" then
        negate = true
        j      = j + 1
    end

    local matched = false
    local first   = true -- a `]` in first position is a literal member
    while j <= plen do
        local c = pat:sub(j, j)
        if c == "]" and not first then
            if negate then matched = not matched end
            return matched, j + 1
        end
        first = false

        if c == "\\" and j < plen then
            if pat:sub(j + 1, j + 1) == ch then matched = true end
            j = j + 2
        elseif pat:sub(j + 1, j + 1) == "-"
            and pat:sub(j + 2, j + 2) ~= ""
            and pat:sub(j + 2, j + 2) ~= "]" then
            local lo, hi = c, pat:sub(j + 2, j + 2)
            if ch >= lo and ch <= hi then matched = true end
            j = j + 3
        else
            if c == ch then matched = true end
            j = j + 1
        end
    end

    return nil -- unterminated `[`
end

-- Match one glob segment (no `/`) against one path component: `*` any run, `?`
-- any single char, `[...]` a class, `\` escapes; else literal. Indices 1-indexed.
-- `*`/`?` can't cross `/` (enforced by `_match_components` splitting on `/`).
---@param pat string
---@param pi integer
---@param str string
---@param ti integer
---@return boolean
local function _seg_match(pat, pi, str, ti)
    local plen, slen = #pat, #str
    while pi <= plen do
        local pc = pat:sub(pi, pi)
        if pc == "*" then
            -- collapse runs of `*` and try the remainder at every split point
            while pat:sub(pi, pi) == "*" do pi = pi + 1 end
            if pi > plen then return true end
            for k = ti, slen + 1 do
                if _seg_match(pat, pi, str, k) then return true end
            end
            return false
        elseif pc == "?" then
            if ti > slen then return false end
            pi, ti = pi + 1, ti + 1
        elseif pc == "[" then
            if ti > slen then return false end
            local m, next_pi = _class_match(pat, pi + 1, str:sub(ti, ti))
            if m == nil then
                if str:sub(ti, ti) ~= "[" then return false end
                pi, ti = pi + 1, ti + 1
            else
                if not m then return false end
                ---@cast next_pi -nil
                pi, ti = next_pi, ti + 1
            end
        elseif pc == "\\" and pi < plen then
            if str:sub(ti, ti) ~= pat:sub(pi + 1, pi + 1) then return false end
            pi, ti = pi + 2, ti + 1
        else
            if str:sub(ti, ti) ~= pc then return false end
            pi, ti = pi + 1, ti + 1
        end
    end
    return ti > slen
end

-- Match glob segments against path components, honouring `**` (globstar): a
-- leading or interior `**` matches zero or more components, a trailing `**` one
-- or more (everything inside a directory, per gitignore's `abc/**`).
---@param gsegs string[]
---@param gi integer
---@param psegs string[]
---@param pj integer
---@return boolean
local function _match_components(gsegs, gi, psegs, pj)
    while gi <= #gsegs do
        if gsegs[gi] == "**" then
            if gi == #gsegs then
                return pj <= #psegs
            end
            for k = pj, #psegs + 1 do
                if _match_components(gsegs, gi + 1, psegs, k) then return true end
            end
            return false
        end
        if pj > #psegs then return false end
        if not _seg_match(gsegs[gi], 1, psegs[pj], 1) then return false end
        gi, pj = gi + 1, pj + 1
    end
    return pj > #psegs
end

-- Split a glob into its polarity and its path segments. Returns `nil` when the
-- pattern carries no glob at all (`""`, `"!"`), which selects nothing.
---@param pattern string
---@return string[]? gsegs
---@return boolean negated
local function _parse_glob(pattern)
    -- only the first `!` is special, mirroring gitignore/rg
    local negated = pattern:sub(1, 1) == "!"
    if negated then pattern = pattern:sub(2) end

    local trimmed = pattern:gsub("/+$", "") -- a trailing `/` only marks directories
    if trimmed == "" then return nil, negated end

    local pat
    if trimmed:find("/", 1, true) then
        pat = trimmed:gsub("^/+", "") -- a leading `/` just anchors to the root
    else
        pat = "**/" .. trimmed        -- no separator → match the basename anywhere
    end

    return vim.split(pat, "/", { plain = true }), negated
end

--- Match a path against a *list* of globs the way ripgrep applies `--glob`.
---
--- The last glob that applies to the path decides: a positive glob includes it,
--- a negated (`!`) glob excludes it. So `{"*.lua", "!*_spec.lua"}` keeps Lua
--- files but drops the specs, while flipping the order keeps the specs too.
--- When nothing applies, the path is kept only if the list is all negations:
--- a single positive glob turns the list into a whitelist. An empty list keeps
--- everything.
---
--- Per-pattern semantics mirror ripgrep `--glob` (case-sensitive; pass `nocase`
--- for the `--iglob` equivalent):
---   * `*`      matches any run of characters except `/`
---   * `?`      matches any single character except `/`
---   * `[...]`  a character class (`[!...]`/`[^...]` negate, `a-z` ranges)
---   * `**`     as a whole path component matches zero or more directories;
---              a trailing `/**` matches everything inside a directory
---   * a pattern with no `/` matches the basename at any depth (e.g. `*.txt`),
---     while a pattern containing `/` is anchored to the path root (`src/*.txt`)
---   * a leading `!` negates the pattern (`!*.txt` excludes every `*.txt`);
---     `\!` starts a pattern with a literal `!`
---@param patterns string[] rg-style globs, applied in order
---@param relpath string    relative file path (e.g. "lua/locate/util/foo.lua")
---@param nocase boolean?   when true, match case-insensitively (like `rg --iglob`)
---@return boolean
function M.match_globs(patterns, relpath, nocase)
    if #patterns == 0 then return true end
    if nocase then relpath = relpath:lower() end

    local psegs = vim.split(relpath, "/", { plain = true })
    local decided = nil ---@type boolean?
    local has_positive = false

    for _, pattern in ipairs(patterns) do
        local gsegs, negated = _parse_glob(nocase and pattern:lower() or pattern)
        if gsegs then
            if not negated then has_positive = true end
            if _match_components(gsegs, 1, psegs, 1) then decided = not negated end
        end
    end

    if decided ~= nil then return decided end
    return not has_positive
end

---@type locate.Picker.AsyncPreviewLoader
function M.file_preview(data, _, callback)
    local _max_size = 10124 * 10124
    local _filepath = data.filepath
    if not _filepath or _filepath == "" then
        callback({})
        return
    end
    if not fsutil.file_exists(_filepath) then
        callback({ error_msg = "Invalid file path: " .. tostring(_filepath) })
        return
    end
    local _cancelled = false
    local _cancel_fn
    vim.uv.fs_stat(_filepath, vim.schedule_wrap(function(stat_err, stat)
        if _cancelled then return end
        if stat_err or not stat then
            callback({ error_msg = stat_err })
            return
        end
        if stat.size > _max_size then
            callback({ error_msg = "Maximum file size exceeded" })
            return
        end
        _cancel_fn = fsutil.async_load_text_file(_filepath, { timeout = 3000 },
            function(load_err, content)
                callback({
                    content   = content,
                    filepath  = _filepath,
                    pos       = data.lnum and { data.lnum, data.col or 0 } or nil,
                    error_msg = load_err,
                })
            end)
    end))
    return function()
        _cancelled = true
        if _cancel_fn then _cancel_fn() end
    end
end

--- Preview the live buffer `data.bufnr` when it is loaded: the previewed text is
--- then the in-memory one (unsaved edits included) and it arrives with whatever
--- highlighting is already attached to that buffer. Entries with no live buffer
--- fall back to the on-disk `file_preview`.
---@type locate.Picker.AsyncPreviewLoader
function M.buffer_preview(data, opts, callback)
    local bufnr = data.bufnr
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
        callback({
            bufnr = bufnr,
            pos   = data.lnum and { data.lnum, data.col or 0 } or nil,
        })
        return
    end
    return M.file_preview(data, opts, callback)
end

---@param name string
---@param opts {max_entries:number?}?
---@return locate.Picker.QueryHistoryProvider
function M.make_history_provider(name, opts)
    opts = opts or {}

    assert(type(name) == "string" and name:match("^[%w_]+$"), "invalid name")
    assert(not opts.max_entries or type(opts.max_entries) == "number")

    local dir = vim.fs.joinpath(vim.fn.stdpath("state"), "locate")
    local file_path = vim.fs.joinpath(dir, "pickhist." .. name .. ".json")
    local max_entries = opts.max_entries or 50
    ---@type locate.Picker.QueryHistoryProvider
    local provider = {
        load = function()
            local ok, content = fsutil.read_content(file_path)
            if not ok then
                return {}
            end
            local decoded_ok, decoded = pcall(vim.json.decode, content)
            if not decoded_ok or type(decoded) ~= "table" or not vim.islist(decoded) then
                return {}
            end
            return decoded
        end,
        ---@param hist string[]
        store = function(hist)
            vim.fn.mkdir(dir, 'p')
            local start_idx = math.max(#hist - max_entries + 1, 1)
            local final_hist = {}
            for i = start_idx, #hist do
                table.insert(final_hist, hist[i])
            end
            fsutil.write_content(file_path, vim.json.encode(final_hist))
        end
    }

    return provider
end


return M
