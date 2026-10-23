$ErrorActionPreference = "Stop"

# Autotest deterministe des garde-fous Pass2F / Pass2B_2F.
# Aucun LLM, HTTP, batch, pipeline ou ecriture de donnee metier.

$repoRoot = Split-Path -Parent $PSScriptRoot
$pipelinePath = [string]$env:CR_REFERE_PIPELINE_PS1
if (-not $pipelinePath) { $pipelinePath = Join-Path $repoRoot "cr-pipeline/pipeline/powershell/cr_refere_preventif_pipeline_json.ps1" }
if (-not (Test-Path -LiteralPath $pipelinePath -PathType Leaf)) { throw ("pipeline introuvable : " + $pipelinePath) }
$scriptText = [System.IO.File]::ReadAllText($pipelinePath, [System.Text.Encoding]::UTF8)

function Import-PipelineFunction {
  param([string] $Text, [string] $Name)
  $marker = "function " + $Name + " {"
  $start = $Text.IndexOf($marker)
  if ($start -lt 0) { throw ("fonction introuvable dans le pipeline : " + $Name) }
  $braceStart = $Text.IndexOf("{", $start)
  $depth = 0
  $end = -1
  for ($i = $braceStart; $i -lt $Text.Length; $i++) {
    if ($Text[$i] -eq "{") { $depth++ }
    elseif ($Text[$i] -eq "}") { $depth--; if ($depth -eq 0) { $end = $i; break } }
  }
  if ($end -lt 0) { throw ("fin de fonction introuvable : " + $Name) }
  return $Text.Substring($start, $end - $start + 1)
}

$functionNames = @(
  'Get-CrProp', 'Get-CrPropString', 'Get-CrPropInt', 'New-PhotoKey',
  'Add-Pass2FValidationIssue', 'Get-Pass2FArrayValue', 'New-PhotoRefIndex',
  'Resolve-PhotoRefIndex', 'Add-Pass2FPhotoRefIssue', 'Add-Pass2FAsrRefIssue',
  'ConvertTo-AsrRowNumber', 'Get-AsrRowCitationsFromText',
  'Test-Pass2FOutputContract', 'Test-Pass2B2FRank1MaterialIntegrity',
  'Test-Pass2FArtifactRevalidation',
  'Test-Pass2FResponseArtifact', 'Assert-P3EChunkPathsPublishable',
  'Get-P3V', 'Read-P3RawText', 'Get-P3SujetNumeroStr',
  'Resolve-P3EChunkPaths', 'Get-P3EUserText', 'Invoke-Pass2FChunkAndRecord'
)
$definitions = @()
foreach ($name in $functionNames) { $definitions += (Import-PipelineFunction -Text $scriptText -Name $name) }
Invoke-Expression ($definitions -join [Environment]::NewLine)

$script:Checks = 0
$script:Failures = 0
function Assert-True {
  param([bool] $Condition, [string] $Message)
  $script:Checks++
  if ($Condition) { Write-Host ("OK   " + $Message) }
  else { $script:Failures++; Write-Host ("KO   " + $Message) }
}
function Assert-Eq {
  param($Actual, $Expected, [string] $Message)
  Assert-True ($Actual -eq $Expected) ($Message + " [attendu=" + [string]$Expected + " obtenu=" + [string]$Actual + "]")
}
function Get-Codes {
  param($Result)
  return @($Result.errors | ForEach-Object { [string]$_.code })
}
function Assert-HasCode {
  param($Result, [string] $Code, [string] $Message)
  Assert-True (@(Get-Codes $Result) -contains $Code) ($Message + " [codes=" + (@(Get-Codes $Result) -join ',') + "]")
}

