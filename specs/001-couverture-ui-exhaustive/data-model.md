# Phase 1 — Inventaire des gestes

L'unité de couverture est le **geste** : une action de l'utilisateur et son résultat
observable. Chaque ligne dit qui la couvre.

Légende : ✅ couvert · 🚫 hors de portée de XCUITest (justifié dans `research.md`)

## Connexion

| # | Geste | Résultat observable | État |
|---|---|---|---|
| C1 | Saisir adresse et jeton | le bouton s'active, le clavier apparaît | ✅ `testFieldsEnableConnectionAndExposeTheKeyboard` |
| C2 | Toucher « Se connecter » sur une adresse invalide | « Adresse de serveur invalide » | ✅ `testInvalidURLIsRejectedVisiblyAfterTheRealTap` |
| C3 | Ne remplir qu'un champ | le bouton reste inactif, dans les deux sens | ✅ `testOneFilledFieldIsNotEnoughToEnableConnection` |
| C4 | Toucher pendant que la connexion travaille | libellé « Connexion… », bouton inactif | ✅ `testBusyButtonAnnouncesItselfAndRefusesASecondTap` |
| C5 | Connexion refusée par le serveur | « Jeton refusé par le serveur. » sous les champs | ✅ `testRejectedTokenIsWrittenUnderTheFields` |
| C6 | Regarder le jeton saisi | il reste masqué | ✅ `testTokenStaysMasked` |
| C7 | Faire défiler pendant la saisie | le clavier se retire | ✅ `testScrollingDismissesTheKeyboard` |

## Projets

| # | Geste | Résultat observable | État |
|---|---|---|---|
| P1 | Lire l'âge d'un dépôt | « il y a 1 h » | ✅ `testProjectAgeIsFormattedAsARelativeFrenchDelay` |
| P2 | Filtrer en majuscules | la casse est ignorée, le vide s'annonce | ✅ `testSearchIsCaseInsensitiveAndItsEmptyStateIsObservable` |
| P3 | Filtrer | l'action principale s'efface | ✅ `testNewProjectActionDisappearsWhileFiltering` |
| P4 | Créer au clavier | la rangée de saisie disparaît | ✅ `testProjectCanBeCreatedFromTheKeyboard` |
| P5 | États vide et en erreur | distincts | ✅ `testStaticEmptyAndErrorStatesStayDistinct` |
| P6 | Toucher un dépôt | ses conversations s'ouvrent sous son nom | ✅ `testTouchingAProjectOpensItsConversationsUnderItsName` |
| P7 | Toucher « Déconnecter » | l'écran de connexion revient | ✅ `testDisconnectBringsBackTheConnectionForm` |
| P8 | Lire un dépôt qui travaille | « en cours · 2:14 » | ✅ `testWorkingProjectShowsItsElapsedTime` |
| P9 | Lire un dépôt à deux tours | « 2 conversations en cours · 3:20 » | ✅ `testProjectWithTwoTurnsCountsThemAndShowsTheLongest` |
| P10 | Lire un dépôt vide / à une conversation | « aucune conversation » / « 1 conversation » | ✅ `testIdleProjectsCountTheirConversations` |
| P11 | Ouvrir la rangée de création puis vider le nom | « Créer » inactif, actif dès un caractère | ✅ `testCreateButtonStaysDisabledUntilANameIsTyped` |
| P12 | Créer par le bouton « Créer » | la rangée disparaît | ✅ `testProjectCanBeCreatedFromTheButton` |
| P13 | Tirer la liste vers le bas | elle se recharge, le contenu neuf apparaît | ✅ `testPullToRefreshAsksTheServerAgain` |
| P14 | Lire un nom de dépôt trop long | le nom se replie, la rangée et son chevron restent dans l'écran | ✅ `testOverlongProjectNameKeepsTheRowInsideTheScreen` |

