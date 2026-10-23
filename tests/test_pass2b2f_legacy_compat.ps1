$ErrorActionPreference = 'Stop'

# Autotest deterministe de compatibilite Pass2B_2F historique.

$repoRoot = Split-Path -Parent $PSScriptRoot
$pipelinePath = [string]$env:CR_REFERE_PIPELINE_PS1
if (-not $pipelinePath) { $pipelinePath = Join-Path $repoRoot 'cr-pipeline/pipeline/powershell/cr_refere_preventif_pipeline_json.ps1' }
if (-not (Test-Path -LiteralPath $pipelinePath -PathType Leaf)) { throw ('pipeline introuvable : ' + $pipelinePath) }
$scriptText = [System.IO.File]::ReadAllText($pipelinePath, [System.Text.Encoding]::UTF8)

function Import-PipelineFunction {
  param([string] $Text, [string] $Name)
  $marker = 'function ' + $Name + ' {'
  $start = $Text.IndexOf($marker)
  if ($start -lt 0) { throw ('fonction introuvable dans le pipeline : ' + $Name) }
  $braceStart = $Text.IndexOf('{', $start)
  $depth = 0
  $end = -1
  for ($i = $braceStart; $i -lt $Text.Length; $i++) {
    if ($Text[$i] -eq '{') { $depth++ }
    elseif ($Text[$i] -eq '}') { $depth--; if ($depth -eq 0) { $end = $i; break } }
  }
  if ($end -lt 0) { throw ('fin de fonction introuvable : ' + $Name) }
  return $Text.Substring($start, $end - $start + 1)
}

$functionNames = @(
  'Get-CrProp', 'Get-CrPropString', 'Test-Pass2B2FLegacySubjectMap',
  'ConvertTo-Pass2B2FCompactSegment'
)
$definitions = @()
foreach ($name in $functionNames) { $definitions += (Import-PipelineFunction -Text $scriptText -Name $name) }
Invoke-Expression ($definitions -join [Environment]::NewLine)

$script:Checks = 0
$script:Failures = 0
function Assert-True {
  param([bool] $Condition, [string] $Message)
  $script:Checks++
  if ($Condition) { Write-Host ('OK   ' + $Message) }
  else { $script:Failures++; Write-Host ('KO   ' + $Message) }
}
function Assert-Eq {
  param($Actual, $Expected, [string] $Message)
  Assert-True ($Actual -eq $Expected) ($Message + ' [attendu=' + [string]$Expected + ' obtenu=' + [string]$Actual + ']')
}

$segArray = @{
  segment_id='segment_test'; start_sec=0; end_sec=10
  sujets=@{}
  llm_analysis=@{ sujets=@(@{ titre='11 - Sujet voisin'; interventions=@(@{ texte='propos'; timecode='00:00:01'; auteur='A' }) }) }
}
$u = ConvertTo-Pass2B2FCompactSegment -Segment $segArray
Assert-True (@($u.sujets_detectes) -contains '11') 'sujets llm_analysis tableau normalises'
Assert-Eq (@($u.points_cles).Count) 1 'points llm_analysis tableau conserves'

$segDict = @{
  segment_id='segment_dict'; start_sec=0; end_sec=10
  sujets=@{ '6'=@(@{ texte='ancien format'; timecode='00:00:02'; auteur='B' }) }
  llm_analysis=@{ sujets=@() }
}
$u = ConvertTo-Pass2B2FCompactSegment -Segment $segDict
Assert-True (@($u.sujets_detectes) -contains '6') 'format dictionnaire historique preserve'

Write-Host ('RESULT legacy_compat checks=' + $script:Checks + ' failures=' + $script:Failures)
if ($script:Failures -gt 0) { exit 1 }
