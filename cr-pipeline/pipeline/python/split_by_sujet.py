#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
split_by_sujet.py

Entrées:
- global.json : { "sujets": { "<numero>": [ {segment_id,timecode,auteur,role,texte}, ... ], ... } }
- sujets_ref.json : liste d'objets contenant Numero, Titre, Localisation, Description

Sorties:
- 1 fichier JSON par sujet (au minimum)
- découpage *_partXX.json si dépassement --target-kb
- split_index.json (inventaire exploitable par la Passe 3E)
"""

from __future__ import annotations
import argparse, json, re
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

_TIME_RE = re.compile(r"^\d{2}:\d{2}:\d{2}$")


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8-sig"))



def dump_json(path: Path, obj: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, ensure_ascii=False, indent=2), encoding="utf-8")


def as_list(x: Any) -> List[Any]:
    return [] if x is None else (x if isinstance(x, list) else [x])


def norm_timecode(tc: Any) -> Optional[str]:
    if not tc:
        return None
    s = str(tc).strip()
    return s if _TIME_RE.match(s) else None


def json_size_bytes(obj: Any) -> int:
    return len(json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))


def intervention_key(iv: Dict[str, Any]) -> Tuple[str, str, str]:
    return (
        str(iv.get("timecode") or "").strip(),
        str(iv.get("auteur") or "").strip(),
        str(iv.get("texte") or "").strip(),
    )


def dedup(items: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    seen, out = set(), []
    for iv in items:
        k = intervention_key(iv)
        if k in seen:
            continue
        seen.add(k)
        out.append(iv)
    return out


def stats(interventions: List[Dict[str, Any]]) -> Dict[str, Any]:
    tcs = [norm_timecode(iv.get("timecode")) for iv in interventions]
    tcs = [t for t in tcs if t]
    tcs.sort()
    return {
        "count": len(interventions),
        "first_timecode": tcs[0] if tcs else None,
        "last_timecode": tcs[-1] if tcs else None,
    }


def chunk(base_obj: Dict[str, Any], interventions: List[Dict[str, Any]], target_bytes: int) -> List[Dict[str, Any]]:
    chunks, cur = [], []

    def make(cur_list):
        o = dict(base_obj)
        o["interventions"] = cur_list
        o["stats"] = stats(cur_list)
        return o

    for iv in interventions:
        tentative = cur + [iv]
        if cur and json_size_bytes(make(tentative)) > target_bytes:
            chunks.append(make(cur))
            cur = [iv]
        else:
            cur = tentative
    if cur:
        chunks.append(make(cur))
    return chunks


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--global-json", dest="global_json", required=True)
    ap.add_argument("--sujets-ref", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--target-kb", type=int, default=80)
    ap.add_argument("--dedup", action="store_true")
    args = ap.parse_args()

    global_path = Path(args.global_json)
    sujets_ref_path = Path(args.sujets_ref)
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    g = load_json(global_path)
    sujets_map = (g or {}).get("sujets") or {}
    if not isinstance(sujets_map, dict):
        raise SystemExit("global.json: champ 'sujets' attendu comme dictionnaire")

    sujets_ref = as_list(load_json(sujets_ref_path))

    subjects: Dict[str, Dict[str, Any]] = {}
    skipped_non_positive = 0
    for sj in sujets_ref:
        numero = int(sj["Numero"])
        if numero <= 0:
            skipped_non_positive += 1
            continue
        num = str(numero)
        subjects[num] = {
            "numero": numero,
            "titre": (sj.get("Titre") or "").strip(),
            "localisation": sj.get("Localisation", ""),
            "description": sj.get("Description", ""),
        }

    ordered_nums = sorted(subjects.keys(), key=lambda x: int(x))
    target_bytes = max(10_000, int(args.target_kb) * 1024)

    index_items: List[Dict[str, Any]] = []

    for num_str in ordered_nums:
        meta = subjects[num_str]
        raw_list = as_list(sujets_map.get(num_str))

        clean = []
        for iv in raw_list:
            if not isinstance(iv, dict):
                continue
            item = {
                "segment_id": iv.get("segment_id"),
                "timecode": norm_timecode(iv.get("timecode")) or iv.get("timecode"),
                "auteur": iv.get("auteur"),
                "role": iv.get("role"),
                "texte": iv.get("texte"),
            }
            if "source_sujet_principal" in iv:
                item["source_sujet_principal"] = iv.get("source_sujet_principal")
            if "multi_subject_match" in iv:
                item["multi_subject_match"] = iv.get("multi_subject_match")
            clean.append(item)

        if args.dedup:
            clean = dedup(clean)

        base_obj = {
            "numero": meta["numero"],
            "titre": meta["titre"],
            "localisation": meta["localisation"],
            "description": meta["description"],
            "interventions": [],
            "stats": {},
            "source": {"global_json": global_path.name},
        }

        # Sujet sans intervention → fichier vide mais présent
        if not clean:
            out_path = out_dir / f"sujet_{meta['numero']:03d}.json"
            obj = dict(base_obj)
            obj["stats"] = stats([])
            dump_json(out_path, obj)
            index_items.append({
                "numero": meta["numero"],
                "titre": meta["titre"],
                "localisation": meta["localisation"],
                "description": meta["description"],
                "files": [out_path.name],
                "chunks": 1
            })
            continue

        full = dict(base_obj)
        full["interventions"] = clean
        full["stats"] = stats(clean)

        # Pas de découpage
        if json_size_bytes(full) <= target_bytes:
            out_path = out_dir / f"sujet_{meta['numero']:03d}.json"
            dump_json(out_path, full)
            index_items.append({
                "numero": meta["numero"],
                "titre": meta["titre"],
                "localisation": meta["localisation"],
                "description": meta["description"],
                "files": [out_path.name],
                "chunks": 1
            })
        else:
            parts = chunk(base_obj, clean, target_bytes)
            files = []
            for i, part in enumerate(parts, 1):
                out_path = out_dir / f"sujet_{meta['numero']:03d}_part{i:02d}.json"
                dump_json(out_path, part)
                files.append(out_path.name)
            index_items.append({
                "numero": meta["numero"],
                "titre": meta["titre"],
                "localisation": meta["localisation"],
                "description": meta["description"],
                "files": files,
                "chunks": len(files)
            })

    dump_json(out_dir / "split_index.json", {
        "subjects": index_items,
        "global": global_path.name,
        "count_sujets": len(index_items),
        "target_kb": int(args.target_kb),
        "dedup": bool(args.dedup),
        "skipped_non_positive_subjects": skipped_non_positive,
    })

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
