# Hublot

Client iOS natif pour piloter Claude et Codex sur un VPS depuis le téléphone.
Hublot remplace Telegram comme interface, sans dupliquer le cerveau du relais :
quotas, passations, permissions et sessions restent assurés par `tg-claude`.

## Architecture

```text
iPhone ──wss──▶ Caddy ──▶ acp_server.py ──▶ Claude / Codex
                              │
                              ├─ bot.py          logique tg-claude
                              ├─ sessions.py     conversations Claude
                              ├─ continuity.py   fil commun et rejeu des outils
                              ├─ usage.py        contexte relu chez chaque moteur
                              └─ radiography.py  événements Codex localisés
```

- `IAClient-UI/ACP/` — JSON-RPC, schéma ACP et transport WebSocket.
- `IAClient-UI/Domain/` — conversation, streaming, notifications, dictée et
  projection de la Radiographie.
- `IAClient-UI/UI/` — projets, sessions, conversation et carte visuelle.
- `IAClient-UI/Render/` — thème, Markdown et coloration syntaxique.
- `Server/` — sources Hublot déployées avec le relais sur le VPS.
- `Tools/` — tests réels et sondes du protocole.

Le service de production tourne dans `/opt/tg-claude`. Le dépôt Hublot et le
dépôt `tg-claude` restent distincts : le premier contient l’app et son relais
ACP, le second la logique historique partagée avec Telegram.

## Construire et tester

Prérequis : Xcode 26, iOS 26 et Node.js 20 pour les tests de bout en bout.

```bash
# 48 tests Swift sur le simulateur iPhone Air
xcodebuild test \
  -project IAClient-UI.xcodeproj \
  -scheme IAClient-UI \
  -destination 'platform=iOS Simulator,name=iPhone Air'

# Tests unitaires du serveur
cd Server
python3 -m unittest discover -v

# Protocole réel, sans appeler de modèle
HUBLOT_TOKEN=… node Tools/e2e.mjs --fast

# Radiographie réelle sur Office Chess, puis rejeu après reconnexion
HUBLOT_TOKEN=… node Tools/radiography-e2e.mjs
```

`Tools/e2e.mjs` contient 20 scénarios : les 10 rapides vérifient liaison,
projets, réglages et erreurs ; les 10 lents lancent réellement les moteurs.
`--only=<motif>` n'en joue qu'un — vérifier un correctif ne devrait pas coûter
vingt tours de quota.

## Fonctionnalités

- connexion WebSocket persistante et reconnexion silencieuse ;
- **un tour survit à la liaison qui l'a lancé** : le téléphone se met en veille,
  le moteur continue, et la conversation repart en direct sur la liaison qui
  revient — texte déjà écrit compris ;
- **signe de vie** : ce que le moteur fait (réfléchit, écrit, telle commande),
  depuis quand, et depuis combien de temps il n'a plus rien émis. Sans ce
  compteur, une commande de trois minutes et un moteur planté donnent le même
  écran ;
- projets et conversations du VPS, avec reprise et suppression ;
- streaming Markdown, coloration syntaxique et outils repliables ;
- retour automatique à la dernière réponse à l'ouverture, et bouton de retour au
  direct dès qu'on remonte lire ;
- sélection Claude/Codex, modèles, effort et permissions décrits par le serveur ;
- bascule de moteur avec passation du seul contexte manquant ;
- quotas, et contexte relu chez le moteur qui le mesure — le journal de session
  pour Claude, celui du fil pour Codex — donc connu dès l'ouverture ;
- envoi de photos : l’image est réduite sur le téléphone, posée sur le VPS et
  lue par le moteur ;
- dictée via Whisper, notifications locales et arrêt d’un tour ;
- Radiographie spatiale des fichiers et services observés, avec chronologie ;
- lecture du `CLAUDE.md` d’un projet.

## Outils

| Commande | Rôle |
|---|---|
| `node Tools/acp-probe.mjs` | Inspecte les capacités réellement annoncées. |
| `node Tools/e2e.mjs [--fast] [--only=…]` | Batterie de bout en bout contre le VPS. |
| `node Tools/radiography-e2e.mjs` | Vérifie localisation et reconnexion sur Office Chess. |
| `Tools/ui-check.sh` | Pose une demande par le chemin de l’interface. |
| `Tools/deploy-iphone.sh` | Construit signé, installe et lance sur l’iPhone. |
| `swift Tools/make-icon.swift` | Régénère l’icône de l’app. |

## Sécurité et déploiement

- Le jeton ACP vit dans le trousseau iOS, jamais dans le dépôt.
- Le serveur borne les répertoires pilotés à `/root/repos`.
- Les commandes dangereuses passent par le garde-fou de `tg-claude`.
- La clé de transcription reste dans l’environnement du VPS.
- Le téléphone reçoit la version courante par `Tools/deploy-iphone.sh` ; le
  relais par `scp Server/*.py hetzner:/opt/tg-claude/` puis
  `systemctl restart acp.service`.
- Le profil Apple gratuit expire après 7 jours : passé ce délai, le lancement
  échoue sur une erreur de provisioning et il faut rouvrir Xcode une fois pour
  le renouveler.