$script:photos = @(
  @{ photo_rel_native='JPG/IMG_0001.jpg'; photo='IMG_0001.jpg' },
  @{ photo_rel_native='JPG/IMG_0002.jpg'; photo='IMG_0002.jpg' },
  @{ photo_rel_native='JPG/IMG_0003.jpg'; photo='IMG_0003.jpg' },
  @{ photo_rel_native='JPG/IMG_0004.jpg'; photo='IMG_0004.jpg' }
)
$script:assignments = @{
  'JPG/IMG_0001.jpg' = @{ status='affectee'; subject_numero=6; subject_title='Sujet 6' }
  'JPG/IMG_0002.jpg' = @{ status='affectee'; subject_numero=6; subject_title='Sujet 6' }
  'JPG/IMG_0003.jpg' = @{ status='affectee'; subject_numero=11; subject_title='Sujet 11' }
  'JPG/IMG_0004.jpg' = @{ status='exclue'; subject_numero=0; subject_title='' }
}
$script:asrRows = @(
  @{ idx=10; start=100; end=105; speaker='A'; text='propos du sujet 11' },
  @{ idx=11; start=106; end=110; speaker='A'; text='autre propos du sujet 11' },
  @{ idx=30; start=200; end=205; speaker='B'; text='propos hors chunk' }
)
$script:Ctx = @{ photos=$script:photos; assignments=$script:assignments; asr_rows=$script:asrRows }

function New-TestChunk {
  param(
    [int] $Subject = 6,
    [object[]] $PhotoSpecs = @(),
    [int[]] $AsrRows = @(10,11)
  )
  $units = @()
  foreach ($p in @($PhotoSpecs)) {
    $units += @{
      kind='photo'
      photo=[string]$p.photo
      photo_rel_native=[string]$p.rel
      subject_numero=[int]$p.subject
      asr=@{ available=(@($AsrRows).Count -gt 0); rows=@($AsrRows); text='' }
    }
  }
  return @{
    chunk_index=1
    chunk_total=1
    photos_count=@($PhotoSpecs).Count
    units_count=@($units).Count
    data=@{ sujet_cible=@{ numero=$Subject }; sequence_documentaire=@($units) }
  }
}

function New-TestPoint {
  param(
    [string] $Text = 'Constat de test.',
    [object[]] $Photos = @('IMG_0001.jpg'),
    [object[]] $AsrRows = @(10),
    [string] $Nature = 'constat_visuel'
  )
  return @{ texte=$Text; nature=$Nature; photos=@($Photos); asr_rows=@($AsrRows); niveau_appui='fort' }
}

function New-TestOutput {
  param(
    [int] $Subject = 6,
    [object[]] $PhotoContexts = @(),
    [object[]] $Points = @(),
    [string] $Synthese = 'Synthese de test.'
  )
  if (@($PhotoContexts).Count -eq 0) {
    $PhotoContexts = @(@{ photo='IMG_0001.jpg'; apport_contextuel='Contexte de test.'; elements_visuels_utiles=@(); elements_oraux_associes=@(); elements_non_retenus=@() })
  }
  if (@($Points).Count -eq 0) { $Points = @(New-TestPoint) }
  return @{
    schema_version=1
    source_pass='2F'
    subject_numero=$Subject
    synthese_intermediaire=$Synthese
    points_documentes=@($Points)
    incertitudes=@()
    photo_contexts=@($PhotoContexts)
  }
}

$chunkOne = New-TestChunk -Subject 6 -PhotoSpecs @(@{photo='IMG_0001.jpg'; rel='JPG/IMG_0001.jpg'; subject=6}) -AsrRows @(10,11)
$planOne = @{ numero=6 }
$valid = New-TestOutput
$r = Test-Pass2FOutputContract -Parsed $valid -Chunk $chunkOne -Plan $planOne -SourceContext $script:Ctx
Assert-True ([bool]$r.ok) 'sortie valide acceptee'
Assert-Eq ([string]$r.status) 'ok' 'statut valide'

$badSubject = New-TestOutput -Subject 11
$r = Test-Pass2FOutputContract -Parsed $badSubject -Chunk $chunkOne -Plan $planOne -SourceContext $script:Ctx
Assert-HasCode $r 'subject_repond_invalide' 'mauvais subject_repond rejete'

