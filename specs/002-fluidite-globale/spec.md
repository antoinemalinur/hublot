# Feature Specification: Fluidité globale

**Feature Branch**: `002-fluidite-globale`

**Created**: 2026-08-15

**Status**: Approved

**Input**: User description: "Améliorer la fluidité et la rapidité globales de
l'application. Je veux une application qui donne envie d'être utilisée."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Écrire pendant que l'agent répond (Priority: P1)

Pendant qu'une réponse arrive rapidement, l'utilisateur peut continuer à lire,
faire défiler le fil, ouvrir le clavier et écrire sa prochaine demande sans
ralentissement sensible. Le texte de l'agent reste progressif, complet et dans
l'ordre.

**Why this priority**: Le fil en direct est le cœur de Hublot. Un composer qui
retarde une touche ou un défilement qui accroche donne immédiatement l'impression
que l'app est bloquée, même si le moteur travaille correctement.

**Independent Test**: Lancer un fil déterministe long, injecter une rafale de
morceaux de réponse, toucher le composer pendant la rafale, saisir une demande et
vérifier simultanément que la saisie est visible et que la réponse complète finit
par apparaître.

**Acceptance Scenarios**:

1. **Given** un fil long épinglé en bas et une réponse reçue en rafale, **When**
   l'utilisateur touche le composer et saisit du texte, **Then** le clavier et le
   texte saisi apparaissent en moins d'une seconde, sans perdre ni réordonner un
   morceau de réponse.
2. **Given** une réponse en cours et l'utilisateur qui relit plus haut, **When**
   de nouveaux morceaux arrivent, **Then** la position de lecture ne saute pas et
   le retour au direct reste touchable.
3. **Given** le dernier morceau immédiatement suivi de la fin du tour, **When**
   l'écran se stabilise, **Then** la réponse est complète, le curseur de streaming
   disparaît et le composer reste utilisable.

---

### User Story 2 - Entrer immédiatement dans un projet (Priority: P2)

Quand l'utilisateur touche un projet, l'écran des conversations répond tout de
suite. Il indique honnêtement ce qu'il charge, conserve ses actions utilisables et
affiche conversations et instructions dès que chacune est disponible.

**Why this priority**: L'attente entre deux écrans est le premier coût perçu à
chaque utilisation. Une destination instantanée avec un état de chargement clair
paraît rapide même quand le réseau est momentanément lent.

**Independent Test**: Utiliser un relais témoin qui retient la liste de
conversations et les instructions, toucher un projet, puis vérifier que l'en-tête,
l'indicateur de chargement et l'action « Nouvelle conversation » sont visibles et
touchables avant les réponses du relais.

**Acceptance Scenarios**:

1. **Given** un relais qui répond lentement, **When** l'utilisateur touche un
   projet, **Then** l'écran de destination et son état de chargement paraissent en
   moins d'une seconde.
2. **Given** la liste et les instructions indépendantes, **When** le projet
   s'ouvre, **Then** leur chargement se chevauche et le temps total n'additionne
   pas les deux attentes.
3. **Given** la liste encore en chargement, **When** l'utilisateur touche
   « Nouvelle conversation », **Then** le geste est accepté et ne reste pas sur
   un bouton inerte.

---

### User Story 3 - Garder un long fil stable et léger (Priority: P3)

Dans une conversation longue, les battements d'activité et les mesures qui
évoluent dans le chrome ne doivent ni refaire travailler tout le document, ni
faire perdre le focus, la position de lecture ou l'état des plis ouverts.

**Why this priority**: Les fils utiles deviennent longs. Leur coût ne doit pas
croître au point que la centième interaction soit moins agréable que la première.

**Independent Test**: Afficher un historique déterministe volumineux, ouvrir un
groupe d'outils, défiler, injecter des battements répétés, puis vérifier que le pli,
la position et le composer restent stables. Une mesure automatisée compare aussi
le coût d'une mise à jour du chrome à celui d'une reconstruction du document.

**Acceptance Scenarios**:

1. **Given** un historique d'au moins 1 000 entrées, **When** seul le signe de vie
   ou une mesure du chrome change, **Then** le document ne se reconstruit pas et
   l'interaction courante reste intacte.
2. **Given** un groupe d'outils ouvert et un battement reçu, **When** l'utilisateur
   continue de lire, **Then** le groupe reste ouvert et la géométrie visible ne
   saute pas.
3. **Given** « Réduire les animations » activé, **When** l'utilisateur parcourt
   les mêmes écrans, **Then** toute animation continue est arrêtée tout en gardant
   l'état et les actions lisibles.

### Edge Cases

- Plusieurs identifiants de messages ou de raisonnements alternent dans une même
  rafale : leur chronologie reste celle du protocole.
- Une rafale est interrompue par un outil, une permission, une déconnexion, une
  annulation ou la fin du tour : tout texte en attente est affiché avant
  l'événement suivant.
