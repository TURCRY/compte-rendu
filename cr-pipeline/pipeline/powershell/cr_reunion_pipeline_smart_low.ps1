<#
cr_reunion_pipeline_smart.ps1
Pipeline complet : CSV (transcription) → segmentation intelligente → Passes 1/2/3 → Markdown (+ DOCX si pandoc).
#>

param(
  [Parameter(Mandatory=$true)]  [string] $CsvPath,
  [Parameter(Mandatory=$false)] [string] $OutDir = ".\out",

  # Provider & modèle
  [ValidateSet("openai","ollama")] [string] $Provider = "openai",
  [string] $ApiBase   = "http://localhost:11434",  # OpenAI-compat: on ajoute /v1/chat/completions
  [string] $OllamaBase= "http://localhost:11434",  # Ollama natif: /api/generate
  [string] $Model     = "mistral:7b-instruct-q4",
  [string] $ApiKey    = "",

  # Segmentation : preset + debug
  [ValidateSet("conservateur","equilibre","agressif")] [string] $Preset = "equilibre",
  [switch] $DebugSeg,    # affiche des logs détaillés de segmentation

  # Relance
  [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info($m){ Write-Host "[INFO]  $m" -ForegroundColor Cyan }
function Write-Warn($m){ Write-Host "[WARN]  $m" -ForegroundColor Yellow }
function Write-Err ($m){ Write-Host "[ERROR] $m" -ForegroundColor Red  }
function Ensure-Dir($p){ if(!(Test-Path $p)){ New-Item -ItemType Directory -Path $p | Out-Null } }

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
  'réserves','réserve','désordre','constat','constats','anomalie','défaut','non respect',
  'non-respect','déviation','écart','écarts','tolérance','cahier des charges',
  'document technique','dossier technique','chantier','travaux','réalisation',
  'maître d’'œuvre','moe','architecte','entreprise de peinture','entreprise','constructeur',
  'bureau d’'études','béton','structure','parking','place','emplacement','numéro','r-1','r-2','r+1',
  'sous-sol','niveau','marquage','signalétique','accès','rampe','circulation','voiture',
  'stationnement','voitures','véhicule','véhicules','garage',
  'livraison','livré','réception','réceptionner','remise','clé','clés',
  'retard','retards','délais','délai','livrable','livrables','plannings','planning',
  'indigo','cuvelage','inondation','eau','étanchéité','pompage','infiltration',
  'travaux de reprise','chantier en cours','achèvement','date de livraison','report','provisoire',
  'accès temporaire','accès parking','garage temporaire',
  'promoteur','acquéreur','maître d’'ouvrage','maître d’'oeuvre','moa','moe','expert','sapiteur',
  'architecte','entreprise','bailleur','vendeur','acheteur','client','parties','avocat',
  'gestionnaire','notaire','propriétaire','copropriétaire','copropriété','locataire','gestion',
  'banque','assureur','assurance','décennale','contrôle technique',
  'pinel','dispositif pinel','avantage fiscal','fiscalité','fiscal','fiscale',
  'impôt','impôts','déduction','déductions','réduction','réductions','loyer','revenu',
  'déclaration','bénéfice','amortissement','loi pinel','loi','sapiteur financier','préjudice fiscal',
  'perte','préjudice','dommage','évaluation financière','calcul','simulation','impacts financiers',
  'mise en cause','mises en cause','mise en demeure','expertise','expertises','expert judiciaire',
  'expert technique','expert amiable','rapport','rapport d’'expertise','note','note technique',
  'procédure','assignation','audience','tribunal','amiable','conciliation','solution amiable',
  'médiation','responsabilité','responsabilités','responsable','dommage','dommages','préjudice',
  'perte de chance','juridique','contrat','contractuel','contrat de vente','acte de vente',
  'document de vente','permis de construire','autorisation','autorisation administrative',
  'litige','conflit','désaccord','accord','signature','décision','décisions','résolution',
  'jugement','référé','appel','parties adverses',
  'laser','mètre','télémètre','niveau','photo','photographie','schéma','plan','croquis',
  'plan d’'exécution','dossier','pièce','annexe','plan de coupe','vue en plan',
  'calcul','tableau','analyse','mesure laser','vérification','contrôle','relevé',
  'instrument','outil','mesurage','tolerances','tolérances',
  'discussion','débat','point suivant','point précédent','sujet suivant','prochain point',
  'ordre du jour','avancement','bilan','proposition','solution','solutions',
  'problème','problèmes','remarque','remarques','commentaire','commentaires',
  'à voir','à vérifier','à corriger','à fournir','à transmettre','à faire','à valider',
  'note','mail','message','compte rendu','cr','procès-verbal','pv','document',
  'appartement','logement','immeuble','bâtiment','résidence','lot','lots',
  'copropriété','parties communes','parties privatives','garage','cave','ascenseur',
  'accès','escalier','palier','hall','portes','volets','fenêtres','menuiserie',
  'isolation','mur','murs','plafond','sol','revêtement','revêtements','béton','peinture',
  'étanchéité','ventilation','chauffage','électricité','eau','réseau','canalisation','fuite'
)
$AnchorPhrases = @(
  'on passe au point suivant','nouveau sujet','dernier point','revenons à',
  'pour terminer ce sujet','changement de sujet','autre point','prochain point',
  'sujet suivant','concluons sur','pour conclure','on clôt'
)
[double] $BonusDomainKeyword = 0.10
[double] $BonusAnchorPhrase  = 0.15

# ── Utils temps ────────────────────────────────────────────────────────────────
function Hms-To-Seconds([string]$hms){ if(-not $hms){return 0}; $p=$hms.Split(":"); if($p.Count -lt 2){return 0}; if($p.Count -eq 2){$p=@("0")+$p}; [int]$p[0]*3600+[int]$p[1]*60+[int][double]$p[2] }
function Seconds-To-Hms([int]$s){ $h=[int]($s/3600); $m=[int](($s%3600)/60); $ss=[int]($s%60); "{0:D2}:{1:D2}:{2:D2}" -f $h,$m,$ss }

# ── Tokenization légère FR ────────────────────────────────────────────────────
$StopFR = @('alors','ainsi','après','avant','avec','car','ce','cela','ces','cet','cette','ceux','chaque',
'comme','comment','dans','de','des','du','donc','en','est','et','été','être','il','ils','elle','elles','on',
'nous','vous','je','la','le','les','leur','là','lui','mais','mes','mon','ne','nos','notre','ou','où','par',
'pas','plus','pour','qu','que','qui','sans','se','ses','son','sur','ta','tes','ton','très','trop','un','une',
'vos','votre','y','au','aux','vers','entre','déjà','peut','peu','fait','faire')

function Normalize-Tokens([string]$text){
  $t = ($text -as [string]).ToLower() -replace "[^a-zàâäçéèêëîïôöùûüÿœ\- ]"," "
  $raw = $t -split "\s+" | Where-Object { $_.Length -gt 2 -and -not ($StopFR -contains $_) }
  $raw | ForEach-Object { ($_ -replace "(ements|ement|ations|ation|istes|iste|iques|ique|ment|tion|s)$","") }
}
function Bag-Of-Words($tokens){ $d=@{}; foreach($w in $tokens){ if($w){ $d[$w]=1+($d[$w] | ForEach-Object {$_}) } }; $d }
function Cosine-Sim($a,$b){ if(-not $a.Keys.Count -or -not $b.Keys.Count){return 0.0}; $dot=0; foreach($k in $a.Keys){ if($b.ContainsKey($k)){ $dot += $a[$k]*$b[$k] } }; $na=[math]::Sqrt(($a.Values|Measure-Object -Sum).Sum); $nb=[math]::Sqrt(($b.Values|Measure-Object -Sum).Sum); if($na -eq 0 -or $nb -eq 0){return 0.0}; $dot/($na*$nb) }

# ── LLM calls ─────────────────────────────────────────────────────────────────
function Invoke-LLM-OpenAICompat([string]$system,[string]$user){
  $uri = ($ApiBase.TrimEnd('/')) + "/v1/chat/completions"
  $headers=@{}; if($ApiKey){ $headers["Authorization"]="Bearer $ApiKey" }
  $body = @{
    model=$Model; temperature=0.2;
    messages=@(@{role="system";content=$system}, @{role="user";content=$user})
  } | ConvertTo-Json -Depth 10
  (Invoke-RestMethod -Method POST -Uri $uri -Headers $headers -Body $body -ContentType "application/json").choices[0].message.content
}
function Invoke-LLM-OllamaNative([string]$system,[string]$user){
  $uri = ($OllamaBase.TrimEnd('/')) + "/api/generate"
  $prompt = "SYSTEM:`n$system`n`nUSER:`n$user"
  $body = @{ model=$Model; prompt=$prompt; stream=$false; options=@{temperature=0.2} } | ConvertTo-Json -Depth 10
  (Invoke-RestMethod -Method POST -Uri $uri -Body $body -ContentType "application/json").response
}
function Invoke-LLM([string]$system,[string]$user){ if($Provider -ieq "openai"){ Invoke-LLM-OpenAICompat $system $user } else { Invoke-LLM-OllamaNative $system $user } }

# ── Prompts Passes 1/2/3 ──────────────────────────────────────────────────────
$Pass1_System=@'
Tu es un assistant d'analyse de réunions. À partir d'une transcription de ~20–30 minutes, produis une synthèse factuelle structurée, sans invention.
Sortie JSON STRICT :
{"resume_segment":"5 phrases max","themes":[{"titre":"string","synthese":["point 1","point 2"],"timecodes":["HH:MM:SS"]}],"actions":[{"action":"string","responsable":"string","echeance":"YYYY-MM-DD | null"}],"problems":[{"probleme":"string","solution":"string"}]}
Règles : reformuler clairement ; s'appuyer sur les timecodes ; regrouper par thème ; ≤1000 mots.
'@
$Pass1_User_Template=@'
Transcription segmentée (de {START_HMS} à {END_HMS}) :

{LINES}

Exige uniquement le JSON au format défini.
'@

$Pass2_System=@'
Tu reçois plusieurs mini-CR JSON d'une même réunion. Fusionne-les en un seul JSON cohérent, sans doublons, en regroupant les thèmes similaires.
Sortie JSON STRICT :
{"resume_global":"6 à 8 phrases","themes":[{"titre":"string","synthese":["..."],"timecodes":["HH:MM:SS","HH:MM:SS"]}],"actions":[{"action":"string","responsable":"string","echeance":"YYYY-MM-DD | null"}],"problems":[{"probleme":"string","solution":"string"}]}
Règles : regrouper par sens ; dédupliquer ; conserver timecodes représentatifs ; garder la date la plus précise.
'@
$Pass2_User_Template=@'
Voici la liste des mini-CR JSON à fusionner (un tableau JSON) :

{SEGMENTS_JSON_ARRAY}

Exige uniquement le JSON au format défini.
'@

$Pass3_System=@'
Tu es un assistant de rédaction. À partir du JSON global ci-dessous, produis un compte rendu en Markdown avec structure fixe :
1) Date  2) Link  3) Résumé (5–6 phrases)  4) Ordre du jour (3–8 items)
5) Thèmes abordés (paragr. 5–10 lignes max)  6) Actions (tableau)  7) Perspectives (Problème → Solution)
Ton pro, concis, neutre ; aucune invention ; titres fixes. Pas de bloc code Markdown englobant.
'@
$Pass3_User_Template=@'
JSON global à rendre au format Markdown standardisé :
{GLOBAL_JSON}

