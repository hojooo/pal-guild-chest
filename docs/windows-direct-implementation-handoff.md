# CGCE Windows 직접 구현 Handoff

- 작성일: 2026-07-26
- 상태: Windows 구현 인계 준비 완료, 실제 mutation 구현은 Gate A까지 차단
- 현재 branch: `feat/windows-discovery-operator`
- 검증된 코드 기준선: `b559d38f18f73f9e74a9069048d332b8f5607404`
- 작업 방식: Windows 환경에서 한 명의 주 작업자가 직접 구현하며 subagent에
  위임하지 않는다.

> `[STOP]` 이 문서는 현재 Discovery Build를 바로 슬롯 증가 모드로 바꾸는
> 허가서가 아니다. Windows smoke 10개는 통과했지만 전체 PowerShell 회귀
> suite, 실제 Task 11A inventory run, exact-symbol Gate A가 아직 남아 있다.
> Checksum-bound Gate A acceptance가 없으면 UObject write, resize, append,
> dirty, replication, game-thread mutation 또는 `apply` 구현을 시작하지 않는다.

이 문서는 Windows 개발 환경에서 다음 작업을 이어받기 위한 단일 시작점이다.
제품 계약은
[`PRD-Crossplay-Guild-Chest-Expander-Windows-PS5-v1.1.md`](../PRD-Crossplay-Guild-Chest-Expander-Windows-PS5-v1.1.md),
구현 순서는
[`2026-07-22-cgce-implementation.md`](superpowers/plans/2026-07-22-cgce-implementation.md),
실제 운영 절차는
[`windows-discovery-operator-runbook.md`](windows-discovery-operator-runbook.md)가
계속 source of truth다.

## 1. 인계 시점의 정확한 상태

| 항목 | 상태 | 다음 완료 조건 |
|---|---|---|
| Task 1–10 read-only Discovery 코드 | 구현됨 | 실제 Windows Gate A evidence 필요 |
| Task 11A backup/clone/restore/export 도구 | 구현됨 | 전체 Windows 회귀와 승인된 실제 run 필요 |
| Windows PowerShell 5.1 smoke | **GREEN** | `b559d38`에서 `tests=10 failures=0` 확인 |
| Windows PowerShell 5.1 전체 회귀 | **PENDING** | 현재 source에서 `failures=0`, 예상 179 PASS |
| 실제 whole-`Saved` inventory run | **BLOCKED** | 전체 회귀 통과와 별도 maintenance 승인 |
| Task 11B exact-symbol Gate A | **BLOCKED** | 실제 private inventory, 설계 확정, 독립 검토 |
| Task 12 mutation engine | **NOT IMPLEMENTED** | 유효한 Gate A acceptance |
| Task 13 신규 길드 lifecycle | **NOT IMPLEMENTED** | Task 12 완료와 Gate A-approved hook |
| Task 14 Windows/PS5/macOS Gate B | **NOT RUN** | 실제 `54→120` 구현과 disposable-world 승인 |
| Release | **BLOCKED** | 세 필수 vanilla client의 공통 인증값 |

Origin 작업에서 확인한 증거:

- Windows smoke:
  `CGCE_WINDOWS_SMOKE_TESTS tests=10 failures=0`
- macOS targeted/full Lua suite: 통과
- discovery package verifier: 통과
- handoff verifier와 서로 다른 두 경로의 deterministic ZIP/sidecar: 통과
- 기준선 handoff ZIP SHA-256:
  `16ebb56630702788e32801e8932468081ec6e9a54946430dc3e0aa04f264fe25`

이 결과는 `b559d38`의 source에만 적용된다. 이후 source가 한 줄이라도
바뀌면 해당 새 commit에서 관련 gate를 다시 실행한다. 기존 Runbook과
traceability의 “smoke 결과 필요” 문구는 smoke 실행 전 snapshot이며, 이
문서의 exact commit 결과가 더 최신이다. 전체 회귀와 실제 maintenance
차단 상태는 그대로다.

