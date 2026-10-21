#!/usr/bin/env nu

# List active and recent Ken background tasks
def main [] {
    let res = (^systemctl --user list-units "ken-*" --all --no-pager | complete)
    if ($res.exit_code == 0) and not ($res.stdout | is-empty) {
        $res.stdout
    } else {
        "No active or recent Ken tasks found."
    }
}
