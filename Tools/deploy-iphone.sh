#!/usr/bin/env bash
#
# deploy-iphone.sh — pose la version courante sur le téléphone d'Antoine.
#
# Une modification qui reste dans le simulateur n'est pas livrée : Hublot se
# juge dans la main, sur le réseau mobile, contre le vrai VPS. Ce script fait
# les trois gestes qui séparent un dépôt d'un téléphone — construire signé,
# installer, lancer — et vérifie que l'app est bien repartie.
#
#   Tools/deploy-iphone.sh              l'iPhone connecté
#   HUBLOT_DEVICE_ID=… Tools/deploy-iphone.sh   un appareil précis
#
# Le profil Apple gratuit expire après sept jours : si le lancement échoue avec
# une erreur de provisioning, c'est presque toujours ça, et il faut rouvrir
# Xcode une fois pour le renouveler.
#
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE="antoinemalinur.IAClient-UI"
DERIVED="build/DeviceDerivedData"
APP="$DERIVED/Build/Products/Debug-iphoneos/IAClient-UI.app"

# L'appareil : celui qu'on impose, sinon le premier iPhone réellement connecté.
# Le chercher plutôt que le coder en dur évite de reposer sur un identifiant qui
# change au réappairage.
if [ -z "${HUBLOT_DEVICE_ID:-}" ]; then
  HUBLOT_DEVICE_ID="$(xcrun devicectl list devices --quiet --json-output - 2>/dev/null \
    | python3 -c '
import json, sys
try:
    payload = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit(0)
for device in payload.get("result", {}).get("devices", []):
    connected = device.get("connectionProperties", {}).get("tunnelState") != "unavailable"
    platform = device.get("hardwareProperties", {}).get("platform")
    if connected and platform == "iOS":
        print(device["identifier"])
        break
')"
fi

if [ -z "$HUBLOT_DEVICE_ID" ]; then
  echo "✕ aucun iPhone connecté — branche-le ou vérifie l'appairage Wi-Fi" >&2
  exit 1
fi

echo "▸ appareil $HUBLOT_DEVICE_ID"
echo "▸ build signé"
xcodebuild -project IAClient-UI.xcodeproj -scheme IAClient-UI -configuration Debug \
  -destination "platform=iOS,id=$HUBLOT_DEVICE_ID" \
  -derivedDataPath "$DERIVED" -allowProvisioningUpdates -quiet build

echo "▸ installation"
xcrun devicectl device install app --device "$HUBLOT_DEVICE_ID" "$APP" >/dev/null

echo "▸ lancement"
xcrun devicectl device process launch --device "$HUBLOT_DEVICE_ID" "$BUNDLE" >/dev/null

echo "✓ Hublot est sur le téléphone"
