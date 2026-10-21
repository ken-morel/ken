#!/usr/bin/env nu

# Generate an image using local Stable Diffusion with LFM visual prompt enrichment
def main [
    --description (-d): string   # Natural language image description
    --size: string = "medium"    # small (256x256), medium (384x384), big (512x512)
    --aspect_ratio: string = "square" # square, landscape, portrait
    --preset: string = "photo"   # photo, illustration, anime, cinematic, doodle, pixel_art
] {
    # Use LFM to expand description into rich visual details and negative prompt
    let lfm_prompt = $"Turn this image description into a detailed diffusion visual prompt and negative prompt.\nInput: ($description)\nOutput format:\nPROMPT: <detailed prompt>\nNEGATIVE: <unwanted elements>"
    let ken_root = ($env.KEN_ROOT? | default ($env.HOME | path join "ken"))
    let ken_nu = ($ken_root | path join "ken.nu")
    let lfm_res = if ($ken_nu | path exists) {
        ^$ken_nu raw $lfm_prompt -m l --max-tokens 150 | complete
    } else {
        ^ken raw $lfm_prompt -m l --max-tokens 150 | complete
    }
    mut final_prompt = $description
    mut neg_prompt = ""

    if $lfm_res.exit_code == 0 and not ($lfm_res.stdout | is-empty) {
        let text = $lfm_res.stdout
        for line in ($text | lines) {
            if ($line | str starts-with "PROMPT:") {
                $final_prompt = ($line | str substring 7.. | str trim)
            } else if ($line | str starts-with "NEGATIVE:") {
                $neg_prompt = ($line | str substring 9.. | str trim)
            }
        }
    }
    let backend = (which gen-img | get path.0? | default ($env.HOME | path join ".config" "bin" "gen-img"))
    if not ($backend | path exists) {
        return "Error: Image generation backend 'gen-img' not found."
    }

    let out_file = ($env.HOME | path join $"image_(date now | format date '%s').png")
    let prompt_with_preset = (if not ($preset | is-empty) and ($preset != "photo") {
        $"($final_prompt), ($preset) style"
    } else {
        $final_prompt
    })

    let res = (^$backend $prompt_with_preset $out_file 1 | complete)
    if ($res.exit_code == 0) and ($out_file | path exists) {
        $"Image generated successfully!\nFile: ($out_file)\nPrompt: ($prompt_with_preset)"
    } else {
        $"Image generation failed: ($res.stderr)\n($res.stdout)"
    }
}
