# Règles de validation

- Toute fonctionnalité et toute correction de bug doivent recevoir un test de régression automatisé dans le même changement.
- Un comportement visible ou tactile doit être exercé par un test `XCTest` d'interface sur simulateur. Un test unitaire ou une compilation seuls ne suffisent pas.
- Le test doit reproduire le geste et vérifier son résultat observable : toucher, saisie, clavier, défilement, navigation et géométrie selon le cas.
- Avant livraison, exécuter la totalité du schéma `IAClient-UI`, les tests serveur concernés et une compilation Release. Aucun test en échec ou ignoré à cause du changement n'est acceptable.
- Ne jamais déployer ni annoncer la correction comme terminée avant ces validations. Signaler explicitement toute vérification impossible sur l'appareil ou le serveur réel.
- Chaque bug rapporté doit rester couvert afin qu'une modification future ne puisse pas le réintroduire silencieusement.

# Parallélisme des tests

- `Tools/test-local.sh full` tourne avec quatre workers et un build Release séquentiel. Ne pas augmenter ce nombre sans remesurer.
- Mesuré le 9 août 2026 sur MacBook Air M5 (10 cœurs dont 4 de performance, 24 Go), phase de tests seule : 161 s à quatre workers, 170 s à deux, 174 s avec le Release lancé en parallèle, 216 s à six.
- Au-delà de quatre simulateurs, les tests d'interface attendent des animations qui n'obtiennent plus le processeur : le cas le plus lent passe de 20 s à 56 s et frôle les délais de `waitForExistence`. Le débit n'y gagne rien.
- `HUBLOT_WORKERS=2` ne coûte que neuf secondes et laisse la machine utilisable pendant le run; `HUBLOT_PARALLEL_RELEASE=1` sert uniquement à remesurer.