$unknown = New-TestOutput -PhotoContexts @(@{photo='IMG_9999.jpg'; apport_contextuel='x'}) -Points @(New-TestPoint -Photos @('IMG_9999.jpg'))
$r = Test-Pass2FOutputContract -Parsed $unknown -Chunk $chunkOne -Plan $planOne -SourceContext $script:Ctx
Assert-HasCode $r 'photo_inconnue' 'photo inconnue rejetee'

$excluded = New-TestOutput -PhotoContexts @(@{photo='IMG_0004.jpg'; apport_contextuel='x'}) -Points @(New-TestPoint -Photos @('IMG_0004.jpg'))
$r = Test-Pass2FOutputContract -Parsed $excluded -Chunk $chunkOne -Plan $planOne -SourceContext $script:Ctx
Assert-HasCode $r 'photo_exclue' 'photo exclue rejetee'

$chunkWrongHuman = New-TestChunk -Subject 6 -PhotoSpecs @(@{photo='IMG_0003.jpg'; rel='JPG/IMG_0003.jpg'; subject=6}) -AsrRows @(10)
$wrongHuman = New-TestOutput -PhotoContexts @(@{photo='IMG_0003.jpg'; apport_contextuel='x'}) -Points @(New-TestPoint -Photos @('IMG_0003.jpg'))
$r = Test-Pass2FOutputContract -Parsed $wrongHuman -Chunk $chunkWrongHuman -Plan $planOne -SourceContext $script:Ctx
Assert-HasCode $r 'photo_mauvais_sujet_humain' 'mauvais sujet humain rejete'
Assert-HasCode $r 'photo_mauvais_sujet_entree' 'incoherence d entree photo rejetee'

$missingAsr = New-TestOutput -Points @(New-TestPoint -AsrRows @(999))
$r = Test-Pass2FOutputContract -Parsed $missingAsr -Chunk $chunkOne -Plan $planOne -SourceContext $script:Ctx
Assert-HasCode $r 'asr_row_inconnue' 'reference ASR absente rejetee'

$outsideChunkAsr = New-TestOutput -Points @(New-TestPoint -AsrRows @(30))
$r = Test-Pass2FOutputContract -Parsed $outsideChunkAsr -Chunk $chunkOne -Plan $planOne -SourceContext $script:Ctx
Assert-HasCode $r 'asr_row_hors_contexte' 'reference ASR hors chunk rejetee'

$neighbor = New-TestOutput -Points @(New-TestPoint -AsrRows @(10))
$r = Test-Pass2FOutputContract -Parsed $neighbor -Chunk $chunkOne -Plan $planOne -SourceContext $script:Ctx
Assert-True ([bool]$r.ok) 'sujet ASR voisin 11 accepte sans reassignation photo'
Assert-Eq ([int]$r.counts.expected_subject) 6 'sujet photo reste 6 avec ASR voisin 11'

$multiNeighbor = New-TestOutput -Points @(New-TestPoint -AsrRows @(10,11))
$r = Test-Pass2FOutputContract -Parsed $multiNeighbor -Chunk $chunkOne -Plan $planOne -SourceContext $script:Ctx
Assert-True ([bool]$r.ok) 'plusieurs sujets ASR voisins acceptes'

$chunkNoAsr = New-TestChunk -Subject 6 -PhotoSpecs @(@{photo='IMG_0001.jpg'; rel='JPG/IMG_0001.jpg'; subject=6}) -AsrRows @()
$noAsr = New-TestOutput -Points @(New-TestPoint -AsrRows @())
$r = Test-Pass2FOutputContract -Parsed $noAsr -Chunk $chunkNoAsr -Plan $planOne -SourceContext $script:Ctx
Assert-True ([bool]$r.ok) 'absence de contexte ASR acceptee'

