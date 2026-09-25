#!/usr/bin/env python3
"""Deterministically prefilter cross-subject candidates for future Pass3F-A."""

from __future__ import annotations

import argparse
import itertools
import re
from collections import defaultdict
from pathlib import Path
from typing import Any, Iterable

from pass3f_provenance import content_tokens, normalize_text, read_json, stable_id, write_json_deterministic


SCHEMA_VERSION = "pass3f.candidates.v2"
_ADDRESS_RE = re.compile(
    r"\b(?P<number>\d{1,4})\s+"
    r"(?P<kind>rue|avenue|boulevard|place|all[ée]e|chemin|impasse)\s+"
    r"(?:(?:de\s+la|de\s+l['’]|de|du|des)\s+)?"
    r"(?P<name>[A-ZÀ-ÖØ-Þ][\w'’-]*(?:\s+[A-ZÀ-ÖØ-Þ][\w'’-]*){0,3})"
)


def _index_unique(items: list[dict[str, Any]], key: str) -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = {}
    for item in items:
        value = str(item[key])
        if value in result:
            raise ValueError(f"duplicate {key}: {value}")
        result[value] = item
    return result


def _canonical_address(match: re.Match[str]) -> str:
    return "|".join((match.group("number"), normalize_text(match.group("kind")), normalize_text(match.group("name"))))


def extract_addresses(text: str) -> list[dict[str, str]]:
    found: dict[str, str] = {}
    for match in _ADDRESS_RE.finditer(text or ""):
        found.setdefault(_canonical_address(match), match.group(0))
    return [{"canonical": key, "display": found[key]} for key in sorted(found)]


def _candidate(kind: str, payload: dict[str, Any]) -> dict[str, Any]:
    identity_payload = {
        key: value for key, value in payload.items()
        if key not in {"direct_evidence_refs", "context_evidence_refs", "target_signals"}
    }
    return {
        "candidate_id": stable_id("candidate", {"kind": kind, **identity_payload}),
        "kind": kind,
        **payload,
        "direct_evidence_refs": sorted(set(
            payload.get("direct_evidence_refs", payload.get("evidence_refs") or [])
        )),
        "context_evidence_refs": sorted(set(payload.get("context_evidence_refs") or [])),
        "ambiguous": True,
        "requires_llm_review": True,
    }


def _subject_signal_indexes(registry: dict[str, Any]) -> tuple[dict[str, set[str]], dict[str, set[str]]]:
    address_subjects: dict[str, set[str]] = defaultdict(set)
    identity_subjects: dict[str, set[str]] = defaultdict(set)
    for subject in registry["subjects"]:
        subject_id = subject["subject_id"]
        reference = " ".join((subject["title"], subject["location"], subject["description"]))
        for address in extract_addresses(reference):
            address_subjects[address["canonical"]].add(subject_id)
        for identity in subject.get("identities") or []:
            normalized = str(identity.get("normalized") or "")
            if normalized:
                identity_subjects[normalized].add(subject_id)
    return address_subjects, identity_subjects


def _contains_normalized_identity(text: str, identity: str) -> bool:
    return f" {identity} " in f" {normalize_text(text)} "


def _enrich_target_signals(registry: dict[str, Any], candidate: dict[str, Any]) -> dict[str, Any]:
    evidence = _index_unique(registry["evidence"], "evidence_occurrence_id")
    fragments = {item["fragment_id"]: item for item in registry["derived_fragments"]}
    address_subjects, identity_subjects = _subject_signal_indexes(registry)
    texts = [candidate.get("excerpt", "")]
    texts.extend(
        fragments[ref]["text"] for ref in candidate.get("fragment_refs") or [] if ref in fragments
    )
    texts.extend(
        evidence[ref]["exact_text"]
        for ref in candidate.get("direct_evidence_refs") or candidate.get("evidence_refs") or []
        if ref in evidence
    )
    corpus = "\n".join(dict.fromkeys(text for text in texts if text))
    address_matches = {
        subject_id
        for address in extract_addresses(candidate.get("excerpt", ""))
        for subject_id in address_subjects.get(address["canonical"], set())
    }
    identity_matches = {
        subject_id
        for identity, subject_ids in identity_subjects.items()
        if _contains_normalized_identity(corpus, identity)
        for subject_id in subject_ids
    }
    combined_matches = address_matches & identity_matches
    result = dict(candidate)
    result["target_signals"] = {
        "address_matches": sorted(address_matches, key=int),
        "identity_matches": sorted(identity_matches, key=int),
        "combined_matches": sorted(combined_matches, key=int),
    }
    signals = list(result["signals"])
    if combined_matches:
        signals.append("exact address and identity signals converge")
    elif identity_matches and not address_matches:
        signals.append("exact identity signal without an exact address target")
    elif address_matches and identity_matches:
        signals.append("exact address and identity signals point to different subjects")
    if len(identity_matches) > 1:
        signals.append("the same normalized identity is associated with multiple subjects")
    result["signals"] = list(dict.fromkeys(signals))
    return result