Métadonnées suggérées :
- Date : {DATE_SUGGEST}
- Link : {LINK_SUGGEST}
'@

# ── Segmentation intelligente enrichie ─────────────────────────────────────────
function Get-IntelligentSegments($rows,$colTime,$colSpeaker,$colText,$logPath){
  $segments=@(); $debugLog=@()
  $norm = foreach($r in $rows){
    [pscustomobject]@{ sec=[int](Hms-To-Seconds $r.$colTime); speaker=[string]$r.$colSpeaker; text=[string]$r.$colText; tokens=(Normalize-Tokens $r.$colText); raw=[string]$r.$colText }
  }
  $n=$norm.Count; if($n -eq 0){ return @() }

  $iStart=0
  while($iStart -lt $n){
    $startSec=$norm[$iStart].sec
    $minLen=$MinSegmentMinutes*60; $target=$TargetSegmentMinutes*60; $maxLen=$MaxSegmentMinutes*60
    $i=$iStart; $lastSpeaker=$norm[$iStart].speaker; $cutReason="none"; $cutIndex=$null; $cutSec=$startSec

    while($i -lt $n){
      $cur=$norm[$i]

      if($i -gt $iStart){
        $gap=$cur.sec - $norm[$i-1].sec
        if($gap -ge $BigGapSeconds -and ($cur.sec - $startSec) -ge $minLen){ $cutReason="big-gap:${gap}s"; $cutIndex=$i; $cutSec=$cur.sec; break }
      }

      $winStart=[math]::Max($i-$WindowLines,$iStart)
      $tokensRecent=@(); for($k=$winStart; $k -lt $i; $k++){ $tokensRecent += $norm[$k].tokens }
      $bagRecent=Bag-Of-Words $tokensRecent; $bagCur=Bag-Of-Words $cur.tokens
      $sim=Cosine-Sim $bagRecent $bagCur; $novelty=1.0-$sim

      if($cur.speaker -ne $lastSpeaker){ $novelty += 0.08 }

      $rawLower=$cur.raw.ToLower()
      if($DomainKeywords | Where-Object { $rawLower -like "*$_*" }){ $novelty += $BonusDomainKeyword }
      if($AnchorPhrases | Where-Object { $rawLower -like "*$_*" })  { $novelty += $BonusAnchorPhrase  }

      $elapsed=$cur.sec - $startSec

      if($elapsed -ge $minLen -and $novelty -ge $ChangeThresh){ $cutReason=("novelty:{0:N2}" -f $novelty); $cutIndex=$i; $cutSec=$cur.sec }
      if($elapsed -ge $maxLen){ if(-not $cutIndex){ $cutIndex=$i; $cutSec=$cur.sec; $cutReason="max-len" }; break }
      if($elapsed -ge $target -and $cutIndex){ break }

      $lastSpeaker=$cur.speaker; $i++
      if($i -ge $n){ $cutIndex=$n; $cutSec=$norm[-1].sec; $cutReason="end" }
    }

    $iEnd = if($cutIndex){ $cutIndex } else { [math]::Min($i,$n); $cutReason="target-no-candidate" }
    $segments += ,@($rows[$iStart..($iEnd-1)])

    if($SegDebug){
      $msg=("SEGMENT {0:D2}   {1} → {2}   len={3}s   reason={4}" -f ($segments.Count),(Seconds-To-Hms $norm[$iStart].sec),(Seconds-To-Hms $norm[$iEnd-1].sec),($norm[$iEnd-1].sec-$norm[$iStart].sec),$cutReason)
      $debugLog += $msg
    }

    $nextStartSec=$norm[$iEnd-1].sec - $OverlapSeconds
    $newStart=$iEnd; for($j=$iEnd; $j -gt 0 -and $norm[$j-1].sec -ge $nextStartSec; $j--){ $newStart=$j }
    $iStart=$newStart
  }

  if($SegDebug -and $logPath){ $debugLog | Out-File $logPath -Encoding UTF8 }
  return $segments
}

