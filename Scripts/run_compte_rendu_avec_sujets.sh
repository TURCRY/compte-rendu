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
ONLY_PASS2B_BATCHES=""
ONLY_SUBJECTS=""
EXISTING_RUN=""
EXPLICIT_OUT_DIR=""
REPRISE_PASS2B=0
REUSE_EXISTING_RUN=0
DOCX_ONLY=0
RENDER_URL="${CR_RENDER_URL:-http://192.168.1.20:8081/render?format=docx}"


while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift;;
    --force)   FORCE=1; shift;;
    --strict-sync) STRICT_SYNC=1; shift;;
    --no-force) FORCE=0; shift;;   # option explicite, utile en n8n
    --docx-only) DOCX_ONLY=1; shift;;
    --only-pass2b-batches)
      REPRISE_PASS2B=1
      ONLY_PASS2B_BATCHES="${2:-}"
      if [[ -z "$ONLY_PASS2B_BATCHES" ]]; then
        echo "ERREUR: --only-pass2b-batches attend une liste, ex: 9 ou 7,9"
        exit 2
      fi
      shift 2
      ;;
    --only-subjects)
      ONLY_SUBJECTS="${2:-}"
      if [[ -z "$ONLY_SUBJECTS" ]]; then
        echo "ERREUR: --only-subjects attend une liste, ex: 1,2,3"
        exit 2
      fi
      shift 2
      ;;
    --existing-run)
      EXISTING_RUN="${2:-}"
      if [[ -z "$EXISTING_RUN" ]]; then
        echo "ERREUR: --existing-run attend un nom de dossier, ex: job_20260429_105314_404634387_21158"
        exit 2
      fi
      shift 2
      ;;
    --out-dir)
      EXPLICIT_OUT_DIR="${2:-}"
      if [[ -z "$EXPLICIT_OUT_DIR" ]]; then
        echo "ERREUR: --out-dir attend un chemin de run existant"
        exit 2
      fi
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 \"/chemin/vers/infos_projet.json\" [--dry-run] [--force|--no-force] [--docx-only] [--only-pass2b-batches \"9\"|\"7,9\"] [--only-subjects \"1,2,3\"] [--existing-run job_...] [--out-dir /chemin/run]"
      exit 0
      ;;
    *)
      echo "Option inconnue: $1"
      echo "Usage: $0 \"/chemin/vers/infos_projet.json\" [--dry-run] [--force|--no-force] [--docx-only] [--only-pass2b-batches \"9\"|\"7,9\"] [--only-subjects \"1,2,3\"] [--existing-run job_...] [--out-dir /chemin/run]"
      echo "STRICT_SYNC : $([[ $STRICT_SYNC -eq 1 ]] && echo 'ON' || echo 'OFF')"
      exit 2
      ;;
  esac
done

if [[ -z "$INFOS" ]]; then
  echo "Usage: $0 \"/chemin/vers/infos_projet.json\" [--dry-run] [--force|--no-force] [--docx-only] [--only-pass2b-batches \"9\"|\"7,9\"] [--only-subjects \"1,2,3\"] [--existing-run job_...] [--out-dir /chemin/run]"
  exit 2
fi
if [[ ! -f "$INFOS" ]]; then
  echo "ERREUR: fichier introuvable: $INFOS"
  exit 2
fi

PASS2B_BATCHES_ARR=()
if [[ -n "$ONLY_PASS2B_BATCHES" ]]; then
  IFS=',' read -r -a _pass2b_batches_raw <<< "$ONLY_PASS2B_BATCHES"
  for batch_num in "${_pass2b_batches_raw[@]}"; do
    batch_num="${batch_num//[[:space:]]/}"
    if [[ -z "$batch_num" || ! "$batch_num" =~ ^[0-9]+$ || "$batch_num" -eq 0 ]]; then
      echo "ERREUR: --only-pass2b-batches doit contenir des entiers > 0 séparés par des virgules: $ONLY_PASS2B_BATCHES"
      exit 2
    fi
    PASS2B_BATCHES_ARR+=("$batch_num")
  done
