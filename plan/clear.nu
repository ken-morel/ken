#!/usr/bin/env nu

# Clear the plan for the current session
def main [] {
    let sess = ($env.KEN_SESSION? | default "default")
    let plan_file = ($env.HOME | path join ".cache" "ken" "sessions" $"($sess)_plan.nuon")
    if ($plan_file | path exists) {
        rm -f $plan_file
        $"Plan for session '($sess)' cleared."
    } else {
        $"No active plan for session '($sess)'."
    }
}