# ── Lecture CSV + segmentation ────────────────────────────────────────────────
if(!(Test-Path $CsvPath)){ throw "CSV introuvable: $CsvPath" }
Ensure-Dir $OutDir; Ensure-Dir (Join-Path $OutDir "segments"); Ensure-Dir (Join-Path $OutDir "logs")
$logFile = Join-Path $OutDir ("logs\run_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")
"Start: $(Get-Date)" | Out-File $logFile -Encoding UTF8

Write-Info "Lecture CSV: $CsvPath"
$rows = Import-Csv -Path $CsvPath
$colSpeaker = ($rows[0].psobject.Properties.Name | Where-Object { $_ -match 'speaker' })[0]
$colTime    = ($rows[0].psobject.Properties.Name | Where-Object { $_ -match 'temps' -or $_ -match 'time' })[0]
$colText    = ($rows[0].psobject.Properties.Name | Where-Object { $_ -match 'texte' -or $_ -match 'text' })[0]
if(-not $colSpeaker -or -not $colTime -or -not $colText){ throw "Colonnes attendues non trouvées (speaker / temps / texte)." }

$rows = $rows | ForEach-Object { $_ | Add-Member -NotePropertyName __sec -NotePropertyValue (Hms-To-Seconds $_.$colTime) -Force; $_ } | Sort-Object __sec
if($rows.Count -eq 0){ throw "CSV vide." }

