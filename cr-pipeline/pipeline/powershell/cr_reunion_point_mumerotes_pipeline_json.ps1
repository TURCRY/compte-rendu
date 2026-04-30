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
  [string] $ApiBase    = "http://openai-adapter:5055",  # OpenAI-compat: /v1/chat/completions
  [string] $OllamaBase = "http://localhost:11434",      # Ollama natif: /api/generate

  # Modèle "par défaut" (optionnel, compat)
  [string] $Model      = "annoter_segments_local",

  # Modèles par passe
  [string] $ModelPass1 = "annoter_segments_local",   # Passe 1 : segments → LOCAL + Passe 2A
  [string] $ModelPass2 = "report_remote",  # Passe 2 : fusion → REMOTE
  [string] $ModelPass2E = "annoter_segments_remote_alt",
  [string] $ModelPass3 = "pass3_remote",  # # Passes 3, 3A/B/C/D, MergeGlobal
  [string] $ModelPass3E = "pass3e_remote",  # Passe 3E : synthèse par sujet (LOCAL)
  # Modèle rédactionnel (2B / MergeGlobal UNIQUEMENT) 
  [string] $ModelReport = "report_remote",
  [string] $ModelPass3A = "pass3a_remote",
  [string] $ModelPass3B = "pass3b_remote",
  [string] $ModelPass3C = "pass3c_remote",
  [string] $ModelPass3D = "pass3d_remote",


  [string] $ApiKey     = "",
  [switch] $PseudonymizeRemote,
  [string] $PseudoApiBase = "",
  [string] $PseudoApiKey = "",
  [string] $PseudoJobId = "",
  [string] $PseudoParticipantsPath = "",

  # Segmentation : preset + debug
  [ValidateSet("conservateur","equilibre","agressif")] [string] $Preset = "equilibre",
  [switch] $DebugSeg,

  [switch] $DebugHttp,

  
  # Paramétrage Passe 2 (agrégation hiérarchique)
  [int] $Pass2BatchSize = 2,

  # Relance
  [switch] $RebuildFromPass2B,
  [switch] $RebuildPass2BOnly,
  [int[]] $OnlyPass2BBatches = @(),
  [switch] $Force

)
[bool] $HasOnlyPass2BBatches = ($OnlyPass2BBatches -and @($OnlyPass2BBatches).Count -gt 0)
if ($HasOnlyPass2BBatches -and (-not $RebuildFromPass2B)) {
  $RebuildFromPass2B = $true
}
[int]$ChunkSize = 30 # voir fonction Get-IntelligentSegments (nombre de ligne de transcription par segment

# Valeurs neutres pour éviter l’erreur en StrictMode
$logsDir = $null
$logFile = $null
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# Lecture des sujets numérotés (Excel)
# via ImportExcel module, ou CSV si tu convertis avant
# On attend par ex. colonnes : Numero, Titre
if (-not $SujetsPath) { throw "SujetsPath est obligatoire." }
if (-not (Test-Path $SujetsPath)) { throw "SujetsPath introuvable: $SujetsPath" }
if (-not $ParticipantsPath) { throw "ParticipantsPath est obligatoire." }
if (-not (Test-Path $ParticipantsPath)) { throw "ParticipantsPath introuvable: $ParticipantsPath" }

if ($SujetsPath) {
    $Sujets = Import-Excel -Path $SujetsPath
    $sujetsImportedCount = @($Sujets).Count
    Microsoft.PowerShell.Utility\Write-Host ("Référentiel sujets importé : {0} ligne(s)" -f $sujetsImportedCount)

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
    $sujetsNormalizedCount = @($Sujets).Count
    Microsoft.PowerShell.Utility\Write-Host ("Référentiel sujets après normalisation : {0} ligne(s)" -f $sujetsNormalizedCount)

    $sujetsTotal = @($Sujets).Count
    $Sujets = @($Sujets | Where-Object { $null -ne $_ -and [int]$_.Numero -gt 0 })
    $sujetsFilteredCount = @($Sujets).Count
    Microsoft.PowerShell.Utility\Write-Host ("Référentiel sujets après filtre Numero > 0 : {0} ligne(s)" -f $sujetsFilteredCount)
    $sujetsRetires = $sujetsTotal - @($Sujets).Count
    if ($sujetsRetires -gt 0) {
      Write-Warning ("R?f?rentiel sujets: {0} entr?e(s) <= 0 ignor?e(s) (sujet 0 supprim? en amont)." -f $sujetsRetires)
    }
    if (-not $Sujets -or @($Sujets).Count -eq 0) {
      throw "Référentiel sujets vide après lecture de Sujets.xlsx."
    }
}

# Map Numero -> Titre (référentiel)
$SujetTitreByNumero = @{}
foreach ($sj in $Sujets) {
  $k = ([string]$sj.Numero).Trim()
  $v = ([string]$sj.Titre).Trim()
  if ($k) { $SujetTitreByNumero[$k] = $v }
}


# Lecture des participants
if ($ParticipantsPath) {
    $Participants = Import-Excel -Path $ParticipantsPath
    # colonnes possibles : NomCanonique, Role, Alias1, Alias2...
}

# Ajustement initial de Pass2BatchSize (les batches tronqu?s seront relanc?s s?lectivement)
if (-not $PSBoundParameters.ContainsKey('Pass2BatchSize')) {
    if ($Provider -ieq "openai" -and ($ModelPass2 -like "*remote*")) {
        $Pass2BatchSize = 4
    } else {
        $Pass2BatchSize = 2
    }
}
if ($Pass2BatchSize -lt 1) {
    $Pass2BatchSize = 1
}


Microsoft.PowerShell.Utility\Write-Host "==== PARAMS PIPELINE ====" -ForegroundColor Cyan
Microsoft.PowerShell.Utility\Write-Host ("Provider       = {0}" -f $Provider)
Microsoft.PowerShell.Utility\Write-Host ("ApiBase        = {0}" -f $ApiBase)
Microsoft.PowerShell.Utility\Write-Host ("PseudonymizeRemote = {0}" -f $PseudonymizeRemote)
if ($PseudoApiBase) {
  Microsoft.PowerShell.Utility\Write-Host ("PseudoApiBase  = {0}" -f $PseudoApiBase)
}
if ($PseudonymizeRemote) {
  Microsoft.PowerShell.Utility\Write-Host ("PseudoApiKeyLen = {0}" -f $PseudoApiKey.Length)
  if ($PseudoParticipantsPath) {
    Microsoft.PowerShell.Utility\Write-Host ("PseudoParticipantsPath = {0}" -f $PseudoParticipantsPath)
  }
}
Microsoft.PowerShell.Utility\Write-Host ("Model          = {0}" -f $Model)
Microsoft.PowerShell.Utility\Write-Host ("ModelPass1     = {0}" -f $ModelPass1)
Microsoft.PowerShell.Utility\Write-Host ("ModelPass2     = {0}" -f $ModelPass2)
Microsoft.PowerShell.Utility\Write-Host ("ModelPass2E    = {0}" -f $ModelPass2E)
Microsoft.PowerShell.Utility\Write-Host ("ModelPass3     = {0}" -f $ModelPass3)
Microsoft.PowerShell.Utility\Write-Host ("ModelPass3E    = {0}" -f $ModelPass3E)
Microsoft.PowerShell.Utility\Write-Host ("ModelReport    = {0}" -f $ModelReport)
Microsoft.PowerShell.Utility\Write-Host ("Pass2BatchSize = {0}" -f $Pass2BatchSize)


if ($ApiKey) {
    Microsoft.PowerShell.Utility\Write-Host ("ApiKeyLen  = {0}" -f $ApiKey.Length)
} else {
    Microsoft.PowerShell.Utility\Write-Host "ApiKey     = (VIDE)" -ForegroundColor Yellow
}
Microsoft.PowerShell.Utility\Write-Host "=========================" -ForegroundColor Cyan

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
# Compteur de batchs Passe 2 (à mettre une seule fois, en dehors de la fonction)
[int] $script:Pass2BatchIndex = 0


function Write-Host($m){ Microsoft.PowerShell.Utility\Write-Host "[INFO]  $m" -ForegroundColor Cyan }
function Write-Warn($m){ Microsoft.PowerShell.Utility\Write-Host "[WARN]  $m" -ForegroundColor Yellow }
function Write-Err ($m){ Microsoft.PowerShell.Utility\Write-Host "[ERROR] $m" -ForegroundColor Red  }

function Assert-RemotePseudonymizationReady {
  param([string] $ModelName)

  if (-not $PseudonymizeRemote) { return }
  if ($Provider -ine "openai") { return }
  if (-not (([string]$ModelName).ToLower().Contains("remote"))) { return }
  if ([string]::IsNullOrWhiteSpace($PseudoApiBase)) {
    throw ("Pseudonymisation distante requise pour le modele '{0}' mais PseudoApiBase est vide." -f $ModelName)
  }
  if ([string]::IsNullOrWhiteSpace($PseudoApiKey)) {
    throw ("Pseudonymisation distante requise pour le modele '{0}' mais PseudoApiKey / LOCAL_LLM_API_KEY est absent." -f $ModelName)
  }
  if ([string]::IsNullOrWhiteSpace($PseudoJobId)) {
    throw ("Pseudonymisation distante requise pour le modele '{0}' mais PseudoJobId est absent." -f $ModelName)
  }
  if ([string]::IsNullOrWhiteSpace($PseudoParticipantsPath)) {
    throw ("Pseudonymisation distante requise pour le modele '{0}' mais PseudoParticipantsPath est absent." -f $ModelName)
  }
}

function Use-RemotePseudonymizationForModel {
  param([string] $ModelName)

  return (
    $PseudonymizeRemote -and
    $Provider -ieq "openai" -and
    -not [string]::IsNullOrWhiteSpace($PseudoApiBase) -and
    (([string]$ModelName).ToLower().Contains("remote"))
  )
}

function Get-PseudoResponseText {
  param(
    [object] $Response,
    [string] $PrimaryKey,
    [string] $FallbackText
  )

  if (-not $Response) { return $FallbackText }

  $prop = $Response.PSObject.Properties[$PrimaryKey]
  if ($prop -and -not [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
    return [string]$prop.Value
  }

  $prop = $Response.PSObject.Properties["text"]
  if ($prop -and -not [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
    return [string]$prop.Value
  }

  return $FallbackText
}

function Invoke-PseudoTransform {
  param(
    [string] $Route,
    [string] $Text,
    [string] $ModelName = ""
  )

  if (-not (Use-RemotePseudonymizationForModel -ModelName $ModelName)) { return $Text }
  if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }

  Assert-RemotePseudonymizationReady -ModelName $ModelName

  $uri = ($PseudoApiBase.TrimEnd('/')) + $Route
  $bodyObj = @{
    text = $Text
    participants_path = $PseudoParticipantsPath
    job_id = $PseudoJobId
    mode = "compte_rendu"
  }
  $body = $bodyObj | ConvertTo-Json -Depth 20 -Compress
  $headers = @{
    "x-api-key" = $PseudoApiKey
  }

  try {
    $resp = Invoke-RestMethod -Method POST -Uri $uri -Headers $headers -Body $body -ContentType "application/json" -TimeoutSec 300 -ErrorAction Stop
  }
  catch {
    throw ("Pseudo transform failed route={0} model={1} job_id={2}: {3}" -f $Route, $ModelName, $PseudoJobId, $_)
  }

  if ($Route -eq "/pseudonymize") {
    return (Get-PseudoResponseText -Response $resp -PrimaryKey "text_pseudonymized" -FallbackText $Text)
  }

  return (Get-PseudoResponseText -Response $resp -PrimaryKey "text_depseudonymized" -FallbackText $Text)
}

function Write-ArtifactText {
  param(
    [string] $Path,
    [string] $Text,
    [string] $ModelName = ""
  )

  $toWrite = if (Use-RemotePseudonymizationForModel -ModelName $ModelName) {
    Invoke-PseudoTransform -Route "/pseudonymize" -Text $Text -ModelName $ModelName
  } else {
    $Text
  }

  [System.IO.File]::WriteAllText($Path, $toWrite, [System.Text.Encoding]::UTF8)
}

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
    Write-Warning ("{0}: contexte insuffisant (tokSys={1}, available={2}), user vidé." -f $Label,$tokSys,$available)
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

  Write-Warning ("{0}: prompt tronqué (approx {1}→{2} tokens, n_ctx={3}, max_tokens={4})" -f $Label,$tokTotal,$tokTotalNew,$nCtx,$maxTok)
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

        "pass3_remote"      { return @{ NCtx=32768; MaxTok=2000; Margin=800 } }
        "pass3_remote_alt"  { return @{ NCtx=32768; MaxTok=2000; Margin=800 } }
        "pass3_remote_alt2" { return @{ NCtx=32768; MaxTok=2000; Margin=800 } }

        # ✅ AJOUT CRITIQUE

        "pass3a_remote" { return @{ NCtx=32768; MaxTok=1200; Margin=800 } }
        "pass3a_remote_alt"  { return @{ NCtx=32768; MaxTok=2000; Margin=800 } }
        "pass3a_remote_alt2" { return @{ NCtx=32768; MaxTok=2000; Margin=800 } }

        "pass3b_remote" { return @{ NCtx=32768; MaxTok=1800; Margin=800 } }
        "pass3b_remote_alt"  { return @{ NCtx=32768; MaxTok=2000; Margin=800 } }
        "pass3b_remote_alt2" { return @{ NCtx=32768; MaxTok=2000; Margin=800 } }

        "pass3c_remote" { return @{ NCtx=32768; MaxTok=1800; Margin=800 } }
        "pass3c_remote_alt"  { return @{ NCtx=32768; MaxTok=2000; Margin=800 } }
        "pass3c_remote_alt2" { return @{ NCtx=32768; MaxTok=2000; Margin=800 } }

        "pass3d_remote" { return @{ NCtx=32768; MaxTok=1200; Margin=800 } }
        "pass3d_remote_alt"  { return @{ NCtx=32768; MaxTok=2000; Margin=800 } }
        "pass3d_remote_alt2" { return @{ NCtx=32768; MaxTok=2000; Margin=800 } }

        "pass3e_remote" { return @{ NCtx=32768; MaxTok=1800; Margin=800 } }
        "pass3e_remote_alt"  { return @{ NCtx=32768; MaxTok=2000; Margin=800 } }
        "pass3e_remote_alt2" { return @{ NCtx=32768; MaxTok=2000; Margin=800 } }



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

  # Cas 1 : secondes (ex: "33.025")
  if($hms -match '^[0-9]+([.,][0-9]+)?$'){
    $hms = $hms -replace ',', '.'
    return [int][double]$hms
  }

  $p = $hms.Split(":")

  # Cas 2 : HH:MM:SS:mmm (ou H:MM:SS:mmm)
  if($p.Count -eq 4){
    $hh = [int]$p[0]
    $mm = [int]$p[1]
    $ss = [int]$p[2]
    $ms = [int]$p[3]
    return [int]($hh*3600 + $mm*60 + $ss + ($ms/1000.0))
  }

  # Cas 3 : HH:MM:SS ou MM:SS
  if($p.Count -lt 2){ return 0 }
  if($p.Count -eq 2){ $p = @("0") + $p }
  $hh = [int]$p[0]
  $mm = [int]$p[1]
  $ss = [int][double](($p[2] -replace ',', '.'))

  # Tolérance à un ancien format erroné de type HH:MM:SS où MM contenait déjà
  # le total de minutes (ex: 01:60:40 au lieu de 01:00:40).
  if($mm -ge 60 -and $hh -ge 0 -and [int]($mm / 60) -eq $hh){
    $mm = $mm % 60
  }

  return $hh*3600 + $mm*60 + $ss
}


function To-TotalSeconds([object]$v){
  if($null -eq $v){ return 0.0 }
  $s = ([string]$v).Trim()
  if(-not $s){ return 0.0 }

  # "33.025" ou "33,025"
  if($s -match '^[0-9]+([.,][0-9]+)?$'){
    return [double]($s -replace ',', '.')
  }

  # "HH:MM:SS" ou "MM:SS" (éventuellement avec décimales sur SS)
  $p = $s.Split(':')
  if($p.Count -lt 2){ return 0.0 }
  if($p.Count -eq 2){ $p = @('0') + $p }

  $h  = [long]$p[0]
  $m  = [long]$p[1]
  $ss = [double]($p[2] -replace ',', '.')
  return ($h*3600.0 + $m*60.0 + $ss)
}



function Try-ParseTimecodeSec {
  param(
    [object]$tc,
    [double]$MaxSec = 0
  )
  $maxMinutesPlausible = [int][math]::Ceiling(($MaxSec / 60.0) * 2.0)

  if ($null -eq $tc) { return $null }
  $s = ([string]$tc).Trim()
  if ($s -eq "") { return $null }

  # A) secondes numériques
  if ($s -match '^[0-9]+([.,][0-9]+)?$') {
    $s = $s -replace ',', '.'
    return [double]$s
  }

  # B) H:MM:SS  ou  H:MM:SS.mmm / H:MM:SS,mmm
  if ($s -match '^(?<h>\d+):(?<m>\d{2}):(?<sec>\d{2})(?<frac>[.,]\d+)?$') {
    $h  = [int]$Matches.h
    $m  = [int]$Matches.m
    $se = [int]$Matches.sec
    if ($m -ge 60 -or $se -ge 60) { return $null }

    $frac = 0.0
    if ($Matches.frac) {
      $frac = [double](("0" + ($Matches.frac -replace ',', '.')))
    }
    return ($h*3600 + $m*60 + $se + $frac)
  }

  # C) H:MM:SS:mmm  (dernier bloc = ms)
  if ($s -match '^(?<h>\d+):(?<m>\d{2}):(?<sec>\d{2}):(?<ms>\d{1,3})$') {
    $h  = [int]$Matches.h
    $m  = [int]$Matches.m
    $se = [int]$Matches.sec
    $ms = [int]$Matches.ms
    if ($m -ge 60 -or $se -ge 60 -or $ms -ge 1000) { return $null }

    return ($h*3600 + $m*60 + $se + ($ms/1000.0))
  }
  # D) MM:SS  ou  M:SS  (format fréquent exports type noota)
  # Garde-fou: minutes <= maxMinutesPlausible, sinon null
  $script:MaxSec = $maxSec
  if ($s -match '^(?<m>\d{1,4}):(?<sec>\d{2})$') {
    $m  = [int]$Matches.m
    $se = [int]$Matches.sec
    if ($se -ge 60) { return $null }

    # seuil "anti-hallucination" : par défaut, 2 * durée max CSV en minutes (plutôt permissif)
    # (vous pouvez le resserrer à 1.2x si vous voulez être strict)
    $maxMinutesPlausible = [int][math]::Ceiling(($script:MaxSec / 60.0) * 2.0)

    if ($m -gt $maxMinutesPlausible) { return $null }
    return ($m*60 + $se)
  }

  return $null
}


function Normalize-Timecodes {
  param(
    [object[]]$timecodes,
    [double]$minSec = 0.0,
    [double]$maxSec
  )


  $out = @()
  foreach($tc in @($timecodes)) {
    $sec = Try-ParseTimecodeSec -tc $tc -MaxSec $maxSec

    if ($null -eq $sec) { $out += $null; continue }
    if ($sec -lt $minSec -or $sec -gt $maxSec) { $out += $null; continue }
       
    # Sortie normalisée au choix :
    # 1) HH:MM:SS (arrondi) :
    $out += (Seconds-To-Hms -s ([int][math]::Round($sec)))

    # ou 2) garder une précision ms : à activer si vous préférez
    # $h=[int]($sec/3600); $m=[int](($sec%3600)/60); $s2=[int]($sec%60)
    # $ms=[int][math]::Round(($sec - [math]::Floor($sec))*1000)
    # $out[-1] = ("{0:D2}:{1:D2}:{2:D2}.{3:D3}" -f $h,$m,$s2,$ms)
  }
  return $out
}

