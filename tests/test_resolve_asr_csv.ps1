$ErrorActionPreference = "Stop"

# Autotest deterministe de Resolve-AsrCsvPath (aucun LLM, aucun HTTP, aucun NAS).
# Cree des dossiers temporaires et verifie la selection du CSV ASR principal.

$repoRoot = Split-Path -Parent $PSScriptRoot
# Chemin du pipeline surchargeable pour executer le test hors arborescence du
# depot (ex. dans le conteneur cr-pipeline : CR_REFERE_PIPELINE_PS1=/pipeline/...).
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
    if ($braceStart -lt 0) { throw ("bloc invalide : " + $Name) }
    $depth = 0
    $end = -1
    for ($i = $braceStart; $i -lt $Text.Length; $i++) {
        if ($Text[$i] -eq "{") { $depth++ }
        elseif ($Text[$i] -eq "}") { $depth--; if ($depth -eq 0) { $end = $i; break } }
    }
    if ($end -lt 0) { throw ("fin de fonction introuvable : " + $Name) }
    return $Text.Substring($start, $end - $start + 1)
}

$script:CsvWarnings = New-Object System.Collections.ArrayList
function Write-CrWarn { param([string] $Message) [void]$script:CsvWarnings.Add([string]$Message) }

$functionNames = @("Get-CrLeafName", "ConvertTo-ContainerAsrPath", "Test-IsPhotoAsrCsvName", "Get-AsrCsvPartKey", "Resolve-AsrCsvPath")
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
    param([string] $Actual, [string] $Expected, [string] $Message)
    Assert-True ($Actual -eq $Expected) ($Message + " [attendu=" + $Expected + " obtenu=" + $Actual + "]")
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) ("asr_csv_test_" + [guid]::NewGuid().ToString("N"))
[void](New-Item -ItemType Directory -Path $root -Force)
$stamp = [datetime]::new(2026, 1, 1, 10, 0, 0)

