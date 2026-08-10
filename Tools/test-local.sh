#!/bin/bash

set -euo pipefail

MODE="${1:-full}"
REPOSITORY="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$REPOSITORY/IAClient-UI.xcodeproj"
SCHEME="IAClient-UI"
PLAN="IAClient-UI"
DERIVED_DATA="$REPOSITORY/Tools/build/DerivedData"
RUN_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/hublot-tests.XXXXXX")"
RESULT_BUNDLE="$RUN_DIRECTORY/Hublot.xcresult"
TEST_LOG="$RUN_DIRECTORY/xcode-test.log"
RELEASE_LOG="$RUN_DIRECTORY/xcode-release.log"

# Quatre workers mesures comme l'optimum sur M5 (10 coeurs, 24 Go): a six, la
# contention rallonge les tests d'interface de 161 s a 216 s.
# HUBLOT_WORKERS et HUBLOT_PARALLEL_RELEASE permettent de remesurer.
WORKERS="${HUBLOT_WORKERS:-4}"
# Mesure: le build Release en fond vole assez de CPU aux simulateurs pour
# rallonger les tests de 161 s a 174 s, alors qu'il ne dure lui-meme que 5 s a
# chaud. Sequentiel par defaut, donc.
PARALLEL_RELEASE="${HUBLOT_PARALLEL_RELEASE:-0}"
RELEASE_PID=""

# Deux xcodebuild concurrents ne peuvent pas partager un meme DerivedData.
if [[ "$PARALLEL_RELEASE" == "1" ]]; then
    DERIVED_DATA_RELEASE="$REPOSITORY/Tools/build/ReleaseDerivedData"
else
    DERIVED_DATA_RELEASE="$DERIVED_DATA"
fi

TIMINGS=()

phase() {
    local label="$1"
    shift
    local started=$SECONDS
    "$@"
    local elapsed=$((SECONDS - started))
    TIMINGS+=("$label|$elapsed")
    echo "== $label: ${elapsed} s"
}

