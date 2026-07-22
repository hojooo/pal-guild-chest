# Binding manifests

Binding manifests map fixed logical names to exact Palworld reflection paths and type signatures. They are revision-specific package data and are never downloaded or inferred at runtime.

A `discovery` manifest contains an empty `symbols` object and cannot confer mutation capability. A `runtime` manifest is created only from reviewed read-only discovery evidence, binds its source audit checksum, and contains all required descriptors. Both kinds carry a canonical JSON SHA-256 self-checksum computed after removing the top-level `checksum` field.

Runtime verification uses only `read_revision()` and `inspect_descriptor(logical_name, descriptor)` on an injected adapter. It requires exact live revision and descriptor equality; it never invokes a discovered function candidate. `tested_platform_matrix` is informational metadata only. Release slot authorization comes exclusively from a separately pinned certification artifact.