fi
ONLY_SUBJECTS_ARR=()
if [[ -n "$ONLY_SUBJECTS" ]]; then
  IFS=',' read -r -a _only_subjects_raw <<< "$ONLY_SUBJECTS"
  for subject_num in "${_only_subjects_raw[@]}"; do
    subject_num="${subject_num//[[:space:]]/}"
    if [[ -z "$subject_num" || ! "$subject_num" =~ ^[0-9]+$ || "$subject_num" -eq 0 ]]; then
      echo "ERREUR: --only-subjects doit contenir des entiers > 0 séparés par des virgules: $ONLY_SUBJECTS"
      exit 2
    fi
    ONLY_SUBJECTS_ARR+=("$subject_num")
  done
fi
if [[ $DOCX_ONLY -eq 1 && ( -n "$ONLY_PASS2B_BATCHES" || -n "$ONLY_SUBJECTS" ) ]]; then
  echo "ERREUR: --docx-only ne peut pas être combiné avec une reprise ciblée."
  exit 2
fi
if [[ -n "$ONLY_PASS2B_BATCHES" && -n "$ONLY_SUBJECTS" ]]; then
  echo "ERREUR: utilisez soit --only-pass2b-batches, soit --only-subjects, pas les deux."
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
  elif [[ "$p" == /volume1/Affaires/* ]]; then
    p="/data/Affaires/${p#/volume1/Affaires/}"
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

# ----------------------------
# Valeurs LLM (défauts stack)
# ----------------------------
PROVIDER="$(json_get provider)";        [[ -z "$PROVIDER" ]] && PROVIDER="openai"
API_BASE="$(json_get api_base)";        [[ -z "$API_BASE" ]] && API_BASE="http://openai-adapter:5055"
MODEL_P1="$(json_get model_pass1)";     [[ -z "$MODEL_P1" ]] && MODEL_P1="annoter_segments_remote"
MODEL_P2="$(json_get model_pass2)";     [[ -z "$MODEL_P2" ]] && MODEL_P2="annoter_segments_remote"
MODEL_P3="$(json_get model_pass3)";     [[ -z "$MODEL_P3" ]] && MODEL_P3="annoter_segments_remote_alt"
PRESET="$(json_get preset)";            [[ -z "$PRESET" ]] && PRESET="equilibre"

OUT_ROOT="/data/Affaires/${AFFAIRE_ID}/BE_Traitement_captations/${CAPTATION_ID}/compte_rendu_LLM"
RUN_JOB_ID="job_$(date +%Y%m%d_%H%M%S_%N)_$$"
OUT_DIR="${OUT_ROOT}/out/${RUN_JOB_ID}"
RESUME_RUN_MSG=""

if [[ -n "$EXISTING_RUN" && -n "$EXPLICIT_OUT_DIR" ]]; then
  echo "ERREUR: utilisez soit --existing-run, soit --out-dir, pas les deux."
  exit 2
fi

if [[ -n "$EXISTING_RUN" ]]; then
  if [[ "$EXISTING_RUN" == */* || "$EXISTING_RUN" == *\\* ]]; then
    echo "ERREUR: --existing-run attend un nom de dossier, pas un chemin: $EXISTING_RUN"
    exit 2
  fi
  RUN_JOB_ID="$EXISTING_RUN"
  OUT_DIR="${OUT_ROOT}/out/${RUN_JOB_ID}"
  REUSE_EXISTING_RUN=1
elif [[ -n "$EXPLICIT_OUT_DIR" ]]; then
  OUT_DIR="$(to_container_path "$EXPLICIT_OUT_DIR")"
  RUN_JOB_ID="$(basename "$OUT_DIR")"
  REUSE_EXISTING_RUN=1
elif [[ $DOCX_ONLY -eq 1 ]]; then
  OUT_DIR="$(docker exec cr-pipeline sh -lc "ls -1td \"$OUT_ROOT\"/out/job_* 2>/dev/null | while IFS= read -r d; do if [ -s \"\$d/global_final.json\" ]; then echo \"\$d\"; break; fi; done")"
  if [[ -z "$OUT_DIR" ]]; then
    echo "ERREUR: aucun run existant exploitable trouvé dans ${OUT_ROOT}/out/job_*"
    echo "Attendu: global_final.json non vide"
    exit 2
  fi
  RUN_JOB_ID="$(basename "$OUT_DIR")"
  REUSE_EXISTING_RUN=1
