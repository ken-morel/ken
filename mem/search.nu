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

    let payload = {
        model: "lfm"
        messages: [
            { role: "user", content: $prompt }
        ]
        temperature: 0.1
        max_tokens: 1024
        stream: false
    }

    let res = (try { http post --content-type "application/json" "http://127.0.0.1:6172/v1/chat/completions" ($payload | to json) } catch { |e| null })
    if ($res == null) {
        return "LFM memory search error: connection to local server failed."
    }

    $res.choices?.0?.message?.content? | default "No relevant memories found."
}