$segLog = Join-Path $OutDir "logs\segments_debug.log"
$segments = Get-IntelligentSegments -rows $rows -colTime $colTime -colSpeaker $colSpeaker -colText $colText -logPath $segLog
Write-Info ("Nombre de segments (smart+) : " + $segments.Count)
if($SegDebug){ Write-Info ("Log segmentation → $segLog") }

# ── Passe 1 : mini-CR par segment ─────────────────────────────────────────────
$segmentJsonPaths=@()
for($i=0; $i -lt $segments.Count; $i++){
  $seg = $segments[$i]
  $segOut = Join-Path $OutDir ("segments\segment_{0:D2}.json" -f ($i+1))
  $startH = Seconds-To-Hms ($seg[0].__sec)
  $endH   = Seconds-To-Hms ($seg[-1].__sec)

  if((Test-Path $segOut) -and (-not $Force)){ Write-Info ("Skip segment {0:D2} (existe) → $segOut" -f ($i+1)); $segmentJsonPaths += $segOut; continue }

  Write-Info ("Passe 1 → Segment {0:D2}  [{1} → {2}]" -f ($i+1,$startH,$endH))

  $lines = $seg | ForEach-Object {
    "[{0}] {1}: {2}" -f $_.$colTime, $_.$colSpeaker, $_.$colText
  } | Out-String

  $userPrompt = $Pass1_User_Template.Replace("{START_HMS}",$startH).Replace("{END_HMS}",$endH).Replace("{LINES}",$lines.Trim())
  $raw = Invoke-LLM -system $Pass1_System -user $userPrompt

  $jsonStr = $raw.Trim()
  try { $null = $jsonStr | ConvertFrom-Json -Depth 50 }
  catch {
    $start=$jsonStr.IndexOf("{"); $end=$jsonStr.LastIndexOf("}")
    if($start -ge 0 -and $end -gt $start){ $jsonStr = $jsonStr.Substring($start,$end-$start+1); $null = $jsonStr | ConvertFrom-Json -Depth 50 }
    else { Write-Err ("JSON invalide segment {0:D2}; brut loggé" -f ($i+1)); $raw | Out-File ($segOut + ".raw.txt") -Encoding UTF8; throw }
  }
  $jsonStr | Out-File $segOut -Encoding UTF8
  $segmentJsonPaths += $segOut
  "Segment {0:D2} OK" -f ($i+1) | Add-Content $logFile
}

