#!/usr/bin/env python3
"""Build a deterministic local Pass3F reconciliation plan without an LLM."""

from __future__ import annotations

import copy
import re
from typing import Any

from pass3f_provenance import canonical_bytes, content_tokens, normalize_text, stable_id


SCHEMA_VERSION = "pass3f.reconciliation-plan.v1"
AUTONOMOUS_FIELDS = ("synthese_echanges", "conclusion_expert")
RELATION_CLASSES = {
    "exact_duplicate",
    "semantic_duplicate",
    "partial_overlap",
    "complementary",
    "contradiction",
    "unrelated",
}
_PARTICIPANT_PATH_RE = re.compile(r"^/avis_participants/(?P<index>\d+)(?:/|$)")
_EMPTY_SYNTHESIS = normalize_text(
    "Aucun element relatif a ce point n'a ete identifie dans les echanges analyses."
)
_EMPTY_CONCLUSION_PREFIX = normalize_text(
    "En l'absence d'echanges ou d'elements fournis relatifs a ce point"
)


def document_hash(value: Any) -> str:
    return stable_id("document", value).split(":", 1)[1]


def _subjects(document: dict[str, Any]) -> dict[str, dict[str, Any]]:
    values = document.get("sujets")
    if not isinstance(values, list):
        raise ValueError("global_by_sujet must contain a sujets list")
    return {str(item["numero"]): item for item in values}


def _paragraphs(subject: dict[str, Any], field: str) -> list[str]:
    value = str(subject.get(field) or "")
    return [part.strip() for part in re.split(r"\n\s*\n", value) if part.strip()]


def _set_paragraphs(subject: dict[str, Any], field: str, values: list[str]) -> None:
    subject[field] = "\n\n".join(values)


def _fragment_evidence(fragment: dict[str, Any]) -> list[str]:
    return sorted({
        str(link["evidence_occurrence_id"])
        for link in fragment.get("links") or []
        if link.get("evidence_occurrence_id")
    })


def _verified_fragment_evidence(fragment: dict[str, Any]) -> list[str]:
    return sorted({
        str(link["evidence_occurrence_id"])
        for link in fragment.get("links") or []
        if link.get("evidence_occurrence_id") and link.get("link_status") == "verified"
    })


def _participant_evidence(
    participant: dict[str, Any],
    fragments: list[dict[str, Any]],
    evidence: dict[str, dict[str, Any]],
) -> tuple[list[str], list[str]]:
    name = normalize_text(participant.get("nom"))
    all_refs: set[str] = set()
    deterministic_refs: set[str] = set()
    for fragment in fragments:
        for ref in _fragment_evidence(fragment):
            all_refs.add(ref)
            item = evidence.get(ref)
            if item and name and name in normalize_text(item.get("exact_text")):
                deterministic_refs.add(ref)
    return sorted(all_refs), sorted(deterministic_refs)


