import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class RestoreDrillTest(unittest.TestCase):
    def run_drill(self, healthy, integrity_result='ok', integrity_status=0):
        with tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parent) as directory:
            root = Path(directory)
            shutil.copy(Path(__file__).resolve().parents[2] / 'deploy/restore-drill.sh', root)
            commands = root / 'commands'
            commands.mkdir()
            (root / '.env.app').touch()
            (root / '.env.litestream').touch()
            docker = commands / 'docker'
            docker.write_text('''#!/usr/bin/env bash
if [[ "$1" == run && "$2" == -d ]]; then
  touch "$STATE/booted"
  touch "$STATE/container"
  echo drill-container-id
elif [[ "$1" == rm ]]; then
  rm -f "$STATE/container"
else
  for argument in "$@"; do
    if [[ "$argument" == sqlite3 ]]; then
      printf '%s\\n' "$INTEGRITY_RESULT"
      exit "$INTEGRITY_STATUS"
    fi
  done
fi
''')
            for name, body in [('curl', 'exit "$HEALTH_STATUS"'), ('sleep', 'exit 0'), ('shuf', 'echo 23456')]:
                (commands / name).write_text('#!/usr/bin/env bash\n' + body + '\n')
            for command in commands.iterdir():
                command.chmod(0o700)
            environment = dict(os.environ, PATH=f'{commands}:{os.environ["PATH"]}',
                               STATE=str(root), TMPDIR=str(root),
                               HEALTH_STATUS='0' if healthy else '1',
                               INTEGRITY_RESULT=integrity_result,
                               INTEGRITY_STATUS=str(integrity_status),
                               LITESTREAM_BUCKET='fixture', SPACES_ENDPOINT='fixture',
                               SPACES_REGION='auto')
            result = subprocess.run(['bash', str(root / 'restore-drill.sh')],
                                    env=environment, text=True, capture_output=True)
            valid = integrity_result == 'ok' and integrity_status == 0
            if healthy and valid:
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue((root / 'container').exists(), 'healthy drill must remain available')
                self.assertIn('http://127.0.0.1:23456', result.stdout)
                cleanup = next(line for line in result.stdout.splitlines() if line.startswith('docker rm -f '))
                subprocess.run(['bash', '-c', cleanup], env=environment, check=True)
            else:
                self.assertNotEqual(result.returncode, 0)
            self.assertEqual((root / 'booted').exists(), valid)
            if not valid:
                self.assertNotIn('Restored app is healthy', result.stdout)
            self.assertFalse((root / 'container').exists())
            self.assertEqual(list(root.glob('tmp.*')), [])

    def test_healthy_drill_remains_until_explicit_cleanup(self):
        self.run_drill(True)

    def test_unhealthy_drill_cleans_up(self):
        self.run_drill(False)

    def test_integrity_diagnostics_prevent_boot_and_clean_up(self):
        for result in ('row 1 missing from index users_email', '', 'ok\nrow 1 missing from index users_email'):
            with self.subTest(result=result):
                self.run_drill(True, integrity_result=result)

    def test_integrity_command_failure_prevents_boot_and_cleans_up(self):
        self.run_drill(True, integrity_status=1)


if __name__ == '__main__':
    unittest.main()
