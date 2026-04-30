#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Repair an empty per-subject JSON from an existing global.json.

This is a targeted, local repair helper: it does not call the LLM, does not
rerun PowerShell, and does not regenerate the pipeline JSON chain.
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any


DEFAULT_ALIAS_PATTERNS = {
    6: r"cave|sous[- ]?sol|garage en dessous|local qui est tr[e\u00e8]s humide|tr[e\u00e8]s humide, on voit de l['\u2019]eau|sous la terrasse|en bas correctement",
}


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8-sig"))


def dump_json(path: Path, obj: Any) -> None:
    path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def as_list(value: Any) -> list[Any]:
    if value is None:
        return []
    return value if isinstance(value, list) else [value]


def get_subject_ref(sujets_ref: list[dict[str, Any]], numero: int) -> dict[str, Any]:
    for item in sujets_ref:
        if int(item.get("Numero", -1)) == numero:
            return item
    raise SystemExit(f"Sujet {numero} introuvable dans sujets_ref.json")


def normalize_intervention(iv: dict[str, Any]) -> dict[str, Any]:
    return {
        "segment_id": iv.get("segment_id"),
        "timecode": iv.get("timecode"),
        "auteur": iv.get("auteur"),
        "role": iv.get("role"),
        "texte": iv.get("texte"),
    }


def intervention_key(iv: dict[str, Any]) -> tuple[str, str, str]:
    return (
        str(iv.get("timecode") or "").strip(),
        str(iv.get("auteur") or "").strip(),
        str(iv.get("texte") or "").strip(),
    )


def stats(interventions: list[dict[str, Any]]) -> dict[str, Any]:
    timecodes = sorted(
        str(iv.get("timecode")).strip()
        for iv in interventions
        if iv.get("timecode")
    )
    return {
        "count": len(interventions),
        "first_timecode": timecodes[0] if timecodes else None,
        "last_timecode": timecodes[-1] if timecodes else None,
    }


def collect_candidates(global_data: dict[str, Any], numero: int, pattern: re.Pattern[str]) -> list[dict[str, Any]]:
    sujets_map = global_data.get("sujets") or {}
    if not isinstance(sujets_map, dict):
        raise SystemExit("global.json invalide: champ 'sujets' attendu comme dictionnaire")

    seen: set[tuple[str, str, str]] = set()
    candidates: list[dict[str, Any]] = []
    for source_num, interventions in sujets_map.items():
        if str(source_num) == str(numero):
            continue
        for raw_iv in as_list(interventions):
            if not isinstance(raw_iv, dict):
                continue
            text = str(raw_iv.get("texte") or "")
            if not pattern.search(text):
                continue
            iv = normalize_intervention(raw_iv)
            iv["_repair_source_sujet"] = int(source_num) if str(source_num).isdigit() else source_num
            key = intervention_key(iv)
            if key in seen:
                continue
            seen.add(key)
            candidates.append(iv)
    return candidates


def build_subject_json(subject_ref: dict[str, Any], interventions: list[dict[str, Any]], pattern_text: str) -> dict[str, Any]:
    numero = int(subject_ref["Numero"])
    provenance = [
        {
            "source_sujet": iv.get("_repair_source_sujet"),
            "segment_id": iv.get("segment_id"),
            "timecode": iv.get("timecode"),
            "auteur": iv.get("auteur"),
        }
        for iv in interventions
    ]
    cleaned = [
        {k: v for k, v in iv.items() if k != "_repair_source_sujet"}
        for iv in interventions
    ]
    return {
        "numero": numero,
        "titre": (subject_ref.get("Titre") or "").strip(),
        "localisation": subject_ref.get("Localisation", ""),
        "description": subject_ref.get("Description", ""),
        "interventions": cleaned,
        "stats": stats(cleaned),
        "source": {
            "global_json": "global.json",
            "repair": "repair_empty_sujet_from_global.py",
            "include_regex": pattern_text,
            "candidates": provenance,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Repasse locale ciblee pour alimenter un sujet vide depuis global.json."
    )
    parser.add_argument("--run-dir", required=True, help="Dossier du run contenant global.json, sujets_ref.json et sujets/")
    parser.add_argument("--sujet", type=int, required=True, help="Numero du sujet a reparer")
    parser.add_argument(
        "--include-regex",
        help="Motif explicite de selection des interventions; sinon motif conservateur connu pour certains sujets",
    )
    parser.add_argument(
        "--max-interventions",
        type=int,
        default=8,
        help="Nombre maximal d'interventions recopiees dans le sujet cible",
    )
    parser.add_argument("--apply", action="store_true", help="Ecrit sujets/sujet_NNN.json; sinon dry-run")
    parser.add_argument(
        "--overwrite-existing",
        action="store_true",
        help="Autorise l'ecrasement d'un sujet cible deja alimente",
    )
    args = parser.parse_args()

    run_dir = Path(args.run_dir).expanduser().resolve()
    global_path = run_dir / "global.json"
    sujets_ref_path = run_dir / "sujets_ref.json"
    sujets_dir = run_dir / "sujets"
    subject_path = sujets_dir / f"sujet_{args.sujet:03d}.json"

    for path in (global_path, sujets_ref_path, sujets_dir):
        if not path.exists():
            raise SystemExit(f"Chemin introuvable: {path}")

    existing = load_json(subject_path) if subject_path.exists() else {}
    existing_count = len(existing.get("interventions") or []) if isinstance(existing, dict) else 0
    if existing_count:
        print(f"Sujet {args.sujet}: {existing_count} intervention(s) deja presentes.")
        if args.apply and not args.overwrite_existing:
            raise SystemExit(
                "Refus d'ecraser un sujet deja alimente. Ajouter --overwrite-existing si c'est voulu."
            )

    pattern_text = args.include_regex or DEFAULT_ALIAS_PATTERNS.get(args.sujet)
    if not pattern_text:
        raise SystemExit(
            "Aucun motif par defaut pour ce sujet. Fournir --include-regex pour une repasse explicite."
        )
    pattern = re.compile(pattern_text, flags=re.IGNORECASE)

    sujets_ref = load_json(sujets_ref_path)
    subject_ref = get_subject_ref(as_list(sujets_ref), args.sujet)
    global_data = load_json(global_path)
    candidates = collect_candidates(global_data, args.sujet, pattern)
    total_candidates = len(candidates)
    if args.max_interventions < 1:
        raise SystemExit("--max-interventions doit etre >= 1")
    candidates = candidates[: args.max_interventions]

    print(f"Run: {run_dir}")
    print(f"Sujet cible: {args.sujet} - {subject_ref.get('Titre')} / {subject_ref.get('Localisation')}")
    print(f"Motif: {pattern_text}")
    print(f"Candidats trouves: {total_candidates}")
    print(f"Candidats retenus: {len(candidates)} (max {args.max_interventions})")
    for iv in candidates:
        text = str(iv.get("texte") or "").replace("\n", " ")
        print(
            f"- source sujet {iv.get('_repair_source_sujet')}, "
            f"{iv.get('segment_id')}, {iv.get('timecode')}: {text[:220]}"
        )

    if not candidates:
        raise SystemExit("Aucun candidat trouve; aucune ecriture effectuee.")

    repaired = build_subject_json(subject_ref, candidates, pattern_text)
    if args.apply:
        dump_json(subject_path, repaired)
        print(f"Ecrit: {subject_path}")
    else:
        print("Dry-run: ajouter --apply pour ecrire le fichier sujet cible.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
