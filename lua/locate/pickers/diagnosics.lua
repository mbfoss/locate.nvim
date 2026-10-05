local M = {}

local pickertools = require("locate.base.pickertools")
local ui          = require("locate.util.ui")
local fsutil      = require("locate.util.fsutil")

---@type locate.queryflags.FlagDef[]
local FLAGS = {
    { name = "sev",    type = "value", multi = true, slot = "level", desc = "filter by severity: error, warn, info, hint" },
    { name = "src",    type = "value", multi = true, slot = "name",  desc = "filter by diagnostic source"                 },
    { name = "filter", type = "value", multi = true, slot = "glob",  desc = "glob filter: *.txt, **/dir/**"               },
}

local SEV_MAP = {
    error = vim.diagnostic.severity.ERROR,
    warn  = vim.diagnostic.severity.WARN,
    info  = vim.diagnostic.severity.INFO,
    hint  = vim.diagnostic.severity.HINT,
}

---@param severity vim.diagnostic.Severity
---@return string, string
local function get_severity_info(severity)
    local map = {
        [vim.diagnostic.severity.ERROR] = { "󰅚", "DiagnosticError" },
        [vim.diagnostic.severity.WARN]  = { "󰀪", "DiagnosticWarn"  },
        [vim.diagnostic.severity.INFO]  = { "󰋽", "DiagnosticInfo"  },
        [vim.diagnostic.severity.HINT]  = { "󰌶", "DiagnosticHint"  },
    }
    local res = map[severity] or { "󰠠", "Comment" }
    return res[1], res[2]
end

local function severity_to_qf_type(severity)
    if severity == vim.diagnostic.severity.ERROR then return "E"
    elseif severity == vim.diagnostic.severity.WARN  then return "W"
    elseif severity == vim.diagnostic.severity.INFO  then return "I"
    elseif severity == vim.diagnostic.severity.HINT  then return "N"
    end
    return ""
end

---@param opts {bufnr:number?}?
---@return locate.PickerSpec?
function M.spec(opts)
    opts = opts or {}
    local diagnostics = vim.diagnostic.get(opts.bufnr)

    if vim.tbl_isempty(diagnostics) then
        vim.notify("No diagnostics found", vim.log.levels.INFO)
        return nil
    end

    table.sort(diagnostics, function(a, b) return a.lnum < b.lnum end)

    local buf_set = {}
    local entries = {}
    for _, d in ipairs(diagnostics) do
        local sev_text, sev_hl = get_severity_info(d.severity)
        local bufname          = vim.api.nvim_buf_get_name(d.bufnr)
        buf_set[d.bufnr]       = true
        table.insert(entries, {
            message       = d.message:gsub("\n", " "),
            severity      = d.severity,
            source        = (d.source or ""):lower(),
            filename      = vim.fn.fnamemodify(bufname, ":t"):lower(),
            relpath       = fsutil.get_relative_path(bufname) or bufname,
            prefix_chunks = {
                { sev_text,                           sev_hl   },
                { string.format(" %3d", d.lnum + 1),  "Number" },
                { ": ",                               "Comment" },
            },
            bufnr    = d.bufnr,
            filepath = bufname,
            lnum     = d.lnum + 1,
            col      = d.col,
        })
    end
    local multi_buf = vim.tbl_count(buf_set) > 1

    return {
        prompt             = opts.bufnr and "Document Diagnostics" or "Workspace Diagnostics",
        flags              = FLAGS,
        enable_preview     = true,
        finder             = function(query, flags, _, callback)
            local sev_filter     = {}
            for _, v in ipairs(flags.sev or {}) do
                local s = SEV_MAP[v:lower()]
                if s then sev_filter[s] = true end
            end
            local has_sev_filter = next(sev_filter) ~= nil

            local items = {}
            for _, entry in ipairs(entries) do
                if has_sev_filter and not sev_filter[entry.severity] then goto continue end

                local skip = false
                for _, v in ipairs(flags.src or {}) do
                    if not entry.source:find(v:lower(), 1, true) then skip = true; break end
                end
                local in_globs = flags["filter"] or {}
                if not skip and not pickertools.match_globs(in_globs, entry.relpath, true) then
                    skip = true
                end
                if skip then goto continue end

                local res = pickertools.match_label(entry.message, query)
                if res then
                    local chunks     = vim.deepcopy(entry.prefix_chunks)
                    vim.list_extend(chunks, res.chunks)
                    local virt_line  = multi_buf and { { entry.relpath, "LocatePath" } } or nil
                    -- Deliberately unscored: the entries were sorted by position
                    -- above, and walking diagnostics in file order is the point
                    -- of the list: a query narrows it, it does not re-rank it.
                    table.insert(items, {
                        label_chunks = chunks,
                        virt_line    = virt_line,
                        data         = {
                            message  = entry.message,
                            severity = entry.severity,
                            bufnr    = entry.bufnr,
                            filepath = entry.filepath,
                            lnum     = entry.lnum,
                            col      = entry.col,
                        },
                    })
                end
                ::continue::
            end
            callback(items)
        end,
        quickfix_formatter = function(data)
            ---@type vim.quickfix.entry
            return {
                type     = severity_to_qf_type(data.severity),
                text     = data.message,
                filename = data.filepath,
                lnum     = data.lnum or 1,
                col      = data.col or 0,
            }
        end,
        on_confirm = function(data)
            if data then ui.smart_open_buffer(data.bufnr, data.lnum, data.col) end
        end,
    }
end

return M
