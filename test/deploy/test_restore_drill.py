import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


# Docker is the executable boundary here. The stub rejects unsafe app starts
# and records each request so failures and cleanup can be exercised without R2.
DOCKER = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
state = Path(os.environ['STATE'])
with (state / 'docker.jsonl').open('a') as log:
    log.write(json.dumps(args) + '\n')
if args[0] == 'inspect':
    print(os.environ['APP_IMAGE'] if args[-1] == 'perfectcrm-app' else os.environ['CONTAINER_RUNNING'])
elif args[0] == 'run':
    if '-d' in args:
        (state / 'booted').touch()
        if ('--network' not in args or args[args.index('--network') + 1] != 'none'
                or any(a in ('-p', '-P', '--publish', '--publish-all', '--env-file') for a in args)
                or any('SOLID_QUEUE_IN_PUMA=' in a for a in args)):
            sys.exit('unsafe app start rejected')
        (state / 'container').touch()
        print('drill-container-id')
        sys.exit(int(os.environ['BOOT_STATUS']))
    elif 'sqlite3' in args:
        print(os.environ['INTEGRITY_RESULT'])
        sys.exit(int(os.environ['INTEGRITY_STATUS']))
    elif 'restore' in args:
        sys.exit(int(os.environ['RESTORE_STATUS']))
elif args[0] == 'exec':
    if 'curl' in args:
        print(os.environ.get('HEALTH_CODE', '200'))
        sys.exit(int(os.environ['HEALTH_STATUS']))
    sys.exit(int(os.environ['RECORD_STATUS']))
elif args[0] == 'rm':
    if os.environ['REMOVE_STATUS'] != '0':
        sys.exit(int(os.environ['REMOVE_STATUS']))
    (state / 'container').unlink(missing_ok=True)
'''

# Host rclone for RESTORE_SOURCE=drive: lists DRIVE_LISTING and streams a
# gzip archive (or bytes that are not gzip) for whichever file is requested.
RCLONE = r'''#!/usr/bin/env python3
import gzip
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
with (Path(os.environ['STATE']) / 'rclone.jsonl').open('a') as log:
    log.write(json.dumps(args) + '\n')
if args[0] == 'lsf':
    sys.stdout.write(os.environ['DRIVE_LISTING'])
elif args[0] == 'cat':
    data = b'SQLite format 3 stand-in'
    sys.stdout.buffer.write(data if os.environ['DRIVE_ARCHIVE'] == 'corrupt' else gzip.compress(data))
else:
    sys.exit('unexpected rclone command')
'''

NEWEST_LISTING = '\n'.join([
    'production-2026-11-09.sqlite3.gz', 'production-2026-11-11.sqlite3.gz',
    'production-2026-10-30.sqlite3.gz', 'production_queue-2026-11-10.sqlite3.gz',
    'production_queue-2026-11-11.sqlite3.gz', 'production-2026-11-12.sqlite3.gz.partial',
    'notes.txt', ''])


class RestoreDrillTest(unittest.TestCase):
    def run_drill(self, *, integrity_result='ok', health_code='200',
                  app_image='sha256:running-image', container_running='true',
                  restore_source=None, drive_listing=NEWEST_LISTING, drive_archive='valid',
                  **statuses):
        # Keep all fixture state outside the checkout, including failed scratch.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / 'app'
            app.mkdir()
            script = root / 'restore-drill.sh'
            shutil.copy(Path(__file__).resolve().parents[2] / 'deploy/restore-drill.sh', script)
            # Sourcing either file as a shell script would execute this sentinel.
            (app / '.env.app').write_text('exit 81\n')
            (app / '.env.litestream').write_text('exit 82\n')
            (app / 'litestream.yml').touch()
            commands = root / 'commands'
            commands.mkdir()
            (commands / 'docker').write_text(DOCKER)
            (commands / 'rclone').write_text(RCLONE)
            (commands / 'sleep').write_text('#!/bin/sh\nexit 0\n')
            (commands / 'rm').write_text('''#!/bin/sh
