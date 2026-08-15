# Feature Specification: Couverture UI exhaustive

**Feature Branch**: `001-couverture-ui-exhaustive`

**Created**: 2026-08-14

**Status**: Draft

**Input**: User description: "Couverture UI exhaustive de Hublot : compléter la cible IAClient-UIScreenTests pour qu'un test XCUITest exerce chaque micro-fonctionnalité tactile et visible de l'app, écran par écran (connexion, projets, conversations, fil, composer, blocs, marée de contexte, radiographie, instructions, attente/reconnexion), afin qu'aucune régression ne puisse passer. Partir de l'inventaire des gestes réellement offerts par l'interface et des identifiants d'accessibilité existants, et couvrir ce qui ne l'est pas encore."

## User Scenarios & Testing *(mandatory)*

Le bénéficiaire de cette feature est la personne qui modifie Hublot — aujourd'hui son
auteur, demain n'importe quel agent. Son besoin : toucher une ligne d'interface et savoir
en une commande si un geste de l'app a cessé de fonctionner. Les « scénarios » ci-dessous
sont donc des parcours de vérification, ordonnés par le coût de la régression qu'ils
empêchent.

### User Story 1 — Les gestes qui font entrer dans l'app (Priority: P1)

Ouvrir l'app, se connecter, choisir un dépôt, ouvrir une conversation, revenir. C'est le
chemin que toute session emprunte : une régression ici rend l'app inutilisable, et aucune
autre vérification ne se joue.

**Why this priority**: un défaut sur ce chemin bloque tout le reste. C'est aussi là que
vivent les navigations, dont aucune n'est aujourd'hui vérifiée de bout en bout.

**Independent Test**: se lance seul sur des relais témoins déterministes, sans réseau, et
prouve qu'on peut atteindre un fil de conversation puis en ressortir.

**Acceptance Scenarios**:

1. **Given** l'écran de connexion vide, **When** on ne remplit qu'un seul des deux champs,
   **Then** le bouton de connexion reste inactif.
2. **Given** les deux champs remplis, **When** la connexion est en cours, **Then** le
   bouton annonce « Connexion… » et refuse un second toucher.
3. **Given** un jeton saisi, **When** on le regarde, **Then** il reste masqué.
4. **Given** la liste des dépôts, **When** on touche un dépôt, **Then** ses conversations
   s'affichent sous son nom.
5. **Given** la liste des conversations, **When** on touche le retour de l'en-tête,
   **Then** la liste des dépôts revient.
6. **Given** la liste des dépôts, **When** on touche « Déconnecter », **Then** l'écran de
   connexion revient.
7. **Given** une conversation ouverte, **When** on touche le retour, **Then** la liste des
   conversations revient avec la conversation présente.

---

### User Story 2 — Écrire, envoyer, joindre, interrompre (Priority: P1)

Tout ce qui part du composer : la saisie, les pièces jointes, l'arrêt d'un tour, la file
d'attente, la dictée, les réglages en pilules.

