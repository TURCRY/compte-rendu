# Diagnostic Pass2E / split_by_sujet

## Contexte

Le benchmark A60 `report_remote` est valide pour Pass1 et Pass2B :

- Pass1 produit 14 segments valides, sans fallback.
- Pass2B produit un `global_meeting.json` riche.
- Le problème restant est local au chaînage par sujet : `global.json` -> `split_by_sujet.py` -> Pass2E -> Pass3E.

## Chaîne actuelle

1. Pass1 écrit `segments/segment_XX.json`.
2. Chaque segment contient une enveloppe déterministe ASR et une analyse LLM :
   - `llm_analysis`
   - `llm_valid`
   - `llm_fallback`
   - `texte_source`
   - parfois une vue legacy `sujets`.
3. Pass2A charge les segments et construit `global.json` via `Aggregate-Sujets`.
4. `split_by_sujet.py` lit `global.json`, attend :
   ```json
   { "sujets": { "1": [ { "segment_id": "...", "timecode": "...", "texte": "..." } ] } }
   ```
5. `split_by_sujet.py` écrit `sujets/sujet_XXX.json`.
6. Pass2E lit ces fichiers et crée `pass2E_sujets_compact/sujet_XXX_compact.json`.

## Point de rupture identifié

`Aggregate-Sujets` lisait uniquement :

```powershell
$seg.sujets
```

Or la stabilisation de Pass1 a déplacé la sortie LLM fiable dans :

```powershell
$seg.llm_analysis.sujets
```

La propriété top-level `sujets` n'est plus la source canonique. Elle n'est qu'une vue de compatibilité. Si cette vue est vide, absente, ou non projetée depuis le nouveau format, Pass2A produit un `global.json` sans interventions par sujet.

Conséquence :

- `split_by_sujet.py` ne reçoit aucune intervention à répartir ;
- il écrit des fichiers `sujet_XXX.json` sans `interventions` ;
- Pass2E calcule `chunk_count = 0` ;
- `global_final.json` reçoit des synthèses par sujet vides du type "Aucun élément relatif à ce point...".

Pass2B peut rester riche malgré cela, car il travaille par segments et peut encore exploiter `texte_source` ou d'autres projections compactes. C'est pourquoi `global_meeting.json` peut être bon alors que Pass2E est vide.

## Correction minimale appliquée

Sans modifier Pass1, `report_remote`, le benchmark ou `adapter.py`, Pass2A est rendu compatible avec les deux formes :

- ancienne forme :
  ```json
  { "sujets": { "3": [ ... ] } }
  ```
- nouvelle forme Pass1 :
  ```json
  {
    "llm_analysis": {
      "sujets": [
        {
          "titre": "3 - Réserve 4226 - chemin de câbles",
          "interventions": [ ... ]
        }
      ]
    }
  }
  ```

`Aggregate-Sujets` sélectionne désormais la meilleure source disponible :

1. `segment.sujets` si elle contient des interventions ;
2. sinon `segment.llm_analysis.sujets`.

Le format liste `sujets[]` est converti en clés numériques en lisant le préfixe du titre (`"3 - ..."`) avec fallback sur l'index.

## Instrumentation QA ajoutée

### Pass2A

Nouveau fichier :

```text
pass2a_subject_matching_qa.json
```

Contenu :

- nombre de segments lus ;
- nombre total d'interventions agrégées ;
- nombre d'interventions par sujet ;
- sujets sans match ;
- diagnostic par segment :
  - source retenue (`segment.sujets` ou `segment.llm_analysis.sujets`) ;
  - nombre de paires sujet ;
  - nombre d'interventions ;
  - raison si aucune intervention.
- lignes ASR rattachees a plusieurs sujets :
  - `row_ref` ;
  - nombre de sujets concernes ;
  - liste des sujets ;
  - extrait texte ;
  - `classification`.

Classification simple :

- `contexte_global` si un `row_ref` est rattache a 4 sujets ou plus ;
- `specifique` sinon.

Cette classification est une QA et un marquage aval. Elle ne supprime aucune intervention.

Un warning non critique est journalise si un `row_ref` est rattache a plus de 3 sujets. Sur A60, les lignes 138 et 139 sont typiquement dans ce cas : elles parlent globalement des "7 reserves a livraison" et peuvent servir de contexte commun, mais ne constituent pas a elles seules une preuve specifique pour chaque reserve.

Les interventions marquees `projection_classification = "contexte_global"` sont conservees dans `global.json`, propagees dans `split_by_sujet.py`, puis visibles dans les chunks Pass2E. Le prompt Pass2E demande de les utiliser comme contexte general et non comme preuve specifique sauf corroboration.

### split_by_sujet.py

Nouveau fichier :

```text
split_by_sujet_qa.json
```

ou `sujets/split_qa.json` si aucun chemin explicite n'est fourni.

Contenu :

- clés sujet présentes dans `global.json` ;
- clés globales non référencées dans `sujets_ref.json` ;
- nombre brut et nettoyé d'interventions par sujet ;
- sujets sans match ;
- raisons :
  - `subject_key_absent_from_global`
  - `subject_key_present_but_empty`
  - `non_object_interventions`
  - `empty_text_interventions`
  - `invalid_timecode_interventions`
  - `dedup_removed`
  - `no_clean_interventions`

## Vérifications locales

Contrôles effectués :

- parse PowerShell OK ;
- compilation Python de `split_by_sujet.py` OK ;
- test ciblé PowerShell : `Aggregate-Sujets` récupère correctement un segment dont `segment.sujets` est vide mais dont `llm_analysis.sujets` contient une liste de sujets ;
- exécution de `split_by_sujet.py` sur `test/job_manuel/global.json` vers un dossier temporaire : la nouvelle QA identifie précisément les sujets absents de `global.json`.

## Conclusion

Les interventions ne disparaissent pas dans le LLM Pass2E. Elles disparaissent avant, à la construction de `global.json`, lorsque Pass2A ne voit pas la structure Pass1 canonique `llm_analysis.sujets`.

La correction robuste consiste à rendre Pass2A bilingue :

- lire l'ancienne vue `sujets` si elle est exploitable ;
- sinon lire `llm_analysis.sujets` ;
- produire une QA explicite de matching avant `split_by_sujet.py`.
