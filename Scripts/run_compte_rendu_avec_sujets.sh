#!/usr/bin/env bash
set -euo pipefail

# ----------------------------
# Args (parsing des options)
# ----------------------------
INFOS="${1:-}"
shift || true
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=0
FORCE=0
STRICT_SYNC=0


while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift;;
    --force)   FORCE=1; shift;;
    --strict-sync) STRICT_SYNC=1; shift;;
    --no-force) FORCE=0; shift;;   # option explicite, utile en n8n
    -h|--help)
      echo "Usage: $0 \"/chemin/vers/infos_projet.json\" [--dry-run] [--force|--no-force]"
      exit 0
      ;;
    *)
      echo "Option inconnue: $1"
      echo "Usage: $0 \"/chemin/vers/infos_projet.json\" [--dry-run] [--force|--no-force]"
      echo "STRICT_SYNC : $([[ $STRICT_SYNC -eq 1 ]] && echo 'ON' || echo 'OFF')"
      exit 2
      ;;
  esac
done

if [[ -z "$INFOS" ]]; then
  echo "Usage: $0 \"/chemin/vers/infos_projet.json\" [--dry-run] [--force|--no-force]"
  exit 2
fi
if [[ ! -f "$INFOS" ]]; then
  echo "ERREUR: fichier introuvable: $INFOS"
  exit 2
fi

# ----------------------------
# Helpers JSON (sans jq)
# ----------------------------
json_get() {
  python3 - <<'PY' "$INFOS" "$1"
import json, sys
path = sys.argv[2].split(".")
with open(sys.argv[1], "r", encoding="utf-8") as f:
    d = json.load(f)
cur = d
for p in path:
    if isinstance(cur, dict) and p in cur:
        cur = cur[p]
    else:
        cur = ""
        break
print("" if cur is None else cur)
PY
}

# ----------------------------
# Windows -> conteneur
# C:\Affaires\...  => /data/Affaires/...
# \\192.168.1.20\Affaires\... => /data/Affaires/...
# ----------------------------
to_container_path() {
  local p="$1"
  [[ -z "$p" ]] && echo "" && return

  if [[ "$p" == C:\\Affaires\\* ]]; then
    p="/data/Affaires/${p#C:\\Affaires\\}"
  elif [[ "$p" == \\\\192.168.1.20\\Affaires\\* ]]; then
    p="/data/Affaires/${p#\\\\192.168.1.20\\Affaires\\}"
  elif [[ "$p" == \\\\192.168.0.155\\Affaires\\* ]]; then
    p="/data/Affaires/${p#\\\\192.168.0.155\\Affaires\\}"
  fi

  p="${p//\\//}"
  echo "$p"
}

