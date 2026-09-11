$ErrorActionPreference = 'Stop'

# Autotest deterministe du plan 6G (aucun pipeline, aucun LLM, aucun HTTP).
$repoRoot = Split-Path -Parent $PSScriptRoot
$pipelinePath = Join-Path $repoRoot 'cr-pipeline/pipeline/powershell/cr_refere_preventif_pipeline_json.ps1'
if (-not (Test-Path -LiteralPath $pipelinePath -PathType Leaf)) { throw "pipeline introuvable : $pipelinePath" }
$scriptText = [System.IO.File]::ReadAllText($pipelinePath, [System.Text.Encoding]::UTF8)
$orchestratorPath = Join-Path $repoRoot 'cr-pipeline/pipeline/powershell/refere_production_orchestrator.ps1'
$orchestratorText = [System.IO.File]::ReadAllText($orchestratorPath, [System.Text.Encoding]::UTF8)

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

$definitions = @()
foreach ($name in @('ConvertTo-HashtableDeep', 'Read-JsonFile', 'Get-Pass2B2FHierarchicalBatchPlan', 'New-Pass2B2FHierarchicalGroupPlans')) {
  $definitions += Import-PipelineFunction -Text $scriptText -Name $name
}
Invoke-Expression ($definitions -join "`n")