def audit_participant_objects(
    global_by_subject: dict[str, Any],
    registry: dict[str, Any],
    proposal: dict[str, Any],
) -> list[dict[str, Any]]:
    source_id = str(proposal["source_subject"])
    target_id = str(proposal["target_subject"])
    subjects = _subjects(global_by_subject)
    source = subjects[source_id]
    target = subjects[target_id]
    fragments = {item["fragment_id"]: item for item in registry["derived_fragments"]}
    evidence = {item["evidence_occurrence_id"]: item for item in registry["evidence"]}
    classified = {
        item["fragment_id"]: item
        for item in proposal.get("fragment_classifications") or []
        if item["representation_type"] == "participant_subfield"
    }
    grouped: dict[int, list[dict[str, Any]]] = {}
    for fragment_id in sorted(classified):
        fragment = fragments[fragment_id]
        match = _PARTICIPANT_PATH_RE.match(str(fragment["field_path"]))
        if match:
            grouped.setdefault(int(match.group("index")), []).append(fragment)

    target_values = target.get("avis_participants") or []
    operations = []
    for index in sorted(grouped):
        source_values = source.get("avis_participants") or []
        if index >= len(source_values):
            continue
        participant = copy.deepcopy(source_values[index])
        all_refs, deterministic_refs = _participant_evidence(
            participant, grouped[index], evidence
        )
        exact_duplicates = [
            target_index for target_index, item in enumerate(target_values)
            if canonical_bytes(item) == canonical_bytes(participant)
        ]
        same_name = [
            target_index for target_index, item in enumerate(target_values)
            if normalize_text(item.get("nom")) == normalize_text(participant.get("nom"))
        ]
        status = (
            "duplicate_target_object"
            if exact_duplicates
            else "ambiguous_target_object"
            if same_name
            else "ready_for_human_validation"
        )
        operations.append({
            "operation_id": stable_id("participant-operation", {
                "source_subject": source_id,
                "target_subject": target_id,
                "source_index": index,
                "participant": participant,
                "fragment_ids": sorted(item["fragment_id"] for item in grouped[index]),
            }),
            "action": "move_participant_object",
            "source_subject": source_id,
            "target_subject": target_id,
            "source_index": index,
            "participant": participant,
            "participant_hash": document_hash(participant),
            "source_fragment_ids": sorted(item["fragment_id"] for item in grouped[index]),
            "evidence_occurrence_ids": deterministic_refs,
            "deterministic_evidence_occurrence_ids": deterministic_refs,
            "excluded_candidate_evidence_occurrence_ids": sorted(
                set(all_refs) - set(deterministic_refs)
            ),
            "target_exact_duplicate_indices": exact_duplicates,
            "target_same_name_indices": same_name,
            "status": status,
            "requires_human_review": True,
        })
    return operations


def _relation(left: dict[str, Any], right: dict[str, Any]) -> str:
    left_text = normalize_text(left["text"])
    right_text = normalize_text(right["text"])
    if left_text == right_text:
        return "exact_duplicate"
    left_tokens = content_tokens(left_text)
    right_tokens = content_tokens(right_text)
    request_verbs = {"fournir", "obtenir", "recueillir", "rassembler"}
    request_objects = {
        "coordonnees", "documents", "photographies", "plans",
        "diagnostics", "visite",
    }
    left_is_request = bool(left_tokens & request_verbs)
    right_is_request = bool(right_tokens & request_verbs)
    if left_is_request != right_is_request:
        request_tokens = left_tokens if left_is_request else right_tokens
        other_tokens = right_tokens if left_is_request else left_tokens
        supported_objects = request_tokens & request_objects
        if supported_objects and not (supported_objects & other_tokens):
            return "complementary"
    overlap = left_tokens & right_tokens
    minimum = min(len(left_tokens), len(right_tokens))
    containment = len(overlap) / minimum if minimum else 0.0
    length_ratio = (
        max(len(left_tokens), len(right_tokens)) / minimum if minimum else float("inf")
    )
    if containment >= 0.8 and length_ratio <= 1.35:
        return "semantic_duplicate"
    if len(overlap) >= 3 and containment >= 0.35:
        return "partial_overlap"
    left_addresses = {token for token in left_tokens if token.isdigit()}
    right_addresses = {token for token in right_tokens if token.isdigit()}
    if left_addresses & right_addresses:
        return "complementary"
    return "unrelated"


def _placeholder_operation(
    section: str,
    index: int,
    text: str,
    positive_insertions: list[dict[str, Any]],
    proposal_id: str,
) -> dict[str, Any] | None:
    normalized = normalize_text(text)
    is_empty_synthesis = section == "synthese_echanges" and normalized == _EMPTY_SYNTHESIS
    is_empty_conclusion = (
        section == "conclusion_expert"
        and normalized.startswith(_EMPTY_CONCLUSION_PREFIX)
    )
    if not (is_empty_synthesis or is_empty_conclusion):
        return None
    contradicting = [
        item["item_id"] for item in positive_insertions if item["section"] == section
    ]
    if not contradicting:
        return None
    return {
        "operation": "remove_placeholder",
        "section": section,
        "index": index,
        "text": text,
        "text_hash": document_hash(text),
        "scope": "entire_section_has_no_identified_content",
        "contradicted_by_item_ids": sorted(contradicting),
        "proposal_id": proposal_id,
        "requires_accepted_decision": True,
    }


