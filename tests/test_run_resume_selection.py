from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
LAUNCHER = ROOT / "Scripts" / "run_compte_rendu_avec_sujets.sh"


class RunResumeSelectionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = LAUNCHER.read_text(encoding="utf-8")

    def test_empty_existing_run_does_not_select_latest_implicitly(self):
        self.assertNotIn('elif [[ $FORCE -eq 0 ]]', self.source)
        self.assertIn('Nouveau run créé : $OUT_DIR (aucune reprise explicite)', self.source)

    def test_resume_latest_is_explicit(self):
        self.assertIn('--resume-latest) RESUME_LATEST=1', self.source)
        self.assertIn('elif [[ $RESUME_LATEST -eq 1 ]]', self.source)

    def test_targeted_resume_requires_selector(self):
        self.assertIn('ce mode de reprise exige --existing-run, --out-dir ou --resume-latest', self.source)

    def test_plan_only_exits_before_output_creation(self):
        plan_index = self.source.index('if [[ $PLAN_ONLY -eq 1 ]]')
        create_index = self.source.index('# Créer OutDir + dossier logs', plan_index)
        self.assertLess(plan_index, create_index)
        self.assertIn('-PlanOnly', self.source[plan_index:create_index])

    def test_mtimes_are_not_normalized_after_pipeline(self):
        self.assertNotIn('xargs -0 -I{} touch -m', self.source)


if __name__ == "__main__":
    unittest.main()
