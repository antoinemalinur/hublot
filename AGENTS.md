# Règles de validation

- Toute fonctionnalité et toute correction de bug doivent recevoir un test de régression automatisé dans le même changement.
- Un comportement visible ou tactile doit être exercé par un test `XCTest` d'interface sur simulateur. Un test unitaire ou une compilation seuls ne suffisent pas.
- Le test doit reproduire le geste et vérifier son résultat observable : toucher, saisie, clavier, défilement, navigation et géométrie selon le cas.
- Avant livraison, exécuter la totalité du schéma `IAClient-UI`, les tests serveur concernés et une compilation Release. Aucun test en échec ou ignoré à cause du changement n'est acceptable.
- Ne jamais déployer ni annoncer la correction comme terminée avant ces validations. Signaler explicitement toute vérification impossible sur l'appareil ou le serveur réel.
- Chaque bug rapporté doit rester couvert afin qu'une modification future ne puisse pas le réintroduire silencieusement.

## Commande locale obligatoire

- Exécuter `Tools/test-local.sh full` avant toute livraison. La commande choisit automatiquement le simulateur `iPhone Air` sur la version iOS disponible la plus récente, lance le plan `IAClient-UI` avec deux workers, refuse les tests ignorés, contrôle la couverture, exécute les tests Python puis compile en Release.
- `Tools/test-local.sh focus <Classe|Classe/testCas> [...]` est la boucle courte du développement : quelques classes en séquentiel, sans couverture, sans tests serveur et sans Release, soit une trentaine de secondes au lieu de sept minutes. La suite d'appartenance est trouvée toute seule. Cette commande ne vaut jamais validation — `full` reste la seule porte de livraison, et le dit en fin d'exécution.
- `Tools/test-local.sh stress` répète les tests Swift concurrents sous Thread Sanitizer.
- Les références visuelles ne peuvent être renouvelées que par `Tools/test-local.sh update-snapshots`; un échec de comparaison ne les met jamais à jour.

## Parallélisme des tests

- Deux workers et un build Release séquentiel : c'est la configuration retenue, ne pas l'augmenter sans remesurer. Les mesures du 9 août 2026 qui donnaient quatre workers pour optimum ne valent plus : la suite a grossi depuis, et quatre simulateurs effondrent désormais le run.
- Mesures du 16 août 2026 sur MacBook Air M5 (10 cœurs dont 4 de performance, 24 Go), phase de tests seule : 446 s à deux workers, 446 s à trois, effondrement à quatre (1223 s et échec).
- Le troisième worker ne rend rien parce que la contention reprend exactement ce que la division donne : le cumulé d'interface enfle de 810 s à 1140 s et la moyenne par test de 7,7 s à 11,0 s. Avec quatre cœurs de performance, un troisième simulateur ne trouve plus de processeur pour animer.
- Le mur vaut la charge du runner d'interface le plus chargé, plus une quarantaine de secondes de build et d'installation : 407 s → 446 s, mesuré sur trois runs. Les 148 cas unitaires n'y pèsent pas, ils tournent dans un seul processus absorbé par les simulateurs.
- Ne pas juger une optimisation sur `xcresulttool get test-results`, qui totalise 2419 s pour un mur de 446 s et met en tête des suites unitaires qui ne coûtent rien. Lire les durées réelles dans `xcode-test.log`, les regrouper par clone, et ne regarder que le runner le plus chargé.
- Chaque cas d'interface coûte 4,1 s avant d'avoir rien vérifié — le cycle `launch()`, confirmé en séquentiel machine au repos, soit environ 432 s de cumulé sur 105 cas. C'est le premier poste de dépense de la suite, et il est incompressible : décomposé le 16 août 2026, il vaut 2,95 s d'arrêt et de démarrage de l'app, 1,08 s pour la première requête d'accessibilité et 0,05 s d'ossature `XCTest`. Retirer le `terminate()` du `tearDown` ne rendrait rien, `launch()` le paie de toute façon en interne (2,95 s avec ou sans). C'est le prix de l'herméticité, pas du gaspillage.
- Réduire les animations du simulateur ne sert à rien : `ReduceMotionEnabled` posé sur l'appareil ne rend que 1,3 % (92,3 s → 91,0 s sur 14 cas). Mesuré le 16 août 2026, inutile de le retenter.
- Le build Release ne dure que 5 s avec un cache chaud; le lancer en parallèle des tests coûte plus cher qu'il ne rapporte.
- `HUBLOT_WORKERS` et `HUBLOT_PARALLEL_RELEASE` permettent de remesurer sur une autre machine.
