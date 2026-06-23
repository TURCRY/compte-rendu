# README `run_compte_rendu_avec_sujets.sh`

## Rôle du script

`run_compte_rendu_avec_sujets.sh` est l'orchestrateur principal du flux compte-rendu côté NAS.

Son rôle réel est :

1. lire `infos_projet.json`
2. résoudre les chemins utiles à partir de ce fichier
3. contrôler la cohérence minimale des entrées
4. lancer le pipeline JSON dans le conteneur `cr-pipeline`
5. persister `pseudo_job_id` et `pseudo_api_base` dans `infos_projet.json`
6. déléguer la fin de chaîne à `render_compte_rendu_from_infos.py`
7. produire in fine le `.docx` final au bon emplacement canonique

La logique de fin de chaîne n'est plus dupliquée dans le `.sh` :

- `run_compte_rendu_avec_sujets.sh` orchestre
- `render_compte_rendu_from_infos.py` relit `global_final.json`, dé-pseudonymise si nécessaire, appelle le renderer DOCX et écrit le document final

Voir aussi :

- [C:\CodexWorkspace\compte-rendu\Scripts\render_compte_rendu_from_infos.py](C:\CodexWorkspace\compte-rendu\Scripts\render_compte_rendu_from_infos.py)
- [C:\CodexWorkspace\compte-rendu\Scripts\README_compte_rendu_from_infos.md](C:\CodexWorkspace\compte-rendu\Scripts\README_compte_rendu_from_infos.md)

## Où lancer le script

Le lancement recommandé en production se fait depuis le dossier où résident les scripts du projet compte-rendu sur le NAS, par exemple :

```text
.../Docker/compte-rendu/Scripts
```

Pourquoi :

- ce dossier contient `run_compte_rendu_avec_sujets.sh`
- il contient aussi `render_compte_rendu_from_infos.py`, appelé ensuite automatiquement par le `.sh`
- le script déduit son voisin Python via `SCRIPT_DIR`, donc il reste robuste même si le répertoire courant varie

En pratique, lancer depuis le dossier `Scripts` est le mode le plus simple et le plus lisible en exploitation.

## Syntaxe de lancement

### Forme générale

```bash
./run_compte_rendu_avec_sujets.sh "/volume1/Affaires/.../infos_projet.json" [--force] [--dry-run] [--strict-sync]
```

Le premier argument est obligatoire :

- chemin hôte/NAS vers `infos_projet.json`

### Miroir PC fixe

Par defaut, tout DOCX genere sur le NAS est recopie vers le PC fixe apres generation reussie.

Comportement :

- `--no-mirror-pc` desactive explicitement cette copie NAS -> PC fixe pour le lancement courant.
- `--mirror-pc` reste accepte pour compatibilite, mais il est maintenant inutile en usage normal puisque le miroir est deja actif par defaut.
- `--mirror-pc-dry-run` active le miroir en simulation rsync, sans copie effective.

La copie miroir utilise `rsync --update`, ne supprime rien, et ne copie que les livrables DOCX/PDF utiles.

### Lancement standard

```bash
cd /volume1/Docker/compte-rendu/Scripts
./run_compte_rendu_avec_sujets.sh \
  "/volume1/Affaires/2025-J46/AF_Expert_ASR/transcriptions/accedit-2025-11-06/infos_projet.json"
```

### Lancement avec `--force`

```bash
cd /volume1/Docker/compte-rendu/Scripts
./run_compte_rendu_avec_sujets.sh \
  "/volume1/Affaires/2025-J46/AF_Expert_ASR/transcriptions/accedit-2025-11-06/infos_projet.json" \
  --force
```

### Lancement avec `--dry-run`

```bash
cd /volume1/Docker/compte-rendu/Scripts
./run_compte_rendu_avec_sujets.sh \
  "/volume1/Affaires/2025-J46/AF_Expert_ASR/transcriptions/accedit-2025-11-06/infos_projet.json" \
  --dry-run
```

### Lancement avec `--strict-sync`

```bash
cd /volume1/Docker/compte-rendu/Scripts
./run_compte_rendu_avec_sujets.sh \
  "/volume1/Affaires/2025-J46/AF_Expert_ASR/transcriptions/accedit-2025-11-06/infos_projet.json" \
  --strict-sync
```