Note sur P14 : le nom **passe à la ligne**, il n'est pas tronqué — c'est ce que fait la
rangée, et c'est donc ce que le test vérifie. La garantie utile est la même : rien ne sort
de l'écran, et la rangée voisine n'est pas chassée.

## Conversations d'un dépôt

| # | Geste | Résultat observable | État |
|---|---|---|---|
| S1 | Lire une conversation qui travaille | « en cours » avant ouverture | ✅ `testRunningTurnsAreVisibleBeforeOpeningAConversation` |
| S2 | Balayer entièrement vers la gauche | suppression immédiate, sans confirmation | ✅ `testFullSwipeDeletesImmediatelyWithoutConfirmation` |
| S3 | Presser longuement puis « Supprimer » | suppression immédiate | ✅ `testContextMenuDeletesImmediatelyWithoutConfirmation` |
| S4 | Ouvrir puis fermer les instructions | la feuille s'ouvre et se ferme | ✅ `testInstructionsSheetOpensAndClosesByTouch` |
| S5 | Ouvrir une conversation et revenir | la date ne rajeunit pas | ✅ `testOpeningAConversationDoesNotMakeItLookRecent` |
| S6 | États vide et en erreur | lisibles | ✅ `testEmptyAndErrorStatesRemainReadable` |
| S7 | Deux fils lancés de suite | les deux restent visibles et « en cours » | ✅ `testTwoPromptsStayVisibleWhileBothConversationsAreRunning` |
| S8 | Toucher le retour de l'en-tête | la liste des dépôts revient | ✅ `testHeaderBackReturnsFromConversationsToProjects` |
| S9 | Balayer partiellement | « Supprimer » se révèle et supprime au toucher | ✅ `testPartialSwipeRevealsTheDeleteButtonBeforeDeleting` |
| S10 | Lire la plus récente | elle seule porte « dernière » | ✅ `testLatestConversationIsMarked` |
| S11 | Lire une conversation à un échange | « 1 échange », au singulier | ✅ `testSingleExchangeIsWrittenInTheSingular` |
| S12 | Ouvrir un dépôt sans fichier d'instructions | aucun bouton d'instructions | ✅ `testInstructionsButtonIsAbsentWithoutADocument` |
| S13 | Faire défiler la feuille d'instructions | le chemin du document reste en tête | ✅ `testInstructionsSheetScrollsUnderItsHeader` |
| S14 | Tirer la liste vers le bas | elle garde son contenu | ✅ `testPullToRefreshKeepsTheConversations` |

## Fil et chrome

| # | Geste | Résultat observable | État |
|---|---|---|---|
| F1 | Défiler puis toucher le retour au direct | la dernière réponse redevient visible | ✅ `testJumpToLatestActuallyReturnsToTheBottom` |
| F2 | Ouvrir une conversation | elle est déjà en bas, sans rattrapage | ✅ `testConversationAppearsAlreadyAtTheBottomWithoutVisibleCatchUp` |
| F3 | Lire le chrome | statut et activité partagent une ligne | ✅ `testChromeSharesOneLineAndModelBarStaysInsideScreen` |
| F4 | Tourner l'appareil | chrome et composer restent touchables | ✅ `testLandscapeChromeAndComposerRemainTouchable` |
| F5 | Lire la barre sous Codex | « 7J » et jamais « 5H » | ✅ `testCodexUsesWeeklyWindowAndNeverFiveHourLabel` |
| F6 | Basculer de Codex à Claude | la barre garde un plafond | ✅ `testStatusBarKeepsItsQuotaAfterSwitchingToClaude` |
| F7 | Toucher le moteur pendant un tour | le choix ne s'ouvre pas ; les permissions, si | ✅ `testEngineCannotChangeWhileCodexIsStillRunning` |
| F8 | Toucher la capsule de plan | les jalons se déplient, le compteur dit 2/4 | ✅ `testPlanCapsuleCountsMilestonesAndUnfoldsThem` |
| F9 | Regarder une activité sans signe de vie | « sans signal » | ✅ `testActivityCapsuleAnnouncesTheMissingSignal` |
| F10 | Regarder un moteur muet depuis une minute | « silence 1:0x » | ✅ `testActivityCapsuleCountsTheEngineSilence` |
| F11 | Perdre la liaison | « reprise de la liaison… » à la place des mesures | ✅ `testReconnectingBannerReplacesTheMeasurements` |
| F12 | Ouvrir un fil sans aucune mesure | pas de barre du tout | ✅ `testStatusBarIsAbsentRatherThanEmpty` |
| F13 | Recevoir un tour en étant en bas | le fil suit | ✅ `testThreadFollowsANewTurnWhenReadingAtTheBottom` |
| F14 | Recevoir un tour après avoir défilé vers le haut | la lecture ne saute pas | ✅ `testThreadDoesNotJumpWhenATurnArrivesWhileReadingHigherUp` |
| F15 | Toucher le retour d'une conversation | la liste des conversations revient | ✅ `testConversationOpensAndItsBackReturnsToTheList` |

