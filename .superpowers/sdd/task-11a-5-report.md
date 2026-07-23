# Task 11A.5 Implementation Report

## Scope and status

This report covers immutable source-manifest authority plus the Task 11A.5
Invoke/process/capture implementation. Portable verification and independent
static review are recorded here. It does not claim that Task 11A.5 has passed
its Windows gate.

### RED

Portable focused command:

```text
./scripts/run-tests.sh tests/integration/discovery_handoff_spec.lua
```

Result: exit `1`.

The three existing handoff checks that reached their prior assertions passed.
The new assertions failed for the intended missing behavior:

```text
FAIL defines a fail-closed Windows prepare entry point
tests/integration/discovery_handoff_spec.lua:119: expected true, got false

FAIL binds invoke bootstrap to immutable source-manifest authority
tests/integration/discovery_handoff_spec.lua:334: expected true, got false
```

The first failure proved Prepare did not commit the source-manifest checksum;
the second proved Contract/spec/plan did not yet define the immutable
Invoke bootstrap authority.

A later RED increment tightened the bootstrap memory bound:

```text
./scripts/run-tests.sh tests/integration/discovery_handoff_spec.lua
```

Result: exit `1`; the Invoke authority case failed at its new bounded-reader
assertion because bootstrap still called `File.ReadAllBytes` before checking
the 1 MiB limit. The implementation then changed to a length-first exact
`FileStream` read with truncation/growth detection.

The Windows behavioral tests were also written before the production change,
but this macOS host cannot execute them:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File \
  .\tests\windows\Run-CgceDiscoveryTests.ps1
```

Result: exit `127`.

```text
zsh: command not found: powershell.exe
```

### GREEN

Implemented authority:

- `New-CgceRunState` has the exact required
  `source_manifest_checksum` field, temporarily null only in the fresh
  in-memory constructor result.
- Every committed genesis/current state requires one lowercase 64-hex value.
  The JSON schema makes the field required and non-null.
- Genesis/current identity and the normal state CAS treat the field as
  immutable.
- `Assert-CgceHandoffSource` requires
  `-ExpectedManifestChecksum`, verifies it before payload validation, and
  rechecks it after validation.
- Prepare captures the checksum after validating the handoff, revalidates it
  under the server lock and immediately before genesis, stores it in genesis,
  and compares later state plus local manifest against the stored authority.
- The authoritative spec and Task 5 plan keep Invoke's CLI unchanged. Invoke
  derives its handoff root from its own script location and must read the
  immutable genesis authority with built-in code before importing any handoff
  module. The plan also requires pre-import module hash checks, full
  post-import state/payload validation, relocation of identical bytes,
  handoff/RunRoot non-overlap, and a re-signed-tree test proving no module side
  effect.
- The portable contract also checks the implemented Invoke bootstrap tokens,
  requires the bootstrap call to precede the first module-import call in the
  main path, and requires the lifecycle re-signed-tree sentinel assertion.
- Bootstrap now checks file length before allocation, reads exactly the
  authorized bytes, rejects truncation/growth and an extra byte, and never uses
  `ReadAllBytes` for genesis or manifest.
- Invoke holds the server lock across its authoritative state read, the
  `PROBE_STAGED -> RUNNING -> CAPTURED` transitions, process execution, capture
  validation, and terminal state write. Replay from `RUNNING`, `BLOCKED`, or
  `CAPTURED` cannot create another child.
- Runtime writes an immutable launch intent before process creation, then a
  gapless PID/path/creation-time chain and final result. A root or descendant
  identity that cannot be read creates a no-overwrite
  `manual-recovery-required.json` barrier instead of guessing. A reused
  numeric PID or exhausted bounded receipt sequence creates the same chained
  durable barrier before failing, so neither ambiguity is left without
  recovery evidence.
- A mandatory pre-launch callback receives the exact launch-intent checksum and
  freshly revalidates state, marker, probe matrix, control evidence, process
  inactivity, inventories, executable/DLL hashes, and handoff authority before
  `Start-Process`.
- Native arguments are fail-closed, quoted with the Windows CRT rules, bounded
  by the 32,766-character process limit, and omitted from `ArgumentList` for a
  zero-token array. Receipts retain only framed count/digest evidence, never
  plaintext arguments.
- Process monitoring uses at most 100 ms waits under monotonic timeout plus
  control/launch deadlines. A quiescence sweep that first discovers a live
  descendant re-enters the bounded loop rather than failing early or declaring
  success. Numeric parent links require one unique observed parent and a child
  creation FileTime no earlier than that exact parent; receipt readers enforce
  the same PID-uniqueness and temporal chain.
- Capture accepts exactly one non-empty object dump, a non-empty header tree,
  exactly one completion-marker occurrence, no blocked marker, and only the
  fixed object/header children in the run capture.

Windows behavioral coverage was added for missing/null/non-lowercase/
line-suffixed committed values, genesis/current and CAS drift, and a
self-consistent re-signed payload/manifest rejected against the original
manifest authority. Additional lifecycle coverage exercises relocated
byte-identical handoff execution, oversized genesis/manifest authority,
pre-launch matrix and DLL drift, executable path/hash drift, timeout/non-zero/
missing-output/log failures, launch/process/PID/result crash boundaries,
one-launch replay barriers, an actual child-to-grandchild parent chain, and a
listener descendant that outlives the root. Runtime coverage also exercises
zero-argument execution, private quote edge vectors, command-line bounds,
unlisted identities, manual-recovery barriers, and late final-sweep
descendants.

Focused portable command:

```text
./scripts/run-tests.sh tests/integration/discovery_handoff_spec.lua
```

Result: exit `0`; `5` passed.

Full portable command:

```text
./scripts/run-tests.sh
```

Result: exit `0`.

Package verification:

```text
./scripts/verify-package.sh discovery
```

Result: exit `0`.

```text
DISCOVERY_PACKAGE_VERIFIED
```

Schema and patch checks:

```text
jq empty tools/windows-discovery/schemas/*.json
git diff --check
```

Result: both exit `0`.

At verification time the Windows suite contained `144` static
`Invoke-CgceTest` definitions: `37` Contract, `32` Files, `49` Runtime, and
`26` Lifecycle cases. Static presence does not replace execution.

### Residual gate

The final Windows command was rerun:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File \
  .\tests\windows\Run-CgceDiscoveryTests.ps1
```

Result: exit `127`; `powershell.exe` is unavailable on this macOS host.

An elevated Windows PowerShell 5.1 run with `failures=0` remains mandatory
before this slice, the Invoke entry point, or Task 11A.5 is treated as
Windows-verified. Task 6 must additionally prove that every partial process
journal blocks Restore while any exact executable, durable PID identity, or
listener remains active, and that a manual-recovery state error or sentinel
always forbids automatic restoration.
