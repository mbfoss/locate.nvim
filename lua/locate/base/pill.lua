---@mod locate.pill
---@brief Text drawn as a pill: a string in `LocatePickerFlagPill`, closed by a
---rounded end at either side. The ends are text painted in the colour the body is
---filled with, so they are derived from that one background.

local M = {}

---Rounded ends of a pill, drawn in the pill's own background colour.
local _LEFT = "\u{e0b6}"
local _RIGHT = "\u{e0b4}"

local _HL = "LocatePickerFlagPill"
local _HL_EDGE = "LocatePickerFlagPillEdge"

---The pill's own colours, with the rounded ends redrawn to match. Derived at the
---moment the body is drawn rather than defined alongside `LocatePickerFlagPill`: read
---from one resolved background, the two cannot drift apart.
local function _face()
	local pill = vim.api.nvim_get_hl(0, { name = _HL, link = false })
	vim.api.nvim_set_hl(0, _HL_EDGE, {
		fg      = pill.bg or pill.fg,
		ctermfg = pill.ctermbg or pill.ctermfg,
		bg      = "NONE",
	})
end

-- `:colorscheme` clears the derived group along with the rest.
vim.api.nvim_create_autocmd("ColorScheme", {
	group    = vim.api.nvim_create_augroup("locate_pill", { clear = true }),
	callback = _face,
})

---Wrap `text` in a pill.
---@param text string
---@return {[1]:string,[2]:string}[] virt_text chunks
function M.wrap(text)
	_face()
	return { { _LEFT, _HL_EDGE }, { text, _HL }, { _RIGHT, _HL_EDGE } }
end

return M
