#!/usr/bin/env nu

# Save information, facts, or user preferences to persistent memory under a descriptive key
def main [
    name: string    # A descriptive identifier/topic name (e.g. user_preferences, project_notes)
    content: string # The factual information or notes to remember
] {
    let raw_safe = ($name | str replace -a -r "[^a-zA-Z0-9_-]+" "_" | str trim -c "_")
    let safe_name = if ($raw_safe | is-empty) { $"note_(date now | format date '%s')" } else { $raw_safe }
    let mem_dir = ($env.HOME | path join ".config" "ken" "_mem")
    mkdir $mem_dir
    let file_path = ($mem_dir | path join $"($safe_name).md")
    $content | save -f $file_path
    $"Saved memory '($safe_name)' successfully."
}