현재 package의 의도된 상태:

- `main.lua`의 인자 없는 production bootstrap은
  `CGCE-LOADER-COMPOSITION-UNAVAILABLE`로 차단된다.
- Discovery `cgce apply`는 `MUTATION_BUILD_UNAVAILABLE`을 반환한다.
- `scripts/verify-package.sh discovery`는 mutation module과 primitive를
  의도적으로 거부한다.
- Windows Task 11A 도구는 복제·복원·private inventory export 도구다. 길드
  상자 슬롯을 변경하지 않는다.

## 2. Windows에서 시작할 때

Windows checkout root는 다음 경로다.

```powershell
$RepoRoot = (
    Resolve-Path `
        -LiteralPath "C:\Users\hojoo\Desktop\workspace\02_pal"
).Path
Set-Location -LiteralPath $RepoRoot

git fetch origin
git switch feat/windows-discovery-operator
git pull --ff-only origin feat/windows-discovery-operator

$ValidatedBaseline = "b559d38f18f73f9e74a9069048d332b8f5607404"
git merge-base --is-ancestor $ValidatedBaseline HEAD
if ($LASTEXITCODE -ne 0) {
    throw "Current HEAD does not descend from the validated baseline."
}

git status --short
git rev-parse HEAD
$PSVersionTable | Format-List PSEdition, PSVersion, CLRVersion
```

필수 조건:

- Windows PowerShell은 `PSEdition=Desktop`, version `5.1`, CLR major `4`다.
- 기준선 이후 변경은 의도적으로 전달된 commit이어야 한다.
- private evidence, 실제 save, credential, `.DS_Store`,
  `.superpowers/sdd/progress.md`를 stage하지 않는다.
- source 변경이 이미 있는데 작성자와 목적을 확인할 수 없으면 `[STOP]`한다.

## 3. 첫 작업: 전체 Windows 회귀 완료

실제 서버나 `Saved`를 건드리기 전에 저장소 root에서 실행한다.

```powershell
$Ps51 = Join-Path `
    $env:WINDIR `
    "System32\WindowsPowerShell\v1.0\powershell.exe"

& $Ps51 `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File .\tests\windows\Run-CgceDiscoveryTests.ps1

if ($LASTEXITCODE -ne 0) {
    throw "CGCE full Windows regression failed."
}
```

완료 조건:

- 예상 179개가 모두 `PASS`
- `FAIL` 없음
- 마지막 줄이 정확히 `CGCE_WINDOWS_TESTS failures=0`
- 중간의 38개 crash-boundary 반복은
  `1/38`, `10/38`, `20/38`, `30/38`, `38/38` 진행 표시를 남기고 정상 종료

실행 중 출력이 잠시 없더라도 `Ctrl+C`를 누르지 않는다. 중단한 결과는 통과
증거가 아니며 suite를 처음부터 다시 실행해야 한다. 새로운 실패가 나오면
실제 server 작업과 `main` 병합을 계속 차단하고, 실패 이름과 stack trace를
기준으로 production 안전 조건을 완화하지 않는 최소 수정만 한다.

수정 후에는 전체 회귀와 smoke를 둘 다 다시 실행한다.

