# Implementation Plan: Fluidité globale

**Branch**: `002-fluidite-globale` | **Date**: 2026-08-15 | **Spec**:
[spec.md](spec.md)

**Input**: Feature specification from
`/specs/002-fluidite-globale/spec.md`

## Summary

Rendre les parcours fréquents immédiatement réactifs sans changer le protocole
ACP ni l'identité visuelle. Le fil regroupera les fragments textuels reçus dans
une fenêtre de 25 ms, videra ce tampon à chaque frontière sémantique, et publiera
une révision monotone du document. SwiftUI isolera ensuite le document long dans
une vue équatable afin qu'un battement du chrome ne recalcule plus ses rangées.
L'ouverture d'un projet présentera enfin son écran avant le réseau, affichera un
chargement explicite et demandera liste et instructions en concurrence.

## Technical Context

**Language/Version**: Swift 6.0, toolchain Apple Swift 6.3.3; Python 3 pour les
tests serveur inchangés

**Primary Dependencies**: SwiftUI, Observation, MarkdownUI, XCTest/XCUITest,
Swift Testing; aucune nouvelle dépendance

**Storage**: mémoire du processus pour le tampon et la révision; trousseau et
persistance existants inchangés

**Testing**: Swift Testing (`IAClient-UITests`), XCTest UI
(`IAClient-UIScreenTests`), `unittest` Python, plan `IAClient-UI`

**Target Platform**: iOS 26.0+, simulateur de référence iPhone Air et iPhone réel

**Project Type**: application mobile native + relais Python existant inchangé

**Performance Goals**: première publication textuelle < 100 ms; au plus 40
révisions/s sous rafale; saisie visible < 1 s sous 1 000 fragments; 100
battements sur 1 000 entrées < 100 ms sans révision du document; chargements de
500 ms achevés ensemble < 750 ms

**Constraints**: ordre ACP exact; aucune perte de caractères; frontières outil,
permission, fin, rejeu et déconnexion synchrones; `@MainActor`; aucune animation
permanente nouvelle; couverture globale ≥ 80 % et fichiers critiques ≥ 90 %

**Scale/Scope**: listes de dizaines de projets, fils de 1 000 entrées et réponses
de plusieurs dizaines de milliers de caractères; chemins projet → conversations
→ fil → composer

## Constitution Check

*GATE: Passed before Phase 0 research; passed again after Phase 1 design.*

| Principle | Plan compliance |
|---|---|
| I. Régression couverte | Chaque changement porte son test Swift ou XCUITest dans le même lot. |
| II. Geste réel sur simulateur | Deux scénarios déterministes exercent toucher de projet, chargement, toucher du composer, saisie, clavier et streaming. |
| III. Le test exerce la feature | La rafale passe par `ACPConnection` et `ChatSession`; le chargement passe par les vraies méthodes `AppModel.open`, `loadSessions` et `loadInstructions`. Les tests seront vus rouges avec la cadence et la concurrence retirées. |
| IV. Le bug reste couvert | Les tests portent le signalement du 15 août 2026 dans leur nom et leur commentaire. |
| V. Validation complète | `Tools/test-local.sh full`, déploiement iPhone, puis PR seulement. |

No constitutional violation or complexity exception is required.

## Project Structure

### Documentation (this feature)

```text
specs/002-fluidite-globale/
├── spec.md
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   └── ui-scenarios.md
├── checklists/
│   └── requirements.md
└── tasks.md
```

### Source Code (repository root)

```text
IAClient-UI/
├── App/
│   ├── AppModel.swift
│   ├── ScreenFixtures.swift
│   └── UITestScenario.swift
├── Domain/
│   └── ChatSession.swift
├── UI/
│   ├── ConversationView.swift
│   └── SessionsView.swift
└── IAClient_UIApp.swift

IAClient-UITests/
├── AppModelTests.swift
├── ConversationFlowTests.swift
└── RenderPerformanceTests.swift

IAClient-UIScreenTests/
├── NavigationScreenTests.swift
└── ComposerScreenMoreTests.swift
```

**Structure Decision**: Conserver les trois cibles et les coutures existantes.
Le tampon appartient à `ChatSession`, seule traduction du protocole vers le fil;
l'isolation du document appartient à `ConversationView`; la concurrence des
ressources appartient à `AppModel`. Les fixtures restent `#if DEBUG` dans les
emplacements déjà prévus par la constitution.

## Design

### Streaming borné par la cadence

`ChatSession` retient seulement le fragment textuel contigu courant. Un nouveau
fragment du même type et du même identifiant concatène le tampon. Une tâche
structurée le publie après 25 ms au maximum. Tout autre événement commence par
vider le tampon synchroniquement; la chronologie reste donc identique au flux.
La fin de tour, de rejeu, de connexion et la fermeture font la même barrière.

Chaque mutation visible du tableau `turns` appelle une seule couture qui met à
jour l'état dérivé de la machine puis incrémente `documentRevision`. Une rafale
peut contenir 1 000 trames, mais elle ne produit que les révisions que l'écran
peut utilement peindre.

### Document isolé du chrome

Le `LazyVStack`, le regroupement `threadRows()` et son témoin de bas migrent dans
`ThreadDocument`, une vue `Equatable`. Son égalité dépend de la révision et de
l'état de machine, pas des compteurs du chrome. `RootView` fournit la révision et
l'état stockés par `ChatSession`; les fixtures statiques utilisent le nombre de
tours comme repli. Les changements d'activité, quota, reconnexion ou composer
continuent de rafraîchir leurs sous-vues sans traverser le document.

### Ouverture de projet progressive

`AppModel.open` conserve le changement d'écran synchrone, puis lance
`loadSessions` et `loadInstructions` avec `async let` avant de les attendre
ensemble. `SessionsView` présente une rangée de chargement tant que la première
liste est en vol. `isLoadingSessions` ne désactive pas l'action de création.
Chaque méthode garde son propre traitement d'échec pour qu'une ressource ne
masque pas l'autre.

## Complexity Tracking

No constitution violations to justify. The only new state is one pending text
fragment, one scheduled task and one integer revision per open conversation.
