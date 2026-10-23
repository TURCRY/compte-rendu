import copy
import csv
import hashlib
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

from jsonschema import Draft202012Validator


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "pipeline" / "python"))

from photo_context_resolver import (  # noqa: E402
    AsrContextItem,
    PhotoContextResolverError,
    SourceSelection,
    build_context_snapshot,
    resolve_photo_context,
    validate_photo_context_bundle,
)


SCHEMA_PATH = ROOT / "pipeline" / "schemas" / "pass3f_provenance.v2.schema.json"
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "photo_context"
INPUT_FILES = (
    "photos.csv",
    "photos_batch.csv",
    "photo_subject_assignments.json",
    "asr_context.json",
)


def load_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def asr_items():
    return [
        AsrContextItem(
            evidence_id=item["evidence_id"],
            row_ref=item.get("row_ref"),
            start_sec=item.get("start_sec"),
            end_sec=item.get("end_sec"),
            subject_numeros=tuple(item.get("subject_numeros") or ()),
            timecode=item.get("timecode", ""),
        )
        for item in load_json(FIXTURES / "asr_context.json")
    ]


def selection(root: Path, *, include_file_status: bool = False) -> SourceSelection:
    return SourceSelection(
        photos_csv=root / "photos.csv",
        assignments_json=root / "photo_subject_assignments.json",
        photos_batch_csv=root / "photos_batch.csv",
        photo_root=root / "images",
        include_file_status=include_file_status,
    )


def resolve_fixture(root: Path = FIXTURES):
    return resolve_photo_context(
        selection(root),
        editorial_subject_numero=6,
        asr_context=asr_items(),
    )


