# Règles de validation

- Toute fonctionnalité et toute correction de bug doivent recevoir un test de régression automatisé dans le même changement.
- Un comportement visible ou tactile doit être exercé par un test `XCTest` d'interface sur simulateur. Un test unitaire ou une compilation seuls ne suffisent pas.
- Le test doit reproduire le geste et vérifier son résultat observable : toucher, saisie, clavier, défilement, navigation et géométrie selon le cas.
- Avant livraison, exécuter la totalité du schéma `IAClient-UI`, les tests serveur concernés et une compilation Release. Aucun test en échec ou ignoré à cause du changement n'est acceptable.
- Ne jamais déployer ni annoncer la correction comme terminée avant ces validations. Signaler explicitement toute vérification impossible sur l'appareil ou le serveur réel.
- Chaque bug rapporté doit rester couvert afin qu'une modification future ne puisse pas le réintroduire silencieusement.

## Commande locale obligatoire

- Exécuter `Tools/test-local.sh full` avant toute livraison. La commande choisit automatiquement le simulateur `iPhone Air` sur la version iOS disponible la plus récente, lance le plan `IAClient-UI` avec quatre workers, refuse les tests ignorés, contrôle la couverture, exécute les tests Python puis compile en Release.
- `Tools/test-local.sh stress` répète les tests Swift concurrents sous Thread Sanitizer.
- Les références visuelles ne peuvent être renouvelées que par `Tools/test-local.sh update-snapshots`; un échec de comparaison ne les met jamais à jour.

## Parallélisme des tests

- Quatre workers et un build Release séquentiel : c'est la configuration retenue, ne pas l'augmenter sans remesurer.
- Mesures du 9 août 2026 sur MacBook Air M5 (10 cœurs dont 4 de performance, 24 Go), phase de tests seule : 161 s à quatre workers en Release séquentiel, 170 s à deux workers, 174 s à quatre workers avec le Release en parallèle, 216 s à six workers.
- Au-delà de quatre simulateurs, les tests d'interface passent leur temps à attendre des animations qui n'obtiennent plus le processeur : le travail cumulé enfle de 673 s à 1087 s et le cas le plus lent passe de 20 s à 56 s, jusqu'à frôler les délais de `waitForExistence`. Le débit n'y gagne rien.
- Le build Release ne dure que 5 s avec un cache chaud; le lancer en parallèle des tests coûte plus cher qu'il ne rapporte.
- `HUBLOT_WORKERS` et `HUBLOT_PARALLEL_RELEASE` permettent de remesurer sur une autre machine. `HUBLOT_WORKERS=2` ne coûte que neuf secondes et laisse la machine utilisable pendant le run.
