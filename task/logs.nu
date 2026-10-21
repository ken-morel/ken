#!/usr/bin/env nu

# Read journal logs for a running or finished background task
def main [
    task_id: string             # Unit name (e.g. ken-default-job-12345678)
    --lines (-n): int = 50      # Maximum number of recent log lines to display
] {
    let unit = (if ($task_id | str ends-with ".service") { $task_id } else { $"($task_id).service" })
    let res = (^journalctl --user $"_SYSTEMD_USER_UNIT=($unit)" -n ($lines | into string) --no-pager | complete)
    if ($res.exit_code == 0) and not ($res.stdout | is-empty) {
        $res.stdout
    } else {
        $"No logs found for task '($task_id)'."
    }
}
