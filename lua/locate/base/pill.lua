---@mod locate.pill
---@brief Text drawn as a pill: a body filled with `LocatePickerFlagPill`, closed by a
---rounded end at either side. The ends are text painted in the colour the body
---is filled with, so every group involved is derived from that one background.

local M = {}

---Rounded ends of a pill, drawn in the colour the pill is filled with.
local _LEFT = "\u{e0b6}"
local _RIGHT = "\u{e0b4}"

local _HL = "LocatePickerFlagPill"
local _HL_EDGE = "LocatePickerFlagPillEdge"

---The colour the pill is filled with: what the ends are painted in, and what
---every chunk is written over. Read by `_face()` rather than at each draw: a
---pill is redrawn on every keystroke.
---@type table<string, any>
local _fill = {}

---Read `LocatePickerFlagPill` into `_fill` and repaint the ends with it.
---`reverse` swaps the pair at render time, so a reversed pill is filled with its
---own foreground, or `Normal`'s where it names none.
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
	_fill = { bg = bg or pill.fg, ctermbg = ctermbg or pill.ctermfg }
	vim.api.nvim_set_hl(0, _HL_EDGE, {
		fg      = _fill.bg,
		ctermfg = _fill.ctermbg,
		bg      = "NONE",
	})
end

_face()

-- `:colorscheme` clears the derived group along with its source, so the cache has
-- to be refilled. Scheduled: a `LocatePickerFlagPill` written out with colours of
-- its own is only put back afterwards, by `apply_highlights()`.
vim.api.nvim_create_autocmd("ColorScheme", {
	group    = vim.api.nvim_create_augroup("locate_pill_hl", { clear = true }),
	callback = function() vim.schedule(_face) end,
})

---A variant of `group` carrying its foreground and style over the pill's
---background. A group of its own rather than a list of two: the last group of a
---list wins every attribute it sets, so a colorscheme giving the syntax group a
---background of its own would break the pill's, leaving the body and the rounded
---ends in two different colours.
---
---Written afresh at each draw. A picker is short-lived, and `:colorscheme` clears
---every group a cache would have pointed at, so nothing here is worth keeping.
---@param group string?
---@param fill table<string, any> The colour the pill is filled with.
---@return string
local function _hl(group, fill)
	if not group then return _HL end

	local name = ("%s_%s"):format(_HL, (group:gsub("%W+", "_"):gsub("^_", "")))
	local src  = vim.api.nvim_get_hl(0, { name = group, link = false })
	-- The foreground and the shape of the text, over the pill's background.
	-- `reverse` is left behind: it would swap that background back out.
	vim.api.nvim_set_hl(0, name, {
		fg            = src.fg,
		ctermfg       = src.ctermfg,
		bg            = fill.bg,
		ctermbg       = fill.ctermbg,
		bold          = src.bold,
		italic        = src.italic,
		underline     = src.underline,
		undercurl     = src.undercurl,
		strikethrough = src.strikethrough,
	})
	return name
end

---Wrap `inner` in a pill, each chunk keeping the colours it was written in.
---@param inner {[1]:string,[2]:string?}[]
---@return {[1]:string,[2]:string}[] virt_text chunks
function M.wrap(inner)
	local out = { { _LEFT, _HL_EDGE } }
	for _, chunk in ipairs(inner) do
		out[#out + 1] = { chunk[1], _hl(chunk[2], _fill) }
	end
	out[#out + 1] = { _RIGHT, _HL_EDGE }
	return out
end

return M
