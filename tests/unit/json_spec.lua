local a = require("tests.support.assertions")
local json = require("CrossplayGuildChestExpander.Scripts.json")

describe("json.decode", function()
    it("decodes nested objects and arrays", function()
        a.deep_equal(
            { a = 1, b = { true, false } },
            json.decode('{"b":[true,false],"a":1}')
        )
    end)

    it("decodes JSON string escapes and Unicode escapes", function()
        a.equal('"\\/\b\f\n\r\tA한😀', json.decode('"\\\"\\\\\\/\\b\\f\\n\\r\\t\\u0041\\uD55C\\uD83D\\uDE00"'))
    end)

    it("decodes JSON numbers", function()
        a.deep_equal(
            { -12, 0, 3.5, 6e2, -0.025 },
            json.decode('[-12,0,3.5,6e2,-2.5e-2]')
        )
    end)

    it("decodes booleans and preserves null with its sentinel", function()
        a.deep_equal(
            { truth = true, falsity = false, nothing = json.null },
            json.decode('{"truth":true,"falsity":false,"nothing":null}')
        )
    end)

    it("rejects duplicate object keys", function()
        a.raises("duplicate key", function()
            json.decode('{"a":1,"a":2}')
        end)
    end)

    it("rejects trailing input", function()
        a.raises("trailing input", function()
            json.decode('true false')
        end)
    end)

    it("rejects non-finite decoded numbers", function()
        a.raises("finite number", function()
            json.decode('1e9999')
        end)
    end)

    it("rejects malformed number grammar", function()
        for _, text in ipairs({ "-", "01", "1.", "1e", "1e+", "+1", ".1" }) do
            a.raises("invalid JSON", function()
                json.decode(text)
            end)
        end
    end)

    it("rejects invalid raw UTF-8", function()
        a.raises("invalid UTF%-8", function()
            json.decode('"' .. string.char(0xC0, 0x80) .. '"')
        end)
    end)

    it("rejects unpaired Unicode surrogates", function()
        a.raises("unpaired Unicode surrogate", function()
            json.decode('"\\uD800"')
        end)
        a.raises("unpaired Unicode surrogate", function()
            json.decode('"\\uDC00"')
        end)
    end)
end)

describe("json.encode", function()
    it("encodes objects with deterministic lexicographic key ordering", function()
        a.equal('{"a":1,"b":[true,false]}', json.encode({ b = { true, false }, a = 1 }))
    end)

    it("encodes null with its explicit sentinel", function()
        a.equal('{"nothing":null}', json.encode({ nothing = json.null }))
    end)

    it("retains an empty array decoded from JSON", function()
        a.equal("[]", json.encode(json.decode("[]")))
    end)

    it("preserves Lua 5.4 integers exactly", function()
        a.equal("9007199254740993", json.encode(9007199254740993))
        a.equal("9223372036854775807", json.encode(math.maxinteger))
        a.equal("-9223372036854775808", json.encode(math.mininteger))
    end)

    it("rejects non-finite numbers", function()
        a.raises("finite number", function()
            json.encode(math.huge)
        end)
        a.raises("finite number", function()
            json.encode(0 / 0)
        end)
    end)

    it("rejects cyclic tables", function()
        local cyclic = {}
        cyclic.self = cyclic

        a.raises("cyclic table", function()
            json.encode(cyclic)
        end)
    end)

    it("rejects sparse arrays and non-string object keys", function()
        a.raises("sparse", function()
            json.encode({ [1] = "one", [3] = "three" })
        end)
        a.raises("keys must be strings", function()
            json.encode({ [true] = "value" })
        end)
    end)

    it("rejects invalid UTF-8 strings", function()
        a.raises("valid UTF%-8", function()
            json.encode(string.char(0xFF))
        end)
    end)
end)
