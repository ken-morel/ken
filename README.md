# Ken (Agentic Assistant Engine)

A fast, minimalist, zero-dependency agentic assistant engine written in pure [Nushell](https://www.nushell.sh/).

Ken turns directories of simple Nushell scripts into a hierarchy of specialized AI agents with autonomous tool execution, subagent delegation, local KV cache snapshotting, and strict separation between interactive terminal UI and Unix pipeline streams.

---

## Highlights

- **Pure Nushell Engine**: Self-contained in a single executable (`ken.nu`) with zero external package dependencies.
- **Strict `/dev/tty` vs `stdout` Separation**:
  - Live visual telemetry—session brackets (`[` / `]`), thinking tokens (`<` / `>`), tool executions (`{` / `}`), and progressive syntax-highlighted Markdown—streams directly to `/dev/tty`.
  - Piped standard output (`stdout`) delivers clean, unformatted text with zero ANSI escape codes, enabling seamless Unix composition (`ken q "..." | ken coder "..."`).
- **Autonomous Delegation Without Symlinks**:
  - Agents declare callable subagents directly in `config.nuon` (`subagents: ["mail", "fs", "notes"]`).
  - `ken` auto-synthesizes OpenAI function calling schemas with live introspection of available subagent descriptions and models.
- **Virtual Slot & KV Cache Preservation**:
  - Keeps local inference engines (e.g. `llama.cpp`) at `parallel = 1` to conserve VRAM/RAM on battery while providing virtualized multi-agent slots via disk snapshots (`~/.cache/ken/slots`).
  - Swaps and restores KV states across recursive subagent calls to eliminate redundant prompt evaluation.
- **Cascading Configuration**:
  - Global configuration in `config.nuon` and secrets in `env.nuon`.
  - Per-agent overrides (`<agent>/config.nuon`) for temperature, top-p, context limits, and default models.

---

## Installation

### 1. Link `ken` to your PATH
```bash
git clone https://github.com/engon/ken.git ~/ken
mkdir -p ~/.local/bin
ln -sf ~/ken/ken.nu ~/.local/bin/ken
```
Make sure `~/.local/bin` is in your `$PATH`.

### 2. Shell Integration
Add this line to your shell configuration file (e.g. `~/.zshrc`, `~/.bashrc`, or `~/.config/fish/config.fish`):

```bash
# In ~/.zshrc or ~/.bashrc:
. <(ken setup $SHELL ~/.config/ken)
```

The `setup` subcommand:
- Exports `KEN_DIR` and `KEN_ROOT` pointing to your agent configuration directory.
- For Zsh, registers the interactive `Alt+E` (`^[e`) command-line helper:
  - Type `# find large files` and press `Alt+E` $\to$ generates the command directly on your prompt.
  - Type `tar -czf archive.tar.gz /path # exclude git` and press `Alt+E` $\to$ modifies the command in place.
  - Type `git rebase -i HEAD~3;` and press `Alt+E` $\to$ explains what the command does.

---

## Directory Structure

Ken separates the engine (`~/ken`) from your personal agent configurations (`~/.config/ken`):

```text
~/.config/ken/
├── config.nuon            # Root config (providers, models, defaults)
├── env.nuon               # Environment secrets & API keys (gitignored)
├── models.ini             # Optional llama-server model runner configurations
└── <agent>/               # Agent directory (e.g. orchestrator, mail, coder, fs)
    ├── config.nuon        # Agent metadata & callable subagents
    ├── prompt.md          # System instructions & persona
    └── <tool>.nu          # Nushell tool scripts (auto-introspected as tools)
```

### Agent Configuration (`<agent>/config.nuon`)
```nuon
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

### Tool Definition (`<agent>/<tool>.nu`)
Any `.nu` script in an agent folder with a documented `main` function is automatically introspected and exposed as a tool:

```nu
#!/usr/bin/env nu
# Read lines from a file
def main [
    path: string       # Path to the file to inspect
    --limit (-n): int  # Maximum lines to read
] {
    open $path | lines | take ($limit | default 50) | str join "\n"
}
```

---

## Usage

### Basic Queries
```bash
# Query the default agent with default model
ken "What is the capital of France?"

# Specify a model alias (e.g. 'q' for Qwen, 'l' for LFM, 'a' for Gemini)
ken q "Explain SQLite WAL mode"

# Target a specific domain specialist agent
ken mail.q "Did I receive any invoice from GitHub today?"
ken notes.l "Summarize the PCB section in operating systems notes"
```

### Raw Model Inference (Fast One-Shot Prompting)
```bash
ken raw "Translate to French: Hello world" -m l
```

### Pipeline Composition
Because `ken` outputs clean text when stdout is a pipe, you can pipe model outputs directly:
```bash
ken q "Generate a JSON schema for a blog post" | jq .
ken q "Write a git commit message for recent changes" | git commit -F -
```

### Management Commands
```bash
ken list                  # List all available agents, models, and tools
ken prefill [agent]       # Pre-evaluate and save prompt KV cache snapshots
ken tok [patterns...]     # Tokenize and count tokens via llama.cpp
ken session list          # List persistent conversation sessions
ken session clear [id]    # Clear session history
```

---

## Visual Telemetry Grammar

Ken indents output by 2 spaces per recursion depth (`$depth * 2`) and uses distinctive single-bracket delimiters for clear visual hierarchy:

- `[` ... `]` : Agent session lifecycle & summary banners
- `<` ... `>` : Reasoning / thinking tokens (dimmed content)
- `{` ... `}` : Tool invocations and execution returns
- `---` ... `---` : Turn metrics (tokens, time-to-first-token, speed)

---

## License

MIT
