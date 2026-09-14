#!/usr/bin/env python3
"""Run the consultative Pass3F-A cross-subject audit through an OpenAI-compatible API."""

from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict, deque
from pathlib import Path
from typing import Any, Callable, Iterable

from pass3f_provenance import canonical_bytes, content_tokens, read_json, stable_id, write_json_deterministic


SCHEMA_VERSION = "pass3f.audit.v1"
MANIFEST_VERSION = "pass3f.audit.manifest.v1"
DEFAULT_MODEL = "pass3_remote"
DEFAULT_TEMPERATURE = 0.1
DEFAULT_MAX_TOKENS = 3000
DEFAULT_MAX_CANDIDATES = 4
DEFAULT_MAX_INPUT_CHARS = 60000
DEFAULT_SAFETY_MARGIN_TOKENS = 2048
PROTECTED_OUTPUT_NAMES = {"global_by_sujet.json", "global_final.json", "global_meeting.json"}
ACTIONS = {"move", "merge", "remove_duplicate", "retain_overlap", "no_action"}
ORIGIN_STAGES = {"pass1", "2e", "3e", "indeterminate"}
LOCAL_STRICT_MODELS = {
    "local-gemma-4": {"local-gemma-4", "Gemma_4_12B_It_Q4_K_M"},
}
_ID_PATTERNS = {
    "proposal_id": re.compile(r"^proposal:[0-9a-f]{64}$"),
    "candidate_id": re.compile(r"^candidate:[0-9a-f]{64}$"),
}
_PROPOSAL_KEYS = {
    "proposal_id", "candidate_id", "action", "source_subject", "target_subject",
    "source_fragment_ids", "evidence_refs", "original_pass1_subjects", "origin_stage",
    "reason", "confidence", "ambiguous", "requires_human_review", "truncation_context",
}


SYSTEM_PROMPT = """Tu réalises la passe consultative 3F-A d'un compte rendu d'expertise judiciaire.
Tu audits des candidats inter-sujets sans modifier aucun artefact et sans prendre de décision finale.

Règles absolues :
- Réponds par un unique objet JSON strict, sans Markdown ni commentaire hors JSON.
- Produis exactement une proposition par candidate_id et recopie proposal_id sans le modifier.
- Une cible doit appartenir à allowed_subject_ids. N'invente ni sujet, ni fragment, ni preuve.
- evidence_refs, source_fragment_ids et original_pass1_subjects doivent être des sous-ensembles exacts des valeurs fournies pour le candidat.
- Un lien de provenance candidate ou unresolved ne devient jamais verified par ton analyse.
- Une troncature possible au niveau fragment n'est jamais une preuve que le fragment est incomplet.
- Une troncature confirmed au niveau sujet/chunk impose de la prudence, sans être attribuée à un fragment particulier.
- Une troncature unknown interdit une confiance forte fondée seulement sur le texte dérivé 2E/3E.
- move, merge et remove_duplicate restent toujours requires_human_review=true.
- Dans cette passe consultative, toutes les propositions restent requires_human_review=true.
- N'invente aucun fait. Préserve dates, lieux, acteurs, portée technique et degré de certitude.

Actions :
- move : mauvaise affectation probable vers un autre sujet existant ;
- merge : formulations proches à rapprocher tout en conservant leurs nuances ;
- remove_duplicate : duplication réelle étayée par la même preuve ;
- retain_overlap : recouvrement légitime entre sujets ;
- no_action : signal insuffisant, faux positif probable ou cas à ne pas changer.

origin_stage indique où l'erreur semble apparaître : pass1, 2e, 3e ou indeterminate.
ambiguous doit rester true dès que les preuves ne permettent pas une conclusion univoque.
Le champ reason doit distinguer observation, preuve et incertitude, sans prétendre à une provenance plus forte que link_status.
"""


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_text(text: str) -> str:
    return sha256_bytes(text.encode("utf-8"))


def estimate_tokens(text: str) -> int:
    """Use the pipeline's deterministic four-characters-per-token estimate."""
    return (len(text) + 3) // 4


def _subject_sort(value: Any) -> tuple[int, str]:
    text = str(value or "")
    try:
        return int(text), text
    except ValueError:
        return 10**9, text


def _candidate_subjects(candidate: dict[str, Any]) -> set[str]:
    values = {str(candidate["source_subject"])}
    if candidate.get("target_subject") is not None:
        values.add(str(candidate["target_subject"]))
    return values


