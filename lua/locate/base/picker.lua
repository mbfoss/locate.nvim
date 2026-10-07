local Spinner            = require("locate.util.Spinner")
local timer              = require("locate.util.timer")
local ui                 = require("locate.util.ui")
local floatwin           = require("locate.util.floatwin")
local layouts            = require("locate.base.layouts")
local queryflags         = require("locate.base.queryflags")
local pill               = require("locate.base.pill")
local pickertools        = require("locate.base.pickertools")
local tbl_new            = require("table.new")

---@mod locate.picker
---@brief Floating async picker with fuzzy filtering and optional preview.

local M                  = {}

local _NS_CURSOR         = vim.api.nvim_create_namespace("locate_PickerCursor")
local _NS_CONTENT        = vim.api.nvim_create_namespace("locate_PickerContent")
local _NS_VLINE          = vim.api.nvim_create_namespace("locate_PickerVirtLine")
local _NS_PREVIEW        = vim.api.nvim_create_namespace("locate_PickerPreview")
local _NS_PREFIX         = vim.api.nvim_create_namespace("locate_PickerPrefix")

-- Completion result carrying no candidates. `refresh = "always"` has to ride along
-- even on the empty answer, or Vim stops asking and the menu cannot come back as
-- the rest of the flag is typed.
local _EMPTY_COMPLETION  = { words = {}, refresh = "always" }

local _antiflicker_delay = 200
local _WINHL             = "NormalFloat:Normal,FloatBorder:Normal,FloatTitle:Title," ..
	"WinBar:Normal,WinBarNC:Normal"

---Fills the list's winbar, so it reads as the rule between prompt and items.
local _RULE              = "─"

---`NonText`'s foreground over the window's own background. The rule and the
---virtual line's branch are drawn in it: a `NonText` carrying a background of
---its own would otherwise paint those rows in it, breaking them against the
---list around them.
local _HL_RULE           = "LocateRule"

local function _set_rule_hl()
	local src = vim.api.nvim_get_hl(0, { name = "NonText", link = false })
	vim.api.nvim_set_hl(0, _HL_RULE, {
		fg      = src.fg,
		ctermfg = src.ctermfg,
		bg      = "NONE",
		ctermbg = "NONE",
	})
end

_set_rule_hl()

-- `:colorscheme` clears the derived group along with the one it came from.
vim.api.nvim_create_autocmd("ColorScheme", {
	group    = vim.api.nvim_create_augroup("locate_rule_hl", { clear = true }),
	callback = _set_rule_hl,
})

---Closes the flags-mode prefix, which is a label rather than a flag.
local _PREFIX_MARK = "› "

---Names the flags section while it is the one being edited.
local _FLAGS_LABEL = "Flags"

---@class locate.picker.ItemData
---@field filepath string?
---@field lnum number?
---@field col number?
---@field [string] any

---@class locate.Picker.Item
---@field label_chunks {[1]:string,[2]:string?}[]?
---@field virt_line? {[1]:string,[2]:string?}[] Single virtual line rendered below the entry.
---@field data locate.picker.ItemData
---@field score number? Match quality, as reported by `match_label`. Ranked descending; see `_rank_items`.

---@class locate.picker.ListItem
---@field label_chunks {[1]:string,[2]:string?}[]?
---@field virt_line? {[1]:string,[2]:string?}[]
---@field data locate.picker.ItemData

---@alias locate.Picker.Callback fun(data:locate.picker.ItemData?)

---Both prompt sections as one value, for a finder that wants the whole reading
---rather than the query and the flags it is handed.
---@class locate.Picker.ParsedPrompt
---@field query string
---@field flags table
---@field errors locate.queryflags.Error[]

---@class locate.Picker.FetcherOpts
---@field line_width number
---@field virt_line_width number
---@field list_height number
---@field parsed locate.Picker.ParsedPrompt?
---@field data table? Setup data supplied by the picker spec.

---@class locate.Picker.QueryHistoryProvider
---@field load fun():string[]
---@field store fun(hist:string[])?

---@alias locate.Picker.Finder fun(query:string,flags:table,opts:locate.Picker.FetcherOpts,callback:fun(new_items:locate.Picker.Item[]?)):fun()?

---@class locate.Picker.AsyncPreviewOpts
---@field viewport_width number
---@field viewport_height number

---@alias locate.Picker.AsyncPreviewData {content:string|string[]|nil,filetype:string?,filepath:string?,pos?:{[1]:integer,[2]:integer},pos_end?:{[1]:integer,[2]:integer},error_msg:string?,bufnr:integer?}
---@alias locate.Picker.AsyncPreviewLoader fun(data:locate.picker.ItemData, opts:locate.Picker.AsyncPreviewOpts, callback:fun(preview:locate.Picker.AsyncPreviewData?)):fun()?

---@class locate.Picker.opts
---@field prompt string
---@field flags locate.queryflags.FlagDef[]?
---@field finder locate.Picker.Finder?
---@field enable_preview boolean?
---@field previewer locate.Picker.AsyncPreviewLoader?
---@field on_cursor fun(data:locate.picker.ItemData)? Called with an item's data when the highlight moves onto it, whether the user stepped onto it or a narrower query left it on top. Not called for the row the picker opens on: the picker chose that one, not the user.
---@field history_provider locate.Picker.QueryHistoryProvider?
---@field quickfix_formatter (fun(data:any):vim.quickfix.entry?)?
---@field layout locate.Picker.LayoutKind? Arrangement of list and preview (default "horizontal").
---@field width_ratio number? Fraction of the editor the whole picker spans.
---@field height_ratio number?
---@field list_wrap boolean?
---@field initial_query  string?
---@field initial_flags  string? The flags section the picker opens with.
---@field initial_cursor (integer|fun(items:locate.Picker.Item[]):integer?)? Row to select on the first populated fetch, as a 1-based index into the ranked list or a function that finds one. Spent by that fetch; later queries start at the top.
---@field auto_complete_flags boolean? Auto-open flag completion on an empty flags line and while typing (default true).
---@field on_close fun(query:string, flag_text:string, index:integer?)? Called when the picker closes, with the two prompt sections and the highlighted item's 1-based list row.

---@class locate.Picker.Layout
---@field prompt_row number
---@field prompt_col number
---@field prompt_width number
---@field prompt_height number
---@field prompt_border string|table Border for the prompt float, as `nvim_open_win` takes it; shares a frame with the list, so it draws no bottom edge.
---@field list_row number
---@field list_col number
---@field list_width number
---@field list_height number
---@field list_border string|table Border for the list float; its top edge is the rule under the prompt, which carries the status indicators.
---@field preview_row number
---@field preview_col number
---@field preview_width number
---@field preview_height number
---@field preview_border string|table Border for the preview float.


---Marks the line under the query as a remark about the query rather than more of
---it. The trailing space is part of it: the two run together otherwise.
---@type string
local _ERROR_ICON = "󰀪 "

---Whether the cursor is still in the span `err` points at: it counts as inside
---while only whitespace separates the end of the span from the cursor, so the
---space after "--dir" is part of writing "--dir", not of having finished it.
---@param query  string
---@param err    locate.queryflags.Error
---@param cursor integer  -- 0-indexed byte column
---@return boolean
local function _at_cursor(query, err, cursor)
	if cursor <= err.start then return false end
	return not query:sub(err.finish + 1, cursor):find("%S")
end

local function _show_help()
	local help_text = [[
`<CR>`        Confirm
`<C-c>`       Close picker
`<Esc>`       Leave insert mode, then close picker
`<C-n>`       Next item
`<C-p>`       Previous item
`<C-d>`       Scroll down half page
`<C-u>`       Scroll up half page
`<C-j>`       Next search history entry
`<C-k>`       Previous search history entry
`j` / `k`     Next / previous history entry (normal mode)
`<C-Space>`   Complete flags
`<C-f>`       Switch between the query and the flags
`<C-q>`       Send results to quickfix list
`<C-r><C-w>`  Insert original <cword>
`g?`          Show help
]]
	floatwin.open(help_text, {
		title = "Picker",
		is_markdown = true,
	})
end

---@type fun(v:number,min:number,max:number):number
local function _clamp(v, min, max)
	return math.max(min, math.min(max, v))
end

local function _key_opts_of(buf)
	assert(buf and vim.api.nvim_buf_is_valid(buf))
	return { buffer = buf, nowait = true, silent = true }
end

---@param modifiable boolean
---@param on_delete fun()
---@param bufhidden 'hide'|'wipe'?
local function _create_buffer(modifiable, on_delete, bufhidden)
	return ui.create_scratch_buffer(false, {
			modifiable = modifiable,
			spelloptions = "noplainbuffer",
			bufhidden = bufhidden,
		},
		on_delete)
end

---@param win integer
---@param lnum integer
---@param col integer?
local function _place_preview_cursor(win, lnum, col)
	vim.api.nvim_win_call(win, function()
		if not col or col < 0 then col = 0 end
		if not pcall(vim.api.nvim_win_set_cursor, win, { lnum, col }) then
			pcall(vim.api.nvim_win_set_cursor, win, { lnum, 0 })
		end
		vim.cmd("normal! zz")
	end)
end

---@param win integer
---@param buf integer
---@param pos {[1]:integer,[2]:integer}?
---@param pos_end {[1]:integer,[2]:integer}?
local function _apply_preview_pos(win, buf, pos, pos_end)
	vim.api.nvim_buf_clear_namespace(buf, _NS_PREVIEW, 0, -1)
	if not pos then
		vim.api.nvim_win_set_cursor(win, { 1, 0 })
		return
	end
	local last = vim.api.nvim_buf_line_count(buf)
	local lnum = _clamp(pos[1], 1, last)
	_place_preview_cursor(win, lnum, pos[2])

	-- Without an end position the whole line is highlighted.
	local start_col = 0
	local end_row = lnum
	local end_col = nil ---@type integer?
	if pos_end then
		start_col = pos[2]
		end_row   = _clamp(pos_end[1], lnum, last + 1) - 1
		end_col   = pos_end[2]
	end
	vim.api.nvim_buf_set_extmark(buf, _NS_PREVIEW, lnum - 1, start_col, {
		end_row  = end_row,
		end_col  = end_col,
		hl_group = "Visual",
		hl_eol   = true,
		hl_mode  = "blend",
	})
