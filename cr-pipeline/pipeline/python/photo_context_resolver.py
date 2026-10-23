"""Deterministic photo/ASR/subject context resolution.

This module is intentionally standalone: it does not import pipeline producers,
call an LLM, or write to source artifacts. Its output uses the P1a definitions
from the Pass3F provenance v2 schema and keeps photo, ASR, and editorial
subject numbers separate.
"""

from __future__ import annotations

import csv
import hashlib
import json
import math
import re
import unicodedata
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, Iterable, Mapping, Sequence


BUNDLE_FORMAT = "photo_context_resolver.bundle.v1"
COMPONENT_ID_RE = re.compile(r"^photo-component:[0-9a-f]{64}$")
ASSIGNMENT_ID_RE = re.compile(r"^photo-assignment:[0-9a-f]{64}$")
EXCLUSION_ID_RE = re.compile(r"^photo-exclusion:[0-9a-f]{64}$")
EVIDENCE_ID_RE = re.compile(r"^evidence-occurrence:[0-9a-f]{64}$")
SNAPSHOT_ID_RE = re.compile(r"^context-snapshot:[0-9a-f]{64}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")

_ASSIGNMENT_TYPES = {"assignment", "human_assignment", "photo_assignment"}
_EXCLUSION_TYPES = {"exclusion", "photo_exclusion"}
_COMPONENT_TYPES = {"component", "content_component", "photo_component"}
_DEFAULT_SELECTION_RULES = (
    "human_assignments_are_authoritative",
    "photo_scope_filters_by_photo_subject",
    "excluded_photos_are_omitted",
    "asr_proximity_is_candidate_only",
    "snapshot_is_prepared_not_llm_execution",
)

_CONTENT_SOURCE_PAIRS = (
    ("description_vlm_ui", "description_vlm_batch", "vlm_description"),
    ("libelle_propose_ui", "libelle_propose_batch", "annotation_label"),
    ("commentaire_propose_ui", "commentaire_propose_batch", "annotation_comment"),
)

_COMPONENT_SPECS = (
    ("description_vlm_ui", "vlm_description", "ui", "unknown",
     "description VLM enregistree via UI; validation humaine par champ non demontree"),
    ("description_vlm", "vlm_description", "pipeline", "unvalidated",
     "description VLM non validee humainement"),
    ("description_vlm_batch", "vlm_description", "batch", "unvalidated",
     "description VLM produite en batch; validation humaine non demontree"),
    ("libelle_propose_ui", "annotation_label", "ui", "unknown",
     "libelle enregistre via UI; validation humaine par champ non demontree"),
    ("libelle_propose_batch", "annotation_label", "batch", "unvalidated",
     "libelle propose en batch; validation humaine non demontree"),
    ("libelle_effectif", "annotation_label", "pipeline", "unknown",
     "libelle effectif calcule; validation humaine par champ non demontree"),
    ("commentaire_propose_ui", "annotation_comment", "ui", "unknown",
     "commentaire enregistre via UI; validation humaine par champ non demontree"),
    ("commentaire_propose_batch", "annotation_comment", "batch", "unvalidated",
     "commentaire propose en batch; validation humaine non demontree"),
    ("commentaire_effectif", "annotation_comment", "pipeline", "unknown",
     "commentaire effectif calcule; validation humaine par champ non demontree"),
    ("dictee_photo", "photo_dictation", "source", "unknown",
     "dictee photographique conservee dans la source; validation humaine non demontree"),
    ("dictee_asr_text", "photo_dictation", "source", "unknown",
     "dictee photographique issue de l'ASR; validation humaine non demontree"),
    ("transcription_photo", "photo_dictation", "source", "unknown",
     "transcription photographique conservee dans la source; validation humaine non demontree"),
)