## Format attendu pour `infos_projet.json`

Le script attend un chemin **hôte / NAS**, pas un chemin conteneur.

Format recommandé :

```text
/volume1/Affaires/<id_affaire>/AF_Expert_ASR/transcriptions/<id_captation>/infos_projet.json
```

Exemple :

```text
/volume1/Affaires/2025-J46/AF_Expert_ASR/transcriptions/accedit-2025-11-06/infos_projet.json
```

Important :

- le `.sh` teste `-f "$INFOS"` directement sur l'hôte
- il lit ensuite ce fichier avec Python sur l'hôte
- il ne faut donc pas lui passer un chemin conteneur `/data/...`

En revanche, à partir de ce fichier, le script convertit ensuite les chemins utiles vers le format conteneur `/data/Affaires/...` quand il appelle `cr-pipeline`.

## Ce que fait le script

### 1. Lecture de `infos_projet.json`

Le script :

- lit `infos_projet.json`
- récupère le `profil_execution`
- lit notamment :
  - `id_affaire`
  - `id_captation`
  - `provider`
  - `api_base`
  - `model_pass1`
  - `model_pass2`
  - `model_pass3`
  - `preset`

### 2. Résolution des chemins

Le script résout :

- le CSV de transcription via `profil_execution.fichier_transcription`
- le contexte JSON dans le dossier du CSV :
  - `contexte_general_compte_rendu.json` prioritaire
  - `contexte_general.json` en fallback
- `Sujets.xlsx`
- `Participants.xlsx`

Les chemins hôte sont ensuite convertis en chemins conteneur `/data/Affaires/...` pour le pipeline PowerShell.

### 3. Contrôles de synchronisation

Le script effectue :

- vérification de présence des fichiers obligatoires
- comparaison des dates de modification CSV / contexte / sujets / participants
- avertissements si désalignement
- blocage si `--strict-sync` est actif et qu'un désalignement est détecté

### 4. Exécution du pipeline PowerShell dans `cr-pipeline`

Le script lance :

```text
docker exec -it cr-pipeline pwsh /pipeline/powershell/cr_reunion_point_mumerotes_pipeline_json.ps1 ...
```

avec notamment :

- `-CsvPath`
- `-OutDir`
- `-ContextJsonPath`
- `-SujetsPath`
- `-ParticipantsPath`
- `-Provider`
- `-ApiBase`
- `-ModelPass1`
- `-ModelPass2`
- `-ModelPass3`
- `-Preset`
- éventuellement `-Force`

### 5. Persistance de `pseudo_job_id` / `pseudo_api_base`

Avant l'exécution du pipeline, le script :

- calcule un `PseudoJobId` unique sous la forme :
  `cr_<id_affaire>_<id_captation>_job_<timestamp>`
- détermine `pseudo_api_base`
- écrit ces deux valeurs dans :

```text
infos_projet.json -> compte_rendu
```

Clés écrites :

- `compte_rendu.pseudo_job_id`
- `compte_rendu.pseudo_api_base`

### 6. Appel à `render_compte_rendu_from_infos.py`

Après succès du pipeline JSON, le `.sh` n'appelle plus directement le renderer DOCX via `curl`.

Il appelle :

```text
render_compte_rendu_from_infos.py
```

avec :

- `--infos`
- `--global-final`
- `--provider`
- `--model-pass1`
- `--model-pass2`
- `--model-pass3`

et, si pseudonymisation distante active :

- `--pseudo-job-id`
- `--pseudo-api-base`
- `--pseudo-api-key`

sinon :

- `--no-pseudonymize-remote`

### 7. Dépôt du `.docx` final

Le `.docx` final est écrit par le script Python de rendu, dans le dossier canonique :

```text
\\...\Affaires/<id_affaire>/BE_Traitement_captations/<id_captation>/compte_rendu_LLM/
```

avec un nom du type :

```text
compte_rendu_<id_affaire>_<id_captation>_V_<timestamp>.docx
```

## Sorties attendues

### Dossier canonique principal

Le répertoire de travail du compte-rendu est :

```text
/data/Affaires/<id_affaire>/BE_Traitement_captations/<id_captation>/compte_rendu_LLM
```

