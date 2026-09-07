local M = {}

local pickertools = require("locator.base.pickertools")
local ui          = require("locator.util.ui")

local _modes = { "n", "i", "v", "x", "s", "o", "c", "t" }

---@type locator.queryflags.FlagDef[]
local FLAGS = {
    { name = "mode",     type = "value",   multi = true, slot = "mode",       desc = "filter by mode: n, i, v, x, s, o, c, t", values = _modes },
    { name = "key",      type = "value",   multi = true, slot = "lhs",        desc = "filter by key (lhs)" },
    { name = "src",      type = "value",   multi = true, slot = "file",       desc = "filter by source file" },
    { name = "buflocal", type = "boolean", desc = "only buffer-local keymaps" },
}

local function format_lhs(lhs)
    if not lhs then return "" end
    return lhs:gsub(" ", "<space>"):gsub("\t", "<C-t>")
end

---@param km vim.api.keyset.get_keymap
---@return string
local function format_preview(km)
    local function fmt(val)
        if val == nil or val == 0 then return nil end
        if val == 1 then return "true" end
        return tostring(val)
    end

    local lines = {}
    local function add(label, value)
        pickertools.preview_field(lines, label, value, fmt)
    end

    add("Mode", km.mode)
    add("LHS", km.lhs)
    add("Description", km.desc)
    add("RHS", km.rhs)
    add("Buffer", km.buf)
    add("Abbreviation", km.abbr)
    add("NoRemap", km.noremap)
    add("Nowait", km.nowait)
    add("Silent", km.silent)
    add("Script", km.script)
    add("Expr", km.expr)
    add("SID", km.sid)
    add("Line", km.lnum)

    table.insert(lines, "")
    table.insert(lines, "Action:")

    if km.callback then
        local info = debug.getinfo(km.callback, "S")
        table.insert(lines, "- Type: Lua callback")
        if info then
            if info.short_src then table.insert(lines, string.format("- Source: `%s`", info.short_src)) end
            if info.linedefined and info.linedefined > 0 then
                table.insert(lines, string.format("- Start Line: %d", info.linedefined))
            end
        end
    elseif km.rhs and km.rhs ~= "" then
        table.insert(lines, "- Type: Vim Command / Mapping")
    else
        table.insert(lines, "_No action defined_")
    end

    return table.concat(lines, "\n")
end

---@return locator.PickerSpec?
function M.spec()
    ---@type vim.api.keyset.get_keymap[]
    local entries = {}

    for _, mode in ipairs(_modes) do
        local global = vim.api.nvim_get_keymap(mode)
        for _, km in ipairs(global) do
            km.mode = mode
            ---@diagnostic disable-next-line: inject-field
            local info = km.callback and debug.getinfo(km.callback, "S") or nil
            ---@diagnostic disable-next-line: inject-field
            km.source   = info and (info.source or ""):gsub("^@", "") or ""
            ---@diagnostic disable-next-line: inject-field
            km.src_lnum = info and info.linedefined or 0
            table.insert(entries, km)
        end
        local bufmaps = vim.api.nvim_buf_get_keymap(vim.api.nvim_get_current_buf(), mode)
        for _, km in ipairs(bufmaps) do
            km.mode = mode
            ---@diagnostic disable-next-line: inject-field
            local info = km.callback and debug.getinfo(km.callback, "S") or nil
            ---@diagnostic disable-next-line: inject-field
            km.source   = info and (info.source or ""):gsub("^@", "") or ""
            ---@diagnostic disable-next-line: inject-field
            km.src_lnum = info and info.linedefined or 0
            table.insert(entries, km)
        end
    end

    if vim.tbl_isempty(entries) then
        vim.notify("No keymaps found", vim.log.levels.WARN)
        return nil
    end

    return {
        prompt         = "Keymaps",
        flags          = FLAGS,
        enable_preview = true,
        finder         = function(query, flags, _, callback)
            local items = {}

            for _, km in ipairs(entries) do
                if flags.buflocal and not km["buffer"] then goto continue end

                local skip = false
                for _, v in ipairs(flags.mode or {}) do
                    if km.mode ~= v then
                        skip = true; break
                    end
                end
                if not skip then
                    local lhs = format_lhs(km.lhs or ""):lower()
                    for _, v in ipairs(flags.key or {}) do
                        if not lhs:find(v:lower(), 1, true) then
                            skip = true; break
                        end
                    end
                end
                if not skip then
                    ---@diagnostic disable-next-line: undefined-field
                    local src = (km["source"] or ""):lower()
                    for _, v in ipairs(flags.src or {}) do
                        if not src:find(v:lower(), 1, true) then
                            skip = true; break
                        end
                    end
                end
                if skip then goto continue end

                local label = (km.desc and km.desc ~= "") and km.desc or (km.rhs or "")
                local match = pickertools.match_label(label, query)
                if match then
                    local chunks = { { string.format("%-10s │ %s │ ", format_lhs(km.lhs or ""), km.mode or " ") } }
                    vim.list_extend(chunks, match.chunks)
                    ---@diagnostic disable-next-line: undefined-field
                    local src = km.source or ""
                    ---@diagnostic disable-next-line: undefined-field
                    local src_lnum = km.src_lnum or 0
                    table.insert(items, {
                        label_chunks = chunks,
                        score        = match.score,
                        data         = {
                            km      = km,
                            source  = src ~= "" and src or nil,
                            src_lnum = src_lnum > 0 and src_lnum or nil,
                        },
                    })
                end
                ::continue::
            end
            callback(items)
        end,
        previewer      = function(data, _, callback)
            callback({ content = format_preview(data.km) })
            return function() end
        end,
        on_confirm     = function(data)
            if data and data.source then
                ui.smart_open_file(data.source, data.src_lnum, 0)
            end
        end,
    }
end

return M
