import copy
import json
import sys
import tempfile
import unittest
from pathlib import Path

from jsonschema import Draft202012Validator


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "pipeline" / "python"))

from pass3f_composite_apply import (  # noqa: E402
    build_composite_application,
    composite_validation_identifier,
    document_hash,
    evidence_occurrences_hash,
    write_composite_application,
)
from pass3f_composites import build_composite_split_plan  # noqa: E402
from pass3f_provenance import stable_id  # noqa: E402
from pass3f_transverse import build_transverse_artifact  # noqa: E402


VALIDATIONS_SCHEMA = ROOT / "pipeline" / "schemas" / "pass3f_composite_validations.v1.schema.json"
APPLIED_SCHEMA = ROOT / "pipeline" / "schemas" / "pass3f_composite_applied.v1.schema.json"
RUN_ID = stable_id("run", "de81b9-composite-application")
PROPOSAL_ID = stable_id("proposal", "de81b9-composite-application")
DECISION_ID = stable_id("decision", "de81b9-composite-application")
EVIDENCE_IDS = [
    "evidence-occurrence:" + prefix + "0" * (64 - len(prefix))
    for prefix in ("0a551a", "5cc44b", "ae91fd")
]
ACTION_TEXTS = [
    "obtenir les coordonnées des occupants du 12 avenue de Girardin pour organiser une visite",
    "fournir des photographies détaillées du mur en béton côté 54 rue de Malleville",
    "fournir des documents techniques ou historiques relatifs à la construction du 15 avenue de Girardin",
]
COMPOSITE_TEXT = (
    "Actions et demandes de documents identifiées : obtenir les coordonnées des occupants "
    "du 12 avenue de Girardin pour organiser une visite, fournir des photographies détaillées "
    "du mur en béton côté 54 rue de Malleville, et fournir des documents techniques ou "
    "historiques relatifs à la construction du 15 avenue de Girardin. Aucun désaccord n'est "
    "signalé dans la synthèse fournie."
)


def fragment(text, index, *, stage="3E"):
    payload = {
        "stage": stage,
        "subject_id": "18",
        "field_path": f"/synthese_echanges/{index}",
        "text": text,
        "source_artifact": f"fixture/{stage.lower()}-{index}.json",
    }
    return {
        "fragment_id": stable_id("fragment", payload),
        **payload,
        "links": [],
        "truncation": {"status": "none"},
    }


