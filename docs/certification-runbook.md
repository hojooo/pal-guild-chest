# CGCE certification and operations runbook

Status: **BLOCKED**. This runbook defines work that has not yet been executed.
The current `1.1.0-discovery` package cannot mutate a world and cannot establish
Steam Windows, PS5, or macOS compatibility. `IsServer=true` is only a loader
deployment rule. It is not client, network, save, or UI evidence.

## Roles and evidence boundary

- An operator owns the server, test world, backups, and commands.
- A reviewer other than the operator checks Gate A evidence and release
  certification checksums.
- Raw world, guild, player, and container identifiers remain under the ignored
  `private-artifacts/discovery/<revision>/` directory.
- Public artifacts contain checksums and summarized results only.
- Xbox is optional. It may be tested separately, but missing Xbox evidence does
  not block the required Steam Windows, PS5, and macOS matrix.

## 1. Whole-world backup and recovery rehearsal

1. Announce downtime and stop all player interaction.
2. Shut down the Windows Dedicated Server normally.
3. Create an offline **whole-world backup** of the complete save directory at a
   single point in time; never back up only one `.sav` file.
4. Record server build, game revision, world ID, directory size, file count,
   backup tool, timestamp, and SHA-256 inventory in the private run record.
5. Copy the backup to storage that the server process cannot overwrite.
6. Restore it to a disposable location, start an isolated server, and verify
   world load, guild list, representative chests, and item GUID/quantity.
7. If the rehearsal fails, mark every later gate `BLOCKED` and stop.

Repeat this procedure immediately before discovery, apply, update, removal,
rollback rehearsal, and every slot-candidate certification run.

## 2. Install or update the Discovery Build

1. Run `scripts/verify-package.sh discovery` and build the archive twice.
2. Require identical archive SHA-256 values and retain one checksum receipt.
3. Inspect the archive: one root `Info.json`, one server-only Lua rule,
   `Dependencies=["UE4SS"]`, no client rule, PAK, DLL, UI, input, game asset,
   private evidence, test tool, or mutation module.
4. Verify UE4SS `3.0.1` and the exact Windows Dedicated Server revision.
5. Place the Workshop package where `Info.json` is directly below the item
   directory. Add `ActiveModList=CrossplayGuildChestExpander` to
   `Mods/PalModSettings.ini`, then restart.
6. For an update, retain the previous package and checksum, make a fresh backup,
   and never reuse a binding manifest across game revisions.
7. In this milestone, require the intentional
   `CGCE-LOADER-COMPOSITION-UNAVAILABLE` result. Any mutation attempt is a
   critical packaging defect.