## Composer

| # | Geste | Résultat observable | État |
|---|---|---|---|
| M1 | Envoyer | le clavier se ferme, le brouillon est vidé | ✅ `testSendingDismissesKeyboardAndClearsTheDraft` |
| M2 | Écrire pendant un tour | mise en file, l'arrêt reste touchable | ✅ `testMessageCanBeQueuedWhileStopRemainsTouchable` |
| M3 | Lire le bouton d'action au repos | dictée, puis envoi dès qu'on écrit | ✅ `testActionButtonSwitchesFromDictationToSending` |
| M4 | Ouvrir le clavier | la rangée de réglages s'efface, puis revient | ✅ `testSettingsRowHidesWhileWritingAndComesBack` |
| M5 | Choisir une valeur dans un réglage | la pilule porte la nouvelle valeur | ✅ `testChoosingAValueRenamesThePill` |
| M6 | Mettre deux messages en file | « 2 messages en attente », en un seul élément | ✅ `testTwoQueuedMessagesAreCountedInThePlural` |
| M7 | Retirer une pièce jointe | la vignette et son poids disparaissent | ✅ `testAttachmentShowsItsWeightAndCanBeRemoved` |
| M8 | Micro refusé | l'invite renvoie aux Réglages | ✅ `testRefusedMicrophoneSendsBackToTheSettings` |
| M9 | Choisir une image dans la photothèque | — | 🚫 boîte système ; son effet est couvert par M7 |
| M10 | Enregistrer une dictée | — | 🚫 autorisation système ; son refus est couvert par M8 |

## Blocs du fil

| # | Geste | Résultat observable | État |
|---|---|---|---|
| B1 | Déplier un groupe d'appels | les six appels restent distincts | ✅ `testToolDetailsExpandWithoutLosingRepeatedCalls` |
| B2 | Toucher un appel isolé | son contenu s'ouvre, un second toucher le referme | ✅ `testLoneToolCallOpensAndClosesOnTouch` |
| B3 | Afficher un appel en échec | il est déjà ouvert | ✅ `testFailedToolCallIsAlreadyExpanded` |
| B4 | Toucher un bloc de raisonnement | son texte apparaît | ✅ `testReasoningBlockRevealsItsTextUnderItsCaption` |
| B5 | Répondre à une demande de permission | le verdict remplace les boutons | ✅ `testAnsweringAPermissionReplacesTheButtonsWithTheVerdict` |
| B6 | Afficher une permission déjà tranchée | le verdict, sans boutons | ✅ `testSettledPermissionShowsItsVerdictWithoutButtons` |
| B7 | Lire un diff | les marqueurs `+` et `−` sont là | ✅ `testDiffCarriesItsAddedAndRemovedMarkers` |
| B8 | Lire une sortie de terminal | le texte est présent et atteignable | ✅ `testTerminalOutputIsPresentAndSelectable` |
| B9 | Toucher « Copier le bloc de code » | le bouton se touche, le fil ne bouge pas | ✅ `testCodeBlockCopyButtonIsReachableAndHarmless` |
| B10 | Lire un message porteur d'images | les vignettes s'affichent au-dessus du texte | ✅ `testMessageImagesAppearAboveTheirText` |

