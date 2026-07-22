local assertions = {}

local function render(value)
    if type(value) == "string" then
        return string.format("%q", value)
    end

    return tostring(value)
end

function assertions.equal(expected, actual)
    if expected ~= actual then
        error(string.format("expected %s, got %s", render(expected), render(actual)), 2)
    end
end

local function tables_equal(expected, actual, seen)
    if expected == actual then
        return true
    end

    if type(expected) ~= "table" or type(actual) ~= "table" then
        return false
    end

    if seen[expected] == actual then
        return true
    end
    seen[expected] = actual

    for key, expected_value in pairs(expected) do
        if not tables_equal(expected_value, actual[key], seen) then
            return false
        end
    end

    for key in pairs(actual) do
        if expected[key] == nil then
            return false
        end
    end

    return true
end

function assertions.deep_equal(expected, actual)
    if not tables_equal(expected, actual, {}) then
        error(string.format("expected deeply equal values, got %s and %s", render(expected), render(actual)), 2)
    end
end

function assertions.raises(pattern, fn)
    local ok, err = pcall(fn)
    if ok then
        error("expected an error, but none was raised", 2)
    end

    if not tostring(err):match(pattern) then
        error(string.format("expected error matching %q, got %s", pattern, tostring(err)), 2)
    end
end

return assertions
