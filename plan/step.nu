#!/usr/bin/env nu

# Update progress or status of a specific step in the session plan
def main [
    id: int                              # Step ID number to update
    status: string                       # Status: todo, in_progress, done, failed
    --verification (-v): string = ""     # Evidence or verification command output proving completion
    --notes (-n): string = ""            # Optional notes or details
] {
    let sess = ($env.KEN_SESSION? | default "default")
    let plan_file = ($env.HOME | path join ".cache" "ken" "sessions" $"($sess)_plan.nuon")

    if not ($plan_file | path exists) {
        return $"Error: No active plan found for session '($sess)'."
    }

    mut plan_data = (open $plan_file)
    let existing_ids = ($plan_data.steps | get id | each { into int })
    if not ($id in $existing_ids) {
        return $"Error: Step ID ($id) not found in plan."
    }

    let updated_steps = ($plan_data.steps | each { |s|
        if ($s.id | into int) == $id {
            mut updated = ($s | upsert status $status)
            if not ($verification | is-empty) {
                $updated = ($updated | upsert verification $verification)
            }
            if not ($notes | is-empty) {
                $updated = ($updated | upsert notes $notes)
            }
            $updated
        } else {
            $s
        }
    })

    $plan_data.steps = $updated_steps
    $plan_data.updated_at = (date now | format date "%Y-%m-%d %H:%M:%S")
    $plan_data | to nuon | save -f $plan_file

    $"Updated Step ($id) -> ($status)"
}