function Update-ContexteGeneralFromCsv {
  param(
    [Parameter(Mandatory=$true)][string]$CsvPath,
    [Parameter(Mandatory=$true)][string]$ContexteJsonPath,
    [string]$StartCol = "start",
    [string]$EndCol   = "end"
  )

  if (-not (Test-Path $CsvPath)) {
    throw "CSV introuvable: $CsvPath"
  }
  if (-not (Test-Path $ContexteJsonPath)) {
    throw "contexte_general.json introuvable: $ContexteJsonPath"
  }

  $rows = Import-Csv -Path $CsvPath -Delimiter ';'
  if (-not $rows -or $rows.Count -eq 0) {
    throw "CSV vide: $CsvPath"
  }

  $minStart = $null
  $maxTime  = 0.0

  foreach ($r in $rows) {
    if (-not $r.PSObject.Properties[$StartCol]) { continue }

    $s = To-SecondsSafe ([string]$r.$StartCol)
    if ($null -ne $s) {
      if ($null -eq $minStart -or $s -lt $minStart) { $minStart = $s }
      if ($s -gt $maxTime) { $maxTime = $s }
    }

    if ($r.PSObject.Properties[$EndCol] -and -not [string]::IsNullOrWhiteSpace([string]$r.$EndCol)) {
      $e = To-SecondsSafe ([string]$r.$EndCol)
      if ($null -ne $e -and $e -gt $maxTime) { $maxTime = $e }
    }
  }

  if ($null -eq $minStart) { $minStart = 0.0 }

  $durationSec = [int][math]::Max(0, [math]::Ceiling($maxTime - $minStart))
  $maxSecInt   = [int][math]::Ceiling($maxTime)

  Microsoft.PowerShell.Utility\Write-Host ("[DEBUG] Avant lecture / mise à jour du contexte JSON : {0}" -f $ContexteJsonPath) -ForegroundColor Yellow
  $ctxRaw = Get-Content -Raw -Encoding UTF8 $ContexteJsonPath
  $ctx = $ctxRaw | ConvertFrom-Json
  Microsoft.PowerShell.Utility\Write-Host ("[DEBUG] Après ConvertFrom-Json : chars={0}" -f $ctxRaw.Length) -ForegroundColor Yellow

  if (-not $ctx.PSObject.Properties['meta'] -or $null -eq $ctx.meta) {
    $ctx | Add-Member -Force NoteProperty meta ([pscustomobject]@{})
  }

  # Écriture propre dans meta
  $ctx.meta | Add-Member -Force NoteProperty duree_reunion_seconds  $durationSec
  $ctx.meta | Add-Member -Force NoteProperty duree_reunion_hms      (Seconds-To-Hms $durationSec)
  $ctx.meta | Add-Member -Force NoteProperty csv_time_min_seconds   ([int][math]::Floor($minStart))
  $ctx.meta | Add-Member -Force NoteProperty csv_time_max_seconds   $maxSecInt
  $ctx.meta | Add-Member -Force NoteProperty csv_path               ((Resolve-Path $CsvPath).Path)
  $ctx.meta | Add-Member -Force NoteProperty source_duree           "csv"
  $ctx.meta | Add-Member -Force NoteProperty updated_at             ((Get-Date).ToString("yyyy-MM-ddTHH:mm:ssK"))

  # Compatibilité éventuelle avec le reste du pipeline
  $ctx | Add-Member -Force NoteProperty duree_reunion_estimee_sec   $durationSec
  $ctx | Add-Member -Force NoteProperty duree_reunion_estimee_hms   (Seconds-To-Hms $durationSec)
  $ctx | Add-Member -Force NoteProperty source_duree                "csv"
  $ctx | Add-Member -Force NoteProperty csv_max_end_sec             $maxSecInt

  $jsonOut = $ctx | ConvertTo-Json -Depth 30
  [System.IO.File]::WriteAllText($ContexteJsonPath, $jsonOut, $utf8NoBom)
  Microsoft.PowerShell.Utility\Write-Host ("[DEBUG] Après écriture du contexte mis à jour : {0}" -f $ContexteJsonPath) -ForegroundColor Yellow

  return [pscustomobject]@{
    durationSec = $durationSec
    durationHms = (Seconds-To-Hms $durationSec)
    minStartSec = [int][math]::Floor($minStart)
    maxSec      = $maxSecInt
    wrote       = $ContexteJsonPath
  }
}


function Timecode-To-Seconds([string]$t){
  if([string]::IsNullOrWhiteSpace($t)){ return $null }

  try {
    $t = $t.Trim().Replace(',', '.')

    # Enlève tous crochets où qu'ils soient (robuste aux crochets mal fermés)
    $t = $t -replace '\[', '' -replace '\]', ''

    # Cas LLM : "8804:213" (secondes:fraction). À traiter AVANT MM:SS
    # - fraction 1..3 digits, normalisée sur 3 (ms)
    if($t -match '^\d+:\d{1,3}$'){
      $a = $t.Split(':', 2)
      $sec = [int]$a[0]
      $frac = $a[1]

      if($frac.Length -lt 3){ $frac = $frac.PadRight(3,'0') }
      if($frac.Length -gt 3){ $frac = $frac.Substring(0,3) }

      $ms = [int]$frac
      if($ms -lt 0 -or $ms -gt 999){ return $null }

      return [double]$sec + ($ms / 1000.0)
    }

    # Secondes (float) : "179.606" ou "8804.213" (après retrait des crochets)
    if($t -match '^\d+(\.\d+)?$'){ return [double]$t }

    $p = $t.Split(':')

    # MM:SS
    if($p.Count -eq 2){
      $m = [int]$p[0]
      $s = [double]$p[1]
      if($m -lt 0 -or $m -ge 60 -or $s -lt 0 -or $s -ge 60){ return $null }
      return [double]($m*60 + $s)
    }

    # H:MM:SS  ou  HH:MM:SS  ou  HH:MM:SS:ms
    if($p.Count -eq 3 -or $p.Count -eq 4){
      $h = [int]$p[0]
      $m = [int]$p[1]
      $s = [double]$p[2]
      if($h -lt 0 -or $m -lt 0 -or $m -ge 60 -or $s -lt 0 -or $s -ge 60){ return $null }

      $base = [double]($h*3600 + $m*60 + $s)

      if($p.Count -eq 4){
        $msStr = $p[3]
        if($msStr -notmatch '^\d{1,3}$'){ return $null }
        $ms = [int]$msStr
        if($ms -lt 0 -or $ms -gt 999){ return $null }
        return $base + ($ms / 1000.0)
      }

      return $base
    }

    return $null
  }
  catch {
    return $null
  }
}

function Normalize-InterventionTimecode {
  param(
    [AllowNull()][string]$Timecode,
    [int]$MaxSec
  )

  if ([string]::IsNullOrWhiteSpace($Timecode)) { return $null }

  $sec = $null
  try {
    $sec = Timecode-To-Seconds $Timecode
  } catch {
    return $null
  }
  if ($null -eq $sec) { return $null }

  if ($MaxSec -gt 0 -and ($sec -lt 0 -or $sec -gt $MaxSec)) { return $null }

  return (Seconds-To-Hms ([int][math]::Round($sec)))
}


function Clean-Timecodes([object[]]$timecodes, [int]$maxSec){
  if(-not $timecodes){ return @() }

  $out = New-Object System.Collections.Generic.List[string]
  foreach($tc in $timecodes){
    $sec = $null
    try {
      $sec = Timecode-To-Seconds ([string]$tc)
    } catch {
      $sec = $null
    }

    # Si invalide : on ignore le timecode, mais on conserve le contenu global
    if($sec -eq $null -or $sec -lt 0 -or $sec -gt $maxSec){
      continue
    }

    $out.Add((Seconds-To-Hms ([int][math]::Round($sec)))) | Out-Null
  }
  return $out.ToArray()
}


function Seconds-To-Hms([int]$s){
  $h=[int]($s/3600); $m=[int](($s%3600)/60); $ss=[int]($s%60)
  "{0:D2}:{1:D2}:{2:D2}" -f $h,$m,$ss
}

function To-SecondsSafe([string]$v){
  if([string]::IsNullOrWhiteSpace($v)){ return $null }
  try {
    return Hms-To-Seconds $v
  } catch {
    return $null
  }
}



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

function Normalize-TextForSubjectMatch([string]$Text) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
  $t = $Text.ToLowerInvariant()
  $t = $t -replace "[\u2010-\u2015]", "-"
  $t = $t -replace "\s+", " "
  return $t.Trim()
}

function Get-ControlledSubjectAliases {
  param(
    [Parameter(Mandatory=$true)] [array] $Sujets
  )

  $rules = @{}
  foreach ($sj in @($Sujets)) {
    $num = [int]$sj.Numero
    $label = Normalize-TextForSubjectMatch ("{0} {1} {2}" -f $sj.Titre, $sj.Localisation, $sj.Description)

    # Controlled aliases for cave / sous-sol disorders.
    # Additive only: copies already extracted interventions to an extra subject.
    if ($label -match "cave|sous-sol|sous sol") {
      $rules[[string]$num] = @(
        @{ pattern = "cave"; score = 2; label = "cave" },
        @{ pattern = "sous(-| )sol"; score = 2; label = "sous-sol" },
        @{ pattern = "garage en dessous"; score = 2; label = "garage en dessous" },
        @{ pattern = "local.*humide"; score = 2; label = "local humide" },
        @{ pattern = "tr.s humide.*eau"; score = 2; label = "tres humide/eau" },
        @{ pattern = "sous la terrasse|sous terrasse"; score = 2; label = "sous terrasse" },
        @{ pattern = "en bas correctement"; score = 2; label = "en bas correctement" }
      )
    }
  }
  return $rules
}

function Get-InterventionKeyForMultiSubject($Iv) {
  return ("{0}|{1}|{2}" -f `
    ([string]$Iv.segment_id).Trim(), `
    ([string]$Iv.timecode).Trim(), `
    ([string]$Iv.texte).Trim())
}

function Add-MultiSubjectAssignments {
  param(
    [Parameter(Mandatory=$true)] [hashtable] $BySujet,
    [Parameter(Mandatory=$true)] [array] $Sujets,
    [string] $LogFile
  )

  $rulesBySubject = Get-ControlledSubjectAliases -Sujets $Sujets
  if ($rulesBySubject.Count -eq 0) { return $BySujet }

  $existingKeys = @{}
  foreach ($num in @($BySujet.Keys)) {
    $existingKeys[[string]$num] = @{}
    foreach ($iv in @($BySujet[$num])) {
      $existingKeys[[string]$num][(Get-InterventionKeyForMultiSubject $iv)] = $true
    }
  }

  $additions = @()
  foreach ($sourceNum in @($BySujet.Keys)) {
    foreach ($iv in @($BySujet[$sourceNum])) {
      $text = Normalize-TextForSubjectMatch ([string]$iv.texte)
      if (-not $text) { continue }

      foreach ($targetNum in @($rulesBySubject.Keys)) {
        if ([string]$targetNum -eq [string]$sourceNum) { continue }

        $score = 0
        $matched = New-Object System.Collections.Generic.List[string]
        foreach ($rule in @($rulesBySubject[$targetNum])) {
          if ($text -match $rule.pattern) {
            $score += [int]$rule.score
            $matched.Add([string]$rule.label) | Out-Null
          }
        }

        # Conservative threshold: one strong phrase/term or two weak cues.
        if ($score -lt 2) { continue }

        $copy = [pscustomobject]@{
          segment_id = $iv.segment_id
          timecode   = $iv.timecode
          auteur     = $iv.auteur
          role       = $iv.role
          texte      = $iv.texte
          source_sujet_principal = [string]$sourceNum
          multi_subject_match = [pscustomobject]@{
            target_sujet = [int]$targetNum
            score        = $score
            matched      = $matched.ToArray()
            rule         = "controlled_aliases"
          }
        }

        $key = Get-InterventionKeyForMultiSubject $copy
        if (-not $existingKeys.ContainsKey([string]$targetNum)) {
          $existingKeys[[string]$targetNum] = @{}
        }
        if ($existingKeys[[string]$targetNum].ContainsKey($key)) { continue }

        $existingKeys[[string]$targetNum][$key] = $true
        $additions += [pscustomobject]@{
          target  = [string]$targetNum
          item    = $copy
          source  = [string]$sourceNum
          score   = $score
          matched = $matched.ToArray()
        }
      }
    }
  }

  foreach ($a in @($additions)) {
    if (-not $BySujet.ContainsKey($a.target)) {
      $BySujet[$a.target] = @()
    }
    $BySujet[$a.target] = @($BySujet[$a.target]) + @($a.item)
    $msg = "Multi-sujet: segment=$($a.item.segment_id) timecode=$($a.item.timecode) source=$($a.source) cible=$($a.target) score=$($a.score) match=$(@($a.matched) -join ',')"
    Write-Host $msg
    if ($LogFile) { $msg | Add-Content $LogFile }
  }

  return $BySujet
}

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

  $uri = ($ApiBase.TrimEnd('/')) + "/v1/chat/completions"

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
    Microsoft.PowerShell.Utility\Write-Host ("[LLM] POST {0}" -f $uri)
    Microsoft.PowerShell.Utility\Write-Host ("[LLM] model={0} bodyChars={1}" -f $model, $body.Length)
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
        Microsoft.PowerShell.Utility\Write-Host ("[LLM] ERROR try {0}/{1} status={2} msg={3}" -f $t, $MaxTry, $status, $msg)
        if ($errBody) { Microsoft.PowerShell.Utility\Write-Host ("[LLM] ERROR body: {0}" -f $errBody) }
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
      $prop = $iv.PSObject.Properties['timecode']
      $tc = if ($prop) { $prop.Value } else { $null }

      $prop = $iv.PSObject.Properties['texte']
      $tx = if ($prop) { $prop.Value } else { $null }

      if (-not $tx) {
        $prop = $iv.PSObject.Properties['text']
        $tx = if ($prop) { $prop.Value } else { $null }
      }

      if (-not $tc) { continue }
      if (-not $tx) { continue }

      $prop = $iv.PSObject.Properties['auteur']
      $au = if ($prop) { $prop.Value } else { $null }

      $prop = $iv.PSObject.Properties['role']
      $ro = if ($prop) { $prop.Value } else { $null }

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

  $systemToSend = $system
  $userToSend   = $user

  if (Use-RemotePseudonymizationForModel -ModelName $model) {
    $systemToSend = Invoke-PseudoTransform -Route "/pseudonymize" -Text $system -ModelName $model
    $userToSend   = Invoke-PseudoTransform -Route "/pseudonymize" -Text $user -ModelName $model
  }

  if($Provider -ieq "openai"){
    return Invoke-LLM-OpenAICompat -system $systemToSend -user $userToSend -model $model -DebugHttp:$DebugHttp
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

  # --- HEAD + TAIL ---
  $marker = "`n/* …TRUNCATED… */`n"
  $markerLen = $marker.Length

  # 70% head / 30% tail (ajustable)
  $headLen = [int][math]::Floor(($maxUserChars - $markerLen) * 0.70)
  $tailLen = ($maxUserChars - $markerLen) - $headLen
  if($headLen -lt 128){ $headLen = [math]::Min(128, $UserText.Length) }
  if($tailLen -lt 128){ $tailLen = [math]::Min(128, $UserText.Length - $headLen) }

  $head = $UserText.Substring(0, [math]::Min($headLen, $UserText.Length))
  $tail = $UserText.Substring([math]::Max(0, $UserText.Length - $tailLen))

  $truncatedUser = $head + $marker + $tail

  Write-Warning ("Prompt tronqué (Pass 3) : approx sys={0} tok, user={1}→{2} tok, n_ctx={3}, max_tokens={4}, available={5} (HEAD+TAIL {6}/{7} chars)" -f $sysTok,$usrTok,$maxUserTokens,$NCtx,$MaxTokens,$available,$headLen,$tailLen)

  return $truncatedUser
}

#------------------------------------------------------------
#  Initialisation du cadre temporel
#------------------------------------------------------------

# maxSec = max(end) si end existe et est non vide, sinon max(start)
Microsoft.PowerShell.Utility\Write-Host ("[DEBUG] Début calcul durée max / lecture CSV : {0}" -f $CsvPath) -ForegroundColor Yellow
$rows = Import-Csv $csvPath -Delimiter ';'
Microsoft.PowerShell.Utility\Write-Host ("[DEBUG] Après Import-Csv : rows={0}" -f @($rows).Count) -ForegroundColor Yellow

$maxSec = 0
$maxSecLoopIndex = 0
foreach($r in $rows){
  $maxSecLoopIndex++
  if (($maxSecLoopIndex % 200) -eq 0) {
    Microsoft.PowerShell.Utility\Write-Host ("[DEBUG] boucle maxSec : i={0}" -f $maxSecLoopIndex) -ForegroundColor Yellow
  }
  if(-not $r.start){ continue }

  $s = To-SecondsSafe ([string]$r.start)
  $cand = $s

  if($r.PSObject.Properties.Name -contains 'end' -and -not [string]::IsNullOrWhiteSpace($r.end)){
    $e = To-SecondsSafe ([string]$r.end)
    $cand = $e
  }

  if($cand -gt $maxSec){ $maxSec = $cand }
}
Microsoft.PowerShell.Utility\Write-Host ("[DEBUG] Après boucle maxSec : maxSec={0}" -f $maxSec) -ForegroundColor Yellow

$maxSecInt = [int][math]::Ceiling($maxSec)
Microsoft.PowerShell.Utility\Write-Host ("[DEBUG] Avant conversion maxSec -> HH:MM:SS : maxSecInt={0}" -f $maxSecInt) -ForegroundColor Yellow
$maxHms    = Seconds-To-Hms $maxSecInt
Microsoft.PowerShell.Utility\Write-Host ("[DEBUG] Après conversion maxSec -> HH:MM:SS : maxHms={0}" -f $maxHms) -ForegroundColor Yellow

Microsoft.PowerShell.Utility\Write-Host ("Durée max détectée (sec) = {0} ; HH:MM:SS = {1}" -f $maxSecInt, $maxHms)

# ---- Charger contexte_general.json, injecter, réécrire ----
Microsoft.PowerShell.Utility\Write-Host ("[DEBUG] Fin calcul durée max : rows={0} ; maxSec={1} ; maxHms={2}" -f @($rows).Count, $maxSecInt, $maxHms) -ForegroundColor Yellow
Microsoft.PowerShell.Utility\Write-Host "[DEBUG] step A2 - avant log fin calcul durée max" -ForegroundColor Yellow
Microsoft.PowerShell.Utility\Write-Host "[DEBUG] step B - avant résolution contextePath" -ForegroundColor Yellow
$contextePath = $ContextJsonPath
Microsoft.PowerShell.Utility\Write-Host ("[DEBUG] step C - contextePath résolu : {0}" -f $contextePath) -ForegroundColor Yellow
Microsoft.PowerShell.Utility\Write-Host "[DEBUG] step D - avant test présence contextePath / Test-Path" -ForegroundColor Yellow
if ($contextePath -and (Test-Path $contextePath)) {
    Microsoft.PowerShell.Utility\Write-Host "[DEBUG] step E - avant appel Update-ContexteGeneralFromCsv" -ForegroundColor Yellow
    $ctxUpdate = Update-ContexteGeneralFromCsv `
        -CsvPath $CsvPath `
        -ContexteJsonPath $contextePath `
        -StartCol "start" `
        -EndCol "end"

    Microsoft.PowerShell.Utility\Write-Host "[DEBUG] step E2 - retour Update-ContexteGeneralFromCsv" -ForegroundColor Yellow

    Microsoft.PowerShell.Utility\Write-Host ("Contexte mis à jour : duree_reunion_estimee_sec={0} ; duree_reunion_estimee_hms={1}" -f `
        $ctxUpdate.durationSec, $ctxUpdate.durationHms)
}
else {
    Microsoft.PowerShell.Utility\Write-Host "Contexte non mis à jour : ContextJsonPath absent ou introuvable."
}

#------------------------------------------------------------
# ── Prompts debrief expert Passe 1B ─────────────────────────────────────────
#------------------------------------------------------------
Microsoft.PowerShell.Utility\Write-Host "[DEBUG] step F01 - avant BaseDebrief_System" -ForegroundColor Yellow
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

Détermination du mode :
- Si la transcription de la réunion est complète et exploitable → mode_debrief = "complement".
- Si la transcription est absente, très lacunaire ou inexploitable (panne audio, segments vides, propos non audibles) → mode_debrief = "substitution".


