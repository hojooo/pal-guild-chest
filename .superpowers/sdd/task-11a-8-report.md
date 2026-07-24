# Task 11A.8 Deterministic Handoff Report

## Scope

Task 8 adds a tracked-source verifier and deterministic macOS builder for the
Windows discovery handoff.

## RED

Command:

```text
./scripts/run-tests.sh tests/integration/discovery_handoff_spec.lua
```

Observed failure before builder/verifier source was added:

```text
FAIL builds only the exact tracked Windows handoff deterministically
scripts/verify-discovery-handoff.sh: No such file or directory
```

Final review added an archive-level ordinal manifest assertion. It reproduced
a second RED because the initial builder emitted the declaration order:

```text
FAIL builds only the exact tracked Windows handoff deterministically
expected true, got false
```

## GREEN

Command:

```text
./scripts/run-tests.sh tests/integration/discovery_handoff_spec.lua
```

Result:

```text
PASS Windows discovery handoff > builds only the exact tracked Windows handoff deterministically
```

The behavior test creates a temporary Git repository, commits the exact input
set, runs the verifier, builds two archives at different paths with the same
basename, compares ZIP and sidecar bytes, checks the exact archive entries, and
proves rogue DLL and dirty included-source rejection.

Implemented:

- exact tracked allowlist and symlink/unallowlisted-file rejection;
- operator-source remote-control and probe mutation-token rejection;
- deterministic sorted source manifest;
- fixed permissions and timestamps;
- path-independent SHA-256 sidecar;
- dirty included-source rejection before building.

## Clean-source gate

After commit `b83b50a`, the real worktree handoff inputs were tracked and clean.
The verifier passed, two independently built ZIPs and sidecars compared
byte-identical, and the archive SHA-256 was:

```text
92fc1482cbc87652c05901b11008111fdde02350e4d4472ba7f9c6c87a4fe21e
```

This checksum identifies the clean Task 8 source state only. Later changes to
any included handoff source intentionally produce a new checksum and require
the gate to be repeated.
