# Task 3 Report — Configuration and revision binding validation

## Files

| Path | Purpose |
|---|---|
| `CrossplayGuildChestExpander/config/config.default.json` | Safe 21-key audit-first Discovery Build default. |
| `CrossplayGuildChestExpander/Scripts/constants.lua` | Contract versions, fixed profile/client sets, slot candidates, and absent Discovery Build certification pin. |
| `CrossplayGuildChestExpander/Scripts/config.lua` | Strict non-coercing config parser and structured `CGCE-CFG-*` failures. |
| `CrossplayGuildChestExpander/Scripts/binding_manifest.lua` | Checksummed discovery/runtime manifest parser and read-only exact reflection verification. |
| `CrossplayGuildChestExpander/Scripts/certification.lua` | Checksum-pinned release certification verification and per-slot client evidence validation. |
| `CrossplayGuildChestExpander/Scripts/bindings/README.md` | Binding-manifest provenance, checksum, and read-only adapter contract. |
| `tests/unit/config_spec.lua` | Config/default/authority-boundary contract tests. |
| `tests/unit/binding_manifest_spec.lua` | Manifest schema, checksum, revision, descriptor, and read-only adapter tests. |
| `tests/unit/certification_spec.lua` | Artifact pin/binding/client/evidence/slot authorization tests. |

## TDD evidence

### Config RED

Command:

```sh
./scripts/run-tests.sh tests/unit/config_spec.lua
```

Exit status: `1`

Observed failure:

```text
FAIL tests/unit/config_spec.lua
tests/unit/config_spec.lua:2: module 'CrossplayGuildChestExpander.Scripts.config' not found
```

The test loaded before any config production module existed and failed for the intended missing-feature reason.

### Config GREEN

Command:

```sh
./scripts/run-tests.sh tests/unit/config_spec.lua
```

Exit status: `0`

Final result: `11` config contract tests passed, covering the exact default, constants, exact keys, JSON shape, fixed profile/client order, optional Xbox subset, opaque guild IDs, disjoint filters, rescan minimum, expand-only, candidate/local restrictions, deferred certification mode, approval presence, and token-safe diagnostics.

### Binding manifest RED

Command:

```sh
./scripts/run-tests.sh tests/unit/binding_manifest_spec.lua
```

Exit status: `1`

Observed failure:

```text
FAIL tests/unit/binding_manifest_spec.lua
tests/unit/binding_manifest_spec.lua:2: module 'CrossplayGuildChestExpander.Scripts.binding_manifest' not found
```

### Binding manifest GREEN

Command:

```sh
./scripts/run-tests.sh tests/unit/binding_manifest_spec.lua
```

Exit status: `0`

Final result: `10` manifest tests passed. Runtime verification inspected all `16` logical descriptors through `read_revision` and `inspect_descriptor`; the fake candidate `invoke` method remained at `0` calls.

### Certification RED

Command:

```sh
./scripts/run-tests.sh tests/unit/certification_spec.lua
```

Exit status: `1`

Observed failure:

```text
FAIL tests/unit/certification_spec.lua
tests/unit/certification_spec.lua:2: module 'CrossplayGuildChestExpander.Scripts.certification' not found
```

### Certification GREEN

Command:

```sh
./scripts/run-tests.sh tests/unit/certification_spec.lua
```

Exit status: `0`

Final result: `10` certification tests passed, covering exact revision/profile and checksum bindings, canonical clients, all-true common evidence, PS5 Community Server/DualSense evidence, release pinning, self-checksum drift, config-only escalation rejection, and `MinRevision` rejection.

### Review regression RED/GREEN — empty object versus array

RED command:

```sh
./scripts/run-tests.sh tests/unit/config_spec.lua tests/unit/binding_manifest_spec.lua
```

Exit status: `1`

Observed failures:

```text
FAIL requires an object root and preserves object-versus-array types
expected "CGCE-CFG-TYPE", got "CGCE-CFG-MISSING-KEY"
FAIL rejects discovery symbols and runtime-only fields
expected false, got true
```

