# Task 6A Report — Approval tokens and safe log formatting

## Scope

This bounded subtask implements only the pure approval and logger modules from Task 6. It does not implement reports, ledgers, persistence, path containment, conflict detection, authorization, mutation, or I/O.

| Path | Purpose |
|---|---|
| `CrossplayGuildChestExpander/Scripts/approval.lua` | Strict checksum-bound operator token generation and verification. |
| `CrossplayGuildChestExpander/Scripts/logger.lua` | Pure one-line text and JSONL formatting with recursive redaction and a fixed byte bound. |
| `tests/unit/approval_spec.lua` | Canonical vector, exact binding, validation, malformed-candidate, and mutable-slot isolation tests. |
| `tests/unit/logger_spec.lua` | Schema, level, redaction, JSON safety, control escaping, size, per-slot, no-I/O, and mutable-slot isolation tests. |

## Approval TDD

### RED

Command:

```sh
./scripts/run-tests.sh tests/unit/approval_spec.lua
```

Exit status: `1`. The approval contract could not load because `CrossplayGuildChestExpander.Scripts.approval` did not exist. No production approval code had been created.

### GREEN

Command:

```sh
./scripts/run-tests.sh tests/unit/approval_spec.lua
```

Exit status: `0`; all `5` approval tests passed.

The canonical preimage is direct concatenation with no implicit delimiter:

```text
LP(s) = decimal UTF-8 byte length + ":" + s

LP("cgce.operator-approval.v1")
+ LP("world_id") + LP(world_id)
+ LP("game_revision") + LP(canonical_decimal_revision)
+ LP("audit_checksum") + LP(audit_checksum)
+ LP("requested_target_slots") + LP(canonical_decimal_target)
+ LP("deployment_profile") + LP(deployment_profile)
```

For `world/alpha`, revision `12345`, `64 × "a"`, target `358`, and profile `windows-dedicated-ps5-macos-required`, pure-Lua SHA-256 returns:

```text
36a4cf7f20cb58e92ba1072b95a4b9c9986cd6f746ac580d77a44199e1b9ab76
```

The vector was independently reproduced by constructing the same byte preimage outside Lua and piping it to `openssl dgst -sha256`; OpenSSL returned the identical lowercase digest.

Approval fields are an exact five-key allow-list. World ID is a non-empty valid UTF-8 string; revision is a positive Lua integer; audit checksum is exactly 64 lowercase hexadecimal characters; target is one of `54,120,256,358`; deployment profile is fixed. Unknown and missing fields fail with structured non-secret `CGCE-APP-*` errors. Verification returns `false` for malformed tokens or fields. Every well-shaped candidate comparison scans all `64` bytes and accumulates XOR differences before deciding.

## Logger TDD

### RED

Command:

```sh
./scripts/run-tests.sh tests/unit/logger_spec.lua
```

Exit status: `1`. The logger contract could not load because `CrossplayGuildChestExpander.Scripts.logger` did not exist. No production logger code had been created.

### GREEN

Command:

```sh
./scripts/run-tests.sh tests/unit/logger_spec.lua
```

Exit status: `0`; all `7` logger tests passed.

The formatter requires non-empty UTF-8 `timestamp` and `event` strings plus exactly one of `DEBUG`, `INFO`, `WARNING`, `BLOCKING`, or `CRITICAL`. It recursively copies accepted data, rejects invalid UTF-8, non-finite numbers, cycles, metatables, sparse/mixed arrays, and non-JSON values, and preserves explicit empty arrays.

Credential keys are normalized to lowercase ASCII alphanumerics before conservative substring matching. Password, token, secret, credential, authorization, API-key, and private-key variants are replaced with `[REDACTED]` at any depth without modifying the input. Both formats JSON-escape strings and keys, contain exactly one trailing physical newline, and contain no embedded CR/LF bytes.

The fixed maximum is `16 * 1024 = 16384` bytes including the final newline. A line at exactly the limit is preserved. An oversized event becomes a small complete `log_event_oversize` record carrying only safe metadata and the original encoded byte count; JSON is never truncated. `slot_index`, slot fingerprint, and equivalent per-slot details fail at INFO-or-higher and are accepted only at DEBUG. Aggregate slot counts remain valid INFO data.

## Verification

Commands:

```sh
./scripts/run-tests.sh tests/unit/approval_spec.lua tests/unit/logger_spec.lua
./scripts/run-tests.sh
third_party/lua-5.4.8/src/luac -p CrossplayGuildChestExpander/Scripts/approval.lua CrossplayGuildChestExpander/Scripts/logger.lua tests/unit/approval_spec.lua tests/unit/logger_spec.lua
git diff --check -- CrossplayGuildChestExpander/Scripts/approval.lua CrossplayGuildChestExpander/Scripts/logger.lua tests/unit/approval_spec.lua tests/unit/logger_spec.lua
rg -n '\b(resize|append|mark_dirty|replicate|apply|ExecuteInGameThread|RegisterHook|io\.|os\.|require_operator_approval)\b' CrossplayGuildChestExpander/Scripts/approval.lua CrossplayGuildChestExpander/Scripts/logger.lua
```

Focused verification reported `12` passes. At this verification point, after the concurrently developed Task 7 files were committed, the current default unit-plus-integration suite reported `161` passes and zero failures. Lua parsing and diff whitespace checks exited `0`. The production-only forbidden-surface scan returned no matches.

## Self-review

- Approval hashes Task 5's canonical `audit_checksum` directly. It does not accept a timestamp wrapper, operational report checksum, `require_operator_approval`, or a caller-selected profile.
- `verify` calls private validation/token functions and a module-initialization-captured SHA-256 function. Replacing `approval.token` or the SHA module's public slot later cannot forge verification.
- Candidate values are never included in errors or logs. Malformed candidates return only `false`.
- Logger formatting is pure and has no filesystem, console, clock, network, UE4SS, or mutation dependency.
- Logger captures JSON helpers at module initialization and both public formatters call private sanitization/encoding functions. Replacing sibling public slots later cannot bypass redaction.
- Recursive input copies, canonical JSON encoding, control escaping, and oversize replacement were checked in both behavior tests and source review.
- No UObject write, resize, append, dirty, replication, apply transition, hook registration, or game-thread operation was introduced.
- The final diff was reread against PRD §§14, 20, 21, and 23 plus the Task 6 brief. Task 6B persistence/report/ledger/path/conflict responsibilities remain deliberately absent.

## Commits

- `72c11c1` — `feat: add approval and safe log formatting`

## Concerns

- Approval verification is a trust-boundary primitive, not mutation authority. Later tasks must still require fresh audit/report persistence, Gate A acceptance, exact manifest binding, fatal safety, and platform certification.
- Logger returns strings only. Safe durable persistence and path containment belong to the remaining Task 6 work.
- No project-global LLM Wiki capture was created in this subtask; the parent implementation session can decide whether to generalize the length-prefixed approval-preimage and immutable dependency-capture patterns during final knowledge triage.
