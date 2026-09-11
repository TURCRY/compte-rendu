<#
cr_refere_preventif_pipeline_json.ps1
=====================================================================
Pipeline AUTONOME « référé préventif » (branche Pass2F photo).

- N'appelle PAS et ne modifie PAS cr_reunion_point_mumerotes_pipeline_json.ps1.
- Lit en entrée : données brutes (ASR, Sujets, config_llm, infos_projet),
  données photo (photos.csv, photos_batch.csv, photo_subject_assignments.json)
  et certains JSON du CR généraliste (LECTURE SEULE).
- Produit : unités documentaires Pass2F, chunks adaptatifs, manifest,
  logs — dans un répertoire dédié compte_rendu_refere_preventif\ (par défaut)
  ou dans -OutDir (mode -DryRun de mise au point).
- Appels LLM/HTTP : autorises uniquement en mode controle 2F-6C2C
  (-ExecuteLlm avec -ChunkSelect, maximum 3 appels logiques) ;
  le mode DryRun 2F-6C2B reste sans appel LLM/HTTP.
- Racine de données par défaut : C:\Affaires\<id_affaire>\ (PC fixe / miroir).

Provenance des fonctions recopiées :
  Fichier source : cr_reunion_point_mumerotes_pipeline_json.ps1 (NAS live).
  Conventions : chaque fonction recopiée porte un commentaire
  « [REUSE <fichier>:<ligne>] ». Les fonctions historiques ne sont PAS modifiées.
Usage (exemple, DryRun) :
  pwsh .\cr_refere_preventif_pipeline_json.ps1 `
    -InfosProjetPath 'C:\Affaires\2025-J48\AF_Expert_ASR\transcriptions\accedit-2025-11-20\infos_projet.json' `
    -DryRun -OutDir 'C:\temp\cr_refere_dryrun_j48' -JobLabel dryrun_j48
#>
param(
  [string] $InfosProjetPath = "",
  [string] $IdAffaire = "",
  [string] $IdCaptation = "",
  [string] $DataRoot = "C:\Affaires",
  [string] $OutDir = "",
  [string] $JobLabel = "",
  [switch] $DryRun,
  [switch] $ExecuteLlm,
  [switch] $Force,
  [string] $ModelPass2F = "pass2f_local",
  [int]    $BudgetNctx = 8192,
  [int]    $MaxOutputTokens = 1800,
  [int]    $SafetyMargin = 200,
  [double] $BudgetRatio = 0.9,
  [double] $CohortGapSec = 600.0,
  [string] $ApiBase = "",
  [string] $ApiKey = "",
  [int]    $LlmTimeoutSec = 900,
  [string[]] $ChunkSelect = @(),
  [int]    $MaxLogicalLlmCalls = 3,
  [switch] $ProbeModelInfo,
  # LOT 2B2F-1 : activation de la passe globale Pass2B_2F (DryRun sans LLM)
  [switch] $BuildPass2B2F,
  [string] $GeneralistSegmentsDir = "",
  [string] $ModelPass2B2F = "report_remote",
  # LOT 2B2F-3 : parametrisation batching Pass2B_2F
  # (S2 : 35000 car. / 9625 tokens) + test reel
  # restreint (max 3 batches report_remote, A/B/C).
  [int]    $Pass2B2FMaxBatchChars = 35000,
  [int]    $Pass2B2FMaxBatchTokens = 9625,
  [switch] $Pass2B2FExecute,
  [string] $Pass2B2FSelectBatches = "",
  # LOT 2B2F-6 : parametres du test reel restreint (candidats S2 corriges A=09 B=25 C=10)
  [string] $Pass2B2FLotLabel = "2B2F-6",
  [string] $Pass2B2FCandidateMap = "A=9,B=25,C=10",
  # LOT 2B2F-7 : run complet Pass2B_2F (tous les batches du plan definitif) + autotest deterministe sans LLM.
  [switch] $Pass2B2FRunComplete,
  [switch] $TestPass2B2FMergeFlat,
  # LOT 2B2F-8 : consolidation finale interne Pass2B_2F.
  [switch] $Pass2B2FConsolidateFinal,
  [switch] $Pass2B2FConsolidateLlm,
  [string] $Pass2B2FExhaustiveJsonPath = "",
  # LOT 2B2F-9 : autotest deterministe SANS LLM/HTTP (garde semantique + trace manifest).
  [switch] $TestPass2B2FConsolidationGuard,
  # LOT 2B2F-12 : consolidation hierarchique interne Pass2B_2F (6 groupes chronologiques + finale).
  [switch] $Pass2B2FConsolidateHierarchical,
  [string] $Pass2B2FBatchOutputsDir = "",
  [int]    $Pass2B2FMaxTokensIntermediate = 4096,
  # LOT 2B2F-12 : autotest deterministe SANS LLM de la trace du manifest d'erreur.
  [switch] $TestPass2B2FErrorManifestTrace,
  # LOT 3R-1B : Pass3 refere (source globale = refere_global_meeting.json 6G)
  [switch] $Pass3Refere,
  [switch] $Pass3RefereDryRun,
  [switch] $Pass3RefereExecute,
  [string] $Pass3RefereGlobalJsonPath = "",
  [string] $Pass3RefereContextJsonPath = "",
  [string] $Pass3ReferePass2EDir = "",
  [string] $Pass3ReferePass2FOutDir = "",
  [int]    $Pass3RefereESubject = 0,
  [string] $Pass3RefereESujetCompactPath = "",
  [string[]] $Pass3RefereEChunkPaths = @(),
  [string] $Pass3RefereOutSubdir = "pass3_refere",
  [string] $Pass3RefereLotLabel = "3R-1B",
  # LOT 3R-1D : reprise (resume) Pass3 refere - ne rejoue PAS A/B/C.
  [switch] $Pass3RefereResumePlanOnly,
  [switch] $Pass3RefereResumeExecute,
  [string] $Pass3RefereResumeRequestJson = "",

  # LOT 3R-1C : autotests deterministes SANS LLM/HTTP (contrat Pass3C + compteurs manifest sur echec).
  [switch] $TestPass3CContractReplay,
  [string] $TestPass3CRawPath = "",
  [switch] $TestPass3RefereErrorCounters,
  # REFERE-E2E-2 : mode de production unique (aucun autre switch de passe active).
  # -RunReferePipeline          : chaine complete Pass2F + Pass2B_2F batches dynamiques + 6G + 3A-D + 3E + DOCX.
  # -RunReferePipelinePlanOnly  : meme resolution, budgets et artefacts de plan, AUCUN appel LLM/HTTP.
  [switch] $RunReferePipeline,
  [switch] $RunReferePipelinePlanOnly,
  [string] $ReferePass2ECompactsDir = "",
  [string] $ReferePass2FChunksDir = "",
  [string] $RefereContextJsonPath = "",
  [string] $RefereBudgetReferenceGlobalJson = "",
  [string] $RefereRendererBase = "",
  # REFERE-E2E-3E : autotests deterministes SANS LLM/HTTP - retry JSON unique Pass2F.
  [switch] $TestPass2FRetryOffline,
  [string] $TestPass2FChunk07RawPath,
  [string] $RefereLotLabel = "E2E-2"

)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:utf8Bom    = New-Object System.Text.UTF8Encoding($true)
$script:PipelineName = "cr_refere_preventif_pipeline_json"
$script:SchemaVersion = "1"
$script:LogFile = ""
$script:Manifest = $null
$script:FunctionalInputs = @()      # chemins d'entrée (garde anti-écrasement)
$script:FilesWritten = @()      # artefacts produits par le DryRun (audit)
$script:CriticalQaWarnings = New-Object System.Collections.ArrayList
$script:HttpBlocked = $true
$script:AdapterApiBase = ''
$script:AdapterApiKey  = ''
$script:AdapterAlias   = 'pass2f_local'
$script:LlmTimeoutSec  = 900
$script:LastHttpStatus = 0
$script:RefereE2E2OrchestratorLoaded = $false
$script:RefereProgress = $null

# LOT 2F-6C2C : -ExecuteLlm autorise UNIQUEMENT en mode controle (<=3 appels logiques,
# chunks imposes via -ChunkSelect 'sujet:chunk'). Aucun changement du mode DryRun 2F-6C2B.
if ($ExecuteLlm) {
  if ($DryRun) {
    throw '[cr_refere_preventif] LOT 2F-6C2C : -DryRun et -ExecuteLlm sont mutuellement exclus.'
  }
  if ([int]$MaxLogicalLlmCalls -lt 1 -or [int]$MaxLogicalLlmCalls -gt 3) {
    throw "[cr_refere_preventif] LOT 2F-6C2C : MaxLogicalLlmCalls doit etre 1..3 (recu=$MaxLogicalLlmCalls)."
  }
  $nSel = @($ChunkSelect).Count
  if ($nSel -lt 1) {
    throw "[cr_refere_preventif] LOT 2F-6C2C : -ChunkSelect requis avec -ExecuteLlm (ex: -ChunkSelect '6:1','17:6','20:8')."
  }
  if ($nSel -gt 3) {
    throw "[cr_refere_preventif] LOT 2F-6C2C : -ChunkSelect limite a 3 chunks logiques (recu=$nSel)."
  }
}

# [REUSE cr_reunion_point_mumerotes_pipeline_json.ps1:288-291] wrappers log (renommés,
# sans redéfinir Write-Host pour ne pas masquer la cmdlet).
function Write-CrInfo([string]$m) { Microsoft.PowerShell.Utility\Write-Host ("[INFO]  " + $m) -ForegroundColor Cyan }
function Write-CrWarn([string]$m) { Microsoft.PowerShell.Utility\Write-Host ("[WARN]  " + $m) -ForegroundColor Yellow }
function Write-CrErr ([string]$m) { Microsoft.PowerShell.Utility\Write-Host ("[ERROR] " + $m) -ForegroundColor Red }

function Add-CrLogLine {
  param([string]$Message)
  if (-not $script:LogFile) { return }
  ("{0:u} {1}" -f (Get-Date), $Message) | Add-Content -LiteralPath $script:LogFile -Encoding UTF8
}

# [REUSE cr_reunion_point_mumerotes_pipeline_json.ps1:399-410] Ensure-Dir
function Ensure-Dir {
  param([string]$Path)
  if (-not $Path) { return }
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path | Out-Null
  }
}

# [REUSE cr_reunion_point_mumerotes_pipeline_json.ps1:411-416] Estimate-Tokens
function Estimate-Tokens([string]$text) {
  if (-not $text) { return 0 }
  return [int][math]::Ceiling($text.Length / 4.0)
}

# [REUSE cr_reunion_point_mumerotes_pipeline_json.ps1:477-524] Get-ContextBudget
# (adaptation : ajout des alias pass2f_* ; budgets historiques INCHANGÉS)
function Get-ContextBudget {
  param([string] $ModelName)
  switch ($ModelName) {
    "annoter_segments_remote"  { return @{ NCtx=120000; MaxTok=4000; Margin=2000 } }
    "annoter_segments_remote_alt"  { return @{ NCtx=120000; MaxTok=4000; Margin=2000 } }
    "report_remote"            { return @{ NCtx=120000; MaxTok=4000; Margin=2000 } }
    "report_remote_alt"        { return @{ NCtx=120000; MaxTok=4000; Margin=2000 } }
    "pass3_remote"             { return @{ NCtx=32768; MaxTok=2000; Margin=800 } }
    "pass3_remote_alt"         { return @{ NCtx=32768; MaxTok=2000; Margin=800 } }
    "pass3a_remote"            { return @{ NCtx=32768; MaxTok=1200; Margin=800 } }
    "pass3a_remote_alt"        { return @{ NCtx=32768; MaxTok=2000; Margin=800 } }
    "pass3b_remote"            { return @{ NCtx=32768; MaxTok=1800; Margin=800 } }
    "pass3b_remote_alt"        { return @{ NCtx=32768; MaxTok=2000; Margin=800 } }
    "pass3c_remote"            { return @{ NCtx=32768; MaxTok=1800; Margin=800 } }
    "pass3c_remote_alt"        { return @{ NCtx=32768; MaxTok=2000; Margin=800 } }
    "pass3d_remote"            { return @{ NCtx=32768; MaxTok=1200; Margin=800 } }
    "pass3d_remote_alt"        { return @{ NCtx=32768; MaxTok=2000; Margin=800 } }
    "pass3e_remote"            { return @{ NCtx=32768; MaxTok=1800; Margin=800 } }
    "pass3e_remote_alt"        { return @{ NCtx=32768; MaxTok=2000; Margin=800 } }
    # Budgets Pass2F : valeurs EXPÉRIMENTALES NON CONFIRMÉES (statut dans le manifest)
    "pass2f_local"             { return @{ NCtx=$BudgetNctx; MaxTok=$MaxOutputTokens; Margin=$SafetyMargin; Status="experimental_unconfirmed" } }
    "pass2f_remote"            { return @{ NCtx=$BudgetNctx; MaxTok=$MaxOutputTokens; Margin=$SafetyMargin; Status="experimental_unconfirmed" } }
    "gpt-4o-mini"             { return @{ NCtx=$BudgetNctx; MaxTok=$MaxOutputTokens; Margin=$SafetyMargin; Status="experimental_unconfirmed" } }
    default                    { return @{ NCtx=4096; MaxTok=1024; Margin=128; Status="historical_default" } }
  }
}

# [REUSE cr_reunion_point_mumerotes_pipeline_json.ps1:417-476] Enforce-ContextLimit
# (recopié tel quel ; en DryRun il n'est PAS exécuté sur des données réelles —
#  on calcule seulement enforce_needed dans le plan de chunk.)
function Enforce-ContextLimit {
  param(
    [string] $SystemPrompt,
    [string] $UserPrompt,
    [string] $Label,
    [string] $LogFile,
    [string] $ModelName
  )
  $budget  = Get-ContextBudget $ModelName
  $nCtx    = $budget.NCtx
  $maxTok  = $budget.MaxTok
  $margin  = $budget.Margin
  $tokSys  = Estimate-Tokens $SystemPrompt
  $tokUser = Estimate-Tokens $UserPrompt
  $tokTotal = $tokSys + $tokUser
  $available = [int](($nCtx - $maxTok - $margin) * 0.9)
  if ($available -lt 512) { $available = 512 }
  if ($tokTotal -le $available) { return $UserPrompt }
  $maxUserTokens = $available - $tokSys
  if ($maxUserTokens -le 0) { return "" }
  $maxUserChars = [int]($maxUserTokens * 4)
  if ($UserPrompt.Length -le $maxUserChars) { return $UserPrompt }
  $headChars = [int]($maxUserChars * 0.4)
  $tailChars = $maxUserChars - $headChars
  $headPart = $UserPrompt.Substring(0, [math]::Min($headChars, $UserPrompt.Length))
  $tailPart = ""
  if ($UserPrompt.Length -gt $headChars) {
    $tailPart = $UserPrompt.Substring($UserPrompt.Length - [math]::Min($tailChars, $UserPrompt.Length - $headChars))
  }
  return ($headPart + "`n[...]`n" + $tailPart)
}

# [REUSE cr_reunion_point_mumerotes_pipeline_json.ps1:1011-1019] Convert-SecondsToHms
function Convert-SecondsToHms {
  param([int] $Sec)
  if ($Sec -lt 0) { $Sec = 0 }
  return ([TimeSpan]::FromSeconds($Sec).ToString("hh\:mm\:ss"))
}

# [REUSE cr_reunion_point_mumerotes_pipeline_json.ps1:1410-1430] Unwrap-AdapterText
function Unwrap-AdapterText {
  param([string] $Raw)
  if (-not $Raw) { return $Raw }
  $t = $Raw.Trim()
  if ($t.StartsWith("{")) {
    try {
      $o = $t | ConvertFrom-Json
      if ($o -and $o.PSObject.Properties["text"]) { return [string]$o.text }
    } catch { }
  }
  return $Raw
}

# [REUSE dependency_plan.psm1:5-12] Get-CrSha256Text (équivalent local, sans import obligatoire)
function Get-CrSha256Text {
  param([AllowEmptyString()][string] $Text)
  $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Text)
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "") }
  finally { $sha.Dispose() }
}

function Get-FileSha256 {
  param([string] $Path)
  if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

# [REUSE dependency_plan.psm1:300-317] écriture atomique (tmp + Move-Item)
function Write-CrJsonAtomic {
  param(
    [Parameter(Mandatory=$true)][string] $Path,
    [Parameter(Mandatory=$true)][object] $Obj,
    [switch] $Compress
  )
  $fullOut = [System.IO.Path]::GetFullPath($Path)
  foreach ($inPath in @($script:FunctionalInputs)) {
    if (-not $inPath) { continue }
    $fullIn = [System.IO.Path]::GetFullPath($inPath)
    if ($fullIn -ieq $fullOut) {
      throw "[garde anti-écrasement] sortie sur un chemin d'entrée interdit: $Path"
    }
  }
  $dir = Split-Path $Path -Parent
  Ensure-Dir $dir
  $depth = 100
  $json = if ($Compress) { $Obj | ConvertTo-Json -Depth $depth -Compress } else { $Obj | ConvertTo-Json -Depth $depth }
  $tmp = $Path + ".tmp." + [guid]::NewGuid().ToString("N")
  [IO.File]::WriteAllText($tmp, $json, $script:utf8NoBom)
  try {
    Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
  } catch {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    throw
  }
}

function Write-CrTextUtf8NoBom {
  param([string] $Path, [string] $Text)
  $dir = Split-Path $Path -Parent
  Ensure-Dir $dir
  [IO.File]::WriteAllText($Path, $Text, $script:utf8NoBom)
}

function ConvertTo-HashtableDeep {
  <#
    Convertit la sortie ConvertFrom-Json (PSCustomObject imbriques) en hashtables,
    pour un acces sans erreur StrictMode dans tout le pipeline.
  #>
  param($InputObject)
  if ($null -eq $InputObject) { return $null }
  if (($InputObject -is [System.Collections.IEnumerable]) -and -not ($InputObject -is [string])) {
    $list = New-Object System.Collections.ArrayList
    foreach ($item in $InputObject) { [void]$list.Add((ConvertTo-HashtableDeep -InputObject $item)) }
    return ,$list.ToArray()
  }
  if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
    $h = @{}
    foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = (ConvertTo-HashtableDeep -InputObject $p.Value) }
    return $h
  }
  return $InputObject
}

function Read-JsonFile {
  param([string] $Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Fichier JSON introuvable: $Path" }
  $obj = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
  return (ConvertTo-HashtableDeep -InputObject $obj)
}

function Test-CrJsonFile {
  param([string] $Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
  try { $null = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop; return $true } catch { return $false }
}

# [REUSE cr_reunion_point_mumerotes_pipeline_json.ps1:4692-4735] Merge-ListUnique
function Merge-ListUnique {
  param([object[]] $Lists)
  $acc  = New-Object System.Collections.ArrayList
  $seen = @{}
  foreach ($lst in $Lists) {
    if ($null -eq $lst) { continue }
    $items = @()
    if ($lst -is [string]) { $s = $lst.Trim(); if ($s) { $items = @($s) } else { continue } }
    elseif ($lst -is [System.Collections.IDictionary]) { $items = @($lst) }
    elseif ($lst -is [pscustomobject]) { $items = @($lst) }
    elseif ($lst -is [System.Collections.IEnumerable]) { $items = @($lst) }
    else { $items = @($lst) }
    foreach ($it in $items) {
      if ($null -eq $it) { continue }
      $k = $null
      try { $k = ($it | ConvertTo-Json -Depth 50 -Compress) } catch { $k = ($it | Out-String).Trim() }
      if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $acc.Add($it) | Out-Null }
    }
  }
  return $acc.ToArray()
}
# ============================================================================
# Section 2 - Constantes et helpers Pass2F (LOT 2F-6C2B)
# ============================================================================
$script:CharPerToken       = 4
$script:SlackFill          = 0.95
$script:MinAvailableTokens = 512
$script:CohortGapSec       = 600.0

# Budget pass2f_local : valeurs EXPERIMENTALES NON CONFIRMEES (statut manifest).
$script:BudgetPass2F = @{
  alias       = [string]$ModelPass2F
  n_ctx       = [int]$BudgetNctx
  max_tok_out = [int]$MaxOutputTokens
  margin      = [int]$SafetyMargin
  status      = "experimental_unconfirmed"
  source      = "param 2F-6C2B (BudgetNctx=$BudgetNctx, MaxOutputTokens=$MaxOutputTokens, SafetyMargin=$SafetyMargin) ; NCtx a confirmer /model_info PC fixe"
}
# ============================================================================
# LOT 2F-6C2C5 - Budget de SORTIE estime (output-aware chunking)
# ----------------------------------------------------------------------------
# Calibrage CONSERVATEUR (3 exemples reels 6C2C3, NON tokenizer-exact) :
#   sujet 6:1   (5 photos) : reponse 3219 chars, parse OK
#   sujet 17:6  (5 photos) : reponse 3016 chars, parse OK
#   sujet 20:8  (8 photos) : reponse 4310 chars, JSON TRONQUE (plafond atteint)
# Plafond demande max_tokens=1800 ; backend Gemma garde une limite de
# generation configurable a 2048 tokens. Le raw 20:8 est coupe en plein nom de
# propriete ("elements_non_") : generation consommee ~= budget de sortie.
# Extrapolation volontaire pour la PLANIFICATION :
#   * ~2.4 caracteres/token pour la sortie Gemma en francais
#     (4310 chars ~= 1800 tokens) => $script:Pass2FOutputCharsPerToken ;
#   * cout fixe JSON ~600 caracteres (en-tete, synthese, incertitudes, clore) ;
#   * cout moyen par photo_context ~500 caracteres (part des points incluse).
# Formule : output_est(photos) = 600 + 500 * photos, comparee (apres
# conversion tokens via 2.4 chars/token) au budget de sortie = max_tokens.
# => 8 photos (1917 tokens est.) REFUSE, 7 photos (1709 tokens est.) passe :
#    garde-fou derive des sorties reelles, aucun nombre magique non documente.
# AUCUN budget de production modifie (n_ctx=8192, max_tokens=1800, marge=200,
# alias pass2f_local, temperature 0.2, prompt 6B : inchanges).
# ============================================================================
$script:Pass2FOutputCharsPerToken = 2.4
$script:Pass2FOutputFixedChars    = 600
$script:Pass2FOutputPerPhotoChars = 500


# --- Texte du message user autonome Pass2F valide en 2F-6B (verdict PROMPT_OK).
# [REUSE pass2f6c1_common.py:50-131 (SECTIONS_COMMON/FINAL) - texte 6B]
$script:SectionMission = @"
[MISSION]
Tu analyses un SUJET CIBLE deja determine par une affectation humaine des photos.
Tu ne dois pas rechercher, proposer ou substituer un autre sujet primaire.
Ta mission est de determiner ce que la sequence photographique et son contexte temporel apportent utilement a la comprehension du sujet cible.
Il s'agit d'une synthese intermediaire de rang 2 destinee a etre utilisee ulterieurement par une passe de rang 3 (Pass3E).
Tu ne produis pas une conclusion finale d'expertise.
"@

$script:SectionSources = @"
[REGLES SUR LES SOURCES]
Les sources n'ont pas le meme statut.
1) AFFECTATION HUMAINE (subject_numero, titre, localisation, description) : AUTORITATIVE. Le sujet est impose. Les echanges peuvent legitiment mentionner un voisin, une autre propriete ou un autre ouvrage : emploie « sujet cible », jamais « sujet exclusif ».
2) VLM (description visuelle) : description visuelle BRUTE. Elle repond a « qu'est-ce qui semble visible sur l'image ? ». Elle peut contenir des details exacts mais inutiles a l'expertise (mobilier ordinaire, objets personnels, vegetation, couleurs accessoires...). Ne conserve que les elements visuels ayant une valeur documentaire ou technique pour le sujet cible.
3) LIBELLE / COMMENTAIRE existants : annotations anterieures. Elles peuvent deja avoir utilise l'ASR : leur repetition dans l'ASR ne constitue donc pas automatiquement une seconde confirmation independante. Evite le double comptage.
4) DICTEE photo (si presente) : indication directe de ce que l'expert cherchait a documenter. Absence normale et non bloquante.
5) ASR reunion : contexte oral primaire. La presence d'une phrase dans la fenetre temporelle ne signifie pas que cette phrase decrit necessairement la photographie.
6) CHRONOLOGIE / COHORTE : aide a comprendre ce qui etait inspecte a cet instant. Elle ne rend pas chaque parole exclusivement relative a la photo. Les contextes de sujets peuvent se chevaucher.
"@

$script:SectionVisibleOral = @"
REGLE FONDAMENTALE VISIBLE / ORAL
Ne dis jamais qu'un element est visible sur une photographie si cette information provient uniquement de l'ASR.
Si un element est seulement evoque oralement, indique qu'il est evoque ou discute pendant la visite.
Si le VLM et l'ASR convergent reellement sur le meme element, tu peux signaler cette convergence, sans transformer une hypothese de cause en constat etabli.
"@

$script:SectionAntiInference = @"
REGLE ANTI-INFERENCE
N'effectue aucune deduction materielle a partir d'un simple terme de vocabulaire, d'une categorie de piece ou d'une proximite semantique.
Exemples :
- « piece d'eau » ne signifie pas « zone humide » ;
- « fenetre » ne signifie pas « infiltration » ;
- « ancien » ne signifie pas « degrade » ;
- « proche d'un mur » ne signifie pas « fissure du mur ».
Une caracteristique physique ne peut etre affirmee que si une source la documente effectivement.
"@

$script:SectionBruit = @"
BRUIT DOCUMENTAIRE
Ecarte les informations sans utilite pour le sujet cible : mobilier ordinaire, objets personnels, couleurs accessoires, echanges administratifs, organisation de la visite, conversations sans rapport technique, sauf si elles sont necessaires pour comprendre la portee documentaire de la sequence.
Ne supprime pas une information seulement parce qu'elle est negative : l'absence de fissure ou de desordre peut etre utile si elle est clairement constatee dans une zone precisement identifiee.
Ne generalise jamais un constat negatif a l'ensemble de l'immeuble.
"@

$script:SectionInterdictions = @"
[INTERDICTIONS]
- NE RECOPIE PAS le payload d'entree.
- NE REPRODUIS PAS integralement le VLM, l'ASR, le commentaire ou la chronologie.
- Ne change pas le sujet cible.
- N'invente pas un desordre, une localisation, une cause, une responsabilite, une chronologie.
- Ne transforme pas une question en constat, ni une hypothese orale en fait etabli.
- Ne considere pas chaque phrase de la fenetre temporelle comme relative a la photo.
- Ne decris pas exhaustivement le mobilier ou l'environnement.
- Ne produis pas une conclusion finale d'expertise.
Tu dois analyser et synthetiser. Les citations de lignes ASR doivent etre referencees par leurs numeros [ROW n], pas reproduites longuement.
"@

$script:SectionSchema = @"
[SCHEMA JSON DE SORTIE]
{
  "schema_version": 1,
  "source_pass": "2F",
  "subject_numero": 0,
  "synthese_intermediaire": "",
  "points_documentes": [
    {
      "texte": "",
      "nature": "constat_visuel|contexte_oral|constat_multimodal|declaration|hypothese|autre",
      "photos": [],
      "asr_rows": [],
      "niveau_appui": "fort|moyen|faible"
    }
  ],
  "incertitudes": [],
  "photo_contexts": [
    {
      "photo": "",
      "apport_contextuel": "",
      "elements_visuels_utiles": [],
      "elements_oraux_associes": [],
      "elements_non_retenus": []
    }
  ]
}
Toutes les cles doivent etre presentes.
Ne cree aucune autre cle.
Une liste vide est autorisee et preferable a une information inventee.
schema_version = 1 ; source_pass = "2F" ; subject_numero = numero du sujet cible.
"@

$script:SectionFinal = @"
[INSTRUCTION FINALE]
Reponds uniquement avec un objet JSON valide conforme exactement au schema demande.
Aucun Markdown.
Aucune explication avant ou apres le JSON.
Ne repete pas les donnees d'entree.
"@

$script:Pass2FSectionsCommon = ($script:SectionMission + "`n`n" + $script:SectionSources + "`n`n" + $script:SectionVisibleOral + "`n`n" + $script:SectionAntiInference + "`n`n" + $script:SectionBruit + "`n`n" + $script:SectionInterdictions + "`n`n" + $script:SectionSchema)
$script:Pass2FFinal = $script:SectionFinal

# [REUSE cr_reunion_point_mumerotes_pipeline_json.ps1:399-410] helpers supplementaires
function Read-CrCsvRows {
  param([string] $Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "CSV introuvable: $Path" }
  # LOT 2B2F-5 : lecture CSV multi-lignes correcte (champs quotes contenant des
  # retours a la ligne, delimiteur ; et encodage UTF-8 conserves). Remplace
  # Get-Content + ConvertFrom-Csv qui decoupaient le fichier ligne physique par
  # ligne physique (perte ~32 % du texte photo J48, 62 champs multi-lignes).
  $rows = @(Import-Csv -LiteralPath $Path -Delimiter ';' -Encoding UTF8)
  return $rows
}

function Convert-RowToHashtable {
  param($Row)
  $h = @{}
  if ($null -eq $Row) { return $h }
  foreach ($prop in $Row.PSObject.Properties) {
    if ($null -ne $prop.Name) {
      $v = $prop.Value
      if ($null -eq $v) { $h[[string]$prop.Name] = '' } else { $h[[string]$prop.Name] = [string]$v }
    }
  }
  return $h
}

function Get-CrField {
  param($RowHash, [string] $Name)
  if ($null -eq $RowHash) { return '' }
  if ($RowHash.ContainsKey($Name)) { $v = $RowHash[$Name]; if ($null -eq $v) { return '' } else { return ([string]$v).Trim() } }
  return ''
}

function New-PhotoKey {
  param([string] $RelOrName)
  $s = [string]$RelOrName
  $s = $s.Trim()
  if ($s -match '([^\\/]+)$') { return $Matches[1] }
  return $s
}

function Get-CrProp {
  <#
    Acces de propriete sans erreur StrictMode, compatible hashtable ET PSCustomObject
    (ConvertFrom-Json). Retour $null si absente.
  #>
  param($Obj, [string] $Name)
  if ($null -eq $Obj) { return $null }
  if ($Obj -is [System.Collections.IDictionary]) {
    if ($Obj.ContainsKey($Name)) { return $Obj[$Name] }
    return $null
  }
  $p = $Obj.PSObject.Properties[$Name]
  if ($null -ne $p) { return $p.Value }
  return $null
}

function Get-CrPropString {
  param($Obj, [string] $Name)
  $v = Get-CrProp -Obj $Obj -Name $Name
  if ($null -eq $v) { return '' }
  return ([string]$v).Trim()
}

function Get-CrPropInt {
  param($Obj, [string] $Name)
  $v = Get-CrProp -Obj $Obj -Name $Name
  if ($null -eq $v -or ([string]$v).Trim() -eq '') { return 0 }
  try { return [int]$v } catch { return 0 }
}
# ============================================================================
# Section 3 - Resolution des chemins et chargement des sources (lecture seule)
# ============================================================================
function Add-ReferePreventifInput {
  param([string] $Path)
  if (-not $Path) { return }
  if (Test-Path -LiteralPath $Path) {
    if (@($script:FunctionalInputs) -notcontains $Path) {
      $script:FunctionalInputs = @($script:FunctionalInputs) + $Path
    }
  }
}

function Resolve-ReferePreventifPaths {
  <#
    Resout l'arborescence reelle d'une affaire/captation :
    C:\Affaires\<id_affaire>\AF_Expert_ASR\transcriptions\<id_captation>\
    C:\Affaires\<id_affaire>\AE_Expert_captations\<id_captation>\photos\
    C:\Affaires\<id_affaire>\BE_Traitement_captations\<id_captation>\compte_rendu_LLM\
    Entree : -InfosProjetPath OU (-IdAffaire + -IdCaptation). DataRoot prioritaire.
  #>
  param(
    [string] $InfosProjetPath,
    [string] $IdAffaire,
    [string] $IdCaptation,
    [string] $DataRoot,
    [switch] $Register
  )
  $infos = $null
  if ($InfosProjetPath) {
    if (-not (Test-Path -LiteralPath $InfosProjetPath -PathType Leaf)) {
      throw "[Resolve-ReferePreventifPaths] infos_projet.json introuvable: $InfosProjetPath"
    }
    $infos = Read-JsonFile -Path $InfosProjetPath
    if ($Register) { Add-ReferePreventifInput $InfosProjetPath }
  }
  if (-not $IdAffaire) {
    if ($infos -and $infos.id_affaire) { $IdAffaire = [string]$infos.id_affaire } else { throw "[Resolve-ReferePreventifPaths] IdAffaire manquant (fournir -IdAffaire ou -InfosProjetPath valide)" }
  }
  if (-not $IdCaptation) {
    if ($infos -and $infos.id_captation) { $IdCaptation = [string]$infos.id_captation } else { throw "[Resolve-ReferePreventifPaths] IdCaptation manquant (fournir -IdCaptation ou -InfosProjetPath valide)" }
  }
  $root = [string]$DataRoot
  if (-not $root) { $root = 'C:\Affaires' }
  # Compatibilite profil pcfixe : si DataRoot par defaut vide sur le PC fixe,
  # retomber sur infos_projet.pcfixe.root_affaires quand il existe.
  if ($root -eq 'C:\Affaires' -and $infos -and $infos.pcfixe -and $infos.pcfixe.root_affaires) {
    $alt = [string]$infos.pcfixe.root_affaires
    if ($alt -and (Test-Path -LiteralPath $alt)) { $root = $alt }
  }
  $affaireRoot = Join-Path $root $IdAffaire
  if (-not (Test-Path -LiteralPath $affaireRoot)) {
    throw "[Resolve-ReferePreventifPaths] dossier affaire introuvable: $affaireRoot (verifier la synchro C:\Affaires)"
  }
  $transcriptionDir = Join-Path $affaireRoot (Join-Path 'AF_Expert_ASR' (Join-Path 'transcriptions' $IdCaptation))
  $photosDir        = Join-Path $affaireRoot (Join-Path 'AE_Expert_captations' (Join-Path $IdCaptation 'photos'))
  $crDir            = Join-Path $affaireRoot (Join-Path 'BE_Traitement_captations' (Join-Path $IdCaptation 'compte_rendu_LLM'))
  foreach ($d in @($transcriptionDir, $photosDir, $crDir)) {
    if (-not (Test-Path -LiteralPath $d -PathType Container)) {
      Write-CrWarn "[Resolve-ReferePreventifPaths] dossier attendu introuvable: $d"
    }
  }
  $paths = @{
    AffaireRoot      = $affaireRoot
    IdAffaire        = $IdAffaire
    IdCaptation      = $IdCaptation
    DataRoot         = $root
    TranscriptionDir = $transcriptionDir
    PhotosDir        = $photosDir
    CompteRenduDir   = $crDir
    InfosProjetPath  = $InfosProjetPath
    ConfigLlmPath    = Join-Path $transcriptionDir 'config_llm.json'
    SujetsCsvPath    = Join-Path $transcriptionDir 'Sujets.csv'
    SujetsXlsxPath   = Join-Path $transcriptionDir 'Sujets.xlsx'
    PhotosCsvPath    = Join-Path $photosDir 'photos.csv'
    PhotosBatchCsvPath = Join-Path $photosDir 'photos_batch.csv'
    AssignmentsJsonPath = Join-Path $photosDir 'photo_subject_assignments.json'
    AsrCsvPath       = ''
  }
  if ($Register) {
    Add-ReferePreventifInput $paths.ConfigLlmPath
    Add-ReferePreventifInput $paths.SujetsCsvPath
    Add-ReferePreventifInput $paths.PhotosCsvPath
    Add-ReferePreventifInput $paths.PhotosBatchCsvPath
    Add-ReferePreventifInput $paths.AssignmentsJsonPath
  }
  return $paths
}

function Get-CrLeafName {
  <#
    Basename portable Windows/Linux.
    Ne pas utiliser [System.IO.Path]::GetFileName() sur une chaine UNC Windows
    executee sous Linux : sur Linux '\' n'est pas un separateur et GetFileName
    renverrait le chemin complet (bug confirme dans le conteneur cr-pipeline).
  #>
  param([string] $Value)
  $s = [string]$Value
  if (-not $s) { return '' }
  $s = $s.Trim().Trim('"')
  $s = $s -replace '\\', '/'
  $s = $s.TrimEnd('/')
  $i = $s.LastIndexOf('/')
  if ($i -ge 0) { $s = $s.Substring($i + 1) }
  return $s
}

function ConvertTo-ContainerAsrPath {
  <#
    Windows/UNC -> chemin conteneur. Meme logique que to_container_path de
    Scripts/run_compte_rendu_avec_sujets.sh (C:\Affaires, UNC NAS / PC fixe /
    VPN, /volume1/Affaires -> /data/Affaires). Entree inchangee si aucun
    prefixe connu ne correspond.
  #>
  param([string] $Value)
  $s = [string]$Value
  if (-not $s) { return '' }
  $s = $s.Trim().Trim('"')
  if (-not $s) { return '' }
  $s = $s -replace '\\', '/'
  $prefixes = @(
    'C:/Affaires/',
    '//192.168.1.20/Affaires/',
    '//192.168.0.120/Affaires/',
    '//192.168.0.155/Affaires/',
    '//10.0.1.10/Affaires/',
    '/volume1/Affaires/'
  )
  foreach ($prefix in $prefixes) {
    if ($s.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
      return '/data/Affaires/' + $s.Substring($prefix.Length)
    }
  }
  return $s
}

function Test-IsPhotoAsrCsvName {
  <#
    Exclusion explicite des variantes photo, comme le grep -v (photo) du
    generaliste (Scripts/run_compte_rendu_avec_sujets.sh).
  #>
  param([string] $Name)
  return ([string]$Name).ToLowerInvariant().Contains('(photo)')
}

function Get-AsrCsvPartKey {
  <#
    Cle de partie d'un CSV ASR : nom sans le marqueur (wav) ni l'extension.
    Evite de compter deux fois la meme partie (X_mono16_16000Hz.csv et
    X_mono16_16000Hz(wav).csv) tout en distinguant part 1 / part 2.
  #>
  param([string] $Name)
  $k = [string]$Name
  $k = $k -replace '\(wav\)', ''
  $k = $k -replace '\.csv$', ''
  return $k.Trim()
}

function Resolve-AsrCsvPath {
  <#
    Resolution du CSV ASR principal, portable Windows/Linux. Priorite :
      1) basename de infos.fichier_transcription (fichier precis) ; si ce chemin
         designe un dossier, prendre le .csv non (photo) le plus recent
         (logique ls -1t + grep -v (photo) du generaliste) ;
      2) CSV agrege/legacy explicitement complet (*_complet_*.csv) ;
      3) CSV principal actuel ..._mono16_16000Hz(wav).csv (ou legacy sans (wav)) ;
      4) plusieurs parties distinctes sans agregat -> erreur explicite, aucune
         selection arbitraire.
    Les (photo).csv sont exclus a chaque etape.
  #>
  param($Paths, $Infos)

  $dir = [string]$Paths.TranscriptionDir

  $allCsv = @()
  if ($dir -and (Test-Path -LiteralPath $dir -PathType Container)) {
    $allCsv = @(Get-ChildItem -LiteralPath $dir -Filter '*.csv' -File -ErrorAction SilentlyContinue)
  }
  $nonPhoto = @($allCsv | Where-Object { $_ -and (-not (Test-IsPhotoAsrCsvName $_.Name)) })
  $sortSpec = @{ Expression = 'LastWriteTime'; Descending = $true }, @{ Expression = 'Name'; Descending = $false }
  $aggregated = @($nonPhoto | Where-Object { $_.Name -like '*_complet_*' } | Sort-Object -Property $sortSpec)
  $mainParts = @($nonPhoto | Where-Object { $_.Name -like '*_mono16_16000Hz*' -and $_.Name -notlike '*_complet_*' } | Sort-Object -Property $sortSpec)

  $ft = ''
  if ($Infos -and $Infos.fichier_transcription) { $ft = [string]$Infos.fichier_transcription }
  $ft = ([string]$ft).Trim().Trim('"')

  # --- 1) fichier_transcription : fichier precis, puis dossier ---
  if ($ft) {
    $leaf = Get-CrLeafName $ft
    if ($leaf -and -not (Test-IsPhotoAsrCsvName $leaf)) {
      $cand = Join-Path $dir $leaf
      if ($dir -and (Test-Path -LiteralPath $cand -PathType Leaf)) {
        # Garde-fou : un part N explicite ne doit pas tronquer une captation
        # dont un CSV agrege existe.
        if (($leaf -notlike '*_complet_*') -and ($mainParts.Count -gt 1) -and ($aggregated.Count -ge 1)) {
          Write-CrWarn ("[Resolve-AsrCsvPath] fichier_transcription pointe une partie (" + $leaf + ") alors qu un CSV agrege existe ; agregat prefere : " + $aggregated[0].FullName)
          return $aggregated[0].FullName
        }
        return $cand
      }
    }
    $ftDir = ConvertTo-ContainerAsrPath $ft
    if ($ftDir -and (Test-Path -LiteralPath $ftDir -PathType Container)) {
      $dirCsv = @(Get-ChildItem -LiteralPath $ftDir -Filter '*.csv' -File -ErrorAction SilentlyContinue |
                  Where-Object { $_ -and (-not (Test-IsPhotoAsrCsvName $_.Name)) } |
                  Sort-Object -Property $sortSpec)
      if ($dirCsv.Count -gt 0) { return $dirCsv[0].FullName }
      throw "[Resolve-AsrCsvPath] dossier fichier_transcription sans .csv exploitable (hors (photo)) : $ftDir"
    }
  }

  # --- 2) CSV agrege/legacy explicitement complet ---
  if ($aggregated.Count -ge 1) { return $aggregated[0].FullName }

  # --- 3) CSV principal actuel (ou legacy sans (wav)) ---
  $partKeys = @($mainParts | ForEach-Object { Get-AsrCsvPartKey $_.Name } | Sort-Object -Unique)
  if ($partKeys.Count -eq 1) { return $mainParts[0].FullName }

  # --- 4) plusieurs parties distinctes sans agregat : blocage explicite ---
  if ($partKeys.Count -gt 1) {
    $names = (@($mainParts | ForEach-Object { $_.Name }) -join ' | ')
    throw ("[Resolve-AsrCsvPath] captation multi-parties sans CSV agrege : " + $mainParts.Count + " candidats ASR non (photo) dans " + $dir + " -> " + $names + " . Fournir un CSV agrege (*_complet_*.csv) ou pointer infos_projet.fichier_transcription sur le fichier a utiliser ; aucune selection arbitraire.")
  }

  return ''
}

function Read-CaptureSources {
  <#
    Charge (lecture seule) : infos_projet, config_llm, Sujets.csv, ASR complet,
    photos.csv, photos_batch.csv, photo_subject_assignments.json et decouvre les
    JSON du CR generaliste (candidats lecture, non requis pour les unites Pass2F).
    Retour : hashtable context complet.
  #>
  param($Paths)
  $infos = Read-JsonFile -Path $Paths.InfosProjetPath
  Add-ReferePreventifInput $Paths.InfosProjetPath

  $config = @{}
  if (Test-Path -LiteralPath $Paths.ConfigLlmPath -PathType Leaf) {
    $config = Read-JsonFile -Path $Paths.ConfigLlmPath
    Add-ReferePreventifInput $Paths.ConfigLlmPath
  }

  # Fenetre ASR commentaire (JAMAIS hardcodee) : config_llm.default_delays.commentaire
  # puis fallback infos_projet.plages_utilisees.commentaire, avec tracage source.
  $beforeSec = $null; $afterSec = $null; $winSource = ''
  $dd = $null
  if ($config -and $config.default_delays) { $dd = $config.default_delays }
  if ($dd -and $dd.commentaire -and ($null -ne $dd.commentaire.before) -and ($null -ne $dd.commentaire.after)) {
    $beforeSec = [double]$dd.commentaire.before
    $afterSec  = [double]$dd.commentaire.after
    $winSource = $Paths.ConfigLlmPath + '::default_delays.commentaire'
  } else {
    $plages = $null
    if ($infos -and $infos.plages_utilisees) { $plages = $infos.plages_utilisees }
    if ($plages -and $plages.commentaire -and ($null -ne $plages.commentaire.before) -and ($null -ne $plages.commentaire.after)) {
      $beforeSec = [double]$plages.commentaire.before
      $afterSec  = [double]$plages.commentaire.after
      $winSource = $Paths.InfosProjetPath + '::plages_utilisees.commentaire (fallback)'
    }
  }
  if ($null -eq $beforeSec -or $null -eq $afterSec) {
    throw "[Read-CaptureSources] fenetre ASR commentaire introuvable (config_llm.json default_delays.commentaire / infos_projet.json plages_utilisees) - ne pas hardcoder"
  }

  $asrCsv = Resolve-AsrCsvPath -Paths $Paths -Infos $Infos
  if (-not $asrCsv) { throw "[Read-CaptureSources] CSV ASR complet introuvable dans $($Paths.TranscriptionDir)" }
  Add-ReferePreventifInput $asrCsv

  # --- Sujets (referentiel canonique Sujets.csv) ---
  $subjects = New-Object System.Collections.ArrayList
  if (Test-Path -LiteralPath $Paths.SujetsCsvPath -PathType Leaf) {
    foreach ($r in @(Read-CrCsvRows -Path $Paths.SujetsCsvPath)) {
      $h = Convert-RowToHashtable $r
      $num = Get-CrField $h 'numero'
      if (-not $num) { continue }
      $subjects.Add(@{ numero=[int]$num; titre=(Get-CrField $h 'titre'); localisation=(Get-CrField $h 'localisation'); description=(Get-CrField $h 'description'); source_file=[string]$Paths.SujetsCsvPath }) | Out-Null
    }
  } else {
    Write-CrWarn "Sujets.csv absent ($($Paths.SujetsCsvPath)) ; Sujets.xlsx non lu dans ce lot (chargement CSV requis)"
  }
  $subjByNum = @{}
  foreach ($s in @($subjects)) { $subjByNum[[int]$s.numero] = $s }

  # --- ASR reunion horodate (idx = numero de ligne 1..N, text integral) ---
  $asrRows = New-Object System.Collections.ArrayList
  $rowNo = 0
  foreach ($r in @(Read-CrCsvRows -Path $asrCsv)) {
    $h = Convert-RowToHashtable $r
    $rowNo++
    $startRaw = Get-CrField $h 'start'
    $endRaw   = Get-CrField $h 'end'
    if (-not $startRaw) { continue }
    try { $st = [double]$startRaw } catch { continue }
    try { $en = if ($endRaw) { [double]$endRaw } else { $st } } catch { $en = $st }
    $speaker = Get-CrField $h 'speaker'
    $text    = (Get-CrField $h 'text')
    $asrRows.Add(@{ idx=$rowNo; start=$st; end=$en; speaker=$speaker; text=$text }) | Out-Null
  }
  $asrArray = @($asrRows)

  # --- Photos : jointure photos.csv (valide) + photos_batch.csv (batch) ---
  $photoValidated = @()
  if (Test-Path -LiteralPath $Paths.PhotosCsvPath -PathType Leaf) {
    foreach ($r in @(Read-CrCsvRows -Path $Paths.PhotosCsvPath)) { $photoValidated += (Convert-RowToHashtable $r) }
  }
  $batchByRel = @{}
  if (Test-Path -LiteralPath $Paths.PhotosBatchCsvPath -PathType Leaf) {
    foreach ($r in @(Read-CrCsvRows -Path $Paths.PhotosBatchCsvPath)) {
      $bh = Convert-RowToHashtable $r
      $rel = Get-CrField $bh 'photo_rel_native'
      if ($rel) { $batchByRel[$rel] = $bh }
    }
  }
  $photos = New-Object System.Collections.ArrayList
  foreach ($pr in $photoValidated) {
    $rel = Get-CrField $pr 'photo_rel_native'
    if (-not $rel) { $rel = Get-CrField $pr 'nom_fichier_image' }
    if (-not $rel) { continue }
    $br = @{}
    if ($batchByRel.ContainsKey($rel)) { $br = $batchByRel[$rel] }
    $tRaw = Get-CrField $pr 't_audio'
    $tAudio = $null
    if ($tRaw) { try { $tAudio = [double]$tRaw } catch { $tAudio = $null } }
    $vlmTxt  = Get-CrField $pr 'description_vlm_ui';   if (-not $vlmTxt)  { $vlmTxt  = Get-CrField $br 'description_vlm_batch' }
    $libTxt  = Get-CrField $pr 'libelle_propose_ui';   if (-not $libTxt)  { $libTxt  = Get-CrField $br 'libelle_propose_batch' }
    $comTxt  = Get-CrField $pr 'commentaire_propose_ui'; if (-not $comTxt) { $comTxt = Get-CrField $br 'commentaire_propose_batch' }
    $dict    = Get-CrField $pr 'dictee_asr_text';      if (-not $dict)    { $dict    = Get-CrField $br 'dictee_asr_text' }
    $vlmOrig = if (Get-CrField $pr 'description_vlm_ui')   { 'validated' } else { 'batch' }
    $libOrig = if (Get-CrField $pr 'libelle_propose_ui')   { 'validated' } else { 'batch' }
    $comOrig = if (Get-CrField $pr 'commentaire_propose_ui') { 'validated' } else { 'batch' }
    $photo = @{
      photo_rel_native = $rel
      photo = if ((Get-CrField $pr 'nom_fichier_image')) { (Get-CrField $pr 'nom_fichier_image') } else { (New-PhotoKey $rel) }
      t_audio = $tAudio
      horodatage_photo = Get-CrField $pr 'horodatage_photo'
      annotation_validee = Get-CrField $pr 'annotation_validee'
      retenue = Get-CrField $pr 'retenue'
      vlm = @{ available = [bool]$vlmTxt; text=$vlmTxt; origin=$vlmOrig; source_file = if ($vlmOrig -eq 'validated') { 'photos.csv' } else { 'photos_batch.csv' }; column = if ($vlmOrig -eq 'validated') { 'description_vlm_ui' } else { 'description_vlm_batch' } }
      libelle = @{ available = [bool]$libTxt; text=$libTxt; origin=$libOrig; source_file = if ($libOrig -eq 'validated') { 'photos.csv' } else { 'photos_batch.csv' }; column = if ($libOrig -eq 'validated') { 'libelle_propose_ui' } else { 'libelle_propose_batch' } }
      commentaire = @{ available = [bool]$comTxt; text=$comTxt; origin=$comOrig; source_file = if ($comOrig -eq 'validated') { 'photos.csv' } else { 'photos_batch.csv' }; column = if ($comOrig -eq 'validated') { 'commentaire_propose_ui' } else { 'commentaire_propose_batch' } }
      dictee_asr = @{ available = [bool]$dict; text=$dict }
      batch_status = Get-CrField $br 'batch_status'
    }
    $photos.Add($photo) | Out-Null
  }
  $photosArray = @($photos)

  # --- Affectations humaines photo -> sujet (AUTORITATIVES) ---
  $assignments = @{}
  if (Test-Path -LiteralPath $Paths.AssignmentsJsonPath -PathType Leaf) {
    $assignDoc = Read-JsonFile -Path $Paths.AssignmentsJsonPath
    Add-ReferePreventifInput $Paths.AssignmentsJsonPath
    $assignList = @()
    if ($assignDoc -is [System.Collections.IDictionary] -and $assignDoc.ContainsKey('assignments')) {
      $assignList = @($assignDoc['assignments'])
    } elseif (($assignDoc -is [System.Collections.IEnumerable]) -and -not ($assignDoc -is [string])) {
      $assignList = @($assignDoc)
    }
    foreach ($a in $assignList) {
      $relA = Get-CrPropString -Obj $a -Name 'photo_rel_native'
      if (-not $relA) { continue }
      $assignments[$relA] = @{
        status          = Get-CrPropString -Obj $a -Name 'status'
        subject_numero  = Get-CrPropInt -Obj $a -Name 'subject_numero'
        subject_title   = Get-CrPropString -Obj $a -Name 'subject_title'
        subject_location= Get-CrPropString -Obj $a -Name 'subject_location'
      }
    }
  }

  # --- Decouverte JSON CR generaliste (LECTURE SEULE : liste + sha256) ---
  $crJson = New-Object System.Collections.ArrayList
  $crPatterns = @('global.json','global_final.json','global_by_sujet.json','global_meeting.json','pseudo_context.json')
  foreach ($name in $crPatterns) {
    $p = Join-Path $Paths.CompteRenduDir $name
    if (Test-Path -LiteralPath $p -PathType Leaf) {
      $crJson.Add(@{ name=$name; path=$p; role='JSON CR generaliste (lecture seule)'; status='present'; sha256=(Get-FileSha256 $p); size_bytes=(Get-Item -LiteralPath $p).Length }) | Out-Null
      Add-ReferePreventifInput $p
    }
  }
  $pctx = Join-Path $Paths.TranscriptionDir 'contexte_general_compte_rendu.json'
  if (Test-Path -LiteralPath $pctx -PathType Leaf) {
    $crJson.Add(@{ name='contexte_general_compte_rendu.json'; path=$pctx; role='contexte canonique CR (lecture seule)'; status='present'; sha256=(Get-FileSha256 $pctx); size_bytes=(Get-Item -LiteralPath $pctx).Length }) | Out-Null
    Add-ReferePreventifInput $pctx
  }

  return @{
    paths = $Paths
    infos_projet = $infos
    config_llm = $config
    asr_window = @{ before_sec=$beforeSec; after_sec=$afterSec; source=$winSource; source_file=$Paths.ConfigLlmPath }
    asr_csv = $asrCsv
    asr_rows = $asrArray
    sujets = @($subjects)
    sujets_by_numero = $subjByNum
    photos = $photosArray
    assignments = $assignments
    cr_json_generaliste = @($crJson)
  }
}
# ============================================================================
# Section 4 - Unites documentaires Pass2F par sujet et chunking adaptatif
# ============================================================================
# [REUSE pass2f6c1_data.py / pass2f6c1_common.py / pass2f_chunk_builder.py]
# Schemas d'unites et de chunks alignes sur le lot 2F-6C1 (deja valide sur J48).

function Get-AsrRowText {
  param($Row)
  $hms = Convert-SecondsToHms ([int][math]::Round([double]$Row.start))
  return ('[ROW {0}] [{1}] {2}: {3}' -f [int]$Row.idx, $hms, $Row.speaker, $Row.text)
}

function New-SubjectUnitStream {
  <#
    Chronologie documentaire deterministe par sujet (schema 2F-6C1) :
      - chaque photo affectee humainement au sujet devient une unite "photo" ;
      - lignes ASR de la fenetre commentaire [t-before, t+after] dedoublonnees
        par numero de ligne au niveau du sujet (premiere photo chronologique) ;
      - unites "asr_continuite" entre deux photos proches du meme sujet si un
        intervalle ASR median existe ;
      - photo hors couverture ASR : unite conservee avec asr.available=false.
  #>
  param(
    [hashtable] $Subject,
    [object[]]  $Photos,
    [object[]]  $AsrRows,
    [double]    $Before,
    [double]    $After,
    [double]    $CohortGapSec
  )
  $numero = [int]$Subject.numero
  $asrEnd = 0.0
  if (@($AsrRows).Count -gt 0) { $lastRow = @($AsrRows)[@($AsrRows).Count - 1]; $asrEnd = [double]$lastRow.end }
  $ordered = @($Photos | Where-Object { $null -ne $_.t_audio } | Sort-Object { [double]$_.t_audio })
  $units = New-Object System.Collections.ArrayList
  $usedRows = @{}
  $rowsUsedList = New-Object System.Collections.ArrayList
  $prev = $null
  foreach ($ph in $ordered) {
    $t = [double]$ph.t_audio
    $ws = $t - $Before
    $we = $t + $After
    if ($null -ne $prev) {
      $prevT = [double]$prev.t_audio
      $gapOk = (($t - $prevT) -le $CohortGapSec) -and (($prevT + $After) -lt $ws)
      if ($gapOk) {
        $gapRows = @($AsrRows | Where-Object { ([double]$_.start) -ge ($prevT + $After) -and ([double]$_.start) -lt $ws -and (-not $usedRows.ContainsKey([int]$_.idx)) })
        if ($gapRows.Count -gt 0) {
          $gapText = ($gapRows | ForEach-Object { Get-AsrRowText $_ }) -join "`n"
          $units.Add(@{
            kind='asr_continuite'; subject_numero=$numero
            window_sec=@([math]::Round($prevT + $After,3),[math]::Round($ws,3))
            asr=@{ available=$true; rows=@($gapRows | ForEach-Object { [int]$_.idx }); chars=$gapText.Length; text=$gapText }
          }) | Out-Null
          foreach ($r in $gapRows) { $usedRows[[int]$r.idx] = $true; $rowsUsedList.Add([int]$r.idx) | Out-Null }
        }
      }
    }
    $winRows = @($AsrRows | Where-Object { ([double]$_.start) -ge $ws -and ([double]$_.start) -lt $we -and (-not $usedRows.ContainsKey([int]$_.idx)) })
    $winText = ($winRows | ForEach-Object { Get-AsrRowText $_ }) -join "`n"
    $asrAvailable = ($winRows.Count -gt 0) -and ($t -le ($asrEnd + 1.0))
    $units.Add(@{
      kind='photo'
      photo=[string]$ph.photo
      photo_rel_native=[string]$ph.photo_rel_native
      subject_numero=$numero
      timestamp_sec=$t
      timestamp_hms=(Convert-SecondsToHms ([int][math]::Round($t)))
      window_sec=@([math]::Round($ws,3),[math]::Round($we,3))
      vlm=$ph.vlm
      libelle=$ph.libelle
      commentaire=$ph.commentaire
      dictee_asr=$ph.dictee_asr
      asr=@{ available=$asrAvailable; rows=@($winRows | ForEach-Object { [int]$_.idx }); chars=$winText.Length; text=$winText }
    }) | Out-Null
    foreach ($r in $winRows) { $usedRows[[int]$r.idx] = $true; $rowsUsedList.Add([int]$r.idx) | Out-Null }
    $prev = $ph
  }
  return @{
    numero=$numero
    titre=[string]$Subject.titre
    localisation=[string]$Subject.localisation
    description=[string]$Subject.description
    photo_count=$ordered.Count
    units=@($units)
    rows_used=@($rowsUsedList)
  }
}

function Get-ChunkBudgetAvailable {
  param($Budget)
  $n = [int]$Budget.n_ctx
  $m = [int]$Budget.max_tok_out
  $g = [int]$Budget.margin
  $avail = [int](($n - $m - $g) * 0.9)
  if ($avail -lt 512) { $avail = 512 }
  return $avail
}

function Get-Pass2FPromptDelims {
  $prefix = $script:Pass2FSectionsCommon + "`n`n[DONNEES DU CAS]`n===== DEBUT DONNEES DU CAS =====`n"
  $suffix = "`n===== FIN DONNEES DU CAS =====" + "`n`n" + $script:Pass2FFinal
  return @{ prefix=$prefix; suffix=$suffix }
}

function Get-UnitWeightChars {
  param($Unit)
  try { $j = $Unit | ConvertTo-Json -Depth 40 -Compress; return $j.Length } catch { return 0 }
}

function Get-Pass2FOutputEstTokens {
  # LOT 2F-6C2C5 : estimation deterministe du volume de SORTIE Pass2F d'un
  # chunk (en tokens). Le JSON de sortie croit avec le nb de photos
  # (photo_contexts) : cause de la troncature reelle du chunk sujet 20:8.
  param([int] $PhotoCount)
  if ([int]$PhotoCount -lt 0) { $PhotoCount = 0 }
  $chars = [int]$script:Pass2FOutputFixedChars + ([int]$script:Pass2FOutputPerPhotoChars * [int]$PhotoCount)
  if ($chars -le 0) { return 0 }
  return [int][math]::Ceiling($chars / $script:Pass2FOutputCharsPerToken)
}

function New-ChunkPlanForSubject {
  <#
    Remplissage des chunks par unite ENTIERE sous DOUBLE budget (LOT 2F-6C2C5) :
      1) budget ENTREE : (n_ctx - max_tokens - marge) * ratio - cout fixe prompt
         (Get-ChunkBudgetAvailable), comportement 2F-6C2B conserve ;
      2) budget SORTIE : estimation deterministe du JSON de sortie Pass2F
         (Get-Pass2FOutputEstTokens, croit avec le nb de photos via
         photo_contexts) plafonnee a max_tokens : cause de la troncature
         reelle du chunk sujet 20:8 (8 photos, raw coupe malgre
         finish_reason=stop synthetique de l'adapter).
    Une unite n'est ajoutee que si elle respecte les DEUX budgets ; sinon le
    chunk courant est ferme avec split_reason = input_budget | output_budget.
    Enforce-ContextLimit reste le filet de securite FINAL apres construction
    reelle du prompt (enforce_required toujours signale dans plan/manifest).
  #>
  param(
    [hashtable] $Stream,
    [hashtable] $Budget,
    [string]    $IdAffaire,
    [string]    $IdCaptation,
    [object[]]  $AsrRows,
    [double]    $AsrEnd
  )
  $available = Get-ChunkBudgetAvailable -Budget $Budget
  $outAvail  = [int]$Budget.max_tok_out
  if ($outAvail -lt 1) { $outAvail = 1 }
  $delims    = Get-Pass2FPromptDelims
  $prefix    = $delims.prefix
  $suffix    = $delims.suffix
  $hardChars = [int]($available * $script:CharPerToken)
  $targetDataChars = [int](($hardChars - $prefix.Length - $suffix.Length - 200) * $script:SlackFill)
  if ($targetDataChars -lt 800) { $targetDataChars = 800 }

  $units = @($Stream.units)
  $weights = @()
  foreach ($u in $units) { $weights += (Get-UnitWeightChars -Unit $u) }

  $chunks = New-Object System.Collections.ArrayList
  $oversized = New-Object System.Collections.ArrayList
  $curIdx = New-Object System.Collections.ArrayList
  $curW = 0
  $curPhotos = 0
  for ($i=0; $i -lt $units.Count; $i++) {
    $w = [int]$weights[$i]
    $isPhoto = ([string]$units[$i].kind -eq 'photo')
    if ($w -gt $targetDataChars) {
      # Unite OVERSIZED : ne peut pas tenir dans le budget ENTREE du chunk
      # courant. On ferme le chunk en cours (raison input_budget) puis on
      # place l'unite seule (chunk force, split_reason=forced_unit).
      if ($curIdx.Count -gt 0) {
        $chunks.Add(@{ indices=@($curIdx); weight=$curW; photos=$curPhotos; split_reason='input_budget' }) | Out-Null
        $curIdx = New-Object System.Collections.ArrayList
        $curW = 0
        $curPhotos = 0
      }
      $soloPhotos = 0
      if ($isPhoto) { $soloPhotos = 1 }
      $chunks.Add(@{ indices=@($i); weight=$w; photos=$soloPhotos; split_reason='forced_unit' }) | Out-Null
      $oversized.Add(@{ unit_index=$i; photo=[string]$units[$i].photo; chars=$w; target_data_chars=$targetDataChars; budget_violated='input_budget' }) | Out-Null
      continue
    }
    $candPhotos = $curPhotos
    if ($isPhoto) { $candPhotos = $candPhotos + 1 }
    if ($curIdx.Count -gt 0) {
      $inEx  = (($curW + $w) -gt $targetDataChars)
      $outEx = ((Get-Pass2FOutputEstTokens -PhotoCount $candPhotos) -gt $outAvail)
      if ($inEx -or $outEx) {
        $reason = 'input_budget'
        if (-not $inEx) { $reason = 'output_budget' }
        $chunks.Add(@{ indices=@($curIdx); weight=$curW; photos=$curPhotos; split_reason=$reason }) | Out-Null
        $curIdx = New-Object System.Collections.ArrayList
        $curW = 0
        $curPhotos = 0
      }
    }
    $curIdx.Add($i) | Out-Null
    $curW += $w
    if ($isPhoto) { $curPhotos = $curPhotos + 1 }
  }
  if ($curIdx.Count -gt 0) {
    $chunks.Add(@{ indices=@($curIdx); weight=$curW; photos=$curPhotos; split_reason='subject_end' }) | Out-Null
  }

  $chunkObjs = New-Object System.Collections.ArrayList
  $totalChunks = $chunks.Count
  for ($ci=0; $ci -lt $totalChunks; $ci++) {
    $ch = $chunks[$ci]
    $idxArr = @($ch.indices)
    $chunkUnits = @()
    $dataW = 0
    foreach ($ix in $idxArr) { $chunkUnits += $units[$ix]; $dataW += [int]$weights[$ix] }
    $photoCount = 0
    foreach ($cu in $chunkUnits) { if ([string]$cu.kind -eq 'photo') { $photoCount++ } }
    $outEst = Get-Pass2FOutputEstTokens -PhotoCount $photoCount
    $data = @{
      schema='cr_refere_preventif.pass2f.chunk.v1'
      source_pass='2F'
      id_affaire=$IdAffaire
      id_captation=$IdCaptation
      sujet_cible=@{ numero=$Stream.numero; titre=$Stream.titre; localisation=$Stream.localisation; description=$Stream.description }
      chunk_index=($ci+1)
      chunk_total=$totalChunks
      sequence_documentaire=$chunkUnits
    }
    $dataJson = $data | ConvertTo-Json -Depth 60 -Compress
    $message  = $prefix + $dataJson + $suffix
    $tokEst   = Estimate-Tokens -text $message
    $enforceReq = ($tokEst -gt $available)
    $enforcedChars = 0
    $enforcedToks  = 0
    if ($enforceReq) {
      $script:CriticalQaWarnings.Add(("chunk sujet {0} chunk {1}/{2} : prompt {3} tokens > budget dispo {4} (Enforce requis au run reel)" -f $Stream.numero, ($ci+1), $totalChunks, $tokEst, $available)) | Out-Null
      # Filet de securite FINAL (Enforce-ContextLimit historique). En DryRun il
      # ne doit jamais se declencher ; le message integral reste conserve dans
      # le fichier d''input, la variante tronquee n''est pas ecrite.
      try {
        $enforcedMsg = Enforce-ContextLimit -SystemPrompt '' -UserPrompt $message -Label ('pass2f.sujet' + [string]$Stream.numero + '.chunk' + [string]($ci+1)) -LogFile $script:LogFile -ModelName $ModelPass2F
        if ($null -ne $enforcedMsg) { $enforcedChars = $enforcedMsg.Length; $enforcedToks = Estimate-Tokens -text $enforcedMsg }
      } catch {
        $script:CriticalQaWarnings.Add(('Enforce-ContextLimit ECHEC sur sujet ' + [string]$Stream.numero + ' chunk ' + [string]($ci+1) + ' : ' + $_.Exception.Message)) | Out-Null
      }
    }
    $chunkObjs.Add(@{
      chunk_index=($ci+1)
      chunk_total=$totalChunks
      unit_indices=$idxArr
      units_count=$chunkUnits.Count
      photos_count=$photoCount
      data_chars_est=$dataW
      prompt_chars=$message.Length
      prompt_tokens_est=$tokEst
      input_tokens_est=$tokEst
      available_tokens=$available
      available_input_tokens=$available
      output_tokens_est=$outEst
      available_output_tokens=$outAvail
      output_budget_ok=($outEst -le $outAvail)
      split_reason=[string]$ch.split_reason
      enforce_required=$enforceReq
      enforced_chars=$enforcedChars
      enforced_tokens_est=$enforcedToks
      data=$data
      message=$message
    }) | Out-Null
  }
  return @{
    numero=$Stream.numero
    titre=$Stream.titre
    localisation=$Stream.localisation
    description=$Stream.description
    budget=$Budget
    available_tokens=$available
    available_output_tokens=$outAvail
    hard_chars=$hardChars
    target_data_chars=$targetDataChars
    unit_count_source=$units.Count
    chunk_count=$totalChunks
    chunks=@($chunkObjs)
    oversized_units=@($oversized)
  }
}
# ============================================================================
# Section 5 - Ecriture des artefacts, manifest et journalisation
# ============================================================================
# ============================================================================
# [LOT 2B2F-1] Section ajoutee : Pass2B_2F (fonctions dediees, DryRun sans LLM)
# ============================================================================
# ============================================================================
# Section 4B - Pass2B_2F (LOT 2B2F-1) : condensation globale enrichie
# ----------------------------------------------------------------------------
# But : produire refere_global_meeting.json (futur) a partir de matiere de
# rang 1 UNIQUEMENT :
#   * segments de rang 1 du run CR generaliste (segments/segment_*.json) ;
#   * donnees photographiques amont (photos.csv / photos_batch.csv /
#     photo_subject_assignments.json + ASR horodate), jamais les sorties
#     Pass2B/Pass2E/Pass2F (aucune consommation rang2 -> rang2).
# Dans LOT 2B2F-1 : DryRun seul, aucun appel LLM/HTTP. Les fonctions ci-dessous
# preparent les unites general_segment et photo_context, les batches, les
# controles 399/164/6 et la trace manifest. La mecanique historique Pass2B
# est reprise par provenance [REUSE cr_reunion_point_mumerotes_pipeline_json.ps1].
# ============================================================================

function ConvertTo-Pass2B2FCompactSegment {
  <#
    [REUSE cr_reunion_point_mumerotes_pipeline_json.ps1:4830-4893]
    ConvertTo-Pass2BCompactSegment adapte aux objets profond (hashtables) du
    pipeline refere. Reproduction fidèle des regles historiques :
      sujets (map numero -> interventions) prioritaire ; sinon texte_source
      tronque a 1200 caracteres ; points_cles max 20 ; demandes_actions [].
    Retour hashtable avec champs supplementaires de provenance/chronologie.
  #>
  param($Segment)
  if ($null -eq $Segment) { return $null }
  $segmentId = Get-CrPropString -Obj $Segment -Name 'segment_id'
  $startHms  = Get-CrPropString -Obj $Segment -Name 'start_hms'
  $endHms    = Get-CrPropString -Obj $Segment -Name 'end_hms'
  $startSec  = 0.0
  $endSec    = 0.0
  $sv = Get-CrProp -Obj $Segment -Name 'start_sec'
  if ($null -ne $sv) { try { $startSec = [double]$sv } catch { $startSec = 0.0 } }
  $ev = Get-CrProp -Obj $Segment -Name 'end_sec'
  if ($null -ne $ev) { try { $endSec = [double]$ev } catch { $endSec = 0.0 } }
  $sujetsObj = Get-CrProp -Obj $Segment -Name 'sujets'
  if ($null -eq $sujetsObj) {
    $la = Get-CrProp -Obj $Segment -Name 'llm_analysis'
    if ($null -ne $la) { $sujetsObj = Get-CrProp -Obj $la -Name 'sujets' }
  }
  $sujetNums = New-Object System.Collections.Generic.List[string]
  $points    = New-Object System.Collections.Generic.List[object]
  if ($null -ne $sujetsObj) {
    $pairs = @()
    if ($sujetsObj -is [System.Collections.IDictionary]) {
      foreach ($e in $sujetsObj.GetEnumerator()) {
        $pairs += @{ Numero = [string]$e.Key; Items = $e.Value }
      }
    } else {
      foreach ($pr in $sujetsObj.PSObject.Properties) {
        $pairs += @{ Numero = [string]$pr.Name; Items = $pr.Value }
      }
    }
    foreach ($pair in @($pairs)) {
      if (-not [string]::IsNullOrWhiteSpace([string]$pair.Numero)) {
        $sujetNums.Add([string]$pair.Numero) | Out-Null
      }
      $items = @()
      if ($null -ne $pair.Items -and ($pair.Items -is [System.Collections.IEnumerable]) -and -not ($pair.Items -is [string])) {
        $items = @($pair.Items)
      } elseif ($null -ne $pair.Items) {
        $items = @($pair.Items)
      }
      foreach ($it in @($items)) {
        if ($null -eq $it) { continue }
        $txt = Get-CrPropString -Obj $it -Name 'texte'
        if (-not $txt) { $txt = [string]$it }
        if ([string]::IsNullOrWhiteSpace($txt)) { continue }
        $points.Add(@{
          sujet    = [string]$pair.Numero
          timecode = Get-CrPropString -Obj $it -Name 'timecode'
          auteur   = Get-CrPropString -Obj $it -Name 'auteur'
          texte    = $txt
        }) | Out-Null
      }
    }
  }
  $texteUtile = ''
  if ($points.Count -gt 0) {
    $texteUtile = (($points | Select-Object -First 12 | ForEach-Object { [string]$_['texte'] }) -join "`n")
  } else {
    $resumeSeg = Get-CrPropString -Obj $Segment -Name 'resume_segment'
    if ($resumeSeg) {
      $texteUtile = $resumeSeg
    } else {
      $src = Get-CrPropString -Obj $Segment -Name 'texte_source'
      if ($src.Length -gt 1200) {
        $texteUtile = $src.Substring(0, 1200) + "`n[...]"
      } else {
        $texteUtile = $src
      }
    }
  }
  return @{
    source_type         = 'general_segment'
    kind                = 'general_segment'
    segment_id          = $segmentId
    chrono_sec          = $startSec
    chrono_hms          = $startHms
    start_sec           = $startSec
    end_sec             = $endSec
    start_hms           = $startHms
    end_hms             = $endHms
    texte_source_utile  = $texteUtile
    sujets_detectes     = @($sujetNums.ToArray() | Sort-Object -Unique)
    points_cles         = @($points.ToArray() | Select-Object -First 20)
    demandes_actions    = @()
    provenance          = @{ source = 'generalist_run_segments'; source_kind = 'segment_rank1' }
  }
}

function Get-PhotoAssignmentRef {
  <#
    Retourne l'affectation d'une photo (hashtable) en utilisant la cle exacte
    photo_rel_native puis la cle normalisee New-PhotoKey. Autoritaire : aucune
    re-affectation n'est jamais faite par ce code.
  #>
  param(
    [hashtable] $Assignments,
    [hashtable] $AssignByBase,
    [string]    $RelNative
  )
  if ($Assignments.ContainsKey($RelNative)) { return $Assignments[$RelNative] }
  $bk = New-PhotoKey $RelNative
  if ($AssignByBase.ContainsKey($bk)) { return $AssignByBase[$bk] }
  return $null
}

function New-Pass2B2FPhotoContextUnit {
  <#
    Construit une vignette photographique contextualisee de rang 1
    (source_type=photo_context) a partir des sources amont de Pass2F,
    JAMAIS a partir des sorties Pass2F. Champ libelle_effectif /
    commentaire_effectif : valeur validee photos.csv sinon photos_batch.csv,
    jamais concatenees. Rows ASR : fenetre [t-before, t+after], dedoublonnees
    par sujet (premiere photo chronologique du sujet), conforme Pass2F.
  #>
  param(
    [hashtable] $Photo,
    [hashtable] $Assignment,
    [object]    $SubjectMeta,
    [object[]]  $AsrRows,
    [double]    $BeforeSec,
    [double]    $AfterSec,
    [object[]]  $UsedRowNumbers,
    [bool]      $CoveredBySegment,
    [string]    $CoveringSegmentId
  )
  $rel  = [string]$Photo.photo_rel_native
  $t    = 0.0
  $hasT = $false
  if ($null -ne $Photo.t_audio) {
    try { $t = [double]$Photo.t_audio; $hasT = $true } catch { $hasT = $false }
  }
  $subjNum = 0
  try { $subjNum = [int]$Assignment.subject_numero } catch { $subjNum = 0 }
  $title = ''
  $loc   = ''
  $desc  = ''
  if ($null -ne $SubjectMeta) {
    $title = [string]$SubjectMeta.titre
    $loc   = [string]$SubjectMeta.localisation
    $desc  = [string]$SubjectMeta.description
  }
  if (-not $title) {
    $title = Get-CrPropString -Obj $Assignment -Name 'subject_title'
    if (-not $loc) { $loc = Get-CrPropString -Obj $Assignment -Name 'subject_location' }
  }
  $used = @{}
  foreach ($rn in @($UsedRowNumbers)) { $used[[int]$rn] = $true }
  $winRows = New-Object System.Collections.ArrayList
  if ($hasT) {
    $ws = $t - $BeforeSec
    $we = $t + $AfterSec
    foreach ($ar in @($AsrRows)) {
      $ridx = [int]$ar.idx
      if ($used.ContainsKey($ridx)) { continue }
      $astart = 0.0
      try { $astart = [double]$ar.start } catch { $astart = 0.0 }
      if ($astart -ge $ws -and $astart -lt $we) { [void]$winRows.Add($ar) }
    }
  }
  $rowIds = @($winRows | ForEach-Object { [int]$_.idx } | Sort-Object)
  $asrTxt = ($winRows | ForEach-Object { Get-AsrRowText $_ }) -join "`n"
  # champs effectifs VLM / libelle / commentaire / dictee (jamais concatene)
  $vlmText  = ''
  $vlmOrig  = 'none'
  $libText  = ''
  $libOrig  = 'none'
  $comText  = ''
  $comOrig  = 'none'
  $dictText = ''
  if ($null -ne $Photo.vlm -and [bool]$Photo.vlm.available) {
    $vlmText = [string]$Photo.vlm.text
    $vlmOrig = [string]$Photo.vlm.origin
    if (-not $vlmOrig) { $vlmOrig = 'validated' }
  }
  if ($null -ne $Photo.libelle -and [bool]$Photo.libelle.available) {
    $libText = [string]$Photo.libelle.text
    $libOrig = [string]$Photo.libelle.origin
    if (-not $libOrig) { $libOrig = 'validated' }
  }
  if ($null -ne $Photo.commentaire -and [bool]$Photo.commentaire.available) {
    $comText = [string]$Photo.commentaire.text
    $comOrig = [string]$Photo.commentaire.origin
    if (-not $comOrig) { $comOrig = 'validated' }
  }
  if ($null -ne $Photo.dictee_asr -and [bool]$Photo.dictee_asr.available) {
    $dictText = [string]$Photo.dictee_asr.text
  }
  $provFiles = @()
  if ($vlmOrig -eq 'validated') { $provFiles = @($provFiles) + 'photos.csv' }
  if ($libOrig -eq 'validated') { $provFiles = @($provFiles) + 'photos.csv' }
  if ($comOrig -eq 'validated') { $provFiles = @($provFiles) + 'photos.csv' }
  if (@($provFiles).Count -eq 0) { $provFiles = @('photos_batch.csv') }
  $provFiles = @($provFiles | Select-Object -Unique)
  $unit = @{
    source_type          = 'photo_context'
    kind                 = 'photo_context'
    subject_numero       = $subjNum
    subject_title        = $title
    subject_location     = $loc
    subject_description  = $desc
    photo_id             = $rel
    photo_display        = [string]$Photo.photo
    chrono_sec           = $(if ($hasT) { $t } else { -1.0 })
    chrono_hms           = $(if ($hasT) { Convert-SecondsToHms ([int][math]::Round($t)) } else { '' })
    timestamp_hms        = $(if ($hasT) { Convert-SecondsToHms ([int][math]::Round($t)) } else { '' })
    has_t_audio          = $hasT
    window_sec           = $(if ($hasT) { @([math]::Round($t - $BeforeSec, 3), [math]::Round($t + $AfterSec, 3)) } else { @(0, 0) })
    vlm_description      = $vlmText
    vlm_origin           = $vlmOrig
    libelle_effectif     = $libText
    libelle_source       = $(if ($libText) { $libOrig } else { 'none' })
    commentaire_effectif = $comText
    commentaire_source   = $(if ($comText) { $comOrig } else { 'none' })
    dictee_photo         = $dictText
    asr_context          = @{
      available = [bool](@($rowIds).Count -gt 0)
      rows      = @($rowIds)
      chars     = $asrTxt.Length
      text      = $asrTxt
    }
    hors_segments        = [bool](-not $CoveredBySegment)
    segment_coverage     = $(if ($CoveredBySegment) { @{ covered = $true; segment_id = $CoveringSegmentId } } else { @{ covered = $false; segment_id = '' } })
    provenance           = @{
      source_files    = @($provFiles)
      assignment      = 'photo_subject_assignments.json'
      assignment_status = 'affectee'
      subject_numero_source = 'human_assignment'
    }
  }
  return @{ unit = $unit; rows_used = @($rowIds) }
}

function Build-Pass2B2FRank1Material {
  <#
    Assemble la matiere de rang 1 Pass2B_2F :
      1) lit les segments generalistes du run (segments/segment_*.json) ;
      2) convertit chaque segment en unite general_segment (compact historique) ;
      3) construit une unite photo_context par photo affectee (hors exclues),
         avec dedoublonnage ASR par sujet (ordre chronologique au sein du sujet) ;
      4) calcule la couverture segmentaire (hors_segments) ;
      5) trie chronologique global segment/photo (fusion deterministe).
    Controles calcules : photo_units_count, general_segments_count,
    photos_hors_segments, excluded_skipped, subjects_with_photos.
  #>
  param(
    [hashtable] $Ctx,
    [string]    $SegmentsDir
  )
  if (-not $SegmentsDir -or -not (Test-Path -LiteralPath $SegmentsDir -PathType Container)) {
    throw "[Build-Pass2B2FRank1Material] segments_dir introuvable: $SegmentsDir"
  }
  $files = @(Get-ChildItem -LiteralPath $SegmentsDir -Filter 'segment_*.json' -File | Sort-Object { $_.Name })
  if ($files.Count -eq 0) {
    throw "[Build-Pass2B2FRank1Material] aucun segment_*.json dans $SegmentsDir"
  }
  $segUnits = @()
  $segmentsForCoverage = New-Object System.Collections.ArrayList
  foreach ($f in $files) {
    Add-ReferePreventifInput $f.FullName
    $segObj = Read-JsonFile -Path $f.FullName
    $cu = ConvertTo-Pass2B2FCompactSegment -Segment $segObj
    if ($null -eq $cu) { continue }
    $cu.provenance = @{ source = 'generalist_run_segments'; source_kind = 'segment_rank1'; segment_file = $f.FullName }
    $segUnits = @($segUnits) + $cu
    [void]$segmentsForCoverage.Add($cu)
  }
  $segUnits = @($segUnits | Sort-Object { [double]$_.chrono_sec })
  # index affectations
  $assignByBase = @{}
  foreach ($k in @($Ctx.assignments.Keys)) {
    $assignByBase[(New-PhotoKey $k)] = $Ctx.assignments[$k]
  }
  # groupement photos par sujet pour dedoublonnage ASR chronologique
  $bySubject = @{}
  foreach ($ph in @($Ctx.photos)) {
    $asg = Get-PhotoAssignmentRef -Assignments $Ctx.assignments -AssignByBase $assignByBase -RelNative ([string]$ph.photo_rel_native)
    if ($null -eq $asg) { continue }
    $st = Get-CrPropString -Obj $asg -Name 'status'
    if ($st -ne 'affectee') { continue }
    $sn = 0
    try { $sn = [int]$asg.subject_numero } catch { $sn = 0 }
    if (-not $bySubject.ContainsKey($sn)) { $bySubject[$sn] = New-Object System.Collections.ArrayList }
    [void]$bySubject[$sn].Add(@{ photo = $ph; asg = $asg })
  }
  $photoUnits = @()
  $excludedCount = 0
  $subjectsWithPhotos = @()
  foreach ($sn in @($bySubject.Keys | Sort-Object)) {
    $subjectsWithPhotos += [int]$sn
    $subjectCanon = $null
    if ($Ctx.sujets_by_numero.ContainsKey([int]$sn)) { $subjectCanon = $Ctx.sujets_by_numero[[int]$sn] }
    $list = @($bySubject[$sn] | Sort-Object { $_.photo.t_audio })
    $usedRows = @()
    foreach ($item in $list) {
      $phItem = $item.photo
      $asgItem = $item.asg
      # couverture segmentaire : t_audio dans [start_sec,end_sec] d un segment
      $tCov = -1.0
      $hasTCov = $false
      if ($null -ne $phItem.t_audio) { try { $tCov = [double]$phItem.t_audio; $hasTCov = $true } catch { $hasTCov = $false } }
      $covered = $false
      $coveringId = ''
      if ($hasTCov) {
        foreach ($sc in $segmentsForCoverage) {
          if ($tCov -ge [double]$sc.start_sec -and $tCov -le [double]$sc.end_sec) {
            $covered = $true
            $coveringId = [string]$sc.segment_id
            break
          }
        }
      }
      $res = New-Pass2B2FPhotoContextUnit -Photo $phItem -Assignment $asgItem -SubjectMeta $subjectCanon -AsrRows $Ctx.asr_rows -BeforeSec ([double]$Ctx.asr_window.before_sec) -AfterSec ([double]$Ctx.asr_window.after_sec) -UsedRowNumbers $usedRows -CoveredBySegment $covered -CoveringSegmentId $coveringId
      $photoUnits = @($photoUnits) + $res.unit
      $usedRows = @($usedRows) + @($res.rows_used)
    }
  }
  $photoUnits = @($photoUnits | Sort-Object { [double]$_.chrono_sec }, { $_.subject_numero }, { $_.photo_id })
  # compteurs exclues (ignorées par construction ci-dessus)
  foreach ($ph2 in @($Ctx.photos)) {
    $asg2 = Get-PhotoAssignmentRef -Assignments $Ctx.assignments -AssignByBase $assignByBase -RelNative ([string]$ph2.photo_rel_native)
    if ($null -ne $asg2 -and (Get-CrPropString -Obj $asg2 -Name 'status') -eq 'exclue') { $excludedCount++ }
  }
  # fusion deterministe segments + photos sur la chronologie
  $merged = New-Object System.Collections.ArrayList
  $i = 0
  $j = 0
  while ($i -lt $segUnits.Count -or $j -lt $photoUnits.Count) {
    if ($i -ge $segUnits.Count) {
      [void]$merged.Add($photoUnits[$j]); $j++; continue
    }
    if ($j -ge $photoUnits.Count) {
      [void]$merged.Add($segUnits[$i]); $i++; continue
    }
    $sk = [double]$segUnits[$i].chrono_sec
    $pk = [double]$photoUnits[$j].chrono_sec
    if ($sk -le $pk) {
      [void]$merged.Add($segUnits[$i]); $i++
    } else {
      [void]$merged.Add($photoUnits[$j]); $j++
    }
  }
  # controles de coherence sur les unites photos
  $photoInUnits = @($photoUnits | Where-Object { $_.source_type -eq 'photo_context' })
  $horsSeg = @($photoInUnits | Where-Object { [bool]$_.hors_segments })
  $dupPhotos = @()
  $seenP = @{}
  foreach ($pu in $photoInUnits) {
    if ($seenP.ContainsKey([string]$pu.photo_id)) { $dupPhotos += [string]$pu.photo_id } else { $seenP[[string]$pu.photo_id] = $true }
  }
  # LOT 2B2F-7 : fenetre ASR de la reunion (bornes reelles des lignes) puis
  # classification des unites photo : couvertes par un segment / dans la duree
  # ASR mais hors segment annote (trou) / apres la fin de l ASR / avant debut.
  $asrStartSet = $false
  $asrStartSec = 0.0
  $asrEndSec = 0.0
  foreach ($rowA in @($Ctx.asr_rows)) {
    $stA = Get-CrProp -Obj $rowA -Name 'start'
    $enA = Get-CrProp -Obj $rowA -Name 'end'
    if ($null -ne $stA) { try { $sA = [double]$stA; if (-not $asrStartSet -or $sA -lt $asrStartSec) { $asrStartSec = $sA; $asrStartSet = $true } } catch { } }
    if ($null -ne $enA) { try { $eA = [double]$enA; if ($eA -gt $asrEndSec) { $asrEndSec = $eA } } catch { } }
  }
  $withSegCount = 0
  $gapCount = 0
  $afterCount = 0
  $beforeCount = 0
  foreach ($puC in $photoInUnits) {
    $tcC = -1.0
    if ($null -ne $puC.chrono_sec) { try { $tcC = [double]$puC.chrono_sec } catch { $tcC = -1.0 } }
    if (-not [bool]$puC.hors_segments) { $withSegCount++ }
    elseif ($tcC -lt 0.0) { $beforeCount++ }
    elseif ($tcC -gt $asrEndSec) { $afterCount++ }
    elseif ($tcC -ge $asrStartSec) { $gapCount++ }
    else { $beforeCount++ }
  }
  $material = @{
    general_segments_count = @($segUnits).Count
    photo_units_count      = @($photoInUnits).Count
    photos_hors_segments   = @($horsSeg).Count
    photo_units_with_segment = $withSegCount
    photo_units_in_asr_gap   = $gapCount
    photo_units_after_asr    = $afterCount
    photo_units_before_asr   = $beforeCount
    asr_start_sec            = $asrStartSec
    asr_end_sec              = $asrEndSec
    excluded_skipped       = $excludedCount
    subjects_with_photos   = @($subjectsWithPhotos | Sort-Object)
    subjects_with_photos_count = @($subjectsWithPhotos).Count
    duplicate_photo_ids    = @($dupPhotos | Sort-Object -Unique)
    total_input_units      = (@($segUnits).Count + @($photoInUnits).Count)
    units                  = @($merged)
    segments_units         = @($segUnits)
    photo_units            = @($photoInUnits)
  }
  return $material
}

function New-Pass2B2FTextConstants {
  <#
    Prompts Pass2B_2F (LOT 2B2F-1) : adaptation minimale du prompt Pass2B
    historique [REUSE cr_reunion_point_mumerotes_pipeline_json.ps1:2308-2378]
    pour indiquer que la matiere provient des echanges/transcriptions ET des
    constatations photographiques contextualisees. Schema de sortie strictement
    identique au "global reunion" (compatibilite Pass3A/B/C/D).
  #>
  $sys = @'
Tu reçois une matiere de rang 1 issue de deux familles de sources COMPLEMENTAIRES :

[SOURCE SEGMENTS] extraits chronologiques annotes des echanges (transcriptions horodatees de la reunion).
[SOURCE PHOTO] vignettes photographiques contextualisees : affectation humaine photo -> sujet,
horodatage, description VLM (observation visuelle brute), libelle effectif, commentaire effectif,
dictee photo eventuelle, contexte ASR temporel et reference de provenance.

Regles obligatoires :
- Traite les deux familles comme complementaires, sans priorite absolue de l une sur l autre.
- Une constatation photographique peut documenter un element peu ou pas evoque oralement :
  elle ne doit pas disparaitre sous pretexte qu elle est absente des echanges.
- Distingue ce qui est VISIBLE / DOCUMENTE (description VLM, photo) de ce qui est seulement DECLARE
  (oral). Ne presente jamais un element uniquement oral comme visible sur une photographie.
- Ne transforme pas une hypothese orale en constat etabli ; n invente aucun contenu photographique.
- Evite le double comptage : si une information orale est deja portee par un segment et par le
  contexte ASR d une vignette photo, elle ne compte qu une fois dans la synthese.
- Preserve sujets, problemes, actions, demandes documentaires, constats et elements techniques.
- Ne renvoie jamais la liste d entree.

Objectif : produire un JSON "global reunion" STRICT au schema suivant (sans inventer) :
{
  "resume_global": "string (6-10 phrases)",
  "themes": [ { "titre":"string", "synthese":["string","..."], "timecodes":["HH:MM:SS","..."] } ],
  "themes_abordes": ["string", "..."],
  "actions": [ { "action":"string", "responsable":"string | null", "echeance":"YYYY-MM-DD | null" } ],
  "perspectives": ["string","..."],
  "demandes_documents_globales": [ { "objet":"string", "demandeur":"string | null", "destinataire":"string | null", "echeance":"YYYY-MM-DD | null", "timecodes":["HH:MM:SS","..."] } ],
  "problems": [ { "probleme":"string", "solution":"string | null" } ]
}

Regles :
- Pas d invention : si incertain -> null ou [].
- 5 a 12 themes max (dans "themes").
- timecodes : uniquement ceux presents dans les sources (HH:MM:SS) ; sinon [].
- "themes_abordes" : 5 a 15 libelles.
- "actions" : uniquement actions explicitement decidees (controle, mesure, intervention, visite, devis).
- Les demandes de documents/informations vont dans "demandes_documents_globales", pas dans "actions".
- Deduplique partout.
- Si les donnees sont insuffisantes, renvoie quand meme un JSON conforme avec chaines vides et tableaux vides.
- La reponse doit commencer par { et se terminer par }.
'@
  $usr = @'
Voici la matiere de rang 1 (segments des echanges + vignettes photographiques contextualisees) :

{UNITS_JSON}

Renvoie uniquement le JSON "global reunion" conforme au schema.
'@
  return @{ system = $sys; user_template = $usr }
}

function Get-Pass2B2FUnitKey {
  param($Unit)
  if ([string]$Unit.source_type -eq 'general_segment') { return ('general_segment:' + [string]$Unit.segment_id) }
  return ('photo_context:' + [string]$Unit.photo_id)
}

function New-Pass2B2FBatchPack {
  <#
    Constitution deterministe des batches Pass2B_2F sur des unites ENTIERES.
    Garde-fous historiques [REUSE cr_reunion_point_mumerotes_pipeline_json.ps1:65-67,
    4950-5050] : prompt_chars <= max_batch_chars ET estimated_tokens <=
    max_batch_tokens. Une unite n est jamais coupee : si une unite seule
    depasse la limite elle est placee seule avec le drapeau forced_oversized.
  #>
  param(
    [object[]] $OrderedUnits,
    [string]   $SystemText,
    [string]   $UserTemplate,
    [int]      $MaxBatchChars,
    [int]      $MaxBatchTokens
  )
  $batches   = New-Object System.Collections.ArrayList
  $oversized = New-Object System.Collections.ArrayList
  if (@($OrderedUnits).Count -eq 0) {
    return @{ batches = @(); oversized = @(); batches_count = 0 }
  }
  $prep = @()
  foreach ($u in @($OrderedUnits)) {
    $jsonStr = $u | ConvertTo-Json -Depth 30 -Compress
    $prep += @{ unit = $u; json = [string]$jsonStr; key = Get-Pass2B2FUnitKey -Unit $u }
  }
  $cur = New-Object System.Collections.ArrayList
  $curJsonParts = New-Object System.Collections.ArrayList
  $n = $prep.Count
  for ($idx = 0; $idx -lt $n; $idx++) {
    $cand = $prep[$idx]
    $probeParts = @($curJsonParts.ToArray()) + @($cand.json)
    $probeJson = '[' + ($probeParts -join ',') + ']'
    $probeUser = $UserTemplate.Replace('{UNITS_JSON}', $probeJson)
    $probeChars = ([string]$SystemText).Length + $probeUser.Length
    $probeToks  = Estimate-Tokens -text (([string]$SystemText) + "`n" + $probeUser)
    $overLimit = ($probeChars -gt $MaxBatchChars) -or ($probeToks -gt $MaxBatchTokens)
    if ($cur.Count -gt 0 -and $overLimit) {
      $batches.Add((New-Pass2B2FBatchObject -Prep $prep -Indices @($cur.ToArray()) -BatchIndex ($batches.Count + 1) -SystemText $SystemText -UserTemplate $UserTemplate -SplitReason 'budget_limit')) | Out-Null
      $cur = New-Object System.Collections.ArrayList
      $curJsonParts = New-Object System.Collections.ArrayList
    }
    [void]$cur.Add($idx)
    [void]$curJsonParts.Add($cand.json)
  }
  if ($cur.Count -gt 0) {
    $batches.Add((New-Pass2B2FBatchObject -Prep $prep -Indices @($cur.ToArray()) -BatchIndex ($batches.Count + 1) -SystemText $SystemText -UserTemplate $UserTemplate -SplitReason 'stream_end')) | Out-Null
  }
  foreach ($b in $batches) {
    if ([int]$b.units_count -eq 1 -and ([int]$b.prompt_chars -gt $MaxBatchChars -or [int]$b.tokens_est -gt $MaxBatchTokens)) {
      $oversized += @{ batch_index = [int]$b.batch_index; unit_keys = @($b.unit_keys); prompt_chars = [int]$b.prompt_chars; tokens_est = [int]$b.tokens_est; reason = 'forced_oversized_unit' }
    }
  }
  return @{
    batches       = $batches.ToArray()
    oversized     = @($oversized)
    batches_count = $batches.Count
  }
}

function New-Pass2B2FBatchObject {
  param(
    [object[]] $Prep,
    [int[]]    $Indices,
    [int]      $BatchIndex,
    [string]   $SystemText,
    [string]   $UserTemplate,
    [string]   $SplitReason
  )
  $units   = @()
  $keys    = @()
  foreach ($ix in @($Indices)) { $units += $Prep[$ix].unit; $keys += [string]$Prep[$ix].key }
  $json = '[' + (@($Indices | ForEach-Object { [string]$Prep[$_].json }) -join ',') + ']'
  $userMsg = $UserTemplate.Replace('{UNITS_JSON}', $json)
  $promptChars = ([string]$SystemText).Length + $userMsg.Length
  $promptToks  = Estimate-Tokens -text (([string]$SystemText) + "`n" + $userMsg)
  $genCount = @($units | Where-Object { [string]$_.source_type -eq 'general_segment' }).Count
  $phoCount = @($units | Where-Object { [string]$_.source_type -eq 'photo_context' }).Count
  $startHms = ''
  $endHms   = ''
  $firstC = $null
  $lastC  = $null
  foreach ($un in $units) {
    $c = $null
    if ($null -ne $un.chrono_sec) { $c = [double]$un.chrono_sec }
    if ($null -eq $firstC -or ($null -ne $c -and $c -lt $firstC)) { $firstC = $c; $startHms = [string]$un.chrono_hms }
    if ($null -ne $c -and ($null -eq $lastC -or $c -ge $lastC)) { $lastC = $c; $endHms = [string]$un.chrono_hms }
  }
  return @{
    batch_index            = $BatchIndex
    split_reason           = $SplitReason
    unit_keys              = @($keys)
    units_count            = @($units).Count
    general_segments_count = $genCount
    photo_units_count      = $phoCount
    chars                  = $json.Length
    tokens_est             = $promptToks
    prompt_chars           = $promptChars
    estimated_input_tokens = $promptToks
    start_hms              = $startHms
    end_hms                = $endHms
    units                  = @($units)
    prompt_user            = $userMsg
    prompt_system          = [string]$SystemText
  }
}

function Write-Pass2B2FArtifacts {
  <#
    Ecriture atomique (Write-CrJsonAtomic / Write-CrTextUtf8NoBom) des artefacts
    Pass2B_2F dans <OutDir>\pass2b2f\ : material rang 1, batches (input+prompt),
    manifest dedie. Aucune ecriture dans les entrees (garde anti-ecrasement).
  #>
  param(
    [hashtable] $Material,
    [hashtable] $Pack,
    [string]    $OutDir,
    [string]    $SegmentsDir,
    [hashtable] $Budget,
    [string]    $ModelAlias,
    [hashtable] $Checks,
    [string]    $StartedAt
  )
  $p2dir = Join-Path $OutDir 'pass2b2f'
  Ensure-Dir (Join-Path $p2dir 'pass2b2f_batches')
  $materialFile = Join-Path $p2dir 'pass2b2f_material_rank1.json'
  $materialDoc = @{
    schema_version = 'cr_refere_preventif.pass2b2f.material_rank1.v1'
    lot = '2B2F-1'
    dry_run = $true
    generated_at = $StartedAt
    general_segments_count = [int]$Material.general_segments_count
    photo_units_count = [int]$Material.photo_units_count
    photos_hors_segments = [int]$Material.photos_hors_segments
    photo_units_with_segment = [int]$Material.photo_units_with_segment
    photo_units_in_asr_gap = [int]$Material.photo_units_in_asr_gap
    photo_units_after_asr = [int]$Material.photo_units_after_asr
    photo_units_before_asr = [int]$Material.photo_units_before_asr
    asr_start_sec = [double]$Material.asr_start_sec
    asr_end_sec = [double]$Material.asr_end_sec
    excluded_skipped = [int]$Material.excluded_skipped
    subjects_with_photos_count = [int]$Material.subjects_with_photos_count
    subjects_with_photos = @($Material.subjects_with_photos)
    total_input_units = [int]$Material.total_input_units
    units = @($Material.units)
  }
  Write-CrJsonAtomic -Path $materialFile -Obj $materialDoc
  Add-CrOutputFile $materialFile
  $perBatch = New-Object System.Collections.ArrayList
  foreach ($b in @($Pack.batches)) {
    $n2 = '{0:D2}' -f ([int]$b.batch_index)
    $batchFile = Join-Path $p2dir ('pass2b2f_batches\batch_' + $n2 + '_input.json')
    $bDoc = @{
      schema_version = 'cr_refere_preventif.pass2b2f.batch_input.v1'
      lot = '2B2F-1'
      dry_run = $true
      execute_llm = $false
      batch_index = [int]$b.batch_index
      split_reason = [string]$b.split_reason
      unit_keys = @($b.unit_keys)
      units_count = [int]$b.units_count
      general_segments_count = [int]$b.general_segments_count
      photo_units_count = [int]$b.photo_units_count
      chars = [int]$b.chars
      tokens_est = [int]$b.tokens_est
      prompt_chars = [int]$b.prompt_chars
      estimated_input_tokens = [int]$b.estimated_input_tokens
      start_hms = [string]$b.start_hms
      end_hms = [string]$b.end_hms
      model_alias = $ModelAlias
      prompt = @{ system = [string]$b.prompt_system; user = [string]$b.prompt_user }
      units = @($b.units)
    }
    Write-CrJsonAtomic -Path $batchFile -Obj $bDoc
    Add-CrOutputFile $batchFile
    $promptFile = Join-Path $p2dir ('pass2b2f_batches\batch_' + $n2 + '_prompt.txt')
    Write-CrTextUtf8NoBom -Path $promptFile -Text ([string]$b.prompt_user)
    Add-CrOutputFile $promptFile
    $perBatch.Add(@{
      batch_index = [int]$b.batch_index
      split_reason = [string]$b.split_reason
      unit_keys = @($b.unit_keys)
      units_count = [int]$b.units_count
      general_segments_count = [int]$b.general_segments_count
      photo_units_count = [int]$b.photo_units_count
      chars = [int]$b.chars
      tokens_est = [int]$b.tokens_est
      prompt_chars = [int]$b.prompt_chars
      start_hms = [string]$b.start_hms
      end_hms = [string]$b.end_hms
    }) | Out-Null
  }
  $manifestFile = Join-Path $p2dir 'pass2b2f_manifest.json'
  $manifest = @{
    schema_version = 'cr_refere_preventif.pass2b2f.dryrun.v1'
    lot = '2B2F-1'
    pipeline = $script:PipelineName
    dry_run = $true
    execute_llm = $false
    llm_calls = 0
    http_calls = 0
    alias = $ModelAlias
    status = 'planned_dryrun_only_no_llm'
    segments_dir = $SegmentsDir
    budget_historical = $Budget
    out_dir = $p2dir
    started_at = $StartedAt
    finished_at = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
    general_segments_count = [int]$Material.general_segments_count
    photo_units_count = [int]$Material.photo_units_count
    photos_hors_segments = [int]$Material.photos_hors_segments
    photo_units_with_segment = [int]$Material.photo_units_with_segment
    photo_units_in_asr_gap = [int]$Material.photo_units_in_asr_gap
    photo_units_after_asr = [int]$Material.photo_units_after_asr
    photo_units_before_asr = [int]$Material.photo_units_before_asr
    asr_start_sec = [double]$Material.asr_start_sec
    asr_end_sec = [double]$Material.asr_end_sec
    excluded_skipped = [int]$Material.excluded_skipped
    subjects_with_photos_count = [int]$Material.subjects_with_photos_count
    subjects_with_photos = @($Material.subjects_with_photos)
    total_input_units = [int]$Material.total_input_units
    batches_count = [int]$Pack.batches_count
    per_batch = @($perBatch)
    oversized_units = @($Pack.oversized)
    checks = $Checks
    output_path = $materialFile
    merge_strategy = 'merge deterministe Merge-MeetingBatchObjects (schema global reunion) etendu aux champs specialises ; consolide les sorties des batches Pass2B_2F vers refere_global_meeting.json. Execute futur (hors LOT 2B2F-1).'
  }
  Write-CrJsonAtomic -Path $manifestFile -Obj $manifest
  Add-CrOutputFile $manifestFile
  return $manifestFile
}

function Merge-Pass2B2FTestBatches {
  <#
    LOT 2B2F-3 : merge de TEST A+B+C, replication locale de la
    regle historique Merge-MeetingBatchObjects
    [REUSE generaliste:4736-4759] : resume_global = resume le plus
    long ; listes fusionnees et dedupliquees. NE PRODUIT PAS
    refere_global_meeting.json (test technique uniquement).
  #>
  param([object[]] $BatchObjs)
  $all = @($BatchObjs | Where-Object { $null -ne $_ })
  if (@($all).Count -eq 0) {
    return @{ resume_global=''; themes=@(); themes_abordes=@(); actions=@(); perspectives=@(); demandes_documents_globales=@(); problems=@() }
  }
  $resumes = @()
  foreach ($o in $all) {
    $v = Get-CrProp -Obj $o -Name 'resume_global'
    if ($null -ne $v -and -not [string]::IsNullOrWhiteSpace([string]$v)) { $resumes += [string]$v }
  }
  $resumeBest = ''
  if (@($resumes).Count -gt 0) {
    $resumeBest = [string](@($resumes | Sort-Object Length -Descending | Select-Object -First 1))
  }
  return @{
    resume_global = $resumeBest
    themes = @(Merge-ListUnique -Lists @($all | ForEach-Object { Get-CrProp -Obj $_ -Name 'themes' }))
    themes_abordes = @(Merge-ListUnique -Lists @($all | ForEach-Object { Get-CrProp -Obj $_ -Name 'themes_abordes' }))
    actions = @(Merge-ListUnique -Lists @($all | ForEach-Object { Get-CrProp -Obj $_ -Name 'actions' }))
    perspectives = @(Merge-ListUnique -Lists @($all | ForEach-Object { Get-CrProp -Obj $_ -Name 'perspectives' }))
    demandes_documents_globales = @(Merge-ListUnique -Lists @(
      $all | ForEach-Object { Get-CrProp -Obj $_ -Name 'demandes_documents_globales' }
    ))
    problems = @(Merge-ListUnique -Lists @($all | ForEach-Object { Get-CrProp -Obj $_ -Name 'problems' }))
  }
}


  # =====================================================================
  # LOT 2B2F-7 : autotest deterministe SANS LLM/HTTP du merge Pass2B_2F.
  # Verifie le contrat plat refere_global_meeting.json : 7 clefs attendues,
  # listes JSON de niveau 1 (aucun tableau imbrique), resume_global string,
  # deduplication des listes. Active uniquement avec -TestPass2B2FMergeFlat.
  # =====================================================================
  if ($TestPass2B2FMergeFlat) {
    $testFails = New-Object System.Collections.ArrayList
    function Add-Pass2B2FTestFail([string]$m) { [void]$testFails.Add($m) }
    $b1 = @{
      resume_global = 'Resume long du batch 1 couvrant sujet 2 et sujet 3 avec plusieurs themes documentaires.'
      themes = @(@{ titre='Theme A'; synthese=@('syn A'); timecodes=@('00:01:00') }, @{ titre='Theme B'; synthese=@('syn B'); timecodes=@('00:02:00') })
      themes_abordes = @('thema A','thema B')
      actions = @(@{ action='controle 1'; responsable=$null; echeance=$null })
      perspectives = @('perspective 1')
      demandes_documents_globales = @(@{ objet='document 1'; demandeur=$null; destinataire=$null; echeance=$null; timecodes=@('00:03:00') })
      problems = @(@{ probleme='probleme 1'; solution=$null })
    }
    $b2 = @{
      resume_global = 'Resume du batch 2.'
      themes = @(@{ titre='Theme A'; synthese=@('syn A'); timecodes=@('00:01:00') }, @{ titre='Theme C'; synthese=@('syn C'); timecodes=@('00:04:00') })
      themes_abordes = @('thema A','thema C')
      actions = @(@{ action='controle 1'; responsable=$null; echeance=$null })
      perspectives = @('perspective 1','perspective 2')
      demandes_documents_globales = @(@{ objet='document 2'; demandeur=$null; destinataire=$null; echeance=$null; timecodes=@('00:05:00') })
      problems = @(@{ probleme='probleme 2'; solution=$null })
    }
    $r = Merge-Pass2B2FTestBatches -BatchObjs @($b1,$b2)
    $schemaKeys = @('resume_global','themes','themes_abordes','actions','perspectives','demandes_documents_globales','problems')
    $listKeys = @('themes','themes_abordes','actions','perspectives','demandes_documents_globales','problems')
    foreach ($k in $schemaKeys) {
      if (-not ($r.ContainsKey($k))) { Add-Pass2B2FTestFail ('cle manquante: ' + $k) }
    }
    foreach ($k in $listKeys) {
      $arr = @($r[$k])
      if (@($arr).Count -eq 0) { Add-Pass2B2FTestFail ('champ ' + $k + ' : liste vide inattendue.') }
      $nested = @($arr | Where-Object { $_ -is [System.Array] })
      if (@($nested).Count -gt 0) { Add-Pass2B2FTestFail ('champ ' + $k + ' : element tableau imbrique -> JSON non plat.') }
    }
    if (@($r.themes_abordes).Count -ne 3) { Add-Pass2B2FTestFail ('themes_abordes: dedup attendu 3, recu ' + @($r.themes_abordes).Count) }
    $uniqueThemes = @($r.themes | ForEach-Object { $_.titre } | Sort-Object -Unique).Count
    if ($uniqueThemes -ne @($r.themes).Count) { Add-Pass2B2FTestFail ('themes: doublon de titre detecte.') }
    $emptyR = Merge-Pass2B2FTestBatches -BatchObjs @()
    foreach ($k in $listKeys) {
      if (@($emptyR[$k]).Count -ne 0) { Add-Pass2B2FTestFail ('merge vide : champ ' + $k + ' non vide.') }
    }
    if (@($testFails).Count -eq 0) { Write-CrInfo 'Autotest Pass2B_2F (merge plat 7 champs) : OK.' }
    foreach ($tf in @($testFails)) { Write-CrErr $tf }
    Write-CrInfo ('Autotest Pass2B_2F : fails=' + @($testFails).Count)
    if (@($testFails).Count -gt 0) { exit 1 }
    exit 0
  }

# =====================================================================
# LOT 2B2F-9 : helper partage de garde semantique (run + autotest).
# Renvoie true si la sortie est structurellement valide mais vide :
# resume_global vide ET 6 listes vides.
# =====================================================================
function Test-Pass2B2FConsolidationEmpty {
  param([object] $Parsed)
  if ($null -eq $Parsed) { return $true }
  $rg = Get-CrPropString -Obj $Parsed -Name 'resume_global'
  $allEmpty = ([string]$rg).Trim().Length -eq 0
  foreach ($k in @('themes','themes_abordes','actions','perspectives','demandes_documents_globales','problems')) {
    $v = Get-CrProp -Obj $Parsed -Name $k
    if (@($v).Count -ne 0) { $allEmpty = $false }
  }
  return [bool]$allEmpty
}

  # =====================================================================
  # LOT 2B2F-9 : autotest deterministe SANS LLM/HTTP de la garde semantique
  # de consolidation + de la propagation de la trace manifest (entree
  # synthetique). Active uniquement avec -TestPass2B2FConsolidationGuard.
  #  - JSON strict vide (7 cles, listes vides)    => doit etre detecte (FAIL)
  #  - JSON strict non vide conforme              => doit passer (PASS)
  #  - entree synthetique propagee (compteurs + llm_entries)
  # =====================================================================
  if ($TestPass2B2FConsolidationGuard) {
    $guardFails = New-Object System.Collections.ArrayList
    function Add-CrGuardTestFail([string]$m) { [void]$guardFails.Add($m) }

    $emptyOut = @{
      resume_global = ''
      themes = @()
      themes_abordes = @()
      actions = @()
      perspectives = @()
      demandes_documents_globales = @()
      problems = @()
    }
    if (-not (Test-Pass2B2FConsolidationEmpty -Parsed $emptyOut)) {
      Add-CrGuardTestFail 'garde semantique : objet vide strict NON detecte (attendu true = FAIL).'
    }

    $validOut = @{
      resume_global = 'Resume synthetique de test LOT 2B2F-9.'
      themes = @(@{ titre='Theme test'; synthese=@('syn'); timecodes=@('00:00:01') })
      themes_abordes = @('theme aborde test')
      actions = @(@{ action='action test'; responsable=''; echeance='' })
      perspectives = @('perspective test')
      demandes_documents_globales = @(@{ objet='demande test'; demandeur=''; destinataire=''; echeance=''; timecodes=@('00:00:01') })
      problems = @(@{ probleme='probleme test'; solution='' })
    }
    if (Test-Pass2B2FConsolidationEmpty -Parsed $validOut) {
      Add-CrGuardTestFail 'garde semantique : objet non vide conforme detecte vide (attendu false = PASS).'
    }

    # Propagation trace manifest avec une entree synthetique (aucun HTTP).
    $script:llmEntries = New-Object System.Collections.ArrayList
    $traceCalls = 0
    $traceHttp = 0
    $traceEntry = @{
      step = 'consolidation_finale'
      lot = '2B2F-9'
      alias = 'report_remote'
      http_status = 200
      duree_sec = 1.25
      status = 'consolidation_ok'
      json_parse_ok = $true
      response_chars = 120
      retries = 0
    }
    $traceCalls += 1
    $traceHttp += 1
    [void]$script:llmEntries.Add($traceEntry)
    if ($traceCalls -ne 1 -or $traceHttp -ne 1) { Add-CrGuardTestFail 'trace : compteurs llm_calls/http_calls non incrementes.' }
    if (@($script:llmEntries).Count -ne 1) { Add-CrGuardTestFail 'trace : llm_entries ne contient pas l''entree synthetique.' }
    $traceObj = @($script:llmEntries)[0]
    foreach ($f in @('step','lot','alias','http_status','duree_sec','status','json_parse_ok','response_chars')) {
      if (-not $traceObj.ContainsKey($f)) { Add-CrGuardTestFail ('trace : champ manquant dans llm_entries -> ' + $f) }
    }
    if ([string]$traceObj['status'] -ne 'consolidation_ok') { Add-CrGuardTestFail 'trace : status attendu consolidation_ok.' }
    if ([double]$traceObj['duree_sec'] -lt 1.0) { Add-CrGuardTestFail 'trace : duree_sec attendue >= 1.0.' }

    if (@($guardFails).Count -eq 0) { Write-CrInfo 'Autotest Pass2B_2F (garde consolidation + trace manifest) : OK.' }
    foreach ($gf in @($guardFails)) { Write-CrErr $gf }
    Write-CrInfo ('Autotest Pass2B_2F garde : fails=' + @($guardFails).Count)
    if (@($guardFails).Count -gt 0) { exit 1 }
    exit 0
  }

function Invoke-Pass2B2FExecuteBatches {
  <#
    LOT 2B2F-3 / 2B2F-6 : test reel restreint Pass2B_2F.
    Execute EXACTEMENT les batches selectionnes. 2B2F-3 : A=7, C=9,
    B=19. 2B2F-6 (donnees CSV corrigees) : A=9, B=25, C=10.
    Gardes : max 3 appels logiques, aucun retry auto, detection JSON
    tronque jamais repare, signature de composition verifiee avant
    chaque appel, persistance inputs/raw/parsed + manifest + merge de
    TEST A+B+C.
  #>
  param(
    [hashtable] $Material,
    [hashtable] $Pack,
    [string]    $OutDir,
    [string]    $ModelAlias,
    [string]    $SelectBatches,
    [int]       $MaxBatchChars,
    [int]       $MaxBatchTokens,
    [string]    $StartedAt,
    [string]    $ApiBaseOverride = "",
    [string]    $ApiKeyOverride = "",
    # LOT 2B2F-6 : libelle du lot + mapping profils A/B/C -> batch_index
    [string]    $LotLabel = "2B2F-6",
    [string]    $CandidateMap = "A=9,B=25,C=10"
  )
  $want = New-Object System.Collections.ArrayList
  foreach ($tok in (([string]$SelectBatches).Split(','))) {
    $tx = ([string]$tok).Trim()
    if (-not $tx) { continue }
    $n = 0
    if (-not [int]::TryParse($tx, [ref]$n)) {
      throw ('[cr_refere_preventif] Pass2B2F select invalide : ' + $tx)
    }
    if ($n -lt 1) { throw '[cr_refere_preventif] Pass2B2F select >= 1.' }
    [void]$want.Add($n)
  }
  if (@($want).Count -lt 1 -or @($want).Count -gt 3) {
    throw '[cr_refere_preventif] Pass2B2F : selection 1..3 batches (recu=' + @($want).Count + ').'
  }
  $lot = ([string]$LotLabel).Trim()
  if (-not $lot) { $lot = '2B2F-6' }
  $lotNum = ($lot -split '-')[-1]
  if (-not $lotNum) { $lotNum = '6' }
  $execName = 'pass2b2f' + $lotNum + '_execute'
  $profiles = @{}
  foreach ($kvRaw in @($CandidateMap -split ',')) {
    $kv = ([string]$kvRaw).Trim()
    if (-not $kv) { continue }
    $pair = $kv.Split('=')
    if ($pair.Count -ne 2 -or 'ABC'.IndexOf($pair[0].Trim()) -lt 0 -or -not ($pair[1].Trim())) {
      throw ('[cr_refere_preventif] Pass2B2F candidate map invalide : ' + $kv)
    }
    if ($profiles.ContainsKey($pair[1].Trim())) {
      throw ('[cr_refere_preventif] Pass2B2F doublon d''indice dans candidate map : ' + $kv)
    }
    $profiles[$pair[1].Trim()] = $pair[0].Trim()
  }
  $letterToIdx = @{}
  foreach ($pk in @($profiles.Keys)) { $letterToIdx[[string]$profiles[$pk]] = $pk }
  $profilesDesc = (@('A','B','C') | ForEach-Object { if ($letterToIdx.ContainsKey($_)) { $_ + '=' + [string]$letterToIdx[$_] } else { $_ + '=?' } }) -join ', '
  $budget = Get-ContextBudget $ModelAlias
  $maxTokOut = [int]$budget.MaxTok
  $temperature = 0.2
  $base = $ApiBaseOverride
  if (-not $base) { $base = [string][Environment]::GetEnvironmentVariable('PIPELINE_API_BASE') }
  if (-not $base) { $base = 'http://192.168.1.20:5055' }
  $key = $ApiKeyOverride
  if (-not $key) { $key = [string][Environment]::GetEnvironmentVariable('PIPELINE_API_KEY') }
  if (-not $key) { $key = [string][Environment]::GetEnvironmentVariable('ADAPTER_API_KEY') }
  if (-not $key) {
    throw ('[cr_refere_preventif] LOT ' + $lot + ' : cle API manquante (param -ApiKey, PIPELINE_API_KEY ou ADAPTER_API_KEY) - arret sans appel LLM.')
  }
  $script:HttpBlocked = $false
  $script:AdapterApiBase = $base
  $script:AdapterApiKey = $key
  $script:LlmTimeoutSec = [int]$LlmTimeoutSec
  Write-CrInfo ('Pass2B_2F test reel ' + $lot + ' : alias=' + $ModelAlias + ' endpoint=' + $base + ' batches=[' + (@($want) -join ',') + '] profils=[' + $profilesDesc + '] max_tokens_out=' + $maxTokOut)
  $p2dir = Join-Path $OutDir 'pass2b2f'
  $execDir = Join-Path $p2dir $execName
  $inputDir = Join-Path $execDir 'inputs'
  $rawDir = Join-Path $execDir 'raw_responses'
  $parsedDir = Join-Path $execDir 'parsed_outputs'
  Ensure-Dir $execDir
  Ensure-Dir $inputDir
  Ensure-Dir $rawDir
  Ensure-Dir $parsedDir
  $byIdx = @{}
  foreach ($b in @($Pack.batches)) { $byIdx[[int]$b.batch_index] = $b }
  $entries = New-Object System.Collections.ArrayList
  $calls = 0
  foreach ($idx in @($want)) {
    if (-not $byIdx.ContainsKey($idx)) {
      throw ('[cr_refere_preventif] Pass2B2F batch ' + $idx + ' absent du pack (profils=' + $profilesDesc + ').')
    }
    $b = $byIdx[$idx]
    $n2 = '{0:D2}' -f $idx
    $tag = 'batch_' + $n2
    $sysTxt = [string]$b.prompt_system
    $usrTxt = [string]$b.prompt_user
    $genU = @($b.units | Where-Object { [string]$_.source_type -eq 'general_segment' })
    $phoU = @($b.units | Where-Object { [string]$_.source_type -eq 'photo_context' })
    $photoSubjects = @($phoU | ForEach-Object { [int]$_.subject_numero } | Sort-Object -Unique)
    $segSujets = @()
    foreach ($g in $genU) {
      foreach ($s in @($g.sujets_detectes)) {
        if ($null -ne $s) { $segSujets += [string]$s }
      }
    }
    $segSujets = @($segSujets | Sort-Object -Unique)
    $sigGen = [int]$b.general_segments_count
    $sigPho = [int]$b.photo_units_count
    Write-CrInfo ('batch ' + $n2 + ' : gen=' + $sigGen + ' photo=' + $sigPho + ' photo_sujets=[' + ($photoSubjects -join ',') + '] seg_sujets=[' + ($segSujets -join ',') + '] tokens_est=' + [int]$b.tokens_est)
    $prof = ''
    if ($profiles.ContainsKey([string]$idx)) { $prof = [string]$profiles[[string]$idx] }
    if (-not $prof) {
      throw ('[cr_refere_preventif] Pass2B2F batch ' + $idx + ' absent du mapping profils (map=' + $CandidateMap + ') - arret sans appel.')
    }
    if ($prof -eq 'A') {
      # A : oral + photos - sujets 2 ET 3 presents.
      if ($sigGen -lt 2 -or $sigPho -lt 6) {
        throw ('[cr_refere_preventif] LOT ' + $lot + ' : batch ' + $idx + ' (A oral+photos) KO attendu gen>=2 photo>=6 - arret sans appel.')
      }
      foreach ($s in $photoSubjects) {
        if ($s -ne 2 -and $s -ne 3) {
          throw ('[cr_refere_preventif] LOT ' + $lot + ' : batch ' + $idx + ' (A) sujet photo hors {2,3} - arret sans appel.')
        }
      }
      if (-not ($photoSubjects -contains 2) -or -not ($photoSubjects -contains 3)) {
        throw ('[cr_refere_preventif] LOT ' + $lot + ' : batch ' + $idx + ' (A) doit couvrir les sujets 2 ET 3 - arret sans appel.')
      }
    } elseif ($prof -eq 'B') {
      # B : 100% photos sujet 20 dans un trou ASR (duree reunion, hors segment).
      if ($sigGen -ne 0 -or $sigPho -lt 10) {
        throw ('[cr_refere_preventif] LOT ' + $lot + ' : batch ' + $idx + ' (B trou ASR) KO attendu gen=0 photo>=10 sujet 20 - arret sans appel.')
      }
      foreach ($s in $photoSubjects) {
        if ($s -ne 20) {
          throw ('[cr_refere_preventif] LOT ' + $lot + ' : batch ' + $idx + ' (B) sujet photo != 20 - arret sans appel.')
        }
      }
      $horsKo = @($phoU | Where-Object { -not [bool]$_.hors_segments }).Count
      if ($horsKo -ne 0) {
        throw ('[cr_refere_preventif] LOT ' + $lot + ' : batch ' + $idx + ' (B) doit etre 100% hors_segments (trou ASR) - arret sans appel.')
      }
    } elseif ($prof -eq 'C') {
      # C : photo-dense sujet 2 homogene, zone couverte ASR, <=1 segment general.
      if ($sigGen -gt 1 -or $sigPho -lt 10) {
        throw ('[cr_refere_preventif] LOT ' + $lot + ' : batch ' + $idx + ' (C photo-dense) KO attendu gen<=1 photo>=10 sujet 2 - arret sans appel.')
      }
      foreach ($s in $photoSubjects) {
        if ($s -ne 2) {
          throw ('[cr_refere_preventif] LOT ' + $lot + ' : batch ' + $idx + ' (C) sujet photo != 2 - arret sans appel.')
        }
      }
    } else {
      throw ('[cr_refere_preventif] Pass2B2F profil inconnu "' + $prof + '" - arret sans appel.')
    }
    if ($calls -ge 3) {
      throw ('[cr_refere_preventif] LOT ' + $lot + ' : depassement max 3 appels logiques.')
    }
    $promptChars = ([string]$sysTxt).Length + ([string]$usrTxt).Length
    $entry = @{
      tag = $tag
      batch_index = $idx
      lot = $lot
      alias_logique = $ModelAlias
      budget_contexte = @{ n_ctx = [int]$budget.NCtx; max_tokens_out = $maxTokOut; margin = [int]$budget.Margin }
      max_batch_chars = $MaxBatchChars
      max_batch_tokens = $MaxBatchTokens
      estimated_input_tokens = [int]$b.tokens_est
      prompt_chars = $promptChars
      temperature = $temperature
      general_segments_count = $sigGen
      photo_units_count = $sigPho
      photo_subjects = @($photoSubjects)
      segment_subjects = @($segSujets)
      units_count = [int]$b.units_count
      start_hms = [string]$b.start_hms
      end_hms = [string]$b.end_hms
      http_status = 0
      duree_sec = 0.0
      finish_reason = $null
      model_reel = $null
      usage = $null
      response_chars = 0
      error = $null
      parse_error = $null
      json_parse_ok = $false
      truncated_or_invalid_response = $false
      missing_keys = @()
      extra_keys = @()
      raw_file = ''
      parsed_file = ''
      input_file = ''
      retries = 0
    }
    $inputDoc = @{
      schema = ('cr_refere_preventif.pass2b2f' + $lotNum + '.batch_input.v1')
      lot = $lot
      execute_llm = $true
      dry_run = $false
      batch_index = $idx
      general_segments_count = $sigGen
      photo_units_count = $sigPho
      units_count = [int]$b.units_count
      estimated_input_tokens = [int]$b.tokens_est
      prompt_chars = $promptChars
      model_alias = $ModelAlias
      max_tokens_out = $maxTokOut
      temperature = $temperature
      prompt = @{ system = $sysTxt; user = $usrTxt }
      units = @($b.units)
    }
    $inputFile = Join-Path $inputDir ($tag + '_input.json')
    Write-CrJsonAtomic -Path $inputFile -Obj $inputDoc
    Add-CrOutputFile $inputFile
    $entry.input_file = $inputFile
    $t0 = Get-Date
    $raw = ''
    try {
      $endpoint = $script:AdapterApiBase.TrimEnd('/') + '/v1/chat/completions'
      $body = @{
        model = $ModelAlias
        messages = @(
          @{ role = 'system'; content = $sysTxt },
          @{ role = 'user'; content = $usrTxt }
        )
        temperature = $temperature
        max_tokens = $maxTokOut
        stream = $false
      }
      $resp = Invoke-LLM-OpenAICompat -Endpoint $endpoint -Body $body -TimeoutSec $script:LlmTimeoutSec -MaxRetries 0
      $entry.duree_sec = [math]::Round(((Get-Date) - $t0).TotalSeconds, 2)
      $entry.http_status = $script:LastHttpStatus
      if ($null -ne $resp) {
        $prm = $resp.PSObject.Properties['model']
        if ($null -ne $prm) { $entry.model_reel = [string]$prm.Value }
      }
      if ($null -eq $resp -or $null -eq $resp.choices -or $null -eq $resp.choices[0] -or $null -eq $resp.choices[0].message) {
        throw '[cr_refere_preventif] Pass2B2F : reponse sans choices[0].message.'
      }
      $ch0 = $resp.choices[0]
      $pFr = $ch0.PSObject.Properties['finish_reason']
      if ($null -ne $pFr) { $entry.finish_reason = [string]$pFr.Value }
      $raw = [string]$ch0.message.content
      $entry.response_chars = $raw.Length
      $pUs = $resp.PSObject.Properties['usage']
      if ($null -ne $pUs) { $entry.usage = $pUs.Value }
      $rawFile = Join-Path $rawDir ($tag + '_raw.txt')
      Write-CrTextUtf8NoBom -Path $rawFile -Text $raw
      Add-CrOutputFile $rawFile
      $entry.raw_file = $rawFile
      try {
        $parsed = Parse-LlmJsonStrict -Raw $raw
        $keys = @($parsed.psobject.Properties.Name)
        $schemaKeys = @('resume_global','themes','themes_abordes','actions','perspectives','demandes_documents_globales','problems')
        $entry.json_parse_ok = $true
        $entry.missing_keys = @($schemaKeys | Where-Object { $_ -notin $keys })
        $entry.extra_keys = @($keys | Where-Object { $_ -notin $schemaKeys })
        $parsedFile = Join-Path $parsedDir ($tag + '_response.json')
        Write-CrJsonAtomic -Path $parsedFile -Obj $parsed
        Add-CrOutputFile $parsedFile
        $entry.parsed_file = $parsedFile
      } catch {
        $entry.parse_error = $_.Exception.Message
      }
    } catch {
      $entry.error = $_.Exception.Message
      try { $entry.duree_sec = [math]::Round(((Get-Date) - $t0).TotalSeconds, 2) } catch { }
    }
    if ([int]$entry.http_status -eq 200 -and $entry.response_chars -gt 0 -and (-not $entry.error) -and (-not [bool]$entry.json_parse_ok)) {
      $entry.truncated_or_invalid_response = $true
      [void]$script:CriticalQaWarnings.Add(('Pass2B_2F batch ' + $tag + ' : HTTP 200 mais JSON incomplet/invalide -> truncated_or_invalid_response ; pas de reparation ni de retry (LOT ' + $lot + ').'))
    }
    $calls++
    [void]$entries.Add($entry)
  }
  # --- Fin de boucle : bilan, persistance, manifest, merge de TEST A+B+C ---
  $okEntries = @($entries | Where-Object { ([int]$_.http_status -eq 200) -and (-not $_.error) -and [bool]$_.json_parse_ok })
  $failEntries = @($entries | Where-Object { [bool]$_.json_parse_ok -eq $false -or ($_.error) })
  $allOk = (@($entries).Count -gt 0 -and @($failEntries).Count -eq 0)
  $entriesFile = Join-Path $execDir 'entries.json'
  $entriesDoc = @{
    schema_version = ('cr_refere_preventif.pass2b2f' + $lotNum + '.entries.v1')
    lot = $lot
    generated_at = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
    selected_batches = @($want)
    calls_count = $calls
    all_ok = $allOk
    entries = @($entries)
  }
  Write-CrJsonAtomic -Path $entriesFile -Obj $entriesDoc
  Add-CrOutputFile $entriesFile
  $traceLines = New-Object System.Collections.ArrayList
  [void]$traceLines.Add(('Pass2B_2F LOT ' + $lot + ' - trace des appels reels (report_remote)'))
  [void]$traceLines.Add('alias_logique=' + $ModelAlias + ' endpoint=' + $base + ' max_tokens_out=' + $maxTokOut + ' temperature=' + $temperature)
  foreach ($e in @($entries)) {
    [void]$traceLines.Add('batch=' + [string]$e.batch_index + ' tag=' + [string]$e.tag + ' http=' + [int]$e.http_status + ' duree_sec=' + [double]$e.duree_sec + ' finish_reason=' + $(if ($null -ne $e.finish_reason) { [string]$e.finish_reason } else { 'N/A' }) + ' model_reel=' + $(if ($null -ne $e.model_reel) { [string]$e.model_reel } else { 'N/A' }) + ' response_chars=' + [int]$e.response_chars + ' json_parse_ok=' + [bool]$e.json_parse_ok + ' truncated=' + [bool]$e.truncated_or_invalid_response + ' error=' + $(if ($e.error) { [string]$e.error } else { '' }) + ' parse_error=' + $(if ($e.parse_error) { [string]$e.parse_error } else { '' }))
  }
  $traceFile = Join-Path $execDir 'calls_trace.txt'
  Write-CrTextUtf8NoBom -Path $traceFile -Text (@($traceLines) -join [Environment]::NewLine)
  Add-CrOutputFile $traceFile
  $mergeObjs = New-Object System.Collections.ArrayList
  foreach ($e in @($entries)) {
    if ([bool]$e.json_parse_ok -and $e.parsed_file) {
      try {
        $po = Read-JsonFile -Path $e.parsed_file
        if ($null -ne $po) { [void]$mergeObjs.Add($po) }
      } catch {
        Write-CrWarn ('merge test : impossible de relire ' + [string]$e.parsed_file)
      }
    }
  }
  $mergeResult = $null
  $mergeDiag = $null
  $mergeFile = ''
  if (@($mergeObjs).Count -gt 0) {
    $mergeResult = Merge-Pass2B2FTestBatches -BatchObjs @($mergeObjs)
    $mergeDiag = @{
      batches_merged = @($mergeObjs).Count
      resume_global_chars = ([string]$mergeResult.resume_global).Length
      themes_count = @($mergeResult.themes).Count
      themes_abordes_count = @($mergeResult.themes_abordes).Count
      actions_count = @($mergeResult.actions).Count
      perspectives_count = @($mergeResult.perspectives).Count
      demandes_documents_count = @($mergeResult.demandes_documents_globales).Count
      problems_count = @($mergeResult.problems).Count
    }
    $mergeFile = Join-Path $execDir 'merge_test_abc.json'
    Write-CrJsonAtomic -Path $mergeFile -Obj $mergeResult
    Add-CrOutputFile $mergeFile
  }
  $manifestFile = Join-Path $execDir ($execName + '_manifest.json')
  $manifest3 = @{
    schema_version = ('cr_refere_preventif.pass2b2f' + $lotNum + '.execute.v1')
    lot = $lot
    pipeline = $script:PipelineName
    dry_run = $false
    execute_llm = $true
    llm_calls_logical = $calls
    http_calls = $calls
    max_allowed_logical_calls = 3
    alias = $ModelAlias
    max_batch_chars = $MaxBatchChars
    max_batch_tokens = $MaxBatchTokens
    budget_contexte = @{ n_ctx = [int]$budget.NCtx; max_tokens_out = $maxTokOut; margin = [int]$budget.Margin }
    endpoint = $base
    selected_batches = @($want)
    started_at = $StartedAt
    finished_at = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
    all_ok = $allOk
    ok_entries = @($okEntries).Count
    entries = @($entries)
    trace_file = $traceFile
    merge_test_abc = $mergeDiag
    merge_test_file = $mergeFile
    output_path = $entriesFile
    notes = @(
      ('LOT ' + $lot + ' : test reel restreint Pass2B_2F sur 3 batches (' + $profilesDesc + ').')
      'Aucun retry auto (MaxRetries=0). Aucune reparation JSON artificielle.'
      'Merge A+B+C : test technique uniquement (pas de refere_global_meeting.json final).'
      'resume_global du merge = resume le plus long (regle historique Merge-MeetingBatchObjects).'
    )
  }
  Write-CrJsonAtomic -Path $manifestFile -Obj $manifest3
  Add-CrOutputFile $manifestFile
  Write-CrInfo ('Pass2B_2F test ' + $lot + ' termine : appels=' + $calls + ' ok=' + @($okEntries).Count + '/' + @($entries).Count + ' manifest=' + $manifestFile)
  return @{
    summary = @{
      ok = $allOk
      calls = $calls
      ok_entries = @($okEntries).Count
      entries_count = @($entries).Count
      manifest = $manifestFile
      entries_file = $entriesFile
      trace_file = $traceFile
      merge_test = $mergeDiag
    }
    entries = @($entries)
  }
}

function Invoke-Pass2B2FRunCompleteBatches {
  <#
    LOT 2B2F-7 : run complet Pass2B_2F sur TOUS les batches du plan definitif.
    Un seul appel LLM par batch (report_remote), aucun retry auto, aucune
    reparation JSON. Si un batch echoue : le run global est invalide, les
    resultats deja obtenus sont conserves, refere_global_meeting.json n est
    PAS produit. Merge deterministe uniquement si tous les batches sont OK
    (regle historique Merge-MeetingBatchObjects : resume_global = resume le
    plus long ; listes fusionnees et dedupliquees, niveau 1, sans encapsulation).
  #>
  param(
    [hashtable] $Material,
    [hashtable] $Pack,
    [string]    $OutDir,
    [string]    $ModelAlias,
    [string]    $StartedAt,
    [int]       $MaxBatchChars,
    [int]       $MaxBatchTokens,
    [string]    $ApiBaseOverride = "",
    [string]    $ApiKeyOverride = "",
    [string]    $LotLabel = "2B2F-7"
  )
  $lot = ([string]$LotLabel).Trim()
  if (-not $lot) { $lot = '2B2F-7' }
  $lotNum = ($lot -split '-')[-1]
  if (-not $lotNum) { $lotNum = '7' }
  $execName = 'pass2b2f' + $lotNum + '_execute'
  $budget = Get-ContextBudget $ModelAlias
  $maxTokOut = [int]$budget.MaxTok
  $temperature = 0.2
  $base = $ApiBaseOverride
  if (-not $base) { $base = [string][Environment]::GetEnvironmentVariable('PIPELINE_API_BASE') }
  if (-not $base) { $base = 'http://192.168.1.20:5055' }
  $key = $ApiKeyOverride
  if (-not $key) { $key = [string][Environment]::GetEnvironmentVariable('PIPELINE_API_KEY') }
  if (-not $key) { $key = [string][Environment]::GetEnvironmentVariable('ADAPTER_API_KEY') }
  if (-not $key) {
    throw ('[cr_refere_preventif] LOT ' + $lot + ' : cle API manquante (PIPELINE_API_KEY / ADAPTER_API_KEY / -ApiKey) - arret sans appel LLM.')
  }
  $script:HttpBlocked = $false
  $script:AdapterApiBase = $base
  $script:AdapterApiKey = $key
  $script:LlmTimeoutSec = [int]$LlmTimeoutSec
  $p2dir = Join-Path $OutDir 'pass2b2f'
  $execDir = Join-Path $p2dir $execName
  $inputDir = Join-Path $execDir 'inputs'
  $rawDir = Join-Path $execDir 'raw_responses'
  $parsedDir = Join-Path $execDir 'parsed_outputs'
  Ensure-Dir $execDir
  Ensure-Dir $inputDir
  Ensure-Dir $rawDir
  Ensure-Dir $parsedDir
  $byIdx = @{}
  foreach ($b in @($Pack.batches)) { $byIdx[[int]$b.batch_index] = $b }
  $idxList = @($Pack.batches | ForEach-Object { [int]$_.batch_index } | Sort-Object)
  $expectedBatches = @($idxList).Count
  Write-CrInfo ('Pass2B_2F LOT ' + $lot + ' run complet : alias=' + $ModelAlias + ' endpoint=' + $base + ' batches=' + $expectedBatches + ' max_tokens_out=' + $maxTokOut + ' temperature=' + $temperature)
  $entries = New-Object System.Collections.ArrayList
  $calls = 0
  foreach ($idx in @($idxList)) {
    if (-not $byIdx.ContainsKey($idx)) {
      throw ('[cr_refere_preventif] Pass2B2F batch ' + $idx + ' absent du pack (run complet).')
    }
    $b = $byIdx[$idx]
    $n2 = '{0:D2}' -f $idx
    $tag = 'batch_' + $n2
    $sysTxt = [string]$b.prompt_system
    $usrTxt = [string]$b.prompt_user
    $genU = @($b.units | Where-Object { [string]$_.source_type -eq 'general_segment' })
    $phoU = @($b.units | Where-Object { [string]$_.source_type -eq 'photo_context' })
    $photoSubjects = @($phoU | ForEach-Object { [int]$_.subject_numero } | Sort-Object -Unique)
    $segSujets = @()
    foreach ($g in $genU) {
      foreach ($s in @($g.sujets_detectes)) {
        if ($null -ne $s) { $segSujets += [string]$s }
      }
    }
    $segSujets = @($segSujets | Sort-Object -Unique)
    $sigGen = [int]$b.general_segments_count
    $sigPho = [int]$b.photo_units_count
    Write-CrInfo ('batch ' + $n2 + ' : gen=' + $sigGen + ' photo=' + $sigPho + ' photo_sujets=[' + ($photoSubjects -join ',') + '] seg_sujets=[' + ($segSujets -join ',') + '] tokens_est=' + [int]$b.tokens_est + ' prompt_chars=' + [int]$b.prompt_chars)
    $promptChars = ([string]$sysTxt).Length + ([string]$usrTxt).Length
    $entry = @{
      tag = $tag
      batch_index = $idx
      lot = $lot
      alias_logique = $ModelAlias
      budget_contexte = @{ n_ctx = [int]$budget.NCtx; max_tokens_out = $maxTokOut; margin = [int]$budget.Margin }
      max_batch_chars = $MaxBatchChars
      max_batch_tokens = $MaxBatchTokens
      estimated_input_tokens = [int]$b.tokens_est
      prompt_chars = $promptChars
      temperature = $temperature
      general_segments_count = $sigGen
      photo_units_count = $sigPho
      photo_subjects = @($photoSubjects)
      segment_subjects = @($segSujets)
      units_count = [int]$b.units_count
      start_hms = [string]$b.start_hms
      end_hms = [string]$b.end_hms
      http_status = 0
      duree_sec = 0.0
      finish_reason = $null
      model_reel = $null
      usage = $null
      response_chars = 0
      error = $null
      parse_error = $null
      json_parse_ok = $false
      truncated_or_invalid_response = $false
      missing_keys = @()
      extra_keys = @()
      raw_file = ''
      parsed_file = ''
      input_file = ''
      retries = 0
    }
    $inputDoc = @{
      schema = ('cr_refere_preventif.pass2b2f' + $lotNum + '.batch_input.v1')
      lot = $lot
      execute_llm = $true
      dry_run = $false
      batch_index = $idx
      general_segments_count = $sigGen
      photo_units_count = $sigPho
      units_count = [int]$b.units_count
      estimated_input_tokens = [int]$b.tokens_est
      prompt_chars = $promptChars
      model_alias = $ModelAlias
      max_tokens_out = $maxTokOut
      temperature = $temperature
      prompt = @{ system = $sysTxt; user = $usrTxt }
      units = @($b.units)
    }
    $inputFile = Join-Path $inputDir ($tag + '_input.json')
    Write-CrJsonAtomic -Path $inputFile -Obj $inputDoc
    Add-CrOutputFile $inputFile
    $entry.input_file = $inputFile
    $t0 = Get-Date
    $raw = ''
    try {
      $endpoint = $script:AdapterApiBase.TrimEnd('/') + '/v1/chat/completions'
      $body = @{
        model = $ModelAlias
        messages = @(
          @{ role = 'system'; content = $sysTxt },
          @{ role = 'user'; content = $usrTxt }
        )
        temperature = $temperature
        max_tokens = $maxTokOut
        stream = $false
      }
      $resp = Invoke-LLM-OpenAICompat -Endpoint $endpoint -Body $body -TimeoutSec $script:LlmTimeoutSec -MaxRetries 0
      $entry.duree_sec = [math]::Round(((Get-Date) - $t0).TotalSeconds, 2)
      $entry.http_status = $script:LastHttpStatus
      if ($null -ne $resp) {
        $prm = $resp.PSObject.Properties['model']
        if ($null -ne $prm) { $entry.model_reel = [string]$prm.Value }
      }
      if ($null -eq $resp -or $null -eq $resp.choices -or $null -eq $resp.choices[0] -or $null -eq $resp.choices[0].message) {
        throw '[cr_refere_preventif] Pass2B2F : reponse sans choices[0].message.'
      }
      $ch0 = $resp.choices[0]
      $pFr = $ch0.PSObject.Properties['finish_reason']
      if ($null -ne $pFr) { $entry.finish_reason = [string]$pFr.Value }
      $raw = [string]$ch0.message.content
      $entry.response_chars = $raw.Length
      $pUs = $resp.PSObject.Properties['usage']
      if ($null -ne $pUs) { $entry.usage = $pUs.Value }
      $rawFile = Join-Path $rawDir ($tag + '_raw.txt')
      Write-CrTextUtf8NoBom -Path $rawFile -Text $raw
      Add-CrOutputFile $rawFile
      $entry.raw_file = $rawFile
      try {
        $parsed = Parse-LlmJsonStrict -Raw $raw
        $keys = @($parsed.psobject.Properties.Name)
        $schemaKeys = @('resume_global','themes','themes_abordes','actions','perspectives','demandes_documents_globales','problems')
        $entry.json_parse_ok = $true
        $entry.missing_keys = @($schemaKeys | Where-Object { $_ -notin $keys })
        $entry.extra_keys = @($keys | Where-Object { $_ -notin $schemaKeys })
        $parsedFile = Join-Path $parsedDir ($tag + '_response.json')
        Write-CrJsonAtomic -Path $parsedFile -Obj $parsed
        Add-CrOutputFile $parsedFile
        $entry.parsed_file = $parsedFile
      } catch {
        $entry.parse_error = $_.Exception.Message
      }
    } catch {
      $entry.error = $_.Exception.Message
      try { $entry.duree_sec = [math]::Round(((Get-Date) - $t0).TotalSeconds, 2) } catch { }
    }
    if ([int]$entry.http_status -eq 200 -and $entry.response_chars -gt 0 -and (-not $entry.error) -and (-not [bool]$entry.json_parse_ok)) {
      $entry.truncated_or_invalid_response = $true
      [void]$script:CriticalQaWarnings.Add(('Pass2B_2F run complet : batch ' + $tag + ' HTTP 200 mais JSON incomplet/invalide -> truncated_or_invalid_response ; pas de reparation ni de retry.'))
    }
    $calls++
    [void]$entries.Add($entry)
  }
  $okEntries = @($entries | Where-Object { ([int]$_.http_status -eq 200) -and (-not $_.error) -and [bool]$_.json_parse_ok })
  $failEntries = @($entries | Where-Object { [bool]$_.json_parse_ok -eq $false -or ($_.error) })
  $allOk = (@($entries).Count -eq $expectedBatches -and @($failEntries).Count -eq 0)
  $entriesFile = Join-Path $execDir 'entries.json'
  $entriesDoc = @{
    schema_version = ('cr_refere_preventif.pass2b2f' + $lotNum + '.entries.v1')
    lot = $lot
    generated_at = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
    selected_batches = @($idxList)
    calls_count = $calls
    expected_batches = $expectedBatches
    all_ok = $allOk
    entries = @($entries)
  }
  Write-CrJsonAtomic -Path $entriesFile -Obj $entriesDoc
  Add-CrOutputFile $entriesFile
  $traceLines = New-Object System.Collections.ArrayList
  [void]$traceLines.Add(('Pass2B_2F LOT ' + $lot + ' - trace des appels reels (run complet ' + $ModelAlias + ')'))
  [void]$traceLines.Add('alias_logique=' + $ModelAlias + ' endpoint=' + $base + ' max_tokens_out=' + $maxTokOut + ' temperature=' + $temperature)
  foreach ($e in @($entries)) {
    [void]$traceLines.Add('batch=' + [string]$e.batch_index + ' tag=' + [string]$e.tag + ' http=' + [int]$e.http_status + ' duree_sec=' + [double]$e.duree_sec + ' finish_reason=' + $(if ($null -ne $e.finish_reason) { [string]$e.finish_reason } else { 'N/A' }) + ' model_reel=' + $(if ($null -ne $e.model_reel) { [string]$e.model_reel } else { 'N/A' }) + ' response_chars=' + [int]$e.response_chars + ' json_parse_ok=' + [bool]$e.json_parse_ok + ' truncated=' + [bool]$e.truncated_or_invalid_response + ' error=' + $(if ($e.error) { [string]$e.error } else { '' }) + ' parse_error=' + $(if ($e.parse_error) { [string]$e.parse_error } else { '' }))
  }
  $traceFile = Join-Path $execDir 'calls_trace.txt'
  Write-CrTextUtf8NoBom -Path $traceFile -Text (@($traceLines) -join [Environment]::NewLine)
  Add-CrOutputFile $traceFile
  $refereFile = ''
  $mergeDiag = $null
  $flatIssues = @()
  $resumeSource = $null
  if ($allOk) {
    $mergeObjs = New-Object System.Collections.ArrayList
    $parsedMeta = New-Object System.Collections.ArrayList
    foreach ($e in @($entries)) {
      if ([bool]$e.json_parse_ok -and $e.parsed_file) {
        try {
          $po = Read-JsonFile -Path $e.parsed_file
          if ($null -ne $po) {
            [void]$mergeObjs.Add($po)
            [void]$parsedMeta.Add(@{ batch_index = [int]$e.batch_index; obj = $po })
          }
        } catch {
          Write-CrWarn ('run complet : impossible de relire ' + [string]$e.parsed_file)
        }
      }
    }
    if (@($mergeObjs).Count -ne $expectedBatches) {
      throw ('[cr_refere_preventif] run complet : objets parses ' + @($mergeObjs).Count + ' != batches ' + $expectedBatches + ' - merge non lance.')
    }
    $mR = Merge-Pass2B2FTestBatches -BatchObjs @($mergeObjs)
    $listKeys7 = @('themes','themes_abordes','actions','perspectives','demandes_documents_globales','problems')
    foreach ($k in $listKeys7) {
      $nestedChk = @(@($mR[$k]) | Where-Object { $_ -is [System.Array] })
      if (@($nestedChk).Count -gt 0) {
        $flatIssues += ('liste non plate: ' + $k)
        [void]$script:CriticalQaWarnings.Add('[Pass2B_2F] refere_global_meeting liste non plate : ' + $k)
      }
    }
    $beforeCounts = @{}
    foreach ($k in $listKeys7) { $beforeCounts[$k] = 0 }
    $actionsBatches = 0
    foreach ($pm in @($parsedMeta)) {
      foreach ($k in $listKeys7) {
        $vL = Get-CrProp -Obj $pm.obj -Name $k
        if ($null -ne $vL) { $beforeCounts[$k] = $beforeCounts[$k] + @($vL).Count }
      }
      $actL = Get-CrProp -Obj $pm.obj -Name 'actions'
      if ($null -ne $actL -and @($actL).Count -gt 0) { $actionsBatches++ }
    }
    $afterCounts = @{}
    foreach ($k in $listKeys7) { $afterCounts[$k] = @($mR[$k]).Count }
    foreach ($pm in @($parsedMeta)) {
      $rv = Get-CrProp -Obj $pm.obj -Name 'resume_global'
      if ($null -ne $rv -and ([string]$rv) -eq ([string]$mR.resume_global)) {
        $resumeSource = @{ batch_index = [int]$pm.batch_index; resume_chars = ([string]$mR.resume_global).Length }
        break
      }
    }
    $refereFile = Join-Path $p2dir 'refere_global_meeting.json'
    Write-CrJsonAtomic -Path $refereFile -Obj $mR
    Add-CrOutputFile $refereFile
    $mergeDiag = @{
      batches_merged = @($mergeObjs).Count
      resume_global_chars = ([string]$mR.resume_global).Length
      resume_global_batch_source = $(if ($null -ne $resumeSource) { [int]$resumeSource.batch_index } else { $null })
      themes_before = [int]$beforeCounts['themes']
      themes_after = [int]$afterCounts['themes']
      themes_abordes_before = [int]$beforeCounts['themes_abordes']
      themes_abordes_after = [int]$afterCounts['themes_abordes']
      actions_before = [int]$beforeCounts['actions']
      actions_after = [int]$afterCounts['actions']
      actions_batches_with_actions = $actionsBatches
      perspectives_before = [int]$beforeCounts['perspectives']
      perspectives_after = [int]$afterCounts['perspectives']
      demandes_before = [int]$beforeCounts['demandes_documents_globales']
      demandes_after = [int]$afterCounts['demandes_documents_globales']
      problems_before = [int]$beforeCounts['problems']
      problems_after = [int]$afterCounts['problems']
      flat_ok = (@($flatIssues).Count -eq 0)
      flat_issues = @($flatIssues)
      refere_global_meeting_path = $refereFile
    }
  }
  $manifestFile = Join-Path $execDir ($execName + '_manifest.json')
  $manifest7 = @{
    schema_version = ('cr_refere_preventif.pass2b2f' + $lotNum + '.execute.v1')
    lot = $lot
    pipeline = $script:PipelineName
    dry_run = $false
    execute_llm = $true
    run_complete = $true
    llm_calls = $calls
    http_calls = $calls
    max_allowed_logical_calls = $expectedBatches
    alias = $ModelAlias
    max_batch_chars = $MaxBatchChars
    max_batch_tokens = $MaxBatchTokens
    budget_contexte = @{ n_ctx = [int]$budget.NCtx; max_tokens_out = $maxTokOut; margin = [int]$budget.Margin }
    endpoint = $base
    selected_batches = @($idxList)
    started_at = $StartedAt
    finished_at = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
    all_ok = $allOk
    ok_entries = @($okEntries).Count
    fail_entries = @($failEntries).Count
    entries = @($entries)
    trace_file = $traceFile
    merge = $mergeDiag
    refere_global_meeting_path = $refereFile
    material_stats = @{
      general_segments_count = [int]$Material.general_segments_count
      photo_units_count = [int]$Material.photo_units_count
      photo_units_with_segment = [int]$Material.photo_units_with_segment
      photo_units_in_asr_gap = [int]$Material.photo_units_in_asr_gap
      photo_units_after_asr = [int]$Material.photo_units_after_asr
      photo_units_before_asr = [int]$Material.photo_units_before_asr
      asr_start_sec = [double]$Material.asr_start_sec
      asr_end_sec = [double]$Material.asr_end_sec
      photos_hors_segments = [int]$Material.photos_hors_segments
      excluded_skipped = [int]$Material.excluded_skipped
      subjects_with_photos = @($Material.subjects_with_photos)
      subjects_with_photos_count = [int]$Material.subjects_with_photos_count
      batches_count = [int]$Pack.batches_count
    }
    output_path = $entriesFile
    notes = @(
      ('LOT ' + $lot + ' : run complet Pass2B_2F sur ' + $expectedBatches + ' batches (' + $ModelAlias + ').')
      'Aucun retry auto (MaxRetries=0). Aucune reparation JSON artificielle.'
      'refere_global_meeting.json produit uniquement si tous les batches sont valides (JSON strict).'
      'resume_global du merge = resume le plus long (regle historique Merge-MeetingBatchObjects).'
      'Listes de niveau 1 (contrat plat global_meeting) verifiees avant ecriture.'
    )
  }
  Write-CrJsonAtomic -Path $manifestFile -Obj $manifest7
  Add-CrOutputFile $manifestFile
  Write-CrInfo ('Pass2B_2F run complet ' + $lot + ' termine : appels=' + $calls + ' ok=' + @($okEntries).Count + '/' + @($entries).Count + ' all_ok=' + $allOk + ' refere=' + $refereFile)
  return @{
    summary = @{
      ok = $allOk
      calls = $calls
      expected_batches = $expectedBatches
      ok_entries = @($okEntries).Count
      entries_count = @($entries).Count
      fail_entries = @($failEntries).Count
      manifest = $manifestFile
      entries_file = $entriesFile
      trace_file = $traceFile
      merge = $mergeDiag
      refere_global_meeting_path = $refereFile
    }
    entries = @($entries)
  }
}

function Invoke-Pass2B2FDryRun {
  <#
    Pilote DryRun Pass2B_2F (LOT 2B2F-1) : preparation des unites rang 1,
    batching, controles attendus (photos affectees / exclues propres a
    l affaire), ecriture des artefacts et du manifest dedie. AUCUN appel LLM.
  #>
  param(
    [hashtable] $Ctx,
    [string]    $SegmentsDir,
    [string]    $OutDir,
    [string]    $ModelAlias,
    [int]       $ExpectedAffected,
    [int]       $ExpectedExcluded,
    [string]    $StartedAt,
    [int]       $MaxBatchChars = 20000,
    [int]       $MaxBatchTokens = 5500
  )
  $maxChars = $MaxBatchChars
  $maxToks  = $MaxBatchTokens
  $budgetCfg = Get-ContextBudget $ModelAlias
  $histBudget = @{
    alias = $ModelAlias
    n_ctx = [int]$budgetCfg.NCtx
    max_tokens_out = [int]$budgetCfg.MaxTok
    margin = [int]$budgetCfg.Margin
    max_batch_chars = $maxChars
    max_batch_tokens = $maxToks
    source = 'historique Pass2B generaliste [G:65-67,486-488] ; inchange'
    status = 'historical_budget_reuse'
  }
  $material = Build-Pass2B2FRank1Material -Ctx $Ctx -SegmentsDir $SegmentsDir
  $consts = New-Pass2B2FTextConstants
  $pack = New-Pass2B2FBatchPack -OrderedUnits @($material.units) -SystemText $consts.system -UserTemplate $consts.user_template -MaxBatchChars $maxChars -MaxBatchTokens $maxToks
  $photoUnits = @($material.photo_units)
  $photoTextChars = 0
  $photoAsrChars  = 0
  foreach ($pu in $photoUnits) {
    $photoTextChars += ([string]$pu.vlm_description).Length + ([string]$pu.libelle_effectif).Length + ([string]$pu.commentaire_effectif).Length + ([string]$pu.dictee_photo).Length
    $ac = $pu.asr_context
    if ($null -ne $ac -and $ac.ContainsKey('chars')) { $photoAsrChars += [int]$ac['chars'] }
  }
  $checks = @{
    photo_units_equal_expected = ([int]$material.photo_units_count -eq [int]$ExpectedAffected)
    excluded_skipped_equal_expected = ([int]$material.excluded_skipped -eq [int]$ExpectedExcluded)
    no_duplicate_photo = (@($material.duplicate_photo_ids).Count -eq 0)
    general_segments_present = ([int]$material.general_segments_count -gt 0)
    totals_coherent = ([int]$material.total_input_units -eq ([int]$material.general_segments_count + [int]$material.photo_units_count))
    expected_affected = [int]$ExpectedAffected
    expected_excluded = [int]$ExpectedExcluded
    photos_hors_segments_observed = [int]$material.photos_hors_segments
    photo_coverage_sums = ([int]$material.photo_units_with_segment + [int]$material.photo_units_in_asr_gap + [int]$material.photo_units_after_asr + [int]$material.photo_units_before_asr -eq [int]$material.photo_units_count)
    photo_units_with_segment_observed = [int]$material.photo_units_with_segment
    photo_units_in_asr_gap_observed = [int]$material.photo_units_in_asr_gap
    photo_units_after_asr_observed = [int]$material.photo_units_after_asr
  }
  $ok = $true
  foreach ($ck in @($checks.Keys)) {
    if ($ck -in @('expected_affected','expected_excluded','photos_hors_segments_observed','photo_units_with_segment_observed','photo_units_in_asr_gap_observed','photo_units_after_asr_observed')) { continue }
    if (-not [bool]$checks[$ck]) { $ok = $false; $script:CriticalQaWarnings.Add('[Pass2B_2F] check KO: ' + $ck) | Out-Null }
  }
  Write-CrInfo ('Pass2B_2F couverture photos : avec_segment=' + [int]$material.photo_units_with_segment + ' trou_asr=' + [int]$material.photo_units_in_asr_gap + ' apres_fin_asr=' + [int]$material.photo_units_after_asr + ' avant_asr=' + [int]$material.photo_units_before_asr + ' (asr_end_sec=' + [double]$material.asr_end_sec + ')')
  $manifestFile = Write-Pass2B2FArtifacts -Material $material -Pack $pack -OutDir $OutDir -SegmentsDir $SegmentsDir -Budget $histBudget -ModelAlias $ModelAlias -Checks $checks -StartedAt $StartedAt
  return @{
    summary = @{
      ok = $ok
      general_segments_count = [int]$material.general_segments_count
      photo_units_count = [int]$material.photo_units_count
      subjects_with_photos_count = [int]$material.subjects_with_photos_count
      subjects_with_photos = @($material.subjects_with_photos)
      photos_hors_segments = [int]$material.photos_hors_segments
      photo_units_with_segment = [int]$material.photo_units_with_segment
      photo_units_in_asr_gap = [int]$material.photo_units_in_asr_gap
      photo_units_after_asr = [int]$material.photo_units_after_asr
      photo_units_before_asr = [int]$material.photo_units_before_asr
      asr_start_sec = [double]$material.asr_start_sec
      asr_end_sec = [double]$material.asr_end_sec
      excluded_skipped = [int]$material.excluded_skipped
      photo_text_chars = $photoTextChars
      photo_asr_text_chars = $photoAsrChars
      total_input_units = [int]$material.total_input_units
      batches_count = [int]$pack.batches_count
      oversized = @($pack.oversized)
      checks = $checks
      manifest = $manifestFile
      alias = $ModelAlias
      budget = $histBudget
    }
    material = $material
    pack = $pack
    manifest = $manifestFile
  }
}

function Resolve-GeneralistSegmentsDir {
  <#
    Decouverte du dossier segments du run CR generaliste : parmi les runs de
    <compte_rendu_LLM>\out\, preference au run dont global_meeting.json a le
    meme sha256 que le global_meeting.json de la racine (source de verite).
  #>
  param([string] $CompteRenduDir)
  if (-not $CompteRenduDir -or -not (Test-Path -LiteralPath $CompteRenduDir -PathType Container)) { return '' }
  $outRoot = Join-Path $CompteRenduDir 'out'
  if (-not (Test-Path -LiteralPath $outRoot -PathType Container)) { return '' }
  $runs = @(Get-ChildItem -LiteralPath $outRoot -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'segments') -PathType Container })
  if ($runs.Count -eq 0) { return '' }
  $rootGm = Join-Path $CompteRenduDir 'global_meeting.json'
  if (Test-Path -LiteralPath $rootGm -PathType Leaf) {
    $rootSha = Get-FileSha256 $rootGm
    foreach ($r in $runs) {
      $rGm = Join-Path $r.FullName 'global_meeting.json'
      if (Test-Path -LiteralPath $rGm -PathType Leaf) {
        $rSha = Get-FileSha256 $rGm
        if ($rSha -eq $rootSha) { return (Join-Path $r.FullName 'segments') }
      }
    }
  }
  if ($runs.Count -eq 1) { return (Join-Path $runs[0].FullName 'segments') }
  $sorted = @($runs | Sort-Object Name -Descending)
  return (Join-Path $sorted[0].FullName 'segments')
}
function Get-CrTimestampStamp {
  return (Get-Date -Format 'yyyyMMdd_HHmmss')
}

function Add-CrOutputFile {
  param([string] $Path)
  if (-not $Path) { return }
  $script:FilesWritten = @($script:FilesWritten) + $Path
}

function Get-SubjectPlanSlim {
  param($Plan)
  $slimChunks = New-Object System.Collections.ArrayList
  foreach ($ch in @($Plan.chunks)) {
    $slimChunks.Add(@{
      chunk_index=[int]$ch.chunk_index
      chunk_total=[int]$ch.chunk_total
      unit_indices=@($ch.unit_indices)
      units_count=[int]$ch.units_count
      photos_count=[int]$ch.photos_count
      data_chars_est=[int]$ch.data_chars_est
      prompt_chars=[int]$ch.prompt_chars
      prompt_tokens_est=[int]$ch.prompt_tokens_est
      input_tokens_est=[int]$ch.input_tokens_est
      available_tokens=[int]$ch.available_tokens
      available_input_tokens=[int]$ch.available_input_tokens
      output_tokens_est=[int]$ch.output_tokens_est
      available_output_tokens=[int]$ch.available_output_tokens
      output_budget_ok=[bool]$ch.output_budget_ok
      split_reason=[string]$ch.split_reason
      enforce_required=[bool]$ch.enforce_required
    }) | Out-Null
  }
  return @{
    numero=[int]$Plan.numero
    titre=[string]$Plan.titre
    localisation=[string]$Plan.localisation
    description=[string]$Plan.description
    budget=$Plan.budget
    available_tokens=[int]$Plan.available_tokens
    available_output_tokens=[int]$Plan.available_output_tokens
    hard_chars=[int]$Plan.hard_chars
    target_data_chars=[int]$Plan.target_data_chars
    unit_count_source=[int]$Plan.unit_count_source
    chunk_count=[int]$Plan.chunk_count
    chunks=@($slimChunks)
    oversized_units=@($Plan.oversized_units)
  }
}
function Write-SubjectArtifacts {
  <#
    Ecrit pour un sujet : prepared\subject_XXX_units.json,
    plans\subject_XXX_chunk_plan.json et chunks\subject_XXX_chunk_YYY_input.json.
    Les inputs LLM (dry-run) sont prepares mais JAMAIS appeles.
    (LOT 2F-6C2C5 : tracabilite double budget ajoutee au chunk input.)
  #>
  param(
    [hashtable] $Stream,
    [hashtable] $Plan,
    [string]    $OutDir,
    [string]    $IdAffaire,
    [string]    $IdCaptation
  )
  $n3 = '{0:D3}' -f ([int]$Plan.numero)
  $unitsFile = Join-Path $OutDir ('prepared\subject_' + $n3 + '_units.json')
  Write-CrJsonAtomic -Path $unitsFile -Obj $Stream
  Add-CrOutputFile $unitsFile

  $planFile = Join-Path $OutDir ('plans\subject_' + $n3 + '_chunk_plan.json')
  $planDoc  = Get-SubjectPlanSlim -Plan $Plan
  Write-CrJsonAtomic -Path $planFile -Obj $planDoc
  Add-CrOutputFile $planFile

  $ci = 0
  foreach ($ch in @($Plan.chunks)) {
    $ci++
    $n2 = '{0:D2}' -f ([int]$ch.chunk_index)
    $inputObj = @{
      schema = 'cr_refere_preventif.pass2f.chunk_input.v1'
      source_pass = '2F'
      id_affaire = $IdAffaire
      id_captation = $IdCaptation
      dry_run = $true
      execute_llm = $false
      chunk_index = [int]$ch.chunk_index
      chunk_total = [int]$ch.chunk_total
      photos_count = [int]$ch.photos_count
      output_budget_ok = [bool]$ch.output_budget_ok
      split_reason = [string]$ch.split_reason
      sujet_cible = @{ numero=[int]$Plan.numero; titre=[string]$Plan.titre; localisation=[string]$Plan.localisation; description=[string]$Plan.description }
      budget = $Plan.budget
      prompt = @{
        chars = [int]$ch.prompt_chars
        tokens_est = [int]$ch.prompt_tokens_est
        input_tokens_est = [int]$ch.input_tokens_est
        available_tokens = [int]$ch.available_tokens
        available_input_tokens = [int]$ch.available_input_tokens
        output_tokens_est = [int]$ch.output_tokens_est
        available_output_tokens = [int]$ch.available_output_tokens
        enforce_required = [bool]$ch.enforce_required
        message = [string]$ch.message
      }
      data = $ch.data
    }
    $inputFile = Join-Path $OutDir ('chunks\subject_' + $n3 + '_chunk_' + $n2 + '_input.json')
    Write-CrJsonAtomic -Path $inputFile -Obj $inputObj
    Add-CrOutputFile $inputFile
  }
}
function Write-CrRunLog {
  param([string] $OutDir, [string] $Label)
  $logDir = Join-Path $OutDir 'logs'
  Ensure-Dir $logDir
  $stamp = Get-CrTimestampStamp
  $script:LogFile = Join-Path $logDir ('run_' + $stamp + '.log')
  if ($Label) { Add-CrLogLine ('job_label=' + $Label) }
  Add-CrLogLine ('pipeline=' + $script:PipelineName + ' schema=' + $script:SchemaVersion + ' dry_run=' + [bool]$DryRun + ' execute_llm=' + [bool]$ExecuteLlm)
  return $script:LogFile
}

function New-CrSourceEntry {
  param([string] $Role, [string] $Path)
  $ok = Test-Path -LiteralPath $Path -PathType Leaf
  return @{
    role=$Role
    path=$Path
    present=$ok
    sha256=$(if ($ok) { Get-FileSha256 $Path } else { $null })
    size_bytes=$(if ($ok) { (Get-Item -LiteralPath $Path).Length } else { 0 })
  }
}

function Write-CrManifestJson {
  param(
    [hashtable] $Ctx,
    [hashtable] $Perimeter,
    [object[]]  $PerSubject,
    [hashtable] $Totals,
    [string]    $OutDir,
    [string]    $StartedAt,
    [int]       $ExitCode,
    [bool]      $Success,
    [string]    $LotLabel = '2F-6C2B',
    [int]       $LlmCalls = 0,
    [int]       $HttpCalls = 0,
    [object[]]  $LlmCallEntries = @(),
    [object]    $ModelInfoProbe = $null
  )
  $stamp = Get-CrTimestampStamp
  $sources = @(
    (New-CrSourceEntry -Role 'infos_projet.json' -Path $Ctx.paths.InfosProjetPath),
    (New-CrSourceEntry -Role 'config_llm.json' -Path $Ctx.paths.ConfigLlmPath),
    (New-CrSourceEntry -Role 'Sujets.csv' -Path $Ctx.paths.SujetsCsvPath),
    (New-CrSourceEntry -Role 'ASR complet' -Path $Ctx.asr_csv),
    (New-CrSourceEntry -Role 'photos.csv' -Path $Ctx.paths.PhotosCsvPath),
    (New-CrSourceEntry -Role 'photos_batch.csv' -Path $Ctx.paths.PhotosBatchCsvPath),
    (New-CrSourceEntry -Role 'photo_subject_assignments.json' -Path $Ctx.paths.AssignmentsJsonPath)
  )
  $manifest = @{
    schema_version = 'cr_refere_preventif.manifest.v1'
    pipeline = $script:PipelineName
    lot = $LotLabel
    job_label = $JobLabel
    dry_run = [bool]$DryRun
    execute_llm = [bool]($LlmCalls -gt 0)
    llm_calls = $LlmCalls
    http_calls = $HttpCalls
    llm_entries = @($LlmCallEntries)
    model_info_probe = $ModelInfoProbe
    id_affaire = $Ctx.paths.IdAffaire
    id_captation = $Ctx.paths.IdCaptation
    data_root = $Ctx.paths.DataRoot
    out_dir = $OutDir
    started_at = $StartedAt
    finished_at = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
    budget_pass2f = $script:BudgetPass2F
    asr_window_config = @{
      source = $Ctx.asr_window.source_file
      resolved_from = $Ctx.asr_window.source
      commentaire_before = $Ctx.asr_window.before_sec
      commentaire_after = $Ctx.asr_window.after_sec
      hardcoded = $false
    }
    sources = $sources
    cr_generaliste_inputs = @($Ctx.cr_json_generaliste)
    perimeter = $Perimeter
    per_subject = $PerSubject
    totals = $Totals
    enforce_required_total = [int]$Totals.enforce_required_total
    critical_qa_warnings = @($script:CriticalQaWarnings)
    functional_inputs = @($script:FunctionalInputs)
    files_written = @($script:FilesWritten)
    exit_code = $ExitCode
    status = $(if ($Success) { 'OK' } else { 'FAILED' })
  }
  $manifestFile = Join-Path $OutDir 'manifest.json'
  Write-CrJsonAtomic -Path $manifestFile -Obj $manifest
  Add-CrOutputFile $manifestFile
  return $manifestFile
}

function Write-CrErrorManifest {
  param(
    [string] $OutDir,
    [string] $StartedAt,
    [string] $ErrorMessage,
    [string] $LotLabel = '2F-6C2B',
    [int]    $LlmCalls = 0,
    [int]    $HttpCalls = 0,
    [object[]] $LlmCallEntries = @(),
    [object]   $Extra = $null
  )
  if (-not $OutDir) { return }
  try {
    Ensure-Dir $OutDir
    $m = @{
      schema_version='cr_refere_preventif.manifest.v1'
      pipeline=$script:PipelineName
      lot=$LotLabel
      job_label=$JobLabel
      dry_run=[bool]$DryRun
      execute_llm=[bool]($LlmCalls -gt 0)
      llm_calls=$LlmCalls
      http_calls=$HttpCalls
      llm_entries=@($LlmCallEntries)
      status='FAILED'
      started_at=$StartedAt
      finished_at=(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
      error=$ErrorMessage
      exit_code=1
    }
    if ($null -ne $Extra) { foreach ($ek in @($Extra.Keys)) { $m[$ek] = $Extra[$ek] } }
    Write-CrJsonAtomic -Path (Join-Path $OutDir 'manifest.json') -Obj $m
  } catch { }
}

# ===========================================================================
# LOT 2B2F-12 : autotest deterministe SANS LLM de la trace du manifest d'erreur
# (Write-CrErrorManifest doit recevoir le vrai LotLabel et les compteurs reels).
# ===========================================================================
if ($TestPass2B2FErrorManifestTrace) {
  $tfFails = New-Object System.Collections.ArrayList
  $tOutDir = $OutDir
  if (-not $tOutDir) {
    $tOutDir = Join-Path ([System.IO.Path]::GetTempPath()) ('cr_refere_errmanifest_' + (Get-CrTimestampStamp))
  }
  $tLot = '2B2F-12'
  if ($Pass2B2FLotLabel) { $tLot = [string]$Pass2B2FLotLabel }
  $tEntry = @{
    step = 'consolidation_intermediaire'
    lot = $tLot
    alias = 'report_remote'
    status = 'consolidation_ok'
    http_status = 200
    duree_sec = 1.1
    finish_reason = 'stop'
    response_chars = 100
    json_parse_ok = $true
    error = $null
    retries = 0
  }
  Write-CrErrorManifest -OutDir $tOutDir -StartedAt (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK') -ErrorMessage 'erreur synthetique pour autotest trace' -LotLabel $tLot -LlmCalls 1 -HttpCalls 1 -LlmCallEntries @($tEntry) -Extra @{ totals = @{ pass2b2f = @{ ok = $false; lot = $tLot } } }
  $tManifestPath = Join-Path $tOutDir 'manifest.json'
  if (-not (Test-Path -LiteralPath $tManifestPath -PathType Leaf)) {
    [void]$tfFails.Add('manifest d erreur absent : ' + $tManifestPath)
  } else {
    $tObj = Read-JsonFile -Path $tManifestPath
    if ([string]$tObj['lot'] -ne $tLot) { [void]$tfFails.Add('lot attendu ' + $tLot + ' recu ' + [string]$tObj['lot']) }
    if ([int]$tObj['llm_calls'] -ne 1) { [void]$tfFails.Add('llm_calls attendu 1 recu ' + [string]$tObj['llm_calls']) }
    if ([int]$tObj['http_calls'] -ne 1) { [void]$tfFails.Add('http_calls attendu 1 recu ' + [string]$tObj['http_calls']) }
    if (-not [bool]$tObj['execute_llm']) { [void]$tfFails.Add('execute_llm attendu true') }
    if (@($tObj['llm_entries']).Count -lt 1) { [void]$tfFails.Add('llm_entries vide dans le manifest d erreur') }
    if (-not $tObj.ContainsKey('totals')) { [void]$tfFails.Add('totals absent du manifest d erreur') }
    if ([string]$tObj['status'] -ne 'FAILED') { [void]$tfFails.Add('status attendu FAILED recu ' + [string]$tObj['status']) }
    if ([int]$tObj['exit_code'] -ne 1) { [void]$tfFails.Add('exit_code attendu 1 recu ' + [string]$tObj['exit_code']) }
  }
  Write-CrInfo ('Autotest Pass2B_2F trace manifest d erreur : fails=' + @($tfFails).Count)
  foreach ($fx in @($tfFails)) { Write-CrErr $fx }
  if (@($tfFails).Count -gt 0) { exit 1 }
  Write-CrInfo 'Autotest Pass2B_2F trace manifest d erreur : OK (lot, compteurs, llm_entries, totals propages).'
  exit 0
}

# ============================================================================
# ============================================================================
# LLM Pass2F - LOT 2F-6C2C : corps HTTP ACTIVE pour pass2f_local
# ----------------------------------------------------------------------------
# Reutilise le schema audite en 2F-6C2A (cr_reunion_point_mumerotes_pipeline_json.ps1) :
#   endpoint OpenAI-compat {ApiBase}/v1/chat/completions, alias pass2f_local,
#   temperature 0.2, max_tokens issu du budget, AUCUN fallback d'alias.
# Tous les retries HTTP sont traces dans CriticalQaWarnings (jamais silencieux).
# En mode DryRun (2F-6C2B), ces fonctions restent bloquees via $script:HttpBlocked.
# [REUSE cr_reunion_point_mumerotes_pipeline_json.ps1 - Invoke-LLM-OpenAICompat /
#  Invoke-LLM / Parse-LlmJsonStrict : conventions auditees en 2F-6C2A]
# ============================================================================
function Measure-EchoRatio {
  param([string] $Text, [string] $Reference)
  if ([string]::IsNullOrWhiteSpace($Text)) { return 0.0 }
  $refWords = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($w in [regex]::Matches($Reference.ToLowerInvariant(), '[a-z0-9_]{4,}')) { [void]$refWords.Add($w.Value) }
  $words = [regex]::Matches($Text.ToLowerInvariant(), '[a-z0-9_]{4,}')
  $tot = $words.Count
  if ($tot -eq 0) { return 0.0 }
  $hit = 0
  foreach ($w in $words) { if ($refWords.Contains($w.Value)) { $hit++ } }
  return [math]::Round(([double]$hit / [double]$tot), 4)
}

function Invoke-LLM-OpenAICompat {
  param(
    [string] $Endpoint = '',
    [object] $Body = $null,
    [int]    $TimeoutSec = 900,
    [int]    $MaxRetries = 0
  )
  if (-not $Endpoint) { throw '[cr_refere_preventif] Invoke-LLM-OpenAICompat : Endpoint vide.' }
  if ($script:HttpBlocked) { throw '[cr_refere_preventif] Invoke-LLM-OpenAICompat bloque en mode DryRun.' }
  $headers = @{ 'Content-Type' = 'application/json' }
  if ($script:AdapterApiKey) { $headers['Authorization'] = 'Bearer ' + $script:AdapterApiKey }
  $bodyJson = $Body | ConvertTo-Json -Depth 100 -Compress
  $lastErr = $null
  for ($attempt = 0; $attempt -le $MaxRetries; $attempt++) {
    if ($attempt -gt 0) {
      $script:CriticalQaWarnings.Add(('[cr_refere_preventif] retry HTTP ' + $attempt + '/' + $MaxRetries + ' endpoint ' + $Endpoint)) | Out-Null
      Start-Sleep -Seconds (3 * $attempt)
    }
    try {
      $resp = Invoke-RestMethod -Method POST -Uri $Endpoint -Headers $headers -Body $bodyJson -ContentType 'application/json' -TimeoutSec $TimeoutSec -ErrorAction Stop
      $script:LastHttpStatus = 200
      return $resp
    } catch {
      $lastErr = $_.Exception.Message
      $script:LastHttpStatus = 0
      try {
        $httpResp = $_.Exception.Response
        if ($null -ne $httpResp -and $null -ne $httpResp.StatusCode) { $script:LastHttpStatus = [int]$httpResp.StatusCode }
      } catch { }
    }
  }
  throw ('[cr_refere_preventif] HTTP ECHEC apres retries (' + $MaxRetries + ') : ' + $lastErr)
}

function Invoke-LLM {
  param(
    [string] $Alias = 'pass2f_local',
    [string] $SystemPrompt = '',
    [string] $UserPrompt = '',
    [int]    $MaxTokens = 0,
    [double] $Temperature = 0.2
  )
  if ($script:HttpBlocked) { throw '[cr_refere_preventif] Invoke-LLM bloque en mode DryRun.' }
  if (-not $script:AdapterApiBase) { throw '[cr_refere_preventif] Invoke-LLM : AdapterApiBase non initialise.' }
  $endpoint = $script:AdapterApiBase.TrimEnd('/') + '/v1/chat/completions'
  # Message utilisateur AUTONOME (prompt 6B) : l'adapter local ne transmet que le
  # message user ; un systeme separe serait ignore (constat lots 2F-6A/6B).
  $content = $UserPrompt
  if ($SystemPrompt) { $content = $SystemPrompt + [Environment]::NewLine + $UserPrompt }
  $body = @{
    model = $Alias
    messages = @( @{ role = 'user'; content = $content } )
    temperature = $Temperature
    max_tokens = $MaxTokens
    stream = $false
  }
  $resp = Invoke-LLM-OpenAICompat -Endpoint $endpoint -Body $body -TimeoutSec $script:LlmTimeoutSec -MaxRetries 0
  return $resp
}

function Parse-LlmJsonStrict {
  param([string] $Raw)
  if ([string]::IsNullOrWhiteSpace($Raw)) { throw '[cr_refere_preventif] Parse-LlmJsonStrict : reponse vide.' }
  $body = $Raw.Trim()
  $fence = [string][char]96 * 3
  if ($body.StartsWith($fence)) {
    $nlIdx = $body.IndexOf([char]10)
    if ($nlIdx -ge 0) { $body = $body.Substring($nlIdx + 1) }
    $body = $body.TrimEnd()
    if ($body.EndsWith($fence)) { $body = $body.Substring(0, $body.Length - 3).TrimEnd() }
  }
  $a = $body.IndexOf('{')
  $z = $body.LastIndexOf('}')
  if ($a -lt 0 -or $z -le $a) { throw '[cr_refere_preventif] Parse-LlmJsonStrict : aucun objet JSON trouve dans la reponse.' }
  $cand = $body.Substring($a, $z - $a + 1)
  $obj = $cand | ConvertFrom-Json -ErrorAction Stop
  if ($null -eq $obj) { throw '[cr_refere_preventif] Parse-LlmJsonStrict : JSON null.' }
  return $obj
}

function Invoke-ProbeModelInfo {
  param([string] $ApiBase)
  $attempts = New-Object System.Collections.ArrayList
  $baseClean = $ApiBase.TrimEnd('/')
  $candidates = @( ($baseClean + '/model_info'), ($baseClean + '/v1/models'), ($baseClean + '/models') )
  $found = $false
  $nctxVal = $null
  $probeFullJson = ''
  foreach ($url in $candidates) {
    $attempt = @{ url = $url; http_status = 0; error = $null; info_json = '' }
    if ($script:HttpBlocked) {
      $attempt.error = 'dry_run_no_http'
    } else {
      try {
        $headers = @{}
        if ($script:AdapterApiKey) { $headers['Authorization'] = 'Bearer ' + $script:AdapterApiKey }
        $r = Invoke-RestMethod -Method GET -Uri $url -Headers $headers -TimeoutSec 20 -ErrorAction Stop
        $attempt.http_status = 200
        try { $fullJson = ($r | ConvertTo-Json -Depth 40 -Compress) } catch { $fullJson = '' }
        $probeFullJson = [string]$fullJson
        if ($probeFullJson) { $attempt.info_json = $probeFullJson.Substring(0, [Math]::Min(4000, $probeFullJson.Length)) }
      } catch {
        $attempt.error = $_.Exception.Message
        try {
          $httpResp = $_.Exception.Response
          if ($null -ne $httpResp -and $null -ne $httpResp.StatusCode) { $attempt.http_status = [int]$httpResp.StatusCode }
        } catch { }
      }
    }
    [void]$attempts.Add($attempt)
    if ($probeFullJson -match '"n_ctx"\s*[:=]\s*"?(\d+)') { $nctxVal = [int]$Matches[1]; $found = $true }
    elseif ($probeFullJson -match '"context_length"\s*[:=]\s*"?(\d+)') { $nctxVal = [int]$Matches[1]; $found = $true }
    elseif ($probeFullJson -match '"max_context"\s*[:=]\s*"?(\d+)') { $nctxVal = [int]$Matches[1]; $found = $true }
    if ($found) { break }
  }
  return @{
    probes_attempted = @($attempts).Count
    n_ctx_confirmed = $found
    n_ctx = $nctxVal
    endpoint_probed = $baseClean
    model_alias = $script:AdapterAlias
    attempts = @($attempts)
  }
}


# =============================================================================
# REFERE-E2E-3E : Pass2F voie remote passthrough + retry JSON unique.
# -----------------------------------------------------------------------------
# - Resolve-Pass2FModelRoute : l'alias LOGIQUE 'pass2f_remote' est traduit en
#   modele de routage BRUT 'gpt-4o-mini'. Ce modele n'est JAMAIS ajoute au
#   MODEL_REGISTRY de l'adapter : il transite par le chemin passthrough brut
#   (aucune reparation silencieuse, aucune normalisation, aucun fallback).
# - Le retry unique vit dans Invoke-Pass2FChunkAndRecord et reste
#   alias-agnostique (identique pour local et remote).
# =============================================================================
function Resolve-Pass2FModelRoute {
  param([string] $ModelPass2F)
  $alias = ([string]$ModelPass2F).Trim()
  if (-not $alias) { return 'pass2f_local' }
  if ($alias -eq 'pass2f_remote') { return 'gpt-4o-mini' }
  return $alias
}

# Consigne technique ajoutee UNIQUEMENT au 2e appel (retry). Aucune demande de
# "reparer une position precise" ; le modele reproduit sa reponse en JSON strict.
$script:Pass2FRetryInstruction = "LA REPONSE PRECEDENTE N'ETAIT PAS UN JSON SYNTACTIQUEMENT VALIDE. REPRODUIS LA REPONSE POUR LES MEMES DONNEES, EXCLUSIVEMENT EN JSON STRICT CONFORME AU SCHEMA DEMANDE. AUCUN MARKDOWN NI TEXTE HORS JSON."
function Invoke-Pass2FChunkAndRecord {
  param(
    [hashtable] $Chunk,
    [hashtable] $Plan,
    [string]    $OutDir,
    [int]       $MaxTokens,
    [double]    $Temperature,
    [string]    $AliasLogique = "",
    [string[]]  $OfflineRawResponses = @()
  )
  $n3 = '{0:D3}' -f ([int]$Plan.numero)
  $ci = [int]$Chunk.chunk_index
  $n2 = '{0:D2}' -f $ci
  $tag = 'subject_' + $n3 + '_chunk_' + $n2
  $inputsDir  = Join-Path $OutDir 'inputs'
  $rawDir     = Join-Path $OutDir 'raw_responses'
  $parsedDir  = Join-Path $OutDir 'parsed_outputs'
  Ensure-Dir $inputsDir
  Ensure-Dir $rawDir
  Ensure-Dir $parsedDir
  $message = [string]$Chunk.message
  $inputObj = @{
    schema = 'cr_refere_preventif.pass2f.chunk_input.v1'
    source_pass = '2F'
    lot = '2F-6C2C'
    execute_llm = $true
    chunk_index = $ci
    chunk_total = [int]$Chunk.chunk_total
    photos_count = [int]$Chunk.photos_count
    output_budget_ok = [bool]$Chunk.output_budget_ok
    split_reason = [string]$Chunk.split_reason
    sujet_cible = @{ numero = [int]$Plan.numero; titre = [string]$Plan.titre; localisation = [string]$Plan.localisation; description = [string]$Plan.description }
    budget = $Plan.budget
    prompt = @{ chars = $message.Length; tokens_est = [int]$Chunk.prompt_tokens_est; input_tokens_est = [int]$Chunk.input_tokens_est; available_tokens = [int]$Chunk.available_tokens; available_input_tokens = [int]$Chunk.available_input_tokens; output_tokens_est = [int]$Chunk.output_tokens_est; available_output_tokens = [int]$Chunk.available_output_tokens; output_budget_ok = [bool]$Chunk.output_budget_ok; enforce_required = [bool]$Chunk.enforce_required }
    data = $Chunk.data
  }
  $inputFile = Join-Path $inputsDir ($tag + '_input.json')
  Write-CrJsonAtomic -Path $inputFile -Obj $inputObj
  Add-CrOutputFile $inputFile
  $entry = @{
    tag = $tag
    subject_numero = [int]$Plan.numero
    chunk_index = $ci
    chunk_total = [int]$Chunk.chunk_total
    alias_logique = $script:AdapterAlias
    temperature = $Temperature
    max_tokens = $MaxTokens
    http_status = 0
    error = $null
    duree_sec = 0.0
    finish_reason = $null
    usage = $null
    prompt_chars = $message.Length
    response_chars = 0
    echo_ratio = 0.0
    json_parse_ok = $false
    truncated_or_invalid_response = $false
    missing_keys = @()
    extra_keys = @()
    parse_error = $null
    raw_file = ''
    parsed_file = ''
    model_alias = ''
    attempt_count = 0
    retry_reason = $null
    attempt_1_json_parse_ok = $false
    attempt_2_json_parse_ok = $false
    final_json_parse_ok = $false
    actual_llm_calls = 0
    actual_http_calls = 0
    raw_files = @()
    units_count = [int]$Chunk.units_count
    photos_count = [int]$Chunk.photos_count
    photos = @()
    prompt_tokens_est = [int]$Chunk.prompt_tokens_est
    input_tokens_est = [int]$Chunk.input_tokens_est
    available_tokens = [int]$Chunk.available_tokens
    available_input_tokens = [int]$Chunk.available_input_tokens
    output_tokens_est = [int]$Chunk.output_tokens_est
    available_output_tokens = [int]$Chunk.available_output_tokens
    output_budget_ok = [bool]$Chunk.output_budget_ok
    split_reason = [string]$Chunk.split_reason
    enforce_required = [bool]$Chunk.enforce_required
  }
  $photosList = New-Object System.Collections.ArrayList
  foreach ($u in @($Chunk.data.sequence_documentaire)) {
    if ($u.kind -eq 'photo' -and $u.photo) { [void]$photosList.Add([string]$u.photo) }
  }
  $entry.photos = @($photosList)
  # REFERE-E2E-3E : voie reelle (local ou remote passthrough) + retry JSON unique.
  $routeModel = [string]$script:AdapterAlias
  if (-not $AliasLogique) { $AliasLogique = $routeModel }
  $entry.model_alias = $routeModel
  $entry.alias_logique = $AliasLogique
  $rawFilesList = New-Object System.Collections.ArrayList
  $retryReason = $null
  $lastRaw = ''
  $attempt1Ok = $false
  $attempt2Ok = $false
  $attemptsTotal = 0
  for ($attempt = 1; $attempt -le 2; $attempt++) {
    $attemptsTotal = $attempt
    $entry.attempt_count = $attempt
    $t0 = Get-Date
    $attemptMessage = $message
    if ($attempt -gt 1) {
      $attemptMessage = $message + "`n`n" + [string]$script:Pass2FRetryInstruction
    }
    $raw = ''
    $parseOkNow = $false
    $entry.parse_error = $null
    try {
      if (@($OfflineRawResponses).Count -gt 0) {
        # Mode TEST HORS LIGNE (REFERE-E2E-3E) : aucune requete LLM/HTTP reelle.
        if ($attempt -gt @($OfflineRawResponses).Count) {
          throw ('entree offline absente pour attempt ' + $attempt)
        }
        $entry.http_status = 200
        $entry.finish_reason = 'stop'
        $raw = [string]@($OfflineRawResponses)[$attempt - 1]
        $entry.duree_sec = 0.0
        $entry.usage = $null
      } else {
        $resp = Invoke-LLM -Alias $routeModel -SystemPrompt '' -UserPrompt $attemptMessage -MaxTokens $MaxTokens -Temperature $Temperature
        $entry.duree_sec = [math]::Round(((Get-Date) - $t0).TotalSeconds, 2)
        $entry.http_status = $script:LastHttpStatus
        if ($null -eq $resp -or $null -eq $resp.choices -or $null -eq $resp.choices[0] -or $null -eq $resp.choices[0].message) {
          throw 'reponse LLM sans choices[0].message.'
        }
        $ch0 = $resp.choices[0]
        $raw = [string]$ch0.message.content
        $respFinishReason = $null
        if ($null -ne $ch0.PSObject.Properties['finish_reason']) { $respFinishReason = $ch0.PSObject.Properties['finish_reason'].Value }
        if ($null -ne $respFinishReason) { $entry.finish_reason = [string]$respFinishReason }
        $respUsage = $null
        if ($null -ne $resp.PSObject.Properties['usage']) { $respUsage = $resp.PSObject.Properties['usage'].Value }
        $entry.usage = $respUsage
      }
      $entry.actual_llm_calls = $attemptsTotal
      $entry.actual_http_calls = $attemptsTotal
      $entry.response_chars = $raw.Length
      $lastRaw = $raw
      $rawAttemptFile = Join-Path $rawDir ($tag + '_raw_attempt_' + $attempt + '.txt')
      Write-CrTextUtf8NoBom -Path $rawAttemptFile -Text $raw
      Add-CrOutputFile $rawAttemptFile
      [void]$rawFilesList.Add($rawAttemptFile)
      try {
        $parsed = Parse-LlmJsonStrict -Raw $raw
        if ($null -ne $parsed) {
          $parseOkNow = $true
          $entry.json_parse_ok = $true
          $keys = @($parsed.psobject.Properties.Name)
          $schemaKeys = @('schema_version','source_pass','subject_numero','synthese_intermediaire','points_documentes','incertitudes','photo_contexts')
          $entry.missing_keys = @($schemaKeys | Where-Object { $_ -notin $keys })
          $entry.extra_keys = @($keys | Where-Object { $_ -notin $schemaKeys })
          $parsedFile = Join-Path $parsedDir ($tag + '_response.json')
          Write-CrJsonAtomic -Path $parsedFile -Obj $parsed
          Add-CrOutputFile $parsedFile
          $entry.parsed_file = $parsedFile
          if ($null -ne $parsed.subject_numero) { $entry.subject_repond = [int]$parsed.subject_numero }
        }
      } catch {
        $entry.parse_error = $_.Exception.Message
      }
    } catch {
      $entry.error = $_.Exception.Message
      try { $entry.duree_sec = [math]::Round(((Get-Date) - $t0).TotalSeconds, 2) } catch { }
      break
    }    if ($attempt -eq 1) { $attempt1Ok = $parseOkNow } else { $attempt2Ok = $parseOkNow }
    if ($attempt -eq 1 -and $parseOkNow) { break }
    if ($attempt -eq 1 -and (-not $parseOkNow) -and [int]$entry.http_status -eq 200 -and $entry.response_chars -gt 0 -and (-not $entry.error)) {
      $retryReason = 'invalid_json_attempt_1'
      $entry.retry_reason = $retryReason
      $fr = 'N/A'
      if ($null -ne $entry.finish_reason) { $fr = [string]$entry.finish_reason }
      Write-CrWarn ('[REFERE-E2E-3E] chunk ' + $tag + ' : attempt 1 JSON invalide (chars=' + [string]$entry.response_chars + ' finish=' + $fr + ') -> retry unique alias=' + $routeModel + '.')
      Add-CrLogLine ('pass2f_retry tag=' + $tag + ' reason=' + $retryReason + ' alias=' + $routeModel)
      continue
    }
    if ($attempt -eq 1) {
      # 1er appel HTTP KO ou contenu vide : aucun retry (comportement 2F-6C2C5).
      break
    }
  }
  $entry.attempt_1_json_parse_ok = $attempt1Ok
  $entry.attempt_2_json_parse_ok = $attempt2Ok
  $entry.final_json_parse_ok = [bool]$entry.json_parse_ok
  if ($retryReason) { $entry.retry_reason = $retryReason }
  $entry.raw_files = @($rawFilesList)
  if (@($rawFilesList).Count -gt 0) {
    $entry.raw_file = [string]@($rawFilesList)[@($rawFilesList).Count - 1]
  }
  # Copie de compatibilite *_raw.txt : dernier raw conserve (lecteurs historiques).
  if ($lastRaw.Length -gt 0) {
    $legacyRawFile = Join-Path $rawDir ($tag + '_raw.txt')
    Write-CrTextUtf8NoBom -Path $legacyRawFile -Text $lastRaw
    Add-CrOutputFile $legacyRawFile
    $entry.legacy_raw_file = $legacyRawFile
  }
  if ([int]$entry.http_status -eq 200 -and $entry.response_chars -gt 0 -and (-not [bool]$entry.json_parse_ok) -and (-not $entry.error)) {
    $entry.truncated_or_invalid_response = $true
    $fr = 'N/A'
    if ($null -ne $entry.finish_reason) { $fr = [string]$entry.finish_reason }
    [void]$script:CriticalQaWarnings.Add(('chunk ' + $tag + ' : JSON invalide apres retry unique (attempt_count=' + $attemptsTotal + ' response_chars=' + [string]$entry.response_chars + ' finish_reason=' + $fr + ') -> STOP (REFERE-E2E-3E) ; aucune reparation silencieuse.'))
  }
  $entry.echo_ratio = Measure-EchoRatio -Text $lastRaw -Reference $message
  return $entry
}
# ============================================================================
# Section 6 - Orchestration principale (DryRun 2F-6C2B / ExecuteLlm controle 2F-6C2C)
# ============================================================================
function Write-CrHighlightLine {
  param([string] $Subject, [string] $Line)
  if ($Subject -in @('2','6','17','20')) {
    Microsoft.PowerShell.Utility\Write-Host ('[HIGHLIGHT sujet ' + $Subject + '] ' + $Line) -ForegroundColor Magenta
  } else {
    Write-CrInfo $Line
  }
}

# ===========================================================================
# LOT 2B2F-8 : consolidation finale interne Pass2B_2F (max 1 appel LLM)
# ---------------------------------------------------------------------------
# Transforme :
#   441 unites rang 1
#     -> 36 sous-appels Pass2B_2F
#     -> merge deterministe exhaustif  refere_global_meeting_exhaustive.json
#     -> consolidation LLM GLOBALE interne a Pass2B_2F
#     -> refere_global_meeting.json (sortie canonique condensee pour 3A-D)
# La consolidation appartient a la MEME passe logique Pass2B_2F : elle ne
# consomme aucune sortie d'une autre passe de rang 2. Son entree est deja de
# la matiere Pass2B_2F structuree (JSON exhaustif), jamais de rang 1.
# ===========================================================================
function Invoke-Pass2B2FConsolidateFinal {
  param(
    [string] $OutDir,
    [string] $ExhaustiveJsonPath = "",
    [string] $ModelAlias = "report_remote",
    [string] $StartedAt = "",
    [string] $ApiBaseOverride = "",
    [string] $ApiKeyOverride = "",
    [string] $LotLabel = "2B2F-8",
    [switch] $ConsolidateLlm
  )
  $lot = ([string]$LotLabel).Trim()
  if (-not $lot) { $lot = '2B2F-8' }
  $lotNum = ($lot -split '-')[-1]
  if (-not $lotNum) { $lotNum = '8' }
  $p2dir = Join-Path $OutDir 'pass2b2f'
  Ensure-Dir $p2dir
  $consDir = Join-Path $p2dir ('pass2b2f' + $lotNum + '_consolidate')
  Ensure-Dir $consDir

  # --- 1. Localiser l'exhaustif (merge deterministe source de verite) -------
  $srcCand = ''
  if ($ExhaustiveJsonPath) {
    $srcCand = ([string]$ExhaustiveJsonPath).Trim()
  } else {
    $defaultCanon = Join-Path $p2dir 'refere_global_meeting.json'
    if (Test-Path -LiteralPath $defaultCanon -PathType Leaf) { $srcCand = $defaultCanon }
    else {
      $defaultExh = Join-Path $p2dir 'refere_global_meeting_exhaustive.json'
      if (Test-Path -LiteralPath $defaultExh -PathType Leaf) { $srcCand = $defaultExh }
    }
  }
  if (-not $srcCand -or -not (Test-Path -LiteralPath $srcCand -PathType Leaf)) {
    throw ('[cr_refere_preventif] LOT 2B2F-8 : JSON exhaustif introuvable (fournir -Pass2B2FExhaustiveJsonPath) : ' + [string]$srcCand)
  }
  $srcPath = [System.IO.Path]::GetFullPath($srcCand)
  Write-CrInfo ('Pass2B_2F LOT ' + $lot + ' consolidation finale : source exhaustive=' + $srcPath)
  Add-CrLogLine ('pass2b2f8_consolidate source=' + $srcPath)

  # --- 2. Preserver l'exhaustif (jamais detruit) -----------------------------
  $exhFile = Join-Path $p2dir 'refere_global_meeting_exhaustive.json'
  if ([System.IO.Path]::GetFullPath($exhFile) -ine $srcPath) {
    Copy-Item -LiteralPath $srcPath -Destination $exhFile -Force
    Write-CrInfo ('Pass2B_2F LOT ' + $lot + ' : exhaustive preserve -> ' + $exhFile)
    Add-CrOutputFile $exhFile
  }

  # --- 3. Lecture + validation de l'entree -----------------------------------
  $exhObj = Read-JsonFile -Path $srcPath
  $schemaKeys7 = @('resume_global','themes','themes_abordes','actions','perspectives','demandes_documents_globales','problems')
  $listKeys6 = @('themes','themes_abordes','actions','perspectives','demandes_documents_globales','problems')
  $inputKeys = @($exhObj.Keys)
  $missingKeys = @($schemaKeys7 | Where-Object { $_ -notin $inputKeys })
  $extraKeys = @($inputKeys | Where-Object { $_ -notin $schemaKeys7 })
  if (@($missingKeys).Count -gt 0) {
    throw ('[cr_refere_preventif] LOT 2B2F-8 : cles manquantes dans l''entree exhaustive : ' + ($missingKeys -join ','))
  }
  if (@($extraKeys).Count -gt 0) {
    throw ('[cr_refere_preventif] LOT 2B2F-8 : cles supplementaires non attendues dans l''entree exhaustive : ' + ($extraKeys -join ','))
  }
  $flatIssuesIn = New-Object System.Collections.ArrayList
  $nullCountIn = 0
  foreach ($k in $listKeys6) {
    foreach ($it in @($exhObj[$k])) {
      if ($null -eq $it) { $nullCountIn++ }
      elseif ($it -is [System.Array]) { [void]$flatIssuesIn.Add($k) }
    }
  }
  $countsBefore = @{
    resume_global_chars = ([string]$exhObj['resume_global']).Length
    themes = @($exhObj['themes']).Count
    themes_abordes = @($exhObj['themes_abordes']).Count
    actions = @($exhObj['actions']).Count
    perspectives = @($exhObj['perspectives']).Count
    demandes_documents_globales = @($exhObj['demandes_documents_globales']).Count
    problems = @($exhObj['problems']).Count
  }
  $oldResume = [string]$exhObj['resume_global']
  $inputDoc = @{
    schema_version = ('cr_refere_preventif.pass2b2f' + $lotNum + '.consolidation_input.v1')
    lot = $lot
    dry_run = (-not [bool]$ConsolidateLlm)
    exhaustive_source = $srcPath
    exhaustive_json = $exhObj
    counts_before = $countsBefore
    resume_global_old = $oldResume
  }
  $inputFile = Join-Path $consDir 'consolidation_input.json'
  Write-CrJsonAtomic -Path $inputFile -Obj $inputDoc
  Add-CrOutputFile $inputFile
  # --- 4. Prompt de consolidation (entree = matiere Pass2B_2F structuree) ----
  $sysTxt = @"
Tu es l etape de consolidation finale interne de la passe Pass2B_2F (rang 2) d un pipeline de compte rendu expertal preventif.

CONTEXTE DE L ENTREE
- L entree est refere_global_meeting_exhaustive.json : le resultat EXHAUSTIF du merge deterministe des sous-appels de la MEME passe Pass2B_2F.
- Chaque sous-appel a condense une fenetre chronologique melangeant deux familles complementaires de matiere de rang 2 : les echanges oraux horodates et les constatations photographiques contextualisees (description VLM, libelle, commentaire, dictee eventuelle, contexte ASR temporel, provenance).
- L entree contient donc deja, pour chaque fenetre : resume_global, themes, themes_abordes, actions, perspectives, demandes_documents_globales, problems.
- Cette etape ne recoit AUCUNE matiere de rang 1 : ni segments, ni photographies, ni ASR brut. Elle ne doit rien ajouter qui ne soit deja represente dans l entree.

MISSION
Produire une consolidation GLOBALE unique portant sur l ensemble de la reunion :
- fusionne les formulations SEMANTIQUEMENT redondantes : themes proches, problemes proches, actions repetees, perspectives equivalentes, demandes documentaires repetees ;
- conserve chaque constat technique DISTINCT : ne fusionne jamais deux desordres, localisations, ouvrages ou constats techniquement differents sous pretexte qu ils se ressemblent ;
- preserve les constatations issues des photographies meme lorsqu elles sont peu ou pas representees dans l oral : elles sont deja portees par l entree, elles ne doivent pas disparaitre a la consolidation ;
- preserve les elements provenant des trous de transcription ASR et de la periode posterieure a la fin de l ASR lorsqu ils sont portes par l entree ;
- consolide les actions, perspectives et demandes documentaires sans en perdre ;
- produit un resume_global de TOUTE la reunion (plusieurs phases, plusieurs sujets, chronologie), et non la reprise d un resume de batch particulier.

REGLES DE PROBITE
- N invente aucune information nouvelle.
- Ne transforme pas une declaration orale en constat photographique : conserve la distinction entre ce qui est declare et ce qui est visible/documente telle qu elle apparait deja dans l entree.
- Ne supprime pas un element significatif simplement parce qu il semble redondant : reduis la redondance de formulation, pas le fait documentaire.
- N ajoute aucun champ, aucune cle, aucun objet qui ne figure pas dans le schema ci-dessous.
- Si une information est absente ou incertaine, utilise une chaine vide ou un tableau vide ; jamais null.

SCHEMA DE SORTIE STRICT (exactement 7 cles, aucune autre)
{
  "resume_global": "chaine",
  "themes": [ { "titre": "chaine", "synthese": ["chaine", "..."], "timecodes": ["HH:MM:SS", "..."] } ],
  "themes_abordes": ["chaine", "..."],
  "actions": [ { "action": "chaine", "responsable": "chaine ou chaine vide", "echeance": "YYYY-MM-DD ou chaine vide" } ],
  "perspectives": ["chaine", "..."],
  "demandes_documents_globales": [ { "objet": "chaine", "demandeur": "chaine ou chaine vide", "destinataire": "chaine ou chaine vide", "echeance": "YYYY-MM-DD ou chaine vide", "timecodes": ["HH:MM:SS", "..."] } ],
  "problems": [ { "probleme": "chaine", "solution": "chaine ou chaine vide" } ]
}

REGLES DE FORME
- Toutes les listes restent PLATES (niveau 1). Les elements de themes, actions, demandes_documents_globales et problems sont des OBJETS ; les elements de themes_abordes et perspectives sont des CHAINES ; synthese et timecodes sont des tableaux de CHAINES. Aucun tableau imbrique accidentel.
- Conserve les timecodes pertinents (HH:MM:SS) presents dans l entree pour les themes et les demandes documentaires.
- Deduplique les libelles strictement identiques.
- Ne vise aucun nombre arbitraire d elements : condense la redondance reelle, conserve le nombre de faits distincts necessaire.
- Reponds uniquement avec l objet JSON. Aucun Markdown. Aucun texte avant ou apres. Le JSON commence par { et se termine par }.
"@
  $usrTpl = @"
Voici le JSON global EXHAUSTIF produit par le merge deterministe des sous-appels Pass2B_2F (rang 2) :

{EXHAUSTIVE_JSON}

Consolide cet ensemble en un unique refere_global_meeting.json conforme au schema strict (7 cles, listes plates, pas de null, pas d invention). Reponds uniquement avec l objet JSON final.
"@
  $exhJsonText = $exhObj | ConvertTo-Json -Depth 100
  $usrTxt = $usrTpl.Replace('{EXHAUSTIVE_JSON}', $exhJsonText)
  $fullPromptText = $sysTxt + [Environment]::NewLine + $usrTxt
  # --- 5. Budget de consolidation (avant tout appel) -------------------------
  $budget = Get-ContextBudget $ModelAlias
  $nCtx = [int]$budget.NCtx
  $maxTokOut = [int]$budget.MaxTok
  $margin = [int]$budget.Margin
  $availableInput = $nCtx - $maxTokOut - $margin
  $sysTok = Estimate-Tokens $sysTxt
  $usrTok = Estimate-Tokens $usrTxt
  $fullTok = Estimate-Tokens $fullPromptText
  $exhTok = Estimate-Tokens $exhJsonText
  $remaining = $availableInput - $fullTok
  $fits = ($remaining -ge 0)
  $budgetDiag = @{
    alias = $ModelAlias
    configured_n_ctx = $nCtx
    configured_max_output_tokens = $maxTokOut
    safety_margin = $margin
    available_input_tokens = $availableInput
    exhaustive_json_chars = $exhJsonText.Length
    exhaustive_json_tokens_est = $exhTok
    system_prompt_chars = $sysTxt.Length
    system_prompt_tokens_est = $sysTok
    user_prompt_chars = $usrTxt.Length
    user_prompt_tokens_est = $usrTok
    final_input_chars = $fullPromptText.Length
    final_input_tokens_est = $fullTok
    remaining_tokens = $remaining
    fits = $fits
  }
  Write-CrInfo ('Pass2B_2F LOT ' + $lot + ' budget consolidation : final_input_tokens_est=' + $fullTok + ' available=' + $availableInput + ' remaining=' + $remaining + ' fits=' + $fits)
  Add-CrLogLine ('pass2b2f8_consolidate budget final_input_tokens_est=' + $fullTok + ' fits=' + $fits)

  # --- 6. Points de controle deterministes (avant appel) ---------------------
  $cpItems = New-Object System.Collections.ArrayList
  $addCp = {
    param([string]$kind,[string]$cat,[string]$txt,[double]$sec)
    if ($txt) { [void]$cpItems.Add(@{ kind=$kind; source_window=$cat; first_sec=$sec; text=$txt }) }
  }
  foreach ($th in @($exhObj['themes'])) {
    $titre = Get-CrPropString -Obj $th -Name 'titre'
    $tc = Get-CrProp -Obj $th -Name 'timecodes'
    $firstSec = -1.0
    foreach ($h in @($tc)) {
      $ps = ([string]$h).Trim() -split ':'
      if (@($ps).Count -ge 3) {
        try {
          $s = 3600.0*[double]$ps[0] + 60.0*[double]$ps[1] + [double]$ps[2]
          if ($firstSec -lt 0 -or $s -lt $firstSec) { $firstSec = $s }
        } catch { }
      }
    }
    $cat = 'non_temporal'
    if ($firstSec -ge 0) {
      if ($firstSec -lt 3600) { $cat = 'debut' }
      elseif ($firstSec -ge 11000 -and $firstSec -lt 11780) { $cat = 'trou_asr' }
      elseif ($firstSec -ge 11780) { $cat = 'fin' }
    }
    if ($titre) { & $addCp 'theme' $cat $titre $firstSec }
  }
  $resumeOldCp = $oldResume
  if ($resumeOldCp) { & $addCp 'resume_ancien' 'resume' $resumeOldCp -1.0 }
  foreach ($p in @($exhObj['problems'])) {
    $t = Get-CrPropString -Obj $p -Name 'probleme'
    if ($t) { & $addCp 'probleme' 'liste' $t -1.0 }
  }
  foreach ($a in @($exhObj['actions'])) {
    $t = Get-CrPropString -Obj $a -Name 'action'
    if ($t) { & $addCp 'action' 'liste' $t -1.0 }
  }
  foreach ($d in @($exhObj['demandes_documents_globales'])) {
    $t = Get-CrPropString -Obj $d -Name 'objet'
    if ($t) { & $addCp 'demande' 'liste' $t -1.0 }
  }
  foreach ($ta in @($exhObj['themes_abordes'])) {
    if ($ta) { & $addCp 'theme_aborde' 'liste' ([string]$ta) -1.0 }
  }
  foreach ($pv in @($exhObj['perspectives'])) {
    if ($pv) { & $addCp 'perspective' 'liste' ([string]$pv) -1.0 }
  }
  $cpFile = Join-Path $consDir 'consolidation_checkpoints.json'
  Write-CrJsonAtomic -Path $cpFile -Obj @{ schema_version=('cr_refere_preventif.pass2b2f' + $lotNum + '.consolidation_checkpoints.v1'); lot=$lot; checkpoints=@($cpItems) }
  Add-CrOutputFile $cpFile
  # --- 7. Artefacts prompts (toujours ecrits) --------------------------------
  $promptFile = Join-Path $consDir 'consolidation_prompt.txt'
  Write-CrTextUtf8NoBom -Path $promptFile -Text $fullPromptText
  Add-CrOutputFile $promptFile
  $budgetFile = Join-Path $consDir 'consolidation_budget.json'
  Write-CrJsonAtomic -Path $budgetFile -Obj $budgetDiag
  Add-CrOutputFile $budgetFile

  $canonicalOutput = Join-Path $p2dir 'refere_global_meeting.json'
  $llmEntry = $null
  $countsAfter = $null
  $compression = $null
  $status = ''
  $checks = @{ input_keys_ok=(@($missingKeys).Count -eq 0 -and @($extraKeys).Count -eq 0); input_flat_issues=@($flatIssuesIn); input_null_count=$nullCountIn }

  if (-not $ConsolidateLlm) {
    # ---------------- Dry-run : budget + artefacts, aucun appel ---------------
    $status = $(if ($fits) { 'consolidation_dry_run_budget_ok' } else { 'consolidation_dry_run_budget_exceeded' })
    Write-CrInfo ('Pass2B_2F LOT ' + $lot + ' : DRY-RUN consolidation (aucun appel LLM) -> ' + $status)
    Add-CrLogLine ('pass2b2f8_consolidate dry_run status=' + $status)
  } else {
    # ---------------- Appel reel unique (report_remote) -----------------------
    if (-not $fits) {
      throw ('[cr_refere_preventif] LOT 2B2F-8 : budget consolidation depasse (final_input_tokens_est=' + $fullTok + ' > available=' + $availableInput + ') - aucun appel LLM.')
    }
    $script:HttpBlocked = $false
    $base = $ApiBaseOverride
    if (-not $base) { $base = [string][Environment]::GetEnvironmentVariable('PIPELINE_API_BASE') }
    if (-not $base) { $base = 'http://192.168.1.20:5055' }
    $key = $ApiKeyOverride
    if (-not $key) { $key = [string][Environment]::GetEnvironmentVariable('PIPELINE_API_KEY') }
    if (-not $key) { $key = [string][Environment]::GetEnvironmentVariable('ADAPTER_API_KEY') }
    if (-not $key) {
      throw ('[cr_refere_preventif] LOT ' + $lot + ' : cle API manquante (PIPELINE_API_KEY / ADAPTER_API_KEY / -ApiKey) - arret sans appel LLM.')
    }
    $script:AdapterApiBase = $base
    $script:AdapterApiKey = $key
    $script:LlmTimeoutSec = [int]$LlmTimeoutSec
    $temperature = 0.2
    Write-CrInfo ('Pass2B_2F LOT ' + $lot + ' consolidation : 1 appel ' + $ModelAlias + ' endpoint=' + $base + ' max_tokens=' + $maxTokOut + ' temperature=' + $temperature)
    $t0 = Get-Date
    $entry = @{
      step = 'consolidation_finale'
      lot = $lot
      alias_logique = $ModelAlias
      budget_contexte = @{ n_ctx=$nCtx; max_tokens_out=$maxTokOut; margin=$margin }
      estimated_input_tokens = $fullTok
      prompt_chars = $fullPromptText.Length
      temperature = $temperature
      http_status = 0
      duree_sec = 0.0
      finish_reason = $null
      model_reel = $null
      usage = $null
      response_chars = 0
      error = $null
      parse_error = $null
      json_parse_ok = $false
      truncated_or_invalid_response = $false
      missing_keys = @()
      extra_keys = @()
      raw_file = ''
      parsed_file = ''
      retries = 0
    }
    try {
      $endpoint = $script:AdapterApiBase.TrimEnd('/') + '/v1/chat/completions'
      $body = @{
        model = $ModelAlias
        messages = @(
          @{ role='system'; content=$sysTxt },
          @{ role='user'; content=$usrTxt }
        )
        temperature = $temperature
        max_tokens = $maxTokOut
        stream = $false
      }
      $resp = Invoke-LLM-OpenAICompat -Endpoint $endpoint -Body $body -TimeoutSec $script:LlmTimeoutSec -MaxRetries 0
      $entry.duree_sec = [math]::Round(((Get-Date) - $t0).TotalSeconds, 2)
      $entry.http_status = $script:LastHttpStatus
      if ($null -ne $resp) {
        $prm = $resp.PSObject.Properties['model']
        if ($null -ne $prm) { $entry.model_reel = [string]$prm.Value }
      }
      if ($null -eq $resp -or $null -eq $resp.choices -or $null -eq $resp.choices[0] -or $null -eq $resp.choices[0].message) {
        throw '[cr_refere_preventif] Pass2B_2F consolidation : reponse sans choices[0].message.'
      }
      $ch0 = $resp.choices[0]
      $pFr = $ch0.PSObject.Properties['finish_reason']
      if ($null -ne $pFr) { $entry.finish_reason = [string]$pFr.Value }
      $raw = [string]$ch0.message.content
      $entry.response_chars = $raw.Length
      $pUs = $resp.PSObject.Properties['usage']
      if ($null -ne $pUs) { $entry.usage = $pUs.Value }
      $rawFile = Join-Path $consDir 'consolidation_raw_response.txt'
      Write-CrTextUtf8NoBom -Path $rawFile -Text $raw
      Add-CrOutputFile $rawFile
      $entry.raw_file = $rawFile
      $parsed = Parse-LlmJsonStrict -Raw $raw
      $outKeys = @($parsed.psobject.Properties.Name)
      $entry.json_parse_ok = $true
      $entry.missing_keys = @($schemaKeys7 | Where-Object { $_ -notin $outKeys })
      $entry.extra_keys = @($outKeys | Where-Object { $_ -notin $schemaKeys7 })
      $parsedFile = Join-Path $consDir 'consolidation_parsed_response.json'
      Write-CrJsonAtomic -Path $parsedFile -Obj $parsed
      Add-CrOutputFile $parsedFile
      $entry.parsed_file = $parsedFile
      # --- Controles stricts du contrat de sortie -----------------------------
      $outFlatIssues = New-Object System.Collections.ArrayList
      $outNullCount = 0
      foreach ($k in $listKeys6) {
        foreach ($it in @($parsed.$k)) {
          if ($null -eq $it) { $outNullCount++ }
          elseif ($it -is [System.Array]) { [void]$outFlatIssues.Add($k) }
        }
      }
      $jsonOutText = $parsed | ConvertTo-Json -Depth 100
      $hasNullToken = $jsonOutText -match ':\s*null\s*[,}]'
      $strictOk = (@($entry.missing_keys).Count -eq 0) -and (@($entry.extra_keys).Count -eq 0) -and (@($outFlatIssues).Count -eq 0) -and ($outNullCount -eq 0) -and (-not $hasNullToken)
      if (-not $strictOk) {
        throw ('[cr_refere_preventif] Pass2B_2F consolidation : contrat de sortie non respecte (missing=' + (@($entry.missing_keys) -join ',') + ' extra=' + (@($entry.extra_keys) -join ',') + ' flat=' + (@($outFlatIssues) -join ',') + ' nullCount=' + $outNullCount + ' hasNullToken=' + $hasNullToken + ') - aucune ecriture canonique.')
      }

      # --- Garde semantique (LOT 2B2F-9) ----------------------------------------
      # Toute sortie structurellement valide mais semantiquement vide (fallback
      # adapter JSON vide) est un ECHEC : aucune ecriture canonique, aucun
      # ecrasement du dernier canonique valide.
      $semanticEmpty = Test-Pass2B2FConsolidationEmpty -Parsed $parsed
      if ($semanticEmpty) {
        $entry.truncated_or_invalid_response = $true
        $entry.status = 'consolidation_failed_semantic_empty'
        $status = 'consolidation_failed_semantic_empty'
        $checks.semantic_empty = $true
        [void]$script:CriticalQaWarnings.Add('[Pass2B_2F consolidation] sortie structurellement valide mais semantiquement vide (fallback adapter) -> consolidation_failed_semantic_empty ; aucune ecriture canonique.')
        Add-CrLogLine 'pass2b2f9_consolidate semantic_empty=true aucune_ecriture_canonique'
        Write-CrErr ('Pass2B_2F LOT ' + $lot + ' : sortie semantiquement vide -> echec (aucune ecriture canonique, canonique conserve).')
      } else {
        # --- Ecriture canonique (refere_global_meeting.json) ---------------------
        # Write-CrJsonAtomic = ecriture temporaire + rename atomique ; le canonique
        # n'est ecrase qu'apres validation complete (structure + semantique).
        $canonicalOut = @{
          resume_global = ([string]$parsed.resume_global)
          themes = @($parsed.themes)
          themes_abordes = @($parsed.themes_abordes)
          actions = @($parsed.actions)
          perspectives = @($parsed.perspectives)
          demandes_documents_globales = @($parsed.demandes_documents_globales)
          problems = @($parsed.problems)
        }
        Write-CrJsonAtomic -Path $canonicalOutput -Obj $canonicalOut
        Add-CrOutputFile $canonicalOutput
        $consolidatedText = [IO.File]::ReadAllText($canonicalOutput, $script:utf8NoBom)
        $countsAfter = @{
          resume_global_chars = ([string]$parsed.resume_global).Length
          themes = @($parsed.themes).Count
          themes_abordes = @($parsed.themes_abordes).Count
          actions = @($parsed.actions).Count
          perspectives = @($parsed.perspectives).Count
          demandes_documents_globales = @($parsed.demandes_documents_globales).Count
          problems = @($parsed.problems).Count
        }
        $compression = @{
          input_chars = $exhJsonText.Length
          output_chars = $consolidatedText.Length
          input_tokens_est = $exhTok
          output_tokens_est = (Estimate-Tokens $consolidatedText)
          compression_ratio_pct = [math]::Round((100.0 * $consolidatedText.Length / [math]::Max(1,$exhJsonText.Length)), 1)
        }
        $status = 'consolidation_ok'
        $entry.status = 'consolidation_ok'
        $entry.alias = $ModelAlias
        $checks.semantic_empty = $false
        $checks.flat_out_ok = (@($outFlatIssues).Count -eq 0)
        $checks.null_out_count = $outNullCount
        $checks.has_null_token = $hasNullToken
        Write-CrInfo ('Pass2B_2F LOT ' + $lot + ' : consolidation OK -> ' + $canonicalOutput)
      }
    } catch {
      $entry.error = $_.Exception.Message
      try { $entry.duree_sec = [math]::Round(((Get-Date) - $t0).TotalSeconds, 2) } catch { }
    }
    if ([int]$entry.http_status -eq 200 -and $entry.response_chars -gt 0 -and (-not $entry.error) -and (-not [bool]$entry.json_parse_ok)) {
      $entry.truncated_or_invalid_response = $true
      [void]$script:CriticalQaWarnings.Add('[Pass2B_2F consolidation] HTTP 200 mais JSON invalide/incomplet -> truncated_or_invalid_response ; pas de reparation ni de retry.')
    }
    $llmEntry = $entry
    if ($entry.error -or (-not [bool]$entry.json_parse_ok)) {
      throw ('[cr_refere_preventif] Pass2B_2F consolidation : echec (error=' + $(if ($entry.error) { [string]$entry.error } else { 'json_invalide' }) + ') - aucun retry, aucune ecriture canonique.')
    }
  }
  # --- 8. Manifest de consolidation ------------------------------------------
  $manifest = @{
    schema_version = ('cr_refere_preventif.pass2b2f' + $lotNum + '.consolidate.v1')
    lot = $lot
    pipeline = $script:PipelineName
    dry_run = (-not [bool]$ConsolidateLlm)
    llm_calls = $(if ($ConsolidateLlm) { 1 } else { 0 })
    http_calls = $(if ($ConsolidateLlm) { 1 } else { 0 })
    alias = $ModelAlias
    exhaustive_source = $srcPath
    exhaustive_preserved_path = $exhFile
    canonical_output = $canonicalOutput
    canonical_exists = (Test-Path -LiteralPath $canonicalOutput -PathType Leaf)
    started_at = $StartedAt
    finished_at = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
    budget = $budgetDiag
    counts_before = $countsBefore
    counts_after = $countsAfter
    compression = $compression
    resume_global_old = $oldResume
    status = $status
    llm_entry = $llmEntry
    checks = $checks
    input_file = $inputFile
    prompt_file = $promptFile
    budget_file = $budgetFile
    checkpoints_file = $cpFile
  }
  $manifestFile = Join-Path $consDir ('pass2b2f' + $lotNum + '_consolidate_manifest.json')
  Write-CrJsonAtomic -Path $manifestFile -Obj $manifest
  Add-CrOutputFile $manifestFile

  $ok = $true
  if ($ConsolidateLlm) { $ok = ($status -eq 'consolidation_ok' -and (Test-Path -LiteralPath $canonicalOutput -PathType Leaf)) }
  Write-CrInfo ('Pass2B_2F LOT ' + $lot + ' : manifest=' + $manifestFile + ' status=' + $status)
  return @{
    summary = @{
      ok = $ok
      status = $status
      lot = $lot
      llm_calls = $(if ($ConsolidateLlm) { 1 } else { 0 })
      http_calls = $(if ($ConsolidateLlm) { 1 } else { 0 })
      mode = $(if ($ConsolidateLlm) { 'llm' } else { 'dry_run' })
      exhaustive_source = $srcPath
      exhaustive_path = $exhFile
      canonical_output = $canonicalOutput
      consolidated_output = $canonicalOutput
      manifest = $manifestFile
      budget = $budgetDiag
      counts_before = $countsBefore
      counts_after = $countsAfter
      compression = $compression
      checks = $checks
      llm_entry = $llmEntry
      resume_global_old = $oldResume
    }
    result = $llmEntry
  }
}

# ===========================================================================
# LOT 2B2F-12 : consolidation hierarchique interne Pass2B_2F (6G).
# ---------------------------------------------------------------------------
# 36 sorties batch Pass2B_2F (run 2B2F-7) -> 6 groupes chronologiques ->
# 6 condensations intermediaires (contrat 7 cles) -> 1 consolidation finale
# -> refere_global_meeting.json (canonique). Chaque appel reste un sous-appel
# interne a la MEME passe logique Pass2B_2F. Aucune sortie d'une autre passe
# de rang 2 n'est consommee. Reutilisation des gardes 2B2F-9 (sortie vide =
# echec) et de l'ecriture atomique Write-CrJsonAtomic.
# ===========================================================================
function Invoke-Pass2B2FCallAndValidate {
  # Un sous-appel unique (groupe ou final) avec contrat 7 cles strict.
  # Ecrit les artefacts prompt/raw/parsed sous $ConsDir/$ArtifactBase.
  # N'ecrit AUCUN canonique : l'appelant decide apres validation.
  param(
    [string] $ConsDir,
    [string] $ArtifactBase,
    [string] $ModelAlias,
    [string] $SysTxt,
    [string] $UsrTxt,
    [object] $Budget,
    [string] $LotLabel = '2B2F-12',
    [string] $ApiBaseOverride = '',
    [string] $ApiKeyOverride = '',
    [int]    $MaxOutTokens = 0,
    [switch] $Llm
  )
  $schemaKeys7 = @('resume_global','themes','themes_abordes','actions','perspectives','demandes_documents_globales','problems')
  $listKeys6 = @('themes','themes_abordes','actions','perspectives','demandes_documents_globales','problems')
  $nCtx = [int]$Budget.NCtx
  $maxOut = $MaxOutTokens
  if ($maxOut -le 0) { $maxOut = [int]$Budget.MaxTok }
  $margin = [int]$Budget.Margin
  $availableInput = $nCtx - $maxOut - $margin
  $sysTok = Estimate-Tokens $SysTxt
  $usrTok = Estimate-Tokens $UsrTxt
  $fullPromptText = $SysTxt + [Environment]::NewLine + $UsrTxt
  $fullTok = Estimate-Tokens $fullPromptText
  $remaining = $availableInput - $fullTok
  $fits = ($remaining -ge 0)
  $budgetDiag = @{
    alias = $ModelAlias
    configured_n_ctx = $nCtx
    configured_max_output_tokens = $maxOut
    safety_margin = $margin
    available_input_tokens = $availableInput
    system_prompt_chars = $SysTxt.Length
    system_prompt_tokens_est = $sysTok
    user_prompt_chars = $UsrTxt.Length
    user_prompt_tokens_est = $usrTok
    final_input_chars = $fullPromptText.Length
    final_input_tokens_est = $fullTok
    remaining_tokens = $remaining
    fits = $fits
  }
  $promptFile = Join-Path $ConsDir ($ArtifactBase + '_prompt.txt')
  Write-CrTextUtf8NoBom -Path $promptFile -Text $fullPromptText
  Add-CrOutputFile $promptFile
  if (-not $Llm) {
    return @{
      ok = $fits
      status = $(if ($fits) { 'dry_run_budget_ok' } else { 'dry_run_budget_exceeded' })
      fits = $fits
      budget = $budgetDiag
      llm_entry = $null
      parsed = $null
      json_text = ''
      raw_file = ''
      parsed_file = ''
      prompt_file = $promptFile
    }
  }
  if (-not $fits) {
    throw ('[cr_refere_preventif] Pass2B_2F LOT ' + $LotLabel + ' : budget depasse (final_input_tokens_est=' + $fullTok + ' > available=' + $availableInput + ') - aucun appel LLM.')
  }
  if ($null -eq $script:llmEntries) { $script:llmEntries = New-Object System.Collections.ArrayList }
  $script:HttpBlocked = $false
  $base = $ApiBaseOverride
  if (-not $base) { $base = [string][Environment]::GetEnvironmentVariable('PIPELINE_API_BASE') }
  if (-not $base) { $base = 'http://192.168.1.20:5055' }
  $key = $ApiKeyOverride
  if (-not $key) { $key = [string][Environment]::GetEnvironmentVariable('PIPELINE_API_KEY') }
  if (-not $key) { $key = [string][Environment]::GetEnvironmentVariable('ADAPTER_API_KEY') }
  if (-not $key) {
    throw ('[cr_refere_preventif] Pass2B_2F LOT ' + $LotLabel + ' : cle API manquante (PIPELINE_API_KEY / ADAPTER_API_KEY / -ApiKey) - arret sans appel LLM.')
  }
  $script:AdapterApiBase = $base
  $script:AdapterApiKey = $key
  $script:LlmTimeoutSec = 900
  $temperature = 0.2
  $entry = @{
    step = $ArtifactBase
    lot = $LotLabel
    alias_logique = $ModelAlias
    budget_contexte = @{ n_ctx = $nCtx; max_tokens_out = $maxOut; margin = $margin }
    estimated_input_tokens = $fullTok
    prompt_chars = $fullPromptText.Length
    temperature = $temperature
    http_status = 0
    duree_sec = 0.0
    finish_reason = $null
    model_reel = $null
    usage = $null
    response_chars = 0
    error = $null
    parse_error = $null
    json_parse_ok = $false
    truncated_or_invalid_response = $false
    missing_keys = @()
    extra_keys = @()
    raw_file = ''
    parsed_file = ''
    retries = 0
  }
  $t0 = Get-Date
  try {
    $endpoint = $script:AdapterApiBase.TrimEnd('/') + '/v1/chat/completions'
    $body = @{
      model = $ModelAlias
      messages = @(
        @{ role = 'system'; content = $SysTxt },
        @{ role = 'user'; content = $UsrTxt }
      )
      temperature = $temperature
      max_tokens = $maxOut
      stream = $false
    }
    if ($null -ne $script:RefereProgress) {
      $script:RefereProgress.llm_calls++
      $script:RefereProgress.http_calls++
    }
    $resp = Invoke-LLM-OpenAICompat -Endpoint $endpoint -Body $body -TimeoutSec $script:LlmTimeoutSec -MaxRetries 0
    $entry.duree_sec = [math]::Round(((Get-Date) - $t0).TotalSeconds, 2)
    $entry.http_status = $script:LastHttpStatus
    if ($null -ne $resp) {
      $prm = $resp.PSObject.Properties['model']
      if ($null -ne $prm) { $entry.model_reel = [string]$prm.Value }
    }
    if ($null -eq $resp -or $null -eq $resp.choices -or $null -eq $resp.choices[0] -or $null -eq $resp.choices[0].message) {
      throw '[cr_refere_preventif] Pass2B_2F consolidation : reponse sans choices[0].message.'
    }
    $ch0 = $resp.choices[0]
    $pFr = $ch0.PSObject.Properties['finish_reason']
    if ($null -ne $pFr) { $entry.finish_reason = [string]$pFr.Value }
    $raw = [string]$ch0.message.content
    $entry.response_chars = $raw.Length
    $pUs = $resp.PSObject.Properties['usage']
    if ($null -ne $pUs) { $entry.usage = $pUs.Value }
    $rawFile = Join-Path $ConsDir ($ArtifactBase + '_raw.txt')
    Write-CrTextUtf8NoBom -Path $rawFile -Text $raw
    Add-CrOutputFile $rawFile
    $entry.raw_file = $rawFile
    $parsed = Parse-LlmJsonStrict -Raw $raw
    $outKeys = @($parsed.psobject.Properties.Name)
    $entry.json_parse_ok = $true
    $entry.missing_keys = @($schemaKeys7 | Where-Object { $_ -notin $outKeys })
    $entry.extra_keys = @($outKeys | Where-Object { $_ -notin $schemaKeys7 })
    $parsedFile = Join-Path $ConsDir ($ArtifactBase + '_parsed_response.json')
    Write-CrJsonAtomic -Path $parsedFile -Obj $parsed
    Add-CrOutputFile $parsedFile
    $entry.parsed_file = $parsedFile
    $outFlatIssues = New-Object System.Collections.ArrayList
    $outNullCount = 0
    foreach ($k in $listKeys6) {
      foreach ($it in @($parsed.$k)) {
        if ($null -eq $it) { $outNullCount++ }
        elseif ($it -is [System.Array]) { [void]$outFlatIssues.Add($k) }
      }
    }
    $jsonOutText = $parsed | ConvertTo-Json -Depth 100
    $hasNullToken = $jsonOutText -match ':\s*null\s*[,}]'
    $strictOk = (@($entry.missing_keys).Count -eq 0) -and (@($entry.extra_keys).Count -eq 0) -and (@($outFlatIssues).Count -eq 0) -and ($outNullCount -eq 0) -and (-not $hasNullToken)
    if (-not $strictOk) {
      throw ('[cr_refere_preventif] Pass2B_2F consolidation : contrat de sortie non respecte (missing=' + (@($entry.missing_keys) -join ',') + ' extra=' + (@($entry.extra_keys) -join ',') + ' flat=' + (@($outFlatIssues) -join ',') + ' nullCount=' + $outNullCount + ' hasNullToken=' + $hasNullToken + ') - aucune ecriture canonique.')
    }
    $semanticEmpty = Test-Pass2B2FConsolidationEmpty -Parsed $parsed
    if ($semanticEmpty) {
      $entry.truncated_or_invalid_response = $true
      $entry.status = 'consolidation_failed_semantic_empty'
      [void]$script:CriticalQaWarnings.Add('[Pass2B_2F consolidation] sortie structurellement valide mais semantiquement vide (fallback adapter) -> echec ; aucune ecriture canonique.')
      throw '[cr_refere_preventif] Pass2B_2F consolidation : sortie semantiquement vide -> echec (aucune ecriture canonique).'
    }
    $entry.status = 'consolidation_ok'
    $entry.alias = $ModelAlias
    [void]$script:llmEntries.Add($entry)
    return @{
      ok = $true
      status = 'consolidation_ok'
      fits = $true
      budget = $budgetDiag
      llm_entry = $entry
      parsed = $parsed
      json_text = $jsonOutText
      raw_file = $rawFile
      parsed_file = $parsedFile
      prompt_file = $promptFile
    }
  } catch {
    $entry.error = $_.Exception.Message
    try { $entry.duree_sec = [math]::Round(((Get-Date) - $t0).TotalSeconds, 2) } catch { }
    if ([int]$entry.http_status -eq 200 -and $entry.response_chars -gt 0 -and (-not [bool]$entry.json_parse_ok)) {
      $entry.truncated_or_invalid_response = $true
    }
    if ($null -eq $script:llmEntries) { $script:llmEntries = New-Object System.Collections.ArrayList }
    [void]$script:llmEntries.Add($entry)
    throw ('[cr_refere_preventif] Pass2B_2F consolidation : echec (error=' + [string]$entry.error + ') - aucun retry, aucune ecriture canonique.')
  }
}

function Get-Pass2B2FHierarchicalBatchPlan {
  param(
    [string] $BatchOutputsDir,
    [string] $BatchEntriesJsonPath = '',
    [string] $LotLabel = '2B2F-12'
  )
  $lot = ([string]$LotLabel).Trim()
  if (-not $lot) { $lot = '2B2F-12' }
  if (-not $BatchOutputsDir -or -not (Test-Path -LiteralPath $BatchOutputsDir -PathType Container)) {
    throw ('[cr_refere_preventif] LOT ' + $lot + ' : -Pass2B2FBatchOutputsDir invalide : ' + [string]$BatchOutputsDir)
  }

  $diskNums = @(
    Get-ChildItem -LiteralPath $BatchOutputsDir -Filter 'batch_*_response.json' -File -ErrorAction SilentlyContinue |
      ForEach-Object {
        $m = [regex]::Match($_.Name, '^batch_0*(\d+)_response\.json$')
        if ($m.Success) { [int]$m.Groups[1].Value }
      } |
      Sort-Object -Unique
  )

  if (-not $BatchEntriesJsonPath) {
    $parentDir = Split-Path $BatchOutputsDir -Parent
    $candidate = Join-Path $parentDir 'entries.json'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { $BatchEntriesJsonPath = $candidate }
  }

  $entriesRoot = $null
  $source = 'parsed_outputs'
  $batchNums = @()
  if ($BatchEntriesJsonPath -and (Test-Path -LiteralPath $BatchEntriesJsonPath -PathType Leaf)) {
    $entriesRoot = Read-JsonFile -Path $BatchEntriesJsonPath
    $selected = @($entriesRoot['selected_batches'])
    if ($selected.Count -gt 0) {
      $batchNums = @($selected | ForEach-Object { [int]$_ } | Sort-Object -Unique)
      $source = 'entries.json:selected_batches'
    } else {
      $derived = New-Object System.Collections.ArrayList
      foreach ($entry in @($entriesRoot['entries'])) {
        $idx = 0
        if ($null -ne $entry -and $entry.ContainsKey('batch_index')) {
          $idx = [int]$entry['batch_index']
        } elseif ($null -ne $entry) {
          $m = [regex]::Match([string]$entry['tag'], 'batch[_\-]?0*(\d+)')
          if ($m.Success) { $idx = [int]$m.Groups[1].Value }
        }
        if ($idx -gt 0) { [void]$derived.Add($idx) }
      }
      if ($derived.Count -gt 0) {
        $batchNums = @($derived.ToArray() | Sort-Object -Unique)
        $source = 'entries.json:entries'
      }
    }
  }
  if ($batchNums.Count -eq 0) { $batchNums = @($diskNums); $source = 'parsed_outputs' }
  $batchNums = @($batchNums | ForEach-Object { [int]$_ } | Sort-Object -Unique)
  if ($batchNums.Count -eq 0) {
    throw ('[cr_refere_preventif] LOT ' + $lot + ' : aucun batch hierarchique disponible dans entries.json ni dans ' + $BatchOutputsDir + '.')
  }

  $n = [int]$batchNums[-1]
  $expected = @(1..$n)
  $holes = @($expected | Where-Object { $_ -notin $batchNums })
  $unexpected = @($batchNums | Where-Object { $_ -notin $expected })
  if ($batchNums.Count -ne $n -or $holes.Count -gt 0 -or $unexpected.Count -gt 0) {
    throw ('[cr_refere_preventif] LOT ' + $lot + ' : batches non continus, attendu 1..' + $n + ' ; absents=' + $(if ($holes.Count -gt 0) { @($holes | ForEach-Object { 'batch ' + $_ }) -join ',' } else { 'aucun' }) + ' inattendus=' + $(if ($unexpected.Count -gt 0) { @($unexpected) -join ',' } else { 'aucun' }) + '.')
  }

  if ($null -ne $entriesRoot -and $entriesRoot.ContainsKey('expected_batches')) {
    $declared = [int]$entriesRoot['expected_batches']
    if ($declared -ne $batchNums.Count) {
      throw ('[cr_refere_preventif] LOT ' + $lot + ' : incoherence entries.json expected_batches=' + $declared + ' mais batches autoritaires=' + $batchNums.Count + '.')
    }
  }

  $missingFiles = @($batchNums | Where-Object {
    $name = 'batch_' + ('{0:D2}' -f $_) + '_response.json'
    -not (Test-Path -LiteralPath (Join-Path $BatchOutputsDir $name) -PathType Leaf)
  })
  $extraFiles = @($diskNums | Where-Object { $_ -notin $batchNums })
  if ($missingFiles.Count -gt 0 -or $extraFiles.Count -gt 0) {
    throw ('[cr_refere_preventif] LOT ' + $lot + ' : incoherence entries.json/parsed_outputs ; fichiers absents=' + $(if ($missingFiles.Count -gt 0) { @($missingFiles | ForEach-Object { 'batch ' + $_ }) -join ',' } else { 'aucun' }) + ' fichiers hors perimetre=' + $(if ($extraFiles.Count -gt 0) { @($extraFiles | ForEach-Object { 'batch ' + $_ }) -join ',' } else { 'aucun' }) + '.')
  }

  return @{
    batch_nums = @($batchNums)
    disk_batch_nums = @($diskNums)
    source = $source
    entries_path = [string]$BatchEntriesJsonPath
    entries_root = $entriesRoot
  }
}

function New-Pass2B2FHierarchicalGroupPlans {
  param([int[]] $BatchNums)
  $nums = @($BatchNums | ForEach-Object { [int]$_ } | Sort-Object -Unique)
  $n = $nums.Count
  if ($n -lt 6) {
    throw ('[cr_refere_preventif] Pass2B_2F hierarchique : au moins 6 batches sont requis pour 6 groupes non vides (recu=' + $n + ').')
  }
  $expected = @(1..$n)
  if (@(Compare-Object $expected $nums).Count -gt 0) {
    throw ('[cr_refere_preventif] Pass2B_2F hierarchique : les batches doivent couvrir exactement 1..' + $n + '.')
  }

  $sizes = @()
  if ($n -eq 36) {
    $sizes = @(6, 3, 7, 6, 7, 7)
  } else {
    $baseSize = [int][math]::Floor($n / 6)
    $remainder = $n % 6
    for ($g = 0; $g -lt 6; $g++) { $sizes += $baseSize + $(if ($g -lt $remainder) { 1 } else { 0 }) }
  }

  $plans = New-Object System.Collections.ArrayList
  $offset = 0
  for ($g = 0; $g -lt 6; $g++) {
    $groupNums = @($nums[$offset..($offset + $sizes[$g] - 1)])
    [void]$plans.Add(@{
      id = ('{0:D2}' -f ($g + 1))
      label = 'G' + ($g + 1)
      batch_nums = @($groupNums)
    })
    $offset += $sizes[$g]
  }
  return @($plans.ToArray())
}
function Invoke-Pass2B2FHierarchicalConsolidation {
  param(
    [string] $OutDir,
    [string] $BatchOutputsDir = '',
    [string] $BatchEntriesJsonPath = '',
    [string] $ExhaustiveJsonPath = '',
    [string] $ModelAlias = 'report_remote',
    [string] $StartedAt = '',
    [string] $ApiBaseOverride = '',
    [string] $ApiKeyOverride = '',
    [string] $LotLabel = '2B2F-12',
    [int]    $MaxTokensIntermediate = 4096,
    [switch] $ConsolidateLlm
  )
  $lot = ([string]$LotLabel).Trim()
  if (-not $lot) { $lot = '2B2F-12' }
  $lotNum = ($lot -split '-')[-1]
  if (-not $lotNum) { $lotNum = '12' }
  $p2dir = Join-Path $OutDir 'pass2b2f'
  Ensure-Dir $p2dir
  $consDir = Join-Path $p2dir ('pass2b2f' + $lotNum + '_hierarchical')
  Ensure-Dir $consDir
  $schemaKeys7 = @('resume_global','themes','themes_abordes','actions','perspectives','demandes_documents_globales','problems')
  $listKeys6 = @('themes','themes_abordes','actions','perspectives','demandes_documents_globales','problems')

  # --- 0. Localiser la source exhaustive (audit + checkpoints) ----------------
  $srcCand = ''
  if ($ExhaustiveJsonPath) {
    $srcCand = ([string]$ExhaustiveJsonPath).Trim()
  } else {
    $defaultExh = Join-Path $p2dir 'refere_global_meeting_exhaustive.json'
    if (Test-Path -LiteralPath $defaultExh -PathType Leaf) { $srcCand = $defaultExh }
  }
  if (-not $srcCand -or -not (Test-Path -LiteralPath $srcCand -PathType Leaf)) {
    throw ('[cr_refere_preventif] LOT ' + $lot + ' : JSON exhaustif introuvable (fournir -Pass2B2FExhaustiveJsonPath) : ' + [string]$srcCand)
  }
  $srcPath = [System.IO.Path]::GetFullPath($srcCand)
  Write-CrInfo ('Pass2B_2F LOT ' + $lot + ' consolidation hierarchique : source exhaustive=' + $srcPath)
  $exhFile = Join-Path $p2dir 'refere_global_meeting_exhaustive.json'
  if ([System.IO.Path]::GetFullPath($exhFile) -ine $srcPath) {
    Copy-Item -LiteralPath $srcPath -Destination $exhFile -Force
    Write-CrInfo ('Pass2B_2F LOT ' + $lot + ' : exhaustive preserve -> ' + $exhFile)
    Add-CrOutputFile $exhFile
  }
  $exhObj = Read-JsonFile -Path $srcPath
  $exhKeys = @($exhObj.Keys)
  $exhMissing = @($schemaKeys7 | Where-Object { $_ -notin $exhKeys })
  $exhExtra = @($exhKeys | Where-Object { $_ -notin $schemaKeys7 })
  if (@($exhMissing).Count -gt 0 -or @($exhExtra).Count -gt 0) {
    throw ('[cr_refere_preventif] LOT ' + $lot + ' : entree exhaustive hors contrat 7 cles (missing=' + (@($exhMissing) -join ',') + ' extra=' + (@($exhExtra) -join ',') + ').')
  }
  $exhJsonText = $exhObj | ConvertTo-Json -Depth 100
  $countsBefore = @{
    resume_global_chars = ([string]$exhObj['resume_global']).Length
    themes = @($exhObj['themes']).Count
    themes_abordes = @($exhObj['themes_abordes']).Count
    actions = @($exhObj['actions']).Count
    perspectives = @($exhObj['perspectives']).Count
    demandes_documents_globales = @($exhObj['demandes_documents_globales']).Count
    problems = @($exhObj['problems']).Count
  }
  $exhResume = [string]$exhObj['resume_global']

  # --- 1. Repertoire et liste autoritaire des sorties batch -------------------
  $batchPlan = Get-Pass2B2FHierarchicalBatchPlan -BatchOutputsDir $BatchOutputsDir -BatchEntriesJsonPath $BatchEntriesJsonPath -LotLabel $lot
  $expectedBatchNums = @($batchPlan.batch_nums)
  $BatchEntriesJsonPath = [string]$batchPlan.entries_path
  $batchOutputs = @{}
  $batchSerTexts = @{}
  foreach ($bi in $expectedBatchNums) {
    $bname = 'batch_' + ('{0:D2}' -f $bi) + '_response.json'
    $bpath = Join-Path $BatchOutputsDir $bname
    if (-not (Test-Path -LiteralPath $bpath -PathType Leaf)) {
      throw ('[cr_refere_preventif] LOT ' + $lot + ' : sortie batch absente : ' + $bpath)
    }
    $bobj = Read-JsonFile -Path $bpath
    $bk = @($bobj.Keys)
    $bmiss = @($schemaKeys7 | Where-Object { $_ -notin $bk })
    $bextra = @($bk | Where-Object { $_ -notin $schemaKeys7 })
    if (@($bmiss).Count -gt 0 -or @($bextra).Count -gt 0) {
      throw ('[cr_refere_preventif] LOT ' + $lot + ' : sortie batch ' + $bname + ' hors contrat 7 cles (missing=' + (@($bmiss) -join ',') + ' extra=' + (@($bextra) -join ',') + ').')
    }
    $batchOutputs[$bi] = $bobj
    $batchSerTexts[$bi] = ($bobj | ConvertTo-Json -Depth 100)
  }
  Write-CrInfo ('Pass2B_2F LOT ' + $lot + ' : ' + $expectedBatchNums.Count + ' sorties batch lues depuis ' + $BatchOutputsDir + ' (source=' + [string]$batchPlan.source + ')')

  # --- 2. Entrees journal (metadonnees chronologiques / sujets) ---------------
  $entriesByTag = @{}
  if (-not $BatchEntriesJsonPath) {
    $parentDir = Split-Path $BatchOutputsDir -Parent
    $candE = Join-Path $parentDir 'entries.json'
    if (Test-Path -LiteralPath $candE -PathType Leaf) { $BatchEntriesJsonPath = $candE }
  }
  if ($BatchEntriesJsonPath -and (Test-Path -LiteralPath $BatchEntriesJsonPath -PathType Leaf)) {
    $entriesRoot = $batchPlan.entries_root
    if ($null -eq $entriesRoot) { $entriesRoot = Read-JsonFile -Path $BatchEntriesJsonPath }
    foreach ($en in @($entriesRoot['entries'])) {
      $tg = [string]$en['tag']
      if ($tg) {
        $entriesByTag[$tg] = $en
        $tm = [regex]::Match($tg, 'batch[_\-]?0*(\d+)')
        if ($tm.Success) {
          $bn = [int]$tm.Groups[1].Value
          $entriesByTag[('batch_' + ('{0:D2}' -f $bn))] = $en
          $entriesByTag[('batch_' + ('{0:D2}' -f $bn) + '_response.json')] = $en
        }
      }
    }
    Write-CrInfo ('Pass2B_2F LOT ' + $lot + ' : entries lues (' + @($entriesByTag.Keys).Count + ') depuis ' + $BatchEntriesJsonPath)
  } else {
    Write-CrWarn ('Pass2B_2F LOT ' + $lot + ' : entries.json absent, metadonnees groupe partiellement derivees des fichiers batch.')
  }

  $groupPlans = @(New-Pass2B2FHierarchicalGroupPlans -BatchNums $expectedBatchNums)
  if (@($groupPlans).Count -ne 6) {
    throw '[cr_refere_preventif] Pass2B_2F hierarchique : la definition 6G doit contenir 6 groupes.'
  }
  # --- 3. Boucle groupes : condensation intermediaire (contrat 7 cles) --------
  $budget = Get-ContextBudget $ModelAlias
  $groupResults = New-Object System.Collections.ArrayList
  $groupSummaries = New-Object System.Collections.ArrayList
  $sysLines = @(
    'Tu es la condensation intermediaire de la passe Pass2B_2F (rang 2) d un pipeline de compte rendu expertal preventif.',
    'Entree : les sorties JSON de plusieurs sous-appels batch Pass2B_2F de la MEME passe, couvrant un groupe chronologique de la reunion.',
    'Chaque sortie batch est deja une matiere structuree (resume_global, themes, themes_abordes, actions, perspectives, demandes_documents_globales, problems) melangeant deux familles complementaires : echanges oraux horodates et constatations photographiques contextualisees.',
    'Cette etape ne recoit AUCUNE matiere de rang 1 (ni segments, ni photographies, ni ASR brut). Elle ne doit rien ajouter qui ne soit deja represente dans les entrees.',
    'Mission : produire UNE condensation intermediaire du groupe.',
    'Fusionner les formulations SEMANTIQUEMENT redondantes entre les sorties du groupe : themes proches, problemes proches, actions repetees, perspectives equivalentes, demandes documentaires repetees.',
    'Conserver chaque constat technique DISTINCT : ne jamais fusionner deux desordres, localisations, ouvrages ou constats techniquement differents.',
    'Conserver les constatations issues des photographies meme lorsqu elles sont peu ou pas representees dans les echanges oraux : elles sont portees par les entrees, elles ne doivent pas disparaitre a la condensation.',
    'Conserver les elements provenant des trous de transcription ASR et de la periode posterieure a la fin ASR lorsqu ils sont portes par les entrees.',
    'Produire un resume_global representatif du groupe (plusieurs fenetres, plusieurs sujets si presents).',
    'Ne rien inventer. Ne pas transformer une declaration orale en constat photographique : conserver la distinction entre ce qui est declare et ce qui est visible ou documente telle qu elle apparait dans les entrees.',
    'Ne pas supprimer un element significatif sous pretexte qu il semble redondant : reduire la redondance de formulation, pas le fait documentaire.',
    'Schema de sortie strict (exactement 7 cles, aucune autre) :',
    'resume_global : chaine.',
    'themes : tableau d objets avec titre (chaine), synthese (tableau de chaines), timecodes (tableau de chaines HH:MM:SS).',
    'themes_abordes : tableau de chaines.',
    'actions : tableau d objets avec action (chaine), responsable (chaine ou chaine vide), echeance (YYYY-MM-DD ou chaine vide).',
    'perspectives : tableau de chaines.',
    'demandes_documents_globales : tableau d objets avec objet, demandeur, destinataire, echeance, timecodes.',
    'problems : tableau d objets avec probleme (chaine) et solution (chaine ou chaine vide).',
    'Regles de forme : toutes les listes restent PLATES (niveau 1) ; aucun null (utiliser une chaine vide) ; conserver les timecodes pertinents presents dans les entrees ; dedupliquer les libelles strictement identiques.',
    'Sortie cible : environ 1500 a 2500 tokens. Ne vise aucun nombre arbitraire d elements : condense la redondance reelle, conserve le nombre de faits distincts necessaire.',
    'Reponds uniquement avec l objet JSON. Aucun Markdown. Aucun texte avant ou apres. Le JSON commence par { et se termine par }.'
  )
  $sysInter = $sysLines -join [Environment]::NewLine
  foreach ($gp in $groupPlans) {
    $groupId = [string]$gp.id
    $groupLabel = [string]$gp.label
    $gArtifact = 'consolidation_group_' + $groupId
    Write-CrInfo ('Pass2B_2F LOT ' + $lot + ' : groupe ' + $groupLabel + ' (batches ' + @($gp.batch_nums)[0] + '..' + @($gp.batch_nums)[-1] + ')')
    $batchDocs = New-Object System.Collections.ArrayList
    $subjectsSet = @{}
    $genSum = 0
    $photoSum = 0
    $startHms = ''
    $endHms = ''
    $inputCharsSum = 0
    $inputTokSum = 0
    foreach ($bi in @($gp.batch_nums)) {
      $bname = 'batch_' + ('{0:D2}' -f $bi) + '_response.json'
      $outObj = $batchOutputs[$bi]
      $serText = $batchSerTexts[$bi]
      $inputCharsSum += $serText.Length
      $inputTokSum += (Estimate-Tokens $serText)
      $sH = ''
      $eH = ''
      $psList = @()
      $gc = 0
      $puc = 0
      if ($entriesByTag.ContainsKey($bname)) {
        $en = $entriesByTag[$bname]
        $sH = [string]$en['start_hms']
        $eH = [string]$en['end_hms']
        $gc = [int]$en['general_segments_count']
        $puc = [int]$en['photo_units_count']
        foreach ($sb in @($en['photo_subjects'])) { if ($null -ne $sb) { $psList += [int]$sb } }
        if (-not $startHms -and $sH) { $startHms = $sH }
        $endHms = $eH
      }
      if ($gc -gt 0) { $genSum += $gc }
      if ($puc -gt 0) { $photoSum += $puc }
      foreach ($sbv in $psList) { if (-not $subjectsSet.ContainsKey($sbv)) { $subjectsSet[$sbv] = $true } }
      [void]$batchDocs.Add(@{
        batch_id = $bname
        start_hms = $sH
        end_hms = $eH
        photo_subjects = @($psList)
        general_segments_count = $gc
        photo_units_count = $puc
        output = $outObj
      })
    }
    $subjList = @($subjectsSet.Keys | Sort-Object)
    $inputDoc = @{
      schema_version = ('cr_refere_preventif.pass2b2f' + $lotNum + '.hierarchical_group_input.v1')
      lot = $lot
      dry_run = (-not [bool]$ConsolidateLlm)
      group_id = $groupLabel
      group_index = $groupId
      period = @{ start_hms = $startHms; end_hms = $endHms }
      source_batches = @($gp.batch_nums)
      subjects = @($subjList)
      general_segments_count = $genSum
      photo_units_count = $photoSum
      batches_input_chars = $inputCharsSum
      batches_input_tokens_est = $inputTokSum
      batches = @($batchDocs.ToArray())
    }
    $inputJson = $inputDoc | ConvertTo-Json -Depth 100
    $inputFile = Join-Path $consDir ($gArtifact + '_input.json')
    Write-CrJsonAtomic -Path $inputFile -Obj $inputDoc
    Add-CrOutputFile $inputFile
    $usrLines = @(
      'Voici les sorties batch Pass2B_2F (rang 2) du groupe chronologique ' + $groupLabel + ' (' + $startHms + ' -> ' + $endHms + '), au format JSON :',
      '{GROUP_JSON}',
      'Produis la condensation intermediaire du groupe au format strict (7 cles, listes plates, aucun null, aucune invention). Reponds uniquement avec l objet JSON final.'
    )
    $usrHeader = ($usrLines -join [Environment]::NewLine)
    $usrInter = $usrHeader.Replace('{GROUP_JSON}', $inputJson)
    Write-CrInfo ('Pass2B_2F LOT ' + $lot + ' groupe ' + $groupLabel + ' : input_chars=' + $inputJson.Length + ' input_tokens_est=' + (Estimate-Tokens $inputJson) + ' batches=' + @($gp.batch_nums).Count + ' gen=' + $genSum + ' photo=' + $photoSum)
    $stageRes = Invoke-Pass2B2FCallAndValidate -ConsDir $consDir -ArtifactBase $gArtifact -ModelAlias $ModelAlias -SysTxt $sysInter -UsrTxt $usrInter -Budget $budget -LotLabel $lot -ApiBaseOverride $ApiBaseOverride -ApiKeyOverride $ApiKeyOverride -MaxOutTokens $MaxTokensIntermediate -Llm:$ConsolidateLlm
    $groupStatus = $stageRes.status
    $groupEntry = $stageRes.llm_entry
    $groupParsed = $stageRes.parsed
    if ($ConsolidateLlm -and -not $stageRes.ok) {
      throw ('[cr_refere_preventif] Pass2B_2F LOT ' + $lot + ' : groupe ' + $groupLabel + ' en echec (status=' + $stageRes.status + ') - arret, pas de consolidation finale.')
    }
    if ($ConsolidateLlm) {
      $groupOutFile = Join-Path $consDir ($gArtifact + '.json')
      Write-CrJsonAtomic -Path $groupOutFile -Obj $groupParsed
      Add-CrOutputFile $groupOutFile
      Write-CrInfo ('Pass2B_2F LOT ' + $lot + ' groupe ' + $groupLabel + ' : OK -> ' + $groupOutFile)
    }
    $groupBudgetFile = Join-Path $consDir ($gArtifact + '_budget.json')
    Write-CrJsonAtomic -Path $groupBudgetFile -Obj $stageRes.budget
    Add-CrOutputFile $groupBudgetFile
    $groupSummary = @{
      group_id = $groupLabel
      group_index = $groupId
      period = @{ start_hms = $startHms; end_hms = $endHms }
      source_batches = @($gp.batch_nums)
      subjects = @($subjList)
      general_segments_count = $genSum
      photo_units_count = $photoSum
      input_chars = $inputJson.Length
      input_tokens_est = (Estimate-Tokens $inputJson)
      status = $groupStatus
      budget = $stageRes.budget
      input_file = $inputFile
      prompt_file = $stageRes.prompt_file
      output_file = $(if ($ConsolidateLlm) { (Join-Path $consDir ($gArtifact + '.json')) } else { '' })
      llm_entry = $groupEntry
    }
    [void]$groupSummaries.Add($groupSummary)
    [void]$groupResults.Add(@{
      group = $groupLabel
      parsed = $groupParsed
      input_json = $inputJson
      input_file = $inputFile
      start_hms = $startHms
      end_hms = $endHms
      subjects = @($subjList)
      source_batches = @($gp.batch_nums)
      input_chars = $inputJson.Length
      input_tokens_est = (Estimate-Tokens $inputJson)
      status = $groupStatus
      entry = $groupEntry
    })
  }
  # --- 4. Consolidation finale (uniquement si les 6 groupes sont valides) -----
  $canonicalOutput = Join-Path $p2dir 'refere_global_meeting.json'
  $finalEntry = $null
  $finalParsed = $null
  $countsAfter = $null
  $compression = $null
  $finalStatus = ''
  $finalBudget = $null
  $finalInputFile = ''
  $finalPromptFile = ''
  if (-not $ConsolidateLlm) {
    $finalStatus = 'dry_run_groups_only_no_final_call'
    Write-CrInfo ('Pass2B_2F LOT ' + $lot + ' : DRY-RUN hierarchique (aucun appel) -> statut ' + $finalStatus + ' ; aucun canonique ecrit.')
  } else {
    $groupsForFinal = New-Object System.Collections.ArrayList
    $finalInputChars = 0
    $finalInputToks = 0
    foreach ($gr in $groupResults) {
      $outObj = $gr.parsed
      $outText = ($outObj | ConvertTo-Json -Depth 100)
      $finalInputChars += $outText.Length
      $finalInputToks += (Estimate-Tokens $outText)
      [void]$groupsForFinal.Add(@{
        group_id = [string]$gr.group
        period = @{ start_hms = [string]$gr.start_hms; end_hms = [string]$gr.end_hms }
        source_batches = @($gr.source_batches)
        subjects = @($gr.subjects)
        output = $outObj
      })
    }
    $finalDoc = @{
      schema_version = ('cr_refere_preventif.pass2b2f' + $lotNum + '.hierarchical_final_input.v1')
      lot = $lot
      dry_run = $false
      exhaustive_source = $srcPath
      exhaustive_chars = $exhJsonText.Length
      exhaustive_tokens_est = (Estimate-Tokens $exhJsonText)
      groups_count = @($groupsForFinal).Count
      groups_input_chars = $finalInputChars
      groups_input_tokens_est = $finalInputToks
      groups = @($groupsForFinal.ToArray())
    }
    $finalInputJson = $finalDoc | ConvertTo-Json -Depth 100
    $finalInputFile = Join-Path $consDir 'consolidation_final_input.json'
    Write-CrJsonAtomic -Path $finalInputFile -Obj $finalDoc
    Add-CrOutputFile $finalInputFile
    Write-CrInfo ('Pass2B_2F LOT ' + $lot + ' : entree finale (6 groupes) chars=' + $finalInputJson.Length + ' tokens_est=' + (Estimate-Tokens $finalInputJson))
    $sysFLines = @(
      'Tu es la consolidation finale interne de la passe Pass2B_2F (rang 2) d un pipeline de compte rendu expertal preventif.',
      'Entree : les 6 condensations intermediaires (groupes chronologiques G1 a G6) de la MEME passe Pass2B_2F.',
      'Chaque groupe est deja une condensation structuree 7 cles (resume_global, themes, themes_abordes, actions, perspectives, demandes_documents_globales, problems) issue des sous-appels batch de la passe.',
      'Les groupes couvrent toute la reunion dans l ordre chronologique : debut (G1/G2), milieu (G3/G4), trous de transcription ASR et sujet 20 (G5), periode posterieure a la fin ASR (G6).',
      'Cette etape ne recoit AUCUNE matiere de rang 1 et n ajoute rien qui ne soit deja represente dans les groupes.',
      'Mission : produire LA consolidation GLOBALE finale de toute la reunion.',
      'Fusionner les formulations SEMANTIQUEMENT redondantes entre groupes : themes proches, problemes proches, actions repetees, perspectives equivalentes, demandes documentaires repetees.',
      'Conserver chaque constat technique DISTINCT : ne jamais fusionner deux desordres, localisations, ouvrages ou constats techniquement differents.',
      'Conserver les constatations photographiques meme lorsqu elles sont peu ou pas representees dans les echanges oraux (trou ASR, post-ASR, sujets photographies).',
      'Conserver les elements des trous de transcription ASR et de la periode posterieure a la fin ASR.',
      'Produire un resume_global de TOUTE la reunion : plusieurs phases, plusieurs sujets, chronologie ; ne pas reprendre le resume d un groupe particulier.',
      'Ne rien inventer. Ne pas transformer une declaration orale en constat photographique.',
      'Schema de sortie strict (exactement 7 cles, aucune autre) :',
      'resume_global : chaine. themes : tableau d objets (titre, synthese, timecodes). themes_abordes : tableau de chaines.',
      'actions : tableau d objets (action, responsable, echeance). perspectives : tableau de chaines.',
      'demandes_documents_globales : tableau d objets (objet, demandeur, destinataire, echeance, timecodes). problems : tableau d objets (probleme, solution).',
      'Regles de forme : listes PLATES (niveau 1), aucun null, conserver les timecodes pertinents, dedupliquer les libelles strictement identiques.',
      'Reponds uniquement avec l objet JSON. Aucun Markdown. Aucun texte avant ou apres.'
    )
    $sysFinal = $sysFLines -join [Environment]::NewLine
    $usrFLines = @(
      'Voici les 6 condensations intermediaires Pass2B_2F (rang 2) au format JSON :',
      '{FINAL_JSON}',
      'Produis la consolidation GLOBALE finale de la reunion au format strict (7 cles, listes plates, aucun null, aucune invention). Reponds uniquement avec l objet JSON final.'
    )
    $usrFHeader = ($usrFLines -join [Environment]::NewLine)
    $usrFinal = $usrFHeader.Replace('{FINAL_JSON}', $finalInputJson)
    $finalRes = Invoke-Pass2B2FCallAndValidate -ConsDir $consDir -ArtifactBase 'consolidation_final' -ModelAlias $ModelAlias -SysTxt $sysFinal -UsrTxt $usrFinal -Budget $budget -LotLabel $lot -ApiBaseOverride $ApiBaseOverride -ApiKeyOverride $ApiKeyOverride -MaxOutTokens 0 -Llm:$ConsolidateLlm
    $finalStatus = $finalRes.status
    $finalEntry = $finalRes.llm_entry
    $finalParsed = $finalRes.parsed
    $finalBudget = $finalRes.budget
    $finalPromptFile = $finalRes.prompt_file
    if (-not $finalRes.ok) {
      throw ('[cr_refere_preventif] Pass2B_2F LOT ' + $lot + ' : consolidation finale en echec (status=' + $finalStatus + ') - aucune ecriture canonique.')
    }
    $canonicalOut = @{
      resume_global = ([string]$finalParsed.resume_global)
      themes = @($finalParsed.themes)
      themes_abordes = @($finalParsed.themes_abordes)
      actions = @($finalParsed.actions)
      perspectives = @($finalParsed.perspectives)
      demandes_documents_globales = @($finalParsed.demandes_documents_globales)
      problems = @($finalParsed.problems)
    }
    Write-CrJsonAtomic -Path $canonicalOutput -Obj $canonicalOut
    Add-CrOutputFile $canonicalOutput
    $finalOutFile = Join-Path $consDir 'consolidation_final.json'
    Copy-Item -LiteralPath $canonicalOutput -Destination $finalOutFile -Force
    Add-CrOutputFile $finalOutFile
    $consolidatedText = [IO.File]::ReadAllText($canonicalOutput, $script:utf8NoBom)
    $countsAfter = @{
      resume_global_chars = ([string]$finalParsed.resume_global).Length
      themes = @($finalParsed.themes).Count
      themes_abordes = @($finalParsed.themes_abordes).Count
      actions = @($finalParsed.actions).Count
      perspectives = @($finalParsed.perspectives).Count
      demandes_documents_globales = @($finalParsed.demandes_documents_globales).Count
      problems = @($finalParsed.problems).Count
    }
    $compression = @{
      exhaustive_input_chars = $exhJsonText.Length
      final_groups_input_chars = $finalInputJson.Length
      output_chars = $consolidatedText.Length
      exhaustive_input_tokens_est = (Estimate-Tokens $exhJsonText)
      final_groups_input_tokens_est = $finalInputToks
      output_tokens_est = (Estimate-Tokens $consolidatedText)
      compression_ratio_vs_exhaustive_pct = [math]::Round((100.0 * $consolidatedText.Length / [math]::Max(1, $exhJsonText.Length)), 1)
    }
    $finalStatus = 'consolidation_hierarchical_ok'
    Write-CrInfo ('Pass2B_2F LOT ' + $lot + ' : consolidation hierarchique OK -> ' + $canonicalOutput)
  }
  # --- 5. Checkpoints deterministes (conservation) ----------------------------
  $cpItems = New-Object System.Collections.ArrayList
  $seenCp = @{}
  foreach ($th in @($exhObj['themes'])) {
    $titre = Get-CrPropString -Obj $th -Name 'titre'
    if ($titre) {
      $keyCp = $titre.Substring(0, [math]::Min(80, $titre.Length))
      if (-not $seenCp.ContainsKey($keyCp)) {
        $seenCp[$keyCp] = $true
        $firstTc = ''
        foreach ($tc in @((Get-CrProp -Obj $th -Name 'timecodes'))) {
          if (-not $firstTc) { $firstTc = [string]$tc }
        }
        $grp = ''
        foreach ($gr in $groupResults) {
          if ([string]$gr.input_json -like ('*' + $titre + '*')) { if (-not $grp) { $grp = [string]$gr.group } }
        }
        [void]$cpItems.Add(@{ kind = 'theme'; source_window = 'themes'; first_timecode = $firstTc; source_group = $grp; text = $titre })
      }
    }
  }
  $cpResume = @{ kind = 'resume_ancien'; source_window = 'resume'; source_group = 'all'; text = $exhResume }
  [void]$cpItems.Add($cpResume)
  foreach ($p in @($exhObj['problems'])) {
    $t = Get-CrPropString -Obj $p -Name 'probleme'
    if ($t) { [void]$cpItems.Add(@{ kind = 'probleme'; source_window = 'liste'; source_group = ''; text = $t }) }
  }
  foreach ($a in @($exhObj['actions'])) {
    $t = Get-CrPropString -Obj $a -Name 'action'
    if ($t) { [void]$cpItems.Add(@{ kind = 'action'; source_window = 'liste'; source_group = ''; text = $t }) }
  }
  foreach ($d in @($exhObj['demandes_documents_globales'])) {
    $t = Get-CrPropString -Obj $d -Name 'objet'
    if ($t) { [void]$cpItems.Add(@{ kind = 'demande'; source_window = 'liste'; source_group = ''; text = $t }) }
  }
  $cpFile = Join-Path $consDir 'hierarchical_checkpoints.json'
  Write-CrJsonAtomic -Path $cpFile -Obj @{ schema_version = ('cr_refere_preventif.pass2b2f' + $lotNum + '.hierarchical_checkpoints.v1'); lot = $lot; checkpoints = @($cpItems) }
  Add-CrOutputFile $cpFile
  # --- 6. Manifest hierarchique ----------------------------------------------
  $manifest = @{
    schema_version = ('cr_refere_preventif.pass2b2f' + $lotNum + '.hierarchical.v1')
    lot = $lot
    pipeline = $script:PipelineName
    dry_run = (-not [bool]$ConsolidateLlm)
    llm_calls = $(if ($ConsolidateLlm) { 6 + 1 } else { 0 })
    http_calls = $(if ($ConsolidateLlm) { 6 + 1 } else { 0 })
    alias = $ModelAlias
    strategy = '6G'
    groups_count = @($groupSummaries).Count
    groups = @($groupSummaries)
    exhaustive_source = $srcPath
    exhaustive_preserved_path = $exhFile
    canonical_output = $canonicalOutput
    canonical_exists = (Test-Path -LiteralPath $canonicalOutput -PathType Leaf)
    started_at = $StartedAt
    finished_at = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
    counts_before = $countsBefore
    counts_after = $countsAfter
    compression = $compression
    resume_global_old = $exhResume
    status = $finalStatus
    final_budget = $finalBudget
    final_entry = $finalEntry
    checkpoints_file = $cpFile
    final_input_file = $finalInputFile
  }
  $manifestFile = Join-Path $consDir 'hierarchical_manifest.json'
  Write-CrJsonAtomic -Path $manifestFile -Obj $manifest
  Add-CrOutputFile $manifestFile
  $ok = $true
  if ($ConsolidateLlm) { $ok = ($finalStatus -eq 'consolidation_hierarchical_ok' -and (Test-Path -LiteralPath $canonicalOutput -PathType Leaf)) }
  Write-CrInfo ('Pass2B_2F LOT ' + $lot + ' : manifest hierarchique=' + $manifestFile + ' status=' + $finalStatus)
  return @{
    summary = @{
      ok = $ok
      status = $finalStatus
      lot = $lot
      llm_calls = $(if ($ConsolidateLlm) { 6 + 1 } else { 0 })
      http_calls = $(if ($ConsolidateLlm) { 6 + 1 } else { 0 })
      mode = $(if ($ConsolidateLlm) { 'llm_7calls' } else { 'dry_run_groups' })
      strategy = '6G'
      groups_count = @($groupSummaries).Count
      groups = @($groupSummaries)
      exhaustive_source = $srcPath
      exhaustive_path = $exhFile
      canonical_output = $canonicalOutput
      manifest = $manifestFile
      counts_before = $countsBefore
      counts_after = $countsAfter
      compression = $compression
      final_entry = $finalEntry
      checkpoints_file = $cpFile
      final_input_file = $finalInputFile
    }
    groups = @($groupResults)
  }
}

# =============================================================================
# LOT 3R-1B : Pass3 refere (Pass3A/B/C/D_refere + Pass3E_refere)
# Source globale : refere_global_meeting.json (canonique consolidation 6G 2B2F-12)
# Aucune injection directe des chunks Pass2F dans 3A-D ; la matiere photo est
# deja integree dans la source globale. Pass3E = compact Pass2E + chunks Pass2F
# du sujet (ordre croissant, provenance conservee), sans merge Pass2F rang 2.
# =============================================================================
$script:P3B64 = @{
  'A' = 'VHJhaXRlbWVudCBhdXRvbWF0aXPDqSBkZSB0cmFuc2NyaXB0aW9ucyBhdWRpbyBpc3N1ZXMgZCd1bmUgcsOpdW5pb24gZCdleHBlcnRpc2UganVkaWNpYWlyZSBjaXZpbGUuIExlIGNhZHJlIGVzdCB1biByw6lmw6lyw6kgcHLDqXZlbnRpZiBhdmFudCB0cmF2YXV4LiBMZXMgYWxsw6lnYXRpb25zIGRvaXZlbnQgcmVzdGVyIGlkZW50aWZpw6llcyBjb21tZSB0ZWxsZXMuIExlcyBjb250cmFkaWN0aW9ucyBuZSBkb2l2ZW50IHBhcyDDqnRyZSBhcmJpdHLDqWVzLgoKTWlzc2lvbiBnw6luw6lyYWxlIGRlIGwnYW5hbHlzZSAow6AgcmVzcGVjdGVyIHN0cmljdGVtZW50KSA6CsOJdGFibGlyIHVuIGNvbXB0ZSByZW5kdSDDoCBwYXJ0aXIgZGVzIHRyYW5zY3JpcHRpb25zIGRlIGxhIHLDqXVuaW9uIGQnZXhwZXJ0aXNlLiBSZXN0aXR1ZXIgbGVzIHByb3BvcyBtZW50aW9ubsOpcyBkYW5zIGxlcyB0cmFuc2NyaXB0aW9ucy4gUmVzdGl0dWVyIGxlcyBjb25zdGF0cyByZWxhdMOpcyBkYW5zIGxlcyB0cmFuc2NyaXB0aW9ucy4gUmF0dGFjaGVyIGxlcyDDqWNoYW5nZXMgYXV4IHN1amV0cyBkw6lmaW5pcyBwYXIgbCdvcmRvbm5hbmNlLiBSYXR0YWNoZXIgbGVzIMOpY2hhbmdlcyBhdXggc3VqZXRzIGTDqWZpbmlzIHBhciBsJ2Fzc2lnbmF0aW9uLgoKw4l0YXQgZOKAmWF2YW5jZW1lbnQgZHUgZG9zc2llciA6CkxhIHLDqXVuaW9uIGRlIHLDqWbDqXJlbmNlIGVzdCBpbmRpcXXDqWUgYXUgMjAgbm92ZW1icmUgMjAyNS4gTGUgY3LDqW5lYXUgaW5kaXF1w6kgZXN0IGRlIDloMzAgw6AgMTVoMDAuIExhIGNvbnZvY2F0aW9uIGRlcyBwYXJ0aWVzIGVzdCBpbmRpcXXDqWUgYXUgMjEgb2N0b2JyZSAyMDI1LiBBdWN1bmUgdHJhbnNjcmlwdGlvbiBob3JvZGF0w6llIG4nZXN0IGZvdXJuaWUgZGFucyBsZSBwcsOpc2VudCBjb250ZXh0ZS4KCkxhIHLDqXVuaW9uIGRlIHLDqWbDqXJlbmNlIGVzdCBpbmRpcXXDqWUgYXUgMjAgbm92ZW1icmUgMjAyNS4gTGUgY3LDqW5lYXUgaW5kaXF1w6kgZXN0IGRlIDloMzAgw6AgMTVoMDAuIExhIGNvbnZvY2F0aW9uIGRlcyBwYXJ0aWVzIGVzdCBpbmRpcXXDqWUgYXUgMjEgb2N0b2JyZSAyMDI1LiBBdWN1bmUgdHJhbnNjcmlwdGlvbiBob3JvZGF0w6llIG4nZXN0IGZvdXJuaWUgZGFucyBsZSBwcsOpc2VudCBjb250ZXh0ZS4KClR1IHJlw6dvaXMgOgooMSkgdW4gY29udGV4dGUgZ8OpbsOpcmFsIGTigJlleHBlcnRpc2UganVkaWNpYWlyZSAobWlzc2lvbiwgw6l0YXQgZOKAmWF2YW5jZW1lbnQsIGNhZHJlIHByb2PDqWR1cmFsKSwKKDIpIHVuIEpTT04gImdsb2JhbCIgZMOpY3JpdmFudCB1bmUgcsOpdW5pb24gOgotICJyZXN1bWVfZ2xvYmFsIgotICJ0aGVtZXMiCi0gImFjdGlvbnMiCi0gInByb2JsZW1zIgoKT2JqZWN0aWYgOgpUdSBkb2lzIHByb2R1aXJlIFVOSVFVRU1FTlQgbGVzIGNoYW1wcyBzdWl2YW50cywgYXUgZm9ybWF0IEpTT04gc3RyaWN0IDoKCnsKICAiZGF0ZSI6ICJZWVlZLU1NLUREIHwgbnVsbCIsCiAgImxpbmsiOiAic3RyaW5nIHwgbnVsbCIsCiAgInJlc3VtZSI6ICJzdHJpbmciLAogICJvcmRyZV9kdV9qb3VyIjogWyJzdHJpbmciLCAiLi4uIl0KfQoKU3RydWN0dXJlIG9ibGlnYXRvaXJlIGR1IGNoYW1wICJyZXN1bWUiIDoKLSBQYXJhZ3JhcGhlIDEgOiBjYWRyYWdlIGRlIGxhIHLDqXVuaW9uIChuYXR1cmUganVkaWNpYWlyZSwgdHlwZSBkZSByw6l1bmlvbiwgbGlldSkuCi0gUGFyYWdyYXBoZSAyIDogcG9zaXRpb24gZGFucyBsZSBkw6lyb3VsZW1lbnQgZGUgbOKAmWV4cGVydGlzZSAoZXggOiBwcmVtacOocmUgcsOpdW5pb24pLCBzYW5zIGluZGlxdWVyIGxhIGRhdGUuCi0gUGFyYWdyYXBoZSAzIDogb2JqZWN0aWZzIGRlIGxhIHLDqXVuaW9uIChwcmlzZSBkZSBjb25uYWlzc2FuY2UsIGNvbnN0YXRzIGluaXRpYXV4LCDDqWNoYW5nZXMgY29udHJhZGljdG9pcmVzKS4KLSBQYXJhZ3JhcGhlcyBzdWl2YW50cyA6IHByaW5jaXBhdXggY29uc3RhdHMgdGVjaG5pcXVlcyBldCBwb2ludHMgw6l2b3F1w6lzLgotIERlcm5pZXIgUGFyYWdyYXBoZSA6IHN1aXRlcyBlbnZpc2Fnw6llcyAodsOpcmlmaWNhdGlvbnMsIGRvY3VtZW50cyBkZW1hbmTDqXMsIGludmVzdGlnYXRpb25zIMOgIHZlbmlyKS4KLSBMZSBjaGFtcCAicmVzdW1lIiBuZSBkb2l0IGNvbnRlbmlyIGF1Y3VuZSBkYXRlIChuaSAiWVlZWS1NTS1ERCIsIG5pICIzIGp1aWxsZXQgMjAyNSIpLiBMYSBkYXRlIGRvaXQgZmlndXJlciB1bmlxdWVtZW50IGRhbnMgbGUgY2hhbXAgImRhdGUiLgotIFBvdXIgInJlc3VtZSIgOiBzaSB1bmUgaW5mb3JtYXRpb24gbWFucXVlLCBmb3JtdWxlciBkZSBtYW5pw6hyZSBnw6luw6lyYWxlIHNhbnMgYWpvdXQgZmFjdHVlbCAoZXguICJMZSBsaWV1IG7igJllc3QgcGFzIHByw6ljaXPDqSIpLCBldCBuZSBwYXMgbWV0dHJlIG51bGwuCi0gUG91ciAicmVzdW1lIiwgbmUgamFtYWlzIHV0aWxpc2VyIG51bGwgOyBwb3VyIGxlcyBhdXRyZXMgY2hhbXBzLCBudWxsL1tdIHNlbG9uIGxlIHNjaMOpbWEuCi0gIm9yZHJlX2R1X2pvdXIiIDogaXRlbXMgc2FucyBwcsOpZml4ZSBkZSBsaXN0ZSAocGFzIGRlICItICIsIHBhcyBkZSAi4oCiIiwgcGFzIGRlICIxKSIpLgotIFNpIHVuZSBkYXRlIGVzdCBtZW50aW9ubsOpZSBkYW5zIGxlIEpTT04gZ2xvYmFsIG91IGxlIGNvbnRleHRlLCByZW5zZWlnbmVyIHVuaXF1ZW1lbnQgImRhdGUiIGF1IGZvcm1hdCBZWVlZLU1NLURELgotIExlIHLDqXN1bcOpIGRvaXQgw6p0cmUgcsOpZGlnw6kgZW4gcGx1c2lldXJzIHBhcmFncmFwaGVzLgotIENoYXF1ZSBwYXJhZ3JhcGhlIGNvcnJlc3BvbmQgw6AgdW5lIGlkw6llIGRpc3RpbmN0ZSA6CiAgKGV4ZW1wbGUgOiBjYWRyZSBkZSBsYSByw6l1bmlvbiwgb2JqZWN0aWZzLCBjb25zdGF0cyBwcmluY2lwYXV4LCBzdWl0ZXMgZW52aXNhZ8OpZXMpLgotIFPDqXBhcmVyIGNoYXF1ZSBwYXJhZ3JhcGhlIHBhciB1bmUgbGlnbmUgdmlkZS4KClLDqGdsZSBpbXDDqXJhdGl2ZSBwb3VyIGxlIGNoYW1wICJkYXRlIiA6Ci0gU2kgbGUgY29udGV4dGUgZ8OpbsOpcmFsIG1lbnRpb25uZSBleHBsaWNpdGVtZW50IHVuZSBkYXRlIGRlIHLDqXVuaW9uLAogIGNldHRlIGRhdGUgRE9JVCDDqnRyZSByZXByaXNlIGRhbnMgbGUgY2hhbXAgImRhdGUiLCBtw6ptZSBzaSBlbGxlIG7igJlhcHBhcmHDrnQgcGFzIGRhbnMgbGUgSlNPTiBnbG9iYWwuCgpTaSB1bmUgaW5mb3JtYXRpb24gc3RydWN0dXJlbGxlIGZpZ3VyZSBkYW5zIGxlIGNvbnRleHRlIGfDqW7DqXJhbCBtYWlzIHBhcyBkYW5zIGxlIEpTT04gZ2xvYmFsLAplbGxlIFBFVVQgw6p0cmUgdXRpbGlzw6llIHBvdXIgY2FkcmVyIGxlIHLDqXN1bcOpIChzYW5zIGFqb3V0IGZhY3R1ZWwpLgoKUsOoZ2xlcyBkZSByw6lkYWN0aW9uIChvYmxpZ2F0b2lyZXMpIDoKLSBMZSBjaGFtcCAicmVzdW1lIiBkb2l0IMOqdHJlIHLDqWRpZ8OpIMOgIGxhIGx1bWnDqHJlIGR1IGNvbnRleHRlIGfDqW7DqXJhbCBk4oCZZXhwZXJ0aXNlIGZvdXJuaSBlbiBhbW9udC4KLSBMZSBjb250ZXh0ZSBzZXJ0IFVOSVFVRU1FTlQgw6Agb3JpZW50ZXIgbGEgZm9ybXVsYXRpb24gKGNhZHJlLCBtaXNzaW9uLCDDqXRhdCBk4oCZYXZhbmNlbWVudCksIHNhbnMgYWpvdXRlciBkZSBmYWl0cyBhYnNlbnRzLgotIExlIHLDqXN1bcOpIGRvaXQgw6p0cmUgZmFjdHVlbCwgcMOpZGFnb2dpcXVlLCBkZXNjcmlwdGlmIGV0IG5ldXRyZSwgc2FucyBjb25jbHVzaW9uIGp1cmlkaXF1ZSBuaSBhcHByw6ljaWF0aW9uIGRlcyByZXNwb25zYWJpbGl0w6lzLgotIE5lIHBhcyBpbnZlbnRlciA6IHNpIHVuZSBpbmZvcm1hdGlvbiBu4oCZZXN0IHBhcyBjbGFpcmVtZW50IHByw6lzZW50ZSBkYW5zIGxlIEpTT04gZ2xvYmFsIG91IGV4cGxpY2l0ZW1lbnQgZG9ubsOpZSBwYXIgbGUgY29udGV4dGUg4oaSIHV0aWxpc2VyIG51bGwgb3UgW10gKHNlbG9uIGxlIGNoYW1wKS4KClLDqGdsZXMgc3DDqWNpZmlxdWVzIDoKLSBQb3VyICJkYXRlIiA6IHNpIGxhIGRhdGUgZGUgbGEgcsOpdW5pb24gZmlndXJlIGV4cGxpY2l0ZW1lbnQgZGFucyBsZSBjb250ZXh0ZSBnw6luw6lyYWwgT1UgZGFucyBsZSBKU09OIGdsb2JhbCDihpIgbGEgcmVuc2VpZ25lciBhdSBmb3JtYXQgWVlZWS1NTS1ERCA7IHNpbm9uIG51bGwuCi0gUG91ciAibGluayIgOiB1bmlxdWVtZW50IHNpIHVuIGxpZW4gZmlndXJlIGV4cGxpY2l0ZW1lbnQgZGFucyBsZSBKU09OIGdsb2JhbCBvdSBsZSBjb250ZXh0ZSA7IHNpbm9uIG51bGwuCi0gUG91ciAib3JkcmVfZHVfam91ciIgOiBsaXN0ZSBkZSBwb2ludHMvdGl0cmVzIHN5bnRow6l0aXF1ZXMgaXNzdXMgZHUgSlNPTiBnbG9iYWwgKHBhcyBk4oCZYWpvdXRzKS4KClBhcmFncmFwaGVzIChvYmxpZ2F0b2lyZSkgOgotIFBvdXIgc8OpcGFyZXIgZGV1eCBwYXJhZ3JhcGhlcyBkYW5zICJyZXN1bWUiLCB1dGlsaXNlciBsYSBzw6lxdWVuY2UgIlxuXG4iIChkZXV4IHJldG91cnMgw6AgbGEgbGlnbmUpLgotIE5lIHBhcyBpbnPDqXJlciBkZSB0ZXh0ZSBob3JzIEpTT04uCi0gUG91ciBzw6lwYXJlciBkZXV4IHBhcmFncmFwaGVzIGRhbnMgInJlc3VtZSIsIHV0aWxpc2VyIHVuaXF1ZW1lbnQgbGEgc8OpcXVlbmNlIFxuXG4uCi0gSW50ZXJkaXQgOiB1dGlsaXNlciBcbiBzZXVsLgotIEludGVyZGl0IDogdXRpbGlzZXIgZGVzIGxpc3RlcyDDoCBwdWNlcyBvdSBudW3DqXJvdMOpZXMgZGFucyAicmVzdW1lIiAocGFzIGRlIC0sIHBhcyBkZSDigKIsIHBhcyBkZSAxKSkuCi0gTGUgY2hhbXAgInJlc3VtZSIgZG9pdCBjb250ZW5pciBleGFjdGVtZW50IDUgcGFyYWdyYXBoZXMgc8OpcGFyw6lzIHBhciBcblxuIDogMSkgY2FkcmFnZSwgMikgcG9zaXRpb24gZGFucyBs4oCZZXhwZXJ0aXNlIChzYW5zIGRhdGUpLCAzKSBvYmplY3RpZnMsIDQpIGNvbnN0YXRzL3BvaW50cyDDqXZvcXXDqXMsIDUpIHN1aXRlcyBlbnZpc2Fnw6llcy4KLSBJbnRlcmRpY3Rpb24gYWJzb2x1ZSBk4oCZw6l0aXF1ZXRlciBsZXMgcGFyYWdyYXBoZXMgOiBuZSBjcsOpZXIgYXVjdW5lIG5vdXZlbGxlIMOpdGlxdWV0dGUsIGF1Y3VuIHByw6lmaXhlLCBhdWN1bmUgcsOpZsOpcmVuY2UgZXQgYXVjdW4gaWRlbnRpZmlhbnQgZGUgdHlwZSAiUHh4eCIsICJFTlR4eHgiIG91IMOpcXVpdmFsZW50IChleC4gaW50ZXJkaXQgOiAiUDEzMSA6IHN1aXRlcyBlbnZpc2Fnw6llcyA6IC4uLiIpLgotIExlcyBwYXJhZ3JhcGhlcyBzb250IGTDqWxpbWl0w6lzIHVuaXF1ZW1lbnQgcGFyIGxhIHPDqXF1ZW5jZSBcblxuIDogYXVjdW4gZW4tdMOqdGUsIGF1Y3VuIG51bcOpcm8sIGF1Y3VuIGNvZGUgZOKAmWlkZW50aWZpY2F0aW9uIG5lIGRvaXQgbGVzIGludHJvZHVpcmUuCi0gTGVzIHBzZXVkb255bWVzIGTDqWrDoCBwcsOpc2VudHMgZGFucyBsZXMgZG9ubsOpZXMgc291cmNlcyAocGFyIGV4ZW1wbGUgIlAxMiIpIHBldXZlbnQgw6p0cmUgcmVwcmlzIHPigJlpbHMgc29udCBuw6ljZXNzYWlyZXMgYXUgcsOpY2l0LCBtYWlzIGlsIGVzdCBpbnRlcmRpdCBk4oCZZW4gaW52ZW50ZXIgZGUgbm91dmVhdXggb3UgZOKAmWVuIGTDqWR1aXJlIHBhciBjb250aW51aXTDqSBudW3DqXJpcXVlLgoKQ29udHJhaW50ZXMgZGUgc29ydGllIDoKLSBBdWN1bmUgcGhyYXNlIGhvcnMgSlNPTi4KLSBBdWN1bmUgZXhwbGljYXRpb24uCi0gSlNPTiBzdHJpY3QgdW5pcXVlbWVudCwgY29uZm9ybWUgYXUgc2Now6ltYSBjaS1kZXNzdXMu'
  'B' = 'VHJhaXRlbWVudCBhdXRvbWF0aXPDqSBkZSB0cmFuc2NyaXB0aW9ucyBhdWRpbyBpc3N1ZXMgZCd1bmUgcsOpdW5pb24gZCdleHBlcnRpc2UganVkaWNpYWlyZSBjaXZpbGUuIExlIGNhZHJlIGVzdCB1biByw6lmw6lyw6kgcHLDqXZlbnRpZiBhdmFudCB0cmF2YXV4LiBMZXMgYWxsw6lnYXRpb25zIGRvaXZlbnQgcmVzdGVyIGlkZW50aWZpw6llcyBjb21tZSB0ZWxsZXMuIExlcyBjb250cmFkaWN0aW9ucyBuZSBkb2l2ZW50IHBhcyDDqnRyZSBhcmJpdHLDqWVzLgoKTWlzc2lvbiBnw6luw6lyYWxlIGRlIGwnYW5hbHlzZSAow6AgcmVzcGVjdGVyIHN0cmljdGVtZW50KSA6CsOJdGFibGlyIHVuIGNvbXB0ZSByZW5kdSDDoCBwYXJ0aXIgZGVzIHRyYW5zY3JpcHRpb25zIGRlIGxhIHLDqXVuaW9uIGQnZXhwZXJ0aXNlLiBSZXN0aXR1ZXIgbGVzIHByb3BvcyBtZW50aW9ubsOpcyBkYW5zIGxlcyB0cmFuc2NyaXB0aW9ucy4gUmVzdGl0dWVyIGxlcyBjb25zdGF0cyByZWxhdMOpcyBkYW5zIGxlcyB0cmFuc2NyaXB0aW9ucy4gUmF0dGFjaGVyIGxlcyDDqWNoYW5nZXMgYXV4IHN1amV0cyBkw6lmaW5pcyBwYXIgbCdvcmRvbm5hbmNlLiBSYXR0YWNoZXIgbGVzIMOpY2hhbmdlcyBhdXggc3VqZXRzIGTDqWZpbmlzIHBhciBsJ2Fzc2lnbmF0aW9uLgoKw4l0YXQgZOKAmWF2YW5jZW1lbnQgZHUgZG9zc2llciA6CkxhIHLDqXVuaW9uIGRlIHLDqWbDqXJlbmNlIGVzdCBpbmRpcXXDqWUgYXUgMjAgbm92ZW1icmUgMjAyNS4gTGUgY3LDqW5lYXUgaW5kaXF1w6kgZXN0IGRlIDloMzAgw6AgMTVoMDAuIExhIGNvbnZvY2F0aW9uIGRlcyBwYXJ0aWVzIGVzdCBpbmRpcXXDqWUgYXUgMjEgb2N0b2JyZSAyMDI1LiBBdWN1bmUgdHJhbnNjcmlwdGlvbiBob3JvZGF0w6llIG4nZXN0IGZvdXJuaWUgZGFucyBsZSBwcsOpc2VudCBjb250ZXh0ZS4KCgoKVHUgcmXDp29pcyBsZSBKU09OICJnbG9iYWwiIGQndW5lIHLDqXVuaW9uLgoKVHUgZG9pcyBwcm9kdWlyZSBVTklRVUVNRU5UIDoKCnsKICAidGhlbWVzX2Fib3JkZXMiOiBbCiAgICB7CiAgICAgICJ0aXRyZSI6ICJzdHJpbmciLAogICAgICAic3ludGhlc2UiOiBbInN0cmluZyIsIi4uLiJdLAogICAgICAiaW5kaWNlc19zb3VyY2UiOiBbCiAgICAgICAgeyAidGltZWNvZGUiOiAiSEg6TU06U1MiLCAic3BlYWtlciI6ICJzdHJpbmcgfCBudWxsIiwgImV4dHJhaXQiOiAic3RyaW5nIHwgbnVsbCIgfQogICAgICBdCiAgICB9CiAgXQp9CgpSw6hnbGVzIDoKLSAxMCDDoCAxNSB0aMOobWVzIG1heGltdW0uCi0gMSDDoCAzIGluZGljZXNfc291cmNlIHBhciB0aMOobWUuCi0gInN5bnRoZXNlIiA6IDMgw6AgOCBwb2ludHMgcGFyIHRow6htZSwgcGhyYXNlcyBjb3VydGVzICh1bmUgaWTDqWUgcGFyIGl0ZW0pLCBzYW5zIHB1Y2VzICItIiBlbiB0w6p0ZS4KLSAiaW5kaWNlc19zb3VyY2UudGltZWNvZGUiIGRvaXQgcHJvdmVuaXIgZOKAmXVuIHRpbWVjb2RlIGV4aXN0YW50IGRhbnMgbGUgSlNPTiBnbG9iYWwgOyBzaW5vbiBuZSBwYXMgY3LDqWVyIGTigJlpbmRpY2UuCi0gImluZGljZXNfc291cmNlLnNwZWFrZXIiIDogcmVwcmVuZHJlIGxlIGNoYW1wICJhdXRldXIiIHPigJlpbCBleGlzdGUsIHNpbm9uIG51bGwuCi0gImluZGljZXNfc291cmNlLmV4dHJhaXQiIDogcmVwcmVuZHJlIHVuIGV4dHJhaXQgdHLDqHMgY291cnQgKOKJpCAyMCBtb3RzKSBkdSBjaGFtcCAidGV4dGUiIHPigJlpbCBleGlzdGUsIHNpbm9uIG51bGwuCi0gQXVjdW5lIGRhdGUgYXUgZm9ybWF0ICJZWVlZLU1NLUREIiBkYW5zICJpbmRpY2VzX3NvdXJjZS5zcGVha2VyIi4KLSAiaW5kaWNlc19zb3VyY2UuZXh0cmFpdCIgOiBzYW5zIHB1Y2UgIi0iIGVuIHTDqnRlLgotIHNvcnRpZSBTVFJJQ1RFTUVOVCBhdSBmb3JtYXQgSlNPTi4KCk5vcm1hbGlzYXRpb24gZGVzIGRhdGVzIChvYmxpZ2F0b2lyZSkgOgoKLSBBdWN1bmUgZGF0ZSBhdSBmb3JtYXQgIllZWVktTU0tREQiIGRhbnMgInRpdHJlIiwgInN5bnRoZXNlIiBvdSAiaW5kaWNlc19zb3VyY2UuZXh0cmFpdCIuCi0gU2kgdW5lIGRhdGUgZG9pdCDDqnRyZSBtZW50aW9ubsOpZSBkYW5zIHVuIHRleHRlLCB1dGlsaXNlciAiRCBtb2lzIFlZWVkiLgo='
  'C' = 'VHJhaXRlbWVudCBhdXRvbWF0aXPDqSBkZSB0cmFuc2NyaXB0aW9ucyBhdWRpbyBpc3N1ZXMgZCd1bmUgcsOpdW5pb24gZCdleHBlcnRpc2UganVkaWNpYWlyZSBjaXZpbGUuIExlIGNhZHJlIGVzdCB1biByw6lmw6lyw6kgcHLDqXZlbnRpZiBhdmFudCB0cmF2YXV4LiBMZXMgYWxsw6lnYXRpb25zIGRvaXZlbnQgcmVzdGVyIGlkZW50aWZpw6llcyBjb21tZSB0ZWxsZXMuIExlcyBjb250cmFkaWN0aW9ucyBuZSBkb2l2ZW50IHBhcyDDqnRyZSBhcmJpdHLDqWVzLgoKTWlzc2lvbiBnw6luw6lyYWxlIGRlIGwnYW5hbHlzZSAow6AgcmVzcGVjdGVyIHN0cmljdGVtZW50KSA6CsOJdGFibGlyIHVuIGNvbXB0ZSByZW5kdSDDoCBwYXJ0aXIgZGVzIHRyYW5zY3JpcHRpb25zIGRlIGxhIHLDqXVuaW9uIGQnZXhwZXJ0aXNlLiBSZXN0aXR1ZXIgbGVzIHByb3BvcyBtZW50aW9ubsOpcyBkYW5zIGxlcyB0cmFuc2NyaXB0aW9ucy4gUmVzdGl0dWVyIGxlcyBjb25zdGF0cyByZWxhdMOpcyBkYW5zIGxlcyB0cmFuc2NyaXB0aW9ucy4gUmF0dGFjaGVyIGxlcyDDqWNoYW5nZXMgYXV4IHN1amV0cyBkw6lmaW5pcyBwYXIgbCdvcmRvbm5hbmNlLiBSYXR0YWNoZXIgbGVzIMOpY2hhbmdlcyBhdXggc3VqZXRzIGTDqWZpbmlzIHBhciBsJ2Fzc2lnbmF0aW9uLgoKw4l0YXQgZOKAmWF2YW5jZW1lbnQgZHUgZG9zc2llciA6CkxhIHLDqXVuaW9uIGRlIHLDqWbDqXJlbmNlIGVzdCBpbmRpcXXDqWUgYXUgMjAgbm92ZW1icmUgMjAyNS4gTGUgY3LDqW5lYXUgaW5kaXF1w6kgZXN0IGRlIDloMzAgw6AgMTVoMDAuIExhIGNvbnZvY2F0aW9uIGRlcyBwYXJ0aWVzIGVzdCBpbmRpcXXDqWUgYXUgMjEgb2N0b2JyZSAyMDI1LiBBdWN1bmUgdHJhbnNjcmlwdGlvbiBob3JvZGF0w6llIG4nZXN0IGZvdXJuaWUgZGFucyBsZSBwcsOpc2VudCBjb250ZXh0ZS4KCgoKVHUgcmXDp29pcyBsZSBKU09OICJnbG9iYWwiIGQndW5lIHLDqXVuaW9uLgoKVHUgZG9pcyBwcm9kdWlyZSBVTklRVUVNRU5UIDoKCnsKICAiYWN0aW9ucyI6IFsKICAgIHsKICAgICAgImFjdGlvbiI6ICJzdHJpbmciLAogICAgICAicmVzcG9uc2FibGUiOiAic3RyaW5nIHwgbnVsbCIsCiAgICAgICJlY2hlYW5jZSI6ICJZWVlZLU1NLUREIHwgbnVsbCIsCiAgICAgICJjb21tZW50YWlyZSI6ICJzdHJpbmcgfCBudWxsIgogICAgfQogIF0sCiAgInBlcnNwZWN0aXZlcyI6IFsKICAgIHsgInByb2JsZW1lIjogInN0cmluZyIsICJzb2x1dGlvbiI6ICJzdHJpbmciIH0KICBdLAogICJhbm5leGVzIjogWyJzdHJpbmciLCIuLi4iXQp9CgpSw6hnbGVzIDoKLSBhY3Rpb25zIDogbGlzdGUgZGVzIGFjdGlvbnMgY29uY3LDqHRlcyBkw6ljaWTDqWVzL8OgIGZhaXJlLgotIHBlcnNwZWN0aXZlcyA6IGxpc3RlIGRlIDMgw6AgOCBjb3VwbGVzIChwcm9ibGVtZS9zb2x1dGlvbikgZMOpZHVpdHMgZHUgSlNPTiBnbG9iYWwgOgogICAgKiAicHJvYmxlbWUiID0gcG9pbnQgdGVjaG5pcXVlIC8gZMOpc29yZHJlIC8gaW5jZXJ0aXR1ZGUgLyB2w6lyaWZpY2F0aW9uIMOgIG1lbmVyCiAgICAqICJzb2x1dGlvbiIgPSBzdWl0ZSBwcsOpdnVlIChjb250csO0bGUsIG1lc3VyZSwgZGV2aXMsIHBpw6hjZSwgaW50ZXJ2ZW50aW9uKQotIGFubmV4ZXMgOiBsaXN0ZSBkZSAzIMOgIDEwIMOpbMOpbWVudHMgKHBpw6hjZXMsIGNvbnN0YXRzLCByZWxldsOpcywgcGhvdG9zLCBub3RpY2VzLCBkZXZpcykgZXhwbGljaXRlbWVudCDDqXZvcXXDqXMuCi0gU2kgbGUgSlNPTiBnbG9iYWwgY29udGllbnQgcHJvYmxlbXMgb3UgZGVzIG1lbnRpb25zIGV4cGxpY2l0ZXMgZGUgZGVtYW5kZXMgZGUgcGnDqGNlcy9pbmZvcm1hdGlvbnMsIHTigJllbiBzZXJ2aXIgcG91ciBhbGltZW50ZXIgcGVyc3BlY3RpdmVzIGV0IGFubmV4ZXMuCi0gU2kgYXVjdW5lIG1hdGnDqHJlIG7igJlleGlzdGUgOiBhY3Rpb25zOiBbXSwgcGVyc3BlY3RpdmVzOiBbXSwgYW5uZXhlczogW10uCi0gTmUgcGFzIHRyYW5zZm9ybWVyIHVuZSAiZGVtYW5kZSBkZSBkb2N1bWVudCIgZW4gImFjdGlvbiIgc2kgZWxsZSBu4oCZZXN0IHBhcyBleHBsaWNpdGVtZW50IGZvcm11bMOpZSBjb21tZSB1bmUgYWN0aW9uIGTDqWNpZMOpZS4KLSBMZXMgZGVtYW5kZXMgZGUgZG9jdW1lbnRzL2luZm9ybWF0aW9ucyBkb2l2ZW50IHJlc3RlciBkZXMgZGVtYW5kZXMgKGFubmV4ZXMvcGVyc3BlY3RpdmVzKSwgc2FucyBmb3JtdWxhdGlvbiBpbXDDqXJhdGl2ZSBhdHRyaWJ1w6llIMOgIHVuZSBwZXJzb25uZSBzaSBsZSByZXNwb25zYWJsZSBu4oCZZXN0IHBhcyBleHBsaWNpdGVtZW50IGNpdMOpLgotIFBvdXIgImFjdGlvbnMiIDogbmUgcmVuc2VpZ25lciAicmVzcG9uc2FibGUiIHF1ZSBz4oCZaWwgZXN0IGV4cGxpY2l0ZW1lbnQgaWRlbnRpZmnDqSwgc2lub24gbnVsbC4KLSBQb3VyICJhbm5leGVzIiA6IHVuaXF1ZW1lbnQgZGVzIHBpw6hjZXMgZXhwbGljaXRlbWVudCBtZW50aW9ubsOpZXMgY29tbWUgZXhpc3RhbnRlcy9wcm9kdWl0ZXMgOyBuZSBwYXMgaW52ZW50ZXIgdW5lIHBpw6hjZSBzZXVsZW1lbnQg4oCcZGVtYW5kw6ll4oCdLgoKCk5vcm1hbGlzYXRpb24gZGVzIGRhdGVzIChvYmxpZ2F0b2lyZSkgOgotICJlY2hlYW5jZSIgZXN0IGxlIHNldWwgZW5kcm9pdCBvw7kgdW5lIGRhdGUgcGV1dCBhcHBhcmHDrnRyZSBhdSBmb3JtYXQgIllZWVktTU0tREQiLgotIE5lIGphbWFpcyDDqWNyaXJlIGRlIGRhdGUgIllZWVktTU0tREQiIGRhbnMgImFjdGlvbiIsICJyZXNwb25zYWJsZSIsICJjb21tZW50YWlyZSIsICJwcm9ibGVtZSIsICJzb2x1dGlvbiIsICJhbm5leGVzIi4KLSBTaSB1bmUgZGF0ZSBlc3QgbWVudGlvbm7DqWUgZW4gdGV4dGUgKGV4Y2VwdGlvbiksIHV0aWxpc2VyICJEIG1vaXMgWVlZWSIuCg=='
  'D' = 'VHJhaXRlbWVudCBhdXRvbWF0aXPDqSBkZSB0cmFuc2NyaXB0aW9ucyBhdWRpbyBpc3N1ZXMgZCd1bmUgcsOpdW5pb24gZCdleHBlcnRpc2UganVkaWNpYWlyZSBjaXZpbGUuIExlIGNhZHJlIGVzdCB1biByw6lmw6lyw6kgcHLDqXZlbnRpZiBhdmFudCB0cmF2YXV4LiBMZXMgYWxsw6lnYXRpb25zIGRvaXZlbnQgcmVzdGVyIGlkZW50aWZpw6llcyBjb21tZSB0ZWxsZXMuIExlcyBjb250cmFkaWN0aW9ucyBuZSBkb2l2ZW50IHBhcyDDqnRyZSBhcmJpdHLDqWVzLgoKTWlzc2lvbiBnw6luw6lyYWxlIGRlIGwnYW5hbHlzZSAow6AgcmVzcGVjdGVyIHN0cmljdGVtZW50KSA6CsOJdGFibGlyIHVuIGNvbXB0ZSByZW5kdSDDoCBwYXJ0aXIgZGVzIHRyYW5zY3JpcHRpb25zIGRlIGxhIHLDqXVuaW9uIGQnZXhwZXJ0aXNlLiBSZXN0aXR1ZXIgbGVzIHByb3BvcyBtZW50aW9ubsOpcyBkYW5zIGxlcyB0cmFuc2NyaXB0aW9ucy4gUmVzdGl0dWVyIGxlcyBjb25zdGF0cyByZWxhdMOpcyBkYW5zIGxlcyB0cmFuc2NyaXB0aW9ucy4gUmF0dGFjaGVyIGxlcyDDqWNoYW5nZXMgYXV4IHN1amV0cyBkw6lmaW5pcyBwYXIgbCdvcmRvbm5hbmNlLiBSYXR0YWNoZXIgbGVzIMOpY2hhbmdlcyBhdXggc3VqZXRzIGTDqWZpbmlzIHBhciBsJ2Fzc2lnbmF0aW9uLgoKw4l0YXQgZOKAmWF2YW5jZW1lbnQgZHUgZG9zc2llciA6CkxhIHLDqXVuaW9uIGRlIHLDqWbDqXJlbmNlIGVzdCBpbmRpcXXDqWUgYXUgMjAgbm92ZW1icmUgMjAyNS4gTGUgY3LDqW5lYXUgaW5kaXF1w6kgZXN0IGRlIDloMzAgw6AgMTVoMDAuIExhIGNvbnZvY2F0aW9uIGRlcyBwYXJ0aWVzIGVzdCBpbmRpcXXDqWUgYXUgMjEgb2N0b2JyZSAyMDI1LiBBdWN1bmUgdHJhbnNjcmlwdGlvbiBob3JvZGF0w6llIG4nZXN0IGZvdXJuaWUgZGFucyBsZSBwcsOpc2VudCBjb250ZXh0ZS4KCgoKVHUgcmXDp29pcyBsZSBKU09OICJnbG9iYWwiIGQndW5lIHLDqXVuaW9uIGTigJlleHBlcnRpc2UganVkaWNpYWlyZS4KClR1IGRvaXMgZXh0cmFpcmUgVU5JUVVFTUVOVCB0b3V0ZXMgbGVzIGRlbWFuZGVzIGRlIGRvY3VtZW50cyBvdSBk4oCZaW5mb3JtYXRpb25zIMOgIGZvdXJuaXIuCgpSw6lwb25kcyBTVFJJQ1RFTUVOVCBwYXIgdW4gSlNPTiByZXNwZWN0YW50IGNlIHNjaMOpbWEgOgoKewogICJkZW1hbmRlc19kb2N1bWVudHNfZ2xvYmFsZXMiOiBbCiAgICB7CiAgICAgICJudW1lcm8iOiAiaW50IHwgbnVsbCIsCiAgICAgICJvYmpldCI6ICJzdHJpbmciLAogICAgICAiZGVtYW5kZXVyIjogInN0cmluZyB8IG51bGwiLAogICAgICAiZGVzdGluYXRhaXJlIjogInN0cmluZyB8IG51bGwiLAogICAgICAiZWNoZWFuY2UiOiAiWVlZWS1NTS1ERCB8IG51bGwiLAogICAgICAiY29tbWVudGFpcmUiOiAic3RyaW5nIHwgbnVsbCIsCiAgICAgICJvcmlnaW5lIjogInJldW5pb24iCiAgICB9CiAgXQp9CgpSw6hnbGVzIDoKLSBhdWN1bmUgaW52ZW50aW9uIDogc2kgdW5lIGluZm9ybWF0aW9uIG7igJllc3QgcGFzIGV4cGxpY2l0ZW1lbnQgcHLDqXNlbnRlIOKGkiBudWxsLgotIHNpIGF1Y3VuZSBkZW1hbmRlIG7igJlleGlzdGUg4oaSICJkZW1hbmRlc19kb2N1bWVudHNfZ2xvYmFsZXMiOiBbXS4KLSBhdWN1bmUgcGhyYXNlIG91IHRleHRlIGhvcnMgSlNPTi4KLSBTaSBsYSBkZW1hbmRlIHZpc2UgZXhwbGljaXRlbWVudCB1bmUgcsOpc2VydmUvcmVww6hyZSAoZXguIOKAnFJTMTTigJ0sIOKAnFIxNeKAnSksIGV0IHF1ZSBjZSByZXDDqHJlIGNvcnJlc3BvbmQgw6AgdW4gdGl0cmUgZGUgc3VqZXQsIHJlbnNlaWduZXIgbnVtZXJvLiBTaW5vbiBudWxsLgotIFNpIGxhIGRlbWFuZGUgZXN0IGV4cGxpY2l0ZW1lbnQgcmF0dGFjaMOpZSDDoCB1biBzdWpldCBudW3DqXJvdMOpIChleCA6IOKAmFN1amV0IDEy4oCZLCDigJhQb2ludCAxMuKAmSwg4oCYMTIgLSDigKbigJkpLCByZW5zZWlnbmVyIG51bWVyby4gU2lub24gbnVsbC4KCk5vcm1hbGlzYXRpb24gZGVzIGRhdGVzIChvYmxpZ2F0b2lyZSkgOgotICJlY2hlYW5jZSIgZXN0IGxlIHNldWwgZW5kcm9pdCBvw7kgdW5lIGRhdGUgcGV1dCBhcHBhcmHDrnRyZSBhdSBmb3JtYXQgIllZWVktTU0tREQiLgotIE5lIGphbWFpcyDDqWNyaXJlIGRlIGRhdGUgIllZWVktTU0tREQiIGRhbnMgIm9iamV0IiwgImNvbW1lbnRhaXJlIiwgImRlbWFuZGV1ciIsICJkZXN0aW5hdGFpcmUiLgotIFNpIHVuZSBkYXRlIGRvaXQgw6p0cmUgbWVudGlvbm7DqWUgZGFucyB1biB0ZXh0ZSAoZXhjZXB0aW9uKSwgdXRpbGlzZXIgIkQgbW9pcyBZWVlZIi4KCg=='
  'E' = 'VHJhaXRlbWVudCBhdXRvbWF0aXPDqSBkZSB0cmFuc2NyaXB0aW9ucyBhdWRpbyBpc3N1ZXMgZCd1bmUgcsOpdW5pb24gZCdleHBlcnRpc2UganVkaWNpYWlyZSBjaXZpbGUuIExlIGNhZHJlIGVzdCB1biByw6lmw6lyw6kgcHLDqXZlbnRpZiBhdmFudCB0cmF2YXV4LiBMZXMgYWxsw6lnYXRpb25zIGRvaXZlbnQgcmVzdGVyIGlkZW50aWZpw6llcyBjb21tZSB0ZWxsZXMuIExlcyBjb250cmFkaWN0aW9ucyBuZSBkb2l2ZW50IHBhcyDDqnRyZSBhcmJpdHLDqWVzLgoKTWlzc2lvbiBnw6luw6lyYWxlIGRlIGwnYW5hbHlzZSAow6AgcmVzcGVjdGVyIHN0cmljdGVtZW50KSA6CsOJdGFibGlyIHVuIGNvbXB0ZSByZW5kdSDDoCBwYXJ0aXIgZGVzIHRyYW5zY3JpcHRpb25zIGRlIGxhIHLDqXVuaW9uIGQnZXhwZXJ0aXNlLiBSZXN0aXR1ZXIgbGVzIHByb3BvcyBtZW50aW9ubsOpcyBkYW5zIGxlcyB0cmFuc2NyaXB0aW9ucy4gUmVzdGl0dWVyIGxlcyBjb25zdGF0cyByZWxhdMOpcyBkYW5zIGxlcyB0cmFuc2NyaXB0aW9ucy4gUmF0dGFjaGVyIGxlcyDDqWNoYW5nZXMgYXV4IHN1amV0cyBkw6lmaW5pcyBwYXIgbCdvcmRvbm5hbmNlLiBSYXR0YWNoZXIgbGVzIMOpY2hhbmdlcyBhdXggc3VqZXRzIGTDqWZpbmlzIHBhciBsJ2Fzc2lnbmF0aW9uLgoKw4l0YXQgZOKAmWF2YW5jZW1lbnQgZHUgZG9zc2llciA6CkxhIHLDqXVuaW9uIGRlIHLDqWbDqXJlbmNlIGVzdCBpbmRpcXXDqWUgYXUgMjAgbm92ZW1icmUgMjAyNS4gTGUgY3LDqW5lYXUgaW5kaXF1w6kgZXN0IGRlIDloMzAgw6AgMTVoMDAuIExhIGNvbnZvY2F0aW9uIGRlcyBwYXJ0aWVzIGVzdCBpbmRpcXXDqWUgYXUgMjEgb2N0b2JyZSAyMDI1LiBBdWN1bmUgdHJhbnNjcmlwdGlvbiBob3JvZGF0w6llIG4nZXN0IGZvdXJuaWUgZGFucyBsZSBwcsOpc2VudCBjb250ZXh0ZS4KCgpUdSByw6lkaWdlcywgcG91ciBVTiBTRVVMIHN1amV0IG51bcOpcm90w6ksIHVuZSBzeW50aMOoc2UgZmFjdHVlbGxlIGRlc3RpbsOpZSBhdSBjb21wdGUgcmVuZHUuCgpFbnRyw6llcyA6Ci0gIm51bWVybyIsICJ0aXRyZSIgZXQsIGxlIGNhcyDDqWNow6lhbnQsICJsb2NhbGlzYXRpb24iLyJkZXNjcmlwdGlvbiIgZHUgc3VqZXQgOwotIGxhIHN5bnRow6hzZSBpbnRlcm3DqWRpYWlyZSBkdSBzdWpldCBpc3N1ZSBkdSB0cmFpdGVtZW50IGRlcyDDqWNoYW5nZXMgKGZhaXRzLCBhY3Rpb25zLCBkw6lzYWNjb3JkcywgZGVtYW5kZXMgZGUgZG9jdW1lbnQsIMOpbMOpbWVudHMgdGVjaG5pcXVlcykgOwotIGxlcyBjb25zdGF0YXRpb25zIHBob3RvZ3JhcGhpcXVlcyBkb2N1bWVudMOpZXMgYXNzb2Npw6llcyBhdSBzdWpldC4KCk9iamVjdGlmIDoKLSByZXN0aXR1ZXIgbGVzIGNvbnN0YXRzIG1hdMOpcmllbHMgb2JzZXJ2w6lzIGV0IGxlcyBkw6ljbGFyYXRpb25zIHBlcnRpbmVudGVzIGRlcyBwYXJ0aWNpcGFudHMgOwotIHLDqWRpZ2VyIHVuZSBzeW50aMOoc2UgZmFjdHVlbGxlIGRlIGwnw6l0YXQgYXBwYXJlbnQgYXZhbnQgdHJhdmF1eCwgcsOpZGlnw6llIGV0IHN0cnVjdHVyw6llLCBldCBub24gdW5lIHJlcHJvZHVjdGlvbiBicnV0ZSBkZXMgZW50csOpZXMgOwotIGRpc3Rpbmd1ZXIgc3lzdMOpbWF0aXF1ZW1lbnQgY2UgcXVpIGVzdCBkw6ljbGFyw6kgZGUgY2UgcXVpIGVzdCB2aXNpYmxlL2RvY3VtZW50w6kgOwotIG5lIHJpZW4gaW52ZW50ZXIgOiBzaSBsYSBtYXRpw6hyZSBmb3VybmllIGVzdCBpbnN1ZmZpc2FudGUsIGxlIGNvbnN0YXRlciBwcnVkZW1tZW50IHNhbnMgY29tcGzDqXRlci4KLSBDaGFxdWUgZW50csOpZSBkZSAiYXZpc19wYXJ0aWNpcGFudHMiIGNvcnJlc3BvbmQgw6AgVU5FIFBFUlNPTk5FIERJU1RJTkNURSAobm9tICsgcsO0bGUpLgotIE5lIHBhcyBmdXNpb25uZXIgcGx1c2lldXJzIHBlcnNvbm5lcyBzb3VzIHVuIG3Dqm1lIHLDtGxlLgotIE5lIHBhcyBpbmNsdXJlIGwnZXhwZXJ0IGp1ZGljaWFpcmUgZGFucyAiYXZpc19wYXJ0aWNpcGFudHMiLgogIFNlcyBjb25zdGF0cyBldCBzZXMgcHJvcG9zIHNvbnQgcmVzdGl0dcOpcyBkYW5zICJzeW50aGVzZV9lY2hhbmdlcyIgZXQvb3UgImNvbmNsdXNpb25fZXhwZXJ0IiBzYW5zIHByZW5kcmUgcGFydGkuCgpMaW1pdGVzIHN0cmljdGVzIGRlIGxhIHN5bnRow6hzZSA6Ci0gTmUgcHJvZHVpcmUgYXVjdW4gcHJvZ3JhbW1lIGQnaW52ZXN0aWdhdGlvbnMsIGF1Y3VuZSBwcmVzY3JpcHRpb24gZGUgcsOpcGFyYXRpb24sIGF1Y3VuIHRyYXZhdXggcmVjb21tYW5kw6ksIGF1Y3VuZSBkw6l0ZXJtaW5hdGlvbiBjYXVzYWxlIG5vbiDDqXRhYmxpZS4KLSBOZSBwYXMgcHJvcG9zZXIgZGUgcmVjaGVyY2hlcywgZXhhbWVucyBvdSBleHBlcnRpc2VzIGRlc3RpbsOpcyDDoCBkw6l0ZXJtaW5lciBkZXMgcsOpcGFyYXRpb25zIG91IGRlcyBjYXVzZXMuCi0gTG9yc3F1J3VuZSBjYXVzZSBvdSB1bmUgaHlwb3Row6hzZSBlc3Qgw6l2b3F1w6llIHBhciB1biBwYXJ0aWNpcGFudCwgbGEgcmVzdGl0dWVyIGNvbW1lIGTDqWNsYXJhdGlvbiBvdSBoeXBvdGjDqHNlLCBzYW5zIGwnYWRvcHRlciBldCBzYW5zIHN1Z2fDqXJlciBjb21tZW50IGxhIGTDqW1vbnRyZXIuCi0gTmUgZm9ybXVsZXIgbmkgYXZpcyBjYXVzYWwsIG5pIGltcHV0YWJpbGl0w6ksIG5pIHJlY29tbWFuZGF0aW9uLCBuaSBjb25jbHVzaW9uIHRlY2huaXF1ZSBkZSBsJ2V4cGVydC4KLSBOZSByZXRlbmlyIGRhbnMgbGEgc3ludGjDqHNlIGR1IHN1amV0IGNvdXJhbnQgcXVlIGxlcyDDqWzDqW1lbnRzIG1hdMOpcmllbGxlbWVudCBwZXJ0aW5lbnRzIHBvdXIgY2Ugc3VqZXQgOyBsZXMgw6lsw6ltZW50cyBpbmNpZGVudHMgYXBwYXJ0ZW5hbnQgbWFuaWZlc3RlbWVudCDDoCB1biBhdXRyZSBzdWpldCBzb250IG9taXMsIHNhbnMgw6p0cmUgcsOpYWZmZWN0w6lzIGF1dG9tYXRpcXVlbWVudC4KCkxhbmdhZ2UgZGUgbGEgc29ydGllIDoKLSBOZSBwYXMgZW1wbG95ZXIgZGFucyBsYSBzb3J0aWUgbGVzIHRlcm1lcyBpbnRlcm5lcyBkZSB0cmFpdGVtZW50IHN1aXZhbnRzIDogIlBhc3MyRSIsICJQYXNzMkYiLCAiY2h1bmsiLCAiYmxvYyIsICJjb25zdGF0X3Zpc3VlbCIsICJuaXZlYXVfYXBwdWkiIChvdSAibml2ZWF1IGQnYXBwdWkiKSwgInByb3ZlbmFuY2UiLgotIFJlZm9ybXVsZXIgZW4gbGFuZ2FnZSBjb3VyYW50IDogImxlcyBwaG90b2dyYXBoaWVzIG1vbnRyZW504oCmIiwgImxlcyDDqWNoYW5nZXMgcmFwcG9ydGVudOKApiIsICJpbCBlc3QgZMOpY2xhcsOp4oCmIi4KClLDqGdsZXMgcsOpZGFjdGlvbm5lbGxlcyBhdXRvbm9tZXMgOgotIFNpIGRlcyDDqWNoYW5nZXMgc29udCBpZGVudGlmacOpcywgcHJvZHVpcmUgdW5lIHN5bnRow6hzZSBmYWN0dWVsbGUgZm9uZMOpZSB1bmlxdWVtZW50IHN1ciBjZXMgw6ljaGFuZ2VzIGV0IHN1ciBsZXMgY29uc3RhdGF0aW9ucyBwaG90b2dyYXBoaXF1ZXMgZm91cm5pZXMuCi0gU2kgbGUgc3VqZXQgZXN0IMOpdm9xdcOpIGNvbW1lIGNvcnJpZ8OpLCByw6lnbMOpLCByZXByaXMgb3UgZmFpdCwgw6ljcmlyZSBxdSdpbCBlc3QgImTDqWNsYXLDqSByZXByaXMiLCBzYW5zIGNvbmNsdXJlIMOgIGxhIGNvbmZvcm1pdMOpIHRlY2huaXF1ZS4KLSBTaSBhdWN1biDDqWNoYW5nZSBuJ2VzdCBpZGVudGlmacOpIGV0IHF1J2F1Y3VuIGNvbnN0YXQgcGhvdG9ncmFwaGlxdWUgcGVydGluZW50IG4nZXN0IGZvdXJuaSwgw6ljcmlyZSBleGFjdGVtZW50IGRhbnMgInN5bnRoZXNlX2VjaGFuZ2VzIiA6CiAgIkF1Y3VuIMOpbMOpbWVudCByZWxhdGlmIMOgIGNlIHBvaW50IG4nYSDDqXTDqSBpZGVudGlmacOpIGRhbnMgbGVzIMOpY2hhbmdlcyBhbmFseXPDqXMuIgotIE5lIGphbWFpcyBpbnZlbnRlciBkZSBjb25zdGF0IG1hdMOpcmllbC4KLSBEaXN0aW5ndWVyIGNlIHF1aSBlc3QgZGl0IGRhbnMgbGVzIMOpY2hhbmdlcyBkZSBjZSBxdWkgZXN0IGVmZmVjdGl2ZW1lbnQgY29uc3RhdMOpLgotIE5lIHBhcyDDqWNyaXJlICJBdWN1biDDqWzDqW1lbnQiIGxvcnNxdWUgbGEgbWF0acOocmUgZm91cm5pZSBjb250aWVudCBhdSBtb2lucyB1biBmYWl0LCB1bmUgYWN0aW9uLCB1biBkw6lzYWNjb3JkLCB1bmUgZGVtYW5kZSBkZSBkb2N1bWVudCBvdSB1biDDqWzDqW1lbnQgdGVjaG5pcXVlIGV4cGxvaXRhYmxlLgotIENvbnNlcnZlciBsZXMgZMOpc2FjY29yZHMsIHLDqXNlcnZlcywgYWN0aW9ucywgZG9jdW1lbnRzIGRlbWFuZMOpcyBldCDDqWzDqW1lbnRzIHRlY2huaXF1ZXMgcHLDqXNlbnRzIGRhbnMgbGEgbWF0acOocmUgZm91cm5pZS4KLSBOZSBwYXMgdHJhbnNmb3JtZXIgdW5lIGFjdGlvbiBwcm9wb3PDqWUgb3UgdW5lIGRlbWFuZGUgZW4gZMOpY2lzaW9uIGFjcXVpc2UuCi0gUHLDqXNlcnZlciBsZXMgaW5jZXJ0aXR1ZGVzIGV0IGZvcm11bGVyIHBydWRlbW1lbnQgbGVzIGNvbmNsdXNpb25zLgoKUsOpcG9uZHMgU1RSSUNURU1FTlQgYXUgZm9ybWF0IEpTT04gKGF1Y3VuIHRleHRlIGhvcnMgSlNPTikgOgoKewogICJudW1lcm8iOiA8aW50PiwKICAidGl0cmUiOiAic3RyaW5nIiwKICAiYXZpc19wYXJ0aWNpcGFudHMiOiBbCiAgICB7ICJub20iOiAic3RyaW5nIiwgInJvbGUiOiAic3RyaW5nIiwgInJlc3VtZSI6ICJzdHJpbmciIH0KICBdLAogICJzeW50aGVzZV9lY2hhbmdlcyI6ICJzdHJpbmciLAogICJjb25jbHVzaW9uX2V4cGVydCI6ICJzdHJpbmciCn0KCkTDqWZpbml0aW9uIGRlcyBjaGFtcHMgOgotICJhdmlzX3BhcnRpY2lwYW50cyIgOiBhdmlzIGV0IGTDqWNsYXJhdGlvbnMgcmFwcG9ydMOpcyBwYXIgcGFydGljaXBhbnQsIHJlc3RpdHXDqXMgY29tbWUgZMOpY2xhcsOpcywgc2FucyDDqnRyZSBhZG9wdMOpcy4KLSAic3ludGhlc2VfZWNoYW5nZXMiIDogc3ludGjDqHNlIGZhY3R1ZWxsZSBkZXMgw6ljaGFuZ2VzIGV0IGRlcyBjb25zdGF0cyBwZXJ0aW5lbnRzIHBvdXIgbGUgc3VqZXQuCi0gImNvbmNsdXNpb25fZXhwZXJ0IiA6IG5vbSBkZSBjaGFtcCBjb25zZXJ2w6kgcG91ciBjb21wYXRpYmlsaXTDqSA7IGNvbnRlbnUgc3RyaWN0ZW1lbnQgZmFjdHVlbCBsaW1pdMOpIMOgIGwnw6l0YXQgYXBwYXJlbnQgYXZhbnQgdHJhdmF1eCB0ZWwgcXUnaWwgcsOpc3VsdGUgZGVzIGNvbnN0YXRzIGRvY3VtZW50w6lzIGV0IGRlcyBkw6ljbGFyYXRpb25zIHJlc3RpdHXDqXMuIE5lIGNvbnRpZW50IG5pIGNhdXNlIGFkb3B0w6llLCBuaSBpbXB1dGFiaWxpdMOpLCBuaSByZWNvbW1hbmRhdGlvbiBkZSB0cmF2YXV4LCBkJ2ludmVzdGlnYXRpb25zIG91IGRlIHLDqXBhcmF0aW9uLCBuaSByZWNoZXJjaGUgZGVzdGluw6llIMOgIGTDqXRlcm1pbmVyIGRlcyByw6lwYXJhdGlvbnMuCgpOb3JtYWxpc2F0aW9uIGRlcyBkYXRlcyAob2JsaWdhdG9pcmUpIDoKLSBJbnRlcmRpY3Rpb24gZCfDqWNyaXJlIGRlcyBkYXRlcyBhdSBmb3JtYXQgIllZWVktTU0tREQiIGRhbnMgdG91dCBjaGFtcCB0ZXh0dWVsLgotIFNpIHVuZSBkYXRlIGRvaXQgw6p0cmUgY2l0w6llIGRhbnMgdW4gdGV4dGUgKGV4Y2VwdGlvbiksIHV0aWxpc2VyICJEIG1vaXMgWVlZWSIuCgpDb25zaWduZSBkZSByw6lkYWN0aW9uIHBvdXIgbGEgc3ludGjDqHNlIGRlcyDDqWNoYW5nZXMgOgotIExhIHN5bnRow6hzZSBkZXMgw6ljaGFuZ2VzIGRvaXQgw6p0cmUgc3RydWN0dXLDqWUgZW4gcGFyYWdyYXBoZXMuCi0gQ2hhcXVlIHBvaW50IGRpc3RpbmN0IChjb25zdGF0LCBkw6ljbGFyYXRpb24sIGTDqXNhY2NvcmQsIGRlbWFuZGUpIGRvaXQgZmFpcmUgbCdvYmpldCBkJ3VuIHBhcmFncmFwaGUgc8OpcGFyw6kuCi0gSW5zw6lyZXIgdW4gc2F1dCBkZSBsaWduZSBlbnRyZSBjaGFxdWUgcGFyYWdyYXBoZS4KLSBQb3VyIHPDqXBhcmVyIGRldXggcGFyYWdyYXBoZXMgZGFucyAic3ludGhlc2VfZWNoYW5nZXMiIGV0ICJjb25jbHVzaW9uX2V4cGVydCIsIHV0aWxpc2VyICJcblxuIi4KCkNvbnNpZ25lIGRlIHLDqWRhY3Rpb24gcG91ciAiY29uY2x1c2lvbl9leHBlcnQiIDoKLSBMYSBjb25jbHVzaW9uIGRvaXQgw6p0cmUgcsOpZGlnw6llIGVuIHBhcmFncmFwaGVzIGRpc3RpbmN0cy4KLSBVbiBwYXJhZ3JhcGhlIHBhciBjb25zdGF0IG91IHBvaW50IGZhY3R1ZWwgZGlzdGluY3QgOyBhdWN1bmUgb3JpZW50YXRpb24gdGVjaG5pcXVlLCBhdWN1biBkaWFnbm9zdGljIGNhdXNhbCwgYXVjdW5lIGltcHV0YWJpbGl0w6ksIGF1Y3VuZSBwcsOpY29uaXNhdGlvbi4KLSBBdWN1biBibG9jIGRlIHRleHRlIHVuaXF1ZS4KClVuIHLDqXN1bcOpIG91IHVuZSBjb25jbHVzaW9uIHLDqWRpZ8OpIGVuIHVuIHNldWwgcGFyYWdyYXBoZSBzZXJhIGNvbnNpZMOpcsOpIGNvbW1lIG5vbiBjb25mb3JtZS4='
}
$script:P3PARTS = @{
  'A' = @{ prefix = 'UDEzMCAoUFJJT1JJVEFJUkUpIDoKTWlzc2lvbiA6IMOJdGFibGlyIHVuIGNvbXB0ZSByZW5kdSDDoCBwYXJ0aXIgZGVzIHRyYW5zY3JpcHRpb25zIGRlIGxhIHLDqXVuaW9uIGQnZXhwZXJ0aXNlLiBSZXN0aXR1ZXIgbGVzIHByb3BvcyBtZW50aW9ubsOpcyBkYW5zIGxlcyB0cmFuc2NyaXB0aW9ucy4gUmVzdGl0dWVyIGxlcyBjb25zdGF0cyByZWxhdMOpcyBkYW5zIGxlcyB0cmFuc2NyaXB0aW9ucy4gUmF0dGFjaGVyIGxlcyDDqWNoYW5nZXMgYXV4IHN1amV0cyBkw6lmaW5pcyBwYXIgbCdvcmRvbm5hbmNlLiBSYXR0YWNoZXIgbGVzIMOpY2hhbmdlcyBhdXggc3VqZXRzIGTDqWZpbmlzIHBhciBsJ2Fzc2lnbmF0aW9uLgrDiXRhdCBk4oCZYXZhbmNlbWVudCA6IExhIHLDqXVuaW9uIGRlIHLDqWbDqXJlbmNlIGVzdCBpbmRpcXXDqWUgYXUgMjAgbm92ZW1icmUgMjAyNS4gTGUgY3LDqW5lYXUgaW5kaXF1w6kgZXN0IGRlIDloMzAgw6AgMTVoMDAuIExhIGNvbnZvY2F0aW9uIGRlcyBwYXJ0aWVzIGVzdCBpbmRpcXXDqWUgYXUgMjEgb2N0b2JyZSAyMDI1LiBBdWN1bmUgdHJhbnNjcmlwdGlvbiBob3JvZGF0w6llIG4nZXN0IGZvdXJuaWUgZGFucyBsZSBwcsOpc2VudCBjb250ZXh0ZS4KCkNvbnNpZ25lIHByaW9yaXRhaXJlIDoKLSBTaSB1bmUgZGF0ZSBkZSByw6l1bmlvbiBmaWd1cmUgZGFucyBs4oCZw6l0YXQgZOKAmWF2YW5jZW1lbnQgY2ktZGVzc3VzLCBsYSByZW5zZWlnbmVyIGVuIElTTyAoWVlZWS1NTS1ERCkuClZvaWNpIGxlIEpTT04gZ2xvYmFsIGlzc3UgZGUgbGEgZnVzaW9uIGRlcyBzZWdtZW50cyA6Cg=='; suffix = 'CgpDb250cmFpbnRlcyA6Ci0gRXh0cmFpcmUgbGEgZGF0ZSBkZSByw6l1bmlvbiBkZXB1aXMgbGUgY29udGV4dGUgc2kgZWxsZSB5IGZpZ3VyZSAoZm9ybWF0IFlZWVktTU0tREQpLgotIExlICJyZXN1bWUiIGRvaXQgY29tbWVuY2VyIHBhciBjYWRyZXIgbGEgcsOpdW5pb24gOiBuYXR1cmUgKHLDqXVuaW9uIGTigJlleHBlcnRpc2UpLCBsaWV1L3NpdGUgc2kgbWVudGlvbm7DqSwgb2JqZXQsIGZpbmFsaXTDqSwgc3VpdGVzIGTDqWNpZMOpZXMuCi0gTmUgcmllbiBpbnZlbnRlci4KClByb2R1aXMgdW5pcXVlbWVudCA6CnsgImRhdGUiOiAiLi4uIiwgImxpbmsiOiBudWxsfCIuLi4iLCAicmVzdW1lIjogIi4uLiIsICJvcmRyZV9kdV9qb3VyIjogWy4uLl0gfQoKSW50ZXJkaWN0aW9uIDoKLSAicmVzdW1lIiBuZSBkb2l0IGNvbnRlbmlyIGF1Y3VuZSBkYXRlLCBuaSAiWVlZWS1NTS1ERCIgbmkgIkQgbW9pcyBZWVlZIi4KLSBUb3V0ZSBkYXRlIGRvaXQgw6p0cmUgdW5pcXVlbWVudCBkYW5zICJkYXRlIi4KClJlbnZvaWUgdW5pcXVlbWVudCBsZSBKU09OLg==' }
  'B' = @{ prefix = 'Vm9pY2kgbGUgSlNPTiBnbG9iYWwgaXNzdSBkZSBsYSBmdXNpb24gZGVzIHNlZ21lbnRzIDoKCg=='; suffix = 'CgrDgCBwYXJ0aXIgZGUgY2UgSlNPTiBnbG9iYWwsIHByb2R1aXMgdW5pcXVlbWVudCBsZSBjaGFtcCAidGhlbWVzX2Fib3JkZXMiCnNlbG9uIGxlIHNjaMOpbWEgaW5kaXF1w6kuCgpSZW52b2llIHVuaXF1ZW1lbnQgbGUgSlNPTiBjb25mb3JtZSBhdSBzY2jDqW1hLg==' }
  'C' = @{ prefix = 'Vm9pY2kgbGUgSlNPTiBnbG9iYWwgaXNzdSBkZSBsYSBmdXNpb24gZGVzIHNlZ21lbnRzIDoKCg=='; suffix = 'CgrDgCBwYXJ0aXIgZGUgY2UgSlNPTiBnbG9iYWwsIHByb2R1aXMgdW5pcXVlbWVudCA6Ci0gImFjdGlvbnMiCi0gInBlcnNwZWN0aXZlcyIKLSAiYW5uZXhlcyIKClNpIGRlcyBpbmNlcnRpdHVkZXMsIGh5cG90aMOoc2VzIHRlY2huaXF1ZXMsIHJpc3F1ZXMsIGludmVzdGlnYXRpb25zIGZ1dHVyZXMgb3UgY29uZGl0aW9ucyBkZSByZXByaXNlIHNvbnQgw6l2b3F1w6lzLAplbGxlcyBkb2l2ZW50IMOqdHJlIHJlZm9ybXVsw6llcyBkYW5zICJwZXJzcGVjdGl2ZXMiLgoKUmVudm9pZSB1bmlxdWVtZW50IGxlIEpTT04gY29uZm9ybWUgYXUgc2Now6ltYS4=' }
  'D' = @{ prefix = 'Vm9pY2kgbGUgSlNPTiBnbG9iYWwgaXNzdSBkZSBsYSBmdXNpb24gZGVzIHNlZ21lbnRzIDoKCg=='; suffix = 'CgpSZW52b2llIHVuaXF1ZW1lbnQgdW4gSlNPTiBjb250ZW5hbnQgbGUgY2hhbXAgImRlbWFuZGVzX2RvY3VtZW50c19nbG9iYWxlcyIu' }
}
$script:P3CtxWarned = $false

function Get-P3Text {
  param([string]$Key)
  if ($script:P3B64.ContainsKey($Key)) {
    try { return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$script:P3B64[$Key])) } catch { return '' }
  }
  return ''
}
function Get-P3Part {
  param([string]$Pass, [string]$Which)
  $p = $null
  if ($script:P3PARTS.ContainsKey($Pass)) { $p = $script:P3PARTS[$Pass] }
  if ($null -eq $p) { return '' }
  try { return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$p[$Which])) } catch { return '' }
}
function Read-P3RawText {
  param([string]$Path)
  if (-not $Path) { return '' }
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
  try { $t = [IO.File]::ReadAllText($Path) } catch { return '' }
  return ($t -replace "`r`n", "`n")
}
function Get-P3ObjectText {
  # Rend un objet JSON en texte multi-lignes (meme convention que Write-CrJsonAtomic).
  param([object]$Obj)
  if ($null -eq $Obj) { return '{}' }
  return ($Obj | ConvertTo-Json -Depth 100)
}
function Get-P3BudgetDiag {
  param([string]$Alias, [string]$SysText, [string]$UsrText)
  $budget = Get-ContextBudget $Alias
  $nCtx = [int]$budget.NCtx
  $maxOut = [int]$budget.MaxTok
  $margin = [int]$budget.Margin
  $availableInput = $nCtx - $maxOut - $margin
  $sysTok = Estimate-Tokens $SysText
  $usrTok = Estimate-Tokens $UsrText
  $fullText = $SysText
  if ($UsrText) { $fullText = $SysText + "`n" + $UsrText }
  $fullTok = Estimate-Tokens $fullText
  $remaining = $availableInput - $fullTok
  $fits = ($remaining -ge 0)
  return @{
    alias = $Alias
    configured_n_ctx = $nCtx
    configured_max_output_tokens = $maxOut
    safety_margin = $margin
    available_input_tokens = $availableInput
    system_prompt_chars = $SysText.Length
    system_prompt_tokens_est = $sysTok
    user_prompt_chars = $UsrText.Length
    user_prompt_tokens_est = $usrTok
    final_input_chars = $fullText.Length
    final_input_tokens_est = $fullTok
    remaining_tokens = $remaining
    fits = $fits
  }
}
function Get-P3Schema {
  param([string]$Pass)
  switch ($Pass) {
    'A' { return @('date','link','resume','ordre_du_jour') }
    'B' { return @('themes_abordes') }
    'C' { return @('actions','perspectives','annexes') }
    'D' { return @('demandes_documents_globales') }
    'E' { return @('numero','titre','avis_participants','synthese_echanges','conclusion_expert') }
  }
  return @()
}
function ConvertTo-P3CSchemaCompliant {
  # LOT 3R-1C : Pass3C - reproduction de la normalisation historique du pipeline
  # generaliste (cr_reunion_point_mumerotes_pipeline_json.ps1 L7257-7355).
  # Garantit un objet strict { actions, perspectives, annexes } :
  #  - actions      : conservees depuis la sortie du modele (objets action/responsable/echeance/commentaire)
  #  - perspectives : liste d'objets {probleme, solution} ; si vide, fallback historique depuis $Source.problems
  #  - annexes      : liste de strings ; si vide, fallback historique depuis $Source.demandes_documents_globales
  param(
    [object] $Parsed,
    [object] $Source
  )
  $outActions = New-Object System.Collections.ArrayList
  $rawA = $null
  if ($Parsed -and $Parsed.PSObject.Properties['actions']) { $rawA = $Parsed.actions }
  if ($null -ne $rawA) {
    foreach ($a in @($rawA)) {
      if ($a -is [string]) {
        $t = ([string]$a).Trim()
        if ($t) { [void]$outActions.Add([pscustomobject]@{ action = $t; responsable = $null; echeance = $null; commentaire = $null }) }
      }
      elseif ($null -ne $a -and $a -is [System.Management.Automation.PSCustomObject]) {
        if (-not $a.PSObject.Properties['action'])       { $a | Add-Member -Force NoteProperty action '' }
        if (-not $a.PSObject.Properties['responsable'])  { $a | Add-Member -Force NoteProperty responsable $null }
        if (-not $a.PSObject.Properties['echeance'])     { $a | Add-Member -Force NoteProperty echeance $null }
        if (-not $a.PSObject.Properties['commentaire'])  { $a | Add-Member -Force NoteProperty commentaire $null }
        [void]$outActions.Add($a)
      }
    }
  }
  $perspList = New-Object System.Collections.ArrayList
  $rawP = $null
  if ($Parsed -and $Parsed.PSObject.Properties['perspectives']) { $rawP = $Parsed.perspectives }
  if ($null -ne $rawP) {
    foreach ($p in @($rawP)) {
      if ($p -is [string]) {
        $t = ([string]$p).Trim()
        if ($t) { [void]$perspList.Add([pscustomobject]@{ probleme = $t; solution = '' }) }
      }
      elseif ($null -ne $p) {
        if (-not $p.PSObject.Properties['probleme']) { $p | Add-Member -Force NoteProperty probleme '' }
        if (-not $p.PSObject.Properties['solution']) { $p | Add-Member -Force NoteProperty solution '' }
        $pr = ([string]$p.probleme).Trim()
        $so = ''
        if ($null -ne $p.solution) { $so = ([string]$p.solution).Trim() }
        if ($pr) { [void]$perspList.Add([pscustomobject]@{ probleme = $pr; solution = $so }) }
      }
    }
  }
  $seenP = @{}
  $perspDedup = New-Object System.Collections.ArrayList
  foreach ($p in @($perspList)) {
    $k = [string]$p.probleme
    if ($k -and -not $seenP.ContainsKey($k)) { $seenP[$k] = $true; [void]$perspDedup.Add($p) }
  }
  $srcProblems = $null
  if ($Source -and $Source.PSObject.Properties['problems']) { $srcProblems = $Source.problems }
  if (@($perspDedup).Count -eq 0 -and $null -ne $srcProblems) {
    foreach ($p in @($srcProblems)) {
      $pr = ''
      if ($p.PSObject.Properties['probleme'] -and $null -ne $p.probleme) { $pr = ([string]$p.probleme).Trim() }
      $so = ''
      if ($p.PSObject.Properties['solution'] -and $null -ne $p.solution -and $p.solution) { $so = ([string]$p.solution).Trim() }
      if ($pr -and -not $seenP.ContainsKey($pr)) { $seenP[$pr] = $true; [void]$perspDedup.Add([pscustomobject]@{ probleme = $pr; solution = $so }) }
    }
  }
  $annList = New-Object System.Collections.ArrayList
  $seenA = @{}
  $rawX = $null
  if ($Parsed -and $Parsed.PSObject.Properties['annexes']) { $rawX = $Parsed.annexes }
  if ($null -ne $rawX) {
    foreach ($x in @($rawX)) {
      $s = ''
      if ($x -is [string]) { $s = ([string]$x).Trim() }
      elseif ($null -ne $x -and $x.PSObject.Properties['objet'] -and $null -ne $x.objet) { $s = ([string]$x.objet).Trim() }
      elseif ($null -ne $x) { $s = ([string]($x | Out-String)).Trim() }
      if ($s -and -not $seenA.ContainsKey($s)) { $seenA[$s] = $true; [void]$annList.Add($s) }
    }
  }
  $srcDemandes = $null
  if ($Source -and $Source.PSObject.Properties['demandes_documents_globales']) { $srcDemandes = $Source.demandes_documents_globales }
  if (@($annList).Count -eq 0 -and $null -ne $srcDemandes) {
    foreach ($d in @($srcDemandes)) {
      $s = ''
      if ($d -is [string]) { $s = ([string]$d).Trim() }
      elseif ($null -ne $d -and $d.PSObject.Properties['objet'] -and $null -ne $d.objet) { $s = ('Demande : ' + ([string]$d.objet).Trim()) }
      if ($s -and -not $seenA.ContainsKey($s)) { $seenA[$s] = $true; [void]$annList.Add($s) }
    }
  }
  $annSorted = @($annList | Sort-Object -Unique)
  return [pscustomobject]@{
    actions      = @($outActions)
    perspectives = @($perspDedup)
    annexes      = @($annSorted)
  }
}
function Get-P3ErrorCountsFromEntries {
  # LOT 3R-1C : rederive les compteurs llm/http reels depuis les llm_entries
  # (chemin d'echec Pass3Refere : un appel HTTP reel a http_status>0).
  # Les entrees New-P3EmptyEntry sont des hashtables ; certaines entrees
  # synthetiques sont des pscustomobject. Les deux formes sont lues.
  param([object[]] $Entries)
  $llm = 0
  $http = 0
  foreach ($e in @($Entries)) {
    if ($null -eq $e) { continue }
    $hs = $null
    try {
      if ($e -is [System.Collections.IDictionary]) {
        if ($e.ContainsKey('http_status')) { $hs = $e['http_status'] }
      } elseif ($e.PSObject.Properties['http_status']) {
        $hs = $e.http_status
      }
      if ($null -ne $hs) { $hs = [int]$hs }
    } catch { $hs = $null }
    if ($null -ne $hs -and $hs -gt 0) { $llm += 1; $http += 1 }
  }
  return @{ llm_calls = $llm; http_calls = $http }
}
function New-P3EmptyEntry {
  param([string]$StepName, [string]$Alias, [int]$MaxOut, [int]$Margin, [int]$FullTok)
  return @{
    step = $StepName
    lot = $script:P3LotLabel
    alias_logique = $Alias
    alias = $Alias
    budget_contexte = @{ n_ctx = 0; max_tokens_out = $MaxOut; margin = $Margin }
    estimated_input_tokens = $FullTok
    prompt_chars = 0
    temperature = 0.2
    http_status = 0
    duree_sec = 0.0
    finish_reason = $null
    model_reel = $null
    usage = $null
    response_chars = 0
    error = $null
    parse_error = $null
    json_parse_ok = $false
    truncated_or_invalid_response = $false
    missing_keys = @()
    extra_keys = @()
    raw_file = ''
    parsed_file = ''
    retries = 0
    status = 'pending'
  }
}
function Invoke-P3Remote {
  # Un appel unique avec trace complete ; aucune relance silencieuse.
  param(
    [string] $ArtifactBase,
    [string] $SysTxt,
    [string] $UsrTxt,
    [string] $Alias,
    [string] $ArtDir,
    [string] $Pass,
    [object] $CSource = $null,
    [string] $ApiBaseOverride = '',
    [string] $ApiKeyOverride = '',
    [int]    $LlmTimeoutSec = 900
  )
  $schemaKeys = @(Get-P3Schema $Pass)
  $budget = Get-ContextBudget $Alias
  $maxOut = [int]$budget.MaxTok
  $margin = [int]$budget.Margin
  $diag = Get-P3BudgetDiag -Alias $Alias -SysText $SysTxt -UsrText $UsrTxt
  $fullTok = [int]$diag.final_input_tokens_est
  $entry = New-P3EmptyEntry -StepName $ArtifactBase -Alias $Alias -MaxOut $maxOut -Margin $margin -FullTok $fullTok
  $entry.budget_contexte = @{ n_ctx = [int]$budget.NCtx; max_tokens_out = $maxOut; margin = $margin }
  $entry.status = 'dry_run_budget_ok'
  $entry.fits = [bool]$diag.fits
  # Prompt artifact toujours ecrit (dry-run comme execute).
  $promptDir = Join-Path $ArtDir 'prompts'
  Ensure-Dir $promptDir
  $promptFile = Join-Path $promptDir ($ArtifactBase + '_prompt.txt')
  $fullPromptText = $SysTxt + "`n" + $UsrTxt
  Write-CrTextUtf8NoBom -Path $promptFile -Text $fullPromptText
  Add-CrOutputFile $promptFile
  $entry.prompt_chars = $fullPromptText.Length
  if (-not $script:P3Exec) {
    return @{ ok = $diag.fits; fits = $diag.fits; diag = $diag; entry = $entry; parsed = $null; raw = ''; prompt_file = $promptFile; raw_file = ''; parsed_file = '' }
  }
  if (-not $diag.fits) {
    $entry.status = 'budget_exceeded_no_call'
    [void]$script:llmEntries.Add($entry)
    throw ('[cr_refere_preventif] Pass3 ' + $Pass + ' (' + $ArtifactBase + ') : budget depasse (final_input_tokens_est=' + $fullTok + ' > available=' + [int]$diag.available_input_tokens + ') - aucun appel LLM.')
  }
  # Resolution api/key (deja initialise par le dispatch, mais double securite).
  $base = $ApiBaseOverride
  if (-not $base) { $base = [string][Environment]::GetEnvironmentVariable('PIPELINE_API_BASE') }
  if (-not $base) { $base = 'http://192.168.1.20:5055' }
  $key = $ApiKeyOverride
  if (-not $key) { $key = [string][Environment]::GetEnvironmentVariable('PIPELINE_API_KEY') }
  if (-not $key) { $key = [string][Environment]::GetEnvironmentVariable('ADAPTER_API_KEY') }
  if (-not $key) { throw '[cr_refere_preventif] Pass3 refere : cle API manquante (PIPELINE_API_KEY / ADAPTER_API_KEY / -ApiKey).' }
  $script:AdapterApiBase = $base
  $script:AdapterApiKey  = $key
  $script:LlmTimeoutSec  = $LlmTimeoutSec
  $script:HttpBlocked    = $false
  $t0 = Get-Date
  try {
    $endpoint = $base.TrimEnd('/') + '/v1/chat/completions'
    $body = @{
      model = $Alias
      messages = @(
        @{ role = 'system'; content = $SysTxt },
        @{ role = 'user';   content = $UsrTxt }
      )
      temperature = 0.2
      stream = $false
    }
    $resp = Invoke-LLM-OpenAICompat -Endpoint $endpoint -Body $body -TimeoutSec $LlmTimeoutSec -MaxRetries 0
    $entry.duree_sec = [math]::Round(((Get-Date) - $t0).TotalSeconds, 2)
    $entry.http_status = $script:LastHttpStatus
    if ($null -ne $resp) {
      $prm = $resp.PSObject.Properties['model']
      if ($null -ne $prm) { $entry.model_reel = [string]$prm.Value }
    }
    if ($null -eq $resp -or $null -eq $resp.choices -or $null -eq $resp.choices[0] -or $null -eq $resp.choices[0].message) {
      throw '[cr_refere_preventif] Pass3 refere : reponse sans choices[0].message.'
    }
    $ch0 = $resp.choices[0]
    $pFr = $ch0.PSObject.Properties['finish_reason']
    if ($null -ne $pFr) { $entry.finish_reason = [string]$pFr.Value }
    $raw = [string]$ch0.message.content
    $entry.response_chars = $raw.Length
    $pUs = $resp.PSObject.Properties['usage']
    if ($null -ne $pUs) { $entry.usage = $pUs.Value }
    $rawDir = Join-Path $ArtDir 'raw'
    Ensure-Dir $rawDir
    $rawFile = Join-Path $rawDir ($ArtifactBase + '_raw.txt')
    Write-CrTextUtf8NoBom -Path $rawFile -Text $raw
    Add-CrOutputFile $rawFile
    $entry.raw_file = $rawFile
    $parsed = Parse-LlmJsonStrict -Raw $raw
    $entry.json_parse_ok = $true
    $outKeys = @($parsed.psobject.Properties.Name)
    $entry.missing_keys = @($schemaKeys | Where-Object { $_ -notin $outKeys })
    $entry.extra_keys = @($outKeys | Where-Object { $_ -notin $schemaKeys })
    # LOT 3R-1C : Pass3C - tolerance au drift historique du modele.
    # Le pipeline generaliste n'exige jamais du modele qu'il produise lui-meme
    # perspectives/annexes : il applique une normalisation deterministe historique
    # (perspectives <- source.problems ; annexes <- source.demandes_documents_globales).
    # On conserve la trace du drift dans l'entree de manifest (p3c_normalized).
    if ($Pass -eq 'C' -and $null -ne $CSource) {
      $driftMissing = @($entry.missing_keys)
      if (@($driftMissing).Count -gt 0) {
        $driftExtra = @($entry.extra_keys)
        $parsed = ConvertTo-P3CSchemaCompliant -Parsed $parsed -Source $CSource
        $entry.p3c_normalized = @{
          model_missing_keys = @($driftMissing)
          model_extra_keys   = @($driftExtra)
          normalization      = 'historique_fallbacks_perspectives_annexes'
        }
        Write-CrWarn ('Pass3 C : drift modele (cles absentes=' + (@($driftMissing) -join ',') + ') -> normalisation historique appliquee (actions conservees; perspectives/annexes via fallback source globale).')
      }
    }
    $outKeys = @($parsed.psobject.Properties.Name)
    $entry.missing_keys = @($schemaKeys | Where-Object { $_ -notin $outKeys })
    $entry.extra_keys = @($outKeys | Where-Object { $_ -notin $schemaKeys })
    if (@($entry.missing_keys).Count -gt 0) {
      throw ('[cr_refere_preventif] Pass3 ' + $Pass + ' : cles requises absentes (' + (@($entry.missing_keys) -join ',') + ').')
    }
    $respDir = Join-Path $ArtDir '.'
    $respFile = Join-Path $respDir ($ArtifactBase + '_response.json')
    Write-CrJsonAtomic -Path $respFile -Obj $parsed
    Add-CrOutputFile $respFile
    $entry.parsed_file = $respFile
    $entry.status = 'ok'
    $entry.alias = $Alias
    [void]$script:llmEntries.Add($entry)
    return @{ ok = $true; fits = $true; diag = $diag; entry = $entry; parsed = $parsed; raw = $raw; prompt_file = $promptFile; raw_file = $rawFile; parsed_file = $respFile }
  } catch {
    $entry.error = $_.Exception.Message
    try { $entry.duree_sec = [math]::Round(((Get-Date) - $t0).TotalSeconds, 2) } catch { }
    if ([int]$entry.http_status -eq 200 -and $entry.response_chars -gt 0 -and (-not [bool]$entry.json_parse_ok)) {
      $entry.truncated_or_invalid_response = $true
    }
    if ($null -eq $script:llmEntries) { $script:llmEntries = New-Object System.Collections.ArrayList }
    [void]$script:llmEntries.Add($entry)
    throw ('[cr_refere_preventif] Pass3 ' + $Pass + ' (' + $ArtifactBase + ') : echec (error=' + [string]$entry.error + ') - aucun retry.')
  }
}
function Get-P3ReducedJsonText {
  param([hashtable]$GlobalObj)
  # Reduction historique Pass3C : resume_global + actions + problems +
  # demandes_documents_globales + themes (ordre conserve).
  $r = [pscustomobject]@{
    resume_global = if ($GlobalObj.ContainsKey('resume_global')) { $GlobalObj['resume_global'] } else { '' }
    actions = if ($GlobalObj.ContainsKey('actions')) { @($GlobalObj['actions']) } else { @() }
    problems = if ($GlobalObj.ContainsKey('problems')) { @($GlobalObj['problems']) } else { @() }
    demandes_documents_globales = if ($GlobalObj.ContainsKey('demandes_documents_globales')) { @($GlobalObj['demandes_documents_globales']) } else { @() }
    themes = if ($GlobalObj.ContainsKey('themes')) { @($GlobalObj['themes']) } else { @() }
  }
  return ($r | ConvertTo-Json -Depth 100)
}
function Get-P3SujetNumeroStr {
  param([int]$Num)
  return ('{0:D3}' -f $Num)
}
function Resolve-P3ECompactPath {
  param([int]$Subject, [string]$Pass2EDir, [string]$ExplicitPath)
  if ($ExplicitPath) { return $ExplicitPath }
  if ($Subject -le 0 -or -not $Pass2EDir) { return '' }
  $cand = Join-Path $Pass2EDir ('sujet_' + (Get-P3SujetNumeroStr $Subject) + '_compact.json')
  if (Test-Path -LiteralPath $cand -PathType Leaf) { return $cand }
  return ''
}
function Resolve-P3EChunkPaths {
  param([int]$Subject, [string]$Pass2FOutDir, [string[]]$ExplicitPaths)
  if (@($ExplicitPaths).Count -gt 0) {
    $out = New-Object System.Collections.ArrayList
    foreach ($x in @($ExplicitPaths)) { if ($x -and (Test-Path -LiteralPath $x -PathType Leaf)) { [void]$out.Add($x) } }
    return @($out | Sort-Object)
  }
  if ($Subject -le 0 -or -not $Pass2FOutDir) { return @() }
  if (-not (Test-Path -LiteralPath $Pass2FOutDir -PathType Container)) { return @() }
  $pat = 'subject_' + (Get-P3SujetNumeroStr $Subject) + '_chunk_*_response.json'
  $found = @(Get-ChildItem -LiteralPath $Pass2FOutDir -Filter $pat -File -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { $_.FullName })
  return @($found)
}
function Get-P3V {
  # Acces generique (hashtable ou pscustomobject) avec defaut vide.
  param($Obj, [string]$Name)
  if ($null -eq $Obj) { return $null }
  if ($Obj -is [System.Collections.IDictionary]) {
    if ($Obj.ContainsKey($Name)) { return $Obj[$Name] }
    return $null
  }
  $p = $Obj.PSObject.Properties[$Name]
  if ($null -ne $p) { return $p.Value }
  return $null
}
function Get-P3EUserText {
  param($CompactObj, [int]$SubjectNumero, [string[]]$ChunkPaths, [switch]$Pass2EAbsent)
  $num = 0
  $titre = ''
  $localisation = ''
  $description = ''
  $vNum = Get-P3V $CompactObj 'numero'
  if ($null -ne $vNum) { $num = [int]$vNum }
  $vT = Get-P3V $CompactObj 'titre'
  if ($null -ne $vT) { $titre = [string]$vT }
  $vL = Get-P3V $CompactObj 'localisation'
  if ($null -ne $vL) { $localisation = [string]$vL }
  $vD = Get-P3V $CompactObj 'description'
  if ($null -ne $vD) { $description = [string]$vD }
  $meta = [pscustomobject]@{ numero = $num; titre = $titre; localisation = $localisation; description = $description }
  $metaJson = $meta | ConvertTo-Json -Depth 10
  $synth = Get-P3V $CompactObj 'synthese_intermediaire'
  $synthJson = ''
  if ($null -ne $synth) { $synthJson = $synth | ConvertTo-Json -Depth 50 }
  if ([bool]$Pass2EAbsent) {
    # LOT REFERE-E2E-3D : sujet documente uniquement par Pass2F (photographies
    # affectees), sans synthese_intermediaire Pass2E exploitable. Message explicite
    # d absence : aucune synthese Pass2E artificielle. La matiere Pass2F reelle est
    # ajoutee plus bas (blocs complets) quand des chunks sont disponibles.
    $user = @"
Sujet :
$metaJson

Synthèse intermédiaire Pass2E :
aucune matière textuelle Pass2E exploitable n'est disponible pour ce sujet. La présente synthèse repose uniquement sur la matière Pass2F fournie ci-dessous (photographies documentées et éléments associés). Ne pas fabriquer de synthèse Pass2E artificielle.

Règles :
- Utiliser exclusivement la matière Pass2F fournie ; ne pas ajouter de faits absents.
- Rédiger une synthèse factuelle de l'état documenté avant travaux.
- Distinguer ce qui est déclaré oralement de ce qui est effectivement visible/documenté sur les photographies.
- Restituer les constats sous forme factuelle (les photographies montrent...) et les déclarations comme telles (il est déclaré...).
- Ne jamais inventer de constat matériel ni d'analyse technique.
- Préserver les incertitudes et les désaccords éventuels.
- Ne pas écrire Aucun élément si la matière Pass2F contient une information exploitable.

Renvoie uniquement le JSON conforme au schéma.
"@
  } else {
    $user = @"
Sujet :
$metaJson

Synthèse intermédiaire Pass2E à utiliser exclusivement :
$synthJson

À partir de cette synthèse intermédiaire, produis la synthèse finale du sujet.

Règles :
- Utiliser exclusivement la synthèse Pass2E fournie ; ne pas ajouter de faits absents.
- Si des échanges ou éléments exploitables sont identifiés, produire une synthèse factuelle.
- Conserver les désaccords, réserves, actions, documents demandés et éléments techniques.
- Ne pas écrire "Aucun élément" si un champ Pass2E contient une information exploitable.
- Si le sujet est évoqué comme corrigé, réglé, repris ou fait, écrire qu'il est "déclaré repris", sans conclure à la conformité technique.
- Si aucun échange n'est identifié, utiliser exactement : "Aucun élément relatif à ce point n'a été identifié dans les échanges analysés."
- Ne jamais inventer de constat matériel.
- Distinguer ce qui est dit dans les échanges de ce qui est effectivement constaté.
- Distinguer avis ou positions des participants, synthèse factuelle des échanges, et conclusion de l'expert.
- Préserver les incertitudes et ne pas transformer une action proposée en décision acquise.

Renvoie uniquement le JSON conforme au schéma.
"@
  }
  if (@($ChunkPaths).Count -gt 0) {
    $user += "`n`n===== MATIERE PASS2F DU SUJET " + (Get-P3SujetNumeroStr $SubjectNumero) + " (blocs complets, ordre croissant, provenance conservee) ====="
    $user += "`nLes blocs Pass2F ci-dessous rassemblent les constats documentes (photographies) et les echanges associes pour ce sujet. Integre leurs apports factuels a la synthese finale en maintenant la distinction entre ce qui est declare oralement et ce qui est visible/documente. Ne transforme jamais un constat photographique en declaration orale, ni l'inverse. N'invente aucune relation non documentee."
    foreach ($cp in @($ChunkPaths)) {
      $fn = [IO.Path]::GetFileName($cp)
      $label = $fn -replace '_response\.json$', ''
      $txt = Read-P3RawText $cp
      $user += "`n`n[SOURCE PASS2F " + $label + " -- " + $fn + "]`n" + $txt
    }
  } else {
    $user += "`n`n(Aucun bloc Pass2F disponible pour ce sujet dans ce test restreint.)"
  }
  return $user
}

# =============================================================================
# Invoke-Pass3Refere : branche Pass3A/B/C/D_refere + Pass3E_refere (LOT 3R-1B)
# Source globale = refere_global_meeting.json (consolidation hierarchique 6G
# 2B2F-12). Aucune injection directe de chunks Pass2F dans 3A-D. Pass3E =
# compact Pass2E + chunks Pass2F complets du sujet (ordre croissant, origine
# conservee). Dry-run par defaut ; appels reels uniquement si -Pass3RefereExecute.
# =============================================================================
function Invoke-Pass3Refere {
  param(
    [hashtable] $Ctx,
    [string]    $OutDirMain,
    [string]    $GlobalJsonPath,
    [string]    $ContextJsonPath,
    [string]    $Pass2EDir,
    [string]    $Pass2FOutDir,
    [string[]]  $EChunkPaths,
    [string]    $ESujetCompactPath,
    [int]       $ESubject,
    [bool]      $Exec,
    [string]    $ApiBase,
    [string]    $ApiKey,
    [string]    $LotLabel,
    [string]    $OutSubdir
  )
  $script:P3LotLabel = $(if ($LotLabel) { [string]$LotLabel } else { '3R-1B' })
  $script:P3Exec = [bool]$Exec
  if ($Exec) {
    $script:HttpBlocked = $false
    $baseApi = $ApiBase
    if (-not $baseApi) { $baseApi = [string][Environment]::GetEnvironmentVariable('PIPELINE_API_BASE') }
    if (-not $baseApi) { $baseApi = 'http://192.168.1.20:5055' }
    $keyApi = $ApiKey
    if (-not $keyApi) { $keyApi = [string][Environment]::GetEnvironmentVariable('PIPELINE_API_KEY') }
    if (-not $keyApi) { $keyApi = [string][Environment]::GetEnvironmentVariable('ADAPTER_API_KEY') }
    if (-not $keyApi) { throw '[cr_refere_preventif] LOT 3R-1B : cle API manquante (PIPELINE_API_KEY / ADAPTER_API_KEY / -ApiKey).' }
    $script:AdapterApiBase = $baseApi
    $script:AdapterApiKey  = $keyApi
    $script:AdapterAlias   = 'pass3a_remote'
    $script:LlmTimeoutSec  = 900
  }
  if (-not $OutSubdir) { $OutSubdir = 'pass3_refere' }
  $p3Root = Join-Path $OutDirMain $OutSubdir
  Ensure-Dir $p3Root

  if (-not $GlobalJsonPath -or -not (Test-Path -LiteralPath $GlobalJsonPath -PathType Leaf)) {
    throw ('[cr_refere_preventif] LOT 3R-1B : refere_global_meeting.json introuvable (' + [string]$GlobalJsonPath + ').')
  }
  $globalRaw = Read-P3RawText $GlobalJsonPath
  if ([string]::IsNullOrWhiteSpace($globalRaw)) {
    throw '[cr_refere_preventif] LOT 3R-1B : refere_global_meeting.json vide (NE PAS CONSOMMER).'
  }
  $globalObj = $null
  try { $globalObj = $globalRaw | ConvertFrom-Json } catch { $globalObj = $null }

  # Reduction historique Pass3C : resume_global + actions + problems +
  # demandes_documents_globales + themes (ordre conserve).
  $reducedText = ''
  if ($null -ne $globalObj) {
    $redObj = [ordered]@{}
    $redObj['resume_global'] = Get-P3V $globalObj 'resume_global'
    $a = Get-P3V $globalObj 'actions'
    $redObj['actions'] = $(if ($null -eq $a) { @() } else { @($a) })
    $p = Get-P3V $globalObj 'problems'
    $redObj['problems'] = $(if ($null -eq $p) { @() } else { @($p) })
    $d = Get-P3V $globalObj 'demandes_documents_globales'
    $redObj['demandes_documents_globales'] = $(if ($null -eq $d) { @() } else { @($d) })
    $t = Get-P3V $globalObj 'themes'
    $redObj['themes'] = $(if ($null -eq $t) { @() } else { @($t) })
    try { $reducedText = ($redObj | ConvertTo-Json -Depth 100) } catch { $reducedText = '' }
  }

  $aliasMap = @{ 'A' = 'pass3a_remote'; 'B' = 'pass3b_remote'; 'C' = 'pass3c_remote'; 'D' = 'pass3d_remote'; 'E' = 'pass3e_remote' }
  $baseMap = @{ 'A' = 'pass3a_refere'; 'B' = 'pass3b_refere'; 'C' = 'pass3c_refere'; 'D' = 'pass3d_refere' }
  $rows = New-Object System.Collections.ArrayList
  $artifacts = New-Object System.Collections.ArrayList
  $llmCount = 0
  $httpCount = 0
  $statusAll = 'ok'

  # --- Phase 1 : mesure A/B/C/D ---------------------------------------------
  $jobs = New-Object System.Collections.ArrayList
  foreach ($pass in @('A', 'B', 'C', 'D')) {
    $sys = Get-P3Text $pass
    if (-not $sys) { throw ('[cr_refere_preventif] LOT 3R-1B : systeme Pass3' + $pass + ' absent des constantes.') }
    $pre = Get-P3Part $pass 'prefix'
    $suf = Get-P3Part $pass 'suffix'
    $jsonTxt = $globalRaw
    if ($pass -eq 'C') {
      if (-not $reducedText) { throw '[cr_refere_preventif] LOT 3R-1B : reduction Pass3C impossible.' }
      $jsonTxt = $reducedText
    }
    $usr = $pre + $jsonTxt + $suf
    $alias = [string]$aliasMap[$pass]
    $base = [string]$baseMap[$pass]
    $diag = Get-P3BudgetDiag -Alias $alias -SysText $sys -UsrText $usr
    $rowH = [ordered]@{
      pass = 'Pass3' + $pass
      subject = $null
      kind = 'global'
      alias = $alias
      input_chars = [int]$diag.final_input_chars
      input_tokens_est = [int]$diag.final_input_tokens_est
      available_input_tokens = [int]$diag.available_input_tokens
      remaining_tokens = [int]$diag.remaining_tokens
      fits = [bool]$diag.fits
      system_chars = [int]$diag.system_prompt_chars
      user_chars = [int]$diag.user_prompt_chars
    }
    [void]$rows.Add($rowH)
    [void]$jobs.Add(@{ pass = $pass; base = $base; sys = $sys; usr = $usr; alias = $alias; diag = $diag })
  }

  # Gate strict avant execute : aucun appel si un budget global ne tient pas.
  if ($Exec) {
    foreach ($j0 in @($jobs)) {
      if (-not [bool]$j0.diag.fits) {
        throw ('[cr_refere_preventif] LOT 3R-1B : Pass3' + [string]$j0.pass + ' DOES_NOT_FIT (final_tokens_est=' + [int]$j0.diag.final_input_tokens_est + ') - aucun appel LLM.')
      }
    }
  }

  # --- Phase 2 : appels A/B/C/D ---------------------------------------------
  foreach ($j in @($jobs)) {
    $fits = [bool]$j.diag.fits
    Write-CrInfo ('Pass3 ' + [string]$j.pass + ' : ' + $(if ($fits) { 'FIT' } else { 'DOES_NOT_FIT' }) + ' final_tokens_est=' + [int]$j.diag.final_input_tokens_est + ' available=' + [int]$j.diag.available_input_tokens)
    $res = Invoke-P3Remote -ArtifactBase ([string]$j.base) -SysTxt ([string]$j.sys) -UsrTxt ([string]$j.usr) -Alias ([string]$j.alias) -ArtDir $p3Root -Pass ([string]$j.pass) -CSource $(if ($j.pass -eq 'C') { $globalObj } else { $null })
    if ($res.prompt_file) { [void]$artifacts.Add([string]$res.prompt_file) }
    if (-not $Exec) { continue }
    $llmCount += 1
    $httpCount += 1
    $entry = $res.entry
    if ($res.ok -and $entry.status -eq 'ok') {
      if ($res.raw_file) { [void]$artifacts.Add([string]$res.raw_file) }
      if ($res.parsed_file) { [void]$artifacts.Add([string]$res.parsed_file) }
      if ($entry.finish_reason -eq 'length') {
        $statusAll = 'truncated'
        Write-CrWarn ('Pass3 ' + [string]$j.pass + ' : finish_reason=length - sortie potentiellement tronquee.')
      }
    } else {
      $statusAll = 'failed'
      throw ('[cr_refere_preventif] LOT 3R-1B : Pass3 ' + [string]$j.pass + ' en echec (status=' + [string]$entry.status + ') - aucun retry.')
    }
  }

  # --- Phase 3 : Pass3E ------------------------------------------------------
  $eRows = New-Object System.Collections.ArrayList
  # LOT 3R-1E : chargement du contexte general (champs system/user) pour Pass3E_refere.
  $eCtxUserText = ''
  $eCtxSystemText = ''
  if ($ContextJsonPath -and (Test-Path -LiteralPath $ContextJsonPath -PathType Leaf)) {
    try {
      $eCtxObj = (Read-P3RawText $ContextJsonPath) | ConvertFrom-Json
      $eCtxV1 = Get-P3V $eCtxObj 'system'
      if ($null -ne $eCtxV1) { $eCtxSystemText = [string]$eCtxV1 }
      $eCtxV2 = Get-P3V $eCtxObj 'user'
      if ($null -ne $eCtxV2) { $eCtxUserText = [string]$eCtxV2 }
    } catch { $eCtxUserText = '' }
  }
  $eSys = Get-P3Text 'E'
  if (-not $eSys) { throw '[cr_refere_preventif] LOT 3R-1B : systeme Pass3E absent des constantes.' }

  # Dry-run : budget pour tous les sujets compacts disponibles.
  if (-not $Exec) {
    $compactFiles = @()
    if ($Pass2EDir -and (Test-Path -LiteralPath $Pass2EDir -PathType Container)) {
      $compactFiles = @(Get-ChildItem -LiteralPath $Pass2EDir -Filter 'sujet_*_compact.json' -File -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { $_.FullName })
    }
    if ($ESujetCompactPath -and (Test-Path -LiteralPath $ESujetCompactPath -PathType Leaf)) {
      $already = $false
      foreach ($f0 in @($compactFiles)) { if ($f0 -ieq $ESujetCompactPath) { $already = $true } }
      if (-not $already) { $compactFiles = @($compactFiles) + @($ESujetCompactPath) }
    }
    foreach ($cf in @($compactFiles)) {
      $compact = $null
      try { $compact = (Read-P3RawText $cf) | ConvertFrom-Json } catch { $compact = $null }
      if ($null -eq $compact) { continue }
      $num = 0
      $vN = Get-P3V $compact 'numero'
      if ($null -ne $vN) { $num = [int]$vN }
      if ($num -le 0) { continue }
      $chunkPaths = @(Resolve-P3EChunkPaths -Subject $num -Pass2FOutDir $Pass2FOutDir -ExplicitPaths @($EChunkPaths))
      $usrE = Get-P3EUserText -CompactObj $compact -SubjectNumero $num -ChunkPaths @($chunkPaths)
      if (-not [string]::IsNullOrWhiteSpace($eCtxUserText)) { $usrE = 'Consignes generales du dossier (champ user, contraignantes) :' + "`n" + $eCtxUserText + "`n`n" + $usrE }
      $diagE = Get-P3BudgetDiag -Alias ([string]$aliasMap['E']) -SysText $eSys -UsrText $usrE
      $ePromptDir = Join-Path $p3Root 'prompts'
      Ensure-Dir $ePromptDir
      $ePromptFile = Join-Path $ePromptDir ('pass3e_sujet_' + (Get-P3SujetNumeroStr $num) + '_prompt.txt')
      if (-not (Test-Path -LiteralPath $ePromptFile -PathType Leaf)) {
        Write-CrTextUtf8NoBom -Path $ePromptFile -Text ($eSys + "`n" + $usrE)
        Add-CrOutputFile $ePromptFile
        [void]$artifacts.Add($ePromptFile)
      }
      $hasSynth = (Has-P3Synthese $compact)
      $eRow = [ordered]@{
        pass = 'Pass3E'
        subject = $num
        kind = 'subject'
        alias = [string]$aliasMap['E']
        compact_file = $cf
        has_synthese_intermediaire = $hasSynth
        chunk_count = @($chunkPaths).Count
        input_chars = [int]$diagE.final_input_chars
        input_tokens_est = [int]$diagE.final_input_tokens_est
        available_input_tokens = [int]$diagE.available_input_tokens
        remaining_tokens = [int]$diagE.remaining_tokens
        fits = ($hasSynth -and [bool]$diagE.fits)
      }
      [void]$rows.Add($eRow)
      [void]$eRows.Add($eRow)
    }
    if ($ESubject -gt 0) {
      $found = $false
      foreach ($er0 in @($eRows)) { if ([int]$er0.subject -eq $ESubject) { $found = $true } }
      if (-not $found) {
        $miss = [ordered]@{
          pass = 'Pass3E'
          subject = $ESubject
          kind = 'subject'
          alias = [string]$aliasMap['E']
          compact_file = ''
          has_synthese_intermediaire = $false
          chunk_count = 0
          input_chars = 0
          input_tokens_est = 0
          available_input_tokens = 0
          remaining_tokens = 0
          fits = $false
        }
        [void]$rows.Add($miss)
        Write-CrWarn ('Pass3E sujet ' + $ESubject + ' : compact Pass2E introuvable - PASS2E_INSUFFICIENT (STOP pour ce sujet).')
      }
    }
  }

  # Execution restreinte : UN sujet Pass3E (test = sujet 20).
  if ($Exec) {
    if ($statusAll -ne 'ok') { throw '[cr_refere_preventif] LOT 3R-1B : arret avant Pass3E (passe globale non ok, status=' + $statusAll + ') - aucun retry.' }
    if ($ESubject -le 0) { throw '[cr_refere_preventif] LOT 3R-1B : -Pass3RefereESubject requis en mode execute.' }
    $compactPath = ''
    if ($ESujetCompactPath -and (Test-Path -LiteralPath $ESujetCompactPath -PathType Leaf)) {
      $compactPath = $ESujetCompactPath
    } else {
      $candPath = Resolve-P3ECompactPath -Subject $ESubject -Pass2EDir $Pass2EDir -ExplicitPath ''
      if ($candPath) { $compactPath = $candPath }
    }
    if (-not $compactPath) {
      Write-CrWarn ('Pass3E sujet ' + $ESubject + ' : compact Pass2E introuvable - PASS2E_INSUFFICIENT (STOP pour ce sujet, aucun appel).')
      $statusAll = 'pass2e_insufficient'
    } else {
      $compact = $null
      try { $compact = (Read-P3RawText $compactPath) | ConvertFrom-Json } catch { $compact = $null }
      if ($null -eq $compact) {
        Write-CrWarn ('Pass3E sujet ' + $ESubject + ' : compact Pass2E illisible - PASS2E_INSUFFICIENT (STOP pour ce sujet, aucun appel).')
        $statusAll = 'pass2e_insufficient'
      } elseif (-not (Has-P3Synthese $compact)) {
        Write-CrWarn ('Pass3E sujet ' + $ESubject + ' : synthese_intermediaire vide - PASS2E_INSUFFICIENT (STOP pour ce sujet, aucun appel).')
        $statusAll = 'pass2e_insufficient'
      } else {
        $chunkPaths = @(Resolve-P3EChunkPaths -Subject $ESubject -Pass2FOutDir $Pass2FOutDir -ExplicitPaths @($EChunkPaths))
        $usrE = Get-P3EUserText -CompactObj $compact -SubjectNumero $ESubject -ChunkPaths @($chunkPaths)
      if (-not [string]::IsNullOrWhiteSpace($eCtxUserText)) { $usrE = 'Consignes generales du dossier (champ user, contraignantes) :' + "`n" + $eCtxUserText + "`n`n" + $usrE }
        $diagE = Get-P3BudgetDiag -Alias ([string]$aliasMap['E']) -SysText $eSys -UsrText $usrE
        $eRowT = [ordered]@{
          pass = 'Pass3E'
          subject = $ESubject
          kind = 'subject'
          alias = [string]$aliasMap['E']
          compact_file = $compactPath
          has_synthese_intermediaire = $true
          chunk_count = @($chunkPaths).Count
          input_chars = [int]$diagE.final_input_chars
          input_tokens_est = [int]$diagE.final_input_tokens_est
          available_input_tokens = [int]$diagE.available_input_tokens
          remaining_tokens = [int]$diagE.remaining_tokens
          fits = [bool]$diagE.fits
        }
        [void]$rows.Add($eRowT)
        if (-not [bool]$diagE.fits) {
          throw ('[cr_refere_preventif] LOT 3R-1B : Pass3E sujet ' + $ESubject + ' DOES_NOT_FIT (final_tokens_est=' + [int]$diagE.final_input_tokens_est + ') - aucun appel.')
        }
        $baseE = 'pass3e_sujet_' + (Get-P3SujetNumeroStr $ESubject)
        Write-CrInfo ('Pass3E sujet ' + $ESubject + ' : FIT chunks=' + @($chunkPaths).Count + ' final_tokens_est=' + [int]$diagE.final_input_tokens_est)
        $resE = Invoke-P3Remote -ArtifactBase $baseE -SysTxt $eSys -UsrTxt $usrE -Alias ([string]$aliasMap['E']) -ArtDir $p3Root -Pass 'E'
        $llmCount += 1
        $httpCount += 1
        $entryE = $resE.entry
        if ($resE.ok -and $entryE.status -eq 'ok') {
          if ($resE.prompt_file) { [void]$artifacts.Add([string]$resE.prompt_file) }
          if ($resE.raw_file) { [void]$artifacts.Add([string]$resE.raw_file) }
          if ($resE.parsed_file) { [void]$artifacts.Add([string]$resE.parsed_file) }
          $sujDir = Join-Path $p3Root 'sujets'
          Ensure-Dir $sujDir
          $sujResp = Join-Path $sujDir ('sujet_' + (Get-P3SujetNumeroStr $ESubject) + '_synthese.json')
          Write-CrJsonAtomic -Path $sujResp -Obj $resE.parsed
          Add-CrOutputFile $sujResp
          [void]$artifacts.Add($sujResp)
          if ($entryE.finish_reason -eq 'length') {
            $statusAll = 'truncated'
            Write-CrWarn ('Pass3E sujet ' + $ESubject + ' : finish_reason=length.')
          }
        } else {
          $statusAll = 'failed'
          throw ('[cr_refere_preventif] LOT 3R-1B : Pass3E sujet ' + $ESubject + ' en echec (status=' + [string]$entryE.status + ') - aucun retry.')
        }
      }
    }
  }

  # --- Tableau budget + artefacts -------------------------------------------
  $rowsOut = @()
  foreach ($r in @($rows)) {
    $isDic = ($r -is [System.Collections.IDictionary])
    $rowsOut += @{
      pass = $(if ($isDic -and $r.Contains('pass')) { [string]$r['pass'] } else { '' })
      subject = $(if ($isDic -and $r.Contains('subject')) { $r['subject'] } else { $null })
      kind = $(if ($isDic -and $r.Contains('kind')) { [string]$r['kind'] } else { '' })
      alias = $(if ($isDic -and $r.Contains('alias')) { [string]$r['alias'] } else { '' })
      has_synthese_intermediaire = $(if ($isDic -and $r.Contains('has_synthese_intermediaire')) { [bool]$r['has_synthese_intermediaire'] } else { $null })
      chunk_count = $(if ($isDic -and $r.Contains('chunk_count')) { [int]$r['chunk_count'] } else { $null })
      input_chars = $(if ($isDic -and $r.Contains('input_chars')) { [int]$r['input_chars'] } else { 0 })
      input_tokens_est = $(if ($isDic -and $r.Contains('input_tokens_est')) { [int]$r['input_tokens_est'] } else { 0 })
      available_input_tokens = $(if ($isDic -and $r.Contains('available_input_tokens')) { [int]$r['available_input_tokens'] } else { 0 })
      remaining_tokens = $(if ($isDic -and $r.Contains('remaining_tokens')) { [int]$r['remaining_tokens'] } else { 0 })
      fits = $(if ($isDic -and $r.Contains('fits')) { [bool]$r['fits'] } else { $false })
    }
  }
  $fitFile = Join-Path $p3Root 'pass3_refere_budget_dryrun.json'
  Write-CrJsonAtomic -Path $fitFile -Obj @{ lot = [string]$LotLabel; dry_run = (-not $Exec); rows = @($rowsOut) }
  Add-CrOutputFile $fitFile
  [void]$artifacts.Add($fitFile)

  $fitCount = 0
  $nofitCount = 0
  foreach ($ro in @($rowsOut)) { if ([bool]$ro.fits) { $fitCount++ } else { $nofitCount++ } }
  $okFinal = $false
  if ($Exec) { $okFinal = ($statusAll -eq 'ok') -and ($httpCount -ge 1) -and ($httpCount -le 5) }
  else { $okFinal = ($statusAll -in @('ok', 'pass2e_insufficient')) -and ($httpCount -eq 0) }
  $summary = @{
    lot = [string]$LotLabel
    mode = $(if ($Exec) { 'execute_restreint_5_max' } else { 'dryrun' })
    llm_calls = $llmCount
    http_calls = $httpCount
    status = $statusAll
    ok = $okFinal
    rows_count = @($rowsOut).Count
    fit_count = $fitCount
    nofit_count = $nofitCount
    out_root = $p3Root
  }
  return @{ ok = [bool]$summary.ok; status = [string]$statusAll; llm_calls = [int]$llmCount; http_calls = [int]$httpCount; rows = @($rowsOut); artifacts = @($artifacts); summary = $summary }
}

# ============================================================================
# LOT 3R-1C : autotest deterministe SANS LLM/HTTP - contrat Pass3C.
# Rejoue la validation stricte (avant correctif) puis la normalisation historique
# (apres correctif) sur un raw Pass3C reel fourni par -TestPass3CRawPath.
# Source du fallback : refere_global_meeting.json (-Pass3RefereGlobalJsonPath).
# ============================================================================
if ($TestPass3CContractReplay) {
  $cFails = New-Object System.Collections.ArrayList
  $cRawPath = [string]$TestPass3CRawPath
  $cSrcPath = [string]$Pass3RefereGlobalJsonPath
  if (-not $cRawPath -or -not (Test-Path -LiteralPath $cRawPath -PathType Leaf)) { [void]$cFails.Add('TestPass3CRawPath introuvable: ' + $cRawPath) }
  if (-not $cSrcPath -or -not (Test-Path -LiteralPath $cSrcPath -PathType Leaf)) { [void]$cFails.Add('Pass3RefereGlobalJsonPath introuvable: ' + $cSrcPath) }
  if (@($cFails).Count -eq 0) {
    $rawText = [IO.File]::ReadAllText($cRawPath)
    $cParsed = Parse-LlmJsonStrict -Raw $rawText
    $cSchema = @(Get-P3Schema 'C')
    $cKeys = @($cParsed.psobject.Properties.Name)
    $missingBefore = @($cSchema | Where-Object { $_ -notin $cKeys })
    $extraBefore   = @($cKeys | Where-Object { $_ -notin $cSchema })
    $sourceObj = $null
    try { $sourceObj = ([IO.File]::ReadAllText($cSrcPath)) | ConvertFrom-Json } catch { $sourceObj = $null }
    $cNorm = ConvertTo-P3CSchemaCompliant -Parsed $cParsed -Source $sourceObj
    $cNormKeys = @($cNorm.psobject.Properties.Name)
    $missingAfter = @($cSchema | Where-Object { $_ -notin $cNormKeys })
    $extraAfter   = @($cNormKeys | Where-Object { $_ -notin $cSchema })
    Write-CrInfo ('Autotest 3R-1C Pass3C : strict_before missing=' + (@($missingBefore) -join ',') + ' extra=' + (@($extraBefore) -join ',') + ' -> FAIL attendu')
    Write-CrInfo ('Autotest 3R-1C Pass3C : normalize_after actions=' + @($cNorm.actions).Count + ' perspectives=' + @($cNorm.perspectives).Count + ' annexes=' + @($cNorm.annexes).Count + ' missing=' + (@($missingAfter) -join ',') + ' extra=' + (@($extraAfter) -join ',') + ' -> PASS attendu')
    if (@($missingBefore).Count -eq 0) { [void]$cFails.Add('drift non reproduit: missing_keys devrait etre non vide') }
    if (@($missingAfter).Count -gt 0) { [void]$cFails.Add('normalisation incomplete: missing_keys=' + (@($missingAfter) -join ',')) }
    if (@($extraAfter).Count -gt 0) { [void]$cFails.Add('normalisation non conforme: extra_keys=' + (@($extraAfter) -join ',')) }
    if (@($cNorm.actions).Count -lt 1) { [void]$cFails.Add('actions perdues par la normalisation') }
  }
  foreach ($fx in @($cFails)) { Write-CrErr $fx }
  if (@($cFails).Count -gt 0) { exit 1 }
  Write-CrInfo 'Autotest 3R-1C Pass3C : OK (drift rejete en validation stricte ; normalisation historique = PASS).'
  exit 0
}
# ============================================================================
# LOT 3R-1C : autotest deterministe SANS LLM/HTTP - compteurs manifest sur echec.
# Simule 3 entrees llm_entries a http_status=200 (A/B ok, C drift) et verifie que
# le catch racine rederive llm_calls=3 / http_calls=3 malgre $llmCallsLog=0.
# ============================================================================
if ($TestPass3RefereErrorCounters) {
  $mFails = New-Object System.Collections.ArrayList
  $script:llmEntries = New-Object System.Collections.ArrayList
  [void]$script:llmEntries.Add(@{ http_status = 200; status = 'ok'; alias = 'pass3a_remote' })
  [void]$script:llmEntries.Add(@{ http_status = 200; status = 'ok'; alias = 'pass3b_remote' })
  [void]$script:llmEntries.Add(@{ http_status = 200; status = 'pending'; alias = 'pass3c_remote'; error = 'schema drift' })
  $llmCallsLog = 0
  $httpCallsLog = 0
  $p3ErrCounts = Get-P3ErrorCountsFromEntries -Entries @($script:llmEntries)
  $errLlm = [Math]::Max($llmCallsLog, [int]$p3ErrCounts.llm_calls)
  $errHttp = [Math]::Max($httpCallsLog, [int]$p3ErrCounts.http_calls)
  if ($errLlm -ne 3) { [void]$mFails.Add('llm_calls attendu 3 recu ' + $errLlm) }
  if ($errHttp -ne 3) { [void]$mFails.Add('http_calls attendu 3 recu ' + $errHttp) }
  foreach ($fx in @($mFails)) { Write-CrErr $fx }
  if (@($mFails).Count -gt 0) { exit 1 }
  Write-CrInfo 'Autotest 3R-1C compteurs manifest echec Pass3Refere : OK (llm_calls=3 http_calls=3 derives de llm_entries).'
  exit 0
}

# =============================================================================
# REFERE-E2E-3E : autotests deterministes SANS LLM/HTTP du retry JSON unique
# Pass2F (alias-agnostique). Verification : valide des l'attempt 1 ; retry
# unique sur JSON invalide ; deux JSON invalides -> STOP cote appelant ;
# aucun troisieme appel ; pas de reparation silencieuse ; cas reel chunk 07.
# =============================================================================
if ($TestPass2FRetryOffline) {
  $script:HttpBlocked = $true
  $tFails = New-Object System.Collections.ArrayList
  $tStamp = Get-CrTimestampStamp
  $tOut = Join-Path ([System.IO.Path]::GetTempPath()) ('cr_e2e3e_offline_' + $tStamp)
  Ensure-Dir $tOut
  $validRaw = '{"schema_version": "cr_refere_preventif.pass2f.chunk.v1", "source_pass": "2F", "subject_numero": 20, "synthese_intermediaire": "synthese valide test E2E-3E", "points_documentes": [], "incertitudes": [], "photo_contexts": []}'
  $invalidLikeChunk07 = '{"schema_version": "cr_refere_preventif.pass2f.chunk.v1", "source_pass": "2F", "subject_numero": 20, "synthese_intermediaire": "synthese chunk07-like", "points_documentes": [], "incertitudes": [], "photo_contexts": [ { "photo": "P1070306" } }'

  function E2E3E-NewChunk {
    param([int] $Numero = 20, [int] $ChunkIndex = 1, [string] $Message = 'prompt test E2E-3E')
    return @{
      message = $Message
      chunk_index = $ChunkIndex
      chunk_total = 1
      photos_count = 0
      split_reason = 'offline_test'
      prompt_tokens_est = 100
      input_tokens_est = 90
      available_tokens = 8000
      available_input_tokens = 7000
      output_tokens_est = 100
      available_output_tokens = 1800
      output_budget_ok = $true
      enforce_required = $false
      units_count = 1
      data = @{ sequence_documentaire = @() }
    }
  }
  function E2E3E-NewPlan {
    param([int] $Numero = 20)
    return @{
      numero = $Numero
      titre = 'test'
      localisation = ''
      description = ''
      budget = $script:BudgetPass2F
    }
  }
  function E2E3E-RunCase {
    param(
      [string] $CaseName,
      [string[]] $OfflineRaws,
      [string] $AliasLogique = 'pass2f_local',
      [string] $RouteModel = 'pass2f_local'
    )
    $outCase = Join-Path $tOut $CaseName
    $script:AdapterAlias = $RouteModel
    $ch = E2E3E-NewChunk -Numero 20 -ChunkIndex 1 -Message ('prompt ' + $CaseName)
    $pl = E2E3E-NewPlan -Numero 20
    $e = Invoke-Pass2FChunkAndRecord -Chunk $ch -Plan $pl -OutDir $outCase -MaxTokens 1800 -Temperature 0.2 -AliasLogique $AliasLogique -OfflineRawResponses @($OfflineRaws)
    return $e
  }

  # 0) Routage alias : pass2f_remote -> passthrough gpt-4o-mini (jamais registry adapter).
  $routeCheck = Resolve-Pass2FModelRoute 'pass2f_remote'
  if ($routeCheck -ne 'gpt-4o-mini') { [void]$tFails.Add('route: pass2f_remote -> ' + $routeCheck) }
  if ((Resolve-Pass2FModelRoute 'pass2f_local') -ne 'pass2f_local') { [void]$tFails.Add('route: pass2f_local inchange') }
  Write-CrInfo 'Autotest E2E-3E : routage alias OK (pass2f_remote -> gpt-4o-mini passthrough)'

  # 1) Valide des l'attempt 1 -> 1 appel, aucun retry.
  $e1 = E2E3E-RunCase -CaseName 'c1_valid_once' -OfflineRaws @($validRaw) -AliasLogique 'pass2f_local' -RouteModel 'pass2f_local'
  if (-not [bool]$e1.json_parse_ok) { [void]$tFails.Add('c1: json_parse_ok=false attendu true') }
  if ([int]$e1.attempt_count -ne 1) { [void]$tFails.Add('c1: attempt_count attendu 1 recu ' + [string]$e1.attempt_count) }
  if ([int]$e1.actual_llm_calls -ne 1 -or [int]$e1.actual_http_calls -ne 1) { [void]$tFails.Add('c1: compteurs attendus 1/1 recus ' + [string]$e1.actual_llm_calls + '/' + [string]$e1.actual_http_calls) }
  if ([bool]$e1.attempt_1_json_parse_ok -ne $true -or [bool]$e1.attempt_2_json_parse_ok -ne $false) { [void]$tFails.Add('c1: trace attempt attendue true/false') }
  Write-CrInfo ('Autotest E2E-3E : c1 valide attempt 1 -> OK (llm=' + $e1.actual_llm_calls + ' http=' + $e1.actual_http_calls + ')')

  # 2) Voie remote : alias_logique pass2f_remote, route gpt-4o-mini.
  $e2 = E2E3E-RunCase -CaseName 'c2_remote_once' -OfflineRaws @($validRaw) -AliasLogique 'pass2f_remote' -RouteModel 'gpt-4o-mini'
  if ([string]$e2.alias_logique -ne 'pass2f_remote') { [void]$tFails.Add('c2: alias_logique != pass2f_remote') }
  if ([string]$e2.model_alias -ne 'gpt-4o-mini') { [void]$tFails.Add('c2: model_alias != gpt-4o-mini recu ' + [string]$e2.model_alias) }
  if (-not [bool]$e2.json_parse_ok) { [void]$tFails.Add('c2: json_parse_ok=false') }
  Write-CrInfo 'Autotest E2E-3E : c2 remote passthrough gpt-4o-mini attempt 1 -> OK'

  # 3) Invalide attempt 1 puis valide attempt 2 -> retry unique.
  $e3 = E2E3E-RunCase -CaseName 'c3_retry_once' -OfflineRaws @($invalidLikeChunk07, $validRaw) -AliasLogique 'pass2f_local' -RouteModel 'pass2f_local'
  if (-not [bool]$e3.json_parse_ok) { [void]$tFails.Add('c3: json_parse_ok=false attendu true apres retry') }
  if ([int]$e3.attempt_count -ne 2) { [void]$tFails.Add('c3: attempt_count attendu 2 recu ' + [string]$e3.attempt_count) }
  if ([string]$e3.retry_reason -ne 'invalid_json_attempt_1') { [void]$tFails.Add('c3: retry_reason != invalid_json_attempt_1') }
  if ([bool]$e3.attempt_1_json_parse_ok -ne $false -or [bool]$e3.attempt_2_json_parse_ok -ne $true) { [void]$tFails.Add('c3: trace attempt attendue false/true') }
  $rawDir3 = Join-Path (Join-Path $tOut 'c3_retry_once') 'raw_responses'
  $f1r = Join-Path $rawDir3 'subject_020_chunk_01_raw_attempt_1.txt'
  $f2r = Join-Path $rawDir3 'subject_020_chunk_01_raw_attempt_2.txt'
  if (-not (Test-Path -LiteralPath $f1r -PathType Leaf) -or -not (Test-Path -LiteralPath $f2r -PathType Leaf)) { [void]$tFails.Add('c3: raws attempt 1/2 absents') }
  Write-CrInfo 'Autotest E2E-3E : c3 invalide puis valide -> retry unique OK'

  # 4) Deux invalides -> STOP cote appelant ; aucun 3e appel.
  $e4 = E2E3E-RunCase -CaseName 'c4_stop_after_retry' -OfflineRaws @($invalidLikeChunk07, $invalidLikeChunk07) -AliasLogique 'pass2f_local' -RouteModel 'pass2f_local'
  if ([bool]$e4.json_parse_ok) { [void]$tFails.Add('c4: json_parse_ok=true attendu false (STOP)') }
  if ([int]$e4.attempt_count -ne 2) { [void]$tFails.Add('c4: attempt_count attendu 2 recu ' + [string]$e4.attempt_count) }
  if ([int]$e4.actual_llm_calls -ne 2 -or [int]$e4.actual_http_calls -ne 2) { [void]$tFails.Add('c4: compteurs retry attendus 2/2 recus ' + [string]$e4.actual_llm_calls + '/' + [string]$e4.actual_http_calls) }
  $rawDir4 = Join-Path (Join-Path $tOut 'c4_stop_after_retry') 'raw_responses'
  $f3r = Join-Path $rawDir4 'subject_020_chunk_01_raw_attempt_3.txt'
  if (Test-Path -LiteralPath $f3r -PathType Leaf) { [void]$tFails.Add('c4: troisieme raw present (interdit)') }
  $cnt4 = @(Get-ChildItem -LiteralPath $rawDir4 -Filter 'subject_020_chunk_01_raw_attempt_*.txt' -File -ErrorAction SilentlyContinue).Count
  if ($cnt4 -ne 2) { [void]$tFails.Add('c4: nb raws attempts attendu 2 recu ' + $cnt4) }
  Write-CrInfo 'Autotest E2E-3E : c4 deux invalides -> STOP sans 3e appel OK'

  # 5) Cas reel subject_002_chunk_07 (optionnel via -TestPass2FChunk07RawPath).
  if ($TestPass2FChunk07RawPath -and (Test-Path -LiteralPath $TestPass2FChunk07RawPath -PathType Leaf)) {
    $raw07 = [IO.File]::ReadAllText($TestPass2FChunk07RawPath)
    if ([string]::IsNullOrWhiteSpace($raw07)) { [void]$tFails.Add('c5: raw chunk07 vide') }
    else {
      $parsed07Ok = $true
      try { $null = Parse-LlmJsonStrict -Raw $raw07 } catch { $parsed07Ok = $false }
      if ($parsed07Ok) { [void]$tFails.Add('c5: raw chunk07 parse OK (attendu invalide)') }
      $e5 = E2E3E-RunCase -CaseName 'c5_chunk07' -OfflineRaws @($raw07, $raw07) -AliasLogique 'pass2f_local' -RouteModel 'pass2f_local'
      if ([bool]$e5.json_parse_ok) { [void]$tFails.Add('c5: chunk07 json_parse_ok=true attendu false') }
      if ([int]$e5.attempt_count -ne 2) { [void]$tFails.Add('c5: attempt_count attendu 2') }
      Write-CrInfo 'Autotest E2E-3E : c5 chunk07 reel -> chemin STOP valide (retry unique sans reparation)'
    }
  } else {
    Write-CrInfo 'Autotest E2E-3E : c5 chunk07 reel SKIP (chemin non fourni ou introuvable)'
  }

  foreach ($fx in @($tFails)) { Write-CrErr $fx }
  if (@($tFails).Count -gt 0) {
    try { Remove-Item -LiteralPath $tOut -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    exit 1
  }
  Write-CrInfo 'Autotest E2E-3E retry JSON unique Pass2F : OK (1 appel valide ; retry unique ; STOP apres 2 invalides ; aucun 3e appel ; aucune reparation silencieuse).'
  try { Remove-Item -LiteralPath $tOut -Recurse -Force -ErrorAction SilentlyContinue } catch { }
  exit 0
}
function Has-P3Synthese {
  param($CompactObj)
  $v = Get-P3V $CompactObj 'synthese_intermediaire'
  if ($null -eq $v) { return $false }
  if ($v -is [System.Collections.IDictionary] -and $v.Count -eq 0) { return $false }
  if ($v -is [string] -and [string]::IsNullOrWhiteSpace([string]$v)) { return $false }
  if ($v -is [System.Array] -and @($v).Count -eq 0) { return $false }
  return $true
}


# =============================================================================
# LOT 3R-1D : reprise Pass3 refere (mode resume) - ne rejoue PAS A/B/C.
# - Reutilise les sorties A/B du run 3R-1B (aucun appel LLM).
# - Normalise C hors LLM depuis le raw 3R-1B (ConvertTo-P3CSchemaCompliant).
# - Execute AU PLUS 2 appels reels : Pass3D_refere puis Pass3E_refere (sujet 20).
# - Aucun retry silencieux ; STOP immediat sur toute anomalie.
# =============================================================================
function Invoke-Pass3RefereResume {
  param(
    [string] $OutDirMain,
    [string] $RequestJsonPath,
    [bool]   $Exec,
    [string] $ApiBase,
    [string] $ApiKey,
    [string] $LotLabel,
    [string] $OutSubdir
  )
  $script:P3LotLabel = $(if ($LotLabel) { [string]$LotLabel } else { '3R-1D' })
  $script:P3Exec = [bool]$Exec
  if ($Exec) {
    $script:HttpBlocked = $false
    $baseApi = $ApiBase
    if (-not $baseApi) { $baseApi = [string][Environment]::GetEnvironmentVariable('PIPELINE_API_BASE') }
    if (-not $baseApi) { $baseApi = 'http://192.168.1.20:5055' }
    $keyApi = $ApiKey
    if (-not $keyApi) { $keyApi = [string][Environment]::GetEnvironmentVariable('PIPELINE_API_KEY') }
    if (-not $keyApi) { $keyApi = [string][Environment]::GetEnvironmentVariable('ADAPTER_API_KEY') }
    if (-not $keyApi) { throw '[cr_refere_preventif] LOT 3R-1D : cle API manquante (PIPELINE_API_KEY / ADAPTER_API_KEY / -ApiKey).' }
    $script:AdapterApiBase = $baseApi
    $script:AdapterApiKey  = $keyApi
    $script:AdapterAlias   = 'pass3d_remote'
    $script:LlmTimeoutSec  = 900
  }
  if (-not $RequestJsonPath -or -not (Test-Path -LiteralPath $RequestJsonPath -PathType Leaf)) {
    throw ('[cr_refere_preventif] LOT 3R-1D : pass3r1d_request.json introuvable (' + [string]$RequestJsonPath + ').')
  }
  $reqRaw = Read-P3RawText $RequestJsonPath
  if ([string]::IsNullOrWhiteSpace($reqRaw)) { throw '[cr_refere_preventif] LOT 3R-1D : pass3r1d_request.json vide.' }
  $req = $null
  try { $req = $reqRaw | ConvertFrom-Json } catch { $req = $null }
  if ($null -eq $req) { throw '[cr_refere_preventif] LOT 3R-1D : pass3r1d_request.json JSON invalide.' }
  $globalJson = [string](Get-P3V $req 'global_json')
  $srcRoot    = [string](Get-P3V $req 'src_3r1b_root')
  $compactPath = [string](Get-P3V $req 'compact_path')
  $chunkPaths = @()
  $vChunks = Get-P3V $req 'chunk_paths'
  if ($null -ne $vChunks) { $chunkPaths = @($vChunks | ForEach-Object { [string]$_ }) }
  $subjectNum = 0
  $vSub = Get-P3V $req 'subject'
  if ($null -ne $vSub) { try { $subjectNum = [int]$vSub } catch { $subjectNum = 0 } }
  $skipD = $false
  $vSkip = Get-P3V $req 'skip_d'
  if ($null -ne $vSkip) { try { $skipD = [bool]$vSkip } catch { $skipD = $false } }
  if ($skipD) { Write-CrInfo ('[cr_refere_preventif] LOT 3R-1E : skip_d=true -> rerun Pass3E seul (aucun appel Pass3D).') }
  if (-not $OutSubdir) { $OutSubdir = 'pass3_refere' }
  $p3Root = Join-Path $OutDirMain $OutSubdir
  Ensure-Dir $p3Root
  Ensure-Dir (Join-Path $p3Root 'raw')
  Ensure-Dir (Join-Path $p3Root 'prompts')
  Ensure-Dir (Join-Path $p3Root 'sujets')
  # --- Source globale canonique (2B2F-12) ---
  if (-not $globalJson -or -not (Test-Path -LiteralPath $globalJson -PathType Leaf)) {
    throw ('[cr_refere_preventif] LOT 3R-1D : refere_global_meeting.json introuvable (' + $globalJson + ').')
  }
  $globalRaw = Read-P3RawText $globalJson
  if ([string]::IsNullOrWhiteSpace($globalRaw)) { throw '[cr_refere_preventif] LOT 3R-1D : refere_global_meeting.json vide (NE PAS CONSOMMER).' }
  $globalObj = $null
  try { $globalObj = $globalRaw | ConvertFrom-Json } catch { $globalObj = $null }
  if ($null -eq $globalObj) { throw '[cr_refere_preventif] LOT 3R-1D : refere_global_meeting.json JSON invalide.' }
  if (-not $srcRoot -or -not (Test-Path -LiteralPath $srcRoot -PathType Container)) {
    throw ('[cr_refere_preventif] LOT 3R-1D : repertoire source 3R-1B introuvable (' + $srcRoot + ').')
  }
  $aliasD = 'pass3d_remote'
  $aliasE = 'pass3e_remote'
  $artifacts = New-Object System.Collections.ArrayList
  $reused    = New-Object System.Collections.ArrayList
  $llmCount  = 0
  $httpCount = 0
  $statusAll = 'ok'
  $schemaFailures = New-Object System.Collections.ArrayList
  # --- REUSE A / B (3R-1B, aucun appel) ---
  $reuseList = @(
    @{ name = 'pass3a_refere'; file = 'pass3a_refere_response.json'; pass = 'A' },
    @{ name = 'pass3b_refere'; file = 'pass3b_refere_response.json'; pass = 'B' }
  )
  foreach ($ru in @($reuseList)) {
    $src = Join-Path $srcRoot ([string]$ru['file'])
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { throw ('[cr_refere_preventif] LOT 3R-1D : sortie 3R-1B absente (' + $src + ').') }
    $rawTxt = Read-P3RawText $src
    if ([string]::IsNullOrWhiteSpace($rawTxt)) { throw ('[cr_refere_preventif] LOT 3R-1D : sortie 3R-1B vide (' + $src + ').') }
    $parsed = Parse-LlmJsonStrict -Raw $rawTxt
    $schema = @(Get-P3Schema ([string]$ru['pass']))
    $missing = @($schema | Where-Object { $_ -notin @($parsed.psobject.Properties.Name) })
    if (@($missing).Count -gt 0) { [void]$schemaFailures.Add(([string]$ru['name'] + ' missing=' + (@($missing) -join ','))) }
    $hash = ''
    try { $hash = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash } catch { $hash = '' }
    $dst = Join-Path $p3Root ([string]$ru['name'] + '_response.json')
    Copy-Item -LiteralPath $src -Destination $dst -Force
    Add-CrOutputFile $dst
    [void]$artifacts.Add($dst)
    [void]$reused.Add([ordered]@{
      step = [string]$ru['name']
      reused_from_previous_run = $true
      source_lot = '3R-1B'
      source_path = $src
      sha256 = $hash
      http_status = 0
      status = 'ok'
    })
    Write-CrInfo ('Resume 3R-1D : reuse ' + [string]$ru['name'] + ' depuis 3R-1B (sha=' + $hash + ')')
  }
  if (@($schemaFailures).Count -gt 0) {
    throw ('[cr_refere_preventif] LOT 3R-1D : sorties 3R-1B schema non conforme : ' + (@($schemaFailures) -join ' ; '))
  }
  # --- REUSE C : normalisation deterministe hors LLM ---
  $cRawPath = Join-Path (Join-Path $srcRoot 'raw') 'pass3c_refere_raw.txt'
  if (-not (Test-Path -LiteralPath $cRawPath -PathType Leaf)) { throw ('[cr_refere_preventif] LOT 3R-1D : raw Pass3C 3R-1B absent (' + $cRawPath + ').') }
  $cRawText = Read-P3RawText $cRawPath
  if ([string]::IsNullOrWhiteSpace($cRawText)) { throw ('[cr_refere_preventif] LOT 3R-1D : raw Pass3C 3R-1B vide (' + $cRawPath + ').') }
  $cParsed = Parse-LlmJsonStrict -Raw $cRawText
  $cSchema = @(Get-P3Schema 'C')
  $cModelKeys = @($cParsed.psobject.Properties.Name)
  $cMissing = @($cSchema | Where-Object { $_ -notin $cModelKeys })
  $cExtra   = @($cModelKeys | Where-Object { $_ -notin $cSchema })
  $cNorm = ConvertTo-P3CSchemaCompliant -Parsed $cParsed -Source $globalObj
  $cNormKeys = @($cNorm.psobject.Properties.Name)
  $cNormMissing = @($cSchema | Where-Object { $_ -notin $cNormKeys })
  if (@($cNormMissing).Count -gt 0) {
    throw ('[cr_refere_preventif] LOT 3R-1D : normalisation Pass3C incomplet (missing=' + (@($cNormMissing) -join ',') + ').')
  }
  $cCounts = @(@($cNorm.actions).Count, @($cNorm.perspectives).Count, @($cNorm.annexes).Count)
  if ((@($cCounts) | Measure-Object -Sum).Sum -eq 0) {
    throw '[cr_refere_preventif] LOT 3R-1D : Pass3C normalise vide (garde semantique) - STOP.'
  }
  $cDst = Join-Path $p3Root 'pass3c_refere_response.json'
  Write-CrJsonAtomic -Path $cDst -Obj $cNorm
  Add-CrOutputFile $cDst
  [void]$artifacts.Add($cDst)
  $cHash = ''
  try { $cHash = (Get-FileHash -LiteralPath $cDst -Algorithm SHA256).Hash } catch { $cHash = '' }
  [void]$reused.Add([ordered]@{
    step = 'pass3c_refere'
    reused_from_previous_run = $true
    source_lot = '3R-1B'
    source_raw_path = $cRawPath
    p3c_normalized = $true
    source_raw_lot = '3R-1B'
    model_missing_keys = @($cMissing)
    model_extra_keys = @($cExtra)
    normalized_counts = @{ actions = [int]$cCounts[0]; perspectives = [int]$cCounts[1]; annexes = [int]$cCounts[2] }
    sha256 = $cHash
    http_status = 0
    status = 'ok'
  })
  Write-CrInfo ('Resume 3R-1D : Pass3C normalise hors LLM depuis 3R-1B (actions=' + $cCounts[0] + ' perspectives=' + $cCounts[1] + ' annexes=' + $cCounts[2] + ')')
  # --- Pass3D (budget puis appel) ---
  $sysD = Get-P3Text 'D'
  if (-not $sysD) { throw '[cr_refere_preventif] LOT 3R-1D : systeme Pass3D absent des constantes.' }
  $preD = Get-P3Part 'D' 'prefix'
  $sufD = Get-P3Part 'D' 'suffix'
  $usrD = $preD + $globalRaw + $sufD
  $diagD = Get-P3BudgetDiag -Alias $aliasD -SysText $sysD -UsrText $usrD
  Write-CrInfo ('Pass3D budget : final_tokens_est=' + [int]$diagD.final_input_tokens_est + ' available=' + [int]$diagD.available_input_tokens + ' fits=' + [bool]$diagD.fits)
  # --- Pass3E (sujet) ---
  # LOT 3R-1E : chargement du contexte general depuis la request (champs system/user).
  $ctxJsonPath = [string](Get-P3V $req 'context_json')
  $ctxUserText = ''
  $ctxSystemText = ''
  if (-not [string]::IsNullOrWhiteSpace($ctxJsonPath)) {
    if (-not (Test-Path -LiteralPath $ctxJsonPath -PathType Leaf)) { throw ('[cr_refere_preventif] LOT 3R-1E : contexte_general_compte_rendu.json introuvable (' + $ctxJsonPath + ').') }
    $ctxObj = $null
    try { $ctxObj = (Read-P3RawText $ctxJsonPath) | ConvertFrom-Json } catch { $ctxObj = $null }
    if ($null -eq $ctxObj) { throw ('[cr_refere_preventif] LOT 3R-1E : contexte_general_compte_rendu.json JSON invalide (' + $ctxJsonPath + ').') }
    $cv1 = Get-P3V $ctxObj 'system'
    if ($null -ne $cv1) { $ctxSystemText = [string]$cv1 }
    $cv2 = Get-P3V $ctxObj 'user'
    if ($null -ne $cv2) { $ctxUserText = [string]$cv2 }
    Write-CrInfo ('LOT 3R-1E : contexte general charge (' + $ctxJsonPath + ') system_chars=' + $ctxSystemText.Length + ' user_chars=' + $ctxUserText.Length)
  }
  $sysE = Get-P3Text 'E'
  if (-not $sysE) { throw '[cr_refere_preventif] LOT 3R-1D : systeme Pass3E absent des constantes.' }
  $eCompactPath = ''
  if ($compactPath -and (Test-Path -LiteralPath $compactPath -PathType Leaf)) { $eCompactPath = $compactPath }
  if (-not $eCompactPath) { throw ('[cr_refere_preventif] LOT 3R-1D : compact Pass2E sujet ' + $subjectNum + ' introuvable - PASS2E_INSUFFICIENT (STOP).') }
  $compactObj = $null
  try { $compactObj = (Read-P3RawText $eCompactPath) | ConvertFrom-Json } catch { $compactObj = $null }
  if ($null -eq $compactObj) { throw ('[cr_refere_preventif] LOT 3R-1D : compact Pass2E sujet ' + $subjectNum + ' JSON invalide - STOP.') }
  if (-not (Has-P3Synthese $compactObj)) { throw ('[cr_refere_preventif] LOT 3R-1D : compact Pass2E sujet ' + $subjectNum + ' sans synthese_intermediaire - PASS2E_INSUFFICIENT (STOP).') }
  # --- Verification : les seuls chunks actuels du sujet = ceux fournis ---
  $explicit = @($chunkPaths | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) })
  if (@($explicit).Count -lt 1) { throw ('[cr_refere_preventif] LOT 3R-1D : chunks Pass2F sujet ' + $subjectNum + ' absents - STOP.') }
  $chunkPathsSorted = @($explicit | Sort-Object { [IO.Path]::GetFileName($_) })
  $byParent = @{}
  foreach ($c0 in @($chunkPathsSorted)) {
    $parent = [IO.Path]::GetDirectoryName($c0)
    if (-not $byParent.ContainsKey($parent)) { $byParent[$parent] = New-Object System.Collections.ArrayList }
    [void]$byParent[$parent].Add($c0)
  }
  $totalChunksFound = 0
  foreach ($pk in @($byParent.Keys)) {
    $pat = 'subject_' + (Get-P3SujetNumeroStr $subjectNum) + '_chunk_*_response.json'
    $inDir = @(Get-ChildItem -LiteralPath $pk -Filter $pat -File -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { $_.FullName })
    $inDirNames = @($inDir | ForEach-Object { [IO.Path]::GetFileName($_) })
    $ours = @($byParent[$pk])
    $oursNames = @($ours | ForEach-Object { [IO.Path]::GetFileName($_) })
    if (@($inDirNames).Count -ne @($oursNames).Count) {
      throw ('[cr_refere_preventif] LOT 3R-1D : sujet ' + $subjectNum + ' chunks actuels (' + (@($inDirNames) -join ',') + ') != fournis (' + (@($oursNames) -join ',') + ') - STOP.')
    }
    $diff = @($inDirNames | Where-Object { $_ -notin $oursNames })
    if (@($diff).Count -gt 0) {
      throw ('[cr_refere_preventif] LOT 3R-1D : sujet ' + $subjectNum + ' chunks inattendus (' + (@($diff) -join ',') + ') - STOP.')
    }
    $totalChunksFound += @($inDir).Count
  }
  if ($subjectNum -eq 20 -and $totalChunksFound -ne 3) {
    throw ('[cr_refere_preventif] LOT 3R-1D : sujet 20 doit avoir exactement 3 chunks actuels (08/09/10), trouve=' + $totalChunksFound + ' - STOP.')
  }
  Write-CrInfo ('Pass3E sujet ' + $subjectNum + ' : chunks fournis=' + @($chunkPathsSorted).Count + ' (ordre croissant) total_actuel=' + $totalChunksFound)
  $usrE = Get-P3EUserText -CompactObj $compactObj -SubjectNumero $subjectNum -ChunkPaths @($chunkPathsSorted)
  if (-not [string]::IsNullOrWhiteSpace($ctxUserText)) { $usrE = 'Consignes generales du dossier (contexte_general_compte_rendu.json - champ user, contraignantes) :' + "`n" + $ctxUserText + "`n`n" + $usrE }
  $diagE = Get-P3BudgetDiag -Alias $aliasE -SysText $sysE -UsrText $usrE
  Write-CrInfo ('Pass3E budget : final_tokens_est=' + [int]$diagE.final_input_tokens_est + ' available=' + [int]$diagE.available_input_tokens + ' fits=' + [bool]$diagE.fits)
  # --- Rows (tableau budget) ---
  $rows = New-Object System.Collections.ArrayList
  [void]$rows.Add([ordered]@{
    pass = 'Pass3D'; subject = $null; kind = 'global'; alias = $aliasD
    input_chars = [int]$diagD.final_input_chars; input_tokens_est = [int]$diagD.final_input_tokens_est
    available_input_tokens = [int]$diagD.available_input_tokens; remaining_tokens = [int]$diagD.remaining_tokens
    fits = [bool]$diagD.fits; system_chars = [int]$diagD.system_prompt_chars; user_chars = [int]$diagD.user_prompt_chars
  })
  [void]$rows.Add([ordered]@{
    pass = 'Pass3E'; subject = $subjectNum; kind = 'subject'; alias = $aliasE
    chunk_count = @($chunkPathsSorted).Count
    has_synthese_intermediaire = (Has-P3Synthese $compactObj)
    input_chars = [int]$diagE.final_input_chars; input_tokens_est = [int]$diagE.final_input_tokens_est
    available_input_tokens = [int]$diagE.available_input_tokens; remaining_tokens = [int]$diagE.remaining_tokens
    fits = [bool]$diagE.fits; system_chars = [int]$diagE.system_prompt_chars; user_chars = [int]$diagE.user_prompt_chars
  })
  $budFile = Join-Path $p3Root 'pass3r1d_budget.json'
  Write-CrJsonAtomic -Path $budFile -Obj @{ lot = $script:P3LotLabel; plan_only = (-not $Exec); rows = @($rows) }
  Add-CrOutputFile $budFile
  [void]$artifacts.Add($budFile)
  if (-not $Exec) {
    $planOk = ($statusAll -eq 'ok') -and [bool]$diagD.fits -and [bool]$diagE.fits
    $summaryPlan = @{
      lot = $script:P3LotLabel; mode = 'plan_only'; llm_calls = 0; http_calls = 0
      status = $(if ($planOk) { 'dry_run_ok' } else { 'dry_run_not_fit' }); ok = $planOk
      out_root = $p3Root
    }
    return @{ ok = $planOk; status = [string]$summaryPlan.status; llm_calls = 0; http_calls = 0; rows = @($rows); artifacts = @($artifacts); reused = @($reused); summary = $summaryPlan; out_root = $p3Root; d_diag = $diagD; e_diag = $diagE; d_entry = $null; e_entry = $null }
  }
  # --- Gate D puis appel unique (contourne si rerun Pass3E seul, LOT 3R-1E skip_d) ---
  if (-not $skipD -and -not [bool]$diagD.fits) { throw ('[cr_refere_preventif] LOT 3R-1D : Pass3D DOES_NOT_FIT (final_tokens_est=' + [int]$diagD.final_input_tokens_est + ') - aucun appel.') }
  if ($skipD) {
    $entryD = $null
    Write-CrInfo ('[cr_refere_preventif] LOT 3R-1E : Pass3D non rappele (skip_d=true) - seul Pass3E sujet ' + $subjectNum + ' sera execute.')
  } else {
    $resD = Invoke-P3Remote -ArtifactBase 'pass3d_refere' -SysTxt $sysD -UsrTxt $usrD -Alias $aliasD -ArtDir $p3Root -Pass 'D'
    $entryD = $resD.entry
    if ($resD.prompt_file) { [void]$artifacts.Add([string]$resD.prompt_file) }
    $llmCount += 1
    $httpCount += 1
    if (-not $resD.ok -or $entryD.status -ne 'ok') { throw ('[cr_refere_preventif] LOT 3R-1D : Pass3D en echec (status=' + $entryD.status + ') - aucun retry.') }
    if ($entryD.finish_reason -eq 'length') { throw '[cr_refere_preventif] LOT 3R-1D : Pass3D finish_reason=length - STOP (aucun Pass3E).' }
    if ($resD.raw_file) { [void]$artifacts.Add([string]$resD.raw_file) }
    if ($resD.parsed_file) { [void]$artifacts.Add([string]$resD.parsed_file) }
  }
  # --- Gate E puis appel unique ---
  if (-not [bool]$diagE.fits) { throw ('[cr_refere_preventif] LOT 3R-1D : Pass3E DOES_NOT_FIT (final_tokens_est=' + [int]$diagE.final_input_tokens_est + ') - aucun appel.') }
  $baseE = 'pass3e_sujet_' + (Get-P3SujetNumeroStr $subjectNum)
  $resE = Invoke-P3Remote -ArtifactBase $baseE -SysTxt $sysE -UsrTxt $usrE -Alias $aliasE -ArtDir $p3Root -Pass 'E'
  $entryE = $resE.entry
  if ($resE.prompt_file) { [void]$artifacts.Add([string]$resE.prompt_file) }
  $llmCount += 1
  $httpCount += 1
  if (-not $resE.ok -or $entryE.status -ne 'ok') { throw ('[cr_refere_preventif] LOT 3R-1D : Pass3E en echec (status=' + $entryE.status + ') - aucun retry.') }
  if ($entryE.finish_reason -eq 'length') { throw ('[cr_refere_preventif] LOT 3R-1D : Pass3E sujet ' + $subjectNum + ' finish_reason=length - STOP.') }
  if ($resE.raw_file) { [void]$artifacts.Add([string]$resE.raw_file) }
  if ($resE.parsed_file) { [void]$artifacts.Add([string]$resE.parsed_file) }
  $sujDir = Join-Path $p3Root 'sujets'
  Ensure-Dir $sujDir
  $sujResp = Join-Path $sujDir ('sujet_' + (Get-P3SujetNumeroStr $subjectNum) + '_synthese.json')
  Write-CrJsonAtomic -Path $sujResp -Obj $resE.parsed
  Add-CrOutputFile $sujResp
  [void]$artifacts.Add($sujResp)
  $expectedCalls = $(if ($skipD) { 1 } else { 2 })
  $okFinal = ($llmCount -eq $expectedCalls) -and ($httpCount -eq $expectedCalls) -and ($statusAll -eq 'ok')
  $summary = @{
    lot = $script:P3LotLabel; mode = 'execute_resume'; llm_calls = $llmCount; http_calls = $httpCount
    status = 'ok'; ok = $okFinal; out_root = $p3Root
  }
  return @{ ok = $okFinal; status = 'ok'; llm_calls = $llmCount; http_calls = $httpCount; rows = @($rows); artifacts = @($artifacts); reused = @($reused); summary = $summary; out_root = $p3Root; d_diag = $diagD; e_diag = $diagE; d_entry = $entryD; e_entry = $entryE }
}


# === fin lot 3R-1B ===


# ---------------------------------------------------------------------------
# Corps principal
# ---------------------------------------------------------------------------
$StartedAtMain = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
$ExitCodeMain = 1
$SuccessMain = $false
$PathsMain = $null
$CtxMain = $null
$OutDirMain = $OutDir

try {
  Write-CrInfo ('pipeline=' + $script:PipelineName + ' lot=' + $(if ($ExecuteLlm) { '2F-6C2C' } else { '2F-6C2B' }) + ' dry_run=' + [bool]$DryRun + ' execute_llm=' + [bool]$ExecuteLlm)

  # --- Garde securite : DryRun => aucun appel ; ExecuteLlm => mode controle 2F-6C2C ---
  $llmCallsLog = 0
  $httpCallsLog = 0
  $chunksInvoked = 0
  $modelInfoProbeResult = $null
  $script:llmEntries = New-Object System.Collections.ArrayList
  if (-not $ExecuteLlm) {
    $script:HttpBlocked = $true
    Write-CrInfo 'mode DryRun : aucun appel LLM/HTTP (comportement 2F-6C2B inchange).'
  } else {
    $script:HttpBlocked = $false
    if (-not $ApiBase) { $ApiBase = [string][Environment]::GetEnvironmentVariable('PIPELINE_API_BASE') }
    if (-not $ApiBase) { $ApiBase = 'http://192.168.1.20:5055' }
    # Ordre de resolution de la cle : 1) -ApiKey  2) PIPELINE_API_KEY  3) ADAPTER_API_KEY.
    # La valeur de la cle n'est jamais journalisee.
    if (-not $ApiKey)  { $ApiKey = [string][Environment]::GetEnvironmentVariable('PIPELINE_API_KEY') }
    if (-not $ApiKey)  { $ApiKey = [string][Environment]::GetEnvironmentVariable('ADAPTER_API_KEY') }
    if (-not $ApiKey)  { throw '[cr_refere_preventif] LOT 2F-6C2C : cle API manquante (parametre -ApiKey, PIPELINE_API_KEY ou ADAPTER_API_KEY) - arret sans appel LLM.' }
    $script:AdapterApiBase = $ApiBase
    $script:AdapterApiKey  = $ApiKey
    $script:AdapterAlias   = Resolve-Pass2FModelRoute $ModelPass2F
    $script:LlmTimeoutSec  = $LlmTimeoutSec
    Write-CrInfo ('mode ExecuteLlm controle (lot 2F-6C2C) : alias=' + $ModelPass2F + ' endpoint=' + $ApiBase + ' temperature=0.2 max_tokens=' + $MaxOutputTokens + ' max_appels_logiques=' + $MaxLogicalLlmCalls)
  }

  # --- Repertoire de sortie ---
  if (-not $OutDirMain) {
    if ($DryRun) {
      $tmpRoot = [System.IO.Path]::GetTempPath()
      $OutDirMain = Join-Path $tmpRoot ('cr_refere_dryrun_' + $(if ($IdAffaire) { $IdAffaire } else { 'affaire' }) + '_' + (Get-CrTimestampStamp))
      Write-CrWarn "Aucun -OutDir fourni en DryRun ; sortie temporaire: $OutDirMain (aucune ecriture production)"
    } else {
      throw "[cr_refere_preventif] -OutDir requis (mode non DryRun refuse dans ce lot)."
    }
  }
  $OutDirMain = [System.IO.Path]::GetFullPath($OutDirMain)

  # --- Resolution des chemins ---
  $PathsMain = Resolve-ReferePreventifPaths -InfosProjetPath $InfosProjetPath -IdAffaire $IdAffaire -IdCaptation $IdCaptation -DataRoot $DataRoot -Register

  # --- Logs ---
  $logFileMain = Write-CrRunLog -OutDir $OutDirMain -Label $JobLabel
  Add-CrLogLine ('out_dir=' + $OutDirMain)
  Add-CrLogLine ('affaire=' + $PathsMain.IdAffaire + ' captation=' + $PathsMain.IdCaptation)
  Add-CrLogLine ('transcription_dir=' + $PathsMain.TranscriptionDir)
  Add-CrLogLine ('photos_dir=' + $PathsMain.PhotosDir)
  Add-CrLogLine ('compte_rendu_dir=' + $PathsMain.CompteRenduDir)

  # --- Chargement des sources (lecture seule) ---
  $CtxMain = Read-CaptureSources -Paths $PathsMain
  Write-CrInfo ('fenetre ASR commentaire: before=' + $CtxMain.asr_window.before_sec + 's after=' + $CtxMain.asr_window.after_sec + 's source=' + $CtxMain.asr_window.source)
  Write-CrInfo ('ASR: ' + @($CtxMain.asr_rows).Count + ' lignes depuis ' + $CtxMain.asr_csv)
  Write-CrInfo ('photos.csv: ' + @($CtxMain.photos).Count + ' photos ; Sujets.csv: ' + @($CtxMain.sujets).Count + ' sujets')
  Add-CrLogLine ('asr_rows=' + @($CtxMain.asr_rows).Count)
  Add-CrLogLine ('photos_csv_rows=' + @($CtxMain.photos).Count)

  # ============================================================================
  # REFERE-E2E-2 : mode de production unique.
  # -RunReferePipeline : EXECUTION complete (Pass2F -> Pass2B_2F 36 batches ->
  #   6G -> Pass3A-D -> Pass3E tous sujets utiles -> assemblage -> DOCX).
  # -RunReferePipelinePlanOnly : plan + budgets, AUCUN appel LLM/HTTP.
  # Exclusif : aucun autre switch Pass2B_2F / Pass3Refere / ExecuteLlm / DryRun.
  # ============================================================================
  if ($RunReferePipeline -or $RunReferePipelinePlanOnly) {
    $refProdPlanOnly = [bool]$RunReferePipelinePlanOnly
    if ($DryRun -or $ExecuteLlm -or $BuildPass2B2F -or $Pass2B2FExecute -or $Pass2B2FRunComplete -or $Pass2B2FConsolidateFinal -or $Pass2B2FConsolidateHierarchical -or $Pass3Refere -or $Pass3RefereResumePlanOnly -or $Pass3RefereResumeExecute) {
      throw '[cr_refere_preventif] REFERE-E2E-2 : -RunReferePipeline est un mode unique et exclusif (aucun autre switch Pass2B_2F/Pass3Refere/ExecuteLlm/DryRun).'
    }
    # Garde anti-rejeu : un OutDir de production doit etre neuf (artefacts de lots
    # precedents refuses par defaut). -Force autorise une reprise explicite.
    $prodConflicts = New-Object System.Collections.ArrayList
    foreach ($pf in @(Get-ChildItem -LiteralPath $OutDirMain -Force -ErrorAction SilentlyContinue)) {
      if ($pf.PSIsContainer -and $pf.Name -eq 'logs') { continue }
      if ($pf.PSIsContainer -and $pf.Name -in @('pass2b2f', 'pass3_refere')) { [void]$prodConflicts.Add($pf.FullName); continue }
      if (-not $pf.PSIsContainer -and $pf.Name -in @('manifest.json', 'refere_production_plan.json', 'refere_global_meeting.json')) { [void]$prodConflicts.Add($pf.FullName); continue }
      if (-not $pf.PSIsContainer) { [void]$prodConflicts.Add($pf.FullName) }
    }
    if (@($prodConflicts).Count -gt 0 -and (-not $Force)) {
      throw ('[cr_refere_preventif] REFERE-E2E-2 : OutDir non neuf (' + $OutDirMain + ') : ' + (@($prodConflicts) -join ', ') + ' - utiliser un OutDir neuf ou -Force.')
    }
    $script:RefereProgress = @{ llm_calls = 0; http_calls = 0; phase = 'init' }
    if (-not $script:RefereE2E2OrchestratorLoaded) {
      $orchE2e2 = Join-Path $PSScriptRoot 'refere_production_orchestrator.ps1'
      if (-not (Test-Path -LiteralPath $orchE2e2 -PathType Leaf)) { throw ('[cr_refere_preventif] REFERE-E2E-2 : orchestrateur introuvable : ' + $orchE2e2) }
      . $orchE2e2
      $script:RefereE2E2OrchestratorLoaded = $true
    }
    $refProdLot = 'E2E-2'
    if ($RefereLotLabel) { $refProdLot = [string]$RefereLotLabel }
    Write-CrInfo ('[REFERE-E2E-2 ' + $(if ($refProdPlanOnly) { 'PLAN' } else { 'EXEC' }) + '] mode production unique lot=' + $refProdLot + ' out=' + $OutDirMain)
    $refProd = Invoke-RefereProductionPipeline -Paths $PathsMain -Ctx $CtxMain -OutDir $OutDirMain -StartedAt $StartedAtMain -Exec:(-not $refProdPlanOnly) -ApiBase $ApiBase -ApiKey $ApiKey -LotLabel $refProdLot -SegmentsDir $GeneralistSegmentsDir -Pass2ECompactsDir $ReferePass2ECompactsDir -Pass2FChunksDir $ReferePass2FChunksDir -ContextJsonPath $RefereContextJsonPath -BudgetReferenceGlobalJson $RefereBudgetReferenceGlobalJson -ModelPass2F $ModelPass2F -MaxTokensPass2F $MaxOutputTokens -ModelPass2B2F $ModelPass2B2F -MaxBatchChars $Pass2B2FMaxBatchChars -MaxBatchTokens $Pass2B2FMaxBatchTokens -MaxTokensIntermediate $Pass2B2FMaxTokensIntermediate -RendererBase $RefereRendererBase
    $refSum2 = $refProd.summary
    $refDoc2 = ''
    if ($null -ne $refProd.plan_or_manifest_path) { $refDoc2 = [string]$refProd.plan_or_manifest_path }
    Write-CrInfo ('RESULT=' + $(if ([bool]$refProd.ok) { 'OK' } else { [string]$refProd.status }))
    Write-CrInfo ('MODE=' + [string]$refSum2.mode)
    Write-CrInfo ('STATUS=' + [string]$refSum2.status)
    Write-CrInfo ('LLM_CALLS=' + [int]$refProd.llm_calls + ' HTTP_CALLS=' + [int]$refProd.http_calls)
    Write-CrInfo ('EXPECTED_LLM_TOTAL=' + [int]$refSum2.expected_llm_calls_total)
    Write-CrInfo ('REFERE_GLOBAL_MEETING=' + [string]$refSum2.refere_global_meeting_path)
    Write-CrInfo ('REFERE_GLOBAL_BY_SUJET=' + [string]$refSum2.refere_global_by_sujet_path)
    Write-CrInfo ('REFERE_GLOBAL_FINAL=' + [string]$refSum2.refere_global_final_path)
    Write-CrInfo ('DOCX=' + [string]$refSum2.docx_path)
    if ($refDoc2) { Write-CrInfo ('PLAN_OR_MANIFEST=' + $refDoc2) }
    $ExitCodeMain = $(if ([bool]$refProd.ok) { 0 } else { 1 })
    $SuccessMain = [bool]$refProd.ok
    if (-not [bool]$refProd.ok) {
      Write-CrErr ('[REFERE-E2E-2] production non OK (status=' + [string]$refSum2.status + ') - aucun retry.')
    }
    exit $ExitCodeMain
  }
  # --- Classification des photos par affectation humaine (AUTORITATIVE) ---
  $assignByBase = @{}
  foreach ($relK in @($CtxMain.assignments.Keys)) {
    $bK = New-PhotoKey $relK
    $assignByBase[$bK] = $CtxMain.assignments[$relK]
  }
  $affectedBySubject = @{}
  $photosAffectees = 0
  $photosExclues = 0
  $photosSansAffectation = 0
  $photosSansTAudio = 0
  foreach ($ph in @($CtxMain.photos)) {
    $base = New-PhotoKey $ph.photo_rel_native
    $asg = $null
    if ($CtxMain.assignments.ContainsKey($ph.photo_rel_native)) { $asg = $CtxMain.assignments[$ph.photo_rel_native] }
    elseif ($assignByBase.ContainsKey($base)) { $asg = $assignByBase[$base] }
    if ($null -eq $asg) { $photosSansAffectation++ }
    elseif ([string]$asg.status -eq 'affectee') {
      $photosAffectees++
      $sn = [int]$asg.subject_numero
      if ($affectedBySubject.ContainsKey($sn)) { $affectedBySubject[$sn] = [int]$affectedBySubject[$sn] + 1 } else { $affectedBySubject[$sn] = 1 }
    }
    elseif ([string]$asg.status -eq 'exclue') { $photosExclues++ }
    if ($null -eq $ph.t_audio) { $photosSansTAudio++ }
  }
  $sujetsAvecPhotos = @($affectedBySubject.Keys | Sort-Object)
  Write-CrInfo ('perimetre photos: total=' + @($CtxMain.photos).Count + ' affectees=' + $photosAffectees + ' exclues=' + $photosExclues + ' sans affectation=' + $photosSansAffectation)
  Add-CrLogLine ('perimeter photos_affectees=' + $photosAffectees + ' exclues=' + $photosExclues + ' sans_affectation=' + $photosSansAffectation)

  # --- LOT 2F-6C2C : parse de -ChunkSelect ('sujet:chunk') puis probe /model_info ---
  $selectMap = @{}
  foreach ($selRaw in @($ChunkSelect)) {
    $parts = ([string]$selRaw).Split(':', 2)
    if (@($parts).Count -ne 2) { throw ('[cr_refere_preventif] -ChunkSelect invalide (format sujet:chunk) : ' + $selRaw) }
    $sA = 0
    $cA = 0
    if (-not [int]::TryParse([string]$parts[0], [ref]$sA)) { throw ('[cr_refere_preventif] -ChunkSelect numero de sujet invalide : ' + $selRaw) }
    if (-not [int]::TryParse([string]$parts[1], [ref]$cA)) { throw ('[cr_refere_preventif] -ChunkSelect numero de chunk invalide : ' + $selRaw) }
    if (-not $selectMap.ContainsKey($sA)) { $selectMap[$sA] = New-Object System.Collections.ArrayList }
    [void]$selectMap[$sA].Add($cA)
  }
  if ($ExecuteLlm) {
    $modelInfoProbeResult = Invoke-ProbeModelInfo -ApiBase $ApiBase
    $httpCallsLog += [int]$modelInfoProbeResult.probes_attempted
    Write-CrInfo ('probe model_info : n_ctx_confirmed=' + [bool]$modelInfoProbeResult.n_ctx_confirmed + ' n_ctx=' + $(if ($null -ne $modelInfoProbeResult.n_ctx) { [string]$modelInfoProbeResult.n_ctx } else { 'N/A' }))
    if (-not [bool]$modelInfoProbeResult.n_ctx_confirmed) {
      Write-CrWarn 'Impossible de confirmer n_ctx via /model_info (ou equivalent) : budget pass2f_local conserve experimental_unconfirmed.'
      [void]$script:CriticalQaWarnings.Add('n_ctx non confirme via probe /model_info (lot 2F-6C2C)')
    }
  }

  # --- Par sujet : unites documentaires + plan de chunks ---
  $perSubject = New-Object System.Collections.ArrayList
  $totUnits = 0
  $totChunks = 0
  $totRowsUsed = 0
  $totDataChars = 0
  $totEnforce = 0
  $totOversized = 0
  $totPhotoUnits = 0
  # LOT 2F-6C2C5 : compteurs double budget (trace manifest)
  $totSplitInput = 0
  $totSplitOutput = 0
  $totSplitSubjectEnd = 0
  $totSplitForcedUnit = 0
  $totOutputBudgetKO = 0
  $maxPhotosPerChunk = 0
  $maxInputTokensEst = 0
  $maxOutputTokensEst = 0

  foreach ($sn in $sujetsAvecPhotos) {
    $snInt = [int]$sn
    $subjectCanon = $null
    if ($CtxMain.sujets_by_numero.ContainsKey($snInt)) { $subjectCanon = $CtxMain.sujets_by_numero[$snInt] }
    $subjectPhotos = @($CtxMain.photos | Where-Object {
      $b2 = New-PhotoKey $_.photo_rel_native
      $ok = $false
      if ($CtxMain.assignments.ContainsKey($_.photo_rel_native)) { $ok = ([string]$CtxMain.assignments[$_.photo_rel_native].status -eq 'affectee' -and [int]$CtxMain.assignments[$_.photo_rel_native].subject_numero -eq $snInt) }
      elseif ($assignByBase.ContainsKey($b2)) { $ok = ([string]$assignByBase[$b2].status -eq 'affectee' -and [int]$assignByBase[$b2].subject_numero -eq $snInt) }
      return $ok
    })
    $title = ''
    $loc = ''
    $desc = ''
    if ($null -ne $subjectCanon) {
      $title = [string]$subjectCanon.titre; $loc = [string]$subjectCanon.localisation; $desc = [string]$subjectCanon.description
    }
    if (-not $title) {
      $firstAsg = $null
      foreach ($phX in $subjectPhotos) {
        $bX = New-PhotoKey $phX.photo_rel_native
        if ($CtxMain.assignments.ContainsKey($phX.photo_rel_native)) { $firstAsg = $CtxMain.assignments[$phX.photo_rel_native]; break }
        elseif ($assignByBase.ContainsKey($bX)) { $firstAsg = $assignByBase[$bX]; break }
      }
      if ($firstAsg) { $title = [string]$firstAsg.subject_title; $loc = [string]$firstAsg.subject_location }
    }
    $subject = @{ numero=$snInt; titre=$title; localisation=$loc; description=$desc }
    $stream = New-SubjectUnitStream -Subject $subject -Photos $subjectPhotos -AsrRows $CtxMain.asr_rows -Before ([double]$CtxMain.asr_window.before_sec) -After ([double]$CtxMain.asr_window.after_sec) -CohortGapSec $script:CohortGapSec
    $plan = New-ChunkPlanForSubject -Stream $stream -Budget $script:BudgetPass2F -IdAffaire $PathsMain.IdAffaire -IdCaptation $PathsMain.IdCaptation -AsrRows $CtxMain.asr_rows -AsrEnd 0.0
    Write-SubjectArtifacts -Stream $stream -Plan $plan -OutDir $OutDirMain -IdAffaire $PathsMain.IdAffaire -IdCaptation $PathsMain.IdCaptation

    # --- LOT 2F-6C2C : execution LLM controlee (uniquement les chunks selectionnes) ---
    if ($ExecuteLlm) {
      $selList = $null
      if ($selectMap.ContainsKey($snInt)) { $selList = $selectMap[$snInt] }
      if ($null -ne $selList) {
        foreach ($chSel in @($plan.chunks)) {
          $ciSel = [int]$chSel.chunk_index
          if (@($selList) -contains $ciSel) {
            if ($chunksInvoked -ge [int]$MaxLogicalLlmCalls) {
              throw ('[cr_refere_preventif] LOT 2F-6C2C : depassement du nombre logique d''appels (max=' + $MaxLogicalLlmCalls + ').')
            }
            Write-CrInfo ('appel pass2f_local : sujet ' + $snInt + ' chunk ' + $ciSel + '/' + $plan.chunk_count + ' unites=' + $chSel.units_count + ' tokens_est=' + $chSel.prompt_tokens_est)
            Add-CrLogLine ('llm_call_start sujet=' + $snInt + ' chunk=' + $ciSel)
            $callEntry = Invoke-Pass2FChunkAndRecord -Chunk $chSel -Plan $plan -OutDir $OutDirMain -MaxTokens $MaxOutputTokens -Temperature 0.2 -AliasLogique $ModelPass2F
            $chunksInvoked++
            $llmCallsLog += [int]$callEntry.actual_llm_calls
            $httpCallsLog += [int]$callEntry.actual_http_calls
            [void]$script:llmEntries.Add($callEntry)
            Add-CrLogLine ('llm_call_end sujet=' + $snInt + ' chunk=' + $ciSel + ' error=' + $(if ($callEntry.error) { 'yes' } else { 'no' }))
          }
        }
      }
    }

    $nUnits = @($stream.units).Count
    $nPhotoUnits = @($stream.units | Where-Object { $_.kind -eq 'photo' }).Count
    $nRows = @($stream.rows_used).Count
    $totUnits += $nUnits
    $totPhotoUnits += $nPhotoUnits
    $totRowsUsed += $nRows
    $totChunks += [int]$plan.chunk_count
    foreach ($ch in @($plan.chunks)) { $totDataChars += [int]$ch.prompt_chars }
    foreach ($ch in @($plan.chunks)) { if ([bool]$ch.enforce_required) { $totEnforce++ } }
    $totOversized += @($plan.oversized_units).Count

    $chunkSummaries = New-Object System.Collections.ArrayList
    $sSplitInput = 0
    $sSplitOutput = 0
    $sSplitSubjectEnd = 0
    $sSplitForcedUnit = 0
    $sMaxPhotos = 0
    $sMaxInputTok = 0
    $sMaxOutputTok = 0
    foreach ($ch in @($plan.chunks)) {
      $chunkSummaries.Add(@{
        chunk_index=[int]$ch.chunk_index
        chunk_total=[int]$ch.chunk_total
        unit_indices=@($ch.unit_indices)
        units_count=[int]$ch.units_count
        photos_count=[int]$ch.photos_count
        data_chars_est=[int]$ch.data_chars_est
        prompt_chars=[int]$ch.prompt_chars
        prompt_tokens_est=[int]$ch.prompt_tokens_est
        input_tokens_est=[int]$ch.input_tokens_est
        available_tokens=[int]$ch.available_tokens
        available_input_tokens=[int]$ch.available_input_tokens
        output_tokens_est=[int]$ch.output_tokens_est
        available_output_tokens=[int]$ch.available_output_tokens
        output_budget_ok=[bool]$ch.output_budget_ok
        split_reason=[string]$ch.split_reason
        enforce_required=[bool]$ch.enforce_required
      }) | Out-Null
      switch ([string]$ch.split_reason) {
        'input_budget'  { $sSplitInput++; $totSplitInput++ }
        'output_budget' { $sSplitOutput++; $totSplitOutput++ }
        'subject_end'   { $sSplitSubjectEnd++; $totSplitSubjectEnd++ }
        'forced_unit'   { $sSplitForcedUnit++; $totSplitForcedUnit++ }
      }
      if (-not [bool]$ch.output_budget_ok) { $totOutputBudgetKO++ }
      $pc = [int]$ch.photos_count
      if ($pc -gt $sMaxPhotos) { $sMaxPhotos = $pc }
      if ($pc -gt $maxPhotosPerChunk) { $maxPhotosPerChunk = $pc }
      $it = [int]$ch.input_tokens_est
      if ($it -gt $sMaxInputTok) { $sMaxInputTok = $it }
      if ($it -gt $maxInputTokensEst) { $maxInputTokensEst = $it }
      $ot = [int]$ch.output_tokens_est
      if ($ot -gt $sMaxOutputTok) { $sMaxOutputTok = $ot }
      if ($ot -gt $maxOutputTokensEst) { $maxOutputTokensEst = $ot }
    }
    $perSubject.Add(@{
      subject_numero=$snInt
      titre=$title
      photo_count=$subjectPhotos.Count
      unit_count=$nUnits
      photo_unit_count=$nPhotoUnits
      rows_used_count=$nRows
      chunk_count=[int]$plan.chunk_count
      split_by_input_budget=$sSplitInput
      split_by_output_budget=$sSplitOutput
      split_by_subject_end=$sSplitSubjectEnd
      split_by_forced_unit=$sSplitForcedUnit
      max_photos_per_chunk=$sMaxPhotos
      max_input_tokens_est=$sMaxInputTok
      max_output_tokens_est=$sMaxOutputTok
      total_prompt_chars=$totDataChars
      chunks=@($chunkSummaries)
      oversized_units=@($plan.oversized_units)
    }) | Out-Null

    $sujChars = 0
    $sujToks  = 0
    foreach ($chP in @($plan.chunks)) { $sujChars += [int]$chP.prompt_chars; $sujToks += [int]$chP.prompt_tokens_est }
    $msg = ('sujet {0} : photos={1} unites={2} rows_asr={3} chunks={4} unites/chunk={5} prompt_chars={6} prompt_tokens_est={7} enforce={8}' -f $snInt, $subjectPhotos.Count, $nUnits, $nRows, $plan.chunk_count, $(if ([int]$plan.chunk_count -gt 0) { [math]::Round($nUnits / [int]$plan.chunk_count, 1) } else { 0 }), $sujChars, $sujToks, $totEnforce)
    Write-CrHighlightLine -Subject ([string]$snInt) -Line $msg
    Add-CrLogLine $msg
  }

  if ($ExecuteLlm -and $llmCallsLog -lt 1) {
    throw '[cr_refere_preventif] LOT 2F-6C2C : aucun chunk selectionne n''a pu etre execute (verifier -ChunkSelect).'
  }

  $totals = @{
    photos_total=@($CtxMain.photos).Count
    photos_affectees=$photosAffectees
    photos_exclues=$photosExclues
    photos_sans_affectation=$photosSansAffectation
    photos_sans_t_audio=$photosSansTAudio
    sujets_avec_photos=$sujetsAvecPhotos
    unit_photo_total=$totPhotoUnits
    unit_total=$totUnits
    asr_rows_utilisees_total=$totRowsUsed
    chunk_total=$totChunks
    prompt_chars_total=$totDataChars
    enforce_required_total=$totEnforce
    oversized_unit_total=$totOversized
    split_by_input_budget=$totSplitInput
    split_by_output_budget=$totSplitOutput
    split_by_subject_end=$totSplitSubjectEnd
    split_by_forced_unit=$totSplitForcedUnit
    output_budget_ok_false_total=$totOutputBudgetKO
    max_photos_per_chunk=$maxPhotosPerChunk
    max_input_tokens_est=$maxInputTokensEst
    max_output_tokens_est=$maxOutputTokensEst
  }

  # --- Verifications QA obligatoires ---
  $qaFail = $false
  if ($photosAffectees -ne 399) {
    $qaFail = $true
    $script:CriticalQaWarnings.Add('photos affectees != 399 (valeur=' + $photosAffectees + ')') | Out-Null
  }
  if ($photosExclues -ne 6) {
    $qaFail = $true
    $script:CriticalQaWarnings.Add('photos exclues != 6 (valeur=' + $photosExclues + ')') | Out-Null
  }
  if ($totPhotoUnits -ne $photosAffectees) {
    $qaFail = $true
    $script:CriticalQaWarnings.Add('unites photo (' + $totPhotoUnits + ') != photos affectees (' + $photosAffectees + ')') | Out-Null
  }
  foreach ($fw in @($script:FilesWritten)) {
    $fwFull = [System.IO.Path]::GetFullPath($fw)
    foreach ($inP in @($script:FunctionalInputs)) {
      if (-not $inP) { continue }
      if ([System.IO.Path]::GetFullPath($inP) -ieq $fwFull) {
        $qaFail = $true
        $script:CriticalQaWarnings.Add('ecriture sur chemin d''entree: ' + $fw) | Out-Null
      }
    }
  }
  if (-not $qaFail) {
    Write-CrInfo 'QA perimeter OK : 399 affectees / 6 exclues / aucune re-affectation / aucun ecrasement d''entree.'
  }

  # =========================================================================
  # LOT 2B2F-1 : Pass2B_2F - DryRun de la matiere globale enrichie (sans LLM)
  # -------------------------------------------------------------------------
  # Active uniquement si -BuildPass2B2F. Interdit dans ce lot : ExecuteLlm,
  # HTTP, LLM. Entrees : segments rang 1 du run CR generaliste + vignettes
  # photographiques rang 1 (affectations humaines). Aucune sortie de passe de
  # rang 2 n est consommee (ni Pass2B, ni Pass2E, ni Pass2F).
  # =========================================================================
  $pass2b2fSummary = $null
  $pass2b2fExecSummary = $null
  $pass2b2fExecuteMode = ($BuildPass2B2F -and $Pass2B2FExecute)
  $pass2b2fConsolidateMode = ($BuildPass2B2F -and $Pass2B2FConsolidateFinal)
  $pass2b2fHierarchicalMode = ($BuildPass2B2F -and $Pass2B2FConsolidateHierarchical)
  if ($pass2b2fHierarchicalMode) {
    # ---------------------------------------------------------------------
    # LOT 2B2F-12 : consolidation hierarchique interne Pass2B_2F (6G).
    # 36 sorties batch -> 6 groupes chronologiques -> 6 condensations
    # intermediaires (7 cles) -> 1 consolidation finale -> canonique.
    # Tous les appels restent des sous-appels internes de la passe.
    # ---------------------------------------------------------------------
    if ($Pass2B2FConsolidateLlm -and $DryRun) {
      throw ('[cr_refere_preventif] Pass2B_2F LOT ' + $Pass2B2FLotLabel + ' : -Pass2B2FConsolidateLlm et -DryRun sont mutuellement exclus.')
    }
    if ($Pass2B2FConsolidateFinal) {
      throw ('[cr_refere_preventif] Pass2B_2F LOT ' + $Pass2B2FLotLabel + ' : -Pass2B2FConsolidateHierarchical est incompatible avec -Pass2B2FConsolidateFinal.')
    }
    if ($Pass2B2FExecute -or $Pass2B2FRunComplete) {
      throw ('[cr_refere_preventif] Pass2B_2F LOT ' + $Pass2B2FLotLabel + ' : -Pass2B2FConsolidateHierarchical est incompatible avec -Pass2B2FExecute / -Pass2B2FRunComplete.')
    }
    if ($ExecuteLlm) {
      throw ('[cr_refere_preventif] Pass2B_2F LOT ' + $Pass2B2FLotLabel + ' : ne pas utiliser -ExecuteLlm (pilote Pass2F) avec la consolidation hierarchique Pass2B_2F.')
    }
    $hierLotStr = $Pass2B2FLotLabel
    if (-not $hierLotStr) { $hierLotStr = '2B2F-12' }
    Write-CrInfo ('Pass2B_2F LOT ' + $hierLotStr + ' : mode consolidation hierarchique 6G (dry_run=' + (-not [bool]$Pass2B2FConsolidateLlm) + ')')
    $hierRes = Invoke-Pass2B2FHierarchicalConsolidation -OutDir $OutDirMain -BatchOutputsDir $Pass2B2FBatchOutputsDir -ExhaustiveJsonPath $Pass2B2FExhaustiveJsonPath -ModelAlias $ModelPass2B2F -StartedAt $StartedAtMain -ApiBaseOverride $ApiBase -ApiKeyOverride $ApiKey -LotLabel $hierLotStr -MaxTokensIntermediate $Pass2B2FMaxTokensIntermediate -ConsolidateLlm:$Pass2B2FConsolidateLlm
    $hierSum = $hierRes.summary
    $pass2b2fSummary = $hierSum
    $totals['pass2b2f'] = @{
      dry_run = (-not [bool]$Pass2B2FConsolidateLlm)
      hierarchical_6g = $true
      lot = [string]$hierSum.lot
      llm_calls = [int]$hierSum.llm_calls
      http_calls = [int]$hierSum.http_calls
      alias = $ModelPass2B2F
      status = [string]$hierSum.status
      ok = [bool]$hierSum.ok
      mode = [string]$hierSum.mode
      strategy = '6G'
      groups_count = [int]$hierSum.groups_count
      groups = @($hierSum.groups)
      exhaustive_source = [string]$hierSum.exhaustive_source
      exhaustive_path = [string]$hierSum.exhaustive_path
      canonical_output = [string]$hierSum.canonical_output
      manifest = [string]$hierSum.manifest
      counts_before = $hierSum.counts_before
      counts_after = $hierSum.counts_after
      compression = $hierSum.compression
      final_entry = $hierSum.final_entry
      checkpoints_file = [string]$hierSum.checkpoints_file
    }
    # Compteurs racine : chaque sous-appel a deja ete ajoute a
    # $script:llmEntries par Invoke-Pass2B2FCallAndValidate (7 entrees max).
    $llmCallsLog += [int]$hierSum.llm_calls
    $httpCallsLog += [int]$hierSum.http_calls
    if (-not [bool]$hierSum.ok) {
      throw ('[cr_refere_preventif] LOT ' + $hierLotStr + ' : consolidation hierarchique en echec (status=' + [string]$hierSum.status + ') - voir ' + [string]$hierSum.manifest)
    }
  } elseif ($pass2b2fConsolidateMode) {
    # ---------------------------------------------------------------------
    # LOT 2B2F-8 : consolidation finale interne Pass2B_2F.
    # Entree = refere_global_meeting.json exhaustif (merge deterministe des
    # 36 sous-appels 2B2F-7), JAMAIS de rang 1, JAMAIS une sortie d'une autre
    # passe de rang 2. Dry-run par defaut ; un seul appel LLM uniquement si
    # -Pass2B2FConsolidateLlm est fourni et si le budget est compatible.
    # ---------------------------------------------------------------------
    if ($Pass2B2FConsolidateLlm -and $DryRun) {
      throw '[cr_refere_preventif] LOT 2B2F-8 : -Pass2B2FConsolidateLlm et -DryRun sont mutuellement exclus.'
    }
    if ($Pass2B2FExecute -or $Pass2B2FRunComplete) {
      throw '[cr_refere_preventif] LOT 2B2F-8 : -Pass2B2FConsolidateFinal est incompatible avec -Pass2B2FExecute / -Pass2B2FRunComplete.'
    }
    if ($ExecuteLlm) {
      throw '[cr_refere_preventif] LOT 2B2F-8 : ne pas utiliser -ExecuteLlm (pilote Pass2F) avec la consolidation Pass2B_2F.'
    }
    Write-CrInfo ('Pass2B_2F LOT 2B2F-8 : mode consolidation finale (dry_run=' + (-not [bool]$Pass2B2FConsolidateLlm) + ')')
    $consolRes = Invoke-Pass2B2FConsolidateFinal -OutDir $OutDirMain -ExhaustiveJsonPath $Pass2B2FExhaustiveJsonPath -ModelAlias $ModelPass2B2F -StartedAt $StartedAtMain -ApiBaseOverride $ApiBase -ApiKeyOverride $ApiKey -LotLabel $Pass2B2FLotLabel -ConsolidateLlm:$Pass2B2FConsolidateLlm
    $consolSum = $consolRes.summary
    $pass2b2fSummary = $consolSum
    $totals['pass2b2f'] = @{
      dry_run = (-not [bool]$Pass2B2FConsolidateLlm)
      consolidation_final = $true
      lot = [string]$consolSum.lot
      llm_calls = [int]$consolSum.llm_calls
      http_calls = [int]$consolSum.http_calls
      alias = $ModelPass2B2F
      status = [string]$consolSum.status
      ok = [bool]$consolSum.ok
      mode = [string]$consolSum.mode
      exhaustive_source = [string]$consolSum.exhaustive_source
      exhaustive_path = [string]$consolSum.exhaustive_path
      canonical_output = [string]$consolSum.canonical_output
      manifest = [string]$consolSum.manifest
      budget = $consolSum.budget
      counts_before = $consolSum.counts_before
      counts_after = $consolSum.counts_after
      compression = $consolSum.compression
      checks = $consolSum.checks
      llm_entry = $consolSum.llm_entry
    }
    # --- Propagation trace vers le manifest racine (LOT 2B2F-9) ------------
    # L'appel de consolidation est un appel HTTP reel : il doit remonter dans
    # les compteurs et la liste llm_entries du manifest racine du job.
    $llmCallsLog += [int]$consolSum.llm_calls
    $httpCallsLog += [int]$consolSum.http_calls
    if ($null -ne $consolSum.llm_entry) {
      $trEntry = $consolSum.llm_entry
      $trEntry['status'] = [string]$consolSum.status
      $trEntry['alias'] = [string]$ModelPass2B2F
      [void]$script:llmEntries.Add($trEntry)
    }
    if (-not [bool]$consolSum.ok) {
      throw ('[cr_refere_preventif] LOT ' + [string]$Pass2B2FLotLabel + ' : consolidation en echec (status=' + [string]$consolSum.status + ') - voir ' + [string]$consolSum.manifest)
    }
  } elseif ($BuildPass2B2F) {
    if ($pass2b2fExecuteMode) {
      if ($DryRun) {
        throw '[cr_refere_preventif] LOT 2B2F-3/2B2F-6 : -Pass2B2FExecute et -DryRun sont mutuellement exclus.'
      }
      if ($ExecuteLlm) {
        throw '[cr_refere_preventif] LOT 2B2F-3/2B2F-6 : utiliser -Pass2B2FExecute seul (sans -ExecuteLlm qui pilote Pass2F).'
      }
    } else {
      if ($ExecuteLlm) {
        throw '[cr_refere_preventif] LOT 2B2F-1 : Pass2B_2F et -ExecuteLlm sont incompatibles (aucun appel LLM Pass2B_2F sans accord explicite).'
      }
      if (-not $DryRun) {
        throw '[cr_refere_preventif] LOT 2B2F-1 : Pass2B_2F autorise uniquement en mode -DryRun dans ce lot.'
      }
    }
    $segDir2B2F = $GeneralistSegmentsDir
    if (-not $segDir2B2F) { $segDir2B2F = Resolve-GeneralistSegmentsDir -CompteRenduDir $PathsMain.CompteRenduDir }
    if (-not $segDir2B2F) {
      throw '[cr_refere_preventif] Pass2B_2F : segments du CR generaliste introuvables (fournir -GeneralistSegmentsDir ou verifier le run compte_rendu_LLM).'
    }
    $segDir2B2F = [System.IO.Path]::GetFullPath($segDir2B2F)
    Write-CrInfo ('Pass2B_2F DryRun : segments_dir=' + $segDir2B2F)
    $p2b2f = Invoke-Pass2B2FDryRun -Ctx $CtxMain -SegmentsDir $segDir2B2F -OutDir $OutDirMain -ModelAlias $ModelPass2B2F -ExpectedAffected $photosAffectees -ExpectedExcluded $photosExclues -StartedAt $StartedAtMain -MaxBatchChars $Pass2B2FMaxBatchChars -MaxBatchTokens $Pass2B2FMaxBatchTokens
    $pass2b2fSummary = $p2b2f.summary
    $msg2 = ('Pass2B_2F DryRun : segments=' + [int]$pass2b2fSummary.general_segments_count + ' photos=' + [int]$pass2b2fSummary.photo_units_count + ' sujets_avec_photos=' + [int]$pass2b2fSummary.subjects_with_photos_count + ' photos_hors_segments=' + [int]$pass2b2fSummary.photos_hors_segments + ' exclues_ignorees=' + [int]$pass2b2fSummary.excluded_skipped + ' batches=' + [int]$pass2b2fSummary.batches_count + ' ok=' + [bool]$pass2b2fSummary.ok)
    Write-CrInfo $msg2
    Add-CrLogLine $msg2
    Write-CrInfo ('Pass2B_2F manifest : ' + [string]$pass2b2fSummary.manifest)
    if ($pass2b2fExecuteMode) {
      if ($Pass2B2FRunComplete) {
        $rcLotStr = $Pass2B2FLotLabel
        if (-not $rcLotStr) { $rcLotStr = '2B2F-7' }
        $selAll = ([string]$Pass2B2FSelectBatches).Trim()
        if ($selAll -and ($selAll -ne 'ALL')) {
          throw '[cr_refere_preventif] -Pass2B2FRunComplete exige -Pass2B2FSelectBatches ALL (ou vide).'
        }
        Write-CrInfo ('Pass2B_2F LOT ' + $rcLotStr + ' : run complet, limite=' + $Pass2B2FMaxBatchChars + 'car/' + $Pass2B2FMaxBatchTokens + 'tok alias=' + $ModelPass2B2F)
        $rcRes = Invoke-Pass2B2FRunCompleteBatches -Material $p2b2f.material -Pack $p2b2f.pack -OutDir $OutDirMain -ModelAlias $ModelPass2B2F -StartedAt $StartedAtMain -MaxBatchChars $Pass2B2FMaxBatchChars -MaxBatchTokens $Pass2B2FMaxBatchTokens -ApiBaseOverride $ApiBase -ApiKeyOverride $ApiKey -LotLabel $rcLotStr
        $pass2b2fExecSummary = $rcRes.summary
        $totals['pass2b2f'] = @{
          dry_run = $false
          run_complete = $true
          llm_calls = [int]$pass2b2fExecSummary.calls
          http_calls = [int]$pass2b2fExecSummary.calls
          alias = $ModelPass2B2F
          status = $(if ([bool]$pass2b2fExecSummary.ok) { 'run_complete_all_batches_ok' } else { 'run_complete_with_errors' })
          ok = [bool]$pass2b2fExecSummary.ok
          entries_count = [int]$pass2b2fExecSummary.entries_count
          ok_entries = [int]$pass2b2fExecSummary.ok_entries
          manifest = [string]$pass2b2fExecSummary.manifest
          merge = $pass2b2fExecSummary.merge
          refere_global_meeting_path = [string]$pass2b2fExecSummary.refere_global_meeting_path
          trace_file = [string]$pass2b2fExecSummary.trace_file
          general_segments_count = [int]$pass2b2fSummary.general_segments_count
          photo_units_count = [int]$pass2b2fSummary.photo_units_count
          photos_hors_segments = [int]$pass2b2fSummary.photos_hors_segments
          photo_units_with_segment = [int]$pass2b2fSummary.photo_units_with_segment
          photo_units_in_asr_gap = [int]$pass2b2fSummary.photo_units_in_asr_gap
          photo_units_after_asr = [int]$pass2b2fSummary.photo_units_after_asr
          photo_units_before_asr = [int]$pass2b2fSummary.photo_units_before_asr
          excluded_skipped = [int]$pass2b2fSummary.excluded_skipped
          batches_count = [int]$pass2b2fSummary.batches_count
        }
        if (-not [bool]$pass2b2fExecSummary.ok) {
          throw ('[cr_refere_preventif] LOT ' + $rcLotStr + ' : run complet invalide (au moins un batch en echec) - voir ' + [string]$pass2b2fExecSummary.manifest)
        }
      } else {
      $selStr = $Pass2B2FSelectBatches
      if (-not $selStr) { $selStr = '9,25,10' }
      $lotStr = $Pass2B2FLotLabel
      if (-not $lotStr) { $lotStr = '2B2F-6' }
      $cmapStr = $Pass2B2FCandidateMap
      if (-not $cmapStr) { $cmapStr = 'A=9,B=25,C=10' }
      Write-CrInfo ('Pass2B_2F LOT ' + $lotStr + ' : test reel restreint, selection=[' + $selStr + '] profils=[' + $cmapStr + '] limite=' + $Pass2B2FMaxBatchChars + 'car/' + $Pass2B2FMaxBatchTokens + 'tok alias=' + $ModelPass2B2F)
      $execRes = Invoke-Pass2B2FExecuteBatches -Material $p2b2f.material -Pack $p2b2f.pack -OutDir $OutDirMain -ModelAlias $ModelPass2B2F -SelectBatches $selStr -MaxBatchChars $Pass2B2FMaxBatchChars -MaxBatchTokens $Pass2B2FMaxBatchTokens -StartedAt $StartedAtMain -ApiBaseOverride $ApiBase -ApiKeyOverride $ApiKey -LotLabel $lotStr -CandidateMap $cmapStr
      $pass2b2fExecSummary = $execRes.summary
      $totals['pass2b2f'] = @{
        dry_run = $false
        llm_calls = [int]$pass2b2fExecSummary.calls
        http_calls = [int]$pass2b2fExecSummary.calls
        alias = $ModelPass2B2F
        status = $(if ([bool]$pass2b2fExecSummary.ok) { 'executed_3_batches_ok' } else { 'executed_with_errors' })
        ok = [bool]$pass2b2fExecSummary.ok
        entries_count = [int]$pass2b2fExecSummary.entries_count
        ok_entries = [int]$pass2b2fExecSummary.ok_entries
        manifest = [string]$pass2b2fExecSummary.manifest
        merge_test = $pass2b2fExecSummary.merge_test
        trace_file = [string]$pass2b2fExecSummary.trace_file
        general_segments_count = [int]$pass2b2fSummary.general_segments_count
        photo_units_count = [int]$pass2b2fSummary.photo_units_count
        photos_hors_segments = [int]$pass2b2fSummary.photos_hors_segments
        photo_units_with_segment = [int]$pass2b2fSummary.photo_units_with_segment
        photo_units_in_asr_gap = [int]$pass2b2fSummary.photo_units_in_asr_gap
        photo_units_after_asr = [int]$pass2b2fSummary.photo_units_after_asr
        photo_units_before_asr = [int]$pass2b2fSummary.photo_units_before_asr
        excluded_skipped = [int]$pass2b2fSummary.excluded_skipped
        batches_count = [int]$pass2b2fSummary.batches_count
      }
      if (-not [bool]$pass2b2fExecSummary.ok) {
        throw ('[cr_refere_preventif] LOT ' + $lotStr + ' : au moins un des 3 appels a echoue - voir ' + [string]$pass2b2fExecSummary.manifest)
      }
      }
    } else {
      $totals['pass2b2f'] = @{
        dry_run = $true
        llm_calls = 0
        http_calls = 0
        alias = [string]$pass2b2fSummary.alias
        status = 'planned_dryrun_only_no_llm'
        ok = [bool]$pass2b2fSummary.ok
        general_segments_count = [int]$pass2b2fSummary.general_segments_count
        photo_units_count = [int]$pass2b2fSummary.photo_units_count
        subjects_with_photos_count = [int]$pass2b2fSummary.subjects_with_photos_count
        photos_hors_segments = [int]$pass2b2fSummary.photos_hors_segments
        photo_units_with_segment = [int]$pass2b2fSummary.photo_units_with_segment
        photo_units_in_asr_gap = [int]$pass2b2fSummary.photo_units_in_asr_gap
        photo_units_after_asr = [int]$pass2b2fSummary.photo_units_after_asr
        photo_units_before_asr = [int]$pass2b2fSummary.photo_units_before_asr
        asr_start_sec = [double]$pass2b2fSummary.asr_start_sec
        asr_end_sec = [double]$pass2b2fSummary.asr_end_sec
        excluded_skipped = [int]$pass2b2fSummary.excluded_skipped
        photo_text_chars = [int]$pass2b2fSummary.photo_text_chars
        photo_asr_text_chars = [int]$pass2b2fSummary.photo_asr_text_chars
        total_input_units = [int]$pass2b2fSummary.total_input_units
        batches_count = [int]$pass2b2fSummary.batches_count
        oversized = @($pass2b2fSummary.oversized)
        checks = $pass2b2fSummary.checks
        manifest = [string]$pass2b2fSummary.manifest
      }
    }
  }

  # =========================================================================
  if ($Pass3RefereResumeExecute -or $Pass3RefereResumePlanOnly) {
    if ($Pass3RefereResumeExecute -and $DryRun) {
      throw '[cr_refere_preventif] LOT 3R-1D : -Pass3RefereResumeExecute et -DryRun sont mutuellement exclus.'
    }
    if ($Pass3Refere -or $BuildPass2B2F -or $Pass2B2FExecute -or $Pass2B2FConsolidateFinal -or $Pass2B2FConsolidateHierarchical -or $Pass2B2FRunComplete -or $ExecuteLlm) {
      throw '[cr_refere_preventif] LOT 3R-1D : -Pass3RefereResume* est incompatible avec les autres modes (Pass2B_2F / ExecuteLlm / Pass3Refere).'
    }
    $rPlan = [bool]$Pass3RefereResumePlanOnly
    $rReqPath = [string]$Pass3RefereResumeRequestJson
    if (-not $rReqPath) { throw '[cr_refere_preventif] LOT 3R-1D : -Pass3RefereResumeRequestJson requis (voir run_3r1d_resume_nas.sh).' }
    $rLot = [string]$Pass3RefereLotLabel
    if (-not $rLot) { $rLot = '3R-1D' }
    Write-CrInfo ('Pass3 refere RESUME LOT ' + $rLot + ' : mode=' + $(if ($rPlan) { 'PLAN-ONLY (aucun appel)' } else { 'EXECUTE (D puis E, max 2 appels)' }) + ' request=' + $rReqPath)
    $resumeRes = Invoke-Pass3RefereResume -OutDirMain $OutDirMain -RequestJsonPath $rReqPath -Exec:(-not $rPlan) -ApiBase $ApiBase -ApiKey $ApiKey -LotLabel $rLot -OutSubdir $Pass3RefereOutSubdir
    $resumeSum = $resumeRes.summary
    $totals['pass3refere_resume'] = @{
      lot = $rLot
      plan_only = $rPlan
      llm_calls = [int]$resumeRes.llm_calls
      http_calls = [int]$resumeRes.http_calls
      status = [string]$resumeSum.status
      ok = [bool]$resumeRes.ok
      out_root = [string]$resumeSum.out_root
      request_json = $rReqPath
      reused_outputs = @($resumeRes.reused)
      rows = @($resumeRes.rows)
      artifacts = @($resumeRes.artifacts)
    }
    if ($rPlan) {
      $planOut = [ordered]@{
        lot = $rLot
        plan_only = $true
        result = $(if ([bool]$resumeRes.ok) { 'PLAN_OK' } else { 'PLAN_FAILED' })
        status = [string]$resumeSum.status
        fits_d = $null
        fits_e = $null
        rows = @($resumeRes.rows)
        reused_count = @($resumeRes.reused).Count
      }
      if ($null -ne $resumeRes.d_diag) { $planOut['fits_d'] = [bool]$resumeRes.d_diag.fits }
      if ($null -ne $resumeRes.e_diag) { $planOut['fits_e'] = [bool]$resumeRes.e_diag.fits }
      $planFile = Join-Path $OutDirMain 'pass3r1d_plan.json'
      Write-CrJsonAtomic -Path $planFile -Obj $planOut
      Add-CrOutputFile $planFile
      Write-CrInfo ('Resume PLAN : ' + $planFile + ' fits_d=' + $(if ($null -ne $resumeRes.d_diag) { [bool]$resumeRes.d_diag.fits } else { 'N/A' }) + ' fits_e=' + $(if ($null -ne $resumeRes.e_diag) { [bool]$resumeRes.e_diag.fits } else { 'N/A' }))
      if (-not [bool]$resumeRes.ok) {
        throw ('[cr_refere_preventif] LOT 3R-1D : plan resume en echec (status=' + [string]$resumeSum.status + ') - aucun appel.')
      }
    } else {
      $llmCallsLog += [int]$resumeRes.llm_calls
      $httpCallsLog += [int]$resumeRes.http_calls
      $sumOut = [ordered]@{
        lot = $rLot
        result = $(if ([bool]$resumeRes.ok) { 'OK' } else { 'FAILED' })
        status = [string]$resumeSum.status
        llm_calls = [int]$resumeRes.llm_calls
        http_calls = [int]$resumeRes.http_calls
        out_root = [string]$resumeSum.out_root
        request_json = $rReqPath
        reused_outputs = @($resumeRes.reused)
        rows = @($resumeRes.rows)
        d_entry = $resumeRes.d_entry
        e_entry = $resumeRes.e_entry
        artifacts = @($resumeRes.artifacts)
      }
      $sumFile = Join-Path $OutDirMain 'pass3r1d_summary.json'
      Write-CrJsonAtomic -Path $sumFile -Obj $sumOut
      Add-CrOutputFile $sumFile
      Write-CrInfo ('Resume EXEC : ' + $sumFile + ' llm_calls=' + [int]$resumeRes.llm_calls + ' http_calls=' + [int]$resumeRes.http_calls)
      if (-not [bool]$resumeRes.ok) {
        throw ('[cr_refere_preventif] LOT 3R-1D : resume en echec (status=' + [string]$resumeSum.status + ') - aucun retry, STOP.')
      }
    }
  }


  # LOT 3R-1B : Pass3 refere (Pass3A/B/C/D_refere + Pass3E_refere)
  # Source globale : refere_global_meeting.json (consolidation 6G 2B2F-12).
  # Aucune injection directe des chunks Pass2F dans 3A-D. Test reel restreint
  # autorise : 4 appels globaux + 1 appel Pass3E (sujet representatif).
  # =========================================================================
  if ($Pass3Refere) {
    if ($Pass3RefereExecute -and $DryRun) {
      throw '[cr_refere_preventif] LOT 3R-1B : -Pass3RefereExecute et -DryRun sont mutuellement exclus.'
    }
    if ($BuildPass2B2F -or $Pass2B2FExecute -or $Pass2B2FConsolidateFinal -or $Pass2B2FConsolidateHierarchical -or $Pass2B2FRunComplete -or $ExecuteLlm) {
      throw '[cr_refere_preventif] LOT 3R-1B : -Pass3Refere est incompatible avec les autres modes (Pass2B_2F / ExecuteLlm).'
    }
    $pass3GlobalPath = [string]$Pass3RefereGlobalJsonPath
    if (-not $pass3GlobalPath) {
      $pass3GlobalPath = '/data/jobs/pass2b2f12_j48_hierarchy/pass2b2f/refere_global_meeting.json'
    }
    $pass3Exec = [bool]$Pass3RefereExecute
    Write-CrInfo ('Pass3 refere LOT ' + [string]$Pass3RefereLotLabel + ' : mode=' + $(if ($pass3Exec) { 'EXECUTE (max 5 appels)' } else { 'DRY-RUN (aucun appel)' }) + ' global=' + $pass3GlobalPath)
    $pass3Res = Invoke-Pass3Refere -Ctx $CtxMain -OutDirMain $OutDirMain -GlobalJsonPath $pass3GlobalPath -ContextJsonPath $Pass3RefereContextJsonPath -Pass2EDir $Pass3ReferePass2EDir -Pass2FOutDir $Pass3ReferePass2FOutDir -EChunkPaths @($Pass3RefereEChunkPaths) -ESujetCompactPath $Pass3RefereESujetCompactPath -ESubject $Pass3RefereESubject -Exec $pass3Exec -ApiBase $ApiBase -ApiKey $ApiKey -LotLabel $Pass3RefereLotLabel -OutSubdir $Pass3RefereOutSubdir
    $pass3Sum = $pass3Res.summary
    $totals['pass3refere'] = @{
      lot = [string]$Pass3RefereLotLabel
      dry_run = (-not $pass3Exec)
      llm_calls = [int]$pass3Res.llm_calls
      http_calls = [int]$pass3Res.http_calls
      aliases = 'pass3a_remote,pass3b_remote,pass3c_remote,pass3d_remote,pass3e_remote'
      status = [string]$pass3Sum.status
      ok = [bool]$pass3Res.ok
      global_json = $pass3GlobalPath
      out_root = [string]$pass3Sum.out_root
      rows = @($pass3Res.rows)
      artifacts = @($pass3Res.artifacts)
    }
    $llmCallsLog += [int]$pass3Res.llm_calls
    $httpCallsLog += [int]$pass3Res.http_calls
    if (-not [bool]$pass3Res.ok) {
      throw ('[cr_refere_preventif] LOT ' + [string]$Pass3RefereLotLabel + ' : Pass3 refere en echec (status=' + [string]$pass3Sum.status + ') - aucun retry.')
    }
  }

  # --- Manifest final ---
  $manifestLot = '2F-6C2B'
  if ($ExecuteLlm) { $manifestLot = '2F-6C2C' }
  if ($BuildPass2B2F -and ($Pass2B2FConsolidateFinal -or $Pass2B2FConsolidateHierarchical) -and $Pass2B2FLotLabel) { $manifestLot = [string]$Pass2B2FLotLabel }
    if (($Pass3Refere -or $Pass3RefereResumeExecute -or $Pass3RefereResumePlanOnly) -and $Pass3RefereLotLabel) { $manifestLot = [string]$Pass3RefereLotLabel }
  $manifestFile = Write-CrManifestJson -Ctx $CtxMain -Perimeter @{
    photos_total=@($CtxMain.photos).Count
    photos_affectees=$photosAffectees
    photos_exclues=$photosExclues
    photos_sans_affectation=$photosSansAffectation
    sujets_avec_photos=$sujetsAvecPhotos
  } -PerSubject @($perSubject) -Totals $totals -OutDir $OutDirMain -StartedAt $StartedAtMain -ExitCode 0 -Success $true -LotLabel $manifestLot -LlmCalls $llmCallsLog -HttpCalls $httpCallsLog -LlmCallEntries @($script:llmEntries) -ModelInfoProbe $modelInfoProbeResult
  Add-CrLogLine ('manifest written: ' + $manifestFile)
  Write-CrInfo ($(if ($ExecuteLlm) { 'ExecuteLlm termine (lot 2F-6C2C)' } else { 'DryRun termine' }) + ' : unites=' + $totUnits + ' chunks=' + $totChunks + ' enforce_required=' + $totEnforce + ' llm_calls=' + $llmCallsLog + ' http_calls=' + $httpCallsLog)
  Write-CrInfo ('manifest: ' + $manifestFile)

  $SuccessMain = $true
  $ExitCodeMain = 0
}
catch {
  $err = $_.Exception.Message
  $errStack = $_.ScriptStackTrace
  Write-CrErr ('ECHEC: ' + $err)
  try { Write-CrErr ('STACK: ' + $errStack) } catch { }
  try {
    Add-CrLogLine ('ERROR: ' + $err)
    Add-CrLogLine ('STACK: ' + $errStack)
    $errLlm = 0; try { $errLlm = [int]$llmCallsLog } catch { }
    $errHttp = 0; try { $errHttp = [int]$httpCallsLog } catch { }
    # LOT 3R-1C : sur le chemin d'echec Pass3Refere, Invoke-Pass3Refere throw avant
    # l'incrementation de $llmCallsLog/$httpCallsLog (ligne += post-appel, jamais atteinte).
    # Les appels reels sont deja traces dans $script:llmEntries (http_status>0) : on les
    # rederive pour que le manifest racine porte les compteurs exacts (lot + status deja propages).
    if (($Pass3Refere -and $Pass3RefereExecute) -or $Pass3RefereResumeExecute) {
      $p3ErrCounts = Get-P3ErrorCountsFromEntries -Entries @($script:llmEntries)
      $errLlm = [Math]::Max($errLlm, [int]$p3ErrCounts.llm_calls)
      $errHttp = [Math]::Max($errHttp, [int]$p3ErrCounts.http_calls)
    }
    # REFERE-E2E-2 : sur le chemin d'echec du mode production, l'orchestrateur
    # alimente $script:RefereProgress a chaque appel termine (Pass2F/2B2F/6G/3A-E,
    # renderer). Les compteurs derives ne dependent pas des lignes += posterieures
    # au point de throw.
    if ($RunReferePipeline -or $RunReferePipelinePlanOnly) {
      # L'orchestrateur alimente $script:RefereProgress au moment de chaque
      # dispatch LLM/HTTP (Pass2F, 2B2F batches, 6G, 3A-E, renderer). Derivation
      # supplementaire depuis les llm_entries reelles (http_status>0) pour les
      # appels Pass3 qui throw dans Invoke-P3Remote apres trace de l'entree.
      if ($null -ne $script:RefereProgress) {
        $errLlm = [Math]::Max($errLlm, [int]$script:RefereProgress.llm_calls)
        $errHttp = [Math]::Max($errHttp, [int]$script:RefereProgress.http_calls)
      }
      $prodErrCounts = Get-P3ErrorCountsFromEntries -Entries @($script:llmEntries)
      $errLlm = [Math]::Max($errLlm, [int]$prodErrCounts.llm_calls)
      $errHttp = [Math]::Max($errHttp, [int]$prodErrCounts.http_calls)
    }
    $errEntries = @(); if ($null -eq $script:llmEntries) { $errEntries = @() } else { $errEntries = @($script:llmEntries) }
    $errLotL = '2F-6C2B'
    if ($ExecuteLlm) { $errLotL = '2F-6C2C' }
    if ($BuildPass2B2F -and ($Pass2B2FConsolidateFinal -or $Pass2B2FConsolidateHierarchical) -and $Pass2B2FLotLabel) { $errLotL = [string]$Pass2B2FLotLabel }
    if (($Pass3Refere -or $Pass3RefereResumeExecute -or $Pass3RefereResumePlanOnly) -and $Pass3RefereLotLabel) { $errLotL = [string]$Pass3RefereLotLabel }
    if (($RunReferePipeline -or $RunReferePipelinePlanOnly) -and $RefereLotLabel) { $errLotL = [string]$RefereLotLabel }
    $errExtra = $null; try { $errExtra = @{ totals = $totals } } catch { }
    Write-CrErrorManifest -OutDir $OutDirMain -StartedAt $StartedAtMain -ErrorMessage $err -LotLabel $errLotL -LlmCalls $errLlm -HttpCalls $errHttp -LlmCallEntries @($errEntries) -Extra $errExtra
  } catch { }
  $ExitCodeMain = 1
  $SuccessMain = $false
}

Write-CrInfo ('exit_code=' + $ExitCodeMain + ' status=' + $(if ($SuccessMain) { 'OK' } else { 'FAILED' }))
exit $ExitCodeMain
