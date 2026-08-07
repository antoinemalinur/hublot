# Hublot — journal de bord

Client iOS natif pour piloter des agents de code sur un VPS, en remplacement de
Telegram. Ce fichier retrace ce qui a été construit, ce qui a cassé, et
**pourquoi** — parce que dans ce projet la plupart des décisions viennent d'une
panne observée, pas d'une intuition.

Dernière mise à jour : 6 août 2026.

---

## Ce que c'est

Une app SwiftUI (iOS 26, Liquid Glass) qui parle **ACP** (Agent Client Protocol,
JSON-RPC une trame par ligne) en WebSocket à un serveur Python sur un VPS
Hetzner. Le serveur traduit `claude -p --output-format stream-json` et
`codex exec --json` en trames ACP, et conserve la logique du relais Telegram :
bascule de moteur sur quota, passation de contexte, garde-fou sur les commandes
dangereuses.

```
iPhone ──wss──▶ Caddy ──▶ acp_server.py ──▶ claude / codex
                              │
                              ├─ bot.py        (importé comme bibliothèque)
                              ├─ sessions.py   (les .jsonl de Claude Code)
                              ├─ continuity.py (le fil, les outils, et ce que chaque moteur a vu)
                              └─ radiography.py (les événements Codex localisés)
```

### Les fichiers qui comptent

| Chemin | Rôle |
|---|---|
| `IAClient-UI/ACP/` | Protocole : JSON-RPC, schéma, transport WebSocket, multiplexeur |
| `IAClient-UI/Domain/ChatSession.swift` | Traduit les trames en fil de conversation |
| `IAClient-UI/Domain/ProjectRadiography.swift` | Projette les outils en régions, liens et chronologie |
| `IAClient-UI/Domain/MarkdownStream.swift` | Découpe le flux pour que le rendu reste linéaire |
| `IAClient-UI/Domain/Dictation.swift` | Enregistrement vocal |
| `IAClient-UI/App/AppModel.swift` | Écrans, liaison, reconnexion |
| `IAClient-UI/UI/` | Les écrans |
| `IAClient-UI/Render/` | Thème, fond ambiant, coloration syntaxique |
| `Server/` | Copie de ce qui tourne dans `/opt/tg-claude/` sur le VPS |
| `Tools/e2e.mjs` | 17 tests de bout en bout contre le serveur réel |
| `Tools/radiography-e2e.mjs` | Test Codex réel, localisation puis rejeu après reconnexion |
| `Tools/ui-check.sh` | Pose une vraie question depuis l'interface et photographie |

### Vérifications

```bash
xcodebuild test -project IAClient-UI.xcodeproj -scheme IAClient-UI \
  -destination 'platform=iOS Simulator,name=iPhone Air'     # 37 tests Swift

HUBLOT_TOKEN=… node Tools/e2e.mjs                            # 17 tests bout en bout
HUBLOT_TOKEN=… node Tools/radiography-e2e.mjs                # Office Chess + reconnexion
HUBLOT_TOKEN=… Tools/ui-check.sh office-chess "ta question"  # l'interface, en vrai
```

---

## Les décisions qui structurent tout

**Le verre a besoin de lumière.** Sur fond noir pur, `.glassEffect` ne rend
rien : il réfracte ce qu'il y a derrière, et derrière il n'y a rien. D'où le
fond en `MeshGradient` qui respire — et comme il fallait une lueur, autant
qu'elle *dise* quelque chose : elle encode l'état de la machine (au repos,
réfléchit, travaille, échec).

**Les conversations existent déjà sur le disque.** Claude Code écrit un `.jsonl`
par session dans `~/.claude/projects/`. Aucun index maison : ces fichiers sont
la vérité pour lister, reprendre et supprimer. Rien à synchroniser, rien à
périmer.

**Le fil est la vérité, les sessions natives sont des caches.** Claude et Codex
ont chacun leur mémoire. Au moment de basculer, le moteur entrant reçoit
**exactement ce qu'il a manqué de cette conversation** — pas tout l'historique,
pas un résumé vague : le delta (`continuity.py`).

