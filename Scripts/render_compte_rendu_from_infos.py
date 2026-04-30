import argparse
import json
import os
import re
import shutil
import subprocess
import uuid
from datetime import datetime
from pathlib import Path

import requests

DEFAULT_RENDER_URL = "http://192.168.1.20:8081/render?format=docx"
DEFAULT_CONTAINER = "cr-pipeline"
DEFAULT_PIPELINE_SCRIPT = "/pipeline/powershell/cr_reunion_point_mumerotes_pipeline_json.ps1"
DEFAULT_PROVIDER = "openai"
DEFAULT_API_BASE = "http://openai-adapter:5055"
DEFAULT_PSEUDO_API_BASE = ""
DEFAULT_PSEUDO_API_KEY = ""
DEFAULT_MODEL_PASS1 = "annoter_segments_remote"
DEFAULT_MODEL_PASS2 = "annoter_segments_remote"
DEFAULT_MODEL_PASS3 = "annoter_segments_remote_alt"
DEFAULT_PRESET = "equilibre"
DEFAULT_API_KEY = os.environ.get("CR_PIPELINE_API_KEY", "*CRpy#VrWz#5zh&F%ww6zY24U")
HOST_AFFAIRES_ROOT = Path("/volume1/Affaires")
CONTAINER_AFFAIRES_ROOT = Path("/data/Affaires")
FINAL_JSON_FILENAMES = (
    "global.json",
    "global_meeting.json",
    "global_by_sujet.json",
    "global_final.json",
)


def pipeline_uses_remote_llm(provider: str, *models: str) -> bool:
    if (provider or "").strip().lower() != "openai":
        return False
    return any("remote" in (model or "").strip().lower() for model in models)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Orchestre le pipeline compte-rendu reel a partir d'un infos_projet.json."
    )
    parser.add_argument("--infos", required=True, help="Chemin vers infos_projet.json.")
    parser.add_argument("--render-url", default=DEFAULT_RENDER_URL, help="URL HTTP de cr-render.")
    parser.add_argument("--container", default=DEFAULT_CONTAINER, help="Nom du conteneur Docker cr-pipeline.")
    parser.add_argument("--pipeline-script", default=DEFAULT_PIPELINE_SCRIPT, help="Chemin du script PowerShell dans le conteneur.")
    parser.add_argument("--csv", default="", help="Override explicite pour le CSV de transcription.")
    parser.add_argument("--context", default="", help="Override explicite pour le JSON de contexte.")
    parser.add_argument("--sujets", default="", help="Override explicite pour Sujets.xlsx.")
    parser.add_argument("--participants", default="", help="Override explicite pour Participants.xlsx.")
    parser.add_argument("--provider", default="", help="Override du provider pipeline.")
    parser.add_argument("--api-base", default="", help="Override de l'API base pipeline.")
    parser.add_argument("--model-pass1", default="", help="Override ModelPass1.")
    parser.add_argument("--model-pass2", default="", help="Override ModelPass2.")
    parser.add_argument("--model-pass3", default="", help="Override ModelPass3.")
    parser.add_argument("--preset", default="", help="Override preset pipeline.")
    parser.add_argument("--api-key", default=DEFAULT_API_KEY, help="API key transmise au script PowerShell.")
    parser.add_argument("--pseudo-api-base", default="", help="Base URL du service Flask de pseudonymisation.")
    parser.add_argument("--pseudo-api-key", default=DEFAULT_PSEUDO_API_KEY, help="Cle API transmise au service Flask de pseudonymisation.")
    parser.add_argument("--pseudo-job-id", default="", help="Job ID de pseudonymisation a reutiliser en mode rendu seul.")
    parser.add_argument("--global-final", default="", help="Chemin vers un global_final.json deja produit. Si renseigne, le pipeline n'est pas relance.")
    parser.add_argument("--docx-only", action="store_true", help="Rendu DOCX seul depuis le global_final.json canonique, sans relancer le pipeline.")
    parser.add_argument("--pseudonymize-remote", dest="pseudonymize_remote", action="store_true", help="Active la pseudonymisation pour les flux distants compte-rendu.")
    parser.add_argument("--no-pseudonymize-remote", dest="pseudonymize_remote", action="store_false", help="Desactive la pseudonymisation pour les flux distants compte-rendu.")
    parser.add_argument("--force", action="store_true", help="Ajoute -Force a la commande pipeline.")
    parser.set_defaults(pseudonymize_remote=True)
    return parser.parse_args()


