# ken

An agent runner in a single Nushell file.

You keep your agents in a config directory. Each agent is a folder with a `prompt.md`, an optional `config.nuon`, and `.nu` scripts that become the model's tools. `ken` runs the agentic loop: it streams the response live to `/dev/tty`, executes tool calls requested by the model, and delegates to other agents declared in `subagents`. It communicates with `llama-server` (llama.cpp) locally or any OpenAI-compatible API endpoint that supports function calling.

---

## Requirements

- [Nushell](https://www.nushell.sh/) (`nu`)
- [`bat`](https://github.com/sharkdp/bat) (used for progressive line syntax highlighting as output streams)
- A model endpoint: local `llama-server` (llama.cpp) or a remote OpenAI-compatible API endpoint (`/chat/completions`)

---

## Installation

### 1. Link `ken` to your PATH
```bash
git clone https://github.com/engon/ken.git ~/ken
mkdir -p ~/.local/bin
ln -sf ~/ken/ken.nu ~/.local/bin/ken
```

### 2. Shell Integration
Add this to your shell startup file (`~/.zshrc`, `~/.bashrc`, or `~/.config/fish/config.fish`):

```bash
. <(ken setup $SHELL ~/.config/ken)
```

`ken setup` prints a snippet exporting `KEN_DIR` and `KEN_ROOT`. On Zsh, it also binds `Alt+E` (`^[e`) on the command line:

- `# find files over 100MB` $\to$ generates the command on your line.
- `tar -czf archive.tar.gz ~/src # skip git` $\to$ rewrites the command using the instruction after `#`.
- `git rebase -i HEAD~3;` $\to$ explains what the command does.

---

## Directory Layout

The `ken` engine repository and your personal agents/configs are kept strictly separate. `~/.config/ken` holds your agents and configuration:

```text
~/.config/ken/
├── config.nuon            # Root config: providers, models, defaults, currency
├── env.nuon               # Secrets & API keys (read into environment)
├── models.ini             # Optional local llama-server launcher configuration
└── <agent>/               # One directory per agent
    ├── config.nuon        # Agent metadata & callable subagents
    ├── prompt.md          # System instructions & persona
    └── <tool>.nu          # Nushell scripts exposed as model tools
```

`ken` discovers its configuration directory in this priority order:
1. `$KEN_DIR` or `$KEN_ROOT` (set by `ken setup`)
2. `$XDG_CONFIG_HOME/ken` (or `~/.config/ken`)
3. The directory containing `ken.nu` (if bundled together as a self-contained folder)
4. The current working directory (`$PWD`)

Secrets are loaded from `env.nuon` or `.env.nuon` inside the configuration directory.

---

## Agents

```nuon
# ~/.config/ken/orchestrator/config.nuon
{
    name: "orchestrator"
    description: "Central intelligence, task coordination, and general assistance"
    default_model: "q"
    subagents: [
        "mail"
        "notes"
        "fs"
        "code"
    ]
}
```

- **Keys**: `name`, `description`, `default_model`, `subagents`, `options` (temperature, top_p, etc.), and `models` (per-model overrides).
- **Subagents**: Listing an agent name in `subagents` automatically generates the `call_agent` tool for the model, enabling autonomous delegation. Delegation is restricted strictly to declared subagents, and recursion automatically halts at depth 3.

---

## Tools

Every `.nu` script in an agent folder with a documented `main` function is automatically introspected into an OpenAI function-calling tool schema:

```nu
#!/usr/bin/env nu
# Read lines from a file
def main [
    path: string        # Path to the file to inspect
    --limit (-n): int   # Maximum lines to read
] {
    open $path | lines | take ($limit | default 50) | str join "\n"
}
```

- The doc-comment above `main` becomes the tool description.
- Parameter comments become argument descriptions.
- Flags and switches are mapped to types (`string`, `integer`, `boolean`).

---

## Running

```text
ken [session][agent.]<model> [query] [--image <path>] [--slot <n>] [--no-md]
```

The target spec syntax:

| Spec | Agent | Model |
| :--- | :--- | :--- |
| `q` | Default agent (`orchestrator`) | `q` |
| `mail` | `mail` | Agent default model |
| `mail.l` | `mail` | `l` |
| `2mail.l` | `mail` (Session 2) | `l` |
| `2q` | Default agent (Session 2) | `q` |

A leading number designates a persistent session ID (`~/.cache/ken/sessions/<session>.json`), allowing multi-turn conversations to pick up where they left off.

```bash
# Basic query
ken "What is SQLite WAL mode?"

# Specify a model alias
ken q "Explain the Raft consensus algorithm"

# Target a domain specialist agent
ken mail.q "Did I receive any invoice from GitHub today?"

# Pipe text from stdin
cat notes.typ | ken notes.l "Summarize the key formulas"

# Pipe output cleanly into another tool
ken q "Generate a JSON schema for a user profile" | jq .
```

### Strict `/dev/tty` vs `stdout` Pipeline Separation
- All interactive telemetry—agent banners (`[` / `]`), thinking tokens (`<` / `>`), tool calls (`{` / `}`), and progressive syntax-highlighted Markdown—streams directly to `/dev/tty`.
- When stdout is redirected or piped (`ken ... | other_tool`), `stdout` receives pure, clean model output with zero ANSI color escape codes or UI noise.

---

## Subcommands

```text
ken setup [shell] [dir]     Emit shell integration script for .zshrc / .bashrc
ken list                    List configured providers, models, agents, and tools
ken prefill [agent]         Pre-evaluate prompt and save KV cache slot snapshot
ken tok [patterns...]       Count tokens via llama.cpp /tokenize endpoint or stdin
ken md [file]               Syntax-highlight Markdown with hierarchy indentation
ken schema [agent]          Dump generated OpenAI function calling tool schemas
ken raw "prompt" -m l       Execute fast one-shot completion without tools or sessions
ken session list|clear|show Manage persistent conversation sessions
```

---

## Virtual Slots & Local KV Caching

When running local models via `llama-server`, setting `parallel = 1` conserves VRAM and RAM on battery while `ken` virtualizes multi-agent slots via disk snapshots (`~/.cache/ken/slots/<agent>_<model>.bin`).

- **Snapshot Restore**: On startup, if a prompt snapshot exists and is newer than the agent's files, `ken` restores the snapshot into slot 0 in milliseconds instead of re-evaluating system prompts.
- **`ken prefill`**: Pre-evaluates and caches the prompt snapshots ahead of time across all agents.
- **Recursive State Preservation**: When an agent delegates via `call_agent`, caller KV state is saved and restored upon return, eliminating redundant prompt evaluation on multi-turn local runs.

---

## Root Configuration (`~/.config/ken/config.nuon`)

```nuon
{
    default_agent: "orchestrator"
    default_model: "q"
    default_ctx: 16384
    currency: "$"  # Display currency symbol or code (e.g. "$", "EUR", "CFA")

    options: {
        temperature: 0.6
        top_p: 0.95
    }

    providers: {
        local: {
            type: "openai"
            base_url: "http://127.0.0.1:6172/v1"
            models: {
                q: {
                    name: "q"
                    description: "Qwen 2.5 4B (Local GPU)"
                    ctx: 16384
                    pricing: { input: 0.0, output: 0.0, cache_hit: 0.0 }
                }
                l: {
                    name: "l"
                    description: "LFM 2.5 1.2B (Local GPU)"
                    ctx: 16384
                    pricing: { input: 0.0, output: 0.0, cache_hit: 0.0 }
                }
            }
        }
        deepseek: {
            type: "openai"
            base_url: "https://api.deepseek.com"
            api_key_env: "DEEPSEEK_API_KEY"
            models: {
                adc: {
                    name: "deepseek-chat"
                    description: "DeepSeek V3 (Cloud)"
                    ctx: 65536
                    pricing: { input: 0.14, output: 0.28, cache_hit: 0.014 }
                }
                adr: {
                    name: "deepseek-reasoner"
                    description: "DeepSeek R1 (Cloud)"
                    ctx: 65536
                    pricing: { input: 0.55, output: 2.19, cache_hit: 0.14 }
                }
            }
        }
    }
}
```

- **`pricing`**: Defined per 1M tokens directly in your chosen `currency`. The totals shown at the end of runs are computed directly in this unit with zero conversion artifacts.
- **`api_key_env`**: Names the environment variable holding your secret key (stored safely in `env.nuon`).

---

## Visual Telemetry Grammar

Ken indents output by 2 spaces per recursion depth (`$depth * 2`) using clean single-character delimiters:

- `[` ... `]` : Agent session lifecycle banners and grand totals
- `<` ... `>` : Reasoning and thinking tokens (dimmed)
- `{` ... `}` : Tool call invocations and results
- `---` ... `---` : Turn metrics (token counts, TTFT, generation speed)

---

## License

MIT
