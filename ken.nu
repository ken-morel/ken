#!/usr/bin/env nu
# Ken - Local Agentic Assistant in pure Nushell

const LLAMA_URL = "http://127.0.0.1:6172/v1/chat/completions"
const TOKENIZE_URL = "http://127.0.0.1:6172/tokenize"
const SLOTS_URL = "http://127.0.0.1:6172/slots"
const DEFAULT_MODEL = "q"
const DEFAULT_CTX = 16384

def get_ken_root [] {
    if not ($env.KEN_ROOT? | default "" | is-empty) and ($env.KEN_ROOT | path exists) {
        return $env.KEN_ROOT
    }
    let home_ken = ($env.HOME | path join "ken")
    if ($home_ken | path exists) {
        return $home_ken
    }
    $env.FILE_PWD? | default ($env.HOME | path join "ken")
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

def calculate_cost [pricing: record, prompt_tokens: int, completion_tokens: int, cached_tokens: int, rate_to_cfa: float = 584.0] {
    let in_price = ($pricing.input? | default 0.0 | into float)
    let out_price = ($pricing.output? | default 0.0 | into float)
    let cache_price = ($pricing.cache_hit? | default 0.0 | into float)

    let uncached_prompt = (if $prompt_tokens >= $cached_tokens { $prompt_tokens - $cached_tokens } else { $prompt_tokens })
    let cost_usd = (($uncached_prompt / 1000000.0) * $in_price) + (($completion_tokens / 1000000.0) * $out_price) + (($cached_tokens / 1000000.0) * $cache_price)
    let cost_cfa = ($cost_usd * $rate_to_cfa)

    let usd_str = (if $cost_usd < 0.0001 and $cost_usd > 0.0 {
        $"$($cost_usd | math round -p 6)"
    } else {
        $"$($cost_usd | math round -p 4)"
    })
    let cfa_str = $"($cost_cfa | math round -p 2) CFA"

    {
        usd: $cost_usd
        cfa: $cost_cfa
        label: $"($usd_str) \(($cfa_str)\)"
        is_free: ($in_price == 0.0 and $out_price == 0.0)
    }
}

def get_known_models [] {
    let from_api = (try {
        http get --max-time 1sec "http://127.0.0.1:6172/v1/models" | get data.id
    } catch { [] })
    if not ($from_api | is-empty) {
        return $from_api
    }

    let ini_path = ($env.HOME | path join "models" "models.ini")
    if ($ini_path | path exists) {
        return (open $ini_path | lines | where ($it | str starts-with "[") and ($it != "[*]") | each { str replace "[" "" | str replace "]" "" | str trim })
    }

    [$DEFAULT_MODEL]
}

def get_model_ctx [model: string] {
    let models_res = (try { http get --max-time 1sec "http://127.0.0.1:6172/v1/models" } catch { null })
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
    $DEFAULT_CTX
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

def get_slots_dir [model: string = $DEFAULT_MODEL] {
    let d = ($env.HOME | path join ".cache" $"($model)-server" "slots")
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
        default_model: $DEFAULT_MODEL
        default_ctx: $DEFAULT_CTX
        options: {}
        models: {}
    }
    if ($conf_path | path exists) {
        let loaded = (try { open $conf_path } catch { {} })
        $root_conf = ($root_conf | merge ($loaded | default {}))
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
        options: $base_conf.options
        models: $base_conf.models
        system_prompt: ""
    }

    if ($conf_path | path exists) {
        let loaded = (try { open $conf_path } catch { {} })
        if ($loaded.name? | default "" | is-not-empty) { $agent_conf.name = $loaded.name }
        if ($loaded.description? | default "" | is-not-empty) { $agent_conf.description = $loaded.description }
        if ($loaded.default_model? | default "" | is-not-empty) { $agent_conf.default_model = $loaded.default_model }
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
    if ($raw | is-empty) {
        return { session: null, agent: "orchestrator", model: null, model_explicit: false }
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
    if ($agent_path | path exists) {
        return { session: $session, agent: $rest, model: null, model_explicit: false }
    }

    # 3. Model alias (e.g. q, l, d, dskc, dskr, gf, gp)
    { session: $session, agent: "orchestrator", model: $rest, model_explicit: true }
}

def resolve_agent_dir [agent: string] {
    let root = (get_ken_root)
    if $agent in ["orchestrator" "ken"] {
        let p = ($root | path join "orchestrator")
        if ($p | path exists) { $p } else { ($root | path join "ken") }
    } else {
        $root | path join $agent
    }
}

# Introspect Nushell tools in agent directory and generate OpenAI schemas
def get_agent_tools [agent_dir: string] {
    if not ($agent_dir | path exists) { return [] }
    let nu_files = (glob ($agent_dir | path join "*.nu") | sort)
    
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

        # For call_agent: scope available agents strictly to symlinked *.k in this agent's directory
        # and document each agent and model with clear, unambiguous descriptions
        if $tool_name == "call_agent" {
            let available_k = (glob ($agent_dir | path join "*.k") | sort)
            if ($available_k | is-empty) {
                # If no agents are symlinked to this agent, omit call_agent entirely
                continue
            }

            let available_agents = ($available_k | each { path parse | get stem } | sort)

            # Build detailed documentation for each available agent from its config.nuon
            let agent_docs = ($available_k | each { |k_path|
                let a_name = ($k_path | path parse | get stem)
                let a_dir = (try { $k_path | path expand } catch { "" })
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

            if ($properties | get -o agent) != null {
                let p_agent = ($properties.agent 
                    | insert enum $available_agents 
                    | upsert description $"Target agent to delegate to. Available agents:\n($agent_docs)")
                $properties = ($properties | upsert agent $p_agent)
            }

            # Enumerate and document available models from root config
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

            let cur_m = ($env.KEN_MODEL? | default "caller model")
            if ($properties | get -o model) != null {
                let p_model = ($properties.model
                    | insert enum $model_aliases
                    | upsert description $"Optional model override. Defaults to inheriting caller's model ($cur_m). Available models:\n($model_docs)")
                $properties = ($properties | upsert model $p_model)
            }

            # Both agent and task are required
            $required = ["agent" "task"]
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
    $tools
}

def record_metric [item: record] {
    let f = ($env.KEN_METRICS_FILE? | default "")
    if ($f | is-not-empty) {
        try {
            $"($item | to json -r)\n" | save --append $f
        }
    }
}

def get_cumulative_cost [] {
    let f = ($env.KEN_METRICS_FILE? | default "")
    if ($f | is-not-empty) and ($f | path exists) {
        let rows = (try { open --raw $f | lines | where ($it | is-not-empty) | each { from json } } catch { [] })
        if not ($rows | is-empty) {
            let sum_usd = ($rows | get cost_usd | math sum)
            let sum_cfa = ($rows | get cost_cfa | math sum)
            return { usd: $sum_usd, cfa: $sum_cfa }
        }
    }
    { usd: 0.0, cfa: 0.0 }
}

def format_cost_label [cost_res: record, cum_cost: record] {
    if ($cost_res.usd == 0.0 or $cost_res.is_free) and ($cum_cost.usd == 0.0) {
        return "$0"
    }
    let u_turn = if ($cost_res.usd == 0.0 or $cost_res.is_free) {
        "$0"
    } else if $cost_res.usd < 0.0001 {
        $"$($cost_res.usd | math round -p 6)"
    } else {
        $"$($cost_res.usd | math round -p 4)"
    }

    let u_tot = if $cum_cost.usd == 0.0 {
        "$0"
    } else if $cum_cost.usd < 0.0001 {
        $"$($cum_cost.usd | math round -p 6)"
    } else {
        $"$($cum_cost.usd | math round -p 4)"
    }
    let cfa_tot = $"($cum_cost.cfa | math round -p 1) CFA"
    $"($u_turn) \(tot: ($u_tot) / ($cfa_tot)\)"
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
    let res = (try {
        http post --max-time 150ms --content-type "application/json" "http://127.0.0.1:6172/tokenize" ({ content: $text } | to json -r)
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
    let tool_path = ($agent_dir | path join $"($fn_name).nu")
    if not ($tool_path | path exists) {
        return $"Error: Tool '($fn_name)' not found in ($agent_dir)."
    }
    let args_dict = (try { $args_json | from json } catch { {} })

    let tool_info = (try {
        nu -c $"source '($tool_path)'; scope commands | where name == 'main' | select signatures | to json" | from json | first
    } catch { null })

    let sigs = ($tool_info.signatures?.any? | default [])
    mut pos_args = []
    mut named_args = []

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

    # Format detailed tool command line
    let agent_name = ($agent_dir | path basename)
    let formatted_args = ($args_dict | transpose key val | each { |it|
        $"--($it.key) '($it.val)'"
    } | str join " ")

    let t_start = (date now)
    let time_start_str = ($t_start | format date "%H:%M:%S")
    tty_report $"\n(ansi cyan)[call](ansi reset) ($agent_name)/($fn_name) ($formatted_args) @ ($time_start_str)\n"
    let res = (^nu $tool_path ...$pos_args ...$named_args | complete)
    let t_end = (date now)
    let t_dur = ($t_end - $t_start)
    let time_end_str = ($t_end | format date "%H:%M:%S")

    if $res.exit_code == 0 {
        let output = (if not ($res.stdout | is-empty) { $res.stdout } else { "(Success with no output)" })
        let n_lines = ($output | lines | length)
        let n_tokens = (count_text_tokens $output)
        # Print the entire tool output so the user can inspect intermediate results and context
        tty_report $"($output)\n"
        tty_report $"(ansi green)[done](ansi reset) ($agent_name)/($fn_name) -> ($n_lines)L ($n_tokens)t \((format_duration $t_dur) @ ($time_end_str)\)\n\n"
        $output
    } else {
        tty_report $"(ansi red)[error](ansi reset) ($agent_name)/($fn_name) -> exit ($res.exit_code) \((format_duration $t_dur) @ ($time_end_str)\)\n"
        if not ($res.stderr | is-empty) { tty_report $"($res.stderr)\n" }
        if not ($res.stdout | is-empty) { tty_report $"($res.stdout)\n" }
        tty_report "\n"
        $"Error: ($res.stderr)\n($res.stdout)"
    }
}

def style_line [text: string, lang: string = "markdown"] {
    if ($text | is-empty) { return "" }
    let res = ($text | ^bat --plain --paging=never --color=always -l $lang | complete)
    if $res.exit_code == 0 {
        $res.stdout | str trim -r -c "\n"
    } else {
        $text
    }
}

# Main chat execution loop
def run_agent [
    spec_str: string
    query: string
    image_path: string = ""
    slot_override: int = -1
    no_md: bool = false
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

    # Slot allocation by alphabetical agent index (local only)
    let root = (get_ken_root)
    let all_agents = (ls $root | where type == dir and (not ($it.name | path basename | str starts-with ".")) and ($it.name | path basename) != "bin" | get name | each { path basename } | sort)
    let agent_idx = ($all_agents | enumerate | where item == $agent_name | get 0.index? | default 0)
    let assigned_slot = (if $slot_override >= 0 { $slot_override } else { $agent_idx mod 2 })

    # Slot snapshot check: restore if cached and up-to-date with agent prompt/config (local only)
    let snap_filename = $"($agent_name)_($model_alias).bin"
    mut snapshot_restored = false

    if $model_info.is_local {
        let slots_dir = (get_slots_dir $model_id)
        let snapshot_file = ($slots_dir | path join $snap_filename)
        let snap_exists = ($snapshot_file | path exists)

        if $snap_exists {
            let snap_mtime = (ls $snapshot_file | get 0.modified)
            let agent_mtime = (try { ls $agent_dir | get modified | math max } catch { null })
            if ($agent_mtime == null) or ($snap_mtime >= $agent_mtime) {
                let res = (try {
                    http post --content-type "application/json" $"($SLOTS_URL)/($assigned_slot)?action=restore" ({ model: $model_id, filename: $snap_filename } | to json -r)
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

    # Dynamic date tag at the tail of user message (KV cache preservation)
    let now_str = (date now | format date "%Y-%m-%d %H:%M:%S")
    let user_text = (if not ($query | is-empty) { $"($query)\n\n[Date: ($now_str)]" } else { $"[Date: ($now_str)]" })

    mut user_content: any = $user_text
    if not ($image_path | is-empty) and ($image_path | path exists) {
        let b64 = (open --raw $image_path | encode base64)
        $user_content = [
            { type: "text", text: $user_text }
            { type: "image_url", image_url: { url: $"data:image/jpeg;base64,($b64)" } }
        ]
    }

    $messages = ($messages | append { role: "user", content: $user_content })

    let is_interactive = (is-terminal --stdout) and ($env.TERM? != "dumb") and (not $no_md)
    let t_run_start = (date now)
    let time_start_str = ($t_run_start | format date "%H:%M:%S")

    if (is-terminal --stdout) and (not $no_md) {
        tty_report $"(ansi d)[start] ($agent_name).($model_alias) @ ($time_start_str)(ansi reset)\n"
    }

    mut total_prompt_tokens = 0
    mut total_pred_tokens = 0
    mut total_cached_tokens = 0

    let cur_session = ($session_id | default "default")
    let depth = (try { $env.KEN_DEPTH | into int } catch { 0 })
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
        $payload = ($payload | merge $model_params)
        if not ($tools | is-empty) {
            $payload = ($payload | insert tools $tools)
        }

        # Real-time streaming turn
        mut turn_content = ""
        mut turn_reasoning = ""
        mut tool_deltas = []
        mut current_line = ""
        mut stream_lines = []

        if $is_interactive {
            print -n "\e7" # Save cursor at start of first line
        }

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
                $turn_reasoning = ($turn_reasoning + $r_tok)
                print -n $"(ansi d)($r_tok)(ansi reset)"
            }

            # Content tokens (progressive bat line highlighting with cursor restore)
            let c_tok = ($delta.content? | default "")
            if not ($c_tok | is-empty) {
                $turn_content = ($turn_content + $c_tok)
                if $is_interactive {
                    if ($c_tok | str contains "\n") {
                        let parts = ($c_tok | split row "\n")
                        let p_count = ($parts | length)
                        for idx in 0..($p_count - 1) {
                            let part = ($parts | get $idx)
                            $current_line = ($current_line + $part)
                            if $idx < ($p_count - 1) {
                                # Newline reached: style line with bat, commit newline, save cursor for next line
                                let styled = (style_line $current_line)
                                let term_cols = (try { term size | get columns } catch { 80 })
                                let line_len = ($current_line | str length)
                                let lines_up = (if $term_cols > 0 and $line_len > 0 { ($line_len - 1) // $term_cols } else { 0 })
                                if $lines_up > 0 {
                                    print -n $"\e[($lines_up)A\r\e[0J($styled)\n\e7"
                                } else {
                                    print -n $"\e8\e[0J($styled)\n\e7"
                                }
                                $current_line = ""
                            } else if not ($current_line | is-empty) {
                                # Partial line after newline: restore cursor and style
                                let styled = (style_line $current_line)
                                let term_cols = (try { term size | get columns } catch { 80 })
                                let line_len = ($current_line | str length)
                                let lines_up = (if $term_cols > 0 and $line_len > 0 { ($line_len - 1) // $term_cols } else { 0 })
                                if $lines_up > 0 {
                                    print -n $"\e[($lines_up)A\r\e[0J($styled)"
                                } else {
                                    print -n $"\e8\e[0J($styled)"
                                }
                            }
                        }
                    } else {
                        # Token in current line: restore cursor, clear to end of screen and highlight with bat
                        $current_line = ($current_line + $c_tok)
                        let styled = (style_line $current_line)
                        let term_cols = (try { term size | get columns } catch { 80 })
                        let line_len = ($current_line | str length)
                        let lines_up = (if $term_cols > 0 and $line_len > 0 { ($line_len - 1) // $term_cols } else { 0 })
                        if $lines_up > 0 {
                            print -n $"\e[($lines_up)A\r\e[0J($styled)"
                        } else {
                            print -n $"\e8\e[0J($styled)"
                        }
                    }
                } else {
                    print -n $c_tok
                }
            }

            # Tool call deltas
            let tc = ($delta.tool_calls? | default [])
            if not ($tc | is-empty) {
                let normalized = ($tc | each { |it|
                    if ($it.index? | default null) == null {
                        $it | insert index 0
                    } else {
                        $it
                    }
                })
                $tool_deltas = ($tool_deltas | append $normalized)
            }
        }

        if $is_interactive and not ($current_line | is-empty) {
            print ""
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

        $total_prompt_tokens = ($total_prompt_tokens + $prompt_n)
        $total_pred_tokens = ($total_pred_tokens + $pred_n)
        $total_cached_tokens = ($total_cached_tokens + $cache_n)

        # Cost calculation & metrics recording
        let rate_cfa = ($root_conf.rate_to_cfa? | default 584.0)
        let cost_res = (calculate_cost $model_info.pricing $prompt_n $pred_n $cache_n $rate_cfa)
        record_metric {
            source: $"($agent_name)"
            model: $model_alias
            turn: ($turn + 1)
            prompt_tokens: $prompt_n
            completion_tokens: $pred_n
            cached_tokens: $cache_n
            cost_usd: $cost_res.usd
            cost_cfa: $cost_res.cfa
        }
        let cum_cost = (get_cumulative_cost)
        let cost_str = (format_cost_label $cost_res $cum_cost)

        if (is-terminal --stdout) and ($turn_timings != null or $turn_usage != null) {
            mut banner_parts = [$"($model_alias):($turn + 1)"]
            let ctx_info = (if $cache_n > 0 {
                $"($prompt_n)+($pred_n) \(($cache_n)c\)"
            } else {
                $"($prompt_n)+($pred_n)"
            })
            $banner_parts = ($banner_parts | append $ctx_info)
            if $ttft_ms > 0 {
                $banner_parts = ($banner_parts | append (format_ms $ttft_ms))
            }
            if $gen_tps > 0 {
                $banner_parts = ($banner_parts | append $"($gen_tps) t/s")
            }
            $banner_parts = ($banner_parts | append $"((format_duration $turn_dur)) @ ($time_now_str)")

            let cum_tokens = ($total_prompt_tokens + $total_pred_tokens)
            $banner_parts = ($banner_parts | append $"tot: ($cum_tokens)t, ((format_duration $total_elapsed))")
            $banner_parts = ($banner_parts | append $cost_str)

            let inner = ($banner_parts | str join " | ")
            let line = $"--- ($inner) ---"
            tty_report $"\n(ansi d)($line)(ansi reset)\n"
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
        $messages = ($messages | append {
            role: "assistant"
            content: $turn_content
        })

        # Save snapshot if it was not restored (missing or updated) - local only
        if $model_info.is_local and (not $snapshot_restored) {
            try {
                http post --content-type "application/json" $"($SLOTS_URL)/($assigned_slot)?action=save" ({ model: $model_id, filename: $snap_filename } | to json -r)
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
        break
    }

    # Final grand-total session banner across all turns, child agents, and ken raw calls
    if $is_top_level and not ($metrics_file | is-empty) and ($metrics_file | path exists) {
        let metric_rows = (try { open --raw $metrics_file | lines | where ($it | is-not-empty) | each { from json } } catch { [] })
        if not ($metric_rows | is-empty) {
            let total_p = ($metric_rows | get prompt_tokens | math sum)
            let total_c = ($metric_rows | get completion_tokens | math sum)
            let total_usd = ($metric_rows | get cost_usd | math sum)
            let total_cfa = ($metric_rows | get cost_cfa | math sum)
            let total_dur = ((date now) - $t_run_start)
            let time_str = (date now | format date "%H:%M:%S")

            mut summary_parts = [$"($agent_name).($model_alias)"]
            $summary_parts = ($summary_parts | append $"($total_p + $total_c)t \(($total_p)in, ($total_c)out\)")
            $summary_parts = ($summary_parts | append $"((format_duration $total_dur)) @ ($time_str)")
            if $total_usd > 0.0 {
                let u_str = (if $total_usd < 0.0001 { $"$($total_usd | math round -p 6)" } else { $"$($total_usd | math round -p 4)" })
                let c_str = $"($total_cfa | math round -p 1) CFA"
                $summary_parts = ($summary_parts | append $"tot: ($u_str) \(($c_str)\)")
            } else {
                $summary_parts = ($summary_parts | append "tot: $0")
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
        let res = (try {
            http post --content-type "application/json" $TOKENIZE_URL ({ model: $target_model, content: $content } | to json -r)
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

    for f in $unique_files {
        let text = (try { open --raw $f } catch { "" })
        let bytes_n = ($text | str length)
        let res = (try {
            http post --content-type "application/json" $TOKENIZE_URL ({ model: $target_model, content: $text } | to json -r)
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

# Subcommand: md (Displays colored markdown)
def "main md" [
    file?: string
    --lang: string = "markdown"
] {
    let has_stdin = (not (is-terminal --stdin))
    if not ($file | is-empty) and ($file | path exists) {
        ^bat --plain --paging=never --color=always -l $lang $file
    } else if $has_stdin {
        ^bat --plain --paging=never --color=always -l $lang
    } else {
        print "Usage: ken md [file.md]"
        print "       cat file.md | ken md"
    }
}

# Subcommand: list (List agents, models, and providers)
def "main list" [] {
    let root = (get_ken_root)
    let root_conf = (load_root_config)
    let rate_cfa = ($root_conf.rate_to_cfa? | default 584.0)

    print $"Ken Providers & Models [rate: 1 USD = ($rate_cfa) CFA]:\n"
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
                $"in: \$($p_in)/1M, out: \$($p_out)/1M"
            })
            print $"    - \e[1;32m($m_alias)\e[0m -> ($m_name) [($m_ctx) ctx] \(($pricing_str)\) - ($m_desc)"
        }
    }

    let agents = (ls $root | where type == dir and (not ($it.name | path basename | str starts-with ".")) and ($it.name | path basename) != "bin" | sort-by name)
    print $"\nAvailable Ken Agents [default: ($root_conf.default_model)]:\n"
    for a in $agents {
        let a_name = ($a.name | path basename)
        let a_conf = (load_agent_config $a.name $root_conf)
        let nu_files = (glob ($a.name | path join "*.nu") | each { path parse | get stem } | sort)
        let desc = (if not ($a_conf.description | is-empty) { $" - ($a_conf.description)" } else { "" })
        let def_m = $a_conf.default_model
        print $"  - \e[1;36m($a_name)\e[0m [($def_m)]($desc):"
        if not ($nu_files | is-empty) {
            print $"      tools: ($nu_files | str join ', ')"
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

        let run_res = (try {
            http post --content-type "application/json" --max-time 60sec $LLAMA_URL ($payload | to json -r)
        } catch { |e| null })

        if $run_res == null {
            print $"\e[31m[failed]\e[0m"
            continue
        }

        let save_res = (try {
            http post --content-type "application/json" $"($SLOTS_URL)/0?action=save" ({ model: $target_model, filename: $snap_filename } | to json -r)
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
    --model (-m): string = "l"   # Model alias (defaults to 'l' for fast local extraction)
    --system (-s): string = ""   # Optional system instructions
    --max-tokens: int = 1024     # Max output tokens
    --temp: float = 0.1          # Sampling temperature
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
    let model_info = (resolve_model_info $model $root_conf)
    let chat_url = $"($model_info.base_url)/chat/completions"

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

    let t_start = (date now)
    mut curl_args = [-s -N --no-buffer $chat_url -H "Content-Type: application/json"]
    if ($model_info.auth_header? | default "" | is-not-empty) {
        $curl_args = ($curl_args | append [-H $"Authorization: ($model_info.auth_header)"])
    }
    $curl_args = ($curl_args | append [-d ($payload | to json -r)])

    mut full_content = ""
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

        let c_tok = ($chunk.choices?.0?.delta?.content? | default "")
        if not ($c_tok | is-empty) {
            $full_content = ($full_content + $c_tok)
            print -n $c_tok
        }
    }

    let t_dur = ((date now) - $t_start)
    let time_now = (date now | format date "%H:%M:%S")

    # If stream failed, print error to stderr
    if ($full_content | is-empty) and (not ($stream_lines | is-empty)) {
        let err_raw = ($stream_lines | str join "\n")
        print -e $"\n(ansi red_bold)[Ken Raw Error](ansi reset) Request to ($chat_url) failed:\n($err_raw)"
        return
    }

    if (is-terminal --stdout) and (not ($full_content | str ends-with "\n")) {
        print ""
    }

    let prompt_n = ($raw_timings.prompt_n? | default ($raw_usage.prompt_tokens? | default 0))
    let pred_n = ($raw_timings.predicted_n? | default ($raw_usage.completion_tokens? | default (count_text_tokens $full_content)))
    let cache_n = ($raw_timings.cache_n? | default ($raw_usage.prompt_tokens_details?.cached_tokens? | default 0))
    let ttft_ms = ($raw_timings.prompt_ms? | default 0 | math round)
    let gen_tps = ($raw_timings.predicted_per_second? | default 0 | into float | math round -p 1)
    let n_lines = ($full_content | lines | length)

    let rate_cfa = ($root_conf.rate_to_cfa? | default 584.0)
    let cost_res = (calculate_cost $model_info.pricing $prompt_n $pred_n $cache_n $rate_cfa)

    record_metric {
        source: "raw"
        model: $model
        turn: 1
        prompt_tokens: $prompt_n
        completion_tokens: $pred_n
        cached_tokens: $cache_n
        cost_usd: $cost_res.usd
        cost_cfa: $cost_res.cfa
    }

    let cum_cost = (get_cumulative_cost)
    let cost_str = (format_cost_label $cost_res $cum_cost)

    let ctx_str = if $cache_n > 0 {
        $"($prompt_n)+($pred_n) \(($cache_n)c\)"
    } else {
        $"($prompt_n)+($pred_n)"
    }
    mut raw_parts = [$"[raw/($model)] ($ctx_str)"]
    if $ttft_ms > 0 {
        $raw_parts = ($raw_parts | append (format_ms $ttft_ms))
    }
    let speed_and_out = if $gen_tps > 0 {
        $"($gen_tps) t/s -> ($n_lines)L ($pred_n)t \(((format_duration $t_dur)) @ ($time_now)\)"
    } else {
        $"-> ($n_lines)L ($pred_n)t \(((format_duration $t_dur)) @ ($time_now)\)"
    }
    $raw_parts = ($raw_parts | append $speed_and_out)
    $raw_parts = ($raw_parts | append $cost_str)

    let raw_line = ($raw_parts | str join " | ")
    tty_report $"\n(ansi d)($raw_line)(ansi reset)\n"
}

# Subcommand: schema (Dump OpenAI tool schema for an agent)
def "main schema" [agent: string = "orchestrator"] {
    let agent_dir = (resolve_agent_dir $agent)
    let tools = (get_agent_tools $agent_dir)
    $tools | to json
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

# Default main entrypoint
def main [
    spec?: string
    query?: string
    --image (-i): string = ""
    --slot: int = -1
    --no-md
] {
    let has_stdin = (not (is-terminal --stdin))
    let piped_input = (if $has_stdin { try { open --raw /dev/stdin } catch { "" } } else { "" })
    if $spec == null or $spec in ["-h" "--help"] {
        print "Usage: ken [session][agent.]<model> [query] [options]"
        print "       ken <subcommand>"
        print "\nSubcommands:"
        print "  ken list                  List agents, default models, and tools"
        print "  ken prefill [agent]       Pre-evaluate & save prompt snapshots"
        print "  ken tok [patterns...]     Count tokens via llama.cpp"
        print "  ken md [file]             Display colored markdown"
        print "  ken schema [agent]        Dump OpenAI tools schema"
        print "  ken session [list|clear]  Manage persistent sessions"
        print "\nExamples:"
        print "  ken 1qwent 'Solve step by step'"
        print "  ken notes.lfm 'What is a PCB?'"
        print "  ken tok '~/Documents/notes/**/*.typ'"
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

    run_agent $spec $full_query $image $slot $no_md
}
