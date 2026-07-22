# Task 5 Report — Discovery-safe state machine and read-only audit engine

## Scope

- Added an explicit discovery-only state graph with terminal execution epochs and no apply-capable node or edge.
- Added the generic `audit_blocked` outcome required for later report/persistence/read-back failures to fail closed without being mislabeled as audit conflicts.
- Added a strict read-only audit context with exactly three ports: `list_guilds`, `resolve_guild_chest`, and `snapshot_container`.
- Added deterministic guild projection, relationship validation, filtering, duplicate detection, detached Task 4 snapshot validation, canonical unsigned checksums, and non-table opaque audit handles.
- Added exported-surface and dynamic trap coverage proving the current discovery build exposes and accesses no write-capable adapter operation.
- Added no UE4SS integration, UObject write, container size change, dirty/replication request, game-thread callback, or Palworld symbol guess.

## TDD evidence

### Cycle 1 — Discovery state graph RED

Command:

```sh
./scripts/run-tests.sh tests/unit/state_machine_spec.lua
```

Exit status: `1`

Observed failure:

```text
FAIL tests/unit/state_machine_spec.lua
tests/unit/state_machine_spec.lua:2: module 'CrossplayGuildChestExpander.Scripts.state_machine' not found
```

The transition-table tests loaded before `state_machine.lua` existed.

### Cycle 1 — Discovery state graph GREEN

Command:

```sh
./scripts/run-tests.sh tests/unit/state_machine_spec.lua
```

Exit status: `0`

Result at the first green point: `11` state-machine tests passed. They covered direct/waiting paths, preflight and audit blockers, audit/apply-mode discovery outcomes, terminal epochs, invalid events/contexts, apply rejection from every state, strict constructor context, and unreachable mutating states.

### Additional dependency cycle — Generic audit blocker RED

Task 9 integration analysis established that post-audit validation, report persistence, and read-back failures need a generic blocker rather than the conflict-specific event.

Command:

```sh
./scripts/run-tests.sh tests/unit/state_machine_spec.lua
```

Exit status: `1`

Observed failure:

```text
FAIL blocks generic post-audit validation and persistence failures
tests/unit/state_machine_spec.lua:17: expected "BLOCKED", got "AUDIT"
```

### Additional dependency cycle — Generic audit blocker GREEN

Command:

```sh
./scripts/run-tests.sh tests/unit/state_machine_spec.lua
```

Exit status: `0`

Result: `12` state-machine tests passed after adding only `AUDIT + audit_blocked -> BLOCKED`. No mutation state or edge was added.

### Cycle 2 — Read-only audit RED

Command:

```sh
./scripts/run-tests.sh tests/integration/audit_spec.lua
```

Exit status: `1`

Observed failure:

```text
FAIL tests/integration/audit_spec.lua
tests/integration/audit_spec.lua:2: module 'CrossplayGuildChestExpander.Scripts.audit' not found
```

The audit contract tests loaded before `audit.lua` existed.

### Cycle 2 — Read-only audit GREEN

Command:

```sh
./scripts/run-tests.sh tests/integration/audit_spec.lua
```

Exit status: `0`

Result at the first green point: `14` audit tests passed. Coverage included all-guild sorted projection, exact filter semantics, duplicate IDs before filtering, owner mismatch, unresolved/non-guild references, uninitialized guilds, malformed projections, sanitized port failures, unknown/write-capable context rejection, write traps, `54 -> expand`, `358/400 -> noop`, deterministic unsigned checksums, and recursive read-only/detached views. The table proxy was later superseded by the opaque-handle review fix below.

### Cycle 3 — Discovery surface RED

Command:

```sh
./scripts/run-tests.sh tests/integration/discovery_surface_spec.lua
```

Exit status: `1`

Observed failure:

```text
FAIL does not let callers inject a state or replace transition behavior
tests/integration/discovery_surface_spec.lua:70: expected false, got true
```

