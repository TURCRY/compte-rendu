# Comparaison jobs A60 pour Pass2E / split_by_sujet

## Jobs compares

1. Ancienne reference :

```text
C:\CodexWorkspace\compte-rendu\test\job_manuel
```

2. Reference actuelle apres restauration Pass1 :

```text
C:\CodexWorkspace\compte-rendu\Scripts\a60_report_model_compare\job_validation_timing_guard
```

Cette comparaison ne relance pas le pipeline. Elle lit uniquement les artefacts existants.

## Synthese courte

Les deux jobs ne sont pas structurellement equivalents cote segments Pass1.

L'ancien job expose les interventions sujet a deux endroits :

- `segment.sujets`
- `segment.llm_analysis.sujets`

Le job actuel expose les interventions uniquement dans :

- `segment.llm_analysis.sujets`

Dans le job actuel, `segment.sujets` est vide pour les 14 segments. Comme l'agregateur Pass2A historique lisait seulement `segment.sujets`, il produit :

```json
{ "sujets": {} }
```

Cela explique directement :

- `sujets/sujet_001.json` a `interventions=[]` ;
- idem pour les 7 sujets ;
- Pass2E obtient `chunk_count=0` pour 7/7 sujets ;
- `pipeline_qa_status.json` signale `Passe 2E a 100% des sujets sans chunk`.

Le probleme n'est donc pas un probleme LLM Pass2E. C'est un probleme de chaînage structurel entre Pass1 et Pass2A.

## Comparaison Pass1

Les deux jobs ont une Pass1 saine :

| Job | segment_count | fallback_count | fallback_ratio |
|---|---:|---:|---:|
| ancien `job_manuel` | 14 | 0 | 0.0 |
| actuel `job_validation_timing_guard` | 14 | 0 | 0.0 |

## Forme des segments

### Ancien job

Interventions presentes dans `segment.sujets` et dans `segment.llm_analysis.sujets`.

Comptage par segment :

| Segment | `segment.sujets` | `llm_analysis.sujets` |
|---|---:|---:|
| segment_02 | 3 | 3 |
| segment_03 | 3 | 3 |
| segment_05 | 3 | 3 |
| segment_06 | 7 | 7 |
| segment_12 | 2 | 2 |
| autres segments | 0 | 0 |

Total : 18 interventions exploitables.

### Job actuel

Interventions absentes de `segment.sujets`, mais presentes dans `segment.llm_analysis.sujets`.

Comptage par segment :

| Segment | `segment.sujets` | `llm_analysis.sujets` |
|---|---:|---:|
| segment_02 | 0 | 4 |
| segment_03 | 0 | 14 |
| segment_05 | 0 | 3 |
| segment_06 | 0 | 7 |
| segment_12 | 0 | 2 |
| autres segments | 0 | 0 |

Total : 30 interventions exploitables, mais uniquement dans `llm_analysis.sujets`.

## global.json

### Ancien job

`global.json` contient 18 interventions :

```text
sujet 1: 8
sujet 3: 4
sujet 4: 1
sujet 5: 5
```

Les sujets 2, 6 et 7 sont sans interventions.

### Job actuel

`global.json` contient :

```json
{ "sujets": {} }
```

Il est vide parce que Pass2A n'a lu que `segment.sujets`, vide dans ce job.

## sujets/sujet_XXX.json

### Ancien job

Les fichiers split refletent correctement `global.json` :

```text
sujet_001: 8 interventions
sujet_002: 0
sujet_003: 4
sujet_004: 1
sujet_005: 5
sujet_006: 0
sujet_007: 0
```

Pass2E signale donc seulement 3 sujets sans chunk : 2, 6, 7.

### Job actuel

Tous les fichiers sujet sont vides :

```text
sujet_001: 0
sujet_002: 0
sujet_003: 0
sujet_004: 0
sujet_005: 0
sujet_006: 0
sujet_007: 0
```

C'est la consequence directe du `global.json` vide.

## Reponses aux questions

### 1. Les segments actuels contiennent-ils les informations uniquement dans `llm_analysis.sujets` ?

Oui.

Dans `job_validation_timing_guard`, `segment.sujets` est vide pour les 14 segments. Les interventions utiles sont uniquement dans `segment.llm_analysis.sujets`.

### 2. L'ancien job et le nouveau job presentent-ils la meme cause de `global.json` vide ?

Non.

L'ancien job n'a pas un `global.json` vide : il contient 18 interventions. Il a seulement 3 sujets sans match.

Le job actuel a un `global.json` vide parce que les interventions ne sont plus projetees dans `segment.sujets`, alors que Pass2A lit uniquement cette ancienne vue.

### 3. La correction `Aggregate-Sujets` est-elle valable pour les deux formats ?

Oui.

La correction est compatible avec :

- l'ancien format : `segment.sujets` ;
- le format actuel : `segment.llm_analysis.sujets` ;
- le format liste : `llm_analysis.sujets = [{ titre, interventions }]`.

Elle selectionne la source qui contient effectivement des interventions. Sur l'ancien job, elle conserve le comportement existant. Sur le job actuel, elle recupere les interventions depuis `llm_analysis.sujets`.

### 4. Apres correction, que donnerait `Aggregate-Sujets` sur le job actuel ?

Simulation sans relance pipeline :

```text
sujet 1: 8 interventions
sujet 2: 2 interventions
sujet 3: 6 interventions
sujet 4: 3 interventions
sujet 5: 7 interventions
sujet 6: 2 interventions
sujet 7: 2 interventions
```

Total : 30 interventions.

Donc le `global.json` actuel ne serait plus vide apres correction de l'agregateur.

### 5. Faut-il relancer A60 pour confirmer que Pass2E recupere des chunks ?

Oui.

La simulation confirme que Pass2A peut reconstruire un `global.json` non vide sur le job actuel, mais seule une relance A60 de l'aval permet de confirmer toute la chaîne :

```text
Aggregate-Sujets -> global.json -> split_by_sujet.py -> sujets/sujet_XXX.json -> Pass2E
```

Le point de validation attendu apres relance :

- `pass2a_subject_matching_qa.json` : total_interventions > 0 ;
- `split_by_sujet_qa.json` : clean_interventions > 0 ;
- `sujets/sujet_001.json` etc. : `interventions` non vides ;
- `pass2e_qa.json` : plus de `100% des sujets sans chunk`.

## Conclusion

La restauration Pass1 a bien change la forme effective consommee par l'aval :

- ancien job : interventions dans `segment.sujets` et `llm_analysis.sujets` ;
- job actuel : interventions uniquement dans `llm_analysis.sujets`.

La correction minimale doit rester dans Pass2A, pas dans Pass1 :

- lire `segment.sujets` si disponible ;
- sinon lire `segment.llm_analysis.sujets` ;
- instrumenter les stats de matching pour verifier la presence d'interventions avant `split_by_sujet.py`.