$chunkTwo = New-TestChunk -Subject 6 -PhotoSpecs @(
  @{photo='IMG_0001.jpg'; rel='JPG/IMG_0001.jpg'; subject=6},
  @{photo='IMG_0002.jpg'; rel='JPG/IMG_0002.jpg'; subject=6}
) -AsrRows @(10)
$partial = New-TestOutput -PhotoContexts @(@{photo='IMG_0001.jpg'; apport_contextuel='x'}) -Points @(New-TestPoint -Photos @('IMG_0001.jpg') -AsrRows @(10))
$r = Test-Pass2FOutputContract -Parsed $partial -Chunk $chunkTwo -Plan $planOne -SourceContext $script:Ctx
Assert-HasCode $r 'photo_context_absente' 'resultat photo partiel rejete'

$duplicate = New-TestOutput -PhotoContexts @(
  @{photo='IMG_0001.jpg'; apport_contextuel='x'},
  @{photo='IMG_0001.jpg'; apport_contextuel='y'}
)
$r = Test-Pass2FOutputContract -Parsed $duplicate -Chunk $chunkOne -Plan $planOne -SourceContext $script:Ctx
Assert-HasCode $r 'photo_context_duplique' 'photo_context duplique rejete'

$proseBadAsr = New-TestOutput -Synthese 'Voir [ROW 999].'
$r = Test-Pass2FOutputContract -Parsed $proseBadAsr -Chunk $chunkOne -Plan $planOne -SourceContext $script:Ctx
Assert-HasCode $r 'asr_row_inconnue' 'citation [ROW] absente rejetee'

$materialOk = @{ photo_units=@(
  @{ photo_id='JPG/IMG_0001.jpg'; subject_numero=6; asr_context=@{ rows=@(10) } }
) }
$r = Test-Pass2B2FRank1MaterialIntegrity -Material $materialOk -Ctx $script:Ctx
Assert-True ([bool]$r.ok) 'material Pass2B_2F valide accepte'

$materialExcluded = @{ photo_units=@(
  @{ photo_id='JPG/IMG_0004.jpg'; subject_numero=0; asr_context=@{ rows=@() } }
) }
$r = Test-Pass2B2FRank1MaterialIntegrity -Material $materialExcluded -Ctx $script:Ctx
Assert-HasCode $r 'photo_exclue' 'unite photo exclue rejetee'

$materialWrongSubject = @{ photo_units=@(
  @{ photo_id='JPG/IMG_0003.jpg'; subject_numero=6; asr_context=@{ rows=@(10) } }
) }
$r = Test-Pass2B2FRank1MaterialIntegrity -Material $materialWrongSubject -Ctx $script:Ctx
Assert-HasCode $r 'photo_mauvais_sujet_humain' 'unite photo au mauvais sujet rejetee'

$materialUnknown = @{ photo_units=@(
  @{ photo_id='JPG/IMG_9999.jpg'; subject_numero=6; asr_context=@{ rows=@() } }
) }
$r = Test-Pass2B2FRank1MaterialIntegrity -Material $materialUnknown -Ctx $script:Ctx
Assert-HasCode $r 'photo_inconnue' 'unite photo inconnue rejetee'

$materialBadAsr = @{ photo_units=@(
  @{ photo_id='JPG/IMG_0001.jpg'; subject_numero=6; asr_context=@{ rows=@(999) } }
) }
$r = Test-Pass2B2FRank1MaterialIntegrity -Material $materialBadAsr -Ctx $script:Ctx
Assert-HasCode $r 'asr_row_inconnue' 'unite photo avec ASR absente rejetee'

$materialDuplicate = @{ photo_units=@(
  @{ photo_id='JPG/IMG_0001.jpg'; subject_numero=6; asr_context=@{ rows=@() } },
  @{ photo_id='JPG/IMG_0001.jpg'; subject_numero=6; asr_context=@{ rows=@() } }
) }
$r = Test-Pass2B2FRank1MaterialIntegrity -Material $materialDuplicate -Ctx $script:Ctx
Assert-HasCode $r 'photo_dupliquee' 'unite photo dupliquee rejetee'

