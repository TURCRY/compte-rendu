import copy
import json
import sys
import tempfile
import unittest
from pathlib import Path

from jsonschema import Draft202012Validator


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "pipeline" / "python"))

from pass3f_provenance import stable_id  # noqa: E402
from pass3f_transverse import (  # noqa: E402
    build_transverse_artifact,
    document_hash,
    normalize_request_object,
    write_transverse_artifact,
)


SCHEMA = ROOT / "pipeline" / "schemas" / "pass3f_transverse.v1.schema.json"
RUN_ID = stable_id("run", "pass3f-transverse-fixture")
PROPOSAL_ID = stable_id("proposal", "pass3f-transverse-fixture")
DECISION_ID = stable_id("decision", "pass3f-transverse-fixture")
FRAGMENT_ID = stable_id("fragment", "de81b9-transverse")
UNIT_ID = stable_id("composite-unit", "de81b9-transverse")
EVIDENCE_ID = "evidence-occurrence:" + "5cc44b" + "0" * 58
REQUEST_TEXT = (
    "fournir des photographies détaillées du mur en béton côté 54 rue de Malleville"
)
EXISTING_OBJECT = (
    "Photographies détaillées du mur en béton côté 54 rue de Malleville"
)


def fixture(existing_requests):
    global_final = {
        "sujets": [],
        "demandes_documents_globales": copy.deepcopy(existing_requests),
    }
    global_source = {
        "sujets": {
            "18": [
                {"texte": "contexte 1"},
                {"texte": "contexte 2"},
                {
                    "segment_id": "debrief",
                    "texte": "Demande de document (débrief) : " + EXISTING_OBJECT,
                    "origine": "debrief_expert",
                },
            ]
        }
    }
    registry = {
        "schema": "pass3f.provenance.v2",
        "run": {"run_id": RUN_ID},
        "evidence": [{
            "evidence_occurrence_id": EVIDENCE_ID,
            "source_pointers": ["/sujets/18/2"],
        }],
    }
    decisions = {
        "schema": "pass3f.decisions.v1",
        "run_id": RUN_ID,
        "decisions": [{
            "decision_id": DECISION_ID,
            "proposal_id": PROPOSAL_ID,
            "decision": "accepted",
            "reviewer": "reviewer-fixture",
            "reason": "Demande transverse validée.",
        }],
    }
    applied = {
        "schema": "pass3f.applied.v2",
        "run_id": RUN_ID,
        "source_hashes": {
            "provenance_registry": document_hash(registry),
            "decisions": document_hash(decisions),
        },
        "operations": [{
            "proposal_id": PROPOSAL_ID,
            "decision_id": DECISION_ID,
            "source_subject": "18",
            "composite_split_plans": [{
                "units": [{
                    "unit_id": UNIT_ID,
                    "text": REQUEST_TEXT,
                    "derived_from_fragment_id": FRAGMENT_ID,
                    "evidence_refs": [EVIDENCE_ID],
                    "destination": "transverse_document_request",
                }],
            }],
        }],
    }
    return global_final, global_source, registry, applied, decisions


