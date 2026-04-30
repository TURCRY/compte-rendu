# README `render_compte_rendu_from_infos.py`

## Positionnement réel du script

`render_compte_rendu_from_infos.py` n'est pas l'orchestrateur principal du pipeline JSON compte-rendu.

L'orchestration métier principale est assurée en amont, côté NAS / chaîne d'exécution, notamment par :

- `run_compte_rendu_avec_sujets.sh`

Dans cette chaîne canonique, `run_compte_rendu_avec_sujets.sh` orchestre le pipeline NAS puis délègue la phase finale DOCX à `render_compte_rendu_from_infos.py`.

Le rôle réel de `render_compte_rendu_from_infos.py` est la fin de chaîne :

1. résoudre les chemins utiles à partir de `infos_projet.json`
2. localiser `global_final.json`
3. dé-pseudonymiser le payload final si nécessaire
4. envoyer la version claire au renderer DOCX
5. écrire le `.docx` final à l'emplacement prévu

Le script réel documenté ici est :

- [C:\CodexWorkspace\compte-rendu\Scripts\render_compte_rendu_from_infos.py](C:\CodexWorkspace\compte-rendu\Scripts\render_compte_rendu_from_infos.py)

## Fonctionnement réel

### 1. Résolution des chemins via `infos_projet.json`

Le script charge `infos_projet.json` via `--infos`, puis résout :

- `id_affaire`
- `id_captation`
- le CSV de transcription
- le contexte JSON
- `Sujets.xlsx`
- `Participants.xlsx`
- le dossier de sortie final canonique

Ordre de résolution principal :

- CSV :
  1. `--csv`
  2. `infos["fichier_transcription"]`
  3. `infos["pcfixe"]["fichier_transcription"]`
- contexte :
  1. `--context`
  2. `infos["fichier_contexte_general"]`
  3. `infos["pcfixe"]["fichier_contexte_general"]`
  4. `<dossier_csv>\contexte_general_compte_rendu.json`
  5. `<dossier_csv>\contexte_general.json`
- sujets :
  1. `--sujets`
  2. `infos["fichier_sujets"]`
  3. `infos["sujets_path"]`
  4. `infos["pcfixe"]["fichier_sujets"]`
  5. `infos["pcfixe"]["sujets_path"]`
  6. `<dossier_csv>\Sujets.xlsx`
- participants :
  1. `--participants`
  2. `infos["fichier_participants"]`
  3. `infos["participants_path"]`
  4. `infos["pcfixe"]["fichier_participants"]`
  5. `infos["pcfixe"]["participants_path"]`
  6. `<dossier_csv>\Participants.xlsx`

### 2. Localisation de `global_final.json`

Deux modes existent.

#### Mode standard

Le script relance le pipeline, puis attend :

```text
<dossier_sortie_final>\global_final.json
```

#### Mode rendu seul

Le script peut repartir d'un `global_final.json` déjà existant avec :

```text
--global-final <path>
```

Dans ce mode, le pipeline n'est pas relancé.

Le script ne résout alors pas les entrées amont du pipeline :

- CSV de transcription
- contexte JSON
- `Sujets.xlsx`
- `Participants.xlsx`

Autrement dit, le mode rendu seul dépend uniquement de :

- `infos_projet.json`
- `global_final.json`
- `pseudo_job_id` si la dé-pseudonymisation distante est active

### 3. Dé-pseudonymisation conditionnelle

La dé-pseudonymisation finale est exécutée seulement si :

- `--pseudonymize-remote` est actif
- et si le backend est considéré comme distant, c'est-à-dire :
  - `provider=openai`
  - et au moins un des modèles `pass1/pass2/pass3` contient `remote`

L'appel effectué est :

```http
POST /depseudonymize
```

avec :

- `text` = contenu brut de `global_final.json`
- `job_id`
- `mode = "compte_rendu_final"`
- header `x-api-key`

Le renderer reçoit ensuite la version dé-pseudonymisée.

### 4. Rendu DOCX

Après lecture éventuelle et dé-pseudonymisation du JSON final, le script envoie :

```http
POST <render-url>
```