**Un champ absent n'est jamais fabriqué.** Devant un plafond de quota, un
chiffre faux est pire que pas de chiffre. La barre de statut disparaît quand
elle n'a rien à dire, et `CTX` est absent sous Codex parce que Codex ne mesure
pas sa fenêtre. Les quotas suivent eux aussi le moteur : le 5 h vient du
moniteur Claude ; la semaine Codex vient de `account/rateLimits/read` via le
service de quotas local. L'un ne sert jamais de repli à l'autre.

**La radiographie n'est pas une prédiction.** Elle dessine uniquement les faits
que le protocole a observés : outils, chemins, ordre et statut. Un dossier lu
n'est pas présenté comme modifié, un échec rattrapé ne reste pas rouge à vie,
et une commande sans chemin demeure honnêtement dans « Terminal ».

---

## Ce qui a cassé, et ce que ça a appris

### Le streaming est quadratique si on le laisse faire

MarkdownUI reparse toute la chaîne à chaque changement. 20 000 caractères
arrivant par morceaux : **19 893 ms**. En figeant les blocs terminés et en ne
gardant vivant que le dernier (`MarkdownStream`) : **174 ms** — ×114. La découpe
elle-même coûte 0,8 ms.

### Un `AsyncStream` n'a qu'un seul consommateur

**Le bug le plus coûteux du projet.** `ACPConnection.events` était un flux
unique partagé. Un `AsyncStream` est mono-consommateur : chaque élément part
chez *un* itérateur, pas chez tous. Dès la deuxième conversation ouverte, deux
boucles tiraient dessus et chacune jetait ce qui ne portait pas son `sessionId`.

À l'écran : un outil sans titre, un `tool_call_update` promu en appel neuf donc
affiché « Other », une réponse coupée au milieu. Environ une trame sur deux
disparaissait.

Corrigé par une vraie diffusion (un flux par abonné). Verrouillé par
`ConversationFlowTests`, qui ouvre **deux** fils et rejoue la capture d'un tour
réel — le test tombe sur l'ancien code avec exactement le symptôme observé.

### Tester l'UI, c'est s'en servir

Au moment de ce bug : 15 tests de bout en bout au vert, 21 tests unitaires au
vert, des captures de chaque écran. Et un tour posé depuis l'app perdait la
moitié de ses trames. Aucune de ces vérifications ne franchissait le chemin
complet « je tape une question → je lis ce qui s'affiche ».

D'où `Tools/ui-check.sh`, qui le franchit — et qui ouvre **deux** conversations
avant de poser la question, parce que plusieurs défauts ne se manifestent qu'à
partir de la deuxième.

### La fin d'un tour arrivait avant sa dernière phrase

La réponse à `session/prompt` et les derniers morceaux de texte arrivent dans la
même lecture du socket, et la réponse gagne. Le curseur s'éteignait sur une
réponse encore en train de s'écrire, et l'aperçu de la notification partait
vide. La fin de tour passe maintenant **dans** la file d'événements, donc
derrière tout ce qui la précède.

### Le fil racontait dans le désordre

Le serveur donnait un seul `messageId` à tout un tour. Les phrases écrites après
les commandes retrouvaient le bloc ouvert **avant** elles et s'y collaient : la
conclusion s'affichait au-dessus des commandes qui l'avaient produite. Un
identifiant par message (`message_start`), et l'ordre est rétabli.

### Écrit sur disque, oublié en mémoire

`session/set_config_option` répondait « OK » pour le modèle et ne changeait
rien : le serveur écrivait le fichier sans mettre à jour `bot.state["model"]`.
Le relais Telegram, lui, a toujours fait les deux.

### Deux tours sur une même conversation

Aucun garde : envoyer pendant que l'agent travaillait lançait un second
processus sur le même fichier de session. Symptôme visible : une passation
fantôme — le tour en vol n'avait pas encore posé son repère, donc le second
croyait découvrir une conversation dont il menait déjà la moitié. Refusé côté
serveur, et impossible côté app depuis que le bouton devient un arrêt.

