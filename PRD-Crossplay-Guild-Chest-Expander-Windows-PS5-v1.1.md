# PRD — Crossplay Guild Chest Expander

- **제품명:** Crossplay Guild Chest Expander
- **약칭:** CGCE
- **문서 버전:** 1.1 — Windows Server + PS5/macOS 필수 프로필
- **상태:** 구현 전 승인안
- **작성일:** 2026-07-22
- **대상 게임:** Palworld 1.0 계열
- **서버 환경:** Windows 64-bit Dedicated Server — 확정
- **클라이언트 대상:** PS5 순정 클라이언트 — 필수·최우선, Steam Windows 순정 클라이언트 — 필수 기준 클라이언트, macOS 순정 클라이언트 — 필수, Xbox — 후속 선택 지원
- **기본 목표 슬롯 수:** 358
- **배포 방식:** Palworld Official Mod Loader + UE4SS Lua server mod
- **핵심 제약:** PS5와 macOS를 포함한 모든 플레이어 클라이언트에는 어떠한 모드도 설치하지 않는다. 모든 기능은 Windows 서버에서만 동작해야 한다.

---

## 1. 제품 요약

Crossplay Guild Chest Expander는 Palworld Windows 데디케이트 서버에만 설치하여 다음을 수행하는 서버사이드 모드다.

1. 이미 월드에 존재하는 길드의 길드 상자를 찾아 기존 슬롯 수를 안전하게 확장한다.
2. 모드 설치 이후 생성되는 신규 길드에도 같은 슬롯 수를 적용한다.
3. PS5, Steam Windows, macOS의 수정되지 않은 클라이언트가 동일한 길드 상자를 열고 사용할 수 있게 한다. Xbox는 후속 호환 대상으로 둔다.
4. 기존 아이템, 수량, 슬롯 순서, 아이템 GUID, 길드 소유 관계를 변경하지 않는다.
5. 슬롯 수를 줄이지 않는 `expand-only` 정책을 사용한다.
6. 실행 전 점검, 마이그레이션 결과, 실패 사유를 운영자가 검증할 수 있게 기록한다.
7. 게임 버전 또는 내부 심볼이 검증되지 않았으면 데이터를 수정하지 않고 안전하게 중단한다.

이 제품에서 “크로스플랫폼 지원”은 모드 바이너리가 모든 플랫폼에서 실행된다는 의미가 아니다. **모드는 Windows 데디케이트 서버에서만 실행되며, PS5와 macOS를 포함한 필수 순정 클라이언트가 별도 설치 없이 기능을 사용한다**는 의미다.

---

## 2. 배경과 문제 정의

길드 상자 슬롯 수를 변경하는 단순 PAK 또는 데이터 오버라이드 모드는 일반적으로 신규 길드 상자 생성 시 적용되는 기본값만 바꾼다. 이미 생성된 길드 상자의 실제 컨테이너 슬롯 배열은 월드 세이브에 저장되어 있기 때문에, 기본값을 변경해도 기존 길드에는 소급 적용되지 않을 수 있다.

운영자가 겪는 문제는 다음과 같다.

- 기존 길드를 유지하면서 길드 상자만 확장하기 어렵다.
- 기존 길드를 해체하고 재생성하면 거점, 소유권, 길드원 관계에 영향을 줄 수 있다.
- 저장 파일을 직접 편집하면 잘못된 GUID 또는 컨테이너를 수정할 위험이 있다.
- 클라이언트 모드를 요구하면 Xbox, PS5 등 콘솔 이용자가 참여하기 어렵다.
- 슬롯 배열을 단순히 교체하면 기존 아이템 유실 또는 중복이 발생할 수 있다.
- 게임 업데이트 후 내부 클래스·프로퍼티·함수 경로가 바뀌면 조용히 잘못된 데이터를 수정할 수 있다.
- 큰 슬롯 수가 모든 플랫폼의 기본 UI와 컨트롤러 탐색에서 정상 동작하는지는 별도 검증이 필요하다.
- 모드 제거 후 자동 축소는 초과 슬롯 아이템 유실 위험이 있다.

### 해결할 핵심 문제

> Windows 데디케이트 서버의 기존·신규 길드 상자를 안전하게 확장하되, PS5, Steam Windows 및 macOS 순정 클라이언트가 별도 모드 없이 동일한 기능을 안정적으로 사용할 수 있게 한다.

---

## 3. 검증된 외부 제약

제품은 다음 제약을 전제로 설계한다.

1. 실제 배포 서버는 **Windows 64-bit Palworld Dedicated Server**다.
2. 현재 Palworld의 공식 서버사이드 모드는 Windows 데디케이트 서버에서만 공식 지원된다.
3. 서버용 모드는 공식 패키지의 `Info.json`에 `"IsServer": true`인 설치 규칙이 있어야 한다.
4. PS5 클라이언트에는 UE4SS, Workshop 모드, PAK, 커스텀 UI를 설치할 수 없으므로 모드는 서버 전용이어야 한다.
5. PS5 사용자가 참여하려면 서버를 `-publiclobby`로 실행하는 커뮤니티 서버로 구성해야 한다.
6. `PalWorldSettings.ini`의 `CrossplayPlatforms`에는 최소 `PS5`가 포함되어야 한다.
7. 현재 서버 설정에서 사용할 수 있는 플랫폼 값은 `Steam`, `Xbox`, `PS5`, `Mac`이다.
8. 서버 모드는 세이브 손상이나 크래시 위험이 있으므로 백업과 단계적 검증이 필수다.
9. UE4SS Lua는 UFunction 후킹, 런타임 UObject 검색, 게임 스레드 실행 기능을 제공한다.
10. PS5 또는 macOS 기본 UI가 목표 슬롯 수를 처리하지 못하면 클라이언트 패치로 보완하지 않고, 모든 필수 클라이언트가 통과한 슬롯 수로 낮춘다.

이 제약은 제품 요구사항의 일부이며, 릴리스마다 현재 공식 문서와 다시 대조한다.

### 3.1 확정 배포 프로필

본 PRD의 1차 배포 프로필은 다음으로 고정한다.

```text
Profile ID: windows-dedicated-ps5-macos-required
Server OS: Windows 64-bit
Server type: Community Server
Required clients:
  - PS5 vanilla client
  - Steam Windows vanilla client
  - macOS vanilla client
Optional clients:
  - Xbox / Microsoft Store
Client-side mod: prohibited
```

권장 서버 실행 인자는 다음과 같다.

```bat
PalServer.exe -publiclobby -port=8211 -publicport=8211 -logformat=json
```

`-publicport`는 서버가 실제로 수신하는 포트를 바꾸지 않으므로 `-port`와 함께 일치시킨다. 공인 IP 자동 감지가 실패할 때만 `-publicip=<공인IP>`를 추가한다.

`PalWorldSettings.ini`에는 최소 다음 의도가 반영되어야 한다.

```ini
CrossplayPlatforms=(Steam,PS5,Mac)
bAllowClientMod=False
PublicPort=8211
LogFormatType=Json
```

Xbox 참가자가 추가되면 다음처럼 확장할 수 있다.

```ini
CrossplayPlatforms=(Steam,Xbox,PS5,Mac)
```

운영 전제:

- Windows 방화벽에서 게임 서버의 UDP 수신 포트를 허용한다.
- 공유기 환경이면 UDP 8211을 서버 PC의 동일 포트로 포트포워딩한다.
- PS5에서는 IP 직접 접속이 아니라 커뮤니티 서버 목록을 통한 검색·접속을 필수 검증한다.
- 동일 공유기 내부에서 공인 주소로 접속하는 테스트는 Hairpin NAT 지원 여부에 영향을 받을 수 있으므로 외부 네트워크 테스트를 병행한다.

---

## 4. 목표

### 4.1 제품 목표

| ID | 목표 |
|---|---|
| G-001 | 기존 길드의 길드 상자를 기본 목표 358칸으로 소급 확장한다. |
| G-002 | 신규 길드 생성 시 동일한 확장 정책을 자동 적용한다. |
| G-003 | PS5, Steam Windows, macOS 순정 클라이언트를 필수 지원하고, Xbox는 후속 선택 지원한다. |
| G-004 | 기존 아이템 데이터와 길드 소유 관계를 보존한다. |
| G-005 | 여러 번 실행해도 결과가 달라지지 않는 멱등 마이그레이션을 제공한다. |
| G-006 | 검증되지 않은 게임 버전에서는 fail-closed로 동작한다. |
| G-007 | 운영자가 변경 전후 상태와 실패 원인을 확인할 수 있게 한다. |
| G-008 | 모드를 제거해도 이미 확장된 슬롯이 정상 세이브에 유지되도록 한다. |
| G-009 | 장기 실행 중 주기적 전체 스캔과 같은 불필요한 서버 부하를 최소화한다. |
| G-010 | 공식 Mod Loader 패키지로 설치·업데이트·비활성화가 가능하게 한다. |

### 4.2 사용자 가치

- 기존 길드를 해체하지 않고 저장공간을 확장할 수 있다.
- PS5 플레이어에게 별도 설치를 요구하지 않는다.
- 마이그레이션이 실패해도 기존 정상 월드를 덮어쓰지 않는 운영 절차를 제공한다.
- 서버 업데이트 후 모드가 안전하지 않으면 자동 수정하지 않고 원인을 알린다.
- 서버 재시작마다 슬롯을 계속 추가하거나 아이템을 재배치하지 않는다.

