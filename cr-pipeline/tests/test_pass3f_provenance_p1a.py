import json
import unittest
from pathlib import Path

from jsonschema import Draft202012Validator


ROOT = Path(__file__).resolve().parents[1]
SCHEMA_PATH = ROOT / 'pipeline' / 'schemas' / 'pass3f_provenance.v2.schema.json'
FIXTURES = Path(__file__).resolve().parent / 'fixtures' / 'pass3f_provenance'


def load_json(path):
    return json.loads(path.read_text(encoding='utf-8'))


class Pass3FProvenanceP1ATest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.schema = load_json(SCHEMA_PATH)
        cls.validator = Draft202012Validator(cls.schema)
        cls.legacy = load_json(FIXTURES / 'legacy_minimal.json')
        cls.enriched = load_json(FIXTURES / 'enriched_photo_context.json')

    def assert_valid(self, registry):
        errors = sorted(self.validator.iter_errors(registry), key=lambda item: list(item.path))
        self.assertEqual([], [error.message for error in errors])

    def test_schema_itself_is_valid_draft_2020_12(self):
        Draft202012Validator.check_schema(self.schema)

    def test_legacy_minimal_fixture_remains_valid(self):
        self.assert_valid(self.legacy)

    def test_enriched_photo_context_fixture_is_valid(self):
        self.assert_valid(self.enriched)

    def test_new_registry_objects_remain_optional(self):
        for key in ('photo_exclusions', 'context_snapshots'):
            self.assertNotIn(key, self.legacy)
            self.assertIn(key, self.enriched)
        self.assertNotIn('subject_scope', self.schema['$defs']['photo']['required'])

    def test_existing_required_contract_and_exact_text_are_preserved(self):
        required = set(self.schema['required'])
        self.assertTrue({'schema', 'run', 'subjects', 'evidence', 'truncation_events', 'derived_fragments', 'stats'} <= required)
        self.assertIn('exact_text', self.schema['$defs']['evidence']['required'])
        self.assertEqual('pass3f.provenance.v2', self.schema['properties']['schema']['const'])

    def test_photo_asr_and_editorial_scopes_are_distinct(self):
        photo = self.enriched['evidence'][1]['photo']
        scope = photo['subject_scope']
        self.assertEqual(6, scope['photo_subject_numero'])
        self.assertEqual([11], scope['asr_subject_numeros'])
        self.assertEqual(6, scope['editorial_subject_numero'])
        self.assertEqual(6, photo['human_subject_numero'])

    def test_ui_origin_is_not_treated_as_human_validation(self):
        photo = self.enriched['evidence'][1]['photo']
        self.assertEqual('ui', photo['assignment']['record_origin'])
        self.assertEqual('unknown', photo['assignment']['validation_status'])
        annotation = next(item for item in photo['content_components'] if item['content_kind'] == 'annotation_label')
        vlm = next(item for item in photo['content_components'] if item['content_kind'] == 'vlm_description')
        self.assertEqual('ui', annotation['origin'])
        self.assertEqual('unknown', annotation['validation_status'])
        self.assertEqual('pipeline', vlm['origin'])
        self.assertEqual('unvalidated', vlm['validation_status'])

    def test_raw_annotation_flag_cannot_masquerade_as_component_provenance(self):
        photo = self.enriched['evidence'][1]['photo']
        component = dict(photo['content_components'][0])
        component['annotation_validee'] = 1
        candidate = json.loads(json.dumps(self.enriched))
        candidate['evidence'][1]['photo']['content_components'][0] = component
        errors = list(self.validator.iter_errors(candidate))
        self.assertTrue(errors)

    def test_excluded_photo_is_not_in_the_llm_snapshot(self):
        exclusion = self.enriched['photo_exclusions'][0]
        snapshot = self.enriched['context_snapshots'][0]
        self.assertNotIn(exclusion['photo_id'], snapshot['included_photo_ids'])
        self.assertIn(exclusion['exclusion_id'], snapshot['photo_exclusion_ids'])

    def test_snapshot_uses_references_and_hashes_without_text_copy(self):
        snapshot = self.enriched['context_snapshots'][0]
        self.assertFalse(snapshot['text_copy_embedded'])
        self.assertNotIn('exact_text', snapshot)
        self.assertIn('context_sha256', snapshot)
        self.assertTrue(snapshot['source_hashes'])

    def test_generation_keeps_component_and_validation_provenance(self):
        fragment = self.enriched['derived_fragments'][0]
        generation = fragment['generation']
        vlm = next(item for item in self.enriched['evidence'][1]['photo']['content_components'] if item['content_kind'] == 'vlm_description')
        self.assertIn(vlm['component_id'], generation['parent_component_ids'])
        self.assertEqual('llm', generation['kind'])
        self.assertEqual('unvalidated', generation['validation_status'])


if __name__ == '__main__':
    unittest.main()
