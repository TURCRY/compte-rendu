# =============================================================================
# LOT REFERE-E2E-2 : orchestrateur du mode production -RunReferePipeline.
# Charge par dot-source depuis cr_refere_preventif_pipeline_json.ps1 (ASCII).
# Reutilise UNIQUEMENT les fonctions validees du pipeline. Aucune logique
# dupliquee ; la chaine est : Pass2F -> Pass2B_2F 36 batches -> consolidation
# hierarchique 6G -> refere_global_meeting.json -> Pass3 A/B/C/D_refere ->
# Pass3E_refere tous sujets utiles -> assemblage refere -> renderer DOCX.
# =============================================================================
function Add-RefereProgressCalls {
  param([int] $Llm = 0, [int] $Http = 0)
  if ($null -ne $script:RefereProgress) {
    $script:RefereProgress.llm_calls += $Llm
    $script:RefereProgress.http_calls += $Http
  }
}

function Invoke-RefereProductionPipeline {
  param(
    [hashtable] $Paths,
    [hashtable] $Ctx,
    [string]    $OutDir,
    [string]    $StartedAt,
    [bool]      $Exec,
    [string]    $ApiBase = '',
    [string]    $ApiKey = '',
    [string]    $LotLabel = 'E2E-2',
    [string]    $SegmentsDir = '',
    [string]    $Pass2ECompactsDir = '',
    [string]    $Pass2FChunksDir = '',
    [string]    $ContextJsonPath = '',
    [string]    $BudgetReferenceGlobalJson = '',
    [string]    $ModelPass2F = 'pass2f_local',
    [int]       $MaxTokensPass2F = 1800,
    [string]    $ModelPass2B2F = 'report_remote',
    [int]       $MaxBatchChars = 35000,
    [int]       $MaxBatchTokens = 9625,
    [int]       $MaxTokensIntermediate = 4096,
    [string]    $RendererBase = ''
  )
  $script:P3LotLabel = $(if ($LotLabel) { [string]$LotLabel } else { 'E2E-2' })
  $script:P3Exec = [bool]$Exec
  if (-not $OutDir) { throw '[cr_refere_preventif] REFERE-E2E-2 : -OutDir requis.' }
  Ensure-Dir $OutDir
  $p3Root = Join-Path $OutDir 'pass3_refere'
  $p2Root = Join-Path $OutDir 'pass2b2f'
  Ensure-Dir $p3Root
  Ensure-Dir $p2Root
  $mode = $(if ($Exec) { 'execute' } else { 'plan' })
  $llmTotal = 0
  $httpTotal = 0
  $rows = New-Object System.Collections.ArrayList
  $artifacts = New-Object System.Collections.ArrayList
  $refereGlobalPath = ''
  $refereGlobalFinalPath = ''
  $refereGlobalBySujetPath = ''
  $docxPath = ''
  $phase = 'init'
  try {
    if ($Exec) {
      $script:HttpBlocked = $false
      $bApi = $ApiBase
      if (-not $bApi) { $bApi = [string][Environment]::GetEnvironmentVariable('PIPELINE_API_BASE') }
      if (-not $bApi) { $bApi = 'http://192.168.1.20:5055' }
      $kApi = $ApiKey
      if (-not $kApi) { $kApi = [string][Environment]::GetEnvironmentVariable('PIPELINE_API_KEY') }
      if (-not $kApi) { $kApi = [string][Environment]::GetEnvironmentVariable('ADAPTER_API_KEY') }
      if (-not $kApi) { throw '[cr_refere_preventif] REFERE-E2E-2 : cle API manquante (PIPELINE_API_KEY / ADAPTER_API_KEY / -ApiKey).' }
      $script:AdapterApiBase = $bApi
      $script:AdapterApiKey  = $kApi
      $script:LlmTimeoutSec  = 900
      $script:AdapterAlias   = Resolve-Pass2FModelRoute $ModelPass2F
    } else {
      $script:HttpBlocked = $true
    }
    $phase = 'perimeter'
    $assignByBase = @{}
    foreach ($relK in @($Ctx.assignments.Keys)) {
      $bK = New-PhotoKey $relK
      $assignByBase[$bK] = $Ctx.assignments[$relK]
    }
    $affected = @{}
    $photosAffectees = 0
    $photosExclues = 0
    foreach ($ph in @($Ctx.photos)) {
      $baseK = New-PhotoKey $ph.photo_rel_native
      $asg = $null
      if ($Ctx.assignments.ContainsKey($ph.photo_rel_native)) { $asg = $Ctx.assignments[$ph.photo_rel_native] }
      elseif ($assignByBase.ContainsKey($baseK)) { $asg = $assignByBase[$baseK] }
      if ($null -eq $asg) { continue }
      if ([string]$asg.status -eq 'affectee') {
        $photosAffectees++
        $snA = [int]$asg.subject_numero
        if ($affected.ContainsKey($snA)) { $affected[$snA] = [int]$affected[$snA] + 1 } else { $affected[$snA] = 1 }
      } elseif ([string]$asg.status -eq 'exclue') { $photosExclues++ }
    }
    $sujetsAvecPhotos = @($affected.Keys | Sort-Object)
    $phase = 'pass2f'
    $expectedChunkCalls = 0
    $pass2fRows = New-Object System.Collections.ArrayList
    $chunkEntryCount = 0
    $plannedChunkBySubject = @{}
    foreach ($sn in @($sujetsAvecPhotos)) {
      $snInt = [int]$sn
      $subjectCanon = $null
      if ($Ctx.sujets_by_numero.ContainsKey($snInt)) { $subjectCanon = $Ctx.sujets_by_numero[$snInt] }
      $subjectPhotos = @($Ctx.photos | Where-Object {
        $b2 = New-PhotoKey $_.photo_rel_native
        $ok2 = $false
        if ($Ctx.assignments.ContainsKey($_.photo_rel_native)) { $ok2 = ([string]$Ctx.assignments[$_.photo_rel_native].status -eq 'affectee' -and [int]$Ctx.assignments[$_.photo_rel_native].subject_numero -eq $snInt) }
        elseif ($assignByBase.ContainsKey($b2)) { $ok2 = ([string]$assignByBase[$b2].status -eq 'affectee' -and [int]$assignByBase[$b2].subject_numero -eq $snInt) }
        return $ok2
      })
      $titleP = ''
      $locP = ''
      $descP = ''
      if ($null -ne $subjectCanon) {
        $titleP = [string]$subjectCanon.titre; $locP = [string]$subjectCanon.localisation; $descP = [string]$subjectCanon.description
      }
      if (-not $titleP) {
        $firstAsg = $null
        foreach ($phX in @($subjectPhotos)) {
          $bX = New-PhotoKey $phX.photo_rel_native
          if ($Ctx.assignments.ContainsKey($phX.photo_rel_native)) { $firstAsg = $Ctx.assignments[$phX.photo_rel_native]; break }
          elseif ($assignByBase.ContainsKey($bX)) { $firstAsg = $assignByBase[$bX]; break }
        }
        if ($null -ne $firstAsg) { $titleP = [string]$firstAsg.subject_title; $locP = [string]$firstAsg.subject_location }
      }
      $subjectP = @{ numero=$snInt; titre=$titleP; localisation=$locP; description=$descP }
      $streamP = New-SubjectUnitStream -Subject $subjectP -Photos $subjectPhotos -AsrRows $Ctx.asr_rows -Before ([double]$Ctx.asr_window.before_sec) -After ([double]$Ctx.asr_window.after_sec) -CohortGapSec $script:CohortGapSec
      $planP = New-ChunkPlanForSubject -Stream $streamP -Budget $script:BudgetPass2F -IdAffaire $Paths.IdAffaire -IdCaptation $Paths.IdCaptation -AsrRows $Ctx.asr_rows -AsrEnd 0.0
      Write-SubjectArtifacts -Stream $streamP -Plan $planP -OutDir $OutDir -IdAffaire $Paths.IdAffaire -IdCaptation $Paths.IdCaptation
      $nChunks = [int]$planP.chunk_count
      $plannedChunkBySubject[$snInt] = $nChunks
      $expectedChunkCalls += $nChunks
      if ($Exec) {
        foreach ($chP in @($planP.chunks)) {
          $chunkEntryCount++
          Write-CrInfo ('[E2E-2 EXEC] Pass2F sujet ' + $snInt + ' chunk ' + [int]$chP.chunk_index + '/' + $nChunks + ' (' + $chunkEntryCount + ')')
          $e = Invoke-Pass2FChunkAndRecord -Chunk $chP -Plan $planP -OutDir $OutDir -MaxTokens $MaxTokensPass2F -Temperature 0.2 -AliasLogique $ModelPass2F
          $llmTotal += [int]$e.actual_llm_calls
          $httpTotal += [int]$e.actual_http_calls
          if ($null -eq $script:llmEntries) { $script:llmEntries = New-Object System.Collections.ArrayList }
          [void]$script:llmEntries.Add($e)
          Add-RefereProgressCalls -Llm ([int]$e.actual_llm_calls) -Http ([int]$e.actual_http_calls)
          if ($e.error -or (-not [bool]$e.json_parse_ok) -or [bool]$e.truncated_or_invalid_response -or ([string]$e.finish_reason -eq 'length')) {
            throw ('[cr_refere_preventif] REFERE-E2E-2 : Pass2F ' + [string]$e.tag + ' invalide (json_parse_ok=' + [bool]$e.json_parse_ok + ' finish=' + ([string]$e.finish_reason) + ' error=' + ([string]$e.error) + ') - aucun retry, STOP.')
          }
        }
      }
      $prow = @{
        phase = 'Pass2F'
        subject = $snInt
        titre = $titleP
        photo_count = @($subjectPhotos).Count
        unit_count = @($streamP.units).Count
        chunk_count = $nChunks
        exec = [bool]$Exec
      }
      [void]$rows.Add($prow)
      [void]$pass2fRows.Add($prow)
    }
    [void]$rows.Add(@{ phase='Pass2F_total'; expected_llm_calls=$expectedChunkCalls; executed_llm_calls=$chunkEntryCount })
    $phase = 'pass2b2f'
    $segDirP = [string]$SegmentsDir
    if (-not $segDirP) { $segDirP = Resolve-GeneralistSegmentsDir -CompteRenduDir $Paths.CompteRenduDir }
    if (-not $segDirP) {
      throw '[cr_refere_preventif] REFERE-E2E-2 : segments du run CR generaliste introuvables (fournir -GeneralistSegmentsDir ou verifier le run compte_rendu_LLM).'
    }
    $segDirP = [System.IO.Path]::GetFullPath($segDirP)
    Write-CrInfo ('[E2E-2 ' + $mode + '] Pass2B_2F DryRun segments_dir=' + $segDirP)
    $p2b = Invoke-Pass2B2FDryRun -Ctx $Ctx -SegmentsDir $segDirP -OutDir $OutDir -ModelAlias $ModelPass2B2F -ExpectedAffected $photosAffectees -ExpectedExcluded $photosExclues -StartedAt $StartedAt -MaxBatchChars $MaxBatchChars -MaxBatchTokens $MaxBatchTokens
    $batchesCount = 0
    if ($null -ne $p2b.pack) { $batchesCount = @($p2b.pack.batches).Count }
    if ($batchesCount -le 0) { $batchesCount = [int]$p2b.summary.batches_count }
    [void]$rows.Add(@{ phase='Pass2B2F_batches'; expected_llm_calls=$batchesCount; batch_manifest=[string]$p2b.summary.manifest; exec=[bool]$Exec })
    $mergePath2 = ''
    $batchParsedDir2 = ''
    $canonical6G = ''
    if ($Exec) {
      if (-not (Test-Path -LiteralPath $segDirP -PathType Container)) { throw '[cr_refere_preventif] REFERE-E2E-2 : segments_dir introuvable : ' + $segDirP }
      Write-CrInfo ('[E2E-2 EXEC] Pass2B_2F run complet : batches=' + $batchesCount + ' alias=' + $ModelPass2B2F + ' (un appel par batch, aucun retry)')
      Add-RefereProgressCalls -Llm $batchesCount -Http $batchesCount
      $rcP = Invoke-Pass2B2FRunCompleteBatches -Material $p2b.material -Pack $p2b.pack -OutDir $OutDir -ModelAlias $ModelPass2B2F -StartedAt $StartedAt -MaxBatchChars $MaxBatchChars -MaxBatchTokens $MaxBatchTokens -ApiBaseOverride $script:AdapterApiBase -ApiKeyOverride $script:AdapterApiKey -LotLabel $script:P3LotLabel
      $llmTotal += [int]$rcP.summary.calls
      $httpTotal += [int]$rcP.summary.calls
      if (-not [bool]$rcP.summary.ok) {
        throw ('[cr_refere_preventif] REFERE-E2E-2 : run complet Pass2B_2F en echec (manifest=' + [string]$rcP.summary.manifest + ') - aucun retry.')
      }
      $mergePath2 = [string]$rcP.summary.refere_global_meeting_path
      $lotSfx = ($script:P3LotLabel -split '-')[-1]
      $execName2 = 'pass2b2f' + $lotSfx + '_execute'
      $batchParsedDir2 = Join-Path $p2Root (Join-Path $execName2 'parsed_outputs')
      if (-not (Test-Path -LiteralPath $batchParsedDir2 -PathType Container)) { throw '[cr_refere_preventif] REFERE-E2E-2 : parsed_outputs batch introuvable : ' + $batchParsedDir2 }
      [void]$rows.Add(@{ phase='Pass2B2F_run_complete'; ok=$true; batches=$batchesCount; merge=$mergePath2 })
      $phase = 'hierarchical_6g'
      $entriesJson2 = Join-Path $p2Root (Join-Path $execName2 'entries.json')
      Add-RefereProgressCalls -Llm 7 -Http 7
      $hierP = Invoke-Pass2B2FHierarchicalConsolidation -OutDir $OutDir -BatchOutputsDir $batchParsedDir2 -ExhaustiveJsonPath $mergePath2 -BatchEntriesJsonPath $entriesJson2 -ModelAlias $ModelPass2B2F -StartedAt $StartedAt -ApiBaseOverride $script:AdapterApiBase -ApiKeyOverride $script:AdapterApiKey -LotLabel $script:P3LotLabel -MaxTokensIntermediate $MaxTokensIntermediate -ConsolidateLlm
      $llmTotal += [int]$hierP.summary.llm_calls
      $httpTotal += [int]$hierP.summary.http_calls
      if (-not [bool]$hierP.summary.ok) {
        throw ('[cr_refere_preventif] REFERE-E2E-2 : consolidation 6G en echec (status=' + [string]$hierP.summary.status + ') - aucun retry.')
      }
      $canonical6G = [string]$hierP.summary.canonical_output
      [void]$rows.Add(@{ phase='Pass2B2F_6G'; ok=$true; groups=[int]$hierP.summary.groups_count; canonical=$canonical6G })
    } else {
      [void]$rows.Add(@{ phase='Pass2B2F_6G'; plan_only=$true; expected_llm_calls=7; note='consolidation 6G (6 intermediaires + 1 final) apres execute' })
    }
    $refereGlobalPath = $canonical6G
    if (-not $refereGlobalPath) {
      $candG = Join-Path $p2Root 'refere_global_meeting.json'
      if (Test-Path -LiteralPath $candG -PathType Leaf) { $refereGlobalPath = $candG }
    }
    $phase = 'pass3_abcd'
    $pass3GlobalPath = $refereGlobalPath
    if (-not $pass3GlobalPath -and $BudgetReferenceGlobalJson) {
      if (Test-Path -LiteralPath $BudgetReferenceGlobalJson -PathType Leaf) { $pass3GlobalPath = $BudgetReferenceGlobalJson }
    }
    $globalRawP = ''
    $globalObjP = $null
    if ($pass3GlobalPath -and (Test-Path -LiteralPath $pass3GlobalPath -PathType Leaf)) {
      $globalRawP = Read-P3RawText $pass3GlobalPath
      try { $globalObjP = $globalRawP | ConvertFrom-Json } catch { $globalObjP = $null }
    }
    $reducedTextP = ''
    if ($null -ne $globalObjP) {
      $redObjP = [ordered]@{}
      $redObjP['resume_global'] = Get-P3V $globalObjP 'resume_global'
      $aa = Get-P3V $globalObjP 'actions'
      $redObjP['actions'] = $(if ($null -eq $aa) { @() } else { @($aa) })
      $pp = Get-P3V $globalObjP 'problems'
      $redObjP['problems'] = $(if ($null -eq $pp) { @() } else { @($pp) })
      $dd = Get-P3V $globalObjP 'demandes_documents_globales'
      $redObjP['demandes_documents_globales'] = $(if ($null -eq $dd) { @() } else { @($dd) })
      $tt = Get-P3V $globalObjP 'themes'
      $redObjP['themes'] = $(if ($null -eq $tt) { @() } else { @($tt) })
      try { $reducedTextP = ($redObjP | ConvertTo-Json -Depth 100) } catch { $reducedTextP = '' }
    }
    $aliasMap3 = @{ 'A'='pass3a_remote'; 'B'='pass3b_remote'; 'C'='pass3c_remote'; 'D'='pass3d_remote'; 'E'='pass3e_remote' }
    $baseMap3  = @{ 'A'='pass3a_refere'; 'B'='pass3b_refere'; 'C'='pass3c_refere'; 'D'='pass3d_refere' }
    $jobs3 = New-Object System.Collections.ArrayList
    $partByPass = @{}
    if ($globalRawP) {
      foreach ($pass in @('A','B','C','D')) {
        $sys3 = Get-P3Text $pass
        if (-not $sys3) { throw ('[cr_refere_preventif] REFERE-E2E-2 : systeme Pass3' + $pass + ' absent des constantes.') }
        $pre3 = Get-P3Part $pass 'prefix'
        $suf3 = Get-P3Part $pass 'suffix'
        $jsonTxt3 = $globalRawP
        if ($pass -eq 'C') {
          if (-not $reducedTextP) { throw '[cr_refere_preventif] REFERE-E2E-2 : reduction Pass3C impossible.' }
          $jsonTxt3 = $reducedTextP
        }
        $usr3 = $pre3 + $jsonTxt3 + $suf3
        $al3 = [string]$aliasMap3[$pass]
        $bs3 = [string]$baseMap3[$pass]
        $diag3 = Get-P3BudgetDiag -Alias $al3 -SysText $sys3 -UsrText $usr3
        [void]$rows.Add(@{ phase='Pass3' + $pass; alias=$al3; input_tokens_est=[int]$diag3.final_input_tokens_est; available_input_tokens=[int]$diag3.available_input_tokens; remaining_tokens=[int]$diag3.remaining_tokens; fits=[bool]$diag3.fits; source_global=$pass3GlobalPath })
        [void]$jobs3.Add(@{ pass=$pass; base=$bs3; sys=$sys3; usr=$usr3; alias=$al3; diag=$diag3 })
      }
      if ($Exec) {
        if (-not (Test-Path -LiteralPath $pass3GlobalPath -PathType Leaf)) { throw ('[cr_refere_preventif] REFERE-E2E-2 : global Pass3 introuvable : ' + $pass3GlobalPath) }
        foreach ($j3 in @($jobs3)) {
          if (-not [bool]$j3.diag.fits) {
            throw ('[cr_refere_preventif] REFERE-E2E-2 : Pass3' + [string]$j3.pass + ' DOES_NOT_FIT (final_tokens_est=' + [int]$j3.diag.final_input_tokens_est + ') - aucun appel.')
          }
        }
        foreach ($j3 in @($jobs3)) {
          Write-CrInfo ('[E2E-2 EXEC] Pass3 ' + [string]$j3.pass + ' (alias ' + [string]$j3.alias + ')')
          Add-RefereProgressCalls -Llm 1 -Http 1
          $res3 = Invoke-P3Remote -ArtifactBase ([string]$j3.base) -SysTxt ([string]$j3.sys) -UsrTxt ([string]$j3.usr) -Alias ([string]$j3.alias) -ArtDir $p3Root -Pass ([string]$j3.pass) -CSource $(if ($j3.pass -eq 'C') { $globalObjP } else { $null })
          if ($res3.prompt_file) { [void]$artifacts.Add([string]$res3.prompt_file) }
          if (-not $res3.ok) { throw ('[cr_refere_preventif] REFERE-E2E-2 : Pass3 ' + [string]$j3.pass + ' en echec - aucun retry.') }
          $llmTotal++
          $httpTotal++
          if ([string]$res3.entry.finish_reason -eq 'length') { throw ('[cr_refere_preventif] REFERE-E2E-2 : Pass3 ' + [string]$j3.pass + ' finish_reason=length - STOP.') }
          $partByPass[[string]$j3.pass] = $res3.parsed
          if ($res3.raw_file) { [void]$artifacts.Add([string]$res3.raw_file) }
          if ($res3.parsed_file) { [void]$artifacts.Add([string]$res3.parsed_file) }
        }
      }
    } else {
      [void]$rows.Add(@{ phase='Pass3A-D'; fits=$null; note='global indisponible en mode ' + $mode + ' (fournir -RefereBudgetReferenceGlobalJson pour le plan) - budgets a verifier apres 6G.' })
    }


    # ============================================================================
    # REFERE-E2E-2 : Phase Pass3E_refere - tous les sujets utiles.
    # LOT REFERE-E2E-3D : un sujet est runnable si has_pass2e (synthese Pass2E
    # exploitable) OU has_pass2f (chunks Pass2F reels en EXEC / planifies en PLAN).
    # Un sujet documente uniquement par Pass2F (photographies affectees, sans ASR
    # general exploitable) est donc traite par Pass3E. Sujet sans Pass2E ni Pass2F
    # -> skipped sans echec global. Chunks Pass2F = sorties du run courant (exec)
    # ou d'un run valide de reference fourni en plan (optionnel).
    # ============================================================================
    $phase = 'pass3e'
    $badBudgetCount = 0
    $eRunnableCount = 0
    $eCtxUserText = ''
    $eCtxSystemText = ''
    if ($ContextJsonPath -and (Test-Path -LiteralPath $ContextJsonPath -PathType Leaf)) {
      try {
        $eCtxObjE = (Read-P3RawText $ContextJsonPath) | ConvertFrom-Json
        $eCtxV1 = Get-P3V $eCtxObjE 'system'
        if ($null -ne $eCtxV1) { $eCtxSystemText = [string]$eCtxV1 }
        $eCtxV2 = Get-P3V $eCtxObjE 'user'
        if ($null -ne $eCtxV2) { $eCtxUserText = [string]$eCtxV2 }
      } catch { $eCtxUserText = '' }
    }
    $eSysE = Get-P3Text 'E'
    if (-not $eSysE) { throw '[cr_refere_preventif] REFERE-E2E-2 : systeme Pass3E absent des constantes.' }
    $p2eDirE = [string]$Pass2ECompactsDir
    $p2eDirOkE = $false
    if ($p2eDirE -and (Test-Path -LiteralPath $p2eDirE -PathType Container)) { $p2eDirOkE = $true }
    if (-not $p2eDirOkE) {
      # LOT REFERE-E2E-3D : la matiere Pass2F (photographies affectees) suffit a
      # rendre un sujet runnable meme sans compact Pass2E. En EXEC, un dossier de
      # compacts absent reste une erreur de configuration bloquante : la matiere
      # Pass2E des autres sujets ne doit jamais etre perdue silencieusement.
      if ($Exec) {
        throw ('[cr_refere_preventif] REFERE-E2E-2 : Pass3E : compacts Pass2E introuvables (fournir -ReferePass2ECompactsDir). dir=' + [string]$p2eDirE)
      }
      Write-CrWarn ('[E2E-2 ' + $mode + '] Pass3E : compacts Pass2E absents en mode plan - sujets evalues sur la seule matiere Pass2F planifiee.')
    }
    $p2fOutE = Join-Path $OutDir 'parsed_outputs'
    $p2fChunkSrc = ''
    if (Test-Path -LiteralPath $p2fOutE -PathType Container) { $p2fChunkSrc = $p2fOutE }
    if (-not $p2fChunkSrc -and $Pass2FChunksDir) {
      if (Test-Path -LiteralPath $Pass2FChunksDir -PathType Container) { $p2fChunkSrc = [string]$Pass2FChunksDir }
    }
    # Univers Pass3E = referentiel canonique des sujets (Sujets.csv) + sujets a
    # chunks Pass2F planifies/reels + sujets presents comme compact Pass2E (si
    # dossier fourni). L'unite est le numero de sujet ; le compact est optionnel.
    $subjectUniverseE = @{}
    foreach ($snCan in @($Ctx.sujets_by_numero.Keys)) {
      $snCanI = [int]$snCan
      $canObjE = $Ctx.sujets_by_numero[$snCan]
      $subjectUniverseE[$snCanI] = @{ numero=$snCanI; titre=[string](Get-P3V $canObjE 'titre'); localisation=[string](Get-P3V $canObjE 'localisation'); description=[string](Get-P3V $canObjE 'description'); compact_path='' }
    }
    foreach ($snPl in @($plannedChunkBySubject.Keys)) {
      $snPlI = [int]$snPl
      if (-not $subjectUniverseE.ContainsKey($snPlI)) {
        $subjectUniverseE[$snPlI] = @{ numero=$snPlI; titre=''; localisation=''; description=''; compact_path='' }
      }
    }
    $compactFilesE = @()
    if ($p2eDirOkE) {
      $compactFilesE = @(Get-ChildItem -LiteralPath $p2eDirE -Filter 'sujet_*_compact.json' -File -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { $_.FullName })
    }
    foreach ($cfE in @($compactFilesE)) {
      $numCfE = 0
      if ($cfE -match 'sujet_(\d+)_compact\.json$') { $numCfE = [int]$Matches[1] }
      $cfObjE = $null
      try { $cfObjE = (Read-P3RawText $cfE) | ConvertFrom-Json } catch { $cfObjE = $null }
      if ($null -ne $cfObjE) {
        $vCfN = Get-P3V $cfObjE 'numero'
        if ($null -ne $vCfN) { $numCfE = [int]$vCfN }
      }
      if ($numCfE -le 0) { continue }
      if (-not $subjectUniverseE.ContainsKey($numCfE)) {
        $subjectUniverseE[$numCfE] = @{ numero=$numCfE; titre=''; localisation=''; description=''; compact_path=$cfE }
      } else {
        $entryCfE = $subjectUniverseE[$numCfE]
        $entryCfE.compact_path = $cfE
        $vCfT = Get-P3V $cfObjE 'titre'
        if (-not [string]$entryCfE.titre -and $null -ne $vCfT) { $entryCfE.titre = [string]$vCfT }
        $vCfL = Get-P3V $cfObjE 'localisation'
        if (-not [string]$entryCfE.localisation -and $null -ne $vCfL) { $entryCfE.localisation = [string]$vCfL }
      }
    }
    if (@($subjectUniverseE.Keys).Count -eq 0) {
      throw '[cr_refere_preventif] REFERE-E2E-2 : aucun sujet Pass3E a considerer (referentiel sujets vide, sans compacts ni photos).'
    }
    $eResults = New-Object System.Collections.ArrayList
    $eSkipped = New-Object System.Collections.ArrayList
    foreach ($numE in @($subjectUniverseE.Keys | Sort-Object)) {
      $subjEntryE = $subjectUniverseE[$numE]
      $compactPathE = [string]$subjEntryE.compact_path
      $compactE = $null
      if ($compactPathE -and (Test-Path -LiteralPath $compactPathE -PathType Leaf)) {
        try { $compactE = (Read-P3RawText $compactPathE) | ConvertFrom-Json } catch { $compactE = $null }
      }
      $titreE = [string]$subjEntryE.titre
      $locE = [string]$subjEntryE.localisation
      $descE = [string]$subjEntryE.description
      if ($null -ne $compactE) {
        $vTfE = Get-P3V $compactE 'titre'
        if (-not $titreE -and $null -ne $vTfE) { $titreE = [string]$vTfE }
        $vLfE = Get-P3V $compactE 'localisation'
        if (-not $locE -and $null -ne $vLfE) { $locE = [string]$vLfE }
        $vDfE = Get-P3V $compactE 'description'
        if (-not $descE -and $null -ne $vDfE) { $descE = [string]$vDfE }
      }
      $hasPass2eE = $false
      if ($null -ne $compactE -and (Has-P3Synthese $compactE)) { $hasPass2eE = $true }
      $chunkPathsE = @(Resolve-P3EChunkPaths -Subject $numE -Pass2FOutDir $p2fChunkSrc -ExplicitPaths @())
      $chunkCountE = @($chunkPathsE).Count
      $plannedCountE = 0
      if ($plannedChunkBySubject.ContainsKey($numE)) { $plannedCountE = [int]$plannedChunkBySubject[$numE] }
      $hasPass2fE = ($chunkCountE -gt 0 -or $plannedCountE -gt 0)
      $runnableE = ($hasPass2eE -or $hasPass2fE)
      $reasonE = 'no_material'
      if ($hasPass2eE -and $hasPass2fE) { $reasonE = 'pass2e+pass2f' }
      elseif ($hasPass2eE) { $reasonE = 'pass2e_only' }
      elseif ($hasPass2fE) { $reasonE = 'pass2f_only' }
      if (-not $runnableE) {
        $skipNoteE = 'no_material : ni synthese Pass2E exploitable ni matiere Pass2F (chunks reels/planifies) : sujet sans matiere, exclu sans echec global'
        [void]$rows.Add(@{ phase='Pass3E'; subject=$numE; titre=$titreE; alias=[string]$aliasMap3['E']; has_pass2e=$false; planned_pass2f_chunks=0; chunk_count=0; chunk_budget_mode='none'; runnable=$false; runnable_reason='no_material'; status='no_material'; fits=$false; excluded=$true; note=$skipNoteE })
        [void]$eSkipped.Add(@{ numero=$numE; titre=$titreE; raison='no_material : ni synthese Pass2E exploitable ni matiere Pass2F' })
        Write-CrWarn ('[E2E-2 ' + $mode + '] Pass3E sujet ' + $numE + ' : ' + $skipNoteE)
        continue
      }
      $eRunnableCount++
      $pass2eAbsentE = (-not $hasPass2eE)
      $compactUsrE = $compactE
      if ($pass2eAbsentE) {
        # LOT REFERE-E2E-3D : aucun artefact Pass2E artificiel. Get-P3EUserText
        # recoit un objet minimal (numero/titre/localisation/description) et le
        # flag -Pass2EAbsent pour annoncer l absence de synthese Pass2E.
        $compactUsrE = [pscustomobject]@{ numero=$numE; titre=$titreE; localisation=$locE; description=$descE }
      }
      $usrE = Get-P3EUserText -CompactObj $compactUsrE -SubjectNumero $numE -ChunkPaths @($chunkPathsE) -Pass2EAbsent:($pass2eAbsentE)
      if (-not [string]::IsNullOrWhiteSpace($eCtxUserText)) { $usrE = 'Consignes generales du dossier (champ user, contraignantes) :' + "`n" + $eCtxUserText + "`n`n" + $usrE }
      $diagE = Get-P3BudgetDiag -Alias ([string]$aliasMap3['E']) -SysText $eSysE -UsrText $usrE
      $budgetModeE = 'none'
      $pass2fMaxTokEstE = 0
      $conservativeTokE = [int]$diagE.final_input_tokens_est
      $effChunkCountE = $chunkCountE
      if ($chunkCountE -gt 0) {
        $budgetModeE = $(if ($Exec) { 'actual_chunks' } else { 'reference_chunks' })
      } elseif ($plannedCountE -gt 0) {
        # LOT REFERE-E2E-3C : en mode PLAN, les chunks Pass2F reels n existent pas
        # encore dans un OutDir neuf. Budget Pass3E conservateur et deterministe :
        # base (compact Pass2E + systeme + contexte) + nb chunks planifies x
        # MaxTokensPass2F (majorant de sortie d un chunk) + surcharge textuelle
        # fixe reelle injectee autour de chaque bloc (Get-P3EUserText).
        $budgetModeE = 'planned_max_output'
        $effChunkCountE = $plannedCountE
        $pass2fMaxTokEstE = [int]($plannedCountE * $MaxTokensPass2F)
        $ccE = '{0:D2}' -f $plannedCountE
        $fnE = 'subject_' + (Get-P3SujetNumeroStr $numE) + '_chunk_' + $ccE + '_response.json'
        $labelE = $fnE -replace '_response\.json$', ''
        $headInstrE = "`n`n===== MATIERE PASS2F DU SUJET " + (Get-P3SujetNumeroStr $numE) + " (blocs complets, ordre croissant, provenance conservee) ====="
        $headInstrE += "`nLes blocs Pass2F ci-dessous rassemblent les constats documentes (photographies) et les echanges associes pour ce sujet. Integre leurs apports factuels a la synthese finale en maintenant la distinction entre ce qui est declare oralement et ce qui est visible/documente. Ne transforme jamais un constat photographique en declaration orale, ni l'inverse. N'invente aucune relation non documentee."
        $noChunkMarkerE = "`n`n(Aucun bloc Pass2F disponible pour ce sujet dans ce test restreint.)"
        $wrapperE = "`n`n[SOURCE PASS2F " + $labelE + " -- " + $fnE + "]`n"
        $baseTokE = [int]$diagE.final_input_tokens_est
        $fixedOverheadTokE = [Math]::Max(0, (Estimate-Tokens $headInstrE) - (Estimate-Tokens $noChunkMarkerE))
        $chunkOverheadTokE = Estimate-Tokens $wrapperE
        $conservativeTokE = $baseTokE + $fixedOverheadTokE + [int]($plannedCountE * ($chunkOverheadTokE + $MaxTokensPass2F))
      }
      $availE = [int]$diagE.available_input_tokens
      $fitE = [bool]$diagE.fits
      $remainE = [int]$diagE.remaining_tokens
      if ($budgetModeE -eq 'planned_max_output') {
        $remainE = $availE - $conservativeTokE
        $fitE = ($remainE -ge 0)
      }
      [void]$rows.Add(@{ phase='Pass3E'; subject=$numE; titre=$titreE; alias=[string]$aliasMap3['E']; has_pass2e=$hasPass2eE; planned_pass2f_chunks=$plannedCountE; chunk_count=$effChunkCountE; planned_chunk_count=$plannedCountE; chunk_budget_mode=$budgetModeE; base_input_tokens_est=[int]$diagE.final_input_tokens_est; pass2f_max_tokens_est=$pass2fMaxTokEstE; conservative_input_tokens_est=$conservativeTokE; input_tokens_est=$conservativeTokE; available_input_tokens=$availE; remaining_tokens=$remainE; fits=[bool]$fitE; runnable=$true; runnable_reason=$reasonE; chunk_source=$(if ($p2fChunkSrc) { $p2fChunkSrc } else { 'aucun' }) })
      if (-not [bool]$fitE) { $badBudgetCount++ }
      if ($Exec) {
        if (-not [bool]$fitE) {
          throw ('[cr_refere_preventif] REFERE-E2E-2 : Pass3E sujet ' + $numE + ' DOES_NOT_FIT (conservative_input_tokens_est=' + $conservativeTokE + ') - aucun appel, STOP.')
        }
        if ($pass2eAbsentE -and $chunkCountE -le 0) {
          throw ('[cr_refere_preventif] REFERE-E2E-2 : Pass3E sujet ' + $numE + ' (pass2f_only) sans chunk reel Pass2F (planifies=' + $plannedCountE + ') - aucun appel, STOP.')
        }
        $baseE = 'pass3e_sujet_' + (Get-P3SujetNumeroStr $numE)
        Write-CrInfo ('[E2E-2 EXEC] Pass3E sujet ' + $numE + ' : FIT chunks=' + $chunkCountE + ' conservative_input_tokens_est=' + $conservativeTokE + ' reason=' + $reasonE)
        Add-RefereProgressCalls -Llm 1 -Http 1
        $resE = Invoke-P3Remote -ArtifactBase $baseE -SysTxt $eSysE -UsrTxt $usrE -Alias ([string]$aliasMap3['E']) -ArtDir $p3Root -Pass 'E'
        $llmTotal++
        $httpTotal++
        $entryE = $resE.entry
        if (-not $resE.ok -or $entryE.status -ne 'ok') {
          throw ('[cr_refere_preventif] REFERE-E2E-2 : Pass3E sujet ' + $numE + ' en echec (status=' + [string]$entryE.status + ') - aucun retry.')
        }
        if ($resE.prompt_file) { [void]$artifacts.Add([string]$resE.prompt_file) }
        if ($resE.raw_file) { [void]$artifacts.Add([string]$resE.raw_file) }
        if ($resE.parsed_file) { [void]$artifacts.Add([string]$resE.parsed_file) }
        if ([string]$entryE.finish_reason -eq 'length') { throw ('[cr_refere_preventif] REFERE-E2E-2 : Pass3E sujet ' + $numE + ' finish_reason=length - STOP.') }
        $sujDirE = Join-Path $p3Root 'sujets'
        Ensure-Dir $sujDirE
        $sujRespE = Join-Path $sujDirE ('sujet_' + (Get-P3SujetNumeroStr $numE) + '_synthese.json')
        Write-CrJsonAtomic -Path $sujRespE -Obj $resE.parsed
        Add-CrOutputFile $sujRespE
        [void]$artifacts.Add($sujRespE)
        $vParsTitre = Get-P3V $resE.parsed 'titre'
        $vParsAvis = Get-P3V $resE.parsed 'avis_participants'
        $vParsSynth = Get-P3V $resE.parsed 'synthese_echanges'
        $vParsConcl = Get-P3V $resE.parsed 'conclusion_expert'
        $vCompactLoc = Get-P3V $compactE 'localisation'
        if ($null -eq $vCompactLoc -and $locE) { $vCompactLoc = $locE }
        $sujObjE = [ordered]@{}
        $sujObjE['numero'] = $numE
        $sujObjE['titre'] = $(if ($titreE) { $titreE } elseif ($null -ne $vParsTitre) { [string]$vParsTitre } else { '' })
        $sujObjE['localisation'] = $(if ($null -ne $vCompactLoc) { [string]$vCompactLoc } else { '' })
        $sujObjE['avis_participants'] = $(if ($null -eq $vParsAvis) { @() } else { @($vParsAvis) })
        $sujObjE['synthese_echanges'] = $(if ($null -eq $vParsSynth) { @() } else { @($vParsSynth) })
        $sujObjE['conclusion_expert'] = $(if ($null -eq $vParsConcl) { @() } else { @($vParsConcl) })
        $sujObjE['synthese_file'] = $sujRespE
        [void]$eResults.Add(@{ numero = $numE; titre = $titreE; sujet_obj = $sujObjE; parsed = $resE.parsed })
        [void]$rows.Add(@{ phase='Pass3E'; subject=$numE; status='ok'; fits=$true; has_pass2e=$hasPass2eE; runnable_reason=$reasonE; chunks=@($chunkPathsE).Count; synthese_file=$sujRespE })
      }
    }
    [void]$rows.Add(@{ phase='Pass3E_total'; runnable_subjects=$eRunnableCount; ok_subjects=@($eResults).Count; skipped_subjects=@($eSkipped).Count })

    # ============================================================================
    # REFERE-E2E-2 : assemblage refere (EXEC) + appel renderer DOCX.
    # refere_global_by_sujet.json / refere_global_final.json ne touchent jamais
    # aux artefacts generalistes (global_by_sujet.json / global_final.json).
    # ============================================================================
    $refereGlobalBySujetPath = ''
    $refereGlobalFinalPath = ''
    $docxPath = ''
    if ($Exec) {
      $phase = 'assembly'
      foreach ($neededP in @('A', 'B', 'C', 'D')) {
        if (-not $partByPass.ContainsKey($neededP)) { throw ('[cr_refere_preventif] REFERE-E2E-2 : sortie Pass3' + $neededP + ' absente - assemblage impossible.') }
      }
      if (-not $pass3GlobalPath -or -not (Test-Path -LiteralPath $pass3GlobalPath -PathType Leaf)) {
        throw ('[cr_refere_preventif] REFERE-E2E-2 : global Pass3 introuvable pour assemblage : ' + [string]$pass3GlobalPath)
      }
      $sujListOut = New-Object System.Collections.ArrayList
      foreach ($erO in @($eResults)) { [void]$sujListOut.Add($erO.sujet_obj) }
      $sujManquantsOut = New-Object System.Collections.ArrayList
      foreach ($skO in @($eSkipped)) { [void]$sujManquantsOut.Add($skO) }
      $refereGlobalBySujetPath = Join-Path $p3Root 'refere_global_by_sujet.json'
      $bySujetObj = [ordered]@{
        schema = 'cr_refere_preventif.refere_global_by_sujet.v1'
        source_global = $pass3GlobalPath
        source_lot = [string]$script:P3LotLabel
        tous_sujets_traites = @($sujListOut).Count
        sujets = @($sujListOut)
        sujets_manquants = @($sujManquantsOut)
      }
      Write-CrJsonAtomic -Path $refereGlobalBySujetPath -Obj $bySujetObj
      Add-CrOutputFile $refereGlobalBySujetPath
      [void]$artifacts.Add($refereGlobalBySujetPath)

      $pA = $partByPass['A']
      $pB = $partByPass['B']
      $pC = $partByPass['C']
      $pD = $partByPass['D']
      $fin = [ordered]@{}
      $vDate = Get-P3V $pA 'date';          $fin['date'] = $(if ($null -ne $vDate) { $vDate } else { '' })
      $vLink = Get-P3V $pA 'link';          $fin['link'] = $(if ($null -ne $vLink) { $vLink } else { '' })
      $vResume = Get-P3V $pA 'resume';      $fin['resume'] = $(if ($null -ne $vResume) { [string]$vResume } else { '' })
      $vOduj = Get-P3V $pA 'ordre_du_jour'; $fin['ordre_du_jour'] = $(if ($null -eq $vOduj) { @() } else { @($vOduj) })
      $vThemes = Get-P3V $pB 'themes_abordes'; $fin['themes_abordes'] = $(if ($null -eq $vThemes) { @() } else { @($vThemes) })
      $vAct = Get-P3V $pC 'actions';        $fin['actions'] = $(if ($null -eq $vAct) { @() } else { @($vAct) })
      $vPersp = Get-P3V $pC 'perspectives'; $fin['perspectives'] = $(if ($null -eq $vPersp) { @() } else { @($vPersp) })
      $vAnn = Get-P3V $pC 'annexes';        $fin['annexes'] = $(if ($null -eq $vAnn) { @() } else { @($vAnn) })
      $vDem = Get-P3V $pD 'demandes_documents_globales'; $fin['demandes_documents_globales'] = $(if ($null -eq $vDem) { @() } else { @($vDem) })
      $fin['sujets'] = @($sujListOut)
      $refereGlobalFinalPath = Join-Path $p3Root 'refere_global_final.json'
      Write-CrJsonAtomic -Path $refereGlobalFinalPath -Obj $fin
      Add-CrOutputFile $refereGlobalFinalPath
      [void]$artifacts.Add($refereGlobalFinalPath)

      # Renderer DOCX (cr-render POST /render?format=docx). Un seul appel HTTP non
      # LLM, aucun retry silencieux ; echec => STOP.
      $renderBase = [string]$RendererBase
      if (-not $renderBase) { $renderBase = [string][Environment]::GetEnvironmentVariable('RENDERER_BASE') }
      if (-not $renderBase) { $renderBase = 'http://cr-render:8080' }
      $renderUrl = $renderBase.TrimEnd('/') + '/render?format=docx'
      $idAff = [string]$Paths.IdAffaire
      $idCap = [string]$Paths.IdCaptation
      $docxName = 'refere_compte_rendu_' + $idAff + '_' + $idCap + '_' + (Get-CrTimestampStamp) + '.docx'
      $docxPath = Join-Path $OutDir $docxName
      $finJson = $fin | ConvertTo-Json -Depth 100
      Write-CrInfo ('[E2E-2 EXEC] renderer DOCX : ' + $renderUrl)
      Add-RefereProgressCalls -Llm 0 -Http 1
      try {
        Invoke-WebRequest -Method POST -Uri $renderUrl -Headers @{ 'Content-Type' = 'application/json' } -Body $finJson -ContentType 'application/json' -OutFile $docxPath -TimeoutSec 600 -ErrorAction Stop
      } catch {
        # REFERE-E2E-3F : tracabilite enrichie du catch renderer (url, http_status,
        # response_body, exception). Echec toujours fatal : aucun retry silencieux.
        $renderErr = $_
        $rendererUrlLog = $renderUrl
        $httpStatusLog = $null
        $respBodyLog = $null
        $exMsgLog = [string]::Empty
        try { $exMsgLog = [string]$renderErr.Exception.Message } catch { }
        try {
          $innerErr = $null
          if ($null -ne $renderErr.Exception) { $innerErr = $renderErr.Exception.InnerException }
          if ($null -ne $innerErr -and -not [string]::IsNullOrWhiteSpace([string]$innerErr.Message)) {
            $exMsgLog = $exMsgLog + ' | ' + [string]$innerErr.Message
          }
        } catch { }
        try {
          $scErrProp = $null
          if ($null -ne $renderErr.Exception) { $scErrProp = $renderErr.Exception.PSObject.Properties['StatusCode'] }
          if ($null -ne $scErrProp -and $null -ne $scErrProp.Value) { $httpStatusLog = [string]$scErrProp.Value }
        } catch { }
        try {
          $respErrProp = $null
          if ($null -ne $renderErr.Exception) { $respErrProp = $renderErr.Exception.PSObject.Properties['Response'] }
          if ($null -ne $respErrProp -and $null -ne $respErrProp.Value) {
            $scRespProp = $respErrProp.Value.PSObject.Properties['StatusCode']
            if ($null -ne $scRespProp) { $httpStatusLog = [string]$scRespProp.Value }
          }
        } catch { }
        try {
          if ($null -ne $renderErr.ErrorDetails -and -not [string]::IsNullOrWhiteSpace([string]$renderErr.ErrorDetails.Message)) {
            $respBodyLog = [string]$renderErr.ErrorDetails.Message
          }
        } catch { }
        try {
          if ([string]::IsNullOrWhiteSpace([string]$respBodyLog)) {
            $wexRaw = $null
            if ($renderErr.Exception -is [System.Net.WebException]) { $wexRaw = $renderErr.Exception }
            elseif ($null -ne $renderErr.Exception -and $null -ne $renderErr.Exception.InnerException -and $renderErr.Exception.InnerException -is [System.Net.WebException]) { $wexRaw = $renderErr.Exception.InnerException }
            if ($null -ne $wexRaw -and $null -ne $wexRaw.Response) {
              $rdr = New-Object System.IO.StreamReader($wexRaw.Response.GetResponseStream())
              try { $respBodyLog = $rdr.ReadToEnd() } finally { $rdr.Dispose() }
            }
          }
        } catch { }
        $httpStatusTxt = $(if ([string]::IsNullOrWhiteSpace([string]$httpStatusLog)) { 'n/a' } else { [string]$httpStatusLog })
        $rendererErrSummary = '[cr_refere_preventif] REFERE-E2E-2 : appel renderer DOCX en echec (url=' + $rendererUrlLog + ', http_status=' + $httpStatusTxt + ', exception=' + $exMsgLog + ')'
        if (-not [string]::IsNullOrWhiteSpace([string]$respBodyLog)) {
          $bodyTxt = [string]$respBodyLog
          if ($bodyTxt.Length -gt 800) { $bodyTxt = $bodyTxt.Substring(0, 800) + '...[truncated body]' }
          $rendererErrSummary = $rendererErrSummary + ' | response_body=' + $bodyTxt
        }
        $rendererErrSummary = $rendererErrSummary + ' - STOP.'
        Write-CrErr $rendererErrSummary
        Add-CrLogLine ('renderer_error url=' + $rendererUrlLog + ' http_status=' + $httpStatusTxt + ' exception=' + $exMsgLog + $(if (-not [string]::IsNullOrWhiteSpace([string]$respBodyLog)) { ' response_body=' + [string]$respBodyLog } else { '' }))
        throw $rendererErrSummary
      }
      if (-not (Test-Path -LiteralPath $docxPath -PathType Leaf)) {
        throw '[cr_refere_preventif] REFERE-E2E-2 : renderer DOCX n a pas produit de fichier - STOP.'
      }
      $httpTotal++
      Add-CrOutputFile $docxPath
      [void]$artifacts.Add($docxPath)
      Write-CrInfo ('[E2E-2 EXEC] DOCX produit : ' + $docxPath)
    }

    # ============================================================================
    # REFERE-E2E-2 : synthese + artefacts de controle (plan/exec) + retour.
    # ============================================================================
    $phase = 'summary'
    $fitProd = 0
    foreach ($rr in @($rows)) {
      if (-not ($rr -is [System.Collections.IDictionary])) { continue }
      if (-not $rr.ContainsKey('fits') -or $null -eq $rr['fits']) { continue }
      if ($rr.ContainsKey('excluded') -and [bool]$rr['excluded']) { continue }
      if ([bool]$rr['fits']) { $fitProd++ }
    }
    $hadGlobalProd = (-not [string]::IsNullOrWhiteSpace($globalRawP))
    $statusProd = 'ok'
    if (-not $Exec) {
      if (-not $hadGlobalProd) { $statusProd = 'NO_GLOBAL_REFERENCE' }
      elseif ($badBudgetCount -gt 0) { $statusProd = 'DOES_NOT_FIT' }
      else { $statusProd = 'PLAN_OK' }
    }
    $okProd = $false
    if ($Exec) { $okProd = ($statusProd -eq 'ok' -and $llmTotal -ge 1) }
    else { $okProd = ($statusProd -eq 'PLAN_OK') }
    $expTotal = [int]$expectedChunkCalls + [int]$batchesCount + 7 + 4 + $eRunnableCount
    $summaryProd = @{
      lot = [string]$script:P3LotLabel
      mode = $(if ($Exec) { 'RunReferePipeline' } else { 'RunReferePipelinePlanOnly' })
      status = $statusProd
      ok = $okProd
      llm_calls = $llmTotal
      http_calls = $httpTotal
      expected_llm_calls_total = $expTotal
      pass2f_expected_chunk_calls = [int]$expectedChunkCalls
      pass2b2f_batches = [int]$batchesCount
      pass2b2f_6g_calls = 7
      pass3abcd_calls = 4
      pass3e_subjects_runnable = $eRunnableCount
      pass3e_subjects_ok = @($eResults).Count
      pass3e_subjects_skipped = @($eSkipped).Count
      bad_budget_count = $badBudgetCount
      fit_rows = $fitProd
      rows_count = @($rows).Count
      out_root = $OutDir
      refere_global_meeting_path = $refereGlobalPath
      refere_global_by_sujet_path = $refereGlobalBySujetPath
      refere_global_final_path = $refereGlobalFinalPath
      docx_path = $docxPath
      finished_at = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
    }
    $retProd = @{
      ok = $okProd
      status = $statusProd
      llm_calls = $llmTotal
      http_calls = $httpTotal
      rows = @($rows)
      artifacts = @($artifacts)
      summary = $summaryProd
      global_meeting_path = $refereGlobalPath
      by_sujet_path = $refereGlobalBySujetPath
      global_final_path = $refereGlobalFinalPath
      docx_path = $docxPath
    }
    $prodDocPath = ''
    if ($Exec) {
      $prodDocPath = Write-RefereProductionManifest -OutDir $OutDir -StartedAt $StartedAt -Paths $Paths -LotLabel ([string]$script:P3LotLabel) -Result $retProd
    } else {
      $prodDocPath = Write-RefereProductionPlan -OutDir $OutDir -StartedAt $StartedAt -LotLabel ([string]$script:P3LotLabel) -Result $retProd
    }
    if ($prodDocPath) {
      $summaryProd['plan_or_manifest_path'] = $prodDocPath
      $retProd['plan_or_manifest_path'] = $prodDocPath
    }
    return $retProd
  } catch {
    $pErr = $_.Exception.Message
    throw ('[cr_refere_preventif] REFERE-E2E-2 : echec phase=' + $phase + ' (llm_calls_ok=' + $llmTotal + ' http_calls_ok=' + $httpTotal + ') : ' + $pErr)
  }
}

