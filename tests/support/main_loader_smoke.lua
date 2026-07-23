local mode = assert(arg[1], "loader smoke mode is required")

if mode == "unresolved-root" then
    package.path = "Scripts/?.lua"
    debug = nil
elseif mode == "debugless-search-path" then
    package.path = "CrossplayGuildChestExpander/Scripts/?.lua"
    debug = nil
elseif mode == "relative-source" then
    package.path = "CrossplayGuildChestExpander/Scripts/?.lua"
else
    error("unknown loader smoke mode")
end

local chunk = assert(loadfile("CrossplayGuildChestExpander/Scripts/main.lua"))
chunk()
chunk()