def resolve_path_like(value: str, *, base_dir: Path) -> Path:
    path = Path(str(value or "").strip())
    if not str(path):
        return path
    if path.is_absolute():
        return path
    return (base_dir / path).resolve()


def normalize_affaires_path(path: Path | str, *, must_exist: bool = False) -> Path:
    candidate = Path(str(path or "").strip())
    if not str(candidate):
        return candidate

    variants = [candidate]
    raw = str(candidate)
    host_prefix = str(HOST_AFFAIRES_ROOT)
    container_prefix = str(CONTAINER_AFFAIRES_ROOT)
    if raw == host_prefix or raw.startswith(host_prefix + "/"):
        variants.append(CONTAINER_AFFAIRES_ROOT / raw[len(host_prefix):].lstrip("/"))
    elif raw == container_prefix or raw.startswith(container_prefix + "/"):
        variants.append(HOST_AFFAIRES_ROOT / raw[len(container_prefix):].lstrip("/"))

    for variant in variants:
        if variant.exists():
            return variant
    return candidate if not must_exist else variants[-1]


def load_infos(infos_path: Path) -> dict:
    text = infos_path.read_text(encoding="utf-8-sig")
    first_line = text.lstrip().splitlines()[0] if text.lstrip().splitlines() else ""
    if first_line.startswith("Usage:"):
        raise RuntimeError(f"infos_projet.json semble corrompu par une sortie Usage: {infos_path}")
    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        raise RuntimeError(
            f"infos_projet.json n'est pas un JSON valide : {infos_path} "
            f"(ligne {exc.lineno}, colonne {exc.colno}: {exc.msg})"
        ) from exc
    if not isinstance(data, dict):
        raise RuntimeError(f"infos_projet.json doit contenir un objet JSON : {infos_path}")
    return data


def load_env_file(path: Path) -> None:
    if not path.exists():
        return
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = value


def load_env_candidates(infos_path: Path) -> None:
    script_dir = Path(__file__).resolve().parent
    for candidate in (
        Path.cwd() / ".env",
        script_dir / ".env",
        script_dir.parent / ".env",
        infos_path.parent / ".env",
    ):
        load_env_file(candidate)


def resolve_compte_rendu_config(infos: dict) -> dict:
    compte_rendu = infos.get("compte_rendu")
    return compte_rendu if isinstance(compte_rendu, dict) else {}


def depseudonymize_final_payload(payload_text: str, *, pseudo_api_base: str, pseudo_api_key: str, job_id: str) -> dict:
    response = requests.post(
        pseudo_api_base.rstrip("/") + "/depseudonymize",
        json={
            "text": payload_text,
            "job_id": job_id,
            "mode": "compte_rendu_final",
        },
        headers={"x-api-key": pseudo_api_key},
        timeout=1800,
    )
    response.raise_for_status()
    data = response.json() or {}
    clear_text = data.get("text_depseudonymized") or data.get("text") or payload_text
    clear_text = (clear_text or "").lstrip("\ufeff").strip()
    return json.loads(clear_text)




def choose_first_existing(candidates: list[Path]) -> Path | None:
    for candidate in candidates:
        if candidate and candidate.exists():
            return candidate
    return None


def choose_first_non_empty(values: list[str]) -> str:
    for value in values:
        text = str(value or "").strip()
        if text:
            return text
    return ""


def _find_affaires_root_from_path(candidate: Path | str) -> Path | None:
    raw = str(candidate or "").strip()
    if not raw:
        return None
    path = Path(raw)
    parts = path.parts
    for idx, part in enumerate(parts):
        if str(part).lower() == "affaires":
            return Path(*parts[: idx + 1])
    return None