Sortie STRICTEMENT JSON :
{
  "mode_debrief": "complement | substitution",
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

Microsoft.PowerShell.Utility\Write-Host "[DEBUG] step F02 - avant branche Debrief_System selon GlobalContext" -ForegroundColor Yellow
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

Microsoft.PowerShell.Utility\Write-Host "[DEBUG] step F03 - avant branche Debrief_User_Template selon ContextUser" -ForegroundColor Yellow
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

#------------------------------------------------------------
# Passe 1 
#------------------------------------------------------------
Microsoft.PowerShell.Utility\Write-Host "[DEBUG] step F04 - avant BasePass1_System" -ForegroundColor Yellow
$BasePass1_System = @'
Tu es un assistant d’analyse judiciaire.

Objectif :
À partir d’un SEGMENT de transcription d’une réunion d’expertise, tu dois :
- repérer quels SUJETS NUMÉROTÉS sont abordés,
- associer chaque prise de parole aux bons sujets,
- identifier l’auteur (participant) de manière canonique.

Tu disposes :
- d’une liste de sujets numérotés (JSON) comprenant au minimum Numero et Titre, et éventuellement Localisation/Description que tu peux utiliser comme indices de rattachement,
- d’une liste de participants (Nom + Rôle + éventuels alias),
- d’un segment de transcription sous forme de lignes : "[HH:MM:SS] SPEAKER: texte".

Règles :
- Tu peux associer une même prise de parole à plusieurs sujets si elle en parle clairement.
- Si tu n’es pas sûr, tu n’associes pas (mieux vaut rater un lien que d’en inventer un).
- Tu ne fais AUCUN résumé ici, uniquement du repérage de contenu par sujet.
- Ne créer une clé "<numero_sujet>" que si au moins une intervention est rattachée à ce sujet.
- "auteur" doit être choisi dans la liste des participants fournie. Si non reconnaissable : "auteur" = "Inconnu", "role" = null.
- "timecode" doit être exactement celui entre crochets [HH:MM:SS] de la ligne source.
- "texte" : extrait fidèle, 1 à 2 phrases maximum, sans reformulation.

Tu dois répondre STRICTEMENT en JSON avec ce schéma :

{
  "segment_id": "string",
  "sujets": {
    "<numero_sujet>": [
      {
        "timecode": "HH:MM:SS",
        "auteur": "Nom canonique du participant| Inconnu",
        "role": "string | null",
        "texte": "extrait fidèle (1 à 2 phrases), sans reformulation"
      }
    ]
  }
}
'@
Microsoft.PowerShell.Utility\Write-Host "[DEBUG] step F05 - avant branche Pass1_System selon GlobalContext" -ForegroundColor Yellow
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

Microsoft.PowerShell.Utility\Write-Host "[DEBUG] step F06 - avant branche Pass1_User_Template selon ContextUser" -ForegroundColor Yellow
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
#--------------------------------------------------------
# Passe 2
#--------------------------------------------------------
Microsoft.PowerShell.Utility\Write-Host "[DEBUG] step F07 - avant BasePass2_System" -ForegroundColor Yellow
$BasePass2_System=@'
Tu reçois plusieurs mini-CR JSON d'une même réunion. Fusionne-les en un seul JSON cohérent,
sans doublons, en regroupant les thèmes similaires.

Retourne UNIQUEMENT du JSON strict (aucun texte hors JSON) avec ce schéma exact :
{
  "resume_global": "string (6–8 phrases)",
  "themes": [
    { "titre":"string", "synthese":["string","..."], "timecodes":["HH:MM:SS","..."] }
  ],
  "actions": [
    { "action":"string", "responsable":"string | null", "echeance":"YYYY-MM-DD | null" }
  ],
  "problems": [
    { "probleme":"string", "solution":"string | null" }
  ]
}

Règles :
- regrouper par sens ;
- dédupliquer les informations redondantes ;
- conserver des timecodes représentatifs (uniquement présents dans les entrées) ;
- "actions" : uniquement actions explicitement décidées (contrôle, mesure, visite, intervention, devis, reprise).
- ne pas transformer une demande de document/information en "action" si elle n’est pas explicitement formulée comme une action décidée.
- si le responsable n’est pas explicitement identifié : responsable = null.
- en cas de conflit sur une date : retenir la date la plus précise.
- pas d’invention : si incertain → null / [].
'@
Microsoft.PowerShell.Utility\Write-Host "[DEBUG] step F08 - avant branche Pass2_System selon GlobalContext" -ForegroundColor Yellow
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

Microsoft.PowerShell.Utility\Write-Host "[DEBUG] step F09 - avant Pass2_User_Template" -ForegroundColor Yellow
$Pass2_User_Template=@'
Voici la liste des mini-CR JSON à fusionner (tableau JSON) :

{SEGMENTS_JSON_ARRAY}

Renvoie uniquement le JSON conforme au schéma.
'@

#------------------------------------------------------------
# ── Pass2B : construire un GLOBAL "réunion" (resume/themes/actions/problems) depuis global.json ──
# ── Pass2B : GLOBAL "réunion" enrichi ──
#------------------------------------------------------------
Microsoft.PowerShell.Utility\Write-Host "[DEBUG] step F10 - avant BasePass2B_System" -ForegroundColor Yellow
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
- Ne jamais renvoyer la liste d’entrée.
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
- "actions" : uniquement actions explicitement décidées (contrôle, mesure, intervention, visite, devis).
- Les demandes de documents/informations vont dans "demandes_documents_globales", pas dans "actions".
- Dédupliquer partout.
- Si les données sont insuffisantes, renvoyer quand même un JSON conforme avec chaînes vides et tableaux vides (pas de texte).
- La réponse doit commencer par { et se terminer par }.
'@


Microsoft.PowerShell.Utility\Write-Host "[DEBUG] step F11 - avant branche Pass2B_System selon GlobalContext" -ForegroundColor Yellow
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

Microsoft.PowerShell.Utility\Write-Host "[DEBUG] step F12 - avant Pass2B_User_Template" -ForegroundColor Yellow
$Pass2B_User_Template = @'
Voici la LISTE des segments annotés :

{SEGMENTS_JSON}

Renvoie uniquement le JSON "global réunion" conforme au schéma.
'@


# agregation hierarchique
Microsoft.PowerShell.Utility\Write-Host "[DEBUG] step F13 - avant définition fonction Aggregate-Sujets" -ForegroundColor Yellow
function Aggregate-Sujets {
  param(
    [object[]] $Segments,
    [int] $MaxSec = 0
  )

  $bySujet = @{}

  foreach ($seg in $Segments) {
    if (-not $seg) { continue }

    $sujets = $seg.sujets
    if (-not $sujets) { continue }

    # 1) Paires numero -> interventions
    $pairs = @()
    if ($sujets -is [System.Collections.IDictionary]) {
      $pairs = $sujets.GetEnumerator() | ForEach-Object {
        [pscustomobject]@{ Numero = [string]$_.Key; Interventions = $_.Value }
      }
    }
    else {
      $pairs = $sujets.PSObject.Properties | ForEach-Object {
        [pscustomobject]@{ Numero = [string]$_.Name; Interventions = $_.Value }
      }
    }

    foreach ($p in $pairs) {
      $numero = ([string]$p.Numero).Trim()
      if (-not $numero) { continue }

      if (-not $bySujet.ContainsKey($numero)) {
        $bySujet[$numero] = New-Object System.Collections.Generic.List[object]
      }

      $interventions = $p.Interventions
      if ($null -eq $interventions) { continue }

      # 2) Normaliser en liste (attention: string est IEnumerable)
      if (($interventions -is [string]) -or ($interventions -isnot [System.Collections.IEnumerable])) {
        $interventions = @($interventions)
      } else {
        $interventions = @($interventions)
      }

      foreach ($iv in $interventions) {
        if (-not $iv) { continue }

        $tcRaw = [string]$iv.timecode
        $tc = $tcRaw

        if ($MaxSec -gt 0) {
          try {
            $tc = Normalize-InterventionTimecode -Timecode $tcRaw -MaxSec $MaxSec
          } catch {
            $tc = $null
          }
        }

        $bySujet[$numero].Add([pscustomobject]@{
          segment_id    = $seg.segment_id
          timecode      = $tc          # HH:MM:SS ou $null
          timecode_raw  = $tcRaw       # ce que le LLM a produit
          auteur        = $iv.auteur
          role          = $iv.role
          texte         = $iv.texte
        }) | Out-Null

      }
    }
  }

  # Convertir les List en tableaux pour sérialisation JSON stable
  foreach ($k in @($bySujet.Keys)) {
    $bySujet[$k] = @($bySujet[$k].ToArray())
  }

  return $bySujet
}

Microsoft.PowerShell.Utility\Write-Host "[DEBUG] step F14 - avant définition fonction Inject-DebriefIntoBySujet" -ForegroundColor Yellow
function Inject-DebriefIntoBySujet {
  param(
    [Parameter(Mandatory=$true)] [hashtable] $BySujet,
    [Parameter(Mandatory=$true)] [object]    $DebriefObj
  )

  if (-not $DebriefObj) { return }

  # 1) sujets[].orientation_expert -> interventions par sujet
  if ($DebriefObj.PSObject.Properties['sujets'] -and $DebriefObj.sujets) {
    foreach ($sj in @($DebriefObj.sujets)) {
      if (-not $sj) { continue }

      $num = $null
      try { $num = [int]$sj.numero } catch { $num = $null }
      if ($null -eq $num) { continue }

      $key = [string]$num
      if (-not $BySujet.ContainsKey($key)) { $BySujet[$key] = @() }

      $txt = $null
      if ($sj.PSObject.Properties['orientation_expert']) {
        $txt = ([string]$sj.orientation_expert).Trim()
      }

      if (-not [string]::IsNullOrWhiteSpace($txt)) {
        $BySujet[$key] += [pscustomobject]@{
          segment_id = "debrief"
          timecode   = $null
          auteur     = "Expert"
          role       = "expert de justice"
          texte      = $txt
          origine    = "debrief_expert"
        }
      }

      # (Optionnel) : vous pouvez aussi pousser les demandes_documents du sujet en "interventions"
      # pour qu'elles apparaissent dans 3E (si vous le souhaitez).
      if ($sj.PSObject.Properties['demandes_documents'] -and $sj.demandes_documents) {
        foreach ($d in @($sj.demandes_documents)) {
          if (-not $d) { continue }
          $obj = if ($d.PSObject.Properties['objet']) { ([string]$d.objet).Trim() } else { "" }
          if ([string]::IsNullOrWhiteSpace($obj)) { continue }

          $comment = $null
          if ($d.PSObject.Properties['commentaire']) { $comment = ([string]$d.commentaire).Trim() }
          $echeance = $null
          if ($d.PSObject.Properties['echeance']) { $echeance = $d.echeance }

          $line = "Demande de document (débrief) : $obj"
          if ($echeance) { $line += " ; Échéance : $echeance" }
          if ($comment)  { $line += " ; Commentaire : $comment" }

          $BySujet[$key] += [pscustomobject]@{
            segment_id = "debrief"
            timecode   = $null
            auteur     = "Expert"
            role       = "expert de justice"
            texte      = $line
            origine    = "debrief_expert"
          }
        }
      }
    }
  }

  # 2) (Optionnel) : rattacher les demandes hors sujet à un "sujet 0" ou les ignorer pour 3E
  # Recommandation : NE PAS les injecter dans bySujet (sinon 3E les répartira mal).
  # Elles doivent rester dans globalMeetingMerged.demandes_documents_globales (Pass3D).
}

Microsoft.PowerShell.Utility\Write-Host "[DEBUG] step F15 - avant définition fonction Invoke-Pass2Fusion" -ForegroundColor Yellow
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
        Write-Warning "Invoke-Pass2Fusion: résultat vide alors que le batch contenait des données. Fallback sur une fusion simple."

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
Microsoft.PowerShell.Utility\Write-Host "[DEBUG] step F16 - avant définition fonction Aggregate-Segments-Hierarchical" -ForegroundColor Yellow
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
        Microsoft.PowerShell.Utility\Write-Host ("Passe 2 (round {0}) → {1} objets à fusionner" -f $round, $current.Count)
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
#------------------------------------------------------------
# 3A : métadonnées et résumé global
#------------------------------------------------------------
Microsoft.PowerShell.Utility\Write-Host "[DEBUG] step F17 - avant BasePass3A_System" -ForegroundColor Yellow
$BasePass3A_System = @'
Tu reçois :
(1) un contexte général d’expertise judiciaire (mission, état d’avancement, cadre procédural),
(2) un JSON "global" décrivant une réunion :
- "resume_global"
- "themes"
- "actions"
- "problems"

Objectif :
Tu dois produire UNIQUEMENT les champs suivants, au format JSON strict :

{
  "date": "YYYY-MM-DD | null",
  "link": "string | null",
  "resume": "string",
  "ordre_du_jour": ["string", "..."]
}

Structure obligatoire du champ "resume" :
- Paragraphe 1 : cadrage de la réunion (nature judiciaire, type de réunion, lieu).
- Paragraphe 2 : position dans le déroulement de l’expertise (ex : première réunion), sans indiquer la date.
- Paragraphe 3 : objectifs de la réunion (prise de connaissance, constats initiaux, échanges contradictoires).
- Paragraphes suivants : principaux constats techniques et points évoqués.
- Dernier Paragraphe : suites envisagées (vérifications, documents demandés, investigations à venir).
- Le champ "resume" ne doit contenir aucune date (ni "YYYY-MM-DD", ni "3 juillet 2025"). La date doit figurer uniquement dans le champ "date".
- Pour "resume" : si une information manque, formuler de manière générale sans ajout factuel (ex. "Le lieu n’est pas précisé"), et ne pas mettre null.
- Pour "resume", ne jamais utiliser null ; pour les autres champs, null/[] selon le schéma.
- "ordre_du_jour" : items sans préfixe de liste (pas de "- ", pas de "•", pas de "1)").
- Si une date est mentionnée dans le JSON global ou le contexte, renseigner uniquement "date" au format YYYY-MM-DD.
- Le résumé doit être rédigé en plusieurs paragraphes.
- Chaque paragraphe correspond à une idée distincte :
  (exemple : cadre de la réunion, objectifs, constats principaux, suites envisagées).
- Séparer chaque paragraphe par une ligne vide.

Règle impérative pour le champ "date" :
- Si le contexte général mentionne explicitement une date de réunion,
  cette date DOIT être reprise dans le champ "date", même si elle n’apparaît pas dans le JSON global.

Si une information structurelle figure dans le contexte général mais pas dans le JSON global,
elle PEUT être utilisée pour cadrer le résumé (sans ajout factuel).

Règles de rédaction (obligatoires) :
- Le champ "resume" doit être rédigé à la lumière du contexte général d’expertise fourni en amont.
- Le contexte sert UNIQUEMENT à orienter la formulation (cadre, mission, état d’avancement), sans ajouter de faits absents.
- Le résumé doit être factuel, pédagogique, descriptif et neutre, sans conclusion juridique ni appréciation des responsabilités.
- Ne pas inventer : si une information n’est pas clairement présente dans le JSON global ou explicitement donnée par le contexte → utiliser null ou [] (selon le champ).

Règles spécifiques :
- Pour "date" : si la date de la réunion figure explicitement dans le contexte général OU dans le JSON global → la renseigner au format YYYY-MM-DD ; sinon null.
- Pour "link" : uniquement si un lien figure explicitement dans le JSON global ou le contexte ; sinon null.
- Pour "ordre_du_jour" : liste de points/titres synthétiques issus du JSON global (pas d’ajouts).

Paragraphes (obligatoire) :
- Pour séparer deux paragraphes dans "resume", utiliser la séquence "\n\n" (deux retours à la ligne).
- Ne pas insérer de texte hors JSON.
- Pour séparer deux paragraphes dans "resume", utiliser uniquement la séquence \n\n.
- Interdit : utiliser \n seul.
- Interdit : utiliser des listes à puces ou numérotées dans "resume" (pas de -, pas de •, pas de 1)).
- Le champ "resume" doit contenir exactement 5 paragraphes séparés par \n\n : 1) cadrage, 2) position dans l’expertise (sans date), 3) objectifs, 4) constats/points évoqués, 5) suites envisagées.

Contraintes de sortie :
- Aucune phrase hors JSON.
- Aucune explication.
- JSON strict uniquement, conforme au schéma ci-dessus.
'@

Microsoft.PowerShell.Utility\Write-Host "[DEBUG] step F18 - avant branche Pass3A_System selon GlobalContext" -ForegroundColor Yellow
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
Microsoft.PowerShell.Utility\Write-Host "[DEBUG] step F19 - avant Pass3A_User_Template" -ForegroundColor Yellow
$Pass3A_User_Template = @'
Voici le JSON global issu de la fusion des segments :
{GLOBAL_JSON}

Contraintes :
- Extraire la date de réunion depuis le contexte si elle y figure (format YYYY-MM-DD).
- Le "resume" doit commencer par cadrer la réunion : nature (réunion d’expertise), lieu/site si mentionné, objet, finalité, suites décidées.
- Ne rien inventer.

Produis uniquement :
{ "date": "...", "link": null|"...", "resume": "...", "ordre_du_jour": [...] }

Interdiction :
- "resume" ne doit contenir aucune date, ni "YYYY-MM-DD" ni "D mois YYYY".
- Toute date doit être uniquement dans "date".

Renvoie uniquement le JSON.
'@


#------------------------------------------------------------
# 3B : thèmes_abordes
#------------------------------------------------------------
Microsoft.PowerShell.Utility\Write-Host "[DEBUG] step F20 - avant BasePass3B_System" -ForegroundColor Yellow
$BasePass3B_System = @'
Tu reçois le JSON "global" d'une réunion.

Tu dois produire UNIQUEMENT :

{
  "themes_abordes": [
    {
      "titre": "string",
      "synthese": ["string","..."],
      "indices_source": [
        { "timecode": "HH:MM:SS", "speaker": "string | null", "extrait": "string | null" }
      ]
    }
  ]
}

Règles :
- 10 à 15 thèmes maximum.
- 1 à 3 indices_source par thème.
- "synthese" : 3 à 8 points par thème, phrases courtes (une idée par item), sans puces "-" en tête.
- "indices_source.timecode" doit provenir d’un timecode existant dans le JSON global ; sinon ne pas créer d’indice.
- "indices_source.speaker" : reprendre le champ "auteur" s’il existe, sinon null.
- "indices_source.extrait" : reprendre un extrait très court (≤ 20 mots) du champ "texte" s’il existe, sinon null.
- Aucune date au format "YYYY-MM-DD" dans "indices_source.speaker".
- "indices_source.extrait" : sans puce "-" en tête.
- sortie STRICTEMENT au format JSON.

Normalisation des dates (obligatoire) :

- Aucune date au format "YYYY-MM-DD" dans "titre", "synthese" ou "indices_source.extrait".
- Si une date doit être mentionnée dans un texte, utiliser "D mois YYYY".

'@

Microsoft.PowerShell.Utility\Write-Host "[DEBUG] step F21 - avant branche Pass3B_System selon GlobalContext" -ForegroundColor Yellow
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

Microsoft.PowerShell.Utility\Write-Host "[DEBUG] step F22 - avant Pass3B_User_Template" -ForegroundColor Yellow
$Pass3B_User_Template = @'
Voici le JSON global issu de la fusion des segments :

{GLOBAL_JSON}

À partir de ce JSON global, produis uniquement le champ "themes_abordes"
selon le schéma indiqué.

Renvoie uniquement le JSON conforme au schéma.
'@
#------------------------------------------------------------
# 3C : actions / perspectives / annexes
#------------------------------------------------------------
Microsoft.PowerShell.Utility\Write-Host "[DEBUG] step F23 - avant BasePass3C_System" -ForegroundColor Yellow
$BasePass3C_System = @'
Tu reçois le JSON "global" d'une réunion.

Tu dois produire UNIQUEMENT :

