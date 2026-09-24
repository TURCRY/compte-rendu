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
from pass3f_provenance import stable_id  # noqa: E402


DECISIONS_SCHEMA = ROOT / "pipeline" / "schemas" / "pass3f_decisions.v1.schema.json"
APPLIED_SCHEMA = ROOT / "pipeline" / "schemas" / "pass3f_applied.v2.schema.json"


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
        self.assertIn(composite[0]["text"], global_doc["sujets"][0]["synthese_echanges"])

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
