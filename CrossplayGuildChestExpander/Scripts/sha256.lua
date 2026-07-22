local sha256 = {}

local MASK = 0xFFFFFFFF

local ROUND_CONSTANTS = {
    0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
    0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3, 0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
    0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
    0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
    0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13, 0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
    0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
    0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
    0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208, 0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2,
}

local function add(...)
    local sum = 0
    for index = 1, select("#", ...) do
        sum = sum + select(index, ...)
    end
    return sum & MASK
end

local function rotate_right(value, amount)
    return ((value >> amount) | (value << (32 - amount))) & MASK
end

local function word_from_bytes(text, index)
    return (text:byte(index) << 24)
        | (text:byte(index + 1) << 16)
        | (text:byte(index + 2) << 8)
        | text:byte(index + 3)
end

local function word_to_bytes(value)
    return string.char(
        (value >> 24) & 0xFF,
        (value >> 16) & 0xFF,
        (value >> 8) & 0xFF,
        value & 0xFF
    )
end

function sha256.hex(text)
    if type(text) ~= "string" then
        error("SHA-256 input must be a string", 2)
    end

    local high_length = (#text >> 29) & MASK
    local low_length = (#text << 3) & MASK
    local zero_padding = (56 - ((#text + 1) % 64)) % 64
    local message = text .. "\128" .. string.rep("\0", zero_padding)
        .. word_to_bytes(high_length) .. word_to_bytes(low_length)

    local h0 = 0x6A09E667
    local h1 = 0xBB67AE85
    local h2 = 0x3C6EF372
    local h3 = 0xA54FF53A
    local h4 = 0x510E527F
    local h5 = 0x9B05688C
    local h6 = 0x1F83D9AB
    local h7 = 0x5BE0CD19

    for chunk = 1, #message, 64 do
        local words = {}
        for index = 1, 16 do
            words[index] = word_from_bytes(message, chunk + ((index - 1) * 4))
        end
        for index = 17, 64 do
            local small_sigma0 = rotate_right(words[index - 15], 7)
                ~ rotate_right(words[index - 15], 18)
                ~ (words[index - 15] >> 3)
            local small_sigma1 = rotate_right(words[index - 2], 17)
                ~ rotate_right(words[index - 2], 19)
                ~ (words[index - 2] >> 10)
            words[index] = add(words[index - 16], small_sigma0, words[index - 7], small_sigma1)
        end

        local a, b, c, d = h0, h1, h2, h3
        local e, f, g, h = h4, h5, h6, h7
        for index = 1, 64 do
            local sum1 = rotate_right(e, 6) ~ rotate_right(e, 11) ~ rotate_right(e, 25)
            local choice = (e & f) ~ ((~e) & g)
            local temporary1 = add(h, sum1, choice, ROUND_CONSTANTS[index], words[index])
            local sum0 = rotate_right(a, 2) ~ rotate_right(a, 13) ~ rotate_right(a, 22)
            local majority = (a & b) ~ (a & c) ~ (b & c)
            local temporary2 = add(sum0, majority)

            h = g
            g = f
            f = e
            e = add(d, temporary1)
            d = c
            c = b
            b = a
            a = add(temporary1, temporary2)
        end

        h0 = add(h0, a)
        h1 = add(h1, b)
        h2 = add(h2, c)
        h3 = add(h3, d)
        h4 = add(h4, e)
        h5 = add(h5, f)
        h6 = add(h6, g)
        h7 = add(h7, h)
    end

    return string.format("%08x%08x%08x%08x%08x%08x%08x%08x", h0, h1, h2, h3, h4, h5, h6, h7)
end

return sha256
