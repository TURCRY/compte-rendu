#!/usr/bin/env bash
set -euo pipefail

# Compare A60 Pass2B/rapport behavior for report_remote physical model:
#   - gpt-5-mini
#   - gpt-4.1-mini
#
# Intended usage: run on the NAS through SSH/PuTTY, where Docker is available.

SCRIPT_NAME="$(basename "$0")"

ADAPTER_PATH="${ADAPTER_PATH:-/volume1/Home/Docker/openai-adapter/adapter.py}"
PIPELINE_CONTAINER="${PIPELINE_CONTAINER:-cr-pipeline}"
ADAPTER_CONTAINER="${ADAPTER_CONTAINER:-openai-adapter}"
PIPELINE_SCRIPT="${PIPELINE_SCRIPT:-/pipeline/powershell/cr_reunion_point_mumerotes_pipeline_json.ps1}"
CSV_PATH="${CSV_PATH:-/data/Affaires/2026-A60/AF_Expert_ASR/transcriptions/accedit-2026-05-21/A60_mono16_16000Hz(wav).csv}"
CONTEXT_JSON_PATH="${CONTEXT_JSON_PATH:-/data/Affaires/2026-A60/AF_Expert_ASR/transcriptions/accedit-2026-05-21/contexte_general.json}"
SUJETS_PATH="${SUJETS_PATH:-/data/Affaires/2026-A60/AF_Expert_ASR/transcriptions/accedit-2026-05-21/Sujets.xlsx}"
PARTICIPANTS_PATH="${PARTICIPANTS_PATH:-/data/Affaires/2026-A60/AF_Expert_ASR/transcriptions/accedit-2026-05-21/Participants.xlsx}"
PSEUDO_PARTICIPANTS_PATH="${PSEUDO_PARTICIPANTS_PATH:-C:\\Affaires\\2026-A60\\AF_Expert_ASR\\transcriptions\\accedit-2026-05-21\\Participants.xlsx}"
PSEUDO_API_BASE="${PSEUDO_API_BASE:-http://10.0.1.2:5050}"
PSEUDO_API_KEY="${PSEUDO_API_KEY:-}"
CLI_PSEUDO_API_KEY=""
PSEUDO_JOB_ID="${PSEUDO_JOB_ID:-job_test_pseudo_2025J46}"
OUT_ROOT="${OUT_ROOT:-/data/Affaires/2026-A60/BE_Traitement_captations/accedit-2026-05-21/compte_rendu_LLM/out}"
API_BASE="${API_BASE:-http://openai-adapter:5055}"
ADAPTER_HEALTH_URL="${ADAPTER_HEALTH_URL:-http://127.0.0.1:5055/v1/models}"
ADAPTER_HEALTH_TIMEOUT_SEC="${ADAPTER_HEALTH_TIMEOUT_SEC:-120}"
API_KEY="${OPENAI_API_KEY:-}"
CLI_API_KEY=""
COLLECT_DIR="${COLLECT_DIR:-/volume1/Home/Codex/compte-rendu/a60_report_model_compare}"
SKIP_DOCKER_RESTART=0
DRY_RUN=0
RUN_MASK_SELF_TEST=0

