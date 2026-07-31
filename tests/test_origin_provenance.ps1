$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot "cr-pipeline/pipeline/powershell/cr_reunion_point_mumerotes_pipeline_json.ps1"
$scriptText = [System.IO.File]::ReadAllText($scriptPath, [System.Text.Encoding]::UTF8)

$start = $scriptText.IndexOf("function Copy-ObjectWithOrigin")
if ($start -lt 0) {
    throw "Copy-ObjectWithOrigin introuvable dans le pipeline."
}
$braceStart = $scriptText.IndexOf("{", $start)
if ($braceStart -lt 0) { throw "Bloc Copy-ObjectWithOrigin invalide." }
$depth = 0
$end = -1
for ($i = $braceStart; $i -lt $scriptText.Length; $i++) {
    if ($scriptText[$i] -eq "{") { $depth++ }
    elseif ($scriptText[$i] -eq "}") {
        $depth--
        if ($depth -eq 0) { $end = $i; break }
    }
}
if ($end -lt 0) { throw "Fin de Copy-ObjectWithOrigin introuvable." }
Invoke-Expression $scriptText.Substring($start, $end - $start + 1)

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Get-OriginPropertyCount {
    param([object] $Obj)
    return @($Obj.PSObject.Properties | Where-Object { $_.Name -ieq "origine" }).Count
}

$participant = [pscustomobject]@{
    objet = "Document produit en réunion"
    origine = "participant_initial"
    commentaire = "reste inchangé"
}
$participantCopy = Copy-ObjectWithOrigin -Obj $participant -Origin "reunion"
Assert-True ($participant.origine -eq "participant_initial") "L'objet participant original a été modifié."
Assert-True ($participantCopy.origine -eq "participant_initial") "L'origine participant existante ne doit pas être remplacée."
Assert-True ($participantCopy.commentaire -eq "reste inchangé") "Une propriété participant a été perdue."
Assert-True ((Get-OriginPropertyCount $participantCopy) -eq 1) "Origine du participant dupliquée."

$debriefWithoutOrigin = [pscustomobject]@{
    objet = "Document demandé par l'expert"
    echeance = "2026-01-15"
}
$debriefCopy1 = Copy-ObjectWithOrigin -Obj $debriefWithoutOrigin -Origin "debrief_expert" -ReplaceExistingOrigin
Assert-True ($debriefCopy1.origine -eq "debrief_expert") "Origine debrief absente non ajoutée."
Assert-True ($debriefCopy1.echeance -eq "2026-01-15") "Une propriété debrief a été perdue."
Assert-True ((Get-OriginPropertyCount $debriefCopy1) -eq 1) "Origine debrief ajoutée en doublon."

$debriefWithOrigin = [pscustomobject]@{
    objet = "Document debrief avec origine héritée"
    origine = "ancien_schema"
    montant = "1000"
}
$debriefCopy2 = Copy-ObjectWithOrigin -Obj $debriefWithOrigin -Origin "debrief_expert" -ReplaceExistingOrigin
Assert-True ($debriefWithOrigin.origine -eq "ancien_schema") "L'objet debrief original a été modifié."
Assert-True ($debriefCopy2.origine -eq "debrief_expert") "Origine debrief existante non remplacée sur la copie."
Assert-True ($debriefCopy2.montant -eq "1000") "Une propriété debrief existante a été perdue."
Assert-True ((Get-OriginPropertyCount $debriefCopy2) -eq 1) "Origine debrief remplacée en doublon."

$globalFinal = [pscustomobject]@{
    sujets = @(
        [pscustomobject]@{
            numero = 2
            avis_participants = @([pscustomobject]@{ nom = "Participant"; resume = "Avis conservé"; origine = "transcription" })
            synthese_echanges = "Synthèse des échanges conservée."
            conclusion_expert = "Conclusion experte conservée."
            demandes_documents = @($participantCopy)
        }
    )
}
$globalFinal.sujets[0].demandes_documents += $debriefCopy1
$globalFinal.sujets[0].demandes_documents += $debriefCopy2

Assert-True ($globalFinal.sujets[0].avis_participants[0].origine -eq "transcription") "Origine participant dans global_final altérée."
Assert-True ($globalFinal.sujets[0].synthese_echanges -like "*conservée*") "Synthèse participants absente."
Assert-True ($globalFinal.sujets[0].conclusion_expert -like "*experte*") "Conclusion expert absente."
Assert-True (@($globalFinal.sujets[0].demandes_documents | Where-Object { $_.origine -eq "participant_initial" }).Count -eq 1) "Information participant absente."
Assert-True (@($globalFinal.sujets[0].demandes_documents | Where-Object { $_.origine -eq "debrief_expert" }).Count -eq 2) "Informations debrief expert absentes."

"OK provenance origine"