avec :

- `json=payload_json`

Le renderer ciblé par défaut est :

```text
http://192.168.1.20:8081/render?format=docx
```

### 5. Écriture du `.docx`

Le binaire DOCX renvoyé par le renderer est écrit dans le dossier final canonique :

```text
\\...\Affaires\<id_affaire>\BE_Traitement_captations\<id_captation>\compte_rendu_LLM\
```

avec le nom :

```text
compte_rendu_<id_affaire>_<id_captation>_V_<YYYYMMDD_HHMMSS>.docx
```

## Paramètres CLI actuels

### Paramètres principaux

- `--infos`
  Obligatoire. Chemin vers `infos_projet.json`.
- `--render-url`
  URL HTTP du renderer DOCX.
- `--container`
  Nom du conteneur Docker du pipeline.
- `--pipeline-script`
  Chemin du script PowerShell dans le conteneur.
- `--csv`
  Override du CSV de transcription.
- `--context`
  Override du contexte JSON.
- `--sujets`
  Override de `Sujets.xlsx`.
- `--participants`
  Override de `Participants.xlsx`.

### Paramètres pipeline / backend

- `--provider`
- `--api-base`
- `--model-pass1`
- `--model-pass2`
- `--model-pass3`
- `--preset`
- `--api-key`
- `--force`

### Paramètres pseudonymisation / rendu final

- `--pseudo-api-base`
  Base URL du service Flask de pseudonymisation.
  Si non fourni, le script tente d'abord `infos_projet.json -> compte_rendu.pseudo_api_base`, puis le défaut runtime.
- `--pseudo-api-key`
  Clé API transmise au service Flask.
- `--pseudo-job-id`
  Identifiant de job à réutiliser pour la dé-pseudonymisation finale.
  Si non fourni, le script tente `infos_projet.json -> compte_rendu.pseudo_job_id`.
- `--pseudonymize-remote`
  Active la dé-pseudonymisation finale quand le backend est distant.
- `--no-pseudonymize-remote`
  Désactive cette dé-pseudonymisation.

### Nouveau mode rendu seul

- `--global-final`
  Chemin d'un `global_final.json` déjà produit.

Quand `--global-final` est fourni :

- le pipeline n'est pas relancé
- le script repart directement du JSON final
- le script ne tente pas de résoudre `Sujets.xlsx`, `Participants.xlsx`, le CSV ni le contexte pipeline
- si la dé-pseudonymisation distante reste active, le `pseudo_job_id` doit correspondre au job utilisé lors de la pseudonymisation amont
- ce `pseudo_job_id` peut être fourni soit :
  - explicitement via `--pseudo-job-id`
  - soit implicitement depuis `infos_projet.json -> compte_rendu.pseudo_job_id`

## Dé-pseudonymisation finale

### Quand elle est active

La dé-pseudonymisation finale intervient si :

- `pseudonymize_remote=True`
- `provider=openai`
- et au moins un modèle `pass1/pass2/pass3` contient `remote`

### Ce que reçoit le renderer

Le renderer DOCX reçoit :

- la version dé-pseudonymisée si la dé-pseudonymisation est active
- sinon le JSON brut lu depuis `global_final.json`

Autrement dit, quand la pseudonymisation distante est utilisée correctement, le renderer ne doit pas recevoir la version pseudonymisée.

### Importance du `job_id`

Le `job_id` est indispensable pour relier la dé-pseudonymisation finale au registre de pseudonymisation créé pendant le pipeline.

En mode standard :

- il est généré par le script sous la forme :
  `cr_<id_affaire>_<id_captation>_<job_tag>`
- et peut être persisté dans `infos_projet.json -> compte_rendu.pseudo_job_id` par l'orchestrateur NAS
- la base Flask de pseudonymisation peut être persistée dans `infos_projet.json -> compte_rendu.pseudo_api_base`

En mode rendu seul :

- il est lu en priorité :
  1. depuis `--pseudo-job-id`
  2. sinon depuis `infos_projet.json -> compte_rendu.pseudo_job_id`

## Emplacement du DOCX final

### Dossier de sortie

