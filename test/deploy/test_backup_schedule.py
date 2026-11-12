import configparser
from datetime import datetime, timedelta
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest


DEPLOY = Path(__file__).resolve().parents[2] / 'deploy'
TIMER = DEPLOY / 'perfectcrm-drive-backup.timer'
SERVICE = DEPLOY / 'perfectcrm-drive-backup.service'
APP_DIR = '/opt/apps/perfectcrm'
SYSTEMD_ANALYZE = shutil.which('systemd-analyze')
needs_systemd = unittest.skipUnless(SYSTEMD_ANALYZE, 'systemd-analyze not installed')


def unit(path):
    parser = configparser.ConfigParser(interpolation=None)
    parser.optionxform = str
    parser.read_string(path.read_text())
    return parser


class DriveBackupScheduleTest(unittest.TestCase):
    @needs_systemd
    def test_systemd_accepts_both_units(self):
        result = subprocess.run([SYSTEMD_ANALYZE, 'verify', str(TIMER), str(SERVICE)],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    @needs_systemd
    def test_timer_fires_once_a_day_at_1145_utc(self):
        # Seen from Pacific time, a schedule that is not pinned to UTC drifts.
        calendar = unit(TIMER)['Timer']['OnCalendar']
        result = subprocess.run([SYSTEMD_ANALYZE, 'calendar', '--iterations=2', calendar],
                                text=True, capture_output=True,
                                env=dict(os.environ, TZ='America/Los_Angeles'))
        self.assertEqual(result.returncode, 0, result.stderr)
        runs = [datetime.strptime(stamp, '%Y-%m-%d %H:%M:%S') for stamp in
                re.findall(r'\(in UTC\): \w+ (\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) UTC', result.stdout)]
        self.assertEqual(len(runs), 2, result.stdout)
        self.assertEqual([run.time().isoformat() for run in runs], ['11:45:00', '11:45:00'])
        self.assertEqual(runs[1] - runs[0], timedelta(days=1))

    def test_timer_starts_the_backup_service_without_catch_up(self):
        timer = unit(TIMER)
        self.assertEqual(timer['Timer']['Unit'], SERVICE.name)
        self.assertFalse(timer.getboolean('Timer', 'Persistent'))
        self.assertIn('timers.target', timer['Install']['WantedBy'].split())

    def test_service_is_a_oneshot_logging_to_its_own_file(self):
        service = unit(SERVICE)['Service']
        self.assertEqual(service['Type'], 'oneshot')
        self.assertEqual(service['StandardOutput'], 'append:/var/log/perfectcrm-drive-backup.log')
        self.assertEqual(service['StandardError'], service['StandardOutput'])

    def run_exec_start(self, env_file):
        # Runs the unit's ExecStart with the app directory moved to a fixture.
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory)
            if env_file is not None:
                (app / '.env.nightly-backup').write_text(env_file)
            (app / '.env.app').write_text('IMAGE_TAG=wrong-file\n')
            script = app / 'drive-backup.sh'
            script.write_text('#!/bin/sh\nprintf "%s|%s\\n" "$IMAGE_TAG" "$RCLONE_CONFIG"\nexit 3\n')
            script.chmod(0o700)
            service = unit(SERVICE)['Service']
            command = [arg.replace(APP_DIR, directory) for arg in shlex.split(service['ExecStart'])]
            environment = dict(assignment.split('=', 1) for assignment in shlex.split(service['Environment']))
            environment['PATH'] = os.environ['PATH']
            return subprocess.run(command, env=environment, text=True, capture_output=True, timeout=10)

    def test_service_exports_the_nightly_environment_to_the_backup(self):
        result = self.run_exec_start('IMAGE_TAG=sha-from-env-file\n')
        self.assertEqual(result.stdout, 'sha-from-env-file|/root/.config/rclone/rclone.conf\n')
        self.assertEqual(result.returncode, 3)

    def test_service_fails_without_the_nightly_environment(self):
        result = self.run_exec_start(None)
        self.assertEqual(result.stdout, '')
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