def copy_inputs(destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    for name in INPUT_FILES:
        shutil.copyfile(FIXTURES / name, destination / name)


class PhotoContextResolverTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.schema = load_json(SCHEMA_PATH)
        cls.bundle = resolve_fixture()
        cls.photos = {item["photo_id"]: item for item in cls.bundle["photos"]}

    def assert_definition_valid(self, value, definition: str):
        wrapper = {
            "$schema": self.schema["$schema"],
            "$defs": self.schema["$defs"],
            "$ref": f"#/$defs/{definition}",
        }
        errors = list(Draft202012Validator(wrapper).iter_errors(value))
        self.assertEqual([], [error.message for error in errors])

    def test_nominal_bundle_is_contract_valid_and_uses_p1a_definitions(self):
        self.assertEqual([], validate_photo_context_bundle(self.bundle))
        self.assert_definition_valid(self.bundle["photo_exclusions"][0], "photo_exclusion")
        for photo in self.bundle["photos"]:
            self.assert_definition_valid(photo["subject_scope"], "subject_scope")
            self.assert_definition_valid(photo["assignment"], "photo_assignment")
            self.assert_definition_valid(photo["asr_context"], "photo_asr_context")
            self.assert_definition_valid(photo["content_components"], "content_components")
        snapshot = build_context_snapshot(
            self.bundle,
            pipeline_kind="refere",
            subject_scope={
                "photo_subject_numero": 6,
                "asr_subject_numeros": [10, 11],
                "editorial_subject_numero": 6,
            },
        )
        self.assert_definition_valid(snapshot, "context_snapshot")

    def test_human_assignment_states_are_preserved(self):
        self.assertEqual("assigned", self.photos["JPG/A.jpg"]["assignment"]["status"])
        self.assertEqual("excluded", self.photos["JPG/B.jpg"]["assignment"]["status"])
        self.assertEqual("unassigned", self.photos["JPG/C.jpg"]["assignment"]["status"])
        self.assertEqual("human", self.photos["JPG/A.jpg"]["assignment"]["authority"])
        self.assertEqual("ui", self.photos["JPG/A.jpg"]["assignment"]["record_origin"])
        self.assertEqual("unknown", self.photos["JPG/A.jpg"]["assignment"]["validation_status"])
        self.assertNotIn("JPG/E.jpg", self.photos)
        self.assertEqual(1, len(self.bundle["photo_exclusions"]))

    def test_annotation_flag_is_not_field_level_human_validation(self):
        components = self.photos["JPG/A.jpg"]["content_components"]
        label = next(item for item in components if item["content_kind"] == "annotation_label"
                     and item["origin"] == "ui")
        description = next(item for item in components if item["content_kind"] == "vlm_description"
                           and item["origin"] == "ui")
        self.assertEqual("unknown", label["validation_status"])
        self.assertEqual("unknown", description["validation_status"])
        self.assertNotIn("annotation_validee", {item["source_field"] for item in components})
        self.assertFalse(any(item["validation_status"] == "validated" for item in components))

    def test_photo_asr_and_editorial_subjects_remain_separate(self):
        photo_a = self.photos["JPG/A.jpg"]
        self.assertEqual(6, photo_a["subject_scope"]["photo_subject_numero"])
        self.assertEqual([11], photo_a["subject_scope"]["asr_subject_numeros"])
        self.assertEqual(6, photo_a["subject_scope"]["editorial_subject_numero"])
        self.assertEqual("candidate", photo_a["asr_context"]["link_status"])
        photo_d = self.photos["JPG/D.jpg"]
        self.assertEqual(6, photo_d["subject_scope"]["photo_subject_numero"])
        self.assertEqual([10, 11], photo_d["subject_scope"]["asr_subject_numeros"])
        self.assertEqual(6, photo_d["subject_scope"]["editorial_subject_numero"])

    def test_absence_of_asr_context_does_not_invent_a_subject(self):
        photo_c = self.photos["JPG/C.jpg"]
        self.assertEqual([], photo_c["subject_scope"]["asr_subject_numeros"])
        self.assertEqual([], photo_c["asr_context"]["evidence_occurrence_ids"])
        self.assertEqual("unresolved", photo_c["asr_context"]["link_status"])

    def test_batch_is_supplementary_and_cannot_add_photos(self):
        self.assertNotIn("JPG/X.jpg", self.photos)
        batch_components = [
            item for item in self.photos["JPG/A.jpg"]["content_components"]
            if item["source_file"] == "photos_batch.csv"
        ]
        self.assertEqual(
            {"vlm_description", "annotation_label", "annotation_comment"},
            {item["content_kind"] for item in batch_components},
        )
        self.assertTrue(all(item["origin"] == "batch" for item in batch_components))
        self.assertTrue(all(item["validation_status"] == "unvalidated" for item in batch_components))
        codes = {item["code"] for item in self.bundle["diagnostics"]}
        self.assertIn("batch_photo_not_in_primary", codes)

    def test_component_ids_are_unique_for_distinct_provenance(self):
        components = self.photos["JPG/A.jpg"]["content_components"]
        ids = [item["component_id"] for item in components]
        self.assertEqual(len(ids), len(set(ids)))
        fingerprints = [item["provenance_fingerprint"] for item in components]
        self.assertEqual(len(fingerprints), len(set(fingerprints)))
        self.assertGreaterEqual(len({
            (item["content_kind"], item["source_file"], item["source_field"], item["origin"])
            for item in components
        }), 7)

    def test_diagnostics_keep_orphan_assignments_and_unassigned_photos(self):
        codes = {item["code"] for item in self.bundle["diagnostics"]}
        self.assertIn("assignment_without_photo", codes)
        self.assertIn("photo_without_assignment", codes)
        orphan = next(
            item for item in self.bundle["diagnostics"]
            if item["code"] == "assignment_without_photo"
        )
        self.assertEqual("JPG/MANQUANTE.jpg", orphan["photo_id"])

    def test_snapshot_omits_exclusions_and_does_not_copy_text(self):
        snapshot = build_context_snapshot(
            self.bundle,
            pipeline_kind="refere",
            subject_scope={
                "photo_subject_numero": 6,
                "asr_subject_numeros": [10, 11],
                "editorial_subject_numero": 6,
            },
            selection_rule_ids=("fixture-photo-scope",),
        )
        self.assertEqual(["JPG/A.jpg", "JPG/D.jpg"], snapshot["included_photo_ids"])
        self.assertNotIn("JPG/B.jpg", snapshot["included_photo_ids"])
        self.assertNotIn("JPG/C.jpg", snapshot["included_photo_ids"])
        self.assertEqual(1, len(snapshot["photo_exclusion_ids"]))
        self.assertFalse(snapshot["text_copy_embedded"])
        serialized = json.dumps(snapshot, ensure_ascii=False)
        for value in (
            "Facade synthetique Alpha.",
            "Cour synthetique sans sujet.",
            "Portail metallique",
            "Commentaire batch synthetique.",
        ):
            self.assertNotIn(value, serialized)

    def test_explicit_validation_record_can_validate_a_field(self):
        records = [{
            "record_type": "assignment",
            "photo_id": "JPG/A.jpg",
            "subject_numero": 6,
            "source_field": "assignments/0/subject_numero",
            "validation_status": "validated",
            "validation_reason": "controle documentaire explicite",
            "validation_record_id": "validation:fixture-0001",
        }]
        bundle = resolve_photo_context(
            selection(FIXTURES),
            editorial_subject_numero=6,
            asr_context=asr_items(),
            validation_records=records,
        )
        photo = next(item for item in bundle["photos"] if item["photo_id"] == "JPG/A.jpg")
        self.assertEqual("validated", photo["assignment"]["validation_status"])
        self.assertEqual("validation:fixture-0001", photo["assignment"]["validation_record_id"])
        assignment_component = next(
            item for item in photo["content_components"]
            if item["content_kind"] == "human_assignment"
        )
        self.assertEqual("validated", assignment_component["validation_status"])
        label = next(
            item for item in photo["content_components"]
            if item["content_kind"] == "annotation_label" and item["origin"] == "ui"
        )
        self.assertEqual("unknown", label["validation_status"])

    def test_conflicting_assignments_are_not_arbitrarily_selected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            copy_inputs(root)
            payload = load_json(root / "photo_subject_assignments.json")
            payload["assignments"].append({
                "photo_rel_native": "JPG/A.jpg",
                "status": "affectee",
                "subject_numero": 11,
            })
            (root / "photo_subject_assignments.json").write_text(
                json.dumps(payload, ensure_ascii=False), encoding="utf-8"
            )
            bundle = resolve_fixture(root)
            self.assertNotIn("JPG/A.jpg", {item["photo_id"] for item in bundle["photos"]})
            self.assertIn("conflicting_assignment", {item["code"] for item in bundle["diagnostics"]})

    def test_ambiguous_subject_text_is_not_parsed_as_a_number(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            copy_inputs(root)
            payload = load_json(root / "photo_subject_assignments.json")
            payload["assignments"][0]["subject_numero"] = "6 annexe"
            (root / "photo_subject_assignments.json").write_text(
                json.dumps(payload, ensure_ascii=False), encoding="utf-8"
            )
            bundle = resolve_fixture(root)
            self.assertNotIn("JPG/A.jpg", {item["photo_id"] for item in bundle["photos"]})
            self.assertIn(
                "assigned_photo_without_subject",
                {item["code"] for item in bundle["diagnostics"]},
            )

    def test_invalid_asr_reference_is_diagnosed_and_not_used(self):
        items = asr_items() + [
            AsrContextItem(
                evidence_id="not-an-evidence-id",
                row_ref=9,
                start_sec=100,
                end_sec=101,
                subject_numeros=(11,),
            )
        ]
        bundle = resolve_photo_context(
            selection(FIXTURES),
            editorial_subject_numero=6,
            asr_context=items,
        )
        self.assertIn("invalid_asr_evidence_id", {item["code"] for item in bundle["diagnostics"]})
        photo_a = next(item for item in bundle["photos"] if item["photo_id"] == "JPG/A.jpg")
        self.assertNotIn("not-an-evidence-id", photo_a["asr_context"]["evidence_occurrence_ids"])

    def test_component_and_assignment_ids_are_stable_after_root_move(self):
        with tempfile.TemporaryDirectory() as first, tempfile.TemporaryDirectory() as second:
            root_a = Path(first)
            root_b = Path(second) / "another-root"
            copy_inputs(root_a)
            copy_inputs(root_b)
            bundle_a = resolve_fixture(root_a)
            bundle_b = resolve_fixture(root_b)

        def identities(bundle):
            return {
                photo["photo_id"]: (
                    photo["assignment"]["assignment_id"],
                    tuple(item["component_id"] for item in photo["content_components"]),
                )
                for photo in bundle["photos"]
            }

        self.assertEqual(identities(bundle_a), identities(bundle_b))
        self.assertEqual(
            [item["exclusion_id"] for item in bundle_a["photo_exclusions"]],
            [item["exclusion_id"] for item in bundle_b["photo_exclusions"]],
        )

    def test_optional_file_status_is_explicit_and_deterministic(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            copy_inputs(root)
            image = root / "images" / "JPG" / "A.jpg"
            image.parent.mkdir(parents=True)
            image.write_bytes(b"synthetic-jpeg-test-bytes")
            bundle = resolve_photo_context(
                selection(root, include_file_status=True),
                editorial_subject_numero=6,
                asr_context=asr_items(),
            )
            photo_a = next(item for item in bundle["photos"] if item["photo_id"] == "JPG/A.jpg")
            self.assertTrue(photo_a["file_status"]["exists"])
            self.assertEqual(len(b"synthetic-jpeg-test-bytes"), photo_a["file_status"]["size_bytes"])
            self.assertEqual("image/jpeg", photo_a["file_status"]["mime_type"])
            self.assert_definition_valid(photo_a["file_status"], "photo_file_status")
            self.assertIn(
                "photo_file_missing",
                {item["code"] for item in bundle["diagnostics"]},
            )

    def test_contract_validator_reports_excluded_photo_in_snapshot(self):
        snapshot = build_context_snapshot(
            self.bundle,
            pipeline_kind="refere",
            subject_scope={
                "photo_subject_numero": 6,
                "asr_subject_numeros": [10, 11],
                "editorial_subject_numero": 6,
            },
        )
        snapshot["included_photo_ids"].append("JPG/B.jpg")
        candidate = copy.deepcopy(self.bundle)
        candidate["context_snapshots"] = [snapshot]
        errors = validate_photo_context_bundle(candidate)
        self.assertIn("snapshot_includes_excluded_photo", {item["code"] for item in errors})

    def test_contract_validator_reports_duplicate_component_ids(self):
        candidate = copy.deepcopy(self.bundle)
        components = candidate["photos"][0]["content_components"]
        components.append(copy.deepcopy(components[0]))
        errors = validate_photo_context_bundle(candidate)
        self.assertIn("duplicate_component_id", {item["code"] for item in errors})

    def test_missing_mandatory_source_is_not_silently_ignored(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            copy_inputs(root)
            (root / "photos.csv").unlink()
            with self.assertRaises(PhotoContextResolverError) as context:
                resolve_fixture(root)
            self.assertEqual("source_missing", context.exception.code)

    def test_batch_content_divergences_are_explicit(self):
        divergences = [
            item for item in self.bundle["diagnostics"]
            if item["code"] == "batch_content_divergence"
        ]
        self.assertEqual(
            {"vlm_description", "annotation_label", "annotation_comment"},
            {item["context_id"] for item in divergences},
        )

    def test_source_hash_keys_cannot_be_physical_paths(self):
        path_key_bundle = resolve_photo_context(
            selection(FIXTURES),
            editorial_subject_numero=6,
            asr_context=asr_items(),
            source_hashes={r"C:\Affaires\photos.csv": "0" * 64},
        )
        self.assertIn(
            "source_hash_key_not_logical",
            {item["code"] for item in path_key_bundle["diagnostics"]},
        )
        self.assertNotIn(r"C:\Affaires\photos.csv", path_key_bundle["source_hashes"])
        bundle = resolve_photo_context(
            selection(FIXTURES),
            editorial_subject_numero=6,
            asr_context=asr_items(),
            source_hashes={"photos.csv": "0" * 64},
        )
        self.assertIn("source_hash_mismatch", {item["code"] for item in bundle["diagnostics"]})
        self.assertEqual(
            hashlib.sha256((FIXTURES / "photos.csv").read_bytes()).hexdigest(),
            bundle["source_hashes"]["photos.csv"],
        )

    def test_snapshot_hashes_and_reference_completeness_are_verified(self):
        snapshot = build_context_snapshot(
            self.bundle,
            pipeline_kind="refere",
            subject_scope={
                "photo_subject_numero": 6,
                "asr_subject_numeros": [10, 11],
                "editorial_subject_numero": 6,
            },
        )
        candidate = copy.deepcopy(self.bundle)
        candidate["context_snapshots"] = [snapshot]
        self.assertEqual([], validate_photo_context_bundle(candidate))
        self.assertIn(
            "snapshot_is_prepared_not_llm_execution",
            snapshot["selection_rule_ids"],
        )
        tampered = copy.deepcopy(snapshot)
        tampered["component_ids"].append("photo-component:" + "0" * 64)
        candidate["context_snapshots"] = [tampered]
        codes = {item["code"] for item in validate_photo_context_bundle(candidate)}
        self.assertIn("snapshot_hash_mismatch", codes)
        self.assertIn("snapshot_unknown_component", codes)
        self.assertIn("snapshot_id_mismatch", codes)

    def test_snapshot_cannot_reference_component_from_unselected_photo(self):
        snapshot = build_context_snapshot(
            self.bundle,
            pipeline_kind="refere",
            subject_scope={
                "photo_subject_numero": 6,
                "asr_subject_numeros": [10, 11],
                "editorial_subject_numero": 6,
            },
        )
        photo_c = self.photos["JPG/C.jpg"]
        snapshot["component_ids"].append(photo_c["content_components"][0]["component_id"])
        candidate = copy.deepcopy(self.bundle)
        candidate["context_snapshots"] = [snapshot]
        codes = {item["code"] for item in validate_photo_context_bundle(candidate)}
        self.assertIn("snapshot_component_not_from_included_photo", codes)

    def test_invalid_prompt_hash_is_rejected(self):
        with self.assertRaises(PhotoContextResolverError) as context:
            build_context_snapshot(
                self.bundle,
                pipeline_kind="refere",
                subject_scope={
                    "photo_subject_numero": 6,
                    "asr_subject_numeros": [10, 11],
                    "editorial_subject_numero": 6,
                },
                prompt_sha256="not-a-sha256",
            )
        self.assertEqual("invalid_snapshot_hash", context.exception.code)

    def test_snapshot_asr_scope_must_match_included_photos(self):
        with self.assertRaises(PhotoContextResolverError) as context:
            build_context_snapshot(
                self.bundle,
                pipeline_kind="refere",
                subject_scope={
                    "photo_subject_numero": 6,
                    "asr_subject_numeros": [11],
                    "editorial_subject_numero": 6,
                },
            )
        self.assertEqual("subject_scope_mismatch", context.exception.code)

    def test_invalid_t_audio_prevents_temporal_asr_attachment(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            copy_inputs(root)
            with (root / "photos.csv").open("r", encoding="utf-8", newline="") as stream:
                reader = csv.DictReader(stream, delimiter=";")
                rows = list(reader)
                fieldnames = reader.fieldnames
            for row in rows:
                if row["photo_rel_native"] == "JPG/D.jpg":
                    row["t_audio"] = "horodatage-invalide"
            with (root / "photos.csv").open("w", encoding="utf-8", newline="") as stream:
                writer = csv.DictWriter(stream, fieldnames=fieldnames, delimiter=";")
                writer.writeheader()
                writer.writerows(rows)
            bundle = resolve_fixture(root)
            photo_d = next(item for item in bundle["photos"] if item["photo_id"] == "JPG/D.jpg")
            self.assertIsNone(photo_d["chrono_sec"])
            self.assertEqual("unresolved", photo_d["asr_context"]["link_status"])
            codes = {item["code"] for item in bundle["diagnostics"]}
            self.assertIn("invalid_t_audio", codes)
            self.assertIn("photo_without_usable_t_audio", codes)

    def test_utf8_bom_and_comma_delimited_csv_are_supported(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            copy_inputs(root)
            (root / "photos.csv").write_text(
                "photo_rel_native,nom_fichier_image,horodatage_photo,t_audio,description_vlm_ui\n"
                "JPG/A.jpg,A.jpg,02/01/2030 10:00:00,100.25,Facade synthetique Alpha.\n",
                encoding="utf-8-sig",
            )
            bundle = resolve_fixture(root)
            self.assertIn("JPG/A.jpg", {item["photo_id"] for item in bundle["photos"]})

    def test_backslash_and_dot_path_are_normalized(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            copy_inputs(root)
            payload = load_json(root / "photo_subject_assignments.json")
            payload["assignments"][0]["photo_rel_native"] = r"JPG\.\A.jpg"
            (root / "photo_subject_assignments.json").write_text(
                json.dumps(payload, ensure_ascii=False), encoding="utf-8"
            )
            bundle = resolve_fixture(root)
            self.assertIn("JPG/A.jpg", {item["photo_id"] for item in bundle["photos"]})

    def test_case_variant_assignment_is_not_silently_merged(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            copy_inputs(root)
            payload = load_json(root / "photo_subject_assignments.json")
            payload["assignments"][0]["photo_rel_native"] = "jpg/a.jpg"
            (root / "photo_subject_assignments.json").write_text(
                json.dumps(payload, ensure_ascii=False), encoding="utf-8"
            )
            bundle = resolve_fixture(root)
            self.assertNotIn("JPG/A.jpg", {item["photo_id"] for item in bundle["photos"]})
            self.assertIn(
                "case_equivalent_photo_reference",
                {item["code"] for item in bundle["diagnostics"]},
            )

    def test_ui_status_columns_never_validate_a_component(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            copy_inputs(root)
            with (root / "photos.csv").open("r", encoding="utf-8", newline="") as stream:
                reader = csv.DictReader(stream, delimiter=";")
                rows = list(reader)
                fieldnames = list(reader.fieldnames)
            fieldnames.extend(("description_vlm_ui_status", "libelle_ui_status"))
            for row in rows:
                row["description_vlm_ui_status"] = "validated"
                row["libelle_ui_status"] = "validated"
            with (root / "photos.csv").open("w", encoding="utf-8", newline="") as stream:
                writer = csv.DictWriter(stream, fieldnames=fieldnames, delimiter=";")
                writer.writeheader()
                writer.writerows(rows)
            bundle = resolve_fixture(root)
            photo_a = next(item for item in bundle["photos"] if item["photo_id"] == "JPG/A.jpg")
            description = next(
                item for item in photo_a["content_components"]
                if item["content_kind"] == "vlm_description" and item["origin"] == "ui"
            )
            label = next(
                item for item in photo_a["content_components"]
                if item["content_kind"] == "annotation_label" and item["origin"] == "ui"
            )
            self.assertEqual("unknown", description["validation_status"])
            self.assertEqual("unknown", label["validation_status"])
            self.assertNotIn(
                "description_vlm_ui_status",
                {item["source_field"] for item in photo_a["content_components"]},
            )

    def test_ambiguous_component_validation_is_not_applied(self):
        bundle = resolve_photo_context(
            selection(FIXTURES),
            editorial_subject_numero=6,
            asr_context=asr_items(),
            validation_records=[{
                "record_type": "component",
                "photo_id": "JPG/A.jpg",
                "content_kind": "annotation_label",
                "validation_status": "validated",
                "validation_record_id": "validation:ambiguous",
            }],
        )
        photo_a = next(item for item in bundle["photos"] if item["photo_id"] == "JPG/A.jpg")
        labels = [
            item for item in photo_a["content_components"]
            if item["content_kind"] == "annotation_label"
        ]
        self.assertTrue(labels)
        self.assertTrue(all(item["validation_status"] != "validated" for item in labels))
        self.assertIn(
            "ambiguous_validation_record",
            {item["code"] for item in bundle["diagnostics"]},
        )

    def test_malformed_assignments_json_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            copy_inputs(root)
            (root / "photo_subject_assignments.json").write_text("{broken", encoding="utf-8")
            with self.assertRaises(PhotoContextResolverError) as context:
                resolve_fixture(root)
            self.assertEqual("invalid_assignments_json", context.exception.code)

    def test_duplicate_photo_row_is_not_published(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            copy_inputs(root)
            with (root / "photos.csv").open("a", encoding="utf-8", newline="") as stream:
                stream.write("JPG/A.jpg;A.jpg;02/01/2030 10:00:00;100.25;Doublon;;;;0\n")
            bundle = resolve_fixture(root)
            self.assertNotIn("JPG/A.jpg", {item["photo_id"] for item in bundle["photos"]})
            self.assertIn(
                "duplicate_photo_row",
                {item["code"] for item in bundle["diagnostics"]},
            )

    def test_csv_row_with_extra_fields_is_diagnosed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            copy_inputs(root)
            with (root / "photos.csv").open("a", encoding="utf-8", newline="") as stream:
                stream.write("JPG/EXTRA.jpg;EXTRA.jpg;;;Texte;;;;0;valeur-en-trop\n")
            bundle = resolve_fixture(root)
            self.assertIn(
                "csv_row_extra_fields",
                {item["code"] for item in bundle["diagnostics"]},
            )

    def test_parent_path_traversal_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            copy_inputs(root)
            payload = load_json(root / "photo_subject_assignments.json")
            payload["assignments"][0]["photo_rel_native"] = "../A.jpg"
            (root / "photo_subject_assignments.json").write_text(
                json.dumps(payload, ensure_ascii=False), encoding="utf-8"
            )
            bundle = resolve_fixture(root)
            self.assertIn(
                "invalid_photo_id",
                {item["code"] for item in bundle["diagnostics"]},
            )


if __name__ == "__main__":
    unittest.main()
