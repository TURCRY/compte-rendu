<#
cr_reunion_pipeline_fulljson.ps1
Pipeline complet : CSV → segmentation intelligente → Passes 1/2/3 (JSON strict à chaque étape)

Sorties :
  - ./out/segments/segment_XX.json
  - ./out/global.json
  - ./out/global_final.json

Aucune génération de Markdown ici (full JSON). Tu peux post-traiter global_final.json côté Flask/PS.

Usage (exemple) :
pwsh .\cr_reunion_pipeline_fulljson.ps1 -CsvPath ".\reunion.csv" -OutDir ".\out" `
  -Provider ollama -OllamaBase "http://localhost:11434" -Model "qwen2.5:14b-instruct" -Preset equilibre -DebugSeg
#>
param(
  [Parameter(Mandatory=$true)]  [string] $CsvPath,
  [Parameter(Mandatory=$false)] [string] $OutDir = ".\out",

  [string] $SujetsPath,
  [string] $ParticipantsPath,
  [string] $NomsPropresPath,
  [string] $CsvDebriefPath,
  [Parameter(Mandatory=$false)]
  [string] $ContextJsonPath = "",

  # LLM provider & modèle
  [ValidateSet("openai","ollama")] [string] $Provider = "openai",
  [string] $ApiBase = $(if ($env:PIPELINE_API_BASE) { $env:PIPELINE_API_BASE } else { "http://192.168.1.20:5055" }),
  # OpenAI-compat: /v1/chat/completions
  [string] $OllamaBase = "http://localhost:11434",      # Ollama natif: /api/generate

  # Modèle "par défaut" (optionnel, compat)
  [string] $Model      = "annoter_segments_local",

  # Modèles par passe
  [string] $ModelPass1 = "annoter_segments_local",   # Passe 1 : segments → LOCAL + Passe 2A
  [string] $ModelPass2 = "report_remote",  # Passe 2 : fusion → REMOTE
  [string] $ModelPass3 = "pass3_remote",  # # Passes 3, 3A/B/C/D, MergeGlobal
  # Modèle rédactionnel (2B / MergeGlobal UNIQUEMENT) 
  [string] $ModelReport = "report_remote",


  [string] $ApiKey     = "",

  # Segmentation : preset + debug
  [ValidateSet("conservateur","equilibre","agressif")] [string] $Preset = "equilibre",
  [switch] $DebugSeg,

  [switch] $DebugHttp,

  
  # Paramétrage Passe 2 (agrégation hiérarchique)
  [int] $Pass2BatchSize = 2,

  # Relance
  [switch] $Force

)
[int]$ChunkSize = 30 # voir fonction Get-IntelligentSegments (nombre de ligne de transcription par segment

# Valeurs neutres pour éviter l’erreur en StrictMode
$logsDir = $null
$logFile = $null

# Lecture des sujets numérotés (Excel)
# via ImportExcel module, ou CSV si tu convertis avant
# On attend par ex. colonnes : Numero, Titre

if ($SujetsPath) {
    $Sujets = Import-Excel -Path $SujetsPath

    # Normalisation + typage + fallback titre
    $Sujets = $Sujets | ForEach-Object {
        $num = [int]$_.Numero

     
        $titre = ([string]$_.Titre).Trim()
        if ([string]::IsNullOrWhiteSpace($titre)) {
            # fallback simple si Titre vide : "Localisation - Description courte"
            $loc = ($_.Localisation | ForEach-Object { $_ })  # évite null
            $desc = ($_.Description | ForEach-Object { $_ })
            $descShort = if($desc){ ($desc.ToString().Trim() -replace '\s+',' ') } else { "" }
            if($descShort.Length -gt 80){ $descShort = $descShort.Substring(0,80) + "…" }
            $titre = ("{0} - {1}" -f $loc, $descShort).Trim(" -")
        }

        [pscustomobject]@{
            Numero       = $num
            Titre        = $titre
            Localisation = ($_.Localisation | ForEach-Object { $_ })
            Description  = ($_.Description  | ForEach-Object { $_ })
        }
    }
}

# Map Numero -> Titre (référentiel)
$SujetTitreByNumero = @{}
foreach ($sj in $Sujets) {
  $SujetTitreByNumero[[string]$sj.Numero] = [string]$sj.Titre
}



# Lecture des participants
if ($ParticipantsPath) {
    $Participants = Import-Excel -Path $ParticipantsPath
    # colonnes possibles : NomCanonique, Role, Alias1, Alias2...
}

# Ajustement intelligent de Pass2BatchSize si l'utilisateur ne l'a pas fixé
if ($Provider -ieq "openai" -and ($ModelPass2 -like "*remote*")) {
    $Pass2BatchSize = 4
} else {
    $Pass2BatchSize = 2
}


Write-Host "==== PARAMS PIPELINE ====" -ForegroundColor Cyan
Write-Host ("Provider       = {0}" -f $Provider)
Write-Host ("ApiBase        = {0}" -f $ApiBase)
Write-Host ("Model          = {0}" -f $Model)
Write-Host ("ModelPass1     = {0}" -f $ModelPass1)
Write-Host ("ModelPass2     = {0}" -f $ModelPass2)
Write-Host ("ModelPass3     = {0}" -f $ModelPass3)
Write-Host ("ModelReport    = {0}" -f $ModelReport)
Write-Host ("Pass2BatchSize = {0}" -f $Pass2BatchSize)


if ($ApiKey) {
    Write-Host ("ApiKeyLen  = {0}" -f $ApiKey.Length)
} else {
    Write-Host "ApiKey     = (VIDE)" -ForegroundColor Yellow
}
Write-Host "=========================" -ForegroundColor Cyan

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
# Compteur de batchs Passe 2 (à mettre une seule fois, en dehors de la fonction)
[int] $script:Pass2BatchIndex = 0


function Write-Info($m){ Write-Host "[INFO]  $m" -ForegroundColor Cyan }
function Write-Warn($m){ Write-Host "[WARN]  $m" -ForegroundColor Yellow }
function Write-Err ($m){ Write-Host "[ERROR] $m" -ForegroundColor Red  }

function Ensure-Dir($p){
    if (-not $p) { 
        return  # ignore les valeurs nulles ou vides
    }
    if (!(Test-Path -LiteralPath $p)) {
        New-Item -ItemType Directory -Path $p | Out-Null
    }
}


# ── Gestion n_ctx / max_tokens : estimation et troncature ───────────── # MODIF GPT

function Estimate-Tokens([string]$text){
  if(-not $text){ return 0 }
  # Heuristique grossière : 1 token ≈ 4 caractères
  return [int][math]::Ceiling($text.Length / 4.0)
}

function Enforce-ContextLimit {
  param(
    [string] $SystemPrompt,
    [string] $UserPrompt,
    [string] $Label,
    [string] $LogFile,
    [string] $ModelName
  )

  $budget = Get-ContextBudget $ModelName
  $nCtx   = $budget.NCtx
  $maxTok = $budget.MaxTok
  $margin = $budget.Margin

  $tokSys   = Estimate-Tokens $SystemPrompt
  $tokUser  = Estimate-Tokens $UserPrompt
  $tokTotal = $tokSys + $tokUser

  $available = [int](($nCtx - $maxTok - $margin) * 0.9)
  if($available -lt 512){ $available = 512 }

  if($tokTotal -le $available){
    "CTX OK $Label : approx=$tokTotal, available=$available" | Add-Content $LogFile
    return $UserPrompt
  }

  $maxUserTokens = $available - $tokSys
  if($maxUserTokens -le 0){
    Write-Warn ("{0}: contexte insuffisant (tokSys={1}, available={2}), user vidé." -f $Label,$tokSys,$available)
    "WARN: $Label → prompt tronqué à 0 token (tokSys=$tokSys, available=$available, n_ctx=$nCtx, max_tokens=$maxTok)" | Add-Content $LogFile
    return ""
  }

  $maxUserChars = [int]($maxUserTokens * 4)

  if($UserPrompt.Length -le $maxUserChars){
    return $UserPrompt
  }

  $headChars = [int]($maxUserChars * 0.4)
  $tailChars = $maxUserChars - $headChars

  $headPart = $UserPrompt.Substring(0, [math]::Min($headChars, $UserPrompt.Length))
  $tailPart = ""
  if($UserPrompt.Length -gt $headChars){
    $tailPart = $UserPrompt.Substring($UserPrompt.Length - [math]::Min($tailChars, $UserPrompt.Length - $headChars))
  }

  $truncated = $headPart + "`n[...]`n" + $tailPart

  $tokUserNew  = Estimate-Tokens $truncated
  $tokTotalNew = $tokSys + $tokUserNew

  Write-Warn ("{0}: prompt tronqué (approx {1}→{2} tokens, n_ctx={3}, max_tokens={4})" -f $Label,$tokTotal,$tokTotalNew,$nCtx,$maxTok)
  "WARN: $Label → prompt tronqué (total≈$tokTotal, après≈$tokTotalNew, available=$available, n_ctx=$nCtx, max_tokens=$maxTok)" | Add-Content $LogFile

  return $truncated
}

# Budget de contexte par modèle (local vs remote)
function Get-ContextBudget {
    param([string] $ModelName)

    switch ($ModelName) {

        "annoter_segments_remote" { return @{ NCtx=120000; MaxTok=4000; Margin=2000 } }
        "annoter_segments_remote_alt" { return @{ NCtx=120000; MaxTok=4000; Margin=2000 } }
        "annoter_segments_remote_alt2" { return @{ NCtx=120000; MaxTok=4000; Margin=2000 } }

        "report_remote" { return @{ NCtx=120000; MaxTok=4000; Margin=2000 } }
        "report_remote_alt" { return @{ NCtx=120000; MaxTok=4000; Margin=2000 } }
        "report_remote_alt2" { return @{ NCtx=120000; MaxTok=4000; Margin=2000 } }

        # ✅ AJOUT CRITIQUE
        "pass3_remote" { return @{ NCtx=120000; MaxTok=4000; Margin=2000 } }
        "pass3_remote_alt" { return @{ NCtx=120000; MaxTok=4000; Margin=2000 } }
        "pass3_remote_alt2" { return @{ NCtx=120000; MaxTok=4000; Margin=2000 } }

        default {
            return @{ NCtx=4096; MaxTok=1024; Margin=128 }
        }
    }
}


function Ensure-List {
  param(
    [object] $Obj,
    [string] $PropName
  )

  if (-not $Obj) { return }

  if (-not $Obj.PSObject.Properties[$PropName] -or $null -eq $Obj.$PropName) {
    $Obj | Add-Member -Force -NotePropertyName $PropName -NotePropertyValue @()
    return
  }

  $v = $Obj.$PropName

  if ($v -is [string]) {
    $Obj.$PropName = if ($v.Trim()) { @($v.Trim()) } else { @() }
    return
  }

  if ($v -is [System.Collections.IDictionary]) {
    $Obj.$PropName = @($v)
    return
  }

  if ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) {
    # ok: array/list
    return
  }

  # scalaire / objet simple
  $Obj.$PropName = @($v)
}



# insertion du contexte général du dossier
$GlobalContext  = $null
$ContextMission = ""
$ContextSystem  = ""
$ContextUser    = ""
$ContextEtatAvancement = ""

# ⚠️ Ajouter un paramètre au début du script :
# [Parameter(Mandatory=$false)]
# [string] $ContextJsonPath = "",

if ($ContextJsonPath -and (Test-Path $ContextJsonPath)) {
    try {
        $GlobalContext  = Get-Content $ContextJsonPath -Raw | ConvertFrom-Json
        $ContextMission = $GlobalContext.mission
        $ContextSystem  = $GlobalContext.system
        $ContextUser    = $GlobalContext.user
        $ContextEtatAvancement = ""
        if ($GlobalContext -and $GlobalContext.PSObject.Properties['etat_avancement']) {
            $ContextEtatAvancement = [string]$GlobalContext.etat_avancement
        }
    }
    catch {
        Write-Warning "Impossible de lire le contexte général : $ContextJsonPath - $_"
    }
}
$EtatBlock = ""
if ($ContextEtatAvancement -and $ContextEtatAvancement.Trim() -ne "") {
    $EtatBlock = "`nÉtat d’avancement du dossier :`n$ContextEtatAvancement`n"
}


# ── Presets segmentation ───────────────────────────────────────────────────────
switch ($Preset) {
  "conservateur" { $TargetSegmentMinutes=30; $MinSegmentMinutes=15; $MaxSegmentMinutes=45; $OverlapSeconds=90; $ChangeThresh=0.85; $WindowLines=50; $BigGapSeconds=60 }
  "equilibre"    { $TargetSegmentMinutes=25; $MinSegmentMinutes=12; $MaxSegmentMinutes=40; $OverlapSeconds=90; $ChangeThresh=0.78; $WindowLines=35; $BigGapSeconds=45 }
  "agressif"     { $TargetSegmentMinutes=20; $MinSegmentMinutes= 8; $MaxSegmentMinutes=30; $OverlapSeconds=75; $ChangeThresh=0.70; $WindowLines=25; $BigGapSeconds=30 }
}
[bool]$SegDebug = [bool]$DebugSeg

