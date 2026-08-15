# Implementation Plan: Couverture UI exhaustive

**Branch**: `001-couverture-ui-exhaustive` | **Date**: 2026-08-14 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/001-couverture-ui-exhaustive/spec.md`

## Summary

Compléter la cible `IAClient-UIScreenTests` pour qu'un test XCUITest exerce chaque geste
atteignable de Hublot. L'approche : partir de l'inventaire des gestes offerts par les dix
écrans, soustraire ce que les 22 tests existants couvrent déjà, puis écrire le reste sous
forme de fichiers de test par écran, adossés à de nouveaux états déterministes déclarés
dans `HublotUITestScenario`. Là où un geste n'a pas de prise — pas d'identifiant
d'accessibilité — l'identifiant est ajouté côté app dans le même changement.

## Technical Context

**Language/Version**: Swift 6, SwiftUI (iOS 26 / Liquid Glass)

**Primary Dependencies**: XCTest / XCUITest, MarkdownUI, PhotosUI ; côté relais Python 3
(hors périmètre)

**Storage**: `UserDefaults` pour l'adresse du serveur, trousseau pour le jeton — remplacés
par `HublotEnvironment.ephemeral` dans tous les états témoins

**Testing**: `IAClient-UIScreenTests` (XCUITest, cible existante), plan `IAClient-UI`,
exécution par `Tools/test-local.sh full`

**Target Platform**: simulateur iPhone Air, iOS le plus récent disponible

**Project Type**: application mobile à écran unique par étape, plus un relais séparé

**Performance Goals**: phase de tests sous trois minutes à quatre workers (SC-004) ; le
budget actuel est de 161 s, l'ajout doit rester dans l'enveloppe

**Constraints**: aucun réseau, aucun accès à un autre dépôt, aucune boîte système, aucun
test ignoré, aucune dépendance d'ordre entre tests (exécution aléatoire déjà configurée
dans le plan)

**Scale/Scope**: 10 écrans, ~34 fichiers source d'interface, 22 tests d'interface
existants, ~60 gestes inventoriés dont ~40 non couverts

## Constitution Check

*GATE: à passer avant la Phase 0, à revérifier après la Phase 1.*

| Principe | Portée pour cette feature | Verdict |
|---|---|---|
| I. Régression couverte dans le même changement | La feature *est* la couverture ; tout identifiant d'accessibilité ajouté arrive avec le test qui l'utilise | ✅ |
| II. Le geste réel sur simulateur | Tous les nouveaux tests sont des XCUITest qui touchent, saisissent, balaient, tournent | ✅ |
| III. Un test doit exercer la feature | Interdiction des fixtures qui affirment le résultat ; les aller-retours passent par un relais témoin. Vérification par mutation exigée (FR-012) | ✅ |
| IV. Le bug rapporté reste couvert | Aucun test existant n'est supprimé ni affaibli ; les nouveaux fichiers s'ajoutent à côté | ✅ |
| V. Validation complète avant livraison | `Tools/test-local.sh full` en fin de parcours, résultat rapporté tel quel | ✅ |

**Post-Phase 1** : rien dans la conception ne demande de dérogation. Aucune entrée dans le
tableau de complexité.

Point de vigilance retenu : le seuil de couverture du script porte sur la cible
`IAClient-UI`. Ajouter des tests d'interface fait *monter* la couverture, jamais descendre —
mais ajouter des fixtures `#if DEBUG` non exercées la ferait baisser. Chaque fixture
introduite doit donc être atteinte par au moins un test.

## Project Structure

### Documentation (this feature)

```text
specs/001-couverture-ui-exhaustive/
├── plan.md              # ce fichier
├── spec.md              # la spécification
├── research.md          # Phase 0
├── data-model.md        # Phase 1 — inventaire des gestes et des scénarios
├── quickstart.md        # Phase 1 — comment exécuter et vérifier
├── contracts/
│   ├── scenarios.md     # contrat des états déterministes
│   └── identifiers.md   # contrat des identifiants d'accessibilité
├── checklists/
│   └── requirements.md
└── tasks.md             # Phase 2 (/speckit-tasks)
```

### Source Code (repository root)

```text
IAClient-UI/
├── App/
│   ├── UITestScenario.swift        # + les nouveaux cas d'énumération
│   └── AppModel.swift              # + fabriques témoins si nécessaire
├── IAClient_UIApp.swift            # + les fixtures et relais témoins
└── UI/                             # + identifiants d'accessibilité manquants
    ├── ConversationView.swift
    ├── ProjectsView.swift
    ├── SessionsView.swift
    ├── Blocks.swift
    ├── ContextTideView.swift
    ├── RadiographyView.swift
    └── HoldingView.swift

IAClient-UIScreenTests/
├── HublotScreenTests.swift         # inchangé — les 22 tests déjà livrés
├── VisualSnapshotScreenTests.swift # inchangé
├── NavigationScreenTests.swift     # nouveau — parcours d'entrée et retours
├── ConnectionScreenMoreTests.swift # nouveau — le formulaire dans tous ses états
├── ProjectsScreenMoreTests.swift   # nouveau — filtre, création, rafraîchissement
├── SessionsScreenMoreTests.swift   # nouveau — rangées, instructions, balayage partiel
├── ComposerScreenMoreTests.swift   # nouveau — pilules, file, pièces jointes, dictée
├── ThreadBlocksScreenTests.swift   # nouveau — chaque type de bloc et son pli
├── ChromeScreenTests.swift         # nouveau — plan, activité, reprise, barre absente
├── ContextTideScreenMoreTests.swift# nouveau — inspection, états, chronologie
├── RadiographyScreenMoreTests.swift# nouveau — sélection de région, états
└── AccessibilityScreenTests.swift  # nouveau — rotation, animations réduites, gros texte
```

**Structure Decision** : un fichier de test par écran, nommé d'après lui, à côté du fichier
historique qui reste intact. Les groupes du projet Xcode sont synchronisés sur le système de
fichiers : déposer un fichier suffit à l'inclure dans sa cible.

## Complexity Tracking

Aucune violation à justifier.
