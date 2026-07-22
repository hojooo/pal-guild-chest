describe("test harness", function()
    it("supports equality and expected errors", function()
        local a = require("tests.support.assertions")
        a.equal(2, 1 + 1)
        a.raises("boom", function() error("boom") end)
    end)
end)

describe("test harness assertions", function()
    it("supports deep equality", function()
        local a = require("tests.support.assertions")
        a.deep_equal(
            { name = "guild chest", slots = { 54, 358 } },
            { slots = { 54, 358 }, name = "guild chest" }
        )
    end)
end)