# ── Domain keywords & anchors (pack riche) ─────────────────────────────────────
$DomainKeywords = @(
  'conformité','conforme','non-conforme','non conformité','dérogation','norme','nfp','plu',
  'dimensions','dimension','mesures','mesure','profondeur','largeur','recul','hauteur',
  'surface','aire','gabarit','cotes','plan','plans','plan d''exécution','deo',
  'réserves','réserve','désordre','constat','constats','anomalie','défaut','non respect','non-respect',
  'déviation','écart','écarts','tolérance','cahier des charges','document technique','dossier technique',
  'chantier','travaux','réalisation','maître d''oeuvre','moe','architecte','entreprise de peinture',
  'entreprise','constructeur','bureau d''études','béton','structure','parking','place','emplacement',
  'numéro','r-1','r-2','r+1','sous-sol','niveau','marquage','signalétique','accès','rampe','circulation',
  'voiture','stationnement','voitures','véhicule','véhicules','garage',
  'livraison','livré','réception','réceptionner','remise','clé','clés','retard','retards','délais','délai',
  'livrable','livrables','plannings','planning','indigo','cuvelage','inondation','eau','étanchéité',
  'pompage','infiltration','travaux de reprise','chantier en cours','achèvement','date de livraison',
  'report','provisoire','accès temporaire','accès parking','garage temporaire',
  'promoteur','acquéreur','maître d''ouvrage','maître d''oeuvre','moa','moe','expert','sapiteur','architecte',
  'entreprise','bailleur','vendeur','acheteur','client','parties','avocat','gestionnaire','notaire',
  'propriétaire','copropriétaire','copropriété','locataire','gestion','banque','assureur','assurance',
  'décennale','contrôle technique',
  'pinel','dispositif pinel','avantage fiscal','fiscalité','fiscal','fiscale','impôt','impôts','déduction',
  'déductions','réduction','réductions','loyer','revenu','déclaration','bénéfice','amortissement','loi pinel',
  'loi','sapiteur financier','préjudice fiscal','perte','préjudice','dommage','évaluation financière',
  'calcul','simulation','impacts financiers',
  'mise en cause','mises en cause','mise en demeure','expertise','expertises','expert judiciaire',
  'expert technique','expert amiable','rapport','rapport d''expertise','note','note technique','procédure',
  'assignation','audience','tribunal','amiable','conciliation','solution amiable','médiation',
  'responsabilité','responsabilités','responsable','dommage','dommages','perte de chance','juridique',
  'contrat','contractuel','contrat de vente','acte de vente','document de vente','permis de construire',
  'autorisation','autorisation administrative','litige','conflit','désaccord','accord','signature','décision',
  'décisions','résolution','jugement','référé','appel','parties adverses',
  'laser','mètre','télémètre','niveau','photo','photographie','schéma','plan','croquis','plan d''exécution',
  'dossier','pièce','annexe','plan de coupe','vue en plan','calcul','tableau','analyse','mesure laser',
  'vérification','contrôle','relevé','instrument','outil','mesurage','tolerances','tolérances',
  'discussion','débat','point suivant','point précédent','sujet suivant','prochain point','ordre du jour',
  'avancement','bilan','proposition','solution','solutions','problème','problèmes','remarque','remarques',
  'commentaire','commentaires','à voir','à vérifier','à corriger','à fournir','à transmettre','à faire',
  'à valider','note','mail','message','compte rendu','cr','procès-verbal','pv','document',
  'appartement','logement','immeuble','bâtiment','résidence','lot','lots','copropriété','parties communes',
  'parties privatives','garage','cave','ascenseur','accès','escalier','palier','hall','portes','volets',
  'fenêtres','menuiserie','isolation','mur','murs','plafond','sol','revêtement','revêtements','béton',
  'peinture','étanchéité','ventilation','chauffage','électricité','eau','réseau','canalisation','fuite'
)
$AnchorPhrases = @(
  'on passe au point suivant','nouveau sujet','dernier point','revenons à','pour terminer ce sujet',
  'changement de sujet','autre point','prochain point','sujet suivant','concluons sur','pour conclure','on clôt'
)
[double] $BonusDomainKeyword = 0.10
[double] $BonusAnchorPhrase  = 0.15

# ── Utils temps ────────────────────────────────────────────────────────────────
function Hms-To-Seconds([string]$hms){
  if(-not $hms){ return 0 }

  # Cas 1 : on reçoit directement un nombre de secondes (ex: "33.025")
  if($hms -match '^[0-9]+([.,][0-9]+)?$'){
    $hms = $hms -replace ',', '.'
    return [int][double]$hms
  }

  # Cas 2 : format HH:MM:SS
  $p = $hms.Split(":")
  if($p.Count -lt 2){ return 0 }
  if($p.Count -eq 2){ $p = @("0") + $p }
  return [int]$p[0]*3600 + [int]$p[1]*60 + [int][double]$p[2]
}
function Seconds-To-Hms([int]$s){ $h=[int]($s/3600); $m=[int](($s%3600)/60); $ss=[int]($s%60); "{0:D2}:{1:D2}:{2:D2}" -f $h,$m,$ss }



# ── Tokenization légère FR ────────────────────────────────────────────────────
$StopFR = @('alors','ainsi','après','avant','avec','car','ce','cela','ces','cet','cette','ceux','chaque',
'comme','comment','dans','de','des','du','donc','en','est','et','été','être','il','ils','elle','elles','on',
'nous','vous','je','la','le','les','leur','là','lui','mais','mes','mon','ne','nos','notre','ou','où','par',
'pas','plus','pour','qu','que','qui','sans','se','ses','son','sur','ta','tes','ton','très','trop','un','une',
'vos','votre','y','au','aux','vers','entre','déjà','peut','peu','fait','faire')

function Normalize-Tokens([string]$text){
  $t = ($text -as [string]).ToLower() -replace "[^a-zàâäçéèêëîïôöùûüÿoe\- ]"," "
  $raw = $t -split "\s+" | Where-Object { $_.Length -gt 2 -and -not ($StopFR -contains $_) }
  $raw | ForEach-Object { ($_ -replace "(ements|ement|ations|ation|istes|iste|iques|ique|ment|tion|s)$","") }
}
function Bag-Of-Words($tokens){
  $d = @{}
  foreach($w in $tokens){
    if(-not $w){ continue }

    if($d.ContainsKey($w)){
      $d[$w] = [int]$d[$w] + 1
    } else {
      $d[$w] = 1
    }
  }
  return $d
}

function Cosine-Sim($a,$b){ if(-not $a.Keys.Count -or -not $b.Keys.Count){return 0.0}; $dot=0; foreach($k in $a.Keys){ if($b.ContainsKey($k)){ $dot += $a[$k]*$b[$k] } }; $na=[math]::Sqrt(($a.Values|Measure-Object -Sum).Sum); $nb=[math]::Sqrt(($b.Values|Measure-Object -Sum).Sum); if($na -eq 0 -or $nb -eq 0){return 0.0}; $dot/($na*$nb) }

# ── LLM calls ─────────────────────────────────────────────────────────────────

function Unwrap-AdapterText {
  param([string] $Raw)

  if (-not $Raw) { return $Raw }
  $t = $Raw.Trim()

  # Si c’est un JSON wrapper { "text": "..." }
  if ($t.StartsWith("{")) {
    try {
      $o = $t | ConvertFrom-Json -Depth 50
      if ($o -and $o.PSObject.Properties["text"]) {
        # Si text est vide, on renvoie vide => déclenche fallback/throw amont
        return [string]$o.text
      }
    } catch {
      # pas un JSON => on laisse Raw tel quel
    }
  }
  return $Raw
}


