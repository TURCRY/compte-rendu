Set-StrictMode -Version Latest

$script:DependencySchemaVersion = 1

function Get-CrSha256Text {
  param([AllowEmptyString()][string] $Text)
  $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Text)
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "") }
  finally { $sha.Dispose() }
}

function Test-CrJsonFile {
  param([Parameter(Mandatory=$true)][string] $Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
  try {
    $null = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    return $true
  } catch { return $false }
}

function Get-CrPathFiles {
  param([string] $Directory, [string] $Filter="*.json", [string] $ExcludeRegex="")
  if (-not $Directory -or -not (Test-Path -LiteralPath $Directory -PathType Container)) { return @() }
  return [string[]]@(Get-ChildItem -LiteralPath $Directory -Filter $Filter -File | Where-Object {
    -not $ExcludeRegex -or $_.Name -notmatch $ExcludeRegex
  } | Sort-Object Name | ForEach-Object { $_.FullName })
}

function New-CrFileRef {
  param([Parameter(Mandatory=$true)][string] $LogicalPath, [string] $Path)
  [pscustomobject]@{ logical_path=$LogicalPath; path=[string]$Path }
}

function Get-CrSnapshots {
  param([object[]] $Refs=@())
  $snapshots = foreach ($ref in @($Refs)) {
    $path = [string]$ref.path
    $exists = (-not [string]::IsNullOrWhiteSpace($path)) -and (Test-Path -LiteralPath $path -PathType Leaf)
    $item = if ($exists) { Get-Item -LiteralPath $path } else { $null }
    [pscustomobject]@{
      logical_path = [string]$ref.logical_path
      path = $path
      exists = [bool]$exists
      sha256 = if ($exists) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash } else { "" }
      size = if ($exists) { [long]$item.Length } else { 0 }
      mtime_utc = if ($exists) { $item.LastWriteTimeUtc.ToString("o") } else { "" }
    }
  }
  return @($snapshots | Sort-Object logical_path)
}

function Get-CrCollectionFingerprint {
  param([object[]] $Snapshots=@())
  $lines = @($Snapshots | Sort-Object logical_path | ForEach-Object {
    "{0}|{1}" -f ([string]$_.logical_path), $(if ($_.exists) { [string]$_.sha256 } else { "MISSING" })
  })
  return Get-CrSha256Text ($lines -join "`n")
}

function Get-CrParameterSnapshot {
  param([hashtable] $Parameters=@{})
  $items = foreach ($key in @($Parameters.Keys | Sort-Object)) {
    [pscustomobject]@{ name=[string]$key; value=[string]$Parameters[$key] }
  }
  $text = @($items | ForEach-Object { "{0}|{1}" -f $_.name,$_.value }) -join "`n"
  [pscustomobject]@{ values=@($items); fingerprint=(Get-CrSha256Text $text) }
}

function New-CrRefsFromFiles {
  param([string] $LogicalRoot, [string[]] $Paths=@())
  $refs = foreach ($path in @($Paths | Sort-Object)) {
    New-CrFileRef -LogicalPath ($LogicalRoot.TrimEnd('/') + "/" + (Split-Path $path -Leaf)) -Path $path
  }
  return @($refs)
}

