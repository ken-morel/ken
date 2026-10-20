#!/usr/bin/env nu

# Generate an image using local Stable Diffusion with LFM visual prompt enrichment
def main [
    --description (-d): string   # Natural language image description
    --size: string = "medium"    # small (256x256), medium (384x384), big (512x512)
    --aspect_ratio: string = "square" # square, landscape, portrait
    --preset: string = "photo"   # photo, illustration, anime, cinematic, doodle, pixel_art
] {
    if ("/dev/tty" | path exists) {
        $"\n[gen_image] enriching visual description with lfm...\n" | save --append "/dev/tty"
    }

    # Use LFM to expand description into rich visual details and negative prompt
    let lfm_prompt = $"Turn this image description into a detailed diffusion visual prompt and negative prompt.\nInput: ($description)\nOutput format:\nPROMPT: <detailed prompt>\nNEGATIVE: <unwanted elements>"
    let lfm_body = {
        model: "lfm",
        messages: [{ role: "user", content: $lfm_prompt }],
        max_tokens: 150
    }
    let lfm_res = (try { http post --content-type application/json http://127.0.0.1:6172/v1/chat/completions $lfm_body } catch { null })
    mut final_prompt = $description
    mut neg_prompt = ""

    if ($lfm_res != null) {
        let text = $lfm_res.choices.0.message.content
        for line in ($text | lines) {
            if ($line | str starts-with "PROMPT:") {
                $final_prompt = ($line | str substring 7.. | str trim)
            } else if ($line | str starts-with "NEGATIVE:") {
                $neg_prompt = ($line | str substring 9.. | str trim)
            }
        }
    }

    if ("/dev/tty" | path exists) {
        $"[gen_image] rendering: ($final_prompt | str substring 0..50)...\n" | save --append "/dev/tty"
    }

    let backend = ($env.HOME | path join "ken/media/gen_image.k")
    mut args = [
        "--prompt" $final_prompt
        "--size" $size
        "--aspect-ratio" $aspect_ratio
        "--preset" $preset
    ]
    if ($neg_prompt | is-not-empty) {
        $args = ($args | append ["--negative-prompt" $neg_prompt])
    }

    ^$backend ...$args
}
