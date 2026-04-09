Voici un **README global, clair, structuré et professionnel**, couvrant l’ensemble de ton infrastructure *compte-rendu* :

* `cr-pipeline`
* `cr-render`
* `openai-adapter`
* `openwebui`
* réseau commun
* workflow complet

À déposer dans :
`\\192.168.1.20\Home\Docker\compte-rendu\README.md`

---

# 🧭 **README — Infrastructure “Compte Rendu Automatique”**

## 📌 Objectif du projet

Ce projet met en place une infrastructure complète permettant de :

1. **Transcrire une réunion** (effectué en amont dans ton serveur Flask)
2. **Segmenter intelligemment une transcription longue**
3. **Produire automatiquement un compte rendu structuré et juridiquement exploitable**
4. **Générer un rendu DOCX ou Markdown**
5. **Utiliser exclusivement des ressources locales ou internes (NAS + PC fixe + OpenWebUI)**

L’architecture repose sur deux microservices :
✔️ `cr-pipeline`
✔️ `cr-render`

Ils sont orchestrés via un fichier `docker-compose` commun et utilisent le réseau Docker `data-net`.

---

# 🏗️ **Architecture Générale**

```
                   +---------------------------+
                   |     Serveur Flask LLM     |
                   |   (PC Fixe / LAN / VPN)   |
                   |  transcription, OCR, LLM  |
                   +-------------+-------------+
                                 ↑
                                 |
                        via openai-adapter
                                 |
     ┌─────────────────────────────────────────────────────────┐
     │                         NAS                             │
     │                                                         │
     │  +-------------------------+   +-----------------------+ │
     │  |      cr-pipeline       |   |       cr-render       | │
     │  |  Segmentation + LLM    |   |   DOCX / MD builder   | │
     │  +-------------------------+   +-----------------------+ │
     │                ↑                       ↑                 │
     │                |                       |                 │
     │         JSON final                    Fichiers DOCX/MD   │
     │                |                       |                 │
     │         (out/global_final.json)        |                 │
     │                                                         │
     │  +-------------------------+                             │
     │  |     openai-adapter     |                             │
     │  |  Proxy OpenAI → Flask  |                             │
     │  +-------------------------+                             │
     │                                                         │
     │  +-------------------------+                             │
     │  |       openwebui         |                            │
     │  |  Interface Web LLM     |                             │
     │  +-------------------------+                             │
     │                                                         │
     └─────────────────────────────────────────────────────────┘
```

---

# 📁 **Arborescence du projet**

```
compte-rendu/
│
├── docker-compose.yml        → orchestre cr-pipeline + cr-render
│
├── cr-pipeline/
│   ├── Dockerfile
│   ├── pipeline/
│   │   └── powershell/
│   │       └── cr_reunion_pipeline_fulljson.ps1
│   ├── app/
│   │   ├── pipeline_server.py
│   │   ├── job_manager.py
│   │   └── ...
│   ├── data/
│   │   └── jobs/     → Jobs créés au runtime
│   └── README.md
│
└── cr-render/
    ├── Dockerfile
    ├── requirements.txt
    ├── app/
    │   ├── app.py           → API Flask
    │   └── renderer.py      → Génération DOCX / MD
    └── README.md
```

---

# ⚙️ **Services du docker-compose**

## 1️⃣ **Service `cr-pipeline`**

Produit automatiquement :

* segmentation intelligente en plusieurs mini-CR
* passes 1/2/3 du pipeline LLM
* JSON global final normalisé :

```
/data/jobs/<job_id>/out/global_final.json
```

Accessible via :

```
http://NAS:8090
```

### Usage typique depuis ton serveur Flask :

```
POST /pipeline/start_job
```

avec :

* fichier `.csv` provenant de l’ASR
* métadonnées (nom dossier, référence, date, etc.)

---

## 2️⃣ **Service `cr-render`**

Génère un **DOCX** ou un **Markdown** à partir du JSON final.

API :

```
POST /render?format=md
POST /render?format=docx
```

Exemple :

```
curl -X POST http://NAS:8081/render?format=docx \
     -H "Content-Type: application/json" \
     --data-binary @global_final.json \
     -o compte_rendu.docx
```

---

## 3️⃣ **Service `openai-adapter`**

Passerelle universelle OpenAI-compatible.

Il permet :

* d’appeler ton serveur Flask (LLM local) **comme si c’était OpenAI**
* de faire du fallback vers OpenAI/OR si souhaité
* d’être vu comme un provider unique par OpenWebUI

Expose :

```
http://NAS:5055/v1/chat/completions
```

→ C’est ce que `cr-pipeline` utilise.

---

## 4️⃣ **OpenWebUI**

Interface web LLM pour :

* tester les modèles locaux
* faire du débogage des prompts Pass 1/2/3
* analyser un job manuellement si besoin

Accessible via :

```
http://NAS:3000
```

---

# 🔄 **Workflow complet**

## 1️⃣ Transcription (en dehors de ce projet)

Ton serveur Flask récupère le WAV/MP3, transcrit via Voxtral/Whisper et génère un CSV :

```
start ; end ; speaker ; text
```

## 2️⃣ Lancement du pipeline

Via API :

```
POST http://NAS:8090/start_job
```

ou en drop-in d’un fichier dans :

```
cr-pipeline/data/jobs/
```

Le pipeline :

* lit le CSV
* segmente la réunion
* produit mini-CR JSON segmentés
* fusionne (Pass 2)
* normalise (Pass 3)
* écrit :

```
…/out/global_final.json
```

## 3️⃣ Rendu du compte rendu

Exemple automatique dans ton Flask :

```
POST http://NAS:8081/render?format=docx
```

et tu obtiens :

```
compte_rendu.docx
```

---

# 🛡️ Sécurité & confidentialité

* Tous les traitements LLM sont locaux (PC fixe via `openai-adapter`).
* Les rendus sont produits sur le NAS.
* Aucun document, transcription ou compte rendu n’est envoyé à l’extérieur.
* Compatible RGPD / données sensibles / expertises judiciaires.

---

# 🔧 Commandes utiles

## Démarrer toute la stack :

```
docker compose up -d --build
```

## Arrêter :

```
docker compose down
```

## Logs :

```
docker logs -f cr-pipeline
docker logs -f cr-render
docker logs -f openai-adapter
```

---

# 📦 Dépendances principales

* Python 3.11
* Flask
* python-docx
* PowerShell Core (dans cr-pipeline)
* mini-serveur LLM Flask distant (ton PC fixe)
* OpenWebUI
* openai-adapter (FastAPI)

---

# ❤️ Conclusion

Cette infrastructure met en place une **chaîne automatisée, robuste et locale** permettant :

* de traiter plusieurs heures de réunion,
* de générer un compte rendu riche, structuré, exploitable en expertise,
* de maintenir la confidentialité des dossiers judiciaires,
* tout en restant flexible et extensible.

---

Si tu veux maintenant :
✔️ **une documentation API détaillée (swagger-like)**
✔️ **un schéma de séquence du pipeline complet**
✔️ **un "Guide utilisateur" pour expliquer à un stagiaire comment utiliser l’ensemble**

… je peux les rédiger.