def _shared_evidence(registry: dict[str, Any]) -> Iterable[dict[str, Any]]:
    for item in registry["evidence"]:
        if len(item["pass1_subjects"]) < 2:
            continue
        for left, right in itertools.combinations(item["pass1_subjects"], 2):
            yield _candidate("shared_evidence", {
                "source_subject": left,
                "target_subject": right,
                "excerpt": item["exact_text"],
                "evidence_refs": [item["evidence_occurrence_id"]],
                "fragment_refs": [],
                "signals": ["same persistent source evidence assigned by Pass1 to both subjects"],
                "score": 1.0,
            })


def _reference_conflicts(registry: dict[str, Any]) -> Iterable[dict[str, Any]]:
    evidence_by_id = _index_unique(registry["evidence"], "evidence_occurrence_id")
    subject_addresses: dict[str, set[str]] = {}
    address_subjects: dict[str, list[str]] = defaultdict(list)
    for subject in registry["subjects"]:
        subject_id = subject["subject_id"]
        reference = " ".join((subject["title"], subject["location"], subject["description"]))
        addresses = {item["canonical"] for item in extract_addresses(reference)}
        subject_addresses[subject_id] = addresses
        for address in addresses:
            address_subjects[address].append(subject_id)

    grouped: dict[tuple[str, str, str | None], dict[str, Any]] = {}
    for fragment in registry["derived_fragments"]:
        source = fragment["subject_id"]
        for address in extract_addresses(fragment["text"]):
            canonical = address["canonical"]
            if canonical in subject_addresses.get(source, set()):
                continue
            targets = [item for item in address_subjects.get(canonical, []) if item != source]
            for target in targets or [None]:
                key = (source, canonical, target)
                if key not in grouped:
                    grouped[key] = {
                        "source_subject": source,
                        "target_subject": target,
                        "excerpt": fragment["text"],
                        "evidence_refs": [],
                        "direct_evidence_refs": [],
                        "context_evidence_refs": [],
                        "fragment_refs": [],
                        "signals": [f"address {address['display']!r} is absent from the source subject reference"],
                        "score": 1.0 if target is not None else 0.9,
                    }
                grouped[key]["fragment_refs"].append(fragment["fragment_id"])
                for link in fragment["links"]:
                    evidence_id = link["evidence_occurrence_id"]
                    if not evidence_id:
                        continue
                    grouped[key]["evidence_refs"].append(evidence_id)
                    evidence_item = evidence_by_id.get(evidence_id)
                    evidence_addresses = {
                        item["canonical"] for item in extract_addresses(
                            evidence_item["exact_text"] if evidence_item else ""
                        )
                    }
                    usage = "direct_evidence_refs" if canonical in evidence_addresses else "context_evidence_refs"
                    grouped[key][usage].append(evidence_id)
    for value in grouped.values():
        value["fragment_refs"] = sorted(set(value["fragment_refs"]))
        value["evidence_refs"] = sorted(set(value["evidence_refs"]))
        value["direct_evidence_refs"] = sorted(set(value["direct_evidence_refs"]))
        value["context_evidence_refs"] = sorted(
            set(value["context_evidence_refs"]) - set(value["direct_evidence_refs"])
        )
        yield _candidate("subject_reference_conflict", value)


