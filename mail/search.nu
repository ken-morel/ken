#!/usr/bin/env nu

# Search emails by topic or query using Notmuch with LFM summarization
def main [
    --query (-q): string         # Natural language search query or keywords
    --limit (-n): int = 5        # Number of emails to inspect
] {
    if ("/dev/tty" | path exists) {
        $"\n[mail/search] query: '($query)' | inspecting top ($limit) emails...\n" | save --append "/dev/tty"
    }

    # Find matching threads
    let threads_res = (^notmuch search --sort=newest-first --limit=($limit | into string) $query | complete)
    let thread_lines = ($threads_res.stdout | lines | where ($it | is-not-empty))
    if ($thread_lines | is-empty) {
        return $"No emails found matching: ($query)"
    }

    # Extract thread headers and snippets
    mut candidates = []
    for line in $thread_lines {
        let parts = ($line | split row " " | compact)
        let thread_id = ($parts | get 0)
        let preview = ($line | str substring 25..)
        $candidates = ($candidates | append $"[($thread_id)] ($preview)")
    }

    let cand_str = ($candidates | str join "\n")

    # Run through LFM to distill and answer the query based on the emails
    if ("/dev/tty" | path exists) {
        $"[lfm] synthesizing answers from matching emails...\n" | save --append "/dev/tty"
    }

    let lfm_prompt = $"User question about emails: ($query)\n\nFound Email Threads:\n($cand_str)\n\nTask: State the most relevant emails found, their thread IDs, and concise summary answering the question."
    let ken_root = ($env.KEN_ROOT? | default ($env.HOME | path join "ken"))
    let ken_nu = ($ken_root | path join "ken.nu")
    let lfm_res = if ($ken_nu | path exists) {
        ^$ken_nu raw $lfm_prompt -m l --max-tokens 400 | complete
    } else {
        ^ken raw $lfm_prompt -m l --max-tokens 400 | complete
    }
    if $lfm_res.exit_code == 0 and not ($lfm_res.stdout | is-empty) {
        return $lfm_res.stdout
    }

    $cand_str
}
