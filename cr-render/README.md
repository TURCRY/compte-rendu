Voici un **README.md clair, complet et propre** pour
`\\192.168.1.20\Home\Docker\compte-rendu\cr-render`.

À copier directement dans :
`cr-render/README.md`

---

# 📝 **README — Service `cr-render`**

## 📌 Présentation

`cr-render` est un service Docker chargé de **produire un document Markdown ou DOCX** à partir du JSON final généré par le service `cr-pipeline`.

Le JSON attendu correspond exactement à la structure produite par la *Pass 3* du pipeline, appelée :

```
global_final.json
```

`cr-render` propose une API HTTP simple :

* `POST /render?format=md` → génère un fichier **Markdown**
* `POST /render?format=docx` → génère un **fichier Word DOCX**

Ce service ne réalise aucun appel LLM : il ne fait que formater des données structurées.

---

## 📁 Arborescence

```
cr-render/
│
├── Dockerfile
├── requirements.txt
├── README.md
│
└── app/
    ├── __init__.py
    ├── app.py              ← API Flask
    └── renderer.py         ← Génération Markdown + DOCX
```

---

## ⚙️ Fonctionnement

### 1) **Entrée attendue**

Le JSON doit respecter le schéma strict :

```json
{
  "date": "YYYY-MM-DD | null",
  "link": "string | null",
  "resume": "string",
  "ordre_du_jour": ["string"],
  "themes_abordes": [
    {
      "titre": "string",
      "synthese": ["string"],
      "indices_source": [
        {
          "timecode": "HH:MM:SS",
          "speaker": "string",
          "extrait": "string"
        }
      ]
    }
  ],
  "actions": [
    {
      "action": "string",
      "responsable": "string",
      "echeance": "YYYY-MM-DD | null",
      "commentaire": "string | null"
    }
  ],
  "perspectives": [
    {
      "probleme": "string",
      "solution": "string"
    }
  ],
  "annexes": ["string"]
}
```

🔎 La fonction `validate_payload()` dans `renderer.py` s’assure que toutes les clés obligatoires sont présentes.

---

## 🖨️ Formats gérés

### **Markdown**

Produit un fichier léger, directement lisible, compatible Git.

Section par section :

* résumé
* ordre du jour
* thèmes abordés
* actions (tableau Markdown)
* perspectives
* annexes

### **DOCX**

Produit un document Word prêt à diffuser :

* titres
* listes à puces
* tableaux
* sous-sections
* mise en forme propre
* styles uniformes

Le DOCX généré peut être ouvert par Word, LibreOffice, OnlyOffice, WPS…

---

## 🌐 API du service

### **Healthcheck**

```
GET /ping
```

Réponse :

```json
{"status": "ok"}
```

---

### **Générer un rendu**

```
POST /render?format=md
POST /render?format=docx
```

#### Headers

```
Content-Type: application/json
```

#### Body

JSON strict conforme au schéma ci-dessus.

---

### 📄 **Exemple curl (Markdown)**

```
curl -X POST "http://NAS:8081/render?format=md" \
     -H "Content-Type: application/json" \
     --data-binary @global_final.json \
     -o compte_rendu.md
```

### 📄 **Exemple curl (DOCX)**

```
curl -X POST "http://NAS:8081/render?format=docx" \
     -H "Content-Type: application/json" \
     --data-binary @global_final.json \
     -o compte_rendu.docx
```

---

## 🐳 Docker

### Construction :

```
docker compose build cr-render
```

### Lancement :

```
docker compose up -d cr-render
```

### Logs :

```
docker logs -f cr-render
```

---

## 🧩 Intégration avec `cr-pipeline`

En général, tu fais :

1. `cr-pipeline` produit :

   ```
   /data/jobs/job_xxxxx/out/global_final.json
   ```

2. `cr-render` transforme ce JSON en DOCX ou Markdown :

   ```
   curl -X POST http://cr-render:8080/render?format=docx \
        -H "Content-Type: application/json" \
        --data-binary @global_final.json \
        -o compte_rendu.docx
   ```

Tu peux aussi automatiser cette étape directement dans `pipeline_server.py` si tu veux, pour que chaque job produise automatiquement son DOCX final.

---

## 🔒 Sécurité

* Aucune donnée n’est envoyée à l’extérieur.
* Aucun appel à un service distant : **100% local**.
* Le service ne fait que du traitement de texte.

---

## 🎯 Résumé

`cr-render` est un microservice très simple :

* reçoit un JSON final normalisé
* valide la structure
* génère un document DOCX ou Markdown
* fonctionne entièrement en local
* intégré au docker-compose global

Il permet de séparer clairement :

* **le pipeline intelligent (LLM + segmentation)**
* **la production documentaire finale**

