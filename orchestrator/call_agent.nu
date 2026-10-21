#!/usr/bin/env nu

# Delegate a task to a specialized domain agent
def main [
    --agent (-a): string          # Target agent (e.g. coder, task, plan, fs, sys, mail)
    --task (-t): string           # The specific prompt or task for the agent
    --model (-m): string = ""     # Optional model override (defaults to agent's configured model)
] {
    let depth = (try { $env.KEN_DEPTH | into int } catch { 0 })
    if $depth >= 3 {
        return "Error: Maximum agent recursion depth (3) reached. Synthesize final answer."
    }

    let ken_root = ($env.KEN_ROOT? | default ($env.HOME | path join "ken"))
    let caller_name = ($env.KEN_AGENT? | default "orchestrator")
    let caller_dir = if $caller_name in ["orchestrator" "ken"] {
        ($ken_root | path join "orchestrator")
    } else {
        ($ken_root | path join $caller_name)
    }

    # Resolve target agent inside caller agent directory (<caller>/<target>.k)
    let agent_k = ($caller_dir | path join $"($agent).k")
    if not ($agent_k | path exists) {
        return $"Error: Agent '($agent)' is not available in ($caller_name)."
    }

    let target = (if not ($model | is-empty) { $"($agent).($model)" } else { $agent })
    let sess_id = ($env.KEN_SESSION? | default "default")
    let full_spec = (if $sess_id != "default" { $"($sess_id)($target)" } else { $target })
    let next_depth = ($depth + 1 | into string)

    # Print ASCII progress report to /dev/tty
    if ("/dev/tty" | path exists) {
        let m_disp = (if not ($model | is-empty) { $model } else { "default" })
        $"\n[call] agent: ($agent) | model: ($m_disp) | task: ($task)\n" | save --append "/dev/tty"
    }

    let ken_nu = ($ken_root | path join "ken.nu")

    let res = (with-env { KEN_DEPTH: $next_depth } {
        if ($ken_nu | path exists) {
            ^$ken_nu $full_spec $task | complete
        } else {
            ^ken $full_spec $task | complete
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
