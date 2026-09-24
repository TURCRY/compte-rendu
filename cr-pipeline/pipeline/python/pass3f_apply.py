#!/usr/bin/env python3
"""Apply accepted Pass3F-A proposals without rewriting source text."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
from collections import defaultdict
from pathlib import Path
from typing import Any

from pass3f_provenance import (
    canonical_bytes,
    read_json,
    stable_id,
    write_json_deterministic,
)


DECISIONS_SCHEMA_VERSION = "pass3f.decisions.v1"
APPLIED_SCHEMA_VERSION = "pass3f.applied.v1"
PLAN_SCHEMA_VERSION = "pass3f.application_plan.v1"
MANIFEST_SCHEMA_VERSION = "pass3f.correction_manifest.v1"
HASHES_SCHEMA_VERSION = "pass3f.hashes.v1"
AUTONOMOUS_FIELDS = ("synthese_echanges", "conclusion_expert")
DECISION_VALUES = {"accepted", "rejected", "deferred"}
CHANGE_ACTIONS = {"move", "merge", "remove_duplicate"}


class StaleDecisionError(ValueError):
    """Raised before output generation when a reviewed input changed."""


def document_hash(value: Any) -> str:
    return hashlib.sha256(canonical_bytes(value)).hexdigest()


def file_hash(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def decision_identifier(decision: dict[str, Any]) -> str:
    return stable_id("decision", {
        key: value for key, value in decision.items() if key != "decision_id"
    })


def _subject_id(subject: dict[str, Any]) -> str:
    return str(int(subject["numero"]))


def _subjects(document: dict[str, Any]) -> dict[str, dict[str, Any]]:
    values = document.get("sujets")
    if not isinstance(values, list):
        raise ValueError("global_by_sujet.sujets must be an array")
    result: dict[str, dict[str, Any]] = {}
    for subject in values:
        if not isinstance(subject, dict) or "numero" not in subject:
            raise ValueError("invalid subject in global_by_sujet")
        subject_id = _subject_id(subject)
        if subject_id in result:
            raise ValueError(f"duplicate subject {subject_id}")
        result[subject_id] = subject
    return result


def _paragraphs(subject: dict[str, Any], field: str) -> list[str]:
    value = subject.get(field, "")
    if value in (None, ""):
        return []
    if not isinstance(value, str):
        raise ValueError(f"subject field {field} must be a string")
    return value.split("\n\n")


def _set_paragraphs(subject: dict[str, Any], field: str, paragraphs: list[str]) -> None:
    subject[field] = "\n\n".join(paragraphs)


def _occurrences(subject: dict[str, Any], text: str) -> list[dict[str, Any]]:
    return [
        {"field": field, "index": index}
        for field in AUTONOMOUS_FIELDS
        for index, paragraph in enumerate(_paragraphs(subject, field))
        if paragraph == text
    ]


def _fragment_evidence(fragment: dict[str, Any]) -> list[str]:
    return sorted({
        str(link["evidence_id"])
        for link in fragment.get("links") or []
        if link.get("evidence_id")
    })


def _validate_decisions(
    decisions: dict[str, Any],
    audit: dict[str, Any],
    global_by_subject: dict[str, Any],
) -> None:
    required = {
        "schema", "run_id", "source_audit_hash", "source_global_hash",
        "source_registry_hash", "decisions",
    }
    if not isinstance(decisions, dict) or set(decisions) != required:
        raise ValueError("decisions document fields do not match the strict contract")
    if decisions["schema"] != DECISIONS_SCHEMA_VERSION:
        raise ValueError("unsupported decisions schema")
    if decisions["run_id"] != audit.get("run_id"):
        raise StaleDecisionError("decision run_id does not match audit")
    if decisions["source_audit_hash"] != document_hash(audit):
        raise StaleDecisionError("source audit hash is stale")
    if decisions["source_global_hash"] != document_hash(global_by_subject):
        raise StaleDecisionError("source global_by_sujet hash is stale")
    if decisions["source_registry_hash"] != audit.get("source_registry_hash"):
        raise StaleDecisionError("source registry hash is stale")

    proposals = {item["proposal_id"]: item for item in audit.get("proposals") or []}
    seen: set[str] = set()
    for decision in decisions["decisions"]:
        expected_fields = {
            "decision_id", "proposal_id", "proposal_hash", "decision",
            "accepted_fragment_ids", "reviewer", "reason",
        }
        if not isinstance(decision, dict) or set(decision) != expected_fields:
            raise ValueError("decision fields do not match the strict contract")
        proposal_id = decision["proposal_id"]
        if proposal_id in seen:
            raise ValueError(f"duplicate decision for {proposal_id}")
        seen.add(proposal_id)
        proposal = proposals.get(proposal_id)
        if proposal is None:
            raise ValueError(f"unknown proposal {proposal_id}")
        fragment_sets = [
            set(proposal[key])
            for key in (
                "source_fragment_ids", "composite_fragment_ids", "unresolved_fragment_ids"
            )
        ]
        if any(
            left & right
            for index, left in enumerate(fragment_sets)
            for right in fragment_sets[index + 1:]
        ):
            raise ValueError(f"proposal fragment scopes overlap for {proposal_id}")
        if decision["proposal_hash"] != document_hash(proposal):
            raise StaleDecisionError(f"proposal hash is stale for {proposal_id}")
        if decision["decision"] not in DECISION_VALUES:
            raise ValueError(f"unsupported decision for {proposal_id}")
        accepted = decision["accepted_fragment_ids"]
        if not isinstance(accepted, list) or len(accepted) != len(set(accepted)):
            raise ValueError(f"accepted_fragment_ids must be unique for {proposal_id}")
        if not set(accepted).issubset(proposal["source_fragment_ids"]):
            raise ValueError(f"decision accepts a non-applicable fragment for {proposal_id}")
        if decision["decision"] != "accepted" and accepted:
            raise ValueError(f"non-accepted decision has accepted fragments for {proposal_id}")
        if decision["decision_id"] != decision_identifier(decision):
            raise ValueError(f"invalid decision_id for {proposal_id}")
        if not str(decision["reviewer"]).strip() or not str(decision["reason"]).strip():
            raise ValueError(f"reviewer and reason are required for {proposal_id}")


def _proposal_status(
    decision_value: str,
    *,
    applied: int,
    pending_composite: int,
    pending_simple: int,
    blocked: int,
) -> str:
    if decision_value == "rejected":
        return "rejected"
    if decision_value == "deferred":
        return "deferred"
    if blocked and not applied:
        return "blocked"
    if pending_composite or pending_simple or blocked:
        return "partially_applied" if applied else "blocked"
    return "applied" if applied else "no_change"


def _move_fragment(
    document_subjects: dict[str, dict[str, Any]],
    fragment: dict[str, Any],
    source_subject: str,
    target_subject: str,
    action: str,
) -> tuple[dict[str, Any], dict[str, Any] | None]:
    source = document_subjects[source_subject]
    target = document_subjects[target_subject]
    text = fragment["text"]
    source_hits = _occurrences(source, text)
    target_hits = _occurrences(target, text)
    base = {
        "fragment_id": fragment["fragment_id"],
        "source_subject": source_subject,
        "target_subject": target_subject,
        "text": text,
        "evidence_refs": _fragment_evidence(fragment),
    }
    if len(source_hits) > 1 or len(target_hits) > 1:
        return {**base, "status": "blocked", "blocker": "non_unique_structural_match"}, None
    if not source_hits and target_hits:
        return {**base, "status": "already_applied", "blocker": None}, None
    if not source_hits:
        return {**base, "status": "blocked", "blocker": "source_fragment_not_autonomous"}, None
    if action == "remove_duplicate" and not target_hits:
        return {**base, "status": "blocked", "blocker": "target_duplicate_not_found"}, None

    source_locator = source_hits[0]
    source_values = _paragraphs(source, source_locator["field"])
    removed = source_values.pop(source_locator["index"])
    _set_paragraphs(source, source_locator["field"], source_values)
    target_locator = None
    if action == "move" and not target_hits:
        target_values = _paragraphs(target, source_locator["field"])
        target_locator = {"field": source_locator["field"], "index": len(target_values)}
        target_values.append(removed)
        _set_paragraphs(target, source_locator["field"], target_values)
    elif action == "move":
        target_locator = target_hits[0]

    change = {
        **base,
        "provenance": {
            key: copy.deepcopy(fragment.get(key))
            for key in ("stage", "field_path", "source_artifact", "links", "truncation")
        },
        "source_locator": source_locator,
        "target_locator": target_locator,
        "before": {"source_text": removed, "target_present": bool(target_hits)},
        "after": {"source_present": False, "target_present": action == "move" or bool(target_hits)},
    }
    return {**base, "status": "applied", "blocker": None}, change


def build_application(
    global_by_subject: dict[str, Any],
    registry: dict[str, Any],
    audit: dict[str, Any],
    decisions: dict[str, Any],
) -> dict[str, Any]:
    _validate_decisions(decisions, audit, global_by_subject)
    if audit.get("source_registry_hash") != stable_id("registry", registry):
        raise StaleDecisionError("audit registry hash does not match registry")
    if registry.get("run", {}).get("run_id") != audit.get("run_id"):
        raise StaleDecisionError("registry run_id does not match audit")

    source_hashes = {
        "global_by_sujet": document_hash(global_by_subject),
        "provenance_registry": document_hash(registry),
        "audit_proposals": document_hash(audit),
        "decisions": document_hash(decisions),
    }
    application_id = stable_id("application", source_hashes)
    output = copy.deepcopy(global_by_subject)
    output_subjects = _subjects(output)
    original_subjects = _subjects(global_by_subject)
    fragments = {item["fragment_id"]: item for item in registry["derived_fragments"]}
    proposals = {item["proposal_id"]: item for item in audit["proposals"]}
    decision_values = sorted(decisions["decisions"], key=lambda item: item["proposal_id"])
    operations = []
    changes = []
    affected_subjects: set[str] = set()

    for decision in decision_values:
        proposal = proposals[decision["proposal_id"]]
        source_subject = str(proposal["source_subject"])
        target_subject = str(proposal["target_subject"]) if proposal["target_subject"] is not None else None
        operation = {
            "proposal_id": proposal["proposal_id"],
            "decision_id": decision["decision_id"],
            "action": proposal["action"],
            "source_subject": source_subject,
            "target_subject": target_subject,
            "status": decision["decision"],
            "applied_fragment_ids": [],
            "already_applied_fragment_ids": [],
            "pending_simple_fragment_ids": [],
            "pending_composite_fragment_ids": list(proposal["composite_fragment_ids"]),
            "blocked_unresolved_fragment_ids": list(proposal["unresolved_fragment_ids"]),
            "blocked_fragments": [],
        }
        if decision["decision"] != "accepted":
            operation["status"] = decision["decision"]
            operations.append(operation)
            continue
        if proposal["unresolved_fragment_ids"]:
            operation["status"] = "blocked"
            operation["pending_simple_fragment_ids"] = list(decision["accepted_fragment_ids"])
            operations.append(operation)
            continue
        if proposal["action"] in {"retain_overlap", "no_action"}:
            operation["status"] = "no_change"
            operations.append(operation)
            continue
        if proposal["action"] == "merge":
            operation["status"] = "blocked"
            operation["pending_simple_fragment_ids"] = list(decision["accepted_fragment_ids"])
            operation["blocked_fragments"].append({
                "fragment_id": None,
                "blocker": "merge_requires_rewrite",
            })
            operations.append(operation)
            continue
        if proposal["action"] not in {"move", "remove_duplicate"} or target_subject is None:
            raise ValueError(f"unsupported deterministic action for {proposal['proposal_id']}")
        if source_subject not in output_subjects or target_subject not in output_subjects:
            raise ValueError(f"unknown source or target subject for {proposal['proposal_id']}")

        accepted = set(decision["accepted_fragment_ids"])
        operation["pending_simple_fragment_ids"] = sorted(
            set(proposal["source_fragment_ids"]) - accepted
        )
        ordered_fragments = []
        for fragment_id in sorted(accepted):
            fragment = fragments.get(fragment_id)
            if fragment is None or str(fragment.get("subject_id")) != source_subject:
                operation["blocked_fragments"].append({
                    "fragment_id": fragment_id,
                    "blocker": "fragment_missing_or_wrong_source",
                })
                continue
            hits = _occurrences(output_subjects[source_subject], fragment["text"])
            order_key = (
                AUTONOMOUS_FIELDS.index(hits[0]["field"]) if len(hits) == 1 else len(AUTONOMOUS_FIELDS),
                hits[0]["index"] if len(hits) == 1 else 10**9,
                fragment_id,
            )
            ordered_fragments.append((order_key, fragment))
        for _order, fragment in sorted(ordered_fragments, key=lambda item: item[0]):
            result, change = _move_fragment(
                output_subjects, fragment, source_subject, target_subject, proposal["action"]
            )
            if result["status"] == "applied":
                operation["applied_fragment_ids"].append(fragment["fragment_id"])
                affected_subjects.update((source_subject, target_subject))
                if change:
                    changes.append({
                        "change_id": stable_id("change", {
                            "application_id": application_id,
                            "proposal_id": proposal["proposal_id"],
                            "fragment_id": fragment["fragment_id"],
                        }),
                        "proposal_id": proposal["proposal_id"],
                        **change,
                    })
            elif result["status"] == "already_applied":
                operation["already_applied_fragment_ids"].append(fragment["fragment_id"])
            else:
                operation["blocked_fragments"].append({
                    "fragment_id": fragment["fragment_id"],
                    "blocker": result["blocker"],
                })
        operation["status"] = _proposal_status(
            decision["decision"],
            applied=len(operation["applied_fragment_ids"]),
            pending_composite=len(operation["pending_composite_fragment_ids"]),
            pending_simple=len(operation["pending_simple_fragment_ids"]),
            blocked=len(operation["blocked_fragments"]),
        )
        operations.append(operation)

    invariant_subjects = sorted(set(original_subjects) - affected_subjects, key=int)
    for subject_id in invariant_subjects:
        if canonical_bytes(original_subjects[subject_id]) != canonical_bytes(output_subjects[subject_id]):
            raise AssertionError(f"unaffected subject changed: {subject_id}")

    applied_ids = {
        fragment_id
        for operation in operations
        for fragment_id in operation["applied_fragment_ids"]
    }
    composite_ids = {
        fragment_id
        for proposal in proposals.values()
        for fragment_id in proposal["composite_fragment_ids"]
    }
    unresolved_ids = {
        fragment_id
        for proposal in proposals.values()
        for fragment_id in proposal["unresolved_fragment_ids"]
    }
    moved_text_is_unique = all(
        not _occurrences(output_subjects[change["source_subject"]], change["text"])
        and len(_occurrences(output_subjects[change["target_subject"]], change["text"])) == 1
        for change in changes
        if proposals[change["proposal_id"]]["action"] == "move"
    )
    composites_unchanged = all(
        len(_occurrences(original_subjects[str(fragments[fragment_id]["subject_id"])], fragments[fragment_id]["text"]))
        == len(_occurrences(output_subjects[str(fragments[fragment_id]["subject_id"])], fragments[fragment_id]["text"]))
        for fragment_id in composite_ids
        if fragment_id in fragments
    )
    evidence_refs_preserved = all(
        change["evidence_refs"] == _fragment_evidence(fragments[change["fragment_id"]])
        for change in changes
    )
    controls = {
        "applied_text_is_unique": moved_text_is_unique,
        "composite_fragments_unchanged": composites_unchanged,
        "unresolved_fragments_not_applied": not bool(applied_ids & unresolved_ids),
        "evidence_refs_preserved": evidence_refs_preserved,
        "unaffected_subjects_identical": True,
    }
    if not all(controls.values()):
        failed = sorted(key for key, value in controls.items() if not value)
        raise AssertionError(f"post-application controls failed: {', '.join(failed)}")

    statuses = {item["status"] for item in operations}
    if "blocked" in statuses and not changes:
        overall_status = "blocked"
    elif statuses & {"partially_applied", "blocked"}:
        overall_status = "partially_applied"
    elif changes:
        overall_status = "applied"
    else:
        overall_status = "no_change"

    plan = {
        "schema": PLAN_SCHEMA_VERSION,
        "application_id": application_id,
        "run_id": audit["run_id"],
        "source_hashes": source_hashes,
        "status": overall_status,
        "operations": operations,
    }
    manifest = {
        "schema": MANIFEST_SCHEMA_VERSION,
        "application_id": application_id,
        "run_id": audit["run_id"],
        "source_hashes": source_hashes,
        "output_global_hash": document_hash(output),
        "rollback": {
            "method": "rebuild_from_immutable_source",
            "source_global_hash": source_hashes["global_by_sujet"],
        },
        "changes": changes,
        "unaffected_subject_ids": invariant_subjects,
        "controls": controls,
    }
    applied = {
        "schema": APPLIED_SCHEMA_VERSION,
        "application_id": application_id,
        "run_id": audit["run_id"],
        "status": overall_status,
        "source_hashes": source_hashes,
        "output_global_hash": document_hash(output),
        "operations": operations,
        "controls": controls,
    }
    return {
        "plan": plan,
        "applied": applied,
        "global_by_sujet_3f": output,
        "manifest": manifest,
    }


def write_application(output_dir: Path, result: dict[str, Any]) -> dict[str, Any]:
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    paths = {
        "pass3f_application_plan.json": result["plan"],
        "pass3f_applied.json": result["applied"],
        "global_by_sujet_3f.json": result["global_by_sujet_3f"],
        "correction_manifest.json": result["manifest"],
    }
    for name, value in paths.items():
        write_json_deterministic(output_dir / name, value)
    hashes = {
        "schema": HASHES_SCHEMA_VERSION,
        "application_id": result["applied"]["application_id"],
        "source_hashes": result["applied"]["source_hashes"],
        "files": {
            name: file_hash(output_dir / name)
            for name in sorted(paths)
        },
    }
    write_json_deterministic(output_dir / "hashes.json", hashes)
    return hashes


def apply_from_files(
    global_path: Path,
    registry_path: Path,
    audit_path: Path,
    decisions_path: Path,
    output_dir: Path,
) -> dict[str, Any]:
    result = build_application(
        read_json(global_path),
        read_json(registry_path),
        read_json(audit_path),
        read_json(decisions_path),
    )
    write_application(output_dir, result)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--global-by-sujet", type=Path, required=True)
    parser.add_argument("--registry", type=Path, required=True)
    parser.add_argument("--audit", type=Path, required=True)
    parser.add_argument("--decisions", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    args = parser.parse_args()
    apply_from_files(
        args.global_by_sujet, args.registry, args.audit, args.decisions, args.out_dir
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
