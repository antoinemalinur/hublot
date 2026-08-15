---

description: "Tâches d'implémentation — couverture UI exhaustive"
---

# Tasks: Couverture UI exhaustive

**Input**: Design documents from `/specs/001-couverture-ui-exhaustive/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: cette feature *est* une feature de tests. Chaque tâche de « story » produit des
tests XCUITest ; les tâches d'app (scénarios témoins, identifiants) sont ce qui leur donne
prise.

## Format: `[ID] [P?] [Story] Description`

- **[P]** : parallélisable (fichier distinct, aucune dépendance en attente)
- **[Story]** : US1…US7, tel que numéroté dans `spec.md`

## Path Conventions

- App : `IAClient-UI/`
- Tests d'interface : `IAClient-UIScreenTests/`

---

## Phase 1: Setup

**Purpose**: partir d'une base verte et connue.

- [x] T001 Exécuter la suite d'interface existante seule pour établir la référence :
  `xcodebuild test -project IAClient-UI.xcodeproj -scheme IAClient-UI -testPlan IAClient-UI -destination "platform=iOS Simulator,name=iPhone Air" -only-testing:IAClient-UIScreenTests`
- [x] T002 Relever la liste exacte des tests existants et leur durée depuis le journal, pour
  vérifier en fin de parcours qu'aucun n'a changé de comportement

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: les coutures partagées par plusieurs stories. Rien ne peut être écrit avant.

**⚠️ CRITICAL**: sans ces tâches, la moitié des gestes n'a aucune prise.

- [x] T003 Ajouter les aides partagées de test dans
  `IAClient-UIScreenTests/ScreenTestSupport.swift` : attente d'un libellé par prédicat,
  assertion d'absence, lancement avec taille de texte accessible, recherche d'une rangée
  par identifiant
- [x] T004 Déclarer tous les nouveaux cas de `contracts/scenarios.md` dans
  `IAClient-UI/App/UITestScenario.swift`
- [x] T005 Ajouter la couture `-HublotHoldingDelay` dans `IAClient-UI/UI/HoldingView.swift`
  (sous `#if DEBUG`, valeur par défaut inchangée à 10 s) et l'identifiant `holding-escape`
- [x] T006 Ajouter la couture d'amorçage du composer dans
  `IAClient-UI/UI/ConversationView.swift` (sous `#if DEBUG` : pièces jointes initiales et
  phase de dictée imposée) et l'`init(debugPhase:)` de `IAClient-UI/Domain/Dictation.swift`
- [x] T007 Ajouter le paramètre « sans instructions » à `AppModel.demoSessions` dans
  `IAClient-UI/App/AppModel.swift`

**Checkpoint**: les scénarios peuvent être branchés et les tests écrits en parallèle.

---

## Phase 3: User Story 1 — Les gestes qui font entrer dans l'app (Priority: P1) 🎯 MVP

**Goal**: prouver qu'on peut entrer dans un fil et en ressortir, et que le formulaire de
connexion dit la vérité dans chacun de ses états.

**Independent Test**: `-only-testing:IAClient-UIScreenTests/NavigationScreenTests` et
`ConnectionScreenMoreTests` passent seuls, sans réseau.

- [x] T008 [US1] Ajouter les identifiants `disconnect`, `sessions-back`,
  `project-row-<nom>`, `session-row-<id>` dans `IAClient-UI/UI/ProjectsView.swift` et
  `IAClient-UI/UI/SessionsView.swift`
- [x] T009 [US1] Écrire le relais témoin et la fixture du scénario `navigation` dans
  `IAClient-UI/IAClient_UIApp.swift` (démarrage sur la liste des dépôts, un dépôt, une
  conversation reprenable, déconnexion possible)
- [x] T010 [P] [US1] Écrire les fixtures `connection-busy` et `connection-failure` dans
  `IAClient-UI/IAClient_UIApp.swift`
