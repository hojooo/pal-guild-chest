local fake_filesystem = {}

local REQUIRED_CAPABILITIES = {
    no_follow = true,
    atomic_replace = true,
    durable_flush = true,
}

local function normalize(path)
    return (path:gsub("/", "\\"))
end

local function fold(path)
    return string.lower(normalize(path))
end

local function copy_table(value)
    local copy = {}
    for key, item in pairs(value) do
        copy[key] = item
    end
    return copy
end

function fake_filesystem.new(options)
    options = options or {}

    local configured_capabilities = options.capabilities or REQUIRED_CAPABILITIES
    local entries = {}
    for path, descriptor in pairs(options.entries or {}) do
        local node
        if type(descriptor) == "string" then
            node = { kind = descriptor }
        else
            node = copy_table(descriptor)
        end
        node.canonical_path = normalize(node.canonical_path or path)
        node.reparse_point = node.reparse_point == true
        entries[fold(path)] = node
    end

    local canonical_overrides = {}
    for path, canonical in pairs(options.canonical_overrides or {}) do
        canonical_overrides[fold(path)] = normalize(canonical)
    end

    local observations = {
        capabilities = 0,
        canonicalize = {},
        inspect_no_follow = {},
        propose_temp_sibling = {},
        writes = 0,
    }

    local fs = {}

    function fs.capabilities()
        observations.capabilities = observations.capabilities + 1
        return copy_table(configured_capabilities)
    end

    function fs.canonicalize(path)
        local normalized = normalize(path)
        observations.canonicalize[#observations.canonicalize + 1] = normalized
        local override = canonical_overrides[fold(normalized)]
        if override ~= nil then
            return override
        end
        local node = entries[fold(normalized)]
        if node ~= nil then
            return node.canonical_path
        end
        return normalized
    end

    function fs.inspect_no_follow(path)
        local normalized = normalize(path)
        observations.inspect_no_follow[#observations.inspect_no_follow + 1] = normalized
        local node = entries[fold(normalized)]
        if node == nil then
            return { kind = "missing", reparse_point = false }
        end
        return {
            kind = node.kind,
            reparse_point = node.reparse_point,
        }
    end

    function fs.propose_temp_sibling(target)
        observations.propose_temp_sibling[#observations.propose_temp_sibling + 1] = target
        if type(options.temp_sibling) == "function" then
            return options.temp_sibling(target)
        end
        return options.temp_sibling or (target .. ".cgce.tmp")
    end

    return fs, observations
end

return fake_filesystem