usage() {
  cat <<EOF
Usage:
  $SCRIPT_NAME [options]

Options:
  --adapter-path PATH       adapter.py a modifier temporairement
                            defaut: $ADAPTER_PATH
  --csv-path PATH           CSV ASR A60 dans le conteneur cr-pipeline
                            defaut: $CSV_PATH
  --context-json-path PATH  contexte A60 dans le conteneur cr-pipeline
                            defaut: $CONTEXT_JSON_PATH
  --sujets-path PATH        Sujets.xlsx A60 dans le conteneur cr-pipeline
                            defaut: $SUJETS_PATH
  --participants-path PATH  Participants.xlsx A60 dans le conteneur cr-pipeline
                            defaut: $PARTICIPANTS_PATH
  --pseudo-participants-path PATH
                            Participants.xlsx vu par l'API pseudo
                            defaut: $PSEUDO_PARTICIPANTS_PATH
  --pseudo-api-base URL     defaut: $PSEUDO_API_BASE
  --pseudo-api-key KEY      optionnel, sinon variable PSEUDO_API_KEY
  --pseudo-job-id ID        defaut: $PSEUDO_JOB_ID
  --out-root PATH           dossier out racine dans le conteneur
                            defaut: $OUT_ROOT
  --collect-dir PATH        dossier NAS de collecte des resultats
                            defaut: $COLLECT_DIR
  --pipeline-container NAME defaut: $PIPELINE_CONTAINER
  --adapter-container NAME  defaut: $ADAPTER_CONTAINER
  --api-base URL            defaut: $API_BASE
  --api-key KEY             optionnel
  --adapter-health-url URL  defaut: $ADAPTER_HEALTH_URL
  --adapter-health-timeout SEC
                            defaut: $ADAPTER_HEALTH_TIMEOUT_SEC
  --skip-docker-restart     ne redemarre pas openai-adapter
  --dry-run                 affiche les actions sans lancer
  --self-test-mask          teste le masquage dry-run puis quitte
  -h, --help                aide

Exemple:
  bash $SCRIPT_NAME \\
    --adapter-path /volume1/Home/Docker/openai-adapter/adapter.py \\
    --csv-path "/data/Affaires/2026-A60/AF_Expert_ASR/transcriptions/accedit-2026-05-21/<CSV_A60>.csv"
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --adapter-path) ADAPTER_PATH="${2:-}"; shift 2;;
    --csv-path) CSV_PATH="${2:-}"; shift 2;;
    --context-json-path) CONTEXT_JSON_PATH="${2:-}"; shift 2;;
    --sujets-path) SUJETS_PATH="${2:-}"; shift 2;;
    --participants-path) PARTICIPANTS_PATH="${2:-}"; shift 2;;
    --pseudo-participants-path) PSEUDO_PARTICIPANTS_PATH="${2:-}"; shift 2;;
    --pseudo-api-base) PSEUDO_API_BASE="${2:-}"; shift 2;;
    --pseudo-api-key) CLI_PSEUDO_API_KEY="${2:-}"; shift 2;;
    --pseudo-job-id) PSEUDO_JOB_ID="${2:-}"; shift 2;;
    --out-root) OUT_ROOT="${2:-}"; shift 2;;
    --collect-dir) COLLECT_DIR="${2:-}"; shift 2;;
    --pipeline-container) PIPELINE_CONTAINER="${2:-}"; shift 2;;
    --adapter-container) ADAPTER_CONTAINER="${2:-}"; shift 2;;
    --api-base) API_BASE="${2:-}"; shift 2;;
    --api-key) CLI_API_KEY="${2:-}"; shift 2;;
    --adapter-health-url) ADAPTER_HEALTH_URL="${2:-}"; shift 2;;
    --adapter-health-timeout) ADAPTER_HEALTH_TIMEOUT_SEC="${2:-}"; shift 2;;
    --skip-docker-restart) SKIP_DOCKER_RESTART=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    --self-test-mask) RUN_MASK_SELF_TEST=1; shift;;
    -h|--help) usage; exit 0;;
    *)
      echo "Option inconnue: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$API_KEY" && -n "$CLI_API_KEY" ]]; then
  API_KEY="$CLI_API_KEY"
fi
if [[ -z "$PSEUDO_API_KEY" && -n "$CLI_PSEUDO_API_KEY" ]]; then
  PSEUDO_API_KEY="$CLI_PSEUDO_API_KEY"
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERREUR: commande introuvable: $1" >&2
    exit 2
  }
}

run() {
  echo "+ $*"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    "$@"
  fi
}