function Get-CrPassDefinitions {
  param(
    [Parameter(Mandatory=$true)][string] $CsvPath,
    [Parameter(Mandatory=$true)][string] $OutDir,
    [string] $CsvDebriefPath="", [string] $ContextJsonPath="", [string] $SujetsPath="", [string] $ParticipantsPath="",
    [hashtable] $Parameters=@{}
  )
  $segments = @(Get-CrPathFiles (Join-Path $OutDir "segments") "segment_*.json")
  $batches = @(Get-CrPathFiles (Join-Path $OutDir "pass2B_batches") "pass2B_batch_*.json" "_meta\.json$")
  $subjects = @(Get-CrPathFiles (Join-Path $OutDir "sujets") "*.json")
  $compacts = @(Get-CrPathFiles (Join-Path $OutDir "pass2E_sujets_compact") "*_compact.json")
  $syntheses = @(Get-CrPathFiles (Join-Path $OutDir "pass3E_sujets") "sujet_*_synthese.json")
  $debriefJson = Join-Path $OutDir "debrief.json"
  $globalJson = Join-Path $OutDir "global.json"
  $meetingJson = Join-Path $OutDir "global_meeting.json"
  $sujetsRef = Join-Path $OutDir "sujets_ref.json"
  $globalBySubject = Join-Path $OutDir "global_by_sujet.json"
  $finalJson = Join-Path $OutDir "global_final.json"
  $depseudoJson = Join-Path $OutDir "global_final_depseudonymized_for_docx.json"
  $docx = @(Get-CrPathFiles $OutDir "compte_rendu_*.docx") | Sort-Object { (Get-Item -LiteralPath $_).LastWriteTimeUtc } -Descending | Select-Object -First 1

  function Pick-Params([string[]] $Names) {
    $picked = @{}
    foreach ($name in $Names) { if ($Parameters.ContainsKey($name)) { $picked[$name] = $Parameters[$name] } }
    return $picked
  }

  $defs = New-Object System.Collections.Generic.List[object]
  $defs.Add([pscustomobject]@{
    name="Pass1 segments"; require_json=$true
    inputs=@(New-CrFileRef "source/transcription.csv" $CsvPath; New-CrFileRef "source/Sujets.xlsx" $SujetsPath; New-CrFileRef "source/Participants.xlsx" $ParticipantsPath; New-CrFileRef "source/contexte.json" $ContextJsonPath)
    outputs=@(New-CrRefsFromFiles "segments" $segments)
    parameters=(Pick-Params @("provider","model_pass1","preset","max_segment_seconds","max_asr_gap_seconds"))
  }) | Out-Null
  $defs.Add([pscustomobject]@{
    name="Pass1B"; require_json=$true
    inputs=@(New-CrFileRef "source/debrief_global.csv" $CsvDebriefPath)
    outputs=@(New-CrFileRef "debrief.json" $debriefJson)
    parameters=(Pick-Params @("provider","model_debrief"))
  }) | Out-Null
  $defs.Add([pscustomobject]@{
    name="Pass2A"; require_json=$true
    inputs=@(New-CrRefsFromFiles "segments" $segments) + @(New-CrFileRef "debrief.json" $debriefJson; New-CrFileRef "source/Sujets.xlsx" $SujetsPath; New-CrFileRef "source/Participants.xlsx" $ParticipantsPath)
    outputs=@(New-CrFileRef "global.json" $globalJson)
    parameters=(Pick-Params @("pipeline_schema"))
  }) | Out-Null
  $defs.Add([pscustomobject]@{
    name="Pass2B"; require_json=$true
    inputs=@(New-CrRefsFromFiles "segments" $segments) + @(New-CrFileRef "source/contexte.json" $ContextJsonPath)
    outputs=@(New-CrRefsFromFiles "pass2B_batches" $batches) + @(New-CrFileRef "global_meeting.json" $meetingJson)
    parameters=(Pick-Params @("provider","model_report","pass2_batch_size","pass2b_prompt_chars_limit","pass2b_estimated_tokens_limit"))
  }) | Out-Null
  $defs.Add([pscustomobject]@{
    name="split sujets"; require_json=$true
    inputs=@(New-CrFileRef "global.json" $globalJson; New-CrFileRef "sujets_ref.json" $sujetsRef; New-CrFileRef "source/Sujets.xlsx" $SujetsPath)
    outputs=@(New-CrRefsFromFiles "sujets" $subjects)
    parameters=(Pick-Params @("pipeline_schema"))
  }) | Out-Null
  $defs.Add([pscustomobject]@{
    name="Pass2E"; require_json=$true
    inputs=@(New-CrRefsFromFiles "sujets" $subjects) + @(New-CrFileRef "source/contexte.json" $ContextJsonPath)
    outputs=@(New-CrRefsFromFiles "pass2E_sujets_compact" $compacts)
    parameters=(Pick-Params @("provider","model_pass2e"))
  }) | Out-Null
  $defs.Add([pscustomobject]@{
    name="Pass3E"; require_json=$true
    inputs=@(New-CrRefsFromFiles "pass2E_sujets_compact" $compacts) + @(New-CrFileRef "source/contexte.json" $ContextJsonPath)
    outputs=@(New-CrRefsFromFiles "pass3E_sujets" $syntheses)
    parameters=(Pick-Params @("provider","model_pass3e","model_pass3"))
  }) | Out-Null
  $defs.Add([pscustomobject]@{
    name="global_by_sujet"; require_json=$true
    inputs=@(New-CrRefsFromFiles "pass3E_sujets" $syntheses)
    outputs=@(New-CrFileRef "global_by_sujet.json" $globalBySubject)
    parameters=(Pick-Params @("pipeline_schema"))
  }) | Out-Null
  $finalInputs = @(New-CrFileRef "global_by_sujet.json" $globalBySubject; New-CrFileRef "global_meeting.json" $meetingJson; New-CrFileRef "debrief.json" $debriefJson; New-CrFileRef "source/contexte.json" $ContextJsonPath; New-CrFileRef "source/Sujets.xlsx" $SujetsPath; New-CrFileRef "source/Participants.xlsx" $ParticipantsPath)
  $defs.Add([pscustomobject]@{
    name="Pass3A-D"; require_json=$true; inputs=$finalInputs; outputs=@(New-CrFileRef "global_final.json" $finalJson)
    parameters=(Pick-Params @("provider","model_pass3a","model_pass3b","model_pass3c","model_pass3d"))
  }) | Out-Null
  $defs.Add([pscustomobject]@{
    name="global_final"; require_json=$true; inputs=$finalInputs; outputs=@(New-CrFileRef "global_final.json" $finalJson)
    parameters=(Pick-Params @("pipeline_schema"))
  }) | Out-Null
  $defs.Add([pscustomobject]@{
    name="JSON depseudonymized"; require_json=$true; inputs=@(New-CrFileRef "global_final.json" $finalJson); outputs=@(New-CrFileRef "global_final_depseudonymized_for_docx.json" $depseudoJson)
    parameters=(Pick-Params @("pseudonymize_remote","pseudo_job_id"))
  }) | Out-Null
  $useDepseudo = ($Parameters.ContainsKey("pseudonymize_remote") -and [string]$Parameters["pseudonymize_remote"] -eq "True")
  $docxInput = if ($useDepseudo) { $depseudoJson } else { $finalJson }
  $defs.Add([pscustomobject]@{
    name="DOCX"; require_json=$false; inputs=@(New-CrFileRef "docx_payload.json" $docxInput); outputs=@(New-CrFileRef "compte_rendu.docx" ([string]$docx))
    parameters=(Pick-Params @("render_url"))
  }) | Out-Null
  return $defs.ToArray()
}

