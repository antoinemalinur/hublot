# Research: Fluidité globale

## Baseline observée

Le 15 août 2026 sur l'iPhone Air iOS le plus récent, le test existant de rendu
Markdown donne :

| Taille | Morceaux | Rendu entier | Queue découpée | Gain |
|---:|---:|---:|---:|---:|
| 200 caractères | 4 | 49 ms | 3 ms | ×15,6 |
| 2 000 caractères | 20 | 341 ms | 20 ms | ×17,1 |
| 8 000 caractères | 80 | 3 470 ms | 70 ms | ×49,3 |

La découpe `MarkdownStream` est donc efficace (0,8 ms pour 20 000 caractères),
mais elle intervient après la publication : `ChatSession.apply` mutait encore le
tableau observable à chaque `agent_message_chunk` et `agent_thought_chunk`.
`ConversationView.body` appelait aussi `turns.threadRows()` et
`MachineState.derive(from:)` à chaque reconstruction, y compris lorsque seul un
battement d'activité changeait.

L'ouverture d'un projet appelait enfin `loadSessions`, puis seulement après son
retour `loadInstructions`; deux attentes réseau indépendantes étaient donc
additionnées.

## Decision 1 — Regrouper à 25 ms au bord du modèle

**Decision**: Coalescer uniquement les fragments textuels contigus dans
`ChatSession`, avec une publication au plus tard 25 ms après le premier fragment.

**Rationale**: C'est l'unique endroit qui connaît l'ordre ACP, la fin de rejeu et
la fin de tour. 25 ms borne la première apparition à moins de 100 ms et limite la
pression à 40 publications par seconde, sous les 60 images/s de l'écran.

**Alternatives considered**:

- Retarder dans la vue : rejeté, car la vue ne connaît ni la chronologie du
  protocole ni les barrières de fin.
- Échantillonner ou abandonner des morceaux : rejeté, car la copie et le rejeu
  doivent être exacts au caractère près.
- Publier à 60 Hz : rejeté, car cela ne réserve presque aucun budget au clavier,
  à MarkdownUI et au défilement sous une rafale.

## Decision 2 — Vider à chaque frontière sémantique

**Decision**: Vider synchroniquement avant outil, permission, usage, activité,
fin de tour, fin de rejeu, déconnexion et fermeture; vider aussi lorsqu'identifiant
ou type textuel change.

**Rationale**: Un simple minuteur peut placer une phrase après l'outil qui la
suivait dans le protocole. Les frontières garantissent la chronologie sans rendre
chaque trame séparément.

**Alternatives considered**:

- Un dictionnaire de tampons par message : rejeté, car il perd l'ordre entre
  identifiants alternés.
- Vider seulement à la fin du tour : rejeté, car le streaming ne serait plus
  visible et une longue réponse semblerait bloquée.

## Decision 3 — Une révision équatable pour le document

**Decision**: Compter les mutations visibles du fil et isoler le document SwiftUI
dans une vue `Equatable` comparée sur cette révision et l'état de machine.

**Rationale**: Les propriétés du chrome évoluent fréquemment mais ne changent
aucune rangée. La révision est O(1), contrairement à une comparaison profonde de
1 000 tours ou à un nouveau `threadRows()`.

**Alternatives considered**:

- Rendre tout `Turn` profondément `Equatable` : rejeté, car les images, closures
  de permission et longues chaînes rendent la comparaison coûteuse ou impossible.
- Maintenir un second tableau incrémental de rangées : rejeté pour ce changement;
  il dupliquerait l'historique et la logique de regroupement alors que l'isolation
  supprime déjà les reconstructions sans mutation du fil.

## Decision 4 — Charger les ressources du projet en concurrence

**Decision**: Lancer liste et instructions par deux enfants structurés et attendre
les deux; conserver leur état et leurs erreurs séparés.

**Rationale**: Les méthodes ACP sont multiplexées et indépendantes. Le temps
perçu devient celui de la plus lente, pas leur somme, sans nouvelle API serveur.

**Alternatives considered**:

- Ajouter une méthode serveur agrégée : rejeté, car elle couple deux ressources,
  impose un déploiement VPS et ne réduit pas mieux le temps réseau.
- Ne plus attendre les instructions : rejeté, car l'appel non structuré pourrait
  survivre à un changement de projet et poser le mauvais document.

## Decision 5 — État de chargement natif et discret

**Decision**: Utiliser une rangée `ProgressView` accessible dans la liste vide,
sans bloquer le bouton principal.

**Rationale**: L'écran destination paraît immédiatement et dit pourquoi il est
vide. Le composant système respecte automatiquement taille de texte, VoiceOver et
réduction des animations.

**Alternatives considered**:

- Skeleton animé : rejeté, car il ajoute une animation permanente et invente la
  géométrie de données inconnues.
- Écran vide : rejeté, car il confond attente, absence et échec.
