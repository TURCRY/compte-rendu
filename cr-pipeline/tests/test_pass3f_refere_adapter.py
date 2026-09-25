import csv
import json
import sys
import tempfile
import unittest
from pathlib import Path

from jsonschema import Draft202012Validator


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "pipeline" / "python"))

from pass3f_audit import build_groups  # noqa: E402
from pass3f_candidates import build_candidates  # noqa: E402
from pass3f_refere_adapter import (  # noqa: E402
    RefereSources,
    build_refere_registry,
    discover_sources,
)
from pass3f_provenance import canonical_bytes  # noqa: E402


def dump(path: Path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")


def write_csv(path: Path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]), delimiter=";")
        writer.writeheader()
        writer.writerows(rows)


def make_sources(root: Path) -> RefereSources:
    affaire = "TEST-1"
    captation = "accedit-2030-01-02"
    affaires = root / "Affaires"
    transcription = (
        affaires / affaire / "AF_Expert_ASR" / "transcriptions" / captation
    )
    photos = affaires / affaire / "AE_Expert_captations" / captation / "photos"
    generalist = root / "generalist"
    run = root / "refere"

    write_csv(transcription / "Sujets.csv", [
        {"numero": 1, "titre": "Etat du 10 rue Alpha", "localisation": "A1", "description": ""},
        {"numero": 2, "titre": "Etat du 20 rue Beta", "localisation": "B2", "description": "Propriete Beta"},
        {"numero": 3, "titre": "Reseaux communs", "localisation": "", "description": ""},
    ])
    photo_a = f"AE_Expert_captations/{captation}/photos/JPG/A.JPG"
    photo_b = f"AE_Expert_captations/{captation}/photos/JPG/B.JPG"
    photo_x = f"AE_Expert_captations/{captation}/photos/JPG/X.JPG"
    dump(photos / "photo_subject_assignments.json", {
        "schema_version": 1,
        "assignments": [
            {"photo_rel_native": photo_a, "status": "affectee", "subject_numero": 2},
            {"photo_rel_native": photo_b, "status": "affectee", "subject_numero": 1},
            {"photo_rel_native": photo_x, "status": "exclue", "subject_numero": None},
        ],
    })
    write_csv(photos / "photos.csv", [
        {
            "photo_rel_native": photo_a, "nom_fichier_image": "A.JPG",
            "horodatage_photo": "02/01/2030 10:00:00",
            "description_vlm_ui": "Facade du 20 rue Beta.",
            "libelle_propose_ui": "", "commentaire_propose_ui": "",
        },
        {
            "photo_rel_native": photo_b, "nom_fichier_image": "B.JPG",
            "horodatage_photo": "02/01/2030 10:00:05",
            "description_vlm_ui": "Facade du 10 rue Alpha.",
            "libelle_propose_ui": "", "commentaire_propose_ui": "",
        },
        {
            "photo_rel_native": photo_x, "nom_fichier_image": "X.JPG",
            "horodatage_photo": "02/01/2030 10:00:10",
            "description_vlm_ui": "Photo exclue.",
            "libelle_propose_ui": "", "commentaire_propose_ui": "",
        },
    ])
    for name in ("A.JPG", "B.JPG", "X.JPG"):
        path = photos / "JPG" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(("image-" + name).encode("ascii"))

    shared = {
        "segment_id": "segment_01", "row_ref": 7, "timecode": "00:00:07",
        "auteur": "Expert", "texte": "La visite porte sur le 20 rue Beta.",
        "projection_classification": "specifique", "row_ref_subject_count": 1,
    }
    dump(generalist / "global.json", {"sujets": {"1": [shared]}})
    for numero in (1, 2, 3):
        dump(
            generalist / "pass2E_sujets_compact" / f"sujet_{numero:03d}_compact.json",
            {
                "numero": numero,
                "synthese_intermediaire": {
                    "points_cles": [f"Projection documentaire du sujet {numero}."]
                },
            },
        )
    segment = generalist / "segments" / "segment_01.json"
    dump(segment, {"segment_id": "segment_01", "rows": [shared]})

    dump(run / "manifest.json", {
        "id_affaire": affaire, "id_captation": captation, "status": "OK",
    })
    photo_units = [
        {
            "kind": "photo_context", "photo_id": photo_a, "photo_display": "A.JPG",
            "timestamp_hms": "00:00:07", "chrono_sec": 7.0, "subject_numero": 2,
            "libelle_effectif": "Facade du 20 rue Beta.",
            "commentaire_effectif": "", "dictee_photo": "",
            "segment_coverage": {"segment_id": "segment_01"},
            "asr_context": {"rows": [7], "text": "[ROW 7] visite"},
            "provenance": {
                "source_files": ["photos.csv"], "assignment": "photo_subject_assignments.json",
                "subject_numero_source": "human_assignment",
            },
        },
        {
            "kind": "photo_context", "photo_id": photo_b, "photo_display": "B.JPG",
            "timestamp_hms": "00:00:08", "chrono_sec": 8.0, "subject_numero": 1,
            "libelle_effectif": "Facade du 10 rue Alpha.",
            "commentaire_effectif": "", "dictee_photo": "",
            "segment_coverage": {"segment_id": "segment_01"},
            "asr_context": {"rows": [7], "text": "[ROW 7] visite"},
            "provenance": {
                "source_files": ["photos.csv"], "assignment": "photo_subject_assignments.json",
                "subject_numero_source": "human_assignment",
            },
        },
    ]
    dump(run / "pass2b2f" / "pass2b2f_material_rank1.json", {
        "schema_version": "fixture",
        "units": [{
            "kind": "general_segment",
            "provenance": {"segment_file": str(segment)},
        }, *photo_units],
    })
    dump(run / "parsed_outputs" / "subject_001_chunk_01_response.json", {
        "schema_version": "cr_refere_preventif.pass2f.v1",
        "source_pass": "2F", "subject_numero": 1,
        "photo_contexts": [{
            "photo_id": photo_a,
            "constat": "La photographie A.JPG documente le 20 rue Beta.",
        }],
        "points_documentes": [], "incertitudes": [],
    })
    participants = {
        1: None,
        2: [{"nom": "P1", "role": "occupant", "resume": "Observation."}],
        3: {"nom": "P2", "role": "expert", "resume": "Avis."},
    }
    aggregate = []
    for numero in (1, 2, 3):
        raw = {
            "numero": numero,
            "titre": f"Sujet {numero}",
            "localisation": "",
            "description": "Description Pass3E recuperee." if numero == 1 else "",
            "avis_participants": participants[numero],
            "synthese_echanges": (
                "La photographie A.JPG documente le 20 rue Beta."
                if numero == 1 else f"Synthese du sujet {numero}."
            ),
            "conclusion_expert": f"Conclusion du sujet {numero}.",
        }
        dump(
            run / "pass3_refere" / "sujets" / f"sujet_{numero:03d}_synthese.json",
            raw,
        )
        aggregate.append({
            key: value for key, value in raw.items() if key != "description"
        } | {"synthese_file": f"sujets/sujet_{numero:03d}_synthese.json"})
    dump(run / "pass3_refere" / "refere_global_by_sujet.json", {
        "schema": "fixture", "sujets": aggregate,
    })

    return RefereSources(
        run_dir=run,
        sujets_csv=transcription / "Sujets.csv",
        generalist_run=generalist,
        assignments_json=photos / "photo_subject_assignments.json",
        photos_csv=photos / "photos.csv",
        pass2e_dir=generalist / "pass2E_sujets_compact",
        pass2f_dir=run / "parsed_outputs",
        pass3e_dir=run / "pass3_refere" / "sujets",
        refere_global_by_sujet=run / "pass3_refere" / "refere_global_by_sujet.json",
        material_rank1=run / "pass2b2f" / "pass2b2f_material_rank1.json",
        affaires_root=affaires,
        id_affaire=affaire,
        id_captation=captation,
    )


