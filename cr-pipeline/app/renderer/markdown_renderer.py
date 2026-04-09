def md_escape(s: str) -> str:
    if s is None:
        return ""
    for ch in ["|", "*", "_", "`"]:
        s = s.replace(ch, f"\\{ch}")
    return s

def render_markdown(j: dict) -> str:
    date = j.get("date") or "—"
    link = j.get("link") or "—"
    lines = []
    lines.append(f"Date    {date}")
    lines.append(f"Link    {link}\n")
    lines.append("Résumé")
    lines.append(md_escape(j.get("resume","")).strip() + "\n")

    lines.append("Ordre du jour")
    for item in j.get("ordre_du_jour") or []:
        lines.append(f"- {md_escape(item)}")
    lines.append("")

    lines.append("Thèmes abordés")
    for t in j.get("themes_abordes", []):
        titre = t.get("titre","(Sans titre)")
        lines.append(f"### {md_escape(titre)}")
        for p in t.get("synthese") or []:
            lines.append(f"- {md_escape(p)}")
        idx = t.get("indices_source") or []
        if idx:
            lines.append("Indices de source")
            for ix in idx:
                tc = ix.get("timecode","")
                sp = ix.get("speaker","")
                ex = ix.get("extrait","")
                lines.append(f"- {md_escape(tc)} — {md_escape(sp)} : {md_escape(ex)}")
        lines.append("")
    lines.append("Actions")
    lines.append("| Action | Responsable | Échéance | Commentaire |")
    lines.append("|---|---|---|---|")
    for a in j.get("actions", []):
        action = md_escape(a.get("action",""))
        resp = md_escape(a.get("responsable",""))
        ech  = md_escape(a.get("echeance") or "—")
        com  = md_escape(a.get("commentaire") or "—")
        lines.append(f"| {action} | {resp} | {ech} | {com} |")
    lines.append("")
    lines.append("Perspectives")
    for p in j.get("perspectives", []):
        prob = md_escape(p.get("probleme",""))
        sol  = md_escape(p.get("solution",""))
        lines.append(f"**Problème :** {prob}")
        lines.append(f"**Solution envisagée / décidée :** {sol}\n")

    annexes = j.get("annexes") or []
    if annexes:
        lines.append("Annexes")
        for i, ax in enumerate(annexes, 1):
            lines.append(f"{i}) {md_escape(ax)}")

    return "\n".join(lines).strip() + "\n"