Le dossier final canonique est :

```text
\\...\Affaires\<id_affaire>\BE_Traitement_captations\<id_captation>\compte_rendu_LLM\
```

avec :

- `id_affaire = infos["id_affaire"]`
- `id_captation = infos["id_captation"]`
- `root_affaires = infos["pcfixe"]["root_affaires"]` si c'est une UNC
- sinon fallback vers `\\192.168.0.155\Affaires`

### Nom du fichier

Le nom écrit par le script est :

```text
compte_rendu_<id_affaire>_<id_captation>_V_<YYYYMMDD_HHMMSS>.docx
```

Le nom éventuellement proposé par le renderer n'est pas conservé : le script réécrit le binaire reçu sous son propre nom canonique.

## Exemples

### Mode standard

```powershell
python D:\GPT4All_Local\scripts\compte-rendu\render_compte_rendu_from_infos.py `
  --infos "\\192.168.0.155\Affaires\2025-J38\AF_Expert_ASR\transcriptions\accedit-2025-07-03\infos_projet.json"
```

### Mode standard avec rendu local

```powershell
python D:\GPT4All_Local\scripts\compte-rendu\render_compte_rendu_from_infos.py `
  --infos "\\192.168.0.155\Affaires\2025-J38\AF_Expert_ASR\transcriptions\accedit-2025-07-03\infos_projet.json" `
  --render-url "http://127.0.0.1:8081/render?format=docx"
```

### Mode rendu seul sans relancer le pipeline

Commande NAS recommandee :

```bash
cd /volume1/home/nicolas/Docker/compte-rendu/Scripts

./render_docx_only_from_infos.sh \
  "/volume1/Affaires/2025-J46/AF_Expert_ASR/transcriptions/accedit-2025-11-06/infos_projet.json"
```

Cette commande :

- ne lance pas `cr_reunion_point_mumerotes_pipeline_json.ps1`
- ne lance pas `docker exec cr-pipeline`
- ne regenere aucun JSON
- accepte les chemins hote NAS `/volume1/Affaires/...` et conteneur `/data/Affaires/...`
- relit `global_final.json` dans le dossier canonique `BE_Traitement_captations/<id_captation>/compte_rendu_LLM/`
- si absent, relit le plus recent `BE_Traitement_captations/<id_captation>/compte_rendu_LLM/out/*/global_final.json`
- relit d'abord `compte_rendu_LLM/pseudo_context.json` pour les metadata de pseudonymisation
- sinon relit le plus recent `logs/pseudo_context_*.json`
- relit `compte_rendu.pseudo_job_id` et `compte_rendu.pseudo_api_base` depuis `infos_projet.json`
- si `compte_rendu.pseudo_job_id` est absent, relit le plus recent `logs/run_metadata_*.json`
- si les metadata ne contiennent pas `pseudo_job_id`, cherche un `PseudoJobId` dans le plus recent `logs/run_*.log`
- charge automatiquement le `.env` du dossier parent de `Scripts`
- relit `LOCAL_LLM_API_KEY` depuis l'environnement ou ce `.env`

En mode `--docx-only`, la base de pseudonymisation est resolue dans cet ordre :

1. `CR_PSEUDO_API_BASE`
2. `PSEUDO_API_BASE`
3. `compte_rendu_LLM/pseudo_context.json`
4. le plus recent `logs/pseudo_context_*.json`
5. le plus recent `logs/run_metadata_*.json`
6. `infos_projet.json -> compte_rendu.pseudo_api_base`

Le `pseudo_job_id` est resolu dans cet ordre :

1. `--pseudo-job-id`
2. `compte_rendu_LLM/pseudo_context.json`
3. le plus recent `logs/pseudo_context_*.json`
4. le plus recent `logs/run_metadata_*.json`
5. `infos_projet.json -> compte_rendu.pseudo_job_id`

La cle API n'est jamais affichee dans les logs.

Au demarrage, le script affiche les chemins effectifs utilises :

- chemin `infos_projet.json` recu et normalise ;
- dossier `compte_rendu_LLM` ;
- dossier `logs` ;
- `global_final.json` ;
- `PseudoApiBase` retenue.
- le `pseudo_context` inspecte ou retenu ;
- les `run_metadata_*.json` et `run_*.log` inspectes pour retrouver `pseudo_job_id`.

La recherche du JSON final suit cet ordre :

1. `--global-final` explicite ;
2. `compte_rendu_LLM/global_final.json` ;
3. le plus recent `compte_rendu_LLM/out/*/global_final.json`.

Les metadata/logs de pseudonymisation sont cherches dans `compte_rendu_LLM/logs/` et, si le JSON final vient d'un run, dans `compte_rendu_LLM/out/<job_id>/logs/`.

Le pipeline complet ecrit aussi un fichier de contexte pseudo independant de `infos_projet.json` :

```text
compte_rendu_LLM/pseudo_context.json
compte_rendu_LLM/logs/pseudo_context_<YYYYMMDD_HHMMSS>.json
```

Ces fichiers ne contiennent pas la cle API. Ils evitent de dependre uniquement de `infos_projet.json`, qui peut etre resynchronise ou regenere par les flux NAS/PC fixe.

### Restauration si `infos_projet.json` a ete corrompu

Si `infos_projet.json` contient une sortie de script au lieu du JSON attendu, par exemple une ligne commencant par `Usage:`, ne pas relancer le pipeline.

Procedure :

1. recopier un `infos_projet.json` sain depuis la source PC fixe ou depuis une sauvegarde NAS ;
2. verifier que le fichier restaure contient bien du JSON ;
3. relancer uniquement le wrapper corrige :

```bash
cd /volume1/home/nicolas/Docker/compte-rendu/Scripts

