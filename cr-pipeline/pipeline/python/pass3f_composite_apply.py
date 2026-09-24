#!/usr/bin/env python3
"""Apply fully resolved and human-validated Pass3F composite plans."""

from __future__ import annotations

import argparse
import copy
import hashlib
from pathlib import Path
from typing import Any

from pass3f_provenance import (
    canonical_bytes,
    read_json,
    stable_id,
    write_json_deterministic,
)


VALIDATIONS_SCHEMA_VERSION = "pass3f.composite_validations.v1"
APPLIED_SCHEMA_VERSION = "pass3f.composite_applied.v1"
PROVENANCE_SCHEMA_VERSION = "pass3f.provenance.v2"
TRANSVERSE_SCHEMA_VERSION = "pass3f.transverse.v1"
AUTONOMOUS_FIELDS = ("synthese_echanges", "conclusion_expert")


def document_hash(value: Any) -> str:
    return hashlib.sha256(canonical_bytes(value)).hexdigest()


def composite_validation_identifier(validation: dict[str, Any]) -> str:
    return stable_id("composite-validation", {
        key: value for key, value in validation.items() if key != "validation_id"
    })


def evidence_occurrences_hash(
    evidence_ids: list[str], registry: dict[str, Any]
) -> str:
    evidence = {
        str(item["evidence_occurrence_id"]): item
        for item in registry.get("evidence") or []
    }
    missing = sorted(set(evidence_ids) - set(evidence))
    if missing:
        raise ValueError(f"unknown evidence occurrences: {', '.join(missing)}")
    return document_hash([evidence[item_id] for item_id in sorted(evidence_ids)])


def _subjects(document: dict[str, Any]) -> dict[str, dict[str, Any]]:
    values = document.get("sujets")
    if not isinstance(values, list):
        raise ValueError("global_by_sujet.sujets must be an array")
    result = {}
    for subject in values:
        subject_id = str(int(subject["numero"]))
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


def _set_paragraphs(subject: dict[str, Any], field: str, values: list[str]) -> None:
    subject[field] = "\n\n".join(values)


def _occurrences(subject: dict[str, Any], text: str) -> list[dict[str, Any]]:
    return [
        {"field": field, "index": index}
        for field in AUTONOMOUS_FIELDS
        for index, paragraph in enumerate(_paragraphs(subject, field))
        if paragraph == text
    ]


def _source_hashes(
    global_by_subject: dict[str, Any],
    registry: dict[str, Any],
    applied: dict[str, Any],
    manifest: dict[str, Any],
    transverse: dict[str, Any],
) -> dict[str, str]:
    return {
        "global_by_sujet": document_hash(global_by_subject),
        "provenance_registry": document_hash(registry),
        "pass3f_applied": document_hash(applied),
        "correction_manifest": document_hash(manifest),
        "transverse_units": document_hash(transverse),
    }


