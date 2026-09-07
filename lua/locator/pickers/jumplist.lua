local M           = {}

local pickertools = require("locator.base.pickertools")
local ui          = require("locator.util.ui")
local fsutil      = require("locator.util.fsutil")

---@param item vim.fn.getjumplist.ret.item
local function read_jump_item(item)
    local bufnr = item.bufnr
    if not bufnr or bufnr == 0 then return nil end
    if not vim.api.nvim_buf_is_valid(bufnr) then return nil end
    local filepath = item.filename or vim.api.nvim_buf_get_name(bufnr)
    local relpath  = fsutil.get_relative_path(filepath) or filepath
    return {
        bufnr    = bufnr,
        filepath = filepath,
        relpath  = relpath,
        lnum     = item.lnum,
        col      = (item.col or 1) - 1,
    }
end

---@return locator.PickerSpec?
function M.spec()
    local jumplist, idx = unpack(vim.fn.getjumplist())
    if not jumplist or vim.tbl_isempty(jumplist) then
        vim.notify("Jumplist is empty", vim.log.levels.WARN)
        return nil
    end

    local current = idx + 1
    local entries = {}
    for i = #jumplist, 1, -1 do
        local data = read_jump_item(jumplist[i])
        if data then
            data.jumpidx = i
            table.insert(entries, data)
        end
    end

    ---@type locator.PickerSpec
    return {
        prompt         = "Jumplist",
        enable_preview = true,
        -- Open on the jump the list is parked at, the one <C-o> would step off.
        finder         = function(query, _, _, callback)
            local items = {}
            local current_row
            for _, data in ipairs(entries) do
                local label = data.relpath or ""
                if label == "" then label = "[No Name]" end
                -- Deliberately unscored: the jumplist is ordered by recency,
                -- which is the whole reason to open it.
                local match = pickertools.match_label(label, query)
                if match then
                    table.insert(match.chunks, { string.format(":%d:%d", data.lnum, data.col) })
                    ---@type locator.Picker.Item
                    table.insert(items, {
                        label_chunks = match.chunks,
                        data         = {
                            filepath = data.filepath,
                            bufnr    = data.bufnr,
                            lnum     = data.lnum,
                            col      = data.col,
                            jumpidx  = data.jumpidx,
                        },
                    })
                    if data.jumpidx == current then current_row = #items end
                end
            end
            callback(items, current_row)
        end,
        on_confirm     = function(data)
            if data then ui.smart_open_buffer(data.bufnr, data.lnum, data.col) end
        end,
    }
end

return M
