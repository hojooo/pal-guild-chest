# CGCE Discovery Build runbook

This runbook is for the non-release, read-only Discovery Build. It collects the
runtime evidence needed for Gate A. It does not authorize, package, load, or
invoke mutation code.

## Safety boundary

- Use a backed-up, disposable Windows dedicated-server world.
- Stop normal player traffic before discovery begins.
- Use the exact UE4SS version declared by the build. The current implementation
  contract is UE4SS `3.0.1`; a different runtime is unsupported until reviewed.
- Keep `mode=audit`. `cgce apply` must return `MUTATION_BUILD_UNAVAILABLE`.
- The build may resolve exact objects, read verified properties, enumerate
  loaded instances, and observe the verified world-ready function. It must not
  call candidate functions, write a property, mutate a `TArray`, construct a
  slot, queue mutation on the game thread, or register mutation/new-guild hooks.
- A server backup is a prerequisite, not evidence that a candidate is safe.

If any read result is ambiguous, unloaded, partial, mismatched, or unavailable,
stop and retain the blocked evidence. Do not replace an exact identity with a
short-name guess, wildcard, substring match, address, or `tostring()` output.

## Private artifacts

Keep the following files in ignored, access-controlled local storage. Do not
commit raw world IDs, guild IDs, container IDs, player data, credentials, or
server logs to the public repository.

1. `discovery-probe-request.json` — owner-authored exact candidates,
   self-checksummed and explicitly non-authoritative.
2. `discovery-observation.json` — read-only observation of every candidate,
   self-checksummed and bound to the request checksum and live revision.
3. `audit-report.json` — the durable operational report for the same run.
4. `binding-manifest.json` — a private review candidate containing only
   uniquely matched exact symbols. Its `source_audit_checksum` binds the same
   run's trusted audit checksum; the later Gate A artifact separately binds
   both the manifest and observation checksums. After Gate A review, its
   world-, guild-, and container-ID-free runtime descriptor data may be
   promoted to `Scripts/bindings/<revision>.json`; the raw capture remains
   private.
5. `gate-a-acceptance.json` — produced later by the read-only Gate A validator,
   never handwritten.

The trust direction is checksum-bound and converges at Gate A:

```text
probe request -> observation ---------------------> Gate A validator -> receipt
trusted audit -> runtime manifest ---------------->
```

Every arrow is an exact checksum comparison. A valid shape or a 64-character
checksum string is not sufficient.

## Preparation

1. Record the server build, Palworld revision source, UE4SS version, server
   launch arguments, and `PalWorldSettings.ini` separately from the artifact.
2. Verify `-publiclobby`, matching public ports, JSON logging, and
   `CrossplayPlatforms` containing `Steam`, `PS5`, and `Mac`. This is only a
   connectivity diagnostic and is not client certification.
3. Back up the entire world and verify that the backup can be restored.
4. Create representative test data in the disposable world:
   - at least one initialized 54-slot guild chest;
   - at least one guild without an initialized chest;
   - at least two distinct guilds for ownership checks;
   - at least one general, non-guild container that must remain excluded;
   - representative occupied and empty slots in the 54-slot chest.
5. Author exact candidate descriptors from primary runtime evidence. A
   descriptor must include its kind, exact absolute path, canonical type
   signature, and, for properties, exact owner path and member name.

## Read-only discovery run

1. For a new revision, start the isolated bootstrap probe with an empty-symbol
   discovery manifest and the separate owner-authored probe request. Read the
   live revision exactly once for that probe epoch. The empty manifest remains
   intentionally incapable: it cannot start normal runtime traversal, infer a
   candidate, or confer binding or mutation authority.
2. Observe every requested candidate without invoking it. Each observation
   must record:
   - logical symbol and kind;
   - exact query and candidate identity;
   - status: `MATCHED`, `NOT_LOADED`, `MISMATCH`, `PARTIAL`, or `ERROR`;
   - observed full name and canonical signature when available;
   - signature coverage and provenance API;
   - `invoked=false`.
   Every `(logical symbol, candidate index)` pair is recorded at most once. A
   symbol is manifest-ready only when every candidate has been observed,
   exactly one is `MATCHED` with full signature coverage, and every alternative
   is a fully observed `MISMATCH`. `NOT_LOADED`, `PARTIAL`, and `ERROR` remain
   blocking because an unobserved alternative could still be ambiguous.
3. Use the same isolated, read-only bootstrap harness to persist the source
   audit and representative snapshot. Review the unique matches, then author a
   self-checksummed runtime manifest whose `source_audit_checksum` equals that
   audit. This manual boundary does not make the observation authoritative; the
   later Gate A validator must cross-check all linked bytes.
4. Close every bootstrap observation handle and timer. Start a fresh normal
   Discovery Build epoch with the exact runtime manifest. It reads the live
   revision once again for the new binding epoch and rejects checksum,
   revision, or reflected-type drift.
5. Wait for selected-world readiness. The policy is one immediate attempt plus
   at most 59 one-second retries. The exact selected world, guild manager, and
   container manager must remain stable for the issued epoch.