def candidate_components(candidates: Iterable[dict[str, Any]]) -> list[list[dict[str, Any]]]:
    ordered = sorted(candidates, key=lambda item: item["candidate_id"])
    by_subject: dict[str, list[int]] = defaultdict(list)
    for index, candidate in enumerate(ordered):
        for subject_id in _candidate_subjects(candidate):
            by_subject[subject_id].append(index)
    remaining = set(range(len(ordered)))
    components: list[list[dict[str, Any]]] = []
    while remaining:
        first = min(remaining)
        queue = deque([first])
        indexes: set[int] = set()
        while queue:
            index = queue.popleft()
            if index not in remaining:
                continue
            remaining.remove(index)
            indexes.add(index)
            for subject_id in _candidate_subjects(ordered[index]):
                queue.extend(by_subject[subject_id])
        components.append([ordered[index] for index in sorted(indexes)])
    return components


def _candidate_truncation(
    candidate: dict[str, Any],
    subjects: dict[str, dict[str, Any]],
    fragments: dict[str, dict[str, Any]],
    fragment_ids: Iterable[str] | None = None,
) -> dict[str, Any]:
    subject_ids = sorted(_candidate_subjects(candidate), key=_subject_sort)
    fragment_ids = sorted(set(fragment_ids if fragment_ids is not None else candidate.get("fragment_refs") or []))
    return {
        "subjects": [
            {"subject_id": subject_id, **subjects[subject_id]["truncation"]}
            for subject_id in subject_ids
        ],
        "fragments": [
            {"fragment_id": fragment_id, **fragments[fragment_id]["truncation"]}
            for fragment_id in fragment_ids if fragment_id in fragments
        ],
        "caution": (
            "Subject/chunk truncation is contextual only; possible fragment truncation is not factual evidence, "
            "and unknown truncation forbids high confidence based only on derived text."
        ),
    }


def _original_pass1_subjects(candidate: dict[str, Any], evidence: dict[str, dict[str, Any]]) -> list[str]:
    values: set[str] = set()
    for evidence_id in candidate.get("evidence_refs") or []:
        item = evidence.get(evidence_id)
        if item:
            values.update(str(value) for value in item["pass1_subjects"])
    return sorted(values, key=_subject_sort)


def _relevant_3e_fragments(
    candidates: list[dict[str, Any]],
    all_fragments: list[dict[str, Any]],
    *,
    per_subject_limit: int = 10,
) -> list[dict[str, Any]]:
    subject_ids = {subject for item in candidates for subject in _candidate_subjects(item)}
    direct_ids = {ref for item in candidates for ref in item.get("fragment_refs") or []}
    query_tokens = {
        subject_id: set().union(*(
            [content_tokens(item.get("excerpt", "")) for item in candidates if subject_id in _candidate_subjects(item)]
            or [set()]
        ))
        for subject_id in subject_ids
    }
    selected: dict[str, dict[str, Any]] = {}
    grouped: dict[str, list[tuple[float, dict[str, Any]]]] = defaultdict(list)
    for fragment in all_fragments:
        if fragment["stage"] != "3E" or fragment["subject_id"] not in subject_ids:
            continue
        fragment_id = fragment["fragment_id"]
        tokens = content_tokens(fragment["text"])
        query = query_tokens[fragment["subject_id"]]
        score = len(tokens & query) / max(1, len(tokens | query))
        if fragment_id in direct_ids:
            score += 2.0
        grouped[fragment["subject_id"]].append((score, fragment))
    for subject_id in sorted(grouped, key=_subject_sort):
        ranked = sorted(grouped[subject_id], key=lambda pair: (-pair[0], pair[1]["fragment_id"]))
        for score, fragment in ranked[:per_subject_limit]:
            if score > 0 or fragment["fragment_id"] in direct_ids:
                selected[fragment["fragment_id"]] = fragment
    return [selected[key] for key in sorted(selected)]


