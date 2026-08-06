#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../Scripts/run_compte_rendu_avec_sujets.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

LIB="$TMP_DIR/docx_publish_lib.sh"
sed -n '/^publish_docx_to_canonical_dir() {/,/^uses_remote_llm() {/p' "$SCRIPT" | sed '$d' > "$LIB"
# shellcheck disable=SC1090
. "$LIB"

assert_file_content() {
  local file="$1"
  local expected="$2"
  local actual=""
  actual="$(cat "$file")"
  if [[ "$actual" != "$expected" ]]; then
    echo "Expected $file to contain '$expected', got '$actual'" >&2
    return 1
  fi
}

assert_grep() {
  local pattern="$1"
  local file="$2"
  if ! grep -qE "$pattern" "$file"; then
    echo "Missing expected pattern: $pattern" >&2
    return 1
  fi
}

canonical="$TMP_DIR/compte_rendu_LLM"
job_dir="$canonical/out/job_test"
mkdir -p "$job_dir"
source_docx="$job_dir/compte_rendu_2026-A60_accedit-2026-06-17_V_test.docx"
printf 'generated-v1' > "$source_docx"

publish_docx_to_canonical_dir "$source_docx" "$canonical" > "$TMP_DIR/publish.log"
target_docx="$canonical/$(basename "$source_docx")"
[[ -f "$target_docx" ]]
assert_file_content "$target_docx" 'generated-v1'
assert_file_content "$source_docx" 'generated-v1'
assert_grep 'docx_published_to_canonical_dir: ok' "$TMP_DIR/publish.log"

publish_docx_to_canonical_dir "$source_docx" "$canonical" > "$TMP_DIR/already.log"
assert_grep 'docx_published_to_canonical_dir: already_published' "$TMP_DIR/already.log"
[[ -z "$(find "$canonical" -maxdepth 1 -name '*.bak_*' -print -quit)" ]]

printf 'old-canonical' > "$target_docx"
printf 'generated-v2' > "$source_docx"
publish_docx_to_canonical_dir "$source_docx" "$canonical" > "$TMP_DIR/replace.log"
assert_file_content "$target_docx" 'generated-v2'
backup_file="$(find "$canonical" -maxdepth 1 -name "$(basename "$target_docx").bak_*" -print -quit)"
[[ -n "$backup_file" ]]
assert_file_content "$backup_file" 'old-canonical'
assert_file_content "$source_docx" 'generated-v2'
assert_grep 'docx_published_to_canonical_dir: backup_existing' "$TMP_DIR/replace.log"

bad_parent="$TMP_DIR/not_a_dir"
printf 'x' > "$bad_parent"
if publish_docx_to_canonical_dir "$source_docx" "$bad_parent/child" > "$TMP_DIR/error.log" 2>&1; then
  echo 'Expected publication error when canonical parent is a file' >&2
  exit 1
fi

assert_grep 'HOST_DOCX_OUT="\$\{HOST_OUT_DIR\}/compte_rendu_' "$SCRIPT"
assert_grep 'publish_docx_to_canonical_dir "\$HOST_DOCX_OUT" "\$HOST_OUT_ROOT"' "$SCRIPT"
assert_grep 'mirror_compte_rendu_livrables_to_pc "\$HOST_OUT_ROOT"' "$SCRIPT"
assert_grep 'docx_generated_in_job_dir:' "$SCRIPT"
assert_grep 'docx_mirrored_to_pc:' "$SCRIPT"

echo 'DOCX canonical publication tests OK'