#!/usr/bin/env nu

# Scrape a web URL or read a file, and extract targeted answers using LFM
def main [
    --target (-t): string        # Web URL (http/https) or local file path
    --query (-q): string = ""    # Specific information, question, or data to extract
] {
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
        let lfm_prompt = $"Document content:\n($raw_text | str substring 0..8000)\n\nQuestion/Goal: ($query)\nExtract the exact, concise answer based strictly on the text."
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
    }

    if ($raw_text | str length) > 3000 {
        $"($raw_text | str substring 0..3000)\n...[truncated]"
    } else {
        $raw_text
    }
}
