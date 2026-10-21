#!/usr/bin/env nu

# Retrieve and read the full content of a saved memory by its descriptive name
def main [
    name: string # The descriptive name/topic of the memory (obtained from list)
] {
    let safe_name = ($name | str replace -a -r "[^a-zA-Z0-9_-]+" "_" | str trim -c "_")
    let mem_dir = ($env.HOME | path join ".config" "ken" "_mem")
    let file_path = ($mem_dir | path join $"($safe_name).md")
    if not ($file_path | path exists) {
        return $"Memory '($name)' not found. Use 'list' to see available memory keys."
    }

    $"Memory [($safe_name)]:\n" + (open --raw $file_path)
}