def fixture():
    composite = fragment(COMPOSITE_TEXT, 0)
    neighbors = [fragment(text, index + 1, stage="2E") for index, text in enumerate(ACTION_TEXTS)]
    for item, evidence_id in zip(neighbors, EVIDENCE_IDS):
        item["links"] = [{
            "evidence_occurrence_id": evidence_id,
            "link_status": "candidate",
            "method": "token_overlap",
            "score": 0.8,
        }]
    global_source = {
        "sujets": {
            "18": [
                {"texte": text, "origine": "debrief_expert", "segment_id": "debrief"}
                for text in ACTION_TEXTS
            ]
        }
    }
    evidence = [
        {
            "evidence_occurrence_id": evidence_id,
            "source_pointers": [f"/sujets/18/{index}"],
            "exact_text": text,
        }
        for index, (evidence_id, text) in enumerate(zip(EVIDENCE_IDS, ACTION_TEXTS))
    ]
    registry = {
        "schema": "pass3f.provenance.v2",
        "run": {"run_id": RUN_ID},
        "subjects": [
            {"subject_id": "18", "title": "12 avenue de Girardin", "location": ""},
            {"subject_id": "19", "title": "15 avenue de Girardin", "location": ""},
        ],
        "evidence": evidence,
        "derived_fragments": [composite, *neighbors],
    }
    proposal = {
        "proposal_id": PROPOSAL_ID,
        "source_subject": "18",
        "target_subject": "19",
        "composite_fragment_ids": [composite["fragment_id"]],
    }
    plan = build_composite_split_plan(composite, proposal, registry)
    global_doc = {
        "sujets": [
            {
                "numero": 18,
                "titre": "12 avenue de Girardin",
                "synthese_echanges": "Contexte S18.\n\n" + COMPOSITE_TEXT,
                "conclusion_expert": "Conclusion S18.",
            },
            {
                "numero": 19,
                "titre": "15 avenue de Girardin",
                "synthese_echanges": "Contexte S19.",
                "conclusion_expert": "Conclusion S19.",
            },
            {
                "numero": 20,
                "titre": "Sujet témoin",
                "synthese_echanges": "Contenu témoin.",
                "conclusion_expert": "Conclusion témoin.",
            },
        ]
    }
    decision = {
        "decision_id": DECISION_ID,
        "proposal_id": PROPOSAL_ID,
        "decision": "accepted",
        "reviewer": "reviewer-fixture",
        "reason": "Proposition et plan composite validés.",
    }
    decisions = {
        "schema": "pass3f.decisions.v1",
        "run_id": RUN_ID,
        "decisions": [decision],
    }
    applied = {
        "schema": "pass3f.applied.v2",
        "application_id": stable_id("application", "de81b9-b1"),
        "run_id": RUN_ID,
        "source_hashes": {
            "provenance_registry": document_hash(registry),
            "decisions": document_hash(decisions),
        },
        "operations": [{
            "proposal_id": PROPOSAL_ID,
            "decision_id": DECISION_ID,
            "source_subject": "18",
            "composite_split_plans": [plan],
        }],
    }
    manifest = {
        "schema": "pass3f.correction_manifest.v1",
        "composite_split_plans": [copy.deepcopy(plan)],
        "changes": [],
    }
    global_final = {
        "demandes_documents_globales": [{
            "numero": 18,
            "objet": "Photographies détaillées du mur en béton côté 54 rue de Malleville",
            "commentaire": None,
            "origine": "reunion",
        }]
    }
    transverse = build_transverse_artifact(
        global_final, global_source, registry, applied, decisions
    )
    source_hashes = {
        "global_by_sujet": document_hash(global_doc),
        "provenance_registry": document_hash(registry),
        "pass3f_applied": document_hash(applied),
        "correction_manifest": document_hash(manifest),
        "transverse_units": document_hash(transverse),
    }
    evidence_ids = sorted({
        evidence_id
        for unit in plan["units"]
        for evidence_id in unit.get("evidence_refs") or []
    })
    transverse_unit = transverse["units"][0]
    validation = {
        "proposal_id": PROPOSAL_ID,
        "split_plan_id": plan["split_plan_id"],
        "split_plan_hash": document_hash(plan),
        "fragment_id": composite["fragment_id"],
        "fragment_hash": document_hash(composite),
        "evidence_occurrence_ids": evidence_ids,
        "evidence_occurrences_hash": evidence_occurrences_hash(evidence_ids, registry),
        "unit_dispositions": [{
            "unit_id": unit["unit_id"],
            "destination": unit["destination"],
            "unit_hash": document_hash(unit),
        } for unit in plan["units"]],
        "transverse_reconciliations": [{
            "unit_id": transverse_unit["unit_id"],
            "materialization_status": "reuse_existing",
            "existing_match_hash": document_hash(transverse_unit["existing_match"]),
        }],
        "decision": "accepted",
        "reviewer": "reviewer-composite-fixture",
        "reason": "Les cinq dispositions de de81b9 sont validées.",
    }
    validation["validation_id"] = composite_validation_identifier(validation)
    validations = {
        "schema": "pass3f.composite_validations.v1",
        "run_id": RUN_ID,
        "source_hashes": source_hashes,
        "validations": [validation],
    }
    return {
        "global": global_doc,
        "registry": registry,
        "applied": applied,
        "manifest": manifest,
        "transverse": transverse,
        "validations": validations,
        "plan": plan,
        "fragment": composite,
    }