### Codex paraissait figé

Il passait par un appel bloquant non suivi : rien ne s'affichait avant la fin, et
le bouton d'arrêt ne l'atteignait pas. `codex exec --json` n'émet pas de jetons,
mais il émet **chaque élément dès qu'il est terminé** — message, commande, sortie,
code de retour. Assez pour que le fil vive. Et le processus est désormais suivi,
donc interruptible.

Une réponse de pure prose reste toutefois un seul élément : « compte jusqu'à
1000 » pouvait donc réfléchir plusieurs minutes sans produire la moindre trame.
Le serveur ouvre maintenant un bloc de raisonnement dès le lancement. Il relève
aussi la limite de ligne JSON au-delà des 64 Kio d'`asyncio`, utilise le fichier
de réponse finale comme filet, et refuse un faux succès (`exit 0` sans message)
au lieu de terminer silencieusement le tour.

### La première action faisait tomber la radiographie

Avec un seul outil dans le fil, la chronologie construisait un `Slider` SwiftUI
sur `0...0` avec un pas de 1. SwiftUI déclenche alors une assertion dans
`Normalizing.init` **pendant l'initialisation** : poser `.disabled(true)` après
ne peut rien sauver. C'est exactement la pile des deux crashs relevés sur
l'iPhone pendant le test Office Chess.

Le curseur n'existe désormais qu'à partir de deux actions ; la première a son
propre état statique. Ce cas est verrouillé à la fois dans le modèle et par un
rendu SwiftUI réel avec `ImageRenderer`.

Le crash masquait deux autres trous : Codex n'attachait aucun `locations` à ses
commandes et ses événements `file_change` étaient ignorés ; puis une reconnexion
rejouait seulement les phrases, donc vidait la carte. `radiography.py` localise
les chemins factuels des commandes et traduit chaque fichier modifié en région.
`continuity.py` conserve maintenant les métadonnées compactes des outils — sans
leurs grosses sorties — et les rejoue dans l'ordre demande → actions → réponse.

Vérification réelle : sur Office Chess, Codex a lu
`office_chess/database.py`; les deux mises à jour localisées sont apparues en
direct puis après une nouvelle connexion. Le test supprime sa session et remet
les réglages en place.

### La capsule Modèle ne proposait que Sol

Le relais réduisait Codex à `CODEX_MODEL`. Il lit maintenant le catalogue que
le CLI maintient dans `models_cache.json`, donc Hublot propose exactement les
modèles visibles et autorisés pour le compte. Le choix est persisté dans
`state/codex-model`, utilisé par le prochain `codex exec --model`, et
immédiatement reflété dans la barre de statut.

Les efforts sont propres au modèle : changer vers Luna ou un ancien modèle
retire automatiquement les niveaux que celui-ci ne supporte pas et rabat la
valeur courante sur le niveau compatible le plus proche.

### Claude sélectionné affichait GPT-5.6 quand son quota était vide

Deux états avaient été confondus : le moteur **configuré** dans le menu et le
moteur **effectif** qui exécute le prochain tour. Quand Claude atteignait 100 %,
le relais effectif devenait Codex ; `_config_options()` s'en servait aussi pour
fabriquer le menu, d'où la combinaison impossible « Claude · GPT-5.6 ».

Les menus suivent maintenant le choix explicite, même indisponible : choisir
Claude expose et modifie ses modèles et son effort. Au repos, la barre suit elle
aussi immédiatement ce choix — moteur, modèle et quotas. Pendant un tour, le
moteur qui exécute réellement garde la priorité : une relève Codex reste donc
visible au moment où elle travaille. Le test E2E reproduit le cas quota épuisé,
vérifie qu'aucun modèle GPT ne fuit dans le menu Claude et que la barre bascule
dès la sélection.

### Les conversations ne se supprimaient qu'en appui long

