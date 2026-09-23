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
    user_prompt,
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
        target = candidate["target_subject"]
        if action in {"move", "merge", "remove_duplicate"} and target is None:
            target = next(
                subject_id for subject_id in candidate["allowed_subject_ids"]
                if subject_id != candidate["source_subject"]
            )
        proposals.append({
            "candidate_id": candidate["candidate_id"],
            "action": action,
            "target_subject": target,
            "confidence": 0.62,
            "ambiguous": True,
            "cited_evidence_ids": candidate["allowed_evidence_refs"],
            "reason": "Le même extrait peut légitimement éclairer les deux objets; validation humaine requise.",
        })
    return {"proposals": proposals}


def address_conflict_documents():
    evidence = {
        "evidence_id": stable_id("evidence", "61 avenue Gérardin"),
        "segment_id": "segment_16",
        "row_ref": 16,
        "timecode": "00:16:00",
        "speaker": "P1",
        "exact_text": "61 avenue Gérardin.",
        "pass1_subjects": ["16"],
        "projection_classification": "specifique",
        "reported_subject_count": 1,
    }
    fragment_base = {
        "stage": "3E",
        "subject_id": "16",
        "field_path": "/synthese_echanges/0",
        "text": "Localisation précise au 61 avenue Gérardin",
        "source_artifact": "pass3E_sujets/sujet_016_synthese.json",
    }
    fragment = {
        "fragment_id": stable_id("fragment", fragment_base),
        **fragment_base,
        "links": [{
            "evidence_id": evidence["evidence_id"],
            "link_status": "candidate",
            "method": "token_overlap",
            "score": 0.9,
        }],
        "truncation": truncation("none"),
    }
    registry = {
        "schema": "pass3f.provenance.v1",
        "run": {
            "run_id": stable_id("run", "address-conflict"),
            "pipeline_kind": "generaliste",
            "input_hashes": {"global.json": "c" * 64},
        },
        "subjects": [{
            "subject_id": "16",
            "numero": 16,
            "title": "État descriptif technique du 61 rue de Malleville",
            "location": "61 rue de Malleville",
            "description": "Référentiel canonique S16",
            "truncation": truncation("none"),
        }],
        "evidence": [evidence],
        "truncation_events": [],
        "derived_fragments": [fragment],
        "stats": {},
    }
    candidate = {
        "ambiguous": True,
        "candidate_id": stable_id("candidate", "address-conflict"),
        "evidence_refs": [evidence["evidence_id"]],
        "excerpt": "Localisation précise au 61 avenue Gérardin",
        "fragment_refs": [fragment["fragment_id"]],
        "kind": "subject_reference_conflict",
        "requires_llm_review": True,
        "score": 0.9,
        "signals": ["address conflict"],
        "source_subject": "16",
        "target_subject": None,
    }
    return registry, build_group_packet(registry, [candidate])


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
        self.assertIn("Pass1 sont des données historiques à auditer", SYSTEM_PROMPT)
        self.assertIn("ne prouvent jamais que l'affectation est correcte", SYSTEM_PROMPT)
        self.assertIn("conflit explicite d'adresse, lieu, acteur ou objet", SYSTEM_PROMPT)

    def test_strict_parser_rejects_markdown_invented_target_and_evidence(self):
        packet = build_group_packet(self.registry, [self.candidates["candidates"][0]])
        parsed = valid_response(packet)
        with self.assertRaises(json.JSONDecodeError):
            parse_and_validate_response("```json\n" + json.dumps(parsed) + "\n```", packet, self.schema)
        parsed["proposals"][0]["target_subject"] = "999"
        with self.assertRaises(ValueError):
            parse_and_validate_response(json.dumps(parsed), packet, self.schema)
        parsed = valid_response(packet)
        parsed["proposals"][0]["cited_evidence_ids"] = ["evidence:" + "f" * 64]
        with self.assertRaises(ValueError):
            parse_and_validate_response(json.dumps(parsed), packet, self.schema)

    def test_python_enriches_final_contract_and_forces_human_review(self):
        source = next(item for item in self.candidates["candidates"] if item["target_subject"] is not None)
        packet = build_group_packet(self.registry, [source])
        candidate = packet["candidates"][0]
        for action in ("move", "merge", "remove_duplicate"):
            final = parse_and_validate_response(
                json.dumps(valid_response(packet, action=action)), packet, self.schema,
            )["proposals"][0]
            self.assertEqual(set(final), self.schema["$defs"]["proposal"]["properties"].keys())
            self.assertEqual(final["proposal_id"], candidate["proposal_id"])
            self.assertEqual(final["source_subject"], candidate["source_subject"])
            self.assertEqual(final["source_fragment_ids"], sorted(candidate["fragment_refs"]))
            self.assertEqual(final["original_pass1_subjects"], candidate["original_pass1_subjects"])
            self.assertEqual(final["truncation_context"], candidate["truncation_context"])
            self.assertEqual(final["origin_stage"], "indeterminate")
            self.assertTrue(final["requires_human_review"])

    def test_pass1_assignment_cannot_resolve_explicit_address_conflict(self):
        _registry, packet = address_conflict_documents()
        candidate = packet["candidates"][0]
        prompt = user_prompt(packet)
        self.assertEqual(packet["pass1_assignments_role"], "historical_audit_input_not_correctness_evidence")
        self.assertIn("61 rue de Malleville", prompt)
        self.assertIn("61 avenue Gérardin", prompt)
        decision = {
            "proposals": [{
                "candidate_id": candidate["candidate_id"],
                "action": "no_action",
                "target_subject": None,
                "confidence": 0.9,
                "ambiguous": False,
                "cited_evidence_ids": candidate["allowed_evidence_refs"],
                "reason": "Pass1 avait affecté la preuve à S16.",
            }],
        }
        with self.assertRaisesRegex(ValueError, "must remain ambiguous"):
            parse_and_validate_response(json.dumps(decision), packet, self.schema)
        decision["proposals"][0]["ambiguous"] = True
        final = parse_and_validate_response(json.dumps(decision), packet, self.schema)["proposals"][0]
        self.assertEqual(final["source_subject"], "16")
        self.assertEqual(final["original_pass1_subjects"], ["16"])
        self.assertTrue(final["ambiguous"])

    def test_invalid_contract_preserves_raw_response_before_raising_without_retry(self):
        seen = []
        invalid_response = response_bytes({"wrong": []})

        def transport(request, _timeout):
            seen.append(request.data)
            return invalid_response

        with tempfile.TemporaryDirectory() as tmp:
            output_dir = Path(tmp) / "pass3f"
            with self.assertRaises(RuntimeError) as caught:
                run_audit(
                    self.registry, self.candidates, output_dir,
                    schema_path=SCHEMA_PATH, api_base="http://example.invalid", api_key="secret",
                    max_candidates=1, max_attempts=3, transport=transport,
                    sleeper=lambda _delay: None,
                )
            self.assertIn("contract validation failed", str(caught.exception))
            self.assertEqual(len(seen), 1)
            group_dir = output_dir / "groups" / "group_001"
            self.assertEqual((group_dir / "transport_raw_response.txt").read_bytes(), invalid_response)
            self.assertEqual(
                (group_dir / "attempts" / "attempt_001" / "transport_raw_response.txt").read_bytes(),
                invalid_response,
            )
            metadata = json.loads((group_dir / "transport_metadata.json").read_text(encoding="utf-8"))
            self.assertEqual(metadata["http_status"], 200)
            self.assertEqual(metadata["model_declared"], "Gemma_4_12B_It_Q4_K_M")
            self.assertEqual(metadata["finish_reason"], "stop")
            self.assertEqual(metadata["attempt"], 1)
            self.assertEqual(metadata["model_alias"], DEFAULT_MODEL)
            self.assertEqual(metadata["endpoint_local"], "http://example.invalid/v1/chat/completions")
            self.assertGreaterEqual(metadata["duration_seconds"], 0)
            contract_error = json.loads((group_dir / "contract_error.json").read_text(encoding="utf-8"))
            self.assertEqual(contract_error["error_type"], "ValueError")
            self.assertIn("proposals array", contract_error["detail"])
            self.assertFalse((group_dir / "parsed_response.json").exists())

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