---

## 5. 비목표

초기 제품에는 다음을 포함하지 않는다.

- Linux 데디케이트 서버 지원
- 클라이언트 UI 신규 제작
- 커스텀 네트워크 프로토콜 또는 클라이언트 RPC 추가
- 신규 아이템·텍스처·위젯·Blueprint 에셋 추가
- 일반 보관함, 냉장고, 먹이 상자 등 길드 상자 외 컨테이너 확장
- 길드 상자 슬롯 축소
- 초과 슬롯 아이템 자동 이동
- 손상된 세이브 복구
- 길드 병합 또는 길드 소유권 이전
- 세이브 파일 오프라인 직접 편집
- 길드 상자 검색·정렬 UI 개선
- 358칸보다 큰 임의 슬롯 수의 공식 지원
- 클라이언트별 다른 슬롯 수 제공
- 플랫폼별 전용 빌드 배포
- PalDefender 또는 다른 관리 모드와의 기능 통합
- 게임 업데이트 직후 자동 호환 추정
- 게임 내부 클래스명·함수명을 fuzzy matching으로 자동 선택

---

## 6. 대상 사용자

### 6.1 서버 운영자

**필요**

- 기존 길드를 보존한다.
- 서버에만 모드를 설치한다.
- 마이그레이션 전후 결과를 확인한다.
- 문제가 생기면 백업으로 즉시 복원한다.
- 게임 업데이트 후 호환 여부를 확인한다.

### 6.2 일반 플레이어

**필요**

- 클라이언트에 아무것도 설치하지 않는다.
- 기존 Palworld UI로 상자를 연다.
- 키보드·마우스 또는 컨트롤러로 모든 슬롯에 접근한다.
- 플랫폼이 달라도 같은 슬롯과 아이템 상태를 본다.

### 6.3 모드 개발자

**필요**

- 게임 revision별 내부 심볼을 분리 관리한다.
- 마이그레이션 로직과 Palworld 바인딩을 격리한다.
- synthetic test와 실제 월드 테스트를 모두 수행한다.
- 게임 업데이트로 바인딩이 깨졌을 때 안전하게 실패한다.

---

## 7. 플랫폼 지원 정의

### 7.1 서버 플랫폼

| 플랫폼 | 지원 | 릴리스 의미 |
|---|---|---|
| Windows 64-bit Dedicated Server | **필수·확정** | 실제 운영 대상 |
| Windows Steam 클라이언트 호스트 | 비지원 | listen server 방식은 범위 밖 |
| Linux Dedicated Server | 비지원 | 공식 서버사이드 모드 지원 범위 밖 |
| Docker Linux Server | 비지원 | 운영 대상 아님 |
| macOS 서버 | 비지원 | 운영 대상 아님 |

### 7.2 클라이언트 플랫폼 등급

| 등급 | 플랫폼 | 클라이언트 설치 | 릴리스 게이트 |
|---|---|---:|---|
| Tier 0 | PS5 | 없음 | **필수·최우선** |
| Tier 0 | Steam Windows | 없음 | **필수 기준 클라이언트** |
| Tier 0 | macOS | 없음 | **필수 릴리스 인증** |
| Tier 1 | Xbox / Microsoft Store | 없음 | 후속 선택 인증 |
| Tier 2 | Steam Deck/Proton | 없음 | 참고 호환성 |

PS5 또는 macOS 테스트가 통과하지 않으면 Steam Windows에서 정상 동작하더라도 정식 릴리스하지 않는다.

### 7.3 PS5 필수 릴리스 기준

PS5 순정 클라이언트에서 다음을 모두 통과해야 한다.

- 커뮤니티 서버 목록에서 서버 검색
- 서버 접속과 재접속
- 길드 가입 후 길드 상자 열기
- 첫 슬롯과 마지막 슬롯 접근
- DualSense D-pad와 아날로그 스틱으로 모든 행 이동
- 아이템 넣기·꺼내기
- 스택 분할과 빠른 이동
- 정렬 후 마지막 슬롯 재접근
- 상자 닫기·재열기
- 서버 재시작 후 상태 유지
- PS5 애플리케이션 재시작 후 상태 유지
- Steam 플레이어와 같은 상자를 동시에 사용
- 마지막 슬롯 아이템의 표시·수량·GUID 보존
- UI 프리징·클라이언트 크래시 0건
- 네트워크 연결 해제 0건

### 7.4 macOS 필수 릴리스 기준

macOS 순정 클라이언트에서 다음을 모두 통과해야 한다.

- 서버 검색, 접속과 재접속
- 길드 가입 후 길드 상자 열기
- 첫 슬롯과 마지막 슬롯 접근
- 키보드·마우스 또는 지원 컨트롤러로 모든 행 이동
- 아이템 넣기·꺼내기
- 스택 분할과 빠른 이동
- 정렬 후 마지막 슬롯 재접근
- 상자 닫기·재열기
- 서버 및 macOS 애플리케이션 재시작 후 상태 유지
- PS5 및 Steam Windows 플레이어와 같은 상자를 동시에 사용
- 마지막 슬롯 아이템의 표시·수량·GUID 보존
- UI 프리징·클라이언트 크래시 0건
- 네트워크 연결 해제 0건

### 7.5 목표 슬롯 수 결정

후보 슬롯 수는 다음 순서로 검증한다.

```text
54 → 120 → 256 → 358
```

각 단계는 Steam Windows 기준 테스트 후 반드시 PS5와 macOS 테스트를 거친다. 세 필수 클라이언트 중 하나라도 실패한 단계는 인증하지 않는다.

```text
certified_target_slots
= Steam Windows, PS5, macOS가 모두 통과한 슬롯 수의 집합
```

358칸이 PS5 또는 macOS에서 실패하면 다음 원칙을 적용한다.

1. PS5 또는 macOS 클라이언트 패치나 별도 UI 모드를 요구하지 않는다.
2. 서버가 플랫폼별로 다른 슬롯 수를 보내지 않는다.
3. 마지막으로 Steam Windows, PS5, macOS가 모두 통과한 값으로 기본 슬롯 수를 낮춘다.
4. 실패한 358칸 빌드는 실험용으로만 유지하고 운영 월드에 적용하지 않는다.

Xbox는 정식 1.0 릴리스의 필수 게이트에서 제외하며, 지원을 표기하려면 별도 인증 결과가 있어야 한다. macOS는 정식 1.0의 필수 게이트다.

---

## 8. 접근 방식 비교

### 접근 A — PAK 또는 PalSchema 기본값 변경

**개요**

신규 길드 상자 생성에 사용하는 기본 슬롯 수만 변경한다.

**장점**

- 구현이 단순하다.
- 런타임 객체 탐색이 적다.
- 서버 시작 오버헤드가 작다.

**단점**

- 기존 길드에 소급 적용되지 않는다.
- 이미 저장된 컨테이너 슬롯 배열을 수정하지 못한다.
- 이번 제품의 핵심 요구를 충족하지 못한다.

**결론**

단독 방식으로 채택하지 않는다.

### 접근 B — 오프라인 세이브 마이그레이터

**개요**

서버를 종료한 뒤 `Level.sav`를 파싱하여 기존 길드 상자 슬롯 배열을 변경한다.

**장점**

- 런타임 후킹이 필요 없다.
- 변경 전후를 오프라인에서 비교하기 쉽다.
- 일회성 기존 길드 마이그레이션에 적합하다.

**단점**

- 새 길드마다 재실행해야 한다.
- 세이브 포맷 변경에 취약하다.
- 운영자가 잘못된 파일에 실행할 수 있다.
- 서버 모드라는 사용자 경험과 맞지 않는다.

**결론**

MVP에서는 제외하고, 향후 read-only 진단 도구로만 검토한다.

### 접근 C — UE4SS Lua 서버 런타임 마이그레이션

**개요**

월드 로드 완료 후 길드와 컨테이너 런타임 객체를 찾아 기존 슬롯을 확장하고, 신규 길드 생성 이벤트에도 동일 로직을 적용한다.

**장점**

- 기존·신규 길드 모두 지원한다.
- 게임의 정상 컨테이너 객체와 저장 루틴을 이용할 수 있다.
- 공식 Mod Loader의 서버 설치 규칙으로 배포할 수 있다.
- 동일 마이그레이션 함수를 반복 사용해 멱등성을 확보할 수 있다.

**단점**

- 게임 revision별 클래스·함수 경로 탐색이 필요하다.
- 게임 업데이트 시 후킹 지점이 바뀔 수 있다.
- 잘못된 UObject mutation은 크래시 위험이 있다.
- 모든 플랫폼의 기본 UI가 확장 배열을 처리하는지 검증해야 한다.

**결론**

채택한다.

### 최종 선택

```text
UE4SS Lua 서버 모드
+ revision별 Binding Manifest
+ audit-first 운영 모드
+ 기존·신규 길드 공통 Migration Engine
+ 플랫폼별 호환성 인증
```

---

## 9. 핵심 설계 원칙

