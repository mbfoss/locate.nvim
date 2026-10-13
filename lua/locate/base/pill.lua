---@mod locate.pill
---@brief Text drawn as a pill: a body filled with `LocatePickerFlagPill`, closed by a
---rounded end at either side. The ends are text painted in the colour the body
---is filled with.

local M = {}

---Rounded ends of a pill, drawn in the colour the pill is filled with.
local _LEFT = "\u{e0b6}"
local _RIGHT = "\u{e0b4}"

local _HL = "LocatePickerFlagPill"
local _HL_EDGE = "LocatePickerFlagPillEdge"

---Paint the ends in the colour `LocatePickerFlagPill` is filled with. `reverse`
---swaps the pair at render time, so a reversed pill is filled with its own
---foreground, or `Normal`'s where it names none.
local function _face()
	local pill   = vim.api.nvim_get_hl(0, { name = _HL, link = false })
	local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })

	local bg, ctermbg = pill.bg, pill.ctermbg
	if pill.reverse then
		bg = pill.fg or normal.fg
	end
	-- A reversal on one channel alone arrives nested, not on `pill.reverse`.
	if pill.cterm and pill.cterm.reverse then
		ctermbg = pill.ctermfg or normal.ctermfg
	end

	-- A group naming a foreground alone fills nothing: it becomes the fill.
	vim.api.nvim_set_hl(0, _HL_EDGE, {
		fg      = bg or pill.fg,
		ctermfg = ctermbg or pill.ctermfg,
		bg      = "NONE",
	})
end

_face()

-- `:colorscheme` clears the derived group along with its source, so the ends have
-- to be repainted. Scheduled: a `LocatePickerFlagPill` written out with colours
-- of its own is only put back afterwards, by `apply_highlights()`.
vim.api.nvim_create_autocmd("ColorScheme", {
	group    = vim.api.nvim_create_augroup("locate_pill_hl", { clear = true }),
	callback = function() vim.schedule(_face) end,
})

---Wrap `text` in a pill, body and ends in the pill's own two groups. A flag is
---drawn as written: it is a badge, not a line of syntax.
---@param text string
---@return {[1]:string,[2]:string}[] virt_text chunks
function M.wrap(text)
	return { { _LEFT, _HL_EDGE }, { text, _HL }, { _RIGHT, _HL_EDGE } }
end

return M