def _context_windows(
    evidence_refs: set[str],
    evidence_items: list[dict[str, Any]],
    *,
    radius: int = 1,
) -> list[dict[str, Any]]:
    ordered = sorted(evidence_items, key=lambda item: (
        str(item.get("segment_id") or ""),
        item.get("row_ref") if isinstance(item.get("row_ref"), int) else 10**12,
        item["evidence_id"],
    ))
    positions = {item["evidence_id"]: index for index, item in enumerate(ordered)}
    windows = []
    for evidence_id in sorted(evidence_refs):
        if evidence_id not in positions:
            continue
        index = positions[evidence_id]
        center = ordered[index]
        rows = []
        for near in ordered[max(0, index - radius):min(len(ordered), index + radius + 1)]:
            if near.get("segment_id") == center.get("segment_id"):
                rows.append({
                    "evidence_id": near["evidence_id"],
                    "row_ref": near["row_ref"],
                    "timecode": near["timecode"],
                    "speaker": near["speaker"],
                    "exact_text": near["exact_text"],
                    "pass1_subjects": near["pass1_subjects"],
                })
        windows.append({"center_evidence_id": evidence_id, "rows": rows})
    return windows


def build_group_packet(
    registry: dict[str, Any],
    candidates: list[dict[str, Any]],
) -> dict[str, Any]:
    subjects = {item["subject_id"]: item for item in registry["subjects"]}
    evidence = {item["evidence_id"]: item for item in registry["evidence"]}
    fragments = {item["fragment_id"]: item for item in registry["derived_fragments"]}
    subject_ids = sorted(
        {subject for item in candidates for subject in _candidate_subjects(item)},
        key=_subject_sort,
    )
    evidence_refs = {ref for item in candidates for ref in item.get("evidence_refs") or []}
    candidate_values = []
    for candidate in sorted(candidates, key=lambda item: item["candidate_id"]):
        original = _original_pass1_subjects(candidate, evidence)
        relevant_3e = _relevant_3e_fragments([candidate], registry["derived_fragments"])
        fragment_ids = sorted({
            ref for ref in candidate.get("fragment_refs") or [] if ref in fragments
        } | {
            item["fragment_id"] for item in relevant_3e
        })
        proposal_id = stable_id("proposal", {
            "run_id": registry["run"]["run_id"],
            "candidate_id": candidate["candidate_id"],
        })
        candidate_values.append({
            **candidate,
            "proposal_id": proposal_id,
            "allowed_subject_ids": subject_ids,
            "allowed_evidence_refs": sorted(set(candidate.get("evidence_refs") or [])),
            "allowed_fragment_ids": fragment_ids,
            "original_pass1_subjects": original,
            "truncation_context": _candidate_truncation(candidate, subjects, fragments, fragment_ids),
        })
    return {
        "schema": "pass3f.audit.input.v1",
        "run_id": registry["run"]["run_id"],
        "pipeline_kind": registry["run"]["pipeline_kind"],
        "allowed_subject_ids": subject_ids,
        "subject_definitions": [subjects[subject_id] for subject_id in subject_ids],
        "candidates": candidate_values,
        "evidence": [evidence[ref] for ref in sorted(evidence_refs) if ref in evidence],
        "asr_context_windows": _context_windows(evidence_refs, registry["evidence"]),
        "pass3e_fragments": _relevant_3e_fragments(candidates, registry["derived_fragments"]),
    }


def build_groups(
    registry: dict[str, Any],
    candidates_doc: dict[str, Any],
    *,
    max_candidates: int = DEFAULT_MAX_CANDIDATES,
    max_input_chars: int = DEFAULT_MAX_INPUT_CHARS,
) -> list[dict[str, Any]]:
    if max_candidates < 1:
        raise ValueError("max_candidates must be at least 1")
    groups: list[list[dict[str, Any]]] = []
    for component in candidate_components(candidates_doc["candidates"]):
        current: list[dict[str, Any]] = []
        for candidate in component:
            trial = current + [candidate]
            packet_size = len(canonical_bytes(build_group_packet(registry, trial)))
            if current and (len(trial) > max_candidates or packet_size > max_input_chars):
                groups.append(current)
                current = [candidate]
            else:
                current = trial
            if len(canonical_bytes(build_group_packet(registry, current))) > max_input_chars:
                raise ValueError(f"candidate {candidate['candidate_id']} exceeds max_input_chars alone")
        if current:
            groups.append(current)
    result = []
    for index, group in enumerate(groups, 1):
        packet = build_group_packet(registry, group)
        result.append({
            "group_id": f"group_{index:03d}",
            "packet": packet,
            "input_hash": sha256_bytes(canonical_bytes(packet)),
            "estimated_input_tokens": estimate_tokens(canonical_bytes(packet).decode("utf-8")),
        })
    return result