printf '%s\\n' "$*" >> "$STATE/removals"
if [ "$SCRATCH_REMOVE_STATUS" != 0 ]; then exit "$SCRATCH_REMOVE_STATUS"; fi
exec /bin/rm "$@"
''')
            for command in commands.iterdir():
                command.chmod(0o700)
            environment = dict(os.environ, PATH=f'{commands}:{os.environ["PATH"]}',
                               STATE=str(root), TMPDIR=str(root), INTEGRITY_RESULT=integrity_result,
                               LITESTREAM_BUCKET="fixture", SPACES_ENDPOINT="fixture",
                               SPACES_REGION="auto", HEALTH_CODE=health_code,
                               APP_IMAGE=app_image, CONTAINER_RUNNING=container_running,
                               DRIVE_LISTING=drive_listing, DRIVE_ARCHIVE=drive_archive)
            environment.pop('RESTORE_SOURCE', None)
            environment.pop('DRIVE_BACKUP_REMOTE', None)
            if restore_source is not None:
                environment['RESTORE_SOURCE'] = restore_source
            for name in ('HEALTH', 'INTEGRITY', 'RESTORE', 'BOOT', 'RECORD', 'REMOVE', 'SCRATCH_REMOVE'):
                environment[f'{name}_STATUS'] = str(statuses.get(name.lower(), 0))
            result = subprocess.run(['bash', str(script), str(app)], env=environment,
                                    text=True, capture_output=True, timeout=10)
            docker_log = root / 'docker.jsonl'
            calls = [json.loads(line) for line in docker_log.read_text().splitlines()] if docker_log.exists() else []
            rclone_log = root / 'rclone.jsonl'
            self.rclone_calls = ([json.loads(line) for line in rclone_log.read_text().splitlines()]
                                 if rclone_log.exists() else [])
            if result.returncode == 0:
                self.assertFalse((root / 'container').exists(), 'successful drill must remove its container')
            scratch = list(root.glob('perfectcrm-restore-drill.*'))
            return result, calls, scratch, (root / 'removals').exists()

    def test_healthy_drill_is_offline_and_cleans_up(self):
        result, calls, scratch, removed = self.run_drill()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Restore drill passed', result.stdout)
        boot = next(call for call in calls if call[:2] == ['run', '-d'])
        self.assertIn('sha256:running-image', boot)
        self.assertNotIn('--env-file', boot)
        self.assertEqual(boot[boot.index('--network') + 1], 'none')
        self.assertEqual([boot[index + 1] for index, arg in enumerate(boot) if arg == '-e'],
                         ['RAILS_ENV=production', 'SECRET_KEY_BASE_DUMMY=1'])
        for call in calls:
            if call[0] == 'run' and 'restore' not in call:
                self.assertEqual(call[call.index('--network') + 1], 'none')
                self.assertIn('sha256:running-image', call)
        self.assertTrue(any(call[0] == 'exec' and 'curl' in call for call in calls))
        self.assertTrue(any(call[0] == 'exec' and '--probe' in call for call in calls))
        restore = next(call for call in calls if 'restore' in call)
        self.assertEqual(restore[-6:], ['restore', '-config', '/etc/litestream.yml', '-o',
                                      '/restore/production.sqlite3', '/rails/storage/production.sqlite3'])
        self.assertTrue(any(call[0] == 'rm' for call in calls))
        self.assertEqual(scratch, [])
        self.assertTrue(removed)

    def test_integrity_diagnostics_prevent_boot_and_clean_up(self):
        for text in ('row 1 missing from index users_email', '', 'ok\nerror'):
            with self.subTest(result=text):
                result, calls, scratch, _ = self.run_drill(integrity_result=text)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('integrity check', result.stderr)
                self.assertFalse(any(call[:2] == ['run', '-d'] for call in calls))
                self.assertEqual(scratch, [])

    def test_restore_and_integrity_command_failures_prevent_boot(self):
        for name in ('restore', 'integrity'):
            with self.subTest(command=name):
                result, calls, scratch, _ = self.run_drill(**{name: 1})
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(call[:2] == ['run', '-d'] for call in calls))
                self.assertEqual(scratch, [])

    def test_boot_health_and_record_failures_clean_up(self):
        for name in ('boot', 'health', 'record'):
            with self.subTest(command=name):
                result, calls, scratch, _ = self.run_drill(**{name: 1})
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('Restore drill passed', result.stdout)
                self.assertTrue(any(call[0] == 'rm' for call in calls))
                self.assertEqual(scratch, [])

    def test_redirect_is_not_a_healthy_response(self):
        result, calls, scratch, _ = self.run_drill(health_code='301')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any('--probe' in call for call in calls))
        self.assertEqual(scratch, [])

    def test_exited_app_fails_immediately_with_logs_and_cleanup(self):
        result, calls, scratch, _ = self.run_drill(health=1, container_running='false')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('exited during boot', result.stderr)
        self.assertTrue(any(call[0] == 'logs' for call in calls))
        self.assertEqual(sum(call[0] == 'exec' for call in calls), 1)
        self.assertTrue(any(call[0] == 'rm' for call in calls))
        self.assertEqual(scratch, [])

    def test_stopped_production_app_prevents_restore(self):
        result, calls, scratch, _ = self.run_drill(app_image='')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('must be running', result.stderr)
        self.assertFalse(any(call[0] == 'run' for call in calls))
        self.assertEqual(scratch, [])

    def test_both_cleanup_failures_are_reported(self):
        result, _, scratch, removed = self.run_drill(remove=1, scratch_remove=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('could not remove container', result.stderr)
        self.assertIn('could not remove scratch', result.stderr)
        self.assertNotIn('Restore drill passed', result.stdout)
        self.assertTrue(removed)
        self.assertEqual(len(scratch), 1)

    def test_container_cleanup_failure_still_removes_scratch(self):
        result, _, scratch, removed = self.run_drill(remove=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('cleanup', result.stderr)
        self.assertIn('container', result.stderr)
        self.assertTrue(removed)
        self.assertEqual(scratch, [])

    def test_scratch_cleanup_failure_is_reported(self):
        result, calls, scratch, removed = self.run_drill(scratch_remove=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('cleanup', result.stderr)
        self.assertIn('scratch', result.stderr)
        self.assertTrue(any(call[0] == 'rm' for call in calls))
        self.assertTrue(removed)
        self.assertEqual(len(scratch), 1)

    def test_litestream_stays_the_default_source(self):
        result, calls, _, _ = self.run_drill()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any('restore' in call for call in calls))
        self.assertEqual(self.rclone_calls, [])

    def test_drive_source_restores_newest_daily_archives_offline(self):
        result, calls, scratch, _ = self.run_drill(restore_source='drive')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Restore drill passed', result.stdout)
        self.assertFalse(any('restore' in call or '--env-file' in call for call in calls))
        self.assertEqual(self.rclone_calls, [
            ['lsf', '--files-only', 'sherpa-backup:perfectcrm/daily'],
            ['cat', 'sherpa-backup:perfectcrm/daily/production-2026-11-11.sqlite3.gz'],
            ['cat', 'sherpa-backup:perfectcrm/daily/production_queue-2026-11-11.sqlite3.gz'],
        ])
        checked = [call[-2] for call in calls if call[0] == 'run' and 'sqlite3' in call]
        self.assertEqual(checked, ['/restore/production.sqlite3', '/restore/production_queue.sqlite3'])
        for call in calls:
            if call[0] == 'run':
                self.assertEqual(call[call.index('--network') + 1], 'none')
        self.assertTrue(any(call[0] == 'exec' and '--probe' in call for call in calls))
        self.assertEqual(scratch, [])

    def test_drive_source_without_an_archive_fails_before_boot(self):
        listing = 'production-2026-11-11.sqlite3.gz\nproduction_queue-2026-11-11.sqlite3.gz.partial\n'
        for name, text in (('empty', ''), ('queue missing', listing)):
            with self.subTest(listing=name):
                result, calls, scratch, _ = self.run_drill(restore_source='drive', drive_listing=text)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('archive in the Drive daily backups', result.stderr)
                self.assertFalse(any(call[0] == 'run' for call in calls))
                self.assertEqual(scratch, [])

    def test_drive_source_corrupt_archive_fails_before_boot(self):
        result, calls, scratch, _ = self.run_drill(restore_source='drive', drive_archive='corrupt')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('did not download and decompress', result.stderr)
        self.assertFalse(any(call[0] == 'run' for call in calls))
        self.assertEqual(scratch, [])

    def test_unknown_source_fails_before_any_work(self):
        result, calls, scratch, _ = self.run_drill(restore_source='r2')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('RESTORE_SOURCE must be litestream or drive', result.stderr)
        self.assertEqual(calls, [])
        self.assertEqual(self.rclone_calls, [])
        self.assertEqual(scratch, [])


if __name__ == '__main__':
    unittest.main()
