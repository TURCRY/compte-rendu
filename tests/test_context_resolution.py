import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER_DIR = ROOT / "cr-pipeline" / "pipeline" / "python"
HELPER = HELPER_DIR / "context_resolution.py"
RENDER = ROOT / "Scripts" / "render_compte_rendu_from_infos.py"
LAUNCHER = ROOT / "Scripts" / "run_compte_rendu_avec_sujets.sh"

sys.path.insert(0, str(HELPER_DIR))

from context_resolution import resolve_compte_rendu_context


def load_render_module():
    spec = importlib.util.spec_from_file_location("render_compte_rendu_from_infos", RENDER)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class ContextResolutionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.csv_dir = self.root / "transcriptions" / "capture"
        self.csv_dir.mkdir(parents=True)
        self.csv_path = self.csv_dir / "transcription.csv"
        self.csv_path.write_text("start;end;text\n0;1;bonjour\n", encoding="utf-8")
        self.infos_path = self.csv_dir / "infos_projet.json"
        self.write_infos(mission="mission infos", system="system infos", user="user infos")

    def tearDown(self):
        self.tmp.cleanup()

    def write_json(self, path: Path, data):
        path.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")

    def write_text(self, path: Path, text: str):
        path.write_text(text, encoding="utf-8")

    def write_infos(self, **extra):
        data = {"id_affaire": "2026-A60", "id_captation": "capture"}
        data.update(extra)
        self.write_json(self.infos_path, data)

    def resolve(self):
        return resolve_compte_rendu_context(
            infos_path=self.infos_path,
            csv_path=self.csv_path,
            materialize_dir=self.csv_dir,
        )

    def test_cr_valid_has_priority(self):
        self.write_json(self.csv_dir / "contexte_general_compte_rendu.json", {"mission": "mission cr"})
        self.write_json(self.csv_dir / "contexte_general.json", {"mission": "mission generale"})

        resolved = self.resolve()

        self.assertEqual(resolved.source, "contexte_general_compte_rendu.json")
        self.assertEqual(resolved.context["mission"], "mission cr")

    def test_cr_absent_uses_general(self):
        self.write_json(self.csv_dir / "contexte_general.json", {"system": "system general"})

        resolved = self.resolve()

        self.assertEqual(resolved.source, "contexte_general.json")
        self.assertEqual(resolved.context["system"], "system general")

    def test_cr_invalid_uses_general(self):
        self.write_text(self.csv_dir / "contexte_general_compte_rendu.json", "{")
        self.write_json(self.csv_dir / "contexte_general.json", {"user": "user general"})

        resolved = self.resolve()

        self.assertEqual(resolved.source, "contexte_general.json")
        self.assertEqual(resolved.context["user"], "user general")

    def test_empty_cr_object_uses_general(self):
        self.write_json(self.csv_dir / "contexte_general_compte_rendu.json", {})
        self.write_json(self.csv_dir / "contexte_general.json", {"etat_avancement": "en cours"})

        resolved = self.resolve()

        self.assertEqual(resolved.source, "contexte_general.json")
        self.assertEqual(resolved.context["etat_avancement"], "en cours")

    def test_invalid_or_empty_files_fallback_to_infos(self):
        self.write_text(self.csv_dir / "contexte_general_compte_rendu.json", "{")
        self.write_json(self.csv_dir / "contexte_general.json", {})

        resolved = self.resolve()

        self.assertEqual(resolved.source, "infos_projet.json")
        self.assertEqual(resolved.context["mission"], "mission infos")
        self.assertTrue(resolved.path.is_file())
        materialized = json.loads(resolved.path.read_text(encoding="utf-8"))
        self.assertEqual(materialized["system"], "system infos")

    def test_valid_context_is_not_merged_with_infos(self):
        self.write_json(self.csv_dir / "contexte_general_compte_rendu.json", {"mission": "mission cr"})

        resolved = self.resolve()

        self.assertEqual(resolved.source, "contexte_general_compte_rendu.json")
        self.assertNotIn("system", resolved.context)
        self.assertNotIn("user", resolved.context)

    def test_render_and_shell_helper_resolve_same_context(self):
        self.write_text(self.csv_dir / "contexte_general_compte_rendu.json", "{")
        self.write_json(self.csv_dir / "contexte_general.json", {"mission": "mission generale"})
        rogue = self.csv_dir / "rogue_infos_context.json"
        self.write_json(rogue, {"mission": "mission pointeur infos"})
        self.write_infos(
            mission="mission infos",
            fichier_contexte_general=str(rogue),
            pcfixe={"fichier_contexte_general": str(rogue)},
        )

        cli = subprocess.run(
            [
                sys.executable,
                str(HELPER),
                "--infos",
                str(self.infos_path),
                "--csv",
                str(self.csv_path),
                "--materialize-dir",
                str(self.csv_dir),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        cli_payload = json.loads(cli.stdout)
        render = load_render_module()
        render_path = render.resolve_context_path({}, self.infos_path, self.csv_path, "")

        self.assertEqual(Path(cli_payload["path"]), self.csv_dir / "contexte_general.json")
        self.assertEqual(render_path, Path(cli_payload["path"]))

    def test_shell_launcher_calls_central_context_resolution(self):
        source = LAUNCHER.read_text(encoding="utf-8")

        self.assertIn("/pipeline/python/context_resolution.py", source)
        self.assertIn("--materialize-dir \"$CSV_DIR\"", source)
        self.assertIn("-ContextJsonPath \"$CTX_PATH\"", source)


if __name__ == "__main__":
    unittest.main()
