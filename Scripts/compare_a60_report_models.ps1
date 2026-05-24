param(
  [string] $AdapterPath = "C:\CodexWorkspace\openai-adapter\adapter.py",
  [string] $PipelineContainer = "cr-pipeline",
  [string] $AdapterContainer = "openai-adapter",
  [string] $PipelineScript = "/pipeline/powershell/cr_reunion_point_mumerotes_pipeline_json.ps1",
  [string] $CsvPath = "/data/Affaires/2026-A60/AF_Expert_ASR/transcriptions/accedit-2026-05-21/A60_mono16_16000Hz(wav).csv",
  [string] $OutRoot = "/data/Affaires/2026-A60/BE_Traitement_captations/accedit-2026-05-21/compte_rendu_LLM/out",
  [string] $ApiBase = "http://openai-adapter:5055",
  [string] $ApiKey = "",
  [string] $HostCollectDir = "C:\CodexWorkspace\compte-rendu\test\a60_report_model_compare",
  [switch] $SkipDockerRestart
)

$ErrorActionPreference = "Stop"

function Set-ReportRemoteModel {
  param(
    [Parameter(Mandatory=$true)][string] $Path,
    [Parameter(Mandatory=$true)][string] $PhysicalModel
  )

  $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
  $pattern = '(?s)("report_remote"\s*:\s*\{.*?"model"\s*:\s*")([^"]+)(")'
  $newText = [System.Text.RegularExpressions.Regex]::Replace(
    $text,
    $pattern,
    ('$1' + $PhysicalModel + '$3'),
    1
  )
  if ($newText -eq $text) {
    throw "Impossible de modifier le modèle physique de report_remote dans $Path"
  }
  [System.IO.File]::WriteAllText($Path, $newText, [System.Text.Encoding]::UTF8)
}

function Invoke-Docker {
  param([string[]] $Args)
  & docker @Args
  if ($LASTEXITCODE -ne 0) {
    throw "docker $($Args -join ' ') a échoué avec code $LASTEXITCODE"
  }
}

function Copy-FromContainerIfPossible {
  param(
    [string] $Container,
    [string] $ContainerPath,
    [string] $HostPath
  )
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $HostPath) | Out-Null
  try {
    Invoke-Docker @("cp", "${Container}:${ContainerPath}", $HostPath)
  } catch {
    Write-Warning "Copie docker cp impossible pour $ContainerPath : $($_.Exception.Message)"
  }
}

function Read-JsonSafe {
  param([string] $Path)
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  return (Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json)
}

function Measure-Pass2B {
  param([object] $Timing)
  $entries = @()
  if ($Timing -and $Timing.entries) { $entries = @($Timing.entries) }
  $total = (($entries | Measure-Object -Property total_duration_sec -Sum).Sum)
  if ($null -eq $total -or $total -eq 0) {
    $total = (($entries | Measure-Object -Property duration_sec -Sum).Sum)
  }
  if ($null -eq $total) { $total = 0 }
  return [pscustomobject]@{
    total_sec = [math]::Round([double]$total, 3)
    batches = @($entries | ForEach-Object {
      [pscustomobject]@{
        batch_id = $_.batch_id
        segments = $_.segments_inclus
        total_duration_sec = if ($_.PSObject.Properties["total_duration_sec"]) { $_.total_duration_sec } else { $_.duration_sec }
        successful_attempt_duration_sec = $_.successful_attempt_duration_sec
        failed_attempts_count = $_.failed_attempts_count
        retries = $_.retries
        model_logical = $_.modele
        model_physical = $_.modele_reel_adapter
        prompt_chars = $_.prompt_chars
        estimated_input_tokens = $_.estimated_input_tokens
        status = $_.final_status
      }
    })
  }
}

function Compare-TextFile {
  param([string] $A, [string] $B)
  if (-not (Test-Path -LiteralPath $A) -or -not (Test-Path -LiteralPath $B)) {
    return [pscustomobject]@{ available = $false }
  }
  $ta = Get-Content -Raw -LiteralPath $A
  $tb = Get-Content -Raw -LiteralPath $B
  return [pscustomobject]@{
    available = $true
    chars_a = $ta.Length
    chars_b = $tb.Length
    same = ($ta -eq $tb)
  }
}