1. **Server authoritative:** 슬롯 배열과 아이템 데이터는 서버만 변경한다.
2. **Vanilla protocol only:** 새 네트워크 메시지나 클라이언트 코드를 추가하지 않는다.
3. **Expand only:** 현재 슬롯 수가 목표보다 작을 때만 확장한다.
4. **Preserve identity:** 기존 컨테이너 ID와 아이템 GUID를 바꾸지 않는다.
5. **Append only:** 기존 슬롯은 그대로 두고 끝에 빈 슬롯만 추가한다.
6. **Fail closed:** 검증되지 않은 revision 또는 모호한 바인딩에서는 수정하지 않는다.
7. **Audit first:** 기본 동작은 읽기 전용 진단이며, 운영자가 명시적으로 apply를 선택해야 한다.
8. **Idempotent:** 같은 월드에서 여러 번 실행해도 슬롯 수와 아이템 상태가 추가로 변하지 않는다.
9. **Game thread mutation:** UObject 변경은 게임 스레드에서만 수행한다.
10. **No client dependency:** 클라이언트용 InstallRule과 파일을 제공하지 않는다.
11. **Platform gate:** Steam 성공만으로 정식 릴리스하지 않는다.
12. **No silent fallback:** 심볼을 찾지 못했을 때 이름 유사도로 다른 필드를 수정하지 않는다.
13. **Atomic rollout:** 정상 검증을 통과한 길드만 완료 상태로 기록한다.
14. **Save is source of truth:** sidecar ledger는 감사용이며 실제 슬롯 상태보다 우선하지 않는다.

---

## 10. 시스템 아키텍처

```text
PalServer.exe
    │
    ▼
Official Mod Loader
    │
    ▼
UE4SS
    │
    ▼
CrossplayGuildChestExpander
    ├── RevisionGuard
    ├── WorldReadyDetector
    ├── GuildRepository
    ├── GuildChestResolver
    ├── ContainerSnapshotter
    ├── ContainerResizer
    ├── InvariantValidator
    ├── ReplicationCoordinator
    ├── MigrationLedger
    ├── NewGuildHook
    ├── AdminCommandAdapter
    └── StructuredLogger
```

### 10.1 RevisionGuard

- 실행 중인 Palworld revision을 읽는다.
- 해당 revision에 맞는 Binding Manifest가 있는지 확인한다.
- manifest checksum과 mod release manifest를 검증한다.
- 미지원 revision이면 `audit-only unsupported` 상태로 전환한다.
- 미지원 revision에서 mutation 관련 hook을 등록하지 않는다.

### 10.2 WorldReadyDetector

- 월드 세이브 로드가 완료된 시점을 감지한다.
- 길드 서브시스템과 아이템 컨테이너 서브시스템이 준비됐는지 확인한다.
- 첫 플레이어가 상호작용하기 전에 기존 길드 마이그레이션을 실행한다.
- 정확한 이벤트 hook이 없으면 제한된 재시도 방식으로 준비 상태를 확인한다.
- 무한 polling을 사용하지 않는다.

### 10.3 GuildRepository

- 현재 월드의 길드 목록을 조회한다.
- 길드 ID, 길드명, 길드 상자 Container ID를 반환한다.
- 길드 상자 ID가 없는 길드는 `not-initialized`로 분류한다.
- 동일 Container ID를 둘 이상의 길드가 참조하면 치명적 오류로 분류한다.

### 10.4 GuildChestResolver

- 길드가 보유한 Container ID로 실제 Item Container UObject를 찾는다.
- 컨테이너의 owner guild ID를 길드 ID와 교차 검증한다.
- 클래스명 또는 오브젝트 이름만으로 대상을 추정하지 않는다.
- 일반 상자와 길드 상자를 구분한다.

### 10.5 ContainerSnapshotter

변경 전후 다음 데이터를 수집한다.

- container ID
- owner guild ID
- slot count
- occupied slot count
- 각 슬롯 index
- item static ID
- item dynamic GUID
- item quantity
- item durability 또는 인스턴스 메타데이터 해시
- 전체 아이템 수량 합
- 전체 아이템 fingerprint

### 10.6 ContainerResizer

- 가능한 경우 Palworld가 제공하는 공식적인 컨테이너 resize 또는 slot append UFunction을 호출한다.
- 공식 함수가 없을 때만 슬롯 배열 끝에 빈 슬롯 객체를 추가한다.
- 기존 슬롯 객체를 재생성하지 않는다.
- 슬롯 index를 재정렬하지 않는다.
- 빈 슬롯 생성도 게임 내부 factory가 있으면 이를 우선 사용한다.
- 목표 슬롯 수를 넘는 컨테이너는 그대로 둔다.

### 10.7 InvariantValidator

변경 후 다음 불변조건을 확인한다.

```text
after.container_id == before.container_id
after.owner_guild_id == before.owner_guild_id
after.slot_count == target_slots
after.occupied_slot_count == before.occupied_slot_count
after.total_item_quantity == before.total_item_quantity
after.item_fingerprint == before.item_fingerprint
기존 슬롯의 item GUID와 index가 모두 동일
새 슬롯은 모두 empty
```

불변조건이 하나라도 실패하면 해당 길드 마이그레이션을 실패 처리하고 오류 정보를 기록한다.

### 10.8 ReplicationCoordinator

- 기존 Palworld replication 경로만 사용한다.
- 신규 커스텀 RPC를 만들지 않는다.
- 가능한 경우 컨테이너의 기존 dirty/replicate 함수를 호출한다.
- 전체 월드 강제 복제를 호출하지 않는다.
- 변경 직후 접속한 클라이언트와 이후 접속한 클라이언트가 동일 슬롯 수를 받는지 검증한다.

### 10.9 MigrationLedger

sidecar 파일에 다음을 저장한다.

```json
{
  "ledger_version": "1.0",
  "world_id": "...",
  "game_revision": 12345,
  "mod_version": "1.0.0",
  "target_slots": 358,
  "guilds": [
    {
      "guild_id": "...",
      "container_id": "...",
      "before_slots": 54,
      "after_slots": 358,
      "before_fingerprint": "...",
      "after_fingerprint": "...",
      "status": "completed",
      "completed_at": "..."
    }
  ]
}
```

ledger는 감사와 운영자 확인을 위한 데이터다. 실제 컨테이너 상태와 ledger가 다르면 실제 상태를 다시 검사한다.

### 10.10 NewGuildHook

- 길드 생성 완료 또는 길드 상자 컨테이너 초기화 완료 UFunction을 후킹한다.
- 컨테이너가 생성되고 비어 있는 것을 확인한 뒤 마이그레이션한다.
- 이벤트 hook이 불가능한 revision에서는 저빈도 rescan fallback을 허용한다.
- fallback 기본 주기는 60초이며, 변경되지 않은 길드는 캐시로 건너뛴다.
- 신규 길드 적용에도 동일 `ContainerResizer`와 `InvariantValidator`를 사용한다.

---

## 11. Binding Manifest

게임 내부 심볼을 코드에 분산 하드코딩하지 않는다.

```json
{
  "manifest_version": "1.0",
  "game_revision": 12345,
  "world_ready_function": "/Script/...",
  "guild_manager_class": "PalGuildManager",
  "guild_list_property": "Guilds",
  "guild_id_property": "GuildId",
  "guild_chest_container_id_property": "GuildChestContainerId",
  "container_manager_class": "PalItemContainerManager",
  "find_container_function": "/Script/...",
  "slot_array_property": "Slots",
  "resize_function": "/Script/...",
  "mark_dirty_function": "/Script/...",
  "replicate_function": "/Script/...",
  "new_guild_function": "/Script/...",
  "tested_platform_matrix": [
    "steam",
    "xbox",
    "ps5",
    "mac"
  ]
}
```

### 요구사항

- release build에는 최소 하나의 정확한 revision manifest가 포함되어야 한다.
- manifest는 발견 과정과 실제 런타임 테스트를 통해 생성한다.
- manifest에 지정된 모든 클래스·프로퍼티·함수가 예상 타입인지 시작 시 검증한다.
- revision이 일치해도 타입 서명이 다르면 mutation을 금지한다.
- manifest 자동 추론은 제공하지 않는다.
- 새 revision 지원은 새 manifest와 플랫폼 재인증을 요구한다.

---

## 12. 마이그레이션 상태 머신

```text
DISABLED
  └─ operator enables mod
       ↓
PREFLIGHT
  ├─ unsupported revision → UNSUPPORTED
  ├─ invalid bindings → BLOCKED
  ├─ world not ready → WAITING
  └─ ready → AUDIT
       ↓
AUDIT
  ├─ conflicts found → BLOCKED
  ├─ backup approval missing → AWAITING_APPROVAL
  ├─ mode=audit → AUDIT_COMPLETE
  └─ mode=apply → APPLYING
       ↓
APPLYING
  ├─ invariant failure → FAILED
  ├─ all guilds complete → VALIDATING
  └─ per-guild result recorded
       ↓
VALIDATING
  ├─ save/reload verification failure → FAILED
  └─ success → COMPLETE
```

### 상태 원칙

- `BLOCKED`, `UNSUPPORTED`, `FAILED` 상태에서는 추가 mutation을 하지 않는다.
- 한 길드에서 치명적 불변조건 위반이 발생하면 기본값으로 전체 작업을 중단한다.
- `continue_on_guild_error=true`는 개발 테스트에서만 허용하며 정식 기본값은 `false`다.
- `COMPLETE` 이후에도 서버 시작마다 read-only drift 검사를 수행한다.

---

## 13. 기능 요구사항

### 13.1 Preflight 및 진단

