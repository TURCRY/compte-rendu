import contextlib
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "pipeline" / "python"))

from structured_output_utils import (  # noqa: E402
    StructuredOutputError,
    extract_json_from_text,
    normalize_pass1_envelope,
    pass1_cli,
    validate_pass1_analysis,
)


class StructuredOutputUtilsTest(unittest.TestCase):
    def test_invalid_json_raises(self):
        with self.assertRaises(StructuredOutputError):
            extract_json_from_text('{"sujets": [}')

    def test_json_surrounded_by_text_is_extracted(self):
        parsed, _payload, repaired = extract_json_from_text('Voici le JSON:\n{"sujets": {}}\nMerci')
        self.assertEqual(parsed, {"sujets": {}})
        self.assertTrue(repaired)

    def test_json_with_utf8_bom_is_not_marked_repaired(self):
        parsed, _payload, repaired = extract_json_from_text('\ufeff{"sujets": {}}')
        self.assertEqual(parsed, {"sujets": {}})
        self.assertFalse(repaired)

    def test_missing_required_field_is_invalid(self):
        result = validate_pass1_analysis({"segment_id": "segment_01"})
        self.assertFalse(result.valid)
        self.assertTrue(any("sujets" in err for err in result.errors))

    def test_new_pass1_subject_array_is_converted_to_legacy_internal_shape(self):
        payload = {
            "segment_id": "segment_01",
            "sujets": [
                {
                    "titre": "2 - Humidité en cave",
                    "interventions": [
                        {
                            "row_ref": 7,
                            "auteur": "Expert",
                            "role": None,
                            "texte": "Trace d'humidité observée.",
                        }
                    ],
                }
            ],
        }

        result = validate_pass1_analysis(payload)

        self.assertTrue(result.valid, result.errors)
        self.assertEqual(list(result.value["sujets"].keys()), ["2"])
        self.assertEqual(result.value["sujets"]["2"][0]["row_ref"], 7)

    def test_incoherent_timecode_is_reported(self):
        payload = {"sujets": {"1": [{"texte": "x", "timecode": "09:00:00"}]}}
        result = validate_pass1_analysis(payload, start_sec=10, end_sec=20)
        self.assertFalse(result.valid)
        self.assertTrue(any("forbidden" in err for err in result.errors))
        self.assertTrue(any("outside segment interval" in err for err in result.errors))

    def test_empty_response_cli_produces_fallback(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            raw = root / "raw.txt"
            raw.write_text("", encoding="utf-8")
            source = root / "source.txt"
            source.write_text("[ROW 1] [00:00:01] A: bonjour", encoding="utf-8")

            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                rc = pass1_cli(
                    [
                        "--raw-file",
                        str(raw),
                        "--source-file",
                        str(source),
                        "--segment-id",
                        "segment_01",
                        "--row-start",
                        "1",
                        "--row-end",
                        "1",
                        "--start-sec",
                        "1",
                        "--end-sec",
                        "2",
                        "--start-hms",
                        "00:00:01",
                        "--end-hms",
                        "00:00:02",
                    ]
                )
            self.assertEqual(rc, 0)
            out = json.loads(stdout.getvalue())
            self.assertEqual(out["segment_id"], "segment_01")
            self.assertFalse(out["llm_valid"])
            self.assertTrue(out["llm_fallback"])
            self.assertEqual(out["texte_source"], "[ROW 1] [00:00:01] A: bonjour")

    def test_pseudonymize_timeout_still_writes_segment_envelope(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            raw = root / "segment_01.json.raw.txt"
            raw.write_text("", encoding="utf-8")
            source = root / "segment_01.json.source.txt"
            source.write_text("[ROW 60] [00:01:00] Expert: constat à conserver", encoding="utf-8")
            segment = root / "segment_01.json"

            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                pass1_cli(
                    [
                        "--raw-file",
                        str(raw),
                        "--source-file",
                        str(source),
                        "--segment-id",
                        "segment_01",
                        "--row-start",
                        "60",
                        "--row-end",
                        "60",
                        "--start-sec",
                        "60",
                        "--end-sec",
                        "61",
                        "--start-hms",
                        "00:01:00",
                        "--end-hms",
                        "00:01:01",
                    ]
                )
            segment.write_text(stdout.getvalue(), encoding="utf-8")
            out = json.loads(segment.read_text(encoding="utf-8"))
            self.assertTrue(segment.exists())
            self.assertIn("llm_analysis", out)
            self.assertIn("llm_raw_response", out)
            self.assertFalse(out["llm_valid"])
            self.assertIsInstance(out["llm_validation_errors"], list)
            self.assertFalse(out["llm_repaired"])
            self.assertTrue(out["llm_fallback"])

    def test_script_cli_uses_sys_argv(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            raw = root / "raw.txt"
            raw.write_text('{"sujets": {}}', encoding="utf-8")
            source = root / "source.txt"
            source.write_text("[ROW 1] [00:00:01] A: bonjour", encoding="utf-8")
            script = ROOT / "pipeline" / "python" / "structured_output_utils.py"

            proc = subprocess.run(
                [
                    sys.executable,
                    str(script),
                    "pass1",
                    "--raw-file",
                    str(raw),
                    "--source-file",
                    str(source),
                    "--segment-id",
                    "segment_01",
                    "--row-start",
                    "1",
                    "--row-end",
                    "1",
                    "--start-sec",
                    "1",
                    "--end-sec",
                    "2",
                    "--start-hms",
                    "00:00:01",
                    "--end-hms",
                    "00:00:02",
                ],
                text=True,
                capture_output=True,
                check=True,
            )
            out = json.loads(proc.stdout)
            self.assertEqual(out["segment_id"], "segment_01")
            self.assertIn("llm_valid", out)
            self.assertNotIn("Usage: structured_output_utils.py", proc.stderr)

    def test_incomplete_structured_output_is_normalized(self):
        out = normalize_pass1_envelope(
            {"segment_id": "segment_01", "sujets": {}},
            {
                "segment_id": "segment_01",
                "row_start": 1,
                "row_end": 1,
                "start_sec": 1,
                "end_sec": 2,
                "start_hms": "00:00:01",
                "end_hms": "00:00:02",
                "texte_source": "[ROW 1] [00:00:01] A: bonjour",
                "llm_raw_response": "",
            },
        )
        self.assertFalse(out["llm_valid"])
        self.assertTrue(out["llm_fallback"])
        self.assertFalse(out["llm_repaired"])
        self.assertEqual(out["llm_analysis"], {"sujets": {}})
        self.assertTrue(any("llm_valid" in err for err in out["llm_validation_errors"]))

    def test_missing_llm_valid_defaults_to_false(self):
        out = normalize_pass1_envelope(
            {
                "segment_id": "segment_01",
                "llm_analysis": {"sujets": {}},
                "llm_raw_response": "{}",
                "llm_validation_errors": [],
                "llm_repaired": False,
                "llm_fallback": False,
                "sujets": {},
            },
            {"segment_id": "segment_01"},
        )
        self.assertFalse(out["llm_valid"])
        self.assertTrue(out["llm_fallback"])
        self.assertTrue(any("llm_valid" in err for err in out["llm_validation_errors"]))


if __name__ == "__main__":
    unittest.main()