class Pass3FRefereAdapterTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.sources = make_sources(Path(self.temp.name))

    def tearDown(self):
        self.temp.cleanup()

    def test_registry_normalizes_refere_and_preserves_human_photo_authority(self):
        registry = build_refere_registry(self.sources)
        schema = json.loads(
            (ROOT / "pipeline" / "schemas" / "pass3f_provenance.v2.schema.json").read_text(
                encoding="utf-8"
            )
        )
        Draft202012Validator(schema).validate(registry)
        self.assertEqual(registry["run"]["pipeline_kind"], "refere")
        self.assertEqual(registry["stats"]["subject_count"], 3)
        self.assertEqual(registry["stats"]["photo_evidence_count"], 2)
        self.assertEqual(registry["stats"]["excluded_photo_count"], 1)
        self.assertEqual(registry["stats"]["participant_source_null_count"], 1)
        self.assertEqual(registry["stats"]["participant_source_array_count"], 1)
        self.assertEqual(registry["stats"]["participant_source_object_count"], 1)
        self.assertEqual(registry["subjects"][0]["description"], "Description Pass3E recuperee.")
        self.assertTrue(
            registry["subjects"][0]["description_source"].startswith("pass3_refere/")
        )

        photos = [item for item in registry["evidence"] if item["evidence_kind"] == "photo"]
        asr = [item for item in registry["evidence"] if item["evidence_kind"] == "asr"]
        self.assertEqual(len(photos), 2)
        self.assertTrue(all(item["pass1_subjects"] == [] for item in photos))
        self.assertEqual(asr[0]["pass1_subjects"], ["1"])
        self.assertFalse(any(
            link["relation_type"] == "subject_assignment"
            for link in asr[0]["provenance_links"]
        ))
        self.assertEqual(asr[0]["provenance_links"][0]["stage"], "pass1")
        self.assertTrue(any(
            key.startswith("refere/segments/")
            for key in registry["run"]["input_hashes"]
        ))
        assignments = [
            link for item in photos for link in item["provenance_links"]
            if link["relation_type"] == "subject_assignment"
        ]
        self.assertTrue(all(link["authority"] == "human" for link in assignments))
        self.assertEqual({link["subject_numero"] for link in assignments}, {1, 2})

    def test_photo_occurrences_are_stable_and_common_consumers_accept_registry(self):
        first = build_refere_registry(self.sources)
        second = build_refere_registry(self.sources)
        first_ids = sorted(
            item["evidence_occurrence_id"] for item in first["evidence"]
            if item["evidence_kind"] == "photo"
        )
        second_ids = sorted(
            item["evidence_occurrence_id"] for item in second["evidence"]
            if item["evidence_kind"] == "photo"
        )
        self.assertEqual(first_ids, second_ids)
        self.assertEqual(canonical_bytes(first), canonical_bytes(second))

        candidates = build_candidates(first)
        photo_conflicts = [
            item for item in candidates["candidates"]
            if "reference_kind=human_photo_assignment" in item["signals"]
        ]
        self.assertTrue(photo_conflicts)
        self.assertTrue(any(
            item["source_subject"] == "1" and item["target_subject"] == "2"
            for item in photo_conflicts
        ))
        groups = build_groups(first, candidates)
        self.assertTrue(groups)
        self.assertEqual(groups[0]["packet"]["pipeline_kind"], "refere")
        self.assertTrue(any(
            item.get("evidence_kind") == "photo"
            for group in groups for item in group["packet"]["evidence"]
        ))

    def test_structural_classification_keeps_photos_out_of_publishable_text(self):
        registry = build_refere_registry(self.sources)
        by_stage = {}
        for fragment in registry["derived_fragments"]:
            by_stage.setdefault(fragment["stage"], set()).add(fragment["representation_type"])
        self.assertEqual(by_stage["2E"], {"provenance_projection"})
        self.assertEqual(by_stage["2F"], {"provenance_projection"})
        self.assertIn("publishable_text_unit", by_stage["3E"])
        self.assertIn("participant_subfield", by_stage["3E"])
        self.assertFalse(any(
            item.get("evidence_kind") == "photo"
            and item.get("pass1_subjects")
            for item in registry["evidence"]
        ))

    def test_source_discovery_falls_back_to_photos_batch(self):
        batch = self.sources.photos_csv.with_name("photos_batch.csv")
        self.sources.photos_csv.rename(batch)
        discovered = discover_sources(
            self.sources.run_dir, affaires_root=self.sources.affaires_root
        )
        self.assertEqual(discovered.photos_csv, batch)


if __name__ == "__main__":
    unittest.main()