class Pass3FCompositeApplyTest(unittest.TestCase):
    def setUp(self):
        self.validation_schema = json.loads(VALIDATIONS_SCHEMA.read_text(encoding="utf-8"))
        self.applied_schema = json.loads(APPLIED_SCHEMA.read_text(encoding="utf-8"))

    def run_fixture(self, values=None):
        values = values or fixture()
        Draft202012Validator(self.validation_schema).validate(values["validations"])
        result = build_composite_application(
            values["global"], values["registry"], values["applied"],
            values["manifest"], values["transverse"], values["validations"],
        )
        Draft202012Validator(self.applied_schema).validate(result["applied"])
        return values, result

    def test_de81b9_fully_applies_all_five_validated_dispositions(self):
        source_values = fixture()
        transverse_before = copy.deepcopy(source_values["transverse"])
        values, result = self.run_fixture(source_values)
        self.assertEqual(result["applied"]["status"], "fully_applied")
        source, target, witness = result["global_by_sujet_3f"]["sujets"]
        self.assertNotIn(COMPOSITE_TEXT, source["synthese_echanges"])
        self.assertEqual(source["synthese_echanges"].count(ACTION_TEXTS[0]), 1)
        self.assertEqual(target["synthese_echanges"].count(ACTION_TEXTS[2]), 1)
        self.assertNotIn(ACTION_TEXTS[1], source["synthese_echanges"])
        self.assertNotIn(ACTION_TEXTS[1], target["synthese_echanges"])
        self.assertEqual(witness, values["global"]["sujets"][2])

        application = result["manifest"]["composite_applications"][0]
        self.assertEqual(application["original_fragment"]["text"], COMPOSITE_TEXT)
        self.assertEqual(
            [unit["destination"] for unit in application["unit_dispositions"]],
            [
                "discard_editorial_wrapper", "subject:18",
                "transverse_document_request", "subject:19", "metadata_only",
            ],
        )
        metadata = next(
            unit for unit in application["unit_dispositions"]
            if unit["destination"] == "metadata_only"
        )
        self.assertIn("Aucun désaccord", metadata["text"])
        self.assertEqual(
            application["transverse_reconciliations"][0]["materialization_status"],
            "reuse_existing",
        )
        self.assertEqual(values["transverse"], transverse_before)
        self.assertEqual(len(values["transverse"]["units"]), 1)
        self.assertTrue(all(result["applied"]["controls"].values()))

    def test_missing_human_validation_blocks_and_preserves_original(self):
        values = fixture()
        values["validations"]["validations"] = []
        _values, result = self.run_fixture(values)
        self.assertEqual(result["applied"]["status"], "blocked")
        self.assertIn(
            "human_validation_missing", result["applied"]["operations"][0]["blockers"]
        )
        self.assertIn(COMPOSITE_TEXT, result["global_by_sujet_3f"]["sujets"][0]["synthese_echanges"])

    def test_changed_plan_blocks_application(self):
        values = fixture()
        values["applied"]["operations"][0]["composite_split_plans"][0]["units"][1]["text"] += " modifié"
        _values, result = self.run_fixture(values)
        blockers = result["applied"]["operations"][0]["blockers"]
        self.assertIn("split_plan_changed", blockers)
        self.assertEqual(result["applied"]["status"], "blocked")

    def test_changed_evidence_occurrence_blocks_application(self):
        values = fixture()
        values["registry"]["evidence"][1]["exact_text"] += " modifié"
        _values, result = self.run_fixture(values)
        self.assertIn(
            "evidence_occurrences_changed",
            result["applied"]["operations"][0]["blockers"],
        )

    def test_transverse_reuse_becoming_ambiguous_or_absent_blocks(self):
        for status, found in (("ambiguous_existing_match", True), ("absent", False)):
            with self.subTest(status=status):
                values = fixture()
                unit = values["transverse"]["units"][0]
                unit["existing_match"]["status"] = status
                unit["existing_match"]["found"] = found
                unit["materialization_status"] = (
                    "blocked_ambiguous" if found else "prepare_new"
                )
                _values, result = self.run_fixture(values)
                self.assertEqual(result["applied"]["status"], "blocked")
                self.assertIn(
                    "transverse_match_changed",
                    result["applied"]["operations"][0]["blockers"],
                )

    def test_unresolved_unit_blocks_application(self):
        values = fixture()
        plan = values["applied"]["operations"][0]["composite_split_plans"][0]
        plan["units"][2]["destination"] = "unresolved"
        plan["destination_status"] = "partial"
        _values, result = self.run_fixture(values)
        blockers = result["applied"]["operations"][0]["blockers"]
        self.assertIn("unit_destination_unresolved", blockers)
        self.assertEqual(result["applied"]["status"], "blocked")

    def test_output_is_byte_stable_for_identical_inputs(self):
        values = fixture()
        first = self.run_fixture(values)[1]
        second = self.run_fixture(values)[1]
        self.assertEqual(first, second)
        with tempfile.TemporaryDirectory() as tmp:
            left = Path(tmp) / "left"
            right = Path(tmp) / "right"
            write_composite_application(left, first)
            write_composite_application(right, second)
            for name in (
                "pass3f_composite_applied.json",
                "global_by_sujet_3f.json",
                "correction_manifest.json",
            ):
                self.assertEqual((left / name).read_bytes(), (right / name).read_bytes())


if __name__ == "__main__":
    unittest.main()
