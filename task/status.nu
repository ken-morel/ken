#!/usr/bin/env nu

# Check active status, exit code, and execution state of a background task
def main [
    task_id: string             # Unit name (e.g. ken-default-job-12345678)
] {
    let active_res = (^systemctl --user is-active $task_id | complete)
    let state = ($active_res.stdout | str trim)

    let show_res = (^systemctl --user show $task_id --property=ActiveState,SubState,Result,ExecMainStatus,ExecMainStartTime,ExecMainExitTimestamp | complete)
    let props = ($show_res.stdout | lines | parse "{k}={v}" | reduce -f {} { |it, acc| $acc | insert $it.k $it.v })

    let is_done = ($state in ["inactive" "failed"])
    let exit_code = ($props.ExecMainStatus? | default "unknown")
    let result = ($props.Result? | default "unknown")

    $"Task: ($task_id)
State: ($state)
SubState: ($props.SubState? | default 'unknown')
Result: ($result)
ExitCode: ($exit_code)
Done: ($is_done)"
}