elif [[ ${#PASS2B_BATCHES_ARR[@]} -gt 0 ]]; then
  REPRISE_PASS2B=1
  OUT_DIR="$(docker exec cr-pipeline sh -lc "ls -1td \"$OUT_ROOT\"/out/job_* 2>/dev/null | while IFS= read -r d; do if [ -d \"\$d/segments\" ] && [ -d \"\$d/pass2B_batches\" ] && [ -f \"\$d/global.json\" ]; then echo \"\$d\"; break; fi; done")"
  if [[ -z "$OUT_DIR" ]]; then
    echo "ERREUR: aucun run existant exploitable trouvé dans ${OUT_ROOT}/out/job_*"
    echo "Attendu: segments/, pass2B_batches/ et global.json"
    exit 2
  fi
  RUN_JOB_ID="$(basename "$OUT_DIR")"
  REUSE_EXISTING_RUN=1
elif [[ ${#ONLY_SUBJECTS_ARR[@]} -gt 0 ]]; then
  OUT_DIR="$(docker exec cr-pipeline sh -lc "ls -1td \"$OUT_ROOT\"/out/job_* 2>/dev/null | while IFS= read -r d; do if [ -d \"\$d/segments\" ] && [ -f \"\$d/global.json\" ]; then echo \"\$d\"; break; fi; done")"
  if [[ -z "$OUT_DIR" ]]; then
    echo "ERREUR: aucun run existant exploitable trouvé dans ${OUT_ROOT}/out/job_*"
    echo "Attendu: segments/ et global.json"
    exit 2
  fi
  RUN_JOB_ID="$(basename "$OUT_DIR")"
  REUSE_EXISTING_RUN=1
elif [[ $FORCE -eq 0 ]]; then
  EXISTING_OUT_DIR="$(docker exec cr-pipeline sh -lc "ls -1td \"$OUT_ROOT\"/out/job_* 2>/dev/null | while IFS= read -r d; do if [ -f \"\$d/global.json\" ] || [ -d \"\$d/segments\" ]; then echo \"\$d\"; break; fi; done")"
  if [[ -n "$EXISTING_OUT_DIR" ]]; then
    OUT_DIR="$EXISTING_OUT_DIR"
    RUN_JOB_ID="$(basename "$OUT_DIR")"
    REUSE_EXISTING_RUN=1
  fi
fi

if [[ $REUSE_EXISTING_RUN -eq 1 ]]; then
  if [[ $DOCX_ONLY -eq 1 ]]; then
    RESUME_RUN_MSG="Generation DOCX sur run existant : $OUT_DIR"
  elif [[ ${#PASS2B_BATCHES_ARR[@]} -gt 0 ]]; then
    RESUME_RUN_MSG="Reprise ciblée sur run existant : $OUT_DIR"
  elif [[ ${#ONLY_SUBJECTS_ARR[@]} -gt 0 ]]; then
    RESUME_RUN_MSG="Reprise sujets ciblés sur run existant : $OUT_DIR"
  else
    RESUME_RUN_MSG="Reprise sur run existant : $OUT_DIR"
  fi
else
  RESUME_RUN_MSG="Nouveau run créé : $OUT_DIR (force=$FORCE ou aucun run existant)"
fi
if [[ "$OUT_DIR" != /data/Affaires/* ]]; then
  echo "ERREUR: OUT_DIR doit pointer dans /data/Affaires: $OUT_DIR"
  exit 2
fi


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
if [[ -n "$RESUME_RUN_MSG" ]]; then
  echo "$RESUME_RUN_MSG"
fi
echo "MODE    : $([[ $DRY_RUN -eq 1 ]] && echo 'DRY-RUN' || echo 'RUN')"
echo "FORCE   : $([[ $FORCE -eq 1 ]] && echo 'ON' || echo 'OFF')"

docker exec cr-pipeline sh -lc "test -f \"$CSV_PATH\"    || (echo 'KO: CSV introuvable' && exit 2)"
docker exec cr-pipeline sh -lc "test -f \"$SUJETS_PATH\" || (echo 'KO: Sujets.xlsx introuvable (obligatoire)' && exit 2)"
docker exec cr-pipeline sh -lc "test -f \"$PART_PATH\"   || (echo 'KO: Participants.xlsx introuvable (obligatoire)' && exit 2)"

# Créer OutDir + dossier logs
if [[ $DOCX_ONLY -eq 1 && ${#PASS2B_BATCHES_ARR[@]} -eq 0 ]]; then
  docker exec cr-pipeline sh -lc "test -d \"$OUT_DIR\" || (echo 'KO: run existant introuvable: $OUT_DIR' && exit 2)"
  docker exec cr-pipeline sh -lc "test -s \"$OUT_DIR/global_final.json\" || (echo 'KO: global_final.json absent ou vide dans le run: $OUT_DIR' && exit 2)"
  docker exec cr-pipeline sh -lc "mkdir -p \"$OUT_DIR/logs\""
elif [[ ${REPRISE_PASS2B:-0} -eq 1 ]]; then
  docker exec cr-pipeline sh -lc "test -d \"$OUT_DIR\" || (echo 'KO: run existant introuvable: $OUT_DIR' && exit 2)"
  docker exec cr-pipeline sh -lc "test -d \"$OUT_DIR/segments\" || (echo 'KO: segments/ absent dans le run: $OUT_DIR' && exit 2)"
  docker exec cr-pipeline sh -lc "test -d \"$OUT_DIR/pass2B_batches\" || (echo 'KO: pass2B_batches/ absent dans le run: $OUT_DIR' && exit 2)"
  docker exec cr-pipeline sh -lc "test -f \"$OUT_DIR/global.json\" || (echo 'KO: global.json absent dans le run: $OUT_DIR' && exit 2)"

  if [[ "${PROVIDER,,}" == "openai" && "${MODEL_P2,,}" == *remote* ]]; then
    PASS2_BATCH_SIZE=4
  else
    PASS2_BATCH_SIZE=2
  fi
  SEG_COUNT="$(docker exec cr-pipeline sh -lc "ls -1 \"$OUT_DIR\"/segments/segment_*.json 2>/dev/null | wc -l")"
  if [[ -z "$SEG_COUNT" || "$SEG_COUNT" -eq 0 ]]; then
    echo "ERREUR: aucun segment_*.json trouvé dans $OUT_DIR/segments"
    exit 2
  fi
  EXPECTED_PASS2B_COUNT=$(( (SEG_COUNT + PASS2_BATCH_SIZE - 1) / PASS2_BATCH_SIZE ))

  missing_batches=()
  for ((i=1; i<=EXPECTED_PASS2B_COUNT; i++)); do
    targeted=0
    for batch_num in "${PASS2B_BATCHES_ARR[@]}"; do
      if [[ "$batch_num" -eq "$i" ]]; then targeted=1; break; fi
    done
    if [[ $targeted -eq 0 ]]; then
      printf -v batch_file "%s/pass2B_batches/pass2B_batch_%02d.json" "$OUT_DIR" "$i"
      if ! docker exec cr-pipeline sh -lc "test -f \"$batch_file\""; then
        missing_batches+=("$i")
      fi
    fi
  done
  for batch_num in "${PASS2B_BATCHES_ARR[@]}"; do
    if (( batch_num > EXPECTED_PASS2B_COUNT )); then
      echo "ERREUR: batch ciblé $batch_num > nombre attendu $EXPECTED_PASS2B_COUNT (segments=$SEG_COUNT, Pass2BatchSize=$PASS2_BATCH_SIZE)"
      exit 2
    fi
  done
  if [[ ${#missing_batches[@]} -gt 0 ]]; then
    echo "ERREUR: batches Pass2B non ciblés manquants dans le run existant: ${missing_batches[*]}"
    echo "Run: $OUT_DIR"
    exit 2
  fi

  docker exec cr-pipeline sh -lc "mkdir -p \"$OUT_DIR/logs\""
elif [[ ${#ONLY_SUBJECTS_ARR[@]} -gt 0 ]]; then
  docker exec cr-pipeline sh -lc "test -d \"$OUT_DIR\" || (echo 'KO: run existant introuvable: $OUT_DIR' && exit 2)"
  docker exec cr-pipeline sh -lc "test -d \"$OUT_DIR/segments\" || (echo 'KO: segments/ absent dans le run: $OUT_DIR' && exit 2)"
  docker exec cr-pipeline sh -lc "test -f \"$OUT_DIR/global.json\" || (echo 'KO: global.json absent dans le run: $OUT_DIR' && exit 2)"
  docker exec cr-pipeline sh -lc "mkdir -p \"$OUT_DIR/logs\""
elif [[ ${REUSE_EXISTING_RUN:-0} -eq 1 ]]; then
  docker exec cr-pipeline sh -lc "test -d \"$OUT_DIR\" || (echo 'KO: run existant introuvable: $OUT_DIR' && exit 2)"
  docker exec cr-pipeline sh -lc "test -f \"$OUT_DIR/global.json\" || test -d \"$OUT_DIR/segments\" || (echo 'KO: run existant sans global.json ni segments/: $OUT_DIR' && exit 2)"
  docker exec cr-pipeline sh -lc "mkdir -p \"$OUT_DIR/logs\""
else
  docker exec cr-pipeline sh -lc "mkdir -p \"$OUT_DIR\" \"$OUT_DIR/logs\""
fi

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
if [[ -n "$RESUME_RUN_MSG" ]]; then
  echo "$RESUME_RUN_MSG"
fi

# ----------------------------
# Valeurs LLM (défauts stack)
# ----------------------------
echo "Provider: $PROVIDER"
echo "ApiBase : $API_BASE"
echo "ModelP1 : $MODEL_P1"
echo "ModelP2 : $MODEL_P2"
echo "ModelP3 : $MODEL_P3"
echo "Preset : $PRESET"

if [[ $DOCX_ONLY -eq 1 && ${#PASS2B_BATCHES_ARR[@]} -eq 0 ]]; then
  HOST_OUT_DIR="/volume1/Affaires${OUT_DIR#/data/Affaires}"
  HOST_OUT_JSON="${HOST_OUT_DIR}/global_final.json"
  DOCX_TS="$(date +%Y%m%d_%H%M%S)"
  HOST_DOCX_OUT="${HOST_OUT_DIR}/compte_rendu_${AFFAIRE_ID}_${CAPTATION_ID}_V_${DOCX_TS}.docx"

  echo "=== Mode DOCX uniquement ==="
  echo "Run output    : $HOST_OUT_DIR"
  echo "Source JSON   : $HOST_OUT_JSON"
  echo "Render URL    : $RENDER_URL"
  echo "Generation DOCX -> $HOST_DOCX_OUT"

  if [[ ! -s "$HOST_OUT_JSON" ]]; then
    echo "ERREUR: global_final.json introuvable ou vide: $HOST_OUT_JSON"
    exit 6
  fi

  echo "=== Commande DOCX ==="
  echo "curl -fsS -X POST \"$RENDER_URL\" -H \"Content-Type: application/json\" --data-binary \"@${HOST_OUT_JSON}\" -o \"$HOST_DOCX_OUT\""

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "DRY-RUN: aucune génération DOCX."
    echo "=== LOG END: $(date -Is) ==="
    exit 0
  fi

  curl -fsS -X POST "$RENDER_URL" -H "Content-Type: application/json" --data-binary "@${HOST_OUT_JSON}" -o "$HOST_DOCX_OUT"
  echo "=== FIN (exit=0): $(date -Is) ==="
  exit 0
fi

PSEUDO_API_BASE="${PSEUDO_API_BASE:-http://192.168.0.155:5000}"
PSEUDO_API_KEY="${LOCAL_LLM_API_KEY:-}"
PSEUDONYMIZE_REMOTE=0
if uses_remote_llm "$PROVIDER" "$MODEL_P1" "$MODEL_P2" "$MODEL_P3"; then
  PSEUDONYMIZE_REMOTE=1
fi

HOST_OUT_ROOT="/volume1/Affaires${OUT_ROOT#/data/Affaires}"
mkdir -p "$HOST_OUT_ROOT" "$HOST_OUT_ROOT/logs"

if [[ ${REUSE_EXISTING_RUN:-0} -eq 1 ]]; then
  echo "Reprise: infos_projet.json non modifié."
else
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
fi

# ------------------------------
METADATA_FILE="$host_log_dir/run_metadata_${ts}.json"
PSEUDO_CONTEXT_FILE="$HOST_OUT_ROOT/pseudo_context.json"
PSEUDO_CONTEXT_HISTORY="$HOST_OUT_ROOT/logs/pseudo_context_${ts}.json"

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

python3 - <<'PY' "$PSEUDO_CONTEXT_FILE" "$PSEUDO_CONTEXT_HISTORY" "$AFFAIRE_ID" "$CAPTATION_ID" "$PSEUDO_JOB_ID" "$PSEUDO_API_BASE" "$PROVIDER" "$MODEL_P1" "$MODEL_P2" "$MODEL_P3" "$PRESET" "$PSEUDONYMIZE_REMOTE"
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

current_path = Path(sys.argv[1])
history_path = Path(sys.argv[2])
payload = {
    "id_affaire": sys.argv[3],
    "id_captation": sys.argv[4],
    "pseudo_job_id": sys.argv[5],
    "pseudo_api_base": sys.argv[6],
    "provider": sys.argv[7],
    "model_pass1": sys.argv[8],
    "model_pass2": sys.argv[9],
    "model_pass3": sys.argv[10],
    "preset": sys.argv[11],
    "pseudonymize_remote": sys.argv[12] == "1",
    "created_at": datetime.now(timezone.utc).isoformat(),
}
for path in (current_path, history_path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
        f.write("\n")
PY

echo "Pseudo context écrit dans: $PSEUDO_CONTEXT_FILE"
echo "Pseudo context historique écrit dans: $PSEUDO_CONTEXT_HISTORY"

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

if [[ -n "$ONLY_PASS2B_BATCHES" ]]; then
  cmd+=(-RebuildFromPass2B -OnlyPass2BBatches)
  for batch_num in "${PASS2B_BATCHES_ARR[@]}"; do
    cmd+=("$batch_num")
  done
  echo "Reprise ciblée Pass2B : batch(es) $ONLY_PASS2B_BATCHES ; aval reconstruit depuis Pass2B."
fi

if [[ -n "$ONLY_SUBJECTS" ]]; then
  cmd+=(-RebuildFromSubjects -OnlySubjectsCsv "$ONLY_SUBJECTS")
  echo "Reprise ciblée sujets : sujet(s) $ONLY_SUBJECTS ; split, Pass2E, Pass3E et aval reconstruits."
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
set +e
"${cmd[@]}"
rc=$?
set -e

# ----------------------------
# Post-traitements sur OUT_DIR (NAS)
# ----------------------------
HOST_OUT_DIR="/volume1/Affaires${OUT_DIR#/data/Affaires}"

# 1) Normaliser les mtimes (pour éviter les inversions de sens côté rsync)
#    Attention: on parenthèse bien les -o avec find
if [[ -d "$HOST_OUT_DIR" ]]; then
  find "$HOST_OUT_DIR" -type f \( -name "*.csv" -o -name "*.json" -o -name "*.docx" \) -print0 \
    | xargs -0 -I{} touch -m "{}"
fi

echo "=== Generation DOCX final ==="
HOST_OUT_JSON="${HOST_OUT_DIR}/global_final.json"
DOCX_TS="$(date +%Y%m%d_%H%M%S)"
HOST_DOCX_OUT="${HOST_OUT_DIR}/compte_rendu_${AFFAIRE_ID}_${CAPTATION_ID}_V_${DOCX_TS}.docx"

if [[ ! -s "$HOST_OUT_JSON" ]]; then
  echo "ERREUR: global_final.json introuvable ou vide: $HOST_OUT_JSON"
  rc=6
else
  echo "Generation DOCX -> $HOST_DOCX_OUT"
  echo "curl -fsS -X POST \"$RENDER_URL\" -H \"Content-Type: application/json\" --data-binary \"@${HOST_OUT_JSON}\" -o \"$HOST_DOCX_OUT\""
  curl -fsS -X POST "$RENDER_URL" -H "Content-Type: application/json" --data-binary "@${HOST_OUT_JSON}" -o "$HOST_DOCX_OUT" || rc=$?

  required_jsons=(global.json global_meeting.json global_by_sujet.json global_final.json)
  mkdir -p "$HOST_OUT_ROOT"
  for json_name in "${required_jsons[@]}"; do
    src_json="${HOST_OUT_DIR}/${json_name}"
    dst_json="${HOST_OUT_ROOT}/${json_name}"
    if [[ -f "$src_json" ]]; then
      cp -f "$src_json" "$dst_json"
      touch -m "$dst_json"
    fi
  done
fi

echo "=== FIN (exit=$rc): $(date -Is) ==="
exit $rc