## Marée de contexte

| # | Geste | Résultat observable | État |
|---|---|---|---|
| T1 | Ouvrir depuis la barre, fermer | s'ouvre et se ferme au premier toucher | ✅ `testContextTideOpensFromStatusBarAndClosesOnFirstTap` |
| T2 | Remonter la chronologie puis revenir | « passé » puis retour au direct | ✅ `testScrubberReturnsToPastThenBackToLive` |
| T3 | Lire l'inspecteur | modèle, moteur, heure et jetons de la mesure | ✅ `testInspectorCarriesModelEngineTimeAndTokens` |
| T4 | Ouvrir sur un fil sans mesure | « Aucune mesure de contexte » | ✅ `testEmptyTideAnnouncesThatNothingWasMeasured` |
| T5 | Ouvrir sur un fil terminé | « terminé », et « Revenir à la fin » | ✅ `testFinishedThreadSaysSoAndOffersToReturnToTheEnd` |
| T6 | Lire un sommet dépassé | « sommet atteint : 92 % » | ✅ `testPastPeakIsStillAnnounced` |

## Radiographie

| # | Geste | Résultat observable | État |
|---|---|---|---|
| R1 | Fermer | part au premier toucher | ✅ `testRadiographyCloseWorksOnFirstTap` |
| R2 | Carte dense | rien ne déborde, rien ne se recouvre | ✅ `testDenseRegionsStayInsideScreenAndDoNotOverlap` |
| R3 | Toucher une région | son inspecteur apparaît ; un second toucher le ferme | ✅ `testTouchingARegionOpensAndClosesItsInspector` |
| R4 | Lire la légende | « 4 régions » | ✅ `testLegendCountsTheRegions` |
| R5 | Remonter la chronologie | « ACTION 1 / 4 », retour au direct | ✅ `testTimelineFreezesThenReturnsToLive` |
| R6 | Ouvrir sur un fil sans outil | « Aucune région observée » | ✅ `testEmptyRadiographyAnnouncesThatNothingWasObserved` |
| R7 | Lire une région en échec | son libellé dit « en échec » | ✅ `testFailedRegionSaysSoInItsLabel` |

## Écrans d'attente

| # | Geste | Résultat observable | État |
|---|---|---|---|
| H1 | Attendre au lancement | le nom de l'app et « Connexion au VPS… » | ✅ `testLaunchScreenNamesTheAppAndSaysWhatItIsDoing` |
| H2 | Attendre trop longtemps | l'issue de secours apparaît et ouvre les réglages | ✅ `testEscapeAppearsLateAndOpensTheConnectionSettings` |
| H3 | Attendre une reprise en cours de route | « Reprise de la liaison… », sans le nom de l'app | ✅ `testReconnectingScreenOmitsTheWordmarkAndReturnsToTheConversations` |

## Cadres et réglages système

| # | Geste | Résultat observable | État |
|---|---|---|---|
| A1 | Paysage sur le fil | tout reste touchable | ✅ `testLandscapeChromeAndComposerRemainTouchable` |
| A2 | Paysage sur projets et conversations | idem | ✅ `testProjectsStayReachableInLandscape`, `testConversationsStayReachableInLandscape` |
| A3 | Grande taille de caractères | rangées lisibles, actions atteignables | ✅ `testProjectsRemainUsableAtAccessibleTextSize`, `testConversationsRemainUsableAtAccessibleTextSize` |
| A4 | Animations réduites | les écrans animés restent complets, immobiles et utilisables | ✅ `testContextTideStaysCompleteAndStillWithReducedMotion`, `testRadiographyStaysSteadyAndTouchableWithReducedMotion` |
| A5 | Animations réduites | les canevas cessent de peindre | 🚫 non observable — voir ci-dessous |

