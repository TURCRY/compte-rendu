#!/usr/bin/env python3
"""Build a deterministic sidecar for accepted Pass3F transverse requests."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
from typing import Any

from pass3f_provenance import (
    canonical_bytes,
    normalize_text,
    read_json,
    stable_id,
    write_json_deterministic,
)


SCHEMA_VERSION = "pass3f.transverse.v1"
APPLIED_SCHEMA_VERSION = "pass3f.applied.v2"
DECISIONS_SCHEMA_VERSION = "pass3f.decisions.v1"
PROVENANCE_SCHEMA_VERSION = "pass3f.provenance.v2"
TRANSVERSE_DESTINATION = "transverse_document_request"
_REQUEST_PREFIXES = (
    ("fournir", "des"),
    ("fournir", "de"),
    ("fournir", "les"),
    ("fournir",),
    ("recueillir", "des"),
    ("recueillir", "les"),
    ("recueillir",),
    ("obtenir", "des"),
    ("obtenir", "les"),
    ("obtenir",),
    ("demander", "des"),
    ("demander", "les"),
    ("demander",),
)


class StaleTransverseInputError(ValueError):
    """Raised when a sidecar input no longer matches the accepted lineage."""


def document_hash(value: Any) -> str:
    return hashlib.sha256(canonical_bytes(value)).hexdigest()


def normalize_request_object(value: Any) -> str:
    """Normalize an object without fuzzy matching or auxiliary metadata."""
    tokens = normalize_text(value).split()
    for prefix in _REQUEST_PREFIXES:
        if tuple(tokens[:len(prefix)]) == prefix:
            tokens = tokens[len(prefix):]
            break
    return " ".join(tokens)


def _json_pointer(document: Any, pointer: str) -> Any:
    if pointer == "":
        return document
    if not pointer.startswith("/"):
        raise ValueError(f"invalid JSON pointer: {pointer}")
    current = document
    for raw_part in pointer[1:].split("/"):
        part = raw_part.replace("~1", "/").replace("~0", "~")
        if isinstance(current, list):
            try:
                current = current[int(part)]
            except (ValueError, IndexError) as exc:
                raise ValueError(f"unresolvable JSON pointer: {pointer}") from exc
        elif isinstance(current, dict) and part in current:
            current = current[part]
        else:
            raise ValueError(f"unresolvable JSON pointer: {pointer}")
    return current


def _historical_origins(
    evidence_ids: list[str],
    evidence_by_id: dict[str, dict[str, Any]],
    global_source: dict[str, Any],
) -> list[str]:
    origins: set[str] = set()
    for evidence_id in evidence_ids:
        evidence = evidence_by_id.get(evidence_id)
        if evidence is None:
            raise ValueError(f"unknown evidence occurrence: {evidence_id}")
        for pointer in evidence.get("source_pointers") or []:
            source = _json_pointer(global_source, str(pointer))
            if isinstance(source, dict) and str(source.get("origine") or "").strip():
                origins.add(str(source["origine"]).strip())
    return sorted(origins)


def _existing_match(text: str, global_final: dict[str, Any]) -> dict[str, Any]:
    requests = global_final.get("demandes_documents_globales") or []
    if not isinstance(requests, list):
        raise ValueError("global_final.demandes_documents_globales must be an array")
    normalized = normalize_request_object(text)
    matches = [
        (index, item)
        for index, item in enumerate(requests)
        if isinstance(item, dict)
        and normalize_request_object(item.get("objet")) == normalized
    ]
    indexes = [index for index, _item in matches]
    if len(matches) == 1:
        entry = matches[0][1]
        return {
            "found": True,
            "status": "unique",
            "normalized_object": normalized,
            "match_indexes": indexes,
            "matched_entry_hash": document_hash(entry),
            "matched_entry": entry,
        }
    return {
        "found": bool(matches),
        "status": "ambiguous_existing_match" if matches else "absent",
        "normalized_object": normalized,
        "match_indexes": indexes,
        "matched_entry_hash": None,
        "matched_entry": None,
    }


def _validate_lineage(
    applied: dict[str, Any],
    decisions: dict[str, Any],
    registry: dict[str, Any],
) -> str:
    if applied.get("schema") != APPLIED_SCHEMA_VERSION:
        raise ValueError("unsupported applied schema")
    if decisions.get("schema") != DECISIONS_SCHEMA_VERSION:
        raise ValueError("unsupported decisions schema")
    if registry.get("schema") != PROVENANCE_SCHEMA_VERSION:
        raise ValueError("unsupported provenance schema")
    run_id = str(applied.get("run_id") or "")
    if not run_id or decisions.get("run_id") != run_id:
        raise StaleTransverseInputError("decision run_id does not match applied result")
    if (registry.get("run") or {}).get("run_id") != run_id:
        raise StaleTransverseInputError("provenance run_id does not match applied result")
    source_hashes = applied.get("source_hashes") or {}
    if source_hashes.get("decisions") != document_hash(decisions):
        raise StaleTransverseInputError("decisions hash is stale")
    if source_hashes.get("provenance_registry") != document_hash(registry):
        raise StaleTransverseInputError("provenance registry hash is stale")
    return run_id


def build_transverse_artifact(
    global_final: dict[str, Any],
    global_source: dict[str, Any],
    registry: dict[str, Any],
    applied: dict[str, Any],
    decisions: dict[str, Any],
) -> dict[str, Any]:
    """Collect accepted transverse units without modifying the final document."""
    run_id = _validate_lineage(applied, decisions, registry)
    decision_by_id = {
        str(item["decision_id"]): item for item in decisions.get("decisions") or []
    }
    evidence_by_id = {
        str(item["evidence_occurrence_id"]): item
        for item in registry.get("evidence") or []
    }
    units: list[dict[str, Any]] = []
    seen_unit_ids: set[str] = set()

    for operation in applied.get("operations") or []:
        decision_id = str(operation.get("decision_id") or "")
        decision = decision_by_id.get(decision_id)
        if decision is None:
            raise StaleTransverseInputError(f"missing decision {decision_id}")
        if decision.get("proposal_id") != operation.get("proposal_id"):
            raise StaleTransverseInputError(f"proposal mismatch for {decision_id}")
        for split_plan in operation.get("composite_split_plans") or []:
            for unit in split_plan.get("units") or []:
                if unit.get("destination") != TRANSVERSE_DESTINATION:
                    continue
                if decision.get("decision") != "accepted":
                    raise StaleTransverseInputError(
                        f"transverse unit without accepted decision: {unit.get('unit_id')}"
                    )
                unit_id = str(unit["unit_id"])
                if unit_id in seen_unit_ids:
                    raise ValueError(f"duplicate transverse unit: {unit_id}")
                seen_unit_ids.add(unit_id)
                evidence_ids = sorted(set(map(str, unit.get("evidence_refs") or [])))
                match = _existing_match(str(unit["text"]), global_final)
                if match["status"] == "unique":
                    materialization_status = "reuse_existing"
                    prepared_entry = None
                elif match["status"] == "absent":
                    materialization_status = "prepare_new"
                    prepared_entry = {
                        "objet": str(unit["text"]),
                        "demandeur": None,
                        "destinataire": None,
                        "echeance": None,
                        "commentaire": None,
                        "origine": "pass3f",
                    }
                else:
                    materialization_status = "blocked_ambiguous"
                    prepared_entry = None
                units.append({
                    "unit_id": unit_id,
                    "text": str(unit["text"]),
                    "derived_from_fragment_id": str(unit["derived_from_fragment_id"]),
                    "evidence_occurrence_ids": evidence_ids,
                    "historical_subject": str(operation["source_subject"]),
                    "historical_origins": _historical_origins(
                        evidence_ids, evidence_by_id, global_source
                    ),
                    "decision": {
                        "decision_id": decision_id,
                        "proposal_id": str(decision["proposal_id"]),
                        "status": "accepted",
                        "reviewer": str(decision["reviewer"]),
                        "reason": str(decision["reason"]),
                    },
                    "existing_match": match,
                    "materialization_status": materialization_status,
                    "automatic_materialization_allowed": (
                        materialization_status != "blocked_ambiguous"
                    ),
                    "prepared_entry": prepared_entry,
                })

    units.sort(key=lambda item: item["unit_id"])
    source_hashes = {
        "global_final": document_hash(global_final),
        "global_source": document_hash(global_source),
        "provenance_registry": document_hash(registry),
        "pass3f_applied": document_hash(applied),
        "decisions": document_hash(decisions),
    }
    core = {
        "run_id": run_id,
        "source_hashes": source_hashes,
        "units": units,
    }
    return {
        "schema": SCHEMA_VERSION,
        "transverse_id": stable_id("transverse", core),
        **core,
        "stats": {
            "unit_count": len(units),
            "existing_unique_count": sum(
                item["materialization_status"] == "reuse_existing" for item in units
            ),
            "new_entry_count": sum(
                item["materialization_status"] == "prepare_new" for item in units
            ),
            "ambiguous_count": sum(
                item["materialization_status"] == "blocked_ambiguous" for item in units
            ),
        },
        "rollback": {
            "method": "discard_sidecar_and_rebuild",
            "source_global_final_hash": source_hashes["global_final"],
        },
    }


def write_transverse_artifact(output_dir: Path, artifact: dict[str, Any]) -> Path:
    path = Path(output_dir) / "pass3f" / "transverse_units.json"
    write_json_deterministic(path, artifact)
    return path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--global-final", type=Path, required=True)
    parser.add_argument("--global-source", type=Path, required=True)
    parser.add_argument("--registry", type=Path, required=True)
    parser.add_argument("--applied", type=Path, required=True)
    parser.add_argument("--decisions", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    artifact = build_transverse_artifact(
        read_json(args.global_final),
        read_json(args.global_source),
        read_json(args.registry),
        read_json(args.applied),
        read_json(args.decisions),
    )
    write_transverse_artifact(args.output_dir, artifact)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