def build_reconciliation_plan(
    global_by_subject: dict[str, Any],
    registry: dict[str, Any],
    proposal: dict[str, Any],
    *,
    additional_units: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    source_id = str(proposal["source_subject"])
    target_id = str(proposal["target_subject"])
    subjects = _subjects(global_by_subject)
    source = subjects[source_id]
    target = subjects[target_id]
    fragments = {item["fragment_id"]: item for item in registry["derived_fragments"]}
    classifications = {
        item["fragment_id"]: item
        for item in proposal.get("fragment_classifications") or []
    }

    projections = sorted(
        fragment_id for fragment_id, item in classifications.items()
        if item["representation_type"] == "provenance_projection"
    )
    participant_operations = audit_participant_objects(
        global_by_subject, registry, proposal
    )
    insertions = []
    for fragment_id in sorted(proposal.get("source_fragment_ids") or []):
        fragment = fragments[fragment_id]
        classification = classifications.get(fragment_id) or {}
        if classification.get("representation_type") != "publishable_text_unit":
            raise ValueError(f"non-publishable fragment declared applicable: {fragment_id}")
        source_hits = [
            (field, index)
            for field in AUTONOMOUS_FIELDS
            for index, value in enumerate(_paragraphs(source, field))
            if value == fragment["text"]
        ]
        if len(source_hits) != 1:
            raise ValueError(f"publishable fragment is not structurally autonomous: {fragment_id}")
        field, _index = source_hits[0]
        insertions.append({
            "item_id": fragment_id,
            "kind": "fragment",
            "section": field,
            "text": fragment["text"],
            "representation_type": "publishable_text_unit",
            "evidence_occurrence_ids": _fragment_evidence(fragment),
            "verified_evidence_occurrence_ids": _verified_fragment_evidence(fragment),
            "source_fragment_ids": [fragment_id],
            "precedence": 0,
        })
    for unit in additional_units or []:
        if str(unit.get("destination")) != f"subject:{target_id}":
            continue
        insertions.append({
            "item_id": str(unit["unit_id"]),
            "kind": "composite_unit",
            "section": str(unit["section"]),
            "text": str(unit["text"]),
            "representation_type": "publishable_text_unit",
            "evidence_occurrence_ids": sorted(set(unit.get("evidence_occurrence_ids") or [])),
            "verified_evidence_occurrence_ids": sorted(set(unit.get("authorized_evidence_occurrence_ids") or [])),
            "source_fragment_ids": sorted(set(unit.get("source_fragment_ids") or [])),
            "precedence": int(unit.get("precedence", 100)),
        })

    deduplicated = []
    exact_duplicate_operations = []
    for item in sorted(
        insertions,
        key=lambda value: (value["precedence"], value["section"], value["item_id"]),
    ):
        duplicate = next((
            kept for kept in deduplicated
            if normalize_text(kept["text"]) == normalize_text(item["text"])
            and set(kept["evidence_occurrence_ids"]) & set(item["evidence_occurrence_ids"])
        ), None)
        if duplicate is None:
            deduplicated.append(item)
        else:
            exact_duplicate_operations.append({
                "operation": "drop_exact_duplicate",
                "kept_item_id": duplicate["item_id"],
                "suppressed_item_id": item["item_id"],
                "shared_evidence_occurrence_ids": sorted(
                    set(duplicate["evidence_occurrence_ids"])
                    & set(item["evidence_occurrence_ids"])
                ),
            })

    placeholder_operations = []
    for section in AUTONOMOUS_FIELDS:
        for index, text in enumerate(_paragraphs(target, section)):
            operation = _placeholder_operation(
                section, index, text, deduplicated, proposal["proposal_id"]
            )
            if operation:
                placeholder_operations.append(operation)

    simulated_target = copy.deepcopy(target)
    for operation in sorted(
        placeholder_operations,
        key=lambda item: (item["section"], -item["index"]),
    ):
        values = _paragraphs(simulated_target, operation["section"])
        if values[operation["index"]] == operation["text"]:
            values.pop(operation["index"])
            _set_paragraphs(simulated_target, operation["section"], values)
    for item in deduplicated:
        values = _paragraphs(simulated_target, item["section"])
        if item["text"] not in values:
            values.append(item["text"])
            _set_paragraphs(simulated_target, item["section"], values)
    simulated_participants = simulated_target.setdefault("avis_participants", [])
    for operation in participant_operations:
        if operation["status"] == "ready_for_human_validation":
            simulated_participants.append(copy.deepcopy(operation["participant"]))

    comparison_items = [
        {
            "item_id": stable_id("target-fragment", {
                "subject": target_id, "section": section, "index": index, "text": text
            }),
            "kind": "existing_target",
            "section": section,
            "text": text,
            "representation_type": "publishable_text_unit",
            "evidence_occurrence_ids": [],
            "verified_evidence_occurrence_ids": [],
            "source_fragment_ids": [],
        }
        for section in AUTONOMOUS_FIELDS
        for index, text in enumerate(_paragraphs(target, section))
        if not any(
            operation["section"] == section and operation["index"] == index
            for operation in placeholder_operations
        )
    ] + deduplicated
    relations = [
        {
            "left_item_id": stable_id("target-fragment", {
                "subject": target_id,
                "section": operation["section"],
                "index": operation["index"],
                "text": operation["text"],
            }),
            "right_item_id": item_id,
            "classification": "contradiction",
            "operation": "remove_placeholder",
            "llm_eligible": False,
            "blockers": [],
        }
        for operation in placeholder_operations
        for item_id in operation["contradicted_by_item_ids"]
    ]
    for left_index, left in enumerate(comparison_items):
        for right in comparison_items[left_index + 1:]:
            relation = _relation(left, right)
            if relation == "unrelated":
                continue
            provenance_ready = bool(left["verified_evidence_occurrence_ids"]) and bool(
                right["verified_evidence_occurrence_ids"]
            )
            same_section = left["section"] == right["section"]
            needs_merge = (
                relation in {"semantic_duplicate", "partial_overlap"}
                and same_section
            )
            llm_eligible = (
                needs_merge
                and left["representation_type"] == "publishable_text_unit"
                and right["representation_type"] == "publishable_text_unit"
                and provenance_ready
            )
            relations.append({
                "left_item_id": left["item_id"],
                "right_item_id": right["item_id"],
                "classification": relation,
                "operation": (
                    "drop_exact_duplicate" if relation == "exact_duplicate"
                    else "merge_required" if needs_merge
                    else "keep_both"
                ),
                "llm_eligible": llm_eligible,
                "blockers": [] if llm_eligible else (
                    ["provenance_not_authorized"]
                    if needs_merge and not provenance_ready
                    else []
                ),
            })

    payload = {
        "schema": SCHEMA_VERSION,
        "source_subject": source_id,
        "target_subject": target_id,
        "proposal_id": proposal["proposal_id"],
        "source_hashes": {
            "global_by_sujet": document_hash(global_by_subject),
            "provenance_registry": document_hash(registry),
            "proposal": document_hash(proposal),
        },
        "publishable_insertions": deduplicated,
        "excluded_provenance_projection_ids": projections,
        "participant_operations": participant_operations,
        "placeholder_operations": placeholder_operations,
        "exact_duplicate_operations": exact_duplicate_operations,
        "relations": relations,
        "simulated_target": simulated_target,
    }
    payload["reconciliation_plan_id"] = stable_id("reconciliation-plan", payload)
    return payload
