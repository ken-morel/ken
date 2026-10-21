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

    # Resolve target model:
    # 1. Explicit --model flag from caller
    # 2. Inherit caller model ($env.KEN_MODEL) if supported by target agent
    # 3. Fall back to target agent's default_model
    let target_dir = ($ken_root | path join $agent)
    let target_conf_path = ($target_dir | path join "config.nuon")
    let target_conf = if ($target_conf_path | path exists) {
        try { open $target_conf_path } catch { {} }
    } else { {} }

    let supported_models = ($target_conf.supported_models? | default [])
    let target_default = ($target_conf.default_model? | default "")
    let caller_model = ($env.KEN_MODEL? | default "")
    # Standard: any multi-letter model alias starting with 'a' is remote/cloud (ad* for DeepSeek, ag* for Gemini)
    let is_cloud_caller = ($caller_model | str starts-with "a")

    let chosen_model = if not ($model | is-empty) {
        $model
    } else if $is_cloud_caller {
        # Cloud callers propagate cloud model down for high speed
        $caller_model
    } else if $target_default == "l" {
        # Fast local subagents (fs, sys, mem, voice) keep fast LFM (co-loaded in --models-max 2)
        "l"
    } else if not ($caller_model | is-empty) and (($supported_models | is-empty) or ($caller_model in $supported_models)) {
        $caller_model
    } else if not ($target_default | is-empty) {
        $target_default
    } else {
        ""
    }

    let target = (if not ($chosen_model | is-empty) { $"($agent).($chosen_model)" } else { $agent })
    let sess_id = ($env.KEN_SESSION? | default "default")
    let full_spec = (if $sess_id != "default" { $"($sess_id)($target)" } else { $target })
    let next_depth = ($depth + 1 | into string)

    let t_start = (date now)
    let time_start_str = ($t_start | format date "%H:%M:%S")

    # Print ASCII progress report to /dev/tty
    if ("/dev/tty" | path exists) {
        let m_disp = (if not ($chosen_model | is-empty) { $chosen_model } else { "default" })
        $"\n[call] agent: ($agent) | model: ($m_disp) | task: ($task) \(at ($time_start_str)\)\n" | save --append "/dev/tty"
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
        let t_end = (date now)
        let t_dur = ($t_end - $t_start)
        let time_end_str = ($t_end | format date "%H:%M:%S")
        $"\n[done] agent: ($agent) | lines: ($lines_n) | exit: ($res.exit_code) \(took ($t_dur) @ ($time_end_str)\)\n" | save --append "/dev/tty"
    }

    if $res.exit_code == 0 {
        $res.stdout
    } else {
        $"Error running agent ($agent): ($res.stderr)\n($res.stdout)"
    }
}