| ID | 우선순위 | 요구사항 | 인수 조건 |
|---|---:|---|---|
| FR-001 | P0 | 게임 revision을 확인한다. | 미지원 revision에서 슬롯 mutation이 발생하지 않는다. |
| FR-002 | P0 | Binding Manifest의 심볼과 타입을 검증한다. | 하나라도 불일치하면 `BLOCKED`로 전환한다. |
| FR-003 | P0 | 길드·컨테이너 목록을 read-only로 스캔한다. | 길드별 현재 슬롯 수와 상태가 보고된다. |
| FR-004 | P0 | 중복 Container ID를 감지한다. | 중복이 있으면 apply가 금지된다. |
| FR-005 | P0 | owner guild ID를 교차 검증한다. | 소유자 불일치 컨테이너는 수정되지 않는다. |
| FR-006 | P0 | 기본 모드를 `audit`로 제공한다. | 설치 직후 자동 mutation이 일어나지 않는다. |
| FR-007 | P0 | 운영자 승인 없이 apply하지 않는다. | 설정의 승인 토큰이 없으면 `AWAITING_APPROVAL`이다. |

### 13.2 기존 길드 마이그레이션

| ID | 우선순위 | 요구사항 | 인수 조건 |
|---|---:|---|---|
| FR-010 | P0 | 현재 슬롯이 목표보다 작은 길드 상자만 확장한다. | 54칸은 확장되고 358칸 이상은 no-op다. |
| FR-011 | P0 | 기존 슬롯을 유지하고 빈 슬롯을 끝에 추가한다. | 기존 item GUID와 index가 동일하다. |
| FR-012 | P0 | 목표 슬롯 수를 설정으로 지정한다. | 인증된 범위를 벗어나면 시작이 차단된다. |
| FR-013 | P0 | 모든 기존 길드를 처리한다. | audit에서 발견된 정상 길드가 결과 보고서에 모두 존재한다. |
| FR-014 | P0 | 변경 후 불변조건을 검증한다. | 수량·GUID·소유권 차이가 0이다. |
| FR-015 | P0 | 반복 실행이 멱등적이어야 한다. | 두 번째 실행에서 mutation 0건이다. |
| FR-016 | P0 | 일반 컨테이너를 수정하지 않는다. | 길드 상자 외 Container ID 변경 0건이다. |
| FR-017 | P1 | 특정 길드만 include/exclude할 수 있다. | guild ID allow/deny list가 적용된다. |

### 13.3 신규 길드

| ID | 우선순위 | 요구사항 | 인수 조건 |
|---|---:|---|---|
| FR-020 | P0 | 신규 길드 상자 생성 후 목표 슬롯을 적용한다. | 신규 길드가 최초 사용 전에 인증 슬롯 수를 가진다. |
| FR-021 | P0 | 기존 길드와 같은 마이그레이션 엔진을 사용한다. | 별도 슬롯 조작 코드가 존재하지 않는다. |
| FR-022 | P0 | 비어 있지 않은 예상 밖 신규 컨테이너도 불변조건 검증 후 처리한다. | 아이템 변화가 없을 때만 완료된다. |
| FR-023 | P1 | hook 실패 시 제한된 rescan fallback을 제공한다. | fallback이 서버 틱을 지속적으로 점유하지 않는다. |

### 13.4 크로스플랫폼

| ID | 우선순위 | 요구사항 | 인수 조건 |
|---|---:|---|---|
| FR-030 | P0 | 클라이언트 설치 없이 작동한다. | PS5, Steam Windows, macOS의 mod-free 클라이언트가 접속한다. |
| FR-031 | P0 | 기본 Palworld UI만 사용한다. | custom UI asset 또는 client script가 패키지에 없다. |
| FR-032 | P0 | 플랫폼 간 동일 슬롯 상태를 제공한다. | 동일 시점 스냅샷이 모든 플랫폼에서 일치한다. |
| FR-033 | P0 | PS5 DualSense로 마지막 슬롯에 접근할 수 있어야 한다. | PS5에서 인증 대상의 마지막 슬롯 입출고가 가능하다. |
| FR-034 | P0 | 동시 접근 시 일관성을 유지한다. | 서로 다른 플랫폼 두 사용자의 입출고가 유실되지 않는다. |
| FR-035 | P0 | PS5 또는 macOS 미인증 revision은 정식 배포하지 않는다. | release metadata에 Steam Windows, PS5, macOS 인증 결과가 있다. |

| FR-036 | P0 | PS5 접속 전제조건을 진단한다. | `-publiclobby`와 `CrossplayPlatforms`의 PS5 포함 여부가 report에 표시된다. |
| FR-037 | P0 | PS5 실패 시 안전 슬롯으로 낮춘다. | 클라이언트 수정 없이 마지막 인증값을 선택한다. |
| FR-038 | P1 | Xbox 지원을 필수 범위와 분리한다. | 미인증 Xbox가 Steam Windows·PS5·macOS 릴리스를 차단하지 않는다. |

### 13.5 운영 명령

초기 버전은 게임 채팅 명령보다 서버 콘솔·로그 중심으로 제공한다. 관리자 채팅 명령은 인증 방식이 확정된 후 추가할 수 있다.

필수 운영 기능:

```text
cgce status
cgce audit
cgce apply
cgce guilds
cgce verify
cgce export-report
```

요구사항:

- `status`: revision, mode, target slots, migration state를 출력한다.
- `audit`: read-only 스캔을 실행한다.
- `apply`: 승인 토큰과 preflight 성공 상태가 있을 때만 실행한다.
- `guilds`: 길드별 상태를 출력한다.
- `verify`: 현재 컨테이너와 ledger를 대조한다.
- `export-report`: JSON 보고서 경로를 출력한다.
- 명령은 게임 클라이언트에 새 UI를 요구하지 않는다.
- 원격 명령 노출은 MVP 범위에서 제외한다.

---

## 14. 설정 명세

파일:

```text
Mods/NativeMods/UE4SS/Mods/CrossplayGuildChestExpander/config.json
```

예시:

```json
{
  "config_version": "1.1",
  "deployment_profile": "windows-dedicated-ps5-macos-required",
  "mode": "audit",
  "requested_target_slots": 358,
  "certified_target_slots": [54],
  "certification_mode": false,
  "required_clients": ["SteamWindows", "PS5", "Mac"],
  "optional_clients": ["Xbox"],
  "expand_only": true,
  "require_operator_approval": true,
  "approval_token": "",
  "fail_fast": true,
  "include_guild_ids": [],
  "exclude_guild_ids": [],
  "new_guild_hook_enabled": true,
  "fallback_rescan_enabled": true,
  "fallback_rescan_seconds": 60,
  "verify_on_startup": true,
  "write_migration_ledger": true,
  "log_level": "INFO",
  "structured_log": true
}
```

### 설정 검증

- 운영 모드에서는 `requested_target_slots`가 `certified_target_slots`에 포함되어야 한다.
- `certification_mode=true`는 테스트 월드 allow-list와 명시적 승인 토큰이 있을 때만 미인증 후보 슬롯 수를 허용한다.
- 정식 기본값의 `certified_target_slots`는 `[54]`에서 시작하며 실제 Steam Windows·PS5·macOS 테스트를 통과한 값만 추가한다.
- `deployment_profile`은 정식 1.x에서 `windows-dedicated-ps5-macos-required`로 고정한다.
- `required_clients`에서 `PS5` 또는 `Mac`을 제거할 수 없다.
- `expand_only`는 정식 빌드에서 `false`로 설정할 수 없다.
- `mode=apply`이고 승인이 필요한 경우 유효한 approval token이 있어야 한다.
- include와 exclude에 같은 guild ID가 있으면 시작을 차단한다.
- fallback rescan 최소값은 30초다.
- 알 수 없는 설정 키는 경고가 아니라 오류로 처리한다.
- 설정 파싱 실패 시 audit도 실행하지 않고 `BLOCKED`로 전환한다.

### 운영자 승인 토큰

audit 완료 후 생성되는 report의 checksum을 사용한다.

```text
approval_token = SHA-256(
  world_id
  + game_revision
  + audit_report_checksum
  + requested_target_slots
  + deployment_profile
)
```

운영자가 audit report와 백업을 확인한 뒤 이 값을 config에 넣어야 apply가 가능하다. 이는 실수로 모드를 설치하자마자 세이브를 변경하는 것을 방지한다.

---

## 15. 마이그레이션 알고리즘

### 15.1 기존 길드

```text
1. revision과 bindings 검증
2. 월드 준비 확인
3. 온라인 플레이어가 길드 상자를 사용 중인지 확인
4. 모든 길드 조회
5. 길드별 chest container ID 조회
6. owner guild ID 교차 검증
7. before snapshot 생성
8. current_slots >= target_slots이면 no-op
9. current_slots < target_slots이면 빈 슬롯 append
10. dirty/replication 함수 호출
11. after snapshot 생성
12. 불변조건 검증
13. ledger 기록
14. 모든 길드 완료 후 save 경로 반영 확인
```

### 15.2 신규 길드

```text
1. 길드 생성 완료 이벤트 수신
2. chest container ID가 초기화될 때까지 제한된 재시도
3. container owner 확인
4. 빈 상자 여부 확인
5. 기존 마이그레이션 함수 호출
6. 불변조건 검증
7. ledger 기록
```

### 15.3 canonical 부모 순서와 같은 개념은 사용하지 않음