function Invoke-LLM-OpenAICompat {
  param(
    [string] $system,
    [string] $user,
    [string] $model,
    [int]    $TimeoutSec = 600,
    [int]    $MaxTry = 6,
    [switch] $DebugHttp
  )
  Write-Host "[DEBUG] ApiBase utilisé = $ApiBase"
  $uri = ($ApiBase.TrimEnd('/')) + "/v1/chat/completions"
  Write-Host "[DEBUG] URI final = $uri"


  $headers = @{}
  if ($ApiKey) {
    $headers["Authorization"] = "Bearer $ApiKey"
  }
  $headers["Content-Type"] = "application/json"

  $bodyObj = @{
    model       = $model
    temperature = 0.2
    messages    = @(
      @{ role="system"; content=$system },
      @{ role="user";   content=$user   }
    )
  }
  $body = $bodyObj | ConvertTo-Json -Depth 20 -Compress

  if ($DebugHttp) {
    Write-Host ("[LLM] POST {0}" -f $uri)
    Write-Host ("[LLM] model={0} bodyChars={1}" -f $model, $body.Length)
  }

  for ($t = 1; $t -le $MaxTry; $t++) {
    try {
      $resp = Invoke-RestMethod -Method POST -Uri $uri -Headers $headers -Body $body `
        -ContentType "application/json" -TimeoutSec $TimeoutSec -ErrorAction Stop

      return $resp.choices[0].message.content
    }
    catch {
      $ex = $_.Exception
      $msg = $ex.Message

      # Status code (quand dispo)
      $status = $null
      try { $status = $ex.Response.StatusCode.value__ } catch {}

      # Body d'erreur (souvent ici qu'il y a {"detail": "..."} côté adapter)
      $errBody = $null

      # 1) d'abord ErrorDetails (quand présent)
      try {
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $errBody = $_.ErrorDetails.Message }
      } catch {}

      # 2) fallback: lire le body depuis la réponse HTTP si ErrorDetails est vide
      if (-not $errBody) {
        try {
          if ($ex.Response -and $ex.Response.Content) {
            $errBody = $ex.Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
          }
        } catch {}
      }

      if ($DebugHttp) {
        Write-Host ("[LLM] ERROR try {0}/{1} status={2} msg={3}" -f $t, $MaxTry, $status, $msg)
        if ($errBody) { Write-Host ("[LLM] ERROR body: {0}" -f $errBody) }
      }

      Write-Warning ("LLM échec try {0}/{1} (status={2}) : {3}" -f $t, $MaxTry, $status, $msg)
      if ($errBody) {
        Write-Warning ("LLM détail: {0}" -f $errBody)
      }

      # retry sur timeout / 429 / 5xx (et 502 de l'adapter)
      $shouldRetry = $true
      if ($status -and ($status -ge 400 -and $status -lt 500) -and ($status -ne 429)) {
        $shouldRetry = $false
      }

      if (-not $shouldRetry -or $t -eq $MaxTry) {
        $detail = if ($errBody) { $errBody } else { $msg }
        throw ("LLM failed (status={0}) {1}" -f $status, $detail)
      }

      Start-Sleep -Seconds ([math]::Min(60, 5 * $t))
    }
  }
}

function Normalize-SegmentObj {
  param([object] $obj)

  if (-not $obj) { return $null }

  if (-not $obj.PSObject.Properties['segment_id']) {
    return $null
  }
  if (-not $obj.PSObject.Properties['sujets'] -or -not $obj.sujets) {
    $obj | Add-Member -Force NoteProperty sujets (@{})
  }

  # sujets doit être un objet/dictionnaire : { "1":[{...}], "2":[...] }
  foreach($p in @($obj.sujets.PSObject.Properties)) {
    $num = $p.Name
    $arr = $p.Value

    # si ce n’est pas une liste → on ignore
    if (-not ($arr -is [System.Collections.IEnumerable])) {
      $obj.sujets.PSObject.Properties.Remove($num) | Out-Null
      continue
    }

    $clean = New-Object System.Collections.Generic.List[object]
    foreach($iv in $arr) {
      if (-not $iv) { continue }

      # exigences minimales : timecode + texte
      $tc = $iv.PSObject.Properties['timecode']?.Value
      $tx = $iv.PSObject.Properties['texte']?.Value

      # si le modèle a “cassé” les champs : on tente un fallback très conservateur
      if (-not $tx) { $tx = $iv.PSObject.Properties['text']?.Value }
      if (-not $tc) { continue }
      if (-not $tx) { continue }

      $au = $iv.PSObject.Properties['auteur']?.Value
      $ro = $iv.PSObject.Properties['role']?.Value

      $clean.Add([pscustomobject]@{
        timecode = [string]$tc
        auteur   = if($au){[string]$au}else{$null}
        role     = if($ro){[string]$ro}else{$null}
        texte    = [string]$tx
      }) | Out-Null
    }

    # remplace la liste initiale par la version nettoyée
    $obj.sujets.$num = $clean
  }

  return $obj
}


function Invoke-LLM-OllamaNative {
  param(
    [string] $system,
    [string] $user,
    [string] $model
  )

  $uri = ($OllamaBase.TrimEnd('/')) + "/api/generate"
  $prompt = "SYSTEM:`n$system`n`nUSER:`n$user"
  $body = @{
    model  = $model
    prompt = $prompt
    stream = $false
    options = @{ temperature = 0.2 }
  } | ConvertTo-Json -Depth 10

  (Invoke-RestMethod -Method POST -Uri $uri -Body $body -ContentType "application/json").response
}

function Invoke-LLM {
  param(
    [string] $system,
    [string] $user,
    [string] $model,
    [switch] $DebugHttp
  )

  if($Provider -ieq "openai"){
    return Invoke-LLM-OpenAICompat -system $system -user $user -model $model -DebugHttp:$DebugHttp
  } else {
    return Invoke-LLM-OllamaNative -system $system -user $user -model $model
  }
}

# ── Contrôle n_ctx / max_tokens pour les prompts ─────────────────────────────
function Get-ApproxTokens([string]$text){
  if(-not $text){ return 0 }
  # heuristique : ~4 caractères ≈ 1 token
  return [int][math]::Ceiling($text.Length / 4.0)
}

function Parse-LlmJsonStrict {
    param(
        [string] $RawText,
        [string] $Label,
        [string] $LogFile
    )

    if (-not $RawText -or $RawText.Trim() -eq "") {
        throw "Parse-LlmJsonStrict($Label) : sortie LLM vide."
    }

    $txt = $RawText.Trim()

    # 1) Retirer un éventuel préfixe "JSON :" (insensible à la casse)
    $txt = $txt -replace '^\s*JSON\s*:\s*', ''
    $txt = $txt -replace '^\s*<json>\s*', ''
    $txt = $txt -replace '\s*</json>\s*$', ''
  


    # 2) Extraire un éventuel bloc ```json ... ```
    if ($txt -match '(?s)```json\s*(.+?)```') {
        $candidate = $Matches[1].Trim()
    } elseif ($txt -match '(?s)```[\s\r\n]*(.+?)```') {
        $candidate = $Matches[1].Trim()
    } else {
        # 3) À défaut, prendre du premier { ou [ au dernier } ou ]
        $startObj = $txt.IndexOf('{')
        $startArr = $txt.IndexOf('[')
        if ($startObj -lt 0 -and $startArr -lt 0) {
            throw "Parse-LlmJsonStrict($Label) : aucun '{' ni '[' détecté."
        }

        if ($startObj -lt 0 -or ($startArr -ge 0 -and $startArr -lt $startObj)) {
            $start = $startArr
            $end   = $txt.LastIndexOf(']')
        } else {
            $start = $startObj
            $end   = $txt.LastIndexOf('}')
        }

        if ($end -lt $start) {
            throw "Parse-LlmJsonStrict($Label) : bornes JSON incohérentes."
        }

        $candidate = $txt.Substring($start, $end - $start + 1).Trim()
    }

    # 4) Cas où le JSON est doublement encodé ou pollué par des backslashes
    #    a) Si le candidat commence par un backslash, on enlève les backslashes de tête
    if ($candidate.Length -gt 0 -and $candidate[0] -eq '\') {
        $candidate = $candidate.TrimStart('\').Trim()
    }

    #    b) Si le candidat est une chaîne JSON (entre guillemets) contenant un JSON échappé
    if ($candidate.StartsWith('"') -and $candidate.EndsWith('"')) {
        try {
            $inner = $candidate | ConvertFrom-Json -Depth 50
            if ($inner -is [string]) {
                $candidate = $inner.Trim()
            } else {
                # déjà un objet ou tableau -> on peut le retourner directement
                "Parse-LlmJsonStrict($Label) OK (string JSON → objet)" | Add-Content $LogFile
                return $inner
            }
        } catch {
            # on laisse tomber cette piste, on tentera quand même un parse direct plus bas
        }
    }

    # ---------------------------------------------------------
    # 5) Parsing en plusieurs passes / réparations
    # ---------------------------------------------------------

    function _Log([string]$msg) {
        if ($LogFile) {
            "[{0}] [Parse-LlmJsonStrict] {1}" -f (Get-Date -Format "u"), $msg | Add-Content $LogFile
        }
    }

    function _TryConvert([string]$payload, [string]$step) {
        _Log "($Label) Tentative ConvertFrom-Json [$step], len=$($payload.Length)."
        return $payload | ConvertFrom-Json -Depth 50 -ErrorAction Stop
    }
    # Tentative d'équilibrage si JSON tronqué
    function Balance-Brackets([string]$s) {
        $openCurly  = ($s -split "{").Count - 1
        $closeCurly = ($s -split "}").Count - 1
        if ($closeCurly -lt $openCurly) {
            $s += "}" * ($openCurly - $closeCurly)
        }

        $openSq  = ($s -split "\[").Count - 1
        $closeSq = ($s -split "\]").Count - 1
        if ($closeSq -lt $openSq) {
            $s += "]" * ($openSq - $closeSq)
        }

        return $s
    }

    $candidate = Balance-Brackets $candidate


    # PASS 1 : tel quel (comportement actuel)
    try {
        $obj = _TryConvert $candidate "direct"
        "Parse-LlmJsonStrict($Label) OK (direct)" | Add-Content $LogFile
        return $obj
    }
    catch {
        "Parse-LlmJsonStrict($Label) ÉCHEC direct. Début candidat: '$($candidate.Substring(0,[Math]::Min(80,$candidate.Length)))'" | Add-Content $LogFile
    }

    # PASS 2 : suppression des virgules finales avant } ou ]
    $candidate2 = $candidate -replace ',\s*(\}|\])','$1'
    try {
        $obj = _TryConvert $candidate2 "sans virgules terminales"
        "Parse-LlmJsonStrict($Label) OK (virgules terminales corrigées)" | Add-Content $LogFile
        return $obj
    }
    catch {
        "Parse-LlmJsonStrict($Label) ÉCHEC pass2. Début candidat2: '$($candidate2.Substring(0,[Math]::Min(80,$candidate2.Length)))'" | Add-Content $LogFile
    }

    # PASS 3 : correction guillemets simples + backslashes parasites
    $candidate3 = $candidate2

    # a) remplace les guillemets simples par doubles (cas JSON avec '...')
    $candidate3 = $candidate3 -replace "''","'"
    $candidate3 = $candidate3 -replace "'",'"'

    # b) supprime les backslashes qui n'introduisent pas une séquence d'échappement JSON valide
    $candidate3 = [System.Text.RegularExpressions.Regex]::Replace(
        $candidate3,
        "\\(?![""\\/bfnrt])",
        ""
    )

    try {
        $obj = _TryConvert $candidate3 "quotes/backslashes corrigés"
        "Parse-LlmJsonStrict($Label) OK (quotes/backslashes)" | Add-Content $LogFile
        return $obj
    }
    catch {
        "Parse-LlmJsonStrict($Label) ÉCHEC pass3. Début candidat3: '$($candidate3.Substring(0,[Math]::Min(80,$candidate3.Length)))'" | Add-Content $LogFile
        throw "Parse-LlmJsonStrict($Label) : impossible de parser la réponse en JSON après 3 passes."
    }
}

function Truncate-For-Context {
  param(
    [string] $SystemText,
    [string] $UserText,
    [string] $ModelName
  )

  $budget = Get-ContextBudget $ModelName
  $NCtx   = $budget.NCtx
  $MaxTokens = $budget.MaxTok
  $Margin = $budget.Margin

  $sysTok = Get-ApproxTokens $SystemText
  $usrTok = Get-ApproxTokens $UserText

  $available = $NCtx - $MaxTokens - $Margin
  if($available -lt 512){ $available = 512 }

  if($sysTok + $usrTok -le $available){
    return $UserText
  }

  $maxUserTokens = $available - $sysTok
  if($maxUserTokens -le 0){
    $maxUserTokens = [int][math]::Floor($available / 2.0)
  }

  $maxUserChars = $maxUserTokens * 4

  if($UserText.Length -le $maxUserChars){
    return $UserText
  }

  $startIndex    = $UserText.Length - $maxUserChars
  $truncatedUser = $UserText.Substring($startIndex)

  Write-Warn ("Prompt tronqué (Pass 3) : approx sys={0} tok, user={1}→{2} tok, n_ctx={3}, max_tokens={4}, available={5}" -f $sysTok,$usrTok,$maxUserTokens,$NCtx,$MaxTokens,$available)

  return $truncatedUser
}

# ── Prompts debrief expert Passe 1B ─────────────────────────────────────────
$BaseDebrief_System = @'
Tu es un expert judiciaire relisant ta propre transcription de DÉBRIEF.

Cette transcription contient :
- tes commentaires pour guider la rédaction du compte rendu,
- tes idées de demandes de documents ou pièces complémentaires.

Tu disposes aussi de la liste numérotée des SUJETS (Numero + Titre).

Tâches :
1) Pour chaque sujet explicite ou implicite dans le débrief :
   - résumer en quelques phrases l’ORIENTATION que tu veux donner dans le rapport,
   - extraire les demandes de documents clairement rattachées à ce sujet.

2) Extraire aussi les demandes de documents qui ne se rattachent pas clairement à un sujet
   (les mettre dans "demandes_documents_hors_sujet").

Sortie STRICTEMENT JSON :
{
  "sujets": [
    {
      "numero": <int>,
      "titre": "string",
      "orientation_expert": "string",
      "demandes_documents": [
        {
          "objet": "string",
          "echeance": "YYYY-MM-DD | null",
          "commentaire": "string | null",
          "origine": "debrief_expert"
        }
      ]
    }
  ],
  "demandes_documents_hors_sujet": [
    {
      "objet": "string",
      "echeance": "YYYY-MM-DD | null",
      "commentaire": "string | null",
      "origine": "debrief_expert"
    }
  ],
  "global_debrief":{
    "resume":"string",
    "ordre_du_jour":["string","..."],
    "themes_abordes":[
      { "titre":"string", "synthese":["string","..."], "indices_source":[{"timecode":null,"speaker":null,"extrait":"string"}] }
    ],
    "actions":[
      { "action":"string", "responsable":"string|null", "echeance":"YYYY-MM-DD|null", "commentaire":"string|null" }
    ],
    "perspectives":[ { "probleme":"string", "solution":"string" } ],
    "annexes":["string","..."]
  }

}
'@

if ($GlobalContext) {
    $Debrief_System = @"
$ContextSystem

Mission générale de l'analyse (à respecter strictement) :
$ContextMission
$EtatBlock
$BaseDebrief_System
"@
}
else {
    $Debrief_System = $BaseDebrief_System
}

if ($ContextUser) {
    $Debrief_User_Template = @"
Contexte général de l’affaire (ne pas réécrire, ne pas inventer d’éléments nouveaux) :
$ContextUser

Liste des sujets numérotés (JSON) :
{SUJETS_JSON}

Transcription complète du débrief de l'expert (lignes chronologiques) :

{DEBRIEF_LINES}

Renvoie uniquement le JSON conforme au schéma.
"@
}
else {
    $Debrief_User_Template = @'
Liste des sujets numérotés (JSON) :
{SUJETS_JSON}

Transcription complète du débrief de l'expert (lignes chronologiques) :

{DEBRIEF_LINES}

Renvoie uniquement le JSON conforme au schéma.
'@
}


# ── Prompts JSON strict Passes 1/2/3 ──────────────────────────────────────────
$BasePass1_System = @'
Tu es un assistant d’analyse judiciaire.

Objectif :
À partir d’un SEGMENT de transcription d’une réunion d’expertise, tu dois :
- repérer quels SUJETS NUMÉROTÉS sont abordés,
- associer chaque prise de parole aux bons sujets,
- identifier l’auteur (participant) de manière canonique.

Tu disposes :
- d’une liste de sujets numérotés (JSON) comprenant au minimum Numeroet Titre, et éventuellement Localisation/Description que tu peux utiliser comme indices de rattachement,
- d’une liste de participants (Nom + Rôle + éventuels alias),
- d’un segment de transcription sous forme de lignes : "[HH:MM:SS] SPEAKER: texte".

Règles :
- Tu peux associer une même prise de parole à plusieurs sujets si elle en parle clairement.
- Si tu n’es pas sûr, tu n’associes pas (mieux vaut rater un lien que d’en inventer un).
- Tu ne fais AUCUN résumé ici, uniquement du repérage de contenu par sujet.

Tu dois répondre STRICTEMENT en JSON avec ce schéma :

{
  "segment_id": "string",
  "sujets": {
    "<numero_sujet>": [
      {
        "timecode": "HH:MM:SS",
        "auteur": "Nom canonique du participant",
        "role": "Rôle du participant",
        "texte": "extrait fidèle, pas trop long"
      }
    ]
  }
}
'@
if ($GlobalContext) {
    $Pass1_System = @"
$ContextSystem

Mission générale de l'analyse (à respecter strictement) :
$ContextMission
$EtatBlock

$BasePass1_System
"@
}
else {
    $Pass1_System = $BasePass1_System
}

if ($ContextUser) {
    $Pass1_User_Template = @"
Contexte général de l’affaire (ne pas le réécrire, ne pas inventer d’éléments nouveaux) :
$ContextUser

Liste des sujets numérotés (JSON) :
{SUJETS_JSON}

Liste des participants (JSON) :
{PARTICIPANTS_JSON}

segment_id = ""{SEGMENT_ID}""

Transcription segmentée (de {START_HMS} à {END_HMS}) :

{LINES}

Renvoie uniquement le JSON conforme au schéma.
"@
}
else {
    $Pass1_User_Template = @'
Liste des sujets numérotés (JSON) :
{SUJETS_JSON}

Liste des participants (JSON) :
{PARTICIPANTS_JSON}

segment_id = "{SEGMENT_ID}"

Transcription segmentée (de {START_HMS} à {END_HMS}) :

{LINES}

Renvoie uniquement le JSON conforme au schéma.
'@
}

$BasePass2_System=@'
Tu reçois plusieurs mini-CR JSON d'une même réunion. Fusionne-les en un seul JSON cohérent,
sans doublons, en regroupant les thèmes similaires.

Retourne UNIQUEMENT du JSON strict (aucun texte hors JSON) avec ce schéma exact :
{
  "resume_global": "string (6–8 phrases)",
  "themes": [
    { "titre":"string", "synthese":["string","..."], "timecodes":["HH:MM:SS","HH:MM:SS"] }
  ],
  "actions": [
    { "action":"string", "responsable":"string", "echeance":"YYYY-MM-DD | null" }
  ],
  "problems": [
    { "probleme":"string", "solution":"string" }
  ]
}

Règles :
- regrouper par sens ;
- dédupliquer les informations redondantes ;
- conserver les timecodes représentatifs ;
- conserver explicitement TOUTES les demandes de documents ou pièces (plans, justificatifs, rapports, etc.),
  en les retranscrivant de préférence comme des actions ("fournir...", "transmettre...") avec le responsable ;
- en cas de conflit sur une date, retenir la date la plus précise.
'@
if ($GlobalContext) {
    $Pass2_System = @"
$ContextSystem

Mission générale de l'analyse (à respecter strictement) :
$ContextMission
$EtatBlock

$BasePass2_System
"@
}
else {
    $Pass2_System = $BasePass2_System
}

$Pass2_User_Template=@'
Voici la liste des mini-CR JSON à fusionner (tableau JSON) :

{SEGMENTS_JSON_ARRAY}

Renvoie uniquement le JSON conforme au schéma.
'@

# ── Pass2B : construire un GLOBAL "réunion" (resume/themes/actions/problems) depuis global.json ──
# ── Pass2B : GLOBAL "réunion" enrichi ──
$BasePass2B_System = @'
Tu reçois une LISTE JSON de segments annotés, sous la forme :
[
  {
    "segment_id": "segment_XX",
    "sujets": {
      "1":[{"timecode":"HH:MM:SS","auteur":"...","role":"...","texte":"..."}, ...],
      "2":[...]
    }
  }
]

Consigne préalable (obligatoire) :
- Fusionner tous les champs "sujets" de tous les segments.
- Dédupliquer les interventions identiques.
- Ne jamais réécrire la liste d'entrée.
- Sortie attendue : UNIQUEMENT le JSON "global réunion" (pas de balises <json>, pas de texte).

Objectif :
Produire un JSON "global réunion" STRICT au schéma suivant (sans inventer) :
{
  "resume_global": "string (6–10 phrases)",
  "themes": [
    { "titre":"string", "synthese":["string","..."], "timecodes":["HH:MM:SS","..."] }
  ],
  "themes_abordes": ["string", "..."],
  "actions": [
    { "action":"string", "responsable":"string | null", "echeance":"YYYY-MM-DD | null" }
  ],
  "perspectives": ["string","..."],
  "demandes_documents_globales": [
    { "objet":"string", "demandeur":"string | null", "destinataire":"string | null", "echeance":"YYYY-MM-DD | null", "timecodes":["HH:MM:SS","..."] }
  ],
  "problems": [
    { "probleme":"string", "solution":"string | null" }
  ]
}

Règles :
- Pas d’invention : si incertain → null / [].
- 5 à 12 thèmes max (dans "themes").
- timecodes : uniquement ceux présents dans les interventions ; sinon [].
- "themes_abordes" : 5 à 15 libellés.
- "actions" : inclure explicitement les demandes de documents comme actions.
- Dédupliquer partout.
- Si les données sont insuffisantes, renvoyer quand même un JSON conforme avec chaînes vides et tableaux vides (pas de texte).
- La réponse doit commencer par { et se terminer par }.
'@


if ($GlobalContext) {
  $Pass2B_System = @"
$ContextSystem

Mission générale de l'analyse (à respecter strictement) :
$ContextMission
$EtatBlock

$BasePass2B_System
"@
} else {
  $Pass2B_System = $BasePass2B_System
}

$Pass2B_User_Template = @'
Voici la LISTE des segments annotés :

{SEGMENTS_JSON}

Renvoie uniquement le JSON "global réunion" conforme au schéma.
'@


# agregation hierarchique
function Aggregate-Sujets {
    param([object[]] $Segments)

    $bySujet = @{}

    foreach ($seg in $Segments) {
        if (-not $seg) { continue }

        $sujets = $seg.sujets
        if (-not $sujets) { continue }

        # 1) Récupérer les paires (numero -> interventions) selon le type
        $pairs = @()

        if ($sujets -is [System.Collections.IDictionary]) {
            # Hashtable / Dictionary
            $pairs = $sujets.GetEnumerator() | ForEach-Object {
                [pscustomobject]@{ Numero = [string]$_.Key; Interventions = $_.Value }
            }
        }
        else {
            # PSCustomObject (ConvertFrom-Json donne souvent ça)
            $pairs = $sujets.PSObject.Properties | ForEach-Object {
                [pscustomobject]@{ Numero = [string]$_.Name; Interventions = $_.Value }
            }
        }

        foreach ($p in $pairs) {
            $numero = ($p.Numero).Trim()
            if (-not $numero) { continue }
            if (-not $bySujet.ContainsKey($numero)) { $bySujet[$numero] = @() }

            $interventions = $p.Interventions
            if (-not $interventions) { continue }

            # 2) Normaliser en liste
            if ($interventions -isnot [System.Collections.IEnumerable] -or $interventions -is [string]) {
                $interventions = @($interventions)
            }

            foreach ($iv in $interventions) {
                if (-not $iv) { continue }
                $bySujet[$numero] += [pscustomobject]@{
                    segment_id = $seg.segment_id
                    timecode   = $iv.timecode
                    auteur     = $iv.auteur
                    role       = $iv.role
                    texte      = $iv.texte
                }
            }
        }
    }

    return $bySujet
}


function Invoke-Pass2Fusion {
    param(
        [object[]] $SegmentBatch,  # petit groupe de mini-CR
        [string]   $LogFile
    )

    if(-not $SegmentBatch -or $SegmentBatch.Count -eq 0){
        throw "Invoke-Pass2Fusion: batch vide"
    }

    # Répertoire de logs à partir du chemin du log courant
    $localLogsDir = Split-Path $LogFile -Parent

    # Incrémenter l’index de batch
    $script:Pass2BatchIndex++
    $batchId = $script:Pass2BatchIndex.ToString("D2")

    $segmentsJsonArray = ($SegmentBatch | ConvertTo-Json -Depth 50)
    $user = $Pass2_User_Template.Replace("{SEGMENTS_JSON_ARRAY}", $segmentsJsonArray)

    # Contrôle n_ctx / max_tokens sur ce batch
    $userEffective = Enforce-ContextLimit `
            -SystemPrompt $Pass2_System `
            -UserPrompt   $user `
            -Label        ("Pass2 batch #" + $batchId) `
            -LogFile      $LogFile `
            -ModelName    $ModelPass2

    # Appel LLM
    $raw = Invoke-LLM -system $Pass2_System -user $userEffective -model $ModelPass2 -DebugHttp:$DebugHttp


    # Logs de debug (prompt effectif + réponse brute)
    $rawPath    = Join-Path $localLogsDir ("pass2_batch_" + $batchId + ".raw.txt")
    $promptPath = Join-Path $localLogsDir ("pass2_batch_" + $batchId + ".prompt_effective.txt")

    [System.IO.File]::WriteAllText(
      $rawPath,
      [string]$raw,
      [System.Text.Encoding]::UTF8
    )

    [System.IO.File]::WriteAllText(
      $promptPath,
      [string]$userEffective,
      [System.Text.Encoding]::UTF8
    )


    # Parsing robuste
    try {
        $obj = Parse-LlmJsonStrict -RawText $raw -Label ("Pass2 batch #" + $batchId) -LogFile $LogFile
    }
    catch {
        $errPath = Join-Path $localLogsDir ("pass2_batch_" + $batchId + ".error.txt")
        $errText = "ERREUR Parse-LlmJsonStrict Passe 2 batch #$batchId`n`nRAW:`n$raw"
        [System.IO.File]::WriteAllText($errPath, $errText, [System.Text.Encoding]::UTF8)

        # Fallback minimal pour ne pas casser tout le pipeline
        $obj = [pscustomobject]@{
            resume_global = ""
            themes        = @()
            actions       = @()
            problems      = @()
        }
    }

    # Normalisation du schéma (sécurité)
    if (-not $obj.PSObject.Properties['resume_global']) { $obj | Add-Member -NotePropertyName resume_global -NotePropertyValue "" }
    if (-not $obj.PSObject.Properties['themes'])        { $obj | Add-Member -NotePropertyName themes        -NotePropertyValue @() }
    if (-not $obj.PSObject.Properties['actions'])       { $obj | Add-Member -NotePropertyName actions       -NotePropertyValue @() }
    if (-not $obj.PSObject.Properties['problems'])      { $obj | Add-Member -NotePropertyName problems      -NotePropertyValue @() }


    # 1) On calcule un indicateur de "richesse" du batch en entrée
    $batchThemesCount   = ($SegmentBatch | ForEach-Object { ($_.themes        | Measure-Object).Count } | Measure-Object -Sum).Sum
    $batchActionsCount  = ($SegmentBatch | ForEach-Object { ($_.actions       | Measure-Object).Count } | Measure-Object -Sum).Sum
    $batchProblemsCount = ($SegmentBatch | ForEach-Object { ($_.problems      | Measure-Object).Count } | Measure-Object -Sum).Sum
    $batchTextLen = (
      $SegmentBatch |
      ForEach-Object {
          $txt = ""

          if ($_.PSObject.Properties['resume_global']  -and $_.resume_global) {
              $txt += ($_.resume_global  | Out-String)
          }
          if ($_.PSObject.Properties['resume_segment'] -and $_.resume_segment) {
              $txt += ($_.resume_segment | Out-String)
          }

          $txt.Length
      } | Measure-Object -Sum
  ).Sum

    # 2) On regarde si le résultat est "vide"
    $resultThemes   = ($obj.themes   | Measure-Object).Count
    $resultActions  = ($obj.actions  | Measure-Object).Count
    $resultProblems = ($obj.problems | Measure-Object).Count
    $resultTextLen  = ($obj.resume_global | Out-String).Length

    $inputRich    = ($batchThemesCount + $batchActionsCount + $batchProblemsCount + $batchTextLen)
    $resultEmpty  = ($resultThemes -eq 0 -and $resultActions -eq 0 -and $resultProblems -eq 0 -and $resultTextLen -eq 0)

    if ($inputRich -gt 0 -and $resultEmpty) {
        # Cas anormal : le LLM a "tout vidé"
        Write-Warn "Invoke-Pass2Fusion: résultat vide alors que le batch contenait des données. Fallback sur une fusion simple."

        # Fallback minimal : on concatène les champs des objets du batch
        $fallback = [pscustomobject]@{
            resume_global = (
              $SegmentBatch |
              ForEach-Object {
                  if ($_.PSObject.Properties['resume_global'] -and $_.resume_global) {
                      $_.resume_global
                  }
                  if ($_.PSObject.Properties['resume_segment'] -and $_.resume_segment) {
                      $_.resume_segment
                  }
              } |
              Where-Object { $_ } |
              Out-String
          ).Trim()
            themes        = @()
            actions       = @()
            problems      = @()
        }

        $fallback.themes   = $SegmentBatch | ForEach-Object { $_.themes   } | Where-Object { $_ } 
        $fallback.actions  = $SegmentBatch | ForEach-Object { $_.actions  } | Where-Object { $_ } 
        $fallback.problems = $SegmentBatch | ForEach-Object { $_.problems } | Where-Object { $_ } 

        return $fallback
    }

    return $obj
}

#----------------------------------------------------
function Aggregate-Segments-Hierarchical {
    param(
        [object[]] $SegmentsObjs,
        [int]      $BatchSize,
        [string]   $LogFile
    )
    
    if(-not $SegmentsObjs -or $SegmentsObjs.Count -eq 0){
        throw "Aggregate-Segments-Hierarchical: aucun segment"
    }

    $current = $SegmentsObjs
    $round   = 1

    while($current.Count -gt 1){
        Write-Info ("Passe 2 (round {0}) → {1} objets à fusionner" -f $round, $current.Count)
        $next = New-Object System.Collections.Generic.List[object]

        for($i=0; $i -lt $current.Count; $i += $BatchSize){
            $j     = [math]::Min($i + $BatchSize - 1, $current.Count - 1)
            $batch = $current[$i..$j]

            $miniGlobal = Invoke-Pass2Fusion -SegmentBatch $batch -LogFile $LogFile
            $next.Add($miniGlobal) | Out-Null
        }

        $current = $next
        $round++
    }

    return $current[0]
}


# ── Passes 3A / 3B / 3C : enrichissement progressif du JSON FINAL ─────────────

# 3A : métadonnées et résumé global
$BasePass3A_System = @'
Tu reçois un JSON "global" décrivant une réunion :
- "resume_global"
- "themes"
- "actions"
- "problems"

Tu dois produire UNIQUEMENT les champs suivants, au format JSON strict :

{
  "date": "YYYY-MM-DD | null",
  "link": "string | null",
  "resume": "string",
  "ordre_du_jour": ["string", "..."]
}

Règles :
- pas d'invention : si l'information n'est pas clairement présente → null ou [].
- aucune phrase hors JSON, aucune explication.
'@

if ($GlobalContext) {
    $Pass3A_System = @"
$ContextSystem

Mission générale de l'analyse (à respecter strictement) :
$ContextMission
$EtatBlock
$ContextEtatAvancement

$BasePass3A_System
"@
}
else {
    $Pass3A_System = $BasePass3A_System
}

$Pass3A_User_Template = @'
Voici le JSON global issu de la fusion des segments :

{GLOBAL_JSON}

À partir de ce JSON global, produis uniquement :
- "date"
- "link"
- "resume"
- "ordre_du_jour"

Renvoie uniquement le JSON conforme au schéma.
'@

# 3B : thèmes_abordes
$BasePass3B_System = @'
Tu reçois le JSON "global" d'une réunion (résumé, thèmes, actions, problèmes).

Tu dois produire UNIQUEMENT :

{
  "themes_abordes": [
    {
      "titre": "string",
      "synthese": ["string","..."],
      "indices_source": [
        { "timecode": "HH:MM:SS", "speaker": "string", "extrait": "string court" }
      ]
    }
  ]
}

Règles :
- 5 à 10 thèmes maximum.
- 1 à 3 indices_source par thème.
- pas d'invention ; ne t'appuie que sur le JSON global.
- sortie STRICTEMENT au format JSON.
'@
if ($GlobalContext) {
    $Pass3B_System = @"
$ContextSystem

Mission générale de l'analyse (à respecter strictement) :
$ContextMission
$EtatBlock


$BasePass3B_System
"@
}
else {
    $Pass3B_System = $BasePass3B_System
}

$Pass3B_User_Template = @'
Voici le JSON global issu de la fusion des segments :

{GLOBAL_JSON}

À partir de ce JSON global, produis uniquement le champ "themes_abordes"
selon le schéma indiqué.

Renvoie uniquement le JSON conforme au schéma.
'@

# 3C : actions / perspectives / annexes
$BasePass3C_System = @'
Tu reçois le JSON "global" d'une réunion.

Tu dois produire UNIQUEMENT :

{
  "actions": [
    {
      "action": "string",
      "responsable": "string",
      "echeance": "YYYY-MM-DD | null",
      "commentaire": "string | null"
    }
  ],
  "perspectives": [
    { "probleme": "string", "solution": "string" }
  ],
  "annexes": ["string","..."]
}

Règles :
- aucun champ supplémentaire.
- pas d'invention : si l'information n'est pas claire → null ou [].
- réponse STRICTEMENT au format JSON.
'@
if ($GlobalContext) {
    $Pass3C_System = @"
$ContextSystem

Mission générale de l'analyse (à respecter strictement) :
$ContextMission
$EtatBlock


$BasePass3C_System
"@
}
else {
    $Pass3C_System = $BasePass3C_System
}

$Pass3C_User_Template = @'
Voici le JSON global issu de la fusion des segments :

{GLOBAL_JSON}

À partir de ce JSON global, produis uniquement :
- "actions"
- "perspectives"
- "annexes"

Renvoie uniquement le JSON conforme au schéma.
'@


# Passe 3 → JSON final (structure CR complète, sans Markdown)
$BasePass3_System = @'
Tu es un expert judiciaire chargé de produire un rapport structuré par SUJET NUMÉROTÉ.

Entrées :
- Un JSON "global" contenant, pour chaque numéro de sujet, la liste des interventions associées :
  {
    "sujets": {
      "1": [ { "timecode": "...", "auteur": "...", "role": "...", "texte": "..." }, ... ],
      "2": [ ... ],
      ...
    }
  }
- La liste des sujets numérotés (Numero + Titre).
- La liste des participants (Nom + Rôle).
- ÉVENTUELLEMENT un JSON debrief_expert (peut être null) de la forme :
  {
    "sujets": [
      {
        "numero": <int>,
        "titre": "string",
        "orientation_expert": "string",
        "demandes_documents": [
          { "objet": "string", "echeance": "YYYY-MM-DD | null", "commentaire": "string | null", "origine": "debrief_expert" }
        ]
      }
    ],
    "demandes_documents_hors_sujet": [
      { "objet": "string", "echeance": "YYYY-MM-DD | null", "commentaire": "string | null", "origine": "debrief_expert" }
    ]
  }

Objectif :
Pour chaque sujet, tu dois également restituer les demandes de documents rattachées à ce sujet.
Tu recevras pour cela un JSON "debrief_expert" qui peut contenir des demandes documentaires
par sujet, et un JSON "demandes_documents_globales" provenant de la réunion.

Règles d’intégration :
- si une demande concerne explicitement un sujet (debrief_expert), tu l’ajoutes au champ "demandes_documents" du sujet correspondant.
- si une demande issue de la réunion mentionne clairement ou implicitement le sujet, tu peux l’y rattacher.
- si tu ne peux pas déterminer le sujet, tu ne l’ajoutes pas dans ce champ et elle restera dans la synthèse globale.
- NE PAS mélanger les demandes entre sujets : pas d’approximation.
- "demandes_documents" par sujet doit contenir uniquement les pièces clairement attribuables.

Pour chaque sujet de la liste (dans l’ordre 1 → N) :
- regrouper les interventions par participant,
- résumer l’avis de chaque participant,
- rédiger une synthèse globale des échanges,
- proposer une conclusion d’expert (neutre, motivée, factuelle).

Utilisation du debrief_expert (si présent) :
- S’il existe une entrée de debrief pour un numéro de sujet donné, utiliser "orientation_expert"
  comme fil directeur de "conclusion_expert".
- Ne pas inventer de faits : "orientation_expert" peut t’inspirer la formulation et les axes
  d’analyse, mais ne doit pas te faire contredire clairement le contenu des échanges.
- Si aucun échange n’est présent pour un sujet MAIS que le debrief fournit une orientation,
  tu peux t’appuyer sur cette orientation pour une conclusion prudente, en restant neutre.
- Ne PAS intégrer les demandes de documents dans les champs de sortie : elles sont traitées
  dans un autre module (passe 3D).

Tu dois OBLIGATOIREMENT traiter tous les sujets de la liste,
même si aucun échange n’existe pour un sujet donné.

Si aucun échange n’est présent pour un sujet :
- "avis_participants" = []
- "synthese_echanges" = "Aucun échange identifié pour ce sujet."
- "conclusion_expert" = conclusion minimale et prudente.

Réponds STRICTEMENT au format JSON avec ce schéma :

{
  "sujets": [
    {
      "numero": <int>,
      "titre": "string",
      "avis_participants": [
        { "nom": "string", "role": "string", "resume": "string" }
      ],
      "synthese_echanges": "string",
      "conclusion_expert": "string"
    }
  ],
  "tous_sujets_traites": true|false,
  "sujets_manquants": [ <int>, ... ]
}

Règles :
- ton neutre, juridique, sans langage familier.
- pas d’invention de faits ; tu peux formuler des analyses dans "conclusion_expert", mais fondées
  sur les échanges et, si disponible, sur "orientation_expert" du debrief.
- si tu détectes qu’un numéro de sujet de la liste initiale n’apparaît pas dans ta sortie,
  ajoute-le dans "sujets_manquants" et mets "tous_sujets_traites": false.
'@
if ($GlobalContext) {
    $Pass3_System = @"
$ContextSystem

Mission générale de l'analyse (à respecter strictement) :
$ContextMission
$EtatBlock


$BasePass3_System
"@
}
else {
    $Pass3_System = $BasePass3_System
}

if ($ContextUser) {
    $Pass3_User_Template = @"
Contexte général de l’affaire (ne pas réécrire, ne pas inventer d’éléments nouveaux) :
$ContextUser

JSON global (interventions par sujet) :
{GLOBAL_JSON}

Liste des sujets numérotés (Numero + Titre) :
{SUJETS_JSON}

Liste des participants :
{PARTICIPANTS_JSON}

JSON debrief_expert (peut être null) :
{DEBRIEF_JSON}

Produis le JSON FINAL du rapport, conforme au schéma demandé.
Renvoie uniquement le JSON.
"@
}
else {
    $Pass3_User_Template = @'
JSON global (interventions par sujet) :
{GLOBAL_JSON}

Liste des sujets numérotés (Numero + Titre) :
{SUJETS_JSON}

Liste des participants :
{PARTICIPANTS_JSON}

JSON debrief_expert (peut être null) :
{DEBRIEF_JSON}

Produis le JSON FINAL du rapport, conforme au schéma demandé.
Renvoie uniquement le JSON.
'@
}

# 3D : demandes de documents
$BasePass3D_System = @'
Tu reçois le JSON "global" d'une réunion d’expertise judiciaire.

Tu dois extraire UNIQUEMENT toutes les demandes de documents ou d’informations à fournir.

Réponds STRICTEMENT par un JSON respectant ce schéma :

{
  "demandes_documents_globales": [
    {
      "objet": "string",
      "demandeur": "string | null",
      "destinataire": "string | null",
      "echeance": "YYYY-MM-DD | null",
      "commentaire": "string | null",
      "origine": "reunion"
    }
  ]
}

Règles :
- aucune invention : si une information n’est pas explicitement présente → null.
- si aucune demande n’existe → "demandes_documents_globales": [].
- aucune phrase ou texte hors JSON.
'@
if ($GlobalContext) {
    $Pass3D_System = @"
$ContextSystem

Mission générale de l'analyse (à respecter strictement) :
$ContextMission
$EtatBlock


$BasePass3D_System
"@
}
else {
    $Pass3D_System = $BasePass3D_System
}

$Pass3D_User_Template = @'
Voici le JSON global issu de la fusion des segments :

{GLOBAL_JSON}

Renvoie uniquement un JSON contenant le champ "demandes_documents_globales".
'@

$MergeGlobal_System = @'
Tu reçois TROIS objets JSON :
- "sujets" : dictionnaire { "<numero>": [ {timecode,auteur,role,texte,segment_id}, ... ] } issu de la Passe 2A (référence factuelle)
- "reunion" : synthèse globale issue des segments (resume_global, themes, actions, etc.)
- "debrief" : complément issu du débrief expert (peut être null)

Objectif : produire un JSON global fusionné STRICTEMENT selon le schéma ci-dessous.

Règles impératives :
- Ne JAMAIS modifier, réécrire, résumer ni dédupliquer le contenu de "sujets" (il est fourni à titre d’ancrage).
- La sortie NE DOIT PAS contenir le champ "sujets".
- Priorité à "reunion" en cas de conflit ; compléter avec "debrief" si information absente.
- Ne jamais inventer de timecodes ; si un thème vient du débrief uniquement : "timecodes": [].
- Pas d’invention : si incertain → null / [] / "".
- Sortie : UNIQUEMENT du JSON strict, commençant par { et finissant par }.

Schéma de sortie :
{
  "resume_global":"string",
  "themes":[{"titre":"string","synthese":["string"],"timecodes":["HH:MM:SS","..."]}],
  "themes_abordes":[{"titre":"string","synthese":["string","..."],"indices_source":[{"timecode":"HH:MM:SS","speaker":"string|null","extrait":"string"}]}],
  "actions":[{"action":"string","responsable":"string|null","echeance":"YYYY-MM-DD | null","commentaire":"string|null"}],
  "perspectives":["string","..."],
  "demandes_documents_globales":[{"objet":"string","demandeur":"string|null","destinataire":"string|null","echeance":"YYYY-MM-DD|null","timecodes":["HH:MM:SS","..."]}],
  "problems":[{"probleme":"string","solution":"string|null"}],
  "annexes":["string","..."]
}
'@


function Get-IntelligentSegments {
    param(
        $rows,
        $colTime,
        $colSpeaker,
        $colText,
        $logPath,
        [int] $ChunkSize = 30   # valeur par défaut
    )

    $segments = New-Object System.Collections.Generic.List[object]

    $total = $rows.Count
    if ($total -eq 0) {
        return @()
    }

    $i = 0
    while ($i -lt $total) {
        $j = [math]::Min($i + $ChunkSize - 1, $total - 1)

        $segmentRows = $rows[$i..$j]
        $segments.Add($segmentRows) | Out-Null

        $i = $j + 1
    }

    if ($logPath) {
        $txt = "Segments (ChunkSize=$ChunkSize) générés : $($segments.Count)"
        [System.IO.File]::WriteAllText($logPath, $txt, [System.Text.Encoding]::UTF8)
    }

    return $segments
}

# passe 0 
# ── Lecture CSV + segmentation ────────────────────────────────────────────────
if(!(Test-Path $CsvPath)){ throw "CSV introuvable: $CsvPath" }
Ensure-Dir $OutDir; Ensure-Dir (Join-Path $OutDir "segments"); Ensure-Dir (Join-Path $OutDir "logs")
$logsDir = Join-Path $OutDir "logs"
Ensure-Dir $logsDir
$logFile = Join-Path $logsDir ("run_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")
$txt = "Start: $(Get-Date)"
[System.IO.File]::WriteAllText($logFile, $txt, [System.Text.Encoding]::UTF8)


Write-Info "Lecture CSV: $CsvPath"

# passe 0+1 technique

$rows = Import-Csv -Path $CsvPath -Delimiter ';'
# Détection forcée (beaucoup plus robuste)
$colSpeaker = 'speaker'
$colTime    = 'start'
$colText    = 'text'
$colEnd     = 'end'


if(-not $colSpeaker -or -not $colTime -or -not $colText){
    throw "Colonnes attendues : start / end / speaker / text (au minimum start, speaker, text)."
}

$rows = $rows | ForEach-Object { $_ | Add-Member -NotePropertyName __sec -NotePropertyValue (Hms-To-Seconds $_.$colTime) -Force; $_ } | Sort-Object __sec
if($rows.Count -eq 0){ throw "CSV vide." }

# ── Segmentation intelligente enrichie ─────────────────────────────────────────

# Choix de ChunkSize en fonction du mode (local vs remote Passe 1A)
if ($Provider -ieq "openai" -and $ModelPass1 -eq "annoter_segments_remote") {
    $ChunkSize = 60    # remote : segments plus gros
} else {
    $ChunkSize = 25    # local : segments plus petits
}

$segLog  = Join-Path $logsDir "segments_debug.log"
$segments = Get-IntelligentSegments `
    -rows       $rows `
    -colTime    $colTime `
    -colSpeaker $colSpeaker `
    -colText    $colText `
    -logPath    $segLog `
    -ChunkSize  $ChunkSize

Write-Info ("Nombre de segments (ChunkSize={0}) : {1}" -f $ChunkSize, $segments.Count)
if($SegDebug){ Write-Info ("Log segmentation → $segLog") }

# ── Passe 1A : mini-CR par segment (JSON strict) ───────────────────────────────
$segmentJsonPaths = New-Object System.Collections.Generic.List[object]

for($i=0; $i -lt $segments.Count; $i++){
    $seg = $segments[$i]
    $segOut = Join-Path $OutDir ("segments/segment_{0:D2}.json" -f ($i+1))
    $startH = Seconds-To-Hms ($seg[0].__sec)
    $endH   = Seconds-To-Hms ($seg[-1].__sec)

    if((Test-Path $segOut) -and (-not $Force)){
        Write-Info "Skip segment $($i+1) (existe) → $segOut"
        $segmentJsonPaths.Add($segOut)
        continue
    }

    Write-Info ("Passe 1A → Segment {0:D2}  [{1} → {2}]" -f ($i+1), $startH, $endH)

    # Construction du prompt utilisateur brut
    $lines = $seg | ForEach-Object {
        "[{0}] {1}: {2}" -f $_.$colTime, $_.$colSpeaker, $_.$colText
    } | Out-String

    $sujetsJson       = ($Sujets | ConvertTo-Json -Depth 10)
    $participantsJson = ($Participants | ConvertTo-Json -Depth 10)

    $userPrompt = $Pass1_User_Template.
        Replace("{START_HMS}", $startH).
        Replace("{END_HMS}",   $endH).
        Replace("{LINES}",     $lines.Trim()).
        Replace("{SEGMENT_ID}", ("segment_{0:D2}" -f ($i+1))).
        Replace("{SUJETS_JSON}", $sujetsJson).
        Replace("{PARTICIPANTS_JSON}", $participantsJson)

    # Logs
    [System.IO.File]::WriteAllText(($segOut + ".prompt.txt"),  $userPrompt,   [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText(($segOut + ".system.txt"),  $Pass1_System, [System.Text.Encoding]::UTF8)


    # Contrôle n_ctx
    $userPrompt_Effective = Enforce-ContextLimit `
        -SystemPrompt $Pass1_System `
        -UserPrompt   $userPrompt `
        -Label        ("segment {0:D2}" -f ($i+1)) `
        -LogFile      $logFile `
        -ModelName    $ModelPass1

    [System.IO.File]::WriteAllText(
        ($segOut + ".prompt_effective.txt"),
        $userPrompt_Effective,
        [System.Text.Encoding]::UTF8
    )
#-----------------------------
    # Appel LLM
    #-----------------------------
    # Appel LLM
    $raw = $null
    try {
      $raw = Invoke-LLM -system $Pass1_System -user $userPrompt_Effective -model $ModelPass1 -DebugHttp:$DebugHttp
    }
    catch {
      Write-Warn ("Segment {0:D2} : Invoke-LLM a échoué ({1}) → JSON minimal." -f ($i+1), $_.Exception.Message)

      $jsonStr = @'
{
  "segment_id": "segment_{0:D2}",
  "sujets": {}
}
'@ -f ($i+1)

      [System.IO.File]::WriteAllText(
          $segOut,
          $jsonStr,
          [System.Text.Encoding]::UTF8
      )
      

      $segmentJsonPaths.Add($segOut)
      ("Segment {0:D2} FORCÉ (Invoke-LLM KO)" -f ($i+1)) | Add-Content $logFile
      continue
    }

    [System.IO.File]::WriteAllText(
        ($segOut + ".raw.txt"),
        $raw,
        [System.Text.Encoding]::UTF8
    )

    # Garde-fou : réponse vide
    if (-not $raw -or $raw.Trim() -eq "") {
      Write-Warn ("Segment {0:D2} : réponse vide → JSON minimal." -f ($i+1))

      $jsonStr = @'
{
  "segment_id": "segment_{0:D2}",
  "sujets": {}
}
'@ -f ($i+1)

      [System.IO.File]::WriteAllText(
          $segOut,
          $jsonStr,
          [System.Text.Encoding]::UTF8
      )      
      $segmentJsonPaths.Add($segOut)
      ("Segment {0:D2} FORCÉ (réponse vide)" -f ($i+1)) | Add-Content $logFile
      continue
    }

    # Parsing robuste JSON
    try {
        $obj = Parse-LlmJsonStrict -RawText $raw -Label ("segment {0:D2}" -f ($i+1)) -LogFile $logFile

        if (-not $obj.PSObject.Properties['segment_id']) {
            $obj | Add-Member -NotePropertyName segment_id -NotePropertyValue ("segment_{0:D2}" -f ($i+1))
        }

        if (-not $obj.PSObject.Properties['sujets']) {
            $obj | Add-Member -NotePropertyName sujets -NotePropertyValue @{}
        }

        $jsonStr = $obj | ConvertTo-Json -Depth 50
    }
    catch {
        Write-Err ("JSON invalide segment {0:D2}; fallback minimal." -f ($i+1))
        [System.IO.File]::WriteAllText(
            ($segOut + ".raw_fallback.txt"),
            $raw,
            [System.Text.Encoding]::UTF8
        )
        
        $jsonStr = @'
{
  "segment_id": "segment_{0:D2}",
  "sujets": {}
}
'@ -f ($i+1)
    }

    # Commun succès / fallback
    [System.IO.File]::WriteAllText(
        $segOut,
        $jsonStr,
        [System.Text.Encoding]::UTF8
    )
    
    $segmentJsonPaths.Add($segOut)
    ("Segment {0:D2} OK" -f ($i+1)) | Add-Content $logFile 
}



# fin passe 1A et début passe 1B



# ── Passe 1B : analyse du débrief expert (optionnelle) ────────────────────────
$DebriefObj = $null

if ($CsvDebriefPath) {
    Write-Info "Passe 1B → Analyse du débrief expert : $CsvDebriefPath"

    if (!(Test-Path $CsvDebriefPath)) {
        Write-Warn "CsvDebriefPath indiqué mais fichier introuvable : $CsvDebriefPath"
    }
    else {
        # On suppose les mêmes colonnes : start / speaker / text
        $rowsDebrief = Import-Csv -Path $CsvDebriefPath -Delimiter ';'

        $debriefColTime    = 'start'
        $debriefColSpeaker = 'speaker'
        $debriefColText    = 'text'

        # Vérif minimale
        if (-not $rowsDebrief -or $rowsDebrief.Count -eq 0) {
            Write-Warn "Débrief : CSV vide, aucune analyse effectuée."
        }
        else {
            # On ajoute un tri temporel si timecode dispo
            if ($rowsDebrief[0].PSObject.Properties[$debriefColTime]) {
                $rowsDebrief = $rowsDebrief | ForEach-Object {
                    $_ | Add-Member -NotePropertyName __sec -NotePropertyValue (Hms-To-Seconds $_.$debriefColTime) -Force; $_
                } | Sort-Object __sec
            }

            # Construction des lignes de débrief
            $debriefLines = $rowsDebrief | ForEach-Object {
                if ($_.PSObject.Properties[$debriefColSpeaker]) {
                    "[{0}] {1}: {2}" -f $_.$debriefColTime, $_.$debriefColSpeaker, $_.$debriefColText
                }
                else {
                    "[{0}] {1}" -f $_.$debriefColTime, $_.$debriefColText
                }
            } | Out-String

            $sujetsJson = $Sujets | ConvertTo-Json -Depth 10

            $debriefUser = $Debrief_User_Template.
                Replace("{SUJETS_JSON}",   $sujetsJson).
                Replace("{DEBRIEF_LINES}", $debriefLines.Trim())

            # Log input brut
            $debriefPromptPath = Join-Path $logsDir "debrief_prompt.txt"
            $debriefSystemPath = Join-Path $logsDir "debrief_system.txt"

            [System.IO.File]::WriteAllText(
                $debriefPromptPath,
                $debriefUser,
                [System.Text.Encoding]::UTF8
            )

            [System.IO.File]::WriteAllText(
                $debriefSystemPath,
                $Debrief_System,
                [System.Text.Encoding]::UTF8
            )
            # Contrôle n_ctx
            $debriefUser_Effective = Enforce-ContextLimit `
                -SystemPrompt $Debrief_System `
                -UserPrompt   $debriefUser `
                -Label        "Debrief expert" `
                -LogFile      $logFile `
                -ModelName    $ModelPass3

            $debriefEffPath = Join-Path $logsDir "debrief_prompt_effective.txt"
            [System.IO.File]::WriteAllText(
                $debriefEffPath,
                $debriefUser_Effective,
                [System.Text.Encoding]::UTF8
            )

            # Appel LLM (on utilise le modèle "remote" de passe 3 pour ce travail global)
            $debriefRaw = Invoke-LLM -system $Debrief_System -user $debriefUser_Effective -model $ModelReport -DebugHttp:$DebugHttp
            [System.IO.File]::WriteAllText(
                (Join-Path $logsDir "debrief_raw.txt"),
                $debriefRaw,
                [System.Text.Encoding]::UTF8
            ) 

            try {
                $DebriefObj = Parse-LlmJsonStrict -RawText $debriefRaw -Label "Debrief" -LogFile $logFile
            }
            catch {
                Write-Warn "Échec parsing JSON Débrief, fallback sujet/demandes vides."
                $DebriefObj = [pscustomobject]@{
                    sujets                       = @()
                    demandes_documents_hors_sujet = @()
                }
            }

            # Normalisation du schéma
            if (-not $DebriefObj.PSObject.Properties['sujets']) {
                $DebriefObj | Add-Member -NotePropertyName sujets -NotePropertyValue @()
            }
            if (-not $DebriefObj.PSObject.Properties['demandes_documents_hors_sujet']) {
                $DebriefObj | Add-Member -NotePropertyName demandes_documents_hors_sujet -NotePropertyValue @()
            }

            # Sauvegarde JSON debrief
            $debriefJson = $DebriefObj | ConvertTo-Json -Depth 50
            $debriefPath = Join-Path $OutDir "debrief.json"
            [System.IO.File]::WriteAllText(
                $debriefPath,
                $debriefJson,
                [System.Text.Encoding]::UTF8
            )

            Write-Info "Débrief expert analysé → $debriefPath"

            # On garde aussi en global pour éventuelle réutilisation en Passe 3
            $Global:DebriefObj = $DebriefObj
        }
    }
}
else {
    Write-Info "Passe 1B ignorée (aucun CsvDebriefPath fourni)."
}


# ── Passe 2A : agrégation par sujet (JSON strict) ─────────────────────────────
Write-Info "Passe 2A → Agrégation par sujet"

# Chargement de tous les segments JSON produits en Passe 1
$segmentsObjs = @()
foreach ($p in $segmentJsonPaths) {
    try {
        $obj = Get-Content $p -Raw | ConvertFrom-Json -Depth 50
        if ($obj) {
            $segmentsObjs += $obj
        }
    }
    catch {
        Write-Warn "JSON invalide ignoré : $p"
    }
}

if (-not $segmentsObjs -or $segmentsObjs.Count -eq 0) {
    throw "Passe 2A : aucun segment exploitable (segmentsObjs vide)."
}

# Agrégation par numéro de sujet
$bySujet = Aggregate-Sujets -Segments $segmentsObjs

# Construction du JSON global : dictionnaire numero_sujet -> liste d'interventions
$globalObj = [pscustomobject]@{
    sujets = $bySujet  # ex: "1" -> [ {segment_id, timecode, auteur, role, texte}, ... ]
}

$globalJson = $globalObj | ConvertTo-Json -Depth 50
$globalPath = Join-Path $OutDir "global.json"
[System.IO.File]::WriteAllText(
    $globalPath,
    $globalJson,
    [System.Text.Encoding]::UTF8
)

$Global:logsDir = $logsDir
Write-Info "Agrégation Passe 2A OK → $globalPath"

# --- Split global.json -> 70 fichiers (1 par sujet) ---
$splitDir = Join-Path $OutDir "sujets"
Ensure-Dir $splitDir

$py = "python"   # ou chemin complet vers python.exe
$scriptSplit = Join-Path $PSScriptRoot "split_by_sujet.py"

& $py $scriptSplit --global $globalPath --sujets $SujetsPath --out $splitDir --debrief (Join-Path $OutDir "debrief.json")



#-------------------------------------------------------------------------
# ── Passe 2B : construire le global "réunion" PAR BATCHS de segments ─────────
#-------------------------------------------------------------------------

Write-Info "Passe 2B → Construction du GLOBAL réunion (par batches de $Pass2BatchSize segments)"

$pass2BDir = Join-Path $OutDir "pass2B_batches"
New-Item -ItemType Directory -Force -Path $pass2BDir | Out-Null

# ---- Helpers (tolérance JSON / types) ---------------------------------


function Normalize-MeetingBatchObj {
  param([object] $o)

  if (-not $o) {
    return [pscustomobject]@{
      resume_global              = ""
      themes                     = @()
      themes_abordes             = @()
      actions                    = @()
      perspectives               = @()
      demandes_documents_globales= @()
      problems                   = @()
    }
  }

  if (-not $o.PSObject.Properties['resume_global']) {
    $o | Add-Member -Force NoteProperty resume_global ""
  }
  $o.resume_global = [string]$o.resume_global

  Ensure-List $o "themes"
  Ensure-List $o "themes_abordes"
  Ensure-List $o "actions"
  Ensure-List $o "perspectives"
  Ensure-List $o "demandes_documents_globales"
  Ensure-List $o "problems"

  return $o
}

function Merge-ListUnique {
  param([object[]]$Lists)

  $acc  = New-Object System.Collections.Generic.List[object]
  $seen = @{}

  foreach ($lst in $Lists) {
    if ($null -eq $lst) { continue }

    $items = @()

    if ($lst -is [string]) {
      $s = $lst.Trim()
      if ($s) { $items = @($s) } else { continue }
    }
    elseif ($lst -is [System.Collections.IDictionary]) {
      $items = @($lst)
    }
    elseif ($lst -is [pscustomobject]) {
      $items = @($lst)
    }
    elseif ($lst -is [System.Collections.IEnumerable]) {
      $items = @($lst)
    }
    else {
      $items = @($lst)
    }

    foreach ($it in $items) {
      if ($null -eq $it) { continue }

      $k = $null
      try { $k = ($it | ConvertTo-Json -Depth 50 -Compress) }
      catch { $k = ($it | Out-String).Trim() }

      if (-not $seen.ContainsKey($k)) {
        $seen[$k] = $true
        $acc.Add($it) | Out-Null
      }
    }
  }

  return ,$acc.ToArray()
}

# ---- 1) Construire la liste des objets segments (depuis les fichiers JSON existants)

$segmentObjs = @()
foreach ($p in $segmentJsonPaths) {
  try {
    $txt = Get-Content $p -Raw
    $o   = $txt | ConvertFrom-Json -Depth 50
    if ($o) { $segmentObjs += $o }
  } catch {
    Write-Warn "Pass2B: segment illisible/JSON invalide: $p (skip)"
  }
}

# ---- 2) Cas sans segments : global_meeting vide conforme

if (-not $segmentObjs -or $segmentObjs.Count -eq 0) {
  Write-Warn "Pass2B: aucun segment exploitable. Fallback globalMeeting vide."
  $globalMeetingObj = Normalize-MeetingBatchObj $null
}
else {

  # ---- 3) Traitement par batches

  $batchCount = [math]::Ceiling($segmentObjs.Count / [double]$Pass2BatchSize)
  $batchPaths = New-Object System.Collections.Generic.List[object]

  for ($b = 0; $b -lt $batchCount; $b++) {

    $from = $b * $Pass2BatchSize
    $to   = [math]::Min($from + $Pass2BatchSize - 1, $segmentObjs.Count - 1)
    $batchIndex = $b + 1

    $batchOut   = Join-Path $pass2BDir ("pass2B_batch_{0:D2}.json" -f $batchIndex)
    $batchBase  = Join-Path $pass2BDir ("pass2B_batch_{0:D2}" -f $batchIndex)
    $promptPath = "${batchBase}_prompt.txt"
    $systemPath = "${batchBase}_system.txt"
    $rawPath    = "${batchBase}_raw.txt"
    $metaPath   = "${batchBase}_meta.json"
    $errorPath  = "${batchBase}_error.txt"

    if ((Test-Path $batchOut) -and (-not $Force)) {
      Write-Info "Pass2B: skip batch $batchIndex (existe) → $batchOut"
      $batchPaths.Add($batchOut) | Out-Null
      continue
    }

    Write-Info ("Pass2B → Batch {0:D2}/{1} (segments {2}..{3})" -f $batchIndex, $batchCount, ($from+1), ($to+1))

    $batchSeg     = $segmentObjs[$from..$to]
    $batchSegJson = $batchSeg | ConvertTo-Json -Depth 50 -Compress
    $pass2BUser   = $Pass2B_User_Template.Replace("{SEGMENTS_JSON}", $batchSegJson)

    $pass2BUser_Effective = Enforce-ContextLimit `
      -SystemPrompt $Pass2B_System `
      -UserPrompt   $pass2BUser `
      -Label        ("Pass2B batch {0:D2}" -f $batchIndex) `
      -LogFile      $logFile `
      -ModelName    $ModelReport

    [System.IO.File]::WriteAllText($promptPath, $pass2BUser_Effective, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($systemPath, $Pass2B_System,       [System.Text.Encoding]::UTF8)

    $meta = [pscustomobject]@{
      batch     = $batchIndex
      segments  = "{0}..{1}" -f ($from+1), ($to+1)
      model     = $ModelReport
      apiBase   = $ApiBase
      timestamp = (Get-Date).ToString("o")
    }
    [System.IO.File]::WriteAllText($metaPath, ($meta | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)

    $batchObj = $null
    $raw      = $null

    try {
      $raw = Invoke-LLM -system $Pass2B_System -user $pass2BUser_Effective -model $ModelReport -DebugHttp:$DebugHttp
      if (-not $raw -or $raw.Trim().Length -eq 0) { throw "Réponse LLM vide" }
      [IO.File]::WriteAllText($rawPath, $raw, [Text.Encoding]::UTF8)
    }
    catch {
      $errTxt = ($_ | Out-String)
      [IO.File]::WriteAllText($errorPath, $errTxt, [Text.Encoding]::UTF8)
      [IO.File]::WriteAllText($rawPath,   $errTxt, [Text.Encoding]::UTF8)  # trace dans raw
      Write-Warn "Pass2B batch ${batchIndex}: échec Invoke-LLM (voir ${errorPath})."
      $raw = $null
    }

    if ($raw) {
      try {
        $batchObj = Parse-LlmJsonStrict -RawText $raw -Label ("Pass2B batch {0:D2}" -f $batchIndex) -LogFile $logFile
      }
      catch {
        $errTxt = ($_ | Out-String)
        [IO.File]::WriteAllText($errorPath, $errTxt, [Text.Encoding]::UTF8)
        Write-Warn "Pass2B batch ${batchIndex}: JSON non parsable (voir ${errorPath})."
        $batchObj = $null
      }
    }

    # Tolérance maximale : une seule rubrique suffit
    $batchObj = Normalize-MeetingBatchObj $batchObj

    $json = $batchObj | ConvertTo-Json -Depth 50
    [System.IO.File]::WriteAllText($batchOut, $json, [System.Text.Encoding]::UTF8)
    $batchPaths.Add($batchOut) | Out-Null
  }

  # ---- 4) Fusion finale des batches

  $allBatchObjs = @()
  foreach ($bp in $batchPaths) {
    try {
      $o = (Get-Content $bp -Raw) | ConvertFrom-Json -Depth 50
      $o = Normalize-MeetingBatchObj $o
      $allBatchObjs += $o
    } catch {
      Write-Warn "Pass2B: batch illisible: $bp (skip). Détail: $($_.Exception.Message)"
    }
  }

  # resume_global : choisir le plus long non vide
  $resumes = @($allBatchObjs | ForEach-Object { $_.resume_global } | Where-Object { $_ -and $_.Trim() -ne "" })
  $resumeBest = ""
  if ($resumes.Count -gt 0) {
    $resumeBest = ($resumes | Sort-Object Length -Descending | Select-Object -First 1)
  }

  $globalMeetingObj = [pscustomobject]@{
    resume_global              = $resumeBest
    themes                     = Merge-ListUnique ($allBatchObjs | ForEach-Object { $_.themes })
    themes_abordes             = Merge-ListUnique ($allBatchObjs | ForEach-Object { $_.themes_abordes })
    actions                    = Merge-ListUnique ($allBatchObjs | ForEach-Object { $_.actions })
    perspectives               = Merge-ListUnique ($allBatchObjs | ForEach-Object { $_.perspectives })
    demandes_documents_globales= Merge-ListUnique ($allBatchObjs | ForEach-Object { $_.demandes_documents_globales })
    problems                   = Merge-ListUnique ($allBatchObjs | ForEach-Object { $_.problems })
  }
}

# ---- 5) Sauvegarde global_meeting.json

$globalMeetingPath = Join-Path $OutDir "global_meeting.json"
$json = $globalMeetingObj | ConvertTo-Json -Depth 50
[System.IO.File]::WriteAllText($globalMeetingPath, $json, [System.Text.Encoding]::UTF8)

Write-Info "GLOBAL réunion → $globalMeetingPath"


# -----------------------------------------------------------------------
# ── Passe 3 : JSON FINAL normalisé (enrichissement progressif) 
# -----------------------------------------------------------------------

Write-Info "Passe 3 → JSON FINAL (enrichissement progressif)"
Ensure-Dir $logsDir

$sujetsJson       = $Sujets       | ConvertTo-Json -Depth 10
$participantsJson = $Participants | ConvertTo-Json -Depth 10

$debriefJson = "null"
if ($Global:DebriefObj) { $debriefJson = $Global:DebriefObj | ConvertTo-Json -Depth 50 }

$debriefGlobal = $null
if ($Global:DebriefObj -and $Global:DebriefObj.PSObject.Properties['global_debrief']) {
  $debriefGlobal = $Global:DebriefObj.global_debrief
}

# Fallback “réunion”
$fallbackMeetingObj = $globalMeetingObj
if (-not $fallbackMeetingObj) {
  $fallbackMeetingObj = [pscustomobject]@{
    resume_global = ""
    themes = @()
    themes_abordes = @()
    actions = @()
    perspectives = @()
    demandes_documents_globales = @()
    problems = @()
    annexes = @()
  }
}

# ---- MergeGlobal (objet) ----
$globalMeetingMerged = $null

try {
  $mergeInput = [pscustomobject]@{
    sujets  = (Get-Content $globalPath -Raw | ConvertFrom-Json -Depth 50).sujets
    reunion = $fallbackMeetingObj
    debrief = $debriefGlobal
  }

  $mergeUser = $mergeInput | ConvertTo-Json -Depth 50
  [IO.File]::WriteAllText((Join-Path $logsDir "mergeGlobal_input.json"), $mergeUser, [Text.Encoding]::UTF8)

  $mergeRaw = Invoke-LLM -system $MergeGlobal_System -user $mergeUser -model $ModelPass3 -DebugHttp:$DebugHttp
  $mergeRaw = Unwrap-AdapterText $mergeRaw


  if (-not $mergeRaw -or $mergeRaw.Trim().Length -eq 0) {
    [IO.File]::WriteAllText((Join-Path $logsDir "mergeGlobal_raw.txt"), "EMPTY_MERGE_RAW", [Text.Encoding]::UTF8)
    throw "MergeGlobal: réponse vide"
  } else {
    [IO.File]::WriteAllText((Join-Path $logsDir "mergeGlobal_raw.txt"), $mergeRaw, [Text.Encoding]::UTF8)
  }

  $mergeObj = Parse-LlmJsonStrict -RawText $mergeRaw -Label "MergeGlobal" -LogFile $logFile
  if (-not $mergeObj) { throw "MergeGlobal: Parse-LlmJsonStrict returned null" }

  # Normalisation minimale (recommandée)
  if (-not $mergeObj.PSObject.Properties["resume_global"]) {
    $mergeObj | Add-Member -Force -NotePropertyName resume_global -NotePropertyValue ""
  } else {
    $mergeObj.resume_global = ([string]$mergeObj.resume_global).Trim()
  }

  $need = @("themes","themes_abordes","actions","perspectives","demandes_documents_globales","problems","annexes")
  foreach ($k in $need) {
    if (-not $mergeObj.PSObject.Properties[$k] -or $null -eq $mergeObj.$k) {
      $mergeObj | Add-Member -Force -NotePropertyName $k -NotePropertyValue @()
    } elseif ($mergeObj.$k -is [string]) {
      $mergeObj.$k = if ($mergeObj.$k.Trim()) { @($mergeObj.$k.Trim()) } else { @() }
    } elseif ($mergeObj.$k -is [System.Collections.IDictionary]) {
      $mergeObj.$k = @($mergeObj.$k)
    } elseif ($mergeObj.$k -is [object[]] -or $mergeObj.$k -is [System.Collections.IList]) {
      # ok
    } else {
      $mergeObj.$k = @($mergeObj.$k)
    }
  }

  $globalMeetingMerged = $mergeObj  # ✅ objet
}
catch {
  Write-Warn "MergeGlobal: échec LLM/JSON ($_). Fallback = globalMeeting."
  $globalMeetingMerged = $fallbackMeetingObj  # ✅ objet
}

# JSON prêt pour Pass 3A/3B/3C/3D
$globalMeetingMergedJson = $globalMeetingMerged | ConvertTo-Json -Depth 50
# Pass3 doit consommer global.json (agrégation par sujets)
if (-not (Test-Path $globalPath)) { throw "globalPath introuvable: $globalPath" }

$globalRawJson = Get-Content $globalPath -Raw


# Debrief : si présent (Passe 1B), on le sérialise ; sinon on met "null"
# 1) (optionnel) log du prompt brut (avant troncature)
$pass3User = $Pass3_User_Template.
    Replace("{GLOBAL_JSON}",       $globalRawJson).
    Replace("{SUJETS_JSON}",       $sujetsJson).
    Replace("{PARTICIPANTS_JSON}", $participantsJson).
    Replace("{DEBRIEF_JSON}",      $debriefJson)

# 2) prompt effectif (après Truncate-For-Context)
$pass3User_Effective = Truncate-For-Context `
  -SystemText $Pass3_System `
  -UserText   $pass3User `
  -ModelName  $ModelPass3

# 3) log du prompt effectivement envoyé au LLM
$path = Join-Path $logsDir "pass3_prompt_effective.txt"
[System.IO.File]::WriteAllText(
    $path,
    $pass3User_Effective,
    [System.Text.Encoding]::UTF8
)

$finalObj = $null
$pass3Raw = $null

try {
  $pass3Raw = Invoke-LLM -system $Pass3_System -user $pass3User_Effective -model $ModelPass3 -DebugHttp:$DebugHttp
  $pass3Raw  = Unwrap-AdapterText $pass3Raw
  if ($pass3Raw) {
    $path = Join-Path $logsDir "pass3_raw.txt"
    [System.IO.File]::WriteAllText(
        $path,
        $pass3Raw,
        [System.Text.Encoding]::UTF8
    )

  }

  $finalObj = Parse-LlmJsonStrict -RawText $pass3Raw -Label "Pass3" -LogFile $logFile
}
catch {
  Write-Warn "Pass3: échec LLM/JSON ($_). Fallback."
  $finalObj = [pscustomobject]@{
    sujets             = @()
    tous_sujets_traites = $false
    sujets_manquants   = @()
  }
}

# Normalisation stricte : garantir les champs racine attendus
if (-not $finalObj.PSObject.Properties['sujets']) {
  $finalObj | Add-Member -Force -NotePropertyName sujets -NotePropertyValue @()
}
if (-not $finalObj.PSObject.Properties['tous_sujets_traites']) {
  $finalObj | Add-Member -Force -NotePropertyName tous_sujets_traites -NotePropertyValue $false
}
if (-not $finalObj.PSObject.Properties['sujets_manquants']) {
  $finalObj | Add-Member -Force -NotePropertyName sujets_manquants -NotePropertyValue @()
}

# (1) Construire la map Numero -> Titre (trim + sécurité)
$SujetTitreByNumero = @{}
foreach ($sj in $Sujets) {
  $k = ([string]$sj.Numero).Trim()
  $v = ([string]$sj.Titre).Trim()
  if ($k -ne "") { $SujetTitreByNumero[$k] = $v }
}

# (2) Replaquer les titres sur la sortie LLM (si possible, sans planter si structure inattendue)
if ($finalObj -and $finalObj.sujets) {
  foreach ($s in $finalObj.sujets) {

    # sécurité : si pas de champ numero, on saute
    if (-not $s.PSObject.Properties['numero']) { continue }

    $k = ([string]$s.numero).Trim()
    if ($SujetTitreByNumero.ContainsKey($k) -and $SujetTitreByNumero[$k]) {
      $s.titre = $SujetTitreByNumero[$k]
    }
    elseif (-not $s.PSObject.Properties['titre'] -or [string]::IsNullOrWhiteSpace([string]$s.titre)) {
      $s.titre = ("Sujet " + $k)
    }
  }
}

# 3A : métadonnées + résumé + ordre du jour
Write-Info "Passe 3A → date / link / resume / ordre_du_jour"


$pass3AUser = $Pass3A_User_Template.Replace("{GLOBAL_JSON}", $globalMeetingMergedJson)


# log prompt brut
$path = Join-Path $logsDir "pass3A_input.txt"
[System.IO.File]::WriteAllText(
    $path,
    $pass3AUser,
    [System.Text.Encoding]::UTF8
)


# contrôle n_ctx / max_tokens (Pass 3A)
$pass3AUser_Effective = Truncate-For-Context `
  -SystemText $Pass3A_System `
  -UserText   $pass3AUser `
  -ModelName  $ModelPass3

# log prompt effectif
$path = Join-Path $logsDir "pass3A_input_effective.txt"
[System.IO.File]::WriteAllText(
    $path,
    $pass3AUser_Effective,
    [System.Text.Encoding]::UTF8
)

$partAObj  = $null
$pass3ARaw = $null

try {
  $pass3ARaw = Invoke-LLM -system $Pass3A_System -user $pass3AUser_Effective -model $ModelPass3 -DebugHttp:$DebugHttp
  $pass3ARaw = Unwrap-AdapterText $pass3ARaw
  if ($pass3ARaw) {
    $path = Join-Path $logsDir "pass3A_raw.txt"
    [System.IO.File]::WriteAllText(
        $path,
        $pass3ARaw,
        [System.Text.Encoding]::UTF8
    )

  }

  $partAObj = Parse-LlmJsonStrict -RawText $pass3ARaw -Label "Pass3A" -LogFile $logFile
}
catch {
  Write-Warn "Pass3A: échec LLM/JSON ($_). Fallback par défaut."
  $partAObj = [pscustomobject]@{
    date          = $null
    link          = $null
    resume        = ""
    ordre_du_jour = @()
  }
}

# Normalisation stricte (anti StrictMode)
if (-not $partAObj.PSObject.Properties['date'])          { $partAObj | Add-Member -Force -NotePropertyName date          -NotePropertyValue $null }
if (-not $partAObj.PSObject.Properties['link'])          { $partAObj | Add-Member -Force -NotePropertyName link          -NotePropertyValue $null }
if (-not $partAObj.PSObject.Properties['resume'])        { $partAObj | Add-Member -Force -NotePropertyName resume        -NotePropertyValue "" }
if (-not $partAObj.PSObject.Properties['ordre_du_jour']) { $partAObj | Add-Member -Force -NotePropertyName ordre_du_jour -NotePropertyValue @() }

# 3B : thèmes_abordes
Write-Info "Passe 3B → themes_abordes"

$pass3BUser = $Pass3B_User_Template.Replace("{GLOBAL_JSON}", $globalMeetingMergedJson)

# log prompt brut
$path = Join-Path $logsDir "pass3B_input.txt"
[System.IO.File]::WriteAllText(
    $path,
    $pass3BUser,
    [System.Text.Encoding]::UTF8
)

$pass3BUser_Effective = Truncate-For-Context `
  -SystemText $Pass3B_System `
  -UserText   $pass3BUser `
  -ModelName  $ModelPass3

# log prompt effectif
$path = Join-Path $logsDir "pass3B_input_effective.txt"
[System.IO.File]::WriteAllText(
    $path,
    $pass3BUser_Effective,
    [System.Text.Encoding]::UTF8
)

$partBObj  = $null
$pass3BRaw = $null

try {
  $pass3BRaw = Invoke-LLM -system $Pass3B_System -user $pass3BUser_Effective -model $ModelPass3 -DebugHttp:$DebugHttp
  $pass3BRaw = Unwrap-AdapterText $pass3BRaw
  if ($pass3BRaw) {
    $path = Join-Path $logsDir "pass3B_raw.txt"
    [System.IO.File]::WriteAllText(
        $path,
        $pass3BRaw,
        [System.Text.Encoding]::UTF8
    )
 
  }

  $partBObj = Parse-LlmJsonStrict -RawText $pass3BRaw -Label "Pass3B" -LogFile $logFile
}
catch {
  Write-Warn "Pass3B: échec LLM/JSON ($_). Fallback themes_abordes=[]."
  $partBObj = [pscustomobject]@{
    themes_abordes = @()
  }
}

# Normalisation stricte (anti StrictMode)
if (-not $partBObj.PSObject.Properties['themes_abordes']) {
  $partBObj | Add-Member -Force -NotePropertyName themes_abordes -NotePropertyValue @()
}
Ensure-List $partBObj "themes_abordes"

# 3C : actions / perspectives / annexes
Write-Info "Passe 3C → actions / perspectives / annexes"

$pass3CUser = $Pass3C_User_Template.Replace("{GLOBAL_JSON}", $globalMeetingMergedJson)


# log prompt brut
$path = Join-Path $logsDir "pass3C_input.txt"
[System.IO.File]::WriteAllText(
    $path,
    $pass3CUser,
    [System.Text.Encoding]::UTF8
)

$pass3CUser_Effective = Truncate-For-Context `
  -SystemText $Pass3C_System `
  -UserText   $pass3CUser `
  -ModelName  $ModelPass3

# log prompt effectif
$path = Join-Path $logsDir "pass3C_input_effective.txt"
[System.IO.File]::WriteAllText(
    $path,
    $pass3CUser_Effective,
    [System.Text.Encoding]::UTF8
)

$partCObj  = $null
$pass3CRaw = $null

try {
  $pass3CRaw = Invoke-LLM -system $Pass3C_System -user $pass3CUser_Effective -model $ModelPass3 -DebugHttp:$DebugHttp
  $pass3CRaw = Unwrap-AdapterText $pass3CRaw
  if ($pass3CRaw) {
    $path = Join-Path $logsDir "pass3C_raw.txt"
    [System.IO.File]::WriteAllText(
        $path,
        $pass3CRaw,
        [System.Text.Encoding]::UTF8
    )

  }

  $partCObj = Parse-LlmJsonStrict -RawText $pass3CRaw -Label "Pass3C" -LogFile $logFile
}
catch {
  Write-Warn "Pass3C: échec LLM/JSON ($_). Fallback actions/perspectives/annexes vides."
  $partCObj = [pscustomobject]@{
    actions      = @()
    perspectives = @()
    annexes      = @()
  }
}

# Normalisation stricte (anti StrictMode)
if (-not $partCObj.PSObject.Properties['actions']) {
  $partCObj | Add-Member -Force -NotePropertyName actions -NotePropertyValue @()
}
if (-not $partCObj.PSObject.Properties['perspectives']) {
  $partCObj | Add-Member -Force -NotePropertyName perspectives -NotePropertyValue @()
}
if (-not $partCObj.PSObject.Properties['annexes']) {
  $partCObj | Add-Member -Force -NotePropertyName annexes -NotePropertyValue @()
}
Ensure-List $partCObj "actions"
Ensure-List $partCObj "perspectives"
Ensure-List $partCObj "annexes"

# 3D : demandes de documents
Write-Info "Passe 3D → demandes de documents"


$pass3DUser = $Pass3D_User_Template.Replace("{GLOBAL_JSON}", $globalMeetingMergedJson)
$path = Join-Path $logsDir "pass3D_input.txt"
[System.IO.File]::WriteAllText(
    $path,
    $pass3DUser,
    [System.Text.Encoding]::UTF8
)


$pass3DUser_Effective = Truncate-For-Context `
  -SystemText $Pass3D_System `
  -UserText   $pass3DUser `
  -ModelName  $ModelPass3

$path = Join-Path $logsDir "pass3D_input_effective.txt"
[System.IO.File]::WriteAllText(
    $path,
    $pass3DUser_Effective,
    [System.Text.Encoding]::UTF8
)


$partDObj  = $null
$pass3DRaw = $null

try {
  $pass3DRaw = Invoke-LLM -system $Pass3D_System -user $pass3DUser_Effective -model $ModelPass3 -DebugHttp:$DebugHttp
  $pass3DRaw = Unwrap-AdapterText $pass3DRaw
  if ($pass3DRaw) {
    
    $path = Join-Path $logsDir "pass3D_raw.txt"
    [System.IO.File]::WriteAllText(
        $path,
        $pass3DRaw,
        [System.Text.Encoding]::UTF8
    )

  }

  $partDObj = Parse-LlmJsonStrict -RawText $pass3DRaw -Label "Pass3D" -LogFile $logFile
}
catch {
  Write-Warn "Pass3D: échec LLM/JSON ($_). Fallback demandes_documents_globales=[]."
  $partDObj = [pscustomobject]@{
    demandes_documents_globales = @()
  }
}

# Normalisation stricte (anti StrictMode)
if (-not $partDObj) {
  $partDObj = [pscustomobject]@{ demandes_documents_globales = @() }
}
if (-not $partDObj.PSObject.Properties['demandes_documents_globales']) {
  $partDObj | Add-Member -Force -NotePropertyName demandes_documents_globales -NotePropertyValue @()
}
if ($null -eq $partDObj.demandes_documents_globales) {
  $partDObj.demandes_documents_globales = @()
}
Ensure-List $partDObj "demandes_documents_globales"


# Helpers pour accéder aux propriétés en mode "tolérant"
function Get-PropOrNull {
    param(
        [object] $Obj,
        [string] $Name
    )

    if (-not $Obj) { return $null }

    $prop = $Obj.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }

    return $prop.Value
}

foreach ($s in $finalObj.sujets) {
    $num = $s.numero.ToString()

    # 1. Rattachement des demandes du débrief (si présentes)
    if ($Global:DebriefObj -and $Global:DebriefObj.sujets) {
        $match = $Global:DebriefObj.sujets | Where-Object { $_.numero -eq $s.numero } | Select-Object -First 1
        if ($match -and $match.PSObject.Properties['demandes_documents'] -and $match.demandes_documents) {
            if (-not $s.PSObject.Properties['demandes_documents']) {
                $s | Add-Member -NotePropertyName demandes_documents -NotePropertyValue @()
            }
            foreach ($d in $match.demandes_documents) {
                $new = $d | Select-Object *, @{ Name="origine"; Expression={ "debrief_expert" } }
                $s.demandes_documents += $new
            }
        }

    }

    # 2. Tentative de rattachement des demandes issues de la réunion
    if ($partDObj -and $partDObj.demandes_documents_globales) {
        foreach ($doc in $partDObj.demandes_documents_globales) {
            # heuristique minimaliste : rattachement par mot-clé dans l’objet
            if (
                $doc -and
                $doc.PSObject.Properties['objet'] -and
                $doc.objet -and
                ($doc.objet -imatch [regex]::Escape([string]$s.titre))
            ) {
                if (-not $s.PSObject.Properties['demandes_documents']) {
                    $s | Add-Member -NotePropertyName demandes_documents -NotePropertyValue @()
                }
                $new2 = $doc | Select-Object *, @{
                    Name="origine"; Expression={ "reunion" }
                }
                $s.demandes_documents += $new2
            }
        }
    }
}


# Ajout des demandes globales au JSON final

$ddg = @()
if ($partDObj -and $partDObj.PSObject.Properties['demandes_documents_globales']) {
    $ddg = $partDObj.demandes_documents_globales
}
$finalObj | Add-Member -Force -NotePropertyName demandes_documents_globales -NotePropertyValue $ddg


$finalLink          = Get-PropOrNull -Obj $partAObj -Name 'link'
$finalResume        = Get-PropOrNull -Obj $partAObj -Name 'resume'
$finalOrdreDuJour   = Get-PropOrNull -Obj $partAObj -Name 'ordre_du_jour'
$finalThemes        = Get-PropOrNull -Obj $partBObj -Name 'themes_abordes'
$finalActions       = Get-PropOrNull -Obj $partCObj -Name 'actions'
$finalPerspectives  = Get-PropOrNull -Obj $partCObj -Name 'perspectives'
$finalAnnexes       = Get-PropOrNull -Obj $partCObj -Name 'annexes'

$finalObj | Add-Member -Force -NotePropertyName link           -NotePropertyValue $finalLink
$finalObj | Add-Member -Force -NotePropertyName resume         -NotePropertyValue $finalResume
$finalObj | Add-Member -Force -NotePropertyName ordre_du_jour  -NotePropertyValue $finalOrdreDuJour
$finalObj | Add-Member -Force -NotePropertyName themes_abordes -NotePropertyValue $finalThemes
$finalObj | Add-Member -Force -NotePropertyName actions        -NotePropertyValue $finalActions
$finalObj | Add-Member -Force -NotePropertyName perspectives   -NotePropertyValue $finalPerspectives
$finalObj | Add-Member -Force -NotePropertyName annexes        -NotePropertyValue $finalAnnexes



$finalJson  = $finalObj | ConvertTo-Json -Depth 100
$finalPath  = Join-Path $OutDir "global_final.json"
[System.IO.File]::WriteAllText(
    $finalPath,
    $finalJson,
    [System.Text.Encoding]::UTF8
)

Write-Info "JSON FINAL → $finalPath"

"Done: $(Get-Date)" | Add-Content $logFile
Write-Info "Pipeline terminé (full JSON)."