function Invoke-Run {
  param(
    [string] $JobName,
    [string] $PhysicalModel
  )

  Write-Host "=== $JobName : report_remote -> $PhysicalModel ==="
  Set-ReportRemoteModel -Path $AdapterPath -PhysicalModel $PhysicalModel
  if (-not $SkipDockerRestart) {
    Invoke-Docker @("restart", $AdapterContainer)
    Start-Sleep -Seconds 5
  }

  $outDir = "$OutRoot/$JobName"
  Invoke-Docker @(
    "exec", $PipelineContainer,
    "pwsh", $PipelineScript,
    "-CsvPath", $CsvPath,
    "-OutDir", $outDir,
    "-Provider", "openai",
    "-ApiBase", $ApiBase,
    "-ApiKey", $ApiKey,
    "-ModelPass1", "annoter_segments_remote",
    "-ModelPass2", "annoter_segments_remote",
    "-ModelReport", "report_remote",
    "-ModelPass2E", "annoter_segments_remote_alt",
    "-ModelPass3", "pass3_remote",
    "-ModelPass3E", "pass3e_remote",
    "-Force"
  )

  $hostJobDir = Join-Path $HostCollectDir $JobName
  New-Item -ItemType Directory -Force -Path $hostJobDir | Out-Null
  foreach ($rel in @(
      "logs/pass2b_timing.json",
      "logs/pass2b_timing.csv",
      "pipeline_qa_status.json",
      "global_meeting.json",
      "global_final.json"
    )) {
    Copy-FromContainerIfPossible `
      -Container $PipelineContainer `
      -ContainerPath "$outDir/$rel" `
      -HostPath (Join-Path $hostJobDir $rel)
  }
  return $hostJobDir
}

$original = [System.IO.File]::ReadAllText($AdapterPath, [System.Text.Encoding]::UTF8)
try {
  New-Item -ItemType Directory -Force -Path $HostCollectDir | Out-Null
  $gpt5Dir = Invoke-Run -JobName "job_test_report_gpt5mini" -PhysicalModel "gpt-5-mini"
  $gpt41Dir = Invoke-Run -JobName "job_test_report_gpt41mini" -PhysicalModel "gpt-4.1-mini"

  $gpt5Timing = Read-JsonSafe (Join-Path $gpt5Dir "logs/pass2b_timing.json")
  $gpt41Timing = Read-JsonSafe (Join-Path $gpt41Dir "logs/pass2b_timing.json")
  $gpt5Qa = Read-JsonSafe (Join-Path $gpt5Dir "pipeline_qa_status.json")
  $gpt41Qa = Read-JsonSafe (Join-Path $gpt41Dir "pipeline_qa_status.json")

  $summary = [pscustomobject]@{
    generated_at = (Get-Date).ToString("o")
    runs = @(
      [pscustomobject]@{
        job = "job_test_report_gpt5mini"
        report_remote_physical_model = "gpt-5-mini"
        path = $gpt5Dir
        pipeline_qa_status = $gpt5Qa
        pass2b = Measure-Pass2B $gpt5Timing
      },
      [pscustomobject]@{
        job = "job_test_report_gpt41mini"
        report_remote_physical_model = "gpt-4.1-mini"
        path = $gpt41Dir
        pipeline_qa_status = $gpt41Qa
        pass2b = Measure-Pass2B $gpt41Timing
      }
    )
    comparisons = [pscustomobject]@{
      global_meeting = Compare-TextFile (Join-Path $gpt5Dir "global_meeting.json") (Join-Path $gpt41Dir "global_meeting.json")
      global_final = Compare-TextFile (Join-Path $gpt5Dir "global_final.json") (Join-Path $gpt41Dir "global_final.json")
    }
  }

  $summaryPath = Join-Path $HostCollectDir "a60_report_model_comparison.json"
  [System.IO.File]::WriteAllText($summaryPath, ($summary | ConvertTo-Json -Depth 80), [System.Text.Encoding]::UTF8)

  $mdPath = Join-Path $HostCollectDir "NOTE_COMPARATIVE_A60_report_remote.md"
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add("# Comparaison A60 report_remote") | Out-Null
  $lines.Add("") | Out-Null
  foreach ($run in @($summary.runs)) {
    $lines.Add(("## {0} ({1})" -f $run.job, $run.report_remote_physical_model)) | Out-Null
    $lines.Add(("- Temps total Pass2B: {0}s" -f $run.pass2b.total_sec)) | Out-Null
    $lines.Add(("- QA pipeline: {0}" -f (($run.pipeline_qa_status | ConvertTo-Json -Compress -Depth 10)))) | Out-Null
    foreach ($b in @($run.pass2b.batches)) {
      $lines.Add(("- Batch {0}: {1}s, retries={2}, failed_attempts={3}, modèle réel={4}, status={5}" -f $b.batch_id, $b.total_duration_sec, $b.retries, $b.failed_attempts_count, $b.model_physical, $b.status)) | Out-Null
    }
    $lines.Add("") | Out-Null
  }
  $lines.Add("## Comparaison fichiers") | Out-Null
  $lines.Add(("- global_meeting identique: {0}" -f $summary.comparisons.global_meeting.same)) | Out-Null
  $lines.Add(("- global_final identique: {0}" -f $summary.comparisons.global_final.same)) | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("## Qualité synthèse") | Out-Null
  $lines.Add("À compléter après lecture humaine de `global_meeting.json` et `global_final.json` des deux jobs : précision, omissions, hallucinations, structure, exploitabilité juridique.") | Out-Null
  $lines.Add("") | Out-Null
  $lines.Add("## Recommandation finale") | Out-Null
  $lines.Add("Choisir le modèle qui minimise les timeouts/retries à qualité équivalente. Si gpt-4.1-mini donne une synthèse comparable avec moins de latence, le préférer pour Pass2B.") | Out-Null
  [System.IO.File]::WriteAllLines($mdPath, $lines, [System.Text.Encoding]::UTF8)

  Write-Host "Comparaison écrite : $summaryPath"
  Write-Host "Note écrite : $mdPath"
}
finally {
  [System.IO.File]::WriteAllText($AdapterPath, $original, [System.Text.Encoding]::UTF8)
  if (-not $SkipDockerRestart) {
    try { Invoke-Docker @("restart", $AdapterContainer) } catch { Write-Warning $_.Exception.Message }
  }
}
