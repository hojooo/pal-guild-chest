local json = {}

json.null = {}

local decoded_empty_arrays = setmetatable({}, { __mode = "k" })

local function is_finite(number)
    return number == number and number ~= math.huge and number ~= -math.huge
end

local function encode_utf8(codepoint)
    if codepoint <= 0x7F then
        return string.char(codepoint)
    end
    if codepoint <= 0x7FF then
        return string.char(
            0xC0 | (codepoint >> 6),
            0x80 | (codepoint & 0x3F)
        )
    end
    if codepoint <= 0xFFFF then
        return string.char(
            0xE0 | (codepoint >> 12),
            0x80 | ((codepoint >> 6) & 0x3F),
            0x80 | (codepoint & 0x3F)
        )
    end

    return string.char(
        0xF0 | (codepoint >> 18),
        0x80 | ((codepoint >> 12) & 0x3F),
        0x80 | ((codepoint >> 6) & 0x3F),
        0x80 | (codepoint & 0x3F)
    )
end

local function valid_utf8(text)
    local index = 1
    local length = #text

    while index <= length do
        local first = text:byte(index)
        if first <= 0x7F then
            index = index + 1
        else
            local second = text:byte(index + 1)
            local third = text:byte(index + 2)
            local fourth = text:byte(index + 3)

            if first >= 0xC2 and first <= 0xDF and second and second >= 0x80 and second <= 0xBF then
                index = index + 2
            elseif first == 0xE0 and second and second >= 0xA0 and second <= 0xBF
                and third and third >= 0x80 and third <= 0xBF then
                index = index + 3
            elseif ((first >= 0xE1 and first <= 0xEC) or (first >= 0xEE and first <= 0xEF))
                and second and second >= 0x80 and second <= 0xBF
                and third and third >= 0x80 and third <= 0xBF then
                index = index + 3
            elseif first == 0xED and second and second >= 0x80 and second <= 0x9F
                and third and third >= 0x80 and third <= 0xBF then
                index = index + 3
            elseif first == 0xF0 and second and second >= 0x90 and second <= 0xBF
                and third and third >= 0x80 and third <= 0xBF
                and fourth and fourth >= 0x80 and fourth <= 0xBF then
                index = index + 4
            elseif first >= 0xF1 and first <= 0xF3
                and second and second >= 0x80 and second <= 0xBF
                and third and third >= 0x80 and third <= 0xBF
                and fourth and fourth >= 0x80 and fourth <= 0xBF then
                index = index + 4
            elseif first == 0xF4 and second and second >= 0x80 and second <= 0x8F
                and third and third >= 0x80 and third <= 0xBF
                and fourth and fourth >= 0x80 and fourth <= 0xBF then
                index = index + 4
            else
                return false
            end
        end
    end

    return true
end

