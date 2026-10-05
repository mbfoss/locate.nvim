local picker = require("locate.base.picker")

local schema = {
    { name = "dir",   type = "value", values = { "lua", "tests", "with space" } },
    { name = "fixed", type = "boolean" },
}

local buf

---Park the cursor at the end of `text`. Outside insert mode the cursor cannot sit
---past the last character, so a trailing space stands in for the room insert mode
---would have; nothing is parsed past the cursor, so it changes no answer.
---@param text string
---@return nil
local function set_prompt(text)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text .. " " })
    vim.api.nvim_win_set_cursor(0, { 1, #text })
end

---Put `line` in the prompt with the cursor at its end, as it would be mid-typing,
---then hand Vim's two completefunc calls the leader it would pass.
---@param line   string
---@param leader string  -- the text Vim cuts out from `startcol` to the cursor
---@return integer startcol -- 0-indexed
---@return string[] words
local function complete(line, leader)
    set_prompt(line)
    local startcol = picker._flag_completefunc(1, "") --[[@as integer]]

    -- Vim removes the leader from the buffer before asking for the candidates.
    assert.are.equal(leader, line:sub(startcol + 1))
    set_prompt(line:sub(1, startcol))

    local res = picker._flag_completefunc(0, leader)
    return startcol, vim.tbl_map(function(it) return it.word end, res.words)
end

describe("picker completefunc", function()
    before_each(function()
        buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_win_set_buf(0, buf)
        vim.b[buf].locate_completion = { flags = schema }
    end)

    it("completes flag names from the word being typed", function()
        local startcol, words = complete("fi", "fi")
        assert.are.equal(0, startcol)
        assert.are.same({ "fixed" }, words)
    end)

    it("offers a value flag with the '=' its value goes behind", function()
        assert.are.same({ "dir=" }, select(2, complete("di", "di")))
    end)

    it("completes a value from the whole line, not from the leader alone", function()
        -- The leader "l" is a bare word on its own; only the "dir=" before it
        -- makes it a value. Parsing the leader in isolation offered flags here.
        local startcol, words = complete("dir=l", "l")
        assert.are.equal(4, startcol)
        assert.are.same({ "lua" }, words)
    end)

    it("offers values in the empty slot after a value flag", function()
        local _, words = complete("dir=", "")
        assert.is_true(vim.tbl_contains(words, "lua"))
        assert.is_true(vim.tbl_contains(words, "tests"))
    end)

    it("offers nothing for a word no flag name begins with", function()
        -- -3 cancels silently and leaves completion mode, which is why this one
        -- cannot go through `complete`.
        set_prompt("fixed wor")
        assert.are.equal(-3, picker._flag_completefunc(1, ""))

        -- And should Vim ask anyway, the candidate list stays empty.
        set_prompt("fixed ")
        assert.are.same({}, picker._flag_completefunc(0, "wor").words)
    end)

    it("matches an escaped candidate against an unescaped leader", function()
        local _, words = complete("dir=with", "with")
        assert.are.same({ "with\\ space" }, words)
    end)

    it("matches an escaped candidate against a leader written with escapes", function()
        -- The leader is the whole value token, escapes and all, and a '\' still
        -- waiting on its character must not drop the candidate it is leading to.
        assert.are.same({ "with\\ space" }, select(2, complete("dir=with\\ sp", "with\\ sp")))
        assert.are.same({ "with\\ space" }, select(2, complete("dir=with\\", "with\\")))
    end)

    it("asks to be called again on every keystroke", function()
        set_prompt("")
        -- Without `refresh` Vim filters one frozen candidate list, so a value
        -- can never be narrowed or a path descended into.
        assert.are.equal("always", picker._flag_completefunc(0, "").refresh)
    end)
end)

describe("picker prompt sections", function()
    ---Open a picker whose finder records what it was asked for, write its two
    ---prompt sections and report back. The flags are written first, in flag
    ---mode; a query moves the prompt to query mode, which is where the cursor
    ---ends up -- past the flags, as it was on the one line the two shared.
    ---`cursor` defaults to the end of the flags, where it would sit having just
    ---been typed. `moved_to` moves it afterwards without touching the text, as
    ---arrowing away from what was typed does.
    ---@param spec {flags:string?, query:string?, cursor:integer?, moved_to:(integer|integer[])?}
    ---@return string? query, table? flags, string? err, integer marked, boolean counted
    ---`marked`: spans underlined as a problem. `counted`: the position counter,
    ---which shares the error's corner, is the one showing there.
    local function type_prompt(spec)
        local seen_query, seen_flags
        picker.open({
            prompt = "Errors",
            flags  = {
                { name = "dir",    type = "value" },
                { name = "case",   type = "value", strict = true, values = { "smart", "on", "off" } },
                { name = "hidden", type = "boolean" },
            },
            finder = function(query, flags, _, cb)
                seen_query, seen_flags = query, flags
                cb({ { label_chunks = { { "item" } }, data = {} } })
            end,
            on_confirm = function() end,
        }, function() end)

        local p = picker._active()
        assert.not_nil(p)
        local pbuf, pwin = p.pbuf, p.pwin

        -- Insert mode is where this is typed, and there the cursor may sit one
        -- past the last character; without `onemore` normal mode clamps it back
        -- onto the text and every error looks like one being typed.
        vim.wo[pwin].virtualedit = "onemore"

        local function write(text, col)
            vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, { text })
            vim.api.nvim_win_set_cursor(pwin, { 1, col or #text })
            vim.api.nvim_exec_autocmds("TextChanged", { buffer = pbuf })
            vim.wait(50)
        end

        if spec.flags then
            p:_set_mode("flags")
            write(spec.flags, spec.cursor)
        end

        ---@type integer[]
        local moves = type(spec.moved_to) == "table" and spec.moved_to or { spec.moved_to }
        for _, col in ipairs(moves) do
            vim.api.nvim_win_set_cursor(pwin, { 1, col })
            vim.api.nvim_exec_autocmds("CursorMoved", { buffer = pbuf })
            vim.wait(50)
        end

        if spec.query then
            p:_set_mode("query")
            write(spec.query)
        end

        -- The error gets a virtual line under the query; the position counter
        -- rides on the rule below it, at the right end of the list float's winbar.
        local err
        local marked = 0
        local counted = false
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(pbuf, -1, 0, -1, { details = true })) do
            -- A rule is drawn above the words, so the message is the chunk
            -- carrying the error's own highlight rather than the first one.
            for _, vline in ipairs(m[4] and m[4].virt_lines or {}) do
                for _, chunk in ipairs(vline) do
                    if chunk[2] == "DiagnosticVirtualTextError" then err = vim.trim(chunk[1]) end
                end
            end
            if m[4] and m[4].hl_group == "DiagnosticUnderlineError" then marked = marked + 1 end
        end
        -- Any float but the prompt's: the counter is the list window's winbar,
        -- and the list is the only other one this picker opens.
        for _, w in ipairs(vim.api.nvim_list_wins()) do
            if w ~= pwin and vim.wo[w].winbar:find("%d+/%d+") then counted = true end
        end

        return seen_query, seen_flags, err, marked, counted
    end

    ---A flag as the prefix draws it: the text between the rounded pill ends.
    ---@param text string
    ---@return string
    local function pill(text)
        return "\u{e0b6}" .. text .. "\u{e0b4}"
    end

    ---The prompt's inline prefix, as one string, pill ends included.
    ---@return string
    local function prefix()
        local p = picker._active()
        local text = ""
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(p.pbuf, -1, 0, -1, { details = true })) do
            for _, chunk in ipairs(m[4] and m[4].virt_text or {}) do
                text = text .. chunk[1]
            end
        end
        return text
    end

    after_each(function() vim.cmd("silent! close!") end)

    it("keeps the two sections apart, each on the line in its own mode", function()
        local query, flags = type_prompt({ flags = "hidden", query = "foo bar" })
        assert.are.equal("foo bar", query)
        assert.is_true(flags.hidden)

        local p = picker._active()
        assert.are.equal("foo bar", vim.api.nvim_buf_get_lines(p.pbuf, 0, 1, false)[1])
        assert.are.equal(" " .. pill("hidden") .. " ", prefix())

        p:toggle_prompt_section()
        assert.are.equal("hidden", vim.api.nvim_buf_get_lines(p.pbuf, 0, 1, false)[1])
        assert.are.equal("Flags› ", prefix())

        p:toggle_prompt_section()
        assert.are.equal("foo bar", vim.api.nvim_buf_get_lines(p.pbuf, 0, 1, false)[1])
    end)

    it("shows no prefix at all until a flag is written", function()
        type_prompt({ query = "foo" })
        assert.are.equal("", prefix())
    end)

    it("squeezes the gaps between flags, but not a space inside a value", function()
        -- Leaving the section settles it: the gaps typing opened close up, and
        -- an escaped space is a character of the value, so it stays where it is.
        type_prompt({ flags = "  dir=my\\ src   hidden ", query = "x" })
        local p = picker._active()
        assert.are.equal("dir=my\\ src hidden", p.flag_text)
        assert.are.equal("my src", select(2, type_prompt({ flags = "dir=my\\ src " })).dir)
    end)

    it("reads a flag written in the query as query text", function()
        -- The query section is only ever a query: a dashed word in it is a word
        -- in the search text like any other, neither underlined nor remarked upon.
        local query, flags, err, marked = type_prompt({ query = "hello --hidden" })
        assert.are.equal("hello --hidden", query)
        assert.is_nil(flags.hidden)
        assert.is_nil(err)
        assert.are.equal(0, marked)
    end)

    it("hands the caller the two sections apart", function()
        type_prompt({ flags = "hidden", query = "--x" })
        local query, flag_text = picker._active():_prompt_state()
        assert.are.equal("--x", query)
        assert.are.equal("hidden", flag_text)
    end)

    it("searches for a backslash waiting on the space it will escape", function()
        -- The moment between the '\' and the whitespace it is there to escape is
        -- not a mistake to report: the backslash stands for itself until the
        -- next character says otherwise, and the list keeps up either way.
        local query, flags, err = type_prompt({ flags = "dir=My\\" })
        assert.are.equal("", query)
        assert.are.equal("My\\", flags.dir)
        assert.is_nil(err)
    end)

    it("keeps complaining about a value slot the rest of the line has closed", function()
        -- Deleting the "=b" from "dir=a dir=b" leaves the cursor in the gap,
        -- where the usual hold rule would read it as a name being typed. It is
        -- not: another flag stands behind it, so no amount of typing at the end
        -- of the line fixes it, and going quiet would reward the deletion.
        local err, marked = select(3, type_prompt({ flags = "dir hidden", cursor = 3 }))
        assert.is_truthy(err:find("needs a value", 1, true))
        assert.are.equal(1, marked)
    end)

    it("says nothing about a flag the cursor is still writing", function()
        -- Every one of these is a state on the way to a correct flag; nagging
        -- through them turns the prompt into a stream of complaints.
        assert.is_nil(select(3, type_prompt({ flags = "dir" })))
        assert.is_nil(select(3, type_prompt({ flags = "case=sm" })))
        assert.is_nil(select(3, type_prompt({ flags = "hi" })))
    end)

    it("speaks up once the cursor leaves what it points at", function()
        assert.is_truthy(select(3, type_prompt({ flags = "case=sm", moved_to = 0 }))
            :find("smart|on|off", 1, true))
    end)

    it("speaks up on the cursor leaving alone, with nothing more typed", function()
        -- Held errors are chosen against where the cursor is, so moving away has
        -- to be reason enough to look again. Waiting on the next keystroke never
        -- comes for the line that is finished except for the mistake in it.
        assert.is_truthy(select(3, type_prompt({ flags = "case=sm", moved_to = 0 }))
            :find("smart|on|off", 1, true))
        assert.is_truthy(select(3, type_prompt({ flags = "hiddn", moved_to = 0 }))
            :find("unknown flag: hiddn", 1, true))
        assert.is_truthy(select(3, type_prompt({ flags = "dir", moved_to = 0 }))
            :find("needs a value", 1, true))
    end)

    it("calls a word among the flags what it is: not one", function()
        -- The section holds flags and nothing else, so a word naming none is a
        -- mistake there -- and the query it would have been is one line over.
        local query, _, err, marked = type_prompt({ flags = "hidden foo", moved_to = 0 })
        assert.are.equal("", query)
        assert.is_truthy(err:find("unknown flag: foo", 1, true))
        assert.are.equal(1, marked)
    end)

    it("gives the shared corner to the error, and to the counter on a clean line", function()
        -- The error and the position counter share one corner. An error takes it,
        -- and there is nothing to count anyway: the search does not run.
        local err, _, counted = select(3, type_prompt({ flags = "case=sm", moved_to = 0 }))
        assert.is_truthy(err)
        assert.is_false(counted)
        -- Nothing to say about a line that parses, so the count has the corner.
        err, _, counted = select(3, type_prompt({ flags = "case=smart", query = "x" }))
        assert.is_nil(err)
        assert.is_true(counted)
    end)

    it("refuses to search a typo'd flag, and flags it as unknown", function()
        -- The finder is never asked, leaving the empty query the picker opened
        -- on as the last one that ran.
        local query, _, err = type_prompt({ flags = "hiddn", query = "x" })
        assert.are.equal("", query)
        assert.is_truthy(err:find("unknown flag: hiddn", 1, true))
    end)

    it("marks every occurrence of a flag written twice", function()
        local query, _, err, marked = type_prompt({ flags = "dir=a dir=b" })
        assert.are.equal("", query)
        assert.is_truthy(err:find("2 times", 1, true))
        assert.are.equal(2, marked)
    end)

    it("passes the query through byte for byte", function()
        assert.are.equal("foo  bar", type_prompt({ flags = "hidden", query = "foo  bar" }))
    end)

    it("passes the space around the query through as well", function()
        -- Nothing else shares the line, so there is no flag to tell the query
        -- apart from: what is between the two ends is the query, spaces and all.
        assert.are.equal("  foo  bar  ", type_prompt({ query = "  foo  bar  " }))
    end)
end)
