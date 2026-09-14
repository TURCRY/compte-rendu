import json
import sys
import tempfile
import unittest
from pathlib import Path

from jsonschema import Draft202012Validator


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "pipeline" / "python"))

from pass3f_audit import (  # noqa: E402
    DEFAULT_MODEL,
    SYSTEM_PROMPT,
    assert_local_api_base,
    build_context_budget_plan,
    build_group_packet,
    build_groups,
    call_openai_compatible,
    parse_and_validate_response,
    run_audit,
)
from pass3f_candidates import build_candidates  # noqa: E402
from pass3f_provenance import stable_id, write_json_deterministic  # noqa: E402


SCHEMA_PATH = ROOT / "pipeline" / "schemas" / "pass3f_audit.v1.schema.json"


def truncation(status="none", scope="subject"):
    return {
        "status": status,
        "stage": "2E",
        "scope": scope,
        "source_file": "logs/run.log",
        "source_hash": "a" * 64,
        "details": "fixture",
        "event_refs": [],
    }


def fixture_documents():
    evidence = []
    for row, subjects, text in (
        (10, ["1", "2"], "Une fissure verticale est décrite au droit de la fenêtre."),
        (11, ["1"], "Le technicien confirme une réserve sur la largeur de la fissure."),
        (20, ["2", "3"], "Le stationnement gêne l'accès au mur mitoyen."),
    ):
        locator = {
            "segment_id": "segment_01",
            "row_ref": row,
            "timecode": f"00:00:{row}",
            "speaker": "Expert",
            "exact_text": text,
        }
        evidence.append({
            "evidence_id": stable_id("evidence", locator),
            **locator,
            "pass1_subjects": subjects,
            "projection_classification": "specifique",
            "reported_subject_count": len(subjects),
        })
    subjects = [
        {"subject_id": "1", "numero": 1, "title": "Fissures", "location": "10 rue Alpha", "description": "Façade", "truncation": truncation("confirmed")},
        {"subject_id": "2", "numero": 2, "title": "Menuiseries", "location": "10 rue Alpha", "description": "Fenêtres", "truncation": truncation("none")},
        {"subject_id": "3", "numero": 3, "title": "Mitoyenneté", "location": "12 rue Beta", "description": "Parking", "truncation": truncation("unknown", "unknown")},
        {"subject_id": "99", "numero": 99, "title": "Sujet sans rapport", "location": "", "description": "", "truncation": truncation("none")},
    ]
    fragments = []
    for stage, subject_id, text, link in (
        ("3E", "1", "La fissure verticale est examinée.", evidence[0]),
        ("3E", "2", "La fissure est mentionnée avec les fenêtres.", evidence[0]),
        ("3E", "3", "Le parking gêne l'accès au mur mitoyen.", evidence[2]),
        ("3E", "99", "Information étrangère au groupe.", evidence[1]),
    ):
        base = {
            "stage": stage,
            "subject_id": subject_id,
            "field_path": "/synthese_echanges/0",
            "text": text,
            "source_artifact": f"pass3E_sujets/sujet_{int(subject_id):03d}_synthese.json",
        }
        fragments.append({
            "fragment_id": stable_id("fragment", base),
            **base,
            "links": [{"evidence_id": link["evidence_id"], "link_status": "candidate", "method": "token_overlap", "score": 0.8}],
            "truncation": truncation("possible" if subject_id == "1" else ("unknown" if subject_id == "3" else "none"), "subject" if subject_id != "3" else "unknown"),
        })
    registry = {
        "schema": "pass3f.provenance.v1",
        "run": {"run_id": stable_id("run", "fixture"), "pipeline_kind": "generaliste", "input_hashes": {"global.json": "b" * 64}},
        "subjects": subjects,
        "evidence": evidence,
        "truncation_events": [],
        "derived_fragments": fragments,
        "stats": {},
    }
    candidates = build_candidates(registry)
    return registry, candidates


def valid_response(packet, *, action="retain_overlap"):
    proposals = []
    for candidate in packet["candidates"]:
        proposals.append({
            "proposal_id": candidate["proposal_id"],
            "candidate_id": candidate["candidate_id"],
            "action": action,
            "source_subject": candidate["source_subject"],
            "target_subject": candidate["target_subject"],
            "source_fragment_ids": candidate["allowed_fragment_ids"],
            "evidence_refs": candidate["allowed_evidence_refs"],
            "original_pass1_subjects": candidate["original_pass1_subjects"],
            "origin_stage": "pass1",
            "reason": "Le même extrait peut légitimement éclairer les deux objets; validation humaine requise.",
            "confidence": 0.62,
            "ambiguous": True,
            "requires_human_review": True,
            "truncation_context": json.loads(json.dumps(candidate["truncation_context"])),
        })
    return {"proposals": proposals}


