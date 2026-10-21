#!/usr/bin/env nu

# Stop and clean up a running background task
def main [
    task_id: string             # Unit name (e.g. ken-default-job-12345678)
] {
    let res = (^systemctl --user stop $task_id | complete)
    if $res.exit_code == 0 {
        $"Task '($task_id)' stopped successfully."
    } else {
        $"Failed to stop task '($task_id)': ($res.stderr)"
    }
}
