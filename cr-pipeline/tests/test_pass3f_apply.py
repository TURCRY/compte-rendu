import copy
import json
import sys
import tempfile
import unittest
from pathlib import Path

from jsonschema import Draft202012Validator


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "pipeline" / "python"))

from pass3f_apply import (  # noqa: E402
    StaleDecisionError,
    build_application,
    decision_identifier,
    document_hash,
    write_application,
)
from pass3f_composites import (  # noqa: E402
    AUTHORITY_REWRITE_VALIDATION_SCHEMA,
    authority_rewrite_validation_identifier,
    build_composite_split_plan,
    composite_status_dimensions,
    resolve_authority_rewrite_plan,
)
from pass3f_provenance import stable_id  # noqa: E402
from pass3f_reconciliation import build_reconciliation_plan  # noqa: E402


DECISIONS_SCHEMA = ROOT / "pipeline" / "schemas" / "pass3f_decisions.v1.schema.json"
APPLIED_SCHEMA = ROOT / "pipeline" / "schemas" / "pass3f_applied.v2.schema.json"
AUTHORITY_VALIDATION_SCHEMA = (
    ROOT / "pipeline" / "schemas" / "pass3f_authority_rewrite_validation.v1.schema.json"
)
COMPOSITE_EVIDENCE_ID = "evidence-occurrence:" + "d" * 64
ACTION_EVIDENCE_IDS = [
    "evidence-occurrence:" + character * 64 for character in ("a", "b", "c")
]


def a007_composite_registry():
    cc_text = (
        "La maison du 12 avenue de Girardin n'a pas pu être visitée en raison de l'absence "
        "des occupants et du retour du courrier recommandé non retiré. Le mur en béton côté "
        "rue de Malleville présente des déformations, fissures et une fragilité avancée "
        "visibles depuis l'extérieur. La maison du 15 avenue de Girardin, occupée par M. P166 "
        "et Mme P167, est une construction de la première moitié du XXe siècle en maçonnerie "
        "enduite, bien entretenue mais avec de petites fissures au niveau des murets de "
        "l'escalier et des soubassements, ainsi qu'un dallage en mauvais état attribué aux "
        "variations du sous-sol."
    )
    de_text = (
        "Actions et demandes de documents identifiées : obtenir les coordonnées des occupants "
        "du 12 avenue de Girardin pour organiser une visite, fournir des photographies "
        "détaillées du mur en béton côté 54 rue de Malleville, et fournir des documents "
        "techniques ou historiques relatifs à la construction du 15 avenue de Girardin. "
        "Aucun désaccord n'est signalé dans la synthèse fournie."
    )
    f2_text = (
        "Recommandation factuelle : obtenir les coordonnées des occupants du 12 avenue de "
        "Girardin pour organiser la visite intérieure, recueillir les photographies détaillées "
        "du mur en béton côté 54 rue de Malleville et rassembler les documents techniques ou "
        "historiques relatifs à la construction du 15 avenue de Girardin afin de poursuivre "
        "l'expertise et permettre des conclusions techniques motivées."
    )
    values = {
        "cc": fragment("18", cc_text, 0),
        "de": fragment("18", de_text, 1),
        "f2": fragment("18", f2_text, 2),
    }
    for key in values:
        values[key]["links"] = [{
            "evidence_occurrence_id": COMPOSITE_EVIDENCE_ID if key == "cc" else None,
            "link_status": "candidate" if key == "cc" else "unresolved",
            "method": "token_overlap" if key == "cc" else "none",
            "score": 0.8 if key == "cc" else 0.0,
        }]
    action_texts = [
        "Obtenir les coordonnées des occupants du 12 avenue de Girardin pour organiser une visite",
        "Fournir des photographies détaillées du mur en béton côté 54 rue de Malleville",
        "Fournir des documents techniques ou historiques relatifs à la construction du 15 avenue de Girardin",
    ]
    neighbors = [fragment("18", text, 10 + index) for index, text in enumerate(action_texts)]
    for item, evidence_id in zip(neighbors, ACTION_EVIDENCE_IDS):
        item["stage"] = "2E"
        item["links"] = [{
            "evidence_occurrence_id": evidence_id,
            "link_status": "candidate",
            "method": "token_overlap",
            "score": 0.8,
        }]
    registry = {
        "schema": "pass3f.provenance.v2",
        "run": {"run_id": stable_id("run", "a007-composites"), "pipeline_kind": "generaliste", "input_hashes": {}},
        "subjects": [
            {"subject_id": "18", "title": "État descriptif technique du 12 avenue de Girardin", "location": "parcelle AE163"},
            {"subject_id": "19", "title": "État descriptif technique du 15 avenue de Girardin", "location": "parcelle AE6"},
        ],
        "evidence": [
            {"evidence_occurrence_id": COMPOSITE_EVIDENCE_ID, "exact_text": cc_text},
            *[
                {"evidence_occurrence_id": evidence_id, "exact_text": text}
                for evidence_id, text in zip(ACTION_EVIDENCE_IDS, action_texts)
            ],
        ],
        "truncation_events": [],
        "derived_fragments": [*values.values(), *neighbors],
        "stats": {},
    }
    proposal = {
        "source_subject": "18",
        "target_subject": "19",
        "composite_fragment_ids": [item["fragment_id"] for item in values.values()],
    }
    return registry, proposal, values