The implementation was then changed to preserve the JSON codec's decoded `[]`/`{}` distinction at every empty array/object boundary.

GREEN command:

```sh
./scripts/run-tests.sh tests/unit/config_spec.lua tests/unit/binding_manifest_spec.lua tests/unit/certification_spec.lua
```

Exit status: `0`; all `31` Task 3 tests passed.

### Review regression RED/GREEN — complete certification evidence schema

RED command:

```sh
./scripts/run-tests.sh tests/unit/certification_spec.lua
```

Exit status: `1`

Observed failure:

```text
FAIL requires exactly one all-true evidence record for every required client
expected false, got true
```

The failing case omitted a required common evidence field. The implementation now requires exactly `ui_access`, `last_slot_access`, `restart_reconnect`, and `cross_platform_consistency` for every required client, plus `community_server_list` and `dualsense_last_slot` for PS5, with every value exactly `true`.

GREEN command:

```sh
./scripts/run-tests.sh tests/unit/certification_spec.lua
```

Exit status: `0`; all `10` certification tests passed.

## Final verification

Commands:

```sh
git diff --cached --check
third_party/lua-5.4.8/src/luac -p CrossplayGuildChestExpander/Scripts/constants.lua CrossplayGuildChestExpander/Scripts/config.lua CrossplayGuildChestExpander/Scripts/binding_manifest.lua CrossplayGuildChestExpander/Scripts/certification.lua tests/unit/config_spec.lua tests/unit/binding_manifest_spec.lua tests/unit/certification_spec.lua
./scripts/run-tests.sh
```

Exit status: `0` for every command. The fresh full suite reported `56` passing tests and no failures or warnings.

A production-only static scan found no definition or call of `resize`, `append`, `mark_dirty`, or `replicate`. `binding_manifest.lua` references only the injected read-only adapter methods `read_revision` and `inspect_descriptor`; the forbidden `invoke` method exists only in the test fake and its call count is asserted as zero.

## Self-review

- Configuration accepts exactly the 21 PRD keys, requires every key, preserves JSON value types, and returns only the decoded validated values. It adds no authorization fields.
- `certification_mode=true` permits parsing a candidate target for a future isolated test-world flow but confers no mutation or production authority. That authorization remains deferred to post-Gate-A Task 12.
- Local `certified_target_slots` cannot authorize release slots. `certification.verify` returns only slots present in a build-pinned, self-checksummed artifact with exact required evidence.
- Discovery manifests require an empty object for `symbols`, reject runtime-only fields, carry no mutation-capability field, and treat `tested_platform_matrix` as non-authoritative metadata.
- Runtime manifests require the source audit checksum and all 16 exact logical descriptors. Descriptor kinds and keys are strict, and live reflection verification is exact/read-only.
- Manifest and certification checksums are SHA-256 over canonical JSON without the top-level `checksum`; certification additionally requires equality with the release-build pin. No signature mechanism was added.
- Exact revision equality is enforced; `MinRevision` is rejected as an unknown authorization field.
- All failures produced by the Task 3 validators are structured tables with stable namespace-prefixed codes, fields, and non-secret details. Approval token contents are not placed in diagnostics.
- The changed diff was reread against the Task 3 brief and PRD §§11, 13.1, 14, 23, and 24.3. No mutation-capable module, UObject access, network access, runtime manifest, certification artifact, or release pin was added.

## Commits

- `92e4865` — `feat: add config and revision trust validation`

## Concerns

- Discovery Build intentionally has no release certification checksum and therefore cannot produce production slot authorization.
- No real runtime manifest or certification artifact is included. Exact Palworld symbols must come from the later read-only Discovery Build/Gate A workflow, and platform evidence must come from the later Gate B certification workflow.
- Downstream production authorization must intersect the parsed local config targets with `certification.verify` output; this Task 3 parser deliberately does not create that mutation authorization.
- No new generalizable LLM Wiki capture was made: the reusable canonical-JSON/checksum trust-boundary principles were already part of the supplied repository plan, and this change only implements the project-specific contract.