function New-Csv {
    param([string] $Dir, [string] $Name, [int] $MinutesOffset)
    $path = Join-Path $Dir $Name
    [System.IO.File]::WriteAllText($path, "start;end;speaker;text", (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::SetLastWriteTime($path, $stamp.AddMinutes($MinutesOffset))
    return $path
}
function New-CaseDir {
    param([string] $Name)
    $d = Join-Path $root $Name
    [void](New-Item -ItemType Directory -Path $d -Force)
    return $d
}
function Get-Name {
    param([string] $FullPath)
    if (-not $FullPath) { return "" }
    return [System.IO.Path]::GetFileName($FullPath)
}

try {
    # ---------------------------------------------------------------- 1) legacy _complet_ (accedit-2025-11-20)
    $dir1 = New-CaseDir "legacy_complet"
    [void](New-Csv $dir1 "J48 Enghien PDS 20 11 2025 part 1_mono16_16000Hz(wav).csv" 10)
    [void](New-Csv $dir1 "J48 Enghien PDS 20 11 2025 part 1_mono16_16000Hz(wav)(photo).csv" 11)
    [void](New-Csv $dir1 "J48 Enghien PDS 20 11 2025 part 2_mono16_16000Hz(wav).csv" 12)
    [void](New-Csv $dir1 "J48 Enghien PDS 20 11 2025 part 2_mono16_16000Hz(wav)(photo).csv" 13)
    [void](New-Csv $dir1 "J48_Enghien_PDS_20_11_2025_complet_mono16_16000Hz.csv" 5)
    [void](New-Csv $dir1 "Sujets.csv" 20)
    $infos1 = @{ fichier_transcription = "\\192.168.1.20\Affaires\2025-J48\AF_Expert_ASR\transcriptions\accedit-2025-11-20\J48_Enghien_PDS_20_11_2025_complet_mono16_16000Hz.csv" }
    $got1 = Resolve-AsrCsvPath -Paths @{ TranscriptionDir = $dir1 } -Infos $infos1
    Assert-Eq (Get-Name $got1) "J48_Enghien_PDS_20_11_2025_complet_mono16_16000Hz.csv" "1) legacy : le CSV agrege _complet_ est retenu (UNC Windows)"

    # ------------------------------------------------- 2) actuel (wav).csv + variante (photo) (accedit-2026-05-28)
    $dir2 = New-CaseDir "actuel_wav"
    [void](New-Csv $dir2 "J48_Enghien_2026-05-28_mono16_16000Hz(wav).csv" 10)
    [void](New-Csv $dir2 "J48_Enghien_2026-05-28_mono16_16000Hz(wav)(photo).csv" 30)
    [void](New-Csv $dir2 "Sujets.csv" 20)
    $infos2 = @{ fichier_transcription = "\\192.168.1.20\Affaires\2025-J48\AF_Expert_ASR\transcriptions\accedit-2026-05-28\J48_Enghien_2026-05-28_mono16_16000Hz(wav).csv" }
    $got2 = Resolve-AsrCsvPath -Paths @{ TranscriptionDir = $dir2 } -Infos $infos2
    Assert-Eq (Get-Name $got2) "J48_Enghien_2026-05-28_mono16_16000Hz(wav).csv" "2) actuel : (wav).csv retenu depuis un UNC Windows"
    Assert-True ($got2 -notlike "*(photo)*") "2b) la variante (photo).csv n'est jamais retenue"

    # --------------------------------- 3) sans fichier_transcription : (wav).csv malgre (photo) plus recent
    $infos3 = @{ fichier_transcription = "" }
    $got3 = Resolve-AsrCsvPath -Paths @{ TranscriptionDir = $dir2 } -Infos $infos3
    Assert-Eq (Get-Name $got3) "J48_Enghien_2026-05-28_mono16_16000Hz(wav).csv" "3) sans fichier_transcription : (wav).csv retenu (hors (photo) plus recent)"

    # --------------------------------------------------------------- 4) legacy sans (wav)
    $dir4 = New-CaseDir "legacy_sans_wav"
    [void](New-Csv $dir4 "CAPTATION_mono16_16000Hz.csv" 10)
    [void](New-Csv $dir4 "Sujets.csv" 20)
    $got4 = Resolve-AsrCsvPath -Paths @{ TranscriptionDir = $dir4 } -Infos @{ fichier_transcription = "" }
    Assert-Eq (Get-Name $got4) "CAPTATION_mono16_16000Hz.csv" "4) legacy sans (wav) : toujours accepte"

    # --------------------------------------- 5) part 1 + part 2 sans agrege : erreur explicite
    $dir5 = New-CaseDir "multi_parties"
    [void](New-Csv $dir5 "J48 part 1_mono16_16000Hz(wav).csv" 10)
    [void](New-Csv $dir5 "J48 part 1_mono16_16000Hz(wav)(photo).csv" 11)
    [void](New-Csv $dir5 "J48 part 2_mono16_16000Hz(wav).csv" 12)
    [void](New-Csv $dir5 "Sujets.csv" 20)
    $threw5 = $false
    $message5 = ""
    try { $null = Resolve-AsrCsvPath -Paths @{ TranscriptionDir = $dir5 } -Infos @{ fichier_transcription = "" } }
    catch { $threw5 = $true; $message5 = $_.Exception.Message }
    Assert-True $threw5 "5) multi-parties sans agrege : erreur explicite levee (aucune selection arbitraire)"
    Assert-True ($message5 -like "*multi-parties*") "5b) le message qualifie le cas multi-parties"
    Assert-True (($message5 -like "*part 1*") -and ($message5 -like "*part 2*")) "5c) le message cite les deux candidats"
    Assert-True ($message5 -like "*_complet_*") "5d) le message indique la sortie attendue (CSV agrege)"

    # --------------------------------- 6) fichier_transcription pointant un dossier
    $dir6 = New-CaseDir "dossier_source"
    [void](New-Csv $dir6 "A_mono16_16000Hz(wav).csv" 10)
    [void](New-Csv $dir6 "A_mono16_16000Hz(wav)(photo).csv" 40)
    [void](New-Csv $dir6 "B_mono16_16000Hz(wav).csv" 30)
    $got6 = Resolve-AsrCsvPath -Paths @{ TranscriptionDir = (New-CaseDir "vide_pour_dossier") } -Infos @{ fichier_transcription = $dir6 }
    Assert-Eq (Get-Name $got6) "B_mono16_16000Hz(wav).csv" "6) fichier_transcription = dossier : .csv non (photo) le plus recent"

    # --------------------------- 7) garde-fou : pointeur sur part 1 alors qu un agrege existe
    $dir7 = New-CaseDir "garde_fou_agrege"
    [void](New-Csv $dir7 "J48 part 1_mono16_16000Hz(wav).csv" 10)
    [void](New-Csv $dir7 "J48 part 2_mono16_16000Hz(wav).csv" 12)
    [void](New-Csv $dir7 "J48_complet_mono16_16000Hz.csv" 5)
    $script:CsvWarnings.Clear()
    $infos7 = @{ fichier_transcription = "\\192.168.1.20\Affaires\2025-J48\AF_Expert_ASR\transcriptions\2025-11-20\J48 part 1_mono16_16000Hz(wav).csv" }
    $got7 = Resolve-AsrCsvPath -Paths @{ TranscriptionDir = $dir7 } -Infos $infos7
    Assert-Eq (Get-Name $got7) "J48_complet_mono16_16000Hz.csv" "7) pointeur sur une partie + agrege present : agrege prefere (pas de troncature)"
    Assert-True ($script:CsvWarnings.Count -ge 1) "7b) un avertissement explicite est emis"

    # ------------------------------------------------- 8) basename portable Windows/Linux
    Assert-Eq (Get-CrLeafName "\\192.168.1.20\Affaires\a\b\c.csv") "c.csv" "8) Get-CrLeafName : UNC Windows"
    Assert-Eq (Get-CrLeafName "C:\Affaires\a\b\c.csv") "c.csv" "8b) Get-CrLeafName : chemin Windows"
    Assert-Eq (Get-CrLeafName "/data/Affaires/a/c.csv") "c.csv" "8c) Get-CrLeafName : chemin conteneur"
    Assert-Eq (Get-CrLeafName '"quoted.csv"') "quoted.csv" "8d) Get-CrLeafName : guillemets retires"

    # ------------------------------------------------- 9) mapping Windows/UNC -> conteneur
    Assert-Eq (ConvertTo-ContainerAsrPath "C:\Affaires\2025-J48\AF_Expert_ASR\transcriptions\x") "/data/Affaires/2025-J48/AF_Expert_ASR/transcriptions/x" "9) mapping C:\Affaires"
    Assert-Eq (ConvertTo-ContainerAsrPath "\\192.168.1.20\Affaires\2025-J48\x") "/data/Affaires/2025-J48/x" "9b) mapping UNC NAS"
    Assert-Eq (ConvertTo-ContainerAsrPath "/volume1/Affaires/2025-J48/x") "/data/Affaires/2025-J48/x" "9c) mapping /volume1"
    Assert-Eq (ConvertTo-ContainerAsrPath "/data/jobs/x") "/data/jobs/x" "9d) chemin inconnu inchange"
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ("checks=" + $script:Checks + " failures=" + $script:Failures)
if ($script:Failures -gt 0) { throw ("ECHEC resolve_asr_csv : " + $script:Failures + " assertion(s) en erreur") }
"OK resolve_asr_csv"