def resolve_pseudo_api_base(
    args: argparse.Namespace,
    compte_rendu_cfg: dict,
    metadata_cfg: dict | None = None,
    pseudo_context_cfg: dict | None = None,
) -> str:
    metadata_cfg = metadata_cfg or {}
    pseudo_context_cfg = pseudo_context_cfg or {}
    if args.docx_only:
        return choose_first_non_empty([
            args.pseudo_api_base,
            os.environ.get("CR_PSEUDO_API_BASE", ""),
            os.environ.get("PSEUDO_API_BASE", ""),
            pseudo_context_cfg.get("pseudo_api_base", ""),
            metadata_cfg.get("pseudo_api_base", ""),
            compte_rendu_cfg.get("pseudo_api_base", ""),
        ])
    return choose_first_non_empty([
        args.pseudo_api_base,
        compte_rendu_cfg.get("pseudo_api_base", ""),
        os.environ.get("CR_PSEUDO_API_BASE", ""),
        os.environ.get("PSEUDO_API_BASE", ""),
    ])


def resolve_docx_only_global_final(final_output_dir: Path, explicit_global_final: Path | None = None) -> tuple[Path, list[Path]]:
    tested: list[Path] = []
    if explicit_global_final:
        explicit_global_final = normalize_affaires_path(explicit_global_final)
        tested.append(explicit_global_final)
        if explicit_global_final.exists():
            return explicit_global_final, tested
        raise FileNotFoundError(
            "global_final.json explicite introuvable. Chemins testes : "
            + " ; ".join(str(path) for path in tested)
        )

    direct = normalize_affaires_path(final_output_dir / "global_final.json")
    tested.append(direct)
    if direct.exists():
        return direct, tested

    out_dir = normalize_affaires_path(final_output_dir / "out")
    run_candidates: list[Path] = []
    if out_dir.exists():
        run_candidates = sorted(
            (normalize_affaires_path(path) for path in out_dir.glob("*/global_final.json")),
            key=lambda path: path.stat().st_mtime if path.exists() else 0,
            reverse=True,
        )
    tested.extend(run_candidates)
    if run_candidates:
        return run_candidates[0], tested

    raise FileNotFoundError(
        "global_final.json introuvable en mode docx-only. Chemins testes : "
        + " ; ".join(str(path) for path in tested)
    )


def resolve_docx_only_logs_dirs(final_output_dir: Path, global_final_path: Path) -> list[Path]:
    logs_dirs: list[Path] = []
    canonical_logs = normalize_affaires_path(final_output_dir / "logs")
    logs_dirs.append(canonical_logs)

    parent = normalize_affaires_path(global_final_path.parent)
    run_logs = normalize_affaires_path(parent / "logs")
    if run_logs != canonical_logs:
        logs_dirs.append(run_logs)

    return logs_dirs


