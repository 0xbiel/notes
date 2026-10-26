"""Check that published identities match source versions and remain unique."""
import os
import unittest
from unittest.mock import patch

from release_version import github_metadata, metadata


class ReleaseVersionTests(unittest.TestCase):
    def setUp(self):
        self.environment = patch.dict(os.environ, {
            'GITHUB_RUN_NUMBER': '42', 'GITHUB_RUN_ATTEMPT': '1',
            'GITHUB_REF_TYPE': 'branch', 'GITHUB_REF_NAME': 'feature/example',
        }, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.version = patch('pathlib.Path.read_text', return_value='0.3.0\n')
        self.version.start()
        self.addCleanup(self.version.stop)

    def test_local_bundle_defaults(self):
        self.assertEqual(metadata(), dict(version='0.3.0', build='1', release='0.3.0'))

    def test_push_and_rerun_have_distinct_versions(self):
        first = github_metadata()
        os.environ['GITHUB_RUN_ATTEMPT'] = '2'
        second = github_metadata()
        self.assertEqual(first['tag'], 'v0.3.0-dev.42.1')
        self.assertEqual(second['tag'], 'v0.3.0-dev.42.2')
        self.assertEqual(second['build'], '42.2')
        self.assertEqual(second['prerelease'], 'true')

    def test_matching_tag_is_stable(self):
        os.environ.update(GITHUB_REF_TYPE='tag', GITHUB_REF_NAME='v0.3.0')
        result = github_metadata()
        self.assertEqual(result['tag'], 'v0.3.0')
        self.assertEqual(result['prerelease'], 'false')

    def test_mismatched_tag_cannot_publish(self):
        os.environ.update(GITHUB_REF_TYPE='tag', GITHUB_REF_NAME='v0.4.0')
        with self.assertRaises(ValueError):
            github_metadata()

    def test_invalid_bundle_metadata_is_rejected(self):
        for key, value in [('NOTES_BUILD_NUMBER', 'preview'),
                           ('NOTES_RELEASE_VERSION', '../outside'),
                           ('NOTES_RELEASE_VERSION', '0.4.0-dev.42.1')]:
            with self.subTest(key=key, value=value), patch.dict(os.environ, {key: value}):
                with self.assertRaises(ValueError):
                    metadata()
        with patch('pathlib.Path.read_text', return_value='v0.3.0'):
            with self.assertRaises(ValueError):
                metadata()


if __name__ == '__main__':
    unittest.main()
