local M = {}

---A value flag's completion source: a `vim.fn.getcompletion()` type (e.g.
---"file", "dir", "buffer") or a function returning candidates for the partial.
---@alias locate.queryflags.CompleteSpec string|fun(partial:string):string[]

---@class locate.queryflags.FlagDef
---@field name     string
---@field type     "boolean"|"value"
---@field multi    boolean?   -- value is a comma-separated list (type=value only)
---@field strict   boolean?   -- `values` is the complete set; anything else is an error (type=value only, requires `values`)
---@field values   string[]?  -- known static values offered in completion (type=value only)
---@field complete locate.queryflags.CompleteSpec?  -- dynamic value completion source (type=value only)
---@field alias    string[]?  -- extra names accepted for this flag
---@field slot     string?    -- short word for what the value stands for, shown as "name=<slot>"
---@field desc     string?    -- shown in the completion menu, beside the form the flag takes

---A mistake in the line. `parse` still returns the flags it could read beside
---its errors, but a line carrying one has no single reading and the picker does
---not search it. `parse` reports the half-written states a correct flag passes
---through too; telling those apart takes the cursor, which the consumer holds
----- see `settled`.
---@class locate.queryflags.Error
---@field start   integer  -- 0-indexed byte start of the offending span
---@field finish  integer  -- 0-indexed byte end of the offending span (exclusive)
---@field msg     string   -- terse; it shares the prompt line with the flags
---@field settled boolean? -- typing on cannot resolve this one, so show it even
---                        -- while the cursor is still inside the span

---@class locate.queryflags.ParseResult
---@field flags table   -- {[name] = true | string | string[]}
---@field errors locate.queryflags.Error[]

---@class locate.queryflags.Completions
---@field startcol integer  -- 1-indexed column for vim.fn.complete()
---@field items    table[]

-- Syntax (README has the full account):
--
--   switch  key=value  key=one,two  ...
--
-- The line is nothing but flags -- the query is written in a section of its own
-- -- so a name stands for itself and needs no marking prefix. A switch is
-- written by its name alone, a filter as `name=value`, and a `multi` one takes
-- its several values comma-separated in the one token. A name is spelled as the
-- schema spells it, case aside: the old '--dir=src' spelling is gone. A filter
-- is written at most once; a switch may be repeated. Whatever else is on the
-- line names no flag, and comes back as an error.
--
--   'hidden dir=src'  → flags hidden, dir='src'
--   'kind=a,b\,c'     → kind = {'a', 'b,c'}
--   'dir=my\ src'     → dir = 'my src'
--
---@class locate.queryflags.Piece
---@field kind     "flag"|"value"|"unknown"
---@field start    integer     -- 1-indexed start in source
---@field finish   integer     -- 1-indexed finish in source (inclusive)
---@field name     string?     -- canonical flag this piece names (kind="flag") or feeds (kind="value")
---@field typed    string?     -- how that flag was actually spelled here, which `name` may only be a synonym of
---@field text     string?     -- decoded value, escapes resolved (kind="value")
---@field parts    string[]?   -- `text` cut at its unescaped commas; one entry when it has none (kind="value")
---@field seps     integer[]?  -- 1-indexed position of each comma that cut `parts`
---@field eq       integer?    -- 1-indexed position of the '=' gluing a value on (kind="flag")
---@field escapes  integer[]?  -- 1-indexed position of each '\' that escaped a character

---@param name string
---@return string
local function _key(name)
    return (name:lower())
end

