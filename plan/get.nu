#!/usr/bin/env nu

# View the current plan checklist and step progress for this session
def main [] {
    let sess = ($env.KEN_SESSION? | default "default")
    let plan_file = ($env.HOME | path join ".cache" "ken" "sessions" $"($sess)_plan.nuon")

    if not ($plan_file | path exists) {
        return $"No active plan found for session '($sess)'. Use plan/set to create one."
    }

    let plan_data = (open $plan_file)
    let goal = ($plan_data.goal? | default "No goal specified")
    let steps = ($plan_data.steps? | default [])

    let formatted = ($steps | each { |s|
        let icon = match ($s.status? | default "todo") {
            "done" => "[x]"
            "in_progress" => "[>]"
            "failed" => "[!]"
            _ => "[ ]"
        }
        let v_note = if not ($s.verification? | default "" | is-empty) {
            $" \(verified: ($s.verification)\)"
        } else {
            ""
        }
        $"($icon) Step ($s.id): ($s.title) - ($s.status)($v_note)"
    } | str join "\n")

    $"=== Plan: ($goal) \(Session: ($sess)\) ===\n($formatted)"
}