function Read-CrDependencyState {
  param([string] $OutDir)
  $path = Join-Path $OutDir "dependency_state.json"
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
  try { return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
  catch { return $null }
}

function New-CrPassState {
  param([object] $Definition, [string] $PipelineVersion)
  $inputs = @(Get-CrSnapshots $Definition.inputs)
  $outputs = @(Get-CrSnapshots $Definition.outputs)
  $parameterState = Get-CrParameterSnapshot $Definition.parameters
  $inputFilesFingerprint = Get-CrCollectionFingerprint $inputs
  $inputFingerprint = Get-CrSha256Text ($inputFilesFingerprint + "`n" + $parameterState.fingerprint)
  $outputFingerprint = Get-CrCollectionFingerprint $outputs
  $valid = ($outputs.Count -gt 0 -and @($outputs | Where-Object { -not $_.exists }).Count -eq 0)
  if ($valid -and $Definition.require_json) {
    $valid = (@($outputs | Where-Object { -not (Test-CrJsonFile $_.path) }).Count -eq 0)
  }
  $result=[ordered]@{
    pipeline_version=$PipelineVersion; computed_at=(Get-Date).ToUniversalTime().ToString("o"); valid=[bool]$valid
    inputs=$inputs; input_files_fingerprint=$inputFilesFingerprint; parameters=$parameterState.values
    parameter_fingerprint=$parameterState.fingerprint; input_fingerprint=$inputFingerprint
    outputs=$outputs; output_fingerprint=$outputFingerprint
  }
  if($Definition.name -eq "Pass2B"){
    $segmentInputs=@($inputs|Where-Object{$_.logical_path -like "segments/*"}|Sort-Object logical_path)
    $contextInputs=@($inputs|Where-Object{$_.logical_path -eq "source/contexte.json"})
    $batchOutputs=@($outputs|Where-Object{$_.logical_path -like "pass2B_batches/*"}|Sort-Object logical_path)
    $batchSize=2;if($Definition.parameters.ContainsKey("pass2_batch_size")){$batchSize=[math]::Max(1,[int]$Definition.parameters["pass2_batch_size"])}
    $batchStates=New-Object System.Collections.Generic.List[object]
    for($index=0;$index -lt $batchOutputs.Count;$index++){
      $from=$index*$batchSize;$to=[math]::Min($from+$batchSize-1,$segmentInputs.Count-1)
      $batchInputs=@($contextInputs);if($from -lt $segmentInputs.Count){$batchInputs=@($segmentInputs[$from..$to])+@($contextInputs)}
      $batchStates.Add([pscustomobject]@{
        batch_id=($index+1);inputs=$batchInputs;input_fingerprint=(Get-CrCollectionFingerprint $batchInputs)
        outputs=@($batchOutputs[$index]);output_fingerprint=(Get-CrCollectionFingerprint @($batchOutputs[$index]));valid=[bool]$batchOutputs[$index].exists
      })|Out-Null
    }
    $result["batches"]=$batchStates.ToArray()
  }
  return [pscustomobject]$result
}

function Get-CrRecordedPass {
  param([object] $State, [string] $Name)
  if (-not $State -or -not $State.PSObject.Properties['passes']) { return $null }
  $property = $State.passes.PSObject.Properties[$Name]
  if (-not $property) { return $null }
  return $property.Value
}

function Compare-CrPassState {
  param([object] $Definition, [object] $Recorded, [string] $PipelineVersion, [bool] $ManifestPresent)
  $current = New-CrPassState $Definition $PipelineVersion
  $action="REUSE"; $reason="empreintes SHA256 identiques"; $divergent=""; $recordedSha=""; $currentSha=$current.input_fingerprint
  if (-not $ManifestPresent) {
    $action="REBUILD"; $reason="dependency manifest absent"
  } elseif (-not $Recorded) {
    $action="REBUILD"; $reason="passe absente du dependency manifest"
  } elseif ([string]$Recorded.pipeline_version -ne $PipelineVersion) {
    $action="REBUILD"; $reason="version pipeline différente"; $recordedSha=[string]$Recorded.pipeline_version; $currentSha=$PipelineVersion
  } elseif (-not [bool]$Recorded.valid) {
    $action="REBUILD"; $reason="état enregistré invalide"
  } elseif (-not $current.valid) {
    $action="REBUILD"; $reason="sortie absente ou invalide"
  } elseif ([string]$Recorded.input_fingerprint -ne $current.input_fingerprint) {
    $action="REBUILD"; $reason="empreinte d'entrée différente"; $recordedSha=[string]$Recorded.input_fingerprint
    $recordedByPath=@{}; foreach($item in @($Recorded.inputs)){$recordedByPath[[string]$item.logical_path]=$item}
    foreach($item in @($current.inputs)){
      $old=$recordedByPath[[string]$item.logical_path]
      if(-not $old -or [string]$old.sha256 -ne [string]$item.sha256){$divergent=[string]$item.logical_path; $recordedSha=if($old){[string]$old.sha256}else{"<absente>"}; $currentSha=[string]$item.sha256; break}
    }
    if(-not $divergent -and [string]$Recorded.parameter_fingerprint -ne $current.parameter_fingerprint){$divergent="parameters"; $recordedSha=[string]$Recorded.parameter_fingerprint; $currentSha=[string]$current.parameter_fingerprint}
  } elseif ([string]$Recorded.output_fingerprint -ne $current.output_fingerprint) {
    $action="REBUILD"; $reason="empreinte de sortie différente"; $recordedSha=[string]$Recorded.output_fingerprint; $currentSha=[string]$current.output_fingerprint; $divergent="output"
  }
  if($action -eq "REUSE"){
    $mtimeChanged=$false; $oldByPath=@{}; foreach($item in @($Recorded.inputs)){$oldByPath[[string]$item.logical_path]=$item}
    foreach($item in @($current.inputs)){if($oldByPath[[string]$item.logical_path] -and [string]$oldByPath[[string]$item.logical_path].mtime_utc -ne [string]$item.mtime_utc){$mtimeChanged=$true;break}}
    if($mtimeChanged){$reason="empreintes SHA256 identiques; mtime différent ignoré"}
    $recordedSha=[string]$Recorded.input_fingerprint
  }
  [pscustomobject]@{
    name=$Definition.name; action=$action; reason=$reason; divergent_input=$divergent
    recorded_sha=$recordedSha; current_sha=$currentSha
    output=(@($Definition.outputs|ForEach-Object{$_.path}) -join ", ")
    input_mtime_utc=(@($current.inputs|ForEach-Object{$_.mtime_utc}|Where-Object{$_}|Sort-Object -Descending|Select-Object -First 1) -join "")
    output_mtime_utc=(@($current.outputs|ForEach-Object{$_.mtime_utc}|Where-Object{$_}|Sort-Object|Select-Object -First 1) -join "")
  }
}

function Get-CrDependencyPlan {
  param(
    [Parameter(Mandatory=$true)][string] $CsvPath, [Parameter(Mandatory=$true)][string] $OutDir,
    [string] $CsvDebriefPath="", [string] $ContextJsonPath="", [string] $SujetsPath="", [string] $ParticipantsPath="",
    [string] $PipelineVersion="", [hashtable] $Parameters=@{}
  )
  if(-not $PipelineVersion){$PipelineVersion="unspecified"}
  $state=Read-CrDependencyState $OutDir
  $manifestPresent=($null -ne $state -and [int]$state.schema_version -eq $script:DependencySchemaVersion)
  $dirty=@{}
  $parents=@{
    "Pass2A"=@("Pass1 segments","Pass1B"); "Pass2B"=@("Pass1 segments"); "split sujets"=@("Pass2A")
    "Pass2E"=@("split sujets"); "Pass3E"=@("Pass2E"); "global_by_sujet"=@("Pass3E")
    "Pass3A-D"=@("global_by_sujet","Pass2B","Pass1B"); "global_final"=@("Pass3A-D")
    "JSON depseudonymized"=@("global_final"); "DOCX"=@("JSON depseudonymized")
  }
  $plan=New-Object System.Collections.Generic.List[object]
  foreach($definition in @(Get-CrPassDefinitions -CsvPath $CsvPath -OutDir $OutDir -CsvDebriefPath $CsvDebriefPath -ContextJsonPath $ContextJsonPath -SujetsPath $SujetsPath -ParticipantsPath $ParticipantsPath -Parameters $Parameters)){
    $recorded=Get-CrRecordedPass $state $definition.name
    $decision=Compare-CrPassState $definition $recorded $PipelineVersion $manifestPresent
    $dirtyParent=$null
    if($parents.ContainsKey([string]$definition.name)){
      $dirtyParent=@($parents[[string]$definition.name] | Where-Object {$dirty.ContainsKey([string]$_) -and $dirty[[string]$_]}) | Select-Object -First 1
    }
    if($dirtyParent){$decision.action="REBUILD"; $decision.reason="propagation dirty depuis $dirtyParent"; $decision.divergent_input=[string]$dirtyParent}
    $dirty[$definition.name]=($decision.action -eq "REBUILD")
    $plan.Add($decision)|Out-Null
  }
  return $plan.ToArray()
}

function Write-CrDependencyState {
  param(
    [Parameter(Mandatory=$true)][string] $CsvPath, [Parameter(Mandatory=$true)][string] $OutDir,
    [string] $CsvDebriefPath="", [string] $ContextJsonPath="", [string] $SujetsPath="", [string] $ParticipantsPath="",
    [Parameter(Mandatory=$true)][string] $PipelineVersion, [hashtable] $Parameters=@{}, [string[]] $ExcludePasses=@()
  )
  $passes=[ordered]@{}
  foreach($definition in @(Get-CrPassDefinitions -CsvPath $CsvPath -OutDir $OutDir -CsvDebriefPath $CsvDebriefPath -ContextJsonPath $ContextJsonPath -SujetsPath $SujetsPath -ParticipantsPath $ParticipantsPath -Parameters $Parameters)){
    if($ExcludePasses -contains $definition.name){continue}
    $passes[$definition.name]=New-CrPassState $definition $PipelineVersion
  }
  $state=[ordered]@{schema_version=$script:DependencySchemaVersion; pipeline_version=$PipelineVersion; generated_at=(Get-Date).ToUniversalTime().ToString("o"); valid=$true; passes=$passes}
  $path=Join-Path $OutDir "dependency_state.json"; $tmp=$path+".tmp"
  [IO.File]::WriteAllText($tmp,($state|ConvertTo-Json -Depth 100),[Text.UTF8Encoding]::new($false))
  Move-Item -LiteralPath $tmp -Destination $path -Force
  return $path
}

function Update-CrDeliveryDependencyState {
  param(
    [Parameter(Mandatory=$true)][string] $CsvPath, [Parameter(Mandatory=$true)][string] $OutDir,
    [string] $CsvDebriefPath="", [string] $ContextJsonPath="", [string] $SujetsPath="", [string] $ParticipantsPath="",
    [Parameter(Mandatory=$true)][string] $PipelineVersion, [hashtable] $Parameters=@{}
  )
  $state=Read-CrDependencyState $OutDir
  if(-not $state -or [int]$state.schema_version -ne $script:DependencySchemaVersion -or [string]$state.pipeline_version -ne $PipelineVersion){return $null}
  $definitions=@(Get-CrPassDefinitions -CsvPath $CsvPath -OutDir $OutDir -CsvDebriefPath $CsvDebriefPath -ContextJsonPath $ContextJsonPath -SujetsPath $SujetsPath -ParticipantsPath $ParticipantsPath -Parameters $Parameters)
  foreach($name in @("JSON depseudonymized","DOCX")){
    $definition=@($definitions|Where-Object{$_.name -eq $name})|Select-Object -First 1
    if(-not $definition){continue}
    $passState=New-CrPassState $definition $PipelineVersion
    if($state.passes.PSObject.Properties[$name]){$state.passes.$name=$passState}else{$state.passes|Add-Member -NotePropertyName $name -NotePropertyValue $passState}
  }
  $state.generated_at=(Get-Date).ToUniversalTime().ToString("o")
  $path=Join-Path $OutDir "dependency_state.json";$tmp=$path+".tmp"
  [IO.File]::WriteAllText($tmp,($state|ConvertTo-Json -Depth 100),[Text.UTF8Encoding]::new($false));Move-Item -LiteralPath $tmp -Destination $path -Force
  return $path
}

function Write-CrDependencyPlan {
  param([Parameter(Mandatory=$true)][object[]] $Plan)
  foreach($item in $Plan){
    Microsoft.PowerShell.Utility\Write-Host ("{0,-7} {1}" -f $item.action,$item.name)
    Microsoft.PowerShell.Utility\Write-Host ("  sortie        : {0}" -f $item.output)
    Microsoft.PowerShell.Utility\Write-Host ("  raison        : {0}" -f $item.reason)
    Microsoft.PowerShell.Utility\Write-Host ("  divergence    : {0}" -f $item.divergent_input)
    Microsoft.PowerShell.Utility\Write-Host ("  SHA enregistrée: {0}" -f $item.recorded_sha)
    Microsoft.PowerShell.Utility\Write-Host ("  SHA actuelle   : {0}" -f $item.current_sha)
    Microsoft.PowerShell.Utility\Write-Host ("  mtime entrée  : {0}" -f $item.input_mtime_utc)
    Microsoft.PowerShell.Utility\Write-Host ("  mtime sortie  : {0}" -f $item.output_mtime_utc)
  }
}

Export-ModuleMember -Function Test-CrJsonFile,Get-CrDependencyPlan,Write-CrDependencyPlan,Write-CrDependencyState,Update-CrDeliveryDependencyState,Get-CrSha256Text
