# Contrat — identifiants d'accessibilité

Les identifiants sont le contrat entre l'app et ses tests. Les renommer oblige à mettre les
tests à jour dans le même commit.

## Existants (inchangés)

| Identifiant | Élément |
|---|---|
| `connect-button`, `connection-url`, `connection-token` | formulaire de connexion |
| `project-filter`, `new-project` | écran des dépôts |
| `close-instructions` | feuille d'instructions |
| `conversation-back`, `status-bar`, `activity-capsule`, `jump-to-latest` | chrome du fil |
| `composer-input`, `composer-action`, `composer-stop`, `composer-queue`, `config-options` | composer |
| `config-<id>` | une pilule de réglage (`config-engine`, `config-permission`, …) |
| `tool-group-<kind>`, `tool-call-<id>` | blocs d'outils |
| `close-context-tide`, `context-token-count` | marée de contexte |
| `close-radiography` | radiographie |

## À ajouter

| Identifiant | Élément | Pourquoi |
|---|---|---|
| `project-row-<nom>` | une rangée de dépôt | viser une rangée précise sans dépendre d'un libellé calculé |
| `session-row-<id>` | une rangée de conversation | idem, et pour le balayage partiel |
| `create-project` | le bouton « Créer » de la rangée de saisie | vérifier son activation |
| `disconnect` | le bouton « Déconnecter » | il n'a aujourd'hui que son texte |
| `sessions-back` | le retour de l'en-tête des conversations | il n'a aucune prise |
| `instructions-button` | le bouton d'ouverture des instructions | prouver son absence quand il n'y a pas de document |
| `plan-capsule` | la capsule de plan | la déplier |
| `reconnecting-banner` | le bandeau « reprise de la liaison… » | le distinguer du badge de la liste |
| `attachment-chip` / `attachment-remove` | la vignette jointe et sa croix | le retrait au toucher |
| `region-<nom>` | un disque de la radiographie | viser une région précise |
| `region-inspector` | l'inspecteur de région | prouver son apparition et sa fermeture |
| `radiography-legend` | la légende | lire « N régions » |
| `tide-inspector` | l'inspecteur de mesure | lire modèle et heure |
| `holding-escape` | l'issue de secours de l'écran d'attente | prouver son apparition tardive |
| `copy-code` | le bouton de copie d'un bloc de code | il n'a qu'un libellé |

## Règles

1. Un identifiant est ajouté **avec** le test qui le vise, jamais « au cas où ».
2. Un identifiant dérivé d'une donnée (`project-row-<nom>`) reprend la donnée telle quelle,
   sans transformation : le test la connaît par son scénario.
3. Un `Label` ou une pile qui expose plusieurs éléments porte
   `.accessibilityElement(children: .combine)` avant son identifiant — sinon deux éléments
   répondent au même nom, comme cela s'est déjà produit sur `composer-queue`.
