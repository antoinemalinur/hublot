# Quickstart — exécuter et vérifier la couverture

## Prérequis

- Xcode avec un simulateur `iPhone Air` disponible (le script choisit seul l'iOS le plus
  récent).
- Python 3 pour les tests du relais.

## Tout valider, comme avant livraison

```bash
Tools/test-local.sh full
```

Enchaîne : `build-for-testing`, le plan `IAClient-UI` complet à quatre workers, le contrôle
des échecs et des tests ignorés, le contrôle de couverture (80 % global, 90 % sur les
fichiers critiques), les tests Python du relais, puis un build Release.

Attendu : aucun échec, aucun test ignoré, et une phase de tests sous trois minutes.

## Ne rejouer que l'interface

```bash
xcodebuild test \
  -project IAClient-UI.xcodeproj -scheme IAClient-UI -testPlan IAClient-UI \
  -destination "platform=iOS Simulator,name=iPhone Air" \
  -only-testing:IAClient-UIScreenTests
```

Un seul fichier :

```bash
  -only-testing:IAClient-UIScreenTests/ThreadBlocksScreenTests
```

## Voir un état témoin à l'œil nu

```bash
xcrun simctl launch --terminate-running-process booted antoinemalinur.IAClient-UI \
  -HublotUITestScenario thread-blocks
```

Remplacer `thread-blocks` par n'importe quel nom de `contracts/scenarios.md`. C'est le même
chemin que celui qu'empruntent les tests : ce qu'on voit est ce qu'ils voient.

## Vérifier qu'un test tient vraiment (principe III)

Un test anti-régression n'est acquis qu'après avoir été vu rouge. Pour chaque nouveau test :

1. Retirer ou inverser la ligne d'interface qu'il protège (un `if`, un libellé, un
   identifiant).
2. Relancer le seul test concerné : il doit échouer, et sur son assertion, pas sur un
   `waitForExistence` accidentel.
3. Remettre la ligne, relancer : il doit passer.

## Renouveler les références visuelles

```bash
Tools/test-local.sh update-snapshots
```

Uniquement quand le rendu change volontairement. Un échec de comparaison ne met jamais les
références à jour.

## Résultat attendu de la feature

- Chaque ligne ➕ de `data-model.md` porte le nom d'un test réel.
- `Tools/test-local.sh full` passe en entier.
- Deux exécutions consécutives donnent le même résultat.
