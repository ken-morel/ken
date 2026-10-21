#!/usr/bin/env nu

# Spawn a transient background process in an isolated cgroup using systemd-run
def main [
    cmd: string                 # Command to execute in background
    --name (-n): string = ""    # Optional human-readable task label
] {
    let sess = ($env.KEN_SESSION? | default "default")
    let ts = (date now | format date "%s")
    let safe_label = (if not ($name | is-empty) {
        $name | str replace -a -r "[^a-zA-Z0-9_-]+" "-" | str trim -c "-"
    } else {
        $"job-($ts)"
    })
    let unit_name = $"ken-($sess)-($safe_label)"

    let res = (^systemd-run --user --unit=$unit_name --remain-after-exit bash -c $cmd | complete)
    if $res.exit_code == 0 {
        $"Task spawned successfully!\nTask ID: ($unit_name)\nStatus: running\nCheck status: task/status ($unit_name)\nView logs: task/logs ($unit_name)"
    } else {
        $"Failed to spawn task: ($res.stderr)\n($res.stdout)"
    }
}
