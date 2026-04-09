import os
import shutil
import uuid
import subprocess
import json
from pathlib import Path
from flask import Flask, request, jsonify

app = Flask(__name__)

BASE_DATA_DIR = Path(os.environ.get("PIPELINE_DATA_DIR", "/data/jobs"))
PS_SCRIPT     = Path(os.environ.get("PIPELINE_SCRIPT", "/pipeline/cr_reunion_pipeline_fulljson.ps1"))

# config LLM (adapter OpenAI du NAS)
DEFAULT_PROVIDER = os.environ.get("PIPELINE_PROVIDER", "openai")
DEFAULT_API_BASE = os.environ.get("PIPELINE_API_BASE", "http://openai-adapter:5055")
DEFAULT_MODEL    = os.environ.get("PIPELINE_MODEL", "mistral:7b-instruct-q4")
DEFAULT_PRESET   = os.environ.get("PIPELINE_PRESET", "equilibre")


def _coalesce_form(name: str, default: str) -> str:
    v = request.form.get(name)
    if v is None:
        return default
    v = v.strip()
    return v if v else default



@app.post("/pipeline/run")
def run_pipeline():
    if "file" not in request.files:
        return jsonify({"error": "champ 'file' manquant (CSV)"}), 400

    f = request.files["file"]
    if not f.filename.lower().endswith(".csv"):
        return jsonify({"error": "format attendu : .csv"}), 400

    # options facultatives
    preset   = _coalesce_form("preset", DEFAULT_PRESET)
    provider = _coalesce_form("provider", DEFAULT_PROVIDER)
    model    = _coalesce_form("model", DEFAULT_MODEL)

    api_base = _coalesce_form("api_base", DEFAULT_API_BASE)


    job_id = str(uuid.uuid4())
    job_dir = BASE_DATA_DIR / job_id
    out_dir = job_dir / "out"
    job_dir.mkdir(parents=True, exist_ok=True)
    out_dir.mkdir(parents=True, exist_ok=True)

    csv_path = job_dir / "input.csv"
    f.save(csv_path)

    # appel du script PowerShell
    cmd = [
        "pwsh",
        str(PS_SCRIPT),
        "-CsvPath", str(csv_path),
        "-OutDir", str(out_dir),
        "-Provider", provider,
        "-ApiBase", api_base,
        "-Model", model,
        "-Preset", preset
    ]


    app.logger.warning("api_base_effectif=%r", api_base)
    app.logger.warning("CMD=%s", " ".join(cmd))

    completed = subprocess.run(cmd, check=False, capture_output=True, text=True)


    if completed.returncode != 0:
        return jsonify({
            "error": "Le pipeline a échoué",
            "stdout": completed.stdout,
            "stderr": completed.stderr
        }), 500

    final_path = out_dir / "global_final.json"
    if not final_path.exists():
        return jsonify({"error": "global_final.json introuvable après exécution"}), 500

    try:
        data = json.loads(final_path.read_text(encoding="utf-8"))
    except Exception as e:
        return jsonify({"error": f"JSON final invalide: {e}"}), 500

    return jsonify(data), 200

@app.get("/health")
def health():
    return jsonify({"status": "ok"}), 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8090")))

