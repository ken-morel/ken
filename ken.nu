#!/usr/bin/env nu
# Ken - Local Agentic Assistant in pure Nushell

def get_ken_root [] {
    # 1. Explicit environment variable set by shell / ken setup
    if not ($env.KEN_DIR? | default "" | is-empty) and ($env.KEN_DIR | path exists) {
        return ($env.KEN_DIR | path expand)
    }
    if not ($env.KEN_ROOT? | default "" | is-empty) and ($env.KEN_ROOT | path exists) {
        return ($env.KEN_ROOT | path expand)
    }
    # 2. XDG user config directory (~/.config/ken)
    let xdg_dir = (if not ($env.XDG_CONFIG_HOME? | default "" | is-empty) {
        $env.XDG_CONFIG_HOME | path join "ken"
    } else {
        $env.HOME | path join ".config" "ken"
    })
    if (($xdg_dir | path join "config.nuon") | path exists) {
        return $xdg_dir
    }
    # 3. Directory containing the script (for portable standalone copies)
    let script_dir = ($env.FILE_PWD? | default "")
    if not ($script_dir | is-empty) and (($script_dir | path join "config.nuon") | path exists) {
        return $script_dir
    }
    # 4. Current working directory
    if (($env.PWD | path join "config.nuon") | path exists) {
        return $env.PWD
    }
    $xdg_dir
}

def get_local_url [endpoint: string = "", root_conf?: record] {
    let rc = if $root_conf != null { $root_conf } else { load_root_config }
    let base = ($rc.providers?.local?.base_url? | default "http://127.0.0.1:6172/v1")
    let p = ($base | url parse)
    let port_str = (if ($p.port? | default "" | is-not-empty) { $":($p.port)" } else { "" })
    let host = $"($p.scheme)://($p.host)($port_str)"
    match $endpoint {
        "slots" => $"($host)/slots"
        "tokenize" => $"($host)/tokenize"
        _ => $"($base)/chat/completions"
    }
}

def --env load_ken_env [] {
    let ken_root = (get_ken_root)
    let nuon_files = [
        ($ken_root | path join "env.nuon")
        ($ken_root | path join ".env.nuon")
    ]
    for f in $nuon_files {
        if ($f | path exists) {
            let data = (try { open $f } catch { {} })
            if ($data | describe | str starts-with "record") {
                load-env $data
            }
        }
    }
    let env_file = ($ken_root | path join ".env")
    if ($env_file | path exists) {
        for line in (open --raw $env_file | lines) {
            let trimmed = ($line | str trim)
            if ($trimmed | is-empty) or ($trimmed | str starts-with "#") { continue }
            if ($trimmed | str contains "=") {
                let parts = ($trimmed | split row -n 2 "=")
                let k = ($parts | get 0 | str trim)
                let v = ($parts | get 1 | str trim | str trim -c '"' | str trim -c "'")
                load-env { $k: $v }
            }
        }
    }
}

def resolve_model_info [model_alias: string, root_conf: record] {
    let providers = ($root_conf.providers? | default {})

    for p_name in ($providers | columns) {
        let p_data = ($providers | get $p_name)
        let p_models = ($p_data.models? | default {})
        
        # 1. Direct alias match (e.g. q, l, d, dskc, dskr, gf, gp)
        if ($p_models | get -o $model_alias) != null {
            let m_info = ($p_models | get $model_alias)
            mut auth_hdr: any = null
            if ($p_data.api_key_env? | default "" | is-not-empty) {
                let k_val = ($env | get -o $p_data.api_key_env | default "")
                if ($k_val | is-not-empty) {
                    $auth_hdr = $"Bearer ($k_val)"
                }
            }
            return {
                alias: $model_alias
                provider: $p_name
                model_name: ($m_info.name? | default $model_alias)
                description: ($m_info.description? | default "")
                ctx: ($m_info.ctx? | default $root_conf.default_ctx)
                base_url: $p_data.base_url
                auth_header: $auth_hdr
                pricing: ($m_info.pricing? | default { input: 0.0, output: 0.0, cache_hit: 0.0 })
                is_local: ($p_name == "local")
                thinking: ($m_info.thinking? | default ($m_info.options?.thinking? | default null))
                reasoning_effort: ($m_info.reasoning_effort? | default ($m_info.options?.reasoning_effort? | default null))
            }
        }

        # 2. Match by underlying model name (e.g. "qwen" -> "q", "deepseek-chat" -> "dskc")
        for m_key in ($p_models | columns) {
            let m_info = ($p_models | get $m_key)
            if ($m_info.name? | default "") == $model_alias {
                mut auth_hdr: any = null
                if ($p_data.api_key_env? | default "" | is-not-empty) {
                    let k_val = ($env | get -o $p_data.api_key_env | default "")
                    if ($k_val | is-not-empty) {
                        $auth_hdr = $"Bearer ($k_val)"
                    }
                }
                return {
                    alias: $m_key
                    provider: $p_name
                    model_name: $m_info.name
                    description: ($m_info.description? | default "")
                    ctx: ($m_info.ctx? | default $root_conf.default_ctx)
                    base_url: $p_data.base_url
                    auth_header: $auth_hdr
                    pricing: ($m_info.pricing? | default { input: 0.0, output: 0.0, cache_hit: 0.0 })
                    is_local: ($p_name == "local")
                    thinking: ($m_info.thinking? | default ($m_info.options?.thinking? | default null))
                    reasoning_effort: ($m_info.reasoning_effort? | default ($m_info.options?.reasoning_effort? | default null))
                }
            }
        }
    }

    # Fallback to local
    {
        alias: $model_alias
        provider: "local"
        model_name: $model_alias
        description: ""
        ctx: $root_conf.default_ctx
        base_url: "http://127.0.0.1:6172/v1"
        auth_header: null
        pricing: { input: 0.0, output: 0.0, cache_hit: 0.0 }
        is_local: true
    }
}

def format_cost [amount: float, currency: string = "$"] {
    if $amount == 0.0 {
        return (match $currency {
            "$" => "$0"
            "€" => "0€"
            "£" => "£0"
            "¥" => "¥0"
            _ => $"0 ($currency)"
        })
    }
    let rounded = if $amount < 0.0001 and $amount > 0.0 {
        ($amount | math round -p 6)
    } else {
        ($amount | math round -p 4)
    }
    match $currency {
        "$" | "£" | "¥" => $"($currency)($rounded)"
        "€" => $"($rounded)€"
        _ => $"($rounded) ($currency)"
    }
}

def calculate_cost [pricing: record, prompt_tokens: int, completion_tokens: int, cached_tokens: int, currency: string = "$"] {
    let in_price = ($pricing.input? | default 0.0 | into float)
    let out_price = ($pricing.output? | default 0.0 | into float)
    let cache_price = ($pricing.cache_hit? | default 0.0 | into float)

    let uncached_prompt = (if $prompt_tokens >= $cached_tokens { $prompt_tokens - $cached_tokens } else { $prompt_tokens })
    let cost = (($uncached_prompt / 1000000.0) * $in_price) + (($completion_tokens / 1000000.0) * $out_price) + (($cached_tokens / 1000000.0) * $cache_price)

    let label = (format_cost $cost $currency)

    {
        amount: $cost
        currency: $currency
        label: $label
        is_free: ($in_price == 0.0 and $out_price == 0.0)
    }
}

def get_known_models [] {
    let rc = (load_root_config)
    let local_base = ($rc.providers?.local?.base_url? | default "http://127.0.0.1:6172/v1")
    let from_api = (try {
        http get --max-time 1sec $"($local_base)/models" | get data.id
    } catch { [] })
    if not ($from_api | is-empty) {
        return $from_api
    }

    let ini_path = ($env.HOME | path join "models" "models.ini")
    if ($ini_path | path exists) {
        return (open $ini_path | lines | where ($it | str starts-with "[") and ($it != "[*]") | each { str replace "[" "" | str replace "]" "" | str trim })
    }

    if not ($rc.default_model | is-empty) {
        return [$rc.default_model]
    }
    []
}

def get_model_ctx [model: string] {
    let rc = (load_root_config)
    let m_info = (try { resolve_model_info $model $rc } catch { null })
    if $m_info != null and ($m_info.ctx? | default null) != null {
        return ($m_info.ctx | into int)
    }
    let local_base = ($rc.providers?.local?.base_url? | default "http://127.0.0.1:6172/v1")
    let models_res = (try { http get --max-time 1sec $"($local_base)/models" } catch { null })
    if $models_res != null {
        let m_data = ($models_res.data? | default [] | where id == $model | first)
        let ctx = ($m_data.meta?.n_ctx? | default null)
        if $ctx != null { return ($ctx | into int) }
        let args = ($m_data.status?.args? | default [])
        for idx in 0..(($args | length) - 1) {
            if ($args | get -o $idx) == "--ctx-size" {
                let val = ($args | get -o ($idx + 1))
                if $val != null { return ($val | into int) }
            }
        }
    }
    ($rc.default_ctx? | default 8192)
}

def get_session_dir [] {
    let d = ($env.HOME | path join ".cache" "ken" "sessions")
    mkdir $d
    $d
}

def get_metrics_dir [] {
    let d = ($env.HOME | path join ".cache" "ken" "metrics")
    mkdir $d
    $d
}