class Pass3FTransverseTest(unittest.TestCase):
    def setUp(self):
        self.schema = json.loads(SCHEMA.read_text(encoding="utf-8"))

    def build(self, existing_requests):
        values = fixture(existing_requests)
        artifact = build_transverse_artifact(*values)
        Draft202012Validator(self.schema).validate(artifact)
        return values, artifact

    def test_existing_unique_match_reuses_entry(self):
        entry = {
            "numero": 18,
            "objet": EXISTING_OBJECT,
            "origine": "reunion",
            "commentaire": None,
        }
        (_inputs, artifact) = self.build([entry])
        unit = artifact["units"][0]
        self.assertEqual(unit["existing_match"]["status"], "unique")
        self.assertTrue(unit["existing_match"]["found"])
        self.assertEqual(unit["existing_match"]["matched_entry"], entry)
        self.assertEqual(unit["materialization_status"], "reuse_existing")
        self.assertIsNone(unit["prepared_entry"])
        self.assertEqual(artifact["stats"]["existing_unique_count"], 1)

    def test_absent_match_prepares_but_does_not_publish_entry(self):
        (inputs, artifact) = self.build([])
        global_final = inputs[0]
        unit = artifact["units"][0]
        self.assertEqual(unit["existing_match"]["status"], "absent")
        self.assertFalse(unit["existing_match"]["found"])
        self.assertEqual(unit["materialization_status"], "prepare_new")
        self.assertEqual(unit["prepared_entry"]["objet"], REQUEST_TEXT)
        self.assertEqual(global_final["demandes_documents_globales"], [])

    def test_multiple_existing_matches_are_ambiguous_and_blocked(self):
        entries = [
            {"objet": EXISTING_OBJECT, "origine": "reunion"},
            {"objet": EXISTING_OBJECT.upper(), "origine": "debrief_expert"},
        ]
        (_inputs, artifact) = self.build(entries)
        unit = artifact["units"][0]
        self.assertEqual(
            unit["existing_match"]["status"], "ambiguous_existing_match"
        )
        self.assertEqual(unit["existing_match"]["match_indexes"], [0, 1])
        self.assertEqual(unit["materialization_status"], "blocked_ambiguous")
        self.assertFalse(unit["automatic_materialization_allowed"])
        self.assertIsNone(unit["prepared_entry"])

    def test_comment_and_origin_do_not_change_object_identity(self):
        entry = {
            "objet": EXISTING_OBJECT,
            "origine": "reunion",
            "commentaire": "Texte différent de la provenance 3F.",
        }
        (_inputs, artifact) = self.build([entry])
        unit = artifact["units"][0]
        self.assertEqual(unit["materialization_status"], "reuse_existing")
        self.assertEqual(
            normalize_request_object(REQUEST_TEXT),
            normalize_request_object(entry["objet"]),
        )

    def test_output_is_byte_stable_and_rollback_only_discards_sidecar(self):
        values = fixture([])
        snapshots = copy.deepcopy(values)
        first = build_transverse_artifact(*values)
        second = build_transverse_artifact(*values)
        self.assertEqual(first, second)
        self.assertEqual(values, snapshots)
        self.assertEqual(first["rollback"]["method"], "discard_sidecar_and_rebuild")
        self.assertEqual(
            first["rollback"]["source_global_final_hash"], document_hash(values[0])
        )
        with tempfile.TemporaryDirectory() as tmp:
            first_path = write_transverse_artifact(Path(tmp) / "first", first)
            second_path = write_transverse_artifact(Path(tmp) / "second", second)
            self.assertEqual(first_path.read_bytes(), second_path.read_bytes())
            self.assertEqual(first_path.relative_to(Path(tmp) / "first").as_posix(),
                             "pass3f/transverse_units.json")

    def test_a007_reuses_global_request_and_preserves_true_provenance(self):
        existing = {
            "numero": 18,
            "objet": EXISTING_OBJECT,
            "demandeur": None,
            "destinataire": None,
            "echeance": None,
            "commentaire": None,
            "origine": "reunion",
        }
        (inputs, artifact) = self.build([existing])
        unit = artifact["units"][0]
        self.assertEqual(len(inputs[0]["demandes_documents_globales"]), 1)
        self.assertEqual(unit["evidence_occurrence_ids"], [EVIDENCE_ID])
        self.assertEqual(unit["historical_subject"], "18")
        self.assertEqual(unit["historical_origins"], ["debrief_expert"])
        self.assertEqual(unit["existing_match"]["matched_entry"]["origine"], "reunion")
        self.assertEqual(unit["materialization_status"], "reuse_existing")
        self.assertIsNone(unit["prepared_entry"])
        self.assertEqual(unit["decision"]["status"], "accepted")


if __name__ == "__main__":
    unittest.main()
