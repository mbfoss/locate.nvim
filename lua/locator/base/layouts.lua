local M = {}

---Rows and columns the outermost border eats. `nvim_open_win` draws a border on
---the row and column it is handed, so a float reaches one cell past the
---geometry on every side; the inner borders are already paid for by the gaps
---between the floats, only the ring around the whole picker is left. Centering
---has to allow for it or the picker sits two cells low and two cells right.
local _BORDER_SPAN = 2

---Helix-style framing. The rule dividing the two floats is drawn by neither
---border: it is the list's winbar, which is also what the status indicators ride
---on (see `Picker:render_status`). The list therefore has no top border, and its
---window is one row taller than its items to pay for the winbar; the frame's
---sides run either side of it, so the two floats still read as one box.
local _BORDER_TOP    = { "╭", "─", "╮", "│", "", "", "", "│" }
local _BORDER_BOTTOM = { "", "", "", "│", "╯", "─", "╰", "│" }
local _BORDER_FULL = "rounded"

---Rows the prompt float covers for a one-line query: its top border and the
---line of text. `nvim_open_win` places a bordered float by its outer edge, so
---the list starts on the row after them -- the rule its winbar draws up there is
---the third row between the frame's top edge and its first item. A wrapped
---prompt is taller than one line; see `_split_frame`.
local _PROMPT_ROWS = 2

---@type fun(v:number,min:number,max:number):number
local function _clamp(v, min, max)
    return math.max(min, math.min(max, v))
end

---Divide the rows the prompt/list frame holds -- everything inside its border,
---the rule between the two floats included -- between a prompt of `desired`
---wrapped lines and the list below it. The prompt never takes more than half of
---what is left once the rule is paid for, so a query long enough to fill the
---frame stops growing at an even split rather than squeezing the list out.
---@param interior integer Rows inside the frame: prompt, rule and list together.
---@param desired integer? Wrapped lines the prompt would like (default 1).
---@return integer prompt_height
---@return integer list_height
local function _split_frame(interior, desired)
    local max = math.max(1, math.floor((interior - 1) / 2))
    local prompt_height = _clamp(math.floor(desired or 1), 1, max)
    return prompt_height, math.max(1, interior - 1 - prompt_height)
end

--- Whether a statusline is drawn at the bottom of the editor. With
--- `laststatus == 1`, assume no status line (for performance)
---@return boolean
local function _has_statusline()
    local laststatus = vim.o.laststatus
    return laststatus ~= 0 and laststatus ~=1
end

---Editor rows the picker may occupy: everything `vim.o.lines` counts, less the
---command line and the statusline. Floats are placed relative to the editor,
---whose row 0 is the top of the screen, so those rows come off the bottom and
---centering within what is left keeps the picker off the command line.
---@return integer
function M.usable_lines()
    local reserved = vim.o.cmdheight + (_has_statusline() and 1 or 0)
    return math.max(1, vim.o.lines - reserved)
end

---The frame's top row, width and interior height. Expanded, the frame fills the
---usable rows edge to edge; otherwise it is a bar across the bottom of the
---editor, `height_ratio` of the usable rows tall, down to the last one, with one
---cell of margin either side.
---@param opts {height_ratio:number?,expanded:boolean?}
---@return integer row
---@return integer width
---@return integer interior
local function _frame(opts)
    local lines = M.usable_lines()

    -- A content width of `vim.o.columns - 4` plus the two border columns spans
    -- all but one cell at either edge of the editor.
    local width = math.max(1, vim.o.columns - 4)

    if opts.expanded then
        -- Edge to edge: the border ring is all that comes off the usable rows.
        return 0, width, math.max(3, lines - _BORDER_SPAN)
    end

    local total_height = math.ceil(lines * _clamp(opts.height_ratio or 0.25, 0.1, 0.9))
    -- Room for the prompt line, the rule and an item row.
    total_height = math.min(math.max(3, total_height), math.max(3, lines - _BORDER_SPAN))

    return math.max(0, lines - total_height - _BORDER_SPAN), width, total_height
end

---The prompt and list in the frame, and the preview -- when it is shown -- on
---the frame's right half, whatever the frame's size: the preview's share of the
---width is `preview_ratio`, and it runs the full height of the frame.
---@param opts {height_ratio:number?,preview_ratio:number?,expanded:boolean?,has_preview:boolean?,prompt_height:integer?}
---@return locator.Picker.Layout
function M.build(opts)
    local row, width, interior = _frame(opts)
    local prompt_height, list_height = _split_frame(interior, opts.prompt_height)

    -- Each box keeps its own border ring, and they touch: sharing a column
    -- would put both boxes' corners on the same cell.
    local list_width, preview_width = width, 0
    if opts.has_preview then
        local ratio = _clamp(opts.preview_ratio or 0.5, 0.1, 0.9)
        preview_width = math.max(1, math.floor((width - 2) * ratio))
        list_width    = math.max(1, width - preview_width - 2)
    end

    local col = 1

    return {
        prompt_row = row,
        prompt_col = col,
        prompt_width = list_width,
        prompt_height = prompt_height,
        prompt_border = _BORDER_TOP,

        list_row = row + _PROMPT_ROWS + prompt_height - 1,
        list_col = col,
        list_width = list_width,
        list_height = list_height,
        list_border = _BORDER_BOTTOM,

        -- Top border level with the prompt's, bottom border with the list's.
        preview_row = row,
        preview_col = list_width + 3,
        preview_width = preview_width,
        preview_height = opts.has_preview and (prompt_height + list_height + 1) or 0,
        preview_border = _BORDER_FULL,
    }
end

return M