def get_slots_dir [model: string = ""] {
    let d = ($env.HOME | path join ".cache" "ken" "slots")
    mkdir $d
    $d
}

def tty_report [msg: string] {
    if ("/dev/tty" | path exists) {
        $msg | save --append "/dev/tty"
    } else {
        print -e -n $msg
    }
}

def load_root_config [] {
    let ken_root = (get_ken_root)
    let conf_path = ($ken_root | path join "config.nuon")
    mut root_conf = {
        default_agent: ""
        default_model: ""
        default_ctx: 8192
        options: {}
        models: {}
        providers: {}
    }
    if ($conf_path | path exists) {
        let loaded = (try { open $conf_path } catch { {} })
        $root_conf = ($root_conf | merge ($loaded | default {}))
    }
    # Auto-detect default_agent if empty
    if ($root_conf.default_agent | is-empty) {
        let candidate_agents = (try {
            ls $ken_root | where type == dir and (not ($it.name | path basename | str starts-with ".")) and ($it.name | path basename) != "bin" | get name | each { path basename }
        } catch { [] })
        if not ($candidate_agents | is-empty) {
            $root_conf = ($root_conf | upsert default_agent ($candidate_agents | first))
        }
    }
    # Auto-detect default_model if empty
    if ($root_conf.default_model | is-empty) {
        let first_model = (try {
            $root_conf.providers | values | get 0.models | columns | get 0
        } catch { "" })
        if not ($first_model | is-empty) {
            $root_conf = ($root_conf | upsert default_model $first_model)
        }
    }
    $root_conf
}

def load_agent_config [agent_dir: string, root_conf?: record] {
    let base_conf = (if $root_conf != null { $root_conf } else { load_root_config })
    let conf_path = ($agent_dir | path join "config.nuon")
    mut agent_conf = {
        name: ($agent_dir | path basename)
        description: ""
        default_model: $base_conf.default_model
        subagents: []
        supported_models: []
        options: $base_conf.options
        models: $base_conf.models
        system_prompt: ""
    }

    if ($conf_path | path exists) {
        let loaded = (try { open $conf_path } catch { {} })
        if ($loaded.name? | default "" | is-not-empty) { $agent_conf.name = $loaded.name }
        if ($loaded.description? | default "" | is-not-empty) { $agent_conf.description = $loaded.description }
        if ($loaded.default_model? | default "" | is-not-empty) { $agent_conf.default_model = $loaded.default_model }
        if ($loaded.subagents? != null) { $agent_conf.subagents = $loaded.subagents }
        if ($loaded.supported_models? != null) { $agent_conf.supported_models = $loaded.supported_models }
        if ($loaded.options? != null) {
            $agent_conf.options = ($agent_conf.options | merge ($loaded.options | default {}))
        }
        if ($loaded.models? != null) {
            $agent_conf.models = ($agent_conf.models | merge ($loaded.models | default {}))
        }
        if ($loaded.system_prompt? | default "" | is-not-empty) {
            $agent_conf.system_prompt = $loaded.system_prompt
        }
    }

    if ($agent_conf.system_prompt | default "" | is-empty) {
        let prompt_path = ($agent_dir | path join "prompt.md")
        if ($prompt_path | path exists) {
            $agent_conf.system_prompt = (open --raw $prompt_path)
        } else {
            $agent_conf.system_prompt = $"You are the Ken ($agent_conf.name) agent."
        }
    }

    $agent_conf
}

def resolve_model_params [agent_conf: record, model_id: string] {
    let global_opts = ($agent_conf.options? | default {})
    let model_opts = ($agent_conf.models? | default {} | get -o $model_id | default {})
    $global_opts | merge $model_opts
}

# Parse model specifier dynamically: [session][agent.]<model> or [session][agent] or [session][model]
def parse_spec [spec_str: string] {
    let raw = ($spec_str | default "" | str trim)
    let root_conf = (load_root_config)
    let def_agent = ($root_conf.default_agent? | default "orchestrator")
    if ($raw | is-empty) {
        return { session: null, agent: $def_agent, model: null, model_explicit: false }
    }

    let p_sess = ($raw | parse -r '^(?<session>\d+)?(?<rest>.*)$' | first)
    let session = (if ($p_sess.session? | default "" | is-empty) { null } else { $p_sess.session })
    let rest = $p_sess.rest
    let ken_root = (get_ken_root)

    # 1. Explicit dot notation: <agent>.<model>
    if ($rest | str contains ".") {
        let parts = ($rest | split row ".")
        let a = ($parts | get 0)
        let m = ($parts | get 1)
        return { session: $session, agent: $a, model: $m, model_explicit: true }
    }

    # 2. Check if name matches an existing agent folder in ken
    let agent_path = ($ken_root | path join $rest)
    if ($agent_path | path exists) and ($agent_path | path type) == "dir" {
        return { session: $session, agent: $rest, model: null, model_explicit: false }
    }

    # 3. Model alias (e.g. q, l, d, dskc, dskr, gf, gp)
    { session: $session, agent: $def_agent, model: $rest, model_explicit: true }
}

def resolve_agent_dir [agent: string] {
    let root = (get_ken_root)
    let root_conf = (load_root_config)
    let def_agent = ($root_conf.default_agent? | default "orchestrator")
    if $agent in ["ken" $def_agent] {
        let p = ($root | path join $def_agent)
        if ($p | path exists) { return $p }
    }
    $root | path join $agent
}

# Introspect Nushell tools in agent directory and generate OpenAI schemas
def get_agent_tools [agent_dir: string] {
    if not ($agent_dir | path exists) { return [] }
    let nu_files = (glob ($agent_dir | path join "*.nu") | where { |it| ($it | path parse | get stem) != "call_agent" } | sort)
    
    mut tools = []
    for f in $nu_files {
        let tool_name = ($f | path parse | get stem)
        let info = (try {
            nu -c $"source '($f)'; scope commands | where name == 'main' | select description signatures | to json" | from json | first
        } catch { null })
        if $info == null { continue }

        let desc = ($info.description? | default $"Execute ($tool_name)")
        let sigs = ($info.signatures?.any? | default [])
        
        mut properties = {}
        mut required = []

        for p in $sigs {
            let p_name = $p.parameter_name
            if $p_name == null or $p.parameter_type in ["input" "output"] { continue }

            let p_type = match $p.syntax_shape {
                "int" => "integer"
                "bool" => "boolean"
                _ => (if $p.parameter_type == "switch" { "boolean" } else { "string" })
            }
            let p_desc = ($p.description? | default $"Parameter ($p_name)")
            $properties = ($properties | insert $p_name { type: $p_type, description: $p_desc })

            if (not ($p.is_optional? | default true)) and ($p.parameter_type != "switch") {
                $required = ($required | append $p_name)
            }
        }

        $tools = ($tools | append {
            type: "function"
            function: {
                name: $tool_name
                description: $desc
                parameters: {
                    type: "object"
                    properties: $properties
                    required: $required
                }
            }
        })
    }

    # Auto-generate call_agent tool if agent has callable subagents declared in config.nuon
    let agent_conf = (load_agent_config $agent_dir)
    let available_agents = ($agent_conf.subagents? | default [] | uniq | sort)

    if not ($available_agents | is-empty) {
        let agent_docs = ($available_agents | each { |a_name|
            let a_dir = (resolve_agent_dir $a_name)
            let conf_file = ($a_dir | path join "config.nuon")
            let a_desc = (if ($conf_file | path exists) {
                try { (open $conf_file).description? | default "" } catch { "" }
            } else { "" })
            if not ($a_desc | is-empty) {
                $"- ($a_name): ($a_desc)"
            } else {
                $"- ($a_name)"
            }
        } | str join "\n")

        let root_conf = (load_root_config)
        mut model_items = []
        for p in ($root_conf.providers | values) {
            for m_alias in ($p.models | columns) {
                let m_info = ($p.models | get $m_alias)
                let m_desc = ($m_info.description? | default $m_info.name)
                $model_items = ($model_items | append { alias: $m_alias, desc: $"- ($m_alias): ($m_desc)" })
            }
        }
        let model_aliases = ($model_items | get alias | sort)
        let model_docs = ($model_items | get desc | str join "\n")
        let cur_m = ($env.KEN_MODEL? | default ($root_conf.default_model))

        $tools = ($tools | append {
            type: "function"
            function: {
                name: "call_agent"
                description: "Delegate a specialized task to a domain specialist agent"
                parameters: {
                    type: "object"
                    properties: {
                        agent: {
                            type: "string"
                            enum: $available_agents
                            description: $"Target agent to delegate to. Available agents:\n($agent_docs)"
                        }
                        task: {
                            type: "string"
                            description: "The specific prompt, instruction, or task for the specialist agent"
                        }
                        model: {
                            type: "string"
                            enum: $model_aliases
                            description: $"Optional model override. Defaults to inheriting caller's model ($cur_m). Available models:\n($model_docs)"
                        }
                    }
                    required: ["agent", "task"]
                }
            }
        })
    }

    $tools
}

