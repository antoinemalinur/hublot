#!/usr/bin/env bash
#
# ui-check.sh — pose une vraie question depuis l'interface, et photographie.
#
# Ce script existe parce qu'il manquait, et que son absence a coûté cher : la
# batterie de bout en bout parlait au serveur sans l'app, les tests unitaires
# assemblaient le fil sans l'écran, et le seul chemin que personne n'empruntait
# — taper une question dans Hublot et regarder ce qui s'affiche — était
# précisément celui qui était cassé.
#
# Il déroule le scénario complet dans le simulateur, contre le serveur du VPS,
# et capture l'écran à intervalles pendant que la réponse s'écrit.
#
#   HUBLOT_TOKEN=… Tools/ui-check.sh office-chess "D'après la bdd, qui gagne ?"
#
# Le second fil ouvert avant la question n'est pas une coquetterie : c'est la
# condition qui faisait disparaître une trame sur deux, et elle doit être jouée
# à chaque vérification.
#
set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE="${HUBLOT_DEVICE:-iPhone Air}"
BUNDLE="antoinemalinur.IAClient-UI"
URL="${HUBLOT_URL:-wss://acp.95-216-190-3.sslip.io}"
TOKEN="${HUBLOT_TOKEN:?HUBLOT_TOKEN manquant}"
PROJECT="${1:?dépôt manquant}"
QUESTION="${2:?question manquante}"
OUT="${HUBLOT_SHOTS:-build/shots}"
SHOTS="${HUBLOT_FRAMES:-6}"
EVERY="${HUBLOT_EVERY:-12}"

mkdir -p "$OUT"

echo "▸ build"
xcodebuild -project IAClient-UI.xcodeproj -scheme IAClient-UI -configuration Debug \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -derivedDataPath build/DerivedData -quiet build

APP="build/DerivedData/Build/Products/Debug-iphonesimulator/IAClient-UI.app"
ID="$(xcrun simctl list devices available -j \
  | python3 -c "import json,sys;d=json.load(sys.stdin)['devices'];print(next(x['udid'] for v in d.values() for x in v if x['name']=='$DEVICE'))")"

xcrun simctl bootstatus "$ID" -b >/dev/null 2>&1 || xcrun simctl boot "$ID"
xcrun simctl terminate "$ID" "$BUNDLE" >/dev/null 2>&1 || true
xcrun simctl install "$ID" "$APP"

xcrun simctl launch "$ID" "$BUNDLE" \
  -hublot.serverURL "$URL" \
  -HublotToken "$TOKEN" \
  -HublotProject "$PROJECT" \
  -HublotSecondSession 1 \
  -HublotOpening "$QUESTION" >/dev/null

echo "▸ « $QUESTION » sur $PROJECT"
for i in $(seq 1 "$SHOTS"); do
  sleep "$EVERY"
  xcrun simctl io "$ID" screenshot --type=png "$OUT/ui-$i.png" >/dev/null 2>&1
  echo "  ▸ $OUT/ui-$i.png"
done
