# render_cr.ps1 (extrait)
param([string]$FinalJsonPath = ".\out\global_final.json", [string]$OutMd = ".\out\compte_rendu.md")
$j = Get-Content $FinalJsonPath -Raw | ConvertFrom-Json

$md = @()
$md += "Date    $($j.date ?? '—')"
$md += "Link    $($j.link ?? '—')"
$md += ""
$md += "Résumé"
$md += $j.resume
$md += ""
$md += "Ordre du jour"
foreach($it in $j.ordre_du_jour){ $md += "- $it" }
$md += ""
$md += "Thèmes abordés"
foreach($t in $j.themes_abordes){
  $md += "### $($t.titre)"
  foreach($p in $t.synthese){ $md += "- $p" }
  if($t.indices_source){
    $md += "Indices de source"
    foreach($ix in $t.indices_source){ $md += "- $($ix.timecode) — $($ix.speaker): $($ix.extrait)" }
  }
  $md += ""
}
$md += "Actions"
$md += "| Action | Responsable | Échéance | Commentaire |"
$md += "|---|---|---|---|"
foreach($a in $j.actions){
  $md += "| $($a.action) | $($a.responsable) | $($a.echeance ?? '—') | $($a.commentaire ?? '—') |"
}
$md += ""
$md += "Perspectives"
foreach($p in $j.perspectives){
  $md += "**Problème :** $($p.probleme)"
  $md += "**Solution envisagée / décidée :** $($p.solution)"
  $md += ""
}
if($j.annexes){
  $md += "Annexes"
  $i=1; foreach($ax in $j.annexes){ $md += "$i) $ax"; $i++ }
}
$md -join "`n" | Out-File $OutMd -Encoding UTF8
