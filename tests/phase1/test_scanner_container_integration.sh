#!/usr/bin/env sh
set -eu

test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$test_dir/../.." && pwd)
container_name=${CR_PIPELINE_TEST_CONTAINER:-cr-pipeline}
run_id="codex_phase1_scanner_$$_$(date +%s)"
container_tmp="/tmp/$run_id"
python_bin="/usr/bin/python3"

host_scanner="$repo_root/cr-pipeline/pipeline/python/publishable_terminology.py"
host_blocking_fixture="$test_dir/fixtures/global_final_j54.json"
host_warning_fixture="$test_dir/fixtures/warning_only.json"

scanner="$container_tmp/publishable_terminology.py"
clean_fixture="$container_tmp/clean.json"
warning_fixture="$container_tmp/warning_only.json"
blocking_fixture="$container_tmp/global_final_j54.json"
invalid_fixture="$container_tmp/invalid.json"
clean_report="$container_tmp/clean_report.json"
warning_report="$container_tmp/warning_report.json"
blocking_report="$container_tmp/blocking_report.json"
invalid_report="$container_tmp/invalid_report.json"

cleanup() {
  docker exec "$container_name" rm -rf -- "$container_tmp" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

test -f "$host_scanner"
test -f "$host_blocking_fixture"
test -f "$host_warning_fixture"

docker exec "$container_name" mkdir -p "$container_tmp"
docker cp "$host_scanner" "$container_name:$scanner" >/dev/null
docker cp "$host_blocking_fixture" "$container_name:$blocking_fixture" >/dev/null
docker cp "$host_warning_fixture" "$container_name:$warning_fixture" >/dev/null
docker exec "$container_name" sh -c 'printf "%s\n" "$1" > "$2"' sh \
  '{"resume":"Le document décrit une constatation matérielle."}' "$clean_fixture"
docker exec "$container_name" sh -c 'printf "%s\n" "$1" > "$2"' sh \
  '{"resume":' "$invalid_fixture"

docker exec "$container_name" test -x "$python_bin"
docker exec "$container_name" "$python_bin" --version
docker exec "$container_name" sh -lc '
  test -f /pipeline/powershell/dependency_plan.psm1 && echo MODULE_PATH_OK=/pipeline/powershell/dependency_plan.psm1
  test -d /pipeline/python && echo SCANNER_PARENT_OK=/pipeline/python
  if test -e /pipeline/python/publishable_terminology.py; then
    echo PRODUCTION_SCANNER_PRESENT=yes
  else
    echo PRODUCTION_SCANNER_PRESENT=no
  fi
'

set +e
docker exec "$container_name" "$python_bin" "$scanner" \
  --input "$clean_fixture" --stage final --report "$clean_report"
clean_rc=$?
docker exec "$container_name" "$python_bin" "$scanner" \
  --input "$warning_fixture" --stage final --report "$warning_report"
warning_rc=$?
docker exec "$container_name" "$python_bin" "$scanner" \
  --input "$blocking_fixture" --stage final --report "$blocking_report"
blocking_rc=$?
invalid_output=$(docker exec "$container_name" "$python_bin" "$scanner" \
  --input "$invalid_fixture" --stage final --report "$invalid_report" 2>&1)
invalid_rc=$?
set -e

printf 'CLEAN_RC=%s\n' "$clean_rc"
printf 'WARNING_RC=%s\n' "$warning_rc"
printf 'BLOCK_RC=%s\n' "$blocking_rc"
printf 'INVALID_RC=%s\n' "$invalid_rc"

test "$clean_rc" -eq 0
test "$warning_rc" -eq 0
test "$blocking_rc" -eq 42
test "$invalid_rc" -eq 2
printf '%s\n' "$invalid_output" | grep 'PUBLISHABLE_TERMINOLOGY_SCAN_ERROR' >/dev/null
if docker exec "$container_name" test -e "$invalid_report"; then
  echo "Un rapport ne doit pas être produit pour un JSON invalide." >&2
  exit 1
fi

docker exec "$container_name" "$python_bin" -c '
import json
import sys

path, expected = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as stream:
    report = json.load(stream)

if expected == "clean":
    assert report["ok"] is True
    assert report["blocking_count"] == 0
    assert report["warning_count"] == 0
elif expected == "warning":
    assert report["ok"] is True
    assert report["blocking_count"] == 0
    assert report["warning_count"] >= 1
    assert any(item["severity"] == "warning" for item in report["findings"])
elif expected == "blocking":
    assert report["ok"] is False
    assert report["blocking_count"] >= 1
    assert any(item["severity"] == "blocking" for item in report["findings"])
else:
    raise AssertionError("type de rapport inattendu")
' "$clean_report" clean
docker exec "$container_name" "$python_bin" -c '
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    report = json.load(stream)
assert report["ok"] is True
assert report["blocking_count"] == 0
assert report["warning_count"] >= 1
assert any(item["severity"] == "warning" for item in report["findings"])
' "$warning_report"
docker exec "$container_name" "$python_bin" -c '
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    report = json.load(stream)
assert report["ok"] is False
assert report["blocking_count"] >= 1
assert any(item["severity"] == "blocking" for item in report["findings"])
' "$blocking_report"

echo "SCANNER_CONTAINER_INTEGRATION_OK"