$script:Checks = 0
$script:Failures = 0
function Assert-True {
  param([bool] $Condition, [string] $Message)
  $script:Checks++
  if ($Condition) { Write-Host ('OK   ' + $Message) }
  else { $script:Failures++; Write-Host ('KO   ' + $Message) }
}
function Assert-Sequence {
  param([object[]] $Actual, [object[]] $Expected, [string] $Message)
  $a = @($Actual | ForEach-Object { [string]$_ }) -join ','
  $e = @($Expected | ForEach-Object { [string]$_ }) -join ','
  Assert-True ($a -ceq $e) ($Message + ' [attendu=' + $e + ' obtenu=' + $a + ']')
}
function Assert-ThrowsLike {
  param([scriptblock] $Action, [string] $Pattern, [string] $Message)
  $threw = $false
  $errorMessage = ''
  try { & $Action } catch { $threw = $true; $errorMessage = $_.Exception.Message }
  Assert-True ($threw -and $errorMessage -like $Pattern) ($Message + ' [erreur=' + $errorMessage + ']')
}
function Get-FlattenedBatches {
  param([object[]] $Plans)
  return @($Plans | ForEach-Object { @($_.batch_nums) })
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('pass2b2f_6g_test_' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $root -Force)
function New-BatchCase {
  param(
    [string] $Name,
    [int[]] $Selected,
    [int[]] $Files,
    [Nullable[int]] $ExpectedBatches = $null,
    [int[]] $EntryIndices = @()
  )
  $caseDir = Join-Path $root $Name
  $parsedDir = Join-Path $caseDir 'parsed_outputs'
  [void](New-Item -ItemType Directory -Path $parsedDir -Force)
  foreach ($idx in @($Files)) {
    $file = Join-Path $parsedDir ('batch_' + ('{0:D2}' -f $idx) + '_response.json')
    [System.IO.File]::WriteAllText($file, '{}', (New-Object System.Text.UTF8Encoding($false)))
  }
  $entries = @($EntryIndices | ForEach-Object { @{ batch_index = [int]$_; tag = 'batch_' + ('{0:D2}' -f $_) } })
  $doc = @{ selected_batches = @($Selected); entries = @($entries) }
  if ($null -ne $ExpectedBatches) { $doc['expected_batches'] = [int]$ExpectedBatches }
  $entriesPath = Join-Path $caseDir 'entries.json'
  [System.IO.File]::WriteAllText($entriesPath, ($doc | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
  return @{ parsed = $parsedDir; entries = $entriesPath }
}

try {
  $plans15 = @(New-Pass2B2FHierarchicalGroupPlans -BatchNums @(1..15))
  Assert-True ($plans15.Count -eq 6) 'N=15 : exactement 6 groupes'
  Assert-Sequence (Get-FlattenedBatches $plans15) @(1..15) 'N=15 : union chronologique exacte, sans trou ni doublon'
  Assert-Sequence @($plans15 | ForEach-Object { @($_.batch_nums).Count }) @(3,3,3,2,2,2) 'N=15 : groupes equilibres'

  $plans36 = @(New-Pass2B2FHierarchicalGroupPlans -BatchNums @(1..36))
  $ranges36 = @($plans36 | ForEach-Object { ([string]@($_.batch_nums)[0]) + '-' + ([string]@($_.batch_nums)[-1]) })
  Assert-Sequence $ranges36 @('1-6','7-9','10-16','17-22','23-29','30-36') 'N=36 : plages historiques strictement preservees'
  Assert-Sequence (Get-FlattenedBatches $plans36) @(1..36) 'N=36 : chaque batch consomme exactement une fois'

  $plans37 = @(New-Pass2B2FHierarchicalGroupPlans -BatchNums @(1..37))
  Assert-True ($plans37.Count -eq 6) 'N=37 : exactement 6 groupes'
  Assert-Sequence (Get-FlattenedBatches $plans37) @(1..37) 'N=37 : chaque batch consomme exactement une fois'

  Assert-ThrowsLike { New-Pass2B2FHierarchicalGroupPlans -BatchNums @(1..5) } '*au moins 6 batches*recu=5*' 'N=5 : erreur explicite, aucun groupe vide'

  $case15 = New-BatchCase -Name 'fifteen' -Selected @(1..15) -Files @(1..15) -ExpectedBatches 15 -EntryIndices @(1..15)
  $batchPlan15 = Get-Pass2B2FHierarchicalBatchPlan -BatchOutputsDir $case15.parsed -BatchEntriesJsonPath $case15.entries -LotLabel 'TEST'
  Assert-Sequence @($batchPlan15.batch_nums) @(1..15) 'entries selected_batches=1..15 : liste autoritaire respectee'
  Assert-True ($batchPlan15.source -eq 'entries.json:selected_batches') 'selected_batches est la source prioritaire'
  Assert-True (16 -notin @($batchPlan15.batch_nums)) 'aucune recherche ni attente de batch_16_response.json'

  $filesWithout14 = @(1..15 | Where-Object { $_ -ne 14 })
  $caseMissing14 = New-BatchCase -Name 'missing14' -Selected @(1..15) -Files $filesWithout14 -ExpectedBatches 15 -EntryIndices @(1..15)
  Assert-ThrowsLike { Get-Pass2B2FHierarchicalBatchPlan -BatchOutputsDir $caseMissing14.parsed -BatchEntriesJsonPath $caseMissing14.entries -LotLabel 'TEST' } '*fichiers absents=batch 14*' 'batch_14 absent : erreur explicite nommant batch 14'

  $caseCountMismatch = New-BatchCase -Name 'count_mismatch' -Selected @() -Files @(1..14) -ExpectedBatches 15 -EntryIndices @(1..14)
  Assert-ThrowsLike { Get-Pass2B2FHierarchicalBatchPlan -BatchOutputsDir $caseCountMismatch.parsed -BatchEntriesJsonPath $caseCountMismatch.entries -LotLabel 'TEST' } '*expected_batches=15*batches autoritaires=14*' 'expected_batches=15 mais seulement 14 batches : erreur de coherence'

  $caseDerived = New-BatchCase -Name 'derived_entries' -Selected @() -Files @(1..6) -EntryIndices @(1..6)
  $derivedPlan = Get-Pass2B2FHierarchicalBatchPlan -BatchOutputsDir $caseDerived.parsed -BatchEntriesJsonPath $caseDerived.entries -LotLabel 'TEST'
  Assert-Sequence @($derivedPlan.batch_nums) @(1..6) 'selected_batches absent : indices derives des entries'
  Assert-True ($derivedPlan.source -eq 'entries.json:entries') 'entries disponibles precedent le fallback disque'

  $fallbackDir = Join-Path $root 'disk_fallback/parsed_outputs'
  [void](New-Item -ItemType Directory -Path $fallbackDir -Force)
  foreach ($idx in @(1..6)) {
    $file = Join-Path $fallbackDir ('batch_' + ('{0:D2}' -f $idx) + '_response.json')
    [System.IO.File]::WriteAllText($file, '{}', (New-Object System.Text.UTF8Encoding($false)))
  }
  $fallbackPlan = Get-Pass2B2FHierarchicalBatchPlan -BatchOutputsDir $fallbackDir -LotLabel 'TEST'
  Assert-Sequence @($fallbackPlan.batch_nums) @(1..6) 'entries.json absent : enumeration disque en fallback'
  Assert-True ($fallbackPlan.source -eq 'parsed_outputs') 'le fallback disque est identifie explicitement'

  Assert-True ($orchestratorText -notmatch 'Add-RefereProgressCalls\s+-Llm\s+7\s+-Http\s+7') 'compteurs 6G : aucun ajout anticipe de 7 appels'
  Assert-True ($scriptText -match '\$script:RefereProgress\.llm_calls\+\+[\s\S]+Invoke-LLM-OpenAICompat') 'compteurs 6G : increment au point de tentative de chaque appel reel'
}
finally {
  Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ('checks=' + $script:Checks + ' failures=' + $script:Failures)
if ($script:Failures -gt 0) { throw ('ECHEC pass2b2f_hierarchical_batches : ' + $script:Failures + ' assertion(s) en erreur') }
'OK pass2b2f_hierarchical_batches'