## Comptage

- Gestes inventoriés : 68
- Couverts : 66
- Hors de portée, justifiés : 2 (M9, M10 — leurs effets côté app sont couverts)
- Tests d'interface : 102 (40 déjà livrés, 62 ajoutés)

## Ce qui n'est pas observable — mesuré, pas supposé

**Qu'un canevas cesse de peindre** (A5) ne se prouve pas depuis XCUITest.

La tentative est instructive et vaut d'être gardée. Le test comparait deux
captures d'écran espacées d'une seconde, en attendant que rien ne bouge. Trois
mesures, sur le simulateur de référence, l'ont écartée :

| état | pixels qui changent |
|---|---|
| animations réduites, code sain | 0,06 % |
| animations réduites, `TideCurve.animates` forcé à `isLive` | 0,04 % |
| animations réduites, anneau de région forcé à s'animer | 0,00 % |

La mutation ne fait pas bouger l'écran **plus** que le code sain : la capture ne
restitue tout simplement pas ces animations. L'anneau de pulsation fait un point
de large à opacité décroissante, la braise voyageuse en fait quatorze — sous le
seuil de différence chromatique, et probablement hors de ce que compose une
capture. Un test fondé là-dessus n'aurait mesuré que du bruit, dans un sens
comme dans l'autre.

Ce qui reste vérifié sous « réduire les animations » est l'autre moitié, et elle
a sa valeur : les deux écrans s'affichent **en entier**, ne se réorganisent plus
une fois posés, et restent touchables.

### Ce que cette mesure a corrigé au passage

L'argument de lancement `-UIAccessibilityReduceMotionEnabled YES` **ne change pas**
`accessibilityReduceMotion` sur iOS 26 : mesuré à 1,6 % de pixels en mouvement
avec l'argument, contre 0,07 % avec le vrai réglage posé par
`defaults write com.apple.Accessibility ReduceMotionEnabled`. Tous les tests qui
passaient cet argument — le test de paysage livré avant cette feature compris —
croyaient couper les animations sans rien couper.

`HublotMotion.isReduced` lit donc désormais cet argument à la main, sous
`#if DEBUG`. Et trois vues qui lisaient le réglage brut au lieu de passer par
`HublotMotion` — la carte de radiographie, l'anneau de ses régions, le point qui
bat du chrome — y passent maintenant comme les autres : elles continuaient
d'animer sous le mode capture, censé pourtant tout figer.

## Ce qui n'est pas testable parce que ce n'est pas atteignable

**La palette de commandes `/`** (`CommandPalette`, `IAClient-UI/UI/ConversationView.swift`)
est du code mort. `Composer` calcule bien `matches` à partir du brouillon, mais son `body`
ne rend jamais `CommandPalette`, et `ConversationView.commands` n'est alimenté par aucun
appelant — ni `RootView`, ni les écrans témoins. Aucun geste ne peut donc l'atteindre.

Conformément à FR-010, elle est **signalée** plutôt que testée par un chemin détourné :
l'activer serait une feature, pas un test.

## Entités

**Scénario témoin** — nom (`kebab-case`), état rendu, mécanisme (données figées ou relais
témoin). Déclaré dans `HublotUITestScenario`, branché dans `IAClient_UIApp`, construit dans
`ScreenFixtures.swift` ou `ThreadFixtures.swift`.

**Geste** — écran, action, résultat observable, test qui le porte. C'est la table
ci-dessus ; elle est le livrable de suivi de la feature.

**Identifiant d'accessibilité** — clé stable visée par les tests. Voir
`contracts/identifiers.md`.