def _validation_blockers(
    plan: dict[str, Any],
    fragment: dict[str, Any] | None,
    validation: dict[str, Any] | None,
    registry: dict[str, Any],
    transverse_by_unit: dict[str, dict[str, Any]],
    source_hashes_match: bool,
) -> list[str]:
    blockers: list[str] = []
    if validation is None:
        return ["human_validation_missing"]
    if not source_hashes_match:
        blockers.append("validation_source_hashes_stale")
    if validation.get("decision") != "accepted":
        blockers.append("human_validation_missing")
    if validation.get("validation_id") != composite_validation_identifier(validation):
        blockers.append("validation_id_invalid")
    if validation.get("split_plan_id") != plan.get("split_plan_id"):
        blockers.append("split_plan_id_changed")
    if validation.get("split_plan_hash") != document_hash(plan):
        blockers.append("split_plan_changed")
    if fragment is None:
        blockers.append("original_fragment_missing_from_registry")
    else:
        if validation.get("fragment_id") != fragment.get("fragment_id"):
            blockers.append("original_fragment_id_changed")
        if validation.get("fragment_hash") != document_hash(fragment):
            blockers.append("original_fragment_changed")

    units = plan.get("units") or []
    if any(unit.get("destination") == "unresolved" for unit in units):
        blockers.append("unit_destination_unresolved")
    if plan.get("split_status") not in {"deterministic", "bounded_llm_completed"}:
        blockers.append("split_not_completed")
    if plan.get("provenance_status") != "recovered":
        blockers.append("provenance_not_recovered")
    if plan.get("destination_status") != "resolved":
        blockers.append("destinations_not_resolved")

    expected_dispositions = [
        {
            "unit_id": str(unit["unit_id"]),
            "destination": str(unit["destination"]),
            "unit_hash": document_hash(unit),
        }
        for unit in units
    ]
    actual_dispositions = validation.get("unit_dispositions") or []
    if actual_dispositions != expected_dispositions:
        blockers.append("unit_dispositions_changed")

    evidence_ids = sorted({
        str(evidence_id)
        for unit in units
        for evidence_id in unit.get("evidence_refs") or []
    })
    if validation.get("evidence_occurrence_ids") != evidence_ids:
        blockers.append("evidence_occurrences_changed")
    else:
        try:
            current_hash = evidence_occurrences_hash(evidence_ids, registry)
        except ValueError:
            current_hash = None
        if validation.get("evidence_occurrences_hash") != current_hash:
            blockers.append("evidence_occurrences_changed")

    reconciliation_by_unit = {
        str(item["unit_id"]): item
        for item in validation.get("transverse_reconciliations") or []
    }
    transverse_units = [
        unit for unit in units
        if unit.get("destination") == "transverse_document_request"
    ]
    if set(reconciliation_by_unit) != {
        str(unit["unit_id"]) for unit in transverse_units
    }:
        blockers.append("transverse_reconciliation_scope_changed")
    for unit in transverse_units:
        unit_id = str(unit["unit_id"])
        reconciled = transverse_by_unit.get(unit_id)
        expected = reconciliation_by_unit.get(unit_id)
        if reconciled is None or expected is None:
            blockers.append("transverse_reconciliation_missing")
            continue
        if expected.get("materialization_status") != reconciled.get("materialization_status"):
            blockers.append("transverse_match_changed")
        if expected.get("existing_match_hash") != document_hash(reconciled.get("existing_match")):
            blockers.append("transverse_match_changed")
        if expected.get("materialization_status") == "reuse_existing" and (
            reconciled.get("materialization_status") != "reuse_existing"
            or (reconciled.get("existing_match") or {}).get("status") != "unique"
        ):
            blockers.append("transverse_reuse_no_longer_unique")
        if reconciled.get("materialization_status") == "blocked_ambiguous":
            blockers.append("transverse_match_ambiguous")
    return sorted(set(blockers))


def _apply_plan(
    output_subjects: dict[str, dict[str, Any]],
    source_subject: str,
    fragment: dict[str, Any],
    plan: dict[str, Any],
) -> tuple[list[str], dict[str, Any]]:
    source_hits = _occurrences(output_subjects[source_subject], str(fragment["text"]))
    if len(source_hits) != 1:
        return ["original_fragment_not_unique_in_active_representation"], {}
    subject_units = [
        unit for unit in plan["units"]
        if str(unit["destination"]).startswith("subject:")
    ]
    for unit in subject_units:
        target_id = str(unit["destination"]).split(":", 1)[1]
        if target_id not in output_subjects:
            return [f"unknown_destination_subject:{target_id}"], {}
        if len(_occurrences(output_subjects[target_id], str(unit["text"]))) > 1:
            return [f"subject_unit_not_unique:{unit['unit_id']}"], {}

    locator = source_hits[0]
    field = locator["field"]
    source_values = _paragraphs(output_subjects[source_subject], field)
    original_text = source_values.pop(locator["index"])
    source_insertions = [
        str(unit["text"])
        for unit in subject_units
        if str(unit["destination"]) == f"subject:{source_subject}"
        and not _occurrences(output_subjects[source_subject], str(unit["text"]))
    ]
    for offset, text in enumerate(source_insertions):
        source_values.insert(locator["index"] + offset, text)
    _set_paragraphs(output_subjects[source_subject], field, source_values)

    for unit in subject_units:
        target_id = str(unit["destination"]).split(":", 1)[1]
        if target_id == source_subject:
            continue
        target = output_subjects[target_id]
        if not _occurrences(target, str(unit["text"])):
            target_values = _paragraphs(target, field)
            target_values.append(str(unit["text"]))
            _set_paragraphs(target, field, target_values)

    return [], {
        "original_text": original_text,
        "source_locator": locator,
        "subject_units": copy.deepcopy(subject_units),
    }


