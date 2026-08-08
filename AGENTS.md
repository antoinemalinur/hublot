# Règles de validation

- Toute fonctionnalité et toute correction de bug doivent recevoir un test de régression automatisé dans le même changement.
- Un comportement visible ou tactile doit être exercé par un test `XCTest` d'interface sur simulateur. Un test unitaire ou une compilation seuls ne suffisent pas.
- Le test doit reproduire le geste et vérifier son résultat observable : toucher, saisie, clavier, défilement, navigation et géométrie selon le cas.
- Avant livraison, exécuter la totalité du schéma `IAClient-UI`, les tests serveur concernés et une compilation Release. Aucun test en échec ou ignoré à cause du changement n'est acceptable.
- Ne jamais déployer ni annoncer la correction comme terminée avant ces validations. Signaler explicitement toute vérification impossible sur l'appareil ou le serveur réel.
- Chaque bug rapporté doit rester couvert afin qu'une modification future ne puisse pas le réintroduire silencieusement.
