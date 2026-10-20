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
    let lfm_body = {
        model: "lfm",
        messages: [{ role: "user", content: $lfm_prompt }],
        max_tokens: 400
    }
    let lfm_res = (try { http post --content-type application/json http://127.0.0.1:6172/v1/chat/completions $lfm_body } catch { null })
    if ($lfm_res != null) {
        return $lfm_res.choices.0.message.content
    }

    $cand_str
}