La liste était un `ScrollView` personnalisé : joli, mais incapable de recevoir
les `swipeActions` natives de SwiftUI. Elle est maintenant une `List` dont les
fonds et séparateurs sont masqués pour conserver les cartes Hublot. Un balayage
vers la gauche révèle le bouton rouge « Supprimer » et un balayage complet le
déclenche. Le bouton est déjà une intention destructive explicite : il efface
donc directement, sans imposer une seconde confirmation.

### La régression que j'ai introduite

En retirant les envois Telegram de `confirm_hook.py`, la **ligne de définition**
d'une fonction a sauté en gardant son corps. Le hook plantait à l'import, sortait
en code 1, et Claude Code interprète ça comme « erreur de hook, on continue ».
**Le garde-fou anti-commandes-dangereuses est resté hors service de 08 h 24 à
19 h 13 le 6 août 2026**, Telegram compris. Restauré depuis sauvegarde, retrait
refait sur l'arbre syntaxique, avec une vérification qui exécute réellement le
hook.

### Autres, plus courtes

- `ISO8601DateFormatter` n'accepte que **trois** décimales de seconde ; Python en
  écrit six, et le refus faisait échouer tout le bloc qui contenait la date.
- Un mauvais jeton était accepté (mise à niveau WebSocket **puis** fermeture) :
  vérifié avant la poignée de main désormais, `401` et rien d'autre.
- Toutes les erreurs renvoyaient `-32603` ; les codes JSON-RPC sont maintenant
  justes.
- Un matériau seul *éclaircit* le noir : le fondu sous le chrome dessinait un
  panneau gris. Teinté vers l'abysse, et sa zone pleine exprimée en points fixes
  — en fraction, elle glissait dès que le chrome grandissait.
- Groq répondait `403 · erreur 1010` : son pare-feu refuse `Python-urllib`. Rien
  à voir avec la clé, et le message ne le disait pas.
- Une commande ratée n'importe où dans l'historique peignait le fond en rouge à
  vie. C'est le dernier événement qui décide, pas le pire de tous.

---

## Où ça en est

**Fait** — connexion permanente et reconnexion silencieuse ; projets lus par un
vrai `ls` ; conversations listées, reprises, supprimées, plusieurs par dépôt ;
streaming avec outils repliables, plans, permissions en ligne ; bascule de
moteur avec passation en delta ; réglages décrits par l'agent (moteur, modèle,
effort, permissions) ; commandes slash de Claude ; visionneuse de `CLAUDE.md` ;
barre de statut `5H: 46% · ↻3:46 · CTX 10%` ; notifications locales ; bouton
d'arrêt ; dictée vocale via Groq (`whisper-large-v3-turbo`, clé côté VPS) ;
radiographie spatiale des régions observées, avec chronologie et rejeu.

**En cours** — envoi de photos dans le fil ; veille de nuit (file de tâches,
étalement selon la fenêtre de quota, page « fait / bloqué / à trancher » au
réveil).

**Connu, non traité** — pas de notifications push (exige le programme
développeur payant, 99 $/an) ; le profil de signature gratuit **expire au bout
de 7 jours** et l'app doit être réinstallée ; les diffs voyagent en texte plutôt
qu'en `ToolCallContent.diff` ; Codex n'a pas de streaming mot à mot (son CLI n'en
émet pas).

## Idées retenues pour la suite

1. **La tour de contrôle** — plusieurs agents en parallèle, l'écran des projets
   devenant un tableau vivant plutôt qu'une liste.
2. **Le filet** — un point de reprise git avant chaque tour, et « revenir avant
   ceci » sur chaque bloc. C'est ce qui rend l'autonomie supportable.
3. **Live Activity** sur la Dynamic Island pour les demandes d'autorisation
   (exige le compte payant).
4. **Widget et Siri** — l'état des agents sans ouvrir l'app.
5. **Reprise sur le Mac** — un geste qui copie la commande reprenant la
   conversation dans le terminal.