./render_docx_only_from_infos.sh \
  "/volume1/Affaires/2025-J46/AF_Expert_ASR/transcriptions/accedit-2025-11-06/infos_projet.json"
```

Le wrapper refuse maintenant de continuer si le fichier passe en premier argument n'est pas un JSON valide ou s'il commence par `Usage:`.

Si le JSON final n'est pas dans l'emplacement canonique :

```bash
./render_docx_only_from_infos.sh \
  "/volume1/Affaires/2025-J46/AF_Expert_ASR/transcriptions/accedit-2025-11-06/infos_projet.json" \
  --global-final "/volume1/Affaires/2025-J46/BE_Traitement_captations/accedit-2025-11-06/compte_rendu_LLM/global_final.json"
```

Equivalent Python :

```bash
python3 ./render_compte_rendu_from_infos.py \
  --infos "/volume1/Affaires/2025-J46/AF_Expert_ASR/transcriptions/accedit-2025-11-06/infos_projet.json" \
  --docx-only
```

```powershell
python "\\192.168.0.155\GPT4All_Local\scripts\compte-rendu\render_compte_rendu_from_infos.py" `
  --infos "\\192.168.0.155\Affaires\2025-J46\AF_Expert_ASR\transcriptions\accedit-2025-11-06\infos_projet.json" `
  --global-final "\\192.168.0.155\Affaires\2025-J46\BE_Traitement_captations\accedit-2025-11-06\compte_rendu_LLM\global_final.json" `
  --pseudo-job-id "job_test_pseudo_2025J46" `
  --pseudo-api-base "http://192.168.0.155:5050"
```

Ce mode permet de tester uniquement :

1. la lecture de `global_final.json`
2. la dé-pseudonymisation finale
3. l'appel au renderer DOCX
4. l'écriture du `.docx`

sans relancer tout le pipeline JSON.

## Limites actuelles

Le script suppose que :

- `infos_projet.json` est valide
- les fichiers requis sont déjà accessibles
- `global_final.json` existe si on utilise `--global-final`
- le service de dé-pseudonymisation est joignable si la dé-pseudonymisation distante est active
- le renderer DOCX est joignable

Le script ne gère pas lui-même :

- l'orchestration NAS complète
- la supervision globale Docker / NAS
- la production métier amont des artefacts du pipeline en dehors de son propre appel standard

En particulier, il ne remplace pas l'orchestrateur principal amont ; il sert surtout à la fin de chaîne de rendu final.