end

---@param msg string
---@param width number
---@param height number
---@return string[]
local function _center_for_previewer(msg, width, height)
	-- Display cells, not bytes: an error message naming a non-ASCII path would
	-- otherwise be pushed off centre by one column per multibyte character.
	local pad_left = math.max(0, math.floor((width - vim.fn.strdisplaywidth(msg)) / 2))
	local centered = string.rep(" ", pad_left) .. msg
	-- `height` is the content area, and the message is one of its rows.
	local pad_top = math.max(0, math.floor((height - 1) / 2))

	local lines = {}
	for i = 1, pad_top do lines[i] = "" end
	lines[pad_top + 1] = centered
	return lines
end


local _active_picker = nil

---@param a table
---@param b table
---@return boolean
local function _flags_equal(a, b)
	for k, v in pairs(a) do
		if type(v) == "table" then
			if type(b[k]) ~= "table" or #v ~= #b[k] then return false end
			for i, x in ipairs(v) do if b[k][i] ~= x then return false end end
		elseif b[k] ~= v then
			return false
		end
	end
	for k in pairs(b) do if a[k] == nil then return false end end
	return true
end

---The two prompt sections as the history file keeps them. They are written
---apart, so one line has to carry both: an unflagged entry stays the plain
---query it always was, and only a flagged one costs the JSON.
---@param flag_text string
---@param query string
---@return string
local function _encode_history(flag_text, query)
	if flag_text == "" then return query end
	return vim.json.encode({ q = query, f = flag_text })
end

---@param entry string
---@return string flag_text, string query
local function _decode_history(entry)
	-- Only an object actually carrying `q` is one of ours: a query that merely
	-- happens to parse as JSON -- `[1,2]`, `{}` -- is still just a query, and
	-- must come back verbatim rather than as "".
	local ok, t = pcall(vim.json.decode, entry)
	if ok and type(t) == "table" and type(t.q) == "string" then
		return type(t.f) == "string" and t.f or "", t.q
	end
	return "", entry
end