- [x] T011 [US1] Écrire `IAClient-UIScreenTests/NavigationScreenTests.swift` : dépôt →
  conversations (P6), retour vers les dépôts (S8), conversation → fil → retour (F15),
  déconnexion (P7)
- [x] T012 [P] [US1] Écrire `IAClient-UIScreenTests/ConnectionScreenMoreTests.swift` : un
  seul champ rempli (C3), bouton occupé (C4), panne annoncée (C5), jeton masqué (C6),
  clavier retiré au défilement (C7)
- [x] T013 [US1] Vérifier par mutation chaque test de T011 et T012 (retirer la ligne
  protégée, constater l'échec, la remettre)

**Checkpoint**: le chemin d'entrée de l'app est tenu de bout en bout.

---

## Phase 4: User Story 2 — Écrire, envoyer, joindre, interrompre (Priority: P1)

**Goal**: couvrir tout ce qui part du composer.

**Independent Test**: `-only-testing:IAClient-UIScreenTests/ComposerScreenMoreTests`.

- [x] T014 [US2] Ajouter les identifiants `attachment-chip` et `attachment-remove` dans
  `IAClient-UI/UI/ConversationView.swift`
- [x] T015 [US2] Écrire les fixtures `composer-attachment` et `composer-refused-mic` dans
  `IAClient-UI/IAClient_UIApp.swift`
- [x] T016 [US2] Étendre la fixture `conversation-working` pour accepter deux mises en file
  successives dans `IAClient-UI/IAClient_UIApp.swift`
- [x] T017 [US2] Écrire `IAClient-UIScreenTests/ComposerScreenMoreTests.swift` : bascule
  micro→envoi du bouton d'action (M3), effacement puis retour de la rangée de réglages (M4),
  choix d'une valeur de réglage (M5), deuxième message en file (M6), retrait d'une pièce
  jointe (M7), invite de micro refusé (M8)
- [x] T018 [US2] Vérifier par mutation chaque test de T017

**Checkpoint**: aucune action de l'utilisateur sur la machine n'est plus sans filet.

---

## Phase 5: User Story 3 — Lire le fil et ce qu'il contient (Priority: P2)

**Goal**: chaque type de bloc et son pli.

**Independent Test**: `-only-testing:IAClient-UIScreenTests/ThreadBlocksScreenTests`.

- [x] T019 [US3] Ajouter l'identifiant `copy-code` dans
  `IAClient-UI/Render/HublotTheme.swift`
- [x] T020 [US3] Écrire la fixture `thread-blocks` dans `IAClient-UI/IAClient_UIApp.swift` :
  message avec image, prose, raisonnement, appel isolé avec diff, appel en échec avec sortie
  de terminal, bloc de code, permission en attente, permission tranchée
- [x] T021 [US3] Écrire `IAClient-UIScreenTests/ThreadBlocksScreenTests.swift` : pli d'un
  appel isolé (B2), échec déjà ouvert (B3), raisonnement (B4), réponse à une permission
  (B5), permission déjà tranchée (B6), marqueurs de diff (B7), sortie de terminal (B8),
  bouton de copie (B9), images d'un message (B10)
- [x] T022 [US3] Vérifier par mutation chaque test de T021

---

## Phase 6: User Story 4 — Suivre ce que la machine fait (Priority: P2)

**Goal**: le chrome haut dans chacun de ses états, et le comportement du fil qui grandit.

**Independent Test**: `-only-testing:IAClient-UIScreenTests/ChromeScreenTests`.

- [x] T023 [US4] Ajouter les identifiants `plan-capsule` et `reconnecting-banner` dans
  `IAClient-UI/UI/ConversationView.swift`
- [x] T024 [P] [US4] Écrire les fixtures `chrome-plan`, `chrome-lost`, `chrome-quiet`,
  `chrome-reconnecting`, `chrome-silent` dans `IAClient-UI/IAClient_UIApp.swift`
- [x] T025 [P] [US4] Écrire la fixture `thread-growing` dans
  `IAClient-UI/IAClient_UIApp.swift`
- [x] T026 [US4] Écrire `IAClient-UIScreenTests/ChromeScreenTests.swift` : dépliage du plan
  (F8), absence de signal (F9), silence du moteur (F10), bandeau de reprise (F11), barre
  absente (F12), suivi du fil en bas (F13), absence de saut après défilement (F14)
- [x] T027 [US4] Vérifier par mutation chaque test de T026

---

## Phase 7: User Story 5 — Les deux écrans d'analyse (Priority: P2)

**Goal**: inspection au toucher, états vides, chronologie.

**Independent Test**: `-only-testing:IAClient-UIScreenTests/RadiographyScreenMoreTests` et
`ContextTideScreenMoreTests`.

- [x] T028 [US5] Ajouter les identifiants `region-<nom>`, `region-inspector`,
  `radiography-legend` dans `IAClient-UI/UI/RadiographyView.swift` et `tide-inspector` dans
  `IAClient-UI/UI/ContextTideView.swift`
- [x] T029 [P] [US5] Écrire les fixtures `radiography-empty`, `context-tide-empty`,
  `context-tide-finished` dans `IAClient-UI/IAClient_UIApp.swift`
- [x] T030 [P] [US5] Écrire
  `IAClient-UIScreenTests/RadiographyScreenMoreTests.swift` : sélection et désélection d'une
  région (R3), légende (R4), chronologie figée (R5), état vide (R6), région en échec (R7)
- [x] T031 [P] [US5] Écrire
  `IAClient-UIScreenTests/ContextTideScreenMoreTests.swift` : inspecteur complet (T3), état
  vide (T4), fil terminé et « Revenir à la fin » (T5), sommet dépassé (T6)
- [x] T032 [US5] Vérifier par mutation chaque test de T030 et T031

---

## Phase 8: User Story 6 — Les écrans de bord (Priority: P3)

**Goal**: attente, reprise, instructions, rafraîchissement.

**Independent Test**: `-only-testing:IAClient-UIScreenTests/SessionsScreenMoreTests` et
`ProjectsScreenMoreTests`.

- [x] T033 [US6] Ajouter les identifiants `instructions-button` et `create-project` dans
  `IAClient-UI/UI/InstructionsSheet.swift` et `IAClient-UI/UI/ProjectsView.swift`
- [x] T034 [P] [US6] Écrire les fixtures `holding-launch` et `holding-reconnect` dans
  `IAClient-UI/IAClient_UIApp.swift`
- [x] T035 [P] [US6] Écrire les fixtures `projects-variants`, `projects-reload` et
  `sessions-variants` dans `IAClient-UI/IAClient_UIApp.swift`
- [x] T036 [P] [US6] Écrire `IAClient-UIScreenTests/ProjectsScreenMoreTests.swift` : dépôt
  qui travaille (P8), deux tours (P9), pluriels et vide (P10), activation du bouton « Créer »
  (P11), création au bouton (P12), rechargement par traction (P13), nom trop long (P14)
- [x] T037 [P] [US6] Écrire `IAClient-UIScreenTests/SessionsScreenMoreTests.swift` :
  balayage partiel (S9), marque « dernière » (S10), singulier d'un échange (S11), absence du
  bouton d'instructions (S12), défilement de la feuille (S13), rechargement (S14)
- [x] T038 [P] [US6] Écrire `IAClient-UIScreenTests/HoldingScreenTests.swift` : écran de
  lancement (H1), issue de secours tardive (H2), écran de reprise (H3)
- [x] T039 [US6] Vérifier par mutation chaque test de T036, T037 et T038

---

## Phase 9: User Story 7 — Tenir dans tous les cadres (Priority: P3)

**Goal**: rotation, grande taille de texte, animations réduites.

**Independent Test**: `-only-testing:IAClient-UIScreenTests/AccessibilityScreenTests`.

- [x] T040 [US7] Écrire `IAClient-UIScreenTests/AccessibilityScreenTests.swift` : paysage
  sur les dépôts et les conversations (A2), taille de caractères accessible (A3), animations
  réduites sur la marée et la radiographie (A4)
- [x] T041 [US7] Vérifier par mutation les assertions de géométrie de T040

---

## Phase 10: Polish & Cross-Cutting Concerns

- [x] T042 Relire `specs/001-couverture-ui-exhaustive/data-model.md` et remplacer chaque ➕
  par le nom du test qui le porte
- [x] T043 Vérifier qu'aucune fixture `#if DEBUG` ajoutée n'est orpheline : chacune est
  atteinte par au moins un test
- [x] T044 Exécuter `Tools/test-local.sh full` en entier et rapporter le résultat tel quel
- [x] T045 Exécuter la suite une seconde fois pour prouver l'absence de test instable
  (SC-005)
- [x] T046 Consigner dans `README.md` la façon de lancer un état témoin à l'œil nu et la
  liste des états disponibles
- [x] T047 Signaler la palette de commandes `/` comme code mort (FR-010) : constat écrit,
  aucune modification de comportement

---

## Dependencies

```text
Phase 1 (T001-T002)
    ↓
Phase 2 (T003-T007)  ← bloquant pour tout le reste
    ↓
    ├── Phase 3 US1 (T008-T013)   P1
    ├── Phase 4 US2 (T014-T018)   P1
    ├── Phase 5 US3 (T019-T022)   P2
    ├── Phase 6 US4 (T023-T027)   P2
    ├── Phase 7 US5 (T028-T032)   P2
    ├── Phase 8 US6 (T033-T039)   P3
    └── Phase 9 US7 (T040-T041)   P3
            ↓
        Phase 10 (T042-T047)
```

Les stories sont indépendantes entre elles : chacune touche ses propres fichiers de test.
Le seul point de contact est `IAClient_UIApp.swift`, où toutes ajoutent des fixtures — à
sérialiser si plusieurs mains travaillent en même temps.

## Parallel Execution Examples

- Après la Phase 2 : T010, T024, T025, T029, T034, T035 (fixtures dans des zones distinctes
  du même fichier) puis, une fois leurs scénarios en place, T012, T030, T031, T036, T037,
  T038 en parallèle (fichiers de test distincts).

## Implementation Strategy

**MVP** : Phases 1 à 3. Le chemin d'entrée de l'app est alors tenu, ce qui est la
régression la plus coûteuse.

**Incréments suivants** : US2 (l'action de l'utilisateur), puis US3–US5 (la lecture et
l'analyse), puis US6–US7 (les bords et les cadres). Chaque phase se termine par sa
vérification par mutation — sans elle, la phase n'est pas finie.

---

## Écarts au plan, et pourquoi

Le plan a tenu, à quatre détails près — tous constatés en chemin, aucun décidé
d'avance.

**Les fixtures ne vivent pas dans `IAClient_UIApp.swift`.** Vingt et un états
témoins y auraient ajouté quinze cents lignes. Ils sont dans
`App/ScreenFixtures.swift` et `App/ThreadFixtures.swift` ; le fichier d'entrée ne
porte plus que l'aiguillage.

**Deux états de plus que prévu.** `sessions-instructions-long`, parce que le
document court est verrouillé par une référence visuelle et qu'il n'y a rien à
faire défiler dedans. `sessions-reload`, parce que le test de traction sur les
conversations ne prouvait rien sans un relais qui réponde deux choses
différentes — il a survécu à sa mutation, et c'est ce qui l'a révélé.

**Un identifiant de plus** : `message-image`, sans lequel les vignettes d'une
demande ne sont pas visables.

**Un geste retiré de la couverture.** « Le canevas cesse de peindre » sous
animations réduites n'est pas observable depuis XCUITest — trois mesures le
montrent, dans `data-model.md`. Le test vérifie ce qui s'observe. En le
cherchant, on a trouvé mieux : `-UIAccessibilityReduceMotionEnabled` ne coupait
rien du tout, et les tests qui le passaient depuis toujours ne testaient pas ce
qu'ils annonçaient.