def user_prompt(packet: dict[str, Any]) -> str:
    return (
        "Audite chaque candidat du paquet ci-dessous. Réponds avec exactement cette racine JSON : "
        "{\"proposals\":[...]}. Chaque objet doit respecter les champs imposés dans le candidat et les règles système.\n\n"
        + json.dumps(packet, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    )


def build_context_budget_plan(
    groups: list[dict[str, Any]],
    *,
    max_tokens: int,
    n_ctx: int | None = None,
    safety_margin_tokens: int = DEFAULT_SAFETY_MARGIN_TOKENS,
) -> dict[str, Any]:
    if max_tokens < 1 or safety_margin_tokens < 0:
        raise ValueError("invalid context budget parameters")
    if n_ctx is not None and n_ctx < 1:
        raise ValueError("n_ctx must be positive when supplied")
    system_tokens = estimate_tokens(SYSTEM_PROMPT)
    rows = []
    for group in groups:
        prompt = user_prompt(group["packet"])
        user_tokens = estimate_tokens(prompt)
        theoretical_total = system_tokens + user_tokens + max_tokens
        required = theoretical_total + safety_margin_tokens
        rows.append({
            "group_id": group["group_id"],
            "candidate_ids": [item["candidate_id"] for item in group["packet"]["candidates"]],
            "system_prompt_tokens_estimated": system_tokens,
            "user_payload_tokens_estimated": user_tokens,
            "requested_output_tokens": max_tokens,
            "theoretical_total_tokens": theoretical_total,
            "safety_margin_tokens": safety_margin_tokens,
            "required_context_tokens": required,
            "n_ctx": n_ctx,
            "remaining_tokens_after_theoretical_total": None if n_ctx is None else n_ctx - theoretical_total,
            "fits_with_safety_margin": None if n_ctx is None else required <= n_ctx,
        })
    return {
        "schema": "pass3f.audit.context-plan.v1",
        "token_estimator": "ceil(unicode_codepoints/4)",
        "n_ctx": n_ctx,
        "requested_output_tokens": max_tokens,
        "safety_margin_tokens": safety_margin_tokens,
        "groups": rows,
    }


def context_split_design() -> dict[str, Any]:
    return {
        "schema": "pass3f.audit.split-design.v1",
        "unit": "candidate_bundle",
        "atomic_fields": [
            "candidate", "subject_definitions", "direct_evidence",
            "asr_context_windows", "direct_fragment_refs", "truncation_context",
        ],
        "algorithm": [
            "split an oversized multi-candidate group only at candidate_bundle boundaries",
            "recompute exact packet estimates after each deterministic split",
            "if one candidate bundle is oversized, keep its atomic fields in every shard",
            "partition only supplemental ranked 3E fragments into deterministic fragment_id-ordered shards",
            "emit stable shard_id from run_id, candidate_id and included supplemental fragment_ids",
            "consolidate shard proposals later by candidate_id without changing evidence_id or fragment_id",
        ],
        "oversized_atomic_bundle": "fail explicitly; never truncate a candidate or its direct evidence",
    }


def _load_output_schema(schema_path: Path) -> dict[str, Any]:
    schema = read_json(schema_path)
    if schema.get("properties", {}).get("schema", {}).get("const") != SCHEMA_VERSION:
        raise ValueError("unsupported Pass3F-A output schema")
    return schema


def _validate_proposal_shape(proposal: Any) -> None:
    if not isinstance(proposal, dict) or set(proposal) != _PROPOSAL_KEYS:
        raise ValueError("proposal fields do not match the strict Pass3F-A contract")
    for key, pattern in _ID_PATTERNS.items():
        if not isinstance(proposal[key], str) or not pattern.fullmatch(proposal[key]):
            raise ValueError(f"invalid {key}")
    if proposal["action"] not in ACTIONS or proposal["origin_stage"] not in ORIGIN_STAGES:
        raise ValueError("unsupported action or origin_stage")
    if not isinstance(proposal["source_subject"], str):
        raise ValueError("source_subject must be a string")
    if proposal["target_subject"] is not None and not isinstance(proposal["target_subject"], str):
        raise ValueError("target_subject must be a string or null")
    for key in ("source_fragment_ids", "evidence_refs", "original_pass1_subjects"):
        values = proposal[key]
        if not isinstance(values, list) or not all(isinstance(value, str) for value in values) or len(values) != len(set(values)):
            raise ValueError(f"{key} must be a unique string array")
    if not isinstance(proposal["reason"], str) or not proposal["reason"].strip():
        raise ValueError("reason must be non-empty")
    confidence = proposal["confidence"]
    if isinstance(confidence, bool) or not isinstance(confidence, (int, float)) or not 0 <= confidence <= 1:
        raise ValueError("confidence must be between 0 and 1")
    if not isinstance(proposal["ambiguous"], bool) or proposal["requires_human_review"] is not True:
        raise ValueError("boolean review fields violate the contract")
    context = proposal["truncation_context"]
    if not isinstance(context, dict) or set(context) != {"subjects", "fragments", "caution"}:
        raise ValueError("invalid truncation_context")
    if not isinstance(context["subjects"], list) or not context["subjects"]:
        raise ValueError("truncation_context.subjects must be non-empty")
    if not isinstance(context["fragments"], list) or not isinstance(context["caution"], str):
        raise ValueError("invalid truncation context values")


def parse_and_validate_response(
    raw_content: str,
    packet: dict[str, Any],
    output_schema: dict[str, Any],
) -> dict[str, Any]:
    parsed = json.loads(raw_content)
    if not isinstance(parsed, dict) or set(parsed) != {"proposals"} or not isinstance(parsed["proposals"], list):
        raise ValueError("response root must contain only a proposals array")
    for proposal in parsed["proposals"]:
        _validate_proposal_shape(proposal)
    expected = {item["candidate_id"]: item for item in packet["candidates"]}
    actual = {item["candidate_id"]: item for item in parsed["proposals"]}
    if len(actual) != len(parsed["proposals"]) or set(actual) != set(expected):
        raise ValueError("response must contain exactly one proposal per candidate_id")
    allowed_subjects = set(packet["allowed_subject_ids"])
    for candidate_id, proposal in actual.items():
        candidate = expected[candidate_id]
        if proposal["proposal_id"] != candidate["proposal_id"]:
            raise ValueError(f"proposal_id mismatch for {candidate_id}")
        if proposal["source_subject"] not in allowed_subjects:
            raise ValueError(f"invented source subject for {candidate_id}")
        target = proposal["target_subject"]
        if target is not None and target not in allowed_subjects:
            raise ValueError(f"invented target subject for {candidate_id}")
        if not set(proposal["source_fragment_ids"]).issubset(candidate["allowed_fragment_ids"]):
            raise ValueError(f"invented fragment reference for {candidate_id}")
        if not set(proposal["evidence_refs"]).issubset(candidate["allowed_evidence_refs"]):
            raise ValueError(f"invented evidence reference for {candidate_id}")
        if not set(proposal["original_pass1_subjects"]).issubset(candidate["original_pass1_subjects"]):
            raise ValueError(f"invented Pass1 assignment for {candidate_id}")
        if proposal["truncation_context"] != candidate["truncation_context"]:
            raise ValueError(f"truncation context was altered for {candidate_id}")
        if proposal["action"] in {"move", "merge", "remove_duplicate"} and target is None:
            raise ValueError(f"action {proposal['action']} requires a target for {candidate_id}")
        if proposal["action"] not in ACTIONS or proposal["origin_stage"] not in ORIGIN_STAGES:
            raise ValueError(f"unsupported classification for {candidate_id}")
        if not proposal["requires_human_review"]:
            raise ValueError(f"human review cannot be disabled for {candidate_id}")
        statuses = {
            item["status"] for item in proposal["truncation_context"]["subjects"]
        } | {
            item["status"] for item in proposal["truncation_context"]["fragments"]
        }
        if not proposal["evidence_refs"] and "unknown" in statuses and proposal["confidence"] > 0.7:
            raise ValueError(f"confidence too high with unknown truncation and no evidence for {candidate_id}")
    parsed["proposals"] = [actual[item["candidate_id"]] for item in packet["candidates"]]
    return parsed


Transport = Callable[[urllib.request.Request, int], bytes]


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, "redirect forbidden in local-strict mode", headers, fp)


