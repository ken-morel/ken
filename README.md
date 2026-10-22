# ken

An agent runner in a single Nushell script.

Agents live in a configuration directory (`~/.config/ken` by default). Each agent is a directory containing a `prompt.md`, an optional `config.nuon`, and `.nu` scripts that expose tools to the model. `ken` handles the conversation loop, streams output, runs tool calls, and delegates to subagents. It works with `llama-server` (llama.cpp) locally and with OpenAI-compatible `/chat/completions` APIs.

## Requirements

- [Nushell](https://www.nushell.sh/) (`nu`)
- [`bat`](https://github.com/sharkdp/bat) (used to highlight Markdown as it streams)
- A model server: `llama-server` or an OpenAI-compatible API endpoint

## Installation

```bash
git clone https://github.com/engon/ken.git ~/ken
mkdir -p ~/.local/bin
ln -sf ~/ken/ken.nu ~/.local/bin/ken
```

Add the shell setup output to your shell rc file (`.zshrc`, `.bashrc`, `config.fish`):

```bash
. <(ken setup $SHELL ~/.config/ken)
```

`ken setup` prints a snippet that exports `KEN_DIR` and `KEN_ROOT`. On `zsh`, it also binds `Alt+E` (`^[e`) to a line-editor widget (referencing a `cmd` agent):

- `# find files over 100MB` — replaces the line with a generated command.
- `tar -czf a.tgz ~/src # exclude .git` — rewrites the command before `#` according to the instruction after `#`.
- `git rebase -i HEAD~3;` — prints an explanation of the command.

For `bash`, `fish`, and `nu`, `ken setup` only sets the environment variables.

## Directory Layout

The engine (`~/ken/ken.nu`) and configuration (`~/.config/ken`) are separate:

```text
~/.config/ken/
├── config.nuon        # providers, models, defaults
├── env.nuon           # API keys and environment variables
└── orchestrator/
    ├── config.nuon    # agent settings and subagents
    ├── prompt.md      # system prompt
    ├── search.nu      # tool script
    └── extract.nu     # tool script
```

`ken` resolves the configuration directory in this order:
1. `$KEN_DIR`
2. `$KEN_ROOT`
3. `$XDG_CONFIG_HOME/ken` (or `~/.config/ken`)
4. The directory containing `ken.nu` (if `config.nuon` exists there)
5. The current working directory (`$PWD`)

Environment variables are loaded from `env.nuon` or `.env.nuon` in the configuration directory.

## Root Configuration

```nuon
# ~/.config/ken/config.nuon
{
    default_agent: "orchestrator"
    default_model: "q"
    default_ctx: 16384
    currency: "$"

    options: {
        temperature: 0.6
        top_p: 0.95
    }

    providers: {
        local: {
            base_url: "http://127.0.0.1:6172/v1"
            models: {
                q: {
                    name: "q"
                    description: "Qwen 4B local"
                    ctx: 16384
                    pricing: { input: 0.0, output: 0.0, cache_hit: 0.0 }
                }
                l: {
                    name: "l"
                    description: "LFM 1.2B local"
                    ctx: 16384
                    pricing: { input: 0.0, output: 0.0, cache_hit: 0.0 }
                }
            }
        }
        deepseek: {
            base_url: "https://api.deepseek.com"
            api_key_env: "DEEPSEEK_API_KEY"
            models: {
                adc: {
                    name: "deepseek-chat"
                    description: "DeepSeek V3"
                    ctx: 65536
                    pricing: { input: 0.14, output: 0.28, cache_hit: 0.014 }
                }
            }
        }
    }
}
```

- `api_key_env` names the environment variable containing the API key (defined in `env.nuon`).
- `pricing` values are per 1M tokens in the unit specified by `currency` (default `"$"`).

## Agents

```nuon
# ~/.config/ken/orchestrator/config.nuon
{
    name: "orchestrator"
    description: "Task coordination and general assistance"
    default_model: "q"
    subagents: ["fs", "notes", "code"]
}
```

Supported fields in `<agent>/config.nuon`:
- `name`, `description`, `default_model`, `supported_models`
- `subagents`: list of agent names this agent is allowed to call. When non-empty, `ken` synthesizes a `call_agent` tool for the model. Delegation stops at depth 3.
- `options` and `models.<alias>`: per-agent and per-model sampling overrides (`temperature`, `top_p`, `top_k`, `min_p`, `max_tokens`, etc.), merged over the root config.

The system prompt is read from `<agent>/prompt.md`.

## Tools

Every `.nu` file in an agent directory is inspected via Nushell's `scope commands` and converted into an OpenAI function schema:

```nu
#!/usr/bin/env nu
# Read lines from a file
def main [
    path: string        # Path to the file
    --limit (-n): int   # Maximum lines to read
] {
    open $path | lines | take ($limit | default 50) | str join "\n"
}
```

The comment above `def main` becomes the function description, parameter comments become argument descriptions, and parameter types (`int`, `bool`, switches, strings) map to JSON schema types.

## Usage

```text
ken [session][agent.]<model> [query] [--image (-i) <path>] [--slot <n>] [--no-md]
```

Target specification examples:

| Spec | Agent | Model | Session |
| :--- | :--- | :--- | :--- |
| `q` | default agent | `q` | none |
| `notes` | `notes` | agent's default | none |
| `notes.l` | `notes` | `l` | none |
| `1q` | default agent | `q` | `1` |
| `2notes.l` | `notes` | `l` | `2` |

A leading number selects a persistent session stored in `~/.cache/ken/sessions/<agent>_<id>.json`.

```bash
ken "What is SQLite WAL mode?"
ken notes.l "What is a PCB?"
cat file.txt | ken q "Summarize this"
ken q "Output a JSON object with keys a and b" | jq .
```

### Output Streams (`/dev/tty` vs `stdout`)

Status lines and live streamed output are written to `/dev/tty`, indented by two spaces per recursion depth:
- `[` ... `]` — agent or raw session start and end summary
- `<` ... `>` — reasoning / thinking tokens
- `{` ... `}` — tool call arguments and return metrics
- `---` ... `---` — per-turn token counts, TTFT, and generation speed

When `stdout` is piped or redirected, only the plain response text is written to `stdout` without ANSI sequences or telemetry tags.

## Subcommands

```text
ken setup [shell] [dir]      Print shell integration script
ken list                     List configured providers, models, agents, and tools
ken prefill [agent]          Evaluate agent system prompts and save slot snapshots
ken tok [patterns...]        Count tokens via llama.cpp /tokenize or stdin
ken md [file] [-p <prefix>]  Render Markdown with bat
ken schema [agent]           Print the generated OpenAI tool schema JSON
ken raw [prompt] -m <model>  Run a single completion without tools or sessions
ken session [list|clear|show] [id]
```

## Local Slot Snapshots

For the `local` provider (`llama-server`), `ken` caches evaluated system prompts in `~/.cache/ken/slots/<agent>_<model>.bin`:

- On startup, if a snapshot exists and is newer than the files in the agent folder, `ken` restores it into the slot instead of re-evaluating the system prompt.
- `ken prefill` generates these snapshots ahead of time.
- When an agent delegates to a subagent that shares the same local model, `ken` saves the caller's slot state to `active_depth_<depth>_<model>.bin` and restores it when the subagent finishes.