def do_call_agent [
    agent: string
    task: string
    model: string = ""
    caller_agent?: string
] {
    let depth = (try { $env.KEN_DEPTH | into int } catch { 0 })
    if $depth >= 3 {
        return "Error: Maximum agent recursion depth (3) reached. Synthesize final answer."
    }

    let ken_root = (get_ken_root)
    let root_conf = (load_root_config)
    let def_agent = $root_conf.default_agent
    let caller_name = (if not ($caller_agent | is-empty) { $caller_agent } else { $env.KEN_AGENT? | default $def_agent })
    let caller_dir = (resolve_agent_dir $caller_name)

    # Resolve target agent: must be declared in caller's subagents
    let caller_conf = (load_agent_config $caller_dir)
    let allowed_subagents = ($caller_conf.subagents? | default [])
    let is_allowed = ($agent in $allowed_subagents)

    if not $is_allowed {
        return $"Error: Agent '($agent)' is not available in ($caller_name)."
    }

    # Resolve target model:
    # 1. Explicit --model flag from caller
    # 2. Cloud caller propagates cloud model down
    # 3. Inherit caller model if supported by target agent
    # 4. Target default model
    let target_dir = (resolve_agent_dir $agent)
    let target_conf = (load_agent_config $target_dir)

    let supported_models = ($target_conf.supported_models? | default [])
    let target_default = ($target_conf.default_model? | default "")
    let caller_model = ($env.KEN_MODEL? | default "")
    let is_cloud_caller = ($caller_model | str starts-with "a")

    let chosen_model = if not ($model | is-empty) {
        $model
    } else if $is_cloud_caller {
        $caller_model
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

    let ken_nu = ($ken_root | path join "ken.nu")
    let res = (with-env { KEN_DEPTH: $next_depth } {
        if ($ken_nu | path exists) {
            ^$ken_nu $full_spec $task | complete
        } else {
            ^ken $full_spec $task | complete
        }
    })

    if $res.exit_code == 0 {
        $res.stdout
    } else {
        $"Error running agent ($agent): ($res.stderr)\n($res.stdout)"
    }
}

def record_metric [item: record] {
    let f = ($env.KEN_METRICS_FILE? | default "")
    if ($f | is-not-empty) {
        try {
            $"($item | to json -r)\n" | save --append $f
        }
    }
}

def get_cumulative_cost [currency: string = "$"] {
    let f = ($env.KEN_METRICS_FILE? | default "")
    if ($f | is-not-empty) and ($f | path exists) {
        let rows = (try { open --raw $f | lines | where ($it | is-not-empty) | each { from json } } catch { [] })
        if not ($rows | is-empty) {
            let sum_amount = ($rows | each { |r| ($r.cost? | default ($r.cost_usd? | default 0.0) | into float) } | math sum)
            return { amount: $sum_amount, currency: $currency }
        }
    }
    { amount: 0.0, currency: $currency }
}

def format_cost_label [cost_res: record, cum_cost: record] {
    let cur = ($cost_res.currency? | default "$")
    if ($cost_res.amount == 0.0 or $cost_res.is_free) and ($cum_cost.amount == 0.0) {
        return (format_cost 0.0 $cur)
    }
    let u_turn = (format_cost $cost_res.amount $cur)
    let u_tot = (format_cost $cum_cost.amount $cur)
    if $u_turn == $u_tot {
        $u_tot
    } else {
        $"($u_turn) \(tot: ($u_tot)\)"
    }
}

def format_ms [ms: int] {
    if $ms < 1000 {
        $"($ms)ms ttft"
    } else {
        $"($ms / 1000.0 | math round -p 1)s ttft"
    }
}

def format_duration [dur: duration] {
    let sec = (($dur | into int) / 1_000_000_000.0)
    if $sec < 1.0 {
        let ms = ($sec * 1000.0 | math round)
        $"($ms)ms"
    } else if $sec < 60.0 {
        $"($sec | math round -p 1)s"
    } else {
        let m = ($sec // 60 | into int)
        let s = ($sec mod 60 | math round -p 1)
        $"($m)m ($s)s"
    }
}

def count_text_tokens [text: string] {
    if ($text | is-empty) { return 0 }
    let tok_url = (get_local_url "tokenize")
    let res = (try {
        http post --max-time 150ms --content-type "application/json" $tok_url ({ content: $text } | to json -r)
    } catch { null })
    if ($res.tokens? | default null) != null {
        return ($res.tokens | length)
    }
    # Fast fallback estimation: max(words * 1.3, chars / 4)
    let words = ($text | split words | length)
    let chars = ($text | str length)
    [($words * 1.3 | math round | into int), ($chars // 4)] | math max
}

def execute_tool [agent_dir: string, fn_name: string, args_json: string] {
    let args_dict = (try { $args_json | from json } catch { {} })
    let agent_name = ($agent_dir | path basename)
    let is_call_agent = ($fn_name in ["call_agent" "call-agent"])
    let tool_path = ($agent_dir | path join $"($fn_name).nu")

    if not $is_call_agent and not ($tool_path | path exists) {
        return $"Error: Tool '($fn_name)' not found in agent '($agent_name)'."
    }

    mut pos_args = []
    mut named_args = []

    if not $is_call_agent {
        let tool_info = (try {
            nu -c $"source '($tool_path)'; scope commands | where name == 'main' | select signatures | to json" | from json | first
        } catch { null })

        let sigs = ($tool_info.signatures?.any? | default [])
        for p in $sigs {
            let p_name = $p.parameter_name
            if $p_name == null or $p.parameter_type in ["input" "output"] { continue }
            if ($args_dict | get -o $p_name) != null {
                let val = ($args_dict | get $p_name)
                if $p.parameter_type == "positional" {
                    $pos_args = ($pos_args | append ($val | into string))
                } else if $p.parameter_type == "switch" {
                    if ($val == true) { $named_args = ($named_args | append $"--($p_name)") }
                } else {
                    $named_args = ($named_args | append $"--($p_name)" | append ($val | into string))
                }
            }
        }
    }

    # Format detailed tool command line
    let formatted_args = ($args_dict | transpose key val | each { |it|
        $"--($it.key) '($it.val)'"
    } | str join " ")

    let depth = (try { $env.KEN_DEPTH | into int } catch { 0 })
    let indent = ("" | fill -c " " -w ($depth * 2))

    let t_start = (date now)
    let time_start_str = ($t_start | format date "%H:%M:%S")
    tty_report $"\n($indent){ ($agent_name)/($fn_name) ($formatted_args) @ ($time_start_str)\n"

    # Virtual Slot Management: If calling subagent (call_agent) on a local model,
    # save active working slot state to SSD so caller KV cache is restored immediately upon return
    let rc = (load_root_config)
    let caller_model = ($env.KEN_MODEL? | default $rc.default_model)
    let is_local_caller = (try {
        (resolve_model_info $caller_model $rc).is_local
    } catch { false })

    let slot_backup_name = $"active_depth_($depth)_($caller_model).bin"
    let slots_url = (get_local_url "slots" $rc)
    if $is_call_agent and $is_local_caller {
        let m_info = (resolve_model_info $caller_model $rc)
        try {
            http post --content-type "application/json" $"($slots_url)/0?action=save" ({ model: $m_info.model_name, filename: $slot_backup_name } | to json -r)
        }
    }

    # Track metrics file lines before tool runs to detect if child model already streamed live to /dev/tty
    let mf = ($env.KEN_METRICS_FILE? | default "")
    let metric_lines_before = if ($mf | is-not-empty) and ($mf | path exists) {
        (try { open --raw $mf | lines | length } catch { 0 })
    } else { 0 }

    let final_pos = $pos_args
    let final_named = $named_args
    let res = if $is_call_agent {
        let target_agent = ($args_dict.agent? | default "")
        let task_str = ($args_dict.task? | default "")
        let model_str = ($args_dict.model? | default "")
        let out = (do_call_agent $target_agent $task_str $model_str $agent_name)
        { stdout: $out, stderr: "", exit_code: 0 }
    } else {
        with-env { KEN_DEPTH: (($depth + 1) | into string) } {
            ^nu $tool_path ...$final_pos ...$final_named | complete
        }
    }

    let t_end = (date now)
    let t_dur = ($t_end - $t_start)
    let time_end_str = ($t_end | format date "%H:%M:%S")

    # Restore caller's working slot after subagent returns
    if $is_call_agent and $is_local_caller {
        let m_info = (resolve_model_info $caller_model $rc)
        try {
            http post --content-type "application/json" $"($slots_url)/0?action=restore" ({ model: $m_info.model_name, filename: $slot_backup_name } | to json -r)
        }
    }

    let metric_lines_after = if ($mf | is-not-empty) and ($mf | path exists) {
        (try { open --raw $mf | lines | length } catch { 0 })
    } else { 0 }
    let child_streamed = ($metric_lines_after > $metric_lines_before)

    if $res.exit_code == 0 {
        let output = (if not ($res.stdout | is-empty) { $res.stdout } else { "(Success with no output)" })
        let n_lines = ($output | lines | length)
        let n_tokens = (count_text_tokens $output)
        
        # Only print raw output if child model didn't already stream live to /dev/tty
        if not $child_streamed {
            let indented_output = ($output | lines | each { |l| $"($indent)  ($l)" } | str join "\n")
            tty_report $"($indented_output)\n"
        }
        tty_report $"($indent)} ($agent_name)/($fn_name) -> ($n_lines)L ($n_tokens)t \((format_duration $t_dur) @ ($time_end_str)\)\n\n"
        $output
    } else {
        tty_report $"($indent)} ($agent_name)/($fn_name) ! exit ($res.exit_code) \((format_duration $t_dur) @ ($time_end_str)\)\n"
        if not ($res.stderr | is-empty) {
            let indented_err = ($res.stderr | lines | each { |l| $"($indent)  ($l)" } | str join "\n")
            tty_report $"($indented_err)\n"
        }
        if not ($res.stdout | is-empty) {
            let indented_out = ($res.stdout | lines | each { |l| $"($indent)  ($l)" } | str join "\n")
            tty_report $"($indented_out)\n"
        }
        tty_report "\n"
        $"Error: ($res.stderr)\n($res.stdout)"
    }
}

def format_stream_token [
    tok: string
    indent: string
    at_start: bool
    prefix: string = ""
    color: string = ""
] {
    if ($tok | is-empty) {
        return { text: "", at_start: $at_start }
    }
    if ($indent | is-empty) and ($prefix | is-empty) and ($color | is-empty) {
        let ends_nl = ($tok | str ends-with "\n")
        return { text: $tok, at_start: $ends_nl }
    }
    let parts = ($tok | split row "\n")
    let n = ($parts | length)
    mut out = ""
    mut cur_start = $at_start
    let reset = (ansi reset)
    let line_pfx = $"($indent)($prefix)($color)"
    
    for i in 0..<($n) {
        let p = ($parts | get $i)
        if $i > 0 {
            if not ($color | is-empty) {
                $out = ($out + $reset)
            }
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

def resolve_thinking_payload [think_val: any] {
    if $think_val == null or ($think_val | into string | is-empty) {
        return {}
    }
    let tv = ($think_val | into string | str lowercase | str trim)
    if $tv in ["off", "false", "none", "0", "disable", "disabled"] {
        {
            chat_template_kwargs: { enable_thinking: false }
            reasoning_budget: 0
        }
    } else if $tv in ["on", "true", "enable", "enabled", "1"] {
        {
            chat_template_kwargs: { enable_thinking: true }
        }
    } else if $tv in ["low", "medium", "high"] {
        {
            chat_template_kwargs: { enable_thinking: true, reasoning_effort: $tv }
            reasoning_effort: $tv
        }
    } else {
        let num = (try { $tv | into int } catch { null })
        if $num != null {
            if $num <= 0 {
                {
                    chat_template_kwargs: { enable_thinking: false }
                    reasoning_budget: 0
                }
            } else {
                {
                    chat_template_kwargs: { enable_thinking: true }
                    reasoning_budget: $num
                }
            }
        } else {
            {
                chat_template_kwargs: { enable_thinking: true, reasoning_effort: $tv }
                reasoning_effort: $tv
            }
        }
    }
}

def apply_thinking_payload [payload: record, think_val: any] {
    let tp = (resolve_thinking_payload $think_val)
    if ($tp | is-empty) { return $payload }
    mut res = $payload
    if ($tp.chat_template_kwargs? != null) {
        let existing = ($res.chat_template_kwargs? | default {})
        $res = ($res | upsert chat_template_kwargs ($existing | merge $tp.chat_template_kwargs))
    }
    if ($tp.reasoning_effort? != null) {
        $res = ($res | upsert reasoning_effort $tp.reasoning_effort)
    }
    if ($tp.reasoning_budget? != null) {
        $res = ($res | upsert reasoning_budget $tp.reasoning_budget)
    }
    $res
}

# Main chat execution loop
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
    let session_id = $parsed.session

    let agent_dir = (resolve_agent_dir $agent_name)
    if not ($agent_dir | path exists) {
        print -e $"Error: Agent directory '($agent_name)' not found."
        return
    }

    load_ken_env
    let root_conf = (load_root_config)
    let agent_conf = (load_agent_config $agent_dir $root_conf)
    let system_prompt = $agent_conf.system_prompt
    let raw_model_spec = (if $parsed.model_explicit {
        $parsed.model
    } else {
        $agent_conf.default_model? | default $root_conf.default_model
    })
    let model_info = (resolve_model_info $raw_model_spec $root_conf)
    let model_alias = $model_info.alias
    let model_id = $model_info.model_name
    let chat_url = $"($model_info.base_url)/chat/completions"

    # Tools: dynamically introspect tools in agent directory
    let tools = (get_agent_tools $agent_dir)

    # Model parameters from cascading config (options + models.<model_id>)
    let model_params = (resolve_model_params $agent_conf $model_alias)
    let think_setting = (if not ($think_override | is-empty) {
        $think_override
    } else if ($model_params.thinking? | default null) != null {
        $model_params.thinking
    } else if ($model_params.reasoning_effort? | default null) != null {
        $model_params.reasoning_effort
    } else if ($model_info.thinking? | default null) != null {
        $model_info.thinking
    } else if ($model_info.reasoning_effort? | default null) != null {
        $model_info.reasoning_effort
    } else {
        ""
    })
    mut clean_params = $model_params
    if ($clean_params.thinking? | default null) != null {
        $clean_params = ($clean_params | reject thinking)
    }

    # Slot allocation by alphabetical agent index (local only)
    let root = (get_ken_root)
    let all_agents = (try { ls $root | where type == dir and (not ($it.name | path basename | str starts-with ".")) and ($it.name | path basename) != "bin" | get name | each { path basename } | sort } catch { [] })
    let match_row = ($all_agents | enumerate | where item == $agent_name)
    let agent_idx = (if ($match_row | is-empty) { 0 } else { $match_row | first | get index })
    let assigned_slot = (if $slot_override >= 0 { $slot_override } else { $agent_idx mod 2 })

    # Slot snapshot check: restore if cached and up-to-date with agent prompt/config (local only)
    let snap_filename = $"($agent_name)_($model_alias).bin"
    mut snapshot_restored = false

    if $model_info.is_local {
        let slots_dir = (get_slots_dir $model_id)
        let snapshot_file = ($slots_dir | path join $snap_filename)
        let snap_exists = ($snapshot_file | path exists)

        if $snap_exists {
            let slots_url = (get_local_url "slots" $root_conf)
            let snap_mtime = (ls $snapshot_file | get 0.modified)
            let agent_mtime = (try { ls $agent_dir | get modified | math max } catch { null })
            if ($agent_mtime == null) or ($snap_mtime >= $agent_mtime) {
                let res = (try {
                    http post --content-type "application/json" $"($slots_url)/($assigned_slot)?action=restore" ({ model: $model_id, filename: $snap_filename } | to json -r)
                } catch { null })
                if $res != null and ($res.timings?.restore_ms? != null) {
                    $snapshot_restored = true
                }
            }
        }
    }

    # Session loading
    let session_dir = (get_session_dir)
    let session_file = ($session_dir | path join $"($agent_name)_($session_id).json")
    mut messages = []
    if $session_id != null and ($session_file | path exists) {
        $messages = (try { open $session_file | get messages } catch { [] })
    }

    if ($messages | is-empty) {
        $messages = [{ role: "system", content: $system_prompt }]
    } else {
        $messages = ($messages | update 0 { role: "system", content: $system_prompt })
    }

    let cur_session = ($session_id | default "default")
    let depth = (try { $env.KEN_DEPTH | into int } catch { 0 })
    let indent = ("" | fill -c " " -w ($depth * 2))
    let is_top_level = ($depth == 0)
    let metrics_dir = (get_metrics_dir)
    let metrics_file = if ($env.KEN_METRICS_FILE? | default "" | is-empty) {
        let now_ts = (date now | format date "%Y%m%d_%H%M%S")
        let f = ($metrics_dir | path join $"run_($now_ts)_($nu.pid).jsonl")
        "" | save -f $f
        $f
    } else {
        $env.KEN_METRICS_FILE
    }

    # Dynamic date prefix only for top-level user message
    let now_str = (date now | format date "%Y-%m-%d %H:%M")
    let user_text = if $is_top_level {
        if not ($query | is-empty) {
            $"The current time is ($now_str).\n\n($query)"
        } else {
            $"The current time is ($now_str)."
        }
    } else {
        $query
    }

    mut user_content: any = $user_text
    if not ($image_path | is-empty) and ($image_path | path exists) {
        let b64 = (open --raw $image_path | encode base64)
        $user_content = [
            { type: "text", text: $user_text }
            { type: "image_url", image_url: { url: $"data:image/jpeg;base64,($b64)" } }
        ]
    }

    $messages = ($messages | append { role: "user", content: $user_content })

    let has_tty = ("/dev/tty" | path exists)
    let is_interactive = ($has_tty or (is-terminal --stdout)) and ($env.TERM? != "dumb") and (not $no_md)
    let t_run_start = (date now)
    let time_start_str = ($t_run_start | format date "%H:%M:%S")

    if (not $no_md) {
        tty_report $"\n($indent)[ ($agent_name).($model_alias) @ ($time_start_str)\n"
    }

    mut total_prompt_tokens = 0
    mut total_pred_tokens = 0
    mut total_cached_tokens = 0

    # Export execution context to tools and subagents
    load-env {
        KEN_SESSION: $cur_session
        KEN_AGENT: $agent_name
        KEN_MODEL: $model_alias
        KEN_ROOT: $root
        KEN_DEPTH: ($env.KEN_DEPTH? | default "0")
        KEN_METRICS_FILE: $metrics_file
    }

    # Conversation / tool-calling turns (up to 8)
    mut final_response = ""
    for turn in 0..7 {
        let t_turn_start = (date now)
        mut turn_timings: any = null
        mut turn_usage: any = null

        mut payload = {
            model: $model_id
            messages: $messages
            stream: true
            stream_options: { include_usage: true }
        }
        if $model_info.is_local {
            $payload = ($payload | insert timings_per_token true | insert cache_prompt true | insert id_slot $assigned_slot)
        }
        $payload = ($payload | merge $clean_params)
        $payload = (apply_thinking_payload $payload $think_setting)
        if not ($tools | is-empty) {
            $payload = ($payload | insert tools $tools)
        }

        # Real-time streaming turn
        mut turn_content = ""
        mut turn_reasoning = ""
        mut in_reasoning = false
        mut reasoning_at_start = true
        mut non_interactive_at_start = true
        mut tool_deltas = []
        mut known_call_ids = []
        mut current_line = ""
        mut stream_lines = []

        mut curl_args = [-s -N --no-buffer $chat_url -H "Content-Type: application/json"]
        if ($model_info.auth_header? | default null) != null {
            $curl_args = ($curl_args | append [-H $"Authorization: ($model_info.auth_header)"])
        }
        $curl_args = ($curl_args | append [-d ($payload | to json -r)])

        for line in (^curl ...$curl_args | lines) {
            let tr = ($line | str trim)
            if ($tr | is-empty) { continue }
            $stream_lines = ($stream_lines | append $tr)

            if not ($line | str starts-with "data: {") {
                continue
            }
            let chunk = (try { $line | str substring 6.. | from json } catch { null })
            if $chunk == null { continue }

            if ($chunk.timings? | default null) != null {
                $turn_timings = $chunk.timings
            }
            if ($chunk.usage? | default null) != null {
                $turn_usage = $chunk.usage
            }

            let delta = ($chunk.choices?.0?.delta? | default {})

            # Reasoning tokens
            let r_tok = ($delta.reasoning_content? | default "")
            if not ($r_tok | is-empty) {
                if not $in_reasoning {
                    $in_reasoning = true
                    tty_report "\n"
                    $reasoning_at_start = true
                }
                $turn_reasoning = ($turn_reasoning + $r_tok)
                let think_prefix_char = ($root_conf.thinking_prefix? | default "│ ")
                let think_pfx = $"((ansi dark_gray))($think_prefix_char)"
                let think_col = (ansi dark_gray)
                let formatted = (format_stream_token $r_tok $indent $reasoning_at_start $think_pfx $think_col)
                $reasoning_at_start = $formatted.at_start
                tty_report $formatted.text
            }

            let c_tok = ($delta.content? | default "")
            let tc = ($delta.tool_calls? | default [])

            # Close reasoning when transitioning to content or tools
            if $in_reasoning and ((not ($c_tok | is-empty)) or (not ($tc | is-empty))) {
                $in_reasoning = false
                tty_report $"(ansi reset)\n\n"
            }

            # Content tokens (stream directly with proper indent and terminal wrapping)
            if not ($c_tok | is-empty) {
                $turn_content = ($turn_content + $c_tok)
                let formatted = (format_stream_token $c_tok $indent $non_interactive_at_start)
                $non_interactive_at_start = $formatted.at_start
                tty_report $formatted.text
            }

            # Tool call deltas
            if not ($tc | is-empty) {
                for it in $tc {
                    mut call_idx = 0
                    if ($it.index? | default null) != null {
                        $call_idx = ($it.index | into int)
                    } else if ($it.id? | default null) != null and ($it.id | is-not-empty) {
                        let cur_id = $it.id
                        let existing_idx = ($known_call_ids | enumerate | where { |r| $r.item == $cur_id } | get -o index | first)
                        if $existing_idx != null {
                            $call_idx = $existing_idx
                        } else {
                            $call_idx = ($known_call_ids | length)
                            $known_call_ids = ($known_call_ids | append $it.id)
                        }
                    } else if not ($known_call_ids | is-empty) {
                        $call_idx = (($known_call_ids | length) - 1)
                    }

                    $tool_deltas = ($tool_deltas | append ($it | upsert index $call_idx))
                }
            }
        }

        if $in_reasoning {
            $in_reasoning = false
            tty_report $"(ansi reset)\n\n"
        }

        if $is_interactive and not ($current_line | is-empty) {
            tty_report "\n"
        }

        # Check for API error if nothing was received
        if ($turn_content | is-empty) and ($turn_reasoning | is-empty) and ($tool_deltas | is-empty) and (not ($stream_lines | is-empty)) {
            let err_raw = ($stream_lines | str join "\n")
            print -e $"\n(ansi red_bold)[Ken Error](ansi reset) Request to ($chat_url) failed:\n($err_raw)"
            return
        }

        # Turn metrics and telemetry
        let turn_dur = ((date now) - $t_turn_start)
        let total_elapsed = ((date now) - $t_run_start)
        let time_now_str = (date now | format date "%H:%M:%S")

        let cache_n = (if ($turn_timings.cache_n? | default null) != null {
            $turn_timings.cache_n
        } else if ($turn_usage.prompt_tokens_details?.cached_tokens? | default null) != null {
            $turn_usage.prompt_tokens_details.cached_tokens
        } else if ($turn_usage.prompt_cache_hit_tokens? | default null) != null {
            $turn_usage.prompt_cache_hit_tokens
        } else {
            0
        })
        let prompt_n = ($turn_timings.prompt_n? | default ($turn_usage.prompt_tokens? | default 0))
        let pred_n = ($turn_timings.predicted_n? | default ($turn_usage.completion_tokens? | default 0))
        let ttft_ms = ($turn_timings.prompt_ms? | default 0 | math round)
        let gen_tps = ($turn_timings.predicted_per_second? | default 0 | into float | math round -p 1)
        let pp_tps = if $ttft_ms > 0 and $prompt_n > 0 {
            ($prompt_n * 1000.0 / $ttft_ms | math round -p 1)
        } else {
            0.0
        }

        $total_prompt_tokens = ($total_prompt_tokens + $prompt_n)
        $total_pred_tokens = ($total_pred_tokens + $pred_n)
        $total_cached_tokens = ($total_cached_tokens + $cache_n)

        # Cost calculation & metrics recording
        let currency = ($root_conf.currency? | default "$")
        let cost_res = (calculate_cost $model_info.pricing $prompt_n $pred_n $cache_n $currency)
        record_metric {
            source: $"($agent_name)"
            model: $model_alias
            turn: ($turn + 1)
            prompt_tokens: $prompt_n
            completion_tokens: $pred_n
            cached_tokens: $cache_n
            cost: $cost_res.amount
            currency: $currency
        }
        let cum_cost = (get_cumulative_cost $currency)
        let cost_str = (format_cost_label $cost_res $cum_cost)

        if ($turn_timings != null or $turn_usage != null) {
            mut banner_parts = [$"($model_alias):($turn + 1)"]
            let ctx_info = (if $cache_n > 0 {
                $"($prompt_n)+($pred_n) \(($cache_n)c\)"
            } else {
                $"($prompt_n)+($pred_n)"
            })
            $banner_parts = ($banner_parts | append $ctx_info)
            if $ttft_ms > 0 {
                let ttft_str = (format_ms $ttft_ms)
                let ttft_with_pp = if $pp_tps > 0 {
                    $"($ttft_str) \(($pp_tps) pp t/s\)"
                } else {
                    $ttft_str
                }
                $banner_parts = ($banner_parts | append $ttft_with_pp)
            }
            if $gen_tps > 0 {
                $banner_parts = ($banner_parts | append $"($gen_tps) t/s")
            }
            $banner_parts = ($banner_parts | append $"((format_duration $turn_dur)) @ ($time_now_str)")

            let cum_tokens = ($total_prompt_tokens + $total_pred_tokens)
            $banner_parts = ($banner_parts | append $"tot: ($cum_tokens)t, ((format_duration $total_elapsed))")
            $banner_parts = ($banner_parts | append $cost_str)

            let inner = ($banner_parts | str join " | ")
            tty_report $"\n($indent)] ($agent_name).($model_alias) | (ansi d)($inner)(ansi reset)\n"
        }

        # Check for tool calls
        if not ($tool_deltas | is-empty) {
            # Reconstruct tool calls
            let tool_calls = ($tool_deltas | group-by index | values | each { |d|
                let id = ($d | get -o id | compact | first | default "call_0")
                let name = ($d | get -o function.name | compact | str join "")
                let args_str = ($d | get -o function.arguments | compact | str join "")
                let extra = ($d | get -o extra_content | compact | first | default null)
                mut tc_obj = {
                    id: $id
                    type: "function"
                    function: {
                        name: $name
                        arguments: $args_str
                    }
                }
                if $extra != null {
                    $tc_obj = ($tc_obj | insert extra_content $extra)
                }
                $tc_obj
            })

            $messages = ($messages | append {
                role: "assistant"
                content: (if not ($turn_content | is-empty) { $turn_content } else { null })
                tool_calls: $tool_calls
            })

            for tc in $tool_calls {
                let tool_res = (execute_tool $agent_dir $tc.function.name $tc.function.arguments)
                $messages = ($messages | append {
                    role: "tool"
                    tool_call_id: $tc.id
                    name: $tc.function.name
                    content: ($tool_res | into string)
                })
            }
            # Continue to next turn with tool results
            continue
        }

        # Final assistant text turn
        let effective_content = if not ($turn_content | is-empty) {
            $turn_content
        } else if not ($turn_reasoning | is-empty) {
            $turn_reasoning
        } else {
            ""
        }

        $messages = ($messages | append {
            role: "assistant"
            content: $effective_content
        })

        # Save snapshot if it was not restored (missing or updated) - local only
        if $model_info.is_local and (not $snapshot_restored) {
            let slots_url = (get_local_url "slots" $root_conf)
            try {
                http post --content-type "application/json" $"($slots_url)/($assigned_slot)?action=save" ({ model: $model_id, filename: $snap_filename } | to json -r)
            }
            $snapshot_restored = true
        }

        # Save session history
        if $session_id != null {
            try {
                {
                    agent: $agent_name
                    session_id: $session_id
                    updated_at: (date now | format date "%Y-%m-%d %H:%M:%S")
                    messages: $messages
                } | to json -r | save -f $session_file
            }
        }

        # Finished turn
        $final_response = $effective_content
        break
    }

    if not (is-terminal --stdout) {
        print -n $final_response
    }

    # Final grand-total session banner across all turns, child agents, and ken raw calls
    if $is_top_level and not ($metrics_file | is-empty) and ($metrics_file | path exists) {
        let metric_rows = (try { open --raw $metrics_file | lines | where ($it | is-not-empty) | each { from json } } catch { [] })
        if not ($metric_rows | is-empty) {
            let total_p = ($metric_rows | get prompt_tokens | math sum)
            let total_c = ($metric_rows | get completion_tokens | math sum)
            let total_cost = ($metric_rows | each { |r| ($r.cost? | default ($r.cost_usd? | default 0.0) | into float) } | math sum)
            let total_dur = ((date now) - $t_run_start)
            let time_str = (date now | format date "%H:%M:%S")
            let currency = ($root_conf.currency? | default "$")

            mut summary_parts = [$"($agent_name).($model_alias)"]
            $summary_parts = ($summary_parts | append $"($total_p + $total_c)t \(($total_p)in, ($total_c)out\)")
            $summary_parts = ($summary_parts | append $"((format_duration $total_dur)) @ ($time_str)")
            if $total_cost > 0.0 {
                let c_str = (format_cost $total_cost $currency)
                $summary_parts = ($summary_parts | append $"tot: ($c_str)")
            } else {
                $summary_parts = ($summary_parts | append $"tot: (format_cost 0.0 $currency)")
            }

            let inner = ($summary_parts | str join " | ")
            let summary_line = $"=== ($inner) ==="
            if (is-terminal --stdout) and (not $no_md) {
                tty_report $"\n(ansi green_bold)($summary_line)(ansi reset)\n"
            }
        }
    }
}

# Subcommand: tok (Count tokens)
def "main tok" [
    ...patterns: string
    --model (-m): string = ""
    --json
] {
    let root_conf = (load_root_config)
    let target_model = (if not ($model | is-empty) { $model } else { $root_conf.default_model })
    let model_ctx = (get_model_ctx $target_model)
    let has_stdin = (not (is-terminal --stdin))
    let piped_input = (if $has_stdin { try { open --raw /dev/stdin } catch { "" } } else { "" })

    if not ($piped_input | is-empty) {
        let content = $piped_input
        let tok_url = (get_local_url "tokenize" $root_conf)
        let res = (try {
            http post --content-type "application/json" $tok_url ({ model: $target_model, content: $content } | to json -r)
        } catch { { tokens: [] } })
        let n_tokens = ($res.tokens | length)
        let n_bytes = ($content | str length)
        if $json {
            { source: "stdin", model: $target_model, bytes: $n_bytes, tokens: $n_tokens } | to json
        } else {
            let pct = (($n_tokens / $model_ctx) * 100 | math round -p 1)
            let sz = ($n_bytes | into filesize)
            print $"Tokens: ($n_tokens) | Size: ($sz) | ($pct)% of ($model_ctx) ctx \(($target_model)\)"
        }
        return
    }

    if ($patterns | is-empty) {
        print "Usage: cat file | ken tok"
        print "       ken tok [patterns...] [--model <name>] [--json]"
        return
    }

    mut matched_files = []
    for pat in $patterns {
        let expanded = ($pat | path expand)
        let hits = (glob $expanded)
        if not ($hits | is-empty) {
            $matched_files = ($matched_files | append $hits)
        } else if ($expanded | path exists) {
            $matched_files = ($matched_files | append $expanded)
        }
    }

    let unique_files = ($matched_files | uniq | where ($it | path type) == "file" | sort)
    if ($unique_files | is-empty) {
        print "No matching files found."
        return
    }

    mut results = []
    mut total_tokens = 0
    mut total_bytes = 0

    let tok_url = (get_local_url "tokenize" $root_conf)
    for f in $unique_files {
        let text = (try { open --raw $f } catch { "" })
        let bytes_n = ($text | str length)
        let res = (try {
            http post --content-type "application/json" $tok_url ({ model: $target_model, content: $text } | to json -r)
        } catch { { tokens: [] } })
        let tokens_n = ($res.tokens | length)

        $total_tokens = ($total_tokens + $tokens_n)
        $total_bytes = ($total_bytes + $bytes_n)

        let home = $env.HOME
        let disp = ($f | str replace $home "~")
        $results = ($results | append {
            file: $disp
            size: ($bytes_n | into filesize)
            tokens: $tokens_n
        })
    }

    if $json {
        {
            model: $target_model
            total_files: ($results | length)
            total_bytes: $total_bytes
            total_tokens: $total_tokens
            ctx_size: $model_ctx
            ctx_percent: (($total_tokens / $model_ctx) * 100 | math round -p 1)
            files: $results
        } | to json
        return
    }

    # Print table
    print ($results | table -e)
    let pct = (($total_tokens / $model_ctx) * 100 | math round -p 1)
    let total_sz = ($total_bytes | into filesize)
    print ("------------------------------------------------------------")
    print ("Total: " + ($results | length | into string) + " files | " + ($total_sz | into string) + " | " + ($total_tokens | into string) + " tokens (" + ($pct | into string) + "% of " + ($model_ctx | into string) + " ctx [" + $target_model + "])")
}

# Subcommand: list (List agents, models, and providers)
def "main list" [] {
    let root = (get_ken_root)
    let root_conf = (load_root_config)
    let currency = ($root_conf.currency? | default "$")

    print $"Ken Providers & Models:\n"
    let providers = ($root_conf.providers? | default {})
    for p_name in ($providers | columns) {
        let p_data = ($providers | get $p_name)
        let p_models = ($p_data.models? | default {})
        print $"  \e[1;35m($p_name)\e[0m \(($p_data.base_url)\):"
        for m_alias in ($p_models | columns) {
            let m = ($p_models | get $m_alias)
            let m_name = ($m.name? | default $m_alias)
            let m_desc = ($m.description? | default "")
            let m_ctx = ($m.ctx? | default $root_conf.default_ctx)
            let p_in = ($m.pricing?.input? | default 0.0 | into float)
            let p_out = ($m.pricing?.output? | default 0.0 | into float)
            let pricing_str = (if $p_in == 0.0 and $p_out == 0.0 {
                "free"
            } else {
                $"in: (format_cost $p_in $currency)/1M, out: (format_cost $p_out $currency)/1M"
            })
            print $"    - \e[1;32m($m_alias)\e[0m -> ($m_name) [($m_ctx) ctx] \(($pricing_str)\) - ($m_desc)"
        }
    }

    let agents = (ls $root | where type == dir and (not ($it.name | path basename | str starts-with ".")) and ($it.name | path basename) != "bin" | sort-by name)
    print $"\nAvailable Ken Agents [default: ($root_conf.default_model)]:\n"
    for a in $agents {
        let a_name = ($a.name | path basename)
        let a_conf = (load_agent_config $a.name $root_conf)
        let agent_tools = (try { get_agent_tools $a.name | get function.name | sort } catch { [] })
        let desc = (if not ($a_conf.description | is-empty) { $" - ($a_conf.description)" } else { "" })
        let def_m = $a_conf.default_model
        print $"  - \e[1;36m($a_name)\e[0m [($def_m)]($desc):"
        if not ($agent_tools | is-empty) {
            print $"      tools: ($agent_tools | str join ', ')"
        } else {
            print "      tools: (none)"
        }
    }
}

# Subcommand: prefill (Warm up and save slot snapshots for agents)
def "main prefill" [
    agent?: string
    --model (-m): string = ""
    --all
] {
    let ken_root = (get_ken_root)
    let root_conf = (load_root_config)
    let all_dirs = (ls $ken_root | where type == dir and (not ($it.name | path basename | str starts-with ".")) and ($it.name | path basename) != "bin" | get name | sort)

    let target_dirs = (if not ($agent | is-empty) and not $all {
        let specific = (resolve_agent_dir $agent)
        if ($specific | path exists) { [$specific] } else { [] }
    } else {
        $all_dirs
    })

    if ($target_dirs | is-empty) {
        print -e $"No matching agents found to prefill."
        return
    }

    print $"Prefilling and saving snapshots for ($target_dirs | length) agents..."
    for adir in $target_dirs {
        let a_name = ($adir | path basename)
        let a_conf = (load_agent_config $adir $root_conf)
        let target_model = (if not ($model | is-empty) { $model } else { $a_conf.default_model })
        let model_info = (resolve_model_info $target_model $root_conf)
        if not $model_info.is_local {
            print $"Prefilling ($a_name) [($target_model)]... \e[33m[skip - cloud model]\e[0m"
            continue
        }
        let tools = (get_agent_tools $adir)
        let prompt = $a_conf.system_prompt
        let snap_filename = $"($a_name)_($target_model).bin"

        print -n $"Prefilling ($a_name) [($target_model)]... "
        mut payload = {
            model: $model_info.model_name
            messages: [
                { role: "system", content: $prompt }
                { role: "user", content: " " }
            ]
            max_tokens: 1
            id_slot: 0
            cache_prompt: true
        }
        if not ($tools | is-empty) {
            $payload = ($payload | insert tools $tools)
        }

        let chat_url = (get_local_url "chat" $root_conf)
        let slots_url = (get_local_url "slots" $root_conf)

        let run_res = (try {
            http post --content-type "application/json" --max-time 60sec $chat_url ($payload | to json -r)
        } catch { |e| null })

        if $run_res == null {
            print $"\e[31m[failed]\e[0m"
            continue
        }

        let save_res = (try {
            http post --content-type "application/json" $"($slots_url)/0?action=save" ({ model: $target_model, filename: $snap_filename } | to json -r)
        } catch { |e| null })

        if $save_res != null and ($save_res.timings?.save_ms? != null) {
            let ms = ($save_res.timings.save_ms | math round -p 1)
            let n_tokens = ($save_res.n_saved? | default 0)
            print $"\e[32m[ok]\e[0m saved ($n_tokens) tokens in ($ms)ms -> ($snap_filename)"
        } else {
            print $"\e[31m[failed to save snapshot]\e[0m"
        }
    }
}

# Subcommand: raw (Direct completion against any configured model without tools or session overhead)
def "main raw" [
    prompt?: string              # Prompt text (or pipe via stdin)
    --model (-m): string = ""    # Model alias (defaults to default_model in config)
    --system (-s): string = ""   # Optional system instructions
    --max-tokens: int = 1024     # Max output tokens
    --temp: float = 0.1          # Sampling temperature
    --think (-t): string = ""    # Reasoning control: off, low, medium, high, on
] {
    let has_stdin = (not (is-terminal --stdin))
    let piped_input = (if $has_stdin { try { open --raw /dev/stdin } catch { "" } } else { "" })
    let full_prompt = (if not ($prompt | default "" | is-empty) and not ($piped_input | is-empty) {
        $"($prompt)\n\n($piped_input)"
    } else if not ($prompt | default "" | is-empty) {
        $prompt
    } else {
        $piped_input
    })

    if ($full_prompt | is-empty) {
        print -e "Error: No prompt provided for raw completion."
        return
    }

    load_ken_env
    let root_conf = (load_root_config)
    let target_m = if not ($model | is-empty) { $model } else { $root_conf.default_model }
    let model_info = (resolve_model_info $target_m $root_conf)
    let chat_url = $"($model_info.base_url)/chat/completions"

    let think_setting = (if not ($think | is-empty) {
        $think
    } else if ($model_info.thinking? | default null) != null {
        $model_info.thinking
    } else if ($model_info.reasoning_effort? | default null) != null {
        $model_info.reasoning_effort
    } else {
        ""
    })

    # Setup metrics tracking if not inherited
    let metrics_dir = (get_metrics_dir)
    let metrics_file = if ($env.KEN_METRICS_FILE? | default "" | is-empty) {
        let now_ts = (date now | format date "%Y%m%d_%H%M%S")
        let f = ($metrics_dir | path join $"run_($now_ts)_($nu.pid).jsonl")
        "" | save -f $f
        $f
    } else {
        $env.KEN_METRICS_FILE
    }
    load-env { KEN_METRICS_FILE: $metrics_file }

    mut messages = []
    if not ($system | is-empty) {
        $messages = ($messages | append { role: "system", content: $system })
    }
    $messages = ($messages | append { role: "user", content: $full_prompt })

    mut payload = {
        model: $model_info.model_name
        messages: $messages
        temperature: $temp
        max_tokens: $max_tokens
        stream: true
        stream_options: { include_usage: true }
    }
    if $model_info.is_local {
        $payload = ($payload | insert timings_per_token true | insert cache_prompt true)
    }
    $payload = (apply_thinking_payload $payload $think_setting)

    let depth = (try { $env.KEN_DEPTH | into int } catch { 0 })
    let indent = ("" | fill -c " " -w ($depth * 2))
    let t_start = (date now)
    let time_start_str = ($t_start | format date "%H:%M:%S")

    tty_report $"\n($indent)[ raw.($model) @ ($time_start_str)\n"

    mut curl_args = [-s -N --no-buffer $chat_url -H "Content-Type: application/json"]
    if ($model_info.auth_header? | default "" | is-not-empty) {
        $curl_args = ($curl_args | append [-H $"Authorization: ($model_info.auth_header)"])
    }
    $curl_args = ($curl_args | append [-d ($payload | to json -r)])

    mut full_content = ""
    mut full_reasoning = ""
    mut in_reasoning = false
    mut at_line_start = true
    mut raw_timings: any = null
    mut raw_usage: any = null
    mut stream_lines = []

    for line in (^curl ...$curl_args | lines) {
        let tr = ($line | str trim)
        if ($tr | is-empty) { continue }
        $stream_lines = ($stream_lines | append $tr)

        if not ($line | str starts-with "data: {") {
            continue
        }
        let chunk = (try { $line | str substring 6.. | from json } catch { null })
        if $chunk == null { continue }

        if ($chunk.timings? | default null) != null {
            $raw_timings = $chunk.timings
        }
        if ($chunk.usage? | default null) != null {
            $raw_usage = $chunk.usage
        }

        let delta = ($chunk.choices?.0?.delta? | default {})

        let r_tok = ($delta.reasoning_content? | default "")
        if not ($r_tok | is-empty) {
            if not $in_reasoning {
                $in_reasoning = true
                tty_report "\n"
                $at_line_start = true
            }
            $full_reasoning = ($full_reasoning + $r_tok)
            let think_prefix_char = ($root_conf.thinking_prefix? | default "│ ")
            let think_pfx = $"((ansi dark_gray))($think_prefix_char)"
            let think_col = (ansi dark_gray)
            let formatted = (format_stream_token $r_tok $indent $at_line_start $think_pfx $think_col)
            $at_line_start = $formatted.at_start
            tty_report $formatted.text
        }

        let c_tok = ($delta.content? | default "")
        if not ($c_tok | is-empty) {
            if $in_reasoning {
                $in_reasoning = false
                tty_report $"(ansi reset)\n\n"
                $at_line_start = true
            }
            $full_content = ($full_content + $c_tok)
            let formatted = (format_stream_token $c_tok $indent $at_line_start)
            $at_line_start = $formatted.at_start
            tty_report $formatted.text
        }
    }

    if $in_reasoning {
        $in_reasoning = false
        tty_report $"(ansi reset)\n\n"
    }

    if not ($full_content | str ends-with "\n") {
        tty_report "\n"
    }

    let t_dur = ((date now) - $t_start)
    let time_now = (date now | format date "%H:%M:%S")

    # If stream failed, print error to stderr
    if ($full_content | is-empty) and ($full_reasoning | is-empty) and (not ($stream_lines | is-empty)) {
        let err_raw = ($stream_lines | str join "\n")
        print -e $"\n(ansi red_bold)[Ken Raw Error](ansi reset) Request to ($chat_url) failed:\n($err_raw)"
        return
    }

    let prompt_n = ($raw_timings.prompt_n? | default ($raw_usage.prompt_tokens? | default 0))
    let pred_n = ($raw_timings.predicted_n? | default ($raw_usage.completion_tokens? | default (count_text_tokens $full_content)))
    let cache_n = ($raw_timings.cache_n? | default ($raw_usage.prompt_tokens_details?.cached_tokens? | default 0))
    let ttft_ms = ($raw_timings.prompt_ms? | default 0 | math round)
    let gen_tps = ($raw_timings.predicted_per_second? | default 0 | into float | math round -p 1)
    let pp_tps = if $ttft_ms > 0 and $prompt_n > 0 {
        ($prompt_n * 1000.0 / $ttft_ms | math round -p 1)
    } else {
        0.0
    }
    let n_lines = ($full_content | lines | length)

    let currency = ($root_conf.currency? | default "$")
    let cost_res = (calculate_cost $model_info.pricing $prompt_n $pred_n $cache_n $currency)

    record_metric {
        source: "raw"
        model: $model
        turn: 1
        prompt_tokens: $prompt_n
        completion_tokens: $pred_n
        cached_tokens: $cache_n
        cost: $cost_res.amount
        currency: $currency
    }

    let cum_cost = (get_cumulative_cost $currency)
    let cost_str = (format_cost_label $cost_res $cum_cost)

    let ctx_str = if $cache_n > 0 {
        $"($prompt_n)+($pred_n) \(($cache_n)c\)"
    } else {
        $"($prompt_n)+($pred_n)"
    }
    mut raw_parts = [$ctx_str]
    if $ttft_ms > 0 {
        let ttft_str = (format_ms $ttft_ms)
        let ttft_with_pp = if $pp_tps > 0 {
            $"($ttft_str) \(($pp_tps) pp t/s\)"
        } else {
            $ttft_str
        }
        $raw_parts = ($raw_parts | append $ttft_with_pp)
    }
    let speed_and_out = if $gen_tps > 0 {
        $"($gen_tps) t/s -> ($n_lines)L ($pred_n)t \(((format_duration $t_dur)) @ ($time_now)\)"
    } else {
        $"-> ($n_lines)L ($pred_n)t \(((format_duration $t_dur)) @ ($time_now)\)"
    }
    $raw_parts = ($raw_parts | append $speed_and_out)
    $raw_parts = ($raw_parts | append $cost_str)

    let raw_line = ($raw_parts | str join " | ")
    tty_report $"\n($indent)] raw.($model) | (ansi d)($raw_line)(ansi reset)\n"

    if not (is-terminal --stdout) {
        print -n $full_content
    }
}

# Subcommand: schema (Dump OpenAI tool schema for an agent)
def "main schema" [agent?: string] {
    let root_conf = (load_root_config)
    let target = if ($agent | default "" | is-not-empty) { $agent } else { $root_conf.default_agent }
    let agent_dir = (resolve_agent_dir $target)
    let tools = (get_agent_tools $agent_dir)
    $tools | to json
}

# Subcommand: call_agent (Delegate task to a specialized domain agent)
def "main call_agent" [
    --agent (-a): string          # Target agent (e.g. coder, task, plan, fs, sys, mail)
    --task (-t): string           # The specific prompt or task for the agent
    --model (-m): string = ""     # Optional model override
] {
    do_call_agent $agent $task $model
}

def "main call-agent" [
    --agent (-a): string
    --task (-t): string
    --model (-m): string = ""
] {
    do_call_agent $agent $task $model
}

# Subcommand: session (Manage persistent chat sessions)
def "main session" [
    action: string = "list"
    target: string = "all"
] {
    let s_dir = (get_session_dir)
    match $action {
        "list" => {
            let files = (ls ($s_dir | path join "*.json") | default [])
            if ($files | is-empty) {
                print "No active sessions found."
                return
            }
            print "Active Sessions:"
            for f in $files {
                let data = (try { open $f.name } catch { null })
                let count = ($data.messages? | default [] | length)
                let updated = ($data.updated_at? | default "unknown")
                let stem = ($f.name | path parse | get stem)
                print $"- ($stem): ($count) messages | last: ($updated)"
            }
        }
        "clear" | "rm" => {
            if $target == "all" {
                rm -f ($s_dir | path join "*.json")
                print "All sessions cleared."
            } else {
                rm -f ($s_dir | path join $"*($target)*.json")
                print $"Cleared session: ($target)"
            }
        }
        "show" => {
            let match_f = (glob ($s_dir | path join $"*($target)*.json") | first)
            if $match_f != null {
                open $match_f | to json
            } else {
                print $"Session '($target)' not found."
            }
        }
        _ => {
            print "Usage: ken session [list|clear|show] [id]"
        }
    }
}

# Subcommand: setup (Generate shell configuration snippet)
def "main setup" [
    shell_name?: string
    config_dir?: string
] {
    let sh = (if not ($shell_name | is-empty) {
        $shell_name | path basename
    } else if not ($env.SHELL? | default "" | is-empty) {
        $env.SHELL | path basename
    } else {
        "zsh"
    })
    
    let default_cfg = (if not ($env.XDG_CONFIG_HOME? | default "" | is-empty) {
        $env.XDG_CONFIG_HOME | path join "ken"
    } else {
        $env.HOME | path join ".config" "ken"
    })
    let target_dir = (if not ($config_dir | is-empty) {
        $config_dir | path expand
    } else {
        $default_cfg
    })

    match $sh {
        "zsh" => {
            let zsh_lines = [
                '# Ken shell integration for zsh'
                $"export KEN_DIR=\"($target_dir)\""
                $"export KEN_ROOT=\"($target_dir)\""
                ''
                'if [[ -n "$ZSH_VERSION" ]]; then'
                '    _ken_execute_widget() {'
                '        local input_text="$BUFFER"'
                '        if [[ -z "${input_text//[[:space:]]/}" ]]; then'
                "            printf '\\a'"
                '            return'
                '        fi'
                ''
                "        # 1. Starts with '#' -> Generate command"
                "        if [[ \"$input_text\" =~ '^[[:space:]]*#' ]]; then"
                '            local prompt="${input_text#*#}"'
                '            zle -I'
                '            local gen_cmd'
                '            gen_cmd=$(ken cmd.q "GENERATE: $prompt" 2>/dev/null)'
                '            if [[ -n "$gen_cmd" ]]; then'
                '                BUFFER="$gen_cmd"'
                '                CURSOR=${#BUFFER}'
                '            else'
                "                printf '\\a'"
                '            fi'
                '            zle reset-prompt'
                ''
                "        # 2. Contains '#' inside -> Modify base command with instruction"
                '        elif [[ "$input_text" == *#* ]]; then'
                '            local base_cmd="${input_text%%#*}"'
                '            local instruction="${input_text#*#}"'
                '            zle -I'
                '            local gen_cmd'
                '            gen_cmd=$(ken cmd.q "MODIFY: Base command: '\''${base_cmd%% }'\'' | Instruction: '\''${instruction## }'\''" 2>/dev/null)'
                '            if [[ -n "$gen_cmd" ]]; then'
                '                BUFFER="$gen_cmd"'
                '                CURSOR=${#BUFFER}'
                '            else'
                "                printf '\\a'"
                '            fi'
                '            zle reset-prompt'
                ''
                "        # 3. Ends with ';' -> Explain command in detail"
                "        elif [[ \"$input_text\" =~ ';[[:space:]]*$' ]]; then"
                '            zle -I'
                '            ken cmd.q "EXPLAIN: $input_text"'
                '            zle reset-prompt'
                ''
                '        # 4. Neither format matches -> Bell / do nothing'
                '        else'
                "            printf '\\a'"
                '        fi'
                '    }'
                '    zle -N _ken_execute_widget'
                "    bindkey '^[e' _ken_execute_widget"
                'fi'
            ]
            print ($zsh_lines | str join (char nl))
        }
        "bash" => {
            print $"# Ken shell integration for bash
export KEN_DIR=\"($target_dir)\"
export KEN_ROOT=\"($target_dir)\"
"
        }
        "fish" => {
            print $"# Ken shell integration for fish
set -gx KEN_DIR \"($target_dir)\"
set -gx KEN_ROOT \"($target_dir)\"
"
        }
        "nu" => {
            print $"# Ken shell integration for nushell
$env.KEN_DIR = \"($target_dir)\"
$env.KEN_ROOT = \"($target_dir)\"
"
        }
        _ => {
            print $"export KEN_DIR=\"($target_dir)\"
export KEN_ROOT=\"($target_dir)\"
"
        }
    }
}

# Default main entrypoint
def main [
    spec?: string
    query?: string
    --image (-i): string = ""
    --slot: int = -1
    --think (-t): string = ""
    --no-md
] {
    let has_stdin = (not (is-terminal --stdin))
    let piped_input = (if $has_stdin { try { open --raw /dev/stdin } catch { "" } } else { "" })
    if $spec == null or $spec in ["-h" "--help"] {
        print "Usage: ken [session][agent.]<model> [query] [options]"
        print "       ken <subcommand>"
        print "\nSubcommands:"
        print "  ken setup [shell] [dir]   Emit shell integration snippet"
        print "  ken list                  List agents, default models, and tools"
        print "  ken prefill [agent]       Pre-evaluate & save prompt snapshots"
        print "  ken tok [patterns...]     Count tokens via llama.cpp"
        print "  ken schema [agent]        Dump OpenAI tools schema"
        print "  ken session [list|clear]  Manage persistent sessions"
        print "\nOptions:"
        print "  -t, --think <level>       Reasoning control: off, low, medium, high, on"
        print "  -i, --image <path>        Pass image for multimodal models"
        print "      --slot <id>           Force llama-server KV slot ID"
        print "      --no-md               Disable telemetry header/footer banners"
        print "\nExamples:"
        print "  ken 1qwent 'Solve step by step'"
        print "  ken -t off q 'Give me 3 bullet points'"
        print "  ken notes.lfm 'What is a PCB?'"
        print "  ken tok '~/Documents/notes/**/*.typ'"
        print "  . <(ken setup $SHELL ~/.config/ken)"
        return
    }

    # Handle piped stdin if query is empty
    let full_query = (if not ($query | is-empty) and not ($piped_input | is-empty) {
        $"($query)\n\n($piped_input)"
    } else if not ($query | is-empty) {
        $query
    } else {
        $piped_input
    })

    if ($full_query | is-empty) {
        print -e "Error: No query provided. Pass as argument or pipe via stdin."
        return
    }

    run_agent $spec $full_query $image $slot $no_md $think
}
