# Phase 0 — Recherche

Ce qu'il fallait établir avant d'écrire une ligne de test, et ce que le dépôt répond.

## 1. Comment un nouveau fichier de test entre dans la cible

**Décision** : déposer les fichiers `.swift` dans `IAClient-UIScreenTests/`, sans toucher au
projet Xcode.

**Justification** : `IAClient-UI.xcodeproj/project.pbxproj` déclare trois
`PBXFileSystemSynchronizedRootGroup` — l'app et les deux cibles de test. Tout fichier posé
dans le dossier est compilé dans sa cible sans édition du projet.

**Alternatives écartées** : éditer `project.pbxproj` à la main (source de conflits, inutile
ici).

## 2. Où déclarer un nouvel état déterministe

**Décision** : un cas de plus dans `HublotUITestScenario`, branché dans le `switch` de
`IAClient_UIApp`, rendu par une fixture `private struct` du même fichier.

**Justification** : c'est le point d'entrée unique déjà en place, entièrement sous
`#if DEBUG`. Les tests le pilotent par `-HublotUITestScenario <nom>`, ce que
`HublotUITestCase.launch` fait déjà.

**Alternatives écartées** : des `UserDefaults` par écran (l'ancien mécanisme, encore
reconnu pour migration, mais qui laisse fuir l'état d'un lancement à l'autre).

## 3. Comment obtenir un état non trivial sans réseau

**Décision** : deux mécanismes, choisis selon ce que le test doit prouver.

- Un **modèle témoin** (`AppModel.demo`, `AppModel.demoSessions`) quand seul l'affichage et
  le geste comptent. `isDemo` neutralise les appels sortants.
- Un **relais témoin** — un `actor` conforme à `ACPTransport` injecté par
  `HublotEnvironment.ephemeral(makeConnection:)` — quand le test doit prouver un
  aller-retour : ouvrir puis revenir, changer un réglage, lancer un tour.

**Justification** : trois relais témoins existent déjà (`ConcurrentConversationsTransport`,
`ConversationAgeTransport`, `EngineSwitchTransport`) et c'est ce qui a permis d'attraper des
bugs qu'un écran figé n'aurait jamais montrés — la date réécrite par l'app, la cellule de
quota disparue.

**Alternatives écartées** : un vrai serveur local (interdit par la constitution : aucune
dépendance extérieure), des captures rejouées (interdit par le principe III).

## 4. Ce que XCUITest ne peut pas piloter

**Décision** : ne pas tester ces chemins par l'interface, et le dire.

| Chemin | Raison | Ce qu'on teste à la place |
|---|---|---|
| `PhotosPicker` | interface système hors processus, contenu de photothèque non déterministe | l'état « pièce jointe présente » forcé par un scénario, puis le retrait au toucher |
| Autorisation micro | boîte système, non rejouable | le repli d'invite « Micro refusé » à partir d'un état de dictée forcé |
| Notifications | idem | rien côté interface |
| Presse-papiers | lisible, mais `UIPasteboard` d'un autre processus n'est pas accessible depuis le runner | la présence et la sensibilité au toucher du bouton de copie |

**Justification** : un test qui dépend d'une boîte système est un test instable ; la
constitution exige une suite reproductible (SC-005).

## 5. Forcer les réglages d'accessibilité au lancement

**Décision** : passer les arguments de lancement déjà employés —
`-UIAccessibilityReduceMotionEnabled YES` — et, pour la taille du texte,
`-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityL`.

**Justification** : `HublotMotion.isReduced` lit déjà l'environnement SwiftUI alimenté par le
premier ; le second est l'argument reconnu par UIKit pour imposer une catégorie de taille
sans passer par les Réglages.

**Alternatives écartées** : `simctl ui` (modifie l'appareil pour tous les tests parallèles,
donc dépendance d'ordre — interdite par FR-011).

## 6. Rotation et géométrie

**Décision** : `XCUIDevice.shared.orientation`, avec remise en portrait dans `tearDown` —
déjà fait par `HublotUITestCase`.

**Justification** : le paysage est déjà couvert sur le fil ; l'étendre aux autres écrans ne
demande aucun outillage neuf. `assertInsideScreen` fournit déjà le critère de
non-débordement.

## 7. Traction pour rafraîchir

**Décision** : `swipeDown()` sur la vue défilante depuis une coordonnée haute, puis assertion
sur la persistance du contenu et sur l'absence d'état d'erreur.

**Justification** : `refreshable` est branché sur `loadProjects` / `loadSessions` ; sur un
modèle témoin ces appels ne partent pas, donc le test ne peut prouver que la non-régression
d'affichage. Le rechargement réel se prouve sur un relais témoin qui compte ses appels.

## 8. Ce qui existe dans le code mais n'est pas atteignable

**Constat** : la palette de commandes `/`.

`Composer.matches` calcule la liste filtrée, `CommandPalette` sait la dessiner — mais le
corps du composer ne la rend jamais, et `RootView` ne passe jamais `commands:` à
`ConversationView`. `ChatSession.commands` est pourtant bien alimenté par
`available_commands_update`.

**Décision** : ne pas écrire de test qui l'atteindrait par un chemin artificiel. Le signaler
(FR-010). L'activer est une feature, pas une couverture.

## 9. Éviter l'instabilité

**Décision** : trois règles pour chaque nouveau test.

1. Aucun `sleep` fixe pour attendre un élément : `waitForExistence` /
   `XCTNSPredicateExpectation`. Les pauses ne restent que pour prouver une **absence** de
   mouvement (le fil qui ne saute pas).
2. Aucun test ne dépend d'un autre : chaque cas relance l'app avec son scénario.
3. Les libellés comparés passent par `plainLabel` — la typographie française pose des
   espaces insécables qu'un clavier ne reproduit pas.