**Why this priority**: c'est le seul endroit de l'app où l'utilisateur agit vraiment sur
la machine. Une régression y est immédiatement bloquante et déjà survenue (brouillon qui
restait affiché après envoi, bouton d'arrêt inaccessible).

**Independent Test**: se joue entièrement sur le fil témoin, sans relais.

**Acceptance Scenarios**:

1. **Given** un fil au repos, **When** le champ est vide, **Then** le bouton d'action
   propose la dictée ; **When** on écrit, **Then** il propose l'envoi.
2. **Given** un brouillon en cours d'écriture, **When** le clavier est ouvert, **Then** la
   rangée de réglages s'efface, et elle revient quand la saisie se termine.
3. **Given** un tour en cours, **When** on touche un réglage autre que les permissions,
   **Then** rien ne s'ouvre ; **When** on touche les permissions, **Then** le choix
   s'ouvre.
4. **Given** un menu de réglage ouvert, **When** on choisit une valeur, **Then** la pilule
   porte la nouvelle valeur.
5. **Given** deux messages confiés pendant un tour, **When** on lit le composer, **Then**
   il annonce « 2 messages en attente ».
6. **Given** une image jointe, **When** on lit la vignette, **Then** son poids est écrit,
   et la croix la retire.

---

### User Story 3 — Lire le fil et ce qu'il contient (Priority: P2)

Les blocs : prose, raisonnement replié, appels d'outils groupés ou isolés, diff, sortie de
terminal, carte de permission, images d'un message.

**Why this priority**: c'est ce qu'on vient lire. Les régressions y sont visuelles et
silencieuses — un pli qui ne s'ouvre plus, un échec qui ne s'ouvre plus tout seul.

**Independent Test**: un scénario témoin porte un fil contenant un exemplaire de chaque
bloc ; chaque geste de dépliage se vérifie isolément.

**Acceptance Scenarios**:

1. **Given** un appel d'outil isolé, **When** on le touche, **Then** son contenu apparaît
   et un second toucher le referme.
2. **Given** un appel d'outil en échec, **When** le fil s'affiche, **Then** son détail est
   déjà ouvert sans qu'on l'ait demandé.
3. **Given** un bloc de raisonnement, **When** on le touche, **Then** son texte apparaît
   sous le libellé « raisonnement ».
4. **Given** une demande de permission, **When** on touche un des boutons proposés par
   l'agent, **Then** les boutons cèdent la place au verdict portant les mots de ce bouton.
5. **Given** un diff affiché, **When** on le lit, **Then** les lignes ajoutées et retirées
   portent leurs marqueurs respectifs.
6. **Given** un bloc de code, **When** on touche « Copier le bloc de code », **Then**
   l'action est disponible et sans effet de bord visible sur le fil.

---

### User Story 4 — Suivre ce que la machine fait (Priority: P2)

Le chrome haut : capsule de plan, capsule d'activité, bandeau de reprise de liaison, barre
de mesures, et le comportement du fil pendant qu'une réponse s'écrit.

**Why this priority**: ces éléments sont la seule différence entre « ça travaille » et
« c'est mort ». Deux bugs coûteux du projet y sont nés.

**Independent Test**: scénarios témoins figés portant chacun un état d'activité précis.

**Acceptance Scenarios**:

1. **Given** un plan de N jalons dont M franchis, **When** on touche la capsule, **Then**
   la liste des jalons se déplie et le compteur annonce M/N.
2. **Given** un tour dont le dernier signe de vie remonte à plus de vingt secondes,
   **When** on lit la capsule d'activité, **Then** elle annonce l'absence de signal.
3. **Given** une liaison en cours de reprise, **When** on lit le chrome, **Then** il
   l'annonce à la place des mesures.
4. **Given** aucune mesure connue, **When** on lit le chrome, **Then** la barre de mesures
   est absente plutôt que vide.
5. **Given** un fil défilé vers le haut, **When** un nouveau tour arrive, **Then** la
   lecture ne saute pas au bas du fil.

---

### User Story 5 — Les deux écrans d'analyse (Priority: P2)

Marée de contexte et radiographie : leurs états vides, leur inspection au toucher, leur
chronologie, et les trois mots qui disent si l'on regarde du direct, du passé ou du
terminé.

**Why this priority**: ce sont les deux écrans les plus riches, et les seuls dont la
géométrie est calculée. Ils sont partiellement couverts ; les gestes d'inspection ne le
sont pas.

**Independent Test**: scénarios témoins déjà existants, complétés par leurs états vides.

**Acceptance Scenarios**:

1. **Given** une carte de radiographie, **When** on touche une région, **Then** son
   inspecteur apparaît avec son nom et son compte d'actions ; un second toucher le ferme.
2. **Given** une conversation sans aucun outil, **When** on ouvre la radiographie,
   **Then** elle annonce qu'aucune région n'a été observée.
3. **Given** une conversation sans mesure, **When** on ouvre la marée, **Then** elle
   annonce qu'aucune mesure n'existe.
4. **Given** une chronologie ramenée en arrière, **When** on lit l'en-tête, **Then** il
   annonce « passé », et le retour au direct le ramène à « direct ».
5. **Given** une marée figée sur une mesure, **When** on lit l'inspecteur, **Then** il
   porte le modèle, l'heure et le compte de jetons de cette mesure.

---

### User Story 6 — Les écrans de bord (Priority: P3)

Attente et reprise de liaison, feuille d'instructions, états vides et d'erreur des listes,
rafraîchissement par traction.

**Why this priority**: rarement vus, mais ce sont les écrans qui ont déjà laissé
l'utilisateur sans issue — un écran blanc dont la seule sortie était de tuer l'app.

**Independent Test**: scénarios témoins dédiés, dont un qui force l'attente longue.

**Acceptance Scenarios**:

1. **Given** une attente qui dure au-delà du raisonnable, **When** on regarde l'écran,
   **Then** une issue de secours apparaît et son toucher rend la main.
2. **Given** un dépôt porteur d'un fichier d'instructions, **When** on ouvre la feuille,
   **Then** elle porte le chemin du document et se referme au toucher.
3. **Given** un dépôt sans fichier d'instructions, **When** on lit l'en-tête, **Then**
   aucun bouton d'instructions n'y figure.
4. **Given** une liste affichée, **When** on la tire vers le bas, **Then** elle se
   recharge sans perdre son contenu.

---

### User Story 7 — Tenir dans tous les cadres (Priority: P3)

Rotation, réduction des animations, grandes tailles de caractères, et non-débordement des
capsules sur chaque écran.

**Why this priority**: ces défauts ne cassent rien fonctionnellement mais rendent l'app
inutilisable sur un appareil réglé autrement que celui du développeur.

**Independent Test**: relance des mêmes scénarios avec les réglages système forcés au
lancement.

**Acceptance Scenarios**:

1. **Given** l'app en paysage, **When** on parcourt chaque écran principal, **Then**
   chrome, listes et actions restent dans l'écran et touchables.
2. **Given** une taille de caractères accessible, **When** on affiche les listes, **Then**
   les rangées restent lisibles et leurs actions atteignables.

---

### Edge Cases

- Un dépôt dont le nom déborde de la rangée : le nom est tronqué, jamais l'heure ni le
  chevron.
- Un filtre qui ne trouve rien : le terme exact tapé est repris dans le message.
- Une conversation supprimée pendant qu'elle travaille : la rangée disparaît sans
  confirmation et sans laisser de point vivant orphelin.
- Un tour qui se termine pendant qu'un menu de réglage est ouvert : le verrou se lève sans
  fermer le menu de force.
- Une image illisible choisie dans la photothèque : elle est ignorée sans message d'erreur
  et sans vignette fantôme.
- Un scrubber ramené sur la toute première mesure : la carte reste peuplée, aucun disque
  ne sort de l'écran.
- Une permission déjà tranchée avant l'affichage : le verdict s'affiche directement, sans
  boutons.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: La suite d'interface DOIT exercer chaque geste tactile atteignable de l'app
  — toucher, saisie, balayage, pression longue, défilement, traction, rotation — et
  vérifier son résultat observable à l'écran.
- **FR-002**: Chaque test DOIT partir d'un état déterministe déclaré, sans réseau, sans
  dépendance à un autre dépôt ni à un service extérieur.
- **FR-003**: Chaque navigation de l'app DOIT être exercée dans les deux sens : entrée
  dans l'écran et retour vers l'écran précédent.
- **FR-004**: Chaque état alternatif d'un écran — vide, en erreur, en chargement, en
  reprise de liaison — DOIT porter un test qui le distingue de l'état nominal.
- **FR-005**: Chaque élément qui apparaît ou disparaît selon une condition DOIT être
  vérifié dans les deux conditions, jamais seulement dans celle où il est présent.
- **FR-006**: Chaque libellé calculé affiché à l'utilisateur — sous-titre de rangée,
  compteur, capsule d'activité, mesure — DOIT être vérifié sur sa valeur exacte, espaces
  insécables normalisés.
- **FR-007**: Un test NE DOIT PAS affirmer une valeur qu'un écran témoin lui fournit déjà
  toute faite ; il DOIT traverser le code qui la calcule ou l'affiche.
- **FR-008**: Les tests existants DOIVENT rester en place et inchangés dans leur intention,
  chacun couvrant un bug déjà rapporté.
- **FR-009**: Les nouveaux états déterministes DOIVENT être déclarés au même point d'entrée
  que les existants et rester compilés hors de la version livrée.
- **FR-010**: Toute micro-fonctionnalité présente dans le code mais inatteignable à
  l'écran DOIT être signalée plutôt que testée par un chemin détourné.
- **FR-011**: La suite complète DOIT rester exécutable en parallèle sur quatre workers sans
  test ignoré ni dépendance d'ordre entre les tests.
- **FR-012**: Chaque nouveau test DOIT avoir été observé en échec sur une version de l'app
  privée du comportement qu'il protège.

### Key Entities

- **Scénario témoin**: un état de l'app nommé, déclenché au lancement, qui produit toujours
  le même écran. Porte soit des données figées, soit un relais de test déterministe.
- **Geste**: une action de l'utilisateur sur l'écran, avec son résultat observable. C'est
  l'unité de couverture de cette feature.
- **Identifiant d'accessibilité**: le contrat entre un élément d'interface et le test qui
  le vise. Ajouter un geste testable peut demander d'en ajouter un.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Chaque écran de l'app possède au moins un test par geste qu'il offre ;
  l'inventaire des gestes non couverts est vide ou explicitement justifié.
- **SC-002**: Retirer n'importe lequel des correctifs déjà livrés fait échouer au moins un
  test nommé.
- **SC-003**: `Tools/test-local.sh full` passe en entier : aucun échec, aucun test ignoré,
  couverture globale au-dessus de 80 % et fichiers critiques au-dessus de 90 %.
- **SC-004**: La phase de tests reste sous les trois minutes sur la machine de référence à
  quatre workers.
- **SC-005**: Deux exécutions consécutives de la suite donnent le même résultat — aucun
  test instable.

## Assumptions

- Le simulateur de référence reste `iPhone Air` sur l'iOS disponible le plus récent, choisi
  par `Tools/test-local.sh`.
- Les gestes qui sortent de l'app — sélecteur de photos système, autorisation micro,
  autorisation de notifications — ne peuvent pas être pilotés de façon déterministe par
  XCUITest ; seuls leurs effets côté app sont vérifiés, à partir d'un état forcé.
- Ce qui se calcule côté relais reste couvert côté relais ; cette feature n'y touche pas.
- Les références visuelles existantes restent la mesure du rendu ; cette feature ajoute des
  gestes, pas des captures, sauf pour les écrans nouvellement dotés d'un état témoin.
- La palette de commandes `/` est aujourd'hui du code mort — jamais rendue par le composer,
  jamais alimentée par la racine. Elle est donc hors périmètre de test et signalée comme
  telle (FR-010) ; l'activer serait une feature, pas un test.