report_timings() {
    echo
    echo "Chronometrage ($WORKERS workers, release parallele=$PARALLEL_RELEASE):"
    local total=0
    for entry in "${TIMINGS[@]}"; do
        printf '  %-34s %5s s\n' "${entry%%|*}" "${entry##*|}"
        total=$((total + ${entry##*|}))
    done
    printf '  %-34s %5s s\n' "TOTAL" "$total"
}

latest_air() {
    xcrun simctl list devices available | awk '
        /^-- iOS / { version=$3 }
        /iPhone Air \(/ {
            identifier=$(NF-1)
            gsub(/[()]/, "", identifier)
            print version "|" identifier
        }
    ' | sort -t. -k1,1n -k2,2n | tail -1
}

AIR="$(latest_air)"
if [[ -z "$AIR" ]]; then
    echo "Erreur: aucun simulateur iPhone Air n'est disponible." >&2
    exit 2
fi

IOS_VERSION="${AIR%%|*}"
AIR_UDID="${AIR#*|}"
DESTINATION="platform=iOS Simulator,id=$AIR_UDID"

echo "Destination obligatoire: iPhone Air · iOS $IOS_VERSION · $AIR_UDID"

XCODE_COMMON=(
    -project "$PROJECT"
    -scheme "$SCHEME"
    -testPlan "$PLAN"
    -destination "$DESTINATION"
    -derivedDataPath "$DERIVED_DATA"
)

build_for_testing() {
    xcodebuild build-for-testing "${XCODE_COMMON[@]}"
}

run_tests() {
    set -o pipefail
    xcodebuild test-without-building "${XCODE_COMMON[@]}" \
        -parallel-testing-enabled YES \
        -parallel-testing-worker-count "$WORKERS" \
        -maximum-concurrent-test-simulator-destinations "$WORKERS" \
        -enableCodeCoverage YES \
        -resultBundlePath "$RESULT_BUNDLE" \
        2>&1 | tee "$TEST_LOG"
}

check_result() {
    local summary="$RUN_DIRECTORY/summary.json"
    xcrun xcresulttool get test-results summary \
        --path "$RESULT_BUNDLE" --format json > "$summary"

    /usr/bin/python3 - "$summary" <<'PY'
import json
import sys

summary = json.load(open(sys.argv[1], encoding="utf-8"))
failed = int(summary.get("failedTests", 0) or 0)
skipped = int(summary.get("skippedTests", 0) or 0)
if failed:
    raise SystemExit(f"Erreur: {failed} test(s) en echec.")
if skipped:
    raise SystemExit(f"Erreur: {skipped} test(s) ignore(s).")
PY

    local coverage="$RUN_DIRECTORY/coverage.json"
    xcrun xccov view --report --json "$RESULT_BUNDLE" > "$coverage"
    /usr/bin/python3 - "$coverage" <<'PY'
import json
import os
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
targets = [target for target in report.get("targets", [])
           if target.get("name", "").startswith("IAClient-UI")]
if not targets:
    raise SystemExit("Erreur: aucune couverture pour IAClient-UI.")
target = max(targets, key=lambda item: item.get("executableLines", 0))
global_percent = float(target.get("lineCoverage", 0)) * 100
if global_percent < 80:
    raise SystemExit(
        f"Erreur: couverture globale {global_percent:.1f} %, seuil 80 %."
    )

critical_suffixes = (
    "/App/AppModel.swift", "/Domain/ChatSession.swift",
    "/ACP/ACPConnection.swift", "/ACP/JSONRPC.swift", "/ACP/ACPSchema.swift",
    "/Domain/Turn.swift", "/Domain/ContextTide.swift",
    "/Domain/ProjectRadiography.swift",
)
files = {item.get("path", ""): item for item in target.get("files", [])}
missing = [suffix for suffix in critical_suffixes
           if not any(path.endswith(suffix) for path in files)]
if missing:
    raise SystemExit("Erreur: fichiers critiques absents de la couverture: " + ", ".join(missing))
below = []
for path, item in files.items():
    if path.endswith(critical_suffixes):
        percent = float(item.get("lineCoverage", 0)) * 100
        if percent < 90:
            below.append(f"{os.path.basename(path)} {percent:.1f} %")
if below:
    raise SystemExit("Erreur: seuil critique 90 % non atteint: " + ", ".join(below))
print(f"Couverture: {global_percent:.1f} % globale; fichiers critiques >= 90 %.")
PY

    local clone_count
    clone_count="$(grep -Eio "started on 'clone [0-9]+" "$TEST_LOG" \
        | grep -Eio 'clone [0-9]+' | sort -u | wc -l | tr -d ' ')"
    if [[ "$clone_count" -lt "$WORKERS" ]]; then
        echo "Erreur: Xcode n'a pas atteste $WORKERS clones dans son journal ($clone_count vus)." >&2
        exit 1
    fi
    echo "Parallele: $clone_count clones distincts attestes."
}

run_server_tests() {
    /usr/bin/python3 -m unittest discover -s "$REPOSITORY/Server" -p 'test_*.py' -v
}

build_release() {
    xcodebuild build \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Release \
        -destination "$DESTINATION" \
        -derivedDataPath "$DERIVED_DATA_RELEASE" \
        CODE_SIGNING_ALLOWED=NO
}

start_release() {
    build_release > "$RELEASE_LOG" 2>&1 &
    RELEASE_PID=$!
    echo "Build Release lance en arriere-plan (PID $RELEASE_PID), journal: $RELEASE_LOG"
}

# Les tests d'interface attendent surtout des animations; le build Release
# consomme le CPU laisse libre pendant ce temps. On ne paie donc que le
# reliquat une fois les tests termines.
wait_release() {
    if wait "$RELEASE_PID"; then
        echo "Build Release termine."
        return 0
    fi
    echo "Erreur: build Release en echec." >&2
    tail -40 "$RELEASE_LOG" >&2
    exit 1
}

update_snapshots() {
    build_for_testing
    xcrun simctl boot "$AIR_UDID" 2>/dev/null || true
    xcrun simctl bootstatus "$AIR_UDID" -b
    xcrun simctl install "$AIR_UDID" \
        "$DERIVED_DATA/Build/Products/Debug-iphonesimulator/IAClient-UI.app"

    local snapshots="$REPOSITORY/IAClient-UIScreenTests/Snapshots"
    local scenarios=(
        connection projects projects-empty projects-error
        sessions sessions-empty sessions-instructions conversation codex-quota
        context-tide radiography radiography-dense
    )
    for scenario in "${scenarios[@]}"; do
        xcrun simctl launch --terminate-running-process "$AIR_UDID" antoinemalinur.IAClient-UI \
            -HublotUITestScenario "$scenario" -UIAccessibilityReduceMotionEnabled YES \
            -HublotSnapshotMode YES >/dev/null
        sleep 2
        xcrun simctl io "$AIR_UDID" screenshot "$snapshots/$scenario.png" >/dev/null
        sips -Z 1368 "$snapshots/$scenario.png" >/dev/null
        echo "Reference mise a jour: $scenario"
    done
}

case "$MODE" in
    full)
        phase "build-for-testing" build_for_testing
        if [[ "$PARALLEL_RELEASE" == "1" ]]; then
            start_release
            phase "tests (avec release en fond)" run_tests
            phase "controles et couverture" check_result
            phase "tests serveur" run_server_tests
            phase "attente release restante" wait_release
        else
            phase "tests" run_tests
            phase "controles et couverture" check_result
            phase "tests serveur" run_server_tests
            phase "build release" build_release
        fi
        report_timings
        ;;
    stress)
        xcodebuild test "${XCODE_COMMON[@]}" \
            -only-testing:IAClient-UITests \
            -parallel-testing-enabled YES \
            -parallel-testing-worker-count "$WORKERS" \
            -maximum-concurrent-test-simulator-destinations "$WORKERS" \
            -enableThreadSanitizer YES \
            -test-iterations 5 \
            -test-repetition-relaunch-enabled YES
        ;;
    update-snapshots)
        update_snapshots
        ;;
    *)
        echo "Usage: Tools/test-local.sh {full|stress|update-snapshots}" >&2
        exit 2
        ;;
esac

echo "Validation $MODE terminee sur iPhone Air (iOS $IOS_VERSION)."
