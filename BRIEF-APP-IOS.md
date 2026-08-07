# BRIEF-APP-IOS

Document de passation. Écrit depuis le VPS le 5 août 2026, destiné à l'agent
(Claude Code ou Codex) qui travaillera **depuis le MacBook d'Antoine** sur une
application iOS native.

Il contient deux parties : l'**historique** de la décision (pourquoi on en est
là, et surtout ce qui a déjà été écarté), puis la **mission** proprement dite.

---

# Partie 1 — Comment on en est arrivé là

## Le point de départ

Antoine pilote ses projets depuis son téléphone via `tg-claude` : un pont
Telegram ↔ Claude Code qui tourne sur son VPS (`/opt/tg-claude`, service
systemd, ~1 700 lignes de Python stdlib). Le pont sait déjà beaucoup de choses :

- **bascule automatique Claude → Codex sur quota** : il lit l'instantané d'usage
  produit localement par `claude-usage-monitor` ; à 98 %, seules les *nouvelles*
  tâches partent chez Codex, une tâche en cours n'est jamais interrompue. Le
  retour est gouverné par la fenêtre hebdomadaire, pas par le rollover 5 h ;
- **passation de contexte** entre moteurs (`handoff.py`) : au *changement* de
  moteur seulement, le journal est condensé dans un fichier passé en prompt
  système au moteur entrant ;
- **sessions natives** (`claude --resume`, `codex exec resume`) ;
- **hook de confirmation** (`confirm_hook.py`, `PreToolUse`) pour les commandes
  dangereuses ;
- vocaux transcrits, images, file d'attente, `/switch`, `/model`, `/effort`.

Le problème : **la lisibilité des réponses dans Telegram**.

## Ce qui a été fait (et qui marche)

Un module `render.py` (~250 lignes, dans ce dépôt) a été écrit, testé
(26 tests dédiés, 97 au total, tous verts) et déployé. Il convertit le Markdown
des moteurs vers le HTML que Telegram accepte :

- gras, italique, barré, liens, code, blocs de code, citations ;
- titres → gras (Telegram n'a pas de titres) ;
- puces typographiques, niveaux imbriqués ;
- **découpe** sur frontière de paragraphe, jamais dans un mot, jamais dans une
  balise ni une entité, avec réouverture des balises ouvertes (un bloc de code
  de 6 000 caractères reste un bloc de code dans les deux messages) ;
- repli en texte nu si Telegram refuse le HTML, pour ne jamais perdre un contenu ;
- au-delà de 3 fragments, la réponse complète part en pièce jointe ;
- **tableaux Markdown** → colonnes alignées en monospace, avec bascule
  automatique en « fiches » (une par ligne) au-delà de 44 caractères de large.

C'est le plafond de la plateforme. Il est atteint.

## Ce qui a été exploré puis écarté — avec les raisons

Ne pas revenir sur ces pistes sans raison nouvelle : elles ont été mesurées.

- **Discord** : limite de 2 000 caractères par message contre 4 096 chez
  Telegram, donc *plus* de coupures. Embeds et boutons ne rendent pas un texte
  long plus lisible. Écarté.
- **Une page web par réponse** (HTML servi par Caddy, lien dans le message) :
  écarté par Antoine, qui veut **tout au même endroit**, sans clic. Argument
  décisif, pas négociable.
- **Raccourcir les réponses** : explicitement refusé. Antoine veut des réponses
  longues, elles lui donnent ses éléments de décision. Le sujet est la
  présentation, pas la longueur.
- **OpenClaw** (ex-Clawdbot/Moltbot) : assistant personnel open source qui relie
  les messageries à un agent. Écarté pour la sécurité : des chercheurs ont
  relevé 40 214 instances exposées, 63 % des déploiements vulnérables, 12 812
  exploitables en exécution de code à distance. L'agent tourne avec les
  privilèges de son hôte — ici root, avec tous les autres services du VPS.
- **OpenACP** (`Open-ACP/OpenACP`, le pont générique messagerie ↔ agents) :
  écarté parce que **l'organisation GitHub entière renvoie 404** (page, API,
  README brut) alors que le listing annonce encore 426 étoiles — vérifié depuis
  le VPS, d'autres dépôts répondant 200 au même moment. Impossible à lire, donc
  impossible à auditer. Son adaptateur Telegram amont ne gère d'ailleurs ni les
  DM ni les groupes simples (supergroupe à forum uniquement).
