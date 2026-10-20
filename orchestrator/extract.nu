#!/usr/bin/env nu

# Scrape a web URL or read a file, and extract targeted answers using LFM
def main [
    --target (-t): string        # Web URL (http/https) or local file path
    --query (-q): string = ""    # Specific information, question, or data to extract
] {
    if ("/dev/tty" | path exists) {
        $"\n[extract] target: ($target) | query: ($query)\n" | save --append "/dev/tty"
    }

    let raw_text = (if ($target | str starts-with "http://") or ($target | str starts-with "https://") {
        let cha_res = (^cha $target -d -M | complete)
        if ($cha_res.exit_code == 0) and ($cha_res.stdout | is-not-empty) {
            $cha_res.stdout
        } else {
            http get $target
        }
    } else if ($target | path exists) {
        open $target | into string
    } else {
        $"Error: Target '($target)' not found."
    })

    if ($raw_text | str starts-with "Error:") {
        return $raw_text
    }

    # If query is provided, pipe through LFM to extract only the target information
    if ($query | is-not-empty) {
        if ("/dev/tty" | path exists) {
            $"[lfm] extracting target information from ($raw_text | str length) chars...\n" | save --append "/dev/tty"
        }
        let lfm_prompt = $"Document content:\n($raw_text | str substring 0..8000)\n\nQuestion/Goal: ($query)\nExtract the exact, concise answer based strictly on the text."
        let lfm_body = {
            model: "lfm",
            messages: [{ role: "user", content: $lfm_prompt }],
            max_tokens: 400
        }
        let lfm_res = (try { http post --content-type application/json http://127.0.0.1:6172/v1/chat/completions $lfm_body } catch { null })
        if ($lfm_res != null) {
            let out = $lfm_res.choices.0.message.content
            if ("/dev/tty" | path exists) {
                $"[done] extract -> ($out | lines | length) lines\n" | save --append "/dev/tty"
            }
            return $out
        }
    }

    if ($raw_text | str length) > 3000 {
        $"($raw_text | str substring 0..3000)\n...[truncated]"
    } else {
        $raw_text
    }
}
