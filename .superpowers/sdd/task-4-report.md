# Task 4 Report — Snapshots, fingerprints, and invariants

## Scope

- Added `json.array(values?)` for explicitly constructed JSON arrays while preserving decoded empty arrays.
- Added canonical SHA-256 item fingerprints over occupied, index-bearing slot records.
- Added fail-closed, detached container snapshots through the exact four-method read-only adapter contract.
- Added a pure invariant comparator with derived no-op counts and deterministic structured violations.
- Added a synthetic read-only adapter and focused unit coverage.
- Added no UObject mutation, resize/append, dirty/replication, selection routing, or fatal-stop capability.

## TDD evidence

### Cycle 1 — JSON array constructor RED

Command:

```sh
./scripts/run-tests.sh tests/unit/json_spec.lua
```

Exit status: `1`

Observed failure:

```text
FAIL constructs empty and populated arrays for deterministic encoding
tests/unit/json_spec.lua:127: attempt to call a nil value (field 'array')
```

The focused test failed because `json.array` did not exist. All pre-existing JSON tests and the decoded-array compatibility test passed.

### Cycle 1 — JSON array constructor GREEN

Command:

```sh
./scripts/run-tests.sh tests/unit/json_spec.lua
```

Exit status: `0`

Result: `20` JSON tests passed, including constructed empty/populated arrays and unchanged decoded-empty-array encoding.

### Cycle 2 — Snapshot and fingerprint RED

Command:

```sh
./scripts/run-tests.sh tests/unit/snapshot_spec.lua
```

Exit status: `1`

Observed failure:

```text
FAIL tests/unit/snapshot_spec.lua
tests/unit/snapshot_spec.lua:5: module 'CrossplayGuildChestExpander.Scripts.snapshot' not found
```

The snapshot contract tests loaded before `snapshot.lua` or `fingerprint.lua` existed.

### Cycle 2 — Snapshot and fingerprint GREEN

Command:

```sh
./scripts/run-tests.sh tests/unit/snapshot_spec.lua
```

Exit status: `0`

Result: `9` snapshot tests passed. Coverage includes engine-order slot records, all preservation fields, canonical insertion-order-independent hashing, index sensitivity, trailing-empty insensitivity, detached copies, every missing/failing adapter method, malformed IDs/slot arrays, and missing/malformed/unknown occupied-item projections.

### Cycle 3 — Validator RED

Command:

```sh
./scripts/run-tests.sh tests/unit/validator_spec.lua
```

Exit status: `1`

Observed failure:

```text
FAIL tests/unit/validator_spec.lua
tests/unit/validator_spec.lua:4: module 'CrossplayGuildChestExpander.Scripts.validator' not found
```

The invariant contract tests loaded before `validator.lua` existed.

### Cycle 3 — Validator GREEN

Command:

```sh
./scripts/run-tests.sh tests/unit/validator_spec.lua
```

Exit status: `0`

Result: `10` validator tests passed. Coverage includes append-only empty expansion, valid `358→358` and `400→400` no-ops, undershoot/overshoot/shrink rejection, container/owner identity, every occupied preservation field, stored index changes, empty↔occupied transitions, item swaps, every appended non-empty slot, and deterministic multi-fault ordering across `CGCE-VAL-001` through `CGCE-VAL-008`.

### Independent review fix — total quantity overflow RED

Command:

```sh
./scripts/run-tests.sh tests/unit/snapshot_spec.lua
```

Exit status: `1`

Observed failure:

```text
FAIL fails closed when total item quantity exceeds the Lua integer range
tests/unit/snapshot_spec.lua:9: expected false, got true
```

Two otherwise-valid occupied projections with quantities `math.maxinteger` and `1` returned normally because Lua 5.4 integer addition wrapped to `math.mininteger`.

### Independent review fix — total quantity overflow GREEN

Command:

```sh
./scripts/run-tests.sh tests/unit/snapshot_spec.lua
```

Exit status: `0`

Result: `10` snapshot tests passed. Snapshot aggregation now checks the remaining signed-integer capacity before addition and fails with exactly `{code="CGCE-SNAP-QUANTITY-OVERFLOW", field="total_item_quantity", detail="total item quantity exceeds Lua integer range"}`.

## Final verification

Command:

```sh
./scripts/run-tests.sh
```

Exit status: `0`

Result after the independent review fix: `79` tests passed with `0` failures.

Additional review check:

```sh
git diff --check
```

Exit status: `0`.

## Self-review

- Re-read the Task 4 brief, PRD §§9, 10.5, 10.7, 15, 16, and AT-001/004/007 against the changed diff.
- Snapshot records copy only scalar preservation fields; adapter-owned slot/item tables and unknown fields cannot enter the snapshot.
- `nil` is interpreted only as an empty slot projection; malformed non-`nil` projections fail closed with structured `CGCE-SNAP-*` errors.
- Fingerprints hash canonical JSON with explicit arrays, occupied records in ascending engine index, and no trailing empty records.
- Total quantity aggregation permits representable positive integer totals through `math.maxinteger` and fails closed before Lua signed-integer wraparound.
- Validator count derivation preserves containers already at or above target and reports every applicable violation in stable code/index/field order.
- The module reports safety violations only; it intentionally has no fatal-stop or persistence behavior.
- AT-004 target selection is intentionally absent and remains a later integration-routing responsibility.
- No mutation-capable adapter method or guessed Palworld symbol was introduced.

## Commits

- `f9bad8e` — `feat: add container snapshot invariants`
- `2a830a0` — `fix: reject snapshot quantity overflow`

## Concerns and deferred evidence

- Exact Palworld slot/item fields, canonical durability extraction, instance metadata hashing, and UObject traversal remain Gate A discovery evidence; this task defines and tests only the fail-closed adapter projection contract.
- The absent advisory Understand Anything graph could not be generated because its workflow requires explicit `.understandignore` confirmation; repository conclusions were verified directly against source, tests, PRD, and the task brief.
- No generalized LLM Wiki capture was warranted; the work implements project-specific contracts already documented in the PRD and task brief.
