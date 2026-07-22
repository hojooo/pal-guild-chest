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
end)
