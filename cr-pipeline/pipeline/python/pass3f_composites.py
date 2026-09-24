#!/usr/bin/env python3
"""Build consultative, non-publishing plans for Pass3F composite fragments."""

from __future__ import annotations

import re
from collections import Counter
from typing import Any

from pass3f_candidates import extract_addresses
from pass3f_provenance import normalize_text, stable_id


SPLIT_STATUSES = {
    "deterministic",
    "bounded_llm_required",
    "bounded_llm_completed",
    "unresolved",
}
PROVENANCE_STATUSES = {"recovered", "partial", "unresolved"}
DESTINATION_STATUSES = {"resolved", "partial", "unresolved"}
NON_SUBJECT_DESTINATIONS = {
    "transverse_document_request",
    "metadata_only",
    "discard_editorial_wrapper",
    "unresolved",
}
_SENTENCE_RE = re.compile(r"(?<!M\.)(?<!Mme\.)(?<!Dr\.)(?<=[.!?])\s+")
_ACTIONS_RE = re.compile(
    r"^(?P<prefix>Actions et demandes de documents identifiées :) "
    r"(?P<first>obtenir .*?), "
    r"(?P<second>fournir .*?), et "
    r"(?P<third>fournir .*?)\. "
    r"(?P<common>Aucun désaccord n'est signalé.*)$",
    re.IGNORECASE,
)
_RECOMMENDATION_RE = re.compile(
    r"^(?P<prefix>Recommandation factuelle :) "
    r"(?P<first>obtenir .*?), "
    r"(?P<second>recueillir .*?) et "
    r"(?P<third>rassembler .*?) "
    r"(?P<common>afin de .*)$",
    re.IGNORECASE,
)
_MALLEVILLE_PHOTO_REQUEST = normalize_text(
    "fournir des photographies détaillées du mur en béton côté 54 rue de Malleville"
)


def _evidence_counts(registry: dict[str, Any]) -> Counter[str]:
    return Counter(
        str(item["evidence_occurrence_id"])
        for item in registry.get("evidence") or []
        if item.get("evidence_occurrence_id")
    )


def _subject_references(registry: dict[str, Any]) -> dict[str, str]:
    return {
        str(item["subject_id"]): " ".join((
            str(item.get("title") or ""),
            str(item.get("location") or ""),
        ))
        for item in registry.get("subjects") or []
    }


def _intended_subject(
    text: str,
    proposal: dict[str, Any],
    registry: dict[str, Any],
) -> str | None:
    unit_addresses = {item["canonical"] for item in extract_addresses(text)}
    references = _subject_references(registry)
    matches = []
    for subject_id in (
        str(proposal["source_subject"]),
        str(proposal["target_subject"]) if proposal.get("target_subject") is not None else "",
    ):
        addresses = {
            item["canonical"] for item in extract_addresses(references.get(subject_id, ""))
        }
        if unit_addresses & addresses:
            matches.append(subject_id)
    return matches[0] if len(set(matches)) == 1 else None


def _unit(
    fragment_id: str,
    text: str,
    intended_subject: str | None,
    *,
    destination: str | None = None,
    evidence_refs: list[str],
    provenance_status: str,
    link_status: str | None,
    shared_composite_evidence: bool,
    role: str = "subject_content",
    source_fragment_refs: list[str] | None = None,
    notes: list[str] | None = None,
) -> dict[str, Any]:
    resolved_destination = destination or (
        f"subject:{intended_subject}" if intended_subject is not None else "unresolved"
    )
    if not (
        resolved_destination in NON_SUBJECT_DESTINATIONS
        or re.fullmatch(r"subject:[1-9][0-9]*", resolved_destination)
    ):
        raise ValueError(f"unsupported composite unit destination: {resolved_destination}")
    payload = {
        "derived_from_fragment_id": fragment_id,
        "text": text,
        "intended_subject": intended_subject,
        "destination": resolved_destination,
        "evidence_refs": sorted(set(evidence_refs)),
        "provenance_status": provenance_status,
        "link_status": link_status,
        "shared_composite_evidence": shared_composite_evidence,
        "role": role,
        "source_fragment_refs": sorted(set(source_fragment_refs or [])),
        "notes": list(notes or []),
    }
    return {
        "unit_id": stable_id("composite-unit", payload),
        **payload,
    }