# --- Publication Pass3E : artefacts de validation et reprise -----------------
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('cr_pass2f_guard_' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
function Write-TestJsonFile {
  param([string] $Path, $Obj)
  $dir = [IO.Path]::GetDirectoryName($Path)
  if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $json = ($Obj | ConvertTo-Json -Depth 100)
  [IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}
function New-Pass2FArtifactFixture {
  param(
    [string] $Name,
    [bool] $WithValidation = $false,
    [bool] $ValidationOk = $true,
    [string] $ValidationStatus = 'ok',
    [string] $HashMode = 'current',
    [bool] $ValidOutput = $true
  )
  $dir = Join-Path $tempRoot $Name
  $parsedDir = Join-Path $dir 'parsed_outputs'
  $inputsDir = Join-Path $dir 'inputs'
  New-Item -ItemType Directory -Path $parsedDir -Force | Out-Null
  New-Item -ItemType Directory -Path $inputsDir -Force | Out-Null
  $inputObj = @{
    schema = 'cr_refere_preventif.pass2f.chunk_input.v1'
    source_pass = '2F'
    chunk_index = 1
    chunk_total = 1
    photos_count = 1
    units_count = 1
    split_reason = 'test_guard'
    sujet_cible = @{ numero=6; titre='Sujet 6'; localisation=''; description='' }
    budget = @{}
    data = @{ sequence_documentaire=@(@{ kind='photo'; photo='IMG_0001.jpg'; photo_rel_native='JPG/IMG_0001.jpg'; subject_numero=6; asr=@{ available=$true; rows=@(10) } }) }
  }
  $responseObj = $(if ($ValidOutput) { New-TestOutput } else { New-TestOutput -Subject 11 })
  $responsePath = Join-Path $parsedDir 'subject_006_chunk_01_response.json'
  $inputPath = Join-Path $inputsDir 'subject_006_chunk_01_input.json'
  Write-TestJsonFile -Path $inputPath -Obj $inputObj
  Write-TestJsonFile -Path $responsePath -Obj $responseObj
  $validationPath = Join-Path $parsedDir 'subject_006_chunk_01_validation.json'
  if ($WithValidation) {
    $hash = (Get-FileHash -LiteralPath $responsePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $validatedHash = $hash
    if ($HashMode -eq 'none') { $validatedHash = '' }
    if ($HashMode -eq 'mismatch') { $validatedHash = '0000000000000000000000000000000000000000000000000000000000000000' }
    $validationErrors = @()
    if (-not $ValidationOk) { $validationErrors = @(@{ code='photo_inconnue'; message='diagnostic source conserve' }) }
    $validationObj = @{ ok=$ValidationOk; status=$ValidationStatus; errors=@($validationErrors); warnings=@(); counts=@{ expected_subject=6 }; response_sha256=$validatedHash }
    Write-TestJsonFile -Path $validationPath -Obj $validationObj
  }
  return [pscustomobject]@{ Dir=$dir; Response=$responsePath; Input=$inputPath; Validation=$validationPath }
}

$r = Test-Pass2FOutputContract -Parsed $valid -Chunk $chunkOne -Plan $planOne
Assert-True (-not [bool]$r.ok) 'not_configured refuse par defaut'
Assert-HasCode $r 'validation_not_configured' 'not_configured expose un diagnostic bloquant'
$r = Test-Pass2FOutputContract -Parsed $valid -Chunk $chunkOne -Plan $planOne -AllowValidationNotConfigured
Assert-True ([bool]$r.ok) 'not_configured accepte uniquement sur option explicite'
Assert-Eq ([string]$r.status) 'not_configured' 'statut not_configured explicite'

$guardChunk = @{ chunk_index=1; chunk_total=1; photos_count=0; units_count=0; data=@{ sequence_documentaire=@() } }
$guardPlan = @{ numero=6 }
$msg = ''
try { Invoke-Pass2FChunkAndRecord -Chunk $guardChunk -Plan $guardPlan -OutDir (Join-Path $tempRoot 'guard1') -MaxTokens 10 -Temperature 0 -OfflineRawResponses @('{}') | Out-Null } catch { $msg = $_.Exception.Message }
Assert-True ($msg.Contains('OfflineTest')) 'offline implicite refuse'
$msg = ''
try { Invoke-Pass2FChunkAndRecord -Chunk $guardChunk -Plan $guardPlan -OutDir (Join-Path $tempRoot 'guard2') -MaxTokens 10 -Temperature 0 | Out-Null } catch { $msg = $_.Exception.Message }
Assert-True ($msg.Contains('SourceContext obligatoire')) 'production sans SourceContext refusee avant appel'
$msg = ''
try { Invoke-Pass2FChunkAndRecord -Chunk $guardChunk -Plan $guardPlan -OutDir (Join-Path $tempRoot 'guard3') -MaxTokens 10 -Temperature 0 -OfflineTest -SourceContext $script:Ctx | Out-Null } catch { $msg = $_.Exception.Message }
Assert-True ($msg.Contains('OfflineRawResponses')) 'OfflineTest sans matiere hors ligne refuse'
$msg = ''
try { Invoke-Pass2FChunkAndRecord -Chunk $guardChunk -Plan $guardPlan -OutDir (Join-Path $tempRoot 'guard4') -MaxTokens 10 -Temperature 0 -AllowValidationNotConfigured -SourceContext $script:Ctx | Out-Null } catch { $msg = $_.Exception.Message }
Assert-True ($msg.Contains('reserve au mode hors ligne')) 'not_configured hors ligne explicite uniquement'

$twoCtx = @(
  @{photo='IMG_0001.jpg'; apport_contextuel='photo A'},
  @{photo='IMG_0002.jpg'; apport_contextuel='photo B'}
)
$twoPoints = @(
  (New-TestPoint -Photos @('IMG_0001.jpg') -AsrRows @(10)),
  (New-TestPoint -Photos @('IMG_0002.jpg') -AsrRows @(10))
)
$r = Test-Pass2FOutputContract -Parsed (New-TestOutput -PhotoContexts $twoCtx -Points $twoPoints) -Chunk $chunkTwo -Plan $planOne -SourceContext $script:Ctx
Assert-True ([bool]$r.ok) 'sujet multi-photos avec lignes ASR partagees accepte'
Assert-Eq ([int]$r.counts.expected_photos) 2 'les deux photos du chunk sont attendues'

$dupAsr = New-TestOutput -Points @(New-TestPoint -AsrRows @(10,10))
$r = Test-Pass2FOutputContract -Parsed $dupAsr -Chunk $chunkOne -Plan $planOne -SourceContext $script:Ctx
Assert-True ([bool]$r.ok) 'duplication de reference ASR ne provoque pas de faux rejet'
Assert-Eq ([int]$r.counts.cited_asr_rows) 1 'references ASR dedupliquees dans les compteurs'

$fxLegacy = New-Pass2FArtifactFixture -Name 'legacy_no_validation'
$state = Test-Pass2FResponseArtifact -Path $fxLegacy.Response -SourceContext $script:Ctx
Assert-True ([bool]$state.ok) 'sortie historique sans validation revalidee et acceptee'
Assert-Eq ([string]$state.validation_mode) 'revalidated_missing_artifact' 'revalidation historique tracee'
$state = Test-Pass2FResponseArtifact -Path $fxLegacy.Response
Assert-True (-not [bool]$state.ok) 'sortie sans validation refusee sans SourceContext'
$explicit = @(Resolve-P3EChunkPaths -Subject 6 -Pass2FOutDir '' -ExplicitPaths @($fxLegacy.Response))
Assert-Eq (@($explicit).Count) 1 'chemin explicite historique resolu sans elargir le lot'
$missingExplicit = Join-Path $tempRoot 'absent_response.json'
$msg = ''
try { Resolve-P3EChunkPaths -Subject 6 -Pass2FOutDir '' -ExplicitPaths @($missingExplicit) | Out-Null } catch { $msg = $_.Exception.Message }
Assert-True ($msg.Contains('introuvable')) 'chemin Pass2F explicite absent bloque'
Assert-True ($msg.Contains('absent_response.json')) 'chemin manquant est nomme dans le diagnostic'

$msg = ''
try { Resolve-P3EChunkPaths -Subject 6 -Pass2FOutDir '' -ExplicitPaths @($fxLegacy.Response, $fxLegacy.Response) | Out-Null } catch { $msg = $_.Exception.Message }
Assert-True ($msg.Contains('duplique')) 'chemin Pass2F explicite duplique refuse'

$compactTxt = @{ numero=6; titre='Sujet 6'; localisation=''; description='' }
$usr = Get-P3EUserText -CompactObj $compactTxt -SubjectNumero 6 -ChunkPaths @($fxLegacy.Response) -Pass2EAbsent -SourceContext $script:Ctx
Assert-True ($usr.Contains('[SOURCE PASS2F subject_006_chunk_01')) 'matiere Pass2F valide injectee apres controle'
Assert-True ($usr.Contains('Synthese de test.')) 'reponse validee effectivement lue'

$fxLegacyBad = New-Pass2FArtifactFixture -Name 'legacy_bad_no_validation' -ValidOutput $false
$state = Test-Pass2FResponseArtifact -Path $fxLegacyBad.Response -SourceContext $script:Ctx
Assert-True (-not [bool]$state.ok) 'sortie historique avec reference metier fausse rejetee'
Assert-True (@($state.errors | ForEach-Object { [string]$_.code }) -contains 'subject_repond_invalide') 'revalidation historique expose le motif metier'

$fxHash = New-Pass2FArtifactFixture -Name 'valid_hash' -WithValidation $true
$state = Test-Pass2FResponseArtifact -Path $fxHash.Response -SourceContext $script:Ctx
Assert-True ([bool]$state.ok) 'validation avec empreinte conforme acceptee'
Assert-Eq ([string]$state.validation_mode) 'validation_artifact_hash' 'mode validation par empreinte trace'
$fxLegacyHash = New-Pass2FArtifactFixture -Name 'legacy_no_hash' -WithValidation $true -HashMode 'none'
$state = Test-Pass2FResponseArtifact -Path $fxLegacyHash.Response
Assert-True ([bool]$state.ok) 'validation historique sans empreinte acceptee hors revalidation'
Assert-Eq ([string]$state.validation_mode) 'legacy_validation_artifact' 'compatibilite historique tracee'

$fxBad = New-Pass2FArtifactFixture -Name 'bad_validation' -WithValidation $true -ValidationOk $false -ValidationStatus 'failed'
$state = Test-Pass2FResponseArtifact -Path $fxBad.Response -SourceContext $script:Ctx
Assert-True (-not [bool]$state.ok) 'validation enregistree en echec rejetee'
Assert-True (@($state.errors | ForEach-Object { [string]$_.code }) -contains 'validation_source_photo_inconnue') 'diagnostic source conserve'
$msg = ''
try { Assert-P3EChunkPathsPublishable -Paths @($fxBad.Response) -SourceContext $script:Ctx | Out-Null } catch { $msg = $_.Exception.Message }
Assert-True ($msg.Contains('subject_006_chunk_01_response.json')) 'reprise avec artefact invalide bloquee avec nom de fichier'
Assert-True ($msg.Contains('validation_artifact_non_ok')) 'reprise avec artefact invalide expose le code'

$fxNotConfigured = New-Pass2FArtifactFixture -Name 'not_configured' -WithValidation $true -ValidationStatus 'not_configured'
$state = Test-Pass2FResponseArtifact -Path $fxNotConfigured.Response -SourceContext $script:Ctx
Assert-True (-not [bool]$state.ok) 'validation not_configured jamais publiable'
Assert-True (@($state.errors | ForEach-Object { [string]$_.code }) -contains 'validation_not_configured_publiee') 'not_configured publie identifie'

$fxMismatch = New-Pass2FArtifactFixture -Name 'hash_mismatch' -WithValidation $true -HashMode 'mismatch'
$state = Test-Pass2FResponseArtifact -Path $fxMismatch.Response -SourceContext $script:Ctx
Assert-True (-not [bool]$state.ok) 'validation obsolete par empreinte rejetee'
Assert-True (@($state.errors | ForEach-Object { [string]$_.code }) -contains 'validation_response_hash_mismatch') 'ecart empreinte identifie'

$resumeDir = Join-Path $tempRoot 'resume_with_invalid'
New-Item -ItemType Directory -Path $resumeDir -Force | Out-Null
Copy-Item -LiteralPath $fxHash.Response -Destination (Join-Path $resumeDir 'subject_006_chunk_01_response.json')
Copy-Item -LiteralPath $fxHash.Validation -Destination (Join-Path $resumeDir 'subject_006_chunk_01_validation.json')
Copy-Item -LiteralPath $fxBad.Response -Destination (Join-Path $resumeDir 'subject_006_chunk_02_response.json')
Copy-Item -LiteralPath $fxBad.Validation -Destination (Join-Path $resumeDir 'subject_006_chunk_02_validation.json')
$foundResume = @(Resolve-P3EChunkPaths -Subject 6 -Pass2FOutDir $resumeDir -ExplicitPaths @())
Assert-Eq (@($foundResume).Count) 2 'la decouverte voit les deux reponses preexistantes'
$msg = ''
try { Assert-P3EChunkPathsPublishable -Paths @($foundResume) -SourceContext $script:Ctx | Out-Null } catch { $msg = $_.Exception.Message }
Assert-True ($msg.Contains('subject_006_chunk_02_response.json')) 'une reprise ne publie pas le lot contenant un artefact invalide'

try {
  $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
  $baseTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  if ($resolvedTemp.StartsWith($baseTemp, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolvedTemp -Recurse -Force }
} catch { }

# Controle J58 facultatif : lecture seule, aucun recalcul de t_audio.
$j58Photos = 'C:\Affaires\2026-J58\AE_Expert_captations\accedit-2026-03-17\photos\photos.csv'
$j58Assign = 'C:\Affaires\2026-J58\AE_Expert_captations\accedit-2026-03-17\photos\photo_subject_assignments.json'
if ((Test-Path -LiteralPath $j58Photos -PathType Leaf) -and (Test-Path -LiteralPath $j58Assign -PathType Leaf)) {
  $csvText = [System.IO.File]::ReadAllText($j58Photos, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
  $jrows = @($csvText | ConvertFrom-Csv -Delimiter ';')
  $ja = (Get-Content -LiteralPath $j58Assign -Raw | ConvertFrom-Json)
  $jassignments = @{}
  $jphotos = @()
  foreach ($a in @($ja.assignments)) { $jassignments[[string]$a.photo_rel_native] = @{ status=[string]$a.status; subject_numero=[int]$a.subject_numero } }
  foreach ($r in @($jrows)) { $jphotos += @{ photo_rel_native=[string]$r.photo_rel_native; photo=[string]$r.nom_fichier_image } }
  $jctx = @{ photos=@($jphotos); assignments=$jassignments; asr_rows=@() }
  $junits = @()
  foreach ($a in @($ja.assignments)) {
    if (([string]$a.status -eq 'affectee') -and ([int]$a.subject_numero -eq 6)) {
      $junits += @{ photo_id=[string]$a.photo_rel_native; subject_numero=6; asr_context=@{ rows=@() } }
    }
  }
  Assert-Eq (@($jrows).Count) 73 'J58 : 73 photographies'
  Assert-Eq (@($junits).Count) 62 'J58 : 62 photographies affectees au sujet 6'
  Assert-Eq (@($ja.assignments | Where-Object { [string]$_.status -eq 'exclue' }).Count) 11 'J58 : 11 exclusions'
  $jr = Test-Pass2B2FRank1MaterialIntegrity -Material @{ photo_units=@($junits) } -Ctx $jctx
  Assert-True ([bool]$jr.ok) 'J58 : les 62 affectations sujet 6 respectent les invariants'
} else {
  Write-Host 'SKIP J58 : donnees de reference non accessibles.'
}

Write-Host ("TOTAL checks=" + $script:Checks + " failures=" + $script:Failures)
if ($script:Failures -gt 0) { exit 1 }
