$ErrorActionPreference = "Stop"

# Autotest deterministe de decontamination des prompts refere Pass3A-E.
# Aucun LLM, aucun HTTP, aucune donnee de production modifiee.

$repoRoot = Split-Path -Parent $PSScriptRoot
$pipelinePath = [string]$env:CR_REFERE_PIPELINE_PS1
if (-not $pipelinePath) { $pipelinePath = Join-Path $repoRoot "cr-pipeline/pipeline/powershell/cr_refere_preventif_pipeline_json.ps1" }
if (-not (Test-Path -LiteralPath $pipelinePath -PathType Leaf)) { throw "pipeline introuvable : $pipelinePath" }
$scriptText = [System.IO.File]::ReadAllText($pipelinePath, [System.Text.Encoding]::UTF8)

function Import-PipelineFunction {
    param([string] $Text, [string] $Name)
    $marker = "function " + $Name + " {"
    $start = $Text.IndexOf($marker)
    if ($start -lt 0) { throw ("fonction introuvable dans le pipeline : " + $Name) }
    $braceStart = $Text.IndexOf("{", $start)
    $depth = 0
    $end = -1
    for ($i = $braceStart; $i -lt $Text.Length; $i++) {
        if ($Text[$i] -eq "{") { $depth++ }
        elseif ($Text[$i] -eq "}") { $depth--; if ($depth -eq 0) { $end = $i; break } }
    }
    if ($end -lt 0) { throw ("fin de fonction introuvable : " + $Name) }
    return $Text.Substring($start, $end - $start + 1)
}

function Get-PipelineBlock {
    param([string] $Text, [string] $Marker)
    $start = $Text.IndexOf($Marker)
    if ($start -lt 0) { throw ("bloc introuvable dans le pipeline : " + $Marker) }
    $braceStart = $Text.IndexOf("{", $start)
    $depth = 0
    $end = -1
    for ($i = $braceStart; $i -lt $Text.Length; $i++) {
        if ($Text[$i] -eq "{") { $depth++ }
        elseif ($Text[$i] -eq "}") { $depth--; if ($depth -eq 0) { $end = $i; break } }
    }
    if ($end -lt 0) { throw ("fin de bloc introuvable : " + $Marker) }
    return $Text.Substring($start, $end - $start + 1)
}

$promptBlocks = @(
    (Get-PipelineBlock -Text $scriptText -Marker '$script:P3B64 = @{'),
    (Get-PipelineBlock -Text $scriptText -Marker '$script:P3PARTS = @{')
)
Invoke-Expression ($promptBlocks -join "`n")

$functionNames = @('Get-P3Text', 'Get-P3Part', 'Get-P3V', 'Get-P3EUserText', 'Resolve-P3RefereGlobalJsonPath')
$definitions = @()
foreach ($name in $functionNames) { $definitions += (Import-PipelineFunction -Text $scriptText -Name $name) }
Invoke-Expression ($definitions -join "`n")

$script:Checks = 0
$script:Failures = 0
function Assert-True {
    param([bool] $Condition, [string] $Message)
    $script:Checks++
    if ($Condition) { Write-Host ("OK   " + $Message) }
    else { $script:Failures++; Write-Host ("KO   " + $Message) }
}
function Assert-Eq {
    param($Actual, $Expected, [string] $Message)
    Assert-True ($Actual -eq $Expected) ($Message + " [attendu=" + [string]$Expected + " obtenu=" + [string]$Actual + "]")
}

$forbidden = @(
    @{ Name = "identifiant J48"; Pattern = '(?i)\bJ48\b' },
    @{ Name = "identifiant J58"; Pattern = '(?i)\bJ58\b' },
    @{ Name = "identifiant 2025-J48/J58"; Pattern = '(?i)2025-J(?:48|58)' },
    @{ Name = "date 21 octobre 2025"; Pattern = '(?i)\b21\s+octobre\s+2025\b' },
    @{ Name = "date 20 novembre 2025"; Pattern = '(?i)\b20\s+novembre\s+2025\b' },
    @{ Name = "date en toutes lettres"; Pattern = '(?i)\b\d{1,2}\s+\p{L}+\s+\d{4}\b' },
    @{ Name = "creneau horaire"; Pattern = '(?i)\b\d{1,2}\s?h\s?\d{2}\b' },
    @{ Name = "identifiant P12/P130/P131"; Pattern = '(?i)\bP(?:12|130|131)\b' },
    @{ Name = "absence de transcription horodatee"; Pattern = '(?i)transcription\s+horodat\p{L}*\s+n''est\s+fournie' },
    @{ Name = "convocation datee"; Pattern = '(?i)convocation\s+des\s+parties\s+est\s+indiqu\p{L}e\s+au' },
    @{ Name = "creneau indique"; Pattern = '(?i)cr\p{L}neau\s+indiqu\p{L}\s+est\s+de' }
)
function Assert-Clean {
    param([string] $Label, [string] $Text)
    $found = @()
    foreach ($item in $forbidden) {
        if ([regex]::IsMatch($Text, [string]$item.Pattern)) { $found += [string]$item.Name }
    }
    Assert-True ($found.Count -eq 0) ($Label + " : motifs interdits=" + ($found -join ", "))
}

