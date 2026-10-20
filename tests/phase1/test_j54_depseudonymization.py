import importlib.util
import json
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "Scripts" / "render_compte_rendu_from_infos.py"
SPEC = importlib.util.spec_from_file_location("render_compte_rendu_from_infos", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class FakeResponse:
    def __init__(self, text):
        self._text = text

    def raise_for_status(self):
        return None

    def json(self):
        return {"text_depseudonymized": self._text}


class J54DepseudonymizationRegressionTests(unittest.TestCase):
    def test_publishable_values_are_depseudonymized_and_metadata_is_preserved(self):
        payload = {
            "sujets": [{"numero": 8, "synthese_echanges": "P1 signale un défaut."}],
            "metadata": {"source_name": "P1_internal", "path": "/tmp/P1.json"},
        }

        def fake_post(_url, *, json, headers, timeout):
            self.assertEqual(json["mode"], "compte_rendu_final")
            self.assertEqual(headers["x-api-key"], "secret")
            return FakeResponse(json["text"].replace("P1", "Monsieur Dupont"))

        with patch.object(MODULE.requests, "post", side_effect=fake_post):
            result = MODULE.depseudonymize_final_payload(
                json.dumps(payload, ensure_ascii=False),
                pseudo_api_base="http://example.invalid",
                pseudo_api_key="secret",
                job_id="job-test",
            )

        self.assertEqual(result["sujets"][0]["synthese_echanges"], "Monsieur Dupont signale un défaut.")
        self.assertEqual(result["metadata"], payload["metadata"])


if __name__ == "__main__":
    unittest.main()
