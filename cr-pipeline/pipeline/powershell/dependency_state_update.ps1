param(
  [Parameter(Mandatory=$true)][string] $CsvPath,
  [Parameter(Mandatory=$true)][string] $OutDir,
  [string] $CsvDebriefPath="", [string] $ContextJsonPath="", [string] $SujetsPath="", [string] $ParticipantsPath="",
  [string] $Provider="openai", [string] $ModelPass1="", [string] $ModelDebrief="", [string] $ModelReport="",
  [string] $ModelPass2E="", [string] $ModelPass3="", [string] $ModelPass3E="",
  [string] $ModelPass3A="", [string] $ModelPass3B="", [string] $ModelPass3C="", [string] $ModelPass3D="",
  [string] $Preset="equilibre", [int] $Pass2BatchSize=2, [int] $Pass2BPromptCharsLimit=20000,
  [int] $Pass2BEstimatedTokensLimit=5500, [int] $MaxSegmentSeconds=600, [int] $MaxAsrGapSeconds=120,
  [switch] $PseudonymizeRemote, [string] $PseudoJobId="", [string] $RenderUrl=""
)
$module=Join-Path $PSScriptRoot "dependency_plan.psm1";$pipeline=Join-Path $PSScriptRoot "cr_reunion_point_mumerotes_pipeline_json.ps1"
Import-Module $module -Force
$version=(Get-FileHash -LiteralPath $pipeline -Algorithm SHA256).Hash
$parameters=@{pipeline_schema="dependency-state-v1";provider=$Provider;model_pass1=$ModelPass1;model_debrief=$ModelDebrief;model_report=$ModelReport;model_pass2e=$ModelPass2E;model_pass3=$ModelPass3;model_pass3e=$ModelPass3E;model_pass3a=$ModelPass3A;model_pass3b=$ModelPass3B;model_pass3c=$ModelPass3C;model_pass3d=$ModelPass3D;preset=$Preset;pass2_batch_size=$Pass2BatchSize;pass2b_prompt_chars_limit=$Pass2BPromptCharsLimit;pass2b_estimated_tokens_limit=$Pass2BEstimatedTokensLimit;max_segment_seconds=$MaxSegmentSeconds;max_asr_gap_seconds=$MaxAsrGapSeconds;pseudonymize_remote=[bool]$PseudonymizeRemote;pseudo_job_id=$PseudoJobId;render_url=$RenderUrl}
$path=Update-CrDeliveryDependencyState -CsvPath $CsvPath -OutDir $OutDir -CsvDebriefPath $CsvDebriefPath -ContextJsonPath $ContextJsonPath -SujetsPath $SujetsPath -ParticipantsPath $ParticipantsPath -PipelineVersion $version -Parameters $parameters
if($path){Write-Host "État SHA256 livraison mis à jour → $path"}else{Write-Warning "État SHA256 livraison non mis à jour: manifest compatible absent."}