```powershell
& $Ps51 `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File .\tests\windows\Run-CgceDiscoverySmokeTests.ps1
```

Smoke 완료 조건은 정확히
`CGCE_WINDOWS_SMOKE_TESTS tests=10 failures=0`이다. Synthetic smoke는 운영
UDP `8211`을 입력으로 사용하지 않는다. 반대로 실제 maintenance에서는
configured listener와 모든 PalServer process/descendant가 없어야 하며 이
검사를 생략하지 않는다.

## 4. 전체 회귀 다음의 구현 순서

### 4.1 Task 11A 실제 inventory run — `[APPROVAL REQUIRED]`

전체 회귀가 통과하면 먼저 문서의 Windows 결과를 exact commit과 transcript에
맞춰 갱신한다. 그 다음 별도 승인된 maintenance window에서만
[`windows-discovery-operator-runbook.md`](windows-discovery-operator-runbook.md)를
따른다.

고정 조건:

1. 운영 자동 재시작·자동 업데이트를 operator가 중지한다.
2. 외부 ingress를 차단하고 모든 사용자를 퇴장시킨다.
3. PalServer를 정상 종료하고 모든 process/descendant/listener 부재를 확인한다.
4. 운영 `Pal\Saved` 전체를 server tree 밖에 backup한다.
5. 실제 실행에는 검증한 whole-`Saved` clone만 활성화한다.
6. 같은 포트는 production과 clone이 동시에 아니라 **순차적으로** 사용한다.
7. dump 완료 후 server를 정상 종료하고 original과 UE4SS before-image를
   exact inventory로 복원한다.
8. private export ZIP과 sidecar를 다시 검증한 뒤에도 운영 서버는 자동으로
   시작하지 않는다.

Task 11A 결과는 object dump, C++ header dump와 파일 inventory다. 이는 후보를
찾는 1차 자료일 뿐, symbol 선택·Gate A·mutation 권한이 아니다.

실제 prepare/invoke/restore/export 명령은 이 Handoff에서 복제하지 않는다.
현재 Runbook의 기술 gate가 통과하고 exact server root, run ID, control
evidence, maintenance window가 승인된 뒤에만 해당 Runbook을 실행 가능 상태로
승격한다.

### 4.2 Task 11B full Gate A 설계 확정 — `[APPROVAL REQUIRED]`

현재
[`2026-07-23-cgce-remote-discovery-handoff-design.md`](superpowers/specs/2026-07-23-cgce-remote-discovery-handoff-design.md)는
full Gate A `1.1` 설계안이지만 상태가 “보류”다. 반면 현재
`gate_a_evidence.lua`의 `1.0` receipt는 synthetic contract이며
`behavior_authorized=false`다.

따라서 다음 중 어느 것도 임의로 결정하지 않는다.

- `1.0` receipt를 mutation 권한으로 간주
- deferred `1.1` 설계를 승인 없이 전부 구현
- Windows dump 이름만으로 binding manifest 작성
- 인터넷 문서나 과거 revision의 symbol 재사용

Task 11B 시작 전에 owner가 `1.1` provenance 계약과 구현 범위를 명시적으로
확정해야 한다. 확정 시 가장 작은 완전한 범위는 다음과 같다.

- 실제 UE4SS `3.0.1` read-only production port
- live revision을 manifest 자기값이 아닌 authoritative source에서 읽는
  production composition
- exact candidate observation과 immutable observation core
- current Task 11A backup/restore/export lifecycle 재사용
- private artifact import/finalization과 trusted review input
- fatal no-save 또는 immediate safe-stop capability의 별도 isolated proof
- 실제 artifact bytes를 다시 읽는 checksum-bound Gate A acceptance/verify

Native bridge, campaign multi-run, Gate A schema version처럼 architecture와
보안 경계에 영향을 주는 항목은 보류 설계에서 골라 생략하지 않는다. 범위를
줄이려면 먼저 대체 보장이 무엇인지 설계 변경으로 승인받는다.

### 4.3 Read-only Gate A evidence 수집

확정된 Task 11B를 RED → GREEN으로 구현한 뒤 disposable baseline에서 다음
16개를 같은 revision과 evidence chain으로 수집한다.

1. authoritative live game revision
2. guild manager class
3. guild-list access path
4. guild ID property
5. guild-chest Container ID property
6. item-container manager class
7. container lookup function과 complete signature
8. slot-array property
9. empty-slot type
10. safe resize/add-slot candidate와 complete signature
11. dirty-mark function과 complete signature
12. replication-request function과 complete signature
13. world-ready hook과 complete signature
14. new-guild hook과 complete signature
15. container-in-use detection method와 complete signature
16. occupied/empty slot을 모두 포함한 canonical 54-slot before snapshot

추가 필수 조건:

- 모든 function candidate는 observation에서 `invoked=false`
- logical symbol마다 full-signature `MATCHED`가 정확히 하나
- 모든 대안은 완전히 관찰된 `MISMATCH`
- `NOT_LOADED`, `PARTIAL`, `ERROR`, ambiguity는 `[STOP]`
- guild → configured chest ID → resolved container owner가 일치
- general/non-guild container가 제외됨
- 별도 fatal harness가 normal/autosave 억제 또는 무저장 즉시 종료를 실제로
  증명

Private 파일은
`private-artifacts/discovery/<revision>/` 아래에만 둔다. 실제 world/guild/
container/player ID, save, config, log, credential은 Git에 올리지 않는다.
독립 검토와 validator가 성공한 뒤에만 ID-free descriptor를
`CrossplayGuildChestExpander/Scripts/bindings/<revision>.json`으로 승격한다.

Gate A acceptance가 생겨도 그 자체는 mutation이나 release 권한이 아니다.
다만 **유효한 acceptance가 없으면 다음 절의 source도 만들지 않는다.**

### 4.4 Task 12: 기존 길드 `54→120` mutation engine

Gate A가 유효해진 뒤 다음 파일을 test-first로 구현한다.

- `CrossplayGuildChestExpander/Scripts/mutation_guard.lua`
- `CrossplayGuildChestExpander/Scripts/mutation_state_machine.lua`
- `CrossplayGuildChestExpander/Scripts/apply_command.lua`
- `CrossplayGuildChestExpander/Scripts/migration.lua`
- `CrossplayGuildChestExpander/Scripts/resizer.lua`
- `CrossplayGuildChestExpander/Scripts/fatal_safety.lua`
- `CrossplayGuildChestExpander/Scripts/persisted_verifier.lua`
- `tests/integration/mutation_guard_spec.lua`
- `tests/integration/migration_spec.lua`
- `tests/integration/release_apply_spec.lua`

구현 계약:

- Discovery command router와 state machine에는 mutation을 추가하지 않는다.
- Release/certification 전용 entry point에서만 `apply`를 노출한다.
- 정확히 Gate A에서 승인된 resize/add-slot path만 호출한다.
- Raw `TArray` blind append나 임의 slot object 생성은 금지한다.
- `execute_in_game_thread(fn)` 안에서 mutation, dirty/replicate, after snapshot,
  즉시 invariant validation을 같은 callback으로 끝낸다.
- apply 직전 live audit와 persisted report receipt를 새로 만들고 approval을
  exact world/revision/audit checksum/target/profile에 bind한다.
- online player 또는 사용 중인 guild chest가 있으면 apply하지 않는다.
- 각 guild의 validated mutation 뒤 durable ledger receipt를 완료한 다음
  다음 guild로 이동한다.
- post-mutation invariant 또는 ledger persistence가 실패하면 terminal
  `FAILED_AFTER_MUTATION`과 verified no-save/safe-stop으로 전환한다.
- 성공한 in-memory apply는 `VALIDATING_RESTART_REQUIRED`까지만 간다. 정상
  save/stop/restart 뒤 live snapshot이 일치해야 `COMPLETE`다.

첫 Alpha의 목표는 기존 길드 상자 `54→120`이다. `256`과 `358`, 신규 길드
자동화, 세 client certification을 같은 단계에 섞지 않는다.

### 4.5 Task 13: 신규 길드 lifecycle

Task 12의 기존 migration engine을 재사용한다.

- `CrossplayGuildChestExpander/Scripts/replication.lua`
- `CrossplayGuildChestExpander/Scripts/new_guild_hook.lua`
- `tests/integration/runtime_mutation_spec.lua`
- `tests/integration/new_guild_spec.lua`

“길드 상자 preset 증가”는 Palworld의 전역 data asset이나 모든 컨테이너의
기본 크기를 편집한다는 뜻이 아니다. 신규 길드의 실제 chest Container ID가
초기화된 뒤 기존 길드와 같은 guarded migration을 적용한다. Exact hook이
native 경로를 모두 포착하지 못할 때만 60초 이상 간격의 live rescan을
fallback으로 사용한다.

### 4.6 Whole-`Saved` clone 기능 수용

실제 Palworld save bytes를 직접 생성하거나 `.sav`를 offline 편집하지 않는다.
PalServer를 정상 종료한 시점의 **전체 `Pal\Saved` 복제본**만 대상으로 실제
server를 실행한다.

Phase 1 Alpha의 최소 판정:

1. 이미 초기화된 모든 대상 54-slot guild chest가 120-slot이 된다.
2. 기존 slot index, item static ID, dynamic GUID, quantity,
   durability/quality/instance metadata, container ID, owner guild ID가
   before와 같다.
3. 새로 추가된 slot은 모두 empty다.
4. general chest와 모든 non-guild container는 변경되지 않는다.
5. 정상 save/stop/restart 뒤 slot count와 모든 invariant가 유지된다.
6. 같은 target으로 두 번째 실행하면 mutation count가 0이다.

신규 길드 수용은 Phase 3에서 같은 migration engine으로 별도 확인한다. 위
Alpha 성공만으로 Steam Windows, PS5, macOS 호환 또는 release를 주장하지
않는다.

### 4.7 Task 14 Gate B

Candidate는 `54 → 120 → 256 → 358` 순서로만 진행한다. 각 candidate는 동일
server revision, manifest, Gate A receipt, world generation, build를 사용해
vanilla Steam Windows, PS5, macOS가 모두 통과해야 한다. 배포값은 세
플랫폼이 공통으로 통과한 최대 prefix다. 자세한 절차는
[`certification-runbook.md`](certification-runbook.md)를 따른다.

## 5. 어떤 데이터를 변경하는가

| 대상 | Task 11B | Task 12 이후 disposable test | 운영 |
|---|---|---|---|
| Git-tracked Lua/PowerShell/test/docs | 구현 중 변경 | 구현 중 변경 | 배포 승인 전 적용 금지 |
| object/header dump와 Gate A evidence | private read-only 수집 | 입력으로만 검증 | Git/public upload 금지 |
| copied whole-`Saved` | read-only discovery 실행의 server side-effect만 허용 | 실제 PalServer가 in-memory container를 변경하고 정상 save | 폐기 가능한 clone만 |
| 원본 운영 `Pal\Saved` | backup·비활성 보존·exact restore만 | mutation 대상 아님 | 직접 테스트 금지 |
| `.sav` bytes | 직접 편집 금지 | 직접 편집 금지 | 직접 편집 금지 |
| guild chest container | 변경 금지 | 승인된 target으로 expand-only | Gate B/release 전 변경 금지 |
| general/non-guild container | 변경 금지 | 변경 금지 | 변경 금지 |

## 6. 공통 `[STOP]` 조건

다음 중 하나라도 발생하면 더 진행하지 않고 현재 bytes와 evidence를 보존한다.

- full Windows regression 또는 smoke failure
- exact commit, handoff, manifest, evidence, inventory checksum mismatch
- 다른 Palworld revision 또는 UE4SS version/hash
- symbol의 missing, ambiguous, fuzzy, partial, unloaded observation
- verified fatal no-save/safe-stop capability 부재
- production 자동 재시작/업데이트 또는 외부 ingress 차단 불확실
- unknown PalServer descendant 또는 configured listener 잔존
- original/backup/clone/restore inventory mismatch
- 실제 운영 `Saved`가 disposable test target으로 선택됨
- online player 또는 사용 중인 guild chest
- owner/container mismatch, duplicate ID, general-container 오탐
- item fingerprint, GUID, quantity, metadata, ownership drift
- post-mutation ledger/report durable write 실패

실패 시 backup, inactive original, clone, quarantine, receipt, private export를
삭제하거나 덮어쓰지 않는다. 수동 rename으로 recovery state를 맞추거나
state/receipt JSON을 편집하지 않는다.

## 7. 구현 검증 명령

Windows PowerShell source 변경 후:

```powershell
& $Ps51 `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File .\tests\windows\Run-CgceDiscoverySmokeTests.ps1

& $Ps51 `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File .\tests\windows\Run-CgceDiscoveryTests.ps1
```

Lua source 변경 후 repository의 POSIX test environment에서:

```sh
make -C third_party/lua-5.4.8 all
./scripts/run-tests.sh
./scripts/verify-package.sh discovery
git diff --check
```

Windows host에 해당 POSIX toolchain이 없으면 Git Bash/WSL의 검증된
toolchain이나 원래 macOS 개발 host에서 실행한다. 실행하지 못한 gate를
통과로 기록하지 않는다.

Mutation source가 추가되는 시점에는 기존 discovery package allowlist를
완화해 한 package에 섞지 않는다. 별도 release/certification packaging
계약을 먼저 RED test로 정의한다. `scripts/build-release.sh release`가 현재
실패하는 것은 의도된 상태다.

## 8. Git 전달 규칙

- `b559d38`을 Windows smoke가 통과한 기준선으로 보존한다.
- 전체 Windows 회귀가 통과하기 전 현재 feature branch를 `main`에 병합하지
  않는다.
- Gate A 구현은 기준선 검증 이후 별도 목적 branch에서 시작하는 것을
  권장한다.
- RED와 GREEN 명령·결과를 해당 `.superpowers/sdd/task-<N>-report.md`에
  기록하되 사용자 소유 `.superpowers/sdd/progress.md`는 수정·stage하지
  않는다.
- 다음 항목은 commit하지 않는다:
  - `/private-artifacts/`
  - `/dist/`
  - 실제 `Saved`, `.sav`, `.ini`, server log
  - password, API key, approval token, private key
  - raw world/guild/container/player ID
  - `.DS_Store`
- 충돌 해결이나 source 변경이 병합 과정에서 생기면 exact merged tree에서
  relevant Windows/Lua gate를 다시 실행한다.

## 9. 다음 Handoff에 남길 결과

다음 작업자가 raw private artifact를 보지 않고도 상태를 확인할 수 있도록
아래 형식만 전달한다.

```text
Branch:
Exact commit:
Windows PowerShell / CLR:
Full Windows suite final line:
Smoke final line:
Palworld revision:
PalServer executable SHA-256:
UE4SS version / DLL SHA-256:
Task 11A run ID:
Private export ZIP SHA-256:
Gate A contract version:
Gate A receipt SHA-256:
Binding manifest SHA-256:
RED command/result:
GREEN command/result:
Whole-Saved clone acceptance:
Remaining STOP/BLOCKED reason:
```

실제 경로, 사용자명, world/guild/container/player ID, save/config 내용,
credential, approval token은 이 기록에 넣지 않는다.

## 10. Windows 작업 재개용 짧은 지시문

새 Windows Codex 작업에는 다음처럼 요청한다.

```text
AGENTS.md와 docs/windows-direct-implementation-handoff.md를 먼저 전부 읽어줘.
subagent를 사용하지 말고 직접 진행해줘. 현재 HEAD와 b559d38 기준선 관계를
확인하고 Windows PowerShell 5.1 전체 회귀를 끝까지 실행한 뒤 결과를
판정해줘. failures=0이 아니면 실제 서버나 Saved를 건드리지 말고 원인만
수정해줘. failures=0이면 Handoff의 다음 미완료 gate만 계획하고, Gate A
승인 전에는 mutation source를 작성하지 마.
```
