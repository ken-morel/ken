#!/usr/bin/env nu

# Search persistent memories using LFM for semantic matching and synthesis
def main [
    query: string # Search query or question about saved knowledge
] {
    let mem_dir = ($env.HOME | path join ".config" "ken" "_mem")
    mkdir $mem_dir

    if ("/dev/tty" | path exists) {
        $"\n[mem/search] query: '($query)'\n" | save --append "/dev/tty"
    }

    let files = (glob ($mem_dir | path join "*.md"))
    if ($files | is-empty) {
        return $"No saved memories found in ($mem_dir)."
    }

    let all_memories = ($files | each { |f|
        let name = ($f | path parse | get stem)
        let body = (open --raw $f | str trim)
        $"=== Memory: ($name) ===\n($body)"
    } | str join "\n\n")

    let prompt = $"You are a memory synthesis assistant.
User Query: ($query)

Available Stored Memories:
($all_memories)

Instructions:
Extract and synthesize the exact information or answers answering the query from the memories above. Cite the memory name\(s\). If no memories are relevant to the query, state 'No relevant memories found for: ($query)'. Output concise plain ASCII text."

    let ken_root = ($env.KEN_ROOT? | default ($env.HOME | path join "ken"))
    let ken_nu = ($ken_root | path join "ken.nu")
    let res = if ($ken_nu | path exists) {
        ^$ken_nu raw $prompt -m l --max-tokens 1024 | complete
    } else {
        ^ken raw $prompt -m l --max-tokens 1024 | complete
    }

    if $res.exit_code == 0 and not ($res.stdout | is-empty) {
        $res.stdout
    } else {
        "No relevant memories found."
    }
}