길드와 컨테이너 관계는 방향성이 있으므로 `guild_id → container_id`를 고정 관계로 사용한다. 컨테이너 이름 검색이나 배열 위치에 의존하지 않는다.

### 15.4 슬롯 추가 방식 우선순위

```text
1. 게임 내부 public/protected resize UFunction
2. 게임 내부 add-empty-slot UFunction 반복 호출
3. 검증된 TArray append
4. 그 외 방식은 지원하지 않음
```

3번을 사용하는 release는 모든 플랫폼에서 별도 회귀 테스트를 요구한다.

---

## 16. 세이브 안전성

### 16.1 필수 불변조건

- 기존 슬롯 수만 증가한다.
- 기존 슬롯 index는 변하지 않는다.
- 기존 item static ID는 변하지 않는다.
- 기존 item dynamic GUID는 변하지 않는다.
- 기존 수량은 변하지 않는다.
- 기존 내구도·품질·인스턴스 데이터 해시는 변하지 않는다.
- 컨테이너 ID는 변하지 않는다.
- owner guild ID는 변하지 않는다.
- 새 슬롯은 empty 상태다.
- 길드 외 컨테이너는 수정하지 않는다.

### 16.2 적용 시점

- 기존 길드 마이그레이션은 서버 시작 직후, 첫 플레이어의 길드 상자 상호작용 전에 실행한다.
- 상자를 사용 중인 플레이어가 있으면 apply를 거부한다.
- 런타임 수동 apply는 온라인 플레이어가 0명이거나 모든 길드 상자가 닫힌 상태에서만 허용한다.
- 신규 길드 상자는 생성 직후 비어 있을 때 확장한다.

### 16.3 백업 정책

모드는 자체적으로 원본 월드 세이브를 대체 백업이라고 주장하지 않는다.

운영 절차:

1. 서버 정상 종료
2. 월드 전체 백업
3. audit 모드 실행
4. report 검토
5. apply 모드 실행
6. 서버 저장 및 종료
7. 재시작 후 verify
8. 플랫폼 인증 smoke test

정식 README에는 특정 `.sav` 하나가 아니라 월드 디렉터리 전체를 같은 시점으로 백업하도록 명시한다.

### 16.4 실패 후 처리

- mutation 도중 불변조건 실패 시 이후 길드 처리를 중단한다.
- 메모리 상태를 되돌릴 수 있는 검증된 API가 있으면 해당 길드에 한해 복구한다.
- 안전한 런타임 복구가 보장되지 않으면 서버를 정상 저장하지 않고 운영자에게 종료·백업 복원을 요구한다.
- 자동으로 손상 가능 상태를 저장하지 않는다.
- 치명적 실패 후 정상 운영을 계속하는 옵션은 제공하지 않는다.

---

## 17. 복제와 UI 호환 전략

### 17.1 원칙

- 클라이언트가 이미 이해하는 Item Container 구조만 확장한다.
- 슬롯 배열 길이 이외의 데이터 포맷을 바꾸지 않는다.
- custom widget, custom scrolling, custom input을 추가하지 않는다.
- 클라이언트 플랫폼을 식별해 별도 응답을 보내지 않는다.
- 모든 플랫폼에 동일한 서버 상태를 복제한다.

### 17.2 핵심 검증 질문

다음은 구현 전 확정 사실이 아니라 테스트로 검증해야 하는 릴리스 게이트다.

- vanilla UI가 358개 슬롯의 동적 배열을 렌더링하는가?
- PS5 DualSense의 D-pad·아날로그 스틱 포커스가 마지막 행까지 이동하는가?
- PS5, Steam Windows, macOS의 스크롤·정렬 결과가 동일한가?
- 상자 정렬 또는 아이템 일괄 이동이 전체 슬롯을 처리하는가?
- 네트워크 초기 동기화 패킷 크기가 연결 안정성에 영향을 주지 않는가?
- 358칸이 모두 채워진 상태에서 재접속 시간이 허용 범위 내인가?
- 필수 플랫폼 사용자들이 같은 슬롯을 동시에 조작할 때 서버 권위가 유지되는가?

### 17.3 인증 슬롯 수

릴리스는 다음 순서로 인증한다.

```text
54 → 120 → 256 → 358
```

각 단계에서 Steam Windows, PS5, macOS 테스트를 모두 통과해야 다음 단계로 진행한다. 358이 실패하면 세 필수 클라이언트에서 성공한 마지막 값을 제품 기본값으로 사용한다.


### 17.4 PS5 전용 호환 원칙

PS5는 클라이언트 측 모드나 진단 스크립트를 설치할 수 없는 필수 참가 플랫폼이므로 다음 원칙을 적용한다.

- PS5에서 발생한 UI 문제를 커스텀 위젯으로 수정하지 않는다.
- PS5만을 위한 별도 슬롯 배열 또는 별도 replication payload를 만들지 않는다.
- PS5에서 마지막 슬롯에 접근할 수 없으면 해당 슬롯 수는 미인증이다.
- PS5 화면 검증은 서버 로그, 테스트 영상, 슬롯별 입출고 결과를 조합해 증빙한다.
- PS5 테스트 계정은 운영 길드와 분리된 인증용 길드에서 먼저 검증한다.
- PS5가 상자를 열고 있는 동안 기존 길드 수동 마이그레이션을 실행하지 않는다.
- PS5 suspend/resume 이후 세션이 불안정하면 완전 재접속 시나리오를 별도로 검증한다.
- PS5 클라이언트 업데이트와 서버 버전이 다르면 호환 테스트를 수행하지 않고 버전을 맞춘다.

### 17.5 Community Server 연결 검증

PS5 지원 빌드는 슬롯 기능뿐 아니라 다음 접속 전제도 release report에 포함한다.

```text
-publiclobby: present
CrossplayPlatforms: contains PS5
PublicPort: matches advertised UDP port
Server visible in PS5 Community Server list: yes
PS5 join test: passed
```

이 검증 실패는 컨테이너 데이터 손상을 의미하지 않으므로 migration engine을 자동 롤백하지 않는다. 다만 제품을 `PS5 compatible`로 표기할 수 없다.

---

## 18. 패키징과 설치

### 18.1 공식 Mod Loader 패키지

```text
CrossplayGuildChestExpander/
├── Info.json
├── thumbnail.png
├── README.md
├── CHANGELOG.md
├── Scripts/
│   ├── main.lua
│   ├── revision_guard.lua
│   ├── world_ready.lua
│   ├── guild_repository.lua
│   ├── container_resolver.lua
│   ├── snapshot.lua
│   ├── resizer.lua
│   ├── validator.lua
│   ├── replication.lua
│   ├── ledger.lua
│   ├── logger.lua
│   └── bindings/
│       └── <revision>.json
└── config/
    └── config.default.json
```

### 18.2 `Info.json` 예시

```json
{
  "ModName": "Crossplay Guild Chest Expander",
  "PackageName": "CrossplayGuildChestExpander",
  "Thumbnail": "thumbnail.png",
  "Version": "1.0.0",
  "DebugMode": false,
  "MinRevision": 0,
  "Author": "Project Maintainer",
  "Dependencies": [
    "UE4SS"
  ],
  "Tags": [
    "UE4SS",
    "Utilities",
    "Gameplay"
  ],
  "InstallRule": [
    {
      "Type": "Lua",
      "IsServer": true,
      "Targets": [
        "./Scripts"
      ]
    }
  ]
}
```

릴리스 빌드는 `MinRevision=0`을 허용하지 않는다. 인증한 최소 게임 revision을 빌드 단계에서 주입하고, 값이 없으면 패키징을 실패시킨다.

### 18.3 클라이언트 파일 금지

정식 패키지에는 다음이 없어야 한다.

- `IsServer`가 없는 Lua InstallRule
- LogicMods
- client PAK
- custom UI asset
- input binding
- texture 또는 widget
- 클라이언트 DLL
- 플랫폼별 설치 파일

### 18.4 서버 설치

운영자는 공식 서버 모드 절차에 따라 Workshop 패키지를 서버에 배치하고 `PalModSettings.ini`의 `ActiveModList`에 PackageName을 추가한다. 서버 재시작 후 공식 Mod Loader가 `Info.json`의 서버 설치 규칙에 따라 파일을 배포한다.

---

## 19. 업데이트와 제거

### 19.1 업데이트

- `Info.json`의 Version을 변경한다.
- 새 게임 revision은 새 Binding Manifest와 전체 플랫폼 인증이 필요하다.
- revision만 추가하고 알고리즘이 같아도 minor release로 배포한다.
- 슬롯 데이터 포맷을 바꾸는 업데이트는 major release로 배포한다.
- 업데이트 전 audit와 백업 절차를 README에 반복 명시한다.

### 19.2 제거

모드 제거 시 이미 저장된 358칸을 자동 축소하지 않는다.

이유:

- 54칸 이후 슬롯에 아이템이 있을 수 있다.
- 축소 시 유실·중복·접근 불가가 발생할 수 있다.
- vanilla 서버가 확장된 슬롯 배열을 계속 저장·복제할 수 있는지는 릴리스 테스트 결과로 명시해야 한다.

제거 절차:

1. 모든 아이템을 기본 슬롯 범위로 이동하지 않아도 유지되는지 인증 결과 확인
2. 월드 전체 백업
3. mod 비활성화
4. 서버 재시작
5. Steam Windows·PS5·macOS smoke test
6. 문제가 있으면 모드 재활성화 또는 백업 복원

