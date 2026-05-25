# Controle projection `llm_analysis.sujets` sur A60

## Objectif

Verifier, sans relancer de LLM ni le pipeline complet, ce que donnerait l'agregateur corrige sur :

```text
C:\CodexWorkspace\compte-rendu\Scripts\a60_report_model_compare\job_validation_timing_guard
```

et comparer avec l'ancien job :

```text
C:\CodexWorkspace\compte-rendu\test\job_manuel
```

La projection a ete faite hors pipeline, en memoire, depuis les fichiers :

```text
segments/segment_XX.json
```

Les timecodes ont ete reconstruits depuis `texte_source` avec les lignes :

```text
[ROW n] [HH:MM:SS] SPEAKER: texte
```

## Resultat structurel

### Ancien job `job_manuel`

Les interventions sont presentes dans les deux vues :

- `segment.sujets`
- `segment.llm_analysis.sujets`

`global.json` contient deja des interventions :

| Sujet | Interventions |
|---:|---:|
| 1 | 8 |
| 2 | 0 |
| 3 | 4 |
| 4 | 1 |
| 5 | 5 |
| 6 | 0 |
| 7 | 0 |

Total : 18 interventions.

### Job actuel `job_validation_timing_guard`

Les interventions sont absentes de `segment.sujets`, mais presentes dans :

```text
segment.llm_analysis.sujets
```

La projection corrigee donne :

| Sujet | Interventions projetees |
|---:|---:|
| 1 | 8 |
| 2 | 2 |
| 3 | 6 |
| 4 | 3 |
| 5 | 7 |
| 6 | 2 |
| 7 | 2 |

Total : 30 interventions.

## Controle `row_ref` et timecodes

Toutes les interventions du job actuel ont ete rattachees a une ligne source :

- `row_ref` introuvables : 0
- timecodes reconstruits manquants : 0
- doublons exacts par sujet `(timecode, texte)` : 0

La reconstruction technique est donc saine : les timecodes ne sont pas perdus.

## Projection detaillee du job actuel

### Sujet 1

8 interventions :

```text
segment_02 row 64  00:07:18  qui porte sur 7 désordres.
segment_02 row 65  00:07:22  qualifié comme tel à la livraison, sur lesquelles effectivement les parties sont en désaccord.
segment_02 row 118 00:10:23  la résolution de ces 7 réserves à livraison participe d'un paiement d'à peu près 890 000, 900 000 euros.
segment_02 row 119 00:10:37  Il y a des lectures du contrat qui sont différentes des deux côtés...
segment_03 row 138 00:12:38  Vous avez proposé, M. P29... une espèce de relevé de ces 7 réserves à livraison,
segment_03 row 139 00:12:46  de ces 7 réserves à livraison,
segment_12 row 663 00:43:24  [intervention liée aux 7 réserves]
segment_12 row 664 00:43:30  [intervention liée aux 7 réserves]
```

### Sujet 2

2 interventions :

```text
segment_03 row 138 00:12:38  Vous avez proposé, M. P29... une espèce de relevé de ces 7 réserves à livraison,
segment_03 row 139 00:12:46  de ces 7 réserves à livraison,
```

Ces deux lignes sont generiques : elles parlent des 7 reserves globalement, pas specifiquement du PC securite R&D.

### Sujet 3

6 interventions :

```text
segment_03 row 138 00:12:38  Vous avez proposé, M. P29... une espèce de relevé de ces 7 réserves à livraison,
segment_03 row 139 00:12:46  de ces 7 réserves à livraison,
segment_06 row 322 00:25:02  Il y a des sujets faciles... manque le chemin de câble.
segment_06 row 323 00:25:09  Est-ce qu'il était prévu ?
segment_06 row 324 00:25:11  C'est quoi un chemin de câble ?
segment_06 row 346 00:26:10  ... le chemin de câble voit bien qu'il est là.
```

Les 4 lignes de `segment_06` sont pertinentes pour le sujet 3. Les 2 lignes de `segment_03` sont generiques.

### Sujet 4

3 interventions :

```text
segment_03 row 138 00:12:38  Vous avez proposé, M. P29... une espèce de relevé de ces 7 réserves à livraison,
segment_03 row 139 00:12:46  de ces 7 réserves à livraison,
segment_05 row 293 00:23:37  Voilà, GTC non fonctionnel, quelle est la performance attendue ?
```

