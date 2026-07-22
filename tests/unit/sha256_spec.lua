local a = require("tests.support.assertions")
local sha256 = require("CrossplayGuildChestExpander.Scripts.sha256")

describe("sha256.hex", function()
    it("matches the empty-string NIST test vector", function()
        a.equal(
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            sha256.hex("")
        )
    end)

    it("matches the abc NIST test vector", function()
        a.equal(
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            sha256.hex("abc")
        )
    end)

    it("matches the multi-block NIST test vector", function()
        a.equal(
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
            sha256.hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
        )
    end)

    it("hashes binary input", function()
        a.equal(
            "7ea646958715ed687aa9ac2f5d785feb1a93411f4f25fdd6c7fcc6ab07fdf0e3",
            sha256.hex(string.char(0, 1, 2, 3, 254, 255))
        )
    end)

    it("handles SHA-256 padding boundaries", function()
        local vectors = {
            [55] = "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318",
            [56] = "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a",
            [63] = "7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34",
            [64] = "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb",
        }

        for length, expected in pairs(vectors) do
            a.equal(expected, sha256.hex(string.rep("a", length)))
        end
    end)
end)