$jsonSample = '{"resume_global":"Resume generique sans date.","themes":[],"actions":[],"problems":[]}'
$passes = @('A', 'B', 'C', 'D', 'E')
foreach ($pass in $passes) {
    $sys = Get-P3Text $pass
    Assert-True (-not [string]::IsNullOrWhiteSpace($sys)) ("systeme Pass3" + $pass + " decode et non vide")
    Assert-Clean ("systeme Pass3" + $pass) $sys
}
foreach ($pass in @('A', 'B', 'C', 'D')) {
    $pre = Get-P3Part $pass 'prefix'
    $suf = Get-P3Part $pass 'suffix'
    Assert-True (-not [string]::IsNullOrWhiteSpace($pre)) ("prefix Pass3" + $pass + " present")
    Assert-True (-not [string]::IsNullOrWhiteSpace($suf)) ("suffix Pass3" + $pass + " present")
    Assert-Clean ("prefix Pass3" + $pass) $pre
    Assert-Clean ("suffix Pass3" + $pass) $suf

    $usr = $pre + $jsonSample + $suf
    $full = $sys + "`n" + $usr
    Assert-True ($full.Contains($jsonSample)) ("message assemble Pass3" + $pass + " contient le JSON d'entree")
    Assert-Clean ("message assemble Pass3" + $pass) $full
}

# Pass3E : message assemble via la meme fonction que la production.
$compact = [pscustomobject]@{
    numero = 1
    titre = "Sujet generique"
    localisation = ""
    description = ""
    synthese_intermediaire = [pscustomobject]@{
        resume_factuel = "Constat generique."
        points_cles = @("point generique")
        actions = @()
        desaccords = @()
        documents_demandes = @()
        elements_techniques = @()
    }
}
$usrE = Get-P3EUserText -CompactObj $compact -SubjectNumero 1 -ChunkPaths @()
$fullE = (Get-P3Text 'E') + "`n" + $usrE
Assert-True ($usrE.Contains("Sujet generique")) "message assemble Pass3E contient le sujet d'entree"
Assert-Clean "message assemble Pass3E" $fullE

# Regles metier preservees (neutralite, constats, declarations, allegations, contradictions).
$sysA = Get-P3Text 'A'
Assert-True ([regex]::IsMatch($sysA, '(?i)all\p{L}gations\s+doivent\s+rester\s+identifi\p{L}es')) "Pass3A : allegations identifiees"
Assert-True ([regex]::IsMatch($sysA, '(?i)contradictions\s+ne\s+doivent\s+pas\s+\p{L}tre\s+arbitr\p{L}es')) "Pass3A : contradictions non arbitrees"
Assert-True ([regex]::IsMatch($sysA, '(?i)restituer\s+les\s+constats')) "Pass3A : constats restitues"
$sysE = Get-P3Text 'E'
Assert-True ([regex]::IsMatch($sysE, '(?i)ne\s+jamais\s+inventer\s+de\s+constat\s+mat\p{L}riel')) "Pass3E : aucun constat invente"
Assert-True ([regex]::IsMatch($sysE, '(?i)distinguer\s+\p{L}+\s+ce\s+qui\s+est\s+d\p{L}clar\p{L}')) "Pass3E : declarations distinguees"
Assert-True ([regex]::IsMatch($sysE, '(?i)pr\p{L}server\s+les\s+incertitudes')) "Pass3E : incertitudes preservees"

# Mode historique -Pass3Refere : chemin global explicite obligatoire.
Assert-True (-not $scriptText.Contains('pass2b2f12_j48_hierarchy')) "aucun chemin de job J48 implicite"
Assert-True (-not [regex]::IsMatch($scriptText, '(?i)\bJ(?:48|58)\b')) "pipeline sans reference J48/J58"

# Les prompts Pass3 du pipeline generaliste ne doivent pas non plus exposer
# d'exemple d'affaire, de date en toutes lettres ou de creneau horaire.
$generalPipelinePath = Join-Path $repoRoot "cr-pipeline/pipeline/powershell/cr_reunion_point_mumerotes_pipeline_json.ps1"
Assert-True (Test-Path -LiteralPath $generalPipelinePath -PathType Leaf) "pipeline generaliste present"
$generalText = [System.IO.File]::ReadAllText($generalPipelinePath, [System.Text.Encoding]::UTF8)
Assert-True (-not [regex]::IsMatch($generalText, '(?i)\bP(?:12|130|131)\b')) "pipeline generaliste sans exemple P12/P130/P131"
Assert-True (-not [regex]::IsMatch($generalText, '(?i)\b\d{1,2}\s+\p{L}+\s+\d{4}\b')) "pipeline generaliste sans date en toutes lettres"
Assert-True (-not [regex]::IsMatch($generalText, '(?i)\b\d{1,2}\s?h\s?\d{2}\b')) "pipeline generaliste sans creneau horaire"
$threw = $false
$message = ""
try { $null = Resolve-P3RefereGlobalJsonPath -Path "" }
catch { $threw = $true; $message = $_.Exception.Message }
Assert-True $threw "chemin global vide refuse"
Assert-True ($message -like "*Pass3RefereGlobalJsonPath requis*") "message de garde explicite"
Assert-Eq (Resolve-P3RefereGlobalJsonPath -Path "C:\temp\global.json") "C:\temp\global.json" "chemin global explicite conserve"
Assert-True ($scriptText.Contains('$pass3GlobalPath = Resolve-P3RefereGlobalJsonPath -Path $Pass3RefereGlobalJsonPath')) "dispatch -Pass3Refere utilise la garde explicite"

Write-Host ("checks=" + $script:Checks + " failures=" + $script:Failures)
if ($script:Failures -gt 0) { throw ("ECHEC refere_prompt_contamination : " + $script:Failures + " assertion(s) en erreur") }
"OK refere_prompt_contamination"