def build_composite_application(
    global_by_subject: dict[str, Any],
    registry: dict[str, Any],
    applied: dict[str, Any],
    manifest: dict[str, Any],
    transverse: dict[str, Any],
    validations: dict[str, Any],
) -> dict[str, Any]:
    if registry.get("schema") != PROVENANCE_SCHEMA_VERSION:
        raise ValueError("unsupported provenance schema")
    if transverse.get("schema") != TRANSVERSE_SCHEMA_VERSION:
        raise ValueError("unsupported transverse schema")
    if validations.get("schema") != VALIDATIONS_SCHEMA_VERSION:
        raise ValueError("unsupported composite validations schema")
    run_id = str(applied.get("run_id") or "")
    if not run_id or validations.get("run_id") != run_id:
        raise ValueError("composite validation run_id mismatch")
    if transverse.get("run_id") != run_id or (registry.get("run") or {}).get("run_id") != run_id:
        raise ValueError("composite input run_id mismatch")

    current_source_hashes = _source_hashes(
        global_by_subject, registry, applied, manifest, transverse
    )
    source_hashes_match = validations.get("source_hashes") == current_source_hashes
    application_id = stable_id("composite-application", {
        "source_hashes": current_source_hashes,
        "validations": document_hash(validations),
    })
    output = copy.deepcopy(global_by_subject)
    output_subjects = _subjects(output)
    original_subjects = _subjects(global_by_subject)
    fragments = {
        str(item["fragment_id"]): item
        for item in registry.get("derived_fragments") or []
    }
    transverse_by_unit = {
        str(item["unit_id"]): item for item in transverse.get("units") or []
    }
    validation_by_plan = {
        str(item["split_plan_id"]): item
        for item in validations.get("validations") or []
    }
    if len(validation_by_plan) != len(validations.get("validations") or []):
        raise ValueError("duplicate validation for a composite split plan")

    operations: list[dict[str, Any]] = []
    applications: list[dict[str, Any]] = []
    affected_subjects: set[str] = set()
    plans = [
        (operation, plan)
        for operation in applied.get("operations") or []
        for plan in operation.get("composite_split_plans") or []
    ]
    for operation, plan in plans:
        fragment_id = str(plan["derived_from_fragment_id"])
        fragment = fragments.get(fragment_id)
        validation = validation_by_plan.get(str(plan["split_plan_id"]))
        blockers = _validation_blockers(
            plan, fragment, validation, registry, transverse_by_unit,
            source_hashes_match,
        )
        source_subject = str(operation["source_subject"])
        if source_subject not in output_subjects:
            blockers.append("source_subject_missing")
        application_details: dict[str, Any] = {}
        if not blockers and fragment is not None:
            blockers, application_details = _apply_plan(
                output_subjects, source_subject, fragment, plan
            )

        status = "blocked" if blockers else "fully_applied"
        subject_units = [
            str(unit["unit_id"]) for unit in plan["units"]
            if str(unit["destination"]).startswith("subject:")
        ]
        transverse_units = [
            str(unit["unit_id"]) for unit in plan["units"]
            if unit["destination"] == "transverse_document_request"
        ]
        metadata_units = [
            str(unit["unit_id"]) for unit in plan["units"]
            if unit["destination"] == "metadata_only"
        ]
        discarded_units = [
            str(unit["unit_id"]) for unit in plan["units"]
            if unit["destination"] == "discard_editorial_wrapper"
        ]
        operation_result = {
            "proposal_id": str(operation["proposal_id"]),
            "split_plan_id": str(plan["split_plan_id"]),
            "fragment_id": fragment_id,
            "validation_id": (
                str(validation["validation_id"]) if validation else None
            ),
            "status": status,
            "blockers": sorted(set(blockers)),
            "subject_unit_ids": subject_units,
            "transverse_unit_ids": transverse_units,
            "metadata_unit_ids": metadata_units,
            "discarded_unit_ids": discarded_units,
        }
        operations.append(operation_result)
        if status == "fully_applied":
            affected_subjects.add(source_subject)
            affected_subjects.update(
                destination.split(":", 1)[1]
                for destination in (unit["destination"] for unit in plan["units"])
                if str(destination).startswith("subject:")
            )
            applications.append({
                **operation_result,
                "validation": copy.deepcopy(validation),
                "original_fragment": copy.deepcopy(fragment),
                "split_plan": copy.deepcopy(plan),
                "unit_dispositions": copy.deepcopy(plan["units"]),
                "transverse_reconciliations": [
                    copy.deepcopy(transverse_by_unit[unit_id])
                    for unit_id in transverse_units
                ],
                "application_details": application_details,
            })

    full_count = sum(item["status"] == "fully_applied" for item in operations)
    if operations and full_count == len(operations):
        overall_status = "fully_applied"
    elif full_count:
        overall_status = "partially_applied"
    else:
        overall_status = "blocked"

    unaffected = sorted(set(original_subjects) - affected_subjects, key=int)
    unaffected_identical = all(
        canonical_bytes(original_subjects[subject_id])
        == canonical_bytes(output_subjects[subject_id])
        for subject_id in unaffected
    )
    original_removed = all(
        not _occurrences(output_subjects[str(app["original_fragment"]["subject_id"])],
                         str(app["original_fragment"]["text"]))
        for app in applications
    )
    subject_unique = all(
        len(_occurrences(
            output_subjects[str(unit["destination"]).split(":", 1)[1]],
            str(unit["text"]),
        )) == 1
        for app in applications
        for unit in app["unit_dispositions"]
        if str(unit["destination"]).startswith("subject:")
    )
    transverse_reconciled = all(
        unit_id in transverse_by_unit
        and transverse_by_unit[unit_id]["materialization_status"]
            in {"reuse_existing", "prepare_new"}
        for app in applications
        for unit_id in app["transverse_unit_ids"]
    )
    metadata_preserved = all(
        any(unit["unit_id"] == unit_id for unit in app["unit_dispositions"])
        for app in applications
        for unit_id in app["metadata_unit_ids"]
    )
    controls = {
        "original_fragments_removed": original_removed,
        "subject_units_unique": subject_unique,
        "transverse_units_reconciled": transverse_reconciled,
        "metadata_preserved_in_manifest": metadata_preserved,
        "unaffected_subjects_identical": unaffected_identical,
    }
    if applications and not all(controls.values()):
        failed = sorted(key for key, value in controls.items() if not value)
        raise AssertionError(f"composite post-application controls failed: {', '.join(failed)}")

    output_manifest = copy.deepcopy(manifest)
    output_manifest["output_global_hash"] = document_hash(output)
    output_manifest["composite_source_hashes"] = current_source_hashes
    output_manifest["composite_applications"] = applications
    output_manifest["unaffected_subject_ids"] = unaffected

    composite_applied = {
        "schema": APPLIED_SCHEMA_VERSION,
        "application_id": application_id,
        "run_id": run_id,
        "status": overall_status,
        "source_hashes": current_source_hashes,
        "output_global_hash": document_hash(output),
        "operations": operations,
        "controls": controls,
    }
    return {
        "applied": composite_applied,
        "global_by_sujet_3f": output,
        "manifest": output_manifest,
    }


def write_composite_application(output_dir: Path, result: dict[str, Any]) -> None:
    output_dir = Path(output_dir)
    write_json_deterministic(
        output_dir / "pass3f_composite_applied.json", result["applied"]
    )
    write_json_deterministic(
        output_dir / "global_by_sujet_3f.json", result["global_by_sujet_3f"]
    )
    write_json_deterministic(
        output_dir / "correction_manifest.json", result["manifest"]
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--global-by-sujet", type=Path, required=True)
    parser.add_argument("--registry", type=Path, required=True)
    parser.add_argument("--applied", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--transverse", type=Path, required=True)
    parser.add_argument("--validations", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    args = parser.parse_args()
    result = build_composite_application(
        read_json(args.global_by_sujet),
        read_json(args.registry),
        read_json(args.applied),
        read_json(args.manifest),
        read_json(args.transverse),
        read_json(args.validations),
    )
    write_composite_application(args.out_dir, result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
