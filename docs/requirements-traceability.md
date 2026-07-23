# CGCE requirements traceability

Snapshot date: 2026-07-23. This matrix describes repository evidence at the
Discovery milestone. `VERIFIED_STATIC` means a local deterministic contract is
covered by tests; it is not Palworld runtime or client compatibility evidence.
Every `BLOCKED_GATE_A` or `BLOCKED_GATE_B` row requires primary private evidence
before its product claim can pass.

## Functional requirements

| ID | Status | Implementation or contract | Evidence / remaining gate |
|---|---|---|---|
| FR-001 | BLOCKED_GATE_A | `revision_guard.lua`; exact injected revision reader | Unit coverage exists; authoritative Windows revision evidence is absent. |
| FR-002 | BLOCKED_GATE_A | `binding_manifest.lua`, `gate_a_evidence.lua` | Exact type checks are synthetic; real manifest is absent. |
| FR-003 | BLOCKED_GATE_A | `guild_repository.lua`, `container_resolver.lua`, `audit.lua` | Read-only tests pass; real world scan is absent. |
| FR-004 | BLOCKED_GATE_A | `guild_repository.lua`, `container_resolver.lua` | Duplicate synthetic cases covered; real ownership inventory is absent. |
| FR-005 | BLOCKED_GATE_A | `container_resolver.lua`, Gate A ownership attestation | Synthetic mismatch covered; multi-guild real proof is absent. |
| FR-006 | VERIFIED_STATIC | `config.default.json`, `config.lua`, `state_machine.lua` | Default audit/non-mutation contract covered by config and state tests. |
| FR-007 | VERIFIED_STATIC | `approval.lua`, `command_router.lua`, discovery-only state machine | Missing approval cannot expose apply; no mutation implementation exists. |
| FR-010 | BLOCKED_GATE_A | Future Task 12 mutation guard/resizer | No resize module exists. |
| FR-011 | BLOCKED_GATE_A | Future verified resize path and invariant validator | No append/resize implementation exists. |
| FR-012 | VERIFIED_STATIC | `config.lua`, `certification.lua` | Certified-slot policy is covered synthetically; real candidates remain unapproved. |
| FR-013 | BLOCKED_GATE_A | `audit.lua`; future migration engine | Audit completeness is synthetic; apply does not exist. |
| FR-014 | BLOCKED_GATE_A | `snapshot.lua`, `fingerprint.lua`, `validator.lua` | Read-only invariants exist; post-mutation proof is impossible yet. |
| FR-015 | BLOCKED_GATE_A | Future migration ledger and mutation engine | Ledger codec exists but no real repeated apply is possible. |
| FR-016 | BLOCKED_GATE_A | `container_resolver.lua`; Gate A ownership exclusion | Synthetic exclusion exists; real non-guild inventory proof is absent. |
| FR-017 | VERIFIED_STATIC | `config.lua`, `audit.lua` | Include/exclude validation and filtering have unit/integration coverage. |
| FR-020 | BLOCKED_GATE_A | `world_ready.lua`; future new-guild mutation hook | Observer is read-only and mutation path absent. |
| FR-021 | BLOCKED_GATE_A | Future Task 12 shared migration engine | No migration engine exists. |
| FR-022 | BLOCKED_GATE_A | Future Task 12 invariant-guarded migration | No mutation path exists. |
| FR-023 | BLOCKED_GATE_A | `scheduler.lua`, `world_ready.lua` read-only scheduling | Synthetic scheduler exists; real new-guild fallback/apply is absent. |
| FR-030 | BLOCKED_GATE_B | Server-only package contract | No vanilla Steam Windows/PS5/macOS connection evidence exists. |
| FR-031 | VERIFIED_STATIC | `Info.json`, archive allow-list, package verifier | Package tests prove no client script, custom UI, input, PAK, or DLL. |
| FR-032 | BLOCKED_GATE_B | Future certification artifact | Cross-client state equality has not run. |
| FR-033 | BLOCKED_GATE_B | PS5 certification runbook | DualSense last-slot evidence is absent. |
| FR-034 | BLOCKED_GATE_B | Future concurrency certification | Cross-platform concurrent access has not run. |
| FR-035 | BLOCKED_GATE_B | Release builder hard block | Release cannot build; three-client certification is absent. |
| FR-036 | BLOCKED_GATE_B | `platform_preflight.lua` | Parser is covered synthetically; real PS5 external discovery is absent. |
| FR-037 | BLOCKED_GATE_B | `certification.lua` common-prefix policy | No 120/256/358 three-client result exists. |
| FR-038 | VERIFIED_STATIC | `constants.lua`, `config.default.json`, certification policy | Xbox is optional and cannot replace a required client. |

