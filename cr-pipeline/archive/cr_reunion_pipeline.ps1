<# 
cr_reunion_pipeline.ps1
Orchestre la production d’un compte rendu standardisé à partir d’une transcription CSV longue (4–5h).

Entrée attendue (CSV) : colonnes speaker, temps (HH:MM:SS), texte
Sorties : 
  - ./out/segments/*.json       (mini-CR par segment)
  - ./out/global.json           (agrégation)
  - ./out/compte_rendu.md       (rendu final Markdown)
  - ./out/logs/*.log            (journaux)
Dépendances : PowerShell 7+, accès HTTP vers votre serveur IA.
Optionnel : pandoc installé pour exporter en DOCX/PDF.

Usage :
  pwsh ./cr_reunion_pipeline.ps1 -CsvPath "C:\data\reunion.csv" -OutDir ".\out" `
       -SegmentMinutes 25 -Provider "openai" -ApiBase "http://localhost:11434/v1" `
       -Model "qwen2.5:14b-instruct-q4" -ApiKey "sk-xxx" -Force:$false

Variantes Provider :
  -Provider "openai"  -> POST {ApiBase}/v1/chat/completions  (LM Studio, vLLM, Ollama OpenAI compat)
  -Provider "ollama"  -> POST {OllamaBase}/api/generate      (Ollama natif)

#>

param(
  [Parameter(Mandatory=$true)] [string] $CsvPath,
  [Parameter(Mandatory=$false)] [string] $OutDir = ".\out",
  [Parameter(Mandatory=$false)] [int]    $SegmentMinutes = 25,
  [Parameter(Mandatory=$false)] [string] $Provider = "openai", # "openai" | "ollama"
  [Parameter(Mandatory=$false)] [string] $ApiBase = "http://localhost:11434", # ex: LM Studio/vLLM/Ollama (OpenAI compat: ajoute /v1 plus bas)
  [Parameter(Mandatory=$false)] [string] $OllamaBase = "http://localhost:11434", # API native Ollama
  [Parameter(Mandatory=$false)] [string] $Model = "mistral:7b-instruct-q4",
  [Parameter(Mandatory=$false)] [string] $ApiKey = "",     # pour OpenAI-compat si requis
  [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ───────────────────────────────────────────────────────────────────────────────
# Utils
# ───────────────────────────────────────────────────────────────────────────────

function Write-Info($msg)  { Write-Host "[INFO]  $msg" -ForegroundColor Cyan }
function Write-Warn($msg)  { Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function Write-Err ($msg)  { Write-Host "[ERROR] $msg" -ForegroundColor Red }

function Ensure-Dir($path) { if (!(Test-Path $path)) { New-Item -ItemType Directory -Path $path | Out-Null } }

function Hms-To-Seconds([string]$hms) {
  if (-not $hms) { return 0 }
  $parts = $hms.Split(":")
  if ($parts.Count -lt 2) { return 0 }
  if ($parts.Count -eq 2) { $parts = @("0") + $parts }
  [int]$parts[0]*3600 + [int]$parts[1]*60 + [int][double]$parts[2]
}

function Seconds-To-Hms([int]$sec) {
  $h = [int]($sec / 3600)
  $m = [int](($sec % 3600) / 60)
  $s = [int]($sec % 60)
  "{0:D2}:{1:D2}:{2:D2}" -f $h,$m,$s
}

# ───────────────────────────────────────────────────────────────────────────────
# Prompts (passes)
# ───────────────────────────────────────────────────────────────────────────────

$Pass1_System = @'
Tu es un assistant d'analyse de réunions. À partir d'une transcription de 20–30 minutes, produis une synthèse factuelle structurée, sans invention.
Format de sortie JSON STRICT (pas de texte hors JSON) :
{
  "resume_segment": "5 phrases maximum",
  "themes": [
    {"titre": "string", "synthese": ["point 1","point 2"], "timecodes": ["HH:MM:SS","..."]}
  ],
  "actions": [
    {"action": "string", "responsable": "string", "echeance": "YYYY-MM-DD | null"}
  ],
  "problems": [
    {"probleme": "string", "solution": "string"}
  ]
}
Contraintes : reformuler clairement ; s'appuyer sur les timecodes fournis ; regrouper par thème ; pas plus de 1000 mots.
'@

$Pass1_User_Template = @'
Transcription segmentée (de {START_HMS} à {END_HMS}) :

{LINES}

Exige uniquement le JSON au format défini.
'@

$Pass2_System = @'
Tu es un assistant de synthèse. Tu reçois plusieurs mini-comptes-rendus JSON d'une même réunion.
Fusionne-les en un seul JSON cohérent, sans doublons, en regroupant les thèmes similaires.

Format de sortie JSON STRICT :
{
  "resume_global": "6 à 8 phrases",
  "themes": [
    {"titre":"string","synthese":["..."],"timecodes":["HH:MM:SS","HH:MM:SS"]}
  ],
  "actions": [
    {"action":"string","responsable":"string","echeance":"YYYY-MM-DD | null"}
  ],
  "problems": [
    {"probleme":"string","solution":"string"}
  ]
}

Règles : regrouper thèmes par sens, dédupliquer, conserver timecodes représentatifs (début/fin de discussion), privilégier la date la plus précise.
'@

$Pass2_User_Template = @'
Voici la liste des mini-CR JSON à fusionner (un tableau JSON) :

{SEGMENTS_JSON_ARRAY}

Exige uniquement le JSON au format défini.
'@

$Pass3_System = @'
Tu es un assistant de rédaction. À partir du JSON global ci-dessous, produis un compte rendu en Markdown avec structure fixe :
1) Date
2) Link
3) Résumé (5–6 phrases)
4) Ordre du jour (3–8 items)
5) Thèmes abordés (paragraphes de 5–10 lignes max, avec faits/décisions)
6) Actions (tableau : Action | Responsable | Échéance | Commentaire [facultatif])
7) Perspectives (Problème → Solution)

Contraintes : ton professionnel, concis, neutre ; aucune invention ; titres fixes. Pas de code block Markdown englobant.
'@

$Pass3_User_Template = @'
JSON global à rendre au format Markdown standardisé :
{GLOBAL_JSON}

Métadonnées suggérées :
- Date : {DATE_SUGGEST}
- Link : {LINK_SUGGEST}
'@

# ───────────────────────────────────────────────────────────────────────────────
# Modèle : appels API
# ───────────────────────────────────────────────────────────────────────────────

function Invoke-LLM-OpenAICompat([string]$system, [string]$user) {
  $uri = ($ApiBase.TrimEnd('/')) + "/v1/chat/completions"
  $headers = @{}
  if ($ApiKey) { $headers["Authorization"] = "Bearer $ApiKey" }
  $body = @{
    model = $Model
    temperature = 0.2
    messages = @(
      @{ role = "system"; content = $system },
      @{ role = "user";   content = $user }
    )
  } | ConvertTo-Json -Depth 10
  $resp = Invoke-RestMethod -Method POST -Uri $uri -Headers $headers -Body $body -ContentType "application/json"
  return $resp.choices[0].message.content
}

function Invoke-LLM-OllamaNative([string]$system, [string]$user) {
  # Ollama /api/generate accepte un prompt unique. On concatène system + user proprement.
  $uri = ($OllamaBase.TrimEnd('/')) + "/api/generate"
  $prompt = "SYSTEM:\n$system\n\nUSER:\n$user"
  $body = @{
    model = $Model
    prompt = $prompt
    stream = $false
    options = @{ temperature = 0.2 }
  } | ConvertTo-Json -Depth 10
  $resp = Invoke-RestMethod -Method POST -Uri $uri -Body $body -ContentType "application/json"
  return $resp.response
}

function Invoke-LLM([string]$system, [string]$user) {
  if ($Provider -ieq "openai") { return Invoke-LLM-OpenAICompat $system $user }
  elseif ($Provider -ieq "ollama") { return Invoke-LLM-OllamaNative $system $user }
  else { throw "Provider inconnu: $Provider" }
}

# ───────────────────────────────────────────────────────────────────────────────
# Lecture CSV et segmentation
# ───────────────────────────────────────────────────────────────────────────────

if (!(Test-Path $CsvPath)) { throw "CSV introuvable: $CsvPath" }

Ensure-Dir $OutDir
Ensure-Dir (Join-Path $OutDir "segments")
Ensure-Dir (Join-Path $OutDir "logs")

$logFile = Join-Path $OutDir ("logs\run_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")
"Start: $(Get-Date)" | Out-File $logFile -Encoding UTF8

Write-Info "Lecture CSV: $CsvPath"
$rows = Import-Csv -Path $CsvPath

# normaliser noms de colonnes possibles
# On suppose : speaker | temps | texte
$colSpeaker = ($rows[0].psobject.Properties.Name | Where-Object { $_ -match 'speaker' })[0]
$colTime    = ($rows[0].psobject.Properties.Name | Where-Object { $_ -match 'temps'   -or $_ -match 'time' })[0]
$colText    = ($rows[0].psobject.Properties.Name | Where-Object { $_ -match 'texte'   -or $_ -match 'text' })[0]

if (-not $colSpeaker -or -not $colTime -or -not $colText) {
  throw "Colonnes attendues non trouvées. Requis ~ 'speaker' / 'temps' / 'texte'."
}

# Trier par temps
$rows = $rows | ForEach-Object {
  $_ | Add-Member -NotePropertyName __sec -NotePropertyValue (Hms-To-Seconds $_.$colTime) -Force
  $_
} | Sort-Object __sec

if ($rows.Count -eq 0) { throw "CSV vide." }

$startSec = $rows[0].__sec
$endSec   = $rows[-1].__sec
$window   = $SegmentMinutes * 60

Write-Info "Fenêtrage par ${SegmentMinutes} min (≈ $window s)."

$segments = @()
$current = @()
$segStart = $startSec
$segEnd = $segStart + $window

foreach ($r in $rows) {
  if ($r.__sec -le $segEnd) {
    $current += $r
  } else {
    if ($current.Count -gt 0) {
      $segments += ,@($current)
    }
    $current = @($r)
    $segStart = $r.__sec
    $segEnd = $segStart + $window
  }
}
if ($current.Count -gt 0) { $segments += ,@($current) }

Write-Info ("Nombre de segments : " + $segments.Count)

# ───────────────────────────────────────────────────────────────────────────────
# Passe 1 : mini-CR par segment
# ───────────────────────────────────────────────────────────────────────────────

$segmentJsonPaths = @()

for ($i = 0; $i -lt $segments.Count; $i++) {
  $seg = $segments[$i]
  $segOut = Join-Path $OutDir ("segments\segment_{0:D2}.json" -f ($i+1))
  $startH = Seconds-To-Hms ($seg[0].__sec)
  $endH   = Seconds-To-Hms ($seg[-1].__sec)

  if ((Test-Path $segOut) -and (-not $Force)) {
    Write-Info "Skip segment {0:D2} (existe) → $segOut" -f ($i+1)
    $segmentJsonPaths += $segOut
    continue
  }

  Write-Info ("Passe 1 → Segment {0:D2}  [{1} → {2}]" -f ($i+1, $startH, $endH))

  # Construire le bloc texte "[HH:MM:SS] Speaker: texte"
  $lines = $seg | ForEach-Object {
    $t = $_.$colTime
    $s = $_.$colSpeaker
    $x = $_.$colText
    "[{0}] {1}: {2}" -f $t, $s, $x
  } | Out-String

  $userPrompt = $Pass1_User_Template.Replace("{START_HMS}", $startH).
                                     Replace("{END_HMS}",   $endH).
                                     Replace("{LINES}",     $lines.Trim())

  $raw = Invoke-LLM -system $Pass1_System -user $userPrompt

  # Nettoyage et validation JSON
  $jsonStr = $raw.Trim()
  try {
    $obj = $jsonStr | ConvertFrom-Json -Depth 50
  } catch {
    # Essai de récupération : extraire JSON entre la première { et la dernière }
    $start = $jsonStr.IndexOf("{")
    $end   = $jsonStr.LastIndexOf("}")
    if ($start -ge 0 -and $end -gt $start) {
      $jsonStr = $jsonStr.Substring($start, $end - $start + 1)
      $obj = $jsonStr | ConvertFrom-Json -Depth 50
    } else {
      Write-Err "Échec parsing JSON segment {0:D2}. Contenu brut loggé." -f ($i+1)
      $raw | Out-File ($segOut + ".raw.txt") -Encoding UTF8
      throw
    }
  }

  $jsonStr | Out-File $segOut -Encoding UTF8
  $segmentJsonPaths += $segOut
  "Segment {0:D2} OK" -f ($i+1) | Add-Content $logFile
}

# ───────────────────────────────────────────────────────────────────────────────
# Passe 2 : agrégation des mini-CR
# ───────────────────────────────────────────────────────────────────────────────

Write-Info "Passe 2 → Agrégation"
$segmentsObjs = @()
foreach ($p in $segmentJsonPaths) {
  try {
    $segmentsObjs += (Get-Content $p -Raw | ConvertFrom-Json -Depth 50)
  } catch {
    Write-Warn "JSON invalide ignoré : $p"
  }
}
$segmentsJsonArray = ($segmentsObjs | ConvertTo-Json -Depth 50)

$pass2User = $Pass2_User_Template.Replace("{SEGMENTS_JSON_ARRAY}", $segmentsJsonArray)
$pass2Raw  = Invoke-LLM -system $Pass2_System -user $pass2User

# Validation JSON
$globalObj = $null
$globalJson = $pass2Raw.Trim()
try {
  $globalObj = $globalJson | ConvertFrom-Json -Depth 50
} catch {
  $start = $globalJson.IndexOf("{")
  $end   = $globalJson.LastIndexOf("}")
  if ($start -ge 0 -and $end -gt $start) {
    $globalJson = $globalJson.Substring($start, $end - $start + 1)
    $globalObj = $globalJson | ConvertFrom-Json -Depth 50
  } else {
    Write-Err "Échec parsing JSON global. Contenu brut loggé."
    $pass2Raw | Out-File (Join-Path $OutDir "global_raw.txt") -Encoding UTF8
    throw
  }
}

$globalPath = Join-Path $OutDir "global.json"
$globalJson | Out-File $globalPath -Encoding UTF8
Write-Info "Agrégation OK → $globalPath"

# ───────────────────────────────────────────────────────────────────────────────
# Passe 3 : rendu final Markdown
# ───────────────────────────────────────────────────────────────────────────────

Write-Info "Passe 3 → Rendu final Markdown"
# Tu peux injecter ici une date/lien si tu les connais ; sinon laisse vide.
$dateSuggest = (Get-Date -Format "yyyy-MM-dd")
$linkSuggest = "—"

$pass3User = $Pass3_User_Template.Replace("{GLOBAL_JSON}",  (Get-Content $globalPath -Raw)).
                                  Replace("{DATE_SUGGEST}", $dateSuggest).
                                  Replace("{LINK_SUGGEST}", $linkSuggest)

$mdRaw = Invoke-LLM -system $Pass3_System -user $pass3User
$mdClean = $mdRaw.Trim()

$mdPath = Join-Path $OutDir "compte_rendu.md"
$mdClean | Out-File $mdPath -Encoding UTF8
Write-Info "Compte rendu → $mdPath"

# ───────────────────────────────────────────────────────────────────────────────
# Optionnel : export DOCX via pandoc si disponible
# ───────────────────────────────────────────────────────────────────────────────

try {
  $pandoc = Get-Command pandoc -ErrorAction Stop
  $docxPath = Join-Path $OutDir "compte_rendu.docx"
  & $pandoc.Source $mdPath -o $docxPath
  Write-Info "DOCX créé (pandoc) → $docxPath"
} catch {
  Write-Warn "Pandoc non détecté : export DOCX sauté."
}

"Done: $(Get-Date)" | Add-Content $logFile
Write-Info "Pipeline terminé."
