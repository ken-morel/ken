# Style guide for coding in ken

## snake_case !!!

Use `snake_case` everywhere: functions, variables, parameters, subcommands, flags, and file names.

## No aliases, no sugar

Never define command aliases or duplicate subcommands (`call-agent`, `session rm`, `session mv`, `session set`, `session renumber`). Every subcommand and function has one canonical name and one way to invoke it.

## Use native help

Never hand-roll `Usage:` or `Examples:` print blocks. Rely on Nushell's builtin `help` command and parameter doc comments on `main` and `main <subcommand>`.

## Avoid comments

Avoid inline `#` comments. Prefer descriptive variable and function names. The only acceptable comments are the `#` doc comments directly on `def "main ..."` signatures and parameters so `help` works natively.

## Avoid mutable variables

Avoid `mut` flags and accumulators where an expression, pipeline (`each`, `where`, `reduce`), or `if` / `match` expression can produce the value directly:

```nu
# GOOD
let chosen_model = if not ($model | is-empty) {
    $model
} else if $is_cloud_caller {
    $caller_model
} else {
    $target_default
}

# BAD
mut chosen_model = ""
if not ($model | is-empty) {
    $chosen_model = $model
}
```

## Always put `else` clauses when returning values

Prefer using `if` / `else` and `match` as expressions rather than scattering early `return` statements across branches:

```nu
# GOOD
def resolve_agent_dir [agent: string] {
    let root = (get_ken_root)
    let def_agent = (load_root_config).default_agent
    if $agent in ["ken" $def_agent] {
        $root | path join $def_agent
    } else {
        $root | path join $agent
    }
}

# BAD
def resolve_agent_dir [agent: string] {
    let root = (get_ken_root)
    if $agent == "ken" {
        return ($root | path join "orchestrator")
    }
    $root | path join $agent
}
```

## Put `if`, `else`, `for`, `try`, `catch` on new lines

Expand multiline blocks cleanly instead of cramming control flow and `catch` blocks onto single long lines, except for trivial one-line fallback defaults.

## Do not swallow errors

Never hide I/O or command failures inside silent `try { ... } catch { }` blocks. Gate optional behavior explicitly via environment or state checks (`if (tty) { ... }`, `if ($path | path exists) { ... }`), and report tool/API failures explicitly.

## Strict separation of `/dev/tty` and `stdout`

- `/dev/tty` is strictly for interactive UI, live token streaming, reasoning, and tool telemetry via `tty_report`, gated by `tty` (`KEN_TTY` == `"1"`).
- `stdout` is strictly for emitting the final model output text at the end of execution, gated by `stdout` (`KEN_STDOUT` == `"1"`, which defaults to `"1"` when `stdout` is piped or `KEN_TTY=0`).
- Never mix telemetry banners onto `stdout`, and never duplicate final output onto `stdout` when interactive `/dev/tty` already displayed it.

## Prefix-first context ordering for KV cache

Always order context from most static to most dynamic so `llama-server` KV prefix caches hit across queries:
1. Base system prompt + tool schemas (`base_<agent>_<model>.bin`)
2. Session conversation history (`sess_<agent>_<session>_<model>.bin`)
3. Piped stdin / file context data
4. User query at the very end

Never inject minute-varying timestamps before piped context data.

## Avoid creating unnecessary functions or duplicating loops

Centralize shared logic in `ken.nu`. `run_agent` and `main raw` must share the same streaming completion function (`stream_chat`) rather than duplicating `curl`, SSE parsing, reasoning formatting, and metric recording. Keep domain/daemon tools (like voice VAD) out of `ken.nu`.
