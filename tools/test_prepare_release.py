"""Release source, completeness and integrity gates (no GitHub writes)."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/prepare-release.py'


class ReleaseInputChecks(unittest.TestCase):
    def test_release_inputs(self):
        for case in ['valid', 'wrong_commit', 'wrong_version', 'missing_arch', 'duplicate_arch', 'bad_checksum', 'dirty_output']:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                for arch in ['arm64', 'x86_64']:
                    folder = root / 'artifacts' / arch
                    folder.mkdir(parents=True)
                    filename = f'RightMouse-0.2.0-local-{arch}.dmg'
                    data = b'fixture installer'
                    (folder / filename).write_bytes(data)
                    (folder / (filename + '.sha256')).write_text(hashlib.sha256(data).hexdigest() + '  ' + filename + '\n')
                    info = dict(version='0.2.0', commit='a' * 40, architecture=arch, notarized=False)
                    if arch == 'arm64':
                        if case == 'wrong_commit': info['commit'] = 'b' * 40
                        if case == 'wrong_version': info['version'] = '0.3.0'
                        if case == 'duplicate_arch': info['architecture'] = 'x86_64'
                        if case == 'bad_checksum': (folder / filename).write_bytes(b'changed')
                    if case != 'missing_arch' or arch != 'x86_64':
                        (folder / 'build-info.json').write_text(json.dumps(info))
                output = root / 'output'
                if case == 'dirty_output':
                    output.mkdir(); (output / 'keep.txt').write_text('keep')
                result = subprocess.run([sys.executable, str(SCRIPT), '--artifacts', str(root / 'artifacts'),
                    '--output', str(output), '--tag', 'v0.2.0-local.1', '--commit', 'a' * 40], capture_output=True, text=True)
                if case == 'valid':
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(len(list(output.iterdir())), 6)
                else:
                    self.assertNotEqual(result.returncode, 0, case)
                    self.assertFalse(output.exists() and list(output.glob('*.dmg')), 'invalid inputs staged installer files')
                    if case == 'dirty_output': self.assertEqual((output / 'keep.txt').read_text(), 'keep')


if __name__ == '__main__':
    unittest.main()
