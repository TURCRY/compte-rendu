"""Utilities for robust structured LLM outputs.

This module is intentionally dependency-light: it validates the pass 1 schema
with JSON-Schema-like rules implemented in Python so the pipeline can run in the
existing container without adding packages. If jsonschema is installed later,
the public API can be extended without changing the PowerShell caller.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass


class StructuredOutputError(ValueError):
    """Raised when an LLM response cannot be extracted or validated."""


@dataclass
class ValidationResult:
    valid: bool
    value: Any = None
    errors: list[str] = field(default_factory=list)
    repaired: bool = False
    fallback: bool = False


PASS1_SCHEMA_HINT = {
    "type": "object",
    "required": ["segment_id", "sujets"],
    "properties": {
        "segment_id": {"type": "string"},
        "sujets": {
            "type": "array",
            "items": {
                "type": "object",
                "required": ["titre", "interventions"],
                "properties": {
                    "titre": {"type": "string"},
                    "interventions": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "required": ["row_ref", "auteur", "role", "texte"],
                            "properties": {
                                "row_ref": {"type": ["integer", "null"]},
                                "auteur": {"type": ["string", "null"]},
                                "role": {"type": ["string", "null"]},
                                "texte": {"type": "string"},
                            },
                            "additionalProperties": False,
                        },
                    },
                },
                "additionalProperties": False,
            },
        },
    },
    "additionalProperties": False,
}


PASS1_LEGACY_SCHEMA_HINT = {
    "type": "object",
    "required": ["sujets"],
    "properties": {
        "sujets": {
            "type": "object",
            "additionalProperties": {
                "type": "array",
                "items": {
                    "type": "object",
                    "required": ["texte"],
                    "properties": {
                        "row_ref": {"type": ["integer", "null"]},
                        "auteur": {"type": ["string", "null"]},
                        "role": {"type": ["string", "null"]},
                        "texte": {"type": "string"},
                    },
                    "additionalProperties": True,
                },
            },
        }
    },
    "additionalProperties": True,
}


JSON_FENCE_RE = re.compile(r"```(?:json)?\s*(.*?)```", re.IGNORECASE | re.DOTALL)
TIME_RE = re.compile(r"\b\d{1,2}:\d{2}:\d{2}(?:[.,]\d+)?\b")


def extract_json_from_text(text: str) -> tuple[Any, str, bool]:
    """Extract and parse the first robust JSON object/array from text.

    Returns ``(parsed, json_text, repaired)``. ``repaired`` means lightweight
    cleanup was applied, such as stripping fences or removing trailing commas.
    """

    if not text or not text.strip():
        raise StructuredOutputError("empty response")

    candidates: list[tuple[str, bool]] = []
    stripped = text.strip().lstrip("\ufeff").strip()
    candidates.append((stripped, False))

    for match in JSON_FENCE_RE.finditer(stripped):
        candidates.append((match.group(1).strip(), True))

    sliced = _slice_first_json(stripped)
    if sliced:
        candidates.append((sliced, sliced != stripped))

    seen: set[str] = set()
    errors: list[str] = []
    for candidate, repaired in candidates:
        if not candidate or candidate in seen:
            continue
        seen.add(candidate)

        for payload, extra_repair in _repair_candidates(candidate):
            try:
                return json.loads(payload), payload, repaired or extra_repair
            except json.JSONDecodeError as exc:
                errors.append(f"{exc.msg} at char {exc.pos}")

    detail = "; ".join(errors[:4]) or "no JSON candidate found"
    raise StructuredOutputError(detail)


def _slice_first_json(text: str) -> str | None:
    starts = [(idx, ch) for idx, ch in enumerate(text) if ch in "[{"]
    for start, opener in starts:
        closer = "}" if opener == "{" else "]"
        stack: list[str] = []
        in_string = False
        escape = False
        for idx in range(start, len(text)):
            ch = text[idx]
            if in_string:
                if escape:
                    escape = False
                elif ch == "\\":
                    escape = True
                elif ch == '"':
                    in_string = False
                continue
            if ch == '"':
                in_string = True
            elif ch in "{[":
                stack.append("}" if ch == "{" else "]")
            elif ch in "}]":
                if not stack or stack[-1] != ch:
                    break
                stack.pop()
                if not stack and ch == closer:
                    return text[start : idx + 1].strip()
    return None


def _repair_candidates(candidate: str) -> list[tuple[str, bool]]:
    out = [(candidate, False)]
    without_labels = re.sub(r"^\s*(?:JSON|Réponse|Reponse)\s*:\s*", "", candidate, flags=re.I)
    if without_labels != candidate:
        out.append((without_labels, True))
    without_trailing_commas = re.sub(r",\s*([}\]])", r"\1", without_labels)
    if without_trailing_commas != without_labels:
        out.append((without_trailing_commas, True))
    balanced = _balance_brackets(without_trailing_commas)
    if balanced != without_trailing_commas:
        out.append((balanced, True))
    return out


def _balance_brackets(payload: str) -> str:
    in_string = False
    escape = False
    stack: list[str] = []
    for ch in payload:
        if in_string:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
        elif ch in "{[":
            stack.append("}" if ch == "{" else "]")
        elif ch in "}]" and stack and stack[-1] == ch:
            stack.pop()
    return payload + "".join(reversed(stack))


def validate_pass1_analysis(value: Any, start_sec: float | None = None, end_sec: float | None = None) -> ValidationResult:
    """Validate pass 1 analysis. Timecodes are forbidden in new LLM output."""

    errors: list[str] = []
    if not isinstance(value, dict):
        return ValidationResult(False, value, ["root must be an object"])

    normalized = normalize_pass1_analysis_shape(value)
    sujets = value.get("sujets")
    if isinstance(sujets, list):
        for subject_idx, subject_obj in enumerate(sujets):
            subject_path = f"sujets[{subject_idx}]"
            if not isinstance(subject_obj, dict):
                errors.append(f"{subject_path}: item must be an object")
                continue
            titre = subject_obj.get("titre")
            if not isinstance(titre, str) or not titre.strip():
                errors.append(f"{subject_path}.titre: missing non-empty string")
            entries = subject_obj.get("interventions")
            if not isinstance(entries, list):
                errors.append(f"{subject_path}.interventions: must be an array")
                continue
            for idx, entry in enumerate(entries):
                _validate_pass1_entry(entry, f"{subject_path}.interventions[{idx}]", errors)
    elif isinstance(sujets, dict):
        for subject, entries in sujets.items():
            if not str(subject).strip().isdigit():
                errors.append(f"sujets.{subject}: subject key must be numeric")
            if not isinstance(entries, list):
                errors.append(f"sujets.{subject}: value must be an array")
                continue
            for idx, entry in enumerate(entries):
                _validate_pass1_entry(entry, f"sujets.{subject}[{idx}]", errors)
    else:
        errors.append("missing or invalid 'sujets' array")

    out_of_interval = find_timecodes_outside_interval(normalized, start_sec, end_sec)
    for tc in out_of_interval:
        errors.append(f"timecode outside segment interval: {tc}")

    return ValidationResult(not errors, normalized, errors)


def _validate_pass1_entry(entry: Any, path: str, errors: list[str]) -> None:
    if not isinstance(entry, dict):
        errors.append(f"{path}: item must be an object")
        return
    for key in ("row_ref", "auteur", "role", "texte"):
        if key not in entry:
            errors.append(f"{path}.{key}: missing required field")
    text = entry.get("texte")
    if not isinstance(text, str) or not text.strip():
        errors.append(f"{path}.texte: missing non-empty string")
    if "timecode" in entry or "timecodes" in entry:
        errors.append(f"{path}: LLM timecodes are forbidden in pass 1")
    row_ref = entry.get("row_ref")
    if row_ref is not None and not isinstance(row_ref, int):
        errors.append(f"{path}.row_ref: must be integer or null")


def normalize_pass1_analysis_shape(value: dict[str, Any]) -> dict[str, Any]:
    """Convert OpenAI strict pass1 sujets[] shape to legacy internal sujets object."""

    sujets = value.get("sujets")
    if isinstance(sujets, dict):
        return dict(value)
    if not isinstance(sujets, list):
        return dict(value)

    legacy: dict[str, list[dict[str, Any]]] = {}
    for idx, subject_obj in enumerate(sujets, start=1):
        if not isinstance(subject_obj, dict):
            continue
        title = str(subject_obj.get("titre") or "").strip()
        subject_key = _subject_key_from_title(title) or str(idx)
        interventions = subject_obj.get("interventions")
        if not isinstance(interventions, list):
            continue
        clean: list[dict[str, Any]] = []
        for entry in interventions:
            if isinstance(entry, dict):
                clean.append(
                    {
                        "row_ref": entry.get("row_ref"),
                        "auteur": entry.get("auteur"),
                        "role": entry.get("role"),
                        "texte": entry.get("texte"),
                    }
                )
        if clean:
            legacy.setdefault(subject_key, []).extend(clean)

    normalized = dict(value)
    normalized["sujets"] = legacy
    return normalized


def _subject_key_from_title(title: str) -> str | None:
    match = re.match(r"^\s*(\d+)\b", title or "")
    if match:
        return match.group(1)
    return None


def call_with_bounded_retry(
    call_llm: Callable[[str | None], str],
    validate: Callable[[Any], ValidationResult],
    max_attempts: int = 2,
) -> ValidationResult:
    """Call an LLM and retry with validator errors as repair instructions."""

    last_errors: list[str] = []
    for attempt in range(max(1, max_attempts)):
        repair_message = None
        if attempt > 0 and last_errors:
            repair_message = "Corrige la sortie JSON. Erreurs: " + " | ".join(last_errors)
        raw = call_llm(repair_message)
        try:
            parsed, _json_text, repaired = extract_json_from_text(raw)
        except StructuredOutputError as exc:
            last_errors = [str(exc)]
            continue
        result = validate(parsed)
        result.repaired = result.repaired or repaired
        if result.valid:
            return result
        last_errors = result.errors
    return ValidationResult(False, None, last_errors, fallback=True)


def build_pass1_fallback_analysis() -> dict[str, Any]:
    return {"sujets": {}}


def build_pass1_envelope(
    *,
    segment_id: str,
    row_start: int,
    row_end: int,
    start_sec: float,
    end_sec: float,
    start_hms: str,
    end_hms: str,
    texte_source: str,
    llm_analysis: dict[str, Any] | None,
    llm_raw_response: str,
    llm_valid: bool,
    llm_validation_errors: list[str],
    repaired: bool = False,
    fallback: bool = False,
) -> dict[str, Any]:
    analysis = llm_analysis if isinstance(llm_analysis, dict) else build_pass1_fallback_analysis()
    sujets_projected = project_pass1_sujets_from_source(analysis, texte_source)
    return {
        "segment_id": segment_id,
        "row_start": row_start,
        "row_end": row_end,
        "start_sec": start_sec,
        "end_sec": end_sec,
        "start_hms": start_hms,
        "end_hms": end_hms,
        "texte_source": texte_source,
        "llm_analysis": analysis,
        "llm_raw_response": llm_raw_response or "",
        "llm_valid": bool(llm_valid),
        "llm_validation_errors": llm_validation_errors,
        "llm_repaired": bool(repaired),
        "llm_fallback": bool(fallback),
        "sujets": sujets_projected,
    }


def normalize_pass1_envelope(value: Any, defaults: dict[str, Any] | None = None) -> dict[str, Any]:
    """Return a complete pass 1 envelope even when ``value`` is incomplete."""

    defaults = defaults or {}
    errors: list[str] = []
    if isinstance(value, dict):
        envelope = dict(value)
    else:
        envelope = {}
        errors.append("structured_output_utils output was not an object")

    required_defaults = {
        "segment_id": defaults.get("segment_id", ""),
        "row_start": defaults.get("row_start", 0),
        "row_end": defaults.get("row_end", 0),
        "start_sec": defaults.get("start_sec", 0),
        "end_sec": defaults.get("end_sec", 0),
        "start_hms": defaults.get("start_hms", ""),
        "end_hms": defaults.get("end_hms", ""),
        "texte_source": defaults.get("texte_source", ""),
        "llm_analysis": build_pass1_fallback_analysis(),
        "llm_raw_response": defaults.get("llm_raw_response", ""),
        "llm_valid": False,
        "llm_validation_errors": [],
        "llm_repaired": False,
        "llm_fallback": True,
    }

    for key, fallback_value in required_defaults.items():
        if key not in envelope:
            envelope[key] = fallback_value
            errors.append(f"missing envelope field: {key}")

    if not isinstance(envelope.get("llm_analysis"), dict):
        envelope["llm_analysis"] = build_pass1_fallback_analysis()
        errors.append("invalid envelope field: llm_analysis")
    if not isinstance(envelope.get("llm_validation_errors"), list):
        envelope["llm_validation_errors"] = [str(envelope.get("llm_validation_errors"))]
        errors.append("invalid envelope field: llm_validation_errors")

    envelope["llm_valid"] = bool(envelope.get("llm_valid", False))
    envelope["llm_repaired"] = bool(envelope.get("llm_repaired", False))
    envelope["llm_fallback"] = bool(envelope.get("llm_fallback", True)) or not envelope["llm_valid"]

    if errors:
        existing_errors = [str(err) for err in envelope.get("llm_validation_errors", [])]
        envelope["llm_validation_errors"] = existing_errors + errors
        envelope["llm_valid"] = False
        envelope["llm_fallback"] = True

    if not isinstance(envelope.get("sujets"), dict):
        envelope["sujets"] = project_pass1_sujets_from_source(
            envelope["llm_analysis"],
            str(envelope.get("texte_source") or ""),
        )

    return envelope


def project_pass1_sujets_from_source(analysis: dict[str, Any], texte_source: str) -> dict[str, list[dict[str, Any]]]:
    """Build the legacy ``sujets`` view with deterministic timecodes from ROW refs."""

    sujets = analysis.get("sujets") if isinstance(analysis, dict) else None
    if not isinstance(sujets, dict):
        return {}

    row_map = _parse_source_rows(texte_source)
    projected: dict[str, list[dict[str, Any]]] = {}
    for subject, entries in sujets.items():
        if not isinstance(entries, list):
            continue
        clean_entries: list[dict[str, Any]] = []
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            row_ref = entry.get("row_ref")
            src = row_map.get(row_ref) if isinstance(row_ref, int) else None
            text = entry.get("texte")
            clean_entries.append(
                {
                    "row_ref": row_ref if isinstance(row_ref, int) else None,
                    "timecode": src.get("timecode") if src else None,
                    "auteur": entry.get("auteur") or (src.get("speaker") if src else None) or "Inconnu",
                    "role": entry.get("role"),
                    "texte": text if isinstance(text, str) and text.strip() else (src.get("text") if src else ""),
                }
            )
        if clean_entries:
            projected[str(subject)] = clean_entries
    return projected


def _parse_source_rows(texte_source: str) -> dict[int, dict[str, str]]:
    rows: dict[int, dict[str, str]] = {}
    pattern = re.compile(r"^\[ROW\s+(\d+)\]\s+\[([^\]]+)\]\s+([^:]+):\s*(.*)$")
    for line in (texte_source or "").splitlines():
        match = pattern.match(line.strip())
        if not match:
            continue
        row, timecode, speaker, text = match.groups()
        rows[int(row)] = {"timecode": timecode, "speaker": speaker.strip(), "text": text.strip()}
    return rows


def find_timecodes_outside_interval(value: Any, start_sec: float | None, end_sec: float | None) -> list[str]:
    if start_sec is None or end_sec is None:
        return []
    out: list[str] = []
    for tc in _walk_timecodes(value):
        sec = _hms_to_seconds(tc)
        if sec is not None and (sec < start_sec or sec > end_sec):
            out.append(tc)
    return out


def _walk_timecodes(value: Any) -> list[str]:
    found: list[str] = []
    if isinstance(value, dict):
        for key, child in value.items():
            if key in {"timecode", "timecodes"}:
                if isinstance(child, list):
                    found.extend(str(v) for v in child)
                else:
                    found.append(str(child))
            else:
                found.extend(_walk_timecodes(child))
    elif isinstance(value, list):
        for child in value:
            found.extend(_walk_timecodes(child))
    elif isinstance(value, str):
        found.extend(TIME_RE.findall(value))
    return found


def _hms_to_seconds(value: str) -> float | None:
    match = re.match(r"^\s*(\d{1,2}):(\d{2}):(\d{2})(?:[.,](\d+))?\s*$", value)
    if not match:
        return None
    h, m, s, frac = match.groups()
    sec = int(h) * 3600 + int(m) * 60 + int(s)
    if frac:
        sec += float("0." + frac)
    return sec


def pass1_cli(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--raw-file", required=True)
    parser.add_argument("--source-file", required=True)
    parser.add_argument("--segment-id", required=True)
    parser.add_argument("--row-start", type=int, required=True)
    parser.add_argument("--row-end", type=int, required=True)
    parser.add_argument("--start-sec", type=float, required=True)
    parser.add_argument("--end-sec", type=float, required=True)
    parser.add_argument("--start-hms", required=True)
    parser.add_argument("--end-hms", required=True)
    args = parser.parse_args(argv)

    raw = Path(args.raw_file).read_text(encoding="utf-8-sig") if Path(args.raw_file).exists() else ""
    source = Path(args.source_file).read_text(encoding="utf-8-sig") if Path(args.source_file).exists() else ""
    repaired = False
    fallback = False
    try:
        parsed, _json_text, repaired = extract_json_from_text(raw)
        result = validate_pass1_analysis(parsed, args.start_sec, args.end_sec)
        analysis = parsed if result.valid else build_pass1_fallback_analysis()
        fallback = not result.valid
    except StructuredOutputError as exc:
        result = ValidationResult(False, None, [str(exc)])
        analysis = build_pass1_fallback_analysis()
        fallback = True

    envelope = build_pass1_envelope(
        segment_id=args.segment_id,
        row_start=args.row_start,
        row_end=args.row_end,
        start_sec=args.start_sec,
        end_sec=args.end_sec,
        start_hms=args.start_hms,
        end_hms=args.end_hms,
        texte_source=source,
        llm_analysis=analysis,
        llm_raw_response=raw,
        llm_valid=result.valid,
        llm_validation_errors=result.errors,
        repaired=repaired,
        fallback=fallback,
    )
    envelope = normalize_pass1_envelope(
        envelope,
        {
            "segment_id": args.segment_id,
            "row_start": args.row_start,
            "row_end": args.row_end,
            "start_sec": args.start_sec,
            "end_sec": args.end_sec,
            "start_hms": args.start_hms,
            "end_hms": args.end_hms,
            "texte_source": source,
            "llm_raw_response": raw,
        },
    )
    print(json.dumps(envelope, ensure_ascii=False, indent=2))
    return 0


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv and argv[0] == "pass1":
        return pass1_cli(argv[1:])
    raise SystemExit("Usage: structured_output_utils.py pass1 ...")


if __name__ == "__main__":
    raise SystemExit(main())
