#!/usr/bin/env nu
# Ken - Local Agentic Assistant in pure Nushell

const LLAMA_URL = "http://127.0.0.1:6172/v1/chat/completions"
const TOKENIZE_URL = "http://127.0.0.1:6172/tokenize"
const SLOTS_URL = "http://127.0.0.1:6172/slots"
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

def get_session_dir [] {
    let d = ($env.HOME | path join ".cache" "ken" "sessions")
    mkdir $d
    $d
}

def get_slots_dir [model: string = "qwen"] {
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

# Parse model specifier: [session][agent.]<model>
def parse_spec [spec_str: string] {
    let raw = ($spec_str | default "")
    
    # Try: (digits)?(agent.)?(model)
    let p1 = ($raw | parse -r '^(?:(?<session>\d+))?(?:(?<agent>[a-zA-Z0-9_-]+)\.)?(?<model>qwent|qwen|lfm|dskt|dsk)$')
    if not ($p1 | is-empty) {
        let row = ($p1 | first)
        let s = (if ($row.session | is-empty) { null } else { $row.session })
        let a = (if ($row.agent | is-empty) { "orchestrator" } else { $row.agent })
        let m_spec = $row.model
        let is_thinking = ($m_spec in ["qwent" "dskt"])
        let m = match $m_spec {
            "lfm" => "lfm"
            "dsk" | "dskt" => "dsk"
            _ => "qwen"
        }
        return { session: $s, agent: $a, model: $m, thinking: $is_thinking }
    }

    # Fallback: (digits)?(agent)
    let p2 = ($raw | parse -r '^(?:(?<session>\d+))?(?<agent>[a-zA-Z0-9_-]+)$')
    if not ($p2 | is-empty) {
        let row = ($p2 | first)
        let s = (if ($row.session | is-empty) { null } else { $row.session })
        let a = $row.agent
        if $a in ["qwen" "qwent" "lfm" "dsk" "dskt"] {
            let is_thinking = ($a in ["qwent" "dskt"])
            let m = match $a {
                "lfm" => "lfm"
                "dsk" | "dskt" => "dsk"
                _ => "qwen"
            }
            return { session: $s, agent: "orchestrator", model: $m, thinking: $is_thinking }
        }
        return { session: $s, agent: $a, model: "qwen", thinking: false }
    }

    { session: null, agent: "orchestrator", model: "qwen", thinking: false }
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
    tty_report $"\n\e[36m[call]\e[0m ($agent_name)/($fn_name) ($formatted_args)\n"
    let res = (^nu $tool_path ...$pos_args ...$named_args | complete)
    let t_dur = ((date now) - $t_start)

    if $res.exit_code == 0 {
        let output = (if not ($res.stdout | is-empty) { $res.stdout } else { "(Success with no output)" })
        let n_lines = ($output | lines | length)
        let n_bytes = ($output | str length | into filesize)
        # Print the entire tool output so the user can inspect intermediate results and context
        tty_report $"($output)\n"
        tty_report $"\e[32m[done]\e[0m ($agent_name)/($fn_name) -> ($n_lines) lines, ($n_bytes) \(took ($t_dur)\)\n\n"
        $output
    } else {
        tty_report $"\e[31m[error]\e[0m ($agent_name)/($fn_name) -> exit ($res.exit_code) \(took ($t_dur)\)\n"
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
    let model_id = $parsed.model
    let thinking = $parsed.thinking
    let session_id = $parsed.session

    let agent_dir = (resolve_agent_dir $agent_name)
    if not ($agent_dir | path exists) {
        print -e $"Error: Agent directory '($agent_name)' not found."
        return
    }

    let prompt_file = ($agent_dir | path join "prompt.md")
    let system_prompt = (if ($prompt_file | path exists) { open --raw $prompt_file } else { $"You are the Ken ($agent_name) agent." })

    # Tools
    let tools = (if $agent_name != "cmd" {
        get_agent_tools $agent_dir
    } else {
        []
    })

    # Slot allocation by alphabetical agent index
    let root = (get_ken_root)
    let all_agents = (ls $root | where type == dir and (not ($it.name | path basename | str starts-with ".")) and ($it.name | path basename) != "bin" | get name | each { path basename } | sort)
    let agent_idx = ($all_agents | enumerate | where item == $agent_name | get 0.index? | default 0)
    let assigned_slot = (if $slot_override >= 0 { $slot_override } else { $agent_idx mod 2 })

    # Slot snapshot check
    let slots_dir = (get_slots_dir $model_id)
    let snapshot_file = ($slots_dir | path join $"($agent_name).bin")
    let has_snapshot = ($snapshot_file | path exists)

    if $has_snapshot {
        try {
            http post --content-type "application/json" $"($SLOTS_URL)/($assigned_slot)?action=restore" ({ model: $model_id, filename: $"($agent_name).bin" } | to json -r)
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
    mut final_timings: any = null
    mut final_usage: any = null

    # Conversation / tool-calling turns (up to 8)
    for turn in 0..7 {
        mut payload = {
            model: $model_id
            messages: $messages
            stream: true
            stream_options: { include_usage: true }
            timings_per_token: true
            cache_prompt: true
            id_slot: $assigned_slot
            temperature: (if $thinking { 0.6 } else { 0.2 })
        }
        if not ($tools | is-empty) {
            $payload = ($payload | insert tools $tools)
        }

        # Real-time streaming turn
        mut turn_content = ""
        mut turn_reasoning = ""
        mut tool_deltas = []
        mut current_line = ""

        if $is_interactive {
            print -n "\e7" # Save cursor at start of first line
        }

        for line in (^curl -s -N --no-buffer $LLAMA_URL -H "Content-Type: application/json" -d ($payload | to json -r) | lines) {
            if not ($line | str starts-with "data: {") {
                continue
            }
            let chunk = (try { $line | str substring 6.. | from json } catch { null })
            if $chunk == null { continue }

            if ($chunk.timings? | default null) != null {
                $final_timings = $chunk.timings
            }
            if ($chunk.usage? | default null) != null {
                $final_usage = $chunk.usage
            }

            let delta = ($chunk.choices?.0?.delta? | default {})

            # Reasoning tokens
            let r_tok = ($delta.reasoning_content? | default "")
            if not ($r_tok | is-empty) {
                $turn_reasoning = ($turn_reasoning + $r_tok)
                if $thinking {
                    print -n ("\e[2m" + $r_tok + "\e[0m")
                }
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
                $tool_deltas = ($tool_deltas | append $tc)
            }
        }

        if $is_interactive and not ($current_line | is-empty) {
            print ""
        }

        # Check for tool calls
        if not ($tool_deltas | is-empty) {
            # Reconstruct tool calls
            let tool_calls = ($tool_deltas | group-by index | values | each { |d|
                let id = ($d | get -o id | compact | first | default "call_0")
                let name = ($d | get -o function.name | compact | str join "")
                let args_str = ($d | get -o function.arguments | compact | str join "")
                {
                    id: $id
                    type: "function"
                    function: {
                        name: $name
                        arguments: $args_str
                    }
                }
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

        # Save snapshot if first time
        if (not $has_snapshot) {
            try {
                http post --content-type "application/json" $"($SLOTS_URL)/($assigned_slot)?action=save" ({ model: $model_id, filename: $"($agent_name).bin" } | to json -r)
            }
        }

        # Footer stats banner
        if (is-terminal --stdout) and ($final_timings != null or $final_usage != null) {
            let cache_n = ($final_timings.cache_n? | default 0)
            let prompt_n = ($final_timings.prompt_n? | default ($final_usage.prompt_tokens? | default 0))
            let pred_n = ($final_timings.predicted_n? | default ($final_usage.completion_tokens? | default 0))
            let ttft_ms = ($final_timings.prompt_ms? | default 0 | math round)
            let gen_tps = ($final_timings.predicted_per_second? | default 0 | into float | math round -p 1)

            mut banner_parts = [("--- " + $model_id)]
            let ctx_info = (if $cache_n > 0 {
                $"ctx: ($prompt_n)+($pred_n) \(($cache_n) cached\)"
            } else {
                $"ctx: ($prompt_n)+($pred_n)"
            })
            $banner_parts = ($banner_parts | append $ctx_info)
            if $ttft_ms > 0 {
                $banner_parts = ($banner_parts | append $"ttft: ($ttft_ms)ms")
            }
            if $gen_tps > 0 {
                $banner_parts = ($banner_parts | append $"gen: ($gen_tps) t/s")
            }
            $banner_parts = ($banner_parts | append "---")

            let line = ($banner_parts | str join " | ")
            print ("\n\e[2m" + $line + "\e[0m")
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
}

# Subcommand: tok (Count tokens)
def "main tok" [
    ...patterns: string
    --model (-m): string = "qwen"
    --json
] {
    let has_stdin = (not (is-terminal --stdin))
    let piped_input = (if $has_stdin { try { open --raw /dev/stdin } catch { "" } } else { "" })

    if not ($piped_input | is-empty) {
        let content = $piped_input
        let res = (try {
            http post --content-type "application/json" $TOKENIZE_URL ({ model: $model, content: $content } | to json -r)
        } catch { { tokens: [] } })
        let n_tokens = ($res.tokens | length)
        let n_bytes = ($content | str length)
        if $json {
            { source: "stdin", model: $model, bytes: $n_bytes, tokens: $n_tokens } | to json
        } else {
            let pct = (($n_tokens / $DEFAULT_CTX) * 100 | math round -p 1)
            let sz = ($n_bytes | into filesize)
            print $"Tokens: ($n_tokens) | Size: ($sz) | ($pct)% of ($DEFAULT_CTX) ctx \(($model)\)"
        }
        return
    }

    if ($patterns | is-empty) {
        print "Usage: cat file | ken tok"
        print "       ken tok [patterns...] [--model qwen|lfm] [--json]"
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
            http post --content-type "application/json" $TOKENIZE_URL ({ model: $model, content: $text } | to json -r)
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
            model: $model
            total_files: ($results | length)
            total_bytes: $total_bytes
            total_tokens: $total_tokens
            ctx_size: $DEFAULT_CTX
            ctx_percent: (($total_tokens / $DEFAULT_CTX) * 100 | math round -p 1)
            files: $results
        } | to json
        return
    }

    # Print table
    print ($results | table -e)
    let pct = (($total_tokens / $DEFAULT_CTX) * 100 | math round -p 1)
    let total_sz = ($total_bytes | into filesize)
    print ("------------------------------------------------------------")
    print ("Total: " + ($results | length | into string) + " files | " + ($total_sz | into string) + " | " + ($total_tokens | into string) + " tokens (" + ($pct | into string) + "% of " + ($DEFAULT_CTX | into string) + " ctx [" + $model + "])")
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

# Subcommand: list (List agents and tools)
def "main list" [] {
    let root = (get_ken_root)
    let agents = (ls $root | where type == dir and (not ($it.name | path basename | str starts-with ".")) and ($it.name | path basename) != "bin" | sort-by name)
    print "Available Ken Agents & Tools:"
    for a in $agents {
        let a_name = ($a.name | path basename)
        let nu_files = (glob ($a.name | path join "*.nu") | each { path parse | get stem } | sort)
        let has_prompt = (if (($a.name | path join "prompt.md") | path exists) { " [has prompt.md]" } else { "" })
        print $"- ($a_name)($has_prompt):"
        if not ($nu_files | is-empty) {
            print $"    tools: ($nu_files | str join ', ')"
        } else {
            print "    tools: (none)"
        }
    }
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
        print "  ken list                  List agents and tools"
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
