#!/usr/bin/env nu

# Set or replace the multi-step plan for the current session
def main [
    --goal (-g): string                  # High-level goal of this plan
    --steps (-s): string                 # JSON or NUON list of steps: [{id: 1, title: "...", status: "todo"}]
] {
    let sess = ($env.KEN_SESSION? | default "default")
    let s_dir = ($env.HOME | path join ".cache" "ken" "sessions")
    mkdir $s_dir
    let plan_file = ($s_dir | path join $"($sess)_plan.nuon")

    let parsed_steps = (try {
        let from_j = (try { $steps | from json } catch { null })
        if $from_j != null { $from_j } else { $steps | from nuon }
    } catch {
        return "Error: Could not parse steps. Provide a valid JSON or NUON array of step records."
    })

    let plan_data = {
        session_id: $sess
        goal: $goal
        created_at: (date now | format date "%Y-%m-%d %H:%M:%S")
        updated_at: (date now | format date "%Y-%m-%d %H:%M:%S")
        steps: $parsed_steps
    }

    $plan_data | to nuon | save -f $plan_file
    $"Plan initialized for session '($sess)' with \(($parsed_steps | length)\) steps.\nGoal: ($goal)"
}