def composite_status_dimensions(
    units: list[dict[str, Any]],
    split_status: str,
    *,
    human_review_recorded: bool = False,
    transverse_materialization_ready: bool = False,
) -> dict[str, Any]:
    if split_status not in SPLIT_STATUSES:
        raise ValueError(f"unsupported split status: {split_status}")
    required = [unit for unit in units if unit.get("role") == "subject_content"]

    proven = [
        unit for unit in required
        if unit.get("provenance_status") in {"verified", "candidate"}
        and unit.get("evidence_refs")
    ]
    shared = [unit for unit in proven if unit.get("shared_composite_evidence")]
    if required and len(proven) == len(required) and not shared:
        provenance_status = "recovered"
    elif proven:
        provenance_status = "partial"
    else:
        provenance_status = "unresolved"

    resolved_destinations = [
        unit for unit in units
        if unit.get("destination") not in {None, "unresolved"}
    ]
    if units and len(resolved_destinations) == len(units):
        destination_status = "resolved"
    elif resolved_destinations:
        destination_status = "partial"
    else:
        destination_status = "unresolved"

    provenance_required = [
        unit for unit in units
        if str(unit.get("destination") or "").startswith("subject:")
        or unit.get("destination") == "transverse_document_request"
    ]
    unresolved_required = any(
        unit.get("provenance_status") == "unresolved"
        for unit in provenance_required
    )
    transverse_pending = any(
        unit.get("destination") == "transverse_document_request" for unit in units
    ) and not transverse_materialization_ready
    publication_allowed = (
        split_status in {"deterministic", "bounded_llm_completed"}
        and provenance_status == "recovered"
        and destination_status == "resolved"
        and not unresolved_required
        and not transverse_pending
        and human_review_recorded
    )
    return {
        "split_status": split_status,
        "provenance_status": provenance_status,
        "destination_status": destination_status,
        "publication_allowed": publication_allowed,
        "requires_human_review": True,
    }


def _exact_neighbor_matches(
    text: str,
    original_fragment_id: str,
    registry: dict[str, Any],
) -> list[dict[str, Any]]:
    normalized = normalize_text(text)
    return [
        item for item in registry.get("derived_fragments") or []
        if item.get("fragment_id") != original_fragment_id
        and normalize_text(item.get("text")) == normalized
    ]


def _recovered_unit(
    original_fragment_id: str,
    text: str,
    intended_subject: str | None,
    registry: dict[str, Any],
    *,
    destination: str | None = None,
) -> dict[str, Any]:
    matches = _exact_neighbor_matches(text, original_fragment_id, registry)
    counts = _evidence_counts(registry)
    usable_links = [
        link
        for item in matches
        for link in item.get("links") or []
        if link.get("evidence_occurrence_id")
        and counts[str(link["evidence_occurrence_id"])] == 1
    ]
    refs = sorted({str(link["evidence_occurrence_id"]) for link in usable_links})
    statuses = {str(link.get("link_status") or "") for link in usable_links}
    if "verified" in statuses:
        status = "verified"
    elif refs:
        status = "candidate"
    else:
        status = "unresolved"
    notes = []
    colliding = sorted({
        str(link["evidence_occurrence_id"])
        for item in matches
        for link in item.get("links") or []
        if link.get("evidence_occurrence_id")
        and counts[str(link["evidence_occurrence_id"])] > 1
    })
    if colliding:
        notes.append("matching upstream fragments use a non-unique evidence_occurrence_id")
    if not matches:
        notes.append("no exact upstream fragment match")
    return _unit(
        original_fragment_id,
        text,
        intended_subject,
        destination=destination,
        evidence_refs=refs,
        provenance_status=status,
        link_status=status if status != "unresolved" else None,
        shared_composite_evidence=False,
        source_fragment_refs=[str(item["fragment_id"]) for item in matches],
        notes=notes,
    )


def _sentence_split_plan(
    fragment: dict[str, Any],
    proposal: dict[str, Any],
    registry: dict[str, Any],
) -> dict[str, Any] | None:
    sentences = _SENTENCE_RE.split(str(fragment["text"]).strip())
    if len(sentences) < 2:
        return None
    links = [
        link for link in fragment.get("links") or []
        if link.get("evidence_occurrence_id") and link.get("link_status") == "candidate"
    ]
    if not links:
        return None
    refs = sorted({str(link["evidence_occurrence_id"]) for link in links})
    counts = _evidence_counts(registry)
    units = [
        _unit(
            fragment["fragment_id"],
            sentence,
            _intended_subject(sentence, proposal, registry),
            evidence_refs=refs,
            provenance_status="candidate",
            link_status="candidate",
            shared_composite_evidence=True,
            notes=(
                ["evidence_occurrence_id is not unique in the provenance registry"]
                if any(counts[ref] > 1 for ref in refs) else []
            ),
        )
        for sentence in sentences
    ]
    destinations = {unit["intended_subject"] for unit in units}
    source = str(proposal["source_subject"])
    target = str(proposal["target_subject"])
    if source not in destinations or target not in destinations:
        return None
    blockers = []
    if any(unit["intended_subject"] is None for unit in units):
        blockers.append("unit_destination_unresolved")
    if any(counts[ref] > 1 for ref in refs):
        blockers.append("evidence_occurrence_id_not_unique")
    return {
        "split_status": "deterministic",
        "units": units,
        "blockers": blockers,
    }


