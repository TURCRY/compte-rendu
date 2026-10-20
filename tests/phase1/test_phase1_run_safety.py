import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PS_SCRIPT = ROOT / "cr-pipeline" / "pipeline" / "powershell" / "cr_reunion_point_mumerotes_pipeline_json.ps1"
BASH_SCRIPT = ROOT / "Scripts" / "run_compte_rendu_avec_sujets.sh"
PWSH = shutil.which("pwsh") or shutil.which("powershell")
_BASH_CANDIDATES = (shutil.which("bash"), r"C:\Program Files\Git\bin\bash.exe")
BASH = next((str(path) for path in _BASH_CANDIDATES if path and Path(path).is_file()), None)


def extract_between(text: str, start: str, end: str) -> str:
    start_pos = text.index(start)
    end_pos = text.index(end, start_pos)
    return text[start_pos:end_pos]


class TargetedSubjectCompatibilityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not PWSH:
            raise unittest.SkipTest("PowerShell indisponible (pwsh ou powershell)")
        source = PS_SCRIPT.read_text(encoding="utf-8-sig")
        cls.function_source = extract_between(
            source,
            "function Assert-TargetedSubjectReuseCompatible {",
            "$PipelineVersion =",
        )

    def run_guard(self, action: str):
        script = (
            self.function_source
            + "\n$plan = @{ Pass2E = [pscustomobject]@{ action = '"
            + action
            + "' } }\n"
            + "Assert-TargetedSubjectReuseCompatible -TargetedSubjectResume $true -PlanByName $plan\n"
            + "Write-Output 'ALLOWED'\n"
        )
        return subprocess.run(
            [PWSH, "-NoProfile", "-NonInteractive", "-Command", script],
            capture_output=True,
            text=True,
            check=False,
        )

    def test_only_subjects_with_unchanged_compatible_version_is_allowed(self):
        result = self.run_guard("REUSE")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ALLOWED", result.stdout)

    def test_only_subjects_with_different_pipeline_version_is_rejected(self):
        result = self.run_guard("REBUILD")
        self.assertNotEqual(result.returncode, 0)
        combined = result.stdout + result.stderr
        self.assertIn("REPRISE_SUJETS_INCOMPATIBLE", combined)
        self.assertIn("nouveau run complet", combined)


@unittest.skipUnless(BASH, "Git Bash indisponible")
class BashPublicationBarrierTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = BASH_SCRIPT.read_text(encoding="utf-8-sig")
        cls.failure_function = extract_between(
            cls.source,
            "record_pipeline_execution_failure() {",
            "scan_docx_placeholders() {",
        )
        cls.qa_function = extract_between(
            cls.source,
            "assert_pipeline_qa_ok_for_docx() {",
            "scan_placeholder_file() {",
        )

    def run_bash(self, body: str, *args: Path | str):
        with tempfile.TemporaryDirectory() as temp_dir:
            script = Path(temp_dir) / "harness.sh"
            python_exe = Path(sys.executable).as_posix()
            prologue = f"#!/usr/bin/env bash\npython3() {{ '{python_exe}' \"$@\"; }}\n"
            script.write_text(prologue + body, encoding="utf-8", newline="\n")
            return subprocess.run(
                [BASH, str(script), *(str(arg) for arg in args)],
                capture_output=True,
                text=True,
                check=False,
            )

    def exercise_pipeline_failure(self, existing_final: bool):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            run_dir = root / "run"
            run_dir.mkdir()
            final_path = run_dir / "global_final.json"
            original = b'{"historical": true}\n'
            if existing_final:
                final_path.write_bytes(original)
            canonical = root / "canonical.docx"
            body = self.failure_function + r'''
run_dir="$1"
pipeline_rc="$2"
canonical="$3"
if [[ $pipeline_rc -ne 0 ]]; then
  record_pipeline_execution_failure "$run_dir" "$pipeline_rc"
  exit "$pipeline_rc"
fi
printf 'PUBLISHED' > "$canonical"
'''
            result = self.run_bash(body, run_dir, "17", canonical)
            self.assertEqual(result.returncode, 17, result.stderr)
            self.assertFalse(canonical.exists())
            status = json.loads((run_dir / "pipeline_execution_status.json").read_text(encoding="utf-8"))
            self.assertEqual(status["pipeline_exit_code"], 17)
            self.assertFalse(status["docx_render_attempted"])
            self.assertFalse(status["canonical_publication_attempted"])
            if existing_final:
                self.assertEqual(final_path.read_bytes(), original)
            else:
                self.assertFalse(final_path.exists())

    def test_powershell_failure_in_empty_run_preserves_code_and_blocks_publication(self):
        self.exercise_pipeline_failure(existing_final=False)

    def test_powershell_failure_with_old_global_final_preserves_it_but_does_not_publish(self):
        self.exercise_pipeline_failure(existing_final=True)

    def test_status_write_failure_does_not_replace_original_pipeline_code(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            missing_run_dir = root / "missing" / "run"
            canonical = root / "canonical.docx"
            body = self.failure_function + r'''
run_dir="$1"
pipeline_rc="$2"
canonical="$3"
if [[ $pipeline_rc -ne 0 ]]; then
  record_pipeline_execution_failure "$run_dir" "$pipeline_rc"
  exit "$pipeline_rc"
fi
printf 'PUBLISHED' > "$canonical"
'''
            result = self.run_bash(body, missing_run_dir, "23", canonical)
            self.assertEqual(result.returncode, 23)
            self.assertFalse(canonical.exists())
            self.assertIn("le code initial 23 reste prioritaire", result.stdout)

    def test_missing_qa_is_not_validation(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            body = "ALLOW_CRITICAL_QA=0\n" + self.qa_function + '\nassert_pipeline_qa_ok_for_docx "$1"\n'
            result = self.run_bash(body, Path(temp_dir))
            self.assertEqual(result.returncode, 30)
            self.assertIn("pipeline_qa_status.json absent", result.stdout)

    def test_docx_only_historical_run_with_valid_qa_is_allowed(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            run_dir = Path(temp_dir)
            (run_dir / "pipeline_qa_status.json").write_text(
                json.dumps({"ok": True, "critical_warnings": []}), encoding="utf-8"
            )
            body = "ALLOW_CRITICAL_QA=0\n" + self.qa_function + '\nassert_pipeline_qa_ok_for_docx "$1"\n'
            result = self.run_bash(body, run_dir)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("pipeline_qa_status ok", result.stdout)
            self.assertLess(self.source.index("if [[ $DOCX_ONLY -eq 1"), self.source.index('"${cmd[@]}"'))

    def test_failure_barrier_precedes_every_full_run_publication_step(self):
        command_pos = self.source.index('"${cmd[@]}"')
        barrier_pos = self.source.index("if [[ $rc -ne 0 ]]", command_pos)
        render_pos = self.source.index('echo "=== Generation DOCX final ==="', barrier_pos)
        canonical_pos = self.source.index("publish_docx_to_canonical_dir", render_pos)
        exit_pos = self.source.index('exit "$rc"', barrier_pos)
        self.assertLess(barrier_pos, exit_pos)
        self.assertLess(exit_pos, render_pos)
        self.assertLess(render_pos, canonical_pos)


if __name__ == "__main__":
    unittest.main()