def load_json_object(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig"))
    except Exception as exc:
        print(f"[CR][PSEUDO]   ignore, JSON illisible : {path} ({exc})")
        return {}
    if not isinstance(data, dict):
        print(f"[CR][PSEUDO]   ignore, JSON non objet : {path}")
        return {}
    return data


def resolve_pseudo_context(final_output_dir: Path, logs_dirs: list[Path]) -> tuple[dict, Path | None]:
    direct = normalize_affaires_path(final_output_dir / "pseudo_context.json")
    print(f"[CR][PSEUDO] pseudo_context direct teste : {direct}")
    if direct.exists():
        data = load_json_object(direct)
        if data:
            print(f"[CR][PSEUDO] pseudo_context selectionne : {direct}")
            return data, direct

    candidates: list[Path] = []
    for logs_dir in logs_dirs:
        logs_dir = normalize_affaires_path(logs_dir)
        if logs_dir.exists():
            candidates.extend(logs_dir.glob("pseudo_context_*.json"))
    candidates = sorted(candidates, key=lambda path: path.stat().st_mtime, reverse=True)
    print(f"[CR][PSEUDO] pseudo_context_*.json trouves : {len(candidates)}")
    for candidate in candidates:
        print(f"[CR][PSEUDO] - pseudo_context candidat : {candidate}")
        data = load_json_object(candidate)
        if data:
            print(f"[CR][PSEUDO] pseudo_context selectionne : {candidate}")
            return data, candidate
    return {}, None


def _short_metadata_summary(data: dict) -> str:
    fields = []
    for key in ("timestamp", "pseudo_job_id", "pseudo_api_base", "provider"):
        value = str(data.get(key) or "").strip()
        if value:
            fields.append(f"{key}={value}")
    return ", ".join(fields) if fields else "aucun champ pseudo/timestamp"


def resolve_latest_run_metadata(logs_dirs: list[Path]) -> tuple[dict, Path | None]:
    existing_logs_dirs = []
    for logs_dir in logs_dirs:
        logs_dir = normalize_affaires_path(logs_dir)
        if logs_dir.exists():
            existing_logs_dirs.append(logs_dir)
        else:
            print(f"[CR][PSEUDO] Dossier logs introuvable : {logs_dir}")
    if not existing_logs_dirs:
        return {}, None

    candidates = []
    for logs_dir in existing_logs_dirs:
        candidates.extend(logs_dir.glob("run_metadata_*.json"))
    candidates = sorted(candidates, key=lambda path: path.stat().st_mtime, reverse=True)
    print(f"[CR][PSEUDO] run_metadata_*.json trouves : {len(candidates)}")
    for candidate in candidates:
        print(f"[CR][PSEUDO] - metadata candidat : {candidate}")

    fallback_data: dict = {}
    fallback_path: Path | None = None
    for candidate in candidates:
        try:
            data = json.loads(candidate.read_text(encoding="utf-8-sig"))
        except Exception as exc:
            print(f"[CR][PSEUDO]   ignore, JSON illisible : {candidate} ({exc})")
            continue
        if isinstance(data, dict):
            print(f"[CR][PSEUDO]   contenu : {_short_metadata_summary(data)}")
            if not fallback_path:
                fallback_data, fallback_path = data, candidate
            if str(data.get("pseudo_job_id") or "").strip():
                return data, candidate
        else:
            print(f"[CR][PSEUDO]   ignore, metadata non objet JSON : {candidate}")
    return fallback_data, fallback_path


def resolve_pseudo_job_id_from_logs(logs_dirs: list[Path]) -> tuple[str, Path | None]:
    existing_logs_dirs = []
    for logs_dir in logs_dirs:
        logs_dir = normalize_affaires_path(logs_dir)
        if logs_dir.exists():
            existing_logs_dirs.append(logs_dir)
    if not existing_logs_dirs:
        return "", None

    candidates = []
    for logs_dir in existing_logs_dirs:
        candidates.extend(logs_dir.glob("run_*.log"))
    candidates = sorted(candidates, key=lambda path: path.stat().st_mtime, reverse=True)
    print(f"[CR][PSEUDO] run_*.log trouves : {len(candidates)}")
    patterns = [
        re.compile(r"PseudoJobId\s*[:=]\s*(?P<value>\S+)", re.I),
        re.compile(r"-PseudoJobId\s+(?P<value>\S+)", re.I),
        re.compile(r"pseudo_job_id[\"']?\s*[:=]\s*[\"']?(?P<value>[^\"'\s,}]+)", re.I),
    ]
    for candidate in candidates:
        print(f"[CR][PSEUDO] - log candidat : {candidate}")
        try:
            text = candidate.read_text(encoding="utf-8", errors="ignore")
        except Exception as exc:
            print(f"[CR][PSEUDO]   ignore, log illisible : {candidate} ({exc})")
            continue
        for pattern in patterns:
            match = pattern.search(text)
            if match:
                value = match.group("value").strip().strip('"').strip("'")
                if value:
                    print(f"[CR][PSEUDO]   pseudo_job_id trouve dans log : {candidate}")
                    return value, candidate
    return "", None


def resolve_runtime_value(args: argparse.Namespace, infos: dict, compte_rendu_cfg: dict, name: str, default: str) -> str:
    arg_value = getattr(args, name, "")
    return choose_first_non_empty([
        arg_value,
        compte_rendu_cfg.get(name, ""),
        infos.get(name, ""),
        default,
    ])


def resolve_output_root(infos: dict, infos_path: Path, csv_path: Path | None = None) -> Path:
    pcfixe = infos.get("pcfixe") or {}
    configured = choose_first_non_empty([
        os.environ.get("CR_ROOT_AFFAIRES", ""),
        os.environ.get("AFFAIRES_ROOT", ""),
        pcfixe.get("root_affaires", ""),
        infos.get("root_affaires", ""),
    ])
    if configured:
        return normalize_affaires_path(Path(configured))

    candidates = [
        infos_path,
        csv_path,
        resolve_path_like(str(pcfixe.get("fichier_transcription") or ""), base_dir=infos_path.parent) if pcfixe.get("fichier_transcription") else None,
        resolve_path_like(str(infos.get("fichier_transcription") or ""), base_dir=infos_path.parent) if infos.get("fichier_transcription") else None,
    ]
    for candidate in candidates:
        root = _find_affaires_root_from_path(candidate)
        if root is not None:
            return normalize_affaires_path(root)

    raise RuntimeError(
        "Racine Affaires introuvable. Renseignez CR_ROOT_AFFAIRES/AFFAIRES_ROOT "
        "ou pcfixe.root_affaires dans infos_projet.json."
    )


def resolve_output_dir(infos: dict, infos_path: Path, csv_path: Path | None = None) -> Path:
    id_affaire = str(infos.get("id_affaire") or "").strip()
    id_captation = str(infos.get("id_captation") or "").strip()
    if not id_affaire or not id_captation:
        raise RuntimeError("id_affaire ou id_captation manquant dans infos_projet.json.")

    root_affaires = resolve_output_root(infos, infos_path, csv_path)
    output_dir = normalize_affaires_path(root_affaires / id_affaire / "BE_Traitement_captations" / id_captation / "compte_rendu_LLM")
    output_dir.mkdir(parents=True, exist_ok=True)
    return output_dir


def resolve_csv_path(infos: dict, infos_path: Path, override: str) -> Path:
    candidates = []
    if override:
        candidates.append(resolve_path_like(override, base_dir=infos_path.parent))
    for raw in (
        infos.get("fichier_transcription"),
        (infos.get("pcfixe") or {}).get("fichier_transcription"),
    ):
        if raw:
            candidates.append(resolve_path_like(str(raw), base_dir=infos_path.parent))

    csv_path = choose_first_existing(candidates)
    if not csv_path:
        raise FileNotFoundError("CSV de transcription introuvable depuis infos_projet.json.")
    return csv_path


def resolve_context_path(infos: dict, infos_path: Path, csv_path: Path, override: str) -> Path:
    candidates: list[Path] = []
    if override:
        candidates.append(resolve_path_like(override, base_dir=infos_path.parent))
    for raw in (
        infos.get("fichier_contexte_general"),
        (infos.get("pcfixe") or {}).get("fichier_contexte_general"),
    ):
        if raw:
            candidates.append(resolve_path_like(str(raw), base_dir=infos_path.parent))

    csv_dir = csv_path.parent
    candidates.append(csv_dir / "contexte_general_compte_rendu.json")
    candidates.append(csv_dir / "contexte_general.json")

    context_path = choose_first_existing(candidates)
    if not context_path:
        raise FileNotFoundError("Contexte JSON introuvable (override, infos_projet.json ou dossier du CSV).")
    return context_path


def resolve_excel_path(infos: dict, infos_path: Path, csv_path: Path, override: str, keys: tuple[str, ...], fallback_name: str) -> Path:
    candidates: list[Path] = []
    if override:
        candidates.append(resolve_path_like(override, base_dir=infos_path.parent))

    pcfixe = infos.get("pcfixe") or {}
    for key in keys:
        raw = infos.get(key)
        if raw:
            candidates.append(resolve_path_like(str(raw), base_dir=infos_path.parent))
        raw_pc = pcfixe.get(key)
        if raw_pc:
            candidates.append(resolve_path_like(str(raw_pc), base_dir=infos_path.parent))

    candidates.append(csv_path.parent / fallback_name)

    resolved = choose_first_existing(candidates)
    if not resolved:
        raise FileNotFoundError(f"Fichier {fallback_name} introuvable (override, infos_projet.json ou dossier du CSV).")
    return resolved


def win_to_container_affaires_path(host_path: Path, root_affaires: Path) -> str:
    host_str = str(host_path)
    root_str = str(root_affaires)

    if host_str.startswith(root_str.rstrip("\\/")):
        rel = host_str[len(root_str.rstrip("\\/")):].lstrip("\\/")
        return "/data/Affaires/" + rel.replace("\\", "/")

    patterns = [
        re.compile(r"^[A-Za-z]:\\Affaires\\(?P<rel>.+)$", re.I),
        re.compile(r"^\\\\192\.168\.0\.155\\Affaires\\(?P<rel>.+)$", re.I),
        re.compile(r"^\\\\192\.168\.1\.20\\Affaires\\(?P<rel>.+)$", re.I),
    ]
    for pattern in patterns:
        match = pattern.match(host_str)
        if match:
            return "/data/Affaires/" + match.group("rel").replace("\\", "/")

    raise RuntimeError(
        "Chemin non convertible vers /data/Affaires pour Docker : "
        f"{host_path}"
    )


def build_pipeline_command(args: argparse.Namespace, infos: dict, csv_path: Path, context_path: Path, sujets_path: Path, participants_path: Path, out_dir_host: Path, pseudo_job_id: str) -> list[str]:
    root_affaires = resolve_output_root(infos, Path(args.infos).resolve(), csv_path)
    out_dir_host.mkdir(parents=True, exist_ok=True)

    compte_rendu_cfg = resolve_compte_rendu_config(infos)
    provider = resolve_runtime_value(args, infos, compte_rendu_cfg, "provider", DEFAULT_PROVIDER)
    api_base = resolve_runtime_value(args, infos, compte_rendu_cfg, "api_base", DEFAULT_API_BASE)
    model_pass1 = resolve_runtime_value(args, infos, compte_rendu_cfg, "model_pass1", DEFAULT_MODEL_PASS1)
    model_pass2 = resolve_runtime_value(args, infos, compte_rendu_cfg, "model_pass2", DEFAULT_MODEL_PASS2)
    model_pass3 = resolve_runtime_value(args, infos, compte_rendu_cfg, "model_pass3", DEFAULT_MODEL_PASS3)
    preset = resolve_runtime_value(args, infos, compte_rendu_cfg, "preset", DEFAULT_PRESET)

    cmd = [
        "docker", "exec", args.container,
        "pwsh", args.pipeline_script,
        "-CsvPath", win_to_container_affaires_path(csv_path, root_affaires),
        "-OutDir", win_to_container_affaires_path(out_dir_host, root_affaires),
        "-ContextJsonPath", win_to_container_affaires_path(context_path, root_affaires),
        "-SujetsPath", win_to_container_affaires_path(sujets_path, root_affaires),
        "-ApiKey", args.api_key,
        "-ParticipantsPath", win_to_container_affaires_path(participants_path, root_affaires),
        "-Provider", provider,
        "-ApiBase", api_base,
        "-ModelPass1", model_pass1,
        "-ModelPass2", model_pass2,
        "-ModelPass3", model_pass3,
        "-Preset", preset,
    ]
    if args.pseudonymize_remote and pipeline_uses_remote_llm(provider, model_pass1, model_pass2, model_pass3):
        if not args.pseudo_api_base.strip():
            raise RuntimeError("Pseudonymisation distante activee mais pseudo_api_base est vide.")
        if not args.pseudo_api_key.strip():
            raise RuntimeError("Pseudonymisation distante activee mais LOCAL_LLM_API_KEY / --pseudo-api-key est absent.")
        cmd.extend([
            "-PseudonymizeRemote",
            "-PseudoApiBase", args.pseudo_api_base,
            "-PseudoApiKey", args.pseudo_api_key,
            "-PseudoJobId", pseudo_job_id,
            "-PseudoParticipantsPath", str(participants_path),
        ])
    if args.force:
        cmd.append("-Force")
    return cmd


def build_docx_name(infos: dict) -> str:
    id_affaire = str(infos.get("id_affaire") or "").strip()
    id_captation = str(infos.get("id_captation") or "").strip()
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    return f"compte_rendu_{id_affaire}_{id_captation}_V_{ts}.docx"


def build_unique_job_id(prefix: str = "job") -> str:
    ts = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
    return f"{prefix}_{ts}_{os.getpid()}_{uuid.uuid4().hex[:8]}"


def promote_final_jsons(run_output_dir: Path, final_output_dir: Path) -> None:
    for filename in FINAL_JSON_FILENAMES:
        source = run_output_dir / filename
        if not source.exists():
            raise FileNotFoundError(f"Artefact final introuvable : {source}")
        shutil.copy2(source, final_output_dir / filename)


def main() -> int:
    args = parse_args()
    infos_path_raw = resolve_path_like(args.infos, base_dir=Path.cwd())
    infos_path = normalize_affaires_path(infos_path_raw)
    if not infos_path.exists():
        raise FileNotFoundError(f"infos_projet.json introuvable : {infos_path}")

    load_env_candidates(infos_path)
    args.pseudo_api_key = args.pseudo_api_key or os.environ.get("LOCAL_LLM_API_KEY", "").strip()

    infos = load_infos(infos_path)
    compte_rendu_cfg = resolve_compte_rendu_config(infos)
    id_affaire = str(infos.get("id_affaire") or "").strip()
    id_captation = str(infos.get("id_captation") or "").strip()
    if not id_affaire or not id_captation:
        raise RuntimeError("id_affaire ou id_captation manquant dans infos_projet.json.")

    print(f"[CR] Infos recu : {infos_path_raw}")
    print(f"[CR] Infos normalise : {infos_path}")

    csv_path_for_output = None
    if infos.get("fichier_transcription"):
        try:
            csv_path_for_output = resolve_csv_path(infos, infos_path, args.csv)
        except Exception:
            csv_path_for_output = None
    final_output_dir = resolve_output_dir(infos, infos_path, csv_path_for_output)
    final_output_dir = normalize_affaires_path(final_output_dir)

    global_final_override = resolve_path_like(args.global_final, base_dir=infos_path.parent) if args.global_final else None
    logs_dirs: list[Path] = [normalize_affaires_path(final_output_dir / "logs")]
    if args.docx_only:
        global_final_path, global_final_tested = resolve_docx_only_global_final(final_output_dir, global_final_override)
        logs_dirs = resolve_docx_only_logs_dirs(final_output_dir, global_final_path)
        print("[CR] global_final candidats testes :")
        for candidate in global_final_tested:
            print(f"[CR] - {candidate}")

    metadata_cfg: dict = {}
    metadata_path: Path | None = None
    pseudo_context_cfg: dict = {}
    pseudo_context_path: Path | None = None
    log_pseudo_job_id = ""
    log_pseudo_job_path: Path | None = None
    if args.docx_only:
        pseudo_context_cfg, pseudo_context_path = resolve_pseudo_context(final_output_dir, logs_dirs)
        metadata_cfg, metadata_path = resolve_latest_run_metadata(logs_dirs)
        if metadata_path:
            print(f"[CR][PSEUDO] Metadata selectionne : {metadata_path}")
        if not str(metadata_cfg.get("pseudo_job_id") or "").strip():
            log_pseudo_job_id, log_pseudo_job_path = resolve_pseudo_job_id_from_logs(logs_dirs)

    pseudo_api_base = resolve_pseudo_api_base(args, compte_rendu_cfg, metadata_cfg, pseudo_context_cfg)
    pseudo_job_id_override = choose_first_non_empty([
        args.pseudo_job_id,
        pseudo_context_cfg.get("pseudo_job_id", ""),
        metadata_cfg.get("pseudo_job_id", ""),
        compte_rendu_cfg.get("pseudo_job_id", ""),
        log_pseudo_job_id,
    ])
    args.pseudo_api_base = pseudo_api_base

    if args.docx_only:
        pseudo_job_id = pseudo_job_id_override
        if args.pseudonymize_remote and not pseudo_job_id:
            expected_metadata = " / ".join(str(logs_dir / "run_metadata_*.json") for logs_dir in logs_dirs)
            expected_log = " / ".join(str(logs_dir / "run_*.log") for logs_dir in logs_dirs)
            raise RuntimeError(
                "pseudo_job_id introuvable pour la depseudonymisation finale. "
                "Renseignez --pseudo-job-id, restaurez compte_rendu.pseudo_job_id "
                "ou verifiez compte_rendu_LLM/pseudo_context.json, "
                f"ou verifiez les fichiers attendus : {expected_metadata} / {expected_log}. "
                "Sans pseudo_job_id associe au registre de pseudonymisation, le DOCX ne peut pas etre depseudonymise."
            )
    elif global_final_override:
        global_final_override = normalize_affaires_path(global_final_override)
        global_final_path = global_final_override
        if not global_final_path.exists():
            raise FileNotFoundError(f"global_final.json introuvable : {global_final_path}")
        pseudo_job_id = pseudo_job_id_override
        if args.pseudonymize_remote and not pseudo_job_id:
            expected_metadata = logs_dirs[0] / "run_metadata_*.json"
            expected_log = logs_dirs[0] / "run_*.log"
            raise RuntimeError(
                "pseudo_job_id introuvable pour la depseudonymisation finale. "
                "Renseignez --pseudo-job-id, restaurez compte_rendu.pseudo_job_id "
                "ou verifiez compte_rendu_LLM/pseudo_context.json, "
                f"ou verifiez les fichiers attendus : {expected_metadata} / {expected_log}. "
                "Sans pseudo_job_id associe au registre de pseudonymisation, le DOCX ne peut pas etre depseudonymise."
            )
    else:
        csv_path = resolve_csv_path(infos, infos_path, args.csv)
        final_output_dir = resolve_output_dir(infos, infos_path, csv_path)
        context_path = resolve_context_path(infos, infos_path, csv_path, args.context)
        sujets_path = resolve_excel_path(infos, infos_path, csv_path, args.sujets, ("fichier_sujets", "sujets_path"), "Sujets.xlsx")
        participants_path = resolve_excel_path(infos, infos_path, csv_path, args.participants, ("fichier_participants", "participants_path"), "Participants.xlsx")
        job_tag = build_unique_job_id()
        pseudo_job_id = f"cr_{id_affaire}_{id_captation}_{job_tag}"
        pipeline_out_dir = final_output_dir / "out" / job_tag
        pipeline_command = build_pipeline_command(args, infos, csv_path, context_path, sujets_path, participants_path, pipeline_out_dir, pseudo_job_id)

        print("[CR] Commande pipeline executee :")
        print(subprocess.list2cmdline(pipeline_command))

        completed = subprocess.run(pipeline_command, capture_output=True, text=True)
        if completed.stdout:
            print(completed.stdout)
        if completed.stderr:
            print(completed.stderr)
        if completed.returncode != 0:
            raise RuntimeError(f"Echec pipeline (code {completed.returncode}).")

        global_final_path = pipeline_out_dir / "global_final.json"
        if not global_final_path.exists():
            raise FileNotFoundError(f"global_final.json introuvable : {global_final_path}")
        promote_final_jsons(pipeline_out_dir, final_output_dir)
        global_final_path = final_output_dir / "global_final.json"

    if args.docx_only:
        print(f"[CR] Dossier compte_rendu_LLM : {final_output_dir}")
        for logs_dir in logs_dirs:
            print(f"[CR] Dossier logs utilise : {logs_dir}")
        if pseudo_context_path:
            print(f"[CR][PSEUDO] pseudo_context utilise : {pseudo_context_path}")
        if log_pseudo_job_path:
            print(f"[CR][PSEUDO] pseudo_job_id lu depuis log : {log_pseudo_job_path}")
        print(f"[CR][PSEUDO] PseudoApiBase utilisee : {pseudo_api_base or '(non configuree)'}")
    print(f"[CR] global_final.json : {global_final_path}")

    payload_text = global_final_path.read_text(encoding="utf-8")
    provider = resolve_runtime_value(args, infos, compte_rendu_cfg, "provider", DEFAULT_PROVIDER)
    model_pass1 = resolve_runtime_value(args, infos, compte_rendu_cfg, "model_pass1", DEFAULT_MODEL_PASS1)
    model_pass2 = resolve_runtime_value(args, infos, compte_rendu_cfg, "model_pass2", DEFAULT_MODEL_PASS2)
    model_pass3 = resolve_runtime_value(args, infos, compte_rendu_cfg, "model_pass3", DEFAULT_MODEL_PASS3)
    if args.pseudonymize_remote and pipeline_uses_remote_llm(provider, model_pass1, model_pass2, model_pass3):
        if not pseudo_api_base:
            raise RuntimeError(
                "Pseudonymisation distante activee mais aucune base URL n'est configuree. "
                "Utilisez CR_PSEUDO_API_BASE, PSEUDO_API_BASE, --pseudo-api-base "
                "ou compte_rendu.pseudo_api_base."
            )
        print(f"[CR][PSEUDO] depseudonymisation finale via {pseudo_api_base} job_id={pseudo_job_id}")
        payload_json = depseudonymize_final_payload(
            payload_text,
            pseudo_api_base=pseudo_api_base,
            pseudo_api_key=args.pseudo_api_key,
            job_id=pseudo_job_id,
        )
    else:
        payload_json = json.loads(payload_text)

    render_response = requests.post(
        args.render_url,
        json=payload_json,
        timeout=1800,
    )
    render_response.raise_for_status()

    docx_path = final_output_dir / build_docx_name(infos)
    docx_path.write_bytes(render_response.content)
    print(f"[CR] DOCX final : {docx_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