{
  "actions": [
    {
      "action": "string",
      "responsable": "string | null",
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
- actions : liste des actions concrètes décidées/à faire.
- perspectives : liste de 3 à 8 couples (probleme/solution) déduits du JSON global :
    * "probleme" = point technique / désordre / incertitude / vérification à mener
    * "solution" = suite prévue (contrôle, mesure, devis, pièce, intervention)
- annexes : liste de 3 à 10 éléments (pièces, constats, relevés, photos, notices, devis) explicitement évoqués.
- Si le JSON global contient problems ou des mentions explicites de demandes de pièces/informations, t’en servir pour alimenter perspectives et annexes.
- Si aucune matière n’existe : actions: [], perspectives: [], annexes: [].
- Ne pas transformer une "demande de document" en "action" si elle n’est pas explicitement formulée comme une action décidée.
- Les demandes de documents/informations doivent rester des demandes (annexes/perspectives), sans formulation impérative attribuée à une personne si le responsable n’est pas explicitement cité.
- Pour "actions" : ne renseigner "responsable" que s’il est explicitement identifié, sinon null.
- Pour "annexes" : uniquement des pièces explicitement mentionnées comme existantes/produites ; ne pas inventer une pièce seulement “demandée”.


Normalisation des dates (obligatoire) :
- "echeance" est le seul endroit où une date peut apparaître au format "YYYY-MM-DD".
- Ne jamais écrire de date "YYYY-MM-DD" dans "action", "responsable", "commentaire", "probleme", "solution", "annexes".
- Si une date est mentionnée en texte (exception), utiliser "D mois YYYY".

'@
Microsoft.PowerShell.Utility\Write-Host "[DEBUG] step F24 - avant branche Pass3C_System selon GlobalContext" -ForegroundColor Yellow
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

Microsoft.PowerShell.Utility\Write-Host "[DEBUG] step F25 - avant Pass3C_User_Template" -ForegroundColor Yellow
$Pass3C_User_Template = @'
Voici le JSON global issu de la fusion des segments :

{GLOBAL_JSON}

À partir de ce JSON global, produis uniquement :
- "actions"
- "perspectives"
- "annexes"

Si des incertitudes, hypothèses techniques, risques, investigations futures ou conditions de reprise sont évoqués,
elles doivent être reformulées dans "perspectives".

Renvoie uniquement le JSON conforme au schéma.
'@


# Passe 3 → JSON final (structure CR complète, sans Markdown)
Microsoft.PowerShell.Utility\Write-Host "[DEBUG] step F26 - avant BasePass3_System" -ForegroundColor Yellow
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
    { "numero": <int>, "titre": "string", "orientation_expert": "string" }
  ]
}


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
- Regrouper les interventions par personne identifiée.
- Chaque entrée de "avis_participants" correspond à UNE PERSONNE DISTINCTE,
  identifiée par son nom et son rôle.
- Ne pas fusionner plusieurs personnes sous un même rôle
  (ex. plusieurs avocats, plusieurs représentants, plusieurs intervenants).
- Ne pas inclure l’expert judiciaire dans avis_participants. Ses constats/positions doivent être intégrés dans synthese_echanges et/ou conclusion_expert selon le cas.


'@
Microsoft.PowerShell.Utility\Write-Host "[DEBUG] step F27 - avant branche Pass3_System selon GlobalContext" -ForegroundColor Yellow
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

Microsoft.PowerShell.Utility\Write-Host "[DEBUG] step F28 - avant branche Pass3_User_Template selon ContextUser" -ForegroundColor Yellow
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


# ── Passe 3E : synthèse PAR SUJET (1 sujet = 1 appel LLM) ─────────────────────
# Objectif : limiter le contexte et favoriser les SLM locaux.
Microsoft.PowerShell.Utility\Write-Host "[DEBUG] step F29 - avant BasePass3E_System" -ForegroundColor Yellow
$BasePass3E_System = @'
Tu es un expert judiciaire chargé de produire une synthèse structurée pour UN SEUL sujet numéroté.

Entrées :
- "numero" et "titre" du sujet
- une liste "interventions" : { "timecode":"HH:MM:SS", "auteur":"...", "role":"...", "texte":"..." }

Objectif :
- regrouper les interventions par participant,
- résumer l’avis de chaque participant,
- rédiger une synthèse globale des échanges,
- proposer une conclusion d’expert (neutre, motivée, factuelle),
- ne pas inventer : si insuffisant, conclure prudemment.
- Chaque entrée de "avis_participants" correspond à UNE PERSONNE DISTINCTE (nom + rôle).
- Ne pas fusionner plusieurs personnes sous un même rôle.
- Ne pas inclure l’expert judiciaire dans "avis_participants".
  Ses constats/positions doivent être intégrés dans "synthese_echanges" et/ou "conclusion_expert" selon le cas.


Réponds STRICTEMENT au format JSON (aucun texte hors JSON) :

{
  "numero": <int>,
  "titre": "string",
  "avis_participants": [
    { "nom": "string", "role": "string", "resume": "string" }
  ],
  "synthese_echanges": "string",
  "conclusion_expert": "string"
}

Normalisation des dates (obligatoire) :
- Interdiction d’écrire des dates au format "YYYY-MM-DD" dans tout champ textuel.
- Si une date doit être citée dans un texte (exception), utiliser "D mois YYYY".

Consigne de rédaction pour la synthèse des échanges :
- La synthèse des échanges doit être structurée en paragraphes.
- Chaque point technique distinct doit faire l’objet d’un paragraphe séparé.
- Insérer un saut de ligne entre chaque paragraphe.
- Pour séparer deux paragraphes dans "synthese_echanges" et "conclusion_expert", utiliser "\n\n".


Consigne de rédaction pour la conclusion de l’expert :
- La conclusion de l’expert doit être rédigée en paragraphes distincts.
- Un paragraphe par idée ou orientation technique.
- Aucun bloc de texte unique.

Un résumé ou une conclusion rédigé en un seul paragraphe sera considéré comme non conforme.


'@

Microsoft.PowerShell.Utility\Write-Host "[DEBUG] step F30 - avant branche Pass3E_System selon GlobalContext" -ForegroundColor Yellow
if ($GlobalContext) {
    $Pass3E_System = @"
$ContextSystem

Mission générale de l'analyse (à respecter strictement) :
$ContextMission
$EtatBlock

$BasePass3E_System
"@
}
else {
    $Pass3E_System = $BasePass3E_System
}

Microsoft.PowerShell.Utility\Write-Host "[DEBUG] step F31 - avant Pass3E_User_Template" -ForegroundColor Yellow
$Pass3E_User_Template = @'
Sujet :
{SUJET_META_JSON}

Interventions rattachées à ce sujet :
{INTERVENTIONS_JSON}

Rappels :
- Ne pas inventer de faits.
- Si aucune intervention : avis_participants=[], synthese_echanges="Aucun échange identifié pour ce sujet.", conclusion_expert prudente.
- Les interventions dont l’auteur est "Expert" et/ou sans timecode peuvent correspondre au débrief post-réunion : à intégrer en priorité dans conclusion_expert, sans les mettre dans avis_participants.

Renvoie uniquement le JSON conforme au schéma.
'@

# ── Passe 2E : condensation intermédiaire par sujet ───────────────────────────
Microsoft.PowerShell.Utility\Write-Host "[DEBUG] step F32 - avant BasePass2E_System" -ForegroundColor Yellow
$BasePass2E_System = @'
Tu es un assistant chargé de produire une synthèse intermédiaire STRICTEMENT factuelle
pour un bloc d’interventions rattachées à un sujet d’expertise judiciaire.

Entrées :
- les métadonnées du sujet ;
- un bloc d’interventions : { "timecode":"HH:MM:SS|null", "auteur":"...", "role":"...", "texte":"..." }

Objectif :
- condenser fidèlement les interventions ;
- conserver les faits utiles à la synthèse finale ;
- relever les points clés, actions évoquées, désaccords, documents demandés et éléments techniques ;
- éliminer les redondances ;
- ne pas rédiger de conclusion d’expert ;
- ne pas produire de compte rendu final ;
- ne rien inventer.

Règles impératives :
- restituer uniquement les éléments explicitement présents dans les interventions ;
- si une information est incertaine, ambiguë ou non attribuable avec certitude, ne pas l’affirmer ;
- ne pas reformuler de manière extensive ;
- ne pas introduire d’analyse juridique ;
- si un champ ne contient aucun élément exploitable, renvoyer un tableau vide ;
- le champ "resume_factuel" doit rester sobre, factuel et synthétique.

Réponds STRICTEMENT au format JSON (aucun texte hors JSON) :

{
  "resume_factuel": "string",
  "points_cles": ["string"],
  "actions": ["string"],
  "desaccords": ["string"],
  "documents_demandes": ["string"],
  "elements_techniques": ["string"]
}

Normalisation des dates :
- ne pas écrire de dates au format "YYYY-MM-DD" dans les champs textuels ;
- si une date doit être mentionnée en texte, utiliser "D mois YYYY".

Contraintes de rédaction :
- "resume_factuel" ne doit pas être une conclusion ;
- "resume_factuel" doit être rédigé en un ou plusieurs paragraphes courts si nécessaire ;
- les listes doivent être brèves, sans doublons, sans invention.
'@

Microsoft.PowerShell.Utility\Write-Host "[DEBUG] step F33 - avant branche Pass2E_System selon GlobalContext" -ForegroundColor Yellow
if ($GlobalContext) {
    $Pass2E_System = @"
$ContextSystem

Mission générale de l'analyse (à respecter strictement) :
$ContextMission
$EtatBlock

$BasePass2E_System
"@
}
else {
    $Pass2E_System = $BasePass2E_System
}

# 3D : demandes de documents
Microsoft.PowerShell.Utility\Write-Host "[DEBUG] step F34 - avant BasePass3D_System" -ForegroundColor Yellow
$BasePass3D_System = @'
Tu reçois le JSON "global" d'une réunion d’expertise judiciaire.

Tu dois extraire UNIQUEMENT toutes les demandes de documents ou d’informations à fournir.

Réponds STRICTEMENT par un JSON respectant ce schéma :

{
  "demandes_documents_globales": [
    {
      "numero": "int | null",
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
- Si la demande vise explicitement une réserve/repère (ex. “RS14”, “R15”), et que ce repère correspond à un titre de sujet, renseigner numero. Sinon null.
- Si la demande est explicitement rattachée à un sujet numéroté (ex : ‘Sujet 12’, ‘Point 12’, ‘12 - …’), renseigner numero. Sinon null.

Normalisation des dates (obligatoire) :
- "echeance" est le seul endroit où une date peut apparaître au format "YYYY-MM-DD".
- Ne jamais écrire de date "YYYY-MM-DD" dans "objet", "commentaire", "demandeur", "destinataire".
- Si une date doit être mentionnée dans un texte (exception), utiliser "D mois YYYY".


'@
Microsoft.PowerShell.Utility\Write-Host "[DEBUG] step F35 - avant branche Pass3D_System selon GlobalContext" -ForegroundColor Yellow
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

Microsoft.PowerShell.Utility\Write-Host "[DEBUG] step F36 - avant Pass3D_User_Template" -ForegroundColor Yellow
$Pass3D_User_Template = @'
Voici le JSON global issu de la fusion des segments :

{GLOBAL_JSON}

Renvoie uniquement un JSON contenant le champ "demandes_documents_globales".
'@

Microsoft.PowerShell.Utility\Write-Host "[DEBUG] step F37 - avant MergeGlobal_System" -ForegroundColor Yellow
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

    Microsoft.PowerShell.Utility\Write-Host ("[DEBUG] Entrée Get-IntelligentSegments : rows={0} ; chunkSize={1}" -f @($rows).Count, $ChunkSize) -ForegroundColor Yellow
    $segments = New-Object System.Collections.Generic.List[object]

    $total = $rows.Count
    if ($total -eq 0) {
        Microsoft.PowerShell.Utility\Write-Host "[DEBUG] Sortie Get-IntelligentSegments : aucun row, retour vide" -ForegroundColor Yellow
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
        Microsoft.PowerShell.Utility\Write-Host ("[DEBUG] Avant écriture log segmentation : {0}" -f $logPath) -ForegroundColor Yellow
        $txt = "Segments (ChunkSize=$ChunkSize) générés : $($segments.Count)"
        [System.IO.File]::WriteAllText($logPath, $txt, [System.Text.Encoding]::UTF8)
        Microsoft.PowerShell.Utility\Write-Host ("[DEBUG] Après écriture log segmentation : {0}" -f $logPath) -ForegroundColor Yellow
    }

    Microsoft.PowerShell.Utility\Write-Host ("[DEBUG] Sortie Get-IntelligentSegments : segments={0}" -f $segments.Count) -ForegroundColor Yellow
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


Microsoft.PowerShell.Utility\Write-Host ("[DEBUG] Début chargement transcription / segmentation : {0}" -f $CsvPath) -ForegroundColor Yellow
Microsoft.PowerShell.Utility\Write-Host "Lecture CSV: $CsvPath"

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

Microsoft.PowerShell.Utility\Write-Host ("[DEBUG] Avant enrichissement __sec / tri : rows={0}" -f @($rows).Count) -ForegroundColor Yellow
$rows = $rows | ForEach-Object {
    $sec = Hms-To-Seconds $_.$colTime
    $_ | Add-Member -NotePropertyName __sec -NotePropertyValue $sec -Force
    $_ | Add-Member -NotePropertyName __time_hms -NotePropertyValue (Seconds-To-Hms $sec) -Force
    $_
} | Sort-Object __sec
Microsoft.PowerShell.Utility\Write-Host ("[DEBUG] Après enrichissement __sec / tri : rows={0}" -f @($rows).Count) -ForegroundColor Yellow
if($rows.Count -eq 0){ throw "CSV vide." }


# maxSec = max(end) si end existe, sinon max(start)
$maxSec = 0.0
foreach($r in $rows){
  $s = [double](([string]$r.$colTime).Trim().Replace(',', '.'))
  $cand = $s

  if($r.PSObject.Properties.Name -contains $colEnd -and -not [string]::IsNullOrWhiteSpace([string]$r.$colEnd)){
    $e = [double](([string]$r.$colEnd).Trim().Replace(',', '.'))
    $cand = $e
  }
  if($cand -gt $maxSec){ $maxSec = $cand }
}
$maxSecInt = [int][math]::Ceiling($maxSec)




# ── Segmentation intelligente enrichie ─────────────────────────────────────────

# Choix de ChunkSize en fonction du mode (local vs remote Passe 1A)
if ($Provider -ieq "openai" -and $ModelPass1 -eq "annoter_segments_remote") {
    $ChunkSize = 60    # remote : segments plus gros
} else {
    $ChunkSize = 25    # local : segments plus petits
}

$segLog  = Join-Path $logsDir "segments_debug.log"
Microsoft.PowerShell.Utility\Write-Host ("[DEBUG] Avant appel Get-IntelligentSegments : rows={0} ; chunkSize={1} ; segLog={2}" -f @($rows).Count, $ChunkSize, $segLog) -ForegroundColor Yellow
$segments = Get-IntelligentSegments `
    -rows       $rows `
    -colTime    $colTime `
    -colSpeaker $colSpeaker `
    -colText    $colText `
    -logPath    $segLog `
    -ChunkSize  $ChunkSize

Microsoft.PowerShell.Utility\Write-Host ("Nombre de segments (ChunkSize={0}) : {1}" -f $ChunkSize, $segments.Count)
Microsoft.PowerShell.Utility\Write-Host ("[DEBUG] Fin segmentation : rows={0} ; segments={1} ; chunkSize={2}" -f @($rows).Count, @($segments).Count, $ChunkSize) -ForegroundColor Yellow
if($SegDebug){ Microsoft.PowerShell.Utility\Write-Host ("Log segmentation → $segLog") }

# ── Passe 1A : mini-CR par segment (JSON strict) ───────────────────────────────
$segmentJsonPaths = New-Object System.Collections.Generic.List[object]
Microsoft.PowerShell.Utility\Write-Host ("[DEBUG] Début première passe 1A : segments={0}" -f @($segments).Count) -ForegroundColor Yellow

for($i=0; $i -lt $segments.Count; $i++){
    $seg = $segments[$i]
    $segOut = Join-Path $OutDir ("segments/segment_{0:D2}.json" -f ($i+1))
    $startH = Seconds-To-Hms ($seg[0].__sec)
    $endH   = Seconds-To-Hms ($seg[-1].__sec)

    if((Test-Path $segOut) -and (-not $Force)){
        Microsoft.PowerShell.Utility\Write-Host "Skip segment $($i+1) (existe) → $segOut"
        $segmentJsonPaths.Add($segOut)
        continue
    }

    Microsoft.PowerShell.Utility\Write-Host ("Passe 1A → Segment {0:D2}  [{1} → {2}]" -f ($i+1), $startH, $endH)

    # Construction du prompt utilisateur brut
    $lines = $seg | ForEach-Object {
        $lineTime = if ($_.PSObject.Properties['__time_hms'] -and $_.__time_hms) { $_.__time_hms } else { [string]$_.$colTime }
        "[{0}] {1}: {2}" -f $lineTime, $_.$colSpeaker, $_.$colText
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
      Write-Warning ("Segment {0:D2} : Invoke-LLM a échoué ({1}) → JSON minimal." -f ($i+1), $_.Exception.Message)

      $fallbackObj = [pscustomobject]@{
          segment_id = ("segment_{0:D2}" -f ($i+1))
          sujets     = @{}
      }
      $jsonStr = $fallbackObj | ConvertTo-Json -Depth 20


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
      Write-Warning ("Segment {0:D2} : réponse vide → JSON minimal." -f ($i+1))

      $fallbackObj = [pscustomobject]@{
          segment_id = ("segment_{0:D2}" -f ($i+1))
          sujets     = @{}
      }
      $jsonStr = $fallbackObj | ConvertTo-Json -Depth 20


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

        $fallbackObj = [pscustomobject]@{
            segment_id = ("segment_{0:D2}" -f ($i+1))
            sujets     = @{}
        }
        $jsonStr = $fallbackObj | ConvertTo-Json -Depth 20

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

$Global:DebriefObj = $null
$DebriefObj = $null

if ($CsvDebriefPath) {
    Microsoft.PowerShell.Utility\Write-Host "Passe 1B → Analyse du débrief expert : $CsvDebriefPath"

    if (!(Test-Path $CsvDebriefPath)) {
        Write-Warning "CsvDebriefPath indiqué mais fichier introuvable : $CsvDebriefPath"
        $Global:DebriefObj = $DebriefObj
    }
    else {
        # On suppose les mêmes colonnes : start / speaker / text
        $rowsDebrief = Import-Csv -Path $CsvDebriefPath -Delimiter ';'

        $debriefColTime    = 'start'
        $debriefColSpeaker = 'speaker'
        $debriefColText    = 'text'

        # Vérif minimale
        if (-not $rowsDebrief -or $rowsDebrief.Count -eq 0) {
            Write-Warning "Débrief : CSV vide, aucune analyse effectuée."
            $Global:DebriefObj = $DebriefObj

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

            Write-ArtifactText -Path $debriefPromptPath -Text $debriefUser -ModelName $ModelReport

            Write-ArtifactText -Path $debriefSystemPath -Text $Debrief_System -ModelName $ModelReport
            # Contrôle n_ctx
            $debriefUser_Effective = Enforce-ContextLimit `
                -SystemPrompt $Debrief_System `
                -UserPrompt   $debriefUser `
                -Label        "Debrief expert" `
                -LogFile      $logFile `
                -ModelName    $ModelReport

            $debriefEffPath = Join-Path $logsDir "debrief_prompt_effective.txt"
            Write-ArtifactText -Path $debriefEffPath -Text $debriefUser_Effective -ModelName $ModelReport

            # Appel LLM (on utilise le modèle "remote" de passe 3 pour ce travail global)
            $debriefRaw = Invoke-LLM -system $Debrief_System -user $debriefUser_Effective -model $ModelReport -DebugHttp:$DebugHttp
            Write-ArtifactText -Path (Join-Path $logsDir "debrief_raw.txt") -Text $debriefRaw -ModelName $ModelReport

            try {
                $DebriefObj = Parse-LlmJsonStrict -RawText $debriefRaw -Label "Debrief" -LogFile $logFile
            }
            catch {
                Write-Warning "Échec parsing JSON Débrief, fallback sujet/demandes vides."
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

            Microsoft.PowerShell.Utility\Write-Host "Débrief expert analysé → $debriefPath"
            $Global:DebriefObj = $DebriefObj
            # On garde aussi en global pour éventuelle réutilisation en Passe 3
        }
    }
}
else {
    Microsoft.PowerShell.Utility\Write-Host "Passe 1B ignorée (aucun CsvDebriefPath fourni)."
}

# Alias local (si vous souhaitez n'utiliser que $DebriefObj ensuite)
$DebriefObj = $Global:DebriefObj # optionnel, mais alors vous n'utilisez plus que $DebriefObj ensuite


# ── Passe 2A : agrégation par sujet (JSON strict) ─────────────────────────────
Microsoft.PowerShell.Utility\Write-Host "Passe 2A → Agrégation par sujet"

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
        Write-Warning "JSON invalide ignoré : $p"
    }
}

if (-not $segmentsObjs -or $segmentsObjs.Count -eq 0) {
    throw "Passe 2A : aucun segment exploitable (segmentsObjs vide)."
}

# Agrégation par numéro de sujet
$bySujet = Aggregate-Sujets -Segments $segmentsObjs -MaxSec $maxSecInt

if ($Sujets) {
  $bySujet = Add-MultiSubjectAssignments -BySujet $bySujet -Sujets $Sujets -LogFile $logFile
}


if ($Global:DebriefObj) {
  $tmp = Inject-DebriefIntoBySujet -BySujet $bySujet -DebriefObj $Global:DebriefObj
  if ($null -ne $tmp) { $bySujet = $tmp }
  Microsoft.PowerShell.Utility\Write-Host "Débrief injecté dans bySujet (matière expert pour Pass3E)."
}



# Contrôle immédiatement après agrégation/injection
if (-not ($bySujet -is [hashtable])) {
  throw "Passe 2A : bySujet n'est pas un hashtable après agrégation/injection."
}

foreach($k in @($bySujet.Keys)){
  $list = @($bySujet[$k])
  for($i=0; $i -lt $list.Count; $i++){
    $iv = $list[$i]
    if($iv -and $iv.PSObject.Properties['timecode']){
      try {
        $iv.timecode = Normalize-InterventionTimecode -Timecode ([string]$iv.timecode) -MaxSec $maxSecInt
      } catch {
        $iv.timecode = $null
      }
    }
  }
  $bySujet[$k] = $list
}
# ─────────────────────────────────────────────────────────────
# Injection du Débrief avant global.json
# ─────────────────────────────────────────────────────────────


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
Microsoft.PowerShell.Utility\Write-Host "Agrégation Passe 2A OK → $globalPath"



#-------------------------------------------------------------------------
# ── Passe 2B : construire le global "réunion" PAR BATCHS de segments ─────────
#-------------------------------------------------------------------------

Microsoft.PowerShell.Utility\Write-Host "Passe 2B → Construction du GLOBAL réunion (par batches de $Pass2BatchSize segments)"
if ($OnlyPass2BBatches -and @($OnlyPass2BBatches).Count -gt 0) {
  Microsoft.PowerShell.Utility\Write-Host ("Pass2B reprise ciblée → batch(es) {0}" -f ((@($OnlyPass2BBatches) | Sort-Object -Unique) -join ","))
  if ($RebuildFromPass2B) {
    Microsoft.PowerShell.Utility\Write-Host "RebuildFromPass2B actif → global_meeting, Pass2E, Pass3E, global_by_sujet et global_final seront reconstruits"
  }
}
elseif ($RebuildPass2BOnly) {
  Microsoft.PowerShell.Utility\Write-Host "Pass2B reprise ciblée → tous les batches Pass2B existants seront recalculés"
}
elseif ($RebuildFromPass2B) {
  Microsoft.PowerShell.Utility\Write-Host "RebuildFromPass2B actif → aval Pass2B reconstruit sans forcer Pass1A"
}

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
function Merge-MeetingBatchObjects {
  param([object[]]$MeetingObjs)

  $allBatchObjs = @($MeetingObjs | Where-Object { $null -ne $_ })
  if (-not $allBatchObjs -or $allBatchObjs.Count -eq 0) {
    return Normalize-MeetingBatchObj $null
  }

  $resumes = @($allBatchObjs | ForEach-Object { $_.resume_global } | Where-Object { $_ -and $_.Trim() -ne "" })
  $resumeBest = ""
  if ($resumes.Count -gt 0) {
    $resumeBest = ($resumes | Sort-Object Length -Descending | Select-Object -First 1)
  }

  return [pscustomobject]@{
    resume_global              = $resumeBest
    themes                     = Merge-ListUnique ($allBatchObjs | ForEach-Object { $_.themes })
    themes_abordes             = Merge-ListUnique ($allBatchObjs | ForEach-Object { $_.themes_abordes })
    actions                    = Merge-ListUnique ($allBatchObjs | ForEach-Object { $_.actions })
    perspectives               = Merge-ListUnique ($allBatchObjs | ForEach-Object { $_.perspectives })
    demandes_documents_globales= Merge-ListUnique ($allBatchObjs | ForEach-Object { $_.demandes_documents_globales })
    problems                   = Merge-ListUnique ($allBatchObjs | ForEach-Object { $_.problems })
  }
}

function Get-Pass2BInputDiagnostics {
  param([object[]] $BatchSeg, [object] $BatchObj)

  $batchThemesCount   = ($BatchSeg | ForEach-Object {
    if ($_ -and $_.PSObject.Properties['themes']) { (@($_.themes) | Measure-Object).Count } else { 0 }
  } | Measure-Object -Sum).Sum
  $batchActionsCount  = ($BatchSeg | ForEach-Object {
    if ($_ -and $_.PSObject.Properties['actions']) { (@($_.actions) | Measure-Object).Count } else { 0 }
  } | Measure-Object -Sum).Sum
  $batchProblemsCount = ($BatchSeg | ForEach-Object {
    if ($_ -and $_.PSObject.Properties['problems']) { (@($_.problems) | Measure-Object).Count } else { 0 }
  } | Measure-Object -Sum).Sum
  $batchTextLen = (
    $BatchSeg |
    ForEach-Object {
      $txt = ""
      if ($_.PSObject.Properties['resume_global'] -and $_.resume_global) {
        $txt += ($_.resume_global | Out-String)
      }
      if ($_.PSObject.Properties['resume_segment'] -and $_.resume_segment) {
        $txt += ($_.resume_segment | Out-String)
      }
      $txt.Length
    } | Measure-Object -Sum
  ).Sum

  $resultThemes   = if ($BatchObj -and $BatchObj.PSObject.Properties['themes']) { (@($BatchObj.themes) | Measure-Object).Count } else { 0 }
  $resultActions  = if ($BatchObj -and $BatchObj.PSObject.Properties['actions']) { (@($BatchObj.actions) | Measure-Object).Count } else { 0 }
  $resultProblems = if ($BatchObj -and $BatchObj.PSObject.Properties['problems']) { (@($BatchObj.problems) | Measure-Object).Count } else { 0 }
  $resultTextLen  = if ($BatchObj -and $BatchObj.PSObject.Properties['resume_global']) { ([string]$BatchObj.resume_global | Out-String).Length } else { 0 }

  $inputRich   = ($batchThemesCount + $batchActionsCount + $batchProblemsCount + $batchTextLen)
  $resultEmpty = ($resultThemes -eq 0 -and $resultActions -eq 0 -and $resultProblems -eq 0 -and $resultTextLen -eq 0)

  return [pscustomobject]@{
    InputRich   = $inputRich
    ResultEmpty = $resultEmpty
  }
}

function New-Pass2BLocalFallback {
  param([object[]] $BatchSeg)

  $fallback = [pscustomobject]@{
    resume_global = (
      $BatchSeg |
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

  $fallback.themes   = $BatchSeg | ForEach-Object { $_.themes }   | Where-Object { $_ }
  $fallback.actions  = $BatchSeg | ForEach-Object { $_.actions }  | Where-Object { $_ }
  $fallback.problems = $BatchSeg | ForEach-Object { $_.problems } | Where-Object { $_ }

  return $fallback
}

function Invoke-Pass2BBatchAttempt {
  param(
    [int] $BatchIndex,
    [string] $AttemptId,
    [object[]] $BatchSeg,
    [string] $BatchBase,
    [string] $Pass2BDir,
    [string] $LogFile,
    [string] $ApiBase,
    [string] $ModelReport,
    [string] $Pass2BSystem,
    [string] $Pass2BUserTemplate,
    [bool] $DebugHttp = $false
  )

  $safeAttemptId = if ([string]::IsNullOrWhiteSpace($AttemptId)) { "main" } else { $AttemptId }
  $attemptBase = if ($safeAttemptId -eq "main") { $BatchBase } else { "${BatchBase}_${safeAttemptId}" }
  $attemptOut = if ($safeAttemptId -eq "main") { "${BatchBase}.json" } else { "${attemptBase}.json" }
  $promptPath = "${attemptBase}_prompt.txt"
  $systemPath = "${attemptBase}_system.txt"
  $rawPath    = "${attemptBase}_raw.txt"
  $metaPath   = "${attemptBase}_meta.json"
  $errorPath  = "${attemptBase}_error.txt"

  $batchSegJson = $BatchSeg | ConvertTo-Json -Depth 50 -Compress
  $pass2BUser   = $Pass2BUserTemplate.Replace("{SEGMENTS_JSON}", $batchSegJson)
  $pass2BUser_Effective = Enforce-ContextLimit `
    -SystemPrompt $Pass2BSystem `
    -UserPrompt   $pass2BUser `
    -Label        ("Pass2B batch {0:D2} [{1}]" -f $BatchIndex, $safeAttemptId) `
    -LogFile      $LogFile `
    -ModelName    $ModelReport

  $wasTruncated = ($pass2BUser_Effective -ne $pass2BUser)

  Write-ArtifactText -Path $promptPath -Text $pass2BUser_Effective -ModelName $ModelReport
  Write-ArtifactText -Path $systemPath -Text $Pass2BSystem -ModelName $ModelReport

  $meta = [pscustomobject]@{
    batch          = $BatchIndex
    attempt        = $safeAttemptId
    segment_count  = @($BatchSeg).Count
    model          = $ModelReport
    apiBase        = $ApiBase
    was_truncated  = $wasTruncated
    timestamp      = (Get-Date).ToString("o")
  }
  [System.IO.File]::WriteAllText($metaPath, ($meta | ConvertTo-Json -Depth 10), $utf8NoBom)

  $batchObj = $null
  $raw = $null
  $outputTruncated = $false

  try {
    $raw = Invoke-LLM -system $Pass2BSystem -user $pass2BUser_Effective -model $ModelReport -DebugHttp:$DebugHttp
    if (-not $raw -or $raw.Trim().Length -eq 0) { throw "R?ponse LLM vide" }
    Write-ArtifactText -Path $rawPath -Text $raw -ModelName $ModelReport
  }
  catch {
    $errTxt = ($_ | Out-String)
    if ($errTxt -match 'finish_reason=length' -or $errTxt -match 'Upstream truncated') {
      $outputTruncated = $true
    }
    [IO.File]::WriteAllText($errorPath, $errTxt, [Text.Encoding]::UTF8)
    Write-ArtifactText -Path $rawPath -Text $errTxt -ModelName $ModelReport
    Write-Warning ("Pass2B batch {0:D2} [{1}]: ?chec Invoke-LLM (voir {2})." -f $BatchIndex, $safeAttemptId, $errorPath)
    $raw = $null
  }

  if ($raw) {
    try {
      $batchObj = Parse-LlmJsonStrict -RawText $raw -Label ("Pass2B batch {0:D2} [{1}]" -f $BatchIndex, $safeAttemptId) -LogFile $LogFile
    }
    catch {
      $errTxt = ($_ | Out-String)
      [IO.File]::WriteAllText($errorPath, $errTxt, [Text.Encoding]::UTF8)
      Write-Warning ("Pass2B batch {0:D2} [{1}]: JSON non parsable (voir {2})." -f $BatchIndex, $safeAttemptId, $errorPath)
      $batchObj = $null
    }
  }

  $batchObj = Normalize-MeetingBatchObj $batchObj
  $diag = Get-Pass2BInputDiagnostics -BatchSeg $BatchSeg -BatchObj $batchObj
  if ($diag.InputRich -gt 0 -and $diag.ResultEmpty) {
    $outputTruncated = $true
    Write-Warning ("Pass2B batch {0:D2} [{1}]: sortie vide malgré une entrée riche." -f $BatchIndex, $safeAttemptId)
  }
  [System.IO.File]::WriteAllText($attemptOut, ($batchObj | ConvertTo-Json -Depth 50), $utf8NoBom)

  return [pscustomobject]@{
    BatchObj      = $batchObj
    WasTruncated  = ($wasTruncated -or $outputTruncated)
    PromptTruncated = $wasTruncated
    OutputTruncated = $outputTruncated
    InputRich     = $diag.InputRich
    ResultEmpty   = $diag.ResultEmpty
    SegmentCount  = @($BatchSeg).Count
    AttemptId     = $safeAttemptId
    OutputPath    = $attemptOut
  }
}

function Invoke-Pass2BAdaptiveBatch {
  param(
    [int] $BatchIndex,
    [object[]] $BatchSeg,
    [int] $RequestedSize,
    [string] $BatchBase,
    [string] $Pass2BDir,
    [string] $LogFile,
    [string] $ApiBase,
    [string] $ModelReport,
    [string] $Pass2BSystem,
    [string] $Pass2BUserTemplate,
    [bool] $DebugHttp = $false,
    [string] $AttemptId = "main"
  )

  $attempt = Invoke-Pass2BBatchAttempt `
    -BatchIndex $BatchIndex `
    -AttemptId $AttemptId `
    -BatchSeg $BatchSeg `
    -BatchBase $BatchBase `
    -Pass2BDir $Pass2BDir `
    -LogFile $LogFile `
    -ApiBase $ApiBase `
    -ModelReport $ModelReport `
    -Pass2BSystem $Pass2BSystem `
    -Pass2BUserTemplate $Pass2BUserTemplate `
    -DebugHttp:$DebugHttp

  if (@($BatchSeg).Count -le 1) {
    if ($attempt.ResultEmpty -and $attempt.InputRich -gt 0) {
      Write-Warning ("Pass2B batch {0:D2}: batch unitaire avec sortie vide persistante, fallback local de fusion simple." -f $BatchIndex)
      return (Normalize-MeetingBatchObj (New-Pass2BLocalFallback -BatchSeg $BatchSeg))
    }
    return $attempt.BatchObj
  }

  if (-not $attempt.WasTruncated) {
    return $attempt.BatchObj
  }

  $nextSize = 1
  if ($RequestedSize -gt 2) {
    $nextSize = 2
  } elseif ($RequestedSize -gt 1) {
    $nextSize = 1
  }

  if ($nextSize -ge @($BatchSeg).Count) {
    $nextSize = @($BatchSeg).Count - 1
  }
  if ($nextSize -lt 1) {
    return $attempt.BatchObj
  }

  if ($attempt.OutputTruncated -and -not $attempt.PromptTruncated) {
    Write-Warning ("Pass2B batch {0:D2}: troncature de sortie d?tect?e, relance s?lective en sous-batches de {1}." -f $BatchIndex, $nextSize)
  } else {
    Write-Warning ("Pass2B batch {0:D2}: prompt tronqu? d?tect?, relance s?lective en sous-batches de {1}." -f $BatchIndex, $nextSize)
  }

  $subObjs = New-Object System.Collections.Generic.List[object]
  $subCount = [math]::Ceiling(@($BatchSeg).Count / [double]$nextSize)
  for ($sub = 0; $sub -lt $subCount; $sub++) {
    $subFrom = $sub * $nextSize
    $subTo = [math]::Min($subFrom + $nextSize - 1, @($BatchSeg).Count - 1)
    $subSeg = @($BatchSeg[$subFrom..$subTo])
    $subAttemptId = "retry_s{0}_{1:D2}" -f $nextSize, ($sub + 1)
    $subObj = Invoke-Pass2BAdaptiveBatch `
      -BatchIndex $BatchIndex `
      -BatchSeg $subSeg `
      -RequestedSize $nextSize `
      -BatchBase $BatchBase `
      -Pass2BDir $Pass2BDir `
      -LogFile $LogFile `
      -ApiBase $ApiBase `
      -ModelReport $ModelReport `
      -Pass2BSystem $Pass2BSystem `
      -Pass2BUserTemplate $Pass2BUserTemplate `
      -DebugHttp:$DebugHttp `
      -AttemptId $subAttemptId
    $subObjs.Add($subObj) | Out-Null
  }

  return (Merge-MeetingBatchObjects $subObjs.ToArray())
}

function Convert-DebriefToMeetingGlobal {
  param([object] $DebriefObj)

  # Base vide conforme
  $out = [pscustomobject]@{
    resume_global              = ""
    themes                     = @()
    themes_abordes             = @()
    actions                    = @()
    perspectives               = @()
    demandes_documents_globales= @()
    problems                   = @()
    annexes                    = @()
  }

  if (-not $DebriefObj) { return $out }

  $gd = $null
  if ($DebriefObj.PSObject.Properties['global_debrief']) { $gd = $DebriefObj.global_debrief }
  if (-not $gd) { return $out }

  # 1) Resume
  if ($gd.PSObject.Properties['resume'] -and $gd.resume) {
    $out.resume_global = [string]$gd.resume
  }

  # 2) Themes_abordes (si vous voulez les conserver)
  if ($gd.PSObject.Properties['themes_abordes'] -and $gd.themes_abordes) {
    $out.themes_abordes = @($gd.themes_abordes)
  }
  # 3) Themes (format meeting) : accepter string OU objet
  if ($gd.PSObject.Properties['themes_abordes'] -and $gd.themes_abordes) {
    $tmpThemes = New-Object System.Collections.Generic.List[object]
    foreach ($t in @($gd.themes_abordes)) {
      if (-not $t) { continue }

      $titre = ""
      $syn   = @()

      if ($t -is [string]) {
        $titre = ([string]$t).Trim()
      } else {
        if ($t.PSObject.Properties['titre']) { $titre = ([string]$t.titre).Trim() }
        if ($t.PSObject.Properties['synthese'] -and $t.synthese) { $syn = @($t.synthese) }
      }

      if ($titre) {
        $tmpThemes.Add([pscustomobject]@{ titre=$titre; synthese=$syn; timecodes=@() }) | Out-Null
      }
    }
    $out.themes = $tmpThemes.ToArray()
  }
  

  # 4) Actions
  if ($gd.PSObject.Properties['actions'] -and $gd.actions) {
    # vos actions debrief ont déjà (action,responsable,echeance,commentaire)
    $out.actions = @($gd.actions)
  }

  # 5) Problems (depuis perspectives du debrief)
  if ($gd.PSObject.Properties['perspectives'] -and $gd.perspectives) {
    foreach ($p in @($gd.perspectives)) {
    $pr = if ($p.PSObject.Properties['probleme']) { ([string]$p.probleme).Trim() } else { "" }
    $so = if ($p.PSObject.Properties['solution']) { ([string]$p.solution).Trim() } else { $null }
      if ($pr) {
        $tmp.Add([pscustomobject]@{ probleme = $pr; solution = $so }) | Out-Null
      }
    }
    $out.problems = $tmp.ToArray()
  }

  # 6) Annexes
  if ($gd.PSObject.Properties['annexes'] -and $gd.annexes) {
    $out.annexes = @($gd.annexes)
  }

  # 7) Demandes de documents : depuis DebriefObj.sujets + hors_sujet
  $docs = New-Object System.Collections.Generic.List[object]

  # a) docs par sujet
  if ($DebriefObj.PSObject.Properties['sujets'] -and $DebriefObj.sujets) {
    foreach ($sj in @($DebriefObj.sujets)) {
      if (-not $sj) { continue }
      $num = $null
      if ($sj.PSObject.Properties['numero']) { try { $num = [int]$sj.numero } catch { $num = $null } }

      if ($sj.PSObject.Properties['demandes_documents'] -and $sj.demandes_documents) {
        foreach ($d in @($sj.demandes_documents)) {
          if (-not $d) { continue }
          $obj = if ($d.PSObject.Properties['objet']) { [string]$d.objet } else { "" }
          if ([string]::IsNullOrWhiteSpace($obj)) { continue }

          $docs.Add([pscustomobject]@{
            objet        = $obj
            demandeur    = $null
            destinataire = $null
            echeance     = if ($d.PSObject.Properties['echeance']) { $d.echeance } else { $null }
            timecodes    = @()
            numero       = $num
          }) | Out-Null
        }
      }
    }
  }

  # b) docs hors sujet
  if ($DebriefObj.PSObject.Properties['demandes_documents_hors_sujet'] -and $DebriefObj.demandes_documents_hors_sujet) {
    foreach ($d in @($DebriefObj.demandes_documents_hors_sujet)) {
      if (-not $d) { continue }
      $obj = if ($d.PSObject.Properties['objet']) { [string]$d.objet } else { "" }
      if ([string]::IsNullOrWhiteSpace($obj)) { continue }

      $docs.Add([pscustomobject]@{
        objet        = $obj
        demandeur    = $null
        destinataire = $null
        echeance     = if ($d.PSObject.Properties['echeance']) { $d.echeance } else { $null }
        timecodes    = @()
        numero       = $null
      }) | Out-Null
    }
  }

  # si Merge-ListUnique existe déjà chez vous, vous pouvez dédupliquer via lui.
  $out.demandes_documents_globales = $docs.ToArray()

  return $out
}
function Normalize-DocRequestsToPass2BSchema {
  param(
    [Parameter(Mandatory=$true)]
    [object]$meetingGlobal
  )
  if (-not ($meetingGlobal.PSObject.Properties.Name -contains "demandes_documents_globales")) {
    $meetingGlobal | Add-Member -NotePropertyName "demandes_documents_globales" -NotePropertyValue @()
  }

  $norm = @()
  foreach ($d in @($meetingGlobal.demandes_documents_globales)) {

    # Support de plusieurs noms possibles (selon vos conversions)
    function First-NonEmpty {
      param([object[]]$Values)
      foreach ($v in $Values) {
        if ($null -ne $v -and "$v".Trim() -ne "") {
          return [string]$v
        }
      }
      return ""
    }
    $objet        = First-NonEmpty @($d.objet, $d.document, $d.demande)
    $demandeur    = First-NonEmpty @($d.demandeur, $d.emetteur)
    $destinataire = First-NonEmpty @($d.destinataire, $d.cible)
    $echeance     = First-NonEmpty @($d.echeance, $d.date_limite)


    # timecodes : doit toujours être une liste (même vide)
    $tcs = @()
    if ($d.PSObject.Properties.Name -contains "timecodes" -and $d.timecodes) {
      $tcs = @($d.timecodes | ForEach-Object { "$_" }) | Where-Object { $_ -ne "" }
    } elseif ($d.PSObject.Properties.Name -contains "timecode" -and $d.timecode) {
      $tcs = @("$($d.timecode)")
    }

    # Conserver éventuellement les champs extra dans "meta" (optionnel)
    $meta = [pscustomobject]@{}
    foreach ($k in @("numero","commentaire","origine","source","contexte")) {
      if ($d.PSObject.Properties.Name -contains $k) {
        $meta | Add-Member -NotePropertyName $k -NotePropertyValue $d.$k -Force
      }
    }

    $norm += [pscustomobject]@{
      objet        = $objet.Trim()
      demandeur    = $demandeur.Trim()
      destinataire = $destinataire.Trim()
      echeance     = $echeance.Trim()
      timecodes    = $tcs
      meta         = $meta  # supprimez cette ligne si vous ne voulez aucun champ extra
    }
  }

  $meetingGlobal.demandes_documents_globales = $norm
  return $meetingGlobal
}

function Assert-MeetingSchema {
  param(
    [Parameter(Mandatory=$true)] [object] $MeetingObj,
    [string] $Label = "globalMeetingMerged",
    [switch] $ThrowOnError
  )

  $errors = New-Object System.Collections.Generic.List[string]

  if (-not $MeetingObj) {
    $errors.Add("Objet null.") | Out-Null
  }
  else {

    # 1) Définition des champs attendus + valeurs par défaut
    $expected = @(
      @{ name="resume_global";                kind="string"; default=""  },
      @{ name="themes";                      kind="list";   default=@() },
      @{ name="actions";                     kind="list";   default=@() },
      @{ name="problems";                    kind="list";   default=@() },
      @{ name="demandes_documents_globales"; kind="list";   default=@() }
    )

    foreach ($e in $expected) {
      $p = $MeetingObj.PSObject.Properties[$e.name]

      # 2) AJOUT si champ manquant
      if (-not $p) {
        $MeetingObj | Add-Member -Force NoteProperty $e.name $e.default
        $errors.Add(("Champ manquant ajouté: {0}" -f $e.name)) | Out-Null
        $p = $MeetingObj.PSObject.Properties[$e.name]
      }

      $v = $p.Value

      # 3) Normalisation de type
      if ($e.kind -eq "string") {
        if ($null -eq $v) { $MeetingObj.$($e.name) = "" }
        elseif ($v -isnot [string]) { $MeetingObj.$($e.name) = [string]$v }
      }
      elseif ($e.kind -eq "list") {
        if ($null -eq $v) { $MeetingObj.$($e.name) = @() }
        elseif ($v -is [string]) { $MeetingObj.$($e.name) = @([string]$v) }
        elseif ($v -isnot [System.Collections.IEnumerable]) { $MeetingObj.$($e.name) = @($v) }
        else { $MeetingObj.$($e.name) = @($v) }  # force array PowerShell
      }
    }

    # 4) Assainissement minimal des themes[]
    $cleanThemes = New-Object System.Collections.Generic.List[object]
    foreach ($t in @($MeetingObj.themes)) {
      if (-not $t) { continue }

      # garantir 'titre'
      if (-not $t.PSObject.Properties['titre']) {
        $t | Add-Member -Force NoteProperty titre ""
        $errors.Add("themes[]: 'titre' manquant ajouté (vide).") | Out-Null
      }
      elseif ($t.titre -isnot [string]) {
        $t.titre = [string]$t.titre
      }

      # garantir 'synthese' (liste)
      if (-not $t.PSObject.Properties['synthese']) {
        $t | Add-Member -Force NoteProperty synthese @()
      }
      else {
        $sv = $t.synthese
        if ($null -eq $sv) { $t.synthese = @() }
        elseif ($sv -is [string]) { $t.synthese = @([string]$sv) }
        elseif ($sv -isnot [System.Collections.IEnumerable]) { $t.synthese = @($sv) }
        else { $t.synthese = @($sv) }
      }

      # garantir 'timecodes' (liste)
      if (-not $t.PSObject.Properties['timecodes']) {
        $t | Add-Member -Force NoteProperty timecodes @()
      }
      else {
        $tv = $t.timecodes
        if ($null -eq $tv) { $t.timecodes = @() }
        elseif ($tv -is [string]) { $t.timecodes = @([string]$tv) }
        elseif ($tv -isnot [System.Collections.IEnumerable]) { $t.timecodes = @($tv) }
        else { $t.timecodes = @($tv) }
      }

      $cleanThemes.Add($t) | Out-Null
    }
    $MeetingObj.themes = $cleanThemes.ToArray()
  }

  # 5) Reporting
  if ($errors.Count -gt 0) {
    Write-Warning ("Assert-MeetingSchema({0}) : {1} ajustement(s) / anomalie(s)." -f $Label, $errors.Count)
    foreach ($m in $errors) { Write-Warning (" - " + $m) }

    if ($ThrowOnError) {
      throw ("Assert-MeetingSchema({0}) : schéma corrigé mais anomalies détectées." -f $Label)
    }
    return $false
  }

  Microsoft.PowerShell.Utility\Write-Host ("Assert-MeetingSchema({0}) : OK" -f $Label)
  return $true
}


# ---- 1) Construire la liste des objets segments (depuis les fichiers JSON existants)

$segmentObjs = @()
foreach ($p in $segmentJsonPaths) {
  try {
    $txt = Get-Content $p -Raw
    $o   = $txt | ConvertFrom-Json -Depth 50
    if ($o) { $segmentObjs += $o }
  } catch {
    Write-Warning "Pass2B: segment illisible/JSON invalide: $p (skip)"
  }
}

# ---- 2) Cas sans segments : global_meeting vide conforme

if (-not $segmentObjs -or $segmentObjs.Count -eq 0) {
  Write-Warning "Pass2B: aucun segment exploitable. Fallback globalMeeting vide."
  $globalMeetingObj = Normalize-MeetingBatchObj $null
}
else {

  # ---- 3) Traitement par batches

  $batchCount = [math]::Ceiling($segmentObjs.Count / [double]$Pass2BatchSize)
  $batchPaths = New-Object System.Collections.Generic.List[object]
  $onlyPass2BSet = @{}
  foreach ($n in @($OnlyPass2BBatches)) {
    if ($n -gt 0) { $onlyPass2BSet[[int]$n] = $true }
  }
  $hasOnlyPass2B = ($onlyPass2BSet.Count -gt 0)

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
    $selectedForPass2BRebuild = ($RebuildPass2BOnly -or ($hasOnlyPass2B -and $onlyPass2BSet.ContainsKey($batchIndex)))

    if ($hasOnlyPass2B -and (-not $selectedForPass2BRebuild)) {
      Microsoft.PowerShell.Utility\Write-Host "Pass2B: skip batch $batchIndex (hors reprise ciblée) → $batchOut"
      if (Test-Path $batchOut) {
        $batchPaths.Add($batchOut) | Out-Null
      }
      else {
        Write-Warning "Pass2B: batch $batchIndex absent alors qu'il n'est pas dans -OnlyPass2BBatches: $batchOut"
      }
      continue
    }

    if ((Test-Path $batchOut) -and (-not $Force) -and (-not $selectedForPass2BRebuild)) {
      Microsoft.PowerShell.Utility\Write-Host "Pass2B: skip batch $batchIndex (existe) → $batchOut"
      $batchPaths.Add($batchOut) | Out-Null
      continue
    }

    Microsoft.PowerShell.Utility\Write-Host ("Pass2B → Batch {0:D2}/{1} (segments {2}..{3})" -f $batchIndex, $batchCount, ($from+1), ($to+1))

    $batchSeg = @($segmentObjs[$from..$to])
    $batchObj = Invoke-Pass2BAdaptiveBatch `
      -BatchIndex $batchIndex `
      -BatchSeg $batchSeg `
      -RequestedSize $Pass2BatchSize `
      -BatchBase $batchBase `
      -Pass2BDir $pass2BDir `
      -LogFile $logFile `
      -ApiBase $ApiBase `
      -ModelReport $ModelReport `
      -Pass2BSystem $Pass2B_System `
      -Pass2BUserTemplate $Pass2B_User_Template `
      -DebugHttp:$DebugHttp

    $batchObj = Normalize-MeetingBatchObj $batchObj
    $json = $batchObj | ConvertTo-Json -Depth 50
    [System.IO.File]::WriteAllText($batchOut, $json, $utf8NoBom)
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
      Write-Warning "Pass2B: batch illisible: $bp (skip). Détail: $($_.Exception.Message)"
    }
  }

  $globalMeetingObj = Merge-MeetingBatchObjects $allBatchObjs
}

# ---- 5) Sauvegarde global_meeting.json

$globalMeetingPath = Join-Path $OutDir "global_meeting.json"
$json = $globalMeetingObj | ConvertTo-Json -Depth 50
[System.IO.File]::WriteAllText($globalMeetingPath, $json, $utf8NoBom)

Microsoft.PowerShell.Utility\Write-Host "GLOBAL réunion → $globalMeetingPath"



# -----------------------------------------------------------------------
# ── Split global.json en 1 fichier JSON par sujet (pour analyses ultérieures)
# -----------------------------------------------------------------------
Microsoft.PowerShell.Utility\Write-Host "Split par sujet → global.json"

try {
  $splitOutDir = Join-Path $OutDir "sujets"
  Ensure-Dir $splitOutDir

  # chemins
  $globalJsonPath = Join-Path $OutDir "global.json"
  if (-not (Test-Path $globalJsonPath)) { throw "global.json introuvable: $globalJsonPath" }

  # 1) produire le référentiel sujets_ref.json AVANT l'appel python
  $sujetsRefPath = Join-Path $OutDir "sujets_ref.json"
  $sujetsJsonLocal = ConvertTo-Json -InputObject @($Sujets) -Depth 10 -Compress
  [System.IO.File]::WriteAllText($sujetsRefPath, $sujetsJsonLocal, $utf8NoBom)

  if (-not (Test-Path $sujetsRefPath)) { throw "sujets_ref.json non écrit: $sujetsRefPath" }

  # 2) localiser split_by_sujet.py
  $pipelineRoot = Split-Path $PSScriptRoot -Parent
  $splitPy = Join-Path $pipelineRoot "python/split_by_sujet.py"
  if (-not (Test-Path $splitPy)) { throw "split_by_sujet.py introuvable: $splitPy" }

  # 3) appel python (UNE seule méthode)
  $argString = @(
    "`"$splitPy`"",
    "--global-json", "`"$globalJsonPath`"",
    "--sujets-ref",  "`"$sujetsRefPath`"",
    "--out",         "`"$splitOutDir`"",
    "--target-kb",   "80",
    "--dedup"
  ) -join " "

  $p = Start-Process -FilePath "python3" -ArgumentList $argString -NoNewWindow -PassThru -Wait
  
  Microsoft.PowerShell.Utility\Write-Host ("Split sujets → python3 " + $argString)

  if ($p.ExitCode -ne 0) {
    throw "split_by_sujet.py a échoué (ExitCode=$($p.ExitCode))"
  }

  $splitIndexPath = Join-Path $splitOutDir "split_index.json"
  if (-not (Test-Path $splitIndexPath)) { throw "split_index.json non généré: $splitIndexPath" }

  Microsoft.PowerShell.Utility\Write-Host "Split par sujet OK → $splitOutDir"
}
catch {
  Write-Warning "Split par sujet: échec ($_). Le pipeline continue sans split."
}
# -------------------------------------------------
# Ingestion de la passe debrief 
#--------------------------------------------------
function Get-MeetingQuality {
  param(
    [object] $GlobalMeetingObj,
    [hashtable] $BySujet
  )

  $themesCount  = @($GlobalMeetingObj.themes).Count
  $actionsCount = @($GlobalMeetingObj.actions).Count
  $docsCount    = @($GlobalMeetingObj.demandes_documents_globales).Count
  $resumeLen    = ([string]$GlobalMeetingObj.resume_global).Trim().Length

  # sujets couverts
  $coveredSujets = 0
  foreach($k in $BySujet.Keys){
    if(@($BySujet[$k]).Count -gt 0){ $coveredSujets++ }
  }

  # participants couverts (hors Inconnu)
  $authors = New-Object System.Collections.Generic.HashSet[string]
  foreach($k in $BySujet.Keys){
    foreach($iv in @($BySujet[$k])){
      if($iv -and $iv.PSObject.Properties['auteur']){
        $a = ([string]$iv.auteur).Trim()
        if($a -and $a -ne "Inconnu"){ [void]$authors.Add($a) }
      }
    }
  }
  $coveredParticipants = $authors.Count

  [pscustomobject]@{
    themesCount = $themesCount
    actionsCount = $actionsCount
    docsCount = $docsCount
    resumeLen = $resumeLen
    coveredSujets = $coveredSujets
    coveredParticipants = $coveredParticipants
  }
}
# --- Déterminer le mode demandé par le debrief (si fourni par le LLM) ---
$DebriefMode = $null
if ($Global:DebriefObj -and $Global:DebriefObj.PSObject.Properties['mode_debrief']) {
  $DebriefMode = ([string]$Global:DebriefObj.mode_debrief).Trim().ToLower()
  if ($DebriefMode -notin @("complement","substitution")) { $DebriefMode = $null }
}


$q = Get-MeetingQuality -GlobalMeetingObj $globalMeetingObj -BySujet $bySujet

$useSubstitutionByHeuristic =
  ( ($q.resumeLen -lt 80) -and (($q.themesCount + $q.actionsCount + $q.docsCount) -eq 0) ) -or
  ($q.coveredSujets -lt 2) -or
  ($q.coveredParticipants -lt 2)

# Priorité au mode_debrief si présent, sinon heuristique
$useSubstitution = $false
if ($DebriefMode -eq "substitution") { $useSubstitution = $true }
elseif ($DebriefMode -eq "complement") { $useSubstitution = $false }
else { $useSubstitution = $useSubstitutionByHeuristic }

$mode = if($useSubstitution){ "substitution" } else { "complement" }
Microsoft.PowerShell.Utility\Write-Host ("Mode debrief = {0} (debrief_mode={1}, resumeLen={2}, themes={3}, actions={4}, docs={5}, sujets={6}, participants={7})" -f
  $mode, $(if ($null -ne $DebriefMode -and "$DebriefMode" -ne "") { $DebriefMode } else { "null" }), $q.resumeLen, $q.themesCount, $q.actionsCount, $q.docsCount, $q.coveredSujets, $q.coveredParticipants)

# Application (UNE SEULE FOIS)

# 1) Base
# --- StrictMode safe init ---
$globalMeetingMerged = $null
$debAsMeeting        = $null
if (-not (Get-Variable -Name globalMeetingMerged -Scope Local -ErrorAction SilentlyContinue)) {
  $globalMeetingMerged = $globalMeetingObj
}
elseif ($null -eq $globalMeetingMerged) {
  $globalMeetingMerged = $globalMeetingObj
}

# 2) Convertir le debrief (si présent)
$debAsMeeting = $null
if ($Global:DebriefObj) {
  $debAsMeeting = Convert-DebriefToMeetingGlobal -DebriefObj $Global:DebriefObj
}

# 3) Substitution ou complément
if ($useSubstitution -and $debAsMeeting) {
  $globalMeetingMerged = $debAsMeeting
}
elseif (-not $useSubstitution -and $debAsMeeting) {

  # compléter si vide côté réunion
  if ([string]::IsNullOrWhiteSpace([string]$globalMeetingMerged.resume_global) -and $debAsMeeting.resume_global) {
    $globalMeetingMerged.resume_global = $debAsMeeting.resume_global
  }
  if (@($globalMeetingMerged.themes).Count -eq 0 -and @($debAsMeeting.themes).Count -gt 0) {
    $globalMeetingMerged.themes = $debAsMeeting.themes
  }

  # fusion dédupliquée des demandes de documents (même si déjà présentes)
  if (-not $globalMeetingMerged.PSObject.Properties['demandes_documents_globales']) {
    $globalMeetingMerged | Add-Member -Force NoteProperty demandes_documents_globales @()
  }
  $globalMeetingMerged.demandes_documents_globales = Merge-ListUnique @(
    $globalMeetingMerged.demandes_documents_globales
    $debAsMeeting.demandes_documents_globales
  )
}

if ($debAsMeeting -and @($globalMeetingMerged.actions).Count -eq 0 -and @($debAsMeeting.actions).Count -gt 0) {
  $globalMeetingMerged.actions = $debAsMeeting.actions
}

[void](Assert-MeetingSchema -MeetingObj $globalMeetingMerged -Label "globalMeetingMerged")

# -------------------------------------------------------------
# -----------------------------------------------------------------------
# ── Passe 2E : condensation par sujet (LLM)
# -----------------------------------------------------------------------
Microsoft.PowerShell.Utility\Write-Host "Passe 2E → Condensation intermédiaire par sujet"

function Get-EstimatedTokens2E {
    param(
        [Parameter(Mandatory=$true)]
        [object]$Obj
    )

    $json = $Obj | ConvertTo-Json -Depth 30 -Compress
    return [math]::Ceiling($json.Length / 4)
}

function Test-TimecodeString {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }

    $ts = [TimeSpan]::Zero
    return [TimeSpan]::TryParse($Value, [ref]$ts)
}

function Split-SujetIntoChunks2E {
    param(
        [Parameter(Mandatory=$true)]
        [array]$Interventions,

        [int]$TargetTokens = 2200,
        [int]$MaxSingleInterventionTokens = 2200
    )

    $chunks = @()
    $currentChunk = @()
    $currentTokens = 0

    foreach ($it in @($Interventions)) {
        if ($null -eq $it) { continue }

        $itTokens = Get-EstimatedTokens2E -Obj $it

        # intervention énorme : bloc autonome
        if ($itTokens -ge $MaxSingleInterventionTokens) {
            if (@($currentChunk).Count -gt 0) {
                $chunks += ,@($currentChunk)
                $currentChunk = @()
                $currentTokens = 0
            }

            $chunks += ,@($it)
            continue
        }

        if ((($currentTokens + $itTokens) -gt $TargetTokens) -and (@($currentChunk).Count -gt 0)) {
            $chunks += ,@($currentChunk)
            $currentChunk = @()
            $currentTokens = 0
        }

        $currentChunk += $it
        $currentTokens += $itTokens
    }

    if (@($currentChunk).Count -gt 0) {
        $chunks += ,@($currentChunk)
    }

    return ,@($chunks)
}

function Split-SujetFileIntoChunkObjects2E {
    param(
        [Parameter(Mandatory=$true)]
        [string]$SujetPath,

        [int]$TargetTokens = 2200,
        [int]$MaxSingleInterventionTokens = 2200
    )

    $raw = Get-Content $SujetPath -Raw -Encoding UTF8
    $sujetObj = $raw | ConvertFrom-Json -Depth 50

    if (-not $sujetObj) {
        throw "Sujet illisible : $SujetPath"
    }

    if (-not ($sujetObj.PSObject.Properties.Name -contains 'interventions')) {
        throw "Le fichier sujet ne contient pas la propriété 'interventions' : $SujetPath"
    }

    $interventions = @($sujetObj.interventions)
    if (@($interventions).Count -eq 0) {
        return @()
    }

    $sourceName = [System.IO.Path]::GetFileNameWithoutExtension($SujetPath)

    $rawChunks = Split-SujetIntoChunks2E `
        -Interventions $interventions `
        -TargetTokens $TargetTokens `
        -MaxSingleInterventionTokens $MaxSingleInterventionTokens

    $out = @()

    for ($i = 0; $i -lt @($rawChunks).Count; $i++) {
        $chunk = @($rawChunks[$i])

        $firstTimecode = $null
        $lastTimecode  = $null

        if (@($chunk).Count -gt 0) {
            if ($chunk[0].PSObject.Properties.Name -contains 'timecode') {
                $tc0 = [string]$chunk[0].timecode
                if (-not [string]::IsNullOrWhiteSpace($tc0)) {
                    $firstTimecode = $tc0
                }
            }

            $lastIdx = @($chunk).Count - 1
            if ($chunk[$lastIdx].PSObject.Properties.Name -contains 'timecode') {
                $tc1 = [string]$chunk[$lastIdx].timecode
                if (-not [string]::IsNullOrWhiteSpace($tc1)) {
                    $lastTimecode = $tc1
                }
            }
        }

        $out += [pscustomobject]@{
            source_name     = $sourceName
            numero          = $sujetObj.numero
            titre           = $sujetObj.titre
            localisation    = $sujetObj.localisation
            description     = $sujetObj.description
            chunk_index     = $i + 1
            chunk_total     = @($rawChunks).Count
            first_timecode  = $firstTimecode
            last_timecode   = $lastTimecode
            interventions   = @($chunk)
            stats           = [pscustomobject]@{
                count = @($chunk).Count
            }
            source          = $sujetObj.source
        }
    }

    return ,@($out)
}

function Invoke-Pass2EChunk {
    param(
        [Parameter(Mandatory=$true)]
        [object]$ChunkObj,

        [Parameter(Mandatory=$true)]
        [string]$LogFile,

        [string]$Model = "annoter_segments_remote_alt"
    )

    $schemaHint = @"
Réponds uniquement en JSON valide, sans texte hors JSON.

Schéma attendu :
{
  "resume_factuel": "string",
  "points_cles": ["string"],
  "actions": ["string"],
  "desaccords": ["string"],
  "documents_demandes": ["string"],
  "elements_techniques": ["string"]
}
"@

    $chunkJson = $ChunkObj | ConvertTo-Json -Depth 50 -Compress

    $userPrompt = @"
Tu réalises une synthèse intermédiaire de sujet d'expertise judiciaire.

Objectif :
- condenser fidèlement les interventions du bloc ;
- conserver les faits utiles ;
- relever les actions, désaccords, documents demandés, éléments techniques ;
- ne pas rédiger de compte rendu final ;
- ne rien inventer.

$schemaHint

Bloc à analyser :
$chunkJson
"@

    $userPromptEffective = Enforce-ContextLimit `
        -SystemPrompt $Pass2E_System `
        -UserPrompt   $userPrompt `
        -Label        ("Pass2E " + $ChunkObj.source_name + " chunk " + $ChunkObj.chunk_index + "/" + $ChunkObj.chunk_total) `
        -LogFile      $LogFile `
        -ModelName    $Model

    $raw = Invoke-LLM -system $Pass2E_System -user $userPromptEffective -model $Model -DebugHttp:$DebugHttp
    $raw = Unwrap-AdapterText $raw

    return (Parse-LlmJsonStrict `
        -RawText $raw `
        -Label ("Pass2E " + $ChunkObj.source_name + " chunk " + $ChunkObj.chunk_index) `
        -LogFile $LogFile)
}

function Merge-Pass2EPartials {
    param(
        [Parameter(Mandatory=$true)]
        [string]$SourceName,

        [Parameter(Mandatory=$true)]
        [array]$Partials,

        [Parameter(Mandatory=$true)]
        [string]$LogFile,

        [string]$Model = "annoter_segments_remote_alt"
    )

    if (-not $Partials -or @($Partials).Count -eq 0) {
        throw "Merge-Pass2EPartials : partials vide pour $SourceName"
    }

    if (@($Partials).Count -eq 1) {
        return $Partials[0]
    }

    $schemaHint = @"
Réponds uniquement en JSON valide, sans texte hors JSON.

Schéma attendu :
{
  "resume_factuel": "string",
  "points_cles": ["string"],
  "actions": ["string"],
  "desaccords": ["string"],
  "documents_demandes": ["string"],
  "elements_techniques": ["string"]
}
"@

    $partialsJson = $Partials | ConvertTo-Json -Depth 50 -Compress

    $userPrompt = @"
Tu fusionnes plusieurs synthèses intermédiaires d’un même sujet d’expertise judiciaire.

Objectif :
- éliminer les redondances ;
- conserver les informations factuelles utiles ;
- fusionner proprement les listes ;
- ne rien inventer ;
- ne pas produire de compte rendu final rédigé.

$schemaHint

Nom source du sujet :
$SourceName

Synthèses partielles :
$partialsJson
"@

    $userPromptEffective = Enforce-ContextLimit `
        -SystemPrompt $Pass2E_System `
        -UserPrompt   $userPrompt `
        -Label        ("Pass2E merge " + $SourceName) `
        -LogFile      $LogFile `
        -ModelName    $Model

    $raw = Invoke-LLM -system $Pass2E_System -user $userPromptEffective -model $Model -DebugHttp:$DebugHttp
    $raw = Unwrap-AdapterText $raw

    return (Parse-LlmJsonStrict `
        -RawText $raw `
        -Label ("Pass2E merge " + $SourceName) `
        -LogFile $LogFile)
}

function Normalize-Pass2ECompactSchema {
    param(
        [Parameter(Mandatory=$true)]
        [object]$Obj
    )

    if ($null -eq $Obj) {
        return [pscustomobject]@{
            resume_factuel      = ""
            points_cles         = @()
            actions             = @()
            desaccords          = @()
            documents_demandes  = @()
            elements_techniques = @()
        }
    }

    if ($Obj -is [hashtable]) {
        $Obj = [pscustomobject]$Obj
    }

    function _GetPropValue {
        param(
            [object]$o,
            [string]$name
        )

        if ($null -eq $o) { return $null }

        if ($o -is [hashtable]) {
            if ($o.ContainsKey($name)) { return $o[$name] }
            return $null
        }

        $p = $o.PSObject.Properties[$name]
        if ($null -ne $p) { return $p.Value }

        return $null
    }

    function _AsStringList {
        param([object]$value)

        if ($null -eq $value) { return @() }

        if ($value -is [string]) {
            $t = $value.Trim()
            if ($t) { return @($t) }
            return @()
        }

        if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) {
            $out = @()
            foreach ($x in $value) {
                if ($null -eq $x) { continue }
                $s = ([string]$x).Trim()
                if ($s) { $out += $s }
            }
            return @($out)
        }

        $s = ([string]$value).Trim()
        if ($s) { return @($s) }
        return @()
    }

    $resume_factuel_src = _GetPropValue $Obj 'resume_factuel'
    if ($null -eq $resume_factuel_src) {
        $resume_factuel_src = _GetPropValue $Obj 'resume_segment'
    }

    $points_cles_src = _GetPropValue $Obj 'points_cles'
    if ($null -eq $points_cles_src) {
        $points_cles_src = _GetPropValue $Obj 'themes'
    }

    $actions_src = _GetPropValue $Obj 'actions'

    $desaccords_src = _GetPropValue $Obj 'desaccords'
    if ($null -eq $desaccords_src) {
        $desaccords_src = _GetPropValue $Obj 'problems'
    }

    $documents_demandes_src  = _GetPropValue $Obj 'documents_demandes'
    $elements_techniques_src = _GetPropValue $Obj 'elements_techniques'

    return [pscustomobject]@{
        resume_factuel      = ([string]$resume_factuel_src).Trim()
        points_cles         = @(_AsStringList $points_cles_src)
        actions             = @(_AsStringList $actions_src)
        desaccords          = @(_AsStringList $desaccords_src)
        documents_demandes  = @(_AsStringList $documents_demandes_src)
        elements_techniques = @(_AsStringList $elements_techniques_src)
    }
}


function Invoke-Pass2EForSujetFile {
    param(
        [Parameter(Mandatory=$true)]
        [string]$SujetPath,

        [Parameter(Mandatory=$true)]
        [string]$OutDir,

        [Parameter(Mandatory=$true)]
        [string]$LogFile,

        [string]$Model = "annoter_segments_remote_alt",
        [int]$TargetTokens = 2200
    )

    $chunkObjs = Split-SujetFileIntoChunkObjects2E `
        -SujetPath $SujetPath `
        -TargetTokens $TargetTokens `
        -MaxSingleInterventionTokens $TargetTokens

    if (-not $chunkObjs -or @($chunkObjs).Count -eq 0) {
        Write-Warning "Pass2E: aucun chunk pour $SujetPath"
        return $null
    }

    $sourceName = $chunkObjs[0].source_name
    $partials = @()

    for ($i = 0; $i -lt @($chunkObjs).Count; $i++) {
        $chunk = $chunkObjs[$i]
        Microsoft.PowerShell.Utility\Write-Host ("Pass2E {0} → chunk {1}/{2}" -f $sourceName, $chunk.chunk_index, $chunk.chunk_total)

        try {
            $partial = Invoke-Pass2EChunk `
                -ChunkObj $chunk `
                -LogFile $LogFile `
                -Model $Model

            $partials += $partial
        }
        catch {
            Write-Warning ("Pass2E {0} chunk {1}: échec LLM : {2}" -f $sourceName, $chunk.chunk_index, $_.Exception.Message)
            throw
        }
    }

    $compactRaw = Merge-Pass2EPartials `
        -SourceName $sourceName `
        -Partials $partials `
        -LogFile $LogFile `
        -Model $Model

    $compact = Normalize-Pass2ECompactSchema -Obj $compactRaw

    $sujetRaw = Get-Content $SujetPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 50

    $finalObj = [pscustomobject]@{
        source_name            = $sourceName
        numero                 = $sujetRaw.numero
        titre                  = $sujetRaw.titre
        localisation           = $sujetRaw.localisation
        description            = $sujetRaw.description
        synthese_intermediaire = $compact
        stats                  = [pscustomobject]@{
            chunk_count         = @($chunkObjs).Count
            interventions_count = @($sujetRaw.interventions).Count
        }
        source                 = $sujetRaw.source
    }

    $outPath = Join-Path $OutDir ($sourceName + "_compact.json")
    $json = $finalObj | ConvertTo-Json -Depth 50
    [System.IO.File]::WriteAllText($outPath, $json, $utf8NoBom)

    Microsoft.PowerShell.Utility\Write-Host "Pass2E OK → $outPath"
    return $outPath
}

$pass2EOutDir = Join-Path $OutDir "pass2E_sujets_compact"
Ensure-Dir $pass2EOutDir

$sujetFiles = Get-ChildItem -Path $splitOutDir -Filter "*.json" -File |
    Where-Object { $_.Name -ne "split_index.json" } |
    Sort-Object Name

$pass2EPaths = @()

foreach ($sf in $sujetFiles) {
    try {
        $compactPath = Invoke-Pass2EForSujetFile `
            -SujetPath $sf.FullName `
            -OutDir $pass2EOutDir `
            -LogFile $logFile `
            -Model $ModelPass2E `
            -TargetTokens 2200

        if ($compactPath) {
            $pass2EPaths += $compactPath
        }
    }
    catch {
        Write-Warning ("Pass2E échouée pour {0} : {1}" -f $sf.Name, $_.Exception.Message)
    }
}

Microsoft.PowerShell.Utility\Write-Host ("Passe 2E terminée → {0} fichier(s) compact(s)" -f @($pass2EPaths).Count)

# ── Fin Passe 2E : condensation par sujet (LLM) ─────────





# -----------------------------------------------------------------------
# ── Passe 3E : synthèses par sujet (sorties indépendantes)
# -----------------------------------------------------------------------

function _GetField($o, [string]$k) {
  if ($o -is [hashtable]) {
    if ($o.ContainsKey($k)) {
      return $o[$k]
    }
    else {
      return $null
    }
  }

  if ($null -ne $o -and $o.PSObject.Properties.Match($k).Count -gt 0) {
    return $o.$k
  }

  return $null
}


Microsoft.PowerShell.Utility\Write-Host "Passe 3E → Synthèses par sujet (à partir des compacts 2E)"

trap {
  Microsoft.PowerShell.Utility\Write-Host "[ERR] $($_.Exception.Message)"
  Microsoft.PowerShell.Utility\Write-Host "[ERR] Position: $($_.InvocationInfo.PositionMessage)"
  Microsoft.PowerShell.Utility\Write-Host "[ERR] ScriptStackTrace: $($_.ScriptStackTrace)"
  break
}

$pass3EDir = Join-Path $OutDir "pass3E_sujets"
Ensure-Dir $pass3EDir

$pass2EOutDir = Join-Path $OutDir "pass2E_sujets_compact"

if (-not (Test-Path $pass2EOutDir)) {
  Write-Warning "Passe 3E ignorée : dossier pass2E introuvable ($pass2EOutDir)."
}
else {
  $compactFiles = Get-ChildItem -Path $pass2EOutDir -Filter "*_compact.json" -File | Sort-Object Name

  if (-not $compactFiles -or @($compactFiles).Count -eq 0) {
    Write-Warning "Passe 3E: aucun fichier compact 2E trouvé."
  }
  else {

    # Prompt de fusion (si un sujet est en plusieurs parties)

    $pass3eResults = New-Object System.Collections.Generic.List[object]

    foreach ($cf in $compactFiles) {

      $compactObj = $null
      try {
        $compactObj = Get-Content $cf.FullName -Raw | ConvertFrom-Json -Depth 50
      } catch {
        Write-Warning ("Pass3E: fichier compact illisible : {0}" -f $cf.FullName)
        continue
      }

      if (-not $compactObj) {
        Write-Warning ("Pass3E: fichier compact vide : {0}" -f $cf.FullName)
        continue
      }

      $num   = [int]$compactObj.numero
      $titre = [string]$compactObj.titre
      $localisation = if ($compactObj.PSObject.Properties['localisation']) { [string]$compactObj.localisation } else { "" }
      $description  = if ($compactObj.PSObject.Properties['description'])  { [string]$compactObj.description  } else { "" }

      $outOne = Join-Path $pass3EDir ("sujet_{0:D3}_synthese.json" -f $num)

      if ((Test-Path $outOne) -and (-not $Force) -and (-not $RebuildFromPass2B)) {
        Microsoft.PowerShell.Utility\Write-Host ("Pass3E: skip sujet {0:D3} (existe) → {1}" -f $num, $outOne)
        try {
          $o = (Get-Content $outOne -Raw) | ConvertFrom-Json -Depth 50
          if ($o) { $pass3eResults.Add($o) | Out-Null }
        } catch {}
        continue
      }
      elseif ((Test-Path $outOne) -and $RebuildFromPass2B -and (-not $Force)) {
        Microsoft.PowerShell.Utility\Write-Host ("Pass3E: rebuild sujet {0:D3} (RebuildFromPass2B) → {1}" -f $num, $outOne)
      }

      $meta = [pscustomobject]@{
        numero       = $num
        titre        = $titre
        localisation = $localisation
        description  = $description
      }

      $compactSynth = $null
      if ($compactObj.PSObject.Properties['synthese_intermediaire']) {
        $compactSynth = $compactObj.synthese_intermediaire
      }

      if (-not $compactSynth) {
        $finalOne = [pscustomobject]@{
          numero = $num
          titre  = $titre
          localisation = $localisation
          description  = $description
          avis_participants = @()
          synthese_echanges = "Synthèse intermédiaire indisponible."
          conclusion_expert = "Conclusion prudente : aucune synthèse intermédiaire exploitable n’a été produite pour ce sujet."
        }
      }
      else {
        $user = @"
    Sujet :
    $($meta | ConvertTo-Json -Depth 10)

    Synthèse intermédiaire 2E :
    $($compactSynth | ConvertTo-Json -Depth 50)

    À partir de cette synthèse intermédiaire, produis la synthèse finale du sujet.

    Renvoie uniquement le JSON conforme au schéma.
"@

        $userEff = Enforce-ContextLimit `
          -SystemPrompt $Pass3E_System `
          -UserPrompt   $user `
          -Label        ("Pass3E sujet {0:D3}" -f $num) `
          -LogFile      $logFile `
          -ModelName    $ModelPass3E

        $raw = $null
        $finalOne = $null

        try {
          $raw = Invoke-LLM -system $Pass3E_System -user $userEff -model $ModelPass3E -DebugHttp:$DebugHttp
          $raw = Unwrap-AdapterText $raw
          $finalOne = Parse-LlmJsonStrict -RawText $raw -Label ("Pass3E sujet {0:D3}" -f $num) -LogFile $logFile
        }
        catch {
          Write-Warning ("Pass3E: échec modèle local sur sujet {0:D3} → fallback ModelPass3." -f $num)
          try {
            $raw = Invoke-LLM -system $Pass3E_System -user $userEff -model $ModelPass3 -DebugHttp:$DebugHttp
            $raw = Unwrap-AdapterText $raw
            $finalOne = Parse-LlmJsonStrict -RawText $raw -Label ("Pass3E(FB) sujet {0:D3}" -f $num) -LogFile $logFile
          }
          catch {
            $finalOne = $null
          }
        }

        if (-not $finalOne) {
          $finalOne = [pscustomobject]@{
            numero = $num
            titre  = $titre
            localisation = $localisation
            description  = $description
            avis_participants = @()
            synthese_echanges = "Synthèse indisponible (échec LLM)."
            conclusion_expert = "Conclusion prudente : sortie LLM non exploitable ; à reprendre."
          }
        }
      }

      if (-not $finalOne) {
        $finalOne = [pscustomobject]@{}
      }


      # Sécurité : titles
      # --- Normalisation : s'assurer d'un PSCustomObject extensible ---
      if ($null -eq $finalOne) { $finalOne = [pscustomobject]@{} }

      # Si c'est un hashtable (fréquent après parsing JSON), on convertit
      if ($finalOne -is [hashtable]) { $finalOne = [pscustomobject]$finalOne }

      # Si l'objet n'est pas "extensible", on le re-emballe en PSCustomObject
      if ($finalOne -isnot [pscustomobject]) { $finalOne = [pscustomobject]@{ value = $finalOne } }

      # --- Sécurité : numero / titre (ajout si absent, sinon affectation) ---
      if ($finalOne.PSObject.Properties.Match('numero').Count -eq 0) {
        $finalOne | Add-Member -NotePropertyName numero -NotePropertyValue $num -Force
      } else {
        $finalOne.numero = $num
      }

      if ($finalOne.PSObject.Properties.Match('titre').Count -eq 0) {
        $finalOne | Add-Member -NotePropertyName titre -NotePropertyValue $titre -Force
      } else {
        $finalOne.titre = $titre
      }

      # Avis participants : doit TOUJOURS être une liste
      if ($finalOne.PSObject.Properties.Match('avis_participants').Count -eq 0) {
          $finalOne | Add-Member -NotePropertyName avis_participants -NotePropertyValue @() -Force
      }
      elseif ($null -eq $finalOne.avis_participants) {
          $finalOne.avis_participants = @()
      }
      elseif ($finalOne.avis_participants -is [hashtable] -or $finalOne.avis_participants -is [pscustomobject]) {
          $finalOne.avis_participants = @($finalOne.avis_participants)
      }
      elseif ($finalOne.avis_participants -is [string]) {
          $finalOne.avis_participants = @($finalOne.avis_participants)
      }
      else {
          $finalOne.avis_participants = @($finalOne.avis_participants)
      }

      # Avis participants : doit TOUJOURS être une liste


      # Puis votre normalisation item par item (votre bloc actuel)
      $finalOne.avis_participants = @($finalOne.avis_participants) | ForEach-Object {
    
          
          
          
          
          if ($_ -eq $null) { return }

          if ($_ -is [string]) {
              $t = $_.Trim()
              if ($t) { return [pscustomobject]@{ nom = ""; role = ""; resume = $t } }
              return
          }

          $nom  = ""
          $n1 = _GetField $_ 'nom'
          if ($n1) { $nom = [string]$n1 } else {
            $n2 = _GetField $_ 'name'
            if ($n2) { $nom = [string]$n2 }
          }

          $avis = ""
          foreach($k in @('avis','commentaire','texte')) {
            $v = _GetField $_ $k
            if ($v) { $avis = [string]$v; break }
          }

          if (-not $nom -and -not $avis) { return }
          $role = ""
          if ($_ -is [hashtable]) {
            if ($_.ContainsKey("role")) { $role = [string]$_["role"] }
          } elseif ($_.PSObject.Properties.Match('role').Count -gt 0) {
            $role = [string]$_.role
          }

          [pscustomobject]@{
            nom    = ([string]$nom).Trim()
            role   = $role.Trim()
            resume = ([string]$avis).Trim()
          }

      } | Where-Object { $_ -ne $null }

      if ($finalOne.PSObject.Properties.Match('avis_participants').Count -eq 0) {
        $finalOne | Add-Member -NotePropertyName avis_participants -NotePropertyValue @() -Force
      }
      elseif ($null -eq $finalOne.avis_participants) {
        $finalOne.avis_participants = @()
      }

      # Sécurité : champs de référence (toujours présents dans la sortie)
      if (-not $finalOne.PSObject.Properties['localisation']) {
        $finalOne | Add-Member -Force NoteProperty localisation $localisation
      } else {
        $finalOne.localisation = $localisation
      }   


      # Puis seulement maintenant sérialiser
      $jsonOne = $finalOne | ConvertTo-Json -Depth 50
      [IO.File]::WriteAllText($outOne, $jsonOne, $utf8NoBom)



      $pass3eResults.Add($finalOne) | Out-Null
      Microsoft.PowerShell.Utility\Write-Host ("Pass3E: sujet {0:D3} OK → {1}" -f $num, $outOne)
    }

    # ---- 3) Agrégation de toutes les synthèses sujet
    $agg = [pscustomobject]@{
      sujets = $pass3eResults.ToArray()
      tous_sujets_traites = $true
      sujets_manquants = @()
    }



    $agg.sujets = @($agg.sujets | Where-Object {
      $null -ne $_ -and $_.PSObject.Properties['numero'] -and [int]$_.numero -gt 0
    })

    $expected = @($Sujets | ForEach-Object { [int]$_.Numero })
    $got = @($agg.sujets | ForEach-Object { [int]$_.numero })
    $missing = $expected | Where-Object { $got -notcontains $_ }
    if (@($missing).Count -gt 0) {
      $agg.tous_sujets_traites = $false
      $agg.sujets_manquants = @($missing)
    }

    $aggPath = Join-Path $OutDir "global_by_sujet.json"
    [IO.File]::WriteAllText($aggPath, ($agg | ConvertTo-Json -Depth 100), $utf8NoBom)

    Microsoft.PowerShell.Utility\Write-Host ("Passe 3E: agrégation → {0}" -f $aggPath)
  }
}



# -----------------------------------------------------------------------
# ── Passe 3 : JSON FINAL normalisé (enrichissement progressif) 
# -----------------------------------------------------------------------

Microsoft.PowerShell.Utility\Write-Host "Passe 3 → JSON FINAL (enrichissement progressif)"
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

# ---- MergeGlobal (SUPPRIMÉ) ----
# Dans ce pipeline, mergeGlobal_input.json (agrégation sujets+réunion+debrief) est volontairement abandonné
# afin de limiter la taille des prompts et de privilégier des traitements locaux.
# On conserve donc le JSON global_meeting.json (éventuellement issu du débrief via Pass1B, déjà intégré ailleurs).

$globalMeetingMerged = $fallbackMeetingObj  # ✅ objet (base = global_meeting.json)

# JSON prêt pour Pass 3A/3B/3C/3D

$globalMeetingMergedJson = $globalMeetingMerged | ConvertTo-Json -Depth 50
# Pass3 doit consommer global.json (agrégation par sujets)
if (-not (Test-Path $globalPath)) { throw "globalPath introuvable: $globalPath" }

# --- Remplacement : on n'envoie plus global.json (trop gros) à un LLM ---
# La "structure sujets" provient de la Passe 3E (global_by_sujet.json)

$aggPath = Join-Path $OutDir "global_by_sujet.json"
if (-not (Test-Path $aggPath)) {
  throw "global_by_sujet.json introuvable ($aggPath). La Passe 3E doit être exécutée avant l'assemblage final."
}

$finalObj = Get-Content $aggPath -Raw | ConvertFrom-Json -Depth 100

# Normalisation stricte minimale
if (-not $finalObj.PSObject.Properties['sujets']) {
  $finalObj | Add-Member -Force -NotePropertyName sujets -NotePropertyValue @()
}
if (-not $finalObj.PSObject.Properties['tous_sujets_traites']) {
  $finalObj | Add-Member -Force -NotePropertyName tous_sujets_traites -NotePropertyValue $false
}
if (-not $finalObj.PSObject.Properties['sujets_manquants']) {
  $finalObj | Add-Member -Force -NotePropertyName sujets_manquants -NotePropertyValue @()
}

# (Optionnel) si vous voulez encore exploiter le débrief pour rattacher des demandes,
# gardez $debriefJson / $Global:DebriefObj plus bas, mais NE PAS construire $pass3User.

# --- NOUVEAU : on ne fait plus d'appel LLM pour la Passe 3 ---
# On récupère la structure "sujets" déjà produite par la Passe 3E
$aggPath = Join-Path $OutDir "global_by_sujet.json"
if (-not (Test-Path $aggPath)) {
  throw "global_by_sujet.json introuvable ($aggPath). La Passe 3E doit être exécutée avant l'assemblage final."
}


# (Optionnel) log de traçabilité : source de $finalObj
$path = Join-Path $logsDir "pass3_source.txt"
[System.IO.File]::WriteAllText(
  $path,
  "Pass3 remplacée par chargement global_by_sujet.json : $aggPath",
  [System.Text.Encoding]::UTF8
)


# (1) Construire la map Numero -> Titre (trim + sécurité)
$SujetMetaByNumero = @{}
foreach ($sj in $Sujets) {
  $k = ([string]$sj.Numero).Trim()
  if ($k -ne "") {
    $SujetMetaByNumero[$k] = @{
      titre        = ([string]$sj.Titre).Trim()
      localisation = ([string]$sj.Localisation).Trim()
      description  = ([string]$sj.Description).Trim()
    }
  }
}

# (2) Replaquer les titres sur la sortie LLM
if ($finalObj -and $finalObj.sujets) {
  $sujetsAvantFiltreFinal = @($finalObj.sujets).Count
  $finalObj.sujets = @($finalObj.sujets | Where-Object {
    $null -ne $_ -and $_.PSObject.Properties['numero'] -and [int]$_.numero -gt 0
  })
  $sujetsRetiresFinal = $sujetsAvantFiltreFinal - @($finalObj.sujets).Count
  if ($sujetsRetiresFinal -gt 0) {
    Write-Warning ("Assemblage final: {0} sujet(s) numero=0 ou invalide supprime(s) avant global_final.json." -f $sujetsRetiresFinal)
  }

  foreach ($s in $finalObj.sujets) {
    if (-not $s.PSObject.Properties['numero']) { continue }

    $k = ([string]$s.numero).Trim()

    if ($SujetMetaByNumero.ContainsKey($k)) {

      $meta = $SujetMetaByNumero[$k]

      $s.titre = if ($meta.titre) { $meta.titre } else { "Sujet $k" }

      if (-not $s.PSObject.Properties['localisation']) {
        $s | Add-Member -Force NoteProperty localisation $meta.localisation
      } else {
        $s.localisation = $meta.localisation
      }

      if (-not $s.PSObject.Properties['description']) {
        $s | Add-Member -Force NoteProperty description $meta.description
      } else {
        $s.description = $meta.description
      }
    }
    elseif (-not $s.PSObject.Properties['titre'] -or [string]::IsNullOrWhiteSpace([string]$s.titre)) {
      $s.titre = ("Sujet " + $k)
    }
  }
}

#------------------------------------------------------------
# 3A : métadonnées + résumé + ordre du jour
#------------------------------------------------------------
Microsoft.PowerShell.Utility\Write-Host "Passe 3A → date / link / resume / ordre_du_jour"

$ctxBlock = ""
if ($GlobalContext) {
  $ctxBlock = @"
CONTEXTE GÉNÉRAL (PRIORITAIRE) :
Mission : $ContextMission
État d’avancement : $ContextEtatAvancement
"@
}

$pass3AUser = @"
$ctxBlock

Consigne prioritaire :
- Si une date de réunion figure dans l’état d’avancement ci-dessus, la renseigner en ISO (YYYY-MM-DD).

"@ + ($Pass3A_User_Template.Replace("{GLOBAL_JSON}", $globalMeetingMergedJson))

# log prompt brut
$path = Join-Path $logsDir "pass3A_input.txt"
Write-ArtifactText -Path $path -Text $pass3AUser -ModelName $ModelPass3A




# contrôle n_ctx / max_tokens (Pass 3A)
$pass3AUser_Effective = Truncate-For-Context `
  -SystemText $Pass3A_System `
  -UserText   $pass3AUser `
  -ModelName  $ModelPass3A

# log prompt effectif
$path = Join-Path $logsDir "pass3A_input_effective.txt"
Write-ArtifactText -Path $path -Text $pass3AUser_Effective -ModelName $ModelPass3A

$partAObj  = $null
$pass3ARaw = $null

try {
  $pass3ARaw = Invoke-LLM -system $Pass3A_System -user $pass3AUser_Effective -model $ModelPass3A -DebugHttp:$DebugHttp
  $pass3ARaw = Unwrap-AdapterText $pass3ARaw
  if ($pass3ARaw) {
    $path = Join-Path $logsDir "pass3A_raw.txt"
    Write-ArtifactText -Path $path -Text $pass3ARaw -ModelName $ModelPass3A

  }

  $partAObj = Parse-LlmJsonStrict -RawText $pass3ARaw -Label "Pass3A" -LogFile $logFile
}
catch {
  Write-Warning "Pass3A: échec LLM/JSON ($_). Fallback par défaut."
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

#------------------------------------------------------------
# 3B : thèmes_abordes
#------------------------------------------------------------
Microsoft.PowerShell.Utility\Write-Host "Passe 3B → themes_abordes"

$pass3BUser = $Pass3B_User_Template.Replace("{GLOBAL_JSON}", $globalMeetingMergedJson)

# log prompt brut
$path = Join-Path $logsDir "pass3B_input.txt"
Write-ArtifactText -Path $path -Text $pass3BUser -ModelName $ModelPass3B

$pass3BUser_Effective = Truncate-For-Context `
  -SystemText $Pass3B_System `
  -UserText   $pass3BUser `
  -ModelName  $ModelPass3B

# log prompt effectif
$path = Join-Path $logsDir "pass3B_input_effective.txt"
Write-ArtifactText -Path $path -Text $pass3BUser_Effective -ModelName $ModelPass3B

$partBObj  = $null
$pass3BRaw = $null

try {
  $pass3BRaw = Invoke-LLM -system $Pass3B_System -user $pass3BUser_Effective -model $ModelPass3B -DebugHttp:$DebugHttp
  $pass3BRaw = Unwrap-AdapterText $pass3BRaw
  if ($pass3BRaw) {
    $path = Join-Path $logsDir "pass3B_raw.txt"
    Write-ArtifactText -Path $path -Text $pass3BRaw -ModelName $ModelPass3B
  
  }

  $partBObj = Parse-LlmJsonStrict -RawText $pass3BRaw -Label "Pass3B" -LogFile $logFile
}
catch {
  Write-Warning "Pass3B: échec LLM/JSON ($_). Fallback themes_abordes=[]."
  $partBObj = [pscustomobject]@{
    themes_abordes = @()
  }
}

# Normalisation stricte (anti StrictMode)
if (-not $partBObj.PSObject.Properties['themes_abordes']) {
  $partBObj | Add-Member -Force -NotePropertyName themes_abordes -NotePropertyValue @()
}
Ensure-List $partBObj "themes_abordes"
#------------------------------------------------------------
# 3C : actions / perspectives / annexes
#------------------------------------------------------------
Microsoft.PowerShell.Utility\Write-Host "Passe 3C → actions / perspectives / annexes"
$globalObj = $globalMeetingMergedJson | ConvertFrom-Json -Depth 200

$reduced = [pscustomobject]@{
  resume_global = $globalObj.resume_global
  actions = $globalObj.actions
  problems = $globalObj.problems
  demandes_documents_globales = $globalObj.demandes_documents_globales
  themes = $globalObj.themes
}

$pass3CUser = $Pass3C_User_Template.Replace("{GLOBAL_JSON}", ($reduced | ConvertTo-Json -Depth 50))


# log prompt brut
$path = Join-Path $logsDir "pass3C_input.txt"
Write-ArtifactText -Path $path -Text $pass3CUser -ModelName $ModelPass3C

$pass3CUser_Effective = Truncate-For-Context `
  -SystemText $Pass3C_System `
  -UserText   $pass3CUser `
  -ModelName  $ModelPass3C

# log prompt effectif
$path = Join-Path $logsDir "pass3C_input_effective.txt"
Write-ArtifactText -Path $path -Text $pass3CUser_Effective -ModelName $ModelPass3C

$partCObj  = $null
$pass3CRaw = $null

try {
  $pass3CRaw = Invoke-LLM -system $Pass3C_System -user $pass3CUser_Effective -model $ModelPass3C -DebugHttp:$DebugHttp
  $pass3CRaw = Unwrap-AdapterText $pass3CRaw
  if ($pass3CRaw) {
    $path = Join-Path $logsDir "pass3C_raw.txt"
    Write-ArtifactText -Path $path -Text $pass3CRaw -ModelName $ModelPass3C

  }

  $partCObj = Parse-LlmJsonStrict -RawText $pass3CRaw -Label "Pass3C" -LogFile $logFile
}
catch {
  Write-Warning "Pass3C: échec LLM/JSON ($_). Fallback actions/perspectives/annexes vides."
  $partCObj = [pscustomobject]@{
    actions      = @()
    perspectives = @()
    annexes      = @()
  }
}
if (-not $partCObj) {
  $partCObj = [pscustomobject]@{ actions=@(); perspectives=@(); annexes=@() }
}
if (-not $partCObj.PSObject.Properties['actions'])      { $partCObj | Add-Member -Force NoteProperty actions      @() }
if (-not $partCObj.PSObject.Properties['perspectives']) { $partCObj | Add-Member -Force NoteProperty perspectives @() }
if (-not $partCObj.PSObject.Properties['annexes'])      { $partCObj | Add-Member -Force NoteProperty annexes      @() }


# Normalisation stricte (anti StrictMode)
if ($partCObj.actions -is [string]) { $partCObj.actions = @([pscustomobject]@{ action = $partCObj.actions; responsable = $null; echeance = $null; commentaire = $null }) }
elseif ($partCObj.actions -and -not ($partCObj.actions -is [System.Collections.IEnumerable])) { $partCObj.actions = @($partCObj.actions) }


# perspectives: garantir liste d'objets {probleme, solution}
$px = @()
if ($null -ne $partCObj.perspectives) { $px = @($partCObj.perspectives) }
if ($partCObj.perspectives -is [string]) { $px = @([string]$partCObj.perspectives) }


# si une seule string
if ($partCObj.perspectives -is [string]) { $px = @([string]$partCObj.perspectives) }

# normaliser en objets
$partCObj.perspectives = @(
  $px | ForEach-Object {
    if ($_ -is [string]) {
      [pscustomobject]@{ probleme = ([string]$_).Trim(); solution = "" }
    }
    else {
      $o = $_
      if (-not $o.PSObject.Properties['probleme']) { $o | Add-Member -Force NoteProperty probleme "" }
      if (-not $o.PSObject.Properties['solution']) { $o | Add-Member -Force NoteProperty solution "" }
      $o.probleme = ([string]$o.probleme).Trim()
      $o.solution = if ($null -eq $o.solution) { "" } else { ([string]$o.solution).Trim() }
      $o
    }
  } |
  Where-Object { $_.probleme -and $_.probleme -ne "" }
)

# dédup par "probleme"
$partCObj.perspectives = @(
  $partCObj.perspectives |
  Group-Object { $_.probleme } |
  ForEach-Object { $_.Group | Select-Object -First 1 }
)

# fallback si vide: reprendre globalObj.problems
if (@($partCObj.perspectives).Count -eq 0 -and $globalObj.problems) {
  $partCObj.perspectives = @(
    @($globalObj.problems) | ForEach-Object {
      [pscustomobject]@{
        probleme = if ($_.PSObject.Properties['probleme']) { ([string]$_.probleme).Trim() } else { "" }
        solution = if ($_.PSObject.Properties['solution'] -and $_.solution) { ([string]$_.solution).Trim() } else { "" }
      }
    } | Where-Object { $_.probleme -and $_.probleme -ne "" } |
    Group-Object { $_.probleme } |
    ForEach-Object { $_.Group | Select-Object -First 1 }
  )
}


# annexes: garantir liste de strings
$ax = @()
if ($null -ne $partCObj.annexes) { $ax = @($partCObj.annexes) }
if ($partCObj.annexes -is [string]) { $ax = @([string]$partCObj.annexes) }

$partCObj.annexes = @(
  $ax | ForEach-Object {
    if ($_ -is [string]) { ([string]$_).Trim() }
    elseif ($_.PSObject.Properties['objet']) { ([string]$_.objet).Trim() }
    else { ([string]($_ | Out-String)).Trim() }
  } |
  Where-Object { $_ -and $_ -ne "" } |
  Sort-Object -Unique
)

# fallback annexes si vide: demandes_documents_globales
if (@($partCObj.annexes).Count -eq 0 -and $globalObj.demandes_documents_globales) {
  $partCObj.annexes = @(
    @($globalObj.demandes_documents_globales) | ForEach-Object {
      if ($_.PSObject.Properties['objet'] -and $_.objet) { ("Demande : " + ([string]$_.objet).Trim()) } else { $null }
    } | Where-Object { $_ } | Sort-Object -Unique
  )
}


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

#------------------------------------------------------------
# 3D : demandes de documents
#------------------------------------------------------------

Microsoft.PowerShell.Utility\Write-Host "Passe 3D → demandes de documents"


$pass3DUser = $Pass3D_User_Template.Replace("{GLOBAL_JSON}", $globalMeetingMergedJson)
$path = Join-Path $logsDir "pass3D_input.txt"
Write-ArtifactText -Path $path -Text $pass3DUser -ModelName $ModelPass3D


$pass3DUser_Effective = Truncate-For-Context `
  -SystemText $Pass3D_System `
  -UserText   $pass3DUser `
  -ModelName  $ModelPass3D

$path = Join-Path $logsDir "pass3D_input_effective.txt"
Write-ArtifactText -Path $path -Text $pass3DUser_Effective -ModelName $ModelPass3D


$partDObj  = $null
$pass3DRaw = $null

try {
  $pass3DRaw = Invoke-LLM -system $Pass3D_System -user $pass3DUser_Effective -model $ModelPass3D -DebugHttp:$DebugHttp
  $pass3DRaw = Unwrap-AdapterText $pass3DRaw
  if ($pass3DRaw) {
    
    $path = Join-Path $logsDir "pass3D_raw.txt"
    Write-ArtifactText -Path $path -Text $pass3DRaw -ModelName $ModelPass3D

  }

  $partDObj = Parse-LlmJsonStrict -RawText $pass3DRaw -Label "Pass3D" -LogFile $logFile
}
catch {
  Write-Warning "Pass3D: échec LLM/JSON ($_). Fallback demandes_documents_globales=[]."
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

# (3) Rattachement des demandes (d’abord par numero, puis fallback texte)
foreach ($s in $finalObj.sujets) {
  if (-not $s.PSObject.Properties['numero']) { continue }
  $num = [int]$s.numero
  $k   = ([string]$num).Trim()

  # titre de référence (le plus fiable)
  $refTitre = $null
  if ($SujetMetaByNumero.ContainsKey($k)) { $refTitre = [string]$SujetMetaByNumero[$k].titre }
  if (-not $refTitre) { $refTitre = [string]$s.titre }
  if ($null -eq $refTitre) { $refTitre = "" }
    $refTitre = ([string]$refTitre).Trim()

  # ne pas "continue" : le match par numero reste possible même sans titre


  foreach ($doc in @($partDObj.demandes_documents_globales)) {
    if (-not $doc) { continue }

    # garantir demandes_documents
    if (-not $s.PSObject.Properties['demandes_documents']) {
      $s | Add-Member -Force -NotePropertyName demandes_documents -NotePropertyValue @()
    }

    $matched = $false

    # 1) match direct par numero si présent
    $docNum = $null
    if ($doc.PSObject.Properties['numero']) {
      try { $docNum = [int]$doc.numero } catch { $docNum = $null }
    }
    if ($null -ne $docNum -and $docNum -eq $num) {
      $matched = $true
    }
        # 2) fallback : match texte sur numero / titre dans objet OU commentaire
    if (-not $matched) {
      $objet = if ($doc.PSObject.Properties['objet']) { [string]$doc.objet } else { "" }
      $commentaire = if ($doc.PSObject.Properties['commentaire']) { [string]$doc.commentaire } else { "" }

      if ($null -eq $objet) { $objet = "" }
      if ($null -eq $commentaire) { $commentaire = "" }
      $hay = (([string]$objet) + " " + ([string]$commentaire)).Trim()

      if ($hay) {
        $rxNum = "(?i)\b(point|sujet|item|odj|ordre)\s*0*$num\b|\b0*$num\s*[-–]\s*"
        if ($hay -match $rxNum) { $matched = $true }
        elseif ($refTitre -and $refTitre.Length -ge 12 -and ($hay -imatch [regex]::Escape($refTitre))) { $matched = $true }
      }
    }

    if ($matched) {
      if ($doc.PSObject.Properties['origine']) {
        $doc.origine = "reunion"
        $new2 = $doc
      } else {
        $new2 = $doc | Select-Object *, @{ Name="origine"; Expression={ "reunion" } }
      }

    

      # dédup simple (clé JSON compressée)
      $kdoc = $null
      try { $kdoc = ($new2 | ConvertTo-Json -Depth 50 -Compress) } catch { $kdoc = ($new2 | Out-String).Trim() }

      $existingKeys = @{}
      foreach ($ex in @($s.demandes_documents)) {
        try { $existingKeys[($ex | ConvertTo-Json -Depth 50 -Compress)] = $true } catch {}
      }

      if (-not $existingKeys.ContainsKey($kdoc)) {
        $s.demandes_documents += $new2
      }
    }
  }
}


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
                $s | Add-Member -Force -NotePropertyName demandes_documents -NotePropertyValue @()
            }
            foreach ($d in $match.demandes_documents) {
              if (-not $s.PSObject.Properties['demandes_documents']) {
                $s | Add-Member -Force -NotePropertyName demandes_documents -NotePropertyValue @()
              }

              $new = $d | Select-Object *, @{ Name="origine"; Expression={ "debrief_expert" } }

              # dédup simple (clé JSON compressée)
              $kdoc = $null
              try { $kdoc = ($new | ConvertTo-Json -Depth 50 -Compress) } catch { $kdoc = ($new | Out-String).Trim() }

              $existingKeys = @{}
              foreach ($ex in @($s.demandes_documents)) {
                try { $existingKeys[($ex | ConvertTo-Json -Depth 50 -Compress)] = $true } catch {}
              }

              if (-not $existingKeys.ContainsKey($kdoc)) {
                $s.demandes_documents += $new
              }
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

# -- Forcer la date si manquante : extraction depuis le contexte (etat_avancement)
if (($null -eq $partAObj.date -or [string]::IsNullOrWhiteSpace([string]$partAObj.date)) -and $ContextEtatAvancement) {
  $m = [regex]::Match($ContextEtatAvancement, '(?i)\b(\d{1,2})\s+(janvier|février|fevrier|mars|avril|mai|juin|juillet|août|aout|septembre|octobre|novembre|décembre|decembre)\s+(\d{4})\b')
  if ($m.Success) {
    $day = [int]$m.Groups[1].Value
    $mon = $m.Groups[2].Value.ToLower()
    $yr  = [int]$m.Groups[3].Value
    $map = @{
      "janvier"=1;"février"=2;"fevrier"=2;"mars"=3;"avril"=4;"mai"=5;"juin"=6;
      "juillet"=7;"août"=8;"aout"=8;"septembre"=9;"octobre"=10;"novembre"=11;"décembre"=12;"decembre"=12
    }
    if ($map.ContainsKey($mon)) {
      $partAObj.date = "{0:D4}-{1:D2}-{2:D2}" -f $yr, $map[$mon], $day
    }
  }
}

$finalDate          = Get-PropOrNull -Obj $partAObj -Name 'date'
$finalObj  | Add-Member -Force -NotePropertyName date -NotePropertyValue $finalDate

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
    $utf8NoBom
)

Microsoft.PowerShell.Utility\Write-Host "JSON FINAL → $finalPath"

"Done: $(Get-Date)" | Add-Content $logFile
Microsoft.PowerShell.Utility\Write-Host "Pipeline terminé (full JSON)."