La ligne `segment_05 row 293` est pertinente pour la GTC. Les 2 lignes de `segment_03` sont generiques.

### Sujet 5

7 interventions :

```text
segment_03 row 138 00:12:38  Vous avez proposé, M. P29... une espèce de relevé de ces 7 réserves à livraison,
segment_03 row 139 00:12:46  de ces 7 réserves à livraison,
segment_05 row 295 00:23:42  dimension ouverture de bande non conforme au P62,
segment_05 row 297 00:23:46  Je ne sais pas si le P62 a été signé.
segment_06 row 306 00:24:00  ... Dimension, ouverture, porte, non conforme P62.
segment_06 row 307 00:24:05  Dimension, ouverture, porte, non conforme P62.
segment_06 row 319 00:24:47  ... le P62, signé, pas signé, conforme, pas conforme...
```

Les lignes P62/ouverture sont pertinentes pour le sujet 5. Les 2 lignes de `segment_03` sont generiques.

### Sujet 6

2 interventions :

```text
segment_03 row 138 00:12:38  Vous avez proposé, M. P29... une espèce de relevé de ces 7 réserves à livraison,
segment_03 row 139 00:12:46  de ces 7 réserves à livraison,
```

Ces deux lignes sont generiques : elles ne parlent pas specifiquement des luminaires.

### Sujet 7

2 interventions :

```text
segment_03 row 138 00:12:38  Vous avez proposé, M. P29... une espèce de relevé de ces 7 réserves à livraison,
segment_03 row 139 00:12:46  de ces 7 réserves à livraison,
```

Ces deux lignes sont generiques : elles ne parlent pas specifiquement du mode hiver.

## Comparaison avec `job_manuel`

| Sujet | Ancien job | Projection actuelle | Ecart |
|---:|---:|---:|---:|
| 1 | 8 | 8 | 0 |
| 2 | 0 | 2 | +2 |
| 3 | 4 | 6 | +2 |
| 4 | 1 | 3 | +2 |
| 5 | 5 | 7 | +2 |
| 6 | 0 | 2 | +2 |
| 7 | 0 | 2 | +2 |

L'ecart vient principalement des lignes `segment_03 row 138` et `row 139`, rattachees par le LLM a tous les sujets 1 a 7.

Ces lignes sont utiles comme contexte global des 7 reserves, mais elles sont peu discriminantes pour les sujets 2, 6 et 7.

## Doublons et surrepresentation

Il n'y a pas de doublon exact a l'interieur d'un meme sujet.

En revanche, il existe un doublonnage transversal volontaire ou involontaire :

```text
row 138 -> sujets 1,2,3,4,5,6,7
row 139 -> sujets 1,2,3,4,5,6,7
```

Cela explique que les sujets 2, 6 et 7 ne soient plus absents dans la projection actuelle, mais uniquement grace a deux lignes generiques.

## Reponses de controle

### Les 30 interventions reconstruites sont-elles techniquement exploitables ?

Oui. Elles ont toutes un `row_ref`, un timecode reconstruit, un segment source et un texte.

### Sont-elles toutes qualitativement pertinentes ?

Non. Les interventions specifiques sont bonnes pour les sujets 3, 4 et 5. Les sujets 2, 6 et 7 ne reçoivent que des lignes generiques sur les 7 reserves.

### La correction `Aggregate-Sujets` suffit-elle a eviter Pass2E 100% sans chunk ?

Oui. Avec 30 interventions projetees, `split_by_sujet.py` ne devrait plus produire 7 sujets vides.

### La correction suffit-elle a garantir une synthese fine par sujet ?

Pas completement. Elle restaure le chaînage, mais elle peut faire entrer du contexte generique dans plusieurs sujets. Une QA doit signaler les lignes rattachees a un grand nombre de sujets.

## Recommandation

Valider la correction `Aggregate-Sujets` pour restaurer les chunks Pass2E.

Ajouter ensuite, si necessaire, une QA aval non bloquante :

- compter les `row_ref` presents dans plusieurs sujets ;
- signaler les lignes rattachees a plus de 3 sujets ;
- distinguer `interventions_specifiques` et `interventions_contexte_global` si le texte contient seulement "7 reserves", "ensemble des reserves" ou une formulation globale.

Cette recommandation ne remet pas en cause Pass1. Elle concerne uniquement la qualite du matching aval.