---@param schema locate.queryflags.FlagDef[]
---@return table<string, locate.queryflags.FlagDef>
local function _build_map(schema)
    local m = {}
    for _, def in ipairs(schema) do
        -- Strictness is enforced against `values`, so a strict flag listing none
        -- would quietly accept everything: a schema mistake, said on first render.
        assert(not def.strict or (def.values and #def.values > 0),
            ("%s is strict but lists no values"):format(def.name))
        m[_key(def.name)] = def
        for _, alias in ipairs(def.alias or {}) do m[_key(alias)] = def end
    end
    return m
end

local _BSLASH = 92 -- '\'
local _COMMA  = 44 -- ','
local _EQUALS = 61 -- '='

---Whether `b` is what `%s` matches. Nil (past the end of the line) is not
---whitespace, which is what makes a trailing '\' content.
---@param b integer?
---@return boolean
local function _is_space(b)
    return b == 32 or (b ~= nil and b >= 9 and b <= 13)
end

---Read a value starting at `i`: a whitespace-delimited run in which '\' escapes
---a following '\', whitespace or comma (`:h <f-args>`, plus the list separator),
---cut into `parts` at its unescaped commas. Read in runs between those three
---bytes; an ordinary character is never handled on its own.
---@param str string
---@param i   integer
---@return locate.queryflags.Piece piece, integer next_i
local function _read_value(str, i)
    local len       = #str
    local tok_start = i
    local escapes   = {}
    local parts     = {}
    local chunks    = {} -- the current part, in runs
    local plain     = i  -- start of the ordinary run not yet taken

    ---@type integer[]
    local seps      = {}

    while true do
        local j = str:find("[%s\\,]", i)
        if not j then
            i = len + 1
            break
        end

        local b = str:byte(j)
        if b == _BSLASH then
            local after = str:byte(j + 1)
            if after == _BSLASH or after == _COMMA or _is_space(after) then
                if j > plain then chunks[#chunks + 1] = str:sub(plain, j - 1) end
                escapes[#escapes + 1] = j
                chunks[#chunks + 1]   = str:sub(j + 1, j + 1)
                i, plain              = j + 2, j + 2
            else
                -- A '\' with nothing escapable behind it, the end of the line
                -- included, is content: the run carries on over it.
                i = j + 1
            end
        elseif b == _COMMA then
            if j > plain then chunks[#chunks + 1] = str:sub(plain, j - 1) end
            seps[#seps + 1]   = j
            parts[#parts + 1] = table.concat(chunks)
            chunks            = {}
            i, plain          = j + 1, j + 1
        else
            i = j -- whitespace ends the value
            break
        end
    end

    if i > plain then chunks[#chunks + 1] = str:sub(plain, i - 1) end
    parts[#parts + 1] = table.concat(chunks)

    return {
        kind    = "value",
        start   = tok_start,
        finish  = i - 1,
        -- Rejoining the parts rebuilds the value: an escaped comma is already
        -- inside the part holding it, so only the separators go back.
        text    = table.concat(parts, ","),
        parts   = parts,
        seps    = #seps > 0 and seps or nil,
        escapes = #escapes > 0 and escapes or nil,
    }, i
end

---The parts of a value piece with the span each was written in, so an error or a
---completion can point at one of several values rather than at all of them.
---@param piece locate.queryflags.Piece
---@return {text:string, start:integer, finish:integer}[]
local function _spanned_parts(piece)
    local parts = assert(piece.parts)
    local seps  = piece.seps or {}
    local out   = {}

    for k, text in ipairs(parts) do
        out[k] = {
            text   = text,
            start  = k == 1 and piece.start or (seps[k - 1] + 1),
            finish = seps[k] and (seps[k] - 1) or piece.finish,
        }
    end

    return out
end

---Walk the line, token by token.
---@param str  string
---@param defs table<string, locate.queryflags.FlagDef>
---@return locate.queryflags.Piece[] pieces, locate.queryflags.Error[] errors
local function _scan(str, defs)
    local pieces = {}
    local errors = {}
    local len    = #str
    local i      = 1

    ---@param s       integer  -- 1-indexed inclusive
    ---@param e       integer  -- 1-indexed inclusive
    ---@param msg     string
    ---@param settled boolean? -- see `Error.settled`
    local function add_error(s, e, msg, settled)
        errors[#errors + 1] = { start = s - 1, finish = e, msg = msg, settled = settled or nil }
    end

    ---Echoes the spelling on the line, not the canonical name: the mark and the
    ---words have to describe one thing, and an alias hides the canonical one.
    ---@param def   locate.queryflags.FlagDef
    ---@param typed string  -- the flag as written here
    ---@return string
    local function needs_value(def, typed)
        if def.strict then
            return ("%s=%s"):format(typed, table.concat(assert(def.values), "|"))
        end
        return ("%s needs a value"):format(typed)
    end

    ---Index in `errors` of an open slot the line may yet close: a value flag
    ---whose '=' has not been typed. Only the last word on the line is still
    ---being written, so anything read after it settles the error.
    ---@type integer?
    local open_error = nil

    while i <= len do
        while i <= len and str:sub(i, i):match("%s") do i = i + 1 end
        if i > len then break end

        if open_error then
            errors[open_error].settled = true
            open_error = nil
        end

        local tok_start = i
        -- The name runs to the '=' that assigns to it, or to the end of the
        -- token. It is empty only when the token opens on the '=' itself.
        local name      = str:match("^[^%s=]*", i)
        local name_end  = i + #name - 1
        local def       = name ~= "" and defs[_key(name)] or nil

        if str:byte(name_end + 1) ~= _EQUALS then
            i = name_end + 1
            if not def then
                -- Whether the word is a typo or a name still being typed is the
                -- cursor's to answer, so the error is left unsettled.
                pieces[#pieces + 1] = { kind = "unknown", start = tok_start, finish = name_end }
                add_error(tok_start, name_end, ("unknown flag: %s"):format(name))
            elseif def.type == "boolean" then
                pieces[#pieces + 1] = { kind = "flag", start = tok_start, finish = name_end, name = def.name, typed = name }
            else
                pieces[#pieces + 1] = { kind = "flag", start = tok_start, finish = name_end, name = def.name, typed = name }
                -- The '=' and its value can still be typed on the end of this.
                add_error(tok_start, name_end, needs_value(def, name))
                open_error = #errors
            end
        else
            local eq = name_end + 1
            local value
            value, i = _read_value(str, eq + 1)

            if not def then
                -- A name closed by its '=' is not going to grow another letter:
                -- settled, whether it is a typo or the empty name of "=x".
                pieces[#pieces + 1] = { kind = "unknown", start = tok_start, finish = value.finish }
                add_error(tok_start, value.finish, name == "" and "no flag name before '='"
                    or ("unknown flag: %s"):format(name), true)
            elseif def.type == "boolean" then
                -- A switch is written by being there: "fixed=false" and
                -- "fixed=true" are the same mistake, and neither is acted on.
                pieces[#pieces + 1] = {
                    kind = "flag", start = tok_start, finish = value.finish,
                    name = def.name, typed = name, eq = eq,
                }
                add_error(tok_start, value.finish, ("%s takes no value"):format(name), true)
            else
                pieces[#pieces + 1] = {
                    kind = "flag", start = tok_start, finish = value.finish,
                    name = def.name, typed = name, eq = eq,
                }
                value.name          = def.name
                value.typed         = name
                pieces[#pieces + 1] = value
            end
        end
    end

    return pieces, errors
end

---@param schema locate.queryflags.FlagDef[]
---@param raw    string
---@return locate.queryflags.ParseResult
function M.parse(schema, raw)
    local defs           = _build_map(schema)
    local flags          = {}
    local pieces, errors = _scan(raw, defs)
    ---Name spans of every occurrence of each value flag, left to right.
    ---@type table<string, {start:integer, finish:integer, typed:string}[]>
    local occurrences    = {}
    ---@type locate.queryflags.Piece?
    local last_flag      = nil

    for _, piece in ipairs(pieces) do
        if piece.kind == "flag" then
            last_flag = piece
            local def = defs[_key(piece.name)]
            if def.type == "boolean" then
                -- An assignment to a switch is a mistake either way round, so it
                -- turns nothing on (see the "takes no value" error). Written
                -- plain it is set, however often: setting it again sets it.
                if not piece.eq then flags[piece.name] = true end
            else
                -- Only the last of a repeated value flag survives, and the ones
                -- it displaces leave no mark on the line. Note where they are,
                -- to say so once the winner is known.
                local spans = occurrences[piece.name] or {}
                spans[#spans + 1] = {
                    start  = piece.start - 1,
                    finish = piece.eq and (piece.eq - 1) or piece.finish,
                    typed  = assert(piece.typed),
                }
                occurrences[piece.name] = spans
            end
        elseif piece.kind == "value" then
            local def   = defs[_key(piece.name)]
            local value = piece.text
            -- A value is only ever pushed right behind the flag it feeds.
            local flag  = assert(last_flag)

            -- A value written out is a value meant, even an empty one.
            if def.strict then
                local values = assert(def.values)
                -- Each value of a list stands or falls on its own.
                local spans = def.multi and _spanned_parts(piece)
                    or { { text = value, start = piece.start, finish = piece.finish } }
                for _, span in ipairs(spans) do
                    if not vim.tbl_contains(values, span.text) then
                        -- An empty value has no span to point at ("case="), so
                        -- the mark falls back to the flag that went without one.
                        local spanned = span.finish >= span.start
                        errors[#errors + 1] = {
                            start  = (spanned and span.start or flag.start) - 1,
                            finish = spanned and span.finish or flag.finish,
                            msg    = ("%s=%s"):format(piece.typed, table.concat(values, "|")),
                        }
                    end
                end
            end

            flags[piece.name] = def.multi and assert(piece.parts) or value
        end
    end

    -- Every occurrence is marked, so the repetition is visible as a whole, and
    -- all of them carry the message.
    for _, spans in pairs(occurrences) do
        if #spans > 1 then
            for _, span in ipairs(spans) do
                errors[#errors + 1] = {
                    start   = span.start,
                    finish  = span.finish,
                    -- A repetition already written: the flag ahead of it is not
                    -- going to be unwritten by typing on.
                    settled = true,
                    -- Each mark speaks for the spelling it sits on: two aliases
                    -- of one flag are one repetition, told twice in two names.
                    msg     = ("%s set %d times"):format(span.typed, #spans),
                }
            end
        end
    end

    table.sort(errors, function(a, b) return a.start < b.start end)

    return { flags = flags, errors = errors }
end

---@param schema locate.queryflags.FlagDef[]
---@param raw    string
---@return {start:integer, finish:integer, hl:string}[]
function M.highlight(schema, raw)
    local defs   = _build_map(schema)
    local hls    = {}
    local pieces = _scan(raw, defs)

    for _, piece in ipairs(pieces) do
        local s0 = piece.start - 1
        local e0 = piece.finish

        if piece.kind == "flag" then
            -- `finish` spans a glued value too; the name alone is the keyword.
            local name_end = piece.eq and (piece.eq - 1) or piece.finish
            table.insert(hls, { start = s0, finish = name_end, hl = "@keyword" })
            if piece.eq then
                table.insert(hls, { start = piece.eq - 1, finish = piece.eq, hl = "@tag.delimiter" })
            end
        elseif piece.kind == "value" and e0 > s0 then
            table.insert(hls, { start = s0, finish = e0, hl = "@string" })
            -- A comma only separates where the flag takes a list.
            if defs[_key(piece.name)].multi then
                for _, pos in ipairs(piece.seps or {}) do
                    table.insert(hls, { start = pos - 1, finish = pos, hl = "@tag.delimiter" })
                end
            end
        end

        -- An escaping '\' is syntax; one that escapes nothing is content and
        -- keeps the value's own highlight. The difference, visible.
        for _, pos in ipairs(piece.escapes or {}) do
            table.insert(hls, { start = pos - 1, finish = pos, hl = "NonText" })
        end
    end

    -- A word naming no flag is styled as nothing: it is not syntax, and the
    -- error under it already says so.
    return hls
end

---Candidates for the value of `def`, as items replacing the whole value token.
---The inserted word is escaped so it re-parses as the candidate it names, which
---is also how the typed value is written, so the live pum filter keeps it.
---@param def     locate.queryflags.FlagDef
---@param partial string  -- value text typed so far, unescaped
---@return table[]
local function _value_items(def, partial)
    local items = {}

    -- A comma is syntax only in a list. Escaping it elsewhere would put a
    -- backslash in the word that the typed text has not got, and the pum filter
    -- would drop the item on the next keystroke.
    local pat = def.multi and "[\\,%s]" or "[\\%s]"

    local function add(v)
        table.insert(items, { word = (v:gsub(pat, "\\%0")), abbr = v })
    end

    for _, v in ipairs(def.values or {}) do
        if vim.startswith(v, partial) then add(v) end
    end

    if def.complete then
        local cands
        if type(def.complete) == "function" then
            cands = def.complete(partial)
        else
            -- getcompletion already filters by `partial`; trust its output.
            local ok, res = pcall(vim.fn.getcompletion, partial, def.complete)
            cands = ok and res or nil
        end
        for _, v in ipairs(cands or {}) do add(v) end
    end

    return items
end

---@param def locate.queryflags.FlagDef
---@return string  -- "" for a switch, else the "<...>" the '=' is waiting for
local function _slot(def)
    -- Without a name of its own the slot only says that something goes here; a
    -- list says so too, this being the only place the comma form is visible.
    if def.type == "boolean" then return "" end
    return ("<%s%s>"):format(def.slot or "value", def.multi and ",..." or "")
end

---Canonical names of the flags already written on the line, barring the one at
---`word_start`, which is the word being completed and names itself.
---@param line       string
---@param defs       table<string, locate.queryflags.FlagDef>
---@param word_start integer  -- 1-indexed start of the word under the cursor
---@return table<string, true>
local function _written(line, defs, word_start)
    local written = {}

    for _, piece in ipairs((_scan(line, defs))) do
        if piece.kind == "flag" and piece.start ~= word_start then
            written[assert(piece.name)] = true
        end
    end

    return written
end

---Flag names matching the word typed so far. A value flag is offered with its
---'=' already on, so accepting the item lands in the slot it opens. A flag
---already on the line is left out: writing a filter twice is an error, and
---writing a switch twice sets what is already set.
---@param schema       locate.queryflags.FlagDef[]
---@param current_word string
---@param written      table<string, true>  -- canonical names already on the line
---@return table[]
local function _flag_items(schema, current_word, written)
    local items = {}

    for _, def in ipairs(schema) do
        -- What is listed is what accepting the item inserts, plus the slot it
        -- wants filled next.
        local word = def.type == "value" and (def.name .. "=") or def.name
        if not written[def.name] and vim.startswith(_key(word), _key(current_word)) then
            table.insert(items, {
                word = word,
                -- The slot goes in `abbr`, not `kind`: a column of its own would
                -- be padded out, leaving a gap where the value is meant to sit.
                abbr = word .. _slot(def),
                menu = def.desc or "",
            })
        end
    end

    return items
end

---@param schema      locate.queryflags.FlagDef[]
---@param line        string
---@param cursor_byte integer  -- 0-indexed byte offset from nvim_win_get_cursor
---@return locate.queryflags.Completions?
function M.get_completions(schema, line, cursor_byte)
    local char_after = line:sub(cursor_byte + 1, cursor_byte + 1)
    if char_after ~= "" and not char_after:match("%s") then return nil end

    local defs   = _build_map(schema)
    local before = line:sub(1, cursor_byte)
    local pieces = _scan(before, defs)
    local last   = pieces[#pieces]

    -- Case 1: past the '=' of a value flag, typing its value or sitting in the
    -- empty slot. A value is all that can be written here.
    if last and last.kind == "value" and last.finish == #before then
        local def = defs[_key(last.name)]
        if not (def.values or def.complete) then return nil end

        local text, start = assert(last.text), last.start
        if def.multi then
            -- Only the value being written is completed.
            local parts = _spanned_parts(last)
            text, start = parts[#parts].text, parts[#parts].start
        end
        -- A trailing '\' parses as a literal backslash, but under the cursor it
        -- is as likely half of a "\ " being typed: it is dropped from the
        -- partial rather than searched for.
        local items = _value_items(def, (text:gsub("\\$", "")))
        return #items > 0 and { startcol = start, items = items } or nil
    end

    -- Case 2: a flag name. Every word on this line is one, so no leading mark
    -- has to be typed before the names are worth offering.
    local word_start   = assert(tonumber(before:match("()%S*$")))
    local current_word = before:sub(word_start)
    -- The whole line, not just what is behind the cursor: a flag written ahead
    -- of it is as written as one behind it.
    local items        = _flag_items(schema, current_word, _written(line, defs, word_start))
    return #items > 0 and { startcol = word_start, items = items } or nil
end

return M
