"""Détection des placeholders de pseudonymisation résiduels.

Ce helper centralise la logique de scan utilisée par
``Scripts/run_compte_rendu_avec_sujets.sh`` :

* :func:`scan_json_payload` : scan d'un payload JSON après désérialisation ;
* :func:`scan_docx` : scan des paragraphes d'un DOCX.

Les deux contrôles partagent volontairement la même regex et la même
allowlist afin de garantir qu'un contenu logique identique produise le
même résultat, quel que soit le support (JSON ou DOCX).

Historique : le scan JSON travaillait initialement sur le texte brut du
fichier. Les retours à la ligne y sont stockés sous la forme des deux
caractères littéraux ``\\`` + ``n``. Un token tel que ``P131`` placé en
début de paragraphe était donc précédé d'un caractère de mot (``n``) et
échappait à la frontière de mot ``\\b`` : le contrôle JSON renvoyait un
faux négatif alors que le contrôle DOCX, lui, détectait le token. Le scan
JSON opère désormais sur les valeurs chaînes désérialisées, où ``\\n`` est
un véritable retour à la ligne.
"""

from __future__ import annotations

import json
import re
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any, Iterable, Iterator, List, Sequence, Tuple

PLACEHOLDER_PATTERN = re.compile(r"(?i)\b(?:P\s*\d+|ENT\s*\d+)\b")

WORD_NS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
WORD_NS_MAP = {"w": WORD_NS}


def parse_allowlist(raw: str | None) -> set[str]:
    """Normalise la valeur de ``CR_PLACEHOLDER_ALLOWLIST``.

    Les tokens sont comparés en majuscules et sans espace, afin que
    ``P 12`` et ``p12`` soient équivalents.
    """
    if not raw:
        return set()
    return {item.strip().upper().replace(" ", "") for item in raw.split(",") if item.strip()}


def normalize_token(token: str) -> str:
    return token.upper().replace(" ", "")


def iter_json_strings(value: Any) -> Iterator[str]:
    """Parcourt récursivement toutes les valeurs chaînes d'une structure JSON."""
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for key in value:
            yield from iter_json_strings_keys(key, value[key])
    elif isinstance(value, (list, tuple)):
        for item in value:
            yield from iter_json_strings(item)


def iter_json_strings_keys(key: Any, value: Any) -> Iterator[str]:
    """Inclut les clés d'objets dans le parcours, comme les valeurs."""
    if isinstance(key, str):
        yield key
    yield from iter_json_strings(value)


def find_tokens(text: str, allowlist: set[str] | None = None) -> List[Tuple[str, str]]:
    """Retourne les couples ``(token, contexte)`` détectés dans ``text``."""
    allowlist = allowlist or set()
    hits: List[Tuple[str, str]] = []
    for match in PLACEHOLDER_PATTERN.finditer(text):
        token = match.group(0)
        if normalize_token(token) in allowlist:
            continue
        start = max(0, match.start() - 70)
        end = min(len(text), match.end() + 70)
        context = text[start:end].replace("\n", " ")
        hits.append((token, context))
    return hits


def scan_json_payload(payload_path: str | Path, allowlist_raw: str | None = None) -> List[Tuple[str, str]]:
    """Scan d'un fichier JSON après désérialisation.

    Le fichier est lu puis désérialisé : les séquences ``\\n`` littérales
    deviennent de véritables retours à la ligne, ce qui rend la frontière
    de mot ``\\b`` opérante en début de paragraphe.
    """
    path = Path(payload_path)
    allowlist = parse_allowlist(allowlist_raw)
    data = json.loads(path.read_text(encoding="utf-8-sig"))
    hits: List[Tuple[str, str]] = []
    for text in iter_json_strings(data):
        hits.extend(find_tokens(text, allowlist))
    return hits


def iter_docx_paragraphs(docx_path: str | Path) -> Iterator[Tuple[str, int, str]]:
    """Itère sur ``(partie, index_paragraphe, texte)`` d'un DOCX."""
    path = Path(docx_path)
    with zipfile.ZipFile(path) as archive:
        names = [
            name
            for name in archive.namelist()
            if name.startswith("word/")
            and name.endswith(".xml")
            and ("document.xml" in name or "header" in name or "footer" in name)
        ]
        for name in names:
            try:
                root = ET.fromstring(archive.read(name))
            except Exception:
                continue
            for idx, paragraph in enumerate(root.findall(".//w:p", WORD_NS_MAP), 1):
                text = "".join(node.text or "" for node in paragraph.findall(".//w:t", WORD_NS_MAP))
                if not text:
                    continue
                yield name, idx, text


def scan_docx(docx_path: str | Path, allowlist_raw: str | None = None) -> List[Tuple[str, int, str, str]]:
    """Scan des paragraphes d'un DOCX.

    Retourne les quadruplets ``(partie, index, token, contexte)``.
    """
    allowlist = parse_allowlist(allowlist_raw)
    hits: List[Tuple[str, int, str, str]] = []
    for name, idx, text in iter_docx_paragraphs(docx_path):
        for token, context in find_tokens(text, allowlist):
            hits.append((name, idx, token, context))
    return hits


def format_json_report(hits: Sequence[Tuple[str, str]], label: str, path: str | Path) -> str:
    lines = [f"ERREUR: placeholders résiduels dans {label}: {path}"]
    for token, context in hits[:40]:
        lines.append(f"- {token}: {context}")
    if len(hits) > 40:
        lines.append(f"... {len(hits) - 40} occurrence(s) supplémentaire(s)")
    return "\n".join(lines)


def format_docx_report(hits: Sequence[Tuple[str, int, str, str]], path: str | Path) -> str:
    lines = [f"ERREUR: placeholders résiduels dans le DOCX: {path}"]
    for part, idx, token, context in hits[:40]:
        lines.append(f"- {part} paragraphe {idx}, {token}: {context}")
    if len(hits) > 40:
        lines.append(f"... {len(hits) - 40} occurrence(s) supplémentaire(s)")
    return "\n".join(lines)


def _main(argv: Sequence[str]) -> int:
    """Point d'entrée CLI utilisé par le script shell.

    Usage :
        placeholder_scan.py json  <fichier.json> <label> [allowlist]
        placeholder_scan.py docx  <fichier.docx> [allowlist]
    """
    if len(argv) < 2:
        print("Usage: placeholder_scan.py {json|docx} <fichier> [label] [allowlist]")
        return 2

    mode = argv[0]
    if mode == "json":
        if len(argv) < 3:
            print("Usage: placeholder_scan.py json <fichier.json> <label> [allowlist]")
            return 2
        target, label = argv[1], argv[2]
        allowlist_raw = argv[3] if len(argv) > 3 else ""
        hits = scan_json_payload(target, allowlist_raw)
        if hits:
            print(format_json_report(hits, label, target))
            return 32
        print(f"QA placeholders OK: {label}")
        return 0

    if mode == "docx":
        target = argv[1]
        allowlist_raw = argv[2] if len(argv) > 2 else ""
        hits = scan_docx(target, allowlist_raw)
        if hits:
            print(format_docx_report(hits, target))
            return 33
        print(f"QA placeholders OK: DOCX {target}")
        return 0

    print(f"Mode inconnu: {mode}")
    return 2


if __name__ == "__main__":
    import sys

    raise SystemExit(_main(sys.argv[1:]))