Équivalent hôte :

```text
/volume1/Affaires/<id_affaire>/BE_Traitement_captations/<id_captation>/compte_rendu_LLM
```

### Contenu technique produit

Le pipeline écrit directement dans ce dossier canonique, notamment :

- `global.json`
- `global_meeting.json`
- `global_by_sujet.json`
- `global_final.json`
- `sujets_ref.json`
- sous-dossiers techniques :
  - `logs`
  - `segments`
  - `pass2B_batches`
  - `pass2E_sujets_compact`
  - `pass3E_sujets`
  - `sujets`

Important :

- le code actuel n'utilise pas un sous-dossier de run de type `compte_rendu_LLM/out/<job_tag>`
- les logs d'orchestration NAS sont écrits dans :
  - `compte_rendu_LLM/logs/run_<timestamp>.log`
  - `compte_rendu_LLM/logs/run_metadata_<timestamp>.json`

### Emplacement du `.docx` final

Le `.docx` final est écrit dans :

```text
/volume1/Affaires/<id_affaire>/BE_Traitement_captations/<id_captation>/compte_rendu_LLM/
```

## Cas sans pseudonymisation distante

Si le backend n'est pas considéré comme distant :

- pas d'activation de `-PseudonymizeRemote` dans le pipeline
- le rendu final est appelé avec `--no-pseudonymize-remote`
- `global_final.json` est envoyé au rendu sans phase de dé-pseudonymisation finale

## Cas avec pseudonymisation distante

Si :

- `provider=openai`
- et qu'au moins un des modèles `pass1/pass2/pass3` contient `remote`

alors :

- le pipeline reçoit :
  - `-PseudonymizeRemote`
  - `-PseudoApiBase`
  - `-PseudoApiKey`
  - `-PseudoJobId`
  - `-PseudoParticipantsPath`
- le même `PseudoJobId` est persisté dans `infos_projet.json`
- ce même `PseudoJobId` est ensuite transmis à `render_compte_rendu_from_infos.py`
- la dé-pseudonymisation finale est donc faite avec le **même identifiant de registre** que celui utilisé pendant le pipeline

Le `PseudoJobId` est donc le lien explicite entre :

- la pseudonymisation amont
- la dé-pseudonymisation finale

## Dépannage

### Docker / conteneur non trouvé

Symptômes possibles :

- `docker exec` échoue
- `cr-pipeline` n'est pas joignable

À vérifier :

- Docker est démarré
- le conteneur `cr-pipeline` existe et tourne

### `global_final.json` absent

Si le pipeline se termine sans `global_final.json` :

- le `.sh` échoue ensuite sur la phase de rendu final
- il faut diagnostiquer en amont le pipeline PowerShell et ses sorties intermédiaires

### Registre pseudo introuvable

Si la dé-pseudonymisation échoue côté rendu final :

- vérifier que la pseudonymisation distante était bien active
- vérifier que `LOCAL_LLM_API_KEY` est présente
- vérifier que le `PseudoJobId` persisté dans `infos_projet.json` correspond bien au run
- vérifier que le service Flask de pseudonymisation est joignable

### Script Python de rendu non synchronisé

Si le `.sh` trouve `global_final.json` mais échoue sur le script Python :

- vérifier la présence de `render_compte_rendu_from_infos.py` dans le même dossier `Scripts`
- vérifier que la version déployée est bien la version à jour

### Erreurs de chemin `Sujets.xlsx` / `Participants.xlsx`

Le script exige ces fichiers dans le dossier du CSV.

À vérifier :

- présence de `Sujets.xlsx`
- présence de `Participants.xlsx`
- cohérence temporelle avec le CSV si `--strict-sync` est utilisé

## Relation entre les composants

Chaîne canonique actuelle :

1. `run_compte_rendu_avec_sujets.sh`
   orchestre le run NAS
2. `cr_reunion_point_mumerotes_pipeline_json.ps1`
   produit les JSON techniques, jusqu'à `global_final.json`
3. `render_compte_rendu_from_infos.py`
   relit `global_final.json`, dé-pseudonymise si nécessaire, appelle le renderer et écrit le `.docx`
4. `README_compte_rendu_from_infos.md`
   documente spécifiquement cette fin de chaîne Python
