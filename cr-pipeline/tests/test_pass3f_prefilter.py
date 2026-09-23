import json
import sys
import tempfile
import unittest
from pathlib import Path

from jsonschema import Draft202012Validator


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "pipeline" / "python"))

from pass3f_candidates import build_candidates  # noqa: E402
from pass3f_provenance import build_registry, write_json_deterministic  # noqa: E402


RUN_A = Path(
    r"C:\Affaires\2025-J48\BE_Traitement_captations\accedit-2025-11-20"
    r"\compte_rendu_LLM\out\job_20260910_153906_016211557_16285"
)
RUN_B = Path(
    r"C:\Affaires\2025-J48\BE_Traitement_captations\accedit-2026-05-28"
    r"\compte_rendu_LLM\out\job_20260910_020904_973539650_26150"
)


def dump(path: Path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")


def synthetic_run(root: Path) -> Path:
    run = root / "run"
    subjects = [
        {"Numero": 1, "Titre": "État du 10 rue Alpha", "Localisation": "", "Description": ""},
        {"Numero": 2, "Titre": "État du 20 rue Beta", "Localisation": "", "Description": ""},
        {"Numero": 3, "Titre": "Altérations apparentes", "Localisation": "", "Description": ""},
    ]
    shared = {
        "segment_id": "segment_01", "row_ref": 10, "timecode": "00:00:10",
        "auteur": "Expert", "texte": "Une fissure verticale est visible sous la fenêtre.",
        "projection_classification": "specifique", "row_ref_subject_count": 2,
    }
    dump(run / "sujets_ref.json", subjects)
    dump(run / "global.json", {"sujets": {"1": [shared], "2": [shared]}})
    dump(run / "global_by_sujet.json", {"sujets": []})
    dump(run / "pass2E_sujets_compact" / "sujet_001_compact.json", {
        "numero": 1,
        "synthese_intermediaire": {
            "points_cles": [
                "Une fissure verticale est visible sous la fenêtre.",
                "Fissure verticale visible sous cette fenêtre ancienne.",
                "Information sans relation avec les preuves disponibles.",
            ]
        },
    })
    dump(run / "pass3E_sujets" / "sujet_001_synthese.json", {
        "numero": 1,
        "synthese_echanges": "La visite concerne le 20 rue Beta.",
        "conclusion_expert": "Aucune conclusion supplémentaire.",
        "avis_participants": [],
    })
    return run


def add_truncation_artifacts(run: Path, *, matching_debug=True):
    dump(run / "pass2e_qa.json", {
        "subject_count": 3,
        "subjects_without_chunk": [{"source_name": "sujet_002", "path": "ignored"}],
        "critical_warnings": [],
    })
    log = "\n".join((
        "Pass2E sujet_001 → chunk 1/2",
        "WARNING: Pass2E sujet_001 chunk 1/2: prompt tronqué (approx 4000→2652 tokens, n_ctx=4096, max_tokens=1024)",
        "Pass2E sujet_001 → chunk 2/2",
    ))
    (run / "logs").mkdir(parents=True, exist_ok=True)
    (run / "logs" / "run_20260101_000001.log").write_text(log, encoding="utf-8")
    compact = json.loads((run / "pass2E_sujets_compact" / "sujet_001_compact.json").read_text(encoding="utf-8"))
    if not matching_debug:
        compact["synthese_intermediaire"] = {"points_cles": ["compact différent"]}
    dump(run / "pass3E_debug" / "sujet_001" / "attempt_20260101_000001" / "input_compact.json", compact)


def find_pair(candidates, kind, left, right, term=""):
    return [
        item for item in candidates
        if item["kind"] == kind
        and {item["source_subject"], item["target_subject"]} == {left, right}
        and term.casefold() in item["excerpt"].casefold()
    ]


class Pass3FProvenanceTest(unittest.TestCase):
    def test_confirmed_chunk_stays_subject_scoped_for_fragments(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = synthetic_run(Path(tmp))
            add_truncation_artifacts(run)
            registry = build_registry(run)
        subjects = {item["subject_id"]: item for item in registry["subjects"]}
        self.assertEqual(subjects["1"]["truncation"]["status"], "confirmed")
        self.assertEqual(subjects["1"]["truncation"]["scope"], "subject")
        self.assertEqual(subjects["2"]["truncation"]["status"], "none")
        self.assertEqual(subjects["3"]["truncation"]["status"], "unknown")
        self.assertEqual(len(registry["truncation_events"]), 1)
        self.assertEqual(registry["truncation_events"][0]["scope"], "chunk")
        affected = [item for item in registry["derived_fragments"] if item["subject_id"] == "1"]
        self.assertTrue(affected)
        self.assertTrue(all(item["truncation"]["status"] == "possible" for item in affected))
        self.assertEqual(registry["stats"]["confirmed_truncation_fragment_count"], 0)

    def test_3e_fragment_is_unknown_when_debug_input_does_not_match_compact(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = synthetic_run(Path(tmp))
            add_truncation_artifacts(run, matching_debug=False)
            registry = build_registry(run)
        stage_2e = [item for item in registry["derived_fragments"] if item["subject_id"] == "1" and item["stage"] == "2E"]
        stage_3e = [item for item in registry["derived_fragments"] if item["subject_id"] == "1" and item["stage"] == "3E"]
        self.assertTrue(all(item["truncation"]["status"] == "possible" for item in stage_2e))
        self.assertTrue(all(item["truncation"]["status"] == "unknown" for item in stage_3e))

    def test_optional_pass2f_fragments_are_registered(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            run = synthetic_run(root)
            pass2f = root / "pass2f"
            dump(pass2f / "subject_001" / "chunk_01_response.json", {
                "schema_version": "cr_refere_preventif.pass2f.chunk.v1",
                "source_pass": "2F",
                "subject_numero": 1,
                "synthese_intermediaire": "Une fissure verticale est visible sous la fenêtre.",
                "points_documentes": [],
                "incertitudes": [],
                "photo_contexts": [],
            })
            registry = build_registry(run, pipeline_kind="refere", pass2f_dir=pass2f)
        fragments = [item for item in registry["derived_fragments"] if item["stage"] == "2F"]
        self.assertEqual(len(fragments), 1)
        self.assertEqual(fragments[0]["links"][0]["link_status"], "verified")
        self.assertIn("pass2f/subject_001/chunk_01_response.json", registry["run"]["input_hashes"])

    def test_link_statuses_and_fuzzy_never_verified(self):
        with tempfile.TemporaryDirectory() as tmp:
            registry = build_registry(synthetic_run(Path(tmp)))
        links_by_text = {item["text"]: item["links"] for item in registry["derived_fragments"]}
        self.assertEqual(links_by_text["Une fissure verticale est visible sous la fenêtre."][0]["link_status"], "verified")
        fuzzy = links_by_text["Fissure verticale visible sous cette fenêtre ancienne."]
        self.assertTrue(fuzzy)
        self.assertTrue(all(link["link_status"] == "candidate" for link in fuzzy))
        self.assertTrue(all(link["method"] == "token_overlap" for link in fuzzy))
        self.assertEqual(links_by_text["Information sans relation avec les preuves disponibles."][0]["link_status"], "unresolved")

    def test_registry_and_candidates_are_byte_reproducible(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            first_run = synthetic_run(root)
            copied_run = synthetic_run(root / "different-parent")
            add_truncation_artifacts(first_run)
            add_truncation_artifacts(copied_run)
            registry = build_registry(first_run)
            candidates = build_candidates(registry)
            first_registry, second_registry = root / "registry-1.json", root / "registry-2.json"
            first_candidates, second_candidates = root / "candidates-1.json", root / "candidates-2.json"
            write_json_deterministic(first_registry, registry)
            write_json_deterministic(second_registry, build_registry(copied_run))
            write_json_deterministic(first_candidates, candidates)
            write_json_deterministic(second_candidates, build_candidates(build_registry(copied_run)))
            self.assertEqual(first_registry.read_bytes(), second_registry.read_bytes())
            self.assertEqual(first_candidates.read_bytes(), second_candidates.read_bytes())

    def test_prefilter_emits_shared_evidence_and_reference_conflict(self):
        with tempfile.TemporaryDirectory() as tmp:
            candidates = build_candidates(build_registry(synthetic_run(Path(tmp))))["candidates"]
        self.assertTrue(find_pair(candidates, "shared_evidence", "1", "2", "fissure"))
        conflicts = [item for item in candidates if item["kind"] == "subject_reference_conflict"]
        self.assertTrue(any(item["source_subject"] == "1" and item["target_subject"] == "2" for item in conflicts))
        self.assertTrue(all(item["ambiguous"] and item["requires_llm_review"] for item in candidates))

    def test_schema_files_are_strict_at_the_root(self):
        schema_dir = ROOT / "pipeline" / "schemas"
        for name in ("pass3f_provenance.v1.schema.json", "pass3f_candidates.v1.schema.json"):
            schema = json.loads((schema_dir / name).read_text(encoding="utf-8"))
            self.assertFalse(schema["additionalProperties"])
            self.assertEqual(schema["$schema"], "https://json-schema.org/draft/2020-12/schema")

    def test_outputs_validate_against_json_schemas(self):
        with tempfile.TemporaryDirectory() as tmp:
            registry = build_registry(synthetic_run(Path(tmp)))
            candidates = build_candidates(registry)
        schema_dir = ROOT / "pipeline" / "schemas"
        provenance_schema = json.loads((schema_dir / "pass3f_provenance.v1.schema.json").read_text(encoding="utf-8"))
        candidates_schema = json.loads((schema_dir / "pass3f_candidates.v1.schema.json").read_text(encoding="utf-8"))
        Draft202012Validator(provenance_schema).validate(registry)
        Draft202012Validator(candidates_schema).validate(candidates)


@unittest.skipUnless(RUN_A.is_dir() and RUN_B.is_dir(), "read-only J48 reference runs unavailable")
class Pass3FJ48ObservationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        root = Path(cls.temp.name)
        cls.outputs = {}
        for label, run in (("A", RUN_A), ("B", RUN_B)):
            registry = build_registry(run)
            candidates = build_candidates(registry)
            registry_path = root / label / "provenance_registry.json"
            candidates_path = root / label / "candidates.json"
            write_json_deterministic(registry_path, registry)
            write_json_deterministic(candidates_path, candidates)
            cls.outputs[label] = (registry, candidates, registry_path, candidates_path)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_outputs_exist_only_in_temporary_directory(self):
        for _registry, _candidates, registry_path, candidates_path in self.outputs.values():
            self.assertTrue(registry_path.is_file())
            self.assertTrue(candidates_path.is_file())
            self.assertNotIn(r"C:\Affaires", str(registry_path))

    def test_run_a_known_shared_assignments_surface(self):
        candidates = self.outputs["A"][1]["candidates"]
        self.assertTrue(find_pair(candidates, "shared_evidence", "1", "22", "fissur"))
        parking_or_party_wall = (
            find_pair(candidates, "shared_evidence", "1", "30", "parking")
            or find_pair(candidates, "shared_evidence", "1", "30", "mitoy")
        )
        self.assertTrue(parking_or_party_wall)

    def test_real_runs_keep_confirmed_truncation_at_subject_scope(self):
        expected = {
            "A": {"1", "20", "21", "22", "26", "29", "30"},
            "B": {"1", "2", "6", "12", "20", "22", "23", "24", "26", "29"},
        }
        for label, subject_ids in expected.items():
            registry = self.outputs[label][0]
            confirmed = {
                item["subject_id"] for item in registry["subjects"]
                if item["truncation"]["status"] == "confirmed"
            }
            self.assertEqual(confirmed, subject_ids)
            self.assertEqual(registry["stats"]["confirmed_truncation_fragment_count"], 0)
            possible = [item for item in registry["derived_fragments"] if item["truncation"]["status"] == "possible"]
            self.assertTrue(possible)
            self.assertTrue(all(item["truncation"]["scope"] == "subject" for item in possible))

    def test_run_b_known_address_conflicts_surface(self):
        registry = self.outputs["B"][0]
        candidates = self.outputs["B"][1]["candidates"]
        conflicts = [item for item in candidates if item["kind"] == "subject_reference_conflict"]
        self.assertTrue(any(item["source_subject"] == "16" and "61 avenue" in item["excerpt"].casefold() for item in conflicts))
        self.assertTrue(any(item["source_subject"] == "2" and item["target_subject"] == "8" and "curzay" in item["excerpt"].casefold() for item in conflicts))
        b005 = next(item for item in conflicts if item["source_subject"] == "16" and "61 avenue" in item["excerpt"].casefold())
        evidence = {item["evidence_id"]: item["exact_text"] for item in registry["evidence"]}
        self.assertEqual([evidence[item] for item in b005["direct_evidence_refs"]], ["61 avenue Gérardin."])
        self.assertIn("Il y a une fenêtre ouverte. Il y a peut-être quelqu'un.", [
            evidence[item] for item in b005["context_evidence_refs"]
        ])
        self.assertTrue(set(b005["direct_evidence_refs"]).isdisjoint(b005["context_evidence_refs"]))

    def test_run_b_cigarette_duplicates_surface(self):
        candidates = self.outputs["B"][1]["candidates"]
        matches = (
            find_pair(candidates, "shared_evidence", "20", "22", "mégot")
            or find_pair(candidates, "shared_evidence", "20", "22", "cigarette")
        )
        self.assertTrue(matches)


if __name__ == "__main__":
    unittest.main()
