local locate = require("locate")
local picker = require("locate.base.picker")

local seen = {}

local source = locate.register("pick_cmd_spec", {
    prompt     = "Args",
    flags      = {
        { name = "dir",    type = "value" },
        { name = "hidden", type = "boolean" },
    },
    finder     = function(query, flags, _, cb)
        seen = { query = query, flags = flags }
        cb({})
    end,
    on_confirm = function() end,
})

describe(":Locate arguments", function()
    after_each(function() vim.cmd("silent! close!") end)

    ---Run `:Locate` and report the two prompt sections it opened on.
    ---@param args string
    ---@return string flag_text, string query
    local function run(args)
        vim.cmd(("Locate %s %s"):format(source, args))
        vim.wait(100)
        local p = assert(picker._active())
        return p.flag_text, p.query_text
    end

    it("reads the flags between --flags and --", function()
        local flag_text = run("--flags hidden dir=lua -- query")
        assert.are.equal("hidden dir=lua", flag_text)
        assert.is_true(seen.flags.hidden)
        assert.are.equal("lua", seen.flags.dir)
        assert.are.equal("query", seen.query)
    end)

    it("keeps an escaped space in a flag value", function()
        assert.are.equal("dir=my\\ src", run("--flags dir=my\\ src"))
        assert.are.equal("my src", seen.flags.dir)
    end)

    it("glues a -- after an escaped space, not the separator", function()
        local flag_text, query = run("--flags dir=my\\ --")
        assert.are.equal("dir=my\\ --", flag_text)
        assert.are.equal("", query)
        assert.are.equal("my --", seen.flags.dir)
    end)

    it("takes the whole line as the query without --flags", function()
        local flag_text, query = run("fn%s+%w+ two")
        assert.are.equal("", flag_text)
        assert.are.equal("fn%s+%w+ two", query)
        assert.are.equal("fn%s+%w+ two", seen.query)
    end)

    it("needs no quoting in the query, flag-shaped or not", function()
        assert.are.equal("--hidden -x", select(2, run("--hidden -x")))
    end)

    it("opens on nothing at all with no arguments", function()
        vim.cmd("Locate " .. source)
        vim.wait(100)
        local p = assert(picker._active())
        assert.are.equal("", p.flag_text)
        assert.are.equal("", p.query_text)
    end)

    it("opens the query at a --", function()
        local flag_text, query = run("--flags hidden -- -f dir=x")
        assert.are.equal("hidden", flag_text)
        assert.are.equal("-f dir=x", query)
        assert.are.equal("-f dir=x", seen.query)
        assert.is_true(seen.flags.hidden)
    end)

    it("keeps a second -- in the query", function()
        assert.are.equal("-- one", select(2, run("--flags hidden -- -- one")))
    end)

    it("keeps a -- in a query that has no flags section", function()
        assert.are.equal("-- one", select(2, run("-- one")))
    end)

    it("opens on nothing at all at a trailing --", function()
        local flag_text, query = run("--flags hidden --")
        assert.are.equal("hidden", flag_text)
        assert.are.equal("", query)
    end)

    it("completes --flags, then the source's flags behind it", function()
        local cmdline = require("locate.cmdline")
        ---@param line string
        ---@return string[]
        local function complete(line)
            return cmdline.complete(line:match("(%S*)$"), line, #line)
        end

        local line = ("Locate %s "):format(source)
        assert.are.same({ "--flags" }, complete(line))
        assert.are.same({ "--flags" }, complete(line .. "--"))
        assert.are.same({ "--flags" }, complete(line .. "--fla"))
        assert.are.same({ "dir=", "hidden" }, complete(line .. "--flags "))
        assert.are.same({ "hidden" }, complete(line .. "--flags hid"))
        assert.are.same({ "hidden" }, complete(line .. "--flags dir=lua hid"))
        -- Past a -- or a word that is not --flags the line is query: free text.
        assert.are.same({}, complete(line .. "some query hid"))
        assert.are.same({}, complete(line .. "--flags dir=lua -- hid"))
    end)
end)