# ── Passe 2 : agrégation ──────────────────────────────────────────────────────
Write-Info "Passe 2 → Agrégation"
$segmentsObjs=@(); foreach($p in $segmentJsonPaths){ try{ $segmentsObjs += (Get-Content $p -Raw | ConvertFrom-Json -Depth 50) } catch { Write-Warn "JSON invalide ignoré : $p" } }
$segmentsJsonArray = ($segmentsObjs | ConvertTo-Json -Depth 50)
$pass2User = $Pass2_User_Template.Replace("{SEGMENTS_JSON_ARRAY}",$segmentsJsonArray)
$pass2Raw  = Invoke-LLM -system $Pass2_System -user $pass2User

$globalJson = $pass2Raw.Trim()
try { $null = $globalJson | ConvertFrom-Json -Depth 50 }
catch {
  $s=$globalJson.IndexOf("{"); $e=$globalJson.LastIndexOf("}")
  if($s -ge 0 -and $e -gt $s){ $globalJson = $globalJson.Substring($s,$e-$s+1); $null = $globalJson | ConvertFrom-Json -Depth 50 }
  else { Write-Err "Échec parsing JSON global (brut loggé)"; $pass2Raw | Out-File (Join-Path $OutDir "global_raw.txt") -Encoding UTF8; throw }
}
$globalPath = Join-Path $OutDir "global.json"; $globalJson | Out-File $globalPath -Encoding UTF8
Write-Info "Agrégation OK → $globalPath"

# ── Passe 3 : rendu Markdown (+ DOCX optionnel) ───────────────────────────────
Write-Info "Passe 3 → Rendu final Markdown"
$dateSuggest=(Get-Date -Format "yyyy-MM-dd"); $linkSuggest="—"
$pass3User = $Pass3_User_Template.Replace("{GLOBAL_JSON}",(Get-Content $globalPath -Raw)).Replace("{DATE_SUGGEST}",$dateSuggest).Replace("{LINK_SUGGEST}",$linkSuggest)
$mdRaw = Invoke-LLM -system $Pass3_System -user $pass3User
$mdClean = $mdRaw.Trim()
$mdPath = Join-Path $OutDir "compte_rendu.md"; $mdClean | Out-File $mdPath -Encoding UTF8
Write-Info "Compte rendu → $mdPath"

try{
  $pandoc = Get-Command pandoc -ErrorAction Stop
  $docxPath = Join-Path $OutDir "compte_rendu.docx"
  & $pandoc.Source $mdPath -o $docxPath
  Write-Info "DOCX créé (pandoc) → $docxPath"
}catch{ Write-Warn "Pandoc non détecté : export DOCX sauté." }

"Done: $(Get-Date)" | Add-Content $logFile
Write-Info "Pipeline terminé."