class PhotoContextResolverError(ValueError):
    """Raised when a mandatory source cannot be interpreted safely."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


@dataclass(frozen=True)
class SourceSelection:
    photos_csv: Path
    assignments_json: Path
    photos_batch_csv: Path | None = None
    photo_root: Path | None = None
    include_file_status: bool = False

    def __post_init__(self) -> None:
        object.__setattr__(self, "photos_csv", Path(self.photos_csv))
        object.__setattr__(self, "assignments_json", Path(self.assignments_json))
        if self.photos_batch_csv is not None:
            object.__setattr__(self, "photos_batch_csv", Path(self.photos_batch_csv))
        if self.photo_root is not None:
            object.__setattr__(self, "photo_root", Path(self.photo_root))


@dataclass(frozen=True)
class AsrContextItem:
    evidence_id: str
    row_ref: int | None
    start_sec: float | None
    end_sec: float | None
    subject_numeros: tuple[int, ...]
    timecode: str = ""


@dataclass
class _AssignmentRecord:
    photo_id: str
    status: str
    subject_numero: int | None
    index: int
    source_field: str
    raw_status: str
    validation_status: str = "unknown"
    validation_reason: str = ""
    validation_record_id: str = ""


@dataclass(frozen=True)
class _AsrRecord:
    evidence_id: str
    row_ref: int | None
    start_sec: float
    end_sec: float
    subject_numeros: tuple[int, ...]
    timecode: str


def _canonical_bytes(value: Any) -> bytes:
    return json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")


def _sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _stable_id(prefix: str, value: Any) -> str:
    return f"{prefix}:{_sha256_bytes(_canonical_bytes(value))}"


def _text(value: Any) -> str:
    return "" if value is None else str(value).strip()


def _add_diagnostic(
    diagnostics: list[dict[str, Any]],
    code: str,
    message: str,
    *,
    severity: str = "warning",
    photo_id: str = "",
    source_file: str = "",
    row_ref: int | None = None,
    context_id: str = "",
) -> None:
    item: dict[str, Any] = {
        "code": code,
        "severity": severity,
        "message": message,
    }
    if photo_id:
        item["photo_id"] = photo_id
    if source_file:
        item["source_file"] = source_file
    if row_ref is not None:
        item["row_ref"] = row_ref
    if context_id:
        item["context_id"] = context_id
    diagnostics.append(item)


def _normalize_photo_id(value: Any) -> str:
    raw = unicodedata.normalize("NFC", _text(value)).replace("\\", "/")
    while raw.startswith("./"):
        raw = raw[2:]
    candidate = PurePosixPath(raw)
    if not raw or candidate.is_absolute() or raw.startswith("/"):
        raise ValueError("photo identifier must be relative")
    if re.match(r"^[A-Za-z]:", raw):
        raise ValueError("photo identifier must not be an absolute Windows path")
    parts = [part for part in candidate.parts if part not in ("", ".")]
    if not parts or any(part == ".." for part in parts):
        raise ValueError("photo identifier contains an invalid path component")
    return "/".join(parts)


def _coerce_numero(value: Any) -> int | None:
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value if value > 0 else None
    if isinstance(value, float):
        return int(value) if value.is_integer() and value > 0 else None
    match = re.fullmatch(
        r"\s*(?:(?:sujet|num[eé]ro|n[°o])\s*[:#-]?\s*)?(\d+)\s*",
        _text(value),
        flags=re.IGNORECASE,
    )
    if not match:
        return None
    numero = int(match.group(1))
    return numero if numero > 0 else None


def _parse_seconds(value: Any) -> float | None:
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        number = float(value)
        return number if math.isfinite(number) and number >= 0 else None
    raw = _text(value).replace(",", ".")
    if not raw:
        return None
    try:
        if ":" in raw:
            parts = raw.split(":")
            if len(parts) not in (2, 3):
                return None
            if len(parts) == 2:
                seconds = float(parts[0]) * 60.0 + float(parts[1])
            else:
                seconds = (
                    float(parts[0]) * 3600.0
                    + float(parts[1]) * 60.0
                    + float(parts[2])
                )
        else:
            seconds = float(raw)
    except ValueError:
        return None
    return seconds if math.isfinite(seconds) and seconds >= 0 else None


def _read_csv(path: Path, diagnostics: list[dict[str, Any]]) -> tuple[list[str], list[tuple[int, dict[str, str]]]]:
    if not path.is_file():
        raise PhotoContextResolverError(
            "source_missing", f"mandatory CSV source is missing: {path.name}"
        )
    try:
        with path.open("r", encoding="utf-8-sig", newline="") as stream:
            first_line = stream.readline()
            if not first_line:
                raise PhotoContextResolverError(
                    "invalid_csv_header", f"CSV source is empty: {path.name}"
                )
            delimiter = ";" if first_line.count(";") > first_line.count(",") else ","
            stream.seek(0)
            reader = csv.DictReader(stream, delimiter=delimiter, strict=True)
            raw_headers = list(reader.fieldnames or [])
            headers: list[str] = []
            seen: set[str] = set()
            for header in raw_headers:
                normalized = unicodedata.normalize("NFKC", _text(header)).casefold()
                if not normalized:
                    continue
                if normalized in seen:
                    _add_diagnostic(
                        diagnostics,
                        "duplicate_csv_header",
                        f"duplicate CSV header ignored: {normalized}",
                        source_file=path.name,
                    )
                    continue
                seen.add(normalized)
                headers.append(normalized)
            if not headers:
                raise PhotoContextResolverError(
                    "invalid_csv_header", f"CSV source has no usable header: {path.name}"
                )
            rows: list[tuple[int, dict[str, str]]] = []
            for raw_row in reader:
                if raw_row.get(None):
                    _add_diagnostic(
                        diagnostics,
                        "csv_row_extra_fields",
                        "CSV row has values beyond the declared header",
                        source_file=path.name,
                        row_ref=reader.line_num,
                    )
                row: dict[str, str] = {}
                for key, value in raw_row.items():
                    if key is None:
                        continue
                    normalized = unicodedata.normalize("NFKC", _text(key)).casefold()
                    if normalized and normalized not in row:
                        row[normalized] = _text(value)
                rows.append((reader.line_num, row))
            return headers, rows
    except PhotoContextResolverError:
        raise
    except (OSError, csv.Error) as exc:
        raise PhotoContextResolverError(
            "source_unreadable", f"cannot read CSV source {path.name}: {exc}"
        ) from exc


def _first_field(row: Mapping[str, str], names: Sequence[str]) -> tuple[str, str]:
    for name in names:
        if name in row:
            value = _text(row[name])
            if value:
                return name, value
    return "", ""


def _read_assignments(path: Path, diagnostics: list[dict[str, Any]]) -> list[_AssignmentRecord]:
    if not path.is_file():
        raise PhotoContextResolverError(
            "source_missing", f"assignment source is missing: {path.name}"
        )
    try:
        payload = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise PhotoContextResolverError(
            "invalid_assignments_json", f"cannot read {path.name}: {exc}"
        ) from exc
    if isinstance(payload, Mapping):
        raw_items = payload.get("assignments")
    else:
        raw_items = payload
    if not isinstance(raw_items, list):
        raise PhotoContextResolverError(
            "invalid_assignments_json",
            "assignment JSON must contain an assignments array",
        )
    records: list[_AssignmentRecord] = []
    for index, item in enumerate(raw_items):
        if not isinstance(item, Mapping):
            _add_diagnostic(
                diagnostics,
                "invalid_assignment_record",
                "assignment entry is not an object",
                source_file=path.name,
                context_id=f"assignment:{index}",
            )
            continue
        raw_photo = (
            item.get("photo_rel_native")
            or item.get("photo_id")
            or item.get("photo")
        )
        try:
            photo_id = _normalize_photo_id(raw_photo)
        except ValueError as exc:
            _add_diagnostic(
                diagnostics,
                "invalid_photo_id",
                f"assignment has no usable photo identifier: {exc}",
                source_file=path.name,
                context_id=f"assignment:{index}",
            )
            continue
        raw_status = _text(item.get("status") or item.get("statut")).casefold()
        status_map = {
            "affectee": "assigned",
            "affectée": "assigned",
            "assigned": "assigned",
            "exclue": "excluded",
            "excluded": "excluded",
            "non_affectee": "unassigned",
            "non affectée": "unassigned",
            "non-affectee": "unassigned",
            "unassigned": "unassigned",
        }
        status = status_map.get(raw_status, "")
        if not status:
            _add_diagnostic(
                diagnostics,
                "invalid_assignment_status",
                f"unsupported assignment status: {raw_status!r}",
                photo_id=photo_id,
                source_file=path.name,
                context_id=f"assignment:{index}",
            )
            continue
        raw_subject = item.get("subject_numero")
        if raw_subject is None:
            raw_subject = item.get("sujet")
        subject_numero = _coerce_numero(raw_subject)
        if status == "assigned" and subject_numero is None:
            _add_diagnostic(
                diagnostics,
                "assigned_photo_without_subject",
                "assigned photo has no positive subject number",
                photo_id=photo_id,
                source_file=path.name,
                context_id=f"assignment:{index}",
            )
            continue
        if status == "excluded" and subject_numero is not None:
            _add_diagnostic(
                diagnostics,
                "excluded_assignment_has_subject",
                "excluded photo also carries a subject; exclusion remains authoritative",
                photo_id=photo_id,
                source_file=path.name,
                context_id=f"assignment:{index}",
            )
        if status == "unassigned" and subject_numero is not None:
            _add_diagnostic(
                diagnostics,
                "unassigned_assignment_has_subject",
                "unassigned photo also carries a subject; subject is ignored",
                photo_id=photo_id,
                source_file=path.name,
                context_id=f"assignment:{index}",
            )
            subject_numero = None
        records.append(
            _AssignmentRecord(
                photo_id=photo_id,
                status=status,
                subject_numero=subject_numero if status == "assigned" else None,
                index=index,
                source_field=f"assignments/{index}/subject_numero",
                raw_status=raw_status,
            )
        )
    return records


_PHOTO_ID_FIELDS = ("photo_rel_native", "photo_id", "chemin_photo", "photo")
_PHOTO_DISPLAY_FIELDS = (
    "nom_fichier_image", "photo_fichier", "nom_fichier", "fichier", "photo_display",
)
_TIMESTAMP_FIELDS = (
    "horodatage_photo", "timestamp_hms", "horodatage", "heure_photo", "timestamp",
)
_T_AUDIO_FIELDS = ("t_audio", "t_audio_sec", "audio_t_sec", "timecode_audio_sec")


def _read_photo_rows(
    path: Path,
    diagnostics: list[dict[str, Any]],
    *,
    source_role: str,
) -> dict[str, dict[str, Any]]:
    headers, rows = _read_csv(path, diagnostics)
    if not any(name in headers for name in _PHOTO_ID_FIELDS):
        raise PhotoContextResolverError(
            "invalid_photos_csv_header",
            f"{path.name} has no supported photo identifier column",
        )
    result: dict[str, dict[str, Any]] = {}
    casefold_index: dict[str, str] = {}
    ambiguous: set[str] = set()
    for row_ref, row in rows:
        identity_field, raw_photo_id = _first_field(row, _PHOTO_ID_FIELDS)
        if not identity_field:
            _add_diagnostic(
                diagnostics,
                "photo_row_without_identifier",
                f"{source_role} row has no photo identifier",
                source_file=path.name,
                row_ref=row_ref,
            )
            continue
        try:
            photo_id = _normalize_photo_id(raw_photo_id)
        except ValueError as exc:
            _add_diagnostic(
                diagnostics,
                "invalid_photo_id",
                f"{source_role} row has an invalid photo identifier: {exc}",
                source_file=path.name,
                row_ref=row_ref,
            )
            continue
        folded = photo_id.casefold()
        previous = casefold_index.get(folded)
        if previous is not None:
            ambiguous.update((previous, photo_id))
            code = "duplicate_photo_row" if previous == photo_id else "case_ambiguous_photo_id"
            _add_diagnostic(
                diagnostics,
                code,
                f"{source_role} contains an ambiguous photo row",
                photo_id=photo_id,
                source_file=path.name,
                row_ref=row_ref,
            )
            continue
        display_field, display = _first_field(row, _PHOTO_DISPLAY_FIELDS)
        timestamp_field, timestamp = _first_field(row, _TIMESTAMP_FIELDS)
        audio_field, raw_audio = _first_field(row, _T_AUDIO_FIELDS)
        t_audio = _parse_seconds(raw_audio) if raw_audio else None
        if raw_audio and t_audio is None:
            _add_diagnostic(
                diagnostics,
                "invalid_t_audio",
                "t_audio is present but is not a non-negative numeric timecode",
                photo_id=photo_id,
                source_file=path.name,
                row_ref=row_ref,
            )
        result[photo_id] = {
            "photo_id": photo_id,
            "row": row,
            "row_ref": row_ref,
            "identity_field": identity_field,
            "display_field": display_field,
            "photo_display": display or Path(photo_id).name,
            "timestamp_field": timestamp_field,
            "timestamp_hms": timestamp,
            "audio_field": audio_field,
            "t_audio_raw": raw_audio,
            "t_audio": t_audio,
            "source_file": path.name,
            "source_role": source_role,
        }
        casefold_index[folded] = photo_id
    for photo_id in sorted(ambiguous):
        result.pop(photo_id, None)
    return result


def _resolve_assignments(
    records: Sequence[_AssignmentRecord],
    photos: Mapping[str, dict[str, Any]],
    diagnostics: list[dict[str, Any]],
    assignment_source: str,
) -> dict[str, _AssignmentRecord]:
    grouped: dict[str, list[_AssignmentRecord]] = {}
    for record in records:
        grouped.setdefault(record.photo_id, []).append(record)
    resolved: dict[str, _AssignmentRecord] = {}
    folded_photo_ids = {photo_id.casefold(): photo_id for photo_id in photos}
    for photo_id, items in grouped.items():
        if photo_id not in photos:
            folded_match = folded_photo_ids.get(photo_id.casefold())
            if folded_match is not None:
                _add_diagnostic(
                    diagnostics,
                    "case_equivalent_photo_reference",
                    "assignment photo path differs only by case; it is not merged silently",
                    photo_id=photo_id,
                    source_file=assignment_source,
                    context_id=folded_match,
                    severity="error",
                )
                continue
            _add_diagnostic(
                diagnostics,
                "assignment_without_photo",
                "human assignment references a photo absent from the selected photos.csv",
                photo_id=photo_id,
                source_file=assignment_source,
            )
            continue
        if len(items) > 1:
            signatures = {(item.status, item.subject_numero) for item in items}
            code = "conflicting_assignment" if len(signatures) > 1 else "duplicate_assignment"
            _add_diagnostic(
                diagnostics,
                code,
                "multiple human assignments exist for this photo; no value is selected",
                photo_id=photo_id,
                source_file=assignment_source,
                severity="error",
            )
            continue
        resolved[photo_id] = items[0]
    for photo_id in sorted(photos):
        if photo_id not in grouped:
            _add_diagnostic(
                diagnostics,
                "photo_without_assignment",
                "photo has no human assignment record; it is not published",
                photo_id=photo_id,
                source_file=assignment_source,
                severity="error",
            )
    return resolved


def _read_batch_rows(
    selection: SourceSelection,
    primary: Mapping[str, dict[str, Any]],
    diagnostics: list[dict[str, Any]],
) -> dict[str, dict[str, Any]]:
    if selection.photos_batch_csv is None:
        return {}
    if not selection.photos_batch_csv.is_file():
        _add_diagnostic(
            diagnostics,
            "batch_source_missing",
            "explicitly selected photos_batch.csv is missing",
            source_file=selection.photos_batch_csv.name,
        )
        return {}
    batch = _read_photo_rows(
        selection.photos_batch_csv, diagnostics, source_role="batch"
    )
    for photo_id in sorted(set(batch) - set(primary)):
        folded_match = next(
            (key for key in primary if key.casefold() == photo_id.casefold()),
            "",
        )
        if folded_match:
            _add_diagnostic(
                diagnostics,
                "case_equivalent_batch_reference",
                "batch photo path differs only by case from photos.csv; it is not merged silently",
                photo_id=photo_id,
                source_file=selection.photos_batch_csv.name,
                context_id=folded_match,
                severity="error",
            )
            batch.pop(photo_id, None)
            continue
        _add_diagnostic(
            diagnostics,
            "batch_photo_not_in_primary",
            "batch-only photo is not added because photos.csv is authoritative",
            photo_id=photo_id,
            source_file=selection.photos_batch_csv.name,
        )
        batch.pop(photo_id, None)
    for photo_id in sorted(set(batch) & set(primary)):
        _diagnose_batch_divergences(
            photo_id,
            primary[photo_id],
            batch[photo_id],
            selection.photos_batch_csv.name,
            diagnostics,
        )
    return batch


def _normalized_comparison(value: Any) -> str:
    return " ".join(unicodedata.normalize("NFC", _text(value)).split())


def _diagnose_batch_divergences(
    photo_id: str,
    primary: Mapping[str, Any],
    batch: Mapping[str, Any],
    batch_source: str,
    diagnostics: list[dict[str, Any]],
) -> None:
    primary_row = primary["row"]
    batch_row = batch["row"]
    for primary_field, batch_field, logical_field in _CONTENT_SOURCE_PAIRS:
        primary_value = _normalized_comparison(primary_row.get(primary_field))
        batch_value = _normalized_comparison(batch_row.get(batch_field))
        if primary_value and batch_value and primary_value != batch_value:
            _add_diagnostic(
                diagnostics,
                "batch_content_divergence",
                "photos.csv and photos_batch.csv carry different non-empty values; both are retained with provenance",
                photo_id=photo_id,
                source_file=batch_source,
                context_id=logical_field,
            )
        elif batch_value and not primary_value:
            _add_diagnostic(
                diagnostics,
                "batch_content_supplement",
                "photos_batch.csv supplies content absent from photos.csv",
                photo_id=photo_id,
                source_file=batch_source,
                context_id=logical_field,
                severity="info",
            )
    if (
        primary.get("photo_display")
        and batch.get("photo_display")
        and primary.get("photo_display") != batch.get("photo_display")
    ):
        _add_diagnostic(
            diagnostics,
            "batch_metadata_divergence",
            "photo display name differs between photos.csv and photos_batch.csv",
            photo_id=photo_id,
            source_file=batch_source,
            context_id="photo_display",
        )
    if (
        primary.get("timestamp_hms")
        and batch.get("timestamp_hms")
        and primary.get("timestamp_hms") != batch.get("timestamp_hms")
    ):
        _add_diagnostic(
            diagnostics,
            "batch_metadata_divergence",
            "photo timestamp differs between photos.csv and photos_batch.csv",
            photo_id=photo_id,
            source_file=batch_source,
            context_id="timestamp_hms",
        )
    primary_audio = primary.get("t_audio")
    batch_audio = batch.get("t_audio")
    if (
        primary_audio is not None
        and batch_audio is not None
        and abs(float(primary_audio) - float(batch_audio)) > 0.000001
    ):
        _add_diagnostic(
            diagnostics,
            "batch_metadata_divergence",
            "t_audio differs between photos.csv and photos_batch.csv; photos.csv remains authoritative",
            photo_id=photo_id,
            source_file=batch_source,
            context_id="t_audio",
        )


def _coerce_asr_item(
    item: AsrContextItem | Mapping[str, Any],
    index: int,
    diagnostics: list[dict[str, Any]],
) -> _AsrRecord | None:
    if isinstance(item, AsrContextItem):
        evidence_id = _text(item.evidence_id)
        row_ref = item.row_ref
        raw_start = item.start_sec
        raw_end = item.end_sec
        raw_subjects = item.subject_numeros
        timecode = _text(item.timecode)
    elif isinstance(item, Mapping):
        evidence_id = _text(item.get("evidence_id"))
        row_ref_raw = item.get("row_ref")
        row_ref = row_ref_raw if isinstance(row_ref_raw, int) else None
        raw_start = item.get("start_sec")
        raw_end = item.get("end_sec")
        raw_subjects = item.get("subject_numeros", ())
        timecode = _text(item.get("timecode"))
    else:
        _add_diagnostic(
            diagnostics,
            "invalid_asr_item",
            "ASR context entry is neither AsrContextItem nor an object",
            context_id=f"asr:{index}",
        )
        return None
    if not EVIDENCE_ID_RE.fullmatch(evidence_id):
        _add_diagnostic(
            diagnostics,
            "invalid_asr_evidence_id",
            "ASR context has no conforming evidence occurrence identifier",
            context_id=evidence_id or f"asr:{index}",
            severity="error",
        )
        return None
    start_sec = _parse_seconds(raw_start)
    end_sec = _parse_seconds(raw_end)
    if start_sec is None and end_sec is None:
        _add_diagnostic(
            diagnostics,
            "invalid_asr_window",
            "ASR context has no usable time window",
            context_id=evidence_id,
        )
        return None
    if start_sec is None:
        start_sec = end_sec
    if end_sec is None:
        end_sec = start_sec
    assert start_sec is not None and end_sec is not None
    if start_sec > end_sec:
        _add_diagnostic(
            diagnostics,
            "invalid_asr_window",
            "ASR context start is after its end",
            context_id=evidence_id,
        )
        return None
    if isinstance(raw_subjects, (str, bytes)) or not isinstance(raw_subjects, Iterable):
        raw_subjects = (raw_subjects,)
    numeros: list[int] = []
    for raw_subject in raw_subjects:
        numero = _coerce_numero(raw_subject)
        if numero is None:
            _add_diagnostic(
                diagnostics,
                "invalid_asr_subject",
                "ASR context contains an invalid subject number",
                context_id=evidence_id,
            )
            return None
        numeros.append(numero)
    if not numeros:
        _add_diagnostic(
            diagnostics,
            "asr_item_without_subject",
            "ASR context without a real subject number is ignored",
            context_id=evidence_id,
            severity="error",
        )
        return None
    return _AsrRecord(
        evidence_id=evidence_id,
        row_ref=row_ref,
        start_sec=float(start_sec),
        end_sec=float(end_sec),
        subject_numeros=tuple(sorted(set(numeros))),
        timecode=timecode,
    )


def _read_asr_context(
    items: Iterable[AsrContextItem | Mapping[str, Any]],
    diagnostics: list[dict[str, Any]],
) -> tuple[_AsrRecord, ...]:
    by_id: dict[str, _AsrRecord] = {}
    conflicting: set[str] = set()
    for index, item in enumerate(items):
        parsed = _coerce_asr_item(item, index, diagnostics)
        if parsed is None or parsed.evidence_id in conflicting:
            continue
        previous = by_id.get(parsed.evidence_id)
        if previous is None:
            by_id[parsed.evidence_id] = parsed
            continue
        if previous == parsed:
            continue
        conflicting.add(parsed.evidence_id)
        by_id.pop(parsed.evidence_id, None)
        _add_diagnostic(
            diagnostics,
            "conflicting_asr_context_item",
            "same ASR evidence identifier has conflicting windows or subjects",
            context_id=parsed.evidence_id,
            severity="error",
        )
    return tuple(by_id[key] for key in sorted(by_id))


def _asr_context_for_photo(
    photo: Mapping[str, Any],
    asr_items: Sequence[_AsrRecord],
    window_seconds: float,
    diagnostics: list[dict[str, Any]],
) -> dict[str, Any]:
    t_audio = photo.get("t_audio")
    photo_id = str(photo["photo_id"])
    source_file = str(photo["source_file"])
    if t_audio is None:
        if photo.get("t_audio_raw"):
            _add_diagnostic(
                diagnostics,
                "photo_without_usable_t_audio",
                "photo has no usable numeric t_audio; no ASR proximity is inferred",
                photo_id=photo_id,
                source_file=source_file,
                row_ref=photo.get("row_ref"),
            )
        return {
            "evidence_occurrence_ids": [],
            "asr_subject_numeros": [],
            "link_status": "unresolved",
            "method": "photo_time_window",
            "rule_id": f"photo-time-window-{window_seconds:g}s",
            "window_start_sec": None,
            "window_end_sec": None,
        }
    point = float(t_audio)
    window_start = point - window_seconds
    window_end = point + window_seconds
    matches: list[tuple[_AsrRecord, float]] = []
    for item in asr_items:
        if item.end_sec < window_start or item.start_sec > window_end:
            continue
        if item.start_sec <= point <= item.end_sec:
            score = 1.0
        else:
            distance = (
                point - item.end_sec
                if item.end_sec < point
                else item.start_sec - point
            )
            score = max(0.0, min(1.0, 1.0 - (max(0.0, distance) / max(window_seconds, 0.001))))
        matches.append((item, round(score, 6)))
    evidence_ids = sorted({item.evidence_id for item, _score in matches})
    subjects = sorted({
        numero for item, _score in matches for numero in item.subject_numeros
    })
    if not matches:
        return {
            "evidence_occurrence_ids": [],
            "asr_subject_numeros": [],
            "link_status": "unresolved",
            "method": "photo_time_window",
            "rule_id": f"photo-time-window-{window_seconds:g}s",
            "window_start_sec": round(window_start, 6),
            "window_end_sec": round(window_end, 6),
        }
    return {
        "evidence_occurrence_ids": evidence_ids,
        "asr_subject_numeros": subjects,
        "link_status": "candidate",
        "method": "photo_time_window",
        "score": max(score for _item, score in matches),
        "rule_id": f"photo-time-window-{window_seconds:g}s",
        "window_start_sec": round(window_start, 6),
        "window_end_sec": round(window_end, 6),
    }


def _validation_match(
    records: Sequence[Mapping[str, Any]],
    used: set[int],
    diagnostics: list[dict[str, Any]],
    *,
    photo_id: str,
    record_types: set[str],
    default_status: str,
    content_kind: str = "",
    source_field: str = "",
    subject_numero: int | None = None,
    source_file: str = "",
    origin: str = "",
    require_source_field: bool = False,
) -> dict[str, str]:
    matches: list[tuple[int, str, str, str]] = []
    for index, record in enumerate(records):
        if index in used or not isinstance(record, Mapping):
            continue
        try:
            record_photo_id = _normalize_photo_id(
                record.get("photo_rel_native") or record.get("photo_id") or record.get("photo")
            )
        except ValueError:
            continue
        if record_photo_id != photo_id:
            continue
        record_type = _text(record.get("record_type") or record.get("type")).casefold()
        if not record_type:
            record_type = "component" if content_kind else "assignment"
        if record_type not in record_types:
            continue
        if content_kind and _text(record.get("content_kind")) not in ("", content_kind):
            continue
        record_source_field = _text(record.get("source_field") or record.get("field"))
        if require_source_field and not record_source_field:
            _add_diagnostic(
                diagnostics,
                "ambiguous_validation_record",
                "component validation record needs an explicit source_field",
                photo_id=photo_id,
                context_id=_text(record.get("validation_record_id") or record.get("record_id")),
                severity="error",
            )
            used.add(index)
            continue
        if record_source_field and record_source_field != source_field:
            continue
        record_source_file = _text(record.get("source_file"))
        if record_source_file and record_source_file != source_file:
            continue
        record_origin = _text(record.get("origin")).casefold()
        if record_origin and record_origin != origin:
            continue
        record_subject = _coerce_numero(record.get("subject_numero"))
        if record_subject is not None and subject_numero is not None and record_subject != subject_numero:
            continue
        status = _text(record.get("validation_status") or record.get("status")).casefold()
        if status not in {"validated", "unvalidated", "unknown"}:
            _add_diagnostic(
                diagnostics,
                "invalid_validation_record",
                "validation record has an unsupported validation status",
                photo_id=photo_id,
                context_id=_text(record.get("validation_record_id") or record.get("record_id")),
            )
            used.add(index)
            continue
        reason = _text(record.get("validation_reason") or record.get("reason"))
        record_id = _text(
            record.get("validation_record_id")
            or record.get("record_id")
            or record.get("evidence_id")
        )
        matches.append((index, status, reason, record_id))
    if not matches:
        return {
            "validation_status": default_status,
            "validation_reason": "",
            "validation_record_id": "",
        }
    statuses = {status for _index, status, _reason, _record_id in matches}
    for index, _status, _reason, _record_id in matches:
        used.add(index)
    if len(statuses) > 1:
        _add_diagnostic(
            diagnostics,
            "conflicting_validation_records",
            "multiple validation records disagree; the default status is retained",
            photo_id=photo_id,
            source_field=source_field,
            severity="error",
        )
        return {
            "validation_status": default_status,
            "validation_reason": "",
            "validation_record_id": "",
        }
    _index, status, reason, record_id = matches[0]
    return {
        "validation_status": status,
        "validation_reason": reason,
        "validation_record_id": record_id,
    }


def _component_record(
    *,
    photo_id: str,
    content_kind: str,
    text: str,
    source_file: str,
    source_field: str,
    origin: str,
    default_validation_status: str,
    default_reason: str,
    locator: str,
    validation: Mapping[str, str],
    parent_component_ids: Sequence[str] = (),
) -> dict[str, Any]:
    identity = {
        "photo_id": photo_id,
        "content_kind": content_kind,
        "source_file": source_file,
        "source_field": source_field,
        "origin": origin,
        "text": text,
        "locator": locator,
        "parent_component_ids": sorted(set(parent_component_ids)),
    }
    status = validation.get("validation_status") or default_validation_status
    reason = validation.get("validation_reason") or default_reason
    component: dict[str, Any] = {
        "component_id": _stable_id("photo-component", identity),
        "photo_id": photo_id,
        "content_kind": content_kind,
        "text": text,
        "source_file": source_file,
        "source_field": source_field,
        "origin": origin,
        "validation_status": status,
        "provenance_fingerprint": _sha256_bytes(_canonical_bytes(identity)),
    }
    if reason:
        component["validation_reason"] = reason
    if parent_component_ids:
        component["parent_component_ids"] = sorted(set(parent_component_ids))
    return component


def _build_content_components(
    photo: Mapping[str, Any],
    batch_row: Mapping[str, Any] | None,
    assignment: _AssignmentRecord,
    assignment_source: str,
    validation_records: Sequence[Mapping[str, Any]],
    used_validations: set[int],
    diagnostics: list[dict[str, Any]],
) -> tuple[list[dict[str, Any]], dict[str, str]]:
    photo_id = str(photo["photo_id"])
    components: list[dict[str, Any]] = []
    component_ids: set[str] = set()

    assignment_validation = _validation_match(
        validation_records,
        used_validations,
        diagnostics,
        photo_id=photo_id,
        record_types=_ASSIGNMENT_TYPES,
        default_status="unknown",
        source_field=assignment.source_field,
        subject_numero=assignment.subject_numero,
        source_file=Path(assignment_source).name,
        origin="ui",
    )
    assignment_text = (
        str(assignment.subject_numero)
        if assignment.status == "assigned"
        else ("exclue" if assignment.status == "excluded" else "non_affectee")
    )
    assignment_component = _component_record(
        photo_id=photo_id,
        content_kind="human_assignment",
        text=assignment_text,
        source_file=Path(assignment_source).name,
        source_field=assignment.source_field,
        origin="ui",
        default_validation_status="unknown",
        default_reason="affectation enregistree via UI; validation humaine par champ non demontree",
        locator=f"assignment:{assignment.index}",
        validation=assignment_validation,
    )
    components.append(assignment_component)
    component_ids.add(assignment_component["component_id"])

    def append_component(
        content_kind: str,
        text: str,
        source_file: str,
        source_field: str,
        origin: str,
        default_status: str,
        default_reason: str,
        locator: str,
    ) -> None:
        if not text:
            return
        validation = _validation_match(
            validation_records,
            used_validations,
            diagnostics,
            photo_id=photo_id,
            record_types=_COMPONENT_TYPES,
            default_status=default_status,
            content_kind=content_kind,
            source_field=source_field,
            subject_numero=assignment.subject_numero,
            source_file=Path(source_file).name,
            origin=origin,
            require_source_field=True,
        )
        component = _component_record(
            photo_id=photo_id,
            content_kind=content_kind,
            text=text,
            source_file=Path(source_file).name,
            source_field=source_field,
            origin=origin,
            default_validation_status=default_status,
            default_reason=default_reason,
            locator=locator,
            validation=validation,
        )
        if component["component_id"] not in component_ids:
            components.append(component)
            component_ids.add(component["component_id"])

    primary_row = photo["row"]
    primary_source = str(photo["source_file"])
    primary_row_ref = int(photo["row_ref"])
    factual_fields = (
        (_PHOTO_DISPLAY_FIELDS, "photo_display", "nom du fichier image"),
        (_TIMESTAMP_FIELDS, "timestamp_hms", "horodatage photographique"),
        (_T_AUDIO_FIELDS, "t_audio_raw", "position audio de la photographie"),
    )
    for aliases, value_key, _label in factual_fields:
        field, _value = _first_field(primary_row, aliases)
        value = _text(photo.get(value_key))
        if field and value:
            append_component(
                "factual_metadata",
                value,
                primary_source,
                field,
                "source",
                "unknown",
                "metadonnee factuelle issue de la source; validation humaine non applicable",
                f"row:{primary_row_ref}:field:{field}",
            )

    for field, content_kind, origin, default_status, reason in _COMPONENT_SPECS:
        if field.endswith("_batch"):
            continue
        value = _text(primary_row.get(field))
        if value:
            append_component(
                content_kind,
                value,
                primary_source,
                field,
                origin,
                default_status,
                reason,
                f"row:{primary_row_ref}:field:{field}",
            )

    if batch_row is not None:
        batch_source = str(batch_row["source_file"])
        batch_row_ref = int(batch_row["row_ref"])
        for field, content_kind, origin, default_status, reason in _COMPONENT_SPECS:
            if not field.endswith("_batch"):
                continue
            value = _text(batch_row["row"].get(field))
            if value:
                append_component(
                    content_kind,
                    value,
                    batch_source,
                    field,
                    origin,
                    default_status,
                    reason,
                    f"row:{batch_row_ref}:field:{field}",
                )

    return components, assignment_validation


def _file_status(
    selection: SourceSelection,
    photo_id: str,
    diagnostics: list[dict[str, Any]],
) -> dict[str, Any]:
    if selection.photo_root is None:
        _add_diagnostic(
            diagnostics,
            "photo_root_missing",
            "file status was requested without an explicit photo_root",
            photo_id=photo_id,
        )
        return {"exists": False, "metadata_status": "unknown"}
    root = selection.photo_root.resolve()
    path = selection.photo_root.joinpath(*PurePosixPath(photo_id).parts).resolve()
    try:
        path.relative_to(root)
    except ValueError:
        _add_diagnostic(
            diagnostics,
            "photo_path_outside_root",
            "resolved photo path escapes the explicit photo_root",
            photo_id=photo_id,
            severity="error",
        )
        return {"exists": False, "metadata_status": "unknown"}
    if not path.is_file():
        _add_diagnostic(
            diagnostics,
            "photo_file_missing",
            "photo file referenced by photos.csv does not exist under photo_root",
            photo_id=photo_id,
        )
        return {"exists": False, "metadata_status": "unknown"}
    suffix = path.suffix.casefold()
    mime_type = {
        ".jpg": "image/jpeg",
        ".jpeg": "image/jpeg",
        ".png": "image/png",
        ".tif": "image/tiff",
        ".tiff": "image/tiff",
    }.get(suffix, "application/octet-stream")
    return {
        "exists": True,
        "metadata_status": "complete",
        "sha256": _sha256_file(path),
        "size_bytes": path.stat().st_size,
        "mime_type": mime_type,
    }


def _source_hashes(
    selection: SourceSelection,
    diagnostics: list[dict[str, Any]],
    provided: Mapping[str, str] | None,
) -> dict[str, str]:
    hashes: dict[str, str] = {}
    sources = [selection.photos_csv, selection.assignments_json]
    if selection.photos_batch_csv is not None and selection.photos_batch_csv.is_file():
        sources.append(selection.photos_batch_csv)
    for path in sources:
        if path.is_file():
            hashes[path.name] = _sha256_file(path)
    if provided is None:
        return hashes
    for raw_key, raw_hash in provided.items():
        key = _text(raw_key)
        digest = _text(raw_hash).casefold()
        if not key or not SHA256_RE.fullmatch(digest):
            _add_diagnostic(
                diagnostics,
                "invalid_source_hash",
                "provided source hash is not a lowercase SHA-256 value",
                context_id=key,
            )
            continue
        if "/" in key or "\\" in key or ":" in key:
            _add_diagnostic(
                diagnostics,
                "source_hash_key_not_logical",
                "source hash keys must be logical file names, not physical paths",
                context_id=key,
                severity="error",
            )
            continue
        if key in hashes and hashes[key] != digest:
            _add_diagnostic(
                diagnostics,
                "source_hash_mismatch",
                "provided source hash differs from the selected file",
                source_file=key,
                severity="error",
            )
            continue
        hashes[key] = digest
    return hashes


def _assignment_public_record(
    assignment: _AssignmentRecord,
    assignment_source: str,
    validation: Mapping[str, str],
) -> dict[str, Any]:
    identity = {
        "photo_id": assignment.photo_id,
        "status": assignment.status,
        "subject_numero": assignment.subject_numero,
        "source_file": Path(assignment_source).name,
        "source_field": assignment.source_field,
        "index": assignment.index,
    }
    record: dict[str, Any] = {
        "assignment_id": _stable_id("photo-assignment", identity),
        "status": assignment.status,
        "authority": "human",
        "record_origin": "ui",
        "validation_status": validation.get("validation_status") or "unknown",
        "source_file": Path(assignment_source).name,
        "source_field": assignment.source_field,
    }
    record_id = validation.get("validation_record_id")
    if record_id:
        record["validation_record_id"] = record_id
    return record


def resolve_photo_context(
    selection: SourceSelection,
    *,
    editorial_subject_numero: int | None = None,
    asr_context: Iterable[AsrContextItem | Mapping[str, Any]] = (),
    validation_records: Iterable[Mapping[str, Any]] = (),
    source_hashes: Mapping[str, str] | None = None,
    asr_window_seconds: float = 30.0,
) -> dict[str, Any]:
    """Resolve photo context from explicitly selected, read-only sources.

    A temporal ASR match remains a candidate. It never creates or changes the
    human photo assignment.
    """

    if asr_window_seconds < 0 or not math.isfinite(asr_window_seconds):
        raise PhotoContextResolverError(
            "invalid_asr_window", "asr_window_seconds must be finite and non-negative"
        )
    if editorial_subject_numero is not None:
        editorial_subject_numero = _coerce_numero(editorial_subject_numero)
        if editorial_subject_numero is None:
            raise PhotoContextResolverError(
                "invalid_editorial_subject", "editorial subject must be a positive integer"
            )
    diagnostics: list[dict[str, Any]] = []
    source_hash_map = _source_hashes(selection, diagnostics, source_hashes)
    photos = _read_photo_rows(selection.photos_csv, diagnostics, source_role="primary")
    batch_rows = _read_batch_rows(selection, photos, diagnostics)
    assignment_records = _read_assignments(selection.assignments_json, diagnostics)
    assignments = _resolve_assignments(
        assignment_records,
        photos,
        diagnostics,
        selection.assignments_json.name,
    )
    asr_items = _read_asr_context(asr_context, diagnostics)
    validation_list: list[Mapping[str, Any]] = []
    for index, record in enumerate(validation_records):
        if not isinstance(record, Mapping):
            _add_diagnostic(
                diagnostics,
                "invalid_validation_record",
                "validation record is not an object",
                context_id=f"validation:{index}",
            )
            continue
        validation_list.append(record)
    used_validations: set[int] = set()
    photo_records: list[dict[str, Any]] = []
    exclusions: list[dict[str, Any]] = []

    for photo_id in sorted(assignments):
        photo = photos[photo_id]
        assignment = assignments[photo_id]
        components, assignment_validation = _build_content_components(
            photo,
            batch_rows.get(photo_id),
            assignment,
            selection.assignments_json.name,
            validation_list,
            used_validations,
            diagnostics,
        )
        asr_item = _asr_context_for_photo(
            photo, asr_items, float(asr_window_seconds), diagnostics
        )
        subject_scope = {
            "photo_subject_numero": (
                assignment.subject_numero if assignment.status == "assigned" else None
            ),
            "asr_subject_numeros": list(asr_item["asr_subject_numeros"]),
            "editorial_subject_numero": editorial_subject_numero,
        }
        record: dict[str, Any] = {
            "photo_id": photo_id,
            "photo_rel_native": photo_id,
            "photo_display": photo["photo_display"],
            "timestamp_hms": photo["timestamp_hms"],
            "chrono_sec": photo["t_audio"],
            "subject_scope": subject_scope,
            "assignment": _assignment_public_record(
                assignment,
                selection.assignments_json.name,
                assignment_validation,
            ),
            "content_components": sorted(
                components, key=lambda item: item["component_id"]
            ),
            "asr_context": asr_item,
        }
        if selection.include_file_status:
            file_status = _file_status(selection, photo_id, diagnostics)
            record["file_status"] = file_status
            if file_status.get("sha256"):
                record["photo_sha256"] = file_status["sha256"]
        photo_records.append(record)

        if assignment.status == "excluded":
            exclusion_validation = _validation_match(
                validation_list,
                used_validations,
                diagnostics,
                photo_id=photo_id,
                record_types=_EXCLUSION_TYPES,
                default_status="unknown",
                source_field=assignment.source_field,
                source_file=selection.assignments_json.name,
                origin="ui",
            )
            exclusion_identity = {
                "photo_id": photo_id,
                "reason_code": "human_exclusion",
                "source_file": selection.assignments_json.name,
                "source_field": assignment.source_field,
                "index": assignment.index,
            }
            exclusion: dict[str, Any] = {
                "exclusion_id": _stable_id("photo-exclusion", exclusion_identity),
                "photo_id": photo_id,
                "reason_code": "human_exclusion",
                "reason_text": assignment.raw_status or "exclue",
                "source_file": selection.assignments_json.name,
                "source_field": assignment.source_field,
                "validation_status": exclusion_validation.get("validation_status") or "unknown",
                "provenance_fingerprint": _sha256_bytes(_canonical_bytes(exclusion_identity)),
            }
            exclusions.append(exclusion)

    for index, _record in enumerate(validation_list):
        if index not in used_validations:
            _add_diagnostic(
                diagnostics,
                "unmatched_validation_record",
                "validation record did not match a published photo field",
                context_id=_text(
                    _record.get("validation_record_id")
                    or _record.get("record_id")
                    or f"validation:{index}"
                ),
            )

    current_hashes = _source_hashes(selection, [], None)
    selected_names = {selection.photos_csv.name, selection.assignments_json.name}
    if selection.photos_batch_csv is not None:
        selected_names.add(selection.photos_batch_csv.name)
    if any(
        current_hashes.get(name) != source_hash_map.get(name)
        for name in selected_names
    ):
        raise PhotoContextResolverError(
            "source_changed_during_resolution",
            "a selected source changed while photo context was being resolved",
        )

    diagnostics.sort(
        key=lambda item: (
            str(item.get("code", "")),
            str(item.get("photo_id", "")),
            int(item.get("row_ref") or 0),
            str(item.get("context_id", "")),
        )
    )
    counts = {
        "photo_record_count": len(photo_records),
        "assigned_photo_count": sum(
            1 for item in photo_records if item["assignment"]["status"] == "assigned"
        ),
        "excluded_photo_count": len(exclusions),
        "unassigned_photo_count": sum(
            1 for item in photo_records if item["assignment"]["status"] == "unassigned"
        ),
        "photo_with_asr_candidate_count": sum(
            1 for item in photo_records if item["asr_context"]["link_status"] == "candidate"
        ),
    }
    return {
        "format": BUNDLE_FORMAT,
        "selection": {
            "photos_source": selection.photos_csv.name,
            "assignment_source": selection.assignments_json.name,
            "batch_source": (
                selection.photos_batch_csv.name
                if selection.photos_batch_csv is not None
                else ""
            ),
            "file_status_requested": selection.include_file_status,
            "asr_window_seconds": float(asr_window_seconds),
        },
        "photos": photo_records,
        "photo_exclusions": sorted(exclusions, key=lambda item: item["exclusion_id"]),
        "source_hashes": source_hash_map,
        "diagnostics": diagnostics,
        "counts": counts,
    }


def build_context_snapshot(
    bundle: dict,
    *,
    pipeline_kind: str,
    subject_scope: dict,
    selection_rule_ids: Iterable[str] = (),
    prompt_artifact: str = "",
    prompt_sha256: str = "",
    system_text_sha256: str = "",
    user_text_sha256: str = "",
    created_at: str | None = None,
) -> dict:
    """Build a reference-only, reproducible snapshot of an LLM photo context."""

    if pipeline_kind not in {"generaliste", "refere"}:
        raise PhotoContextResolverError(
            "invalid_pipeline_kind", "pipeline_kind must be generaliste or refere"
        )
    contract_errors = validate_photo_context_bundle(bundle)
    if contract_errors:
        codes = ", ".join(item["code"] for item in contract_errors[:5])
        raise PhotoContextResolverError(
            "invalid_photo_context_bundle",
            f"cannot snapshot an invalid bundle: {codes}",
        )
    if not isinstance(subject_scope, Mapping):
        raise PhotoContextResolverError(
            "invalid_subject_scope", "subject_scope must be an object"
        )
    photo_subject = subject_scope.get("photo_subject_numero")
    editorial_subject = subject_scope.get("editorial_subject_numero")
    if photo_subject is not None and _coerce_numero(photo_subject) is None:
        raise PhotoContextResolverError(
            "invalid_subject_scope", "photo_subject_numero must be a positive integer or null"
        )
    if editorial_subject is not None and _coerce_numero(editorial_subject) is None:
        raise PhotoContextResolverError(
            "invalid_subject_scope", "editorial_subject_numero must be a positive integer or null"
        )
    raw_asr_subjects = subject_scope.get("asr_subject_numeros", [])
    if not isinstance(raw_asr_subjects, Sequence) or isinstance(raw_asr_subjects, (str, bytes)):
        raise PhotoContextResolverError(
            "invalid_subject_scope", "asr_subject_numeros must be an array"
        )
    normalized_asr_subjects: list[int] = []
    for value in raw_asr_subjects:
        numero = _coerce_numero(value)
        if numero is None:
            raise PhotoContextResolverError(
                "invalid_subject_scope", "asr_subject_numeros contains an invalid number"
            )
        normalized_asr_subjects.append(numero)
    normalized_scope = {
        "photo_subject_numero": _coerce_numero(photo_subject),
        "asr_subject_numeros": sorted(set(normalized_asr_subjects)),
        "editorial_subject_numero": _coerce_numero(editorial_subject),
    }

    photos_by_id = {str(item["photo_id"]): item for item in bundle.get("photos", [])}
    excluded_photo_ids = {
        str(item["photo_id"])
        for item in bundle.get("photo_exclusions", [])
        if isinstance(item, Mapping)
    }
    included: list[dict[str, Any]] = []
    if normalized_scope["photo_subject_numero"] is not None:
        included = [
            item
            for photo_id, item in sorted(photos_by_id.items())
            if photo_id not in excluded_photo_ids
            and item.get("assignment", {}).get("status") == "assigned"
            and item.get("subject_scope", {}).get("photo_subject_numero")
            == normalized_scope["photo_subject_numero"]
        ]
    included_photo_ids = sorted(str(item["photo_id"]) for item in included)
    included_set = set(included_photo_ids)

    exclusion_ids: list[str] = []
    if normalized_scope["editorial_subject_numero"] is not None:
        for exclusion in bundle.get("photo_exclusions", []):
            if not isinstance(exclusion, Mapping):
                continue
            photo = photos_by_id.get(str(exclusion.get("photo_id")))
            if not photo:
                continue
            photo_scope = photo.get("subject_scope") or {}
            if (
                photo_scope.get("editorial_subject_numero")
                == normalized_scope["editorial_subject_numero"]
                and str(exclusion["photo_id"]) not in included_set
            ):
                exclusion_ids.append(str(exclusion["exclusion_id"]))

    evidence_ids = sorted({
        str(evidence_id)
        for photo in included
        for evidence_id in (photo.get("asr_context") or {}).get(
            "evidence_occurrence_ids", []
        )
    })
    included_asr_subjects = sorted({
        int(numero)
        for photo in included
        for numero in (photo.get("subject_scope") or {}).get(
            "asr_subject_numeros", []
        )
    })
    if normalized_scope["asr_subject_numeros"] != included_asr_subjects:
        raise PhotoContextResolverError(
            "subject_scope_mismatch",
            "snapshot ASR subjects must equal the union of included photo ASR subjects",
        )
    component_ids = sorted({
        str(component["component_id"])
        for photo in included
        for component in photo.get("content_components", [])
    })
    rule_ids = sorted(
        set(_DEFAULT_SELECTION_RULES)
        | {_text(item) for item in selection_rule_ids if _text(item)}
    )
    hashes: dict[str, str] = {}
    for key, value in (bundle.get("source_hashes") or {}).items():
        digest = _text(value).casefold()
        if SHA256_RE.fullmatch(digest):
            hashes[_text(key)] = digest
    body: dict[str, Any] = {
        "pipeline_kind": pipeline_kind,
        "subject_scope": normalized_scope,
        "included_photo_ids": included_photo_ids,
        "photo_exclusion_ids": sorted(set(exclusion_ids)),
        "evidence_occurrence_ids": evidence_ids,
        "component_ids": component_ids,
        "selection_rule_ids": rule_ids,
        "source_hashes": dict(sorted(hashes.items())),
        "text_copy_embedded": False,
    }
    if prompt_artifact:
        body["prompt_artifact"] = prompt_artifact
    if prompt_sha256:
        body["prompt_sha256"] = prompt_sha256
    if system_text_sha256:
        body["system_text_sha256"] = system_text_sha256
    if user_text_sha256:
        body["user_text_sha256"] = user_text_sha256
    if created_at is not None:
        body["created_at"] = created_at
    for field_name, digest in (
        ("prompt_sha256", prompt_sha256),
        ("system_text_sha256", system_text_sha256),
        ("user_text_sha256", user_text_sha256),
    ):
        if digest and not SHA256_RE.fullmatch(_text(digest).casefold()):
            raise PhotoContextResolverError(
                "invalid_snapshot_hash",
                f"{field_name} must be a lowercase SHA-256 value or empty",
            )
        if digest:
            body[field_name] = _text(digest).casefold()
    context_sha256 = _sha256_bytes(_canonical_bytes(body))
    snapshot = {
        "snapshot_id": _stable_id(
            "context-snapshot",
            {"context_sha256": context_sha256, "created_at": created_at or ""},
        ),
        **body,
        "context_sha256": context_sha256,
    }
    return snapshot


def _contract_error(code: str, message: str, path: str) -> dict[str, str]:
    return {
        "code": code,
        "severity": "error",
        "message": message,
        "context_id": path,
    }


def _is_positive_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 1


def _is_string_list(value: Any) -> bool:
    return isinstance(value, list) and all(isinstance(item, str) for item in value)


def validate_photo_context_bundle(bundle: dict) -> list[dict[str, str]]:
    """Return contract diagnostics for a resolver bundle (empty when valid)."""

    errors: list[dict[str, str]] = []
    if not isinstance(bundle, Mapping):
        return [_contract_error("bundle_not_object", "bundle must be an object", "$")]
    if bundle.get("format") != BUNDLE_FORMAT:
        errors.append(_contract_error(
            "bundle_format_invalid",
            f"bundle format must be {BUNDLE_FORMAT}",
            "$.format",
        ))
    bundle_hashes = bundle.get("source_hashes")
    if not isinstance(bundle_hashes, Mapping):
        errors.append(_contract_error(
            "bundle_source_hashes_invalid", "source_hashes must be an object",
            "$.source_hashes",
        ))
        bundle_hashes = {}
    else:
        for key, digest in bundle_hashes.items():
            logical_key = _text(key)
            if "/" in logical_key or "\\" in logical_key or ":" in logical_key:
                errors.append(_contract_error(
                    "bundle_source_hash_key_not_logical",
                    "source hash keys must not contain physical path separators",
                    "$.source_hashes",
                ))
            if not SHA256_RE.fullmatch(_text(digest).casefold()):
                errors.append(_contract_error(
                    "bundle_source_hash_invalid",
                    "bundle source hash must be a lowercase SHA-256 value",
                    "$.source_hashes." + logical_key,
                ))
    photos = bundle.get("photos")
    if not isinstance(photos, list):
        return errors + [_contract_error("photos_not_array", "photos must be an array", "$.photos")]
    photos_by_id: dict[str, Mapping[str, Any]] = {}
    component_ids: set[str] = set()
    evidence_ids: set[str] = set()
    excluded_ids: set[str] = set()
    for photo_index, photo in enumerate(photos):
        path_base = f"$.photos[{photo_index}]"
        if not isinstance(photo, Mapping):
            errors.append(_contract_error("photo_not_object", "photo must be an object", path_base))
            continue
        photo_id = _text(photo.get("photo_id"))
        if not photo_id:
            errors.append(_contract_error("photo_id_missing", "photo_id is required", path_base))
            continue
        if photo_id in photos_by_id:
            errors.append(_contract_error(
                "duplicate_photo_id", "photo_id must be unique", path_base + ".photo_id"
            ))
        photos_by_id[photo_id] = photo
        scope = photo.get("subject_scope")
        assignment = photo.get("assignment")
        asr_context = photo.get("asr_context")
        components = photo.get("content_components")
        if not isinstance(scope, Mapping):
            errors.append(_contract_error("subject_scope_missing", "subject_scope is required", path_base))
            scope = {}
        if not isinstance(assignment, Mapping):
            errors.append(_contract_error("assignment_missing", "assignment is required", path_base))
            assignment = {}
        if not isinstance(asr_context, Mapping):
            errors.append(_contract_error("asr_context_missing", "asr_context is required", path_base))
            asr_context = {}
        if not isinstance(components, list):
            errors.append(_contract_error("components_missing", "content_components must be an array", path_base))
            components = []
        photo_subject = scope.get("photo_subject_numero")
        if photo_subject is not None and not _is_positive_int(photo_subject):
            errors.append(_contract_error(
                "photo_subject_invalid", "photo subject must be a positive integer or null",
                path_base + ".subject_scope.photo_subject_numero",
            ))
        asr_subjects = scope.get("asr_subject_numeros")
        if not isinstance(asr_subjects, list) or not all(
            _is_positive_int(value) for value in asr_subjects
        ):
            errors.append(_contract_error(
                "asr_subjects_invalid", "ASR subject numbers must be positive integers",
                path_base + ".subject_scope.asr_subject_numeros",
            ))
            asr_subjects = []
        if len(asr_subjects) != len(set(asr_subjects)):
            errors.append(_contract_error(
                "asr_subjects_duplicate", "ASR subject numbers must be unique",
                path_base + ".subject_scope.asr_subject_numeros",
            ))
        editorial_subject = scope.get("editorial_subject_numero")
        if editorial_subject is not None and not _is_positive_int(editorial_subject):
            errors.append(_contract_error(
                "editorial_subject_invalid", "editorial subject must be a positive integer or null",
                path_base + ".subject_scope.editorial_subject_numero",
            ))
        assignment_status = assignment.get("status")
        if assignment_status not in {"assigned", "excluded", "unassigned"}:
            errors.append(_contract_error(
                "assignment_status_invalid", "assignment status is invalid",
                path_base + ".assignment.status",
            ))
        if assignment_status == "assigned":
            if not _is_positive_int(photo_subject):
                errors.append(_contract_error(
                    "assignment_subject_missing", "assigned record needs a subject number",
                    path_base + ".subject_scope.photo_subject_numero",
                ))
        elif photo_subject is not None:
            errors.append(_contract_error(
                "nonassigned_photo_has_subject",
                "excluded and unassigned photos must not carry a photo subject",
                path_base + ".subject_scope.photo_subject_numero",
            ))
        if assignment.get("authority") != "human":
            errors.append(_contract_error(
                "assignment_authority_invalid",
                "photo assignment authority must remain human",
                path_base + ".assignment.authority",
            ))
        if assignment.get("record_origin") not in {"ui", "batch", "pipeline", "unknown"}:
            errors.append(_contract_error(
                "assignment_origin_invalid", "assignment origin is invalid",
                path_base + ".assignment.record_origin",
            ))
        if assignment.get("validation_status") not in {"validated", "unvalidated", "unknown"}:
            errors.append(_contract_error(
                "assignment_validation_invalid", "assignment validation status is invalid",
                path_base + ".assignment.validation_status",
            ))
        assignment_id = assignment.get("assignment_id")
        if assignment_id and not ASSIGNMENT_ID_RE.fullmatch(str(assignment_id)):
            errors.append(_contract_error(
                "assignment_id_invalid", "assignment identifier is invalid",
                path_base + ".assignment.assignment_id",
            ))
        context_subjects = asr_context.get("asr_subject_numeros")
        if not isinstance(context_subjects, list) or sorted(context_subjects) != sorted(asr_subjects):
            errors.append(_contract_error(
                "asr_subject_scope_mismatch",
                "ASR subjects must match between subject_scope and asr_context",
                path_base + ".asr_context.asr_subject_numeros",
            ))
        context_evidence = asr_context.get("evidence_occurrence_ids")
        if not isinstance(context_evidence, list) or not all(
            EVIDENCE_ID_RE.fullmatch(str(value)) for value in context_evidence
        ):
            errors.append(_contract_error(
                "asr_evidence_invalid", "ASR evidence identifiers are invalid",
                path_base + ".asr_context.evidence_occurrence_ids",
            ))
            context_evidence = []
        evidence_ids.update(str(value) for value in context_evidence)
        link_status = asr_context.get("link_status")
        if link_status not in {"verified", "candidate", "unresolved"}:
            errors.append(_contract_error(
                "asr_link_status_invalid", "ASR link status is invalid",
                path_base + ".asr_context.link_status",
            ))
        if link_status == "candidate" and not context_evidence:
            errors.append(_contract_error(
                "candidate_without_evidence",
                "a candidate ASR relation needs at least one evidence identifier",
                path_base + ".asr_context",
            ))
        for component_index, component in enumerate(components):
            component_path = f"{path_base}.content_components[{component_index}]"
            if not isinstance(component, Mapping):
                errors.append(_contract_error(
                    "component_not_object", "component must be an object", component_path
                ))
                continue
            component_id = _text(component.get("component_id"))
            if not COMPONENT_ID_RE.fullmatch(component_id):
                errors.append(_contract_error(
                    "component_id_invalid", "component identifier is invalid",
                    component_path + ".component_id",
                ))
            elif component_id in component_ids:
                errors.append(_contract_error(
                    "duplicate_component_id", "component identifier must be unique",
                    component_path + ".component_id",
                ))
            component_ids.add(component_id)
            if component.get("photo_id") != photo_id:
                errors.append(_contract_error(
                    "component_photo_mismatch", "component photo_id must match its photo",
                    component_path + ".photo_id",
                ))
            if component.get("content_kind") not in {
                "human_assignment", "factual_metadata", "vlm_description",
                "annotation_label", "annotation_comment", "photo_dictation",
                "computed_relation", "editorial_summary",
            }:
                errors.append(_contract_error(
                    "component_kind_invalid", "component content kind is invalid",
                    component_path + ".content_kind",
                ))
            if component.get("origin") not in {"ui", "batch", "pipeline", "source", "unknown"}:
                errors.append(_contract_error(
                    "component_origin_invalid", "component origin is invalid",
                    component_path + ".origin",
                ))
            if component.get("validation_status") not in {"validated", "unvalidated", "unknown"}:
                errors.append(_contract_error(
                    "component_validation_invalid", "component validation status is invalid",
                    component_path + ".validation_status",
                ))
            for required_field in ("text", "source_file", "source_field"):
                if not isinstance(component.get(required_field), str):
                    errors.append(_contract_error(
                        "component_field_invalid",
                        f"component {required_field} must be a string",
                        component_path + "." + required_field,
                    ))
        assignment_components = [
            item for item in components
            if isinstance(item, Mapping) and item.get("content_kind") == "human_assignment"
        ]
        if assignment_status == "assigned" and _is_positive_int(photo_subject):
            expected = str(photo_subject)
            if not any(item.get("text") == expected for item in assignment_components):
                errors.append(_contract_error(
                    "human_assignment_component_missing",
                    "assigned photo needs a human_assignment component for its subject",
                    path_base + ".content_components",
                ))

    exclusions = bundle.get("photo_exclusions", [])
    if not isinstance(exclusions, list):
        errors.append(_contract_error(
            "exclusions_not_array", "photo_exclusions must be an array", "$.photo_exclusions"
        ))
        exclusions = []
    exclusion_objects: dict[str, Mapping[str, Any]] = {}
    for index, exclusion in enumerate(exclusions):
        path_base = f"$.photo_exclusions[{index}]"
        if not isinstance(exclusion, Mapping):
            errors.append(_contract_error("exclusion_not_object", "exclusion must be an object", path_base))
            continue
        exclusion_id = _text(exclusion.get("exclusion_id"))
        if not EXCLUSION_ID_RE.fullmatch(exclusion_id):
            errors.append(_contract_error(
                "exclusion_id_invalid", "exclusion identifier is invalid",
                path_base + ".exclusion_id",
            ))
        elif exclusion_id in exclusion_objects:
            errors.append(_contract_error(
                "duplicate_exclusion_id", "exclusion identifier must be unique",
                path_base + ".exclusion_id",
            ))
        exclusion_objects[exclusion_id] = exclusion
        photo_id = _text(exclusion.get("photo_id"))
        photo = photos_by_id.get(photo_id)
        if photo is None:
            errors.append(_contract_error(
                "exclusion_photo_missing", "excluded photo is absent from photo records",
                path_base + ".photo_id",
            ))
        elif photo.get("assignment", {}).get("status") != "excluded":
            errors.append(_contract_error(
                "exclusion_status_mismatch", "exclusion must reference an excluded photo",
                path_base + ".photo_id",
            ))
        if exclusion.get("validation_status") not in {"validated", "unvalidated", "unknown"}:
            errors.append(_contract_error(
                "exclusion_validation_invalid", "exclusion validation status is invalid",
                path_base + ".validation_status",
            ))
        excluded_ids.add(photo_id)

    snapshots = bundle.get("context_snapshots", [])
    if not isinstance(snapshots, list):
        errors.append(_contract_error(
            "snapshots_not_array", "context_snapshots must be an array", "$.context_snapshots"
        ))
        snapshots = []
    for index, snapshot in enumerate(snapshots):
        path_base = f"$.context_snapshots[{index}]"
        if not isinstance(snapshot, Mapping):
            errors.append(_contract_error("snapshot_not_object", "snapshot must be an object", path_base))
            continue
        if not SNAPSHOT_ID_RE.fullmatch(_text(snapshot.get("snapshot_id"))):
            errors.append(_contract_error(
                "snapshot_id_invalid", "snapshot identifier is invalid",
                path_base + ".snapshot_id",
            ))
        if snapshot.get("pipeline_kind") not in {"generaliste", "refere"}:
            errors.append(_contract_error(
                "snapshot_pipeline_invalid", "snapshot pipeline kind is invalid",
                path_base + ".pipeline_kind",
            ))
        snapshot_scope = snapshot.get("subject_scope")
        if not isinstance(snapshot_scope, Mapping):
            errors.append(_contract_error(
                "snapshot_subject_scope_missing", "snapshot subject scope is required",
                path_base + ".subject_scope",
            ))
            snapshot_scope = {}
        for key in (
            "included_photo_ids", "photo_exclusion_ids", "evidence_occurrence_ids",
            "component_ids", "selection_rule_ids",
        ):
            if not _is_string_list(snapshot.get(key)):
                errors.append(_contract_error(
                    "snapshot_array_invalid", f"snapshot {key} must be an array of strings",
                    path_base + "." + key,
                ))
            elif len(snapshot[key]) != len(set(snapshot[key])):
                errors.append(_contract_error(
                    "snapshot_array_duplicate", f"snapshot {key} contains duplicates",
                    path_base + "." + key,
                ))
        if snapshot.get("text_copy_embedded") is not False:
            errors.append(_contract_error(
                "snapshot_text_copy_not_false",
                "resolver snapshots must reference sources rather than embed text",
                path_base + ".text_copy_embedded",
            ))
        actual_context_hash = _sha256_bytes(_canonical_bytes({
            key: value
            for key, value in snapshot.items()
            if key not in {"snapshot_id", "context_sha256"}
        }))
        if _text(snapshot.get("context_sha256")) != actual_context_hash:
            errors.append(_contract_error(
                "snapshot_hash_mismatch",
                "snapshot context hash does not match its referenced content",
                path_base + ".context_sha256",
            ))
        expected_snapshot_id = _stable_id(
            "context-snapshot",
            {
                "context_sha256": actual_context_hash,
                "created_at": _text(snapshot.get("created_at")),
            },
        )
        if _text(snapshot.get("snapshot_id")) != expected_snapshot_id:
            errors.append(_contract_error(
                "snapshot_id_mismatch",
                "snapshot identifier does not match the context hash and creation time",
                path_base + ".snapshot_id",
            ))
        for hash_field in ("prompt_sha256", "system_text_sha256", "user_text_sha256"):
            hash_value = _text(snapshot.get(hash_field))
            if hash_value and not SHA256_RE.fullmatch(hash_value):
                errors.append(_contract_error(
                    "snapshot_hash_invalid", f"{hash_field} is not a SHA-256 value",
                    path_base + "." + hash_field,
                ))
        source_hashes = snapshot.get("source_hashes")
        if not isinstance(source_hashes, Mapping) or not all(
            SHA256_RE.fullmatch(_text(value)) for value in source_hashes.values()
        ):
            errors.append(_contract_error(
                "snapshot_source_hashes_invalid",
                "snapshot source hashes must be lowercase SHA-256 values",
                path_base + ".source_hashes",
            ))
            source_hashes = {}
        if isinstance(bundle_hashes, Mapping):
            for key, digest in bundle_hashes.items():
                if _text(source_hashes.get(key)).casefold() != _text(digest).casefold():
                    errors.append(_contract_error(
                        "snapshot_source_hash_mismatch",
                        "snapshot source hash is missing or differs from the resolver bundle",
                        path_base + ".source_hashes",
                    ))
        included = snapshot.get("included_photo_ids")
        included_component_ids: set[str] = set()
        included_evidence_ids: set[str] = set()
        included_asr_subjects: set[int] = set()
        included_photo_set = set(included) if isinstance(included, list) else set()
        if isinstance(included, list):
            for photo_id in included:
                if photo_id in excluded_ids:
                    errors.append(_contract_error(
                        "snapshot_includes_excluded_photo",
                        "an excluded photo cannot appear in included_photo_ids",
                        path_base + ".included_photo_ids",
                    ))
                photo = photos_by_id.get(str(photo_id))
                if photo is None:
                    errors.append(_contract_error(
                        "snapshot_unknown_photo", "snapshot references an unknown photo",
                        path_base + ".included_photo_ids",
                    ))
                elif photo.get("assignment", {}).get("status") != "assigned":
                    errors.append(_contract_error(
                        "snapshot_includes_nonassigned_photo",
                        "snapshot can include only assigned photos",
                        path_base + ".included_photo_ids",
                    ))
                elif (
                    snapshot_scope.get("photo_subject_numero")
                    != (photo.get("subject_scope") or {}).get("photo_subject_numero")
                ):
                    errors.append(_contract_error(
                        "snapshot_photo_subject_mismatch",
                        "included photo does not match the snapshot photo subject",
                        path_base + ".included_photo_ids",
                    ))
                if photo is not None:
                    included_component_ids.update(
                        str(item.get("component_id"))
                        for item in photo.get("content_components", [])
                        if isinstance(item, Mapping)
                    )
                    included_evidence_ids.update(
                        str(item)
                        for item in (photo.get("asr_context") or {}).get(
                            "evidence_occurrence_ids", []
                        )
                    )
                    included_asr_subjects.update(
                        int(item)
                        for item in (photo.get("subject_scope") or {}).get(
                            "asr_subject_numeros", []
                        )
                    )
        component_id_values = snapshot.get("component_ids")
        if isinstance(component_id_values, list):
            for component_id in component_id_values:
                if component_id not in component_ids:
                    errors.append(_contract_error(
                        "snapshot_unknown_component",
                        "snapshot references an unknown component",
                        path_base + ".component_ids",
                    ))
                elif component_id not in included_component_ids:
                    errors.append(_contract_error(
                        "snapshot_component_not_from_included_photo",
                        "snapshot component does not belong to an included photo",
                        path_base + ".component_ids",
                    ))
            missing_components = included_component_ids - set(component_id_values)
            if missing_components:
                errors.append(_contract_error(
                    "snapshot_components_incomplete",
                    "snapshot omits components from an included photo",
                    path_base + ".component_ids",
                ))
        evidence_values = snapshot.get("evidence_occurrence_ids")
        if isinstance(evidence_values, list):
            for evidence_id in evidence_values:
                if evidence_id not in evidence_ids:
                    errors.append(_contract_error(
                        "snapshot_unknown_evidence",
                        "snapshot references unknown ASR evidence",
                        path_base + ".evidence_occurrence_ids",
                    ))
                elif evidence_id not in included_evidence_ids:
                    errors.append(_contract_error(
                        "snapshot_evidence_not_from_included_photo",
                        "snapshot evidence does not belong to an included photo",
                        path_base + ".evidence_occurrence_ids",
                    ))
            missing_evidence = included_evidence_ids - set(evidence_values)
            if missing_evidence:
                errors.append(_contract_error(
                    "snapshot_evidence_incomplete",
                    "snapshot omits ASR evidence from an included photo",
                    path_base + ".evidence_occurrence_ids",
                ))
        exclusion_values = snapshot.get("photo_exclusion_ids")
        if isinstance(exclusion_values, list):
            for exclusion_id in exclusion_values:
                if exclusion_id not in exclusion_objects:
                    errors.append(_contract_error(
                        "snapshot_unknown_exclusion",
                        "snapshot references an unknown exclusion",
                        path_base + ".photo_exclusion_ids",
                    ))
        snapshot_scope_subjects = snapshot_scope.get("asr_subject_numeros", [])
        if isinstance(snapshot_scope_subjects, list):
            expected_subjects = sorted(included_asr_subjects)
            if sorted(set(snapshot_scope_subjects)) != expected_subjects:
                errors.append(_contract_error(
                    "snapshot_asr_subject_scope_mismatch",
                    "snapshot ASR subjects do not match included photos",
                    path_base + ".subject_scope.asr_subject_numeros",
                ))
        rule_values = snapshot.get("selection_rule_ids")
        if (
            bundle.get("format") == BUNDLE_FORMAT
            and isinstance(rule_values, list)
            and "snapshot_is_prepared_not_llm_execution" not in rule_values
        ):
            errors.append(_contract_error(
                "snapshot_execution_state_ambiguous",
                "resolver snapshots must state that they are prepared, not executed",
                path_base + ".selection_rule_ids",
            ))
    return errors


__all__ = [
    "AsrContextItem",
    "PhotoContextResolverError",
    "SourceSelection",
    "build_context_snapshot",
    "resolve_photo_context",
    "validate_photo_context_bundle",
]
