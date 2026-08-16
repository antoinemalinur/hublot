# Quickstart: validate Fluidité globale

## Targeted red/green cycle

1. Run the streaming domain tests and record that the 1,000-frame test fails if
   `enqueueStream` calls its immediate append path.
2. Run the project-loading test and record that it exceeds the bound if
   `AppModel.open` awaits the two resources sequentially.
3. Run the UI tests and record that removing the loading row or bypassing
   `ChatSession` makes the observable assertion fail.

```bash
xcodebuild test \
  -project IAClient-UI.xcodeproj \
  -scheme IAClient-UI \
  -destination 'platform=iOS Simulator,name=iPhone Air' \
  -only-testing:IAClient-UITests/ConversationFlowTests \
  -only-testing:IAClient-UITests/AppModelTests

xcodebuild test \
  -project IAClient-UI.xcodeproj \
  -scheme IAClient-UI \
  -destination 'platform=iOS Simulator,name=iPhone Air' \
  -only-testing:IAClient-UIScreenTests/ComposerScreenMoreTests \
  -only-testing:IAClient-UIScreenTests/NavigationScreenTests
```

## Mandatory delivery gate

```bash
Tools/test-local.sh full
```

The command must report all UI/unit tests green with no skips, Python server tests
green, coverage thresholds met, four distinct simulator clones, and Release build
success. Only then:

```bash
Tools/deploy-iphone.sh
```

Perform a real-device smoke check of project navigation, loading, streaming,
keyboard input, scrolling and back navigation. Record any unavailable VPS check
explicitly before opening the PR.

## Validation performed

On 2026-08-16, `Tools/test-local.sh full` completed successfully on the exact
`iPhone Air` simulator with iOS 26.5:

- 4 distinct simulator workers, 0 failed or skipped tests;
- 92.3% overall coverage and every critical file at or above 90%;
- 72/72 Python server tests green;
- Release build successful;
- 394 s total, including 383 s for tests.

At the user's explicit request, the signed app was installed on “iPhone de
Antoine Malinur” before that run completed. The device was locked during the
first launch attempt and disconnected after the retry, so installation is
confirmed but launch and the real tactile smoke check are not.
