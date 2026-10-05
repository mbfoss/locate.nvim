local pickertools = require("locate.base.pickertools")

--- Single-pattern shorthand: the pattern semantics are the same whether a glob
--- arrives alone or in a list.
---@param pattern string
---@param relpath string
---@param nocase boolean?
---@return boolean
local function match(pattern, relpath, nocase)
    return pickertools.match_globs({ pattern }, relpath, nocase)
end

describe("match_globs basename patterns (no slash)", function()
    it("matches a basename glob at any depth", function()
        assert.is_true(match("*.txt", "foo.txt"))
        assert.is_true(match("*.txt", "a/b/foo.txt"))
        assert.is_true(match("*.lua", "lua/locate/util/foo.lua"))
    end)

    it("anchors the extension", function()
        assert.is_false(match("*.txt", "foo.txtx"))
        assert.is_false(match("*.txt", "foo.txt.bak"))
    end)

    it("matches a bare name at any depth, the whole component only", function()
        assert.is_true(match("foo", "foo"))
        assert.is_true(match("foo", "a/foo"))
        assert.is_false(match("foo", "foobar"))
        assert.is_false(match("foo", "a/foo/bar")) -- foo is not the final component
    end)

    it("does not let * cross a separator", function()
        assert.is_false(match("*.txt", "a/foo.txt/bar"))
    end)
end)

describe("match_globs anchored patterns (with slash)", function()
    it("anchors to the path root", function()
        assert.is_true(match("src/*.lua", "src/foo.lua"))
        assert.is_false(match("src/*.lua", "lua/src/foo.lua"))
    end)

    it("treats a leading slash as a root anchor", function()
        assert.is_true(match("/foo.txt", "foo.txt"))
        assert.is_false(match("/foo.txt", "a/foo.txt"))
    end)

    it("keeps a single * within one component", function()
        assert.is_true(match("src/*", "src/foo"))
        assert.is_false(match("src/*", "src/foo/bar"))
    end)
end)

describe("match_globs globstar (**)", function()
    it("leading **/ matches zero or more directories", function()
        assert.is_true(match("**/foo", "foo"))
        assert.is_true(match("**/foo", "a/foo"))
        assert.is_true(match("**/foo", "a/b/foo"))
        assert.is_false(match("**/foo", "a/foobar"))
    end)

    it("trailing /** matches everything inside a directory", function()
        assert.is_true(match("src/**", "src/foo"))
        assert.is_true(match("src/**", "src/a/b/c"))
        assert.is_false(match("src/**", "src"))   -- not the directory itself
        assert.is_false(match("src/**", "x/src/foo"))
    end)

    it("interior /**/ matches zero or more directories", function()
        assert.is_true(match("a/**/b", "a/b"))
        assert.is_true(match("a/**/b", "a/x/b"))
        assert.is_true(match("a/**/b", "a/x/y/b"))
        assert.is_false(match("a/**/b", "a/b/c"))
        assert.is_false(match("a/**/b", "x/a/b"))
    end)

    it("combines ** with trailing globs", function()
        assert.is_true(match("src/**/*.lua", "src/foo.lua"))
        assert.is_true(match("src/**/*.lua", "src/a/b/foo.lua"))
        assert.is_false(match("src/**/*.lua", "src/foo.txt"))
    end)
end)

describe("match_globs single character (?)", function()
    it("matches exactly one character", function()
        assert.is_true(match("?.txt", "a.txt"))
        assert.is_false(match("?.txt", "ab.txt"))
        assert.is_false(match("?.txt", ".txt"))
    end)

    it("does not cross a separator", function()
        assert.is_false(match("a?b", "a/b"))
    end)
end)

describe("match_globs character classes", function()
    it("matches a set", function()
        assert.is_true(match("[abc].txt", "a.txt"))
        assert.is_true(match("[abc].txt", "c.txt"))
        assert.is_false(match("[abc].txt", "d.txt"))
    end)

    it("matches a range", function()
        assert.is_true(match("[a-z].lua", "m.lua"))
        assert.is_false(match("[a-z].lua", "0.lua"))
    end)

    it("negates with ! or ^", function()
        assert.is_false(match("[!abc].txt", "a.txt"))
        assert.is_true(match("[!abc].txt", "d.txt"))
        assert.is_true(match("[^abc].txt", "d.txt"))
    end)
end)