def response_envelope(parsed, *, prompt_tokens=1000, completion_tokens=300):
    return {
        "id": "fixture",
        "model": "gpt-5-mini",
        "choices": [{"finish_reason": "stop", "message": {"content": json.dumps(parsed, ensure_ascii=False)}}],
        "usage": {"prompt_tokens": prompt_tokens, "completion_tokens": completion_tokens, "total_tokens": prompt_tokens + completion_tokens},
    }


def response_bytes(parsed, *, model="Gemma_4_12B_It_Q4_K_M"):
    value = response_envelope(parsed)
    value["model"] = model
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


class Pass3FAuditTest(unittest.TestCase):
    def setUp(self):
        self.registry, self.candidates = fixture_documents()
        self.schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))

    def test_group_packet_is_bounded_and_excludes_unrelated_subject(self):
        candidate = next(item for item in self.candidates["candidates"] if item["kind"] == "shared_evidence")
        packet = build_group_packet(self.registry, [candidate])
        self.assertNotIn("99", packet["allowed_subject_ids"])
        self.assertNotIn("Information étrangère", json.dumps(packet, ensure_ascii=False))
        self.assertEqual(len(packet["candidates"]), 1)
        self.assertTrue(packet["asr_context_windows"])
        self.assertTrue(all(item["stage"] == "3E" for item in packet["pass3e_fragments"]))
        self.assertTrue(packet["candidates"][0]["allowed_fragment_ids"])
        self.assertEqual(
            set(packet["candidates"][0]["allowed_fragment_ids"]),
            {item["fragment_id"] for item in packet["pass3e_fragments"]},
        )

    def test_groups_are_deterministic_and_respect_candidate_limit(self):
        first = build_groups(self.registry, self.candidates, max_candidates=1)
        second = build_groups(self.registry, self.candidates, max_candidates=1)
        self.assertEqual(first, second)
        self.assertTrue(all(len(item["packet"]["candidates"]) == 1 for item in first))
        observed = [candidate["candidate_id"] for group in first for candidate in group["packet"]["candidates"]]
        self.assertEqual(sorted(observed), sorted(item["candidate_id"] for item in self.candidates["candidates"]))

    def test_prompt_contains_provenance_and_truncation_guards(self):
        self.assertIn("candidate ou unresolved ne devient jamais verified", SYSTEM_PROMPT)
        self.assertIn("troncature possible", SYSTEM_PROMPT)
        self.assertIn("requires_human_review=true", SYSTEM_PROMPT)

    def test_strict_parser_rejects_markdown_and_invented_target(self):
        packet = build_group_packet(self.registry, [self.candidates["candidates"][0]])
        parsed = valid_response(packet)
        with self.assertRaises(json.JSONDecodeError):
            parse_and_validate_response("```json\n" + json.dumps(parsed) + "\n```", packet, self.schema)
        parsed["proposals"][0]["target_subject"] = "999"
        with self.assertRaises(ValueError):
            parse_and_validate_response(json.dumps(parsed), packet, self.schema)

    def test_parser_rejects_altered_truncation_and_disabled_review(self):
        packet = build_group_packet(self.registry, [self.candidates["candidates"][0]])
        parsed = valid_response(packet)
        parsed["proposals"][0]["truncation_context"]["caution"] = "invented"
        with self.assertRaises(ValueError):
            parse_and_validate_response(json.dumps(parsed), packet, self.schema)
        parsed = valid_response(packet)
        parsed["proposals"][0]["requires_human_review"] = False
        with self.assertRaises(Exception):
            parse_and_validate_response(json.dumps(parsed), packet, self.schema)

    def test_json_failure_retries_same_request_without_repair(self):
        packet = build_group_packet(self.registry, [self.candidates["candidates"][0]])
        seen = []

        def transport(request, _timeout):
            seen.append(request.data)
            if len(seen) == 1:
                return response_bytes({"wrong": []})
            return response_bytes(valid_response(packet))

        result, failures = call_openai_compatible(
            api_base="http://example.invalid", api_key="secret", model=DEFAULT_MODEL,
            temperature=0.1, max_tokens=1000, system=SYSTEM_PROMPT, user="fixture",
            packet=packet, output_schema=self.schema, transport=transport, sleeper=lambda _delay: None,
        )
        self.assertEqual(result["attempt_count"], 2)
        self.assertEqual(seen[0], seen[1])
        self.assertEqual(len(failures), 1)
        self.assertIn("json_contract_error", failures[0]["error"])

    def test_run_writes_auditable_package_and_leaves_inputs_unchanged(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            registry_path = root / "provenance_registry.json"
            candidates_path = root / "candidates.json"
            write_json_deterministic(registry_path, self.registry)
            write_json_deterministic(candidates_path, self.candidates)
            before = (registry_path.read_bytes(), candidates_path.read_bytes())

            def transport(request, _timeout):
                body = json.loads(request.data)
                packet = json.loads(body["messages"][1]["content"].split("\n\n", 1)[1])
                return response_bytes(valid_response(packet))

            audit = run_audit(
                self.registry, self.candidates, root / "pass3f",
                schema_path=SCHEMA_PATH, api_base="http://example.invalid", api_key="secret",
                max_candidates=1, transport=transport, sleeper=lambda _delay: None,
            )
            Draft202012Validator(self.schema).validate(audit)
            self.assertEqual(before, (registry_path.read_bytes(), candidates_path.read_bytes()))
            self.assertTrue((root / "pass3f" / "audit_proposals.json").is_file())
            self.assertTrue((root / "pass3f" / "manifest.json").is_file())
            group_dir = root / "pass3f" / "groups" / "group_001"
            for name in ("input_packet.json", "system_prompt.txt", "user_prompt.txt", "request.json", "transport_raw_response.bin", "transport_raw_response.txt", "transport_response.json", "adapter_message_content.txt", "parsed_response.json"):
                self.assertTrue((group_dir / name).is_file(), name)
            manifest = json.loads((root / "pass3f" / "manifest.json").read_text(encoding="utf-8"))
            self.assertRegex(manifest["hashes"]["audit_proposals"], r"^[0-9a-f]{64}$")
            self.assertFalse(manifest["model_raw_response"]["available"])
            self.assertNotIn("model_raw_response.txt", {item.name for item in group_dir.iterdir()})

    def test_context_budget_plan_is_deterministic_and_keeps_n_ctx_unknown(self):
        groups = build_groups(self.registry, self.candidates, max_candidates=1)
        first = build_context_budget_plan(groups, max_tokens=3000)
        second = build_context_budget_plan(groups, max_tokens=3000)
        self.assertEqual(first, second)
        self.assertIsNone(first["n_ctx"])
        for row in first["groups"]:
            self.assertEqual(
                row["theoretical_total_tokens"],
                row["system_prompt_tokens_estimated"] + row["user_payload_tokens_estimated"] + 3000,
            )
            self.assertIsNone(row["fits_with_safety_margin"])

    def test_local_strict_forwards_parameters_and_preserves_transport_bytes(self):
        packet = build_group_packet(self.registry, [self.candidates["candidates"][0]])
        expected = response_bytes(valid_response(packet))
        requests = []

        def transport(request, _timeout):
            requests.append(json.loads(request.data))
            return expected

        result, _failures = call_openai_compatible(
            api_base="http://openai-adapter:5055", api_key="secret", model="local-gemma-4",
            temperature=0.1, max_tokens=3000, system=SYSTEM_PROMPT, user="fixture",
            packet=packet, output_schema=self.schema, local_strict=True,
            transport=transport, sleeper=lambda _delay: None,
        )
        self.assertEqual(result["transport_raw_bytes"], expected)
        self.assertEqual(result["reported_model"], "Gemma_4_12B_It_Q4_K_M")
        self.assertEqual(requests[0]["temperature"], 0.1)
        self.assertEqual(requests[0]["max_tokens"], 3000)
        self.assertEqual(requests[0]["response_format"], {"type": "json_object"})
        self.assertEqual([item["role"] for item in requests[0]["messages"]], ["system", "user"])

    def test_local_strict_blocks_public_url_and_silent_model_change(self):
        with self.assertRaises(ValueError):
            assert_local_api_base("https://api.openai.com/v1")
        with self.assertRaises(ValueError):
            assert_local_api_base("http://unapproved-service:5055")
        packet = build_group_packet(self.registry, [self.candidates["candidates"][0]])
        with self.assertRaises(RuntimeError) as caught:
            call_openai_compatible(
                api_base="http://openai-adapter:5055", api_key="secret", model="local-gemma-4",
                temperature=0.1, max_tokens=3000, system=SYSTEM_PROMPT, user="fixture",
                packet=packet, output_schema=self.schema, local_strict=True, max_attempts=1,
                transport=lambda _request, _timeout: response_bytes(valid_response(packet), model="gpt-5-mini"),
                sleeper=lambda _delay: None,
            )
        self.assertIn("silent model change blocked", str(caught.exception))

    def test_output_schema_is_strict_and_default_alias_is_generic(self):
        self.assertFalse(self.schema["additionalProperties"])
        self.assertFalse(self.schema["$defs"]["proposal"]["additionalProperties"])
        self.assertEqual(DEFAULT_MODEL, "pass3_remote")


if __name__ == "__main__":
    unittest.main()
