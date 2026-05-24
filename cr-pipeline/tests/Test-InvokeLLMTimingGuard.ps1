param(
  [string] $PipelinePath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($PipelinePath)) {
  if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $PipelinePath = Join-Path $PSScriptRoot "..\pipeline\powershell\cr_reunion_point_mumerotes_pipeline_json.ps1"
  }
  else {
    $PipelinePath = Join-Path (Get-Location) "cr-pipeline\pipeline\powershell\cr_reunion_point_mumerotes_pipeline_json.ps1"
  }
}

$source = [System.IO.File]::ReadAllText($PipelinePath, [System.Text.Encoding]::UTF8)
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors -and $parseErrors.Count -gt 0) {
  throw ("Parse errors in pipeline script: " + (($parseErrors | ForEach-Object { $_.Message }) -join "; "))
}

$requiredFunctions = @(
  "Unwrap-AdapterText",
  "Get-CurrentLLMTimingAttemptsList",
  "Add-CurrentLLMTimingAttempt",
  "Invoke-LLM-OpenAICompat"
)

$functionAsts = @($ast.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $requiredFunctions -contains $node.Name
}, $true))

$foundNames = @($functionAsts | ForEach-Object { $_.Name })
$missing = @($requiredFunctions | Where-Object { $foundNames -notcontains $_ })
if ($missing.Count -gt 0) {
  throw ("Missing functions for timing guard test: " + ($missing -join ", "))
}

$functionSource = ($functionAsts | Sort-Object { [array]::IndexOf($requiredFunctions, $_.Name) } | ForEach-Object { $_.Extent.Text }) -join "`n`n"
$testSource = @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = "Stop"
`$ApiBase = "http://127.0.0.1:9"
`$ApiKey = "test"

$functionSource

Remove-Variable -Scope Script -Name CurrentLLMTimingAttempts -ErrorAction SilentlyContinue
try {
  Invoke-LLM-OpenAICompat -system "system" -user "user" -model "test-model" -Label "TimingGuardSelfTest" -TimeoutSec 1 -MaxTry 1 | Out-Null
  throw "Expected Invoke-LLM-OpenAICompat to fail against closed local port"
}
catch {
  `$message = `$_.Exception.Message
  if (`$message -match "CurrentLLMTimingAttempts") {
    throw "Invoke-LLM depends on CurrentLLMTimingAttempts outside Pass2B: `$message"
  }
  Write-Host "Invoke-LLM timing guard OK"
}
"@

& ([scriptblock]::Create($testSource))
