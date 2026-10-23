#!/usr/bin/env python3
"""Adapt a completed refere run to the common deterministic Pass3F registry."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import logging
import re
import shutil
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

from pass3f_provenance import (
    EVIDENCE_CONTENT_ALGORITHM,
    PHOTO_OCCURRENCE_ALGORITHM,
    build_registry,
    canonical_bytes,
    extract_subject_identities,
    file_sha256,
    normalize_text,
    read_json,
    recompute_registry_stats,
    stable_id,
    write_json_deterministic,
)
from photo_context_resolver import SourceSelection, resolve_photo_context


ADAPTER_VERSION = "pass3f.refere-adapter.v2"
PHOTO_ASR_WINDOW_SECONDS = 30.0
_LOGGER = logging.getLogger("pass3f.refere_adapter")
_ROW_RE = re.compile(r"\[ROW\s+(\d+)\]")
_PHOTO_CONTEXT_RE = re.compile(r"^/photo_contexts/(\d+)(?:/|$)")


@dataclass(frozen=True)
class RefereSources:
    run_dir: Path
    sujets_csv: Path
    generalist_run: Path
    assignments_json: Path
    photos_csv: Path
    pass2e_dir: Path
    pass2f_dir: Path
    pass3e_dir: Path
    refere_global_by_sujet: Path
    material_rank1: Path
    affaires_root: Path
    id_affaire: str
    id_captation: str


class RefereAdapterConsistencyError(ValueError):
    """Raised when photo sources contradict the legacy refere material."""

    def __init__(
        self,
        code: str,
        message: str,
        *,
        diagnostics: Iterable[dict[str, Any]] = (),
    ):
        super().__init__(message)
        self.code = code
        self.message = message
        self.diagnostics = tuple(dict(item) for item in diagnostics)


def _read_csv(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-8-sig", newline="") as stream:
        sample = stream.read(8192)
        stream.seek(0)
        try:
            dialect = csv.Sniffer().sniff(sample, delimiters=";,\t,")
        except csv.Error:
            dialect = csv.excel
            dialect.delimiter = ";"
        return [
            {str(key or "").strip(): str(value or "").strip() for key, value in row.items()}
            for row in csv.DictReader(stream, dialect=dialect)
        ]


def _first_existing(paths: Iterable[Path]) -> Path:
    for path in paths:
        if path.is_file():
            return path
    raise FileNotFoundError("none of the expected files exists: " + ", ".join(map(str, paths)))


def _generalist_run_from_material(material: dict[str, Any]) -> Path:
    for unit in material.get("units") or []:
        segment_file = (unit.get("provenance") or {}).get("segment_file")
        if segment_file:
            path = Path(str(segment_file))
            if path.parent.name == "segments":
                return path.parent.parent
    raise ValueError("pass2b2f material does not identify the generalist source run")


def discover_sources(run_dir: Path, *, affaires_root: Path | None = None) -> RefereSources:
    run_dir = Path(run_dir)
    manifest = read_json(run_dir / "manifest.json")
    id_affaire = str(manifest["id_affaire"])
    id_captation = str(manifest["id_captation"])
    if affaires_root is None:
        candidates = [Path("/data/Affaires"), Path(r"C:\Affaires")]
        affaires_root = next((path for path in candidates if path.is_dir()), candidates[0])
    material_path = run_dir / "pass2b2f" / "pass2b2f_material_rank1.json"
    material = read_json(material_path)
    generalist_run = _generalist_run_from_material(material)
    transcription = (
        affaires_root / id_affaire / "AF_Expert_ASR" / "transcriptions" / id_captation
    )
    photos_dir = (
        affaires_root / id_affaire / "AE_Expert_captations" / id_captation / "photos"
    )
    photos_csv = _first_existing((photos_dir / "photos.csv", photos_dir / "photos_batch.csv"))
    return RefereSources(
        run_dir=run_dir,
        sujets_csv=transcription / "Sujets.csv",
        generalist_run=generalist_run,
        assignments_json=photos_dir / "photo_subject_assignments.json",
        photos_csv=photos_csv,
        pass2e_dir=generalist_run / "pass2E_sujets_compact",
        pass2f_dir=run_dir / "parsed_outputs",
        pass3e_dir=run_dir / "pass3_refere" / "sujets",
        refere_global_by_sujet=run_dir / "pass3_refere" / "refere_global_by_sujet.json",
        material_rank1=material_path,
        affaires_root=affaires_root,
        id_affaire=id_affaire,
        id_captation=id_captation,
    )


def _subject_number(value: Any) -> int:
    match = re.search(r"\d+", str(value or ""))
    if not match:
        raise ValueError(f"invalid subject number: {value!r}")
    return int(match.group())


def _canonical_subjects(path: Path) -> list[dict[str, Any]]:
    values = []
    for row in _read_csv(path):
        lowered = {key.casefold(): value for key, value in row.items()}
        numero = _subject_number(lowered.get("numero"))
        values.append({
            "Numero": numero,
            "Titre": lowered.get("titre", ""),
            "Localisation": lowered.get("localisation", ""),
            "Description": lowered.get("description", ""),
        })
    return sorted(values, key=lambda item: item["Numero"])


def normalize_participants(value: Any) -> list[Any]:
    if value is None:
        return []
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        return [value]
    raise TypeError(f"unsupported avis_participants value: {type(value).__name__}")


def _aggregate_subjects(path: Path) -> dict[int, dict[str, Any]]:
    raw = read_json(path)
    values = raw.get("sujets") or []
    if isinstance(values, dict):
        values = list(values.values())
    return {_subject_number(item.get("numero")): item for item in values}


def _prepare_common_run(sources: RefereSources, destination: Path) -> dict[str, Any]:
    canonical = _canonical_subjects(sources.sujets_csv)
    canonical_by_id = {item["Numero"]: item for item in canonical}
    aggregate = _aggregate_subjects(sources.refere_global_by_sujet)
    write_json_deterministic(destination / "sujets_ref.json", canonical)
    shutil.copy2(sources.generalist_run / "global.json", destination / "global.json")
    shutil.copytree(sources.pass2e_dir, destination / "pass2E_sujets_compact")

    for relative in ("pass2e_qa.json",):
        source = sources.generalist_run / relative
        if source.is_file():
            shutil.copy2(source, destination / relative)
    for directory in ("logs", "pass3E_debug"):
        source = sources.generalist_run / directory
        if source.is_dir():
            shutil.copytree(source, destination / directory)

    normalized_aggregate = dict(read_json(sources.refere_global_by_sujet))
    normalized_subjects = []
    shape_counts = {"null": 0, "array": 0, "object": 0}
    description_sources: dict[int, str] = {}
    historical_pointers: dict[int, str] = {}
    pass3e_out = destination / "pass3E_sujets"
    pass3e_out.mkdir(parents=True, exist_ok=True)
    raw_files = sorted(sources.pass3e_dir.glob("sujet_*_synthese.json"))
    raw_by_id = {
        _subject_number(read_json(path).get("numero")): (path, read_json(path))
        for path in raw_files
    }
    for numero in sorted(canonical_by_id):
        aggregate_item = aggregate.get(numero, {})
        raw_path, raw_item = raw_by_id.get(numero, (None, {}))
        raw_participants = aggregate_item.get(
            "avis_participants", raw_item.get("avis_participants")
        )
        shape = (
            "null" if raw_participants is None
            else "array" if isinstance(raw_participants, list)
            else "object" if isinstance(raw_participants, dict)
            else "unsupported"
        )
        if shape == "unsupported":
            raise TypeError(f"unsupported avis_participants for subject {numero}")
        shape_counts[shape] += 1
        raw_description = str(raw_item.get("description") or "").strip()
        canonical_description = str(canonical_by_id[numero]["Description"] or "").strip()
        description = raw_description or canonical_description
        description_sources[numero] = (
            f"pass3_refere/sujets/{raw_path.name}#/description"
            if raw_description and raw_path else "Sujets.csv#/description"
        )
        normalized = {
            **raw_item,
            "numero": numero,
            "titre": str(raw_item.get("titre") or canonical_by_id[numero]["Titre"]),
            "localisation": str(
                raw_item.get("localisation") or canonical_by_id[numero]["Localisation"]
            ),
            "description": description,
            "avis_participants": normalize_participants(raw_participants),
            "synthese_echanges": str(raw_item.get("synthese_echanges") or ""),
            "conclusion_expert": str(raw_item.get("conclusion_expert") or ""),
        }
        write_json_deterministic(
            pass3e_out / f"sujet_{numero:03d}_synthese.json", normalized
        )
        aggregate_normalized = dict(aggregate_item)
        aggregate_normalized.update({
            "numero": numero,
            "titre": normalized["titre"],
            "localisation": normalized["localisation"],
            "description": description,
            "avis_participants": normalized["avis_participants"],
            "synthese_echanges": normalized["synthese_echanges"],
            "conclusion_expert": normalized["conclusion_expert"],
        })
        historical = str(aggregate_item.get("synthese_file") or "")
        if historical:
            historical_pointers[numero] = historical
        normalized_subjects.append(aggregate_normalized)
    normalized_aggregate["sujets"] = normalized_subjects
    write_json_deterministic(destination / "global_by_sujet.json", normalized_aggregate)
    return {
        "participant_shape_counts": shape_counts,
        "description_sources": description_sources,
        "descriptions": {
            numero: (
                str(raw_by_id.get(numero, (None, {}))[1].get("description") or "").strip()
                or str(canonical_by_id[numero]["Description"] or "").strip()
            )
            for numero in canonical_by_id
        },
        "historical_pointers": historical_pointers,
    }


def _material_photos(path: Path) -> dict[str, dict[str, Any]]:
    material = read_json(path)
    return {
        str(item["photo_id"]).replace("\\", "/"): item
        for item in material.get("units") or []
        if item.get("kind") == "photo_context" and item.get("photo_id")
    }


def _photo_rows(path: Path) -> dict[str, dict[str, str]]:
    result = {}
    for row in _read_csv(path):
        key = str(row.get("photo_rel_native") or "").replace("\\", "/")
        if key:
            result[key] = row
    return result


def _photos_batch_csv(path: Path) -> Path | None:
    candidate = path.with_name("photos_batch.csv")
    if candidate.is_file() and candidate.absolute() != path.absolute():
        return candidate
    return None


def _cited_asr_evidence_ids(
    assignments: list[dict[str, Any]],
    material_photos: dict[str, dict[str, Any]],
    row_to_evidence: dict[int, list[str]],
) -> set[str]:
    cited: set[str] = set()
    problems: list[dict[str, Any]] = []
    for assignment in assignments:
        if assignment.get("status") != "affectee":
            continue
        photo_rel = str(assignment["photo_rel_native"]).replace("\\", "/")
        material = material_photos.get(photo_rel)
        if material is None:
            continue
        for raw_row in (material.get("asr_context") or {}).get("rows") or []:
            text = str(raw_row).strip()
            if not text.isdigit() or int(text) <= 0:
                problems.append({
                    "code": "invalid_asr_context_row",
                    "severity": "error",
                    "message": "Pass2B_2F material cites an invalid ASR row reference",
                    "photo_id": photo_rel,
                    "context_id": text,
                })
                continue
            row_ref = int(text)
            evidence_ids = row_to_evidence.get(row_ref) or []
            if not evidence_ids:
                problems.append({
                    "code": "unknown_asr_context_reference",
                    "severity": "error",
                    "message": "Pass2B_2F material cites an ASR row absent from Pass3F evidence",
                    "photo_id": photo_rel,
                    "row_ref": row_ref,
                })
                continue
            cited.update(evidence_ids)
    if problems:
        raise RefereAdapterConsistencyError(
            "unknown_asr_context_reference",
            "Pass2B_2F photo contexts contain ASR references that cannot be resolved",
            diagnostics=problems,
        )
    return cited


def _resolver_asr_items(
    registry: dict[str, Any],
    cited_evidence_ids: set[str],
) -> list[dict[str, Any]]:
    """Build start-time anchors without asserting an unknown ASR duration."""

    evidence_by_id = {
        item["evidence_occurrence_id"]: item for item in registry["evidence"]
    }
    missing = sorted(cited_evidence_ids - set(evidence_by_id))
    if missing:
        raise RefereAdapterConsistencyError(
            "unknown_asr_context_reference",
            "cited ASR evidence identifiers are absent from Pass3F evidence",
            diagnostics=[
                {
                    "code": "unknown_asr_context_reference",
                    "severity": "error",
                    "message": "cited ASR evidence identifier is absent",
                    "context_id": evidence_id,
                }
                for evidence_id in missing
            ],
        )

    items: list[dict[str, Any]] = []
    problems: list[dict[str, Any]] = []
    for evidence_id in sorted(cited_evidence_ids):
        evidence = evidence_by_id[evidence_id]
        raw_subjects = evidence.get("pass1_subjects") or []
        if isinstance(raw_subjects, (str, bytes)):
            raw_subjects = [raw_subjects]
        subject_numeros: list[int] = []
        invalid_subject = False
        for raw_subject in raw_subjects:
            text = str(raw_subject).strip()
            if not text.isdigit() or int(text) <= 0:
                problems.append({
                    "code": "invalid_asr_subject",
                    "severity": "error",
                    "message": "cited ASR evidence has a non-numeric subject identifier",
                    "context_id": evidence_id,
                })
                invalid_subject = True
                break
            subject_numeros.append(int(text))
        if invalid_subject or not subject_numeros:
            continue
        known_start = str(evidence.get("timecode") or "").strip()
        if not known_start:
            problems.append({
                "code": "asr_evidence_without_timecode",
                "severity": "error",
                "message": "cited ASR evidence has no temporal anchor",
                "context_id": evidence_id,
            })
            continue
        items.append({
            "evidence_id": evidence_id,
            "row_ref": evidence.get("row_ref"),
            "start_sec": known_start,
            "end_sec": known_start,
            "subject_numeros": sorted(set(subject_numeros)),
            "timecode": known_start,
        })
    if problems:
        raise RefereAdapterConsistencyError(
            "invalid_cited_asr_context",
            "cited ASR evidence cannot be represented safely",
            diagnostics=problems,
        )
    return items


def _journal_nonblocking_diagnostics(diagnostics: Iterable[dict[str, Any]]) -> None:
    summary = sorted({
        (
            str(item.get("code") or ""),
            str(item.get("severity") or ""),
            str(item.get("photo_id") or ""),
            str(item.get("row_ref") or ""),
            str(item.get("context_id") or ""),
        )
        for item in diagnostics
    })
    if not summary:
        return
    _LOGGER.warning(
        "photo context resolver non-blocking diagnostics: %s",
        json.dumps([
            {
                "code": code,
                "severity": severity,
                "photo_id": photo_id,
                "row_ref": row_ref,
                "context_id": context_id,
            }
            for code, severity, photo_id, row_ref, context_id in summary
        ], ensure_ascii=False, sort_keys=True),
    )


def _attach_photo_context(
    registry: dict[str, Any],
    sources: RefereSources,
    assignments: list[dict[str, Any]],
    material_photos: dict[str, dict[str, Any]],
    photo_evidence: dict[str, dict[str, Any]],
    row_to_evidence: dict[int, list[str]],
) -> dict[str, Any]:
    cited_evidence_ids = _cited_asr_evidence_ids(
        assignments, material_photos, row_to_evidence
    )
    asr_items = _resolver_asr_items(registry, cited_evidence_ids)
    batch_csv = _photos_batch_csv(sources.photos_csv)
    bundle = resolve_photo_context(
        SourceSelection(
            photos_csv=sources.photos_csv,
            assignments_json=sources.assignments_json,
            photos_batch_csv=batch_csv,
        ),
        asr_context=asr_items,
        asr_window_seconds=PHOTO_ASR_WINDOW_SECONDS,
    )

    diagnostics = list(bundle.get("diagnostics") or [])
    blocking = [
        item for item in diagnostics
        if item.get("severity") == "error"
        and item.get("code") != "photo_without_assignment"
    ]
    blocking.extend(
        item for item in diagnostics
        if str(item.get("code") or "").startswith("invalid_asr_")
        or item.get("code") == "conflicting_asr_context_item"
    )
    if blocking:
        raise RefereAdapterConsistencyError(
            "photo_context_resolver_consistency_error",
            "photo context resolution found blocking provenance contradictions",
            diagnostics=blocking,
        )
    blocking_objects = {id(item) for item in blocking}
    _journal_nonblocking_diagnostics(
        item for item in diagnostics if id(item) not in blocking_objects
    )

    records = {
        str(item["photo_id"]): item for item in bundle.get("photos") or []
    }
    assigned_ids = {
        photo_id for photo_id, item in records.items()
        if (item.get("assignment") or {}).get("status") == "assigned"
    }
    adapter_ids = set(photo_evidence)
    if assigned_ids != adapter_ids:
        raise RefereAdapterConsistencyError(
            "photo_assignment_scope_mismatch",
            "photo resolver and legacy adapter do not expose the same assigned photos",
            diagnostics=[
                {
                    "code": "photo_assignment_scope_mismatch",
                    "severity": "error",
                    "message": "assigned photo set differs",
                    "photo_id": photo_id,
                }
                for photo_id in sorted(assigned_ids ^ adapter_ids)
            ],
        )

    component_ids: set[str] = set()
    for photo_id, evidence in photo_evidence.items():
        record = records[photo_id]
        scope = record["subject_scope"]
        human_subject = evidence["photo"]["human_subject_numero"]
        if scope.get("photo_subject_numero") != human_subject:
            raise RefereAdapterConsistencyError(
                "photo_subject_scope_mismatch",
                "resolved photo subject differs from the human assignment",
                diagnostics=[{
                    "code": "photo_subject_scope_mismatch",
                    "severity": "error",
                    "message": "photo subject differs from human_subject_numero",
                    "photo_id": photo_id,
                }],
            )
        components = list(record.get("content_components") or [])
        if any(item.get("photo_id") != photo_id for item in components):
            raise RefereAdapterConsistencyError(
                "photo_component_scope_mismatch",
                "a resolver component is attached to a different photo",
                diagnostics=[{
                    "code": "photo_component_scope_mismatch",
                    "severity": "error",
                    "message": "component photo_id differs from the evidence photo",
                    "photo_id": photo_id,
                }],
            )
        for component_id in (item["component_id"] for item in components):
            if component_id in component_ids:
                raise RefereAdapterConsistencyError(
                    "photo_component_id_collision",
                    "resolver component identifiers are not unique",
                    diagnostics=[{
                        "code": "photo_component_id_collision",
                        "severity": "error",
                        "message": "duplicate photo component identifier",
                        "context_id": component_id,
                    }],
                )
            component_ids.add(component_id)
        evidence["photo"].update({
            "subject_scope": scope,
            "assignment": record["assignment"],
            "content_components": components,
            "asr_context": record["asr_context"],
        })

    exclusions = list(bundle.get("photo_exclusions") or [])
    excluded_ids = {str(item["photo_id"]) for item in exclusions}
    declared_excluded_ids = {
        str(item["photo_rel_native"]).replace("\\", "/")
        for item in assignments
        if item.get("status") == "exclue"
    }
    missing_exclusions = declared_excluded_ids - excluded_ids
    if missing_exclusions:
        raise RefereAdapterConsistencyError(
            "excluded_photo_missing_from_resolution",
            "a human exclusion is absent from resolved photo exclusions",
            diagnostics=[{
                "code": "excluded_photo_missing_from_resolution",
                "severity": "error",
                "message": "excluded photo was not represented in photo_exclusions",
                "photo_id": photo_id,
            } for photo_id in sorted(missing_exclusions)],
        )
    if excluded_ids & adapter_ids:
        raise RefereAdapterConsistencyError(
            "excluded_photo_published",
            "an excluded photo is also exposed as assigned evidence",
            diagnostics=[{
                "code": "excluded_photo_published",
                "severity": "error",
                "message": "excluded photo is present in assigned evidence",
                "photo_id": photo_id,
            } for photo_id in sorted(excluded_ids & adapter_ids)],
        )
    existing_exclusions = registry.get("photo_exclusions")
    if existing_exclusions and existing_exclusions != exclusions:
        raise RefereAdapterConsistencyError(
            "photo_exclusions_conflict",
            "the registry already contains different photo exclusions",
            diagnostics=[{
                "code": "photo_exclusions_conflict",
                "severity": "error",
                "message": "existing photo exclusions differ from resolved exclusions",
            }],
        )
    registry["photo_exclusions"] = exclusions
    return bundle


def _photo_text(material: dict[str, Any], row: dict[str, str]) -> str:
    values = []
    for key in (
        "libelle_effectif", "commentaire_effectif", "dictee_photo",
        "description_vlm_ui", "libelle_propose_ui", "commentaire_propose_ui",
    ):
        value = str(material.get(key) or row.get(key) or "").strip()
        if value and value not in values:
            values.append(value)
    return "\n".join(values) or str(material.get("photo_display") or material["photo_id"])


def _relative_photo_path(sources: RefereSources, photo_rel: str) -> Path:
    return sources.affaires_root / sources.id_affaire / Path(photo_rel)


def _photo_occurrence(
    sources: RefereSources,
    assignment: dict[str, Any],
    assignment_index: int,
    material: dict[str, Any],
    photo_row: dict[str, str],
    assignment_hash: str,
    row_to_evidence: dict[int, list[str]],
) -> dict[str, Any]:
    photo_rel = str(assignment["photo_rel_native"]).replace("\\", "/")
    exact_text = _photo_text(material, photo_row)
    photo_path = _relative_photo_path(sources, photo_rel)
    photo_hash = file_sha256(photo_path) if photo_path.is_file() else ""
    identity_source_hash = photo_hash or assignment_hash
    pointer = f"/assignments/{assignment_index}"
    occurrence_id = stable_id("evidence-occurrence", {
        "algorithm": PHOTO_OCCURRENCE_ALGORITHM,
        "source_hash": identity_source_hash,
        "source_pointer": pointer,
        "photo_rel_native": photo_rel,
        "timestamp_hms": str(material.get("timestamp_hms") or ""),
        "chrono_sec": material.get("chrono_sec"),
    })
    evidence_content_id = stable_id("evidence-content", {
        "algorithm": EVIDENCE_CONTENT_ALGORITHM,
        "normalized_text": normalize_text(exact_text),
    })
    context_rows = [
        int(value) for value in (material.get("asr_context") or {}).get("rows") or []
        if str(value).isdigit()
    ]
    provenance_links = [{
        "relation_type": "subject_assignment",
        "stage": "photo_assignment",
        "authority": "human",
        "subject_numero": int(assignment["subject_numero"]),
        "source_id": photo_rel,
        "source_artifact": "photo_subject_assignments.json",
        "source_field": f"{pointer}/subject_numero",
    }, {
        "relation_type": "origin",
        "stage": "photo_metadata",
        "authority": "source",
        "subject_numero": None,
        "source_id": photo_rel,
        "source_artifact": sources.photos_csv.name,
        "source_field": "photo_rel_native",
    }]
    for row_ref in context_rows:
        for evidence_id in row_to_evidence.get(row_ref, []):
            provenance_links.append({
                "relation_type": "context",
                "stage": "photo_asr_window",
                "authority": "derived",
                "subject_numero": None,
                "source_id": evidence_id,
                "source_artifact": "pass2b2f_material_rank1.json",
                "source_field": "asr_context.rows",
            })
    legacy_id = stable_id("evidence", {
        "source_hash": assignment_hash, "photo_rel_native": photo_rel
    })
    segment_id = str((material.get("segment_coverage") or {}).get("segment_id") or "")
    exact_hash = hashlib.sha256(exact_text.encode("utf-8")).hexdigest()
    return {
        "evidence_occurrence_id": occurrence_id,
        "evidence_content_id": evidence_content_id,
        "identity_algorithm": PHOTO_OCCURRENCE_ALGORITHM,
        "evidence_kind": "photo",
        "source_artifact": "photo_subject_assignments.json",
        "source_hash": identity_source_hash,
        "source_pointers": [pointer],
        "segment_id": segment_id,
        "row_ref": None,
        "timecode": str(material.get("timestamp_hms") or ""),
        "speaker": "",
        "exact_text": exact_text,
        "exact_text_sha256": exact_hash,
        "legacy_evidence_id": legacy_id,
        "legacy_evidence_id_collision": False,
        "legacy_evidence_id_occurrence_count": 1,
        "pass1_subjects": [],
        "projection_classification": "photo",
        "reported_subject_count": None,
        "provenance_links": provenance_links,
        "photo": {
            "photo_rel_native": photo_rel,
            "photo_display": str(material.get("photo_display") or Path(photo_rel).name),
            "timestamp_hms": str(material.get("timestamp_hms") or ""),
            "chrono_sec": material.get("chrono_sec"),
            "photo_sha256": photo_hash,
            "metadata_sources": sorted(set(
                str(value) for value in (material.get("provenance") or {}).get("source_files") or []
            ) | {sources.photos_csv.name, "photo_subject_assignments.json"}),
            "human_subject_numero": int(assignment["subject_numero"]),
            "pass2f_source_artifacts": [],
            "context_asr_evidence_ids": sorted({
                evidence_id for row_ref in context_rows
                for evidence_id in row_to_evidence.get(row_ref, [])
            }),
        },
    }


def _photo_from_context(obj: dict[str, Any], index: int) -> str:
    contexts = obj.get("photo_contexts") or []
    if index >= len(contexts) or not isinstance(contexts[index], dict):
        return ""
    context = contexts[index]
    return str(
        context.get("photo_id") or context.get("photo")
        or context.get("photo_display") or ""
    ).replace("\\", "/")


def _add_photo_fragment_links(
    registry: dict[str, Any],
    sources: RefereSources,
    photo_evidence: dict[str, dict[str, Any]],
) -> None:
    aliases: dict[str, str] = {}
    for photo_rel, item in photo_evidence.items():
        aliases[normalize_text(photo_rel)] = photo_rel
        aliases[normalize_text(Path(photo_rel).name)] = photo_rel
        aliases[normalize_text(item["photo"]["photo_display"])] = photo_rel
    pass2f_cache: dict[str, dict[str, Any]] = {}
    for fragment in registry["derived_fragments"]:
        photo_rel = ""
        status = "candidate"
        method = "explicit_photo_identifier"
        if fragment["stage"] == "2F":
            relative = fragment["source_artifact"].removeprefix("pass2f/")
            obj = pass2f_cache.setdefault(relative, read_json(sources.pass2f_dir / relative))
            match = _PHOTO_CONTEXT_RE.match(fragment["field_path"])
            if match:
                photo_rel = _photo_from_context(obj, int(match.group(1)))
                status = "verified"
                method = "structured_photo_reference"
        if not photo_rel:
            normalized = normalize_text(fragment["text"])
            photo_rel = next((
                value for alias, value in sorted(aliases.items(), key=lambda item: -len(item[0]))
                if alias and alias in normalized
            ), "")
        if photo_rel and photo_rel not in photo_evidence:
            basename = normalize_text(Path(photo_rel).name)
            photo_rel = aliases.get(basename, "")
        if not photo_rel:
            continue
        evidence = photo_evidence[photo_rel]
        link = {
            "evidence_occurrence_id": evidence["evidence_occurrence_id"],
            "link_status": status,
            "method": method,
            "score": 1.0,
        }
        existing = [
            item for item in fragment["links"]
            if item["evidence_occurrence_id"] is not None
        ]
        existing.append(link)
        fragment["links"] = sorted(
            {canonical_bytes(item): item for item in existing}.values(),
            key=lambda item: (item["link_status"], item["evidence_occurrence_id"] or ""),
        )
        if fragment["stage"] == "2F":
            evidence["photo"]["pass2f_source_artifacts"].append(fragment["source_artifact"])
    for item in photo_evidence.values():
        item["photo"]["pass2f_source_artifacts"] = sorted(
            set(item["photo"]["pass2f_source_artifacts"])
        )


def _actual_input_hashes(sources: RefereSources) -> dict[str, str]:
    files = {
        "refere/manifest.json": sources.run_dir / "manifest.json",
        "refere/Sujets.csv": sources.sujets_csv,
        "refere/photo_subject_assignments.json": sources.assignments_json,
        f"refere/{sources.photos_csv.name}": sources.photos_csv,
        "refere/pass2b2f_material_rank1.json": sources.material_rank1,
        "refere/refere_global_by_sujet.json": sources.refere_global_by_sujet,
        "refere/generalist_global.json": sources.generalist_run / "global.json",
    }
    batch_csv = _photos_batch_csv(sources.photos_csv)
    if batch_csv is not None:
        files[f"refere/{batch_csv.name}"] = batch_csv
    for path in sorted(sources.pass3e_dir.glob("*.json")):
        files[f"refere/pass3_refere/sujets/{path.name}"] = path
    for path in sorted(sources.pass2f_dir.rglob("*.json")):
        files[f"refere/pass2f/{path.relative_to(sources.pass2f_dir).as_posix()}"] = path
    for path in sorted((sources.generalist_run / "segments").glob("*.json")):
        files[f"refere/segments/{path.name}"] = path
    return {name: file_sha256(path) for name, path in sorted(files.items())}


def build_refere_registry(sources: RefereSources) -> dict[str, Any]:
    for path in (
        sources.sujets_csv, sources.assignments_json, sources.photos_csv,
        sources.refere_global_by_sujet, sources.material_rank1,
    ):
        if not path.is_file():
            raise FileNotFoundError(path)
    with tempfile.TemporaryDirectory(prefix="pass3f-refere-") as temp:
        common_run = Path(temp)
        normalization = _prepare_common_run(sources, common_run)
        registry = build_registry(
            common_run, pipeline_kind="refere", pass2f_dir=sources.pass2f_dir
        )

    subjects = {item["numero"]: item for item in registry["subjects"]}
    for numero, subject in subjects.items():
        subject["description"] = normalization["descriptions"][numero]
        subject["description_source"] = normalization["description_sources"][numero]
        subject["historical_synthese_file"] = normalization["historical_pointers"].get(
            numero, ""
        )
        subject["identities"] = extract_subject_identities({
            "Titre": subject["title"],
            "Localisation": subject["location"],
            "Description": subject["description"],
        }, str(numero))

    assignments_doc = read_json(sources.assignments_json)
    assignments = assignments_doc.get("assignments") or []
    material_photos = _material_photos(sources.material_rank1)
    photo_rows = _photo_rows(sources.photos_csv)
    assignment_hash = file_sha256(sources.assignments_json)
    row_to_evidence: dict[int, list[str]] = {}
    for item in registry["evidence"]:
        if isinstance(item.get("row_ref"), int):
            row_to_evidence.setdefault(item["row_ref"], []).append(
                item["evidence_occurrence_id"]
            )
        item.setdefault("evidence_kind", "asr")
        item.setdefault("provenance_links", [{
            "relation_type": "origin",
            "stage": "pass1",
            "authority": "source",
            "subject_numero": None,
            "source_id": item["evidence_occurrence_id"],
            "source_artifact": item["source_artifact"],
            "source_field": ",".join(item["source_pointers"]),
        }])

    photo_evidence: dict[str, dict[str, Any]] = {}
    excluded = 0
    for index, assignment in enumerate(assignments):
        if assignment.get("status") != "affectee":
            excluded += 1
            continue
        photo_rel = str(assignment["photo_rel_native"]).replace("\\", "/")
        material = material_photos.get(photo_rel)
        if material is None:
            raise ValueError(f"affected photo missing from Pass2B2F material: {photo_rel}")
        photo_evidence[photo_rel] = _photo_occurrence(
            sources, assignment, index, material, photo_rows.get(photo_rel, {}),
            assignment_hash, row_to_evidence,
        )
    occurrence_ids = {
        item["evidence_occurrence_id"] for item in registry["evidence"]
    }
    for item in photo_evidence.values():
        if item["evidence_occurrence_id"] in occurrence_ids:
            raise ValueError("photo evidence occurrence identity collision")
        occurrence_ids.add(item["evidence_occurrence_id"])
        registry["evidence"].append(item)
    _attach_photo_context(
        registry, sources, assignments, material_photos, photo_evidence,
        row_to_evidence,
    )
    _add_photo_fragment_links(registry, sources, photo_evidence)
    registry["evidence"].sort(key=lambda item: item["evidence_occurrence_id"])
    actual_hashes = _actual_input_hashes(sources)
    registry["run"]["input_hashes"].update(actual_hashes)
    registry["run"]["run_id"] = stable_id("run", {
        "pipeline_kind": "refere", "inputs": registry["run"]["input_hashes"]
    })
    registry["run"]["adapter"] = ADAPTER_VERSION
    photo_components = [
        component
        for item in registry["evidence"]
        if item.get("evidence_kind") == "photo"
        for component in (item.get("photo") or {}).get("content_components") or []
    ]
    registry["stats"].update({
        "photo_evidence_count": len(photo_evidence),
        "human_subject_assignment_count": len(photo_evidence),
        "excluded_photo_count": excluded,
        "participant_source_null_count": normalization["participant_shape_counts"]["null"],
        "participant_source_array_count": normalization["participant_shape_counts"]["array"],
        "participant_source_object_count": normalization["participant_shape_counts"]["object"],
        "description_recovered_count": sum(
            value.startswith("pass3_refere/")
            for value in normalization["description_sources"].values()
        ),
        "photo_component_count": len(photo_components),
        "photo_component_validated_count": sum(
            item.get("validation_status") == "validated"
            for item in photo_components
        ),
        "photo_component_unvalidated_count": sum(
            item.get("validation_status") == "unvalidated"
            for item in photo_components
        ),
        "photo_component_unknown_count": sum(
            item.get("validation_status") == "unknown"
            for item in photo_components
        ),
        "photo_asr_context_count": sum(
            (item.get("photo") or {}).get("asr_context", {}).get("link_status")
            in {"verified", "candidate"}
            for item in registry["evidence"]
            if item.get("evidence_kind") == "photo"
        ),
        "photo_exclusion_record_count": len(registry.get("photo_exclusions") or []),
        "context_snapshot_count": len(registry.get("context_snapshots") or []),
    })
    recompute_registry_stats(registry)
    return registry


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-dir", required=True, type=Path)
    parser.add_argument("--affaires-root", type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args(argv)
    sources = discover_sources(args.run_dir, affaires_root=args.affaires_root)
    write_json_deterministic(args.out, build_refere_registry(sources))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
