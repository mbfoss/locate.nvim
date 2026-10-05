local files = require("locate.pickers.files")

local resolve_case = files._resolve_case
local resolve_mode = files._resolve_mode
local do_match     = files._do_match

describe("resolve_mode", function()
    it("defaults to fuzzy with no mode flag set", function()
        assert.are.equal("fuzzy", resolve_mode({}))
    end)

    it("names the mode of whichever flag is set", function()
        assert.are.equal("fixed", resolve_mode({ fixed = true }))
        assert.are.equal("glob", resolve_mode({ glob = true }))
    end)

    it("picks one when several are set", function()
        assert.are.equal("glob", resolve_mode({ glob = true, fixed = true }))
    end)
end)

describe("resolve_case", function()
    it("honors the explicit case flags", function()
        assert.is_true(resolve_case({ case = true }, "foo"))
        assert.is_false(resolve_case({ nocase = true }, "FOO"))
    end)

    it("lets case win over nocase", function()
        assert.is_true(resolve_case({ case = true, nocase = true }, "foo"))
    end)

    it("smart-cases on uppercase when neither is set", function()
        assert.is_false(resolve_case({}, "foo"))
        assert.is_true(resolve_case({}, "Foo"))
    end)
end)

describe("do_match (fuzzy)", function()
    it("matches case-insensitively then gates on case_sensitive", function()
        assert.not_nil(do_match("README.md", "README.md", "rdme", "fuzzy", false))
        assert.not_nil(do_match("FooBar", "FooBar", "foo", "fuzzy", false))
        assert.is_nil(do_match("FooBar", "FooBar", "foo", "fuzzy", true))
        assert.not_nil(do_match("FooBar", "FooBar", "Foo", "fuzzy", true))
    end)

    it("defaults to fuzzy when mode is nil", function()
        assert.not_nil(do_match("README.md", "README.md", "rdme", nil, false))
    end)
end)

describe("do_match (fixed)", function()
    it("requires a contiguous substring, not a subsequence", function()
        assert.not_nil(do_match("README.md", "README.md", "adme", "fixed", false))
        assert.is_nil(do_match("README.md", "README.md", "rdme", "fixed", false))
    end)

    it("matches case-insensitively then gates on case_sensitive", function()
        assert.not_nil(do_match("FooBar", "FooBar", "oob", "fixed", false))
        assert.is_nil(do_match("FooBar", "FooBar", "oob", "fixed", true))
        assert.not_nil(do_match("FooBar", "FooBar", "ooB", "fixed", true))
    end)
end)

describe("do_match (inpath)", function()
    it("matches over the relative path instead of the basename", function()
        assert.not_nil(do_match("foo.lua", "src/foo.lua", "src/foo", "fixed", false, nil, true))
        assert.is_nil(do_match("foo.lua", "src/foo.lua", "src/foo", "fixed", false, nil, false))
        assert.not_nil(do_match("foo.lua", "src/deep/foo.lua", "sdfoo", "fuzzy", false, nil, true))
        assert.is_nil(do_match("foo.lua", "src/deep/foo.lua", "sdfoo", "fuzzy", false, nil, false))
    end)

    it("highlights over the path, so the row can drop its directory prefix", function()
        local res = do_match("foo.lua", "src/foo.lua", "src", "fixed", false, nil, true)
        assert.not_nil(res)
        assert.are.same({ { "src", "LocateMatch" }, { "/foo.lua" } }, res.chunks)
    end)

    it("widens glob chunks to the path it already matched", function()
        local res = do_match("foo.lua", "src/foo.lua", "*.lua", "glob", false, nil, true)
        assert.not_nil(res)
        assert.are.same({ { "src/foo.lua" } }, res.chunks)
    end)
end)

describe("do_match (glob)", function()
    it("matches the relative path with rg-style globs", function()
        assert.not_nil(do_match("foo.lua", "src/foo.lua", "*.lua", "glob", false))
        assert.is_nil(do_match("foo.txt", "src/foo.txt", "*.lua", "glob", false))
        assert.not_nil(do_match("foo.lua", "src/foo.lua", "src/*.lua", "glob", false))
        assert.is_nil(do_match("foo.lua", "lib/foo.lua", "src/*.lua", "glob", false))
    end)

    it("honors case sensitivity", function()
        assert.not_nil(do_match("Foo.LUA", "Foo.LUA", "*.lua", "glob", false))
        assert.is_nil(do_match("Foo.LUA", "Foo.LUA", "*.lua", "glob", true))
    end)

    it("takes a whitespace-separated sequence of globs", function()
        local q = "*.lua *.txt"
        assert.not_nil(do_match("foo.lua", "src/foo.lua", q, "glob", false))
        assert.not_nil(do_match("foo.txt", "src/foo.txt", q, "glob", false))
        assert.is_nil(do_match("foo.md", "src/foo.md", q, "glob", false))
    end)

    it("lets a later negation exclude, like rg --glob", function()
        local q = "*.lua  !*_spec.lua"
        assert.not_nil(do_match("foo.lua", "lua/foo.lua", q, "glob", false))
        assert.is_nil(do_match("foo_spec.lua", "tests/foo_spec.lua", q, "glob", false))
    end)
end)