to_unc_affaires_path() {
  local p="$1"
  [[ -z "$p" ]] && echo "" && return

  if [[ "$p" == /data/Affaires/* ]]; then
    p="\\\\192.168.0.155\\Affaires\\${p#/data/Affaires/}"
    p="${p//\//\\}"
  fi

  echo "$p"
}

uses_remote_llm() {
  local provider="${1,,}"
  shift || true
  [[ "$provider" == "openai" ]] || return 1
  local model=""
  for model in "$@"; do
    [[ "${model,,}" == *remote* ]] && return 0
  done
  return 1
}



# ----------------------------
# Profil d'exécution
# ----------------------------
PROFILE="$(json_get profil_execution)"
[[ -z "$PROFILE" ]] && PROFILE="pcfixe"

# ----------------------------
# CSV obligatoire
# ----------------------------
CSV_PATH_RAW="$(json_get "${PROFILE}.fichier_transcription")"
CSV_PATH="$(to_container_path "$CSV_PATH_RAW")"
if [[ -z "$CSV_PATH" ]]; then
  echo "ERREUR: chemin manquant dans infos_projet.json (${PROFILE}.fichier_transcription)."
  exit 2
fi

# CSV_PATH peut être un fichier .csv OU un dossier contenant des .csv
if docker exec cr-pipeline sh -lc "test -d \"$CSV_PATH\""; then
  CSV_DIR="$CSV_PATH"
  CSV_MAIN="$(docker exec cr-pipeline sh -lc "ls -1t \"$CSV_DIR\"/*.csv 2>/dev/null | grep -v '(photo)' | head -n 1 || true")"
  if [[ -z "$CSV_MAIN" ]]; then
    echo "ERREUR: aucun .csv trouvé dans le dossier de transcription: $CSV_DIR"
    exit 2
  fi
  CSV_PATH="$CSV_MAIN"
else
  CSV_DIR="$(dirname "$CSV_PATH")"
fi

# Excel obligatoires (toujours à côté)
SUJETS_PATH="${CSV_DIR}/Sujets.xlsx"
PART_PATH="${CSV_DIR}/Participants.xlsx"

# Contexte (priorité stricte, à côté du CSV)
CTX_CR="${CSV_DIR}/contexte_general_compte_rendu.json"
CTX_FALLBACK="${CSV_DIR}/contexte_general.json"


# OutDir : 
AFFAIRE_ID="$(json_get id_affaire)"
CAPTATION_ID="$(json_get id_captation)"

if [[ -z "$AFFAIRE_ID" ]]; then
  AFFAIRE_ID="$(echo "$CSV_PATH" | sed -n 's|^/data/Affaires/\([^/]*\)/.*$|\1|p')"
fi
if [[ -z "$CAPTATION_ID" ]]; then
  CAPTATION_ID="$(basename "$CSV_DIR")"
fi
# ----------------------------
# Garde-fous : IDs obligatoires
# ----------------------------

if [[ -z "$AFFAIRE_ID" ]]; then
  echo "ERREUR: id_affaire introuvable (ni dans infos_projet.json, ni déductible de CSV_PATH=$CSV_PATH)."
  echo "Attendu: /data/Affaires/<id_affaire>/..."
  exit 10
fi

if [[ -z "$CAPTATION_ID" ]]; then
  echo "ERREUR: id_captation introuvable (ni dans infos_projet.json, ni déductible de CSV_DIR=$CSV_DIR)."
  exit 11
fi

if [[ ! "$AFFAIRE_ID" =~ ^[0-9]{4}-[A-Za-z0-9._-]+$ ]]; then
  echo "ERREUR: id_affaire a un format inattendu: '$AFFAIRE_ID'"
  exit 12
fi

OUT_ROOT="/data/Affaires/${AFFAIRE_ID}/BE_Traitement_captations/${CAPTATION_ID}/compte_rendu_LLM"
RUN_JOB_ID="job_$(date +%Y%m%d_%H%M%S_%N)_$$"
OUT_DIR="${OUT_ROOT}/out/${RUN_JOB_ID}"


# Résolution du contexte via tests dans le conteneur
if docker exec cr-pipeline sh -lc "test -f \"$CTX_CR\""; then
  CTX_PATH="$CTX_CR"
elif docker exec cr-pipeline sh -lc "test -f \"$CTX_FALLBACK\""; then
  CTX_PATH="$CTX_FALLBACK"
else
  echo "KO: aucun contexte général trouvé."
  echo "  Attendus (dans $CSV_DIR) :"
  echo "   - contexte_general_compte_rendu.json (prioritaire)"
  echo "   - contexte_general.json (fallback)"
  exit 2
fi

# ----------------------------
# VALIDATION BASE DE TRAVAIL (Niveau B)
# ----------------------------

echo "=== Validation base de travail ==="

HOST_CSV="/volume1/Affaires${CSV_PATH#/data/Affaires}"
HOST_CTX="/volume1/Affaires${CTX_PATH#/data/Affaires}"
HOST_SUJETS="/volume1/Affaires${SUJETS_PATH#/data/Affaires}"
HOST_PART="/volume1/Affaires${PART_PATH#/data/Affaires}"

MAX_AGE_HOURS=24

now=$(date +%s)
csv_mtime=$(stat -c %Y "$HOST_CSV")
ctx_mtime=$(stat -c %Y "$HOST_CTX")
suj_mtime=$(stat -c %Y "$HOST_SUJETS")
par_mtime=$(stat -c %Y "$HOST_PART")

csv_age_h=$(( (now - csv_mtime) / 3600 ))

CSV_DATE="$(stat -c %y "$HOST_CSV")"
CTX_DATE="$(stat -c %y "$HOST_CTX")"
SUJ_DATE="$(stat -c %y "$HOST_SUJETS")"
PAR_DATE="$(stat -c %y "$HOST_PART")"

echo "CSV         : $CSV_DATE"
echo "CTX         : $CTX_DATE"
echo "Sujets      : $SUJ_DATE"
echo "Participants: $PAR_DATE"

DESYNC=0

if (( csv_age_h > MAX_AGE_HOURS )); then
  echo "⚠ CSV ancien ($csv_age_h h)"
fi

if (( csv_mtime > ctx_mtime )); then
  echo "⚠ CSV plus récent que contexte"
  DESYNC=1
fi

if (( csv_mtime > suj_mtime )); then
  echo "⚠ CSV plus récent que Sujets.xlsx"
  DESYNC=1
fi

if (( csv_mtime > par_mtime )); then
  echo "⚠ CSV plus récent que Participants.xlsx"
  DESYNC=1
fi

if [[ $STRICT_SYNC -eq 1 && $DESYNC -eq 1 ]]; then
  echo "ERREUR: désalignement détecté (mode strict)."
  exit 3
fi

echo "=== Validation terminée ==="

# ----------------------------
# Vérifications BLOQUANTES
# ----------------------------
echo "=== Vérifications (obligatoires) ==="
echo "CSV     : $CSV_PATH"
echo "CTX     : $CTX_PATH"
echo "SUJETS  : $SUJETS_PATH"
echo "PART    : $PART_PATH"
echo "OUT     : $OUT_DIR"
echo "MODE    : $([[ $DRY_RUN -eq 1 ]] && echo 'DRY-RUN' || echo 'RUN')"
echo "FORCE   : $([[ $FORCE -eq 1 ]] && echo 'ON' || echo 'OFF')"

docker exec cr-pipeline sh -lc "test -f \"$CSV_PATH\"    || (echo 'KO: CSV introuvable' && exit 2)"
docker exec cr-pipeline sh -lc "test -f \"$SUJETS_PATH\" || (echo 'KO: Sujets.xlsx introuvable (obligatoire)' && exit 2)"
docker exec cr-pipeline sh -lc "test -f \"$PART_PATH\"   || (echo 'KO: Participants.xlsx introuvable (obligatoire)' && exit 2)"

# Créer OutDir + dossier logs
docker exec cr-pipeline sh -lc "mkdir -p \"$OUT_DIR\" \"$OUT_DIR/logs\""

# ----------------------------
# Logging (sur l'hôte, dans le partage)
# - on écrit directement dans /volume1/Affaires/... via son équivalent hôte
# - déduction : /data/Affaires/... <=> /volume1/Affaires/...
# ----------------------------
# On fabrique un chemin hôte pour le log (car docker exec ne "tee" pas facilement côté conteneur)
# Hypothèse validée chez vous : /volume1/Affaires est bind-mounté dans /data/Affaires
host_log_dir="/volume1/Affaires${OUT_DIR#/data/Affaires}/logs"
mkdir -p "$host_log_dir"

ts="$(date '+%Y%m%d_%H%M%S')"
log_file="$host_log_dir/run_${ts}.log"
PSEUDO_JOB_ID="cr_${AFFAIRE_ID}_${CAPTATION_ID}_${RUN_JOB_ID}"
PSEUDO_PART_PATH="$(to_unc_affaires_path "$PART_PATH")"

# Tout ce qui suit est loggué
exec > >(tee -a "$log_file") 2>&1

echo "=== LOG START: $(date -Is) ==="
echo "Infos JSON: $INFOS"
echo "Profil: $PROFILE"

# ----------------------------
# Valeurs LLM (défauts stack)
# ----------------------------
PROVIDER="$(json_get provider)";        [[ -z "$PROVIDER" ]] && PROVIDER="openai"
API_BASE="$(json_get api_base)";        [[ -z "$API_BASE" ]] && API_BASE="http://openai-adapter:5055"
MODEL_P1="$(json_get model_pass1)";     [[ -z "$MODEL_P1" ]] && MODEL_P1="annoter_segments_remote"
MODEL_P2="$(json_get model_pass2)";     [[ -z "$MODEL_P2" ]] && MODEL_P2="annoter_segments_remote"
MODEL_P3="$(json_get model_pass3)";     [[ -z "$MODEL_P3" ]] && MODEL_P3="annoter_segments_remote_alt"
PRESET="$(json_get preset)";            [[ -z "$PRESET" ]] && PRESET="equilibre"

echo "Provider: $PROVIDER"
echo "ApiBase : $API_BASE"
echo "ModelP1 : $MODEL_P1"
echo "ModelP2 : $MODEL_P2"
echo "ModelP3 : $MODEL_P3"
echo "Preset : $PRESET"

PSEUDO_API_BASE="${PSEUDO_API_BASE:-http://192.168.0.155:5000}"
PSEUDO_API_KEY="${LOCAL_LLM_API_KEY:-}"
PSEUDONYMIZE_REMOTE=0
if uses_remote_llm "$PROVIDER" "$MODEL_P1" "$MODEL_P2" "$MODEL_P3"; then
  PSEUDONYMIZE_REMOTE=1
fi

python3 - <<'PY' "$INFOS" "$PSEUDO_JOB_ID" "$PSEUDO_API_BASE"
import json
import sys
from pathlib import Path

infos_path = Path(sys.argv[1])
pseudo_job_id = sys.argv[2]
pseudo_api_base = sys.argv[3]

with infos_path.open("r", encoding="utf-8") as f:
    data = json.load(f)

compte_rendu = data.get("compte_rendu")
if not isinstance(compte_rendu, dict):
    compte_rendu = {}
    data["compte_rendu"] = compte_rendu

compte_rendu["pseudo_job_id"] = pseudo_job_id
compte_rendu["pseudo_api_base"] = pseudo_api_base

with infos_path.open("w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY

# ------------------------------
METADATA_FILE="$host_log_dir/run_metadata_${ts}.json"

cat > "$METADATA_FILE" <<EOF
{
  "timestamp": "$(date -Is)",
  "profil": "$PROFILE",
  "strict_sync": $STRICT_SYNC,
  "id_affaire": "$AFFAIRE_ID",
  "id_captation": "$CAPTATION_ID",
  "csv": { "path": "$CSV_PATH", "modified": "$CSV_DATE" },
  "contexte": { "path": "$CTX_PATH", "modified": "$CTX_DATE" },
  "sujets": { "path": "$SUJETS_PATH", "modified": "$SUJ_DATE" },
  "participants": { "path": "$PART_PATH", "modified": "$PAR_DATE" },
  "provider": "$PROVIDER",
  "api_base": "$API_BASE",
  "model_pass1": "$MODEL_P1",
  "model_pass2": "$MODEL_P2",
  "model_pass3": "$MODEL_P3",
  "preset": "$PRESET",
  "pseudonymize_remote": $PSEUDONYMIZE_REMOTE,
  "pseudo_api_base": "$PSEUDO_API_BASE",
  "pseudo_job_id": "$PSEUDO_JOB_ID"
}
EOF

echo "Metadata écrit dans: $METADATA_FILE"

# ----------------------------
# Commande PS1
# ----------------------------
API_KEY='*CRpy#VrWz#5zh&F%ww6zY24U'

cmd=(docker exec -it cr-pipeline pwsh /pipeline/powershell/cr_reunion_point_mumerotes_pipeline_json.ps1
  -CsvPath "$CSV_PATH"
  -OutDir "$OUT_DIR"
  -ContextJsonPath "$CTX_PATH"
  -SujetsPath "$SUJETS_PATH"
  -ApiKey "$API_KEY"
  -ParticipantsPath "$PART_PATH"
  -Provider "$PROVIDER"
  -ApiBase "$API_BASE"
  -ModelPass1 "$MODEL_P1"
  -ModelPass2 "$MODEL_P2"
  -ModelPass3 "$MODEL_P3"
  -Preset "$PRESET"
)

if [[ $PSEUDONYMIZE_REMOTE -eq 1 ]]; then
  if [[ -z "$PSEUDO_API_BASE" ]]; then
    echo "ERREUR: pseudonymisation distante active mais PSEUDO_API_BASE est vide."
    exit 13
  fi
  if [[ -z "$PSEUDO_API_KEY" ]]; then
    echo "ERREUR: pseudonymisation distante active mais LOCAL_LLM_API_KEY est vide."
    exit 14
  fi

  cmd+=(
    -PseudonymizeRemote
    -PseudoApiBase "$PSEUDO_API_BASE"
    -PseudoApiKey "$PSEUDO_API_KEY"
    -PseudoJobId "$PSEUDO_JOB_ID"
    -PseudoParticipantsPath "$PSEUDO_PART_PATH"
  )
fi

if [[ $FORCE -eq 1 ]]; then
  cmd+=(-Force)
fi

echo "=== Commande ==="
printf '%q ' "${cmd[@]}"
echo
echo "=== Log file ==="
echo "$log_file"

if [[ $DRY_RUN -eq 1 ]]; then
  echo "DRY-RUN: aucune exécution."
  echo "=== LOG END: $(date -Is) ==="
  exit 0
fi

# ----------------------------
# Exécution
# ----------------------------
"${cmd[@]}"
rc=$?

# ----------------------------
# Post-traitements sur OUT_DIR (NAS)
# ----------------------------
HOST_OUT_ROOT="/volume1/Affaires${OUT_ROOT#/data/Affaires}"
HOST_OUT_DIR="/volume1/Affaires${OUT_DIR#/data/Affaires}"

# 1) Normaliser les mtimes (pour éviter les inversions de sens côté rsync)
#    Attention: on parenthèse bien les -o avec find
if [[ -d "$HOST_OUT_DIR" ]]; then
  find "$HOST_OUT_DIR" -type f \( -name "*.csv" -o -name "*.json" -o -name "*.docx" \) -print0 \
    | xargs -0 -I{} touch -m "{}"
fi

# 2) Génération DOCX depuis global_final.json (sur le NAS)
if [[ $rc -eq 0 ]]; then
  echo "=== Rendu DOCX final via render_compte_rendu_from_infos.py ==="

  required_jsons=(global.json global_meeting.json global_by_sujet.json global_final.json)
  mkdir -p "$HOST_OUT_ROOT"
  for json_name in "${required_jsons[@]}"; do
    src_json="${HOST_OUT_DIR}/${json_name}"
    dst_json="${HOST_OUT_ROOT}/${json_name}"
    if [[ ! -f "$src_json" ]]; then
      echo "❌ ${json_name} introuvable dans le run isolé: $src_json"
      rc=5
      break
    fi
    cp -f "$src_json" "$dst_json"
    touch -m "$dst_json"
  done

  HOST_OUT_JSON="${HOST_OUT_ROOT}/global_final.json"
  PY_RENDER="${SCRIPT_DIR}/render_compte_rendu_from_infos.py"

  echo "Source JSON : $HOST_OUT_JSON"
  echo "Render script : $PY_RENDER"
  echo "PseudoJobId   : $PSEUDO_JOB_ID"
  echo "Run output    : $HOST_OUT_DIR"
  echo "Canonical dir : $HOST_OUT_ROOT"

  if [[ $rc -ne 0 ]]; then
    :
  elif [[ ! -f "$HOST_OUT_JSON" ]]; then
    echo "❌ global_final.json introuvable"
    rc=6
  elif [[ ! -f "$PY_RENDER" ]]; then
    echo "❌ render_compte_rendu_from_infos.py introuvable"
    rc=7
  else
    render_cmd=(python3 "$PY_RENDER"
      --infos "$INFOS"
      --global-final "$HOST_OUT_JSON"
      --provider "$PROVIDER"
      --model-pass1 "$MODEL_P1"
      --model-pass2 "$MODEL_P2"
      --model-pass3 "$MODEL_P3"
    )

    if [[ $PSEUDONYMIZE_REMOTE -eq 1 ]]; then
      render_cmd+=(
        --pseudo-job-id "$PSEUDO_JOB_ID"
        --pseudo-api-base "$PSEUDO_API_BASE"
        --pseudo-api-key "$PSEUDO_API_KEY"
      )
    else
      render_cmd+=(--no-pseudonymize-remote)
    fi

    echo "=== Commande render final ==="
    printf '%q ' "${render_cmd[@]}"
    echo

    "${render_cmd[@]}" || rc=$?
  fi
fi

echo "=== FIN (exit=$rc): $(date -Is) ==="
exit $rc
