local constants = {
    versions = {
        config = "1.1",
        manifest = "1.0",
        certification = "1.0",
    },
    deployment_profile = "windows-dedicated-ps5-macos-required",
    required_clients = { "SteamWindows", "PS5", "Mac" },
    optional_clients = { "Xbox" },
    target_slot_candidates = { 54, 120, 256, 358 },
    release_certification_checksum = nil,
}

return constants
