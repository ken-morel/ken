#!/usr/bin/env nu

def tty []: nothing -> bool {
    let base = ((is-terminal --stdin) or (is-terminal --stdout) or (is-terminal --stderr)) | into int | into string
    (($env.KEN_TTY? | default $base) == "1")
}

def stdout []: nothing -> bool {
    let base = ((not (is-terminal --stdout)) or (not (tty))) | into int | into string
    (($env.KEN_STDOUT? | default $base) == "1")
}

def tty_report [msg: string] {
    if (tty) { $msg | save --append /dev/tty }
}

def get_ken_root [] {
    let xdg_dir = if not ($env.XDG_CONFIG_HOME? | default "" | is-empty) {
        $env.XDG_CONFIG_HOME | path join "ken"
    } else {
        $env.HOME | path join ".config" "ken"
    }
    let script_dir = ($env.FILE_PWD? | default "")
    if not ($env.KEN_DIR? | default "" | is-empty) and ($env.KEN_DIR | path exists) {
        $env.KEN_DIR | path expand
    } else if not ($env.KEN_ROOT? | default "" | is-empty) and ($env.KEN_ROOT | path exists) {
        $env.KEN_ROOT | path expand
    } else if (($xdg_dir | path join "config.nuon") | path exists) {
        $xdg_dir
    } else if not ($script_dir | is-empty) and (($script_dir | path join "config.nuon") | path exists) {
        $script_dir
    } else if (($env.PWD | path join "config.nuon") | path exists) {
        $env.PWD
    } else {
        $xdg_dir
    }
}

def get_cache_dir [sub: string] {
    let d = ($env.HOME | path join ".cache" "ken" $sub)
    mkdir $d
    $d
}

def list_agent_dirs [ken_root: string] {
    let excluded = ["bin" "hey" "scripts" "_mem"]
    ls $ken_root
    | where type == dir
    | where { |it|
        let name = ($it.name | path basename)
        (not ($name | str starts-with ".")) and (not ($name | str starts-with "_")) and ($name not-in $excluded) and ((($it.name | path join "config.nuon") | path exists) or (($it.name | path join "prompt.md") | path exists))
    }
    | sort-by name
}

def load_root_config [] {
    let ken_root = (get_ken_root)
    let conf_path = ($ken_root | path join "config.nuon")
    let base_conf = { default_agent: "", default_model: "", default_ctx: 8192, currency: "$", options: {}, models: {}, providers: {} }
    let merged = if ($conf_path | path exists) { $base_conf | merge (open $conf_path) } else { $base_conf }
    let with_agent = if ($merged.default_agent | is-empty) {
        let agents = (list_agent_dirs $ken_root | get name | each { path basename })
        $merged | upsert default_agent ($agents | first | default "")
    } else {
        $merged
    }
    if ($with_agent.default_model | is-empty) {
        let first_m = ($with_agent.providers | values | get -o 0.models | default {} | columns | first | default "")
        $with_agent | upsert default_model $first_m
    } else {
        $with_agent
    }
}

def get_local_url [endpoint: string = "", root_conf?: record] {
    let rc = if $root_conf != null { $root_conf } else { load_root_config }
    let base = ($rc.providers?.local?.base_url? | default "http://127.0.0.1:6172/v1")
    let p = ($base | url parse)
    let port_str = if ($p.port? | default "" | is-not-empty) { $":($p.port)" } else { "" }
    let host = $"($p.scheme)://($p.host)($port_str)"
    match $endpoint {
        "slots" => $"($host)/slots"
        "tokenize" => $"($host)/tokenize"
        _ => $"($base)/chat/completions"
    }
}

def --env load_ken_env [] {
    let ken_root = (get_ken_root)
    for f in [($ken_root | path join "env.nuon") ($ken_root | path join ".env.nuon")] {
        if ($f | path exists) {
            let data = (open $f)
            if ($data | describe | str starts-with "record") { load-env $data }
        }
    }
    let env_file = ($ken_root | path join ".env")
    if ($env_file | path exists) {
        let pairs = (
            open --raw $env_file
            | lines
            | each { str trim }
            | where { |l| (not ($l | is-empty)) and (not ($l | str starts-with "#")) and ($l | str contains "=") }
            | each { |l|
                let parts = ($l | split row -n 2 "=")
                { key: ($parts | get 0 | str trim), val: ($parts | get 1 | str trim | str trim -c '"' | str trim -c "'") }
            }
        )
        if not ($pairs | is-empty) { load-env ($pairs | transpose -r -d) }
    }
}

def resolve_model_info [model_alias: string, root_conf: record] {
    let providers = ($root_conf.providers? | default {})
    let matches = (
        $providers
        | transpose p_name p_data
        | each { |p|
            let key_env = ($p.p_data.api_key_env? | default "")
            let key_val = if not ($key_env | is-empty) { $env | get -o $key_env | default "" } else { "" }
            let auth_hdr = if not ($key_val | is-empty) { $"Bearer ($key_val)" } else { null }
            $p.p_data.models?
            | default {}
            | transpose m_key m_info
            | where { |m| ($m.m_key == $model_alias) or (($m.m_info.name? | default "") == $model_alias) }
            | each { |m|
                {
                    alias: $m.m_key
                    provider: $p.p_name
                    model_name: ($m.m_info.name? | default $m.m_key)
                    description: ($m.m_info.description? | default "")
                    ctx: ($m.m_info.ctx? | default $root_conf.default_ctx)
                    base_url: $p.p_data.base_url
                    auth_header: $auth_hdr
                    pricing: ($m.m_info.pricing? | default { input: 0.0, output: 0.0, cache_hit: 0.0 })
                    is_local: ($p.p_name == "local")
                    thinking: ($m.m_info.thinking? | default ($m.m_info.options?.thinking? | default null))
                    reasoning_effort: ($m.m_info.reasoning_effort? | default ($m.m_info.options?.reasoning_effort? | default null))
                }
            }
        }
        | flatten
    )
    if not ($matches | is-empty) {
        $matches | first
    } else {
        {
            alias: $model_alias
            provider: "local"
            model_name: $model_alias
            description: ""
            ctx: $root_conf.default_ctx
            base_url: ($providers.local?.base_url? | default "http://127.0.0.1:6172/v1")
            auth_header: null
            pricing: { input: 0.0, output: 0.0, cache_hit: 0.0 }
            is_local: true
            thinking: null
            reasoning_effort: null
        }
    }
}

def format_cost [amount: float, currency: string = "$"] {
    if $amount == 0.0 {
        match $currency {
            "$" | "£" | "¥" => $"($currency)0"
            "€" => "0€"
            _ => $"0 ($currency)"
        }
    } else {
        let rounded = if $amount < 0.0001 and $amount > 0.0 { $amount | math round -p 6 } else { $amount | math round -p 4 }
        match $currency {
            "$" | "£" | "¥" => $"($currency)($rounded)"
            "€" => $"($rounded)€"
            _ => $"($rounded) ($currency)"
        }
    }
}

def calculate_cost [pricing: record, prompt_tokens: int, completion_tokens: int, cached_tokens: int, currency: string = "$"] {
    let in_price = ($pricing.input? | default 0.0 | into float)
    let out_price = ($pricing.output? | default 0.0 | into float)
    let cache_price = ($pricing.cache_hit? | default 0.0 | into float)
    let uncached_prompt = if $prompt_tokens >= $cached_tokens { $prompt_tokens - $cached_tokens } else { $prompt_tokens }
    let cost = (($uncached_prompt / 1_000_000.0) * $in_price) + (($completion_tokens / 1_000_000.0) * $out_price) + (($cached_tokens / 1_000_000.0) * $cache_price)
    { amount: $cost, currency: $currency, label: (format_cost $cost $currency), is_free: ($in_price == 0.0 and $out_price == 0.0) }
}

