param([string] $ModulePath = "")

$ErrorActionPreference = "Stop"
if (-not $ModulePath) { $ModulePath = Join-Path (Split-Path $PSScriptRoot -Parent) "cr-pipeline/pipeline/powershell/dependency_plan.psm1" }
Import-Module $ModulePath -Force

function Assert-Equal($Expected,$Actual,[string]$Message){if($Expected-ne$Actual){throw "$Message (attendu=$Expected, obtenu=$Actual)"}}
function Write-TestFile([string]$Path,[string]$Content='{}'){$parent=Split-Path $Path -Parent;if($parent){New-Item -ItemType Directory -Force -Path $parent|Out-Null};[IO.File]::WriteAllText($Path,$Content,[Text.UTF8Encoding]::new($false))}
function Set-TestTime([string]$Path,[datetime]$Time){(Get-Item -LiteralPath $Path).LastWriteTimeUtc=$Time}

$root=Join-Path ([IO.Path]::GetTempPath()) ("cr-sha-test-"+[guid]::NewGuid().ToString("N"))
try{
  $inputs=Join-Path $root "inputs";$out=Join-Path $root "out/job_test"
  $csv=Join-Path $inputs "transcription.csv";$debrief=Join-Path $inputs "debrief_global.csv";$context=Join-Path $inputs "context.json";$subjects=Join-Path $inputs "Sujets.xlsx";$participants=Join-Path $inputs "Participants.xlsx"
  $sourceFiles=@($csv,$debrief,$context,$subjects,$participants)
  $outputFiles=@(
    "segments/segment_01.json","debrief.json","global.json","pass2B_batches/pass2B_batch_01.json","global_meeting.json",
    "sujets_ref.json","sujets/sujet_001.json","pass2E_sujets_compact/sujet_001_compact.json",
    "pass3E_sujets/sujet_001_synthese.json","global_by_sujet.json","global_final.json","global_final_depseudonymized_for_docx.json"
  )
  $docx=Join-Path $out "compte_rendu_test.docx"
  $params=@{pipeline_schema="dependency-state-v1";provider="openai";model_pass1="p1";model_debrief="d";model_report="p2b";model_pass2e="p2e";model_pass3="p3";model_pass3e="p3e";model_pass3a="a";model_pass3b="b";model_pass3c="c";model_pass3d="d";preset="equilibre";pass2_batch_size=2;pass2b_prompt_chars_limit=20000;pass2b_estimated_tokens_limit=5500;max_segment_seconds=600;max_asr_gap_seconds=120;pseudonymize_remote=$true;pseudo_job_id="job";render_url="render"}
  $version="pipeline-v1"

  function Reset-Fixture {
    foreach($path in $sourceFiles){Write-TestFile $path ("source:"+(Split-Path $path -Leaf))}
    foreach($relative in $outputFiles){Write-TestFile (Join-Path $out $relative) ("{`"file`":`"$relative`"}")}
    Write-TestFile $docx "docx"
    $old=[datetime]::UtcNow.AddHours(-2);$new=[datetime]::UtcNow.AddHours(-1)
    foreach($path in $sourceFiles){Set-TestTime $path $old};foreach($relative in $outputFiles){Set-TestTime (Join-Path $out $relative) $new};Set-TestTime $docx $new
    Write-CrDependencyState -CsvPath $csv -OutDir $out -CsvDebriefPath $debrief -ContextJsonPath $context -SujetsPath $subjects -ParticipantsPath $participants -PipelineVersion $version -Parameters $params | Out-Null
  }
  function Get-Plan([string]$PlanVersion=$version){return @(Get-CrDependencyPlan -CsvPath $csv -OutDir $out -CsvDebriefPath $debrief -ContextJsonPath $context -SujetsPath $subjects -ParticipantsPath $participants -PipelineVersion $PlanVersion -Parameters $params)}
  function By-Name([object[]]$Plan){$map=@{};foreach($item in $Plan){$map[$item.name]=$item};return $map}

  Reset-Fixture
  $savedState=Get-Content -LiteralPath (Join-Path $out "dependency_state.json") -Raw|ConvertFrom-Json
  Assert-Equal 1 @($savedState.passes.Pass2B.batches).Count "Pass2B doit enregistrer l'identité de chaque batch"
  Assert-Equal 1 @($savedState.passes.Pass2B.batches[0].inputs|Where-Object{$_.logical_path -like 'segments/*'}).Count "le batch Pass2B doit référencer ses segments réels"
  foreach($item in @(Get-Plan)){Assert-Equal "REUSE" $item.action ("état initial: "+$item.name)}

  # Contenu modifié avec mtime conservé: SHA doit gagner sur mtime.
  Reset-Fixture;$savedTime=(Get-Item $debrief).LastWriteTimeUtc;Write-TestFile $debrief "debrief modifié";Set-TestTime $debrief $savedTime
  $map=By-Name (Get-Plan)
  Assert-Equal "REUSE" $map["Pass1 segments"].action "le débrief ne doit pas invalider Pass1"
  Assert-Equal "REBUILD" $map["Pass1B"].action "le SHA du débrief doit invalider Pass1B"
  Assert-Equal "REUSE" $map["Pass2B"].action "Pass2B doit rester indépendante du débrief"
  foreach($name in @("Pass2A","split sujets","Pass2E","Pass3E","global_by_sujet","Pass3A-D","global_final","JSON depseudonymized","DOCX")){Assert-Equal "REBUILD" $map[$name].action ("propagation débrief: "+$name)}

  # Mtime modifié, contenu identique: réutilisation permise par SHA.
  Reset-Fixture;Set-TestTime $context ([datetime]::UtcNow)
  $map=By-Name (Get-Plan)
  Assert-Equal "REUSE" $map["Pass1 segments"].action "un contexte identique malgré un mtime récent doit être réutilisé"
  Assert-Equal "REUSE" $map["Pass2B"].action "Pass2B doit ignorer un simple changement de mtime"

  # Une collection change sans changement de mtime.
  Reset-Fixture;$segment=Join-Path $out "segments/segment_01.json";$savedTime=(Get-Item $segment).LastWriteTimeUtc;Write-TestFile $segment '{"changed":true}';Set-TestTime $segment $savedTime
  $map=By-Name (Get-Plan)
  Assert-Equal "REBUILD" $map["Pass1 segments"].action "une sortie Pass1 corrompue/modifiée doit être détectée"
  Assert-Equal "REBUILD" $map["Pass2B"].action "une collection segments modifiée doit invalider Pass2B"

  # Manifest absent: aucune compatibilité inventée.
  Reset-Fixture;Remove-Item -LiteralPath (Join-Path $out "dependency_state.json") -Force
  $map=By-Name (Get-Plan)
  Assert-Equal "REBUILD" $map["Pass1 segments"].action "manifest absent"
  Assert-Equal "dependency manifest absent" $map["Pass1 segments"].reason "raison manifest absent"
  Assert-Equal "REBUILD" $map["Pass1B"].action "Pass1B sans preuve"

  # Sortie JSON invalide et changement de version.
  Reset-Fixture;Write-TestFile (Join-Path $out "debrief.json") "not-json"
  $map=By-Name (Get-Plan);Assert-Equal "REBUILD" $map["Pass1B"].action "sortie corrompue"
  Reset-Fixture;$map=By-Name (Get-Plan "pipeline-v2");Assert-Equal "REBUILD" $map["Pass1 segments"].action "version pipeline différente";Assert-Equal "version pipeline différente" $map["Pass1 segments"].reason "raison version"

  Write-Host "OK: tests SHA256 du graphe de dépendances"
}finally{if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
