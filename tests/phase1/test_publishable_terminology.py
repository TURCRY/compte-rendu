import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
TEST_DIR = Path(__file__).resolve().parent
MODULE_PATH = ROOT / "cr-pipeline" / "pipeline" / "python" / "publishable_terminology.py"
SPEC = importlib.util.spec_from_file_location("publishable_terminology", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PublishableTerminologyTests(unittest.TestCase):
    def test_blocking_internal_references(self):
        payload = {
            "sujets": [{"conclusion_expert": "La synthèse Pass2E provient du pipeline et du prompt LLM."}]
        }
        report = MODULE.scan_payload(payload, stage="pass3e")
        self.assertFalse(report["ok"])
        self.assertGreaterEqual(report["blocking_count"], 3)

    def test_ambiguous_terms_warn_only(self):
        payload = {
            "synthese_echanges": "Selon la synthèse fournie et les échanges analysés, les éléments analysés restent incomplets."
        }
        report = MODULE.scan_payload(payload, stage="pass3e")
        self.assertTrue(report["ok"])
        self.assertEqual(report["blocking_count"], 0)
        self.assertEqual(report["warning_count"], 3)

    def test_legitimate_documentary_language_is_clean(self):
        payload = {
            "conclusion_expert": (
                "Selon les déclarations du propriétaire et la pièce n° 7, le désordre a été signalé. "
                "L'expert ne l'a pas constaté matériellement pendant la réunion."
            )
        }
        report = MODULE.scan_payload(payload, stage="pass3e")
        self.assertTrue(report["ok"])
        self.assertEqual(report["warning_count"], 0)

    def test_legitimate_technical_pass_and_pipeline_are_clean(self):
        payload = {
            "conclusion_expert": "Une passe 2 mm d'enduit protège le pipeline de gaz existant."
        }
        report = MODULE.scan_payload(payload, stage="pass3e")
        self.assertTrue(report["ok"])

    def test_pass2b_and_pass3b_publishable_fields_are_scanned(self):
        pass2b = {"themes": [{"titre": "Constat", "synthese": ["Résumé produit par Pass2B."]}]}
        pass3b = {
            "themes_abordes": [
                {
                    "titre": "Travaux",
                    "synthese": ["Le prompt LLM indique une reprise."],
                    "indices_source": [{"extrait": "La Pass3B technique est citée dans une métadonnée."}],
                }
            ]
        }
        report2b = MODULE.scan_payload(pass2b, stage="pass2b")
        report3b = MODULE.scan_payload(pass3b, stage="pass3b")
        self.assertGreaterEqual(report2b["blocking_count"], 1)
        self.assertGreaterEqual(report3b["blocking_count"], 2)
        self.assertFalse(any(item["path"].endswith("indices_source[0].extrait") for item in report3b["findings"]))

    def test_metadata_and_provenance_are_preserved(self):
        payload = {
            "metadata": {"description": "Sortie Pass3E du pipeline LLM"},
            "source": {"titre": "prompt Pass2B"},
            "synthese_echanges": "Les échanges de la réunion décrivent une fissure.",
        }
        report = MODULE.scan_payload(payload, stage="final")
        self.assertTrue(report["ok"])
        self.assertEqual(report["blocking_count"], 0)

    def test_non_publishable_unknown_field_is_not_scanned(self):
        payload = {"internal_note": "La synthèse Pass2E vient du pipeline."}
        report = MODULE.scan_payload(payload, stage="final")
        self.assertTrue(report["ok"])

    def test_cli_blocks_and_warnings_do_not_block(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = Path(temp_dir)
            input_path = temp / "input.json"
            report_path = temp / "report.json"
            input_path.write_text(json.dumps({"resume": "Produit par la Pass3E."}), encoding="utf-8")
            blocked = subprocess.run(
                [sys.executable, str(MODULE_PATH), "--input", str(input_path), "--stage", "final", "--report", str(report_path)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(blocked.returncode, 42)
            self.assertTrue(report_path.exists())
            input_path.write_text(json.dumps({"resume": "Selon la synthèse fournie."}), encoding="utf-8")
            warned = subprocess.run(
                [sys.executable, str(MODULE_PATH), "--input", str(input_path), "--stage", "final", "--report", str(report_path)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(warned.returncode, 0)
            self.assertEqual(json.loads(report_path.read_text(encoding="utf-8"))["warning_count"], 1)

    def test_j54_fixture_is_blocked_without_mutation(self):
        fixture = TEST_DIR / "fixtures" / "global_final_j54.json"
        before = fixture.read_bytes()
        report = MODULE.scan_file(fixture, stage="final")
        self.assertGreaterEqual(report["blocking_count"], 1)
        self.assertGreaterEqual(report["warning_count"], 1)
        self.assertEqual(fixture.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