The initial machine stored its current state in a caller-writable table field, so external code could inject an arbitrary state despite the transition table being safe.

### Cycle 3 — Discovery surface GREEN

Command:

```sh
./scripts/run-tests.sh tests/integration/discovery_surface_spec.lua
```

Exit status: `0`

Result at the first green point: `4` surface tests passed after moving state into a private weak-key store and making the returned machine proxy read-only. A later review found that `rawset` could still shadow an authority-relevant method; the non-table handle fix below closes that remaining path.

### Review fix 1 — Opaque state-machine handle RED

Command:

```sh
./scripts/run-tests.sh tests/unit/state_machine_spec.lua
```

Exit status: `1`

Observed failures included:

```text
FAIL takes the direct ready path to an audit-only completion
tests/unit/state_machine_spec.lua:34: expected "function", got "table"
FAIL takes the bounded waiting path and blocks readiness failures
tests/unit/state_machine_spec.lua:16: attempt to call a nil value (field 'transition')
```

The table handle could accept `rawset(handle, "transition", ...)`, and authority-relevant behavior was still reached through colon methods.

### Review fix 1 — Opaque state-machine handle GREEN

Command:

```sh
./scripts/run-tests.sh tests/unit/state_machine_spec.lua
```

Exit status: `0`

Result: `14` state-machine tests passed. `state_machine.new` now returns a unique function token; only `state_machine.state(handle)` and `state_machine.transition(handle, event, context)` consult the private weak-key store. `rawset`, method shadowing, forged handles, `nil`, and malformed handles fail closed.

### Review fix 2 — Opaque audit handle and deterministic context errors RED

Command:

```sh
./scripts/run-tests.sh tests/integration/audit_spec.lua
```

Exit status: `1`

Observed failures included:

```text
FAIL binds checksum to deterministic canonical unsigned data
tests/integration/audit_spec.lua:456: attempt to call a nil value (field 'checksum')
FAIL returns an opaque handle backed by cached canonical data
tests/integration/audit_spec.lua:477: expected "function", got "table"
FAIL uses deterministic fields for unknown context keys without address leakage
tests/integration/audit_spec.lua:524: expected "context", got "function: 0x..."
FAIL validates the exact scalar, filter, and read-port context
tests/integration/audit_spec.lua:549: expected false, got true
```

The audit proxy could be `rawset`-shadowed, non-string unknown keys leaked runtime addresses into `field`, and revision `0` was accepted.

### Review fix 2 — Opaque audit handle and deterministic context errors GREEN

Command:

```sh
./scripts/run-tests.sh tests/integration/audit_spec.lua
```

Exit status: `0`

Result: `16` audit tests passed. `audit.capture` now returns a unique function token, while `audit.to_table`, `audit.canonical_json`, and `audit.checksum` read only trusted captured storage. Direct field access, `rawset`, detached-copy mutation, forged handles, and `nil` handles cannot alter or impersonate an audit. Revision must be at least `1`; string unknown keys are sorted and non-string table/function/userdata keys use fixed field `context` without address leakage.

### Second re-review — Public accessor shadow split-brain RED

Command:

```sh
./scripts/run-tests.sh tests/integration/audit_spec.lua
```

Exit status: `1`

Observed failure:

```text
FAIL keeps saved accessors bound to trusted storage when public slots are shadowed
tests/integration/audit_spec.lua:544: expected "world/test", got "world/forged"
```

The saved original `audit.to_table` still dynamically called mutable public slot `audit.canonical_json`. Shadowing that slot made a real handle decode forged data and let a forged handle bypass the original `to_table` validation, while the saved original checksum accessor still returned trusted data.

### Second re-review — Public accessor shadow split-brain GREEN

Command:

```sh
./scripts/run-tests.sh tests/integration/audit_spec.lua
```

Exit status: `0`

