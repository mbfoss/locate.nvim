local M = {}

local pickertools = require("locate.base.pickertools")

---@type locate.queryflags.FlagDef[]
local FLAGS = {
    { name = "float",  type = "boolean", desc = "include floating windows" },
    { name = "hidden", type = "boolean", desc = "include hidden windows"   },
}

---@param winid number
---@param query string
---@param config table window config from `nvim_win_get_config()`
---@param current_tab number? tabpage handle, or nil when tab info should be hidden
---@return locate.Picker.Item?
local function window_to_picker_item(winid, query, config, current_tab)
    if not vim.api.nvim_win_is_valid(winid) then return nil end

    local bufnr    = vim.api.nvim_win_get_buf(winid)
    local bufname  = vim.api.nvim_buf_get_name(bufnr)
    local filename = bufname ~= "" and vim.fn.fnamemodify(bufname, ":t") or "[No Name]"

    local match = pickertools.match_label(filename, query)
    if not match then return nil end

    local label_chunks = {
        { string.format("%2d ", winid), "Comment" },
    }

    if current_tab then
        local tabpage = vim.api.nvim_win_get_tabpage(winid)
        table.insert(label_chunks, {
            string.format("tab %d ", vim.api.nvim_tabpage_get_number(tabpage)),
            tabpage == current_tab and "Special" or "Comment",
        })
    end

    table.insert(label_chunks, { string.format("[%d] ", vim.api.nvim_win_get_number(winid)), "Constant" })
    vim.list_extend(label_chunks, match.chunks)

    if config.relative ~= "" then
        table.insert(label_chunks, { " [float]", "Special" })
    end
    if config.hide then
        table.insert(label_chunks, { " [hidden]", "Special" })
    end

    local cursor = vim.api.nvim_win_get_cursor(winid)

    ---@type locate.Picker.Item
    return {
        label_chunks = label_chunks,
        score        = match.score,
        data         = { winid = winid, bufnr = bufnr, lnum = cursor[1], col = cursor[2] },
    }
end

---@param opts {only_current_tab:boolean?}?
---@return locate.PickerSpec
function M.spec(opts)
    opts = opts or {}
    local windows     = opts.only_current_tab
        and vim.api.nvim_tabpage_list_wins(0)
        or vim.api.nvim_list_wins()
    local current_win = vim.api.nvim_get_current_win()
    -- only annotate with tab info when more than one tab is in play
    local current_tab = not opts.only_current_tab
        and #vim.api.nvim_list_tabpages() > 1
        and vim.api.nvim_get_current_tabpage()
        or nil

    return {
        prompt         = "Switch Window",
        flags          = FLAGS,
        enable_preview = true,
        initial_cursor = function(items)
            for row, item in ipairs(items) do
                if item.data.winid == current_win then return row end
            end
        end,
        finder         = function(query, flags, _, callback)
            local items = {}
            for _, winid in ipairs(windows) do
                local config   = vim.api.nvim_win_get_config(winid)
                local is_float = config.relative ~= ""
                if is_float and not flags.float then goto continue end

                if config.hide and not flags.hidden then goto continue end

                local item = window_to_picker_item(winid, query, config, current_tab)
                if item then table.insert(items, item) end
                ::continue::
            end
            callback(items)
        end,
        previewer = function(data, _, callback)
            local bufnr     = data.bufnr
            local cancelled = false
            vim.schedule(function()
                if not cancelled and vim.api.nvim_buf_is_valid(bufnr) then
                    callback({
                        content  = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
                        filetype = vim.bo[bufnr].filetype,
                    })
                else
                    callback({})
                end
            end)
            return function() cancelled = true end
        end,
        on_confirm = function(data)
            if data and vim.api.nvim_win_is_valid(data.winid) then
                vim.api.nvim_set_current_win(data.winid)
            end
        end,
    }
end

return M
