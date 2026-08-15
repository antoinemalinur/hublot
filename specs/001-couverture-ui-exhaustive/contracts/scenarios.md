# Contrat — états déterministes

Chaque état est nommé, lancé par `-HublotUITestScenario <nom>`, et rend toujours le même
écran. Les états existants ne changent pas ; ceux qui suivent s'ajoutent.

## Existants (inchangés)

`connection` · `projects` · `projects-prompt-age` · `projects-empty` · `projects-error` ·
`sessions` · `sessions-empty` · `sessions-error` · `sessions-instructions` ·
`concurrent-conversations` · `conversation-age` · `engine-switch-quota` · `conversation` ·
`conversation-working` · `codex-quota` · `active-engine-lock` · `context-tide` ·
`radiography` · `radiography-dense`

## Nouveaux

| Nom | Mécanisme | Ce qu'il garantit |
|---|---|---|
| `navigation` | relais témoin | Un dépôt `hublot`, une conversation `Reprendre le fil`. L'app démarre sur la liste des dépôts. Permet dépôt → conversations → fil → retour → retour → déconnexion. |
| `connection-busy` | relais témoin | `connect()` ne rend jamais la main : le bouton reste sur « Connexion… », inactif. |
| `connection-failure` | relais témoin | `connect()` échoue avec « Le serveur a refusé le jeton. » |
| `projects-variants` | données figées | Quatre dépôts : un vide (0 conversation), un à une seule conversation, un avec deux tours en cours, un au nom très long. |
| `projects-reload` | relais témoin | Le premier `hublot/projects` rend `avant-rechargement`, les suivants rendent `apres-rechargement`. |
| `sessions-variants` | données figées | Trois conversations : la plus récente, une à un seul échange, une ancienne. Aucun fichier d'instructions. |
| `sessions-reload` | relais témoin | Le premier `session/list` rend `avant-rechargement`, les suivants `apres-rechargement`. Ajouté en cours de route : sans lui, une liste rechargée et une liste jamais relue sont indistinguables. |
| `sessions-instructions-long` | données figées | Le même écran que `sessions-instructions`, avec un règlement assez long pour défiler. L'état court reste inchangé — c'est lui que la référence visuelle photographie. |
| `thread-blocks` | données figées | Un fil portant un exemplaire de chaque bloc : message avec image, prose, raisonnement, appel isolé avec diff, appel en échec avec sortie de terminal, bloc de code, permission en attente, permission déjà tranchée. |
| `thread-growing` | données figées animées | Un fil de dix tours auquel un onzième s'ajoute une seconde et demie après l'affichage. |
| `chrome-plan` | données figées | Un plan de quatre jalons dont deux franchis. |
| `chrome-lost` | données figées | Dernier signe de vie reçu vingt-cinq secondes plus tôt. |
| `chrome-quiet` | données figées | Moteur muet depuis soixante secondes, liaison vivante. |
| `chrome-reconnecting` | données figées | `isReconnecting` vrai. |
| `chrome-silent` | données figées | Ni statut ni pourcentage de contexte. |
| `composer-attachment` | données figées | Une pièce jointe déjà présente dans le composer. |
| `composer-refused-mic` | données figées | Dictée en état `refused`. |
| `context-tide-empty` | données figées | Aucune mesure. |
| `context-tide-finished` | données figées | Mesures présentes, fil terminé. |
| `radiography-empty` | données figées | Fil sans aucun appel d'outil. |
| `holding-launch` | données figées | Écran d'attente au lancement, délai d'issue de secours raccourci. |
| `holding-reconnect` | données figées | Écran de reprise en cours de route. |

## Arguments de lancement reconnus

| Argument | Effet | Origine |
|---|---|---|
| `-HublotUITestScenario <nom>` | choisit l'état | existant |
| `-HublotSnapshotMode YES` | fige les animations pour les références visuelles | existant |
| `-UIAccessibilityReduceMotionEnabled YES` | réduit les animations | système |
| `-UIPreferredContentSizeCategoryName <catégorie>` | impose une taille de texte | système |
| `-HublotHoldingDelay <secondes>` | raccourcit le délai avant l'issue de secours de l'écran d'attente | **nouveau**, `#if DEBUG` |
| `-HublotGrowingDelay <secondes>` | recule l'arrivée du tour supplémentaire de `thread-growing`, le temps que le test se place | **nouveau**, `#if DEBUG` |

Une correction à noter sur `-UIAccessibilityReduceMotionEnabled` : cet argument
**ne change pas** `accessibilityReduceMotion` sur iOS 26. `HublotMotion.isReduced`
le lit donc à la main sous `#if DEBUG`. Mesures et raisonnement dans `data-model.md`.

## Règles

1. Toute fixture ajoutée DOIT être atteinte par au moins un test — sinon elle fait baisser
   la couverture de la cible sans rien prouver.
2. Un relais témoin ne dort jamais pour simuler une latence, sauf là où l'attente **est**
   le sujet (`connection-busy`, `thread-growing`).
3. Aucun état ne lit ni n'écrit `UserDefaults` ni le trousseau : tous passent par
   `HublotEnvironment.ephemeral`.
