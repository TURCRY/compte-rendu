"""Tests de non-régression du scan des placeholders de pseudonymisation.

Couvre le faux négatif historique : le scan JSON travaillait sur le texte
brut du fichier, où un retour à la ligne est stocké sous la forme des deux
caractères littéraux ``\\`` + ``n``. Un token ``P131`` placé en début de
paragraphe était précédé du caractère de mot ``n`` et échappait donc à la
frontière de mot ``\\b``, alors que le contrôle DOCX le détectait.
"""

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "Scripts" / "placeholder_scan.py"
LAUNCHER = ROOT / "Scripts" / "run_compte_rendu_avec_sujets.sh"
PASS3A_SCRIPT = ROOT / "cr-pipeline" / "pipeline" / "powershell" / "cr_reunion_point_mumerotes_pipeline_json.ps1"


def load_helper():
    spec = importlib.util.spec_from_file_location("placeholder_scan", HELPER)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def write_docx(path: Path, paragraphs):
    """Écrit un DOCX minimal dont les paragraphes sont fournis dans l'ordre."""
    ns = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    body = "".join(
        f'<w:p><w:r><w:t xml:space="preserve">{text}</w:t></w:r></w:p>'
        for text in paragraphs
    )
    document = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        f'<w:document xmlns:w="{ns}"><w:body>{body}</w:body></w:document>'
    )
    content_types = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="xml" ContentType="application/xml"/>'
        "</Types>"
    )
    rels = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>'
    )
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("[Content_Types].xml", content_types)
        archive.writestr("_rels/.rels", rels)
        archive.writestr("word/document.xml", document)


class PlaceholderScanTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.helper = load_helper()

    def tearDown(self):
        self.tmp.cleanup()

    def write_json(self, name, data):
        path = self.root / name
        path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
        return path

    # ------------------------------------------------------------------
    # Régression principale
    # ------------------------------------------------------------------
    def test_detects_p131_after_blank_line_in_json_value(self):
        """Le cas réel du run J48 : P131 en tête du 5e paragraphe de /resume."""
        path = self.write_json(
            "payload.json",
            {
                "resume": (
                    "Paragraphe un.\n\nParagraphe deux.\n\nParagraphe trois.\n\n"
                    "Paragraphe quatre.\n\nP131 : suites envisagées : réaliser des "
                    "inspections techniques visuelles."
                )
            },
        )
        hits = self.helper.scan_json_payload(path)
        tokens = [token.upper().replace(" ", "") for token, _ in hits]
        self.assertIn("P131", tokens)

    def test_raw_text_scan_would_have_missed_it(self):
        """Démontre le faux négatif de l'ancienne méthode (texte brut + \\b)."""
        path = self.write_json(
            "payload.json",
            {"resume": "Paragraphe quatre.\n\nP131 : suites envisagées."},
        )
        raw = path.read_text(encoding="utf-8-sig")
        self.assertEqual(len(self.helper.PLACEHOLDER_PATTERN.findall(raw)), 0)
        self.assertEqual(len(self.helper.scan_json_payload(path)), 1)

    # ------------------------------------------------------------------
    # Détections de base
    # ------------------------------------------------------------------
    def test_detects_p126(self):
        path = self.write_json("p.json", {"resume": "Échange avec P126 sur le sujet."})
        tokens = [t.upper().replace(" ", "") for t, _ in self.helper.scan_json_payload(path)]
        self.assertIn("P126", tokens)

    def test_detects_ent3(self):
        path = self.write_json("e.json", {"resume": "Intervention de ENT3."})
        tokens = [t.upper().replace(" ", "") for t, _ in self.helper.scan_json_payload(path)]
        self.assertIn("ENT3", tokens)

    def test_detects_token_with_space(self):
        path = self.write_json("s.json", {"resume": "Intervention de P 12."})
        tokens = [t.upper().replace(" ", "") for t, _ in self.helper.scan_json_payload(path)]
        self.assertIn("P12", tokens)

    def test_detects_in_nested_structures(self):
        path = self.write_json(
            "nested.json",
            {
                "sujets": [
                    {"numero": 3, "conclusion_expert": "Constat avec P45."},
                    {"numero": 4, "avis_participants": [{"texte": "Dit par ENT7."}]},
                ]
            },
        )
        tokens = [t.upper().replace(" ", "") for t, _ in self.helper.scan_json_payload(path)]
        self.assertIn("P45", tokens)
        self.assertIn("ENT7", tokens)

    # ------------------------------------------------------------------
    # Allowlist
    # ------------------------------------------------------------------
    def test_allowlist_ignores_listed_token(self):
        path = self.write_json("a.json", {"resume": "Référence P12 tolérée."})
        self.assertEqual(len(self.helper.scan_json_payload(path, "P12")), 0)
        self.assertEqual(len(self.helper.scan_json_payload(path, "p 12")), 0)
        self.assertEqual(len(self.helper.scan_json_payload(path, "")), 1)

    def test_allowlist_does_not_hide_other_tokens(self):
        path = self.write_json("a2.json", {"resume": "P12 toléré mais P131 non."})
        tokens = [t.upper().replace(" ", "") for t, _ in self.helper.scan_json_payload(path, "P12")]
        self.assertEqual(tokens, ["P131"])

    # ------------------------------------------------------------------
    # JSON sain
    # ------------------------------------------------------------------
    def test_clean_json_passes(self):
        path = self.write_json(
            "clean.json",
            {
                "resume": "Cadrage.\n\nObjectifs.\n\nConstats.\n\nSuites envisagées.",
                "sujets": [{"numero": 3, "titre": "Bâtiment A"}],
            },
        )
        self.assertEqual(self.helper.scan_json_payload(path), [])

    # ------------------------------------------------------------------
    # Cohérence JSON / DOCX
    # ------------------------------------------------------------------
    def test_json_and_docx_scanners_agree(self):
        """Un contenu logique identique doit produire les mêmes tokens."""
        paragraphs = [
            "Cadrage de la réunion.",
            "Objectifs de la réunion.",
            "Principaux constats techniques.",
            "P131 : suites envisagées : inspections visuelles.",
            "Intervention de P126 et ENT3.",
        ]
        resume = "\n\n".join(paragraphs)

        json_path = self.write_json("agree.json", {"resume": resume})
        docx_path = self.root / "agree.docx"
        write_docx(docx_path, paragraphs)

        json_tokens = sorted(
            t.upper().replace(" ", "") for t, _ in self.helper.scan_json_payload(json_path)
        )
        docx_tokens = sorted(
            t.upper().replace(" ", "") for _, _, t, _ in self.helper.scan_docx(docx_path)
        )
        self.assertEqual(json_tokens, docx_tokens)
        self.assertEqual(json_tokens, ["ENT3", "P126", "P131"])

    def test_docx_scanner_detects_leading_token(self):
        docx_path = self.root / "lead.docx"
        write_docx(docx_path, ["P131 : suites envisagées : inspections."])
        hits = self.helper.scan_docx(docx_path)
        self.assertEqual(len(hits), 1)
        part, idx, token, _ = hits[0]
        self.assertEqual(part, "word/document.xml")
        self.assertEqual(idx, 1)
        self.assertEqual(token.upper().replace(" ", ""), "P131")

    def test_docx_clean_passes(self):
        docx_path = self.root / "clean.docx"
        write_docx(docx_path, ["Cadrage.", "Objectifs.", "Suites envisagées."])
        self.assertEqual(self.helper.scan_docx(docx_path), [])

    # ------------------------------------------------------------------
    # CLI
    # ------------------------------------------------------------------
    def test_cli_json_exit_codes(self):
        bad = self.write_json("bad.json", {"resume": "A.\n\nP131 : suites."})
        good = self.write_json("good.json", {"resume": "A.\n\nSuites."})

        bad_rc = subprocess.run(
            [sys.executable, str(HELPER), "json", str(bad), "payload test"],
            capture_output=True, text=True,
        )
        self.assertEqual(bad_rc.returncode, 32)
        self.assertIn("ERREUR: placeholders résiduels dans payload test", bad_rc.stdout)

        good_rc = subprocess.run(
            [sys.executable, str(HELPER), "json", str(good), "payload test"],
            capture_output=True, text=True,
        )
        self.assertEqual(good_rc.returncode, 0)
        self.assertIn("QA placeholders OK: payload test", good_rc.stdout)

    def test_cli_docx_exit_codes(self):
        bad = self.root / "bad.docx"
        write_docx(bad, ["P131 : suites envisagées."])
        good = self.root / "good.docx"
        write_docx(good, ["Suites envisagées."])

        bad_rc = subprocess.run(
            [sys.executable, str(HELPER), "docx", str(bad)],
            capture_output=True, text=True,
        )
        self.assertEqual(bad_rc.returncode, 33)
        self.assertIn("ERREUR: placeholders résiduels dans le DOCX", bad_rc.stdout)

        good_rc = subprocess.run(
            [sys.executable, str(HELPER), "docx", str(good)],
            capture_output=True, text=True,
        )
        self.assertEqual(good_rc.returncode, 0)
        self.assertIn("QA placeholders OK: DOCX", good_rc.stdout)

    # ------------------------------------------------------------------
    # Câblage du script shell
    # ------------------------------------------------------------------
    def test_launcher_delegates_to_helper(self):
        source = LAUNCHER.read_text(encoding="utf-8")
        self.assertIn('placeholder_scan.py" json', source)
        self.assertIn('placeholder_scan.py" docx', source)
        self.assertIn("scan_placeholder_file()", source)
        self.assertIn("scan_docx_placeholders()", source)

    def test_launcher_no_longer_inlines_scanner(self):
        """Le scan ne doit plus être dupliqué en shell."""
        source = LAUNCHER.read_text(encoding="utf-8")
        self.assertNotIn("import zipfile", source)
        self.assertNotIn("xml.etree.ElementTree", source)


class Pass3APromptTests(unittest.TestCase):
    """Vérifie le durcissement du prompt système de la Passe 3A."""

    def setUp(self):
        self.source = PASS3A_SCRIPT.read_text(encoding="utf-8-sig")

    def test_prompt_forbids_invented_labels(self):
        self.assertIn("Pxxx", self.source)
        self.assertIn("ENTxxx", self.source)

    def test_prompt_mentions_no_new_identifier(self):
        lowered = self.source.lower()
        self.assertTrue(
            "aucune nouvelle étiquette" in lowered
            or "aucun nouvel identifiant" in lowered
            or "ne créer aucune" in lowered,
            "contrainte d'interdiction d'étiquette absente du prompt 3A",
        )

    def test_prompt_still_requires_five_paragraphs(self):
        self.assertIn("exactement 5 paragraphes", self.source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