def _default_transport(request: urllib.request.Request, timeout: int, *, allow_redirects: bool) -> bytes:
    opener = urllib.request.build_opener() if allow_redirects else urllib.request.build_opener(_NoRedirect)
    with opener.open(request, timeout=timeout) as response:
        return response.read()


def assert_local_api_base(api_base: str) -> None:
    parsed = urllib.parse.urlparse(api_base)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname or parsed.username or parsed.password:
        raise ValueError("local-strict mode requires a plain HTTP(S) API base")
    hostname = parsed.hostname.casefold()
    if hostname in {"localhost", "openai-adapter"}:
        return
    try:
        address = ipaddress.ip_address(hostname)
    except ValueError as exc:
        raise ValueError(f"non-local API host forbidden in local-strict mode: {hostname}") from exc
    if not (address.is_private or address.is_loopback or address.is_link_local):
        raise ValueError(f"non-local API address forbidden in local-strict mode: {hostname}")


def validate_reported_local_model(envelope: dict[str, Any], requested_model: str) -> str:
    allowed = LOCAL_STRICT_MODELS.get(requested_model)
    if not allowed:
        raise ValueError(f"model is not approved for local-strict mode: {requested_model}")
    reported = str(envelope.get("model") or "").strip()
    if not reported:
        raise ValueError("local-strict response does not report the model used")
    if reported not in allowed:
        raise ValueError(f"silent model change blocked: requested={requested_model} reported={reported}")
    return reported


