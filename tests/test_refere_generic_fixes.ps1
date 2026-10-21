$ErrorActionPreference = "Stop"

# Autotest deterministe des correctifs generiques du pipeline refere.
# Aucun LLM, aucun HTTP, aucune donnee J58 modifiee.

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

$functionNames = @('Get-P3V', 'Read-P3RawText', 'Get-Pass2ECompactParts', 'Merge-Pass2ECompactParts', 'Test-P3SynthesisHasMatter', 'Has-P3Synthese', 'Read-RefereContextTexts')
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
function Write-JsonFile {
    param([string] $Path, $Obj)
    $json = $Obj | ConvertTo-Json -Depth 30
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) ("refere_generic_fixes_" + [guid]::NewGuid().ToString("N"))
[void](New-Item -ItemType Directory -Path $root -Force)

try {
    # ----------------------------- 1) Pass2E multiparties : cas J58 03-12 sujet 1
    $d = Join-Path $root "pass2E_sujets_compact"
    [void](New-Item -ItemType Directory -Path $d -Force)
    $part1 = [ordered]@{
        source_name = "sujet_001_part01"
        numero = 1
        titre = "Deroulement general de l expertise"
        synthese_intermediaire = [ordered]@{
            resume_factuel = "Partie un : constat reel du sujet 1."
            points_cles = @("point part01")
            actions = @("action part01")
            desaccords = @()
            documents_demandes = @()
            elements_techniques = @("technique part01")
        }
        stats = [ordered]@{ chunk_count = 10; interventions_count = 295 }
    }
    $part2 = [ordered]@{
        source_name = "sujet_001_part02"
        numero = 1
        titre = "Deroulement general de l expertise"
        synthese_intermediaire = [ordered]@{
            resume_factuel = "Partie deux : second constat reel du sujet 1."
            points_cles = @("point part02")
            actions = @("action part02")
            desaccords = @()
            documents_demandes = @("document part02")
            elements_techniques = @()
        }
        stats = [ordered]@{ chunk_count = 8; interventions_count = 255 }
    }
    Write-JsonFile (Join-Path $d "sujet_001_part02_compact.json") $part2
    Write-JsonFile (Join-Path $d "sujet_001_part01_compact.json") $part1
    $parts = @(Get-Pass2ECompactParts -Dir $d -Subject 1)
    Assert-Eq $parts.Count 2 "1) sujet 1 part01 + part02 : deux parties decouvertes"
    Assert-Eq ([string]$parts[0].name) "sujet_001_part01_compact.json" "1b) part01 en premier (ordre numerique)"
    Assert-Eq ([string]$parts[1].name) "sujet_001_part02_compact.json" "1c) part02 en second"
    Assert-Eq ([int]$parts[0].part) 1 "1d) numero de partie part01 = 1"
    Assert-Eq ([int]$parts[1].part) 2 "1e) numero de partie part02 = 2"

    $merged = Merge-Pass2ECompactParts -Parts $parts
    Assert-True ($null -ne $merged) "2) fusion multiparties non nulle"
    Assert-Eq (@($merged.parts).Count) 2 "2b) les deux parties sont conservees dans la fusion"
    Assert-Eq ([int]$merged.parts[0].part) 1 "2c) part01 conservee en premiere position"
    Assert-Eq ([int]$merged.parts[1].part) 2 "2d) part02 conservee en seconde position"
    $resume = [string]$merged.synthese_intermediaire.resume_factuel
    Assert-True ($resume.Contains("Partie un")) "2e) resume part01 present"
    Assert-True ($resume.Contains("Partie deux")) "2f) resume part02 present"
    Assert-True ($resume.IndexOf("Partie un") -lt $resume.IndexOf("Partie deux")) "2g) ordre chronologique part01 puis part02"
    Assert-Eq ([int]$merged.stats.chunk_count) 18 "2h) chunk_count additionne"
    Assert-Eq ([int]$merged.stats.interventions_count) 550 "2i) interventions_count additionne"
    Assert-Eq (@($merged.synthese_intermediaire.points_cles).Count) 2 "2j) points_cles des deux parties conserves"
    $mergedHasSynth = $false
    $mergedErr = ''
    try { $mergedHasSynth = [bool](Has-P3Synthese $merged) } catch { $mergedErr = $_.Exception.Message }
    Assert-True ($mergedErr -eq '') "2k) compact fusionne : aucune exception"
    Assert-True $mergedHasSynth "2l) compact fusionne avec matiere reelle : exploitable"

    $emptyParts = @()
    foreach ($pn in @(1, 2)) {
        $emptyParts += [pscustomobject]@{
            numero = 1
            part = $pn
            name = 'sujet_001_part0' + $pn + '_compact.json'
            path = ''
            compact = [pscustomobject]@{
                stats = [ordered]@{ chunk_count = 1; interventions_count = 1 }
                synthese_intermediaire = [pscustomobject]@{
                    resume_factuel = "Aucun element relatif a ce point n a ete identifie dans les echanges analyses."
                    points_cles = @()
                    actions = @()
                    desaccords = @()
                    documents_demandes = @()
                    elements_techniques = @()
                }
            }
        }
    }
    $mergedEmpty = Merge-Pass2ECompactParts -Parts $emptyParts
    $mergedEmptyHasSynth = $true
    $mergedEmptyErr = ''
    try { $mergedEmptyHasSynth = [bool](Has-P3Synthese $mergedEmpty) } catch { $mergedEmptyErr = $_.Exception.Message }
    Assert-True ($mergedEmptyErr -eq '') "2m) compact fusionne sans matiere : aucune exception"
    Assert-True (-not $mergedEmptyHasSynth) "2n) compact fusionne sans matiere : non exploitable"
    # ----------------------------- 3) Pass2E squelette non exploitable
    $skeleton = [pscustomobject]@{
        stats = [pscustomobject]@{ chunk_count = 0; interventions_count = 0 }
        synthese_intermediaire = [pscustomobject]@{
            resume_factuel = "Aucun element relatif a ce point n a ete identifie dans les echanges de la reunion."
            points_cles = @()
            actions = @()
            desaccords = @()
            documents_demandes = @()
            elements_techniques = @()
        }
    }
    Assert-True (-not (Has-P3Synthese $skeleton)) "3) stats chunk_count=0/interventions_count=0 : non exploitable"

    # ----------------------------- 4) synthese generique meme avec stats non nulles
    $generic = [pscustomobject]@{
        stats = [pscustomobject]@{ chunk_count = 1; interventions_count = 1 }
        synthese_intermediaire = [pscustomobject]@{
            resume_factuel = "Aucun element relatif a ce point n a ete identifie dans les echanges analyses."
            points_cles = @()
            actions = @()
            desaccords = @()
            documents_demandes = @()
            elements_techniques = @()
        }
    }
    Assert-True (-not (Has-P3Synthese $generic)) "4) synthese generique Aucun element : non exploitable"
    # ----------------------------- 5) compact reel preserve
    $real = [pscustomobject]@{
        stats = [pscustomobject]@{ chunk_count = 3; interventions_count = 50 }
        synthese_intermediaire = [pscustomobject]@{
            resume_factuel = "Un desordre a ete constate sur le mur mitoyen."
            points_cles = @("fissure observee")
            actions = @()
            desaccords = @()
            documents_demandes = @()
            elements_techniques = @("mur en beton")
        }
    }
    Assert-True (Has-P3Synthese $real) "5) compact avec matiere reelle : conserve"
    # ----------------------------- 6) contexte refere explicite
    $ctxDir = Join-Path $root "contexte"
    [void](New-Item -ItemType Directory -Path $ctxDir -Force)
    $ctxPath = Join-Path $ctxDir "contexte_general_compte_rendu.json"
    Write-JsonFile $ctxPath ([ordered]@{
        system = "Systeme refere explicite."
        user = "Consignes refere explicites."
    })
    $ctx = Read-RefereContextTexts -Path $ctxPath
    Assert-True ([bool]$ctx.provided) "6) contexte explicite marque fourni"
    Assert-Eq ([string]$ctx.system) "Systeme refere explicite." "6b) champ system lu"
    Assert-Eq ([string]$ctx.user) "Consignes refere explicites." "6c) champ user lu"
    $ctxEmpty = Read-RefereContextTexts -Path ""
    Assert-True (-not [bool]$ctxEmpty.provided) "7) chemin vide : contexte non fourni"
    Assert-Eq ([string]$ctxEmpty.user) "" "7b) chemin vide : aucun user injecte"

    $photosCtx = Join-Path $ctxDir "contexte_general_photos.json"
    Write-JsonFile $photosCtx ([ordered]@{ system = "PHOTO SYSTEM"; user = "PHOTO USER" })
    $ctxNoAuto = Read-RefereContextTexts -Path ""
    Assert-Eq ([string]$ctxNoAuto.user) "" "7c) aucun branchement automatique sur contexte_general_photos.json"
    $threwMissing = $false
    $messageMissing = ""
    try { $null = Read-RefereContextTexts -Path (Join-Path $ctxDir "absent.json") }
    catch { $threwMissing = $true; $messageMissing = $_.Exception.Message }
    Assert-True $threwMissing "8) contexte explicite absent : erreur"
    Assert-True ($messageMissing -like "*introuvable*") "8b) message contexte introuvable"

    $badCtx = Join-Path $ctxDir "invalid.json"
    [System.IO.File]::WriteAllText($badCtx, "{ pas du json", (New-Object System.Text.UTF8Encoding($false)))
    $threwBad = $false
    $messageBad = ""
    try { $null = Read-RefereContextTexts -Path $badCtx }
    catch { $threwBad = $true; $messageBad = $_.Exception.Message }
    Assert-True $threwBad "9) contexte explicite JSON invalide : erreur"
    Assert-True ($messageBad -like "*JSON invalide*") "9b) message JSON invalide"
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ("checks=" + $script:Checks + " failures=" + $script:Failures)
if ($script:Failures -gt 0) { throw ("ECHEC refere_generic_fixes : " + $script:Failures + " assertion(s) en erreur") }
"OK refere_generic_fixes"
