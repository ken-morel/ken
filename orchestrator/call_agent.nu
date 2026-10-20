#!/usr/bin/env nu

# Delegate a task to a specialized domain agent
def main [
    --agent (-a): string          # Target agent: mail, fs, code, mem, sys, voice, agy
    --task (-t): string           # The specific prompt or task for the agent
    --model (-m): string = "qwen" # Model to run the agent with (default: qwen)
] {
    let depth = (try { $env.KEN_DEPTH | into int } catch { 0 })
    if $depth >= 3 {
        return "Error: Maximum agent recursion depth (3) reached. Synthesize final answer."
    }

    let target = $"($agent).($model)"
    let next_depth = ($depth + 1 | into string)

    # Print ASCII progress report to /dev/tty
    if ("/dev/tty" | path exists) {
        $"\n[call] agent: ($agent) | model: ($model) | task: ($task | str substring 0..60)...\n" | save --append "/dev/tty"
    }

    let ken_nu = ($env.KEN_ROOT? | default ($env.HOME | path join "ken") | path join "ken.nu")

    let res = (with-env { KEN_DEPTH: $next_depth } {
        if ($ken_nu | path exists) {
            ^$ken_nu $target $task | complete
        } else {
            ^ken $target $task | complete
        }
    })

    if ("/dev/tty" | path exists) {
        let lines_n = ($res.stdout | lines | length)
        $"\n[done] agent: ($agent) | lines: ($lines_n) | exit: ($res.exit_code)\n" | save --append "/dev/tty"
    }

    if $res.exit_code == 0 {
        $res.stdout
    } else {
        $"Error running agent ($agent): ($res.stderr)\n($res.stdout)"
    }
}
