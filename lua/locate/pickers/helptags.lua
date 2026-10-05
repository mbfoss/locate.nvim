local M           = {}

local pickertools = require("locate.base.pickertools")

--- Rows handed to the picker per query. A runtimepath with a few plugins on it
--- carries tens of thousands of tags, and rendering them all costs more than the
--- tail of a fuzzy ranking is ever worth.
local _MAX_ITEMS  = 1000

--- Does `file` satisfy the `--file` filter? Each value is a case-insensitive
--- substring, so `--file opt` finds options.txt. Repeats widen rather than
--- narrow: a tag belongs to exactly one file, so requiring it to match every
--- value could only ever match the values that are substrings of one another.
---@param file string Basename of the tag's help file.
---@param wanted string[]
---@return boolean
local function _in_files(file, wanted)
    local lower = file:lower()
    for _, want in ipairs(wanted) do
        if lower:find(want:lower(), 1, true) then return true end
    end
    return false
end

--- Strip the punctuation tags wrap names in (`'scroll'`, `<ScrollWheelUp>`). To
--- `matchfuzzypos` that leading punctuation is unmatched text, so `'scrolloff'`
--- scores as a mid-string hit and sinks below `hl-Scrollbar`; matching the name
--- earns Vim's start-of-string and exact bonuses instead. Outer edges only, so
--- `i_<S-ScrollWheelUp>` keeps its mode prefix. Also applied to the query.
---@param str string
---@return string name The undecorated name.
---@return integer offset Bytes removed from the front.
local function _undecorate(str)
    local stripped = str:gsub("^[^%w]+", "")
    return (stripped:gsub("[^%w]+$", "")), #str - #stripped
end

--- Index of `:help` tags -> { help file, in-file anchor }, parsed from the
--- `doc/tags` files across the runtimepath (the same index `:help` consults).
--- Each line reads `tag<tab>file<tab>/*tag*`; the anchor is the address with its
--- leading `/` dropped (`/*:write*` -> `*:write*`), searched for literally since
--- the surrounding `*` make it unique. Rebuilt on each picker open rather than
--- memoised, so nothing is retained in module memory between invocations and a
--- newly installed plugin's docs show up straight away.
---@return table<string, { file: string, anchor: string }>
function M.tag_index()
    local tags = {}
    for _, tagfile in ipairs(vim.api.nvim_get_runtime_file("doc/tags", true)) do
        local dir = vim.fs.dirname(tagfile)
        local ok, lines = pcall(vim.fn.readfile, tagfile)
        if ok then
            for _, line in ipairs(lines) do
                local tag, rel, addr = line:match("^([^\t]+)\t([^\t]+)\t(.+)$")
                if tag then
                    tags[tag] = { file = vim.fs.joinpath(dir, rel), anchor = (addr:gsub("^/", "")) }
                end
            end
        end
    end
    return tags
end

--- Build the previewer for a help tag: the whole help file, positioned on the
--- line carrying the tag's anchor. Files are cached for as long as the picker is
--- open so scrolling through tags of the same file re-reads nothing.
---@param index table<string, { file: string, anchor: string }>
---@return locate.Picker.AsyncPreviewLoader
local function make_previewer(index)
    ---@type table<string, string[]>
    local file_cache = {}

    return function(data, _, callback)
        local hit = index[data.tag]
        if not hit then
            callback({})
            return
        end

        local lines = file_cache[hit.file]
        if not lines then
            local ok, content = pcall(vim.fn.readfile, hit.file)
            lines             = (ok and content) or {}
            file_cache[hit.file] = lines
        end

        local lnum = 1
        for i, line in ipairs(lines) do
            if line:find(hit.anchor, 1, true) then
                lnum = i
                break
            end
        end

        callback({
            content  = lines,
            filepath = hit.file,
            filetype = "help",
            pos      = { lnum, 0 },
        })
    end
end

---@return locate.PickerSpec?
function M.spec()
    local index = M.tag_index()
    local tags  = vim.tbl_keys(index)

    if #tags == 0 then
        vim.notify("No help tags found; is 'helptags' up to date?", vim.log.levels.WARN)
        return nil
    end
    table.sort(tags)

    -- Matched against instead of `tags`, carrying the offset that maps positions
    -- back onto the decorated tag. Needs `matchfuzzypos`' dict form: undecorating
    -- is not injective (`scroll` and `'scroll'` collapse), so a returned string
    -- alone could not be traced back to its tag.
    ---@type { name: string, tag: string, offset: integer, file: string }[]
    local candidates = {}
    ---Basenames offered to `--file` completion, deduplicated and sorted.
    local files      = {}
    for i, tag in ipairs(tags) do
        local name, offset = _undecorate(tag:lower())
        local file         = vim.fs.basename(index[tag].file)
        candidates[i]      = { name = name, tag = tag, offset = offset, file = file }
        files[file]        = true
    end
    files = vim.tbl_keys(files)
    table.sort(files)

    -- Built here rather than at module scope: the values are whatever help files
    -- this runtimepath turned out to carry. Not `strict` -- the values are
    -- complete basenames, but a substring of one is a legitimate way to write the
    -- filter, and strictness would reject every such value.
    ---@type locate.queryflags.FlagDef[]
    local flag_schema = {
        { name = "file", type = "value", multi = true, values = files, alias = { "source" }, slot = "name", desc = "filter by help file" },
    }

    return {
        prompt         = "Help Tags",
        enable_preview = true,
        previewer      = make_previewer(index),
        flags          = flag_schema,
        finder         = function(query, flags, _, callback)
            -- Narrowed before matching so the score ranks what survives, and so
            -- `_MAX_ITEMS` spends its rows on the requested file rather than on
            -- better-scoring tags from files the filter excludes.
            local pool = candidates
            if flags.file then
                pool = {}
                for _, cand in ipairs(candidates) do
                    if _in_files(cand.file, flags.file) then pool[#pool + 1] = cand end
                end
            end

            -- Help tag lists run to tens of thousands of entries, so they are
            -- matched in a single batched `matchfuzzypos` (which also ranks them)
            -- instead of one call per tag.
            local matched, positions, scores
            if query == "" then
                matched = pool
            else
                local result = vim.fn.matchfuzzypos(pool, (_undecorate(query:lower())),
                    { key = "name" })
                matched, positions, scores = result[1], result[2], result[3]
            end

            local items = {}
            for i = 1, math.min(#matched, _MAX_ITEMS) do
                local tag    = matched[i].tag
                -- Positions are 0-based into the name; the highlighter wants
                -- 1-based columns into the tag as displayed.
                local offset = matched[i].offset + 1
                local chunks = pickertools.highlight_chunks(tag, positions and vim.tbl_map(
                    function(p) return p + offset end, positions[i]) or nil)
                table.insert(chunks, { "  " .. vim.fs.basename(index[tag].file), "Comment" })
                ---@type locate.Picker.Item
                table.insert(items, {
                    label_chunks = chunks,
                    score        = scores and scores[i] or nil,
                    data         = { tag = tag },
                })
            end
            callback(items)
        end,
        on_confirm     = function(data)
            if data then vim.cmd("help " .. vim.fn.fnameescape(data.tag)) end
        end,
    }
end

return M