def call_openai_compatible(
    *,
    api_base: str,
    api_key: str,
    model: str,
    temperature: float,
    max_tokens: int,
    system: str,
    user: str,
    packet: dict[str, Any],
    output_schema: dict[str, Any],
    timeout: int = 600,
    max_attempts: int = 3,
    local_strict: bool = False,
    transport: Transport | None = None,
    sleeper: Callable[[float], None] = time.sleep,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    if local_strict:
        assert_local_api_base(api_base)
        if model not in LOCAL_STRICT_MODELS:
            raise ValueError(f"local-strict mode forbids model: {model}")
    request_body = {
        "model": model,
        "temperature": temperature,
        "max_tokens": max_tokens,
        "response_format": {"type": "json_object"},
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
    }
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    request = urllib.request.Request(
        api_base.rstrip("/") + "/v1/chat/completions",
        data=canonical_bytes(request_body),
        headers=headers,
        method="POST",
    )
    failures: list[str] = []
    for attempt in range(1, max_attempts + 1):
        try:
            transport_raw = (
                transport(request, timeout)
                if transport is not None
                else _default_transport(request, timeout, allow_redirects=not local_strict)
            )
            if not isinstance(transport_raw, bytes):
                raise TypeError("transport must return the exact HTTP response body as bytes")
            transport_text = transport_raw.decode("utf-8-sig")
            transport_response = json.loads(transport_text)
            reported_model = validate_reported_local_model(transport_response, model) if local_strict else str(transport_response.get("model") or "")
            adapter_message_content = str(transport_response["choices"][0]["message"]["content"])
            parsed = parse_and_validate_response(adapter_message_content, packet, output_schema)
            return {
                "request": request_body,
                "transport_raw_bytes": transport_raw,
                "transport_raw_text": transport_text,
                "transport_response": transport_response,
                "adapter_message_content": adapter_message_content,
                "reported_model": reported_model,
                "parsed": parsed,
                "attempt_count": attempt,
            }, [{"attempt": index + 1, "error": value} for index, value in enumerate(failures)]
        except (json.JSONDecodeError, KeyError, IndexError, TypeError, ValueError) as exc:
            failures.append(f"json_contract_error: {type(exc).__name__}: {exc}")
        except urllib.error.HTTPError as exc:
            failures.append(f"http_error: {exc.code}: {exc.reason}")
            if exc.code < 500 and exc.code != 429:
                raise RuntimeError(failures[-1]) from exc
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            failures.append(f"network_error: {type(exc).__name__}: {exc}")
        if attempt < max_attempts:
            sleeper(min(10.0, float(2 ** (attempt - 1))))
    raise RuntimeError(f"Pass3F-A failed after {max_attempts} attempts: {failures[-1]}")


def _safe_write_text(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value, encoding="utf-8", newline="\n")


def run_audit(
    registry: dict[str, Any],
    candidates_doc: dict[str, Any],
    output_dir: Path,
    *,
    schema_path: Path,
    api_base: str,
    api_key: str,
    model: str = DEFAULT_MODEL,
    temperature: float = DEFAULT_TEMPERATURE,
    max_tokens: int = DEFAULT_MAX_TOKENS,
    max_candidates: int = DEFAULT_MAX_CANDIDATES,
    max_input_chars: int = DEFAULT_MAX_INPUT_CHARS,
    timeout: int = 600,
    max_attempts: int = 3,
    n_ctx: int | None = None,
    safety_margin_tokens: int = DEFAULT_SAFETY_MARGIN_TOKENS,
    local_strict: bool = False,
    transport: Transport | None = None,
    sleeper: Callable[[float], None] = time.sleep,
) -> dict[str, Any]:
    if registry.get("schema") != "pass3f.provenance.v1":
        raise ValueError("unsupported provenance registry schema")
    if candidates_doc.get("schema") != "pass3f.candidates.v1":
        raise ValueError("unsupported candidates schema")
    if candidates_doc.get("source_registry_hash") != stable_id("registry", registry):
        raise ValueError("candidates.json does not match provenance_registry.json")
    output_dir = Path(output_dir)
    if output_dir.name in PROTECTED_OUTPUT_NAMES:
        raise ValueError("output_dir cannot name a protected upstream artifact")
    output_schema = _load_output_schema(schema_path)
    groups = build_groups(
        registry, candidates_doc,
        max_candidates=max_candidates,
        max_input_chars=max_input_chars,
    )
    context_plan = build_context_budget_plan(
        groups,
        max_tokens=max_tokens,
        n_ctx=n_ctx,
        safety_margin_tokens=safety_margin_tokens,
    )
    if n_ctx is not None:
        oversized = [item["group_id"] for item in context_plan["groups"] if not item["fits_with_safety_margin"]]
        if oversized:
            raise ValueError(
                "context budget exceeded before any LLM call; deterministic candidate-bundle split required for: "
                + ", ".join(oversized)
            )
    write_json_deterministic(output_dir / "context_budget_plan.json", context_plan)
    write_json_deterministic(output_dir / "context_split_design.json", context_split_design())
    parameters = {
        "temperature": temperature,
        "max_tokens": max_tokens,
        "timeout_seconds": timeout,
        "max_attempts": max_attempts,
        "response_format": "json_object",
        "local_strict": local_strict,
        "n_ctx": n_ctx,
        "safety_margin_tokens": safety_margin_tokens,
    }
    audit_groups = []
    proposals = []
    manifest_groups = []
    for group in groups:
        group_dir = output_dir / "groups" / group["group_id"]
        prompt = user_prompt(group["packet"])
        result, failures = call_openai_compatible(
            api_base=api_base,
            api_key=api_key,
            model=model,
            temperature=temperature,
            max_tokens=max_tokens,
            system=SYSTEM_PROMPT,
            user=prompt,
            packet=group["packet"],
            output_schema=output_schema,
            timeout=timeout,
            max_attempts=max_attempts,
            local_strict=local_strict,
            transport=transport,
            sleeper=sleeper,
        )
        write_json_deterministic(group_dir / "input_packet.json", group["packet"])
        _safe_write_text(group_dir / "system_prompt.txt", SYSTEM_PROMPT)
        _safe_write_text(group_dir / "user_prompt.txt", prompt)
        write_json_deterministic(group_dir / "request.json", result["request"])
        (group_dir / "transport_raw_response.bin").write_bytes(result["transport_raw_bytes"])
        _safe_write_text(group_dir / "transport_raw_response.txt", result["transport_raw_text"])
        write_json_deterministic(group_dir / "transport_response.json", result["transport_response"])
        _safe_write_text(group_dir / "adapter_message_content.txt", result["adapter_message_content"])
        write_json_deterministic(group_dir / "parsed_response.json", result["parsed"])
        group_proposals = result["parsed"]["proposals"]
        proposals.extend(group_proposals)
        usage = result["transport_response"].get("usage") or {}
        audit_groups.append({
            "group_id": group["group_id"],
            "candidate_ids": [item["candidate_id"] for item in group["packet"]["candidates"]],
            "proposal_ids": [item["proposal_id"] for item in group_proposals],
            "input_hash": group["input_hash"],
            "estimated_input_tokens": group["estimated_input_tokens"],
            "reported_model": result["reported_model"],
            "reported_usage": {
                "prompt_tokens": usage.get("prompt_tokens"),
                "completion_tokens": usage.get("completion_tokens"),
                "total_tokens": usage.get("total_tokens"),
            },
        })
        artifact_hashes = {}
        for name in (
            "input_packet.json", "system_prompt.txt", "user_prompt.txt", "request.json",
            "transport_raw_response.bin", "transport_raw_response.txt", "transport_response.json",
            "adapter_message_content.txt", "parsed_response.json",
        ):
            artifact_hashes[name] = sha256_bytes((group_dir / name).read_bytes())
        manifest_groups.append({
            "group_id": group["group_id"],
            "attempt_count": result["attempt_count"],
            "failed_attempts": failures,
            "artifacts": artifact_hashes,
        })
    proposals.sort(key=lambda item: item["proposal_id"])
    audit = {
        "schema": SCHEMA_VERSION,
        "run_id": registry["run"]["run_id"],
        "source_registry_hash": stable_id("registry", registry),
        "source_candidates_hash": stable_id("candidates", candidates_doc),
        "model_alias": model,
        "parameters": parameters,
        "groups": audit_groups,
        "proposals": proposals,
    }
    audit_path = output_dir / "audit_proposals.json"
    write_json_deterministic(audit_path, audit)
    manifest = {
        "schema": MANIFEST_VERSION,
        "model_alias": model,
        "parameters": parameters,
        "hashes": {
            "registry": sha256_bytes(canonical_bytes(registry)),
            "candidates": sha256_bytes(canonical_bytes(candidates_doc)),
            "system_prompt": sha256_text(SYSTEM_PROMPT),
            "audit_proposals": sha256_bytes(audit_path.read_bytes()),
        },
        "model_raw_response": {
            "available": False,
            "reason": "The client observes the OpenAI-compatible transport response after the adapter and local Flask server; neither layer proves that message content is the unmodified model output.",
        },
        "groups": manifest_groups,
    }
    write_json_deterministic(output_dir / "manifest.json", manifest)
    return audit


def _api_key_from_environment() -> str:
    return os.environ.get("PIPELINE_API_KEY") or os.environ.get("ADAPTER_API_KEY") or ""


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", required=True, type=Path)
    parser.add_argument("--candidates", required=True, type=Path)
    parser.add_argument("--out-dir", required=True, type=Path)
    parser.add_argument("--schema", type=Path, default=Path(__file__).resolve().parents[1] / "schemas" / "pass3f_audit.v1.schema.json")
    parser.add_argument("--api-base", default=os.environ.get("PIPELINE_API_BASE", "http://openai-adapter:5055"))
    parser.add_argument("--model", default=os.environ.get("PASS3FA_MODEL", DEFAULT_MODEL))
    parser.add_argument("--temperature", type=float, default=DEFAULT_TEMPERATURE)
    parser.add_argument("--max-tokens", type=int, default=DEFAULT_MAX_TOKENS)
    parser.add_argument("--max-candidates", type=int, default=DEFAULT_MAX_CANDIDATES)
    parser.add_argument("--max-input-chars", type=int, default=DEFAULT_MAX_INPUT_CHARS)
    parser.add_argument("--timeout", type=int, default=600)
    parser.add_argument("--max-attempts", type=int, default=3)
    parser.add_argument("--n-ctx", type=int)
    parser.add_argument("--safety-margin-tokens", type=int, default=DEFAULT_SAFETY_MARGIN_TOKENS)
    parser.add_argument("--local-strict", action="store_true")
    parser.add_argument("--plan-only", action="store_true")
    args = parser.parse_args(argv)
    registry = read_json(args.registry)
    candidates = read_json(args.candidates)
    if args.plan_only:
        groups = build_groups(
            registry, candidates,
            max_candidates=args.max_candidates,
            max_input_chars=args.max_input_chars,
        )
        write_json_deterministic(
            args.out_dir / "context_budget_plan.json",
            build_context_budget_plan(
                groups,
                max_tokens=args.max_tokens,
                n_ctx=args.n_ctx,
                safety_margin_tokens=args.safety_margin_tokens,
            ),
        )
        write_json_deterministic(args.out_dir / "context_split_design.json", context_split_design())
        return 0
    run_audit(
        registry, candidates, args.out_dir,
        schema_path=args.schema,
        api_base=args.api_base,
        api_key=_api_key_from_environment(),
        model=args.model,
        temperature=args.temperature,
        max_tokens=args.max_tokens,
        max_candidates=args.max_candidates,
        max_input_chars=args.max_input_chars,
        timeout=args.timeout,
        max_attempts=args.max_attempts,
        n_ctx=args.n_ctx,
        safety_margin_tokens=args.safety_margin_tokens,
        local_strict=args.local_strict,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
