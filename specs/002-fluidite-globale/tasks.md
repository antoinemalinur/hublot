# Tasks: Fluidité globale

**Input**: Design documents from `/specs/002-fluidite-globale/`

**Prerequisites**: `plan.md`, `spec.md`, `research.md`, `data-model.md`,
`contracts/ui-scenarios.md`, `quickstart.md`

**Tests**: Mandatory under the Hublot constitution. Each behavior test is written
and observed failing before its implementation.

## Phase 1: Baseline and test contracts

- [x] T001 Record the existing Markdown streaming baseline in
  `specs/002-fluidite-globale/research.md` using
  `IAClient-UITests/RenderPerformanceTests.swift`
- [x] T002 [P] [US1] Add a domain regression that injects 1,000 real ACP message
  chunks, verifies exact ordered output, a bounded document revision count, and
  all end/replay barriers in `IAClient-UITests/ConversationFlowTests.swift`
- [x] T003 [P] [US1] Declare `streaming-pressure`, build its debug relay through
  `ACPConnection`/`ChatSession`, and add the real composer touch/typing XCTest in
  `IAClient-UI/App/UITestScenario.swift`, `IAClient-UI/IAClient_UIApp.swift`, and
  `IAClient-UIScreenTests/ComposerScreenMoreTests.swift`
- [x] T004 [P] [US2] Extend the AppModel relay so two retained project resources
  prove concurrent dispatch, and add the red domain test in
  `IAClient-UITests/AppModelTests.swift`
- [x] T005 [P] [US2] Declare `project-loading`, add its retained relay, then add
  the project tap/loading/action XCTest in `IAClient-UI/App/UITestScenario.swift`,
  `IAClient-UI/App/ScreenFixtures.swift`, and
  `IAClient-UIScreenTests/NavigationScreenTests.swift`

**Checkpoint**: New regressions fail against the pre-change paths: one visible
publication per chunk, sequential resource requests, and no loading state.

## Phase 2: User Story 1 — responsive live conversation (P1)

- [x] T006 [US1] Add the single pending-fragment state, 25 ms scheduled flush,
  synchronous semantic barriers and one revision per visible batch in
  `IAClient-UI/Domain/ChatSession.swift`
- [x] T007 [US1] Store the derived machine state with each document revision and
  pass both through production and real-relay fixtures in
  `IAClient-UI/Domain/ChatSession.swift` and `IAClient-UI/IAClient_UIApp.swift`
- [x] T008 [US1] Extract the `LazyVStack` into an equatable `ThreadDocument` keyed
  by revision/state so chrome updates skip regrouping in
  `IAClient-UI/UI/ConversationView.swift`
- [x] T009 [US1] Run the targeted domain and UI regressions, inspect the
  1,000-fragment revision/latency diagnostics, and temporarily remove the
  coalescing call to demonstrate the regression turns red

**Checkpoint**: Typing, scrolling and exact streaming pass independently under
the pressure fixture.

## Phase 3: User Story 2 — immediate project entry (P2)

- [x] T010 [US2] Start conversation-list and instruction loads as sibling
  structured tasks, preserving independent results, in
  `IAClient-UI/App/AppModel.swift`
- [x] T011 [US2] Add the accessible, non-blocking loading row and identifier in
  `IAClient-UI/UI/SessionsView.swift`
- [x] T012 [US2] Run the concurrent-load domain test and project tap XCUITest,
  then temporarily serialize the two awaits to demonstrate the timing contract
  turns red

**Checkpoint**: The destination screen, spinner and creation action appear
before either retained network response.

## Phase 4: User Story 3 — stable long histories (P3)

- [x] T013 [US3] Add a 1,000-entry/100-heartbeat regression and diagnostics to
  `IAClient-UITests/RenderPerformanceTests.swift`, proving unchanged revision and
  sub-100 ms update cost
- [x] T014 [US3] Exercise scroll-position and open-tool-group stability alongside
  `streaming-pressure`, retaining the existing `thread-growing` UI coverage
- [x] T015 [US3] Re-run the motion-reduction and long-thread UI tests to confirm
  no continuous animation, geometry or accessibility regression

## Phase 5: Delivery validation

- [x] T016 Run all targeted Swift tests and affected Python server tests
- [x] T017 Run mandatory `Tools/test-local.sh full`; require four workers, no
  failures/skips, coverage thresholds and Release success
- [x] T018 Review `git diff`, ensure `.claude/` remains untouched, and update all
  completed task boxes plus validation evidence in the spec documents
- [ ] T019 Deploy the validated build with `Tools/deploy-iphone.sh` and perform
  the real-device navigation/keyboard/scroll/stream smoke check
- [ ] T020 Commit the feature branch, push it, open a PR to `main`, verify CI,
  squash-merge it, and verify local/remote `main` at the squash commit

## Validation record

- 2026-08-15: the pre-change path failed with 1,000 visible revisions and the
  sequential project requests; removing the loading row also made its UI
  regression fail.
- 2026-08-16: `Tools/test-local.sh full` succeeded on iPhone Air / iOS 26.5 in
  394 s: four distinct workers, no failure or skip, 92.3% overall coverage,
  critical files at or above 90%, 72 server tests green, and Release build
  successful.
- Device exception requested by the user: the signed build was installed on
  “iPhone de Antoine Malinur” before the complete gate ended. Automatic launch
  first met the locked device, then the phone disconnected; the real-device
  navigation/keyboard/scroll smoke check remains unavailable, so T019 stays
  open.

## Dependencies & execution order

- T002–T005 may be authored independently, but all must fail before T006/T010.
- T006 blocks T007–T009 and T013–T15.
- T010 blocks T011–T012.
- T016–T020 are sequential delivery gates; deployment and GitHub mutation are
  forbidden before T017 succeeds.

## Implementation strategy

Ship no partial slice. US1 removes main-thread pressure, US2 removes perceived
navigation latency, and US3 proves the gains persist at realistic history size.
The complete local gate precedes device deployment, which precedes PR creation and
squash merge.