def format_cost_label [cost_res: record, cum_cost: record] {
    let cur = ($cost_res.currency? | default "$")
    if ($cost_res.amount == 0.0 or $cost_res.is_free) and ($cum_cost.amount == 0.0) {
        format_cost 0.0 $cur
    } else {
        let u_turn = (format_cost $cost_res.amount $cur)
        let u_tot = (format_cost $cum_cost.amount $cur)
        if $u_turn == $u_tot { $u_tot } else { $"($u_turn) \(tot: ($u_tot)\)" }
    }
}

def format_duration [dur: duration] {
    let sec = (($dur | into int) / 1_000_000_000.0)
    if $sec < 1.0 {
        $"($sec * 1000.0 | math round)ms"
    } else if $sec < 60.0 {
        $"($sec | math round -p 1)s"
    } else {
        $"($sec // 60 | into int)m ($sec mod 60 | math round -p 1)s"
    }
}

def count_text_tokens [text: string] {
    if ($text | is-empty) {
        0
    } else {
        let tok_url = (get_local_url "tokenize")
        let res = (try { http post --max-time 150ms --content-type "application/json" $tok_url ({ content: $text } | to json -r) } catch { null })
        if ($res.tokens? | default null) != null {
            $res.tokens | length
        } else {
            [(($text | split words | length) * 1.3 | math round | into int), (($text | str length) // 4)] | math max
        }
    }
}

def record_metric [item: record] {
    let f = ($env.KEN_METRICS_FILE? | default "")
    if not ($f | is-empty) { $"($item | to json -r)\n" | save --append $f }
}

def get_cumulative_cost [currency: string = "$"] {
    let f = ($env.KEN_METRICS_FILE? | default "")
    if (not ($f | is-empty)) and ($f | path exists) {
        let rows = (open --raw $f | lines | where ($it | is-not-empty) | each { from json })
        if not ($rows | is-empty) {
            let sum_amount = ($rows | each { |r| $r.cost? | default ($r.cost_usd? | default 0.0) | into float } | math sum)
            { amount: $sum_amount, currency: $currency }
        } else {
            { amount: 0.0, currency: $currency }
        }
    } else {
        { amount: 0.0, currency: $currency }
    }
}

def load_agent_config [agent_dir: string, root_conf?: record] {
    let base_conf = if $root_conf != null { $root_conf } else { load_root_config }
    let conf_path = ($agent_dir | path join "config.nuon")
    let loaded = if ($conf_path | path exists) { open $conf_path } else { {} }
    let name = ($loaded.name? | default ($agent_dir | path basename))
    let prompt_path = ($agent_dir | path join "prompt.md")
    let sys_prompt = if ($loaded.system_prompt? | default "" | is-not-empty) {
        $loaded.system_prompt
    } else if ($prompt_path | path exists) {
        open --raw $prompt_path
    } else {
        $"You are the Ken ($name) agent."
    }
    {
        name: $name
        description: ($loaded.description? | default "")
        default_model: ($loaded.default_model? | default $base_conf.default_model)
        subagents: ($loaded.subagents? | default [])
        supported_models: ($loaded.supported_models? | default [])
        options: (($base_conf.options? | default {}) | merge ($loaded.options? | default {}))
        models: (($base_conf.models? | default {}) | merge ($loaded.models? | default {}))
        system_prompt: $sys_prompt
    }
}

def resolve_agent_dir [agent: string] {
    let root = (get_ken_root)
    let def_agent = (load_root_config).default_agent
    if $agent in ["ken" $def_agent] {
        let p = ($root | path join $def_agent)
        if ($p | path exists) { $p } else { $root | path join $agent }
    } else {
        $root | path join $agent
    }
}

def parse_spec [spec_str: string] {
    let raw = ($spec_str | default "" | str trim)
    let def_agent = ((load_root_config).default_agent? | default "")
    if ($raw | is-empty) {
        { session: null, agent: $def_agent, model: null, model_explicit: false }
    } else {
        let p_sess = ($raw | parse -r '^(?<session>\d+)?(?<rest>.*)$' | first)
        let session = if ($p_sess.session? | default "" | is-empty) { null } else { $p_sess.session }
        let rest = ($p_sess.rest | default "" | str trim)
        let agent_path = ((get_ken_root) | path join $rest)
        if ($rest | is-empty) {
            { session: $session, agent: $def_agent, model: null, model_explicit: false }
        } else if ($rest | str contains ".") {
            let parts = ($rest | split row ".")
            { session: $session, agent: ($parts | get 0), model: ($parts | get 1), model_explicit: true }
        } else if ($agent_path | path exists) and (($agent_path | path type) == "dir") {
            { session: $session, agent: $rest, model: null, model_explicit: false }
        } else {
            { session: $session, agent: $def_agent, model: $rest, model_explicit: true }
        }
    }
}

def get_agent_tools [agent_dir: string] {
    if not ($agent_dir | path exists) {
        []
    } else {
        let nu_files = (glob ($agent_dir | path join "*.nu") | where { |it| ($it | path parse | get stem) != "call_agent" } | sort)
        let file_tools = (
            $nu_files
            | each { |f|
                let tool_name = ($f | path parse | get stem)
                let info = (try { ^nu -c $"source '($f)'; scope commands | where name == 'main' | select description signatures | to json" | from json | first } catch { null })
                if $info == null {
                    null
                } else {
                    let desc = ($info.description? | default $"Execute ($tool_name)")
                    let sigs = ($info.signatures?.any? | default [] | where { |p| $p.parameter_name != null and ($p.parameter_type not-in ["input" "output"]) })
                    let properties = (
                        $sigs
                        | each { |p|
                            let p_type = match $p.syntax_shape {
                                "int" => "integer"
                                "bool" => "boolean"
                                _ => (if $p.parameter_type == "switch" { "boolean" } else { "string" })
                            }
                            { key: $p.parameter_name, val: { type: $p_type, description: ($p.description? | default $"Parameter ($p.parameter_name)") } }
                        }
                        | if ($in | is-empty) { {} } else { transpose -r -d }
                    )
                    let required = ($sigs | where { |p| (not ($p.is_optional? | default true)) and ($p.parameter_type != "switch") } | get parameter_name)
                    { type: "function", function: { name: $tool_name, description: $desc, parameters: { type: "object", properties: $properties, required: $required } } }
                }
            }
            | compact
        )
        let agent_conf = (load_agent_config $agent_dir)
        let available_agents = ($agent_conf.subagents? | default [] | uniq | sort)
        if ($available_agents | is-empty) {
            $file_tools
        } else {
            let agent_docs = (
                $available_agents
                | each { |a_name|
                    let conf_file = ((resolve_agent_dir $a_name) | path join "config.nuon")
                    let a_desc = if ($conf_file | path exists) { (open $conf_file).description? | default "" } else { "" }
                    if not ($a_desc | is-empty) { $"- ($a_name): ($a_desc)" } else { $"- ($a_name)" }
                }
                | str join "\n"
            )
            let root_conf = (load_root_config)
            let model_items = (
                $root_conf.providers
                | values
                | each { |p| $p.models | transpose alias m_info | each { |m| { alias: $m.alias, desc: $"- ($m.alias): ($m.m_info.description? | default $m.m_info.name)" } } }
                | flatten
            )
            let cur_m = ($env.KEN_MODEL? | default $root_conf.default_model)
            $file_tools | append {
                type: "function"
                function: {
                    name: "call_agent"
                    description: "Delegate a specialized task to a domain specialist agent"
                    parameters: {
                        type: "object"
                        properties: {
                            agent: { type: "string", enum: $available_agents, description: $"Target agent to delegate to. Available agents:\n($agent_docs)" }
                            task: { type: "string", description: "The specific prompt, instruction, or task for the specialist agent" }
                            model: { type: "string", enum: ($model_items | get alias | sort), description: $"Optional model override. Defaults to inheriting caller's model ($cur_m). Available models:\n($model_items | get desc | str join "\n")" }
                        }
                        required: ["agent" "task"]
                    }
                }
            }
        }
    }
}

def do_call_agent [agent: string, task: string, model: string = "", caller_agent?: string] {
    let depth = (try { $env.KEN_DEPTH | into int } catch { 0 })
    if $depth >= 3 {
        "Error: Maximum agent recursion depth (3) reached. Synthesize final answer."
    } else {
        let ken_root = (get_ken_root)
        let root_conf = (load_root_config)
        let caller_name = if not ($caller_agent | is-empty) { $caller_agent } else { $env.KEN_AGENT? | default $root_conf.default_agent }
        let caller_conf = (load_agent_config (resolve_agent_dir $caller_name) $root_conf)
        if $agent not-in ($caller_conf.subagents? | default []) {
            $"Error: Agent '($agent)' is not available in ($caller_name)."
        } else {
            let target_conf = (load_agent_config (resolve_agent_dir $agent) $root_conf)
            let supported_models = ($target_conf.supported_models? | default [])
            let target_default = ($target_conf.default_model? | default "")
            let caller_model = ($env.KEN_MODEL? | default "")
            let caller_is_local = (resolve_model_info $caller_model $root_conf).is_local
            let chosen_model = if not ($model | is-empty) {
                $model
            } else if (not ($caller_model | is-empty)) and (not $caller_is_local) {
                $caller_model
            } else if (not ($caller_model | is-empty)) and (($supported_models | is-empty) or ($caller_model in $supported_models)) {
                $caller_model
            } else {
                $target_default
            }
            let target = if not ($chosen_model | is-empty) { $"($agent).($chosen_model)" } else { $agent }
            let sess_id = ($env.KEN_SESSION? | default "0")
            let full_spec = if $sess_id != "0" and $sess_id != "default" { $"($sess_id)($target)" } else { $target }
            let ken_nu = ($env.CURRENT_FILE? | default ($ken_root | path join "ken.nu"))
            let res = (with-env { KEN_DEPTH: (($depth + 1) | into string), KEN_TTY: ((tty) | into int | into string) } {
                if ($ken_nu | path exists) { ^$ken_nu $full_spec $task | complete } else { ^ken $full_spec $task | complete }
            })
            if $res.exit_code == 0 { $res.stdout } else { $"Error running agent ($agent): ($res.stderr)\n($res.stdout)" }
        }
    }
}

def execute_tool [agent_dir: string, fn_name: string, args_json: string] {
    let args_dict = (try { $args_json | from json } catch { {} })
    let agent_name = ($agent_dir | path basename)
    let is_call_agent = ($fn_name == "call_agent")
    let tool_path = ($agent_dir | path join $"($fn_name).nu")
    if (not $is_call_agent) and (not ($tool_path | path exists)) {
        $"Error: Tool '($fn_name)' not found in agent '($agent_name)'."
    } else {
        let formatted_args = ($args_dict | transpose key val | each { |it| $"--($it.key) '($it.val)'" } | str join " ")
        let depth = (try { $env.KEN_DEPTH | into int } catch { 0 })
        let indent = ("" | fill -c " " -w ($depth * 2))
        let t_start = (date now)
        tty_report $"\n($indent){ ($agent_name)/($fn_name) ($formatted_args) @ ($t_start | format date '%H:%M:%S')\n"

        let rc = (load_root_config)
        let caller_model = ($env.KEN_MODEL? | default $rc.default_model)
        let m_info = (resolve_model_info $caller_model $rc)
        let slot_backup_name = $"active_depth_($depth)_($caller_model).bin"
        let slots_url = (get_local_url "slots" $rc)
        if $is_call_agent and $m_info.is_local {
            try { http post --content-type "application/json" $"($slots_url)/0?action=save" ({ model: $m_info.model_name, filename: $slot_backup_name } | to json -r) } catch { null }
        }

        let mf = ($env.KEN_METRICS_FILE? | default "")
        let metric_lines_before = if (not ($mf | is-empty)) and ($mf | path exists) { open --raw $mf | lines | length } else { 0 }

        let res = if $is_call_agent {
            { stdout: (do_call_agent ($args_dict.agent? | default "") ($args_dict.task? | default "") ($args_dict.model? | default "") $agent_name), stderr: "", exit_code: 0 }
        } else {
            let tool_info = (try { ^nu -c $"source '($tool_path)'; scope commands | where name == 'main' | select signatures | to json" | from json | first } catch { null })
            let sigs = ($tool_info.signatures?.any? | default [] | where { |p| $p.parameter_name != null and ($p.parameter_type not-in ["input" "output"]) })
            let pos_args = ($sigs | where parameter_type == "positional" | where { |p| ($args_dict | get -o $p.parameter_name) != null } | each { |p| ($args_dict | get $p.parameter_name) | into string })
            let named_args = (
                $sigs
                | where parameter_type != "positional"
                | each { |p|
                    let val = ($args_dict | get -o $p.parameter_name)
                    if $val == null {
                        []
                    } else if $p.parameter_type == "switch" {
                        if $val == true { [$"--($p.parameter_name)"] } else { [] }
                    } else {
                        [$"--($p.parameter_name)" ($val | into string)]
                    }
                }
                | flatten
            )
            with-env { KEN_DEPTH: (($depth + 1) | into string), KEN_TTY: ((tty) | into int | into string) } {
                ^nu $tool_path ...$pos_args ...$named_args | complete
            }
        }

        let t_end = (date now)
        let t_dur = ($t_end - $t_start)
        let time_end_str = ($t_end | format date "%H:%M:%S")

        if $is_call_agent and $m_info.is_local {
            try { http post --content-type "application/json" $"($slots_url)/0?action=restore" ({ model: $m_info.model_name, filename: $slot_backup_name } | to json -r) } catch { null }
        }

        let metric_lines_after = if (not ($mf | is-empty)) and ($mf | path exists) { open --raw $mf | lines | length } else { 0 }
        if $res.exit_code == 0 {
            let output = if not ($res.stdout | is-empty) { $res.stdout } else { "(Success with no output)" }
            if $metric_lines_after <= $metric_lines_before {
                let indented_output = ($output | lines | each { |l| $"($indent)  ($l)" } | str join "\n")
                tty_report $"($indented_output)\n"
            }
            tty_report $"($indent)} ($agent_name)/($fn_name) -> ($output | lines | length)L (count_text_tokens $output)t \((format_duration $t_dur) @ ($time_end_str)\)\n\n"
            $output
        } else {
            tty_report $"($indent)} ($agent_name)/($fn_name) ! exit ($res.exit_code) \((format_duration $t_dur) @ ($time_end_str)\)\n"
            if not ($res.stderr | is-empty) {
                tty_report $"($res.stderr | lines | each { |l| $'($indent)  ($l)' } | str join '\n')\n"
            }
            if not ($res.stdout | is-empty) {
                tty_report $"($res.stdout | lines | each { |l| $'($indent)  ($l)' } | str join '\n')\n"
            }
            tty_report "\n"
            $"Error: ($res.stderr)\n($res.stdout)"
        }
    }
}

def format_stream_token [tok: string, indent: string, at_start: bool, prefix: string = "", color: string = ""] {
    if ($tok | is-empty) {
        { text: "", at_start: $at_start }
    } else if ($indent | is-empty) and ($prefix | is-empty) and ($color | is-empty) {
        { text: $tok, at_start: ($tok | str ends-with "\n") }
    } else {
        let parts = ($tok | split row "\n")
        let n = ($parts | length)
        let reset = (ansi reset)
        let line_pfx = $"($indent)($prefix)($color)"
        mut out = ""
        mut cur_start = $at_start
        for i in 0..<$n {
            let p = ($parts | get $i)
            if $i > 0 {
                if not ($color | is-empty) { $out = ($out + $reset) }
                $out = ($out + "\n")
                $cur_start = true
            }
            if not ($p | is-empty) {
                if $cur_start {
                    $out = ($out + $line_pfx)
                    $cur_start = false
                }
                $out = ($out + $p)
            } else if $i > 0 and $i < ($n - 1) and (not ($prefix | is-empty)) {
                $out = ($out + $"($indent)($prefix)")
            }
        }
        { text: $out, at_start: $cur_start }
    }
}

def apply_thinking_payload [payload: record, think_val: any] {
    if $think_val == null or ($think_val | into string | is-empty) {
        $payload
    } else {
        let tv = ($think_val | into string | str lowercase | str trim)
        let tp = if $tv in ["off" "false" "none" "0" "disable" "disabled"] {
            { chat_template_kwargs: { enable_thinking: false }, reasoning_budget: 0 }
        } else if $tv in ["on" "true" "enable" "enabled" "1"] {
            { chat_template_kwargs: { enable_thinking: true } }
        } else if $tv in ["low" "medium" "high"] {
            { chat_template_kwargs: { enable_thinking: true, reasoning_effort: $tv }, reasoning_effort: $tv }
        } else {
            let num = (try { $tv | into int } catch { null })
            if $num != null {
                if $num <= 0 { { chat_template_kwargs: { enable_thinking: false }, reasoning_budget: 0 } } else { { chat_template_kwargs: { enable_thinking: true }, reasoning_budget: $num } }
            } else {
                { chat_template_kwargs: { enable_thinking: true, reasoning_effort: $tv }, reasoning_effort: $tv }
            }
        }
        let with_kw = if ($tp.chat_template_kwargs? != null) {
            $payload | upsert chat_template_kwargs (($payload.chat_template_kwargs? | default {}) | merge $tp.chat_template_kwargs)
        } else {
            $payload
        }
        let with_eff = if ($tp.reasoning_effort? != null) { $with_kw | upsert reasoning_effort $tp.reasoning_effort } else { $with_kw }
        if ($tp.reasoning_budget? != null) { $with_eff | upsert reasoning_budget $tp.reasoning_budget } else { $with_eff }
    }
}

def stream_chat [
    payload: record
    model_info: record
    root_conf: record
    source_name: string
    turn_idx: int
    indent: string
    t_run_start: datetime
    prior_tokens: int
    is_raw: bool = false
] {
    let chat_url = $"($model_info.base_url)/chat/completions"
    let t_turn_start = (date now)
    let auth_args = if ($model_info.auth_header? | default "" | is-not-empty) { [-H $"Authorization: ($model_info.auth_header)"] } else { [] }
    let curl_args = ([-s -N --no-buffer $chat_url -H "Content-Type: application/json"] | append $auth_args | append [-d "@-"])

    mut turn_content = ""
    mut turn_reasoning = ""
    mut in_reasoning = false
    mut reasoning_at_start = true
    mut content_at_start = true
    mut tool_deltas = []
    mut known_call_ids = []
    mut turn_timings: any = null
    mut turn_usage: any = null
    mut stream_lines = []

    let think_pfx = $"((ansi dark_gray))($root_conf.thinking_prefix? | default '│ ')"
    let think_col = (ansi dark_gray)

    for line in (($payload | to json -r) | ^curl ...$curl_args | lines) {
        let tr = ($line | str trim)
        if ($tr | is-empty) { continue }
        $stream_lines = ($stream_lines | append $tr)
        if not ($line | str starts-with "data: {") { continue }
        let chunk = (try { $line | str substring 6.. | from json } catch { null })
        if $chunk == null { continue }

        if ($chunk.timings? | default null) != null { $turn_timings = $chunk.timings }
        if ($chunk.usage? | default null) != null { $turn_usage = $chunk.usage }

        let delta = ($chunk.choices?.0?.delta? | default {})
        let r_tok = ($delta.reasoning_content? | default "")
        if not ($r_tok | is-empty) {
            if not $in_reasoning {
                $in_reasoning = true
                tty_report "\n"
                $reasoning_at_start = true
            }
            $turn_reasoning = ($turn_reasoning + $r_tok)
            let formatted = (format_stream_token $r_tok $indent $reasoning_at_start $think_pfx $think_col)
            $reasoning_at_start = $formatted.at_start
            tty_report $formatted.text
        }

        let c_tok = ($delta.content? | default "")
        let tc = ($delta.tool_calls? | default [])

        if $in_reasoning and ((not ($c_tok | is-empty)) or (not ($tc | is-empty))) {
            $in_reasoning = false
            tty_report $"(ansi reset)\n\n"
            $content_at_start = true
        }

        if not ($c_tok | is-empty) {
            $turn_content = ($turn_content + $c_tok)
            let formatted = (format_stream_token $c_tok $indent $content_at_start)
            $content_at_start = $formatted.at_start
            tty_report $formatted.text
        }

        if not ($tc | is-empty) {
            for it in $tc {
                let call_idx = if ($it.index? | default null) != null {
                    $it.index | into int
                } else if ($it.id? | default "" | is-not-empty) {
                    let existing_idx = ($known_call_ids | enumerate | where item == $it.id | get -o 0.index)
                    if $existing_idx != null {
                        $existing_idx
                    } else {
                        let next_idx = ($known_call_ids | length)
                        $known_call_ids = ($known_call_ids | append $it.id)
                        $next_idx
                    }
                } else if not ($known_call_ids | is-empty) {
                    ($known_call_ids | length) - 1
                } else {
                    0
                }
                $tool_deltas = ($tool_deltas | append ($it | upsert index $call_idx))
            }
        }
    }

    if $in_reasoning { tty_report $"(ansi reset)\n\n" }

    if ($turn_content | is-empty) and ($turn_reasoning | is-empty) and ($tool_deltas | is-empty) and (not ($stream_lines | is-empty)) {
        print -e $"\n(ansi red_bold)[Ken Error](ansi reset) Request to ($chat_url) failed:\n($stream_lines | str join '\n')"
        { ok: false, content: "", reasoning: "", tool_calls: [], prompt_tokens: 0, pred_tokens: 0, cached_tokens: 0 }
    } else {
        let turn_dur = ((date now) - $t_turn_start)
        let total_elapsed = ((date now) - $t_run_start)
        let time_now_str = (date now | format date "%H:%M:%S")
        let cache_n = ($turn_timings.cache_n? | default ($turn_usage.prompt_tokens_details?.cached_tokens? | default ($turn_usage.prompt_cache_hit_tokens? | default 0)))
        let prompt_n = ($turn_timings.prompt_n? | default ($turn_usage.prompt_tokens? | default 0))
        let pred_n = ($turn_timings.predicted_n? | default ($turn_usage.completion_tokens? | default (if $is_raw { count_text_tokens $turn_content } else { 0 })))
        let ttft_ms = ($turn_timings.prompt_ms? | default 0 | math round)
        let gen_tps = ($turn_timings.predicted_per_second? | default 0 | into float | math round -p 1)
        let pp_tps = if $ttft_ms > 0 and $prompt_n > 0 { ($prompt_n * 1000.0 / $ttft_ms) | math round -p 1 } else { 0.0 }
        let currency = ($root_conf.currency? | default "$")
        let cost_res = (calculate_cost $model_info.pricing $prompt_n $pred_n $cache_n $currency)
        record_metric { source: $source_name, model: $model_info.alias, turn: $turn_idx, prompt_tokens: $prompt_n, completion_tokens: $pred_n, cached_tokens: $cache_n, cost: $cost_res.amount, currency: $currency }
        let cost_str = (format_cost_label $cost_res (get_cumulative_cost $currency))

        if ($turn_timings != null or $turn_usage != null or $is_raw) {
            let ctx_info = if $cache_n > 0 { $"($prompt_n)+($pred_n) \(($cache_n)c\)" } else { $"($prompt_n)+($pred_n)" }
            let ttft_part = if $ttft_ms > 0 {
                let s = if $ttft_ms < 1000 { $"($ttft_ms)ms ttft" } else { $"($ttft_ms / 1000.0 | math round -p 1)s ttft" }
                if $pp_tps > 0 { [$"($s) \(($pp_tps) pp t/s\)"] } else { [$s] }
            } else {
                []
            }
            let banner_parts = if $is_raw {
                let n_lines = ($turn_content | lines | length)
                let speed_out = if $gen_tps > 0 { $"($gen_tps) t/s -> ($n_lines)L ($pred_n)t \(((format_duration $turn_dur)) @ ($time_now_str)\)" } else { $"-> ($n_lines)L ($pred_n)t \(((format_duration $turn_dur)) @ ($time_now_str)\)" }
                ([$ctx_info] | append $ttft_part | append [$speed_out $cost_str])
            } else {
                let gen_part = if $gen_tps > 0 { [$"($gen_tps) t/s"] } else { [] }
                let cum_tokens = ($prior_tokens + $prompt_n + $pred_n)
                ([$"($model_info.alias):($turn_idx)" $ctx_info] | append $ttft_part | append $gen_part | append [$"((format_duration $turn_dur)) @ ($time_now_str)" $"tot: ($cum_tokens)t, ((format_duration $total_elapsed))" $cost_str])
            }
            tty_report $"\n($indent)] ($source_name).($model_info.alias) | (ansi d)($banner_parts | str join ' | ')(ansi reset)\n"
        }

        let tool_calls = if ($tool_deltas | is-empty) {
            []
        } else {
            $tool_deltas
            | group-by index
            | values
            | each { |d|
                let id = ($d | get -o id | compact | first | default "call_0")
                let name = ($d | get -o function.name | compact | str join "")
                let args_str = ($d | get -o function.arguments | compact | str join "")
                let extra = ($d | get -o extra_content | compact | first | default null)
                let base_tc = { id: $id, type: "function", function: { name: $name, arguments: $args_str } }
                if $extra != null { $base_tc | insert extra_content $extra } else { $base_tc }
            }
        }

        { ok: true, content: $turn_content, reasoning: $turn_reasoning, tool_calls: $tool_calls, prompt_tokens: $prompt_n, pred_tokens: $pred_n, cached_tokens: $cache_n }
    }
}

def run_agent [
    spec_str: string
    query: string
    image_path: string = ""
    slot_override: int = -1
    no_md: bool = false
    think_override: string = ""
] {
    let parsed = (parse_spec $spec_str)
    let agent_name = $parsed.agent
    let is_explicit_session = ($parsed.session != null)
    let session_id = if $is_explicit_session { $parsed.session } else { "0" }
    let agent_dir = (resolve_agent_dir $agent_name)

    if not ($agent_dir | path exists) {
        print -e $"Error: Agent directory '($agent_name)' not found."
    } else {
        load_ken_env
        let root_conf = (load_root_config)
        let agent_conf = (load_agent_config $agent_dir $root_conf)
        let system_prompt = $agent_conf.system_prompt
        let raw_model_spec = if $parsed.model_explicit { $parsed.model } else { $agent_conf.default_model? | default $root_conf.default_model }
        let model_info = (resolve_model_info $raw_model_spec $root_conf)
        let model_alias = $model_info.alias
        let model_id = $model_info.model_name
        let tools = (get_agent_tools $agent_dir)
        let model_params = (($agent_conf.options? | default {}) | merge ($agent_conf.models? | default {} | get -o $model_alias | default {}))
        let think_setting = if not ($think_override | is-empty) {
            $think_override
        } else {
            $model_params.thinking? | default ($model_params.reasoning_effort? | default ($model_info.thinking? | default ($model_info.reasoning_effort? | default "")))
        }
        let clean_params = if ($model_params.thinking? | default null) != null { $model_params | reject thinking } else { $model_params }

        let root = (get_ken_root)
        let all_agents = (list_agent_dirs $root | get name | each { path basename })
        let match_row = ($all_agents | enumerate | where item == $agent_name)
        let agent_idx = if ($match_row | is-empty) { 0 } else { $match_row | first | get index }
        let assigned_slot = if $slot_override >= 0 { $slot_override } else { $agent_idx mod 2 }

        let slots_dir = (get_cache_dir "slots")
        let base_snap = $"base_($agent_name)_($model_alias).bin"
        let sess_snap = $"sess_($agent_name)_($session_id)_($model_alias).bin"
        let legacy_snap = $"($agent_name)_($model_alias).bin"

        if not $is_explicit_session { rm -f ($slots_dir | path join $sess_snap) }

        if $model_info.is_local {
            let slots_url = (get_local_url "slots" $root_conf)
            let sess_snap_path = ($slots_dir | path join $sess_snap)
            let base_snap_path = if (($slots_dir | path join $base_snap) | path exists) { $slots_dir | path join $base_snap } else { $slots_dir | path join $legacy_snap }
            if $is_explicit_session and ($sess_snap_path | path exists) {
                try { http post --content-type "application/json" $"($slots_url)/($assigned_slot)?action=restore" ({ model: $model_id, filename: $sess_snap } | to json -r) } catch { null }
            } else if ($base_snap_path | path exists) {
                let snap_mtime = (ls $base_snap_path | get 0.modified)
                let agent_mtime = (ls $agent_dir | get modified | math max)
                if $snap_mtime >= $agent_mtime {
                    try { http post --content-type "application/json" $"($slots_url)/($assigned_slot)?action=restore" ({ model: $model_id, filename: ($base_snap_path | path basename) } | to json -r) } catch { null }
                }
            }
        }

        let session_dir = (get_cache_dir "sessions")
        let session_file = ($session_dir | path join $"($agent_name)_($session_id).json")
        if not $is_explicit_session { rm -f $session_file }
        let loaded_msgs = if $is_explicit_session and ($session_file | path exists) { open $session_file | get -o messages | default [] } else { [] }
        let init_messages = if ($loaded_msgs | is-empty) { [{ role: "system", content: $system_prompt }] } else { $loaded_msgs | update 0 { role: "system", content: $system_prompt } }

        let user_content = if (not ($image_path | is-empty)) and ($image_path | path exists) {
            let b64 = (open --raw $image_path | encode base64)
            [{ type: "text", text: $query } { type: "image_url", image_url: { url: $"data:image/jpeg;base64,($b64)" } }]
        } else {
            $query
        }
        mut messages = ($init_messages | append { role: "user", content: $user_content })

        let depth = (try { $env.KEN_DEPTH | into int } catch { 0 })
        let indent = ("" | fill -c " " -w ($depth * 2))
        let is_top_level = ($depth == 0)
        let metrics_dir = (get_cache_dir "metrics")
        let metrics_file = if ($env.KEN_METRICS_FILE? | default "" | is-empty) {
            let f = ($metrics_dir | path join $"run_(date now | format date '%Y%m%d_%H%M%S')_($nu.pid).jsonl")
            "" | save -f $f
            $f
        } else {
            $env.KEN_METRICS_FILE
        }

        let t_run_start = (date now)
        if not $no_md { tty_report $"\n($indent)[ ($agent_name).($model_alias) @ ($t_run_start | format date '%H:%M:%S')\n" }

        load-env {
            KEN_SESSION: $session_id
            KEN_AGENT: $agent_name
            KEN_MODEL: $model_alias
            KEN_ROOT: $root
            KEN_DEPTH: ($env.KEN_DEPTH? | default "0")
            KEN_METRICS_FILE: $metrics_file
            KEN_TTY: ((tty) | into int | into string)
        }

        mut total_tokens = 0
        mut final_response = ""

        for turn in 0..7 {
            let base_payload = { model: $model_id, messages: $messages, stream: true, stream_options: { include_usage: true } }
            let local_payload = if $model_info.is_local {
                $base_payload | insert timings_per_token true | insert cache_prompt true | insert id_slot $assigned_slot
            } else {
                $base_payload
            }
            let merged_payload = (apply_thinking_payload ($local_payload | merge $clean_params) $think_setting)
            let payload = if not ($tools | is-empty) { $merged_payload | insert tools $tools } else { $merged_payload }

            let step = (stream_chat $payload $model_info $root_conf $agent_name ($turn + 1) $indent $t_run_start $total_tokens false)
            if not $step.ok { return }
            $total_tokens = ($total_tokens + $step.prompt_tokens + $step.pred_tokens)

            if not ($step.tool_calls | is-empty) {
                $messages = ($messages | append { role: "assistant", content: (if not ($step.content | is-empty) { $step.content } else { null }), tool_calls: $step.tool_calls })
                for tc in $step.tool_calls {
                    let tool_res = (execute_tool $agent_dir $tc.function.name $tc.function.arguments)
                    $messages = ($messages | append { role: "tool", tool_call_id: $tc.id, name: $tc.function.name, content: ($tool_res | into string) })
                }
                continue
            }

            let effective_content = if not ($step.content | is-empty) { $step.content } else if not ($step.reasoning | is-empty) { $step.reasoning } else { "" }
            $messages = ($messages | append { role: "assistant", content: $effective_content })

            if $model_info.is_local {
                let slots_url = (get_local_url "slots" $root_conf)
                try { http post --content-type "application/json" $"($slots_url)/($assigned_slot)?action=save" ({ model: $model_id, filename: $sess_snap } | to json -r) } catch { null }
            }

            { agent: $agent_name, session_id: $session_id, updated_at: (date now | format date "%Y-%m-%d %H:%M:%S"), messages: $messages } | to json -r | save -f $session_file
            $final_response = $effective_content
            break
        }

        if $is_top_level and (not $no_md) and (not ($metrics_file | is-empty)) and ($metrics_file | path exists) {
            let metric_rows = (open --raw $metrics_file | lines | where ($it | is-not-empty) | each { from json })
            if not ($metric_rows | is-empty) {
                let total_p = ($metric_rows | get prompt_tokens | math sum)
                let total_c = ($metric_rows | get completion_tokens | math sum)
                let total_cost = ($metric_rows | each { |r| $r.cost? | default ($r.cost_usd? | default 0.0) | into float } | math sum)
                let total_dur = ((date now) - $t_run_start)
                let time_str = (date now | format date "%H:%M:%S")
                let currency = ($root_conf.currency? | default "$")
                let inner = ([$"($agent_name).($model_alias)" $"($total_p + $total_c)t \(($total_p)in, ($total_c)out\)" $"((format_duration $total_dur)) @ ($time_str)" $"tot: (format_cost $total_cost $currency)"] | str join " | ")
                tty_report $"\n(ansi green_bold)=== ($inner) ===(ansi reset)\n"
            }
        }

        if (stdout) { print -n $final_response }
    }
}

# Count tokens for files or piped stdin via llama.cpp
def "main tok" [
    ...patterns: string           # File paths or glob patterns
    --model (-m): string = ""     # Model alias (defaults to default_model)
    --json                        # Emit JSON output
] {
    let root_conf = (load_root_config)
    let target_model = if not ($model | is-empty) { $model } else { $root_conf.default_model }
    let model_ctx = ((resolve_model_info $target_model $root_conf).ctx? | default ($root_conf.default_ctx? | default 8192) | into int)
    let piped_input = if not (is-terminal --stdin) { open --raw /dev/stdin } else { "" }
    let tok_url = (get_local_url "tokenize" $root_conf)

    if not ($piped_input | is-empty) {
        let res = (try { http post --content-type "application/json" $tok_url ({ model: $target_model, content: $piped_input } | to json -r) } catch { { tokens: [] } })
        let n_tokens = ($res.tokens | length)
        let n_bytes = ($piped_input | str length)
        if $json {
            { source: "stdin", model: $target_model, bytes: $n_bytes, tokens: $n_tokens } | to json
        } else {
            let pct = (($n_tokens / $model_ctx) * 100 | math round -p 1)
            print $"Tokens: ($n_tokens) | Size: ($n_bytes | into filesize) | ($pct)% of ($model_ctx) ctx \(($target_model)\)"
        }
    } else if ($patterns | is-empty) {
        help "main tok"
    } else {
        let unique_files = (
            $patterns
            | each { |pat|
                let expanded = ($pat | path expand)
                let hits = (glob $expanded)
                if not ($hits | is-empty) { $hits } else if ($expanded | path exists) { [$expanded] } else { [] }
            }
            | flatten
            | uniq
            | where { |it| ($it | path type) == "file" }
            | sort
        )
        if ($unique_files | is-empty) {
            print -e "No matching files found."
        } else {
            let results = (
                $unique_files
                | each { |f|
                    let text = (open --raw $f)
                    let bytes_n = ($text | str length)
                    let res = (try { http post --content-type "application/json" $tok_url ({ model: $target_model, content: $text } | to json -r) } catch { { tokens: [] } })
                    { file: ($f | str replace $env.HOME "~"), bytes: $bytes_n, size: ($bytes_n | into filesize), tokens: ($res.tokens | length) }
                }
            )
            let total_tokens = ($results | get tokens | math sum)
            let total_bytes = ($results | get bytes | math sum)
            let pct = (($total_tokens / $model_ctx) * 100 | math round -p 1)
            if $json {
                { model: $target_model, total_files: ($results | length), total_bytes: $total_bytes, total_tokens: $total_tokens, ctx_size: $model_ctx, ctx_percent: $pct, files: ($results | reject bytes) } | to json
            } else {
                print ($results | reject bytes | table -e)
                print "------------------------------------------------------------"
                print $"Total: ($results | length) files | ($total_bytes | into filesize) | ($total_tokens) tokens \(($pct)% of ($model_ctx) ctx [($target_model)]\)"
            }
        }
    }
}

# List configured providers, models, and agents
def "main list" [] {
    let root = (get_ken_root)
    let root_conf = (load_root_config)
    let currency = ($root_conf.currency? | default "$")

    print "Ken Providers & Models:\n"
    for p in ($root_conf.providers? | default {} | transpose p_name p_data) {
        print $"  (ansi purple_bold)($p.p_name)(ansi reset) \(($p.p_data.base_url)\):"
        for m in ($p.p_data.models? | default {} | transpose m_alias m_info) {
            let m_name = ($m.m_info.name? | default $m.m_alias)
            let m_desc = ($m.m_info.description? | default "")
            let m_ctx = ($m.m_info.ctx? | default $root_conf.default_ctx)
            let p_in = ($m.m_info.pricing?.input? | default 0.0 | into float)
            let p_out = ($m.m_info.pricing?.output? | default 0.0 | into float)
            let pricing_str = if $p_in == 0.0 and $p_out == 0.0 { "free" } else { $"in: (format_cost $p_in $currency)/1M, out: (format_cost $p_out $currency)/1M" }
            print $"    - (ansi green_bold)($m.m_alias)(ansi reset) -> ($m_name) [($m_ctx) ctx] \(($pricing_str)\) - ($m_desc)"
        }
    }

    print $"\nAvailable Ken Agents [default: ($root_conf.default_model)]:\n"
    for a in (list_agent_dirs $root) {
        let a_name = ($a.name | path basename)
        let a_conf = (load_agent_config $a.name $root_conf)
        let agent_tools = (get_agent_tools $a.name | get function.name | sort)
        let desc = if not ($a_conf.description | is-empty) { $" - ($a_conf.description)" } else { "" }
        let tools_str = if not ($agent_tools | is-empty) { $agent_tools | str join ", " } else { "(none)" }
        print $"  - (ansi cyan_bold)($a_name)(ansi reset) [($a_conf.default_model)]($desc):\n      tools: ($tools_str)"
    }
}

# Warm up and save base KV slot snapshots for agents
def "main prefill" [
    agent?: string                # Specific agent to prefill (defaults to all)
    --model (-m): string = ""     # Override model alias
    --all                         # Prefill all agents
] {
    let ken_root = (get_ken_root)
    let root_conf = (load_root_config)
    let all_dirs = (list_agent_dirs $ken_root | get name)
    let target_dirs = if (not ($agent | is-empty)) and (not $all) {
        let specific = (resolve_agent_dir $agent)
        if ($specific | path exists) { [$specific] } else { [] }
    } else {
        $all_dirs
    }

    if ($target_dirs | is-empty) {
        print -e "No matching agents found to prefill."
    } else {
        let chat_url = (get_local_url "chat" $root_conf)
        let slots_url = (get_local_url "slots" $root_conf)
        print $"Prefilling and saving base snapshots for ($target_dirs | length) agents..."
        for adir in $target_dirs {
            let a_name = ($adir | path basename)
            let a_conf = (load_agent_config $adir $root_conf)
            let target_model = if not ($model | is-empty) { $model } else { $a_conf.default_model }
            let model_info = (resolve_model_info $target_model $root_conf)
            if not $model_info.is_local {
                print $"Prefilling ($a_name) [($target_model)]... (ansi yellow)[skip - cloud model](ansi reset)"
                continue
            }
            let tools = (get_agent_tools $adir)
            let snap_filename = $"base_($a_name)_($target_model).bin"
            print -n $"Prefilling ($a_name) [($target_model)]... "
            let base_payload = {
                model: $model_info.model_name
                messages: [{ role: "system", content: $a_conf.system_prompt } { role: "user", content: " " }]
                max_tokens: 1
                id_slot: 0
                cache_prompt: true
            }
            let payload = if not ($tools | is-empty) { $base_payload | insert tools $tools } else { $base_payload }
            let run_res = (try { http post --content-type "application/json" --max-time 60sec $chat_url ($payload | to json -r) } catch { null })
            if $run_res == null {
                print $"(ansi red)[failed](ansi reset)"
            } else {
                let save_res = (try { http post --content-type "application/json" $"($slots_url)/0?action=save" ({ model: $target_model, filename: $snap_filename } | to json -r) } catch { null })
                if $save_res != null and ($save_res.timings?.save_ms? != null) {
                    print $"(ansi green)[ok](ansi reset) saved ($save_res.n_saved? | default 0) tokens in ($save_res.timings.save_ms | math round -p 1)ms -> ($snap_filename)"
                } else {
                    print $"(ansi red)[failed to save snapshot](ansi reset)"
                }
            }
        }
    }
}

# Stateless direct completion against any model without agent or session overhead
def "main raw" [
    prompt?: string              # Prompt text (or pipe via stdin)
    --model (-m): string = ""    # Model alias (defaults to default_model)
    --system (-s): string = ""   # Optional system instructions
    --image (-i): string = ""    # Path to image file for multimodal models
    --max-tokens: int = 1024     # Max output tokens
    --temp: float = 0.1          # Sampling temperature
    --think (-t): string = ""    # Reasoning control: off, low, medium, high, on
] {
    let piped = if not (is-terminal --stdin) { open --raw /dev/stdin } else { "" }
    let p_str = ($prompt | default "")
    let full_prompt = if (not ($piped | is-empty)) and (not ($p_str | is-empty)) { $"($piped)\n\n($p_str)" } else if not ($p_str | is-empty) { $p_str } else { $piped }

    if ($full_prompt | is-empty) {
        help "main raw"
    } else {
        load_ken_env
        let root_conf = (load_root_config)
        let target_m = if not ($model | is-empty) { $model } else { $root_conf.default_model }
        let model_info = (resolve_model_info $target_m $root_conf)
        let think_setting = if not ($think | is-empty) { $think } else { $model_info.thinking? | default ($model_info.reasoning_effort? | default "") }

        let metrics_dir = (get_cache_dir "metrics")
        let metrics_file = if ($env.KEN_METRICS_FILE? | default "" | is-empty) {
            let f = ($metrics_dir | path join $"run_(date now | format date '%Y%m%d_%H%M%S')_($nu.pid).jsonl")
            "" | save -f $f
            $f
        } else {
            $env.KEN_METRICS_FILE
        }
        load-env { KEN_METRICS_FILE: $metrics_file, KEN_TTY: ((tty) | into int | into string) }

        let sys_msgs = if not ($system | is-empty) { [{ role: "system", content: $system }] } else { [] }
        let user_content = if (not ($image | is-empty)) and ($image | path exists) {
            let b64 = (open --raw $image | encode base64)
            [{ type: "text", text: $full_prompt } { type: "image_url", image_url: { url: $"data:image/jpeg;base64,($b64)" } }]
        } else {
            $full_prompt
        }
        let messages = ($sys_msgs | append { role: "user", content: $user_content })
        let base_payload = { model: $model_info.model_name, messages: $messages, temperature: $temp, max_tokens: $max_tokens, stream: true, stream_options: { include_usage: true } }
        let local_payload = if $model_info.is_local { $base_payload | insert timings_per_token true | insert cache_prompt true } else { $base_payload }
        let payload = (apply_thinking_payload $local_payload $think_setting)

        let depth = (try { $env.KEN_DEPTH | into int } catch { 0 })
        let indent = ("" | fill -c " " -w ($depth * 2))
        let t_start = (date now)
        tty_report $"\n($indent)[ raw.($model_info.alias) @ ($t_start | format date '%H:%M:%S')\n"

        let step = (stream_chat $payload $model_info $root_conf "raw" 1 $indent $t_start 0 true)
        if $step.ok and (stdout) { print -n $step.content }
    }
}

# Dump OpenAI tool schema for an agent
def "main schema" [agent?: string] {
    let root_conf = (load_root_config)
    let target = if ($agent | default "" | is-not-empty) { $agent } else { $root_conf.default_agent }
    get_agent_tools (resolve_agent_dir $target) | to json
}

# Delegate a task to a specialized domain agent
def "main call_agent" [
    --agent (-a): string          # Target agent name
    --task (-t): string           # The specific prompt or task for the agent
    --model (-m): string = ""     # Optional model override
] {
    do_call_agent $agent $task $model
}

# Manage persistent chat sessions
def "main session" [] {
    help "main session"
}

# List all active persistent sessions
def "main session list" [] {
    let s_dir = (get_cache_dir "sessions")
    let paths = (glob ($s_dir | path join "*.json"))
    if ($paths | is-empty) {
        print "No active sessions found."
    } else {
        $paths
        | each { |p|
            let data = (open $p)
            let sz = (((ls $p | get 0.size | into int) / 1024) | math round --precision 1)
            { session: ($data.session_id? | default ($p | path parse | get stem)), agent: ($data.agent? | default "unknown"), messages: ($data.messages? | default [] | length), size: $"($sz) KB", updated_at: ($data.updated_at? | default "unknown") }
        }
        | sort-by updated_at -r
    }
}

# Inspect messages inside a session
def "main session show" [
    target: string = "0"          # Session ID or name (default: 0)
] {
    let s_dir = (get_cache_dir "sessions")
    let exact = (glob ($s_dir | path join $"*_($target).json"))
    let match_f = if not ($exact | is-empty) { $exact | first } else { glob ($s_dir | path join $"*($target)*.json") | first }

    if $match_f == null {
        print -e $"Error: Session '($target)' not found in ($s_dir)"
    } else {
        let data = (open $match_f)
        print $"(ansi cyan_bold)=== Session: ($data.session_id? | default $target) [($data.agent? | default 'unknown')] ===(ansi reset)"
        print $"(ansi dark_gray)File: ($match_f) | Last updated: ($data.updated_at? | default 'unknown')(ansi reset)\n"
        for msg in ($data.messages? | default []) {
            let content = if ($msg.content | describe) =~ "string" { $msg.content } else { $msg.content | to json }
            match $msg.role {
                "system" => { print $"(ansi dark_gray)[system]: ($content | lines | first | default '')...(ansi reset)\n" }
                "user" => { print $"(ansi green_bold)[user]:(ansi reset)\n($content)\n" }
                "assistant" => { print $"(ansi yellow_bold)[assistant]:(ansi reset)\n($content)\n" }
                _ => { print $"(ansi magenta_bold)[($msg.role)]:(ansi reset)\n($content)\n" }
            }
        }
    }
}

# Clear session history and associated KV slot caches
def "main session clear" [
    target: string = "all"        # Session ID to clear or 'all'
] {
    let s_dir = (get_cache_dir "sessions")
    let slots_dir = (get_cache_dir "slots")
    if $target in ["all" "*"] {
        for f in (glob ($s_dir | path join "*.json")) { rm -f $f }
        for f in (glob ($slots_dir | path join "sess_*.bin")) { rm -f $f }
        print "✓ All sessions cleared."
    } else {
        let matched = (glob ($s_dir | path join $"*($target)*.json"))
        if ($matched | is-empty) {
            print $"No session found matching '($target)'."
        } else {
            for f in $matched {
                rm -f $f
                print $"✓ Cleared session file: ($f | path basename)"
            }
            for s in (glob ($slots_dir | path join $"sess_*_($target)_*.bin")) { rm -f $s }
        }
    }
}

# Rename or commit a session (source defaults to 0)
def "main session rename" [
    arg1?: string                 # Destination name (if one arg) or source session ID
    arg2?: string                 # Destination name when source is specified
] {
    let s_dir = (get_cache_dir "sessions")
    let slots_dir = (get_cache_dir "slots")
    let src = if ($arg2 | default "" | is-not-empty) { $arg1 } else { "0" }
    let dst = if ($arg2 | default "" | is-not-empty) { $arg2 } else { $arg1 }

    if ($dst | default "" | is-empty) {
        help "main session rename"
    } else {
        let matched_files = (glob ($s_dir | path join $"*_($src).json"))
        if ($matched_files | is-empty) {
            print -e $"Error: No active session found matching '($src)' in ($s_dir)"
        } else {
            for f in $matched_files {
                let new_name = (($f | path basename) | str replace -r $"_($src)\\.json$" $"_($dst).json")
                let new_path = ($s_dir | path join $new_name)
                (open $f | upsert session_id $dst | upsert updated_at (date now | format date "%Y-%m-%d %H:%M:%S")) | to json -r | save -f $new_path
                if $f != $new_path { rm -f $f }
                print $"✓ Session '($src)' renamed to '($dst)' -> ($new_name)"
            }
            for s in (glob ($slots_dir | path join $"sess_*_($src)_*.bin")) {
                mv -f $s ($slots_dir | path join ($s | path basename | str replace $"_($src)_" $"_($dst)_"))
            }
        }
    }
}

# Start or reset a session
def "main session new" [
    id: string = "0"              # Session ID to reset (default: 0)
] {
    let s_dir = (get_cache_dir "sessions")
    let slots_dir = (get_cache_dir "slots")
    for f in (glob ($s_dir | path join $"*_($id).json")) { rm -f $f }
    for s in (glob ($slots_dir | path join $"sess_*_($id)_*.bin")) { rm -f $s }
    print $"✓ Session '($id)' reset."
}

# Emit shell configuration and keybinding snippet
def "main setup" [
    shell_name?: string           # Target shell (zsh, bash, fish, nu)
    config_dir?: string           # Config directory path
] {
    let sh = if not ($shell_name | is-empty) {
        $shell_name | path basename
    } else if not ($env.SHELL? | default "" | is-empty) {
        $env.SHELL | path basename
    } else {
        "zsh"
    }
    let default_cfg = if not ($env.XDG_CONFIG_HOME? | default "" | is-empty) { $env.XDG_CONFIG_HOME | path join "ken" } else { $env.HOME | path join ".config" "ken" }
    let target_dir = if not ($config_dir | is-empty) { $config_dir | path expand } else { $default_cfg }

    match $sh {
        "zsh" => {
            [
                $"export KEN_DIR=\"($target_dir)\""
                $"export KEN_ROOT=\"($target_dir)\""
                'if [[ -n "$ZSH_VERSION" ]]; then'
                '    _ken_execute_widget() {'
                '        local input_text="$BUFFER"'
                '        [[ -z "${input_text//[[:space:]]/}" ]] && { printf "\a"; return; }'
                '        zle -I'
                '        local out'
                "        if [[ \"$input_text\" =~ '^[[:space:]]*#' ]]; then"
                '            out=$(KEN_TTY=0 ken cmd "GENERATE: ${input_text#*#}" 2>/dev/null)'
                '            [[ -n "$out" && "$out" != *\; ]] && out="${out%"${out##*[![:space:]]}"};"'
                '        elif [[ "$input_text" == *#* ]]; then'
                '            out=$(KEN_TTY=0 ken cmd "MODIFY: Base command: ${input_text%%#*} | Instruction: ${input_text#*#}" 2>/dev/null)'
                '            [[ -n "$out" && "$out" != *\; ]] && out="${out%"${out##*[![:space:]]}"};"'
                "        elif [[ \"$input_text\" =~ ';[[:space:]]*$' ]]; then"
                '            out=$(KEN_TTY=0 ken cmd "EXPLAIN: $input_text" 2>/dev/null | sed "s/^/# /")'
                '        fi'
                '        if [[ -n "$out" ]]; then BUFFER="$out"; CURSOR=${#BUFFER}; else printf "\a"; fi'
                '        zle reset-prompt'
                '    }'
                '    zle -N _ken_execute_widget'
                "    bindkey '^[e' _ken_execute_widget"
                'fi'
            ] | str join (char nl) | print
        }
        "fish" => { print $"set -gx KEN_DIR \"($target_dir)\"\nset -gx KEN_ROOT \"($target_dir)\"" }
        "nu" => { print $"$env.KEN_DIR = \"($target_dir)\"\n$env.KEN_ROOT = \"($target_dir)\"" }
        _ => { print $"export KEN_DIR=\"($target_dir)\"\nexport KEN_ROOT=\"($target_dir)\"" }
    }
}

# Run a Ken agent query or session
def main [
    spec?: string                 # Spec format: [session][agent.]<model> or prompt query
    query?: string                # Prompt query (when spec is provided)
    --image (-i): string = ""     # Pass image for multimodal models
    --slot: int = -1              # Force llama-server KV slot ID
    --think (-t): string = ""     # Reasoning control: off, low, medium, high, on
    --no-md                       # Disable telemetry header/footer banners
] {
    let piped_input = if not (is-terminal --stdin) { open --raw /dev/stdin } else { "" }
    let raw_spec = ($spec | default "")
    let raw_query = ($query | default "")

    if ($raw_spec | is-empty) and ($piped_input | is-empty) {
        help main
    } else {
        let resolved = if ($raw_query | is-empty) and ($piped_input | is-empty) and (not ($raw_spec | is-empty)) {
            let root_conf = (load_root_config)
            let ken_root = (get_ken_root)
            let all_aliases = ($root_conf.providers? | default {} | values | each { |p| $p.models? | default {} | columns } | flatten)
            let has_session_digit = not ($raw_spec | parse -r '^(?<session>\d+)(?<rest>.*)$' | is-empty)
            let is_model_alias = ($raw_spec in $all_aliases)
            let agent_dir = ($ken_root | path join $raw_spec)
            let is_agent_dir = (($agent_dir | path exists) and (($agent_dir | path type) == "dir"))
            let is_dotted = ($raw_spec | str contains ".")
            if not ($has_session_digit or $is_model_alias or $is_agent_dir or $is_dotted) {
                { spec: "", query: $raw_spec }
            } else {
                { spec: $raw_spec, query: "" }
            }
        } else {
            { spec: $raw_spec, query: $raw_query }
        }

        let full_query = if (not ($piped_input | is-empty)) and (not ($resolved.query | is-empty)) {
            $"($piped_input)\n\n($resolved.query)"
        } else if not ($resolved.query | is-empty) {
            $resolved.query
        } else {
            $piped_input
        }

        if ($full_query | is-empty) {
            print -e "Error: No query provided. Pass as argument or pipe via stdin."
        } else {
            run_agent $resolved.spec $full_query $image $slot $no_md $think
        }
    }
}
