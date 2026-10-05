local M = {}

local ui          = require("locate.util.ui")
local pickertools = require("locate.base.pickertools")

local _MAX_ENTRIES = 500

--- Listed buffers in Vim's own most-recently-used order, which is what
--- `:buffers t` sorts by. Sorting `getbufinfo()` in Lua instead does not work:
--- `lastused` is a unix timestamp with one-second resolution, so every buffer
--- visited in the same second ties, and `table.sort` is unstable -- it permutes
--- exactly the entries this source exists to surface. Vim breaks the same ties
--- on buffer number, so its order is at least stable.
---
--- A buffer that was loaded but never displayed -- an LSP resolving a
--- definition, a plugin reading a file -- has no cursor position and is listed
--- as `line 0`. Those were never visited, so they are dropped rather than left
--- to crowd out files that were.
---@return integer[] bufnrs
local function _mru_bufnrs()
    local bufnrs  = {}
    local listing = vim.api.nvim_exec2("buffers t", { output = true }).output
    for _, line in ipairs(vim.split(listing, "\n", { trimempty = true })) do
        local bufnr = tonumber(line:match("^%s*(%d+)"))
        if bufnr and not line:match("line 0$") then
            table.insert(bufnrs, bufnr)
        end
    end
    return bufnrs
end

---@return locate.PickerSpec
function M.spec()
    local cwd     = vim.fn.getcwd()
    local curbuf  = vim.api.nvim_get_current_buf()
    local seen    = {}
    seen[vim.fn.fnamemodify(vim.api.nvim_buf_get_name(curbuf), ":p")] = true

    local recent_files = {}

    ---@param path string A path in any form; resolved to a full path here.
    local function add(path)
        if #recent_files >= _MAX_ENTRIES then return end
        local full_path = vim.fn.fnamemodify(path, ":p")
        if full_path == "" or seen[full_path] or vim.fn.filereadable(full_path) ~= 1 then return end
        seen[full_path] = true
        local match_path = (full_path:find(cwd, 1, true) == 1)
            and vim.fn.fnamemodify(full_path, ":.")
            or vim.fn.fnamemodify(full_path, ":~")
        table.insert(recent_files, {
            full_path  = full_path,
            match_path = match_path,
        })
    end

    for _, bufnr in ipairs(_mru_bufnrs()) do
        if bufnr ~= curbuf then
            add(vim.api.nvim_buf_get_name(bufnr))
        end
    end
    for _, path in ipairs(vim.v.oldfiles) do
        add(path)
    end

    return {
        prompt         = "Recent Files",
        enable_preview = true,
        finder         = function(query, _, _, callback)
            local items = {}
            for _, file in ipairs(recent_files) do
                local res = pickertools.match_label(file.match_path, query)
                if res then
                    -- Deliberately unscored: the list is ordered by last use, and
                    -- that recency is the only reason to reach for it over the
                    -- files picker.
                    table.insert(items, {
                        label_chunks = res.chunks,
                        data         = { filepath = file.full_path },
                    })
                end
            end
            callback(items)
        end,
        on_confirm = function(data)
            if data then ui.smart_open_file(data.filepath) end
        end,
    }
end

return M
