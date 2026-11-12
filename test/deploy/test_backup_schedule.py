import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class DriveBackupScheduleTest(unittest.TestCase):
    def test_timer_runs_daily_in_utc_without_catchup(self):
        timer = (ROOT / 'deploy/perfectcrm-drive-backup.timer').read_text()
        self.assertIn('OnCalendar=*-*-* 11:45:00 UTC\n', timer)
        self.assertIn('Persistent=false\n', timer)
        self.assertIn('Unit=perfectcrm-drive-backup.service\n', timer)
        self.assertIn('WantedBy=timers.target\n', timer)

    def test_service_runs_drive_backup_with_existing_environment_and_own_log(self):
        service = (ROOT / 'deploy/perfectcrm-drive-backup.service').read_text()
        self.assertIn('Type=oneshot\n', service)
        self.assertIn('Environment=RCLONE_CONFIG=/root/.config/rclone/rclone.conf\n', service)
        self.assertIn(
            "ExecStart=/bin/bash -c 'set -ae; . /opt/apps/perfectcrm/.env.nightly-backup; "
            "exec /opt/apps/perfectcrm/drive-backup.sh'\n", service)
        self.assertIn('StandardOutput=append:/var/log/perfectcrm-drive-backup.log\n', service)
        self.assertIn('StandardError=append:/var/log/perfectcrm-drive-backup.log\n', service)


if __name__ == '__main__':
    unittest.main()