---Squeeze the gaps between flags: every unescaped run of whitespace becomes one
---space, and the ends lose theirs. A '\' takes the character after it along
---untouched, so the space in `dir=my\ src` is part of the value, not a gap
---between two tokens, and stays exactly as written.
---@param text string
---@return string
local function _tidy_flags(text)
	local out, i, n = {}, 1, #text
	local gap = false
	while i <= n do
		local c = text:sub(i, i)
		if c == "\\" then
			if gap and #out > 0 then out[#out + 1] = " " end
			gap = false
			out[#out + 1] = text:sub(i, i + 1)
			i = i + 2
		elseif c:match("%s") then
			gap = true
			i = i + 1
		else
			if gap and #out > 0 then out[#out + 1] = " " end
			gap = false
			out[#out + 1] = c
			i = i + 1
		end
	end
	return table.concat(out)
end

---Cut `text` into `virt_text` chunks carrying `spans`. A span written later
---wins the bytes it shares with an earlier one, as the extmarks of equal
---priority these mirror do.
---@param text string
---@param spans {start:integer, finish:integer, hl:string}[] 0-indexed, end-exclusive
---@return {[1]:string,[2]:string?}[]
local function _chunked(text, spans)
	local hls = {} ---@type table<integer, string>
	for _, span in ipairs(spans) do
		for i = span.start, span.finish - 1 do hls[i] = span.hl end
	end

	local chunks, from = {}, 0
	for i = 1, #text do
		if hls[i] ~= hls[i - 1] then
			chunks[#chunks + 1] = { text:sub(from + 1, i), hls[i - 1] }
			from = i
		end
	end
	if from < #text then chunks[#chunks + 1] = { text:sub(from + 1), hls[from] } end
	return chunks
end

---Byte spans of the whitespace-delimited tokens of `text`. A '\' takes the
---character after it along, so an escaped space stays inside its token.
---@param text string
---@return {[1]:integer,[2]:integer}[] 0-indexed, end-exclusive
local function _tokens(text)
	local out, n, i = {}, #text, 1
	while i <= n do
		while i <= n and text:sub(i, i):match("%s") do i = i + 1 end
		if i > n then break end
		local start = i
		while i <= n do
			local c = text:sub(i, i)
			if c == "\\" and i < n then
				i = i + 2
			elseif c:match("%s") then
				break
			else
				i = i + 1
			end
		end
		out[#out + 1] = { start - 1, i - 1 }
	end
	return out
end

---The spans falling inside `from`..`to`, measured from `from`.
---@param spans {start:integer, finish:integer, hl:string}[] 0-indexed, end-exclusive
---@param from integer
---@param to integer
---@return {start:integer, finish:integer, hl:string}[]
local function _spans_within(spans, from, to)
	local out = {}
	for _, span in ipairs(spans) do
		local start, finish = math.max(span.start, from), math.min(span.finish, to)
		if start < finish then
			out[#out + 1] = { start = start - from, finish = finish - from, hl = span.hl }
		end
	end
	return out
end

--- Rank fetched items by match quality, best first.
---
--- A source opts in by handing back the score `match_label` gave it; whatever it
--- leaves unscored keeps the order the source produced. `match_label` reports no
--- score for an empty query, so an unfiltered list always reads in its source's
--- own order (references by file and position, buffers by number, the jumplist
--- by recency) and only ranks once there is a query to rank by.
---
--- The sort has to be stable, and `table.sort` is not: equal scores are the
--- common case (glob matches all score 0), and without the index tiebreak those
--- rows would reshuffle on every keystroke.
---
--- Sorts `items` in place and returns it.
---@param items locate.Picker.Item[]
---@return locate.Picker.Item[]
local function _rank_items(items)
	local n = #items
	if n < 2 then return items end

	-- Answered before the index map is built. An unscored list is what an empty
	-- query yields, which is also the longest list a source ever hands over, so
	-- it must not pay to fill in a map it is about to walk away from.
	local scored = false
	for i = 1, n do
		if items[i].score ~= nil then
			scored = true
			break
		end
	end
	if not scored then return items end

	local order = tbl_new(0, n)
	for i = 1, n do
		order[items[i]] = i
	end

	table.sort(items, function(a, b)
		local sa, sb = a.score, b.score
		if sa ~= sb then
			if sa == nil then return false end
			if sb == nil then return true end
			return sa > sb
		end
		return order[a] < order[b]
	end)
	return items
end

---Every list label is written behind this prefix, which leaves the room the
---cursor marker is drawn in.
local _LIST_PREFIX = "  "

---A label occupies one buffer line, and `nvim_buf_set_lines` refuses a string
---with a newline in it. The swap is byte for byte, so the byte columns the
---highlight chunks are placed at are unaffected by it.
---@param text string
---@return string
local function _one_line(text)
	if text:find("\n", 1, true) then return (text:gsub("\n", " ")) end
	return text
end

---@param item locate.picker.ListItem|locate.Picker.Item
---@return string
local function _item_label(item)
	if not item.label_chunks then return "" end
	local parts = {}
	for i, chunk in ipairs(item.label_chunks) do
		parts[i] = chunk[1] or ""
	end
	return _one_line(table.concat(parts))
end

---@class locate.util.Picker
---@field new fun(self: locate.util.Picker,opts:locate.Picker.opts,callback:locate.Picker.Callback) : locate.util.Picker
---@field opts locate.Picker.opts
---@field callback locate.Picker.Callback
---@field _preview_enabled boolean
---@field _layout locate.Picker.Layout
---@field _pbuf integer?
---@field _lbuf integer?
---@field _vbuf integer?
---@field _pwin integer?
---@field _lwin integer?
---@field _vwin integer?
---@field _pwin_augroup number?
---@field _spinner locate.util.Spinner?
---@field _spinner_delay_timer table? -- pending timer that would start the spinner, nil once it has fired or been cancelled
---@field _closed boolean
---@field _list_items locate.picker.ListItem[]
---@field _async_fetch_context number
---@field _async_fetch_cancel fun()?
---@field _async_preview_context number
---@field _async_preview_cancel fun()?
---@field _preview_external_buf integer?
---@field _preview_timer table?
---@field _query_text string
---@field _flag_text string -- the flags section, held apart from the query
---@field _mode "query"|"flags" -- which of the two the prompt line is editing
---@field _query_col integer? -- prompt cursor column held while the flags section is edited
---@field _flag_col integer? -- prompt cursor column held while the query section is edited
---@field _original_cword string
---@field _history string[]
---@field _history_idx number
---@field _history_saved_entry string?
---@field _set_init_cursor boolean
---@field _last_clean_query string?
---@field _last_flags table?
---@field _suppress_autocomplete boolean?
---@field _query_error string? -- message of the query error currently shown in the prompt
---@field _error_col integer? -- prompt cursor column the shown errors were chosen for
---@field _spinner_frame string? -- spinner frame currently drawn on the prompt line, nil when idle
---@field _prompt_wrapped integer -- screen lines the prompt took when the picker was last laid out
---@field _vline_row integer? -- list row whose virtual line currently carries the cursor-line highlight
---@field _cursor_row integer? -- list row the highlight was last on; nil once a fetch invalidates it, so whatever it lands on next counts as new
local Picker = {}
Picker.__index = Picker

function Picker:new(...)
	local obj = setmetatable({}, self)
	if obj.init then obj:init(...) end
	return obj
end

---@param opts locate.Picker.opts
---@param callback locate.Picker.Callback
function Picker:init(opts, callback)
	vim.validate("opts", opts, "table")
	vim.validate("callback", callback, "function")

	self.opts                  = vim.deepcopy(opts)
	self.opts.flags            = self.opts.flags or {}
	self.callback              = callback

	self._preview_enabled       = opts.enable_preview == true

	self._list_items            = {} ---@type locate.picker.ListItem[]

	self._vline_row            = nil
	self._cursor_row           = nil

	self._prompt_wrapped       = 1

	self._closed                = false

	self._async_fetch_context   = 0
	self._async_fetch_cancel    = nil

	self._set_init_cursor      = true

	self._async_preview_context = 0
	self._async_preview_cancel  = nil

	self._spinner               = nil
	self._spinner_frame        = nil

	self._query_text            = ""
	self._flag_text             = ""
	self._mode                  = "query"
	self._query_col            = nil
	self._flag_col             = nil

	self._history               = {}
	self._history_idx           = 0
	self._history_saved_entry   = nil

	if self.opts.history_provider then
		self._history = self.opts.history_provider.load() or {}
		self._history_idx = #self._history + 1
	end

	-- Load-bearing pcall: `expand` throws E348 when there is no word under the
	-- cursor, which is the ordinary state of a blank line. It only returns a
	-- list when asked to, which this is not, hence the cast.
	local ok, cword     = pcall(vim.fn.expand, "<cword>")
	self._original_cword = (ok and cword or "") --[[@as string]]

	_active_picker      = self

	self:setup_ui()
	self:setup_input()

	assert(self._pwin)
	vim.api.nvim_set_current_win(self._pwin)

	-- Draws the prefix and arms completion for the section being edited.
	self:_set_mode("query")

	local seed_flags = type(opts.initial_flags) == "string" and opts.initial_flags or ""
	local seed_query = type(opts.initial_query) == "string" and opts.initial_query or ""
	if seed_flags ~= "" or seed_query ~= "" then
		self:set_prompt(seed_flags, seed_query)
	else
		self:run_fetch()
	end
	vim.schedule(function()
		-- Anything closing the picker within the same tick leaves the focus on a
		-- normal buffer, and starting insert there is the user's file, not a prompt.
		if self._closed then return end
		vim.cmd("startinsert!")
	end)
end

function Picker:apply_prompt()
	if self._closed then return end
	-- A multi-line paste is flattened onto the one line the prompt has
	local nlines = vim.api.nvim_buf_line_count(self._pbuf)
	local lines = vim.api.nvim_buf_get_lines(self._pbuf, 0, -1, false)
	local raw = lines[1] or ""
	local text = raw:gsub("[%c]", "")
	if nlines > 1 or text ~= raw then
		local col = vim.api.nvim_win_get_cursor(self._pwin)[2]
		vim.api.nvim_buf_set_lines(self._pbuf, 0, -1, false, { text })
		vim.api.nvim_win_set_cursor(self._pwin, { 1, math.min(col, #text) })
	end
	-- Before the fetch: the query just typed may have wrapped onto another line,
	-- and the list is laid out again to make room for it. `render_prompt_highlight`
	-- syncs too, but it only runs when the query itself changed -- a line edited
	-- back to the same query can still have been rewrapped by the edit.
	self:_sync_prompt_height()

	if text == self:_mode_text() then return end
	if self._mode == "flags" then
		self._flag_text = text
	else
		self._query_text = text
	end
	self:render_prompt_highlight()
	self:run_fetch()
end

---Text of the section the prompt line is editing.
---@return string
function Picker:_mode_text()
	return self._mode == "flags" and self._flag_text or self._query_text
end

---First column the cursor can hold without being drawn over the inline prefix:
---at column 0 the block cursor sits on the virtual text rather than on the
---character it marks, so a drawn prefix puts the floor past the first character.
---@param text string
---@return integer
function Picker:_min_col(text)
	if text == "" or self:_prefix_width() == 0 then return 0 end
	return vim.fn.byteidx(text, 1)
end

---Column to put the cursor at on arriving at the current section: the one it was
---left at, or the end of the text when it has not been visited yet. Normal mode
---has no column past the last character, so the end is one back there, and none
---on the prefix either.
---@param text string
---@return integer
function Picker:_mode_col(text)
	local col ---@type integer?
	if self._mode == "flags" then
		col = self._flag_col
	else
		col = self._query_col
	end
	local max = #text
	if vim.api.nvim_get_mode().mode:sub(1, 1) ~= "i" then
		max = math.max(max - 1, 0)
		col = math.max(col or max, self:_min_col(text))
	end
	return math.min(col or #text, max)
end

---Move the cursor off the inline prefix. Normal mode allows column 0, where the
---cursor is drawn on the prefix instead of on the line.
---@return nil
function Picker:_nudge_off_prefix()
	if self._closed or not self._pwin then return end
	if vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then return end
	local col = vim.api.nvim_win_get_cursor(self._pwin)[2]
	if col > 0 then return end
	local text = vim.api.nvim_buf_get_lines(self._pbuf, 0, 1, false)[1] or ""
	local min  = self:_min_col(text)
	if min > 0 then vim.api.nvim_win_set_cursor(self._pwin, { 1, min }) end
end

---Both sections, as everything outside the prompt speaks of them.
---@return string query, string flag_text
function Picker:_prompt_state()
	return self._query_text, self._flag_text
end

---Whether the character just typed ended the token before it and opened a new
---one: an unescaped space between flags, or an unescaped comma between the
---values of a list. A '\' escapes the character behind it and is itself
---escapable, so what counts is the parity of the run of them.
---@param line string
---@param col  integer  -- 0-indexed byte offset of the cursor
---@return boolean
local function _opens_token(line, col)
	local last = line:sub(col, col)
	if last ~= "," and not last:match("%s") then return false end
	local slashes = line:sub(1, col - 1):match("\\*$")
	return #slashes % 2 == 0
end

--- Fire flag completion (the omnifunc, via <C-x><C-o>) while typing so the
--- menu appears without pressing <C-Space>. Triggers inside an in-progress flag
--- -- a name being typed, or the value slot a "name=" opened -- and on the
--- separator that opens the next one.
---@return nil
function Picker:maybe_autocomplete()
	if self._closed or self.opts.auto_complete_flags == false then return end
	if self._mode ~= "flags" then return end
	if vim.fn.pumvisible() == 1 then return end
	if vim.api.nvim_get_current_buf() ~= self._pbuf then return end
	if vim.api.nvim_get_mode().mode:sub(1, 1) ~= "i" then return end

	local flags = self.opts.flags
	if not flags or #flags == 0 then return end

	local line = vim.api.nvim_get_current_line()
	local col  = vim.api.nvim_win_get_cursor(0)[2]

	if self._suppress_autocomplete then
		self._suppress_autocomplete = false
		-- The suppression is against the menu reopening on the item just
		-- accepted. It holds no further than that item: the separator typed
		-- behind it opens a token of its own, which is worth its own menu.
		if not _opens_token(line, col) then return end
	end

	if not queryflags.get_completions(flags, line, col) then return end

	vim.api.nvim_feedkeys(
		vim.api.nvim_replace_termcodes("<C-x><C-o>", true, false, true), "n", false
	)
end

---@return nil
function Picker:setup_ui()
	self:_create_windows()
	self:relayout()

	assert(self._pbuf ~= nil)
	-- Expose flag completion on the prompt buffer so <C-x><C-o>, <C-x><C-u>, or any
	-- completion engine on this buffer can drive it. The flag schema is stashed on the
	-- buffer once here; the function computes candidates live from it, needing no picker
	-- or module state.
	--
	-- The menu is driven through the *omnifunc*: while a menu is open Vim only keeps
	-- completing on characters `ins_compl_accept_char()` accepts, and for user-defined
	-- completion that is 'iskeyword' characters only. A name is glued to its value
	-- with `=`, a name may carry a `-`, and a value may open with `"`, none of which
	-- is a keyword character, so under <C-x><C-u> the `=` would dismiss the menu.
	-- Omni completion accepts any printable non-blank character, which is exactly
	-- the alphabet of a flag.
	local completefunc                 = "v:lua.require'locate.base.picker'._flag_completefunc"
	vim.bo[self._pbuf].omnifunc         = completefunc
	vim.bo[self._pbuf].completefunc     = completefunc
	vim.b[self._pbuf].locate_completion = { flags = self.opts.flags }
	-- Hook into CompleteDone to restore highlights and trigger a fetch update
	vim.api.nvim_create_autocmd("CompleteDone", {
		buffer = self._pbuf,
		callback = function()
			-- Accepting an item fires TextChangedI; suppress its auto-trigger.
			-- A menu dismissed by a keystroke it cannot complete on (a space
			-- ending a value) reports a stub item for the text typed so far, so
			-- what marks a real choice is the `abbr` every item here carries.
			if (vim.v.completed_item or {}).abbr ~= nil and vim.v.completed_item.abbr ~= "" then
				self._suppress_autocomplete = true
			end
			self:apply_prompt()
		end
	})
	vim.keymap.set("i", "<C-r><C-w>", function()
		vim.api.nvim_feedkeys(
			vim.api.nvim_replace_termcodes(self._original_cword, true, false, true),
			"i", false
		)
	end, { buffer = self._pbuf, desc = "Paste original <cword>" })
end

---Screen lines the query takes, wrapped to the prompt's current width. Neovim
---counts them: `nvim_win_text_height` measures the buffer as the window would
---draw it, wrapping, tabs, double-width characters and all.
---
---What it does not count is the cursor, which in insert mode sits one cell past
---the query -- on the row after, when the query fills its last row exactly. That
---row is the one being typed into, so the prompt is given it.
---@return integer
function Picker:_prompt_text_height()
	if not self._pwin or not vim.api.nvim_win_is_valid(self._pwin) then return 1 end
	local height = vim.api.nvim_win_text_height(self._pwin, {}).all
	local width = vim.api.nvim_win_get_width(self._pwin)
	local line = vim.api.nvim_buf_get_lines(self._pbuf, 0, 1, false)[1] or ""
	-- The prefix is inline virtual text: drawn on the line, absent from it.
	local drawn = self:_prefix_width() + vim.fn.strdisplaywidth(line)
	local last = drawn % width
	return height + (last == 0 and drawn > 0 and 1 or 0)
end

---Re-lay the picker out when the query has grown or shrunk by a wrapped line.
---Called from wherever the prompt text changes; a query that still wraps the
---same way costs nothing but the measurement.
---@return nil
function Picker:_sync_prompt_height()
	if self._closed or not self._layout then return end
	-- `relayout` dismisses the completion menu to move the floats out from under
	-- it. Growing the prompt is not worth that mid-completion; `CompleteDone`
	-- runs `apply_prompt` and the resize lands then.
	if vim.fn.pumvisible() == 1 then return end
	if self:_prompt_text_height() == self._prompt_wrapped then return end
	-- `_apply_layout`, not `relayout`: a taller prompt takes rows off the list
	-- without changing any width, so nothing the list holds has to be drawn
	-- again -- and skipping the render is also what keeps this off a path that
	-- would come back around to here.
	self:_apply_layout()
end

---Take the picker down on the next tick, unless it is already going.
---@return nil
function Picker:_close_soon()
	if self._closed then return end
	vim.schedule(function() self:close() end)
end

---Geometry of the picker's floats for the current editor size and prompt height.
---@class locate.Picker.Cfgs
---@field prompt table
---@field list table
---@field preview table

---Build the float configs off `self._layout`.
---@return locate.Picker.Cfgs
function Picker:_float_cfgs()
	local l = self._layout
	local title = self.opts.prompt and (" " .. self.opts.prompt .. " ") or ""

	-- The border is per float and comes from the layout: the prompt and the list
	-- share one frame, each drawing the half of it that is theirs.
	---@param cfg table Placement and border, read off the layout.
	---@return table
	local function float_cfg(cfg)
		return vim.tbl_extend("force", { relative = "editor", style = "minimal" }, cfg)
	end

	return {
		prompt = float_cfg {
			row       = l.prompt_row,
			col       = l.prompt_col,
			width     = l.prompt_width,
			height    = l.prompt_height,
			border    = l.prompt_border,
			title     = title,
			title_pos = "center",
		},
		-- The list has no top border: its first row is the winbar drawing the rule
		-- above the items, which is what the extra row of height pays for.
		list = float_cfg {
			row    = l.list_row,
			col    = l.list_col,
			width  = l.list_width,
			height = l.list_height + 1,
			border = l.list_border,
		},
		preview = float_cfg {
			row    = l.preview_row,
			col    = l.preview_col,
			width  = l.preview_width,
			height = l.preview_height,
			border = l.preview_border,
		},
	}
end

---Build the layout for the current editor size and the given prompt height.
---@param prompt_height integer
---@return locate.Picker.Layout
function Picker:_build_layout(prompt_height)
	return layouts.build(self.opts.layout, {
		has_preview = self._preview_enabled,
		height_ratio = self.opts.height_ratio,
		width_ratio = self.opts.width_ratio,
		prompt_height = prompt_height,
	})
end

---Create the picker's floats, with the buffers, options and autocommands each of
---them carries. Called once, when the picker goes up; `relayout` only moves what
---this leaves behind.
---@return nil
function Picker:_create_windows()
	assert(not self._pwin and not self._lwin and not self._vwin)
	self._layout = self:_build_layout(1)
	local cfgs = self:_float_cfgs()

	self._pbuf = _create_buffer(true, function()
		self._pbuf = nil
		self:_close_soon()
	end)
	local pwin_augroup
	self._pwin, pwin_augroup = ui.create_window(self._pbuf, true, cfgs.prompt, function()
		self._pwin = nil
		self:_close_soon()
	end)
	vim.wo[self._pwin].winhighlight = _WINHL
	-- A query longer than the frame is wrapped rather than scrolled sideways:
	-- the float grows a line at a time to hold it, up to the even split with
	-- the list that `layouts` caps it at.
	vim.wo[self._pwin].wrap = true

	assert(type(pwin_augroup) == "number")
	self._pwin_augroup = pwin_augroup
	vim.api.nvim_create_autocmd("WinEnter", {
		group = pwin_augroup,
		callback = function(_)
			local win = vim.api.nvim_get_current_win()
			assert(not self._closed)
			local cfg = vim.api.nvim_win_get_config(win)
			local is_float = cfg.relative and cfg.relative ~= ""
			if not is_float and win ~= self._pwin and win ~= self._lwin and win ~= self._vwin then
				self:_close_soon()
			end
		end
	})
	vim.api.nvim_create_autocmd("VimResized", {
		group = pwin_augroup,
		callback = function()
			assert(not self._closed)
			vim.schedule(function()
				self:relayout()
			end)
		end
	})

	self._lbuf = _create_buffer(false, function()
		self._lbuf = nil
		self:_close_soon()
	end)
	self._lwin = ui.create_window(self._lbuf, false, cfgs.list, function()
		self._lwin = nil
		self:_close_soon()
	end)
	vim.wo[self._lwin].winhighlight = _WINHL
	vim.wo[self._lwin].wrap = self.opts.list_wrap ~= false
	-- `wbr` is what `%=` stretches across the winbar; `eob` comes with the
	-- window's `style = "minimal"`, and setting 'fillchars' here drops it.
	vim.wo[self._lwin].fillchars = "eob: ,wbr:" .. _RULE
	vim.wo[self._lwin].winbar = self:_status_winbar()
	-- Indent wrapped list lines so continuations read as continuations: one
	-- lines up under the label above it, not under the prefix that label
	-- starts past.
	vim.wo[self._lwin].breakindent = true

	if self._preview_enabled then
		self._vbuf = _create_buffer(false, function() self._vbuf = nil end, "hide")
		local vbuf_key_opts = _key_opts_of(self._vbuf)
		vim.keymap.set("n", "<CR>", function() self:confirm() end, vbuf_key_opts)
		vim.keymap.set("n", "<Esc>", function() self:close() end, vbuf_key_opts)
		self._vwin = ui.create_window(self._vbuf, false, cfgs.preview, function()
			self._vwin = nil
			if self._vbuf then
				vim.api.nvim_buf_delete(self._vbuf, { force = true })
				self._vbuf = nil
			end
			self:_close_soon()
		end)
		vim.wo[self._vwin].wrap = true
		vim.wo[self._vwin].winhighlight = _WINHL
		vim.wo[self._vwin].conceallevel = 3
	end
end

---Move `win` to `cfg`, unless it already sits there. The comparison is against
---the window's own geometry, so a config the picker never applied -- one the
---window was created with, or moved to from outside -- counts as it should.
---@param win integer?
---@param cfg table
---@return boolean moved
function Picker:_resize_window(win, cfg)
	if not win or not vim.api.nvim_win_is_valid(win) then return false end
	local cur = vim.api.nvim_win_get_config(win)
	if cur.relative == cfg.relative
		and cur.row == cfg.row
		and cur.col == cfg.col
		and cur.width == cfg.width
		and cur.height == cfg.height then
		return false
	end
	vim.api.nvim_win_set_config(win, cfg)
	return true
end

---Move the open floats to `cfgs`. Nothing else: the windows exist and keep the
---buffers and options they were created with.
---@param cfgs locate.Picker.Cfgs
---@return boolean list_moved Whether the list window changed geometry.
function Picker:_resize_windows(cfgs)
	self:_resize_window(self._pwin, cfgs.prompt)
	local list_moved = self:_resize_window(self._lwin, cfgs.list)
	if self._preview_enabled then self:_resize_window(self._vwin, cfgs.preview) end
	return list_moved
end

---Settle the layout for the current editor size and move the floats onto it.
---Renders nothing, so no renderer can call back into it: the one loop the
---measurement could close is cut here rather than guarded against.
---@return boolean list_moved Whether the list window changed geometry.
function Picker:_apply_layout()
	if vim.fn.pumvisible() == 1 then
		vim.api.nvim_feedkeys(
			vim.api.nvim_replace_termcodes("<C-e>", true, false, true), "n", false
		)
	end

	-- The wrapped query is measured off the prompt window, so the layout starts
	-- from the height the prompt has now and is settled below, once the window
	-- has been moved to the width this one gives it.
	self._layout = self:_build_layout(self._layout.prompt_height)
	local list_moved = self:_resize_windows(self:_float_cfgs())

	-- The prompt is where it will be and as wide as it will be, so what the query
	-- wraps to can be measured. Only its height is still open, and only the rows
	-- under it -- the list's -- answer to it; the widths and the preview do not,
	-- so this second pass is the last one.
	local wrapped = self:_prompt_text_height()
	if wrapped ~= self._layout.prompt_height then
		self._layout = self:_build_layout(wrapped)
		list_moved = self:_resize_windows(self:_float_cfgs()) or list_moved
	end
	-- What was measured, not what the layout granted: past the even split the
	-- prompt stops growing, and the two part company. Comparing against the
	-- measurement is what keeps a query that goes on growing from asking for a
	-- relayout on every keystroke.
	self._prompt_wrapped = wrapped

	return list_moved
end

---Move the floats to the current editor size and draw what the new size changed.
---The windows themselves are put up once by `_create_windows`, at launch.
---@return nil
function Picker:relayout()
	if self._closed then return end

	local list_moved = self:_apply_layout()

	-- The separators are drawn to the list width, so a list that survives a
	-- relayout has to be laid out again against the new one -- otherwise every
	-- separator keeps the length of the window the picker used to be. The
	-- labels themselves were cropped by their source and stay as they are until
	-- the next fetch re-crops them.
	if list_moved and #self._list_items > 0 then
		local row = self:get_cursor()
		self:set_items(self._list_items)
		if row then self:move_cursor(row, true, true) end
	end

	if self._preview_enabled then self:update_preview() end
end

---Show `msg` under the query, along the prompt's right edge.
---
---A virtual line rather than `eol_right_align` virtual text: aligning to the
---right edge pins the message to whatever screen row the query happens to end
---on, and a query long enough to reach it slides underneath and takes the
---corner. A virtual line is a screen row of its own, so the query cannot reach
---it -- and `nvim_win_text_height` counts it, so the prompt grows a row to hold
---it instead of pushing the query out of sight.
---
---Virtual lines are not wrapped ('wrap' does not reach them), and one wider than
---the prompt is cut off at the right -- so a message too long for the prompt
---loses its tail rather than its opening words. `virt_lines_overflow` says as
---much explicitly.
---@param ns integer Namespace, cleared by the caller.
---@param msg string
---@param hl string
---@param priority integer
---@return nil
function Picker:_set_prompt_error(ns, msg, hl, priority)
	vim.api.nvim_buf_set_extmark(self._pbuf, ns, 0, 0, {
		virt_lines          = { { { _ERROR_ICON .. msg, hl } } },
		virt_lines_overflow = "trunc",
		priority            = priority,
	})
end

---The prefix as `virt_text` chunks: the label "Flags" while the flags are being
---written, one pill per written flag while the query is. Flags nobody has
---written are nothing to show, so an unflagged query gets no prefix at all.
---
---@param errors locate.queryflags.Error[]? Mistakes in the flags, if any.
---@return {[1]:string,[2]:string?}[]
function Picker:_prefix_chunks(errors)
	-- The label names the section rather than standing for a flag, so it is not
	-- drawn as one: a mark closes it, as it always did.
	if self._mode == "flags" then
		return { { _FLAGS_LABEL, "Special" }, { _PREFIX_MARK, "Special" } }
	end
	if self._flag_text == "" then return {} end

	-- The flags carry the colours they are written in, so a pill reads as the same
	-- text the flags section holds. A mistake reddens the span it sits on, not the
	-- whole flag: the rest of it is still read as written.
	local spans = queryflags.highlight(self.opts.flags, self._flag_text)
	for _, err in ipairs(errors or {}) do
		spans[#spans + 1] = { start = err.start, finish = err.finish, hl = "DiagnosticError" }
	end

	-- A blank cell stands either side of the run of pills, holding them off the
	-- edge of the window and off the query.
	local chunks = { { " " } } ---@type {[1]:string,[2]:string?}[]
	for i, token in ipairs(_tokens(self._flag_text)) do
		local from, to = token[1], token[2]
		if i > 1 then chunks[#chunks + 1] = { " " } end -- one space between pills
		vim.list_extend(chunks, pill.wrap(_chunked(
			self._flag_text:sub(from + 1, to), _spans_within(spans, from, to))))
	end
	-- Whitespace alone is no flag: no pill, and no prefix either.
	if #chunks == 1 then return {} end
	chunks[#chunks + 1] = { " " }
	return chunks
end

---Width the prompt prefix draws, in screen cells.
---@return integer
function Picker:_prefix_width()
	local width = 0
	for _, chunk in ipairs(self:_prefix_chunks()) do
		width = width + vim.fn.strdisplaywidth(chunk[1])
	end
	return width
end

---Draw the section that is not being edited at the head of the prompt line, as
---inline virtual text. Virtual text rather than buffer content, so the line holds
---one section and one only -- what is typed is what that section is.
---@param errors locate.queryflags.Error[] Mistakes in the flags, if any.
---@return nil
function Picker:_render_prompt_prefix(errors)
	if not self._pbuf then return end
	vim.api.nvim_buf_clear_namespace(self._pbuf, _NS_PREFIX, 0, -1)

	local chunks = self:_prefix_chunks(errors)
	if #chunks == 0 then return end

	vim.api.nvim_buf_set_extmark(self._pbuf, _NS_PREFIX, 0, 0, {
		virt_text     = chunks,
		virt_text_pos = "inline",
		right_gravity = false,
		hl_mode       = "combine",
		priority      = 10,
	})
end

---Mistakes in the flags section, as `parse` reports them.
---@return locate.queryflags.Error[] errors, locate.queryflags.ParseResult parsed
function Picker:_flag_errors()
	local parsed = queryflags.parse(self.opts.flags, self._flag_text)
	return parsed.errors, parsed
end

---The prefix, the flag highlights, and the message for the first mistake among
---the flags.
---@return nil
function Picker:render_prompt_highlight()
	self:_render_prompt_marks()
	-- An error is a virtual line, and the prompt has to find it a row.
	self:_sync_prompt_height()
end

---@return nil
function Picker:_render_prompt_marks()
	if not self._pbuf then return end
	vim.api.nvim_buf_clear_namespace(self._pbuf, _NS_CONTENT, 0, -1)
	self._query_error = nil
	if #self.opts.flags == 0 then
		self:_render_prompt_prefix({})
		return
	end

	local errors = self:_flag_errors()
	local query = self._flag_text
	self:_render_prompt_prefix(errors)

	-- Away from the flags there is nothing on this line to mark up, but a
	-- mistake among them still stops the search, so it still says so.
	if self._mode ~= "flags" then
		if #errors > 0 then
			self._query_error = errors[1].msg
			self:_set_prompt_error(_NS_CONTENT, errors[1].msg, "DiagnosticVirtualTextError", 100)
		end
		return
	end

	-- Spans are measured against `query`, but the extmarks land on the prompt
	-- line as it is right now. Insert-mode completion changes that line without
	-- a TextChangedI, so the two can disagree; clamping keeps a stale span from
	-- erroring out of range instead of just highlighting a little too much.
	local line = #(vim.api.nvim_buf_get_lines(self._pbuf, 0, 1, false)[1] or "")

	for _, h in ipairs(queryflags.highlight(self.opts.flags, query)) do
		local start = math.min(h.start, line)
		local finish = math.min(h.finish, line)
		if start < finish then
			vim.api.nvim_buf_set_extmark(self._pbuf, _NS_CONTENT, 0, start, {
				end_col  = finish,
				hl_group = h.hl,
			})
		end
	end

	-- An error about the span the cursor is still inside is an error about
	-- unfinished typing: half of "dir=x" is a missing value and half of
	-- "case=smart" is a bad one, and saying so on the way through helps nobody. Those
	-- wait for the cursor to leave; a mistake `parse` marks `settled` cannot be
	-- typed out of, so it says so at once. Holding a message back only delays
	-- the words: an error stops the search either way (see `run_fetch`).
	local cursor    = self._pwin and vim.api.nvim_win_get_cursor(self._pwin)[2] or #query
	self._error_col = cursor
	local shown     = {}
	for _, err in ipairs(errors) do
		if err.settled or not _at_cursor(query, err, cursor) then
			table.insert(shown, err)
		end
	end
	if #shown == 0 then return end

	for _, err in ipairs(shown) do
		vim.api.nvim_buf_set_extmark(self._pbuf, _NS_CONTENT, 0, math.min(err.start, line), {
			end_col  = math.min(err.finish, line),
			hl_group = "DiagnosticUnderlineError",
			priority = 200,
		})
	end

	-- Only the first gets words; the prompt line is not a diagnostics window.
	self._query_error = shown[1].msg
	self:_set_prompt_error(_NS_CONTENT, shown[1].msg, "DiagnosticVirtualTextError", 100)
end

---The list's winbar: the rule below the prompt, with the spinner while a fetch
---is in flight and then the position counter at its right end. They live on the
---rule rather than on the prompt line so that a query long enough to reach the
---right edge no longer collides with them. The rule itself is the `wbr` fill
---char stretched by `%=`, so the winbar is never empty -- an empty 'winbar'
---would take the row back and pull the items up into it.
---@return string
function Picker:_status_winbar()
	local text = ""
	if self._spinner_frame then
		text = text .. " " .. self._spinner_frame
	end
	-- An error about the query says more than the count does, and only one of
	-- the two is shown at a time.
	local total = #self._list_items
	if not self._query_error and total > 0 then
		text = text .. string.format(" %d/%d", self:get_cursor() or 1, total)
	end
	-- A spinner frame is arbitrary text; `%` in a winbar is an item introducer.
	return "%#" .. _HL_RULE .. "#%=" .. text:gsub("%%", "%%%%")
end

---Redraw the rule's right end, which carries both the spinner and the position
---counter. The rule is the list float's winbar, a window-local option, so this
---touches neither window config nor the prompt.
function Picker:render_status()
	if not (self._lwin and vim.api.nvim_win_is_valid(self._lwin)) then return end
	vim.wo[self._lwin].winbar = self:_status_winbar()
end

function Picker:render_cursor()
	if not self._lbuf then return end
	vim.api.nvim_buf_clear_namespace(self._lbuf, _NS_CURSOR, 0, -1)
	local total = #self._list_items
	if total == 0 then
		self:render_status()
		return
	end
	local cur = self:get_cursor() or 1
	vim.api.nvim_buf_set_extmark(self._lbuf, _NS_CURSOR, cur - 1, 0, {
		virt_text = { { "❯ ", "Special" } },
		virt_text_pos = "overlay",
		priority = 100,
	})
	-- The line the cursor leaves has to give the highlight back.
	if self._vline_row and self._vline_row ~= cur then self:_render_virt_line(self._vline_row, false) end
	self._vline_row = cur
	self:_render_virt_line(cur, true)
end

---(Re)draw the virtual line hanging under list row `row`, if it has one.
---'cursorline' cannot reach a virtual line, so `CursorLine` is baked into the
---chunks plus width padding. Keyed by row in its own namespace, since
---`render_cursor` clears its namespace whole.
---@param row integer 1-based
---@param cursor boolean whether the row is the one under the cursor
---@return nil
function Picker:_render_virt_line(row, cursor)
	local item = self._list_items[row]
	if not item or not item.virt_line or #item.virt_line == 0 then return end

	local chunks = { { _LIST_PREFIX }, { "╰─ ", _HL_RULE } }
	vim.list_extend(chunks, item.virt_line)
	if cursor then
		local width = vim.fn.strdisplaywidth(chunks[1][1])
		for i = 2, #chunks do
			local text, hl = chunks[i][1], chunks[i][2]
			width = width + vim.fn.strdisplaywidth(text)
			-- Stacked lowest priority first: the chunk's own group keeps its
			-- colours and only falls back to the cursor line's background.
			chunks[i] = { text, hl and { "CursorLine", hl } or "CursorLine" }
		end
		local pad = self._layout.list_width - width
		if pad > 0 then chunks[#chunks + 1] = { string.rep(" ", pad), "CursorLine" } end
	end

	vim.api.nvim_buf_set_extmark(self._lbuf, _NS_VLINE, row - 1, 0, {
		id         = row,
		virt_lines = { chunks },
		hl_mode    = "blend",
	})
end

---@return integer?
function Picker:get_cursor()
	if not self._lwin then return nil end
	return vim.api.nvim_win_get_cursor(self._lwin)[1]
end

---Neovim won't scroll to reveal virt_lines hanging below the cursor line, so an
---entry sitting on the bottom row of the viewport has its virtual line clipped.
---When that's the case, scroll the view up a row to bring it back.
---
---Only the *last* entry needs this. Scrolling to the cursor works for every
---other row, because there is a real line below it to scroll onto; past the end
---of the buffer there is nothing to scroll to and Neovim stops, leaving the
---hanging lines off screen. Callers gate on that -- see `move_cursor`.
---@param row integer
function Picker:_reveal_virt_lines(row)
	if not self._lwin or not vim.api.nvim_win_is_valid(self._lwin) then return end
	local item = self._list_items[row]
	-- Only the virtual line moves the view: a separator clipped at the very
	-- bottom of the list costs nothing to leave there.
	if not item or not item.virt_line then return end

	vim.api.nvim_win_call(self._lwin, function()
		-- Screen height of the entry's own text (wrapped rows, excluding virt_lines).
		local line_height = vim.api.nvim_win_text_height(self._lwin, {
			start_row = row - 1,
			end_row = row - 1,
		}).all
		-- Only act when the entry's last row is the bottom row of the viewport.
		-- `winline()` counts from the first text row, which the winbar's own row
		-- is not, while the window height counts it.
		local bottom_row = vim.fn.winline() + line_height - 1
		if bottom_row < vim.api.nvim_win_get_height(self._lwin) - 1 then return end
		local view = vim.fn.winsaveview()
		view.topline = view.topline + 1
		vim.fn.winrestview(view)
	end)
end

---@param row integer
---@param force boolean?
---@param clamp boolean?
function Picker:move_cursor(row, force, clamp)
	local total = #self._list_items
	if total == 0 then return end
	if not self._lwin or not vim.api.nvim_win_is_valid(self._lwin) then return end

	if clamp then
		row = _clamp(row, 1, total)
	else
		if row > total then row = 1 end
		if row < 1 then row = total end
	end

	-- Compared after clamping, not before: <C-d> on the last row resolves to
	-- the row the cursor already sits on, and re-selecting it would cancel the
	-- preview and load the same item again.
	if not force and row == self:get_cursor() then return end

	vim.api.nvim_win_set_cursor(self._lwin, { row, 0 })
	vim.schedule(function()
		if not self._closed and row == #self._list_items then
			self:_reveal_virt_lines(row)
		end
	end)

	self:render_cursor()
	self:render_status()
	self:update_preview()

	-- An item is new when it sits on a row other than the one last highlighted; a
	-- refetch clears that row, so the item it lands on counts as new as well.
	local previous = self._cursor_row
	self._cursor_row = row
	if previous ~= row and self.opts.on_cursor then
		local item = self._list_items[row]
		if item then self.opts.on_cursor(item.data) end
	end
end

---@return nil
function Picker:update_preview()
	self._async_preview_context = self._async_preview_context + 1
	local preview_context = self._async_preview_context
	local fetch_context = self._async_fetch_context

	if self._closed then return end
	if not self._vbuf then return end

	self:request_clear_preview()

	if self._async_preview_cancel then
		self._async_preview_cancel()
		self._async_preview_cancel = nil
	end

	local cursor = self:get_cursor()
	---@type locate.picker.ListItem?
	local item = cursor and self._list_items[cursor] or nil
	if not item then return end

	-- The layout's width and height are what `nvim_open_win` was handed, and it
	-- draws the border outside them (see `layouts._BORDER_SPAN`), so these are
	-- already the content area a previewer gets to fill.
	local preview_width = self._layout.preview_width
	local preview_height = self._layout.preview_height

	local preview_fn = self.opts.previewer or pickertools.file_preview

	self._async_preview_cancel = preview_fn(
		item.data,
		{
			viewport_width = preview_width,
			viewport_height = preview_height,
		},
		vim.schedule_wrap(function(preview)
			if self._closed or preview_context ~= self._async_preview_context or fetch_context ~= self._async_fetch_context then
				return
			end
			preview = preview or {}
			self:cancel_clear_preview_req()

			if preview.bufnr and vim.api.nvim_buf_is_valid(preview.bufnr) then
				if self._vwin and vim.api.nvim_win_is_valid(self._vwin) then
					self:release_external_preview_buf()
					self._preview_external_buf = preview.bufnr
					vim.api.nvim_win_set_buf(self._vwin, preview.bufnr)
					self:_reset_preview_winhl()
					_apply_preview_pos(self._vwin, preview.bufnr, preview.pos, preview.pos_end)
				end
				return
			end

			self:_restore_preview_buf()

			local content = preview.content
			local lines ---@type string[]
			if type(content) == "string" then
				lines = vim.split(content, "\n")
			elseif content then
				lines = content
			else
				lines = _center_for_previewer(preview.error_msg or "No preview", preview_width, preview_height)
			end
			if self._vbuf then
				vim.bo[self._vbuf].modifiable = true
				vim.api.nvim_buf_set_lines(self._vbuf, 0, -1, false, lines)
				vim.bo[self._vbuf].modifiable = false
				local filetype = content and (preview.filetype
					or (preview.filepath and vim.filetype.match({ filename = preview.filepath }))
					or "") or ""
				-- Set only 'syntax' (not 'filetype') so no FileType autocmd fires and
				-- treesitter/lsp never attaches (avoid slowness and flickering); legacy vim-regex syntax highlighting is
				-- still loaded via the Syntax autocmd.
				vim.bo[self._vbuf].syntax = filetype
				_apply_preview_pos(self._vwin, self._vbuf, content and preview.pos or nil,
					content and preview.pos_end or nil)
			end
		end)
	)
end

function Picker:start_spinner()
	if self._spinner or self._spinner_delay_timer then return end
	self._spinner_delay_timer = vim.defer_fn(function()
		self._spinner_delay_timer = nil
		if not self._spinner then
			self._spinner = Spinner:new {
				interval = 100,
				on_update = function(frame)
					self._spinner_frame = frame
					self:render_status()
				end
			}
			self._spinner:start()
		end
	end, _antiflicker_delay)
end

function Picker:stop_spinner()
	if self._spinner_delay_timer then
		self._spinner_delay_timer:close()
		self._spinner_delay_timer = nil
	end
	if self._spinner then
		self._spinner:stop()
		self._spinner = nil
	end
	self._spinner_frame = nil
	self:render_status()
end

function Picker:release_external_preview_buf()
	if self._preview_external_buf and vim.api.nvim_buf_is_valid(self._preview_external_buf) then
		pcall(vim.api.nvim_buf_clear_namespace, self._preview_external_buf, _NS_PREVIEW, 0, -1)
	end
	self._preview_external_buf = nil
end

---Show the preview window's own buffer again, undoing a previewer that swapped
---one of its own in, and let that one go.
---@return nil
function Picker:_restore_preview_buf()
	if not self._preview_external_buf then return end
	if self._vwin and vim.api.nvim_win_is_valid(self._vwin) then
		pcall(vim.api.nvim_win_set_buf, self._vwin, self._vbuf)
		self:_reset_preview_winhl()
	end
	self:release_external_preview_buf()
end

---`nvim_win_set_buf` mutates 'winhighlight' (it drops the EndOfBuffer remap), so
---every buffer swap in the preview window has to put it back.
---@return nil
function Picker:_reset_preview_winhl()
	vim.wo[self._vwin].winhighlight = _WINHL
end

---@param immediate  boolean?
function Picker:request_clear_preview(immediate)
	local clear = function()
		if not self._vbuf or self._closed then return end
		self:_restore_preview_buf()
		vim.bo[self._vbuf].modifiable = true
		vim.api.nvim_buf_set_lines(self._vbuf, 0, -1, false, {})
		vim.bo[self._vbuf].modifiable = false
		vim.api.nvim_buf_clear_namespace(self._vbuf, _NS_PREVIEW, 0, -1)
	end
	if immediate then
		self:cancel_clear_preview_req()
		clear()
	elseif not self._preview_timer then
		self._preview_timer = vim.defer_fn(function()
			self._preview_timer = nil
			clear()
		end, _antiflicker_delay)
	end
end

function Picker:cancel_clear_preview_req()
	self._preview_timer = timer.stop_and_close_timer(self._preview_timer)
end

function Picker:clear_list()
	-- Set first: `set_items` is a no-op without a list buffer, and the list has
	-- to read as empty either way.
	self._list_items = {}
	self:set_items({})
	self:request_clear_preview()
	self:render_cursor()
	self:render_status()
end

---@param items (locate.Picker.Item|locate.picker.ListItem)[]?
function Picker:set_items(items)
	items = items or {}
	if not self._lbuf then return end

	local prefix     = _LIST_PREFIX
	local count      = #items

	local list_items = tbl_new(count, 0) ---@type locate.picker.ListItem[]
	local lines      = tbl_new(count, 0) ---@type string[]

	for row_idx = 1, count do
		local item          = items[row_idx]
		local chunks        = item.label_chunks

		list_items[row_idx] = {
			data = item.data,
			label_chunks = chunks,
			virt_line = item.virt_line,
		}

		if not chunks or #chunks == 0 then
			lines[row_idx] = prefix
		elseif #chunks == 1 then
			lines[row_idx] = prefix .. _one_line(chunks[1][1] or "")
		else
			local parts = tbl_new(#chunks + 1, 0)
			parts[1] = prefix
			for i = 1, #chunks do
				local text = chunks[i][1]
				if text and #text > 0 then parts[#parts + 1] = _one_line(text) end
			end
			lines[row_idx] = table.concat(parts)
		end
	end

	self._list_items = list_items

	vim.bo[self._lbuf].modifiable = true
	vim.api.nvim_buf_set_lines(self._lbuf, 0, -1, false, lines)
	vim.api.nvim_buf_clear_namespace(self._lbuf, _NS_CONTENT, 0, -1)
	vim.api.nvim_buf_clear_namespace(self._lbuf, _NS_VLINE, 0, -1)
	self._vline_row = nil
	-- virt lines
	for row_idx = 1, count do
		local item   = items[row_idx]
		local row    = row_idx - 1
		local chunks = item.label_chunks

		if chunks then
			local col = #prefix
			for i = 1, #chunks do
				local text, hl = chunks[i][1], chunks[i][2]
				if text and #text > 0 then
					if hl then
						vim.api.nvim_buf_set_extmark(self._lbuf, _NS_CONTENT, row, col, {
							end_col  = col + #text,
							hl_group = hl,
						})
					end
					col = col + #text
				end
			end
		end

		self:_render_virt_line(row_idx, false)
	end

	vim.bo[self._lbuf].modifiable = false
	if self._lwin and vim.api.nvim_win_is_valid(self._lwin) then
		vim.wo[self._lwin].cursorline = count > 0
	end
end

-- Resolve which row the cursor starts on. The function form is handed the items
-- in their final ranked order, which is the only order a row number means
-- anything in, and rows map 1:1 onto `set_items`.
---@param items locate.Picker.Item[] ranked, in final list order
---@param initial_cursor (integer|fun(items:locate.Picker.Item[]):integer?)?
---@return integer? row 1-based, nil to leave the cursor at the top
local function _resolve_initial_cursor(items, initial_cursor)
	if type(initial_cursor) == "function" then return initial_cursor(items) end
	return initial_cursor
end

function Picker:run_fetch()
	local cancel = function()
		if self._async_fetch_cancel then
			self._async_fetch_cancel()
			self._async_fetch_cancel = nil
		end
		-- A callback already on its way in belongs to a context nothing waits for.
		self._async_fetch_context = self._async_fetch_context + 1
		self:stop_spinner()
		self:clear_list()
		self._last_clean_query = nil
		self._last_flags       = nil
	end

	-- The query is the whole prompt line now, and it goes to the source as it
	-- stands: nothing else shares the line, so its spaces are the query's own.
	local query_text = self._query_text

	---@type locate.Picker.FetcherOpts
	local fetch_opts = {
		-- The window width is the content area; the two columns come off for
		-- the prefix every row is written behind, not for the border.
		line_width      = math.max(1, self._layout.list_width - 2),
		virt_line_width = math.max(1, self._layout.list_width - 5),
		list_height     = math.max(1, self._layout.list_height),
	}

	local clean_query = query_text
	local flags
	if #self.opts.flags > 0 then
		-- An error means the flags have no single reading, so searching them would
		-- search for something other than what is written: no errors, no fetch.
		local errors, parsed = self:_flag_errors()
		flags                = parsed.flags
		-- The two sections read as one thing, for the sources that want both.
		---@type locate.Picker.ParsedPrompt
		fetch_opts.parsed    = { query = query_text, flags = flags, errors = errors }

		if #errors > 0 then
			cancel()
			return
		end
	else
		flags = {}
	end

	-- Parse before touching the in-flight fetch or the preview: an edit that
	-- leaves the parsed query unchanged (a trailing space, doubled separators)
	-- must be a no-op, not a cancel-and-clear of results that still apply.
	if clean_query == self._last_clean_query and _flags_equal(flags, self._last_flags or {}) then
		return
	end
	self._last_clean_query = clean_query
	self._last_flags       = flags

	if self._async_fetch_cancel then
		self._async_fetch_cancel()
		self._async_fetch_cancel = nil
	end

	self:request_clear_preview()

	self._async_fetch_context = self._async_fetch_context + 1
	local context            = self._async_fetch_context

	local complete           = false

	self._async_fetch_cancel  = self.opts.finder(
		clean_query,
		flags,
		fetch_opts,
		function(new_items)
			if complete or self._closed or context ~= self._async_fetch_context then return end
			complete = true
			self:stop_spinner()
			if new_items and #new_items > 0 then
				new_items        = _rank_items(new_items)
				-- Read before the flag it comes from is spent below.
				local opening    = self._set_init_cursor
				local target_row = 1
				if opening then
					self._set_init_cursor = false
					target_row = _clamp(
						_resolve_initial_cursor(new_items, self.opts.initial_cursor) or 1, 1, #new_items)
				end
				-- New results leave the cursor on an item the user has not seen, so
				-- the row it was on no longer applies. The opening fetch is the
				-- picker's own choice of row, so it records it as already on.
				self._cursor_row = opening and target_row or nil
				self:set_items(new_items)
				self:move_cursor(target_row, true, true)
			else
				self:clear_list()
			end
		end
	)
	if not complete then
		assert(type(self._async_fetch_cancel) == "function",
			"finder with deferred result should return a function")
		self:start_spinner()
	end
end

function Picker:history_prev()
	if not self.opts.history_provider or #self._history == 0 then return end

	if self._history_idx == #self._history + 1 then
		self._history_saved_entry = _encode_history(self._flag_text, self._query_text)
	end

	local new_idx = math.max(1, self._history_idx - 1)
	if new_idx ~= self._history_idx then
		self._history_idx = new_idx
		self:set_prompt(_decode_history(self._history[self._history_idx]))
	end
end

function Picker:history_next()
	if not self.opts.history_provider then return end

	local new_idx = self._history_idx + 1
	if new_idx <= #self._history then
		self._history_idx = new_idx
		self:set_prompt(_decode_history(self._history[self._history_idx]))
	elseif new_idx == #self._history + 1 then
		self._history_idx         = new_idx
		local entry              = self._history_saved_entry or ""
		self._history_saved_entry = nil
		self:set_prompt(_decode_history(entry))
	end
end

---Replace both prompt sections, put the cursor at the end of the one being
---edited and refetch.
---@param flag_text string
---@param query string
function Picker:set_prompt(flag_text, query)
	self._flag_text  = _tidy_flags(flag_text)
	self._query_text = query
	self._query_col = nil
	self._flag_col  = nil
	local text      = self:_mode_text()
	vim.api.nvim_buf_set_lines(self._pbuf, 0, -1, false, { text })
	vim.api.nvim_win_set_cursor(self._pwin, { 1, #text })
	self:render_prompt_highlight()
	self:run_fetch()
end

function Picker:send_to_qf()
	if #self._list_items == 0 then return end
	local qf_entries = {} ---@type vim.quickfix.entry[]
	local formatter  = self.opts.quickfix_formatter

	for _, item in ipairs(self._list_items) do
		local entry ---@type vim.quickfix.entry?
		if formatter then
			entry = formatter(item.data)
		else
			local data = item.data or {}
			entry = {
				text     = _item_label(item),
				filename = data.filepath,
				lnum     = data.lnum or 1,
				col      = data.col or 1,
			}
		end
		if entry then qf_entries[#qf_entries + 1] = entry end
	end

	if #qf_entries > 0 then
		self:close()
		vim.fn.setqflist(qf_entries, "r")
		vim.cmd("copen")
	end
end

function Picker:confirm()
	local cursor = self:get_cursor()
	---@type locate.picker.ListItem?
	local list_item = cursor and self._list_items[cursor] or nil
	self:close(list_item and list_item.data or nil)
end

---@param selected_data locate.picker.ItemData?
function Picker:close(selected_data)
	if self._closed then return end

	-- Capture the highlighted row before tearing down (get_cursor needs the list
	-- window), so on_close can report it and a reopen can reselect the same row.
	local cursor = self:get_cursor()

	self._closed = true
	if _active_picker == self then _active_picker = nil end

	-- The floats outlive this call by a tick (see the stopinsert note below),
	-- so their autocmds go now: each one asserts a picker that is still open.
	if self._pwin_augroup then pcall(vim.api.nvim_del_augroup_by_id, self._pwin_augroup) end
	self._pwin_augroup = nil

	self:stop_spinner()

	self._preview_timer = timer.stop_and_close_timer(self._preview_timer)

	if self._async_fetch_cancel then self._async_fetch_cancel() end
	if self._async_preview_cancel then self._async_preview_cancel() end

	self:release_external_preview_buf()

	-- Leaving insert mode steps the cursor one column left, and `:stopinsert`
	-- only takes effect once this returns -- so the floats have to outlive it,
	-- or that step lands in the window the focus falls back to.
	--
	-- Both go in ahead of the spec's own callbacks below. `closed` is already
	-- true and the prompt's autocmds are already gone, so an error raised out
	-- of one of those would otherwise leave three floats on screen that no
	-- keymap can shut: every one of them routes back through here.
	vim.cmd("stopinsert!")
	vim.schedule(function()
		for _, w in pairs({ self._pwin, self._lwin, self._vwin }) do
			if vim.api.nvim_win_is_valid(w) then
				vim.api.nvim_win_close(w, true)
			end
		end

		for _, b in pairs({ self._pbuf, self._lbuf, self._vbuf }) do
			if vim.api.nvim_buf_is_valid(b) then
				vim.api.nvim_buf_delete(b, { force = true })
			end
		end

		self.callback(selected_data)
	end)

	if self.opts.on_close then
		self.opts.on_close(self._query_text, self._flag_text, cursor)
	end

	if self.opts.history_provider then
		local entry = _encode_history(self._flag_text, self._query_text)
		if entry ~= "" and entry ~= self._history[#self._history] then
			table.insert(self._history, entry)
			if self.opts.history_provider.store then
				self.opts.history_provider.store(self._history)
			end
		end
	end
end

---Move the prompt to `mode`, showing that section's text on the line and the
---other one in the prefix. Completion follows: the menu is the flag menu, and
---the query has nothing to complete.
---@param mode "query"|"flags"
---@return nil
function Picker:_set_mode(mode)
	-- The flag menu belongs to the section it was opened in, so it is answered
	-- here rather than carried across to hang over the other one with
	-- insert-completion still live.
	if vim.fn.pumvisible() == 1 then
		-- A highlighted entry is taken (<C-y>); with none, the menu is aborted
		-- (<C-e>), which puts back what was typed.
		local chosen = (vim.fn.complete_info({ "selected" }).selected or -1) >= 0
		-- Ahead of the keys: aborting restores the line, and the TextChangedI that
		-- comes with it would reopen the menu this is closing.
		self._suppress_autocomplete = true
		vim.api.nvim_feedkeys(
			vim.api.nvim_replace_termcodes(chosen and "<C-y>" or "<C-e>", true, false, true),
			"n", false
		)
		-- Fed keys are typeahead: the menu closes and the line is rewritten after
		-- this call returns, so the switch reads the line on the next tick.
		vim.schedule(function()
			if not self._closed then self:_apply_mode(mode) end
		end)
		return
	end

	self:_apply_mode(mode)
end

---Put `mode` on the prompt line, with no completion menu left to settle.
---@param mode "query"|"flags"
---@return nil
function Picker:_apply_mode(mode)
	-- Backstop: a menu reopened since `_set_mode` closed one, or one this path
	-- reached without it, must not outlive the section it belongs to.
	if vim.fn.pumvisible() == 1 then
		vim.api.nvim_select_popupmenu_item(-1, false, true, {})
	end

	-- The line as it stands, not as it was last applied: an edit that has yet to
	-- reach `apply_prompt` is still what the section says.
	local live = vim.api.nvim_buf_get_lines(self._pbuf, 0, 1, false)[1] or ""
	if self._mode == "flags" then
		-- Leaving the flags settles them: what the prefix shows, and what the
		-- joined line carries, is the flags without the gaps typing them opened.
		self._flag_text = mode == "flags" and live or _tidy_flags(live)
	else
		self._query_text = live
	end

	-- The column the section is left at, to be given back on returning to it.
	local col = vim.api.nvim_win_get_cursor(self._pwin)[2]
	if self._mode == "flags" then
		self._flag_col = col
	else
		self._query_col = col
	end

	self._mode                   = mode
	local text                  = self:_mode_text()
	-- Writing the section fires TextChangedI; the menu was just answered, so it is
	-- not to be reopened on arrival.
	self._suppress_autocomplete = true
	vim.api.nvim_buf_set_lines(self._pbuf, 0, -1, false, { text })
	vim.api.nvim_win_set_cursor(self._pwin, { 1, self:_mode_col(text) })
	vim.b[self._pbuf].locate_completion = { flags = mode == "flags" and self.opts.flags or {} }
	self:render_prompt_highlight()

	if mode == "flags" and self.opts.auto_complete_flags then
		vim.schedule(function()
			self:maybe_autocomplete()
		end)
	end
end

---Switch between writing the query and writing the flags. Each section keeps its
---own text and the column it was left at; a section not yet visited starts at its
---end.
---@return nil
function Picker:toggle_prompt_section()
	if not self._pwin or #self.opts.flags == 0 then return end
	self:_set_mode(self._mode == "flags" and "query" or "flags")
end

function Picker:setup_input()
	local pbuf_key_opts = _key_opts_of(self._pbuf)
	local expr_opts     = vim.tbl_extend("force", pbuf_key_opts, { expr = true })
	local has_flags     = #self.opts.flags > 0

	---Step the selection by one row. With no selection yet, either end wraps
	---onto the row nearest it.
	---@param delta 1|-1
	local function step(delta)
		self:move_cursor((self:get_cursor() or (delta > 0 and 0 or 1)) + delta)
	end

	---Same, but handing the key back to the completion menu while one is open.
	---@param delta 1|-1
	---@param key string
	---@return fun():string
	local function step_or_pum(delta, key)
		return function()
			if vim.fn.pumvisible() == 1 then return key end
			step(delta)
			return ""
		end
	end

	---@param dir 1|-1
	---@return fun()
	local function half_page(dir)
		return function()
			local cur = self:get_cursor()
			if cur then
				self:move_cursor(cur + dir * math.floor(self._layout.list_height / 2), false, true)
			end
		end
	end

	vim.keymap.set("n", "g?", _show_help, pbuf_key_opts)

	vim.keymap.set({ "i", "n" }, "<CR>", function() self:confirm() end, pbuf_key_opts)

	vim.keymap.set("n", "<Esc>", function() self:close() end, pbuf_key_opts)
	vim.keymap.set("i", "<C-c>", function() self:close() end, pbuf_key_opts)

	vim.keymap.set("n", "<C-n>", function() step(1) end, pbuf_key_opts)
	vim.keymap.set("n", "<C-p>", function() step(-1) end, pbuf_key_opts)

	vim.keymap.set("i", "<C-n>", step_or_pum(1, "<C-n>"), expr_opts)
	vim.keymap.set("i", "<C-p>", step_or_pum(-1, "<C-p>"), expr_opts)
	vim.keymap.set("i", "<Down>", step_or_pum(1, "<Down>"), expr_opts)
	vim.keymap.set("i", "<Up>", step_or_pum(-1, "<Up>"), expr_opts)

	vim.keymap.set({ "i", "n" }, "<C-d>", half_page(1), pbuf_key_opts)
	vim.keymap.set({ "i", "n" }, "<C-u>", half_page(-1), pbuf_key_opts)

	vim.keymap.set("i", "<C-j>", function() self:history_next() end, pbuf_key_opts)
	vim.keymap.set("i", "<C-k>", function() self:history_prev() end, pbuf_key_opts)

	vim.keymap.set("n", "j", function() self:history_next() end, pbuf_key_opts)
	vim.keymap.set("n", "k", function() self:history_prev() end, pbuf_key_opts)

	vim.keymap.set({ "n", "i" }, "<C-q>", function() self:send_to_qf() end, pbuf_key_opts)

	if has_flags then
		vim.keymap.set({ "i", "n" }, "<C-f>", function() self:toggle_prompt_section() end, pbuf_key_opts)
	end

	vim.keymap.set("i", "<C-Space>", function()
		if self._mode ~= "flags" then return end
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-x><C-o>", true, false, true), "n", false)
	end, pbuf_key_opts)

	-- Leaving insert steps the cursor one column left, which can land it on the
	-- prefix.
	vim.api.nvim_create_autocmd("InsertLeave", {
		buffer = self._pbuf,
		callback = function() self:_nudge_off_prefix() end,
	})

	-- TextChangedP, not only TextChangedI: while the menu is open Vim reports the
	-- keystrokes that filter it there instead, and the line they write is the one
	-- being searched for. Without it the results only catch up once the menu
	-- closes. Nothing is completed off a menu that is already up, so the
	-- auto-trigger stays on the insert event alone.
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
		buffer = self._pbuf,
		callback = function(ev)
			self:apply_prompt()
			if ev.event == "TextChangedI" and self.opts.auto_complete_flags then
				vim.schedule(function()
					self:maybe_autocomplete()
				end)
			end
		end
	})

	-- Which errors are held depends on where the cursor is, so leaving a
	-- half-written flag has to be an event of its own: without this the
	-- error waits for the next keystroke, and a query finished with a typo
	-- in it -- nothing left to type -- never says anything at all.
	if has_flags then
		vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
			buffer = self._pbuf,
			callback = function()
				if self._closed or not self._pwin then return end
				-- Typing moves the cursor too, and the text path has just
				-- drawn these same errors for this same column.
				if vim.api.nvim_win_get_cursor(self._pwin)[2] == self._error_col then return end
				-- A line the cache has not caught up with is taken in whole --
				-- flags read again, results refetched -- rather than assigned to
				-- the cache: assigning here settles the text the text path
				-- compares against, and the fetch that path owes is never run.
				-- `apply_prompt` costs nothing when the two already agree.
				self:apply_prompt()
				self:render_prompt_highlight()
				self:render_status()
			end
		})
	end

	local lbuf_key_opts = _key_opts_of(self._lbuf)
	vim.keymap.set("n", "<Esc>", function() self:close() end, lbuf_key_opts)
	vim.keymap.set("n", "<CR>", function() self:confirm() end, lbuf_key_opts)
end

--- Buffer-local 'omnifunc'/'completefunc' for picker flag completion. The flag schema is
--- read from a buffer variable set once at picker load; candidates are computed
--- live from the current prompt line, so this function needs no picker reference
--- or module-level state.
---@param findstart 0|1
---@param base string
---@return integer|table -- the 0-indexed start column, or a `complete-functions` dict
function M._flag_completefunc(findstart, base)
	local ctx   = vim.b.locate_completion
	local flags = ctx and ctx.flags
	if not flags or #flags == 0 then
		return findstart == 1 and -3 or _EMPTY_COMPLETION
	end

	-- Candidates depend on the whole prompt line, not just `base`: "l" alone is a
	-- bare word, but "dir=l" is a directory being named. On the second call Vim
	-- has cut `base` out of the buffer and parked the cursor at its start, so the
	-- line is put back together before parsing it.
	local line = vim.api.nvim_get_current_line()
	local col  = vim.api.nvim_win_get_cursor(0)[2]
	if findstart == 0 then
		line = line:sub(1, col) .. base .. line:sub(col + 1)
		col  = col + #base
	end

	local completions = queryflags.get_completions(flags, line, col)
	if not completions or #completions.items == 0 then
		return findstart == 1 and -3 or _EMPTY_COMPLETION
	end

	-- get_completions returns a 1-indexed byte column; completefunc wants 0-indexed.
	if findstart == 1 then return completions.startcol - 1 end

	-- Keep only candidates matching what was typed since startcol. Escapes are
	-- resolved on both sides, so an unescaped partial still matches an escaped
	-- value (base `fo` or `foo\ b` matches word `foo\ bar`). A trailing '\' goes
	-- with them: it parses as content, but a candidate must not drop out of the
	-- menu for the keystroke between it and the space it is there to escape.
	local function unescaped(s) return (s:gsub("\\([\\%s])", "%1"):gsub("\\$", "")) end
	local needle = unescaped(base)
	local items  = {}
	for _, item in ipairs(completions.items) do
		if vim.startswith(unescaped(item.word), needle) then
			items[#items + 1] = item
		end
	end
	return { words = items, refresh = "always" }
end

--- Exposed for the test suite; the picker that is open, if one is.
---@return locate.util.Picker?
function M._active()
	return _active_picker
end

--- Exposed for the test suite; `run_fetch` is the only caller in anger.
M._rank_items = _rank_items

--- Exposed for the test suite.
M._resolve_initial_cursor = _resolve_initial_cursor

---@param opts locate.Picker.opts
---@param callback locate.Picker.Callback
function M.open(opts, callback)
	assert(opts.finder, "finder missing in opts")
	if _active_picker and not _active_picker._closed then
		_active_picker:close()
	end
	Picker:new(opts, callback)
end

return M