### 19.3 축소 도구

축소는 별도의 위험한 마이그레이션 제품으로 분리하며 본 프로젝트에는 포함하지 않는다.

---

## 20. 오류 처리

### 오류 등급

| 등급 | 예 | 동작 |
|---|---|---|
| INFO | 이미 358칸 | no-op 기록 |
| WARNING | 한국어 길드명 로그 인코딩 문제 | 진행 가능 |
| BLOCKING | 미지원 revision | mutation 금지 |
| BLOCKING | owner guild 불일치 | mutation 금지 |
| CRITICAL | item fingerprint 변경 | 즉시 중단 |
| CRITICAL | duplicate Container ID | 전체 apply 중단 |
| CRITICAL | slot append 후 수량 변화 | 저장 금지 안내 |

### 오류 메시지 형식

```text
[CGCE-VAL-004] Item fingerprint changed after resize
world_id=<id>
guild_id=<id>
container_id=<id>
before_slots=54
after_slots=358
before_fingerprint=<hash>
after_fingerprint=<hash>
action=STOP_SERVER_AND_RESTORE_BACKUP
report=<path>
```

### Fail-safe

- 예상 타입과 실제 타입이 다르면 nil fallback으로 계속하지 않는다.
- Lua exception을 catch한 뒤 다른 길드로 무조건 진행하지 않는다.
- report 저장 실패도 apply 중단 사유다.
- 로그 파일에 비밀번호나 관리자 토큰을 기록하지 않는다.

---

## 21. 로깅과 관측성

### 21.1 로그

텍스트 로그와 JSON Lines를 지원한다.

```json
{
  "timestamp": "2026-07-22T00:00:00Z",
  "level": "INFO",
  "event": "guild_chest_migrated",
  "world_id": "...",
  "guild_id": "...",
  "container_id": "...",
  "before_slots": 54,
  "after_slots": 358,
  "occupied_slots": 27,
  "duration_ms": 18,
  "game_revision": 12345,
  "mod_version": "1.0.0"
}
```

### 21.2 지표

- discovered guild count
- eligible guild count
- migrated guild count
- no-op guild count
- blocked guild count
- failed guild count
- migration duration
- startup delay added
- rescan count
- hook invocation count
- invariant failure count
- replication request count
- platform certification results

### 21.3 로그 제한

- 정상 상태에서 슬롯별 로그를 출력하지 않는다.
- debug 모드에서만 슬롯 fingerprint 상세를 출력한다.
- 한 이벤트의 로그 크기를 제한한다.
- 길드명에 제어문자가 있어도 로그 포맷을 깨지 않게 escape한다.

---

## 22. 성능 요구사항

다음은 제품 수용 목표다.

| 항목 | 목표 |
|---|---:|
| 정상 시작 시 steady-state CPU 증가 | 1%p 이하 |
| steady-state 메모리 증가 | 100MB 이하 |
| 100개 길드 audit | 5초 이하 |
| 100개 빈 길드 상자 migration | 10초 이하 |
| 54→358 단일 길드 migration | 100ms 이하 |
| 완료 후 전체 periodic scan | 기본 비활성 또는 60초 이상 |
| 이미 완료된 길드 재검사 | O(1) 캐시 확인 후 필요 시 실제 상태 확인 |
| 서버 저장 시간 증가 | 동일 월드 baseline 대비 15% 이하 |
| 길드 상자 열기 응답 지연 | 54칸 baseline 대비 p95 +300ms 이하 |
| 클라이언트 재접속 시간 증가 | baseline 대비 10% 이하 |

테스트 환경과 월드 크기는 release report에 기록한다. 목표를 넘으면 기능이 정상이어도 성능 경고 릴리스로 분류하지 않고 정식 배포를 보류한다.

---

## 23. 보안 요구사항

- 외부 네트워크 포트를 열지 않는다.
- REST API 또는 웹 서버를 포함하지 않는다.
- 원격 코드 다운로드를 하지 않는다.
- Binding Manifest를 인터넷에서 자동 다운로드하지 않는다.
- package 내 파일만 로드한다.
- config 경로를 이용한 directory traversal을 허용하지 않는다.
- 로그에 AdminPassword, token, 사용자 인증 정보를 기록하지 않는다.
- operator approval token은 world·revision·audit report에 바인딩한다.
- 채팅 명령을 추가할 경우 PalDefender와 무관한 별도 관리자 인증 없이 공개하지 않는다.
- 외부 입력으로 UFunction 이름을 임의 실행하지 않는다.
- Binding Manifest의 허용 필드만 읽는다.

---

## 24. 호환성 요구사항

### 24.1 다른 모드

지원 원칙:

- 같은 길드 상자 슬롯 배열을 수정하는 모드와 동시 사용하지 않는다.
- 일반 보관함 확장 모드는 별도 컨테이너만 수정하는 것이 검증된 경우에만 조건부 지원한다.
- PalDefender는 길드 상자 구조를 수정하지 않는 버전에서 조건부 지원한다.
- PalSchema 기반 358 슬롯 모드와 동시 사용은 비지원한다.
- mod list와 package version을 report에 기록한다.

### 24.2 충돌 감지

가능한 경우 다음을 감지한다.

- target slot 기본값을 변경하는 다른 패키지
- 동일 ContainerResizer hook
- 이미 예상하지 않은 슬롯 수
- container class가 다른 모드로 대체됨
- slot 객체 타입 불일치

감지할 수 없는 충돌 가능성은 README에 명시한다.

### 24.3 게임 업데이트

- 게임 revision이 달라지면 기존 Binding Manifest를 재사용하지 않는다.
- 새 revision에서 audit-only smoke test를 먼저 수행한다.
- class dump와 runtime object inspection을 통해 심볼을 다시 확인한다.
- Steam Windows, PS5, macOS 인증 전 정식 compatible 표시를 하지 않는다. Xbox 표기는 별도 인증 후 추가한다.

---

## 25. 테스트 전략

### 25.1 단위 테스트

Lua 비게임 로직을 가능한 범위에서 분리해 테스트한다.

- config validation
- approval token
- include/exclude rule
- migration state machine
- ledger serialization
- fingerprint calculation
- no-op condition
- expand-only condition
- error severity mapping

### 25.2 Synthetic UObject Adapter 테스트

실제 UObject 대신 adapter를 사용한다.

- 54칸 빈 상자 → 358칸
- 54칸 30개 아이템 → 아이템 동일
- 358칸 → no-op
- 400칸 → no-op
- owner mismatch → blocked
- duplicate container → blocked
- append 중 exception → failed
- after fingerprint mismatch → critical

### 25.3 실제 서버 통합 테스트

#### 월드 구성

- 기존 길드 3개
- 신규 길드 생성 가능 계정
- 54칸 길드 상자
- 빈 상자, 일부 사용 상자, 가득 찬 상자
- stack item, 장비, 내구도 아이템, 고유 instance 아이템
- 한글·영문·특수문자 길드명

#### 필수 케이스

1. audit-only 실행
2. apply 승인 누락
3. 정상 apply
4. 서버 저장
5. 서버 재시작
6. mod 제거 후 재시작
7. mod 재설치
8. 신규 길드 생성
9. 길드 탈퇴·재가입
10. 길드장 변경
11. 동시 상자 접근
12. 서버 강제 종료 후 공식 백업 복원

### 25.4 플랫폼 인증 테스트

Tier 0인 Steam Windows, PS5, macOS에서 동일한 데이터 무결성 체크리스트를 수행하되, PS5에는 별도 컨트롤러·커뮤니티 서버 검증을 추가한다.

#### 기본 UI

- 상자 열기
- 슬롯 수 확인
- 빠른 스크롤
- 마지막 슬롯 선택
- 마지막 슬롯 입출고
- 전체 슬롯 정렬
- 상자 닫기·재열기

#### PS5 커뮤니티 서버 접속

- 서버를 `-publiclobby`로 실행
- PS5 커뮤니티 서버 목록에서 이름 검색
- 서버 암호가 있으면 정상 입력
- 길드 가입
- 상자 테스트 후 로그아웃
- 서버 재시작 후 재접속
- 앱 완전 종료 후 재접속

#### PS5 DualSense

- D-pad 및 스틱 이동
- 행 경계 이동
- 마지막 행 포커스
- 슬롯 tooltip
- 아이템 분할
- 빠른 이동 버튼

#### 네트워크

- 다른 플랫폼 사용자와 동시 열기
- 동일 아이템에 동시 접근
- 고지연 네트워크
- 일시적 패킷 손실
- 재접속
- 서버 재시작

#### Steam Windows ↔ PS5 교차 테스트

- 같은 길드 가입
- 같은 길드 상자를 동시에 열기
- 서로 다른 슬롯에 동시 입고
- 같은 스택에 순차 입출고
- PS5 마지막 슬롯 입고 후 Steam에서 확인
- Steam 마지막 슬롯 입고 후 PS5에서 확인
- 자동 저장 직전·직후 상태 확인
- 한쪽 연결 종료 후 다른 쪽 상태 확인

#### macOS 필수 인증

