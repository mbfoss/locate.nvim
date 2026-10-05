local qf = require("locate.base.queryflags")

local schema = {
    { name = "path",      type = "value", values = { "foo", "foo bar", "baz" } },
    { name = "kind",      type = "value", multi = true },
    { name = "repl",      type = "value", alias = { "replace" } },
    { name = "case",      type = "value", strict = true, values = { "smart", "on", "off" } },
    { name = "no-ignore", type = "boolean" },
    { name = "fixed",     type = "boolean" },
}

---An error is a span and a message; nothing on it names the mistake. These
---patterns stand for the kinds the tests below talk about, matched on the
---message. Kept here rather than exported: only the tests sort errors by kind.
---@type table<string, string>
local _KIND = {
    ["unknown-flag"]     = "^unknown flag: ",
    ["not-a-flag"]       = "^no flag name before ",
    ["duplicate-flag"]   = " set %d+ times",
    ["missing-value"]    = " needs a value$",
    ["bad-value"]        = "^%S+=%S*|",
    ["unexpected-value"] = " takes no value$",
}

---@param result locate.queryflags.ParseResult
---@param kind   string  -- a key of `_KIND`
---@return locate.queryflags.Error?
local function error_of(result, kind)
    local pat = assert(_KIND[kind])
    for _, h in ipairs(result.errors) do
        if h.msg:find(pat) then return h end
    end
    return nil
end

