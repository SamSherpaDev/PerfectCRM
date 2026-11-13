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
ATTACHMENTS_TIMER = DEPLOY / 'perfectcrm-attachments-backup.timer'
ATTACHMENTS_SERVICE = DEPLOY / 'perfectcrm-attachments-backup.service'
APP_DIR = '/opt/apps/perfectcrm'
SYSTEMD_ANALYZE = shutil.which('systemd-analyze')
needs_systemd = unittest.skipUnless(SYSTEMD_ANALYZE, 'systemd-analyze not installed')


def unit(path):
    parser = configparser.ConfigParser(interpolation=None)
    parser.optionxform = str
    parser.read_string(path.read_text())
    return parser


def next_runs(timer):
    # Seen from Pacific time, a schedule that is not pinned to UTC drifts.
    calendar = unit(timer)['Timer']['OnCalendar']
    result = subprocess.run([SYSTEMD_ANALYZE, 'calendar', '--iterations=2', calendar],
                            text=True, capture_output=True,
                            env=dict(os.environ, TZ='America/Los_Angeles'))
    assert result.returncode == 0, result.stderr
    return [datetime.strptime(stamp, '%Y-%m-%d %H:%M:%S') for stamp in
            re.findall(r'\(in UTC\): \w+ (\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) UTC', result.stdout)]


def run_exec_start(service_path, script_name, env_file, report):
    # Runs the unit's ExecStart with the app directory moved to a fixture.
    with tempfile.TemporaryDirectory() as directory:
        app = Path(directory)
        if env_file is not None:
            (app / '.env.nightly-backup').write_text(env_file)
        (app / '.env.app').write_text('IMAGE_TAG=wrong-file\nATTACHMENTS_ACCESS=wrong-file\n')
        script = app / script_name
        script.write_text(f'#!/bin/sh\nprintf "%s|%s\\n" "{report}" "$RCLONE_CONFIG"\nexit 3\n')
        script.chmod(0o700)
        service = unit(service_path)['Service']
        command = [arg.replace(APP_DIR, directory) for arg in shlex.split(service['ExecStart'])]
        environment = dict(assignment.split('=', 1) for assignment in shlex.split(service['Environment']))
        environment['PATH'] = os.environ['PATH']
        return subprocess.run(command, env=environment, text=True, capture_output=True, timeout=10)


class DriveBackupScheduleTest(unittest.TestCase):
    @needs_systemd
    def test_systemd_accepts_both_units(self):
        result = subprocess.run([SYSTEMD_ANALYZE, 'verify', str(TIMER), str(SERVICE)],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    @needs_systemd
    def test_timer_fires_once_a_day_at_1145_utc(self):
        runs = next_runs(TIMER)
        self.assertEqual(len(runs), 2, runs)
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
        return run_exec_start(SERVICE, 'drive-backup.sh', env_file, '$IMAGE_TAG')

    def test_service_exports_the_nightly_environment_to_the_backup(self):
        result = self.run_exec_start('IMAGE_TAG=sha-from-env-file\n')
        self.assertEqual(result.stdout, 'sha-from-env-file|/root/.config/rclone/rclone.conf\n')
        self.assertEqual(result.returncode, 3)

    def test_service_fails_without_the_nightly_environment(self):
        result = self.run_exec_start(None)
        self.assertEqual(result.stdout, '')
        self.assertNotEqual(result.returncode, 0)


class AttachmentsBackupScheduleTest(unittest.TestCase):
    @needs_systemd
    def test_systemd_accepts_both_units(self):
        result = subprocess.run([SYSTEMD_ANALYZE, 'verify', str(ATTACHMENTS_TIMER), str(ATTACHMENTS_SERVICE)],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    @needs_systemd
    def test_timer_fires_hourly_at_minute_20_utc(self):
        # Minute 20 keeps clear of the 11:30 and 11:45 UTC database jobs.
        runs = next_runs(ATTACHMENTS_TIMER)
        self.assertEqual(len(runs), 2, runs)
        self.assertEqual([(run.minute, run.second) for run in runs], [(20, 0), (20, 0)])
        self.assertEqual(runs[1] - runs[0], timedelta(hours=1))

    def test_timer_starts_the_mirror_without_catch_up(self):
        timer = unit(ATTACHMENTS_TIMER)
        self.assertEqual(timer['Timer']['Unit'], ATTACHMENTS_SERVICE.name)
        self.assertFalse(timer.getboolean('Timer', 'Persistent'))
        self.assertIn('timers.target', timer['Install']['WantedBy'].split())

    def test_service_is_a_oneshot_logging_to_its_own_file(self):
        service = unit(ATTACHMENTS_SERVICE)['Service']
        self.assertEqual(service['Type'], 'oneshot')
        self.assertEqual(service['StandardOutput'], 'append:/var/log/perfectcrm-attachments-backup.log')
        self.assertEqual(service['StandardError'], service['StandardOutput'])

    def test_service_exports_the_nightly_environment_to_the_mirror(self):
        result = run_exec_start(ATTACHMENTS_SERVICE, 'drive-attachments-backup.sh',
                                'ATTACHMENTS_ACCESS=remote\n', '$ATTACHMENTS_ACCESS')
        self.assertEqual(result.stdout, 'remote|/root/.config/rclone/rclone.conf\n')
        self.assertEqual(result.returncode, 3)

    def test_service_fails_without_the_nightly_environment(self):
        result = run_exec_start(ATTACHMENTS_SERVICE, 'drive-attachments-backup.sh', None, '$ATTACHMENTS_ACCESS')
        self.assertEqual(result.stdout, '')
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