- 순정 macOS 클라이언트로 서버 검색·접속 및 재접속
- 길드 가입 후 길드 상자 열기
- 첫 슬롯과 인증 대상의 마지막 슬롯 접근
- 아이템 넣기·꺼내기, 스택 분할, 빠른 이동 및 정렬
- 상자 닫기·재열기와 클라이언트 완전 종료 후 재접속
- 서버 재시작 후 슬롯 수와 마지막 슬롯 아이템 상태 유지
- Steam Windows·PS5와 같은 길드 상자 동시 접근
- 마지막 슬롯 아이템의 표시·수량·GUID 보존
- UI 프리징·클라이언트 크래시·네트워크 연결 해제 0건

### 25.5 부하 테스트

- 32명 접속
- 10개 길드
- 각 길드 상자 358칸
- 슬롯 80% 채움
- 8명이 동시에 각기 다른 길드 상자 사용
- 4명이 같은 길드 상자 동시 사용
- 자동 저장 시 상자 조작
- 6시간 soak test

### 25.6 회귀 테스트

게임 revision별로 다음을 보관한다.

- Binding Manifest
- audit report schema
- 길드·컨테이너 snapshot hash
- 플랫폼 인증 결과
- 성능 baseline
- mod compatibility list

실제 게임 세이브는 공개 저장소에 커밋하지 않는다.

---

## 26. 제품 수용 테스트

### AT-001 — 기존 길드 확장

```text
Given 54칸 길드 상자에 30개 슬롯의 아이템이 있고
When audit 승인 후 apply를 실행하면
Then 슬롯 수는 인증된 목표값이 되고
And 기존 슬롯 index·GUID·수량·소유권은 동일하다.
```

### AT-002 — 멱등성

```text
Given 이미 목표 슬롯 수인 상자가 있고
When 서버를 세 번 재시작하면
Then 추가 mutation은 0건이고
And fingerprint는 동일하다.
```

### AT-003 — 신규 길드

```text
Given mod가 정상 실행 중이고
When 신규 길드를 생성하면
Then 최초 길드 상자 사용 전에 인증 슬롯 수가 적용된다.
```

### AT-004 — 일반 상자 비변경

```text
Given 월드에 일반 상자와 길드 상자가 있을 때
When migration을 실행하면
Then 일반 상자의 slot count와 fingerprint는 변경되지 않는다.
```

### AT-005 — 미지원 revision

```text
Given Binding Manifest가 없는 game revision일 때
When 서버를 시작하면
Then mod는 UNSUPPORTED 상태가 되고
And UObject mutation은 0건이다.
```

### AT-006 — owner mismatch

```text
Given guild ID와 container owner가 다를 때
When audit를 실행하면
Then apply가 차단되고
And 충돌 대상이 report에 기록된다.
```

### AT-007 — item 불변성 실패

```text
Given resize 이후 item fingerprint가 달라졌을 때
When validator가 실행되면
Then 전체 작업을 중단하고
And 저장 금지 및 백업 복원 안내를 출력한다.
```

### AT-008 — Steam 클라이언트

```text
Given 수정되지 않은 Steam 클라이언트일 때
When 확장된 상자를 사용하면
Then 마지막 슬롯까지 정상 입출고할 수 있다.
```

### AT-009 — PS5 커뮤니티 서버 접속

```text
Given Windows 서버가 `-publiclobby`로 실행되고 CrossplayPlatforms에 PS5가 포함될 때
When 수정되지 않은 PS5 클라이언트가 커뮤니티 서버 목록에서 접속하면
Then 길드 상자를 열고 인증 대상의 마지막 슬롯까지 DualSense로 정상 입출고할 수 있다.
```

### AT-010 — PS5 재접속·재시작

```text
Given PS5가 확장 상자를 사용한 이력이 있을 때
When PS5 앱 완전 종료, 서버 재시작, PS5 재접속을 수행하면
Then 슬롯 수와 마지막 슬롯 아이템 상태가 유지되고 UI 크래시가 없어야 한다.
```

### AT-011 — Steam Windows 기준 클라이언트

```text
Given 수정되지 않은 Steam Windows 클라이언트일 때
When 확장된 상자를 사용하면
Then 슬롯 상태와 item fingerprint가 PS5에서 관찰한 결과와 일치한다.
```

### AT-012 — 교차 플랫폼 동시 접근

```text
Given Steam Windows, PS5, macOS 사용자가 같은 상자를 열고 있을 때
When 서로 다른 슬롯에 아이템을 넣고 꺼내면
Then 서버 저장 결과에 모든 작업이 정확히 반영된다.
```

### AT-013 — mod 제거

```text
Given 마이그레이션 완료 후 월드가 정상 저장되었을 때
When mod를 비활성화하고 서버를 재시작하면
Then 인증된 플랫폼에서 상자를 열 수 있고
And 아이템 데이터가 유지된다.
```

### AT-014 — 승인 없는 apply 차단

```text
Given mode=apply지만 approval token이 없을 때
When 서버를 시작하면
Then mutation 없이 AWAITING_APPROVAL 상태가 된다.
```


### AT-015 — PS5 설정 누락 진단

```text
Given CrossplayPlatforms에 PS5가 없거나 실행 인자에 -publiclobby가 없을 때
When preflight를 실행하면
Then PS5_CONNECTIVITY_MISCONFIGURED 상태와 수정 방법이 report에 표시되고
And PS5 compatible 릴리스 판정은 실패한다.
```

### AT-016 — PS5에서 358칸 실패

```text
Given Steam에서는 358칸이 정상이나 PS5에서 마지막 슬롯 접근이 실패할 때
When certification 결과를 판정하면
Then 358은 certified_target_slots에 추가되지 않고
And 마지막으로 세 필수 클라이언트가 통과한 슬롯 수를 운영 기본값으로 선택한다.
```

### AT-017 — macOS 필수 인증 실패

```text
Given Steam Windows와 PS5는 인증 슬롯 수를 정상 처리하지만 macOS가 마지막 슬롯 접근 또는 데이터 보존에 실패할 때
When 정식 1.0 릴리스 게이트를 판정하면
Then 해당 슬롯 수는 certified_target_slots에 추가되지 않고
And macOS 호환성 문제가 해결되거나 세 필수 클라이언트가 공통 통과한 슬롯 수로 낮추기 전에는 릴리스하지 않는다.
```

---

## 27. 릴리스 전략

### Phase 0 — Discovery Build

목표:

- 현재 revision의 정확한 guild/container 클래스와 심볼 확인
- read-only object discovery
- 54칸과 신규 기본값 상자의 구조 비교
- resize UFunction 후보 확인

완료 조건:

- 길드 ID에서 실제 길드 상자 Container ID까지 정확히 추적한다.
- 일반 상자를 오탐하지 않는다.
- audit report를 생성한다.
- mutation 코드는 비활성 상태다.

### Phase 1 — Server Migration Alpha

목표:

- Windows 데디케이트 서버에서 54→120 확장
- 기존 아이템 불변성 검증
- 서버 저장·재시작

완료 조건:

- synthetic 및 실제 월드 테스트 통과
- item fingerprint 변경 0건
- 반복 실행 mutation 0건

### Phase 2 — Crossplay Compatibility Beta

목표:

- 120→256→358 단계 인증
- Steam Windows·PS5·macOS 필수 테스트
- 컨트롤러 UI 검증
- 동시 접근 테스트

완료 조건:

- Steam Windows, PS5, macOS 전체 수용 테스트 통과
- 인증된 최대 슬롯 수 결정
- 크래시·접속 해제 0건

### Phase 3 — New Guild Automation

목표:

- 신규 길드 생성 hook
- fallback rescan
- 장기 soak test

완료 조건:

- 신규 길드 20회 반복 테스트 통과
- steady-state CPU 목표 충족
- rescan에 의한 틱 지연 없음

### Phase 4 — Official Package Release

목표:

- Official Mod Loader 패키징
- MinRevision 주입
- 설치·업데이트·제거 가이드
- release report

완료 조건:

- `IsServer=true` 패키지 검증
- client InstallRule 0건
- Steam Windows·PS5·macOS 인증 matrix 공개, Xbox는 검증된 경우에만 추가 표기
- rollback 절차 검증

### Phase 5 — Revision Maintenance

목표:

- 게임 업데이트 대응
- 새 Binding Manifest
- 자동 audit report 비교
- Steam Windows·PS5·macOS 재인증

완료 조건:

- 미지원 revision에서 fail-closed
- 새 revision 전체 테스트 통과 후 compatible 릴리스

---

## 28. 성공 지표

| 지표 | 목표 |
|---|---:|
| 기존 길드 마이그레이션 성공률 | 100% |
| 아이템 GUID·수량 변경 | 0건 |
| 일반 컨테이너 오수정 | 0건 |
| 반복 실행 추가 mutation | 0건 |
| 필수 클라이언트 모드 설치 | 0건 |
| Steam Windows·PS5·macOS 인증 과정의 클라이언트 크래시 | 0건 |
| 미지원 revision의 mutation | 0건 |
| 정상 운영 중 steady-state 오류 로그 | 0건 |
| 신규 길드 자동 적용 성공률 | 100% |
| Steam Windows·PS5·macOS 마지막 슬롯 접근 성공률 | 100% |
| 치명적 오류 후 자동 저장 | 0건 |

---

## 29. 위험과 완화책

