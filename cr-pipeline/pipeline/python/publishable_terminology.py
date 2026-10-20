#!/usr/bin/env python3
"""Scan publishable report fields for internal pipeline terminology.

Exit codes: 0 clean/warnings only, 42 blocking findings, 2 scanner error.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any, Iterable


BLOCKING_RULES = (
    (
        "internal_pass_name",
        re.compile(r"(?i)\b(?:pass(?:e|es)?\s*[123]\s*[-_.]?\s*[a-f]|pass[123])\b"),
        "Référence explicite à une passe interne.",
    ),
    (
        "intermediate_summary",
        re.compile(r"(?i)\b(?:cette\s+|la\s+|une\s+)?synth[eè]se\s+interm[eé]diaire\b"),
        "Référence manifeste à une synthèse intermédiaire du traitement.",
    ),
    (
        "internal_prompt",
        re.compile(r"(?i)\b(?:ce|le|un|du|dans\s+le)\s+prompt\b|\bprompt\s+(?:syst[eè]me|utilisateur|LLM)\b"),
        "Référence à un prompt de fabrication du compte rendu.",
    ),
    (
        "internal_llm_model",
        re.compile(r"(?i)\bLLM\b|\bmod[eè]le\s+(?:de\s+langage|LLM|IA|local|distant)\b"),
        "Référence à un modèle LLM ou à un modèle interne.",
    ),
    (
        "internal_pipeline",
        re.compile(
            r"(?i)\bpipeline\s+(?:du|de\s+la|de)\s+(?:compte\s+rendu|traitement|g[eé]n[eé]ration|synth[eè]se)\b"
            r"|\b(?:[eé]tape|traitement|m[eé]canisme)\s+(?:du\s+)?(?:pipeline|interne)\b"
        ),
        "Référence au pipeline ou à une étape interne de fabrication.",
    ),
)

WARNING_RULES = (
    ("provided_summary", re.compile(r"(?i)\bsynth[eè]se\s+fournie\b"), "Formulation ambiguë : synthèse fournie."),
    ("analyzed_exchanges", re.compile(r"(?i)\b[eé]changes\s+analys[eé]s\b"), "Formulation ambiguë : échanges analysés."),
    ("analyzed_elements", re.compile(r"(?i)\b[eé]l[eé]ments\s+analys[eé]s\b"), "Formulation ambiguë : éléments analysés."),
)

PRESERVED_SUBTREES = frozenset(
    {
        "debug",
        "diagnostics",
        "indices_source",
        "meta",
        "metadata",
        "provenance",
        "source",
        "sources",
        "stats",
    }
)

PUBLISHABLE_KEYS = frozenset(
    {
        "action",
        "annexes",
        "avis",
        "avis_participants",
        "commentaire",
        "conclusion_expert",
        "demandes_documents",
        "demandes_documents_globales",
        "description",
        "extrait",
        "objet",
        "ordre_du_jour",
        "perspectives",
        "probleme",
        "resume",
        "resume_global",
        "role",
        "solution",
        "synthese",
        "synthese_echanges",
        "themes",
        "themes_abordes",
        "titre",
    }
)


def _iter_publishable_strings(
    value: Any,
    *,
    path: str = "$",
    publishable: bool = False,
    preserved: bool = False,
) -> Iterable[tuple[str, str]]:
    if isinstance(value, dict):
        for key, item in value.items():
            normalized = str(key).casefold()
            child_preserved = preserved or normalized in PRESERVED_SUBTREES
            child_publishable = publishable or normalized in PUBLISHABLE_KEYS
            yield from _iter_publishable_strings(
                item,
                path=f"{path}.{key}",
                publishable=child_publishable,
                preserved=child_preserved,
            )
    elif isinstance(value, list):
        for index, item in enumerate(value):
            yield from _iter_publishable_strings(
                item,
                path=f"{path}[{index}]",
                publishable=publishable,
                preserved=preserved,
            )
    elif isinstance(value, str) and publishable and not preserved:
        yield path, value


def scan_payload(payload: Any, *, stage: str, source: str = "") -> dict[str, Any]:
    findings: list[dict[str, Any]] = []
    for path, text in _iter_publishable_strings(payload):
        for severity, rules in (("blocking", BLOCKING_RULES), ("warning", WARNING_RULES)):
            for rule_id, pattern, message in rules:
                for match in pattern.finditer(text):
                    start = max(0, match.start() - 80)
                    end = min(len(text), match.end() + 80)
                    findings.append(
                        {
                            "severity": severity,
                            "rule_id": rule_id,
                            "message": message,
                            "stage": stage,
                            "source": source,
                            "path": path,
                            "match": match.group(0),
                            "context": text[start:end].replace("\n", " "),
                        }
                    )
    blocking = sum(item["severity"] == "blocking" for item in findings)
    warnings = sum(item["severity"] == "warning" for item in findings)
    return {
        "schema": "publishable-terminology-report-v1",
        "stage": stage,
        "source": source,
        "ok": blocking == 0,
        "blocking_count": blocking,
        "warning_count": warnings,
        "findings": findings,
    }


def scan_file(path: Path, *, stage: str) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8-sig"))
    return scan_payload(payload, stage=stage, source=str(path))


def _main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--stage", required=True)
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        report = scan_file(args.input, stage=args.stage)
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    except Exception as exc:
        print(f"PUBLISHABLE_TERMINOLOGY_SCAN_ERROR: {exc}", file=sys.stderr)
        return 2
    for item in report["findings"]:
        print(
            f"[{item['severity'].upper()}] {item['rule_id']} {item['path']}: "
            f"{item['match']}"
        )
    if report["blocking_count"]:
        print(
            f"PUBLISHABLE_TERMINOLOGY_BLOCKED: {report['blocking_count']} anomalie(s) bloquante(s); "
            f"rapport={args.report}",
            file=sys.stderr,
        )
        return 42
    if report["warning_count"]:
        print(f"PUBLISHABLE_TERMINOLOGY_WARNING: {report['warning_count']} avertissement(s); rapport={args.report}")
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
