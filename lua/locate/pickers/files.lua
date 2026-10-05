local M           = {}

local ui          = require("locate.util.ui")
local strutil     = require("locate.util.strutil")
local fsutil      = require("locate.util.fsutil")
local pickertools = require("locate.base.pickertools")
local icons       = require("locate.icons")

---@class locate.filepicker.Opts
---@field prompt string?
---@field cwd string?
---@field max_results number?

---@alias locate.filepicker.Mode "fuzzy"|"fixed"|"glob"

---@class locate.filepicker.SearchOpts
---@field cwd string The root directory for the search
---@field mode locate.filepicker.Mode? how the query matches a file (default "fuzzy")
---@field max_results number?
---@field case_sensitive boolean?
---@field inpath boolean? match the relative path instead of the basename (like `fd --full-path`)
---@field follow_symlinks boolean?
---@field show_hidden boolean?

---@type locate.queryflags.FlagDef[]
local FLAGS       = {
    { name = "dir",    type = "value",   complete = "dir", slot = "path",   desc = "override search root directory" },
    { name = "fixed",  type = "boolean", desc = "match a literal substring (default: fuzzy)" },
    { name = "glob",   type = "boolean", desc = "read the query as globs over the path: src/*.lua !*_spec.lua" },
    { name = "inpath", type = "boolean", desc = "match the whole relative path, not just the filename" },
    { name = "case",   type = "boolean", desc = "force case-sensitive (default: smart case)" },
    { name = "nocase", type = "boolean", desc = "force case-insensitive (default: smart case)" },
    { name = "follow", type = "boolean", desc = "follow symlinks" },
    { name = "hidden", type = "boolean", desc = "include hidden (dotfiles)" },
}

--- Resolve the case flags into a case-sensitivity decision. `--case` forces
--- sensitive and `--nocase` forces insensitive; with neither, smart case
--- applies: sensitive only when `query` itself contains an uppercase character.
---@param flags table<string, any>
---@param query string
---@return boolean case_sensitive
local function resolve_case(flags, query)
    if flags.case then return true end
    if flags.nocase then return false end
    return query:match("%u") ~= nil
end

--- Resolve the mutually exclusive mode flags into a single mode. Fuzzy is the
--- default; when more than one is set, the order below decides.
---@param flags table<string, any>
---@return locate.filepicker.Mode
local function resolve_mode(flags)
    if flags.glob then return "glob" end
    if flags.fixed then return "fixed" end
    return "fuzzy"
end

--- Fuzzy-match a filename against the query, then apply the case gate on top.
--- The matcher itself is case-insensitive; when `case_sensitive` is set the
--- subsequence is re-checked with case and re-highlighted on a hit.
---@param filename string
---@param query string
---@param case_sensitive boolean?
---@return {score:number, chunks:table[]}?
local function fuzzy_match(filename, query, case_sensitive)
    local res = pickertools.match_label(filename, query)
    if not res then return nil end
    if case_sensitive then
        local pos = pickertools.case_subseq(filename, query)
        if not pos then return nil end
        res = { score = res.score, chunks = pickertools.highlight_chunks(filename, pos) }
    end
    return res
end