describe("match_globs case sensitivity", function()
    it("is case-sensitive like ripgrep --glob", function()
        assert.is_false(match("*.TXT", "foo.txt"))
        assert.is_true(match("*.TXT", "foo.TXT"))
    end)

    it("matches case-insensitively when nocase is set", function()
        assert.is_true(match("*.TXT", "foo.txt", true))
        assert.is_true(match("SRC/*.LUA", "src/foo.lua", true))
        assert.is_true(match("[A-Z].lua", "m.lua", true))
    end)
end)

describe("match_globs negation (!)", function()
    it("inverts a basename pattern", function()
        assert.is_false(match("!*.txt", "foo.txt"))
        assert.is_false(match("!*.txt", "a/b/foo.txt"))
        assert.is_true(match("!*.txt", "foo.lua"))
    end)

    it("inverts an anchored pattern", function()
        assert.is_false(match("!src/*.lua", "src/foo.lua"))
        assert.is_true(match("!src/*.lua", "lua/foo.lua"))
    end)

    it("inverts globstar patterns", function()
        assert.is_false(match("!**/test/**", "a/test/b.lua"))
        assert.is_true(match("!**/test/**", "a/src/b.lua"))
    end)

    it("honours nocase", function()
        assert.is_false(match("!*.TXT", "foo.txt", true))
        assert.is_true(match("!*.TXT", "foo.txt"))
    end)

    it("treats an escaped bang as a literal", function()
        assert.is_true(match("\\!foo.txt", "!foo.txt"))
        assert.is_false(match("\\!foo.txt", "foo.txt"))
    end)

    it("treats only the first bang as special", function()
        -- `!!foo` is a negation of the literal pattern `!foo`, not a double negation
        assert.is_false(match("!!foo", "!foo"))
        assert.is_true(match("!!foo", "foo"))
    end)
end)

describe("match_globs (rg --glob lists)", function()
    local match_globs = pickertools.match_globs

    it("keeps everything for an empty list", function()
        assert.is_true(match_globs({}, "foo.txt"))
    end)

    it("treats a list of positives as a whitelist", function()
        assert.is_true(match_globs({ "*.lua", "*.txt" }, "a/foo.txt"))
        assert.is_false(match_globs({ "*.lua", "*.txt" }, "a/foo.md"))
    end)

    it("treats a list of negations as a blacklist", function()
        assert.is_false(match_globs({ "!*.lua" }, "a/foo.lua"))
        assert.is_true(match_globs({ "!*.lua" }, "a/foo.md"))
    end)

    it("lets the last applicable glob win", function()
        local globs = { "*.lua", "!*_spec.lua" }
        assert.is_true(match_globs(globs, "lua/foo.lua"))
        assert.is_false(match_globs(globs, "tests/foo_spec.lua"))
        assert.is_false(match_globs(globs, "README.md"))
    end)

    it("is order-sensitive, like rg", function()
        local globs = { "!*_spec.lua", "*.lua" }
        assert.is_true(match_globs(globs, "tests/foo_spec.lua"))
        assert.is_true(match_globs(globs, "lua/foo.lua"))
    end)

    it("re-includes after excluding a directory", function()
        local globs = { "!vendor/**", "vendor/keep/**" }
        assert.is_false(match_globs(globs, "vendor/a/b.lua"))
        assert.is_true(match_globs(globs, "vendor/keep/b.lua"))
        -- the positive glob makes the whole list a whitelist
        assert.is_false(match_globs(globs, "src/a.lua"))
    end)

    it("ignores empty patterns when deciding the default", function()
        assert.is_true(match_globs({ "" }, "foo.txt"))
        assert.is_true(match_globs({ "!" }, "foo.txt"))
    end)

    it("honours nocase", function()
        assert.is_true(match_globs({ "*.LUA" }, "foo.lua", true))
        assert.is_false(match_globs({ "*.LUA" }, "foo.lua"))
        assert.is_false(match_globs({ "*.lua", "!*_SPEC.lua" }, "foo_spec.lua", true))
    end)
end)

describe("match_globs edge cases", function()
    it("ignores a trailing directory slash", function()
        assert.is_true(match("foo", "a/foo"))
    end)
end)
