#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import argparse
import json
import re
from pathlib import Path

JSON_START_RE = re.compile(r"[{\[]")


def extract_candidate(text: str) -> str | None:
    """Repère le premier '{' ou '[' et retourne tout ce qui suit."""
    m = JSON_START_RE.search(text or "")
    if not m:
        return None
    return text[m.start():]


def cleanup_wrappers(s: str) -> str:
    """Supprime éventuellement <json> ... </json> et espaces parasites."""
    s = s.strip()
    s = re.sub(r"^<json>\s*", "", s, flags=re.I)
    s = re.sub(r"\s*</json>\s*$", "", s, flags=re.I)
    return s.strip()


def try_load_json(s: str):
    try:
        return json.loads(s)
    except Exception:
        return None


def balance_brackets(s: str) -> str | None:
    """Ferme les { et [ manquants à la fin (sans corriger le reste)."""
    opens_curly = s.count("{")
    closes_curly = s.count("}")
    if closes_curly > opens_curly:
        return None

    opens_sq = s.count("[")
    closes_sq = s.count("]")
    if closes_sq > opens_sq:
        return None

    s = s + "}" * (opens_curly - closes_curly)
    s = s + "]" * (opens_sq - closes_sq)
    return s


def light_cleanup(s: str) -> str:
    """Nettoyage léger : supprime virgules finales avant ] ou }."""
    # virgule juste avant ] ou }
    s = re.sub(r",\s*([}\]])", r"\1", s)
    # virgule en fin de texte
    s = re.sub(r",\s*$", "", s)
    return s


def repair_json_from_raw(raw: str, max_trim: int = 2000):
    """
    Essaye de récupérer un JSON valide à partir d'un texte LLM potentiellement tronqué.

    Stratégie :
    - extraction du bloc après le premier { ou [
    - tentative directe json.loads + nettoyage léger
    - si échec, on tronque progressivement par la fin et on rebalance les crochets
    """
    cand = extract_candidate(raw or "")
    if not cand:
        return None
    cand = cleanup_wrappers(cand)

    # Essai direct
    direct = try_load_json(cand)
    if direct is not None:
        return direct

    cand2 = light_cleanup(cand)
    direct2 = try_load_json(cand2)
    if direct2 is not None:
        return direct2

    base = cand
    start = max(0, len(base) - max_trim)

    # On teste des préfixes de plus en plus courts
    for end in range(len(base), start, -1):
        prefix = base[:end]

        # Si nombre de guillemets est impair, supprimer le bout de chaîne après le dernier "
        # (évite les chaînes non terminées du type "00')
        if prefix.count('"') % 2 == 1:
            last_q = prefix.rfind('"')
            if last_q != -1:
                prefix = prefix[:last_q]

        prefix = light_cleanup(prefix)
        balanced = balance_brackets(prefix)
        if not balanced:
            continue

        balanced = light_cleanup(balanced)
        obj = try_load_json(balanced)
        if obj is not None:
            return obj

    return None


def normalize_segment_annotation(parsed):
    """
    Normalise dans le format attendu par le pipeline :
    {
      "resume_segment": str,
      "themes": list,
      "actions": list,
      "problems": list
    }
    """
    if isinstance(parsed, list) and parsed:
        parsed = parsed[0]
    if not isinstance(parsed, dict):
        parsed = {}

    out = {}

    # resume_segment
    val_res = parsed.get("resume_segment", "")
    if not isinstance(val_res, str):
        val_res = "" if val_res is None else str(val_res)
    out["resume_segment"] = val_res.strip()

    # themes
    val_themes = parsed.get("themes", [])
    if not isinstance(val_themes, list):
        val_themes = []
    out["themes"] = val_themes

    # actions
    val_actions = parsed.get("actions", [])
    if not isinstance(val_actions, list):
        val_actions = []
    out["actions"] = val_actions

    # problems
    val_problems = parsed.get("problems", [])
    if not isinstance(val_problems, list):
        val_problems = []
    out["problems"] = val_problems

    return out


def process_directory(root: Path, overwrite: bool = False):
    """
    Parcourt tous les segment_XX.raw.txt d'un dossier et produit
    soit segment_XX.fixed.json, soit écrase segment_XX.json.
    """
    for raw_path in sorted(root.glob("segment_*.raw.txt")):
        print(f"→ Traitement {raw_path.name}")
        raw_text = raw_path.read_text(encoding="utf-8", errors="ignore")

        parsed = repair_json_from_raw(raw_text)
        if parsed is None:
            print(f"  ⚠️ impossible de reconstruire un JSON pour {raw_path.name}, on laisse en l'état.")
            continue

        normalized = normalize_segment_annotation(parsed)

        if overwrite:
            out_path = raw_path.with_suffix(".json")  # remplace le .raw.txt par .json
        else:
            # ex : segment_01.raw.txt → segment_01.fixed.json
            out_path = raw_path.with_name(raw_path.name.replace(".raw.txt", ".fixed.json"))

        out_path.write_text(json.dumps(normalized, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"  ✅ JSON réparé écrit dans {out_path.name}")


def main():
    ap = argparse.ArgumentParser(description="Réparation des segments JSON tronqués (compte-rendu).")
    ap.add_argument("directory", help="Dossier contenant les segment_XX.raw.txt")
    ap.add_argument(
        "--overwrite",
        action="store_true",
        help="Écrase segment_XX.json au lieu de créer segment_XX.fixed.json"
    )
    args = ap.parse_args()

    root = Path(args.directory).expanduser().resolve()
    if not root.is_dir():
        raise SystemExit(f"Dossier introuvable : {root}")

    process_directory(root, overwrite=args.overwrite)


if __name__ == "__main__":
    main()