def _human_photo_assignment_conflicts(
    registry: dict[str, Any],
) -> Iterable[dict[str, Any]]:
    evidence_by_id = _index_unique(registry["evidence"], "evidence_occurrence_id")
    subject_addresses: dict[str, set[str]] = {}
    for subject in registry["subjects"]:
        reference = " ".join((
            subject["title"], subject["location"], subject["description"]
        ))
        subject_addresses[subject["subject_id"]] = {
            item["canonical"] for item in extract_addresses(reference)
        }
    grouped: dict[tuple[str, str, str], dict[str, Any]] = {}
    for fragment in registry["derived_fragments"]:
        source = fragment["subject_id"]
        for link in fragment["links"]:
            evidence_id = link.get("evidence_occurrence_id")
            evidence = evidence_by_id.get(evidence_id)
            if not evidence or evidence.get("evidence_kind") != "photo":
                continue
            assignment = next((
                relation for relation in evidence.get("provenance_links") or []
                if relation.get("relation_type") == "subject_assignment"
                and relation.get("stage") == "photo_assignment"
                and relation.get("authority") == "human"
            ), None)
            if not assignment or assignment.get("subject_numero") is None:
                continue
            target = str(assignment["subject_numero"])
            if target == source:
                continue
            key = (source, target, evidence_id)
            if key not in grouped:
                signals = [
                    "reference_kind=human_photo_assignment",
                    "the linked photo has an explicit human assignment to another subject",
                ]
                fragment_addresses = {
                    item["canonical"] for item in extract_addresses(fragment["text"])
                }
                if fragment_addresses & subject_addresses.get(target, set()):
                    signals.append("reference_kind=combined")
                context_ids = {
                    relation["source_id"]
                    for relation in evidence.get("provenance_links") or []
                    if relation.get("relation_type") == "context"
                    and relation.get("stage") == "photo_asr_window"
                }
                context_subjects = {
                    str(subject_id)
                    for context_id in context_ids
                    for subject_id in (
                        evidence_by_id.get(context_id, {}).get("pass1_subjects") or []
                    )
                }
                if source in context_subjects:
                    signals.append("reference_kind=visit_window")
                grouped[key] = {
                    "source_subject": source,
                    "target_subject": target,
                    "excerpt": fragment["text"],
                    "evidence_refs": [evidence_id],
                    "direct_evidence_refs": [evidence_id],
                    "context_evidence_refs": sorted(context_ids),
                    "fragment_refs": [],
                    "signals": signals,
                    "score": 1.0,
                }
            grouped[key]["fragment_refs"].append(fragment["fragment_id"])
    for value in grouped.values():
        value["fragment_refs"] = sorted(set(value["fragment_refs"]))
        yield _candidate("subject_reference_conflict", value)


def _derived_duplicates(registry: dict[str, Any]) -> Iterable[dict[str, Any]]:
    fragments = [item for item in registry["derived_fragments"] if len(content_tokens(item["text"])) >= 8]
    for left, right in itertools.combinations(fragments, 2):
        if left["subject_id"] == right["subject_id"] or left["stage"] != right["stage"]:
            continue
        left_tokens = content_tokens(left["text"])
        right_tokens = content_tokens(right["text"])
        union = left_tokens | right_tokens
        score = len(left_tokens & right_tokens) / len(union) if union else 0.0
        exact = normalize_text(left["text"]) == normalize_text(right["text"])
        if not exact and score < 0.9:
            continue
        left_evidence = {
            link["evidence_occurrence_id"] for link in left["links"]
            if link["evidence_occurrence_id"]
        }
        right_evidence = {
            link["evidence_occurrence_id"] for link in right["links"]
            if link["evidence_occurrence_id"]
        }
        common_evidence = left_evidence & right_evidence
        if not common_evidence:
            continue
        yield _candidate("derived_text_duplicate", {
            "source_subject": left["subject_id"],
            "target_subject": right["subject_id"],
            "excerpt": left["text"],
            "evidence_refs": sorted(common_evidence),
            "fragment_refs": sorted((left["fragment_id"], right["fragment_id"])),
            "signals": ["normalized exact duplicate" if exact else "token Jaccard >= 0.90"],
            "score": 1.0 if exact else round(score, 6),
        })


def build_candidates(registry: dict[str, Any]) -> dict[str, Any]:
    if registry.get("schema") != "pass3f.provenance.v2":
        raise ValueError("unsupported provenance registry schema")
    values = list(_shared_evidence(registry))
    values.extend(_reference_conflicts(registry))
    values.extend(_human_photo_assignment_conflicts(registry))
    values.extend(_derived_duplicates(registry))
    values = [_enrich_target_signals(registry, item) for item in values]
    candidates = sorted({item["candidate_id"]: item for item in values}.values(), key=lambda item: item["candidate_id"])
    by_kind: dict[str, int] = defaultdict(int)
    for item in candidates:
        by_kind[item["kind"]] += 1
    return {
        "schema": SCHEMA_VERSION,
        "source_registry_hash": stable_id("registry", registry),
        "candidates": candidates,
        "stats": {"candidate_count": len(candidates), "by_kind": dict(sorted(by_kind.items()))},
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args(argv)
    write_json_deterministic(args.out, build_candidates(read_json(args.registry)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