## Product acceptance tests

All product AT rows remain blocked even where a synthetic lower-level test
exists; no row below is a claim about a real Palworld server or client.

| ID | Status | Implementation or contract | Evidence / remaining gate |
|---|---|---|---|
| AT-001 | BLOCKED_GATE_B | Future approved resize and three-client verification | 54-slot real migration not run. |
| AT-002 | BLOCKED_GATE_B | Ledger/idempotency design | Three real restarts after apply not run. |
| AT-003 | BLOCKED_GATE_B | Read-only world/new-guild observer | New-guild mutation not implemented or certified. |
| AT-004 | BLOCKED_GATE_A | Resolver ownership exclusion | Real general-container before/after proof absent. |
| AT-005 | BLOCKED_GATE_A | Fail-closed revision guard | Unsupported real revision zero-mutation capture absent. |
| AT-006 | BLOCKED_GATE_A | Resolver and audit blockers | Real owner-mismatch report absent. |
| AT-007 | BLOCKED_GATE_A | Fingerprint/validator and fatal Gate A proof | Post-mutation fatal path not implemented. |
| AT-008 | BLOCKED_GATE_B | Steam client checklist | Vanilla Steam result absent. |
| AT-009 | BLOCKED_GATE_B | PS5 Community Server and DualSense checklist | External PS5 result absent. |
| AT-010 | BLOCKED_GATE_B | PS5 restart/reconnect checklist | Evidence absent. |
| AT-011 | BLOCKED_GATE_B | Steam Windows comparison checklist | Evidence absent. |
| AT-012 | BLOCKED_GATE_B | Three-client concurrency checklist | Evidence absent. |
| AT-013 | BLOCKED_GATE_B | Removal protocol | Vanilla removal result absent. |
| AT-014 | BLOCKED_GATE_A | Approval/state-machine synthetic tests | Real approved build does not exist. |
| AT-015 | BLOCKED_GATE_B | Preflight diagnostics | Synthetic coverage exists; PS5 external setup evidence absent. |
| AT-016 | BLOCKED_GATE_B | Common certified-prefix policy | PS5 candidate progression not run. |
| AT-017 | BLOCKED_GATE_B | Mac is a required client in constants/config | macOS candidate progression not run. |

## Definition of Done

| ID | Status | DoD condition | Evidence / remaining gate |
|---|---|---|---|
| DOD-01 | BLOCKED_GATE_A | Official loader installs on Windows Dedicated Server | Real installation absent. |
| DOD-02 | VERIFIED_STATIC | Sole server-only Lua InstallRule | `package_spec.lua`, `verify-package.sh`. |
| DOD-03 | BLOCKED_GATE_A | Exact non-zero `MinRevision` | Discovery deliberately uses zero; release hard-blocked. |
| DOD-04 | BLOCKED_GATE_A | UE4SS dependency installation check | Metadata declares UE4SS; real loader check absent. |
| DOD-05 | BLOCKED_GATE_A | Zero mutation on unsupported revision | No mutation source exists; real unsupported-revision run absent. |
| DOD-06 | VERIFIED_STATIC | Audit is default | Config and config tests. |
| DOD-07 | BLOCKED_GATE_A | No apply without approval | Synthetic contract exists; approved mutation build absent. |
| DOD-08 | BLOCKED_GATE_B | Existing 54-slot chest expands | Not implemented or run. |
| DOD-09 | BLOCKED_GATE_B | New guild chest auto-expands | Not implemented or run. |
| DOD-10 | BLOCKED_GATE_B | Expanded chest is no-op | Not implemented or run. |
| DOD-11 | BLOCKED_GATE_B | Chest above 358 never shrinks | No mutation engine; real proof absent. |
| DOD-12 | BLOCKED_GATE_B | GUID, quantity, index, metadata preserved | Real before/after/reload proof absent. |
| DOD-13 | BLOCKED_GATE_A | General chests unchanged | Synthetic resolver only; real inventory proof absent. |
| DOD-14 | BLOCKED_GATE_A | Duplicate and owner mismatch blocked | Synthetic coverage only. |
| DOD-15 | BLOCKED_GATE_B | Save/restart persistence | Not run. |
| DOD-16 | BLOCKED_GATE_B | Removal smoke test | Not run. |
| DOD-17 | BLOCKED_GATE_B | Steam client certification | Not run. |
| DOD-18 | BLOCKED_GATE_B | PS5 Community Server search/join | Not run. |
| DOD-19 | BLOCKED_GATE_B | Vanilla PS5 certification | Not run. |
| DOD-20 | BLOCKED_GATE_B | Vanilla Steam Windows certification | Not run. |
| DOD-21 | BLOCKED_GATE_B | Vanilla macOS certification | Not run. |
| DOD-22 | BLOCKED_GATE_B | PS5 DualSense last-slot access | Not run. |
| DOD-23 | VERIFIED_STATIC | Xbox advertised only when certified | Xbox remains optional and unadvertised. |
| DOD-24 | BLOCKED_GATE_B | Cross-platform concurrent access | Not run. |
| DOD-25 | BLOCKED_GATE_B | Six-hour soak | Not run. |
| DOD-26 | BLOCKED_GATE_B | Performance thresholds | Not run. |
| DOD-27 | BLOCKED_GATE_A | Migration ledger and structured report | Codecs/reports are synthetic; production loader blocked. |
| DOD-28 | VERIFIED_STATIC | Backup/install/update/removal/restore docs | README and certification runbook provide procedures. |
| DOD-29 | VERIFIED_STATIC | Public package excludes client/UI/original assets | Static verifier and deterministic archive test. |
| DOD-30 | BLOCKED_GATE_B | Release notes list three-client matrix and runtime identity | No release/certification exists. |