| 위험 | 영향 | 가능성 | 완화 |
|---|---|---:|---|
| PS5 vanilla UI가 358칸을 처리하지 못함 | 필수 참가자의 마지막 슬롯 접근 불가·크래시 | 중간 | 54→120→256→358 단계 인증, PS5 실패 시 마지막 안전값 채택 |
| macOS vanilla UI 또는 입력 체계가 358칸을 처리하지 못함 | 필수 참가자의 마지막 슬롯 접근 불가·크래시 | 중간 | 세 필수 클라이언트 단계 인증, macOS 실패 시 공통 마지막 안전값 채택 |
| 게임 revision으로 심볼 변경 | 크래시·잘못된 mutation | 높음 | Binding Manifest, 타입 검증, fail-closed |
| 잘못된 컨테이너 식별 | 다른 상자 손상 | 낮음~중간 | guild ID + container ID + owner 3중 검증 |
| item GUID 변경 | 아이템 손상·복제 | 낮음 | before/after fingerprint, 즉시 중단 |
| 동시 상호작용 중 변경 | race condition | 중간 | startup migration, 상자 사용 중 apply 금지 |
| 다른 storage 모드 충돌 | 데이터 불일치 | 높음 | 동시 사용 비지원, 충돌 감지, mod list 기록 |
| 큰 replication payload | 접속 지연·disconnect | 중간 | 120/256/358 단계 부하 테스트 |
| mod 제거 후 vanilla 처리 실패 | 상자 접근 불가 | 중간 | 제거 인증 테스트, backup rollback |
| 신규 길드 hook 변경 | 신규 상자 미적용 | 높음 | revision manifest, fallback rescan |
| ledger와 save 불일치 | 잘못된 완료 판단 | 낮음 | save 상태 우선, startup drift 검사 |
| 서버 크래시 중간 저장 | 부분 적용 | 낮음 | startup 작업, per-guild 검증, 공식 백업 |
| official mod loader 구조 변경 | 설치 실패 | 중간 | release 시 공식 문서 대조 및 패키지 smoke test |
| PS5 테스트 환경 부족 | 핵심 요구를 검증하지 못함 | 중간 | PS5 실기기 인증 없이는 정식 릴리스 금지 |
| macOS 테스트 환경 부족 | 첫 릴리스 필수 호환성을 검증하지 못함 | 중간 | 지원 macOS 환경의 실기기 인증 없이는 정식 릴리스 금지 |
| PS5에 클라이언트 핫픽스 배포 불가 | UI 문제 우회 불가 | 높음 | custom UI를 범위에서 제외하고 안전 슬롯 수를 낮춤 |
| 커뮤니티 서버 목록 미노출 | PS5 참가 불가 | 중간 | `-publiclobby`, PublicIP/PublicPort, UDP 8211 preflight 및 외부망 접속 테스트 |

---

## 30. Definition of Done

정식 1.0 릴리스는 다음을 모두 만족해야 한다.

- [ ] Windows 데디케이트 서버에서 공식 Mod Loader로 설치된다.
- [ ] `Info.json`에 서버 전용 `IsServer=true` Lua InstallRule만 존재한다.
- [ ] 정확한 `MinRevision`이 설정돼 있다.
- [ ] UE4SS 의존성이 설치 검사에서 확인된다.
- [ ] 미지원 revision에서 mutation이 0건이다.
- [ ] audit 모드가 기본값이다.
- [ ] operator approval token이 없으면 apply되지 않는다.
- [ ] 기존 길드 54칸 상자가 인증 슬롯 수로 확장된다.
- [ ] 신규 길드 상자가 자동 확장된다.
- [ ] 이미 확장된 상자는 no-op 처리된다.
- [ ] 358칸보다 큰 상자는 축소하지 않는다.
- [ ] 기존 item GUID, 수량, index, instance metadata가 유지된다.
- [ ] 일반 상자는 변경되지 않는다.
- [ ] duplicate container와 owner mismatch를 차단한다.
- [ ] 서버 저장·재시작 후 데이터가 유지된다.
- [ ] mod 제거 smoke test를 통과한다.
- [ ] Steam 클라이언트 인증을 통과한다.
- [ ] PS5가 커뮤니티 서버 목록에서 서버를 검색하고 접속할 수 있다.
- [ ] PS5 순정 클라이언트 인증을 통과한다.
- [ ] Steam Windows 순정 클라이언트 인증을 통과한다.
- [ ] macOS 순정 클라이언트 인증을 통과한다.
- [ ] PS5 DualSense로 인증 대상의 마지막 슬롯에 접근할 수 있다.
- [ ] Xbox는 인증된 경우에만 지원 플랫폼으로 표기한다.
- [ ] 플랫폼 간 동시 접근 테스트를 통과한다.
- [ ] 6시간 soak test를 통과한다.
- [ ] 성능 목표를 충족한다.
- [ ] migration ledger와 structured report가 생성된다.
- [ ] 백업·설치·업데이트·제거·복원 문서가 제공된다.
- [ ] 공개 패키지에 client script, custom UI, 게임 원본 asset이 없다.
- [ ] Steam Windows·PS5·macOS 인증 결과, 서버 실행 인자, CrossplayPlatforms, 게임 revision이 release notes에 명시된다.

---

## 31. 구현 작업 분해

1. 모드 저장소와 Lua 모듈 구조 생성
2. config schema와 validator
3. game revision reader
4. Binding Manifest schema
5. read-only UObject discovery
6. WorldReadyDetector
7. GuildRepository
8. GuildChestResolver
9. ContainerSnapshotter
10. item fingerprint
11. audit report
12. approval token
13. ContainerResizer prototype
14. game-thread mutation wrapper
15. InvariantValidator
16. ReplicationCoordinator
17. MigrationLedger
18. migration state machine
19. startup existing-guild migration
20. new-guild hook
21. fallback rescan
22. structured logging
23. official `Info.json` packaging
24. synthetic adapter tests
25. real-world Windows server tests
26. Steam Windows 기준 클라이언트 테스트
27. PS5 커뮤니티 서버 검색·접속 테스트
28. PS5 DualSense·UI 테스트
29. Steam Windows ↔ PS5 동시 접근 테스트
30. macOS 필수 호환성 테스트
31. Xbox 선택 호환성 테스트
32. soak and performance tests
33. removal and rollback tests
34. release report generator
35. Windows 서버 + PS5 + macOS 운영 문서

---

## 32. 구현 전 기술 스파이크의 확정 산출물

내부 Palworld 심볼은 버전 종속적이므로 PRD에서 임의의 클래스명을 구현 계약으로 고정하지 않는다. 첫 기술 스파이크는 다음 산출물을 반드시 만든다.

1. 현재 revision 번호
2. 길드 manager 실제 클래스명
3. 길드 목록 접근 경로
4. 길드 ID 프로퍼티
5. 길드 상자 Container ID 프로퍼티
6. Item Container manager 클래스
7. Container 조회 함수
8. slot array 프로퍼티
9. 빈 slot 객체 타입
10. 안전한 resize 또는 append 함수
11. dirty 처리 함수
12. replication 요청 함수
13. world-ready hook
14. new-guild hook
15. 상자 사용 중 여부 확인 방법
16. 54칸 상자 before snapshot
17. 358칸 상자 after snapshot
18. Steam Windows UI 렌더링 결과
19. PS5 UI·DualSense 마지막 슬롯 접근 결과
20. mod 제거 후 Steam Windows·PS5·macOS vanilla 동작 결과

이 산출물이 확보되지 않으면 mutation 기능 구현 단계로 진행하지 않는다.

---

## 33. 운영 가이드 요약

### 최초 설치

```text
1. 서버 종료
2. 월드 전체 백업
3. UE4SS와 CGCE 설치
4. mode=audit로 서버 실행
5. audit report 검토
6. 서버 종료
7. approval token 설정
8. mode=apply로 서버 실행
9. migration complete 확인
10. 서버 저장·재시작
11. PS5 커뮤니티 서버 검색·접속 smoke test
12. Steam Windows ↔ PS5 길드 상자 동시 접근 test
13. mode=audit 또는 verify-only로 변경
```

### 게임 업데이트 직후

```text
1. CGCE 비활성화 또는 audit-only
2. 서버와 게임 업데이트
3. 새 revision 지원 여부 확인
4. 지원되지 않으면 mutation 금지 상태 유지
5. 새 호환 릴리스 설치
6. 백업 후 audit
7. Steam Windows·PS5·macOS smoke test
```

### 문제 발생

```text
1. 서버에 추가 상호작용 중지 공지
2. 정상 저장을 강제하지 않음
3. CGCE 로그와 report 보존
4. 서버 종료
5. 백업 복원
6. 충돌 모드 제거
7. audit-only 재현
```

---

## 34. 참고 자료

이 PRD는 다음 1차 문서의 현재 제약을 기준으로 작성했다.

- Palworld Server Guide 1.0.0 — Introduction
- Palworld Server Guide — About server 및 PS5 커뮤니티 서버 접속 제약
- Palworld Server Guide — Configuration parameters
- Palworld Server Guide — Configure for community server
- Palworld Server Guide — Installing Mods on a Server
- Pocketpair Palworld Official Mod Uploader — Package specification
- Pocketpair Palworld Official Mod Uploader — Technical specification
- UE4SS Documentation — RegisterHook
- UE4SS Documentation — ExecuteInGameThread
- UE4SS Documentation — FindAllOf

실제 구현과 릴리스 전에는 위 문서의 최신 버전, Palworld revision, UE4SS 호환성을 다시 검증한다.