6. Enumerate guilds only through the selected world's verified guild manager.
   Record detached guild ID, display name, and configured chest container ID.
7. Resolve a configured chest only through the exact loaded guild-chest class
   inventory and the selected world's verified container manager. Scan the full
   inventory before filtering. Duplicate container IDs, a different manager,
   a general container, or an owner mismatch are blocking findings.
8. Perform no resolution and no snapshot read for a guild whose configured
   chest ID is absent.
9. Close every observation handle and timer. A callback arriving after shutdown
   must be ignored by the invalidated generation.

## Gate A evidence checklist

Gate A covers PRD section 32 items 1–16 only. Items 17–20 belong to Gate B and
must not be claimed by discovery.

1. Exact live game revision and authoritative provenance.
2. Guild manager class.
3. Guild-list access path.
4. Guild ID property.
5. Guild-chest container-ID property.
6. Item-container manager class.
7. Container lookup function and complete signature.
8. Slot-array property.
9. Empty-slot type.
10. Safe resize or add-slot function and complete signature.
11. Dirty-mark function and complete signature.
12. Replication-request function and complete signature.
13. World-ready hook candidate and complete signature.
14. New-guild hook candidate and complete signature.
15. Container-in-use detection method and complete signature.
16. Canonical before snapshot of one exact 54-slot guild chest.

The snapshot is acceptable only when the runtime mapping proves all of these
projections without raw-value coercion:

- engine-order slot array and exact slot count;
- empty-versus-occupied discriminator;
- item static ID;
- dynamic item GUID;
- positive integer quantity;
- canonical durability representation;
- complete, ordered metadata-hash inputs and their allow-listed canonical codec;
- container ID and owner guild ID.

The observation binds, by exact lowercase SHA-256, the projection contract,
projector implementation, capture source, durability codec, metadata codec,
and ordered metadata-input contract. Those links make the artifact reviewable;
they do not prove the linked implementations. The Gate A validator must load
and cross-check the actual linked artifacts. The representative snapshot must
contain at least one occupied and one empty slot.

The resulting snapshot must contain exactly 54 records, recompute its occupied
count and total quantity, and reproduce its item fingerprint. A generic Lua
table projection is not proof of the runtime field mapping.

Gate A also requires a separately verified fatal path that either suppresses
later normal/autosave or immediately stops the server without saving after an
invariant failure. Discovering a candidate name is insufficient; inability to
prove this behavior blocks Gate A.

The non-authoritative observation may bind the claimed mode, selected candidate
index, behavior-proof artifact checksum, and harness implementation checksum.
It must keep `behavior_verified=false`; only the later Gate A validator may
validate those linked bytes and issue an acceptance receipt.

## Review and acceptance

1. Confirm every runtime-manifest symbol has candidates, every candidate was
   observed, exactly one candidate per symbol is `MATCHED`, all alternatives
   are proven `MISMATCH`, functions have complete signature coverage, and every
   record says `invoked=false`.
2. Confirm the observation is bound to the exact probe request and live
   revision, its checksum-bound revision evidence records the exact source,
   signature, provenance API, and source artifact checksum, and its
   self-checksum recomputes.
3. Author the runtime manifest separately from the observation. Its symbol set
   must equal the unique matched set, and its `source_audit_checksum` must equal
   the trusted audit checksum embedded in the same run's operational report.
   The later Gate A artifact must bind the observation checksum separately.
4. Confirm the operational report, manifest, observation, 54-slot snapshot,
   fatal-safety evidence, reviewer, timestamp, world, revision, and UE4SS
   version all refer to the same run.
5. Treat `manifest_readiness` only as permission to author a runtime-manifest
   candidate. It is not Gate A eligibility or authority.
6. Run the Gate A validator over the actual linked artifacts. A receipt remains
   non-mutating; it is only a future prerequisite for implementing the isolated
   post-Gate-A mutation layer.

Do not promote an artifact if a required symbol lacks exactly one full
`MATCHED` record, an alternative candidate is not a full `MISMATCH`, or any
record is absent, `NOT_LOADED`, `PARTIAL`, `ERROR`, invoked, ambiguous,
checksum-mismatched, or stored in a public package path.

## Stop conditions

Stop the run, preserve the artifacts, and leave mutation unavailable when:

- the live revision cannot be read authoritatively;
- the exact binding manifest is missing or fails type verification;
- selected-world authority changes during a read;
- duplicate IDs, wrong-world objects, non-guild containers, or owner mismatch
  are found;
- any snapshot projection or canonical codec is unproven;
- any candidate would need to be invoked to discover its signature;
- observation/timer cleanup is uncertain;
- fatal save suppression or safe stop cannot be proven.

## Gate B reminder

Gate B is a later disposable-world mutation and client-certification phase. A
release requires vanilla Steam Windows, PS5, and macOS evidence for the same
revision and slot candidate. Xbox remains optional. No Gate A result, successful
Windows-only test, or server-only package may substitute for those client tests.
