import json
import sys
import unittest
from pathlib import Path

from jsonschema import Draft202012Validator


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "pipeline" / "python"))
SCHEMA = ROOT / "pipeline" / "schemas" / "pass3f_reconciliation_plan.v1.schema.json"

from pass3f_provenance import fragment_representation_type  # noqa: E402
from pass3f_reconciliation import build_reconciliation_plan  # noqa: E402


EVIDENCE_COMPOSITE = "evidence-occurrence:" + "5" * 64
EVIDENCE_DOCUMENTS = "evidence-occurrence:" + "a" * 64


def _fragment(fragment_id, stage, field_path, text, links):
    return {
        "fragment_id": fragment_id,
        "stage": stage,
        "subject_id": "18",
        "field_path": field_path,
        "text": text,
        "source_artifact": "fixture.json",
        "representation_type": fragment_representation_type(stage, field_path),
        "structure_algorithm": "pass3f.fragment-structure.v1",
        "links": links,
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


def fixture():
    house = (
        "Maison du 15 avenue de Girardin (occupée par M. P166 et Mme P167) : "
        "décrite comme une construction de la première moitié du XXe siècle en "
        "maçonnerie enduite et globalement bien entretenue. Sont relevés de petites "
        "fissures au niveau des murets de l'escalier et des soubassements."
    )
    paving = (
        "Dallage du 15 avenue de Girardin : signalé en mauvais état, cet état est "
        "attribué dans la synthèse aux variations du sous-sol. Cette explication est "
        "présentée comme l'interprétation des observations rapportées."
    )
    conclusion = (
        "Pour le 15 avenue de Girardin, la maison est décrite comme une construction "
        "en maçonnerie enduite de la première moitié du XXe siècle, globalement bien "
        "entretenue mais présentant de petites fissures sur les murets de l'escalier "
        "et les soubassements, ainsi qu'un dallage en mauvais état attribué aux "
        "variations du sous-sol. Ces constats, tels que fournis, indiquent des "
        "désordres localisés et une pathologie possible liée au sous-sol, mais ne "
        "permettent pas d'établir un diagnostic précis ni l'origine exacte sans "
        "documents techniques/historiques et investigations complémentaires."
    )
    links_candidate = [{
        "evidence_occurrence_id": EVIDENCE_COMPOSITE,
        "link_status": "candidate",
        "method": "token_overlap",
        "score": 0.8,
    }]
    links_unresolved = [{
        "evidence_occurrence_id": None,
        "link_status": "unresolved",
        "method": "none",
        "score": 0.0,
    }]
    fragments = [
        _fragment("fragment:" + "1" * 64, "3E", "/synthese_echanges/2", house, links_candidate),
        _fragment("fragment:" + "2" * 64, "3E", "/synthese_echanges/3", paving, links_unresolved),
        _fragment("fragment:" + "3" * 64, "3E", "/conclusion_expert/2", conclusion, links_unresolved),
    ]
    projection_ids = []
    for index, path in enumerate((
        "/synthese_intermediaire/actions/2/0",
        "/synthese_intermediaire/points_cles/2/0",
        "/synthese_intermediaire/documents_demandes/2/0",
        "/synthese_intermediaire/points_cles/3/0",
    ), 4):
        fragment_id = "fragment:" + str(index) * 64
        projection_ids.append(fragment_id)
        fragments.append(_fragment(
            fragment_id, "2E", path, f"Projection {index} du 15 avenue de Girardin",
            links_candidate,
        ))
    participant_ids = []
    for index, participant_index in ((8, 2), (9, 3)):
        fragment_id = "fragment:" + str(index) * 64
        participant_ids.append(fragment_id)
        fragments.append(_fragment(
            fragment_id,
            "3E",
            f"/avis_participants/{participant_index}/role/0",
            "occupant (15 avenue de Girardin)",
            [
                *links_candidate,
                {
                    "evidence_occurrence_id": EVIDENCE_DOCUMENTS,
                    "link_status": "candidate",
                    "method": "token_overlap",
                    "score": 0.75,
                },
            ],
        ))
    global_doc = {
        "sujets": [
            {
                "numero": 18,
                "avis_participants": [
                    {"nom": "P31", "role": "propriétaire", "resume": ""},
                    {"nom": "P32", "role": "propriétaire", "resume": ""},
                    {"nom": "P166", "role": "occupant (15 avenue de Girardin)", "resume": ""},
                    {"nom": "P167", "role": "occupante (15 avenue de Girardin)", "resume": ""},
                ],
                "synthese_echanges": "\n\n".join([house, paving]),
                "conclusion_expert": conclusion,
            },
            {
                "numero": 19,
                "avis_participants": [],
                "synthese_echanges": "Aucun élément relatif à ce point n’a été identifié dans les échanges analysés.",
                "conclusion_expert": (
                    "En l’absence d’échanges ou d’éléments fournis relatifs à ce point, "
                    "il n’est pas possible de formuler un état descriptif technique du "
                    "bien situé 15 avenue de Girardin (parcelle AE6). Aucune conclusion "
                    "matérielle ou technique ne peut être tirée à partir des éléments "
                    "d’audience disponibles.\n\n"
                    "Pour permettre l’établissement d’un état descriptif technique, il "
                    "conviendrait de compléter le dossier par des investigations et "
                    "documents complémentaires. À défaut, l’expertise devra rester réservée."
                ),
            },
        ]
    }
    classifications = [
        {
            "fragment_id": item["fragment_id"],
            "representation_type": item["representation_type"],
            "content_shape": "atomic",
            "operation_disposition": (
                "publishable_move"
                if item["representation_type"] == "publishable_text_unit"
                else "manifest_only"
                if item["representation_type"] == "provenance_projection"
                else "structured_parent_required"
            ),
        }
        for item in fragments
    ]
    proposal = {
        "proposal_id": "proposal:" + "f" * 64,
        "source_subject": "18",
        "target_subject": "19",
        "source_fragment_ids": [item["fragment_id"] for item in fragments[:3]],
        "composite_fragment_ids": [],
        "unresolved_fragment_ids": [],
        "fragment_classifications": classifications,
    }
    registry = {
        "schema": "pass3f.provenance.v2",
        "run": {"run_id": "run:" + "1" * 64, "pipeline_kind": "generaliste", "input_hashes": {}},
        "subjects": [],
        "evidence": [
            {
                "evidence_occurrence_id": EVIDENCE_COMPOSITE,
                "exact_text": (
                    "La maison du 15 avenue de Girardin, occupée par M. P166 et Mme P167, "
                    "présente de petites fissures et un dallage en mauvais état."
                ),
            },
            {
                "evidence_occurrence_id": EVIDENCE_DOCUMENTS,
                "exact_text": "Documents techniques relatifs au 15 avenue de Girardin.",
            },
        ],
        "truncation_events": [],
        "derived_fragments": fragments,
        "stats": {},
    }
    additional_units = [
        {
            "unit_id": "composite-unit:" + "d" * 64,
            "text": "Fournir des documents techniques ou historiques relatifs à la construction du 15 avenue de Girardin",
            "destination": "subject:19",
            "section": "synthese_echanges",
            "evidence_occurrence_ids": [EVIDENCE_DOCUMENTS],
            "authorized_evidence_occurrence_ids": [EVIDENCE_DOCUMENTS],
            "source_fragment_ids": ["fragment:" + "d" * 64],
            "precedence": 10,
        },
        {
            "unit_id": "composite-unit:" + "e" * 64,
            "text": "Fournir des documents techniques ou historiques relatifs à la construction du 15 avenue de Girardin",
            "destination": "subject:19",
            "section": "conclusion_expert",
            "evidence_occurrence_ids": [EVIDENCE_DOCUMENTS],
            "authorized_evidence_occurrence_ids": [EVIDENCE_DOCUMENTS],
            "source_fragment_ids": ["fragment:" + "e" * 64],
            "precedence": 20,
        },
    ]
    return global_doc, registry, proposal, projection_ids, participant_ids, additional_units


class Pass3FReconciliationTest(unittest.TestCase):
    def test_structural_typology_distinguishes_publishable_projection_and_subfield(self):
        self.assertEqual(
            fragment_representation_type("3E", "/synthese_echanges/2"),
            "publishable_text_unit",
        )
        self.assertEqual(
            fragment_representation_type("2E", "/synthese_intermediaire/actions/0"),
            "provenance_projection",
        )
        self.assertEqual(
            fragment_representation_type("3E", "/avis_participants/2/role/0"),
            "participant_subfield",
        )

    def test_a007_plan_excludes_projections_moves_objects_and_removes_false_placeholders(self):
        global_doc, registry, proposal, projection_ids, _participant_ids, units = fixture()
        plan = build_reconciliation_plan(
            global_doc, registry, proposal, additional_units=units
        )
        Draft202012Validator(json.loads(SCHEMA.read_text(encoding="utf-8"))).validate(plan)
        self.assertEqual(plan["excluded_provenance_projection_ids"], sorted(projection_ids))
        self.assertEqual(len(plan["publishable_insertions"]), 4)
        self.assertEqual(len(plan["exact_duplicate_operations"]), 1)
        self.assertEqual(
            plan["exact_duplicate_operations"][0]["kept_item_id"],
            "composite-unit:" + "d" * 64,
        )
        self.assertEqual(len(plan["placeholder_operations"]), 2)
        self.assertTrue(any(
            item["classification"] == "contradiction"
            and item["operation"] == "remove_placeholder"
            for item in plan["relations"]
        ))
        target = plan["simulated_target"]
        self.assertNotIn("Aucun élément relatif", target["synthese_echanges"])
        self.assertNotIn("En l’absence d’échanges", target["conclusion_expert"])
        self.assertIn("Pour permettre l’établissement", target["conclusion_expert"])
        self.assertEqual([item["nom"] for item in target["avis_participants"]], ["P166", "P167"])
        self.assertTrue(all(
            item["status"] == "ready_for_human_validation"
            for item in plan["participant_operations"]
        ))
        self.assertTrue(all(
            item["deterministic_evidence_occurrence_ids"] == [EVIDENCE_COMPOSITE]
            for item in plan["participant_operations"]
        ))
        self.assertTrue(all(
            item["excluded_candidate_evidence_occurrence_ids"] == [EVIDENCE_DOCUMENTS]
            for item in plan["participant_operations"]
        ))

    def test_no_projection_is_materialized_and_no_semantic_merge_is_llm_ready(self):
        global_doc, registry, proposal, projection_ids, _participant_ids, units = fixture()
        plan = build_reconciliation_plan(
            global_doc, registry, proposal, additional_units=units
        )
        inserted_ids = {item["item_id"] for item in plan["publishable_insertions"]}
        self.assertFalse(inserted_ids & set(projection_ids))
        merge_relations = [
            item for item in plan["relations"]
            if item["operation"] == "merge_required"
        ]
        self.assertTrue(all(not item["llm_eligible"] for item in plan["relations"]))
        self.assertTrue(all(
            "provenance_not_authorized" in item["blockers"]
            for item in merge_relations
        ))

    def test_existing_participant_object_is_not_duplicated(self):
        global_doc, registry, proposal, _projection_ids, _participant_ids, units = fixture()
        global_doc["sujets"][1]["avis_participants"].append(
            global_doc["sujets"][0]["avis_participants"][2].copy()
        )
        plan = build_reconciliation_plan(
            global_doc, registry, proposal, additional_units=units
        )
        operations = {item["participant"]["nom"]: item for item in plan["participant_operations"]}
        self.assertEqual(operations["P166"]["status"], "duplicate_target_object")
        self.assertEqual(
            [item["nom"] for item in plan["simulated_target"]["avis_participants"]].count("P166"),
            1,
        )


if __name__ == "__main__":
    unittest.main()
