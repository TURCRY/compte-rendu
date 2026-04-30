#!/usr/bin/env bash
set -euo pipefail

INFOS_RAW="${1:-}"
INFOS="$INFOS_RAW"
if [[ $# -gt 0 ]]; then
  shift
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY_RENDER="${SCRIPT_DIR}/render_compte_rendu_from_infos.py"
ENV_FILE="${SCRIPT_DIR}/../.env"
PYTHON_BIN="${PYTHON_BIN:-python3}"

usage() {
  echo "Usage: $0 \"/chemin/vers/infos_projet.json\" [--global-final /chemin/global_final.json] [options render_compte_rendu_from_infos.py]" >&2
}

if [[ -z "$INFOS" || "$INFOS" == "-h" || "$INFOS" == "--help" ]]; then
  usage
  exit 2
fi

normalize_affaires_path() {
  local path="$1"
  local alt=""

  if [[ -e "$path" ]]; then
    echo "$path"
    return 0
  fi

  if [[ "$path" == /volume1/Affaires/* ]]; then
    alt="/data/Affaires/${path#/volume1/Affaires/}"
  elif [[ "$path" == /data/Affaires/* ]]; then
    alt="/volume1/Affaires/${path#/data/Affaires/}"
  fi

  if [[ -n "$alt" && -e "$alt" ]]; then
    echo "$alt"
  else
    echo "$path"
  fi
}

INFOS="$(normalize_affaires_path "$INFOS")"

if [[ ! -f "$INFOS" ]]; then
  echo "ERREUR: fichier introuvable: $INFOS" >&2
  if [[ "$INFOS" != "$INFOS_RAW" ]]; then
    echo "Chemin recu: $INFOS_RAW" >&2
  fi
  exit 2
fi

if [[ ! -f "$PY_RENDER" ]]; then
  echo "ERREUR: render_compte_rendu_from_infos.py introuvable: $PY_RENDER" >&2
  exit 2
fi

guard_stdout_not_infos() {
  local infos_real=""
  local stdout_real=""

  infos_real="$(readlink -f "$INFOS" 2>/dev/null || true)"
  stdout_real="$(readlink -f /proc/self/fd/1 2>/dev/null || true)"

  if [[ -n "$infos_real" && -n "$stdout_real" && "$infos_real" == "$stdout_real" ]]; then
    echo "ERREUR: la sortie standard pointe vers infos_projet.json." >&2
    echo "Refus d'executer pour eviter d'ecraser: $INFOS" >&2
    exit 30
  fi
}

validate_infos_json() {
  "$PYTHON_BIN" - "$INFOS" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8-sig")
first_line = text.lstrip().splitlines()[0] if text.lstrip().splitlines() else ""

if first_line.startswith("Usage:"):
    print(f"ERREUR: infos_projet.json semble corrompu par une sortie Usage: {path}", file=sys.stderr)
    sys.exit(31)

try:
    data = json.loads(text)
except json.JSONDecodeError as exc:
    print(f"ERREUR: infos_projet.json n'est pas un JSON valide: {path}", file=sys.stderr)
    print(f"Detail: ligne {exc.lineno}, colonne {exc.colno}: {exc.msg}", file=sys.stderr)
    sys.exit(32)

if not isinstance(data, dict):
    print(f"ERREUR: infos_projet.json doit contenir un objet JSON: {path}", file=sys.stderr)
    sys.exit(33)
PY
}

guard_stdout_not_infos
validate_infos_json

load_env_file() {
  local env_file="$1"
  [[ -f "$env_file" ]] || return 0

  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    local line="${raw_line#"${raw_line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* || "$line" != *=* ]] && continue

    local key="${line%%=*}"
    local value="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"

    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    if [[ -z "${!key+x}" ]]; then
      export "$key=$value"
    fi
  done < "$env_file"
}

load_env_file "$ENV_FILE"

if [[ -z "${CR_ROOT_AFFAIRES:-}" && "$INFOS" == /volume1/Affaires/* ]]; then
  export CR_ROOT_AFFAIRES="/volume1/Affaires"
fi

cmd=("$PYTHON_BIN" "$PY_RENDER" --infos "$INFOS" --docx-only)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --global-final)
      if [[ $# -lt 2 ]]; then
        echo "ERREUR: --global-final attend un chemin." >&2
        exit 2
      fi
      cmd+=(--global-final "$2")
      shift 2
      ;;
    --render-url|--pseudo-api-base|--pseudo-api-key|--pseudo-job-id|--provider|--model-pass1|--model-pass2|--model-pass3)
      if [[ $# -lt 2 ]]; then
        echo "ERREUR: $1 attend une valeur." >&2
        exit 2
      fi
      cmd+=("$1" "$2")
      shift 2
      ;;
    --pseudonymize-remote|--no-pseudonymize-remote)
      cmd+=("$1")
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Option inconnue: $1" >&2
      usage
      exit 2
      ;;
  esac
done

echo "=== Rendu DOCX seul depuis infos_projet.json ==="
echo "Infos recu : $INFOS_RAW"
echo "Infos normalise : $INFOS"
if [[ -f "$ENV_FILE" ]]; then
  echo "Env charge : ${ENV_FILE}"
fi
"${cmd[@]}"