- **acp-ui** (`formulahendry/acp-ui`, 430 ★, client ACP multiplateforme, cible
  iOS compilable) : **écarté pour son ergonomie**. Antoine a regardé, ne trouve
  ni moderne ni agréable. C'est un rejet de design, pas de technique — son
  **protocole** reste la bonne référence, son interface n'est pas le modèle.

## Le constat qui commande tout le reste

Claude Desktop n'affiche pas mieux parce que le modèle écrirait mieux : il
affiche mieux **parce que c'est un navigateur**. Le modèle produit du Markdown
brut, identique partout ; c'est le *client* qui le passe dans un moteur de rendu
(famille remark/rehype avec l'extension GFM), le stylise en CSS et colorie le
code. La transformation coûte **zéro token** : elle est mécanique et
post-génération.

Conséquence : **la mise en forme est une propriété de la fenêtre, pas de la
sortie**. Telegram a une liste fermée d'entités et **aucune primitive de
tableau**. Aucun code ne peut en créer une.

D'où la décision : **une application iOS native**, sideloadée sur l'iPhone
d'Antoine, jamais publiée sur l'App Store.

## Contraintes déjà établies

- Antoine **a un Mac** — Xcode est disponible.
- **Signature** : un Apple ID gratuit suffit pour installer sur son propre
  appareil, mais le profil expire au bout de **7 jours** (réinstallation depuis
  Xcode), avec **3 apps** signées au maximum, et **sans notifications push**
  (capacité réservée au programme payant). Le programme payant (99 $/an) donne
  1 an et le push. **Décision : on démarre gratuit**, on paiera quand le push
  deviendra nécessaire.
- **La logique métier ne peut pas vivre dans l'app.** La bascule quota, la
  passation, les sessions, les permissions ont besoin d'un shell et des CLI
  installées ; iOS est en bac à sable et ne lance pas de sous-processus. Le
  serveur reste sur le VPS, l'app est une **vue**.
- **Le serveur parlera ACP** (Agent Client Protocol) même si le client est
  100 % maison : ça ne coûte pas plus cher à écrire et ça laisse un filet — on
  peut se brancher avec n'importe quel client existant pendant que l'app n'existe
  pas encore, ou le jour où elle casse.

---

# Partie 2 — Mission

> À lire par l'agent qui travaille depuis le MacBook.

## Objectif

Construire **une application iOS native, moderne et agréable**, qui remplace
Telegram comme *interface* de pilotage des agents de code d'Antoine, et qui
affiche enfin correctement ce que Telegram ne peut pas : tableaux, code coloré,
diffs, blocs repliables, texte sélectionnable.

Antoine la veut « extrêmement moderne, qui casse un peu les codes, très facile à
utiliser mais riche en fonctionnalités ». C'est une intention d'ambiance, pas une
spécification — **la traduire en propositions concrètes fait partie du travail**,
et il faut les lui montrer tôt, en captures.

## Répartition du travail

Le projet a deux moitiés, développées **en parallèle** :

| Moitié | Qui | Où |
|---|---|---|
| Serveur ACP | agent VPS | VPS |
| App iOS | toi | MacBook |

- **Serveur ACP (VPS, pas toi)** : un daemon qui expose la logique existante
  (bascule quota, passation, sessions, permissions) en ACP sur WebSocket,
  derrière Caddy en `wss://` avec authentification par jeton.
- **App iOS (toi)** : client ACP natif SwiftUI.

**Tu n'as pas besoin d'attendre le serveur pour commencer.** Fais tourner un
agent ACP de référence sur le Mac — `@agentclientprotocol/claude-agent-acp` —
et expose-le en `ws://` sur le réseau local pour que l'iPhone l'atteigne. Le
protocole est le contrat : si l'app parle ACP correctement, elle se branchera
sur le serveur du VPS sans modification.

## Périmètre v1 (le noyau, à faire tourner avant tout embellissement)

1. Connexion : URL du serveur + jeton, stockés dans le Keychain.
2. Liste des sessions, création, reprise.
3. Conversation en **streaming** (les réponses arrivent par morceaux).
4. **Rendu riche** : tableaux GFM, blocs de code avec coloration syntaxique,
   listes, citations, liens, texte sélectionnable et copiable.
5. Appels d'outils et raisonnement affichés en blocs **repliables**.
6. **Permissions** : autoriser / refuser en natif quand l'agent le demande.
7. Sélecteur de moteur (Claude / Codex), de modèle et d'effort.

Hors périmètre v1, à ne pas commencer : notifications push, vocal, images,
multi-utilisateur, édition de fichiers dans l'app, partage, iPad, widgets.

## Contraintes techniques

- **SwiftUI**, Swift 6, iOS 18 minimum. Pas de framework transverse (ni React
  Native, ni Flutter, ni Tauri) : c'est précisément ce qu'on fuit.
- Rendu Markdown par une vraie bibliothèque — `swift-markdown-ui` (MarkdownUI)
  ou `swift-markdown` d'Apple avec un rendu maison. **Les tableaux GFM sont un
  critère d'acceptation, pas une option.**
- WebSocket via `URLSessionWebSocketTask` (stdlib). ACP = JSON-RPC 2.0.
  Prévoir un heartbeat (`$/ping`) toutes les ~25 s : les proxys coupent les
  connexions inactives.
- Aucun service tiers, aucune télémétrie, aucun compte. Le jeton dans le
  Keychain, rien ailleurs.
- Reconnexion automatique au retour au premier plan, avec reprise de session.

## Méthode attendue

Antoine travaille de cette façon, et ça n'est pas négociable :

- **Un plan avant le code.** Montre l'architecture et l'écran principal avant
  d'écrire l'app entière.
- **Des captures à chaque étape.** Xcode 26.3 intègre le SDK Claude Agent avec
  vérification visuelle par les Previews : sers-t'en, regarde ce que tu
  construis, itère jusqu'à ce que ce soit juste.
- **Des chiffres mesurés, jamais estimés.** Antoine vérifie.
- **Tester sur l'appareil réel**, pas seulement dans le simulateur.
- Dire clairement ce qui n'a pas été fait, plutôt que de réduire le périmètre en
  silence.

## Références utiles

- Protocole : `agentclientprotocol/agent-client-protocol` (3 871 ★, Apache-2.0)
  et <https://agentclientprotocol.com/>. Couvre sessions, streaming, permissions,
  appels d'outils, diffs ; le Markdown est le format par défaut du contenu.
- Agent Claude Code : `@agentclientprotocol/claude-agent-acp`.
- Agent Codex : `@zed-industries/codex-acp`.
- `formulahendry/acp-ui` : **référence de protocole uniquement**. Son interface
  a été explicitement rejetée — ne pas s'en inspirer visuellement.
- `render.py`, dans ce dépôt : montre concrètement quelles constructions
  Markdown les moteurs produisent en pratique. Utile pour savoir ce que le
  moteur de rendu de l'app doit vraiment couvrir.

## À trancher avec Antoine avant de coder

- Le nom de l'app.
- La direction visuelle (sombre d'abord ? typographie dominante ? densité ?).
- Ce qui reste dans Telegram : l'alerte et la question rapide, ou plus rien.
