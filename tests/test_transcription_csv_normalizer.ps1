$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$pipelinePath = Join-Path $repoRoot "cr-pipeline/pipeline/powershell/cr_reunion_point_mumerotes_pipeline_json.ps1"
$fixtures = Join-Path $PSScriptRoot "fixtures/transcription_csv"
$scriptText = [System.IO.File]::ReadAllText($pipelinePath, [System.Text.Encoding]::UTF8)

function Import-PipelineFunction {
  param([string]$Text, [string]$Name)
  $marker = "function " + $Name + " {"
  $start = $Text.IndexOf($marker)
  if ($start -lt 0) { throw "Fonction introuvable: $Name" }
  $braceStart = $Text.IndexOf("{", $start)
  $depth = 0
  for ($i = $braceStart; $i -lt $Text.Length; $i++) {
    if ($Text[$i] -eq "{") { $depth++ }
    elseif ($Text[$i] -eq "}") {
      $depth--
      if ($depth -eq 0) { return $Text.Substring($start, $i - $start + 1) }
    }
  }
  throw "Fin de fonction introuvable: $Name"
}

$definitions = @(
  Import-PipelineFunction $scriptText "Convert-TranscriptionTimestampToSeconds"
  Import-PipelineFunction $scriptText "Read-NormalizedTranscriptionCsv"
  Import-PipelineFunction $scriptText "Convert-SecondsToHms"
  Import-PipelineFunction $scriptText "Get-IntelligentSegments"
)
Invoke-Expression ($definitions -join "`n")

$script:Checks = 0
function Assert-True([bool]$Condition, [string]$Message) {
  $script:Checks++
  if (-not $Condition) { throw "ECHEC: $Message" }
  Write-Host "OK   $Message"
}
function Assert-Eq($Actual, $Expected, [string]$Message) {
  Assert-True ($Actual -eq $Expected) "$Message [attendu=$Expected obtenu=$Actual]"
}
function Assert-ThrowsLike([scriptblock]$Action, [string]$Pattern, [string]$Message) {
  $caught = ""
  try { & $Action } catch { $caught = $_.Exception.Message }
  Assert-True ($caught -like $Pattern) "$Message [message=$caught]"
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cr_csv_normalizer_" + [guid]::NewGuid().ToString("N"))
[void](New-Item -ItemType Directory -Path $tempRoot)
try {
  $voxEnd = Read-NormalizedTranscriptionCsv (Join-Path $fixtures "voxtral_with_end.csv")
  Assert-Eq $voxEnd.Format "voxtral" "Voxtral avec end détecté"
  Assert-True $voxEnd.HasEnd "end conservé lorsqu'il existe"
  Assert-Eq $voxEnd.Rows[0].start "0" "start Voxtral préservé"
  Assert-Eq $voxEnd.Rows[0].end "4.5" "end Voxtral préservé"
  Assert-Eq $voxEnd.Rows[0].confidence "0.98" "colonne Voxtral supplémentaire préservée"

  $voxNoEnd = Read-NormalizedTranscriptionCsv (Join-Path $fixtures "voxtral_without_end.csv")
  Assert-True (-not $voxNoEnd.HasEnd) "Voxtral sans end accepté"
  Assert-True ($null -eq $voxNoEnd.Rows[0].PSObject.Properties['end']) "aucun end artificiel pour Voxtral"

  $noota = Read-NormalizedTranscriptionCsv (Join-Path $fixtures "noota_valid.csv")
  Assert-Eq $noota.Format "noota" "Noota.io détecté"
  Assert-Eq $noota.Rows[0].start 62 "HH:MM:SS Noota converti directement en secondes"
  Assert-Eq $noota.Rows[2].start 3723 "durée Noota supérieure à une heure"
  Assert-Eq $noota.Rows[0].speaker "Élodie" "locuteur et accents conservés"
  Assert-Eq $noota.Rows[0].text "Texte cité; avec point-virgule et accents" "champ CSV cité conservé"
  Assert-Eq $noota.Rows[0].note "n°1" "colonne Noota supplémentaire conservée"
  Assert-True ($null -eq $noota.Rows[0].PSObject.Properties['end']) "aucun end artificiel pour Noota"

  $ordered = @($noota.Rows | ForEach-Object {
    $_ | Add-Member __sec ([double]$_.start) -Force
    $_ | Add-Member __end_sec ([double]$_.start) -Force
    $_
  } | Sort-Object __sec)
  $segments = Get-IntelligentSegments -rows $ordered -colTime start -colSpeaker speaker -colText text -logPath (Join-Path $tempRoot "segments.log") -ChunkSize 25
  Assert-Eq $ordered[0].speaker "André" "ordre temporel normalisé exploitable par la segmentation"
  Assert-True (@($segments).Count -gt 0) "segmentation synthétique Noota produite sans LLM"

  $voxOrdered = @($voxNoEnd.Rows | ForEach-Object {
    $_ | Add-Member __sec ([double]$_.start) -Force
    $_ | Add-Member __end_sec ([double]$_.start) -Force
    $_
  } | Sort-Object __sec)
  $voxSegments = Get-IntelligentSegments -rows $voxOrdered -colTime start -colSpeaker speaker -colText text -logPath (Join-Path $tempRoot "vox_segments.log") -ChunkSize 25
  Assert-Eq @($voxSegments).Count 2 "les deux lignes Voxtral traversent la segmentation historique"
  Assert-Eq $voxSegments[0][0].speaker "Alice" "ordre Voxtral conservé après tri historique"

  $badCases = @(
    @{ Name="empty.csv"; Content=""; Pattern="*CSV vide*" },
    @{ Name="header_only.csv"; Content="start;speaker;text`n"; Pattern="*sans ligne*" },
    @{ Name="comma.csv"; Content="start,speaker,text`n0,Alice,Texte`n"; Pattern="*Séparateur CSV incompatible*" },
    @{ Name="schema.csv"; Content="time;who;words`n0;Alice;Texte`n"; Pattern="*Schéma CSV incompatible*" },
    @{ Name="invalid_noota.csv"; Content="horodatage;locuteur;texte`n00:61:00;Alice;Texte`n"; Pattern="*Horodatage Noota.io invalide*" },
    @{ Name="absolute.csv"; Content="horodatage;locuteur;texte`n2026-10-12 09:30:00;Alice;Texte`n"; Pattern="*Horodatage absolu non pris en charge*" }
  )
  foreach ($case in $badCases) {
    $path = Join-Path $tempRoot $case.Name
    [System.IO.File]::WriteAllText($path, $case.Content, (New-Object System.Text.UTF8Encoding($false)))
    Assert-ThrowsLike { Read-NormalizedTranscriptionCsv $path } $case.Pattern $case.Name
  }

  $validateOut = Join-Path $tempRoot "business-output-must-not-exist"
  $validateOutput = & pwsh -NoLogo -NoProfile -File $pipelinePath -CsvPath (Join-Path $fixtures "noota_valid.csv") -OutDir $validateOut -ValidateCsvOnly 2>&1
  Assert-Eq $LASTEXITCODE 0 "ValidateCsvOnly retourne le code succès"
  Assert-True (-not (Test-Path -LiteralPath $validateOut)) "ValidateCsvOnly n'écrit aucun répertoire métier"
  Assert-True (($validateOutput -join "`n") -match '"format":\s*"noota"') "ValidateCsvOnly affiche le format détecté"
}
finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "OK normaliseur transcription: $script:Checks vérifications"
