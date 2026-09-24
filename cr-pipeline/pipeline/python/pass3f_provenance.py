#!/usr/bin/env python3
"""Build a deterministic Pass3F provenance registry without network access."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import unicodedata
from collections import defaultdict
from pathlib import Path
from typing import Any, Iterable


SCHEMA_VERSION = "pass3f.provenance.v2"
EVIDENCE_OCCURRENCE_ALGORITHM = "pass3f.evidence-occurrence.v2"
EVIDENCE_CONTENT_ALGORITHM = "pass3f.evidence-content.v1"
_WORD_RE = re.compile(r"[a-z0-9]+")
_CIVILITY_RE = re.compile(
    r"\b(?:M(?:onsieur)?\.?|Mme\.?|Madame|Mlle\.?|Mademoiselle|Ma[iî]tre)\s+",
    re.IGNORECASE,
)
_COMPANY_RE = re.compile(
    r"\b(?P<form>S\.?\s*C\.?\s*I\.?|S\.?\s*C\.?\s*C\.?\s*V\.?|S\.?\s*A\.?\s*R\.?\s*L\.?|"
    r"S\.?\s*A\.?\s*S\.?|S\.?\s*A\.?|E\.?\s*U\.?\s*R\.?\s*L\.?)\s+"
    r"(?P<name>[\wÀ-ÖØ-öø-ÿ'’-]+(?:\s+[\wÀ-ÖØ-öø-ÿ'’-]+){0,5})",
    re.IGNORECASE,
)
_NAMED_ORGANIZATION_RE = re.compile(
    r"\b(?P<form>soci[ée]t[ée]|organisme|association)\s+"
    r"(?P<name>[\wÀ-ÖØ-öø-ÿ'’-]+(?:\s+[\wÀ-ÖØ-öø-ÿ'’-]+){0,5})",
    re.IGNORECASE,
)
_ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
_CHUNK_RUN_RE = re.compile(r"Pass2E sujet_(\d+)\s+.*?chunk\s+(\d+)/(\d+)", re.IGNORECASE)
_CHUNK_TRUNC_RE = re.compile(r"Pass2E sujet_(\d+)\s+chunk\s+(\d+)/(\d+).*?prompt tronqu", re.IGNORECASE)
_MERGE_TRUNC_RE = re.compile(r"Pass2E merge sujet_(\d+).*?prompt tronqu", re.IGNORECASE)
_STOP_WORDS = {
    "a", "ai", "au", "aux", "avec", "ce", "ces", "dans", "de", "des",
    "du", "elle", "en", "et", "est", "il", "la", "le", "les", "mais",
    "ne", "on", "ou", "par", "pas", "pour", "que", "qui", "se", "sur",
    "un", "une", "vous",
}


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")


def stable_id(prefix: str, value: Any) -> str:
    return f"{prefix}:{hashlib.sha256(canonical_bytes(value)).hexdigest()}"


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8-sig"))


def write_json_deterministic(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n"
    path.write_text(text, encoding="utf-8", newline="\n")


def normalize_text(value: Any) -> str:
    text = unicodedata.normalize("NFKD", str(value or ""))
    text = "".join(char for char in text if not unicodedata.combining(char))
    return " ".join(_WORD_RE.findall(text.casefold()))


def content_tokens(value: Any) -> set[str]:
    return {token for token in normalize_text(value).split() if token not in _STOP_WORDS}


def normalize_identity(value: Any) -> str:
    text = _CIVILITY_RE.sub("", str(value or ""), count=1).strip()
    for form, compact in (
        (r"S\.?\s*C\.?\s*C\.?\s*V\.?", "SCCV"),
        (r"S\.?\s*A\.?\s*R\.?\s*L\.?", "SARL"),
        (r"E\.?\s*U\.?\s*R\.?\s*L\.?", "EURL"),
        (r"S\.?\s*C\.?\s*I\.?", "SCI"),
        (r"S\.?\s*A\.?\s*S\.?", "SAS"),
        (r"S\.?\s*A\.?", "SA"),
    ):
        text = re.sub(rf"\b{form}\b", compact, text, flags=re.IGNORECASE)
    return normalize_text(text)


def _identity_role(prefix: str) -> str:
    normalized = normalize_text(prefix)
    markers = (
        ("propriete de", "proprietaire"),
        ("appartient a", "proprietaire"),
        ("occupe par", "occupant"),
        ("occupee par", "occupant"),
        ("occupant", "occupant"),
        ("partie", "partie"),
        ("representee par", "other"),
        ("represente par", "other"),
    )
    found = [(normalized.rfind(marker), role) for marker, role in markers]
    position, role = max(found, default=(-1, "other"))
    return role if position >= 0 else "other"


def _clean_identity_name(value: str) -> str:
    text = re.split(r"[,.;]", value, maxsplit=1)[0]
    text = re.sub(r"\s+(?:et|ainsi\s+que)\s*$", "", text, flags=re.IGNORECASE)
    return text.strip(" \t\r\n,-")


def extract_subject_identities(item: dict[str, Any], subject_id: str) -> list[dict[str, str]]:
    identities: dict[tuple[str, str, str], dict[str, str]] = {}
    fields = (
        ("Titre", str(item.get("Titre", item.get("titre", "")) or "")),
        ("Localisation", str(item.get("Localisation", item.get("localisation", "")) or "")),
        ("Description", str(item.get("Description", item.get("description", "")) or "")),
    )
    for field_name, text in fields:
        source = f"sujets_ref.json#/Numero/{subject_id}/{field_name}"
        civility_matches = list(_CIVILITY_RE.finditer(text))
        for index, match in enumerate(civility_matches):
            end = civility_matches[index + 1].start() if index + 1 < len(civility_matches) else len(text)
            canonical = _clean_identity_name(text[match.end():end])
            normalized = normalize_identity(canonical)
            if not normalized:
                continue
            role = _identity_role(text[:match.start()])
            key = (normalized, role, source)
            identities[key] = {
                "canonical": canonical,
                "normalized": normalized,
                "role": role,
                "source": source,
            }
        for pattern, default_role in ((_COMPANY_RE, "societe"), (_NAMED_ORGANIZATION_RE, "organisme")):
            for match in pattern.finditer(text):
                name = _clean_identity_name(match.group("name"))
                form = re.sub(r"[.\s]", "", match.group("form")).upper()
                canonical = f"{form} {name}" if pattern is _COMPANY_RE else f"{match.group('form')} {name}"
                normalized = normalize_identity(canonical)
                if not normalized:
                    continue
                key = (normalized, default_role, source)
                identities[key] = {
                    "canonical": canonical,
                    "normalized": normalized,
                    "role": default_role,
                    "source": source,
                }
    return [identities[key] for key in sorted(identities)]


def _subject_number(value: Any) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def _subject_reference(item: dict[str, Any]) -> dict[str, Any]:
    number = _subject_number(item.get("Numero", item.get("numero")))
    subject_id = str(number)
    return {
        "subject_id": subject_id,
        "numero": number,
        "title": str(item.get("Titre", item.get("titre", "")) or ""),
        "location": str(item.get("Localisation", item.get("localisation", "")) or ""),
        "description": str(item.get("Description", item.get("description", "")) or ""),
        "identities": extract_subject_identities(item, subject_id),
    }


def _selected_pass2e_log(run_dir: Path) -> Path | None:
    logs = sorted((run_dir / "logs").glob("run_*.log")) if (run_dir / "logs").is_dir() else []
    return logs[-1] if logs else None


def _selected_pass3e_inputs(run_dir: Path) -> dict[str, Path]:
    selected: dict[str, Path] = {}
    debug_root = run_dir / "pass3E_debug"
    if not debug_root.is_dir():
        return selected
    for subject_dir in sorted(debug_root.glob("sujet_*")):
        subject_id = str(_subject_number(subject_dir.name.rsplit("_", 1)[-1]))
        inputs = sorted(subject_dir.glob("attempt_*/input_compact.json"))
        if inputs and subject_id != "0":
            selected[subject_id] = inputs[-1]
    return selected


def _truncation_record(
    status: str,
    scope: str,
    *,
    source_file: str = "",
    source_hash: str = "",
    details: str,
    event_refs: Iterable[str] = (),
) -> dict[str, Any]:
    return {
        "status": status,
        "stage": "2E",
        "scope": scope,
        "source_file": source_file,
        "source_hash": source_hash,
        "details": details,
        "event_refs": sorted(set(event_refs)),
    }


def _pass2e_truncation(
    run_dir: Path,
    subject_ids: set[str],
    input_hashes: dict[str, str],
) -> tuple[dict[str, dict[str, Any]], list[dict[str, Any]]]:
    log_path = _selected_pass2e_log(run_dir)
    qa_path = run_dir / "pass2e_qa.json"
    no_chunk_subjects: set[str] = set()
    if qa_path.is_file():
        qa_obj = read_json(qa_path)
        for item in qa_obj.get("subjects_without_chunk", []):
            match = re.search(r"sujet_(\d+)", str(item.get("source_name") or ""), re.IGNORECASE)
            if match:
                no_chunk_subjects.add(str(int(match.group(1))))

    announced: dict[str, set[int]] = defaultdict(set)
    totals: dict[str, set[int]] = defaultdict(set)
    events: list[dict[str, Any]] = []
    log_logical = f"logs/{log_path.name}" if log_path else ""
    log_hash = input_hashes.get(log_logical, "")
    if log_path:
        for line_number, raw_line in enumerate(log_path.read_text(encoding="utf-8-sig", errors="replace").splitlines(), 1):
            line = _ANSI_RE.sub("", raw_line).strip()
            run_match = _CHUNK_RUN_RE.search(line)
            if run_match:
                subject_id = str(int(run_match.group(1)))
                announced[subject_id].add(int(run_match.group(2)))
                totals[subject_id].add(int(run_match.group(3)))
            chunk_match = _CHUNK_TRUNC_RE.search(line)
            merge_match = _MERGE_TRUNC_RE.search(line)
            if not chunk_match and not merge_match:
                continue
            subject_id = str(int((chunk_match or merge_match).group(1)))
            event = {
                "subject_id": subject_id,
                "operation": "chunk" if chunk_match else "merge",
                "chunk_index": int(chunk_match.group(2)) if chunk_match else None,
                "chunk_total": int(chunk_match.group(3)) if chunk_match else None,
                "status": "confirmed",
                "stage": "2E",
                "scope": "chunk" if chunk_match else "subject",
                "source_file": log_logical,
                "source_line": line_number,
                "source_hash": log_hash,
                "details": line,
            }
            event["event_id"] = stable_id("truncation", {
                "source_hash": log_hash,
                "subject_id": subject_id,
                "operation": event["operation"],
                "chunk_index": event["chunk_index"],
                "chunk_total": event["chunk_total"],
                "details": line,
            })
            events.append(event)
    events.sort(key=lambda item: (int(item["subject_id"]), item["source_line"], item["event_id"]))
    events_by_subject: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for event in events:
        events_by_subject[event["subject_id"]].append(event)

    qa_logical = "pass2e_qa.json"
    summaries: dict[str, dict[str, Any]] = {}
    for subject_id in sorted(subject_ids, key=int):
        subject_events = events_by_subject.get(subject_id, [])
        if subject_events:
            summaries[subject_id] = _truncation_record(
                "confirmed", "subject", source_file=log_logical, source_hash=log_hash,
                details="At least one Pass2E chunk or merge prompt was explicitly logged as truncated; no fragment-to-chunk mapping is persisted.",
                event_refs=(item["event_id"] for item in subject_events),
            )
            continue
        if subject_id in no_chunk_subjects:
            summaries[subject_id] = _truncation_record(
                "none", "subject", source_file=qa_logical, source_hash=input_hashes.get(qa_logical, ""),
                details="pass2e_qa.json records that no Pass2E chunk was generated for this subject.",
            )
            continue
        expected_totals = totals.get(subject_id, set())
        complete = len(expected_totals) == 1 and announced.get(subject_id) == set(range(1, next(iter(expected_totals)) + 1))
        if complete and (run_dir / "pass2E_sujets_compact" / f"sujet_{int(subject_id):03d}_compact.json").is_file():
            summaries[subject_id] = _truncation_record(
                "none", "subject", source_file=log_logical, source_hash=log_hash,
                details="The selected run log announces every Pass2E chunk for this subject and contains no truncation warning for it.",
            )
        else:
            summaries[subject_id] = _truncation_record(
                "unknown", "unknown", source_file=log_logical, source_hash=log_hash,
                details="Existing artifacts do not prove whether every Pass2E input for this subject was truncated or complete.",
            )
    return summaries, events


def _source_evidence_locator(item: dict[str, Any]) -> dict[str, Any]:
    return {
        "segment_id": str(item.get("segment_id") or ""),
        "row_ref": item.get("row_ref"),
        "timecode": str(item.get("timecode") or ""),
        "speaker": str(item.get("auteur") or ""),
        "exact_text": str(item.get("texte") or ""),
    }


def _normalized_evidence_locator(item: dict[str, Any]) -> dict[str, Any]:
    return {
        "segment_id": str(item.get("segment_id") or ""),
        "row_ref": item.get("row_ref"),
        "timecode": str(item.get("timecode") or ""),
        "speaker": str(item.get("speaker") or ""),
        "exact_text": str(item.get("exact_text") or ""),
    }


def _json_pointer_token(value: Any) -> str:
    return str(value).replace("~", "~0").replace("/", "~1")


def _legacy_evidence_id(source_hash: str, item: dict[str, Any]) -> str:
    # Reproduce the v1 bug for historical diagnostics only.
    return stable_id("evidence", {
        "source_hash": source_hash,
        "locator": _source_evidence_locator(item),
    })


def _evidence_occurrence_id(source_hash: str, item: dict[str, Any]) -> str:
    locator = _normalized_evidence_locator(item)
    return stable_id("evidence-occurrence", {
        "algorithm": EVIDENCE_OCCURRENCE_ALGORITHM,
        "source_artifact": "global.json",
        "source_hash": source_hash,
        "source_pointers": sorted(item["source_pointers"]),
        "segment_id": locator["segment_id"],
        "row_ref": locator["row_ref"],
        "timecode": locator["timecode"],
        "speaker": locator["speaker"],
        "exact_text_sha256": hashlib.sha256(locator["exact_text"].encode("utf-8")).hexdigest(),
    })


def _evidence_content_id(exact_text: str) -> str:
    return stable_id("evidence-content", {
        "algorithm": EVIDENCE_CONTENT_ALGORITHM,
        "normalized_text": normalize_text(exact_text),
    })


def _paragraphs(value: str) -> list[str]:
    parts = [part.strip() for part in re.split(r"\n\s*\n", value) if part.strip()]
    return parts or ([value.strip()] if value.strip() else [])


def _walk_semantic_text(value: Any, path: str) -> Iterable[tuple[str, str]]:
    if isinstance(value, str):
        for index, paragraph in enumerate(_paragraphs(value)):
            yield f"{path}/{index}", paragraph
    elif isinstance(value, list):
        for index, item in enumerate(value):
            yield from _walk_semantic_text(item, f"{path}/{index}")
    elif isinstance(value, dict):
        for key in sorted(value):
            yield from _walk_semantic_text(value[key], f"{path}/{key}")


def _derived_texts(stage: str, obj: dict[str, Any]) -> Iterable[tuple[str, str]]:
    if stage == "2E":
        semantic = obj.get("synthese_intermediaire")
        if semantic is not None:
            yield from _walk_semantic_text(semantic, "/synthese_intermediaire")
        return
    if stage == "2F":
        for key in ("synthese_intermediaire", "points_documentes", "incertitudes", "photo_contexts"):
            if key in obj:
                yield from _walk_semantic_text(obj[key], f"/{key}")
        return
    for key in ("avis_participants", "synthese_echanges", "conclusion_expert"):
        if key in obj:
            yield from _walk_semantic_text(obj[key], f"/{key}")


def _link_fragment(text: str, evidence: list[dict[str, Any]]) -> list[dict[str, Any]]:
    normalized = normalize_text(text)
    fragment_tokens = content_tokens(text)
    verified: list[dict[str, Any]] = []
    candidates: list[dict[str, Any]] = []
    for item in evidence:
        evidence_text = item["exact_text"]
        evidence_normalized = normalize_text(evidence_text)
        if min(len(normalized), len(evidence_normalized)) >= 24 and (
            normalized in evidence_normalized or evidence_normalized in normalized
        ):
            verified.append({
                "evidence_occurrence_id": item["evidence_occurrence_id"],
                "link_status": "verified",
                "method": "normalized_exact_containment",
                "score": 1.0,
            })
            continue
        evidence_tokens = content_tokens(evidence_text)
        overlap = len(fragment_tokens & evidence_tokens)
        denominator = min(len(fragment_tokens), len(evidence_tokens))
        score = (overlap / denominator) if denominator else 0.0
        if overlap >= 3 and score >= 0.6:
            candidates.append({
                "evidence_occurrence_id": item["evidence_occurrence_id"],
                "link_status": "candidate",
                "method": "token_overlap",
                "score": round(score, 6),
            })
    links = verified or sorted(
        candidates, key=lambda link: (-link["score"], link["evidence_occurrence_id"])
    )[:8]
    if links:
        return sorted(links, key=lambda link: (link["link_status"], link["evidence_occurrence_id"]))
    return [{
        "evidence_occurrence_id": None,
        "link_status": "unresolved",
        "method": "none",
        "score": 0.0,
    }]


def _collect_input_files(run_dir: Path, pass2f_dir: Path | None) -> list[tuple[str, Path]]:
    required = ["global.json", "sujets_ref.json", "global_by_sujet.json"]
    files: list[tuple[str, Path]] = []
    for name in required:
        path = run_dir / name
        if not path.is_file():
            raise FileNotFoundError(f"required Pass3F input missing: {path}")
        files.append((name, path))
    for directory, pattern in (
        (run_dir / "pass2E_sujets_compact", "*.json"),
        (run_dir / "pass3E_sujets", "*.json"),
    ):
        if directory.is_dir():
            files.extend((f"{directory.name}/{p.name}", p) for p in sorted(directory.glob(pattern)))
    qa_path = run_dir / "pass2e_qa.json"
    if qa_path.is_file():
        files.append(("pass2e_qa.json", qa_path))
    pass2e_log = _selected_pass2e_log(run_dir)
    if pass2e_log:
        files.append((f"logs/{pass2e_log.name}", pass2e_log))
    for subject_id, path in sorted(_selected_pass3e_inputs(run_dir).items(), key=lambda item: int(item[0])):
        files.append((f"pass3E_debug/sujet_{int(subject_id):03d}/input_compact.json", path))
    if pass2f_dir and pass2f_dir.is_dir():
        files.extend(
            (f"pass2f/{p.relative_to(pass2f_dir).as_posix()}", p)
            for p in sorted(pass2f_dir.rglob("*.json"))
        )
    return sorted(files, key=lambda pair: pair[0])


def build_registry(
    run_dir: Path,
    *,
    pipeline_kind: str = "generaliste",
    pass2f_dir: Path | None = None,
) -> dict[str, Any]:
    run_dir = Path(run_dir)
    input_files = _collect_input_files(run_dir, pass2f_dir)
    input_hashes = {logical: file_sha256(path) for logical, path in input_files}
    run_id = stable_id("run", {"pipeline_kind": pipeline_kind, "inputs": input_hashes})

    subjects = sorted(
        (_subject_reference(item) for item in read_json(run_dir / "sujets_ref.json")),
        key=lambda item: item["numero"],
    )
    subject_ids = {item["subject_id"] for item in subjects}
    subject_truncation, truncation_events = _pass2e_truncation(run_dir, subject_ids, input_hashes)
    for subject in subjects:
        subject["truncation"] = subject_truncation[subject["subject_id"]]
    raw_subjects = read_json(run_dir / "global.json").get("sujets", {})
    grouped: dict[bytes, dict[str, Any]] = {}
    for raw_subject_id in sorted(raw_subjects, key=lambda value: _subject_number(value)):
        subject_id = str(_subject_number(raw_subject_id))
        if subject_id not in subject_ids:
            continue
        locator_occurrences: dict[bytes, int] = defaultdict(int)
        for item_index, item in enumerate(raw_subjects.get(raw_subject_id) or []):
            if not isinstance(item, dict) or not str(item.get("texte") or "").strip():
                continue
            locator = _source_evidence_locator(item)
            locator_key = canonical_bytes(locator)
            occurrence_index = locator_occurrences[locator_key]
            locator_occurrences[locator_key] += 1
            key = canonical_bytes({"locator": locator, "occurrence_index": occurrence_index})
            if key not in grouped:
                grouped[key] = {
                    **locator,
                    "source_artifact": "global.json",
                    "source_pointers": set(),
                    "pass1_subjects": set(),
                    "projection_classification": str(item.get("projection_classification") or ""),
                    "reported_subject_count": item.get("row_ref_subject_count"),
                }
            grouped[key]["source_pointers"].add(
                f"/sujets/{_json_pointer_token(raw_subject_id)}/{item_index}"
            )
            grouped[key]["pass1_subjects"].add(subject_id)

    evidence: list[dict[str, Any]] = []
    for key in sorted(grouped):
        item = grouped[key]
        item["source_pointers"] = sorted(item["source_pointers"])
        item["pass1_subjects"] = sorted(item["pass1_subjects"], key=int)
        item["identity_algorithm"] = EVIDENCE_OCCURRENCE_ALGORITHM
        item["source_hash"] = input_hashes["global.json"]
        item["exact_text_sha256"] = hashlib.sha256(item["exact_text"].encode("utf-8")).hexdigest()
        item["evidence_occurrence_id"] = _evidence_occurrence_id(input_hashes["global.json"], item)
        item["evidence_content_id"] = _evidence_content_id(item["exact_text"])
        item["legacy_evidence_id"] = _legacy_evidence_id(input_hashes["global.json"], item)
        evidence.append(item)
    legacy_counts: dict[str, int] = defaultdict(int)
    for item in evidence:
        legacy_counts[item["legacy_evidence_id"]] += 1
    for item in evidence:
        item["legacy_evidence_id_collision"] = legacy_counts[item["legacy_evidence_id"]] > 1
        item["legacy_evidence_id_occurrence_count"] = legacy_counts[item["legacy_evidence_id"]]
    occurrence_ids = [item["evidence_occurrence_id"] for item in evidence]
    if len(occurrence_ids) != len(set(occurrence_ids)):
        raise ValueError("evidence occurrence identity collision")
    evidence.sort(key=lambda item: (
        str(item["segment_id"]),
        item["row_ref"] if isinstance(item["row_ref"], int) else 10**12,
        item["evidence_occurrence_id"],
    ))
    by_subject: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for item in evidence:
        for subject_id in item["pass1_subjects"]:
            by_subject[subject_id].append(item)

    derived: list[dict[str, Any]] = []
    pass3e_inputs = _selected_pass3e_inputs(run_dir)
    pass3e_compact_verified: dict[str, bool] = {}
    for subject_id, debug_path in pass3e_inputs.items():
        compact_path = run_dir / "pass2E_sujets_compact" / f"sujet_{int(subject_id):03d}_compact.json"
        pass3e_compact_verified[subject_id] = compact_path.is_file() and canonical_bytes(read_json(debug_path)) == canonical_bytes(read_json(compact_path))
    stage_dirs = (
        ("2E", run_dir / "pass2E_sujets_compact", "*_compact.json"),
        ("3E", run_dir / "pass3E_sujets", "*_synthese.json"),
    )
    for stage, directory, pattern in stage_dirs:
        if not directory.is_dir():
            continue
        for path in sorted(directory.glob(pattern)):
            obj = read_json(path)
            subject_id = str(_subject_number(obj.get("numero")))
            if subject_id not in subject_ids:
                continue
            for field_path, text in _derived_texts(stage, obj):
                fragment = {
                    "stage": stage,
                    "subject_id": subject_id,
                    "field_path": field_path,
                    "text": text,
                    "source_artifact": f"{directory.name}/{path.name}",
                }
                fragment["fragment_id"] = stable_id("fragment", fragment)
                fragment["links"] = _link_fragment(text, by_subject.get(subject_id, []))
                subject_status = subject_truncation[subject_id]
                if subject_status["status"] == "confirmed":
                    if stage == "2E" or pass3e_compact_verified.get(subject_id, False):
                        fragment["truncation"] = _truncation_record(
                            "possible", "subject", source_file=subject_status["source_file"], source_hash=subject_status["source_hash"],
                            details="This fragment derives from a subject whose Pass2E processing has a confirmed truncation, but no persisted artifact maps the fragment to a specific truncated chunk.",
                            event_refs=subject_status["event_refs"],
                        )
                    else:
                        fragment["truncation"] = _truncation_record(
                            "unknown", "unknown", source_file=subject_status["source_file"], source_hash=subject_status["source_hash"],
                            details="The subject has a confirmed Pass2E truncation, but pass3E_debug does not prove that this 3E output consumed the matching compact.",
                            event_refs=subject_status["event_refs"],
                        )
                else:
                    fragment["truncation"] = dict(subject_status)
                derived.append(fragment)
    if pass2f_dir and pass2f_dir.is_dir():
        for path in sorted(pass2f_dir.rglob("*.json")):
            obj = read_json(path)
            if not isinstance(obj, dict):
                continue
            schema_version = str(obj.get("schema_version") or "")
            source_pass = str(obj.get("source_pass") or "")
            if source_pass != "2F" and "pass2f" not in schema_version.casefold():
                continue
            subject_id = str(_subject_number(obj.get("subject_numero", obj.get("numero"))))
            if subject_id not in subject_ids:
                continue
            source_artifact = f"pass2f/{path.relative_to(pass2f_dir).as_posix()}"
            for field_path, text in _derived_texts("2F", obj):
                fragment = {
                    "stage": "2F",
                    "subject_id": subject_id,
                    "field_path": field_path,
                    "text": text,
                    "source_artifact": source_artifact,
                }
                fragment["fragment_id"] = stable_id("fragment", fragment)
                fragment["links"] = _link_fragment(text, by_subject.get(subject_id, []))
                fragment["truncation"] = _truncation_record(
                    "unknown", "unknown",
                    details="This Pass2F fragment is not itself generated from a Pass2E compact; no Pass2E truncation relation is asserted.",
                )
                derived.append(fragment)
    derived.sort(key=lambda item: (
        item["stage"], int(item["subject_id"]), item["field_path"], item["fragment_id"]
    ))

    return {
        "schema": SCHEMA_VERSION,
        "run": {"run_id": run_id, "pipeline_kind": pipeline_kind, "input_hashes": input_hashes},
        "subjects": subjects,
        "evidence": evidence,
        "truncation_events": truncation_events,
        "derived_fragments": derived,
        "stats": {
            "subject_count": len(subjects),
            "evidence_count": len(evidence),
            "evidence_occurrence_count": len(evidence),
            "evidence_content_count": len({item["evidence_content_id"] for item in evidence}),
            "legacy_evidence_collision_id_count": sum(count > 1 for count in legacy_counts.values()),
            "derived_fragment_count": len(derived),
            "verified_link_count": sum(link["link_status"] == "verified" for item in derived for link in item["links"]),
            "candidate_link_count": sum(link["link_status"] == "candidate" for item in derived for link in item["links"]),
            "unresolved_fragment_count": sum(item["links"][0]["link_status"] == "unresolved" for item in derived),
            "confirmed_truncation_subject_count": sum(item["truncation"]["status"] == "confirmed" for item in subjects),
            "confirmed_truncation_fragment_count": sum(item["truncation"]["status"] == "confirmed" for item in derived),
            "possible_truncation_fragment_count": sum(item["truncation"]["status"] == "possible" for item in derived),
            "unknown_truncation_fragment_count": sum(item["truncation"]["status"] == "unknown" for item in derived),
            "truncation_event_count": len(truncation_events),
        },
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-dir", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--pipeline-kind", choices=("generaliste", "refere"), default="generaliste")
    parser.add_argument("--pass2f-dir", type=Path)
    args = parser.parse_args(argv)
    write_json_deterministic(
        args.out,
        build_registry(args.run_dir, pipeline_kind=args.pipeline_kind, pass2f_dir=args.pass2f_dir),
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