Official server deployment reference: [Palworld — Installing Mods on a
Server](https://docs.palworldgame.com/settings-and-operation/mod/).

## 3. Gate A discovery and review

Gate A is read-only and covers PRD section 32 items 1–16 plus a separately
isolated fatal no-save/safe-stop behavior proof.

1. Use a disposable restored world on the Windows server.
2. Capture the exact probe request, revision source, non-authoritative
   observation, canonical operational report, 54-slot snapshot, candidate
   signatures, implementation bytes, fatal proof, and harness bytes.
   The revision source is a canonical runtime-identity artifact that records
   both the game revision and UE4SS version. The fatal bundle includes an exact
   ordered execution transcript with a zero save-write count at every event.
3. Confirm every candidate observation has `invoked=false`; discovery must not
   call resize, dirty, replication, hook, in-use, or fatal functions.
4. Author a runtime manifest only from one exact full match per logical symbol;
   every alternative must be a full mismatch, not `PARTIAL` or `NOT_LOADED`.
5. Review world/revision/profile/UE4SS identity, guild ownership exclusion,
   exact report/audit/manifest links, snapshot mapping, and actual byte hashes.
6. Validate the private request at
   `private-artifacts/discovery/<revision>/gate-a-evidence.json` and emit the
   deterministic private receipt `gate-a-acceptance.json`.
7. Supply the review-request checksum and reviewer-authorization checksum from
   an independent, access-controlled approval channel. They are trusted pins,
   not values copied from the request under review.
8. The validator resolves every declared path beneath the trusted repository
   root with no-follow metadata and reads the bytes at that path. Separately
   supplied or nonexistent bytes cannot stand in for a private artifact.
9. Independently re-verify the receipt against all actual bytes. A syntactically
   valid receipt without its linked bytes is invalid.
10. Gate A remains non-mutation and non-release. Function entries 9–12 are
   explicitly identity-reviewed, not behavior-authorized. Do not proceed to production
   apply until the later mutation guard and certification exception exist.

## 4. Audit, approval, and future apply

The current Discovery Build supports no apply path. The following steps become
eligible only after Tasks 11–13 produce and verify the required code and pins.

1. Restore a fresh disposable copy and run `mode=audit`.
2. Review every guild, resolved guild-chest ownership, current slot count,
   snapshot, conflict finding, exact manifest checksum, and platform preflight.
3. Persist and read back the canonical operational report atomically.
4. Generate an approval token bound to world ID, exact game revision, fresh
   audit checksum, requested target slots, and deployment profile.
5. Confirm `require_operator_approval=true`, `verify_on_startup=true`,
   `write_migration_ledger=true`, and expand-only behavior.
6. Stop all chest interaction. Run apply once on the disposable allow-listed
   certification world only.
7. For each guild, compare before/after slot count, index, static ID, dynamic
   GUID, quantity, durability, metadata hash, container ID, and owner guild ID.
8. Any invariant failure enters the verified no-save or immediate safe-stop
   path. Do not force a normal save.
9. Persist and read back the migration ledger and structured report, then save,
   stop, restart, and run verify.

### 4.1 Minimum whole-`Saved` clone behavior acceptance

This is a future post-Gate-A, separately authorized mutation test. It is not
part of the current read-only Discovery Build. Do not synthesize Palworld save
bytes or edit one `.sav` file. Start from a normal-stop copy of the complete
`Pal\Saved` tree and let the real PalServer use only that disposable clone.

The minimum product behavior acceptance set is:

1. Every already-initialized target guild chest grows to the approved target
   slot count.
2. A new guild chest grows through the same migration engine after its real
   Container ID is initialized.
3. Existing slot indexes, item static IDs, dynamic GUIDs, quantities,
   durability/quality/instance metadata, container ID, and owner guild ID are
   unchanged, and every appended slot is empty.
4. General chests and all other non-guild containers are unchanged.
5. After a normal save, stop, and restart, the target slot count and all data
   invariants still hold.

The design does not assume a direct global chest-preset edit. A newly created
guild is migrated only after its actual chest container is initialized. This
minimum set spans existing-guild migration and new-guild automation; it does
not collapse the Phase 1 Alpha and Phase 3 completion gates or replace the
Steam Windows, PS5, and macOS certification below.

## 5. Candidate progression and common-prefix rule

Certify in exactly this order: **54 → 120 → 256 → 358**.

For one candidate, all three required vanilla clients must use the same server
game revision, manifest, Gate A receipt, world generation, slot count, and
release candidate. Advance only when Steam Windows, PS5, and macOS all pass.
The shipped default is the greatest common certified prefix. For example, if
macOS fails at 358 while the other clients pass, the release may use at most
256 after all three clients have passed 256. Never repair a platform failure
with a client mod, custom UI, platform-specific slot array, or response.

## 6. Common vanilla-client checklist

Execute and checksum-bind evidence for Steam Windows, PS5, and macOS:

1. Search for and connect to the server; disconnect and reconnect.
2. Join the isolated certification guild and open the guild chest.
3. Navigate the first row, every intermediate row, boundaries, and the **last
   slot** using the platform's normal input method.
4. Deposit and withdraw at the first and last slots.
5. Split a stack, quick-move, sort the entire chest, then reselect the last
   slot and verify display, quantity, and GUID.
6. Close/reopen the chest and fully terminate/relaunch the client.
7. Save, restart the server, reconnect, and recheck slot count and last-slot
   item identity.
8. Run high-latency and transient-packet-loss scenarios with no UI freeze,
   client crash, disconnect, duplication, or loss.
9. Store video, server logs, before/after snapshots, and exact client/server
   versions as private evidence.

### Steam Windows

Use an unmodified Steam Windows client. Confirm mouse/keyboard and controller
navigation, sorting, stack operations, restart persistence, and equality with
the PS5 and macOS observations.

### PS5 Community Server and DualSense

1. Start with `-publiclobby`; ensure listen port, advertised `PublicPort`, and
   external UDP forwarding match. `CrossplayPlatforms` must include `PS5`.
2. Find the server through the PS5 **Community Server** list and join with an
   unmodified client. Record external-network discovery and join evidence.
3. With **DualSense**, test **D-pad** and analog navigation across every row,
   row boundaries, last-row focus, tooltip, stack split, quick move, sort, and
   last-slot deposit/withdrawal.
4. Test suspend/resume separately from full application termination and
   reconnect. Any hidden row, lost focus, freeze, crash, or disconnect fails
   the candidate.

### macOS

Use an unmodified supported Mac client. Verify server search, connect/reconnect,
guild join, first/last slot, split, quick move, sort, close/reopen, complete app
termination, server restart, last-slot display/quantity/GUID, and simultaneous
access with Steam Windows and PS5. Zero UI freeze, crash, or network disconnect
is required.

## 7. Cross-platform concurrency and lifecycle

1. Have all three clients open the same guild chest concurrently.
2. Deposit into different slots, then perform sequential operations on one
   stack. Verify authoritative server state and equal client observations.
3. Repeat around autosave, one-client disconnect, server restart, guild
   leave/rejoin, and guild-owner transfer.
4. Run three consecutive restarts, eight distinct chests, an 80%-full chest,
   and four clients operating one chest.
5. Any lost operation, stale slot, duplicate, GUID drift, or ownership mismatch
   makes that candidate and all larger candidates `BLOCKED`.

## 8. Removal test

1. Complete a fresh whole-world backup after certification data is saved.
2. Stop the server; never shrink the slot array automatically.
3. Remove the package from `ActiveModList`, restart vanilla, and run the full
   three-client **removal** smoke test.
4. On every required client, open the chest, reach the last certified slot,
   withdraw/deposit, sort, reconnect, and verify GUID/quantity.
5. If vanilla removal cannot preserve access and data, release is `BLOCKED`.
   Restore the backup; do not attempt an unverified shrink.

## 9. Performance and six-hour soak

Record hardware, OS, game/UE4SS/package versions, world size, guild/chest/item
counts, client builds, network conditions, baseline method, raw samples, and
analysis script checksum. Required thresholds are:

- steady-state **CPU ≤ 1 percentage point** above baseline;
- steady-state **memory ≤ 100 MB** above baseline;
- **100-guild audit ≤ 5 seconds**;
- **100 empty migrations ≤ 10 seconds**;
- one **54→358 migration ≤ 100 ms**;
- periodic scan disabled or interval at least 60 seconds;
- completed-guild fast path is O(1) before any required live verification;
- **save-time increase ≤ 15%**;
- **open-chest p95 ≤ baseline + 300 ms**;
- **reconnect-time increase ≤ 10%**.

Then run a **six-hour soak** with 32 clients, ten guilds, 358-slot chests at 80%
occupancy, eight users on separate chests, four users on one chest, and chest
operations during autosave. Require zero critical errors, corruption, crash,
disconnect attributable to CGCE, GUID drift, duplicate, or lost item. A missed
threshold is a release block, not a warning-only release.

## 10. Fatal-path rollback rehearsal

1. Start from a disposable restored backup and preserve the pre-run checksum.
2. Trigger the approved fatal invariant path in the isolated harness/run.
3. Prove no later normal save or autosave occurred; for `SAFE_STOP`, prove the
   server stopped immediately without save.
4. Preserve logs and proof, restore the official backup, restart, and verify
   world/guild/chest/item integrity on Steam Windows, PS5, and macOS.
5. Bind rollback evidence into the later release report. If save suppression,
   stop behavior, or restore verification is uncertain, remain `BLOCKED`.

## 11. Release sign-off

Two reviewers compare actual bytes for the non-zero `MinRevision`, runtime
manifest, Gate A receipt, release report, certification artifact, archive, and
release notes. Release notes must list server arguments, `CrossplayPlatforms`,
game revision, exact UE4SS version, common certified slot prefix, and the Steam
Windows/PS5/macOS results. `scripts/build-release.sh release` must continue to
fail until this sign-off and Tasks 11–13 are genuinely complete.