--- Literal (fixed-string) substring match, highlighting the matched run.
--- Matches case-insensitively unless `case_sensitive`; earlier matches score
--- higher so they sort ahead.
---@param filename string
---@param query string
---@param case_sensitive boolean?
---@return {score:number, chunks:table[]}?
local function fixed_match(filename, query, case_sensitive)
    if query == "" then
        return { score = 0, chunks = pickertools.highlight_chunks(filename) }
    end
    local haystack = case_sensitive and filename or filename:lower()
    local needle   = case_sensitive and query or query:lower()
    local byte_s   = haystack:find(needle, 1, true)
    if not byte_s then return nil end

    -- Convert the matched byte span into 1-based char positions for highlighting.
    local char_s    = vim.fn.charidx(filename, byte_s - 1)
    local qn        = vim.fn.strchars(query)
    local positions = {}
    for k = 0, qn - 1 do positions[#positions + 1] = char_s + 1 + k end
    return { score = -byte_s, chunks = pickertools.highlight_chunks(filename, positions) }
end

--- Split a glob-mode query into the sequence of globs it names.
--- Globs are whitespace separated, so `*.lua !*_spec.lua` reads as an rg
--- `--glob *.lua --glob !*_spec.lua` invocation.
---@param query string
---@return string[]
local function split_globs(query)
    return vim.split(query, "%s+", { trimempty = true })
end

--- Match a file against the query under the selected `mode`:
---   * "fuzzy" (default) : fuzzy subsequence over the target
---   * "fixed"           : literal substring over the target
---   * "glob"            : rg-style globs over the relative path (unhighlighted)
--- The target is the basename, or the whole relative path under `inpath`
--- (like `fd --full-path`). Glob mode always matches the relative path: the
--- flag only widens what its chunks describe.
--- The returned chunks describe exactly the target, and the row is assembled
--- to suit (see `make_file_item`).
---@param filename string
---@param relpath string
---@param query string
---@param mode locate.filepicker.Mode?
---@param case_sensitive boolean?
---@param globs string[]? `query` pre-split by `split_globs` (glob mode only)
---@param inpath boolean? match the relative path instead of the basename
---@return {score:number, chunks:table[]}?
local function do_match(filename, relpath, query, mode, case_sensitive, globs, inpath)
    local target = inpath and relpath or filename
    if mode == "glob" then
        globs = globs or split_globs(query)
        if not pickertools.match_globs(globs, relpath, not case_sensitive) then return nil end
        return { score = 0, chunks = pickertools.highlight_chunks(target) }
    elseif mode == "fixed" then
        return fixed_match(target, query, case_sensitive)
    end
    return fuzzy_match(target, query, case_sensitive)
end

--- Build a result row for a matched file: the filetype icon (when an icon
--- provider is available), its directory prefix, then the matched chunks
--- (fuzzy match highlight). Under `inpath` the chunks already cover the
--- whole relative path, so the directory prefix is left off rather than
--- printed twice.
---@param filepath string
---@param filename string
---@param relative_path string
---@param name_chunks table[]
---@param score number? Match quality; the picker ranks on it.
---@param inpath boolean? `name_chunks` describes the relative path, not the basename
---@return locate.Picker.Item
local function make_file_item(filepath, filename, relative_path, name_chunks, score, inpath)
    local filedir       = inpath and "" or relative_path:sub(1, #relative_path - #filename)
    local icon, icon_hl = icons.get_icon(filename)
    local chunks        = icon and { { icon, icon_hl }, { " " }, { filedir } } or { { filedir } }
    vim.list_extend(chunks, name_chunks)
    return {
        label_chunks = chunks,
        score        = score,
        data         = { filepath = filepath },
    }
end

---@param query string User input
---@param opts locate.filepicker.SearchOpts
---@param fetch_opts locate.Picker.FetcherOpts
---@param callback fun(items:locate.Picker.Item[]?)
local function async_lua_search(query, opts, fetch_opts, callback)
    local count              = 0
    local max_results        = opts.max_results or 10000
    local items              = {}
    local mode               = opts.mode or "fuzzy"
    local globs              = mode == "glob" and split_globs(query) or nil

    local base_excludes      = opts.show_hidden and {} or { ".*", "**/.*" }
    local exclude_regex_list = vim.tbl_map(strutil.compile_glob, base_excludes)

    local aborted            = false
    local walk_cancel ---@type fun()?
    -- `on_file` cancels the walk once `max_results` is reached, which must hold
    -- even if a slice ever runs before `walk_cancel` is assigned: latch the
    -- request and apply it on return.
    local cancel_requested   = false
    local function cancel_walk()
        cancel_requested = true
        if walk_cancel then walk_cancel() end
    end

    walk_cancel = fsutil.async_walk_dir(
        opts.cwd,
        {
            exclude_regex_list = exclude_regex_list,
            follow_symlinks    = opts.follow_symlinks,
            -- No per-directory redraw: results are only handed over in
            -- `on_done`, so a redraw mid-walk showed nothing new. The walk's
            -- inter-slice yield lets Neovim redraw (and animate the spinner)
            -- on its own.
            on_file            = function(filepath, filename, relative_path)
                local res = do_match(filename, relative_path, query, mode, opts.case_sensitive, globs,
                    opts.inpath)
                if not res then return end
                if count >= max_results then
                    cancel_walk()
                    return
                end
                items[#items + 1] = make_file_item(filepath, filename, relative_path, res.chunks, res.score,
                    opts.inpath)
                count = count + 1
            end,
            on_done            = function()
                if aborted then return end
                -- Ranking is the picker's job: it sorts on the score carried by
                -- each item, and leaves the walk order alone for an empty query.
                callback(items)
                callback(nil)
            end
        })

    if cancel_requested then walk_cancel() end

    return function()
        aborted = true
        cancel_walk()
    end
end

---@param opts locate.filepicker.Opts?
---@return locate.PickerSpec
function M.spec(opts)
    opts = opts or {}
    return {
        prompt             = opts.prompt or "Files",
        flags              = opts.cwd and vim.tbl_filter(function(f) return f.name ~= "dir" end, FLAGS) or FLAGS,
        enable_preview     = true,
        finder             = function(query, flags, fetch_opts, callback)
            if not query or query == "" then
                callback()
                return
            end

            local target_cwd = flags.dir or opts.cwd or vim.fn.getcwd()
            target_cwd = vim.fn.expand(target_cwd)

            ---@type locate.filepicker.SearchOpts
            local search_opts = {
                cwd             = target_cwd,
                mode            = resolve_mode(flags),
                max_results     = opts.max_results,
                case_sensitive  = resolve_case(flags, query),
                inpath          = flags.inpath,
                follow_symlinks = flags.follow,
                show_hidden     = flags.hidden,
            }
            return async_lua_search(query, search_opts, fetch_opts, callback)
        end,
        quickfix_formatter = function(data)
            ---@type vim.quickfix.entry
            return { filename = data.filepath }
        end,
        on_confirm         = function(data)
            if data and data.filepath then ui.smart_open_file(data.filepath) end
        end,
    }
end

-- Exposed for tests.
M._resolve_case = resolve_case
M._resolve_mode = resolve_mode
M._do_match     = do_match

return M