function Write-RefereProductionManifest {
  param(
    [string] $OutDir,
    [string] $StartedAt,
    [hashtable] $Paths,
    [string] $LotLabel,
    [object] $Result
  )
  Ensure-Dir $OutDir
  $sum = $Result.summary
  $outputs = New-Object System.Collections.ArrayList
  if ($sum.refere_global_meeting_path) { [void]$outputs.Add([string]$sum.refere_global_meeting_path) }
  if ($sum.refere_global_by_sujet_path) { [void]$outputs.Add([string]$sum.refere_global_by_sujet_path) }
  if ($sum.refere_global_final_path) { [void]$outputs.Add([string]$sum.refere_global_final_path) }
  if ($sum.docx_path) { [void]$outputs.Add([string]$sum.docx_path) }
  foreach ($oa in @($Result.artifacts)) { if ($oa) { [void]$outputs.Add([string]$oa) } }
  $m = [ordered]@{
    schema_version = 'cr_refere_preventif.production_manifest.v1'
    mode = 'RunReferePipeline'
    lot = $LotLabel
    status = $(if ([bool]$Result.ok) { 'OK' } else { [string]$Result.status })
    id_affaire = [string]$Paths.IdAffaire
    id_captation = [string]$Paths.IdCaptation
    started_at = $StartedAt
    finished_at = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
    llm_calls = [int]$Result.llm_calls
    http_calls = [int]$Result.http_calls
    refere_global_meeting_path = $(if ($sum.refere_global_meeting_path) { [string]$sum.refere_global_meeting_path } else { '' })
    refere_global_by_sujet_path = $(if ($sum.refere_global_by_sujet_path) { [string]$sum.refere_global_by_sujet_path } else { '' })
    refere_global_final_path = $(if ($sum.refere_global_final_path) { [string]$sum.refere_global_final_path } else { '' })
    docx_path = $(if ($sum.docx_path) { [string]$sum.docx_path } else { '' })
    out_root = [string]$OutDir
    outputs = @($outputs)
    errors = @()
    details = $sum
  }
  $mf = Join-Path $OutDir 'manifest.json'
  Write-CrJsonAtomic -Path $mf -Obj $m
  return $mf
}

function Write-RefereProductionPlan {
  param(
    [string] $OutDir,
    [string] $StartedAt,
    [string] $LotLabel,
    [object] $Result
  )
  Ensure-Dir $OutDir
  $sum = $Result.summary
  $p = [ordered]@{
    schema_version = 'cr_refere_preventif.production_plan.v1'
    mode = 'RunReferePipelinePlanOnly'
    lot = $LotLabel
    status = [string]$sum.status
    ok = [bool]$Result.ok
    started_at = $StartedAt
    finished_at = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
    expected_llm_calls_total = [int]$sum.expected_llm_calls_total
    pass2f_expected_chunk_calls = [int]$sum.pass2f_expected_chunk_calls
    pass2b2f_batches = [int]$sum.pass2b2f_batches
    pass3abcd_calls = [int]$sum.pass3abcd_calls
    pass3e_subjects_runnable = [int]$sum.pass3e_subjects_runnable
    bad_budget_count = [int]$sum.bad_budget_count
    rows = @($Result.rows)
    artifacts = @($Result.artifacts)
  }
  $pf = Join-Path $OutDir 'refere_production_plan.json'
  Write-CrJsonAtomic -Path $pf -Obj $p
  return $pf
}