def authority_validation(plan, fragment, approved_requirement_ids=None):
    validation = {
        "schema": AUTHORITY_REWRITE_VALIDATION_SCHEMA,
        "base_split_plan_id": plan["split_plan_id"],
        "base_split_plan_hash": document_hash(plan),
        "fragment_id": fragment["fragment_id"],
        "fragment_hash": document_hash(fragment),
        "approved_requirement_ids": sorted(
            approved_requirement_ids
            if approved_requirement_ids is not None
            else [
                item["requirement_id"]
                for item in plan["authority_rewrite_requirements"]
            ]
        ),
        "decision": "accepted",
        "reviewer": "reviewer-fixture",
        "reason": "Retour explicite aux trois formulations d'autorité validé.",
    }
    validation["validation_id"] = authority_rewrite_validation_identifier(validation)
    return validation


def fragment(subject_id, text, index):
    base = {
        "stage": "3E",
        "subject_id": subject_id,
        "field_path": f"/synthese_echanges/{index}",
        "text": text,
        "source_artifact": f"pass3E_sujets/sujet_{int(subject_id):03d}_synthese.json",
    }
    return {
        "fragment_id": stable_id("fragment", base),
        **base,
        "links": [{
            "evidence_occurrence_id": stable_id("evidence-occurrence", {"subject": subject_id, "text": text}),
            "link_status": "verified",
            "method": "fixture",
            "score": 1.0,
        }],
        "truncation": {
            "status": "none",
            "stage": "2E",
            "scope": "subject",
            "source_file": "",
            "source_hash": "",
            "details": "",
            "event_refs": [],
        },
    }


def fixture(action="move", *, simple_count=1, composite_count=0, unresolved_count=0):
    simple = [
        fragment("18", f"Information autonome {index} concernant le 15 avenue de Girardin.", index)
        for index in range(simple_count)
    ]
    composite = [
        fragment(
            "18",
            f"Le 12 avenue de Girardin et le 15 avenue de Girardin sont examinés ensemble {index}.",
            simple_count + index,
        )
        for index in range(composite_count)
    ]
    unresolved = [
        fragment("18", f"Objet insuffisamment localisé {index}.", simple_count + composite_count + index)
        for index in range(unresolved_count)
    ]
    all_fragments = simple + composite + unresolved
    global_doc = {
        "sujets": [
            {
                "numero": 18,
                "titre": "12 avenue de Girardin",
                "localisation": "AE163",
                "description": "",
                "avis_participants": [],
                "synthese_echanges": "\n\n".join(item["text"] for item in all_fragments),
                "conclusion_expert": "Conclusion source inchangée.",
            },
            {
                "numero": 19,
                "titre": "15 avenue de Girardin",
                "localisation": "AE164",
                "description": "",
                "avis_participants": [],
                "synthese_echanges": "Introduction cible.",
                "conclusion_expert": "Conclusion cible inchangée.",
            },
            {
                "numero": 20,
                "titre": "Sujet témoin",
                "localisation": "AE165",
                "description": "",
                "avis_participants": [],
                "synthese_echanges": "Contenu témoin.",
                "conclusion_expert": "Conclusion témoin.",
            },
        ]
    }
    run_id = stable_id("run", "pass3f-b1-fixture")
    registry = {
        "schema": "pass3f.provenance.v2",
        "run": {"run_id": run_id, "pipeline_kind": "generaliste", "input_hashes": {}},
        "subjects": [],
        "evidence": [],
        "truncation_events": [],
        "derived_fragments": all_fragments,
        "stats": {},
    }
    proposal = {
        "proposal_id": stable_id("proposal", {
            "run_id": run_id,
            "action": action,
            "simple": [item["fragment_id"] for item in simple],
        }),
        "candidate_id": stable_id("candidate", "pass3f-b1-fixture"),
        "action": action,
        "source_subject": "18",
        "target_subject": "19" if action not in {"no_action"} else None,
        "source_fragment_ids": [item["fragment_id"] for item in simple],
        "composite_fragment_ids": [item["fragment_id"] for item in composite],
        "unresolved_fragment_ids": [item["fragment_id"] for item in unresolved],
        "evidence_refs": [],
        "original_pass1_subjects": ["18"],
        "origin_stage": "indeterminate",
        "reason": "Fixture.",
        "confidence": 0.9,
        "ambiguous": False,
        "requires_human_review": True,
        "truncation_context": {"subjects": [], "fragments": [], "caution": "fixture"},
    }
    audit = {
        "schema": "pass3f.audit.v2",
        "run_id": run_id,
        "source_registry_hash": stable_id("registry", registry),
        "source_candidates_hash": stable_id("candidates", "fixture"),
        "model_alias": "fixture",
        "parameters": {},
        "groups": [],
        "proposals": [proposal],
    }
    return global_doc, registry, audit, proposal, simple, composite, unresolved