function json.decode(text)
    if type(text) ~= "string" then
        error("JSON text must be a string", 2)
    end

    local index = 1
    local length = #text

    local function fail(message)
        error(string.format("invalid JSON at byte %d: %s", index, message), 0)
    end

    local function skip_whitespace()
        while index <= length do
            local character = text:sub(index, index)
            if character ~= " " and character ~= "\n" and character ~= "\r" and character ~= "\t" then
                return
            end
            index = index + 1
        end
    end

    local parse_value

    local function parse_string()
        index = index + 1
        local characters = {}

        while index <= length do
            local value = text:byte(index)
            if value == 0x22 then
                index = index + 1
                local decoded = table.concat(characters)
                if not valid_utf8(decoded) then
                    fail("invalid UTF-8 string")
                end
                return decoded
            end
            if value < 0x20 then
                fail("unescaped control character in string")
            end
            if value ~= 0x5C then
                characters[#characters + 1] = string.char(value)
                index = index + 1
            else
                index = index + 1
                local escape = text:sub(index, index)
                local replacements = {
                    ['"'] = '"',
                    ["\\"] = "\\",
                    ["/"] = "/",
                    b = "\b",
                    f = "\f",
                    n = "\n",
                    r = "\r",
                    t = "\t",
                }

                if replacements[escape] then
                    characters[#characters + 1] = replacements[escape]
                    index = index + 1
                elseif escape == "u" then
                    local hexadecimal = text:sub(index + 1, index + 4)
                    if #hexadecimal ~= 4 or not hexadecimal:match("^%x%x%x%x$") then
                        fail("invalid Unicode escape")
                    end

                    local codepoint = tonumber(hexadecimal, 16)
                    index = index + 5
                    if codepoint >= 0xD800 and codepoint <= 0xDBFF then
                        if text:sub(index, index + 1) ~= "\\u" then
                            fail("unpaired Unicode surrogate")
                        end

                        local low_hexadecimal = text:sub(index + 2, index + 5)
                        if #low_hexadecimal ~= 4 or not low_hexadecimal:match("^%x%x%x%x$") then
                            fail("invalid Unicode escape")
                        end

                        local low_surrogate = tonumber(low_hexadecimal, 16)
                        if low_surrogate < 0xDC00 or low_surrogate > 0xDFFF then
                            fail("unpaired Unicode surrogate")
                        end

                        codepoint = 0x10000 + ((codepoint - 0xD800) << 10) + (low_surrogate - 0xDC00)
                        index = index + 6
                    elseif codepoint >= 0xDC00 and codepoint <= 0xDFFF then
                        fail("unpaired Unicode surrogate")
                    end

                    characters[#characters + 1] = encode_utf8(codepoint)
                else
                    fail("invalid string escape")
                end
            end
        end

        fail("unterminated string")
    end

    local function parse_number()
        local start = index
        if text:sub(index, index) == "-" then
            index = index + 1
        end

        local first_digit = text:sub(index, index)
        if first_digit == "0" then
            index = index + 1
            if text:sub(index, index):match("%d") then
                fail("leading zero in number")
            end
        elseif first_digit:match("[1-9]") then
            repeat
                index = index + 1
            until not text:sub(index, index):match("%d")
        else
            fail("invalid number")
        end

        if text:sub(index, index) == "." then
            index = index + 1
            if not text:sub(index, index):match("%d") then
                fail("invalid number fraction")
            end
            repeat
                index = index + 1
            until not text:sub(index, index):match("%d")
        end

        local exponent = text:sub(index, index)
        if exponent == "e" or exponent == "E" then
            index = index + 1
            local sign = text:sub(index, index)
            if sign == "+" or sign == "-" then
                index = index + 1
            end
            if not text:sub(index, index):match("%d") then
                fail("invalid number exponent")
            end
            repeat
                index = index + 1
            until not text:sub(index, index):match("%d")
        end

        local number = tonumber(text:sub(start, index - 1))
        if not is_finite(number) then
            fail("number must be a finite number")
        end
        return number
    end

    local function parse_array()
        index = index + 1
        skip_whitespace()
        local array = {}
        if text:sub(index, index) == "]" then
            index = index + 1
            decoded_empty_arrays[array] = true
            return array
        end

        while true do
            array[#array + 1] = parse_value()
            skip_whitespace()
            local separator = text:sub(index, index)
            if separator == "]" then
                index = index + 1
                return array
            end
            if separator ~= "," then
                fail("expected comma or closing bracket")
            end
            index = index + 1
            skip_whitespace()
        end
    end

    local function parse_object()
        index = index + 1
        skip_whitespace()
        local object = {}
        if text:sub(index, index) == "}" then
            index = index + 1
            return object
        end

        while true do
            if text:sub(index, index) ~= '"' then
                fail("expected object key")
            end
            local key = parse_string()
            if object[key] ~= nil then
                fail("duplicate key")
            end
            skip_whitespace()
            if text:sub(index, index) ~= ":" then
                fail("expected colon")
            end
            index = index + 1
            skip_whitespace()
            object[key] = parse_value()
            skip_whitespace()

            local separator = text:sub(index, index)
            if separator == "}" then
                index = index + 1
                return object
            end
            if separator ~= "," then
                fail("expected comma or closing brace")
            end
            index = index + 1
            skip_whitespace()
        end
    end

    parse_value = function()
        skip_whitespace()
        local character = text:sub(index, index)
        if character == '"' then
            return parse_string()
        end
        if character == "[" then
            return parse_array()
        end
        if character == "{" then
            return parse_object()
        end
        if character == "t" and text:sub(index, index + 3) == "true" then
            index = index + 4
            return true
        end
        if character == "f" and text:sub(index, index + 4) == "false" then
            index = index + 5
            return false
        end
        if character == "n" and text:sub(index, index + 3) == "null" then
            index = index + 4
            return json.null
        end
        if character == "-" or character:match("%d") then
            return parse_number()
        end
        fail("expected value")
    end

    local value = parse_value()
    skip_whitespace()
    if index <= length then
        fail("trailing input")
    end
    return value
end

local function encode_string(value)
    if not valid_utf8(value) then
        error("JSON strings must contain valid UTF-8", 3)
    end

    local escaped = { '"' }
    for index = 1, #value do
        local byte = value:byte(index)
        if byte == 0x22 then
            escaped[#escaped + 1] = '\\"'
        elseif byte == 0x5C then
            escaped[#escaped + 1] = "\\\\"
        elseif byte == 0x08 then
            escaped[#escaped + 1] = "\\b"
        elseif byte == 0x09 then
            escaped[#escaped + 1] = "\\t"
        elseif byte == 0x0A then
            escaped[#escaped + 1] = "\\n"
        elseif byte == 0x0C then
            escaped[#escaped + 1] = "\\f"
        elseif byte == 0x0D then
            escaped[#escaped + 1] = "\\r"
        elseif byte < 0x20 then
            escaped[#escaped + 1] = string.format("\\u%04x", byte)
        else
            escaped[#escaped + 1] = string.char(byte)
        end
    end
    escaped[#escaped + 1] = '"'
    return table.concat(escaped)
end

local function table_kind(value)
    if decoded_empty_arrays[value] and next(value) == nil then
        return "array", 0
    end

    local count = 0
    local largest = 0

    for key in next, value do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            return "object"
        end
        count = count + 1
        if key > largest then
            largest = key
        end
    end

    if count == 0 then
        return "object"
    end
    if largest ~= count then
        error("JSON arrays cannot be sparse", 3)
    end
    return "array", count
end

function json.encode(value)
    local stack = {}

    local function encode(current)
        if current == json.null then
            return "null"
        end

        local value_type = type(current)
        if value_type == "nil" then
            error("cannot encode nil as JSON; use json.null", 3)
        end
        if value_type == "boolean" then
            return current and "true" or "false"
        end
        if value_type == "number" then
            if not is_finite(current) then
                error("JSON numbers must be finite numbers", 3)
            end
            if current == 0 then
                return "0"
            end
            return (string.format("%.17g", current):gsub(",", "."))
        end
        if value_type == "string" then
            return encode_string(current)
        end
        if value_type ~= "table" then
            error("cannot encode " .. value_type .. " as JSON", 3)
        end
        if stack[current] then
            error("cannot encode cyclic table", 3)
        end

        stack[current] = true
        local kind, length = table_kind(current)
        local encoded
        if kind == "array" then
            local values = {}
            for index = 1, length do
                values[index] = encode(current[index])
            end
            encoded = "[" .. table.concat(values, ",") .. "]"
        else
            local keys = {}
            for key in next, current do
                if type(key) ~= "string" then
                    error("JSON object keys must be strings", 3)
                end
                keys[#keys + 1] = key
            end
            table.sort(keys)

            local members = {}
            for index, key in ipairs(keys) do
                members[index] = encode_string(key) .. ":" .. encode(current[key])
            end
            encoded = "{" .. table.concat(members, ",") .. "}"
        end
        stack[current] = nil
        return encoded
    end

    return encode(value)
end

return json
