param(
  [Parameter(Mandatory=$true)] [string] $DependencyModulePath,
  [Parameter(Mandatory=$true)] [string] $CandidatePipelinePath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Equal {
  param([object] $Actual, [object] $Expected, [string] $Label)
  if ([string]$Actual -ne [string]$Expected) {
    throw "$Label : attendu='$Expected', obtenu='$Actual'"
  }
}

function Write-Utf8Text {
  param([string] $Path, [string] $Text)
  $parent = Split-Path -Parent $Path
  if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
  [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Get-Pass2EDecision {
  param([object[]] $Plan)
  return @($Plan | Where-Object { $_.name -eq 'Pass2E' }) | Select-Object -First 1
}

$moduleResolved = (Resolve-Path -LiteralPath $DependencyModulePath).Path
$candidateResolved = (Resolve-Path -LiteralPath $CandidatePipelinePath).Path
Import-Module $moduleResolved -Force

$candidateSource = Get-Content -LiteralPath $candidateResolved -Raw -Encoding UTF8
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($candidateSource, [ref]$tokens, [ref]$parseErrors)
if (@($parseErrors).Count -gt 0) { throw "Script candidat non analysable." }
$guardAst = $ast.Find({
  param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Assert-TargetedSubjectReuseCompatible'
}, $true)
if (-not $guardAst) { throw "Protection Assert-TargetedSubjectReuseCompatible introuvable." }
. ([ScriptBlock]::Create($guardAst.Extent.Text))

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixtureRoot = Join-Path $tempRoot ("cr_phase1_dependency_" + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null

try {
  $outDir = Join-Path $fixtureRoot 'out'
  [IO.Directory]::CreateDirectory($outDir) | Out-Null
  $csv = Join-Path $fixtureRoot 'transcription.csv'
  $debriefCsv = Join-Path $fixtureRoot 'debrief.csv'
  $context = Join-Path $fixtureRoot 'context.json'
  $subjectsXlsx = Join-Path $fixtureRoot 'Sujets.xlsx'
  $participantsXlsx = Join-Path $fixtureRoot 'Participants.xlsx'

  Write-Utf8Text $csv "speaker,text`nP1,Test"
  Write-Utf8Text $debriefCsv "speaker,text`nP1,Debrief"
  Write-Utf8Text $context '{"affaire":"fixture"}'
  Write-Utf8Text $subjectsXlsx 'fixture-xlsx-subjects'
  Write-Utf8Text $participantsXlsx 'fixture-xlsx-participants'
  Write-Utf8Text (Join-Path $outDir 'segments/segment_001.json') '{"segment_id":"001"}'
  Write-Utf8Text (Join-Path $outDir 'debrief.json') '{}'
  Write-Utf8Text (Join-Path $outDir 'global.json') '{"sujets":[]}'
  Write-Utf8Text (Join-Path $outDir 'global_meeting.json') '{}'
  Write-Utf8Text (Join-Path $outDir 'pass2B_batches/pass2B_batch_01.json') '{}'
  Write-Utf8Text (Join-Path $outDir 'sujets_ref.json') '[]'
  Write-Utf8Text (Join-Path $outDir 'sujets/sujet_001.json') '{"numero":1}'
  Write-Utf8Text (Join-Path $outDir 'pass2E_sujets_compact/sujet_001_compact.json') '{"numero":1,"synthese_intermediaire":{}}'

  $parameters = @{
    pipeline_schema = 'dependency-state-v1'
    provider = 'fixture'
    model_pass1 = 'fixture'
    model_debrief = 'fixture'
    model_report = 'fixture'
    model_pass2e = 'fixture'
    pass2_batch_size = 2
  }
  $common = @{
    CsvPath = $csv
    OutDir = $outDir
    CsvDebriefPath = $debriefCsv
    ContextJsonPath = $context
    SujetsPath = $subjectsXlsx
    ParticipantsPath = $participantsXlsx
    Parameters = $parameters
  }

  $versionOne = 'PIPELINE_VERSION_FIXTURE_V1'
  $versionTwo = 'PIPELINE_VERSION_FIXTURE_V2'
  Write-CrDependencyState @common -PipelineVersion $versionOne | Out-Null

  $samePlan = @(Get-CrDependencyPlan @common -PipelineVersion $versionOne)
  $samePass2E = Get-Pass2EDecision $samePlan
  Assert-Equal $samePass2E.action 'REUSE' 'Version inchangée / Pass2E'
  $sameByName = @{}; foreach ($item in $samePlan) { $sameByName[[string]$item.name] = $item }
  Assert-TargetedSubjectReuseCompatible -TargetedSubjectResume $true -PlanByName $sameByName

  $changedPlan = @(Get-CrDependencyPlan @common -PipelineVersion $versionTwo)
  $changedPass2E = Get-Pass2EDecision $changedPlan
  Assert-Equal $changedPass2E.action 'REBUILD' 'Version différente / Pass2E'
  $changedRejected = $false
  try {
    $changedByName = @{}; foreach ($item in $changedPlan) { $changedByName[[string]$item.name] = $item }
    Assert-TargetedSubjectReuseCompatible -TargetedSubjectResume $true -PlanByName $changedByName
  } catch {
    $changedRejected = ($_.Exception.Message -like '*REPRISE_SUJETS_INCOMPATIBLE*')
  }
  Assert-Equal $changedRejected $true 'Protection version différente'

  Remove-Item -LiteralPath (Join-Path $outDir 'dependency_state.json') -Force
  $missingPlan = @(Get-CrDependencyPlan @common -PipelineVersion $versionOne)
  $missingPass2E = Get-Pass2EDecision $missingPlan
  Assert-Equal $missingPass2E.action 'REBUILD' 'Manifest absent / Pass2E'
  $missingRejected = $false
  try {
    $missingByName = @{}; foreach ($item in $missingPlan) { $missingByName[[string]$item.name] = $item }
    Assert-TargetedSubjectReuseCompatible -TargetedSubjectResume $true -PlanByName $missingByName
  } catch {
    $missingRejected = ($_.Exception.Message -like '*REPRISE_SUJETS_INCOMPATIBLE*')
  }
  Assert-Equal $missingRejected $true 'Protection manifest absent'

  Write-Utf8Text (Join-Path $outDir 'dependency_state.json') '{"schema_version":999,"passes":{}}'
  $invalidPlan = @(Get-CrDependencyPlan @common -PipelineVersion $versionOne)
  $invalidPass2E = Get-Pass2EDecision $invalidPlan
  Assert-Equal $invalidPass2E.action 'REBUILD' 'Manifest invalide / Pass2E'
  $invalidRejected = $false
  try {
    $invalidByName = @{}; foreach ($item in $invalidPlan) { $invalidByName[[string]$item.name] = $item }
    Assert-TargetedSubjectReuseCompatible -TargetedSubjectResume $true -PlanByName $invalidByName
  } catch {
    $invalidRejected = ($_.Exception.Message -like '*REPRISE_SUJETS_INCOMPATIBLE*')
  }
  Assert-Equal $invalidRejected $true 'Protection manifest invalide'

  [pscustomobject]@{
    module_path = $moduleResolved
    compatible = [pscustomobject]@{ action=$samePass2E.action; reason=$samePass2E.reason; guard='ACCEPTED' }
    changed_version = [pscustomobject]@{ action=$changedPass2E.action; reason=$changedPass2E.reason; guard='REJECTED' }
    missing_manifest = [pscustomobject]@{ action=$missingPass2E.action; reason=$missingPass2E.reason; guard='REJECTED' }
    invalid_manifest = [pscustomobject]@{ action=$invalidPass2E.action; reason=$invalidPass2E.reason; guard='REJECTED' }
  } | ConvertTo-Json -Depth 10
}
finally {
  $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
  if (-not $resolvedFixture.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
      -not ([IO.Path]::GetFileName($resolvedFixture)).StartsWith('cr_phase1_dependency_')) {
    throw "Refus de nettoyer un chemin temporaire inattendu: $resolvedFixture"
  }
  if (Test-Path -LiteralPath $resolvedFixture) {
    Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
  }
}
