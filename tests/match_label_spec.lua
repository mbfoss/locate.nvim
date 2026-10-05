local pickertools = require("locate.base.pickertools")

local match = pickertools.match_label

describe("match_label", function()
    it("matches regardless of case", function()
        assert.not_nil(match("Foobar", "foo"))
        assert.not_nil(match("foobar", "FOO"))
        assert.not_nil(match("README.md", "rdme"))
    end)

    it("returns nil when characters are absent", function()
        assert.is_nil(match("foobar", "xyz"))
    end)

    it("matches an empty query", function()
        assert.not_nil(match("foobar", ""))
    end)
end)
