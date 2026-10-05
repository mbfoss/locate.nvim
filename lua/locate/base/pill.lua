---@mod locate.pill
---@brief Text drawn as a pill: a body filled with `LocateFlagPill`, closed by a
---rounded end at either side. The ends are text painted in the colour the body
---is filled with, so every group involved is derived from that one background.

local M = {}

---Rounded ends of a pill, drawn in the pill's own background colour.
local _LEFT = "\u{e0b6}"
local _RIGHT = "\u{e0b4}"

local _HL = "LocateFlagPill"
local _HL_EDGE = "LocateFlagPillEdge"

---Pill-backed groups built so far, by the group each was derived from.
---@type table<string, string>
local _hls = {}

---The pill's own colours, with the rounded ends redrawn to match. Derived at the
---moment the body is drawn rather than defined alongside `LocateFlagPill`: read
---from one resolved background, the two cannot drift apart.
---@return vim.api.keyset.get_hl_info
local function _face()
	local pill = vim.api.nvim_get_hl(0, { name = _HL, link = false })
	vim.api.nvim_set_hl(0, _HL_EDGE, {
		fg      = pill.bg or pill.fg,
		ctermfg = pill.ctermbg or pill.ctermfg,
		bg      = "NONE",
	})
	return pill
end

---A variant of `group` carrying its foreground and style over the pill's
---background. A group of its own rather than a list of two: the last group of a
---list wins every attribute it sets, so a colorscheme giving the syntax group a
---background of its own would break the pill's, leaving the body and the rounded
---ends in two different colours.
---@param group string?
---@return string
local function _hl(group)
	if not group then return _HL end
	if _hls[group] then return _hls[group] end

	local name = ("%s_%s"):format(_HL, (group:gsub("%W", "_")))
	local pill = _face()
	local src  = vim.api.nvim_get_hl(0, { name = group, link = false })
	-- The foreground and the shape of the text, over the pill's background.
	-- `reverse` is left behind: it would swap that background back out.
	vim.api.nvim_set_hl(0, name, {
		fg            = src.fg,
		ctermfg       = src.ctermfg,
		bg            = pill.bg,
		ctermbg       = pill.ctermbg,
		bold          = src.bold,
		italic        = src.italic,
		underline     = src.underline,
		undercurl     = src.undercurl,
		strikethrough = src.strikethrough,
	})

	_hls[group] = name
	return name
end

-- `:colorscheme` clears every group, the derived ones included.
vim.api.nvim_create_autocmd("ColorScheme", {
	group    = vim.api.nvim_create_augroup("locate_pill_hls", { clear = true }),
	callback = function() _hls = {} end,
})

---Wrap `inner` in a pill, each chunk keeping the colours it was written in.
---@param inner {[1]:string,[2]:string?}[]
---@return {[1]:string,[2]:string}[] virt_text chunks
function M.wrap(inner)
	_face()
	local out = { { _LEFT, _HL_EDGE } }
	for _, chunk in ipairs(inner) do
		out[#out + 1] = { chunk[1], _hl(chunk[2]) }
	end
	out[#out + 1] = { _RIGHT, _HL_EDGE }
	return out
end

return M