Result: `17` audit tests passed. A private local `require_captured(handle)` now performs the only trusted lookup, and each exported accessor calls it directly. The regression shadows all three public module slots, invokes saved originals, restores every slot before assertions, and proves real data remains coherent while forged handles still raise `CGCE-AUD-CHECKSUM`.

## Final verification

Focused Task 5 unit test:

```sh
./scripts/run-tests.sh tests/unit/state_machine_spec.lua
```

Exit status: `0`; `14` tests passed.

Focused Task 5 integration tests:

```sh
./scripts/run-tests.sh tests/integration/audit_spec.lua tests/integration/discovery_surface_spec.lua
```

Exit status: `0`; `22` tests passed.

Repository default full suite:

```sh
./scripts/run-tests.sh
```

Exit status: `0`; `141` current unit and integration tests passed with `0` failures. This run included the Task 7 files concurrently present in the workspace; the immutable Task 5 focused evidence is `14` state-machine, `17` audit, and `5` discovery-surface tests.

Staged whitespace review before the implementation commit:

```sh
git diff --cached --check
```

Exit status: `0`.

## Self-review

- Re-read Task 5, PRD §§9–13, FR-003–007, FR-010, FR-013, FR-016–017, AT-004–006, AT-014, and the Discovery Build completion criteria against the changed files.
- The state graph contains only `DISABLED`, `PREFLIGHT`, `WAITING`, `AUDIT`, `AUDIT_COMPLETE`, `AWAITING_APPROVAL`, `BLOCKED`, and `UNSUPPORTED`; `apply` always returns `CGCE-STATE-MUTATION-BUILD-UNAVAILABLE` without changing state.
- State and audit authority are represented by non-table function tokens, so table field assignment, `rawset`, and colon-method shadowing are structurally unavailable. Forged tokens are absent from trusted weak-key stores and fail closed.
- `audit_blocked` is a fail-closed discovery transition for later non-conflict failures and does not confer apply authority.
- Audit context values and every guild/resolution/snapshot projection are strict and copied; port-owned containers, unknown fields, functions, and raw object references never enter the report.
- Duplicate configured container IDs and all relationship/snapshot blockers are evaluated for every discovered guild before action filtering, so exclusions cannot hide a blocker.
- Missing configured IDs do not call either downstream port and remain non-blocking `not_initialized` records.
- The resolver is called only with a configured guild chest ID. There is no API for enumerating general containers, and the general-container fixture remains untouched.
- Checksum input is canonical unsigned JSON with no timestamp; the signed canonical JSON and checksum are cached in trusted storage before returning the opaque handle. `to_table` decodes a fresh detached copy, while `checksum` never trusts a caller-owned table field.
- `canonical_json`, `checksum`, and `to_table` independently call private `require_captured`; no authority-bearing accessor dispatches through another mutable public module slot.
- Invalid context reporting is deterministic: sorted string unknowns identify the first stable field, while any non-string key reports fixed field `context` and never stringifies an address-bearing value.
- Underlying port exceptions and unknown context values are never copied into structured errors, reports, or canonical JSON.
- No implementation line guesses a Palworld class, property, function, or revision-specific symbol.

## Commits

- `4708257` — `feat: add read-only discovery audit`
- `657a035` — `fix: make discovery handles opaque`
- `59fc33d` — `fix: bind audit accessors to trusted storage`

## Concerns and deferred evidence

- Guild, resolved-container, and snapshot projections are synthetic contracts only. Exact Palworld traversal and field evidence remain Gate A discovery work and cannot be inferred from these tests.
- This task proves audit safety and identity relationships but cannot prove that a resolved runtime container is the actual normal guild chest without the real read-only adapter and Gate A evidence.
- The surface test enumerates all production modules present through Task 5. Later discovery-only tasks must extend the list when adding production modules through Task 10.
- No generalized LLM Wiki capture was warranted; this work implements project-specific safety contracts already captured in the PRD and implementation plan.
