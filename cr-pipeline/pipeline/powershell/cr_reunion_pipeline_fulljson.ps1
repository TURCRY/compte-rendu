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
  [Parameter(Mandatory=$false)]
  [string] $ContextJsonPath = "",

  # LLM provider & modèle
  [ValidateSet("openai","ollama")] [string] $Provider = "openai",
  [string] $ApiBase    = "http://openai-adapter:5055",  # OpenAI-compat: /v1/chat/completions
  [string] $OllamaBase = "http://localhost:11434",      # Ollama natif: /api/generate

  # Modèle "par défaut" (optionnel, compat)
  [string] $Model      = "annoter_segments_local",

  # Modèles par passe
  [string] $ModelPass1 = "annoter_segments_local",   # Passe 1 : segments → LOCAL
  [string] $ModelPass2 = "annoter_segments_remote",  # Passe 2 : fusion → REMOTE
  [string] $ModelPass3 = "annoter_segments_remote",  # Passe 3 : JSON final → REMOTE

  [string] $ApiKey     = "",

  # Segmentation : preset + debug
  [ValidateSet("conservateur","equilibre","agressif")] [string] $Preset = "equilibre",
  [switch] $DebugSeg,
  
  # Paramétrage Passe 2 (agrégation hiérarchique)
  [int] $Pass2BatchSize = 2,

  # Relance
  [switch] $Force

)
[int]$ChunkSize = 30 # voir fonction Get-IntelligentSegments (nombre de ligne de transcription par segment

# Valeurs neutres pour éviter l’erreur en StrictMode
$logsDir = $null
$logFile = $null

# Ajustement intelligent de Pass2BatchSize si l'utilisateur ne l'a pas fixé
if (-not $PSBoundParameters.ContainsKey('Pass2BatchSize')) {

    # Cas remote : on profite du gros contexte
    if ($Provider -ieq "openai" -and $ModelPass2 -eq "annoter_segments_remote") {
        $Pass2BatchSize = 6   # par exemple (à ajuster après essais : 4, 6, 8…)
    }
    else {
        # Cas local ou autre modèle : valeur conservatrice
        $Pass2BatchSize = 2
    }
}

Write-Host "==== PARAMS PIPELINE ====" -ForegroundColor Cyan
Write-Host ("Provider       = {0}" -f $Provider)
Write-Host ("ApiBase        = {0}" -f $ApiBase)
Write-Host ("Model          = {0}" -f $Model)
Write-Host ("ModelPass1     = {0}" -f $ModelPass1)
Write-Host ("ModelPass2     = {0}" -f $ModelPass2)
Write-Host ("ModelPass3     = {0}" -f $ModelPass3)
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
    if($LogFile){
      "CTX OK $Label : approx=$tokTotal, available=$available" | Add-Content $LogFile
    }
    return $UserPrompt
  }


  $maxUserTokens = $available - $tokSys
  if($maxUserTokens -le 0){

    Write-Warn ("{0}: contexte insuffisant (tokSys={1}, available={2}), user vidé." -f $Label,$tokSys,$available)

    if($LogFile){
      "WARN: $Label → prompt tronqué à 0 token (tokSys=$tokSys, available=$available, n_ctx=$nCtx, max_tokens=$maxTok)" | Add-Content $LogFile
    }

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
  if($LogFile){
    "WARN: $Label → prompt tronqué (total≈$tokTotal, après≈$tokTotalNew, available=$available, n_ctx=$nCtx, max_tokens=$maxTok)" | Add-Content $LogFile
  }
  return $truncated
}

# Budget de contexte par modèle (local vs remote)
function Get-ContextBudget {
    param(
        [string] $ModelName
    )

    switch ($ModelName) {
        "annoter_segments_remote" {
            return [pscustomobject]@{
                NCtx   = 120000
                MaxTok = 4000
                Margin = 2000
            }
        }
        "annoter_segments_remote_alt" {
            return [pscustomobject]@{
                NCtx   = 120000
                MaxTok = 4000
                Margin = 2000
            }
        }
        "annoter_segments_remote_alt2" {
            return [pscustomobject]@{
                NCtx   = 120000
                MaxTok = 4000
                Margin = 2000
            }
        }
        default {
            return [pscustomobject]@{
                NCtx   = 4096
                MaxTok = 1024
                Margin = 128
            }
        }
    }
}
# insertion du contexte général du dossier
$GlobalContext = $null
$ContextMission = ""
$ContextSystem  = ""
$ContextUser    = ""
$ContextEtatAvancement = ""