## PRD section 32 spike artifacts

Items 1–16 belong to read-only Gate A (Task 11B). Task 11A's preliminary
object/header inventory is non-authoritative and does not satisfy a spike row.
Items 17–20 belong to Gate B and release certification. The validator's
synthetic tests do not satisfy any real spike row.

| ID | Status | Required artifact | Evidence / remaining gate |
|---|---|---|---|
| SPIKE-01 | BLOCKED_GATE_A | Current revision number | Authoritative Windows source absent. |
| SPIKE-02 | BLOCKED_GATE_A | Guild manager actual class | Real full-name/signature absent. |
| SPIKE-03 | BLOCKED_GATE_A | Guild list access path | Real path absent. |
| SPIKE-04 | BLOCKED_GATE_A | Guild ID property | Real property/type absent. |
| SPIKE-05 | BLOCKED_GATE_A | Guild chest Container ID property | Real property/type absent. |
| SPIKE-06 | BLOCKED_GATE_A | Item Container manager class | Real class absent. |
| SPIKE-07 | BLOCKED_GATE_A | Container lookup function | Real exact signature absent. |
| SPIKE-08 | BLOCKED_GATE_A | Slot array property | Real property/type absent. |
| SPIKE-09 | BLOCKED_GATE_A | Empty slot object type | Real struct/type absent. |
| SPIKE-10 | BLOCKED_GATE_A | Safe resize or append function | Real behavior/signature proof absent. |
| SPIKE-11 | BLOCKED_GATE_A | Dirty function | Real signature absent. |
| SPIKE-12 | BLOCKED_GATE_A | Replication request function | Real signature absent. |
| SPIKE-13 | BLOCKED_GATE_A | World-ready hook | Real callback contract absent. |
| SPIKE-14 | BLOCKED_GATE_A | New-guild hook | Real callback contract absent. |
| SPIKE-15 | BLOCKED_GATE_A | Container-in-use method | Real method absent. |
| SPIKE-16 | BLOCKED_GATE_A | Canonical 54-slot before snapshot | Same-run real snapshot absent. |
| SPIKE-17 | BLOCKED_GATE_B | 358-slot after snapshot | Mutation not implemented/certified. |
| SPIKE-18 | BLOCKED_GATE_B | Steam Windows UI result | Not run. |
| SPIKE-19 | BLOCKED_GATE_B | PS5 UI/DualSense last-slot result | Not run. |
| SPIKE-20 | BLOCKED_GATE_B | Removal behavior on Steam Windows/PS5/macOS | Not run. |

## Release conclusion

The repository can produce only a deterministic, mutation-incapable Discovery
archive. Release remains `BLOCKED_GATE_A` and `BLOCKED_GATE_B`; no compatibility
label is authorized.