def decisions_for(global_doc, audit, proposal, accepted_ids, value="accepted"):
    item = {
        "proposal_id": proposal["proposal_id"],
        "proposal_hash": document_hash(proposal),
        "decision": value,
        "accepted_fragment_ids": list(accepted_ids),
        "reviewer": "reviewer-fixture",
        "reason": "Décision de test.",
    }
    item["decision_id"] = decision_identifier(item)
    return {
        "schema": "pass3f.decisions.v1",
        "run_id": audit["run_id"],
        "source_audit_hash": document_hash(audit),
        "source_global_hash": document_hash(global_doc),
        "source_registry_hash": audit["source_registry_hash"],
        "decisions": [item],
    }


class Pass3FApplyTest(unittest.TestCase):
    def setUp(self):
        self.decisions_schema = json.loads(DECISIONS_SCHEMA.read_text(encoding="utf-8"))
        self.applied_schema = json.loads(APPLIED_SCHEMA.read_text(encoding="utf-8"))
        self.authority_validation_schema = json.loads(
            AUTHORITY_VALIDATION_SCHEMA.read_text(encoding="utf-8")
        )

    def apply_fixture(self, action="move", **kwargs):
        values = fixture(action, **kwargs)
        global_doc, registry, audit, proposal, simple, _composite, _unresolved = values
        decisions = decisions_for(
            global_doc, audit, proposal, [item["fragment_id"] for item in simple]
        )
        Draft202012Validator(self.decisions_schema).validate(decisions)
        result = build_application(global_doc, registry, audit, decisions)
        Draft202012Validator(self.applied_schema).validate(result["applied"])
        return values, decisions, result

    def test_simple_move_preserves_text_and_removes_source(self):
        (global_doc, _registry, _audit, _proposal, simple, _c, _u), _decisions, result = self.apply_fixture()
        source, target, _witness = result["global_by_sujet_3f"]["sujets"]
        self.assertNotIn(simple[0]["text"], source["synthese_echanges"])
        self.assertEqual(target["synthese_echanges"].split("\n\n")[-1], simple[0]["text"])
        self.assertEqual(result["applied"]["status"], "applied")
        self.assertTrue(all(result["applied"]["controls"].values()))
        self.assertEqual(
            result["manifest"]["changes"][0]["provenance"]["source_artifact"],
            simple[0]["source_artifact"],
        )
        self.assertEqual(global_doc["sujets"][0]["synthese_echanges"], simple[0]["text"])

    def test_retain_overlap_changes_nothing(self):
        values = fixture("retain_overlap")
        global_doc, registry, audit, proposal, _simple, _c, _u = values
        decisions = decisions_for(global_doc, audit, proposal, [])
        result = build_application(global_doc, registry, audit, decisions)
        self.assertEqual(result["global_by_sujet_3f"], global_doc)
        self.assertEqual(result["applied"]["status"], "no_change")
        self.assertEqual(result["applied"]["operations"][0]["status"], "no_change")

    def test_composite_is_not_applied(self):
        (global_doc, _registry, _audit, _proposal, simple, composite, _u), _decisions, result = self.apply_fixture(
            simple_count=1, composite_count=1
        )
        source, target, _witness = result["global_by_sujet_3f"]["sujets"]
        self.assertIn(composite[0]["text"], source["synthese_echanges"])
        self.assertNotIn(composite[0]["text"], target["synthese_echanges"])
        self.assertNotIn(simple[0]["text"], source["synthese_echanges"])
        self.assertEqual(result["applied"]["status"], "partially_applied")
        self.assertEqual(
            result["applied"]["operations"][0]["pending_composite_fragment_ids"],
            [composite[0]["fragment_id"]],
        )
        split_plan = result["applied"]["operations"][0]["composite_split_plans"][0]
        self.assertFalse(split_plan["publication_allowed"])
        self.assertTrue(split_plan["original_fragment_retained"])
        self.assertEqual(result["manifest"]["composite_split_plans"], [split_plan])
        self.assertEqual(split_plan["units"][0]["text"], composite[0]["text"])
        self.assertIn(composite[0]["text"], global_doc["sujets"][0]["synthese_echanges"])

    def test_cc0311_deterministic_split_preserves_exact_text_and_candidate_evidence(self):
        registry, proposal, values = a007_composite_registry()
        plan = build_composite_split_plan(values["cc"], proposal, registry)
        sentences = [
            "La maison du 12 avenue de Girardin n'a pas pu être visitée en raison de l'absence des occupants et du retour du courrier recommandé non retiré.",
            "Le mur en béton côté rue de Malleville présente des déformations, fissures et une fragilité avancée visibles depuis l'extérieur.",
            "La maison du 15 avenue de Girardin, occupée par M. P166 et Mme P167, est une construction de la première moitié du XXe siècle en maçonnerie enduite, bien entretenue mais avec de petites fissures au niveau des murets de l'escalier et des soubassements, ainsi qu'un dallage en mauvais état attribué aux variations du sous-sol.",
        ]
        self.assertEqual(plan["split_status"], "deterministic")
        self.assertEqual(plan["provenance_status"], "partial")
        self.assertEqual(plan["destination_status"], "partial")
        self.assertEqual([unit["text"] for unit in plan["units"]], sentences)
        self.assertEqual(
            [unit["intended_subject"] for unit in plan["units"]],
            ["18", None, "19"],
        )
        self.assertTrue(plan["requires_human_review"])
        self.assertFalse(plan["publication_allowed"])
        self.assertTrue(plan["original_fragment_retained"])
        self.assertIn("unit_destination_unresolved", plan["blockers"])
        for unit in plan["units"]:
            self.assertEqual(unit["derived_from_fragment_id"], values["cc"]["fragment_id"])
            self.assertEqual(unit["evidence_refs"], [COMPOSITE_EVIDENCE_ID])
            self.assertEqual(unit["link_status"], "candidate")
            self.assertEqual(unit["provenance_status"], "candidate")
            self.assertTrue(unit["shared_composite_evidence"])

    def test_de81_action_units_recover_distinct_occurrence_provenance(self):
        registry, proposal, values = a007_composite_registry()
        plan = build_composite_split_plan(values["de"], proposal, registry)
        self.assertEqual(plan["split_status"], "deterministic")
        self.assertEqual(plan["provenance_status"], "recovered")
        self.assertEqual(plan["destination_status"], "resolved")
        subject_units = [unit for unit in plan["units"] if unit["role"] == "subject_content"]
        common_units = [unit for unit in plan["units"] if unit["role"] == "common"]
        self.assertEqual(
            [unit["intended_subject"] for unit in subject_units],
            ["18", None, "19"],
        )
        self.assertEqual(
            [unit["destination"] for unit in plan["units"]],
            [
                "discard_editorial_wrapper",
                "subject:18",
                "transverse_document_request",
                "subject:19",
                "metadata_only",
            ],
        )
        self.assertEqual(len(common_units), 2)
        self.assertIn("Aucun désaccord n'est signalé", common_units[1]["text"])
        self.assertEqual(
            [unit["evidence_refs"] for unit in subject_units],
            [[evidence_id] for evidence_id in ACTION_EVIDENCE_IDS],
        )
        self.assertTrue(all(unit["provenance_status"] == "candidate" for unit in subject_units))
        self.assertNotIn("action_provenance_unresolved", plan["blockers"])
        self.assertNotIn("unit_destination_unresolved", plan["blockers"])
        self.assertIn(
            "transverse_document_request_materialization_unavailable",
            plan["blockers"],
        )
        self.assertFalse(plan["publication_allowed"])

    def test_transverse_destination_requires_materialization_before_publication(self):
        units = [
            {
                "role": "subject_content",
                "destination": "subject:18",
                "provenance_status": "candidate",
                "evidence_refs": ["evidence-occurrence:" + "a" * 64],
                "shared_composite_evidence": False,
            },
            {
                "role": "subject_content",
                "destination": "transverse_document_request",
                "provenance_status": "candidate",
                "evidence_refs": ["evidence-occurrence:" + "b" * 64],
                "shared_composite_evidence": False,
            },
            {
                "role": "common",
                "destination": "metadata_only",
                "provenance_status": "unresolved",
                "evidence_refs": [],
                "shared_composite_evidence": False,
            },
        ]
        pending = composite_status_dimensions(
            units, "deterministic", human_review_recorded=True
        )
        ready = composite_status_dimensions(
            units,
            "deterministic",
            human_review_recorded=True,
            transverse_materialization_ready=True,
        )
        self.assertEqual(pending["destination_status"], "resolved")
        self.assertFalse(pending["publication_allowed"])
        self.assertTrue(ready["publication_allowed"])

    def test_f2cb_common_purpose_is_retained_and_bounded_rewrite_remains_required(self):
        registry, proposal, values = a007_composite_registry()
        plan = build_composite_split_plan(values["f2"], proposal, registry)
        self.assertEqual(plan["split_status"], "bounded_llm_required")
        self.assertEqual(plan["provenance_status"], "unresolved")
        self.assertEqual(plan["destination_status"], "partial")
        common_units = [unit for unit in plan["units"] if unit["role"] == "common"]
        self.assertEqual(len(common_units), 2)
        self.assertEqual(common_units[0]["text"], "Recommandation factuelle :")
        self.assertTrue(common_units[1]["text"].startswith("afin de poursuivre l'expertise"))
        self.assertIn("bounded_rewrite_required", plan["blockers"])
        self.assertEqual(
            [item["authority_text"] for item in plan["authority_rewrite_requirements"]],
            [
                "obtenir les coordonnées des occupants du 12 avenue de Girardin pour organiser une visite",
                "fournir des photographies détaillées du mur en béton côté 54 rue de Malleville",
                "fournir des documents techniques ou historiques relatifs à la construction du 15 avenue de Girardin",
            ],
        )
        self.assertFalse(plan["publication_allowed"])

    def test_f2cb_requires_explicit_approval_of_all_authority_rewrites(self):
        registry, proposal, values = a007_composite_registry()
        plan = build_composite_split_plan(values["f2"], proposal, registry)
        validation = authority_validation(
            plan,
            values["f2"],
            [plan["authority_rewrite_requirements"][0]["requirement_id"]],
        )
        Draft202012Validator(self.authority_validation_schema).validate(validation)
        with self.assertRaisesRegex(ValueError, "authority_rewrite_approval_incomplete"):
            resolve_authority_rewrite_plan(
                values["f2"], proposal, registry, validation
            )

    def test_f2cb_validated_authority_rewrite_is_deterministic_and_recovered(self):
        registry, proposal, values = a007_composite_registry()
        base_plan = build_composite_split_plan(values["f2"], proposal, registry)
        validation = authority_validation(base_plan, values["f2"])
        Draft202012Validator(self.authority_validation_schema).validate(validation)
        plan = resolve_authority_rewrite_plan(
            values["f2"], proposal, registry, validation
        )
        self.assertEqual(plan["split_status"], "deterministic")
        self.assertEqual(plan["provenance_status"], "recovered")
        self.assertEqual(plan["destination_status"], "resolved")
        self.assertFalse(plan["publication_allowed"])
        self.assertNotIn("bounded_rewrite_required", plan["blockers"])
        self.assertEqual(
            [item["destination"] for item in plan["units"]],
            [
                "discard_editorial_wrapper",
                "subject:18",
                "transverse_document_request",
                "subject:19",
                "metadata_only",
            ],
        )
        self.assertEqual(
            [item["evidence_refs"] for item in plan["units"] if item["role"] == "subject_content"],
            [[evidence_id] for evidence_id in ACTION_EVIDENCE_IDS],
        )

    def test_f2cb_document_unit_is_deduplicated_before_insertion_against_de81(self):
        registry, proposal, values = a007_composite_registry()
        de_plan = build_composite_split_plan(values["de"], proposal, registry)
        base_f2 = build_composite_split_plan(values["f2"], proposal, registry)
        f2_plan = resolve_authority_rewrite_plan(
            values["f2"], proposal, registry,
            authority_validation(base_f2, values["f2"]),
        )
        de_unit = next(
            item for item in de_plan["units"] if item["destination"] == "subject:19"
        )
        f2_unit = next(
            item for item in f2_plan["units"] if item["destination"] == "subject:19"
        )
        global_doc = {
            "sujets": [
                {
                    "numero": 18,
                    "avis_participants": [],
                    "synthese_echanges": "Source.",
                    "conclusion_expert": "Conclusion source.",
                },
                {
                    "numero": 19,
                    "avis_participants": [],
                    "synthese_echanges": "Cible.",
                    "conclusion_expert": "Conclusion cible.",
                },
            ]
        }
        reconciliation_proposal = {
            "proposal_id": stable_id("proposal", "f2cb-deduplication"),
            "source_subject": "18",
            "target_subject": "19",
            "source_fragment_ids": [],
            "fragment_classifications": [],
        }
        additional_units = [
            {
                "unit_id": unit["unit_id"],
                "text": unit["text"],
                "destination": unit["destination"],
                "section": section,
                "evidence_occurrence_ids": unit["evidence_refs"],
                "authorized_evidence_occurrence_ids": unit["evidence_refs"],
                "source_fragment_ids": [unit["derived_from_fragment_id"]],
                "precedence": precedence,
            }
            for unit, section, precedence in (
                (de_unit, "synthese_echanges", 10),
                (f2_unit, "conclusion_expert", 20),
            )
        ]
        plan = build_reconciliation_plan(
            global_doc, registry, reconciliation_proposal,
            additional_units=additional_units,
        )
        self.assertEqual(len(plan["publishable_insertions"]), 1)
        self.assertEqual(plan["publishable_insertions"][0]["item_id"], de_unit["unit_id"])
        self.assertEqual(len(plan["exact_duplicate_operations"]), 1)
        self.assertEqual(
            plan["exact_duplicate_operations"][0]["suppressed_item_id"],
            f2_unit["unit_id"],
        )
        self.assertEqual(
            plan["exact_duplicate_operations"][0]["shared_evidence_occurrence_ids"],
            [ACTION_EVIDENCE_IDS[2]],
        )
        self.assertFalse(any(item["llm_eligible"] for item in plan["relations"]))

    def test_publication_requires_resolved_dimensions_and_recorded_human_review(self):
        units = [
            {
                "role": "subject_content", "intended_subject": subject,
                "destination": f"subject:{subject}",
                "provenance_status": "candidate", "evidence_refs": [evidence],
                "shared_composite_evidence": False,
            }
            for subject, evidence in (
                ("18", "evidence-occurrence:" + "a" * 64),
                ("19", "evidence-occurrence:" + "b" * 64),
            )
        ]
        pending = composite_status_dimensions(units, "deterministic")
        reviewed = composite_status_dimensions(
            units, "deterministic", human_review_recorded=True
        )
        bounded_pending = composite_status_dimensions(
            units, "bounded_llm_required", human_review_recorded=True
        )
        bounded_completed = composite_status_dimensions(
            units, "bounded_llm_completed", human_review_recorded=True
        )
        self.assertEqual(pending["provenance_status"], "recovered")
        self.assertEqual(pending["destination_status"], "resolved")
        self.assertFalse(pending["publication_allowed"])
        self.assertTrue(reviewed["publication_allowed"])
        self.assertFalse(bounded_pending["publication_allowed"])
        self.assertTrue(bounded_completed["publication_allowed"])

        unresolved_common = [
            *units,
            {
                "role": "common", "intended_subject": None,
                "destination": "unresolved",
                "provenance_status": "unresolved", "evidence_refs": [],
                "shared_composite_evidence": False,
            },
        ]
        reviewed_with_common = composite_status_dimensions(
            unresolved_common, "deterministic", human_review_recorded=True
        )
        self.assertFalse(reviewed_with_common["publication_allowed"])

    def test_unresolved_blocks_whole_proposal(self):
        (global_doc, _registry, _audit, _proposal, simple, _c, unresolved), _decisions, result = self.apply_fixture(
            simple_count=1, unresolved_count=1
        )
        self.assertEqual(result["global_by_sujet_3f"], global_doc)
        self.assertEqual(result["applied"]["status"], "blocked")
        operation = result["applied"]["operations"][0]
        self.assertEqual(operation["applied_fragment_ids"], [])
        self.assertEqual(operation["pending_simple_fragment_ids"], [simple[0]["fragment_id"]])
        self.assertEqual(
            operation["blocked_unresolved_fragment_ids"], [unresolved[0]["fragment_id"]]
        )

    def test_stale_hash_is_rejected_before_application(self):
        values = fixture()
        global_doc, registry, audit, proposal, simple, _c, _u = values
        decisions = decisions_for(
            global_doc, audit, proposal, [simple[0]["fragment_id"]]
        )
        decisions["source_global_hash"] = "f" * 64
        with self.assertRaisesRegex(StaleDecisionError, "global_by_sujet"):
            build_application(global_doc, registry, audit, decisions)

    def test_v1_registry_and_audit_lineage_is_rejected_as_stale(self):
        global_doc, registry, audit, proposal, simple, _c, _u = fixture()
        decisions = decisions_for(
            global_doc, audit, proposal, [simple[0]["fragment_id"]]
        )
        registry["schema"] = "pass3f.provenance.v1"
        with self.assertRaisesRegex(StaleDecisionError, "provenance registry schema"):
            build_application(global_doc, registry, audit, decisions)

    def test_double_execution_writes_identical_bytes(self):
        values = fixture(composite_count=1)
        global_doc, registry, audit, proposal, simple, _c, _u = values
        decisions = decisions_for(
            global_doc, audit, proposal, [item["fragment_id"] for item in simple]
        )
        first = build_application(global_doc, registry, audit, decisions)
        second = build_application(global_doc, registry, audit, decisions)
        with tempfile.TemporaryDirectory() as tmp:
            left = Path(tmp) / "left"
            right = Path(tmp) / "right"
            write_application(left, first)
            write_application(right, second)
            names = {
                "pass3f_application_plan.json",
                "pass3f_applied.json",
                "global_by_sujet_3f.json",
                "correction_manifest.json",
                "hashes.json",
            }
            self.assertEqual(
                {name: (left / name).read_bytes() for name in names},
                {name: (right / name).read_bytes() for name in names},
            )
            hashes = json.loads((left / "hashes.json").read_text(encoding="utf-8"))
            self.assertEqual(hashes["source_hashes"], first["applied"]["source_hashes"])

    def test_unaffected_subject_is_canonically_identical(self):
        (global_doc, _registry, _audit, _proposal, _s, _c, _u), _decisions, result = self.apply_fixture()
        self.assertEqual(
            result["global_by_sujet_3f"]["sujets"][2],
            global_doc["sujets"][2],
        )
        self.assertEqual(result["manifest"]["unaffected_subject_ids"], ["20"])

    def test_a007_applies_nine_simple_and_leaves_three_composites(self):
        pure_texts = [
            "Maison du 15 avenue de Girardin (occupée par M. P166 et Mme P167) : décrite comme une construction de la première moitié du XXe siècle en maçonnerie enduite et globalement bien entretenue. Sont relevés de petites fissures au niveau des murets de l'escalier et des soubassements.",
            "Dallage du 15 avenue de Girardin : signalé en mauvais état, cet état est attribué dans la synthèse aux variations du sous-sol. Cette explication est présentée comme l'interprétation des observations rapportées.",
            "Pour le 15 avenue de Girardin, la maison est décrite comme une construction en maçonnerie enduite de la première moitié du XXe siècle, globalement bien entretenue mais présentant de petites fissures sur les murets de l'escalier et les soubassements, ainsi qu'un dallage en mauvais état attribué aux variations du sous-sol. Ces constats, tels que fournis, indiquent des désordres localisés et une pathologie possible liée au sous-sol, mais ne permettent pas d'établir un diagnostic précis ni l'origine exacte sans documents techniques/historiques et investigations complémentaires.",
            "Fournir des documents techniques ou historiques relatifs à la construction du 15 avenue de Girardin",
            "Maison du 15 avenue de Girardin datant de la première moitié du XXe siècle",
            "Documents techniques ou historiques relatifs à la construction du 15 avenue de Girardin",
            "Petites fissures sur les murets de l'escalier et soubassements du 15 avenue de Girardin",
            "occupante (15 avenue de Girardin)",
            "occupant (15 avenue de Girardin)",
        ]
        composite_texts = [
            "La maison du 12 avenue de Girardin n'a pas pu être visitée en raison de l'absence des occupants et du retour du courrier recommandé non retiré. Le mur en béton côté rue de Malleville présente des déformations, fissures et une fragilité avancée visibles depuis l'extérieur. La maison du 15 avenue de Girardin, occupée par M. P166 et Mme P167, est une construction de la première moitié du XXe siècle en maçonnerie enduite, bien entretenue mais avec de petites fissures au niveau des murets de l'escalier et des soubassements, ainsi qu'un dallage en mauvais état attribué aux variations du sous-sol.",
            "Actions et demandes de documents identifiées : obtenir les coordonnées des occupants du 12 avenue de Girardin pour organiser une visite, fournir des photographies détaillées du mur en béton côté 54 rue de Malleville, et fournir des documents techniques ou historiques relatifs à la construction du 15 avenue de Girardin. Aucun désaccord n'est signalé dans la synthèse fournie.",
            "Recommandation factuelle : obtenir les coordonnées des occupants du 12 avenue de Girardin pour organiser la visite intérieure, recueillir les photographies détaillées du mur en béton côté 54 rue de Malleville et rassembler les documents techniques ou historiques relatifs à la construction du 15 avenue de Girardin afin de poursuivre l'expertise et permettre des conclusions techniques motivées.",
        ]
        global_doc, registry, audit, proposal, _simple, _composite, _unresolved = fixture(
            simple_count=0
        )
        simple = [fragment("18", text, index) for index, text in enumerate(pure_texts)]
        composite = [
            fragment("18", text, len(simple) + index)
            for index, text in enumerate(composite_texts)
        ]
        registry["derived_fragments"] = simple + composite
        global_doc["sujets"][0]["synthese_echanges"] = "\n\n".join(pure_texts + composite_texts)
        proposal["source_fragment_ids"] = [item["fragment_id"] for item in simple]
        proposal["composite_fragment_ids"] = [item["fragment_id"] for item in composite]
        proposal["unresolved_fragment_ids"] = []
        audit["source_registry_hash"] = stable_id("registry", registry)
        decisions = decisions_for(
            global_doc, audit, proposal, proposal["source_fragment_ids"]
        )
        result = build_application(global_doc, registry, audit, decisions)
        operation = result["applied"]["operations"][0]
        source, target, _witness = result["global_by_sujet_3f"]["sujets"]
        self.assertEqual(len(operation["applied_fragment_ids"]), 9)
        self.assertEqual(len(operation["pending_composite_fragment_ids"]), 3)
        self.assertEqual(operation["blocked_unresolved_fragment_ids"], [])
        self.assertEqual(operation["status"], "partially_applied")
        self.assertEqual(source["synthese_echanges"].split("\n\n"), composite_texts)
        self.assertNotIn("12 avenue", target["synthese_echanges"])
        self.assertNotIn("rue de Malleville", target["synthese_echanges"])
        self.assertTrue(all(text in target["synthese_echanges"] for text in pure_texts))

    def test_rollback_is_reconstruction_from_original_with_rejected_decision(self):
        values = fixture()
        global_doc, registry, audit, proposal, _simple, _c, _u = values
        rejected = decisions_for(global_doc, audit, proposal, [], value="rejected")
        rebuilt = build_application(global_doc, registry, audit, rejected)
        self.assertEqual(rebuilt["global_by_sujet_3f"], global_doc)
        self.assertEqual(
            rebuilt["manifest"]["rollback"]["method"],
            "rebuild_from_immutable_source",
        )


if __name__ == "__main__":
    unittest.main()