if ($ContextJsonPath -and (Test-Path $ContextJsonPath)) {
    try {
        $GlobalContext = Get-Content $ContextJsonPath -Raw | ConvertFrom-Json
        $ContextMission = $GlobalContext.mission
        $ContextSystem  = $GlobalContext.system
        $ContextUser    = $GlobalContext.user
        $ContextEtatAvancement = $GlobalContext.etat_avancement

    }
    catch {
        Write-Warning "Impossible de lire le contexte général : $ContextJsonPath - $_"
    }
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
function Invoke-LLM-OpenAICompat {
  param(
    [string] $system,
    [string] $user,
    [string] $model
  )

  $uri = ($ApiBase.TrimEnd('/')) + "/v1/chat/completions"
  $headers=@{}
  if($ApiKey){
    $headers["Authorization"]="Bearer $ApiKey"
  }

  $body = @{
    model       = $model
    temperature = 0.2
    messages    = @(
      @{ role="system"; content=$system },
      @{ role="user";   content=$user   }
    )
  } | ConvertTo-Json -Depth 10

  $maxRetries = 3
  for($attempt = 1; $attempt -le $maxRetries; $attempt++){

    try {
      Write-Host ("[LLM] POST {0} (attempt {1}/{2})" -f $uri, $attempt, $maxRetries) -ForegroundColor Cyan
      $resp = Invoke-RestMethod -Method POST -Uri $uri -Headers $headers -Body $body -ContentType "application/json"
      return $resp.choices[0].message.content
    }
    catch {
      $msg = $_.Exception.Message
      Write-Warn ("Invoke-LLM-OpenAICompat: erreur HTTP (tentative {0}/{1}) : {2}" -f $attempt,$maxRetries,$msg)

      # Si la réponse JSON contient "502 Bad Gateway" ou similaire, on retente
      $detail = $null
      try {
        $errBody = $_.ErrorDetails.Message
        if($errBody){
          $errObj = $errBody | ConvertFrom-Json -ErrorAction SilentlyContinue
          $detail = $errObj.detail
        }
      } catch {}

      if($attempt -lt $maxRetries -and ($detail -like "*502 Bad Gateway*" -or $msg -like "*502*")){
        Start-Sleep -Seconds 3
        continue
      }

      # Sinon, on remonte l'erreur
      throw
    }
  }
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
    [string] $model
  )

  if($Provider -ieq "openai"){
    return Invoke-LLM-OpenAICompat -system $system -user $user -model $model
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
                if($LogFile){
                  "Parse-LlmJsonStrict($Label) OK (string JSON → objet)" | Add-Content $LogFile
                }
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
        if($LogFile){
          "Parse-LlmJsonStrict($Label) OK (direct)" | Add-Content $LogFile
        }
        return $obj
    }
    catch {
        if($LogFile){
          "Parse-LlmJsonStrict($Label) ÉCHEC direct. Début candidat: '$($candidate.Substring(0,[Math]::Min(80,$candidate.Length)))'" | Add-Content $LogFile
        }
    }

    # PASS 2 : suppression des virgules finales avant } ou ]
    $candidate2 = $candidate -replace ',\s*(\}|\])','$1'
    try {
        $obj = _TryConvert $candidate2 "sans virgules terminales"
        if($LogFile){
          "Parse-LlmJsonStrict($Label) OK (virgules terminales corrigées)" | Add-Content $LogFile
        }
        return $obj
    }
    catch {
        if($LogFile){
          "Parse-LlmJsonStrict($Label) ÉCHEC pass2. Début candidat2: '$($candidate2.Substring(0,[Math]::Min(80,$candidate2.Length)))'" | Add-Content $LogFile
        }
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
        if($LogFile){
          "Parse-LlmJsonStrict($Label) OK (quotes/backslashes)" | Add-Content $LogFile
        }
        return $obj
    }
    catch {
        if($LogFile){
          "Parse-LlmJsonStrict($Label) ÉCHEC pass3. Début candidat3: '$($candidate3.Substring(0,[Math]::Min(80,$candidate3.Length)))'" | Add-Content $LogFile
        }
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



# ── Prompts JSON strict Passes 1/2/3 ──────────────────────────────────────────
# 1) On garde une version "de base" du système, avec le schéma
$BasePass1_System = @'
Tu es un assistant d'analyse de réunions. À partir d'une transcription de ~20–30 minutes,
produis une synthèse factuelle.

Retourne UNIQUEMENT du JSON strict (aucun texte hors JSON) avec ce schéma exact :
{
  "resume_segment": "string (≤5 phrases)",
  "themes": [
    { "titre": "string", "synthese": ["string", "..."], "timecodes": ["HH:MM:SS", "..."] }
  ],
  "actions": [
    { "action": "string", "responsable": "string", "echeance": "YYYY-MM-DD | null" }
  ],
  "problems": [
    { "probleme": "string", "solution": "string" }
  ]
}

Règles :
- interdiction d'inventer ;
- s'appuyer sur les timecodes et regrouper par thème ;
- ≤1000 mots au total ;
- CONSERVEZ explicitement toutes les demandes de documents ou d'informations...
'@

# 2) Si un contexte existe, on le PREPEND (ou APPEND) à cette base
if ($GlobalContext) {
    $Pass1_System = @"
$ContextSystem

Mission générale de l'analyse (à respecter strictement) :
$ContextMission

État d’avancement de la mission :
$ContextEtatAvancement

$BasePass1_System
"@
}
else {
    $Pass1_System = $BasePass1_System
}




if ($ContextUser) {
    $Pass1_User_Template=@"
Contexte général de l’affaire (ne pas réécrire, ne pas inventer d’éléments nouveaux) :
$ContextUser

Transcription segmentée (de {START_HMS} à {END_HMS}) :

{LINES}

Renvoie uniquement le JSON conforme au schéma.
"@
}
else {
  $Pass1_User_Template=@'
Transcription segmentée (de {START_HMS} à {END_HMS}) :

{LINES}

Renvoie uniquement le JSON conforme au schéma.
'@
}
# passe 2
# 1) On garde une version "de base" du système, avec le schéma
$BasePass2_System = @'
Tu es un assistant chargé de fusionner et clarifier des segments déjà annotés au format JSON.
Tu dois regrouper les informations redondantes, améliorer la cohérence et la lisibilité,
sans ajouter de nouveaux faits ni modifier le sens de ce qui est fourni.

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

# 2) Si un contexte existe, on le PREPEND (ou APPEND) à cette base
if ($GlobalContext) {
    $Pass2_System = @"
$ContextSystem

Mission générale de l'analyse (à respecter strictement) :
$ContextMission

État d’avancement de la mission :
$ContextEtatAvancement

$BasePass2_System
"@
}
else {
    $Pass2_System = $BasePass2_System
}
$Pass2_User_Template = @"
Contexte : tu continues la même mission et les mêmes limites que décrites dans le message système.

Segments annotés (JSON) à fusionner / regrouper :
{SEGMENTS_JSON_ARRAY}

Renvoie uniquement le JSON conforme au schéma.
"@

# agregation hierarchique


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

    $raw = Invoke-LLM -system $Pass2_System -user $userEffective -model $ModelPass2

    # Logs de debug (prompt effectif + réponse brute)
    $rawPath    = Join-Path $localLogsDir ("pass2_batch_" + $batchId + ".raw.txt")
    $promptPath = Join-Path $localLogsDir ("pass2_batch_" + $batchId + ".prompt_effective.txt")

    $raw          | Out-File $rawPath    -Encoding UTF8
    $userEffective| Out-File $promptPath -Encoding UTF8

    # Parsing robuste
    try {
        $obj = Parse-LlmJsonStrict -RawText $raw -Label ("Pass2 batch #" + $batchId) -LogFile $LogFile
    }
    
        
    catch {
        $errPath = Join-Path $localLogsDir ("pass2_batch_" + $batchId + ".error.txt")
        ("ERREUR Parse-LlmJsonStrict Passe 2 batch #" + $batchId + "`n`nRAW:`n" + $raw) | Out-File $errPath -Encoding UTF8

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
# 1) On garde une version "de base" du système, avec le schéma
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

# 2) Si un contexte existe, on le PREPEND (ou APPEND) à cette base
if ($GlobalContext) {
    $Pass3A_System = @"
$ContextSystem

Mission générale de l'analyse (à respecter strictement) :
$ContextMission

État d’avancement de la mission :
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
# 1) On garde une version "de base" du système, avec le schéma
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
# 2) Si un contexte existe, on le PREPEND (ou APPEND) à cette base
if ($GlobalContext) {
    $Pass3B_System = @"
$ContextSystem

Mission générale de l'analyse (à respecter strictement) :
$ContextMission

État d’avancement de la mission :
$ContextEtatAvancement

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
# 1) On garde une version "de base" du système, avec le schéma
$BasePass3C_System = @'
Tu reçois le JSON "global" d'une réunion d’expertise, déjà structuré avec :
- un "resume_global",
- des "themes",
- des "actions",
- éventuellement des "problems" ou assimilés.

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
    {
      "probleme": "string",
      "solution": "string"
    }
  ],
  "annexes": [
    "string",
    "..."
  ]
}

Définitions :
- "actions" : tâches concrètes décidées en réunion (qui fait quoi, pour faire quoi, avant quand),
  généralement déjà présentes dans le champ "actions" du JSON global ;
- "perspectives" : couples (probleme, solution) décrivant :
  - soit des "problems" avec une solution ou une piste de solution associée,
  - soit des difficultés ou enjeux futurs accompagnés d’une manière de les traiter
    (projet de travaux, étude à réaliser, arbitrage à rendre, etc.) ;
- "annexes" : liste de libellés de documents ou supports mentionnés comme pièces du dossier
  (plans, photos, rapports, diagnostics, attestations, relevés, notes, courriels, « pièce 6 », etc.).

Règles d’extraction :
- Pour "actions" :
  - partir en priorité du champ "actions" du JSON global ;
  - tu peux reprendre ces actions presque telles quelles, en complétant "commentaire"
    si le texte du JSON global contient des précisions utiles ;
- Pour "perspectives" :
  - rechercher les problèmes et pistes de solution dans :
    - le champ "problems" du JSON global s’il existe,
    - les descriptions de "themes",
    - le "resume_global",
    - et, le cas échéant, les commentaires des actions ;
  - dès qu’un problème et une solution (ou une piste de solution) sont identifiables,
    créer un objet { "probleme": "...", "solution": "..." } ;
- Pour "annexes" :
  - lister chaque type de document ou support mentionné (plans, annexes, pièces, photos, rapports, etc.),
    sous forme de chaîne courte (ex. "Plans du bâtiment", "Attestation d’assurance multirisque",
    "Pièce 6 – courrier manquant", "Photos des infiltrations").

Règles de prudence :
- pas d’invention : si une information précise n’est pas présente (date, nom d’une partie, etc.), tu ne la crées pas ;
- en cas d’information incomplète :
  - pour "actions", tu peux laisser "echeance" à null et/ou utiliser "commentaire" pour préciser la situation ;
  - pour "perspectives" et "annexes", tu reformules sobrement ce qui est dans le JSON global ;
- tu ne dois renvoyer des tableaux vides ("perspectives": [], "annexes": [])
  que si tu as vérifié qu’aucun problème avec solution ni aucun document/support n’est mentionné dans le JSON global.

Sortie :
- aucun champ supplémentaire ;
- aucune phrase hors JSON ;
- réponse STRICTEMENT au format JSON, conforme au schéma ci-dessus.
'@

# 2) Si un contexte existe, on le PREPEND (ou APPEND) à cette base
if ($GlobalContext) {
    $Pass3C_System = @"
$ContextSystem

Mission générale de l'analyse (à respecter strictement) :
$ContextMission

État d’avancement de la mission :
$ContextEtatAvancement

$BasePass3C_System
"@
}
else {
    $Pass3C_System = $BasePass3C_System
}
$Pass3C_User_Template = @"
Voici le JSON global issu de la fusion des segments :

{GLOBAL_JSON}

À partir de ce JSON global, produis UNIQUEMENT :
- le champ ""actions"" en structurant les tâches décidées (en t'appuyant en priorité sur ""actions"" du JSON global) ;
- le champ ""perspectives"" en associant les problèmes et leurs solutions ou pistes de solution,
  à partir des champs ""problems"", ""themes"" et du ""resume_global"" ;
- le champ ""annexes"" en listant les documents ou supports mentionnés (plans, pièces, photos, rapports, etc.).

Renvoie uniquement le JSON conforme au schéma indiqué dans le message système.
"@


# 3D : demandes de documents
# 1) On garde une version "de base" du système, avec le schéma
$BasePass3D_System = @'
Tu reçois le JSON "global" d'une réunion d’expertise judiciaire.

Tu dois extraire UNIQUEMENT les demandes de documents ou d’informations à fournir :
- pièces écrites (plans, attestations, rapports, diagnostics, justificatifs, relevés, courriers, etc.) ;
- informations formelles à communiquer (confirmation écrite, précision d’adresse, correction de référence, etc.).

Réponds STRICTEMENT par un JSON respectant ce schéma :

{
  "demandes_documents": [
    {
      "objet": "string",
      "demandeur": "string | null",
      "destinataire": "string | null",
      "echeance": "YYYY-MM-DD | null",
      "commentaire": "string | null"
    }
  ]
}

Règles d’identification :
- considérer comme "demande de document ou d’information" toute phrase ou action comportant des formulations
  du type : "demander", "demande de", "fournir", "transmettre", "communiquer", "envoyer", "produire",
  "remettre", "joindre", "pièce manquante".
- les demandes peuvent se trouver dans :
  - le champ "actions" (ex. "Demander la communication des plans du bâtiment…"),
  - le résumé global,
  - les thèmes (ex. "Documents, assurance et recherches complémentaires").

Règles de prudence :
- aucune invention : si une information (demandeur, destinataire, échéance) n’est pas explicitement présente,
  mettre null pour ce champ.
- MAIS si des demandes de documents existent dans le JSON (par exemple des actions commençant par "Demander...",
  "Demander la communication...", "Demander la fourniture...", "Transmettre...", etc.), tu DOIS les extraire
  dans "demandes_documents".
- Tu ne dois renvoyer "demandes_documents": [] que si tu as vérifié qu’aucune demande de document
  ou d’information n’apparaît dans le JSON global.

Aucune phrase ou texte hors JSON.
'@
# 2) Si un contexte existe, on le PREPEND (ou APPEND) à cette base
if ($GlobalContext) {
    $Pass3D_System = @"
$ContextSystem

Mission générale de l'analyse (à respecter strictement) :
$ContextMission

État d’avancement de la mission :
$ContextEtatAvancement


$BasePass3D_System
"@
}
else {
    $Pass3D_System = $BasePass3D_System
}
$Pass3D_User_Template = @'
Voici le JSON global issu de la fusion des segments :

{GLOBAL_JSON}

À partir de ce JSON global, produis uniquement le champ "demandes_documents"
selon le schéma indiqué ci-dessus.

Renvoie uniquement le JSON conforme au schéma.
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
        "Segments (ChunkSize=$ChunkSize) générés : $($segments.Count)" | Out-File $logPath -Encoding UTF8
    }

    return $segments
}


# ── Lecture CSV + segmentation ────────────────────────────────────────────────
if(!(Test-Path $CsvPath)){ throw "CSV introuvable: $CsvPath" }
Ensure-Dir $OutDir; Ensure-Dir (Join-Path $OutDir "segments"); Ensure-Dir (Join-Path $OutDir "logs")
$logsDir = Join-Path $OutDir "logs"
Ensure-Dir $logsDir
$logFile = Join-Path $logsDir ("run_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")
"Start: $(Get-Date)" | Out-File $logFile -Encoding UTF8

Write-Info "Lecture CSV: $CsvPath"

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

# Choix de ChunkSize en fonction du mode (local vs remote Passe 1)
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


# ── Passe 1 : mini-CR par segment (JSON strict) ───────────────────────────────
$segmentJsonPaths = New-Object System.Collections.Generic.List[object]
for($i=0; $i -lt $segments.Count; $i++){
  $seg = $segments[$i]
  $segOut = Join-Path $OutDir ("segments/segment_{0:D2}.json" -f ($i+1))
  $startH = Seconds-To-Hms ($seg[0].__sec)
  $endH   = Seconds-To-Hms ($seg[-1].__sec)

  if((Test-Path $segOut) -and (-not $Force)){
    $skipMsg = "Skip segment $($i+1) (existe) → $segOut"
    Write-Info $skipMsg
    $segmentJsonPaths.Add($segOut)
    continue
  }

  $infoMsg = "Passe 1 → Segment $($i+1)  [$startH → $endH]"
  Write-Info $infoMsg

  # Construction du prompt utilisateur brut
  $lines = $seg | ForEach-Object {
    "[{0}] {1}: {2}" -f $_.$colTime, $_.$colSpeaker, $_.$colText
  } | Out-String

  $userPrompt = $Pass1_User_Template.
    Replace("{START_HMS}", $startH).
    Replace("{END_HMS}",   $endH).
    Replace("{LINES}",     $lines.Trim())

  # Log du prompt brut et du system prompt
  $userPrompt   | Out-File ($segOut + ".prompt.txt")  -Encoding UTF8
  $Pass1_System | Out-File ($segOut + ".system.txt")  -Encoding UTF8

  # MODIF GPT : contrôle n_ctx / max_tokens pour ce segment
  $userPrompt_Effective = Enforce-ContextLimit `
        -SystemPrompt $Pass1_System `
        -UserPrompt   $userPrompt `
        -Label        ("segment {0:D2}" -f ($i+1)) `
        -LogFile      $logFile `
        -ModelName    $ModelPass1


  # Log éventuel du prompt effectivement envoyé
  $userPrompt_Effective | Out-File ($segOut + ".prompt_effective.txt") -Encoding UTF8

  # Appel LLM (une seule fois)
  $raw = Invoke-LLM -system $Pass1_System -user $userPrompt_Effective -model $ModelPass1

  # Log brut pour diagnostic
  $raw | Out-File ($segOut + ".raw.txt") -Encoding UTF8

  # Garde-fou : réponse vide ou {'reponse': ''}
  if (-not $raw -or $raw.Trim() -eq "" -or $raw.Trim() -eq "{'reponse': ''}") {
      Write-Warn ("Segment {0:D2} : annoter a renvoyé une réponse vide, on force un JSON minimal." -f ($i+1))

      $jsonStr = @'
{
  "resume_segment": "",
  "themes": [],
  "actions": [],
  "problems": []
}
'@

      $jsonStr | Out-File $segOut -Encoding UTF8
      $segmentJsonPaths.Add($segOut)
      ("Segment {0:D2} FORCÉ (réponse vide annoter)" -f ($i+1)) | Add-Content $logFile
      continue
  }
  # Nettoyage + parsing robuste du JSON (Pass 1)
  try {
      $obj = Parse-LlmJsonStrict -RawText $raw -Label ("segment {0:D2}" -f ($i+1)) -LogFile $logFile

      # Ici, on suppose que le modèle renvoie déjà un objet du type :
      # { "resume_segment": "...", "themes": [...], "actions": [...], "problems": [...] }
      # Si besoin, on peut forcer un schéma minimal :
      if (-not $obj.PSObject.Properties['resume_segment']) { $obj | Add-Member -NotePropertyName resume_segment -NotePropertyValue "" }
      if (-not $obj.PSObject.Properties['themes'])         { $obj | Add-Member -NotePropertyName themes         -NotePropertyValue @() }
      if (-not $obj.PSObject.Properties['actions'])        { $obj | Add-Member -NotePropertyName actions        -NotePropertyValue @() }
      if (-not $obj.PSObject.Properties['problems'])       { $obj | Add-Member -NotePropertyName problems       -NotePropertyValue @() }

      $jsonStr = $obj | ConvertTo-Json -Depth 50
  }
  catch {
      Write-Err ("JSON invalide segment {0:D2}; brut loggé (fallback minimal)" -f ($i+1))
      $raw | Out-File ($segOut + ".raw_fallback.txt") -Encoding UTF8

      $jsonStr = @'
{
  "resume_segment": "",
  "themes": [],
  "actions": [],
  "problems": []
}
'@
  }

  $jsonStr | Out-File $segOut -Encoding UTF8
  $segmentJsonPaths.Add($segOut)
  "Segment {0:D2} OK" -f ($i+1) | Add-Content $logFile
}

# ── Passe 2 : agrégation hiérarchique (JSON strict) ───────────────────────────
Write-Info "Passe 2 → Agrégation hiérarchique"

$segmentsObjs = New-Object System.Collections.Generic.List[object]
foreach($p in $segmentJsonPaths){
    try{
        $obj = Get-Content $p -Raw | ConvertFrom-Json -Depth 50
        $segmentsObjs.Add($obj)
    } catch {
        Write-Warn "JSON invalide ignoré : $p"
    }
}

# Agrégation par vagues pour rester dans le contexte
$globalObj  = Aggregate-Segments-Hierarchical `
                  -SegmentsObjs $segmentsObjs.ToArray() `
                  -BatchSize    $Pass2BatchSize `
                  -LogFile      $logFile

$globalJson = $globalObj | ConvertTo-Json -Depth 50
$globalPath = Join-Path $OutDir "global.json"
$globalJson | Out-File $globalPath -Encoding UTF8
$Global:logsDir = $logsDir

Write-Info "Agrégation OK → $globalPath"

# ── Passe 3 : JSON FINAL normalisé (enrichissement progressif) ───────────────
Write-Info "Passe 3 → JSON FINAL (enrichissement progressif)"

$globalRaw = Get-Content $globalPath -Raw

# 3A : métadonnées + résumé + ordre du jour
Write-Info "Passe 3A → date / link / resume / ordre_du_jour"

$pass3AUser = $Pass3A_User_Template.Replace("{GLOBAL_JSON}", $globalRaw)
$pass3AUser | Out-File (Join-Path $logsDir "pass3A_input.txt") -Encoding UTF8

# contrôle n_ctx / max_tokens (Pass 3A)
$pass3AUser_Effective = Truncate-For-Context `
  -SystemText $Pass3A_System `
  -UserText   $pass3AUser `
  -ModelName  $ModelPass3

$pass3AUser_Effective | Out-File (Join-Path $logsDir "pass3A_input_effective.txt") -Encoding UTF8

$pass3ARaw  = Invoke-LLM -system $Pass3A_System -user $pass3AUser_Effective -model $ModelPass3
$pass3ARaw | Out-File (Join-Path $logsDir "pass3A_raw.txt") -Encoding UTF8

try {
    $partAObj = Parse-LlmJsonStrict -RawText $pass3ARaw -Label "Pass3A" -LogFile $logFile
}
catch {
    Write-Warn "Échec parsing JSON Pass 3A, fallback par défaut."
    $partAObj = [pscustomobject]@{
        date          = "[Date]"
        link          = $null
        resume        = ""
        ordre_du_jour = @()
    }
}

# 3B : thèmes_abordes
Write-Info "Passe 3B → themes_abordes"
$pass3BUser = $Pass3B_User_Template.Replace("{GLOBAL_JSON}", $globalRaw)
$pass3BUser | Out-File (Join-Path $logsDir "pass3B_input.txt") -Encoding UTF8


$pass3BUser_Effective = Truncate-For-Context `
  -SystemText $Pass3B_System `
  -UserText   $pass3BUser `
  -ModelName  $ModelPass3

$pass3BUser_Effective | Out-File (Join-Path $logsDir "pass3B_input_effective.txt") -Encoding UTF8

$pass3BRaw  = Invoke-LLM -system $Pass3B_System -user $pass3BUser_Effective -model $ModelPass3
$pass3BRaw | Out-File (Join-Path $logsDir "pass3B_raw.txt") -Encoding UTF8

try {
    $partBObj = Parse-LlmJsonStrict -RawText $pass3BRaw -Label "Pass3B" -LogFile $logFile
}
catch {
    Write-Warn "Échec parsing JSON Pass 3B, fallback themes_abordes=[]."
    $partBObj = [pscustomobject]@{
        themes_abordes = @()
    }
}


# 3C : actions / perspectives / annexes
Write-Info "Passe 3C → actions / perspectives / annexes"

$pass3CUser = $Pass3C_User_Template.Replace("{GLOBAL_JSON}", $globalRaw)
$pass3CUser | Out-File (Join-Path $logsDir "pass3C_input.txt") -Encoding UTF8

$pass3CUser_Effective = Truncate-For-Context `
  -SystemText $Pass3C_System `
  -UserText   $pass3CUser `
  -ModelName  $ModelPass3

$pass3CUser_Effective | Out-File (Join-Path $logsDir "pass3C_input_effective.txt") -Encoding UTF8

$pass3CRaw  = Invoke-LLM -system $Pass3C_System -user $pass3CUser_Effective -model $ModelPass3
$pass3CRaw | Out-File (Join-Path $logsDir "pass3C_raw.txt") -Encoding UTF8

try {
    $partCObj = Parse-LlmJsonStrict -RawText $pass3CRaw -Label "Pass3C" -LogFile $logFile
}
catch {
    Write-Warn "Échec parsing JSON Pass 3C, fallback actions/perspectives/annexes vides."
    $partCObj = [pscustomobject]@{
        actions      = @()
        perspectives = @()
        annexes      = @()
    }
}


# 3D : demandes de documents
Write-Info "Passe 3D → demandes de documents"

$pass3DUser = $Pass3D_User_Template.Replace("{GLOBAL_JSON}", $globalRaw)
$pass3DUser | Out-File (Join-Path $logsDir "pass3D_input.txt") -Encoding UTF8

$pass3DUser_Effective = Truncate-For-Context `
  -SystemText $Pass3D_System `
  -UserText   $pass3DUser `
  -ModelName  $ModelPass3

$pass3DUser_Effective | Out-File (Join-Path $logsDir "pass3D_input_effective.txt") -Encoding UTF8



$pass3DRaw  = Invoke-LLM -system $Pass3D_System -user $pass3DUser_Effective -model $ModelPass3
$pass3DRaw | Out-File (Join-Path $logsDir "pass3D_raw.txt") -Encoding UTF8

try {
    $partDObj = Parse-LlmJsonStrict -RawText $pass3DRaw -Label "Pass3D" -LogFile $logFile
}
catch {
    Write-Warn "Échec parsing JSON Pass 3D, fallback demandes_documents=[]."
    $partDObj = [pscustomobject]@{
        demandes_documents = @()
    }
}

# Garde-fou : si l'objet est vide ou si la propriété n'existe pas, forcer au moins un tableau vide
if (-not $partDObj -or -not $partDObj.PSObject.Properties['demandes_documents']) {
    $partDObj = [pscustomobject]@{
        demandes_documents = @()
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



$finalLink          = Get-PropOrNull -Obj $partAObj -Name 'link'
$finalResume        = Get-PropOrNull -Obj $partAObj -Name 'resume'
$finalOrdreDuJour   = Get-PropOrNull -Obj $partAObj -Name 'ordre_du_jour'
$finalThemes        = Get-PropOrNull -Obj $partBObj -Name 'themes_abordes'
$finalActions       = Get-PropOrNull -Obj $partCObj -Name 'actions'
$finalPerspectives  = Get-PropOrNull -Obj $partCObj -Name 'perspectives'
$finalAnnexes       = Get-PropOrNull -Obj $partCObj -Name 'annexes'

function Get-PropOrDefault {
    param(
        [object] $Obj,
        [string] $Name,
        $Default
    )

    if($null -eq $Obj){ return $Default }
    $prop = $Obj.PSObject.Properties[$Name]
    if($null -eq $prop){ return $Default }
    return $prop.Value
}


# Fusion finale des morceaux dans un seul objet
$finalObj = [pscustomobject]@{
    date              = Get-PropOrDefault $partAObj 'date'          '[Date]'
    link              = Get-PropOrDefault $partAObj 'link'          $null
    resume            = Get-PropOrDefault $partAObj 'resume'        ""
    ordre_du_jour     = Get-PropOrDefault $partAObj 'ordre_du_jour' @()
    themes_abordes    = Get-PropOrDefault $partBObj 'themes_abordes' @()
    actions           = Get-PropOrDefault $partCObj 'actions'        @()
    perspectives      = Get-PropOrDefault $partCObj 'perspectives'   @()
    annexes           = Get-PropOrDefault $partCObj 'annexes'        @()
    demandes_documents= Get-PropOrDefault $partDObj 'demandes_documents' @()
}


$finalJson  = $finalObj | ConvertTo-Json -Depth 100
$finalPath  = Join-Path $OutDir "global_final.json"
$finalJson | Out-File $finalPath -Encoding UTF8
Write-Info "JSON FINAL → $finalPath"

"Done: $(Get-Date)" | Add-Content $logFile
Write-Info "Pipeline terminé (full JSON)."