mask_command_args() {
  local masked=("$@")
  local i
  for ((i = 0; i < ${#masked[@]}; i++)); do
    if [[ "${masked[$i]}" == "-ApiKey" || "${masked[$i]}" == "-PseudoApiKey" ]]; then
      if (( i + 1 < ${#masked[@]} )); then
        masked[$((i + 1))]="***MASKED***"
      fi
    fi
  done
  printf '%s\0' "${masked[@]}"
}

print_masked_command() {
  local -a masked=()
  local arg
  while IFS= read -r -d '' arg; do
    masked+=("$arg")
  done < <(mask_command_args "$@")

  printf '+'
  for arg in "${masked[@]}"; do
    printf ' %q' "$arg"
  done
  printf '\n'
}

run_mask_self_test() {
  local -a original=(
    docker exec cr-pipeline pwsh /pipeline/powershell/cr_reunion_point_mumerotes_pipeline_json.ps1
    -ApiKey sk-secret
    -ContextJsonPath /data/Affaires/2026-A60/AF_Expert_ASR/transcriptions/accedit-2026-05-21/contexte_general.json
    -PseudoApiBase http://10.0.1.2:5050
    -PseudoApiKey pseudo-secret
    -OutDir /data/Affaires/2026-A60/out/job_test_report_gpt5mini
    -ModelPass1 annoter_segments_remote
  )
  local -a masked=()
  local arg
  while IFS= read -r -d '' arg; do
    masked+=("$arg")
  done < <(mask_command_args "${original[@]}")

  [[ "${masked[6]}" == "***MASKED***" ]] || { echo "self-test mask: -ApiKey non masque" >&2; return 1; }
  [[ "${masked[12]}" == "***MASKED***" ]] || { echo "self-test mask: -PseudoApiKey non masque" >&2; return 1; }
  [[ "${masked[7]}" == "-ContextJsonPath" ]] || { echo "self-test mask: -ContextJsonPath altere" >&2; return 1; }
  [[ "${masked[8]}" == "/data/Affaires/2026-A60/AF_Expert_ASR/transcriptions/accedit-2026-05-21/contexte_general.json" ]] || { echo "self-test mask: /data/Affaires altere" >&2; return 1; }
  [[ "${masked[10]}" == "http://10.0.1.2:5050" ]] || { echo "self-test mask: PseudoApiBase altere" >&2; return 1; }
  [[ "${masked[14]}" == "/data/Affaires/2026-A60/out/job_test_report_gpt5mini" ]] || { echo "self-test mask: job_test_report_gpt5mini altere" >&2; return 1; }
  [[ "${masked[16]}" == "annoter_segments_remote" ]] || { echo "self-test mask: annoter_segments_remote altere" >&2; return 1; }

  local masked_count=0
  for arg in "${masked[@]}"; do
    if [[ "$arg" == "***MASKED***" ]]; then
      masked_count=$((masked_count + 1))
    fi
  done
  [[ "$masked_count" -eq 2 ]] || { echo "self-test mask: nombre de valeurs masquees inattendu: $masked_count" >&2; return 1; }

  print_masked_command "${original[@]}"
  echo "self-test mask: OK"
}

docker_exec() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    print_masked_command docker exec "$@"
  else
    docker exec "$@"
  fi
}

restart_adapter() {
  ensure_adapter_container_running
  if [[ "$SKIP_DOCKER_RESTART" -eq 1 ]]; then
    echo "Skip docker restart: $ADAPTER_CONTAINER"
    return
  fi
  run docker restart "$ADAPTER_CONTAINER" >/dev/null
}

resolve_adapter_container() {
  local exact
  local fuzzy

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "Dry-run: container adapter utilise: $ADAPTER_CONTAINER"
    return 0
  fi

  exact="$(docker ps --format '{{.Names}}' | awk -v name="$ADAPTER_CONTAINER" '$0 == name { print; exit }')"
  if [[ -n "$exact" ]]; then
    ADAPTER_CONTAINER="$exact"
    return 0
  fi

  fuzzy="$(docker ps --format '{{.Names}}' | awk -v name="$ADAPTER_CONTAINER" '
    index($0, name) > 0 || index($0, "openai-adapter") > 0 { print; exit }
  ')"
  if [[ -n "$fuzzy" ]]; then
    ADAPTER_CONTAINER="$fuzzy"
    echo "Container adapter detecte: $ADAPTER_CONTAINER"
    return 0
  fi

  echo "ERREUR: container openai-adapter introuvable dans docker ps." >&2
  docker ps --format '  - {{.Names}}  {{.Status}}' >&2 || true
  return 1
}

ensure_adapter_container_running() {
  local running

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "Dry-run: verification running adapter ignoree ($ADAPTER_CONTAINER)."
    return 0
  fi

  resolve_adapter_container
  running="$(docker inspect -f '{{.State.Running}}' "$ADAPTER_CONTAINER" 2>/dev/null || true)"
  if [[ "$running" != "true" ]]; then
    echo "ERREUR: container adapter non running: $ADAPTER_CONTAINER (running=$running)." >&2
    docker ps -a --filter "name=$ADAPTER_CONTAINER" --format '  - {{.Names}}  {{.Status}}' >&2 || true
    return 1
  fi
}

check_adapter_http_python() {
  local url="$1"
  python3 - "$url" <<'PY'
import sys
import urllib.error
import urllib.request

url = sys.argv[1]
try:
    with urllib.request.urlopen(url, timeout=5) as response:
        code = response.getcode()
        body = response.read(4096).decode("utf-8", "replace")
except urllib.error.HTTPError as exc:
    code = exc.code
    body = exc.read(4096).decode("utf-8", "replace")
except Exception as exc:
    print(f"python urllib error: {exc}", file=sys.stderr)
    raise SystemExit(2)

print(f"HTTP {code}")
if body:
    print(body[:500])
if code == 200 or (code in (401, 403) and "Missing Bearer token" in body):
    raise SystemExit(0)
raise SystemExit(1)
PY
}

check_adapter_http_wget() {
  local url="$1"
  local output
  local status
  local code

  command -v wget >/dev/null 2>&1 || return 2
  output="$(wget -S -O - --timeout=5 "$url" 2>&1)" && status=0 || status=$?
  code="$(printf '%s\n' "$output" | awk '/HTTP\// { code=$2 } END { print code }')"
  printf '%s\n' "$output" | tail -n 8
  if [[ "$code" == "200" ]]; then
    return 0
  fi
  if [[ "$code" == "401" || "$code" == "403" ]]; then
    if [[ "$output" == *"Missing Bearer token"* ]]; then
      return 0
    fi
  fi
  return "$status"
}

print_adapter_diagnostics() {
  echo "Diagnostic openai-adapter:" >&2
  docker inspect -f '  status={{.State.Status}} running={{.State.Running}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$ADAPTER_CONTAINER" >&2 || true
  docker logs --tail 80 "$ADAPTER_CONTAINER" >&2 || true
}

wait_for_adapter_health() {
  local deadline
  local elapsed=0

  if [[ "$DRY_RUN" -eq 1 ]]; then
    print_masked_command python3 - "$ADAPTER_HEALTH_URL"
    echo "Dry-run: healthcheck openai-adapter considere OK."
    return 0
  fi

  ensure_adapter_container_running
  echo "Attente openai-adapter depuis l'hote NAS: $ADAPTER_HEALTH_URL (max ${ADAPTER_HEALTH_TIMEOUT_SEC}s)"
  deadline=$((SECONDS + ADAPTER_HEALTH_TIMEOUT_SEC))
  while (( SECONDS < deadline )); do
    ensure_adapter_container_running
    if command -v python3 >/dev/null 2>&1 && check_adapter_http_python "$ADAPTER_HEALTH_URL" >/tmp/adapter_health_python.log 2>&1; then
      elapsed=$((ADAPTER_HEALTH_TIMEOUT_SEC - (deadline - SECONDS)))
      echo "openai-adapter pret via python urllib apres ${elapsed}s"
      return 0
    fi
    if check_adapter_http_wget "$ADAPTER_HEALTH_URL" >/tmp/adapter_health_wget.log 2>&1; then
      elapsed=$((ADAPTER_HEALTH_TIMEOUT_SEC - (deadline - SECONDS)))
      echo "openai-adapter pret via wget apres ${elapsed}s"
      return 0
    fi
    if [[ -s /tmp/adapter_health_python.log ]]; then
      echo "Healthcheck en attente (python): $(tail -n 1 /tmp/adapter_health_python.log)"
    else
      echo "Healthcheck en attente: port 5055 non joignable"
    fi
    sleep 3
  done

  echo "ERREUR: openai-adapter ne repond pas sur $ADAPTER_HEALTH_URL apres ${ADAPTER_HEALTH_TIMEOUT_SEC}s." >&2
  print_adapter_diagnostics
  echo "Benchmark arrete avant lancement de cr-pipeline." >&2
  return 1
}

set_report_remote_model() {
  local physical_model="$1"
  echo "Patch report_remote model -> $physical_model dans $ADAPTER_PATH"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return
  fi
  python3 - "$ADAPTER_PATH" "$physical_model" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
model = sys.argv[2]
text = path.read_text(encoding="utf-8")
pattern = r'(?s)("report_remote"\s*:\s*\{.*?"model"\s*:\s*")([^"]+)(")'
new, count = re.subn(pattern, r"\1" + model + r"\3", text, count=1)
if count != 1:
    raise SystemExit(f"Impossible de modifier report_remote dans {path}")
path.write_text(new, encoding="utf-8")
PY
}

copy_from_container() {
  local container_path="$1"
  local host_path="$2"
  mkdir -p "$(dirname "$host_path")"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "+ docker cp ${PIPELINE_CONTAINER}:${container_path} ${host_path}"
    return
  fi
  if ! docker cp "${PIPELINE_CONTAINER}:${container_path}" "$host_path"; then
    echo "WARN: copie impossible: $container_path" >&2
  fi
}

validate_pass1_qa() {
  local host_job_dir="$1"
  local pass1_qa_path="${host_job_dir}/pass1_qa.json"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "Dry-run: validation pass1_qa non executee."
    return 0
  fi

  if [[ ! -f "$pass1_qa_path" && -f "${host_job_dir}/logs/pass1_qa.json" ]]; then
    pass1_qa_path="${host_job_dir}/logs/pass1_qa.json"
  fi

  python3 - "$pass1_qa_path" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.exists():
    raise SystemExit(f"ERREUR: pass1_qa.json introuvable: {path}")

data = json.loads(path.read_text(encoding="utf-8-sig"))
summary = data.get("summary") if isinstance(data.get("summary"), dict) else {}

def first_int(obj, names):
    for name in names:
        value = obj.get(name)
        if isinstance(value, bool):
            continue
        if isinstance(value, int):
            return value
        if isinstance(value, float) and value.is_integer():
            return int(value)
    return None

segment_count = first_int(summary, ("segment_count", "segments_count", "total_segments", "pass1_total_segments"))
fallback_count = first_int(summary, ("fallback_count", "segments_fallback_count", "llm_fallback_count"))

if segment_count is None:
    segment_count = first_int(data, ("segment_count", "segments_count", "total_segments", "pass1_total_segments"))
if fallback_count is None:
    fallback_count = first_int(data, ("fallback_count", "segments_fallback_count", "llm_fallback_count"))

if segment_count is None and isinstance(data.get("segments"), list):
    segment_count = len(data["segments"])
if fallback_count is None and isinstance(data.get("segments"), list):
    fallback_count = sum(1 for item in data["segments"] if isinstance(item, dict) and item.get("llm_fallback") is True)
if fallback_count is None and isinstance(data.get("sorties_fallback"), list):
    fallback_count = len(data["sorties_fallback"])

if segment_count is None or fallback_count is None:
    raise SystemExit(f"ERREUR: impossible de lire segment_count/fallback_count dans {path}")

print(f"pass1_qa: segment_count={segment_count} fallback_count={fallback_count}")
if segment_count > 0 and fallback_count == segment_count:
    raise SystemExit("ERREUR: run invalide, pass1_qa fallback_count == segment_count")
PY
}

run_pipeline_job() {
  local job_name="$1"
  local physical_model="$2"
  local out_dir="${OUT_ROOT}/${job_name}"
  local host_job_dir="${COLLECT_DIR}/${job_name}"

  echo
  echo "============================================================"
  echo "RUN $job_name : report_remote -> $physical_model"
  echo "============================================================"

  set_report_remote_model "$physical_model"
  resolve_adapter_container
  ensure_adapter_container_running
  restart_adapter
  wait_for_adapter_health
  if [[ -z "$API_KEY" ]]; then
    echo "WARN: OPENAI_API_KEY/API_KEY vide ; -ApiKey sera transmis vide." >&2
  fi
  if [[ -z "$PSEUDO_API_KEY" ]]; then
    echo "WARN: PSEUDO_API_KEY vide ; -PseudoApiKey sera transmis vide." >&2
  fi

  docker_exec "$PIPELINE_CONTAINER" \
    pwsh "$PIPELINE_SCRIPT" \
      -CsvPath "$CSV_PATH" \
      -OutDir "$out_dir" \
      -Provider openai \
      -ApiBase "$API_BASE" \
      -ApiKey "$API_KEY" \
      -ContextJsonPath "$CONTEXT_JSON_PATH" \
      -SujetsPath "$SUJETS_PATH" \
      -ParticipantsPath "$PARTICIPANTS_PATH" \
      -PseudoParticipantsPath "$PSEUDO_PARTICIPANTS_PATH" \
      -PseudoApiBase "$PSEUDO_API_BASE" \
      -PseudoApiKey "$PSEUDO_API_KEY" \
      -PseudoJobId "$PSEUDO_JOB_ID" \
      -PseudonymizeRemote \
      -ModelPass1 annoter_segments_remote \
      -ModelPass2 annoter_segments_remote \
      -ModelReport report_remote \
      -ModelPass2E annoter_segments_remote_alt \
      -ModelPass3 pass3_remote \
      -ModelPass3E pass3e_remote \
      -Force

  mkdir -p "$host_job_dir/logs"
  copy_from_container "$out_dir/pass1_qa.json" "$host_job_dir/pass1_qa.json"
  copy_from_container "$out_dir/logs/pass2b_timing.json" "$host_job_dir/logs/pass2b_timing.json"
  copy_from_container "$out_dir/logs/pass2b_timing.csv" "$host_job_dir/logs/pass2b_timing.csv"
  copy_from_container "$out_dir/pipeline_qa_status.json" "$host_job_dir/pipeline_qa_status.json"
  copy_from_container "$out_dir/global_meeting.json" "$host_job_dir/global_meeting.json"
  copy_from_container "$out_dir/global_final.json" "$host_job_dir/global_final.json"
  validate_pass1_qa "$host_job_dir"
}

write_comparison_note() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "Dry-run: pas de note comparative generee."
    return
  fi

  python3 - "$COLLECT_DIR" <<'PY'
import json
import statistics
import sys
from pathlib import Path

root = Path(sys.argv[1])
runs = [
    ("job_test_report_gpt5mini", "gpt-5-mini"),
    ("job_test_report_gpt41mini", "gpt-4.1-mini"),
]

def load_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except Exception:
        return None

def file_text(path):
    try:
        return path.read_text(encoding="utf-8")
    except Exception:
        return ""

def pass2b_summary(timing):
    entries = (timing or {}).get("entries") or []
    total = 0.0
    batches = []
    for e in entries:
        dur = e.get("total_duration_sec", e.get("duration_sec", 0)) or 0
        total += float(dur)
        attempts = e.get("llm_attempts") or []
        timeouts = sum(1 for a in attempts if str(a.get("status", "")).upper() == "TIMEOUT")
        failed = e.get("failed_attempts_count")
        if failed is None:
            failed = sum(1 for a in attempts if a.get("status") != "OK")
        batches.append({
            "batch_id": e.get("batch_id"),
            "segments": e.get("segments_inclus"),
            "duration_sec": round(float(dur), 3),
            "successful_attempt_duration_sec": e.get("successful_attempt_duration_sec"),
            "failed_attempts_count": failed,
            "retries": e.get("retries", failed),
            "timeouts": timeouts,
            "logical_model": e.get("modele"),
            "physical_model": e.get("modele_reel_adapter"),
            "prompt_chars": e.get("prompt_chars"),
            "estimated_input_tokens": e.get("estimated_input_tokens"),
            "status": e.get("final_status"),
        })
    return {"total_sec": round(total, 3), "batches": batches}

summary = {
    "runs": [],
    "comparisons": {},
}

for job, model in runs:
    job_dir = root / job
    timing = load_json(job_dir / "logs" / "pass2b_timing.json")
    qa = load_json(job_dir / "pipeline_qa_status.json")
    global_meeting = file_text(job_dir / "global_meeting.json")
    global_final = file_text(job_dir / "global_final.json")
    summary["runs"].append({
        "job": job,
        "report_remote_physical_model": model,
        "path": str(job_dir),
        "pipeline_qa_status": qa,
        "pass2b": pass2b_summary(timing),
        "global_meeting_chars": len(global_meeting),
        "global_final_chars": len(global_final),
    })

gm_a = file_text(root / runs[0][0] / "global_meeting.json")
gm_b = file_text(root / runs[1][0] / "global_meeting.json")
gf_a = file_text(root / runs[0][0] / "global_final.json")
gf_b = file_text(root / runs[1][0] / "global_final.json")
summary["comparisons"] = {
    "global_meeting_same": gm_a == gm_b,
    "global_final_same": gf_a == gf_b,
    "global_meeting_chars": [len(gm_a), len(gm_b)],
    "global_final_chars": [len(gf_a), len(gf_b)],
}

(root / "a60_report_model_comparison.json").write_text(
    json.dumps(summary, ensure_ascii=False, indent=2),
    encoding="utf-8",
)

lines = []
lines.append("# Comparaison A60 report_remote")
lines.append("")
for run in summary["runs"]:
    lines.append(f"## {run['job']} ({run['report_remote_physical_model']})")
    lines.append(f"- Temps total Pass2B: {run['pass2b']['total_sec']}s")
    lines.append(f"- QA pipeline: `{json.dumps(run['pipeline_qa_status'], ensure_ascii=False)}`")
    lines.append(f"- Taille global_meeting.json: {run['global_meeting_chars']} caracteres")
    lines.append(f"- Taille global_final.json: {run['global_final_chars']} caracteres")
    for b in run["pass2b"]["batches"]:
        lines.append(
            "- Batch {batch_id}: {duration_sec}s, retries={retries}, "
            "timeouts={timeouts}, failed_attempts={failed_attempts_count}, "
            "modele reel={physical_model}, status={status}, tokens~={estimated_input_tokens}".format(**b)
        )
    lines.append("")

lines.append("## Comparaison fichiers")
lines.append(f"- global_meeting identique: {summary['comparisons']['global_meeting_same']}")
lines.append(f"- global_final identique: {summary['comparisons']['global_final_same']}")
lines.append("")
lines.append("## Qualite synthese")
lines.append(
    "Comparer manuellement les deux `global_meeting.json` et `global_final.json`: "
    "precision, omissions, hallucinations, structure, exploitabilite juridique."
)
lines.append("")
lines.append("## Recommandation finale")
run_by_model = {r["report_remote_physical_model"]: r for r in summary["runs"]}
g5 = run_by_model.get("gpt-5-mini", {})
g41 = run_by_model.get("gpt-4.1-mini", {})
if g5 and g41:
    t5 = g5["pass2b"]["total_sec"]
    t41 = g41["pass2b"]["total_sec"]
    if t41 < t5:
        lines.append("Si la qualite est comparable, preferer `gpt-4.1-mini` pour Pass2B: plus rapide sur ce run.")
    elif t5 < t41:
        lines.append("Si la qualite est comparable, conserver `gpt-5-mini`: plus rapide sur ce run.")
    else:
        lines.append("Les temps Pass2B sont equivalants; trancher sur la qualite de synthese.")
else:
    lines.append("Synthese incomplete: un des deux runs est manquant.")

(root / "NOTE_COMPARATIVE_A60_report_remote.md").write_text(
    "\n".join(lines) + "\n",
    encoding="utf-8",
)
print(root / "a60_report_model_comparison.json")
print(root / "NOTE_COMPARATIVE_A60_report_remote.md")
PY
}

if [[ "$RUN_MASK_SELF_TEST" -eq 1 ]]; then
  run_mask_self_test
  exit 0
fi

need_cmd docker
need_cmd python3

if [[ ! -f "$ADAPTER_PATH" ]]; then
  echo "ERREUR: adapter.py introuvable: $ADAPTER_PATH" >&2
  echo "Indiquez le chemin NAS avec --adapter-path." >&2
  exit 2
fi

mkdir -p "$COLLECT_DIR"
BACKUP="$(mktemp)"
cp "$ADAPTER_PATH" "$BACKUP"

restore_adapter() {
  local status=$?
  if [[ -f "$BACKUP" && "$DRY_RUN" -eq 0 ]]; then
    echo "Restauration adapter.py puis redemarrage de $ADAPTER_CONTAINER"
    cp "$BACKUP" "$ADAPTER_PATH"
    restart_adapter || true
    wait_for_adapter_health || true
  fi
  return "$status"
}
trap restore_adapter EXIT

echo "Adapter: $ADAPTER_PATH"
echo "CSV: $CSV_PATH"
echo "ContextJsonPath: $CONTEXT_JSON_PATH"
echo "SujetsPath: $SUJETS_PATH"
echo "ParticipantsPath: $PARTICIPANTS_PATH"
echo "PseudoParticipantsPath: $PSEUDO_PARTICIPANTS_PATH"
echo "PseudoApiBase: $PSEUDO_API_BASE"
echo "PseudoJobId: $PSEUDO_JOB_ID"
echo "Out root: $OUT_ROOT"
echo "Collecte: $COLLECT_DIR"

run_pipeline_job "job_test_report_gpt5mini" "gpt-5-mini"
run_pipeline_job "job_test_report_gpt41mini" "gpt-4.1-mini"
write_comparison_note

echo
echo "Termine. Resultats dans: $COLLECT_DIR"
