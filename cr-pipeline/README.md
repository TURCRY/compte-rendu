Voici un **README.md clair, structuré et opérationnel** pour ton dossier
`\\192.168.1.20\Home\Docker\compte-rendu\cr-pipeline`.

Il décrit :

* le rôle du service
* l’architecture des dossiers
* le fonctionnement du pipeline
* l’API exposée
* comment lancer / déboguer
* comment intégrer avec `cr-render`

Tu peux copier-coller tel quel dans `cr-pipeline/README.md`.

---

# 📝 **README — Service `cr-pipeline`**

## 📌 **Présentation**

`cr-pipeline` est un service Docker qui exécute un pipeline complet de génération de **compte rendu de réunion** à partir d’un fichier CSV issu d’une transcription.

Le pipeline fonctionne selon trois étapes successives :

1. **Segmentation intelligente** de la transcription en blocs cohérents.
2. **Synthèse LLM par segment** (Pass 1).
3. **Agrégation par LLM** en un seul résumé global (Pass 2).
4. **Normalisation en JSON final structuré** conforme au modèle attendu (Pass 3).

Le résultat final est toujours :

```
<data/jobs>/<job_id>/out/global_final.json
```

Ce JSON est ensuite consommé par le service `cr-render` pour produire
un **Markdown** ou un **DOCX**.

---

## 📁 **Arborescence**

```
cr-pipeline/
│
├── Dockerfile
├── requirements.txt
├── README.md
│
├── app/
│   ├── __init__.py
│   ├── app.py                ← API Flask
│   └── pipeline_server.py    ← Gestion des jobs, appel PowerShell
│
├── pipeline/
│   ├── powershell/
│   │   ├── cr_reunion_pipeline_fulljson.ps1    ← pipeline principal
│   │   ├── cr_reunion_pipeline_smart_low.ps1   ← variante (optionnelle)
│   │   └── cr_reunion_pipeline.ps1             ← ancienne version (archivage)
│   │
│   └── prompts/ (optionnel)
│
└── data/
    └── jobs/                 ← volume monté pour les exécutions
        ├── job_2025xxxx_XXXXXX/
        │   ├── input.csv
        │   ├── out/
        │   │   ├── segments/
        │   │   ├── global.json
        │   │   ├── global_final.json   ← résultat principal
        │   │   └── logs/
        │   └── metadata.json
        └── ...
```

---

## ⚙️ **Pipeline détaillé**

### ● Entrée

Un fichier CSV avec les colonnes :

```
start;end;speaker;text
```

* `start` et `end` en **secondes décimales**
* `speaker` = identifiant du locuteur
* `text` = transcription brute

### ● Étapes

1. **Segmentation**
   Algorithme maison basé sur :

   * distance lexicale
   * ruptures de speakers
   * mots-clés métiers
   * ancres conversationnelles
   * durée minimale/maximale

   Les segments sont sauvegardés dans :

   ```
   out/segments/segment_XX.json
   ```

2. **Pass 1 : Synthèse par segment**
   Chaque segment est envoyé au LLM (local via openai-adapter).
   Sortie : JSON strict par segment.

3. **Pass 2 : Fusion et dédoublonnage**
   Le LLM fusionne les mini-résumés en un JSON global :

   ```
   out/global.json
   ```

4. **Pass 3 : Format final normalisé**
   Le LLM produit le JSON final structuré :

   ```
   out/global_final.json
   ```

---

## 🌐 **API exposée par `cr-pipeline`**

### **1) Healthcheck**

```
GET /ping
```

Réponse :

```json
{"status": "ok"}
```

---

### **2) Lancer un pipeline**

```
POST /run
```

#### Body attendu :

```json
{
  "job_id": "string (optionnel)",
  "filename": "nom-fichier.csv",
  "content": "contenu CSV brut base64"
}
```

ou
`multipart/form-data` avec un fichier CSV.

#### Réponse :

```json
{
  "job_id": "job_2025xxxx_xxxxxx",
  "status": "started"
}
```

Le pipeline s’exécute ensuite de manière synchrone ou asynchrone selon `pipeline_server.py`.

---

### **3) Récupérer le résultat**

```
GET /result/<job_id>
```

Retourne :

```json
{
  "status": "ok",
  "data": { JSON global_final.json }
}
```

ou un message d’erreur si le job n’est pas terminé.

---

## 🔌 **Connexion au LLM via openai-adapter**

Le pipeline utilise :

```
PIPELINE_PROVIDER = "openai"
PIPELINE_API_BASE = "http://openai-adapter:5055"
PIPELINE_API_KEY  = "${ADAPTER_API_KEY}"
PIPELINE_MODEL    = "annoter"
```

Donc :

* le LLM **appelé est local**, sur ton PC fixe
* l’adapter traduit `annoter` → `Mistral_7B`
* pas de modèle Ollama dans cette configuration
* aucune donnée sensible n’est envoyée en remote

---

## 🐳 **Utilisation (Docker)**

### Construction :

```
docker compose build cr-pipeline
```

### Lancement :

```
docker compose up -d cr-pipeline
```

### Logs :

```
docker logs -f cr-pipeline
```

---

## 🛠️ **Débogage / Test manuel**

Depuis le NAS :

```
curl -X POST http://localhost:8090/run \
     -H "Content-Type: application/json" \
     --data-binary @test.json
```

Vérifier un job :

```
curl http://localhost:8090/result/job_2025xxxx_xxxxxx
```

---

## 🔁 **Chaînage avec `cr-render`**

Une fois `global_final.json` généré, `cr-render` peut produire un document :

```
curl -X POST "http://cr-render:8080/render?format=docx" \
     -H "Content-Type: application/json" \
     --data-binary @global_final.json \
     --output compte_rendu.docx
```

---

## 🎯 **Résumé**

`cr-pipeline` :

* Segmente intelligemment les transcriptions
* Synthétise chaque segment via LLM local
* Fusionne et normalise tous les résultats
* Produit un JSON final 100% structuré
* Expose une API REST simple
* Fonctionne entièrement localement (RGPD 👍)