---@param result locate.queryflags.ParseResult
---@param kind   string  -- a key of `_KIND`
---@return locate.queryflags.Error[]  -- in the order parse sorted them, left to right
local function errors_of(result, kind)
    local pat = assert(_KIND[kind])
    local found = {}
    for _, h in ipairs(result.errors) do
        if h.msg:find(pat) then found[#found + 1] = h end
    end
    return found
end

describe("queryflags switches", function()
    it("reads nothing out of an empty line", function()
        local r = qf.parse(schema, "")
        assert.are.same({}, r.flags)
        assert.are.same({}, r.errors)
    end)

    it("sets a switch by its name alone", function()
        local r = qf.parse(schema, "fixed")
        assert.is_true(r.flags.fixed)
        assert.are.same({}, r.errors)
    end)

    it("sets several, in any order, over any spacing", function()
        local r = qf.parse(schema, "   fixed    no-ignore  ")
        assert.is_true(r.flags.fixed)
        assert.is_true(r.flags["no-ignore"])
        assert.are.same({}, r.errors)
    end)

    it("takes no value, however it is written", function()
        for _, line in ipairs({ "fixed=true", "fixed=false", "fixed=" }) do
            local r = qf.parse(schema, line)
            assert.is_nil(r.flags.fixed)
            local err = error_of(r, "unexpected-value")
            assert.is_truthy(err)
            assert.is_true(err.settled)
            assert.are.equal(0, err.start)
            assert.are.equal(#line, err.finish)
        end
    end)
end)

describe("queryflags values", function()
    it("reads a value from behind the '='", function()
        local r = qf.parse(schema, "path=src")
        assert.are.equal("src", r.flags.path)
        assert.are.same({}, r.errors)
    end)

    it("keeps a value that reads as a flag name", function()
        local r = qf.parse(schema, "path=fixed")
        assert.are.equal("fixed", r.flags.path)
        assert.are.same({}, r.errors)
    end)

    it("keeps an empty value, which is a value meant", function()
        local r = qf.parse(schema, "path= fixed")
        assert.are.equal("", r.flags.path)
        assert.is_true(r.flags.fixed)
        assert.are.same({}, r.errors)
    end)

    it("takes an escaped space into the value", function()
        assert.are.equal("my src", qf.parse(schema, "path=my\\ src").flags.path)
        assert.are.equal("a\\b", qf.parse(schema, "path=a\\\\b").flags.path)
    end)

    it("reads a '\\' with nothing escapable behind it as content", function()
        assert.are.equal("a\\b", qf.parse(schema, "path=a\\b").flags.path)
        assert.are.equal("My\\", qf.parse(schema, "path=My\\").flags.path)
    end)

    it("ends a value at the whitespace after it", function()
        local r = qf.parse(schema, "path=src fixed")
        assert.are.equal("src", r.flags.path)
        assert.is_true(r.flags.fixed)
    end)
end)

describe("queryflags lists", function()
    it("cuts a multi value at its commas", function()
        assert.are.same({ "a", "b", "c" }, qf.parse(schema, "kind=a,b,c").flags.kind)
    end)

    it("gives a single value back as a one-entry list", function()
        assert.are.same({ "a" }, qf.parse(schema, "kind=a").flags.kind)
    end)

    it("keeps an escaped comma inside the value it was written in", function()
        assert.are.same({ "a", "b,c" }, qf.parse(schema, "kind=a,b\\,c").flags.kind)
    end)

    it("leaves a comma alone where the flag takes no list", function()
        assert.are.equal("a,b", qf.parse(schema, "path=a,b").flags.path)
    end)
end)

describe("queryflags flag names", function()
    it("ignores case", function()
        for _, line in ipairs({ "no-ignore", "NO-IGNORE", "No-Ignore" }) do
            assert.is_true(qf.parse(schema, line).flags["no-ignore"], line)
        end
    end)

    it("spells the name as the schema does, separators and all", function()
        for _, line in ipairs({ "noignore", "no_ignore", "--no-ignore", "no-ignore-" }) do
            assert.is_nil(qf.parse(schema, line).flags["no-ignore"], line)
        end
        assert.is_nil(qf.parse(schema, "--path=x").flags.path)
    end)

    it("answers to an alias under the canonical name", function()
        assert.are.equal("x", qf.parse(schema, "replace=x").flags.repl)
    end)
end)

describe("queryflags errors", function()
    it("calls a word naming no flag unknown, and holds it open", function()
        local r = qf.parse(schema, "fixe")
        local err = error_of(r, "unknown-flag")
        assert.is_truthy(err)
        -- Still being typed, for all the parser can tell.
        assert.is_nil(err.settled)
        assert.are.equal(0, err.start)
        assert.are.equal(4, err.finish)
    end)

    it("settles the unknown name its own '=' closed", function()
        local err = error_of(qf.parse(schema, "fixe=1"), "unknown-flag")
        assert.is_truthy(err)
        assert.is_true(err.settled)
        assert.are.equal(6, err.finish)
    end)

    it("calls a token opening on '=' no flag at all", function()
        local err = error_of(qf.parse(schema, "=x"), "not-a-flag")
        assert.is_truthy(err)
        assert.is_true(err.settled)
    end)

    it("holds the open slot of the last word on the line", function()
        local err = error_of(qf.parse(schema, "fixed path"), "missing-value")
        assert.is_truthy(err)
        -- "path=" is a keystroke away.
        assert.is_nil(err.settled)
        assert.are.equal(6, err.start)
        assert.are.equal(10, err.finish)
    end)

    it("settles the open slot the rest of the line closed", function()
        local err = error_of(qf.parse(schema, "path fixed"), "missing-value")
        assert.is_truthy(err)
        assert.is_true(err.settled)
    end)

    it("names the values a strict flag will take", function()
        local err = error_of(qf.parse(schema, "case=maybe"), "bad-value")
        assert.is_truthy(err)
        assert.are.equal("case=smart|on|off", err.msg)
        assert.are.equal(5, err.start)
        assert.are.equal(10, err.finish)
    end)

    it("points an empty strict value at the flag that went without one", function()
        local err = error_of(qf.parse(schema, "case="), "bad-value")
        assert.is_truthy(err)
        assert.are.equal(0, err.start)
        assert.are.equal(5, err.finish)
    end)

    it("lets a strict value through", function()
        local r = qf.parse(schema, "case=smart")
        assert.are.equal("smart", r.flags.case)
        assert.are.same({}, r.errors)
    end)

    it("marks every occurrence of a flag written twice, last one winning", function()
        local r = qf.parse(schema, "path=a path=b")
        assert.are.equal("b", r.flags.path)
        local errors = errors_of(r, "duplicate-flag")
        assert.are.equal(2, #errors)
        for _, h in ipairs(errors) do
            assert.is_true(h.settled)
            assert.are.equal("path set 2 times", h.msg)
        end
        assert.are.equal(0, errors[1].start)
        assert.are.equal(4, errors[1].finish)
        assert.are.equal(7, errors[2].start)
    end)

    it("lets a switch be repeated, which sets it and no more", function()
        local r = qf.parse(schema, "fixed fixed")
        assert.is_true(r.flags.fixed)
        assert.are.same({}, r.errors)
    end)

    it("counts two spellings of one flag as one repetition, told in both", function()
        local errors = errors_of(qf.parse(schema, "repl=a replace=b"), "duplicate-flag")
        assert.are.equal(2, #errors)
        assert.are.equal("repl set 2 times", errors[1].msg)
        assert.are.equal("replace set 2 times", errors[2].msg)
    end)


    it("sorts errors left to right", function()
        local r = qf.parse(schema, "nope case=maybe")
        assert.is_true(#r.errors >= 2)
        for i = 2, #r.errors do
            assert.is_true(r.errors[i - 1].start <= r.errors[i].start)
        end
    end)
end)

describe("queryflags strict lists", function()
    local list_schema = {
        { name = "kind", type = "value", multi = true, strict = true, values = { "a", "b" } },
    }

    it("judges each value of a list on its own", function()
        local errors = errors_of(qf.parse(list_schema, "kind=a,x,b"), "bad-value")
        assert.are.equal(1, #errors)
        assert.are.equal(7, errors[1].start)
        assert.are.equal(8, errors[1].finish)
    end)

    it("passes a list whose values are all known", function()
        assert.are.same({}, qf.parse(list_schema, "kind=a,b").errors)
    end)
end)

describe("queryflags schema", function()
    it("refuses a strict flag that lists no values", function()
        assert.has_error(function()
            qf.parse({ { name = "x", type = "value", strict = true } }, "")
        end)
    end)
end)

describe("queryflags highlight", function()
    ---@return table<integer, string>  -- 0-indexed byte → the last hl covering it
    local function styled(line)
        local map = {}
        for _, h in ipairs(qf.highlight(schema, line)) do
            for i = h.start, h.finish - 1 do map[i] = h.hl end
        end
        return map
    end

    it("styles a name as a keyword", function()
        local m = styled("fixed")
        assert.are.equal("@keyword", m[0])
        assert.are.equal("@keyword", m[4])
    end)

    it("styles the '=' apart from the name and the value", function()
        local m = styled("path=src")
        assert.are.equal("@keyword", m[3])
        assert.are.equal("@tag.delimiter", m[4])
        assert.are.equal("@string", m[5])
    end)

    it("styles a list separator, but only where the flag takes a list", function()
        assert.are.equal("@tag.delimiter", styled("kind=a,b")[6])
        assert.are.equal("@string", styled("path=a,b")[6])
    end)

    it("styles an escaping backslash apart from what it escapes", function()
        local m = styled("path=a\\ b")
        assert.are.equal("NonText", m[6])
        assert.are.equal("@string", m[7])
    end)

    it("leaves a word naming no flag unstyled", function()
        assert.are.same({}, styled("nope"))
    end)
end)

describe("queryflags completion", function()
    ---@return integer? startcol, string[] words
    local function complete(line)
        local comps = qf.get_completions(schema, line, #line)
        if not comps then return nil, {} end
        return comps.startcol, vim.tbl_map(function(it) return it.word end, comps.items)
    end

    it("offers flag names for the word being typed", function()
        local startcol, words = complete("fi")
        assert.are.equal(1, startcol)
        assert.are.same({ "fixed" }, words)
    end)

    it("offers a value flag with the '=' already on it", function()
        assert.are.same({ "path=" }, select(2, complete("pat")))
    end)

    it("offers every name on an empty line", function()
        local _, words = complete("")
        assert.are.equal(#schema, #words)
    end)

    it("leaves out a flag already on the line", function()
        local _, words = complete("fixed ")
        assert.is_false(vim.tbl_contains(words, "fixed"))
        assert.is_true(vim.tbl_contains(words, "no-ignore"))
    end)

    it("counts a flag written under an alias as written", function()
        assert.is_false(vim.tbl_contains(select(2, complete("replace=x ")), "repl="))
    end)

    it("counts a flag written ahead of the cursor as written", function()
        local comps = qf.get_completions(schema, "  fixed", 0)
        local words = vim.tbl_map(function(it) return it.word end, assert(comps).items)
        assert.is_false(vim.tbl_contains(words, "fixed"))
    end)

    it("still offers the flag the cursor is retyping", function()
        assert.are.same({ "fixed" }, select(2, complete("fixed")))
    end)

    it("offers nothing once every flag is written", function()
        assert.are.same({}, select(2, complete("path=a kind=b repl=c case=on no-ignore fixed ")))
    end)

    it("offers names case-insensitively, as the parser reads them", function()
        assert.are.same({ "no-ignore" }, select(2, complete("NO-IG")))
    end)

    it("offers values once the '=' is written", function()
        local startcol, words = complete("path=")
        assert.are.equal(6, startcol)
        assert.is_true(vim.tbl_contains(words, "foo"))
        assert.is_true(vim.tbl_contains(words, "baz"))
    end)

    it("narrows the values by what was typed behind the '='", function()
        local startcol, words = complete("path=ba")
        assert.are.equal(6, startcol)
        assert.are.same({ "baz" }, words)
    end)

    it("escapes a candidate so it re-parses as the value it names", function()
        assert.are.same({ "foo", "foo\\ bar" }, select(2, complete("path=foo")))
    end)

    it("completes only the value being written in a list", function()
        local list_schema = { { name = "kind", type = "value", multi = true, values = { "alpha", "beta" } } }
        local comps = qf.get_completions(list_schema, "kind=alpha,be", 13)
        assert.are.equal(12, comps.startcol)
        assert.are.same({ "beta" }, vim.tbl_map(function(it) return it.word end, comps.items))
    end)

    it("says nothing for a value flag with no candidates to offer", function()
        assert.is_nil(qf.get_completions(schema, "repl=x", 6))
    end)

    it("says nothing with the cursor inside a word", function()
        assert.is_nil(qf.get_completions(schema, "fixed", 2))
    end)

    it("offers names again once a value is behind it", function()
        local startcol, words = complete("path=src fi")
        assert.are.equal(10, startcol)
        assert.are.same({ "fixed" }, words)
    end)

    it("takes a slot and a description into the menu entry", function()
        local items = qf.get_completions(
            { { name = "dir", type = "value", slot = "path", desc = "search under" } }, "d", 1).items
        assert.are.equal("dir=<path>", items[1].abbr)
        assert.are.equal("search under", items[1].menu)
    end)

    it("marks a list slot as one", function()
        local items = qf.get_completions(
            { { name = "kind", type = "value", multi = true } }, "k", 1).items
        assert.are.equal("kind=<value,...>", items[1].abbr)
    end)
end)