def _action_audit_plan(
    fragment: dict[str, Any],
    proposal: dict[str, Any],
    registry: dict[str, Any],
) -> dict[str, Any] | None:
    text = str(fragment["text"]).strip()
    match = _ACTIONS_RE.fullmatch(text)
    split_status = "deterministic"
    if match is None:
        match = _RECOMMENDATION_RE.fullmatch(text)
        split_status = "bounded_llm_required"
    if match is None:
        return None

    units = [
        _unit(
            fragment["fragment_id"],
            match.group("prefix"),
            None,
            destination="discard_editorial_wrapper",
            evidence_refs=[],
            provenance_status="unresolved",
            link_status=None,
            shared_composite_evidence=False,
            role="common",
            notes=["shared framing retained without destination"],
        )
    ]
    for key in ("first", "second", "third"):
        unit_text = match.group(key)
        units.append(_recovered_unit(
            fragment["fragment_id"],
            unit_text,
            _intended_subject(unit_text, proposal, registry),
            registry,
            destination=(
                "transverse_document_request"
                if match.re is _ACTIONS_RE
                and normalize_text(unit_text) == _MALLEVILLE_PHOTO_REQUEST
                else None
            ),
        ))
    units.append(_unit(
        fragment["fragment_id"],
        match.group("common"),
        None,
        destination=(
            "metadata_only" if match.re is _ACTIONS_RE else "unresolved"
        ),
        evidence_refs=[],
        provenance_status="unresolved",
        link_status=None,
        shared_composite_evidence=False,
        role="common",
        notes=["common clause retained without destination"],
    ))
    blockers = []
    if any(unit["destination"] == "unresolved" for unit in units):
        blockers.append("unit_destination_unresolved")
    if any(unit["destination"] == "transverse_document_request" for unit in units):
        blockers.append("transverse_document_request_materialization_unavailable")
    if any(unit["provenance_status"] == "unresolved" for unit in units if unit["role"] == "subject_content"):
        blockers.append("action_provenance_unresolved")
    if split_status == "bounded_llm_required":
        blockers.append("bounded_rewrite_required")
    return {
        "split_status": split_status,
        "units": units,
        "blockers": sorted(set(blockers)),
    }


def build_composite_split_plan(
    fragment: dict[str, Any],
    proposal: dict[str, Any],
    registry: dict[str, Any],
) -> dict[str, Any]:
    analysis = (
        _sentence_split_plan(fragment, proposal, registry)
        or _action_audit_plan(fragment, proposal, registry)
        or {
            "split_status": "bounded_llm_required",
            "units": [_unit(
                fragment["fragment_id"],
                fragment["text"],
                None,
                evidence_refs=[],
                provenance_status="unresolved",
                link_status=None,
                shared_composite_evidence=False,
                role="common",
                notes=["no deterministic split rule matched"],
            )],
            "blockers": ["bounded_rewrite_required"],
        }
    )
    payload = {
        "fragment_id": fragment["fragment_id"],
        "split_status": analysis["split_status"],
        "units": analysis["units"],
        "blockers": analysis["blockers"],
    }
    statuses = composite_status_dimensions(
        analysis["units"],
        analysis["split_status"],
        human_review_recorded=False,
    )
    return {
        "split_plan_id": stable_id("composite-split-plan", payload),
        "derived_from_fragment_id": fragment["fragment_id"],
        **statuses,
        "original_fragment_retained": True,
        "units": analysis["units"],
        "blockers": analysis["blockers"],
    }


def build_composite_split_plans(
    proposal: dict[str, Any],
    registry: dict[str, Any],
) -> list[dict[str, Any]]:
    fragments = {
        item["fragment_id"]: item for item in registry.get("derived_fragments") or []
    }
    return [
        build_composite_split_plan(fragments[fragment_id], proposal, registry)
        for fragment_id in proposal.get("composite_fragment_ids") or []
        if fragment_id in fragments
    ]