- Un historique est rejoué plus vite que l'écran ne peut se rafraîchir : la
  barrière de fin de rejeu attend le dernier contenu, sans imposer un rendu par
  trame.
- La réponse ne contient qu'un seul petit morceau : elle apparaît sans délai
  perceptible et n'attend jamais indéfiniment un morceau suivant.
- La taille de texte d'accessibilité agrandit fortement les rangées : chargement,
  clavier, défilement et actions restent atteignables.
- Une requête de liste échoue tandis que les instructions réussissent, ou
  l'inverse : chaque résultat est adopté indépendamment et l'échec reste lisible.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Le système MUST plafonner les mises à jour visuelles produites par
  une rafale de texte à la cadence d'affichage utile, tout en conservant chaque
  caractère et son ordre exact.
- **FR-002**: Le système MUST vider tout texte retenu avant un changement de type
  de contenu, une fin de tour, une fin de rejeu, une annulation ou une
  déconnexion.
- **FR-003**: Le système MUST conserver le rendu progressif : le premier contenu
  d'une réponse en direct apparaît au plus tard 100 ms après sa réception.
- **FR-004**: Le document de conversation MUST être isolé des mises à jour qui ne
  modifient que le chrome, afin qu'un battement ne regroupe ni ne rende à nouveau
  tout l'historique.
- **FR-005**: Le regroupement des outils, les identités de rangées, l'état des
  plis, la sélection de texte et la position de défilement MUST rester inchangés.
- **FR-006**: Le toucher d'un projet MUST présenter l'écran des conversations
  sans attendre la fin des appels réseau.
- **FR-007**: L'écran des conversations MUST montrer un état de chargement
  observable tant que la première liste n'est pas revenue, sans désactiver les
  actions indépendantes de cette lecture.
- **FR-008**: La liste des conversations et les instructions du projet MUST être
  demandées concurremment et leurs succès ou échecs traités indépendamment.
- **FR-009**: Les optimisations MUST fonctionner aussi pendant un rejeu
  d'historique et lors de la reprise d'un tour lancé avant la liaison actuelle.
- **FR-010**: Tout nouveau comportement visible ou tactile MUST être couvert par
  un scénario déterministe et un test d'interface qui reproduit le geste.
- **FR-011**: Les tests de domaine MUST prouver la conservation exacte du texte,
  de la chronologie et de la barrière de fin de tour, ainsi que la réduction du
  nombre de publications observables sous une rafale.
- **FR-012**: Le changement MUST conserver le respect de « Réduire les
  animations » et ne pas introduire de nouvelle animation permanente.

### Key Entities

- **Rafale de streaming**: suite ordonnée de morceaux ACP contigus qui peuvent
  être publiés visuellement ensemble sans changer le contenu final.
- **Révision du document**: identité monotone d'un état du fil; elle change
  uniquement quand les rangées rendues changent, pas quand seul le chrome évolue.
- **Ressource de projet**: liste des conversations ou document d'instructions,
  chargés indépendamment pour le même projet.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Sur simulateur, le test d'interface peut toucher le composer et
  rendre 20 caractères visibles en moins d'une seconde pendant une rafale d'au
  moins 1 000 morceaux.
- **SC-002**: Après le dernier morceau d'une rafale, 100 % du texte attendu est
  visible et dans l'ordre en moins de 250 ms.
- **SC-003**: Une rafale de 1 000 morceaux reçue en une seconde produit au plus
  40 révisions visibles du document, contre une révision par morceau avant le
  changement.
- **SC-004**: Cent battements appliqués à un historique de 1 000 entrées ne
  produisent aucune révision du document et se traitent en moins de 100 ms dans
  le test de performance local.
- **SC-005**: Avec les deux ressources de projet retenues par le relais témoin,
  l'en-tête, le chargement et l'action principale de l'écran de destination sont
  visibles en moins d'une seconde après le toucher.
- **SC-006**: Quand deux réponses indépendantes prennent chacune 500 ms, leur
  chargement combiné finit en moins de 750 ms dans le test automatisé, hors coût
  de construction initial du simulateur.
- **SC-007**: `Tools/test-local.sh full` réussit sans test échoué ou ignoré, avec
  les seuils de couverture imposés et une compilation Release réussie.

## Assumptions

- La priorité porte sur les parcours fréquents — listes, navigation, fil,
  streaming et composer — plutôt que sur une refonte graphique ou réseau.
- Le relais et le protocole ACP restent compatibles; aucune nouvelle méthode
  serveur n'est nécessaire.
- Une cadence de publication de 30 à 40 fois par seconde est visuellement
  continue pour du texte tout en laissant du temps au clavier et au défilement.
- Les mesures temporelles strictes sont exécutées sur les fixtures locales et
  servent de garde-fou de régression, pas de promesse sur la latence du VPS ou du
  réseau mobile.